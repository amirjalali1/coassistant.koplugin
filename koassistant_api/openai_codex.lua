local OpenAIHandler = require("koassistant_api.openai")
local ResponseParser = require("koassistant_api.response_parser")
local DebugUtils = require("koassistant_debug_utils")
local ModelConstraints = require("model_constraints")
local OAuth = require("koassistant_openai_codex_oauth")
local json = require("json")

local CodexHandler = OpenAIHandler:new()

local CODEX_URL = "https://chatgpt.com/backend-api/codex/responses"
local USER_AGENT = "codex_cli_rs/0.0.0 (KOAssistant)"
local ORIGINATOR = "codex_cli_rs"

local function buildHeaders(config)
    local account_id = config.oauth and config.oauth.chatgpt_account_id
    return {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer " .. (config.api_key or ""),
        ["ChatGPT-Account-ID"] = account_id or "",
        ["User-Agent"] = USER_AGENT,
        ["originator"] = ORIGINATOR,
    }
end

function CodexHandler:buildRequestBody(message_history, config)
    local model = config.model or "gpt-5.6-terra"
    local built = self:buildResponsesRequest(message_history, config, model)
    built.url = CODEX_URL
    built.provider = "openai_codex"
    built.headers = buildHeaders(config)
    -- ChatGPT's Codex backend chooses its own output ceiling and rejects the
    -- public Responses API's max_output_tokens field.
    built.body.max_output_tokens = nil
    return built
end

function CodexHandler:query(message_history, config)
    if not config or not config.api_key then
        return "Error: Missing OAuth access token in configuration"
    end
    if not (config.oauth and config.oauth.chatgpt_account_id) then
        return "Error: Missing ChatGPT account id in OAuth configuration"
    end

    local built = self:buildRequestBody(message_history, config)
    local request_body = built.body
    local base_url = built.url
    local headers = built.headers
    local use_streaming = config.features and config.features.enable_streaming ~= false

    if config and config.features and config.features.debug then
        ModelConstraints.logAdjustments("OpenAI Subscription", built.adjustments)
        DebugUtils.print("OpenAI Codex Request Body:", request_body, config)
        print("Streaming enabled:", use_streaming and "yes" or "no")
    end

    local requestBody = json.encode(request_body)
    headers["Content-Length"] = tostring(#requestBody)

    if use_streaming then
        local stream_request_body = json.decode(requestBody)
        stream_request_body.stream = true
        local stream_body = json.encode(stream_request_body)
        headers["Content-Length"] = tostring(#stream_body)
        headers["Accept"] = "text/event-stream"

        local stream_fn = self:backgroundRequest(base_url, headers, stream_body)
        local effort = request_body.reasoning and request_body.reasoning.effort
        if effort then
            return {
                _stream_fn = stream_fn,
                _reasoning_requested = true,
                _reasoning_effort = effort,
            }
        end
        return stream_fn
    end

    local parser_key = built.parser or "openai_responses"
    local reasoning_effort = request_body.reasoning and request_body.reasoning.effort
    local debug_enabled = config and config.features and config.features.debug

    local response_parser = function(response)
        if debug_enabled then
            DebugUtils.print("OpenAI Codex Parsed Response:", response, config)
        end
        local parse_success, result, reasoning, web_search_used = ResponseParser:parseResponse(response, parser_key)
        if not parse_success then
            return false, "Error: " .. result
        end
        if reasoning_effort then
            return true, result, { _requested = true, effort = reasoning_effort }, web_search_used
        end
        return true, result, reasoning, web_search_used
    end

    return {
        _background_fn = self:backgroundRequest(base_url, headers, requestBody),
        _non_streaming = true,
        _response_parser = response_parser,
    }
end

function CodexHandler:getOAuthModule()
    return OAuth
end

return CodexHandler
