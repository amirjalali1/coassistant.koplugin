--[[--
Kimi (Moonshot) API Handler

OpenAI-compatible handler with regional endpoint selection (Z.AI pattern).
Moonshot runs two SEPARATE platforms whose API keys are NOT interchangeable
(T9 refresh 2026-08-14): keys minted on one host 401 against the other.
  - International: platform.kimi.ai      -> api.moonshot.ai  (default)
  - China:         platform.moonshot.cn  -> api.moonshot.cn
Fresh installs default to "international"; a one-time initSettings migration
(_kimi_region_migrated) stamps kimi_region="china" for installs that already
held a kimi key — those keyed against the China platform our docs pointed at.

@module kimi
]]

local OpenAICompatibleHandler = require("koassistant_api.openai_compatible")

local KimiHandler = OpenAICompatibleHandler:new()

-- Regional endpoints for Kimi (keys are region-locked — see header)
local REGIONAL_ENDPOINTS = {
    international = "https://api.moonshot.ai/v1/chat/completions",
    china = "https://api.moonshot.cn/v1/chat/completions",
}

function KimiHandler:getProviderName()
    return "Kimi"
end

function KimiHandler:getProviderKey()
    return "kimi"
end

-- Use regional endpoint based on kimi_region setting
function KimiHandler:customizeUrl(url, config)
    if config.base_url then
        return config.base_url
    end
    local region = config.features and config.features.kimi_region or "international"
    return REGIONAL_ENDPOINTS[region] or REGIONAL_ENDPOINTS.international
end

-- kimi-k2.6 wire quirks (all probed live 2026-08-15 on the international platform):
--   * Thinks by DEFAULT; disable = anthropic-shaped thinking = {type="disabled"}
--     (reasoning tokens 311 -> 1). The resolver emits the neutral
--     api_params.kimi_thinking only on an explicit OFF decision.
--   * tool_choice "required" (the runner's gather mode) is "incompatible with
--     thinking enabled" -- tool sessions force the disable (deepseek precedent;
--     phase 2 of gather mode carries no config.tools, so the streamed answer
--     keeps the model's default thinking).
--   * Temperature is MODE-LOCKED: thinking on accepts ONLY 1 (forced in
--     model_constraints), thinking off accepts ONLY 0.6, omitting works in
--     both -- so whenever thinking is disabled here, temperature is dropped.
function KimiHandler:customizeRequestBody(request_body, config)
    local api_params = config.api_params or {}
    if type(api_params.kimi_thinking) == "table" then
        request_body.thinking = api_params.kimi_thinking
    end
    if config.tools and config.tools.specs then
        request_body.thinking = { type = "disabled" }
    end
    if request_body.thinking and request_body.thinking.type == "disabled" then
        request_body.temperature = nil
    end
    return request_body
end

-- Add hint for auth errors about region setting (keys are region-locked)
function KimiHandler:enhanceErrorMessage(error_msg, config)
    local err_lower = error_msg:lower()
    if err_lower:find("401") or err_lower:find("auth") or err_lower:find("invalid") or err_lower:find("key") then
        return error_msg .. "\n\nHint: Kimi API keys only work on the platform that issued them. Check Settings → Advanced → Provider Settings → Kimi Region."
    end
    return error_msg
end

return KimiHandler
