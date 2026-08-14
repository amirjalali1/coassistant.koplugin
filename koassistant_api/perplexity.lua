--[[--
Perplexity API Handler

OpenAI-compatible handler for Perplexity Sonar models.
Web search is ON BY DEFAULT (the provider's native behavior) but toggleable
since 2026-08-14: disable_search is real on the wire (probed — the old
"always-on, not toggleable" claim was false), sent when the resolved web
decision is off; the Web chip seeds ON for this provider so the default is
truthful. Citations are appended as clickable footnotes by the response
parser; web_search_used is reported only when search artifacts came back.

Reasoning models (sonar-reasoning-pro) support reasoning_effort parameter
and use <think> tags for reasoning output. Reasoning is always-on for these
models — effort controls depth, not whether reasoning occurs.

Endpoint: https://api.perplexity.ai/chat/completions
Docs: https://docs.perplexity.ai/

@module perplexity
]]

local OpenAICompatibleHandler = require("koassistant_api.openai_compatible")
local ModelConstraints = require("model_constraints")

local PerplexityHandler = OpenAICompatibleHandler:new()

function PerplexityHandler:getProviderName()
    return "Perplexity"
end

function PerplexityHandler:getProviderKey()
    return "perplexity"
end

-- Perplexity sonar-reasoning-pro uses <think> tags for reasoning
function PerplexityHandler:supportsReasoningExtraction()
    return true
end

-- Perplexity requires strict user/assistant message alternation.
-- Merge consecutive same-role messages to avoid 400 errors
-- (e.g., context message + user question are both role="user").
-- Also add reasoning_effort for reasoning models.
function PerplexityHandler:customizeRequestBody(body, config)
    local messages = body.messages
    if messages and #messages > 1 then
        local merged = { messages[1] }
        for i = 2, #messages do
            local prev = merged[#merged]
            if messages[i].role == prev.role then
                prev.content = prev.content .. "\n\n" .. messages[i].content
            else
                table.insert(merged, messages[i])
            end
        end
        body.messages = merged
    end

    -- Add reasoning_effort for reasoning models
    local model = body.model or ""
    if ModelConstraints.supportsCapability("perplexity", model, "reasoning") then
        if config.api_params and config.api_params.perplexity_reasoning then
            body.reasoning_effort = config.api_params.perplexity_reasoning.effort
        end
    end

    -- Web toggle (campaign T3, probed 2026-08-14): disable_search EXISTS and
    -- works (0 citations/search_results, knowledge-only answer; control run
    -- searched) — the old "always-on, not toggleable" assumption is dead on
    -- the wire. Explicit false (action pin, Web chip off, book/global via the
    -- bake) disables search; nil falls to the global, and an untouched global
    -- keeps Perplexity's NATIVE default (search on). The Web chip seeds ON
    -- for this provider (dialogs side) so out-of-box chats still search and
    -- the chip is truthful.
    local web_on
    if config.enable_web_search ~= nil then
        web_on = config.enable_web_search and true or false
    elseif config.features and config.features.enable_web_search ~= nil then
        web_on = config.features.enable_web_search and true or false
    else
        web_on = true -- provider native default
    end
    if not web_on then
        body.disable_search = true
    else
        -- Web search effort dial → search_context_size; standard sends nothing
        -- (API default), matching pre-dial behavior.
        local effort = ModelConstraints.webSearchEffort(config.features)
        if effort ~= "standard" then
            body.web_search_options = {
                search_context_size = effort == "light" and "low" or "high",
            }
        end
    end

    return body
end

return PerplexityHandler
