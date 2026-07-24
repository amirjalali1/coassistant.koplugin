--[[--
Requesty API Handler

OpenAI-compatible handler for Requesty (https://requesty.ai), a model router
that exposes an OpenAI-style Chat Completions endpoint at
https://router.requesty.ai/v1/chat/completions and uses provider/model naming
(e.g. "openai/gpt-4o-mini"), like OpenRouter.

Like OpenRouter, Requesty accepts optional HTTP-Referer and X-Title headers for
attribution, and a unified `reasoning` object that it forwards to the backend
model.

@module requesty
]]

local OpenAICompatibleHandler = require("koassistant_api.openai_compatible")
local Constants = require("koassistant_constants")

local RequestyHandler = OpenAICompatibleHandler:new()

function RequestyHandler:getProviderName()
    return "Requesty"
end

function RequestyHandler:getProviderKey()
    return "requesty"
end

-- Requesty accepts optional HTTP-Referer and X-Title headers for attribution
function RequestyHandler:customizeHeaders(headers, config)
    headers["HTTP-Referer"] = Constants.GITHUB.URL
    headers["X-Title"] = "KOAssistant"
    return headers
end

function RequestyHandler:customizeRequestBody(body, config)
    -- Add reasoning object (Requesty forwards it to the backend provider).
    -- enabled=false disables reasoning on disable-capable backends; effort sets the level.
    local rq_reasoning = config.api_params and config.api_params.requesty_reasoning
    if rq_reasoning then
        if rq_reasoning.enabled == false then
            body.reasoning = { enabled = false }
        elseif rq_reasoning.effort then
            body.reasoning = { effort = rq_reasoning.effort }
        end
    end

    return body
end

return RequestyHandler
