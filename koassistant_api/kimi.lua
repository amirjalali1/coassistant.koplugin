--[[--
Kimi (Moonshot) API Handler

OpenAI-compatible handler with regional endpoint selection (Z.AI pattern).
Moonshot runs two SEPARATE platforms whose API keys are NOT interchangeable
(T9 refresh 2026-08-14): keys minted on one host 401 against the other.
  - China:         platform.moonshot.cn  -> api.moonshot.cn
  - International: platform.kimi.ai      -> api.moonshot.ai
Default stays "china" (the long-shipped endpoint our signup docs point at);
international users flip Settings > Advanced > Provider Settings > Kimi Region.

@module kimi
]]

local OpenAICompatibleHandler = require("koassistant_api.openai_compatible")

local KimiHandler = OpenAICompatibleHandler:new()

-- Regional endpoints for Kimi (keys are region-locked — see header)
local REGIONAL_ENDPOINTS = {
    china = "https://api.moonshot.cn/v1/chat/completions",
    international = "https://api.moonshot.ai/v1/chat/completions",
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
    local region = config.features and config.features.kimi_region or "china"
    return REGIONAL_ENDPOINTS[region] or REGIONAL_ENDPOINTS.china
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
