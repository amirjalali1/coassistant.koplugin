--[[--
Qwen (DashScope) API Handler

OpenAI-compatible handler with regional endpoint selection.
API keys are region-specific and NOT interchangeable.

@module qwen
]]

local OpenAICompatibleHandler = require("koassistant_api.openai_compatible")
local ModelConstraints = require("model_constraints")

local QwenHandler = OpenAICompatibleHandler:new()

-- Regional endpoints for Qwen/DashScope
-- API keys are region-specific and NOT interchangeable
local REGIONAL_ENDPOINTS = {
    international = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions",  -- Singapore
    china = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",               -- Beijing
    us = "https://dashscope-us.aliyuncs.com/compatible-mode/v1/chat/completions",               -- Virginia
}

function QwenHandler:getProviderName()
    return "Qwen"
end

function QwenHandler:getProviderKey()
    return "qwen"
end

-- Use regional endpoint based on qwen_region setting
function QwenHandler:customizeUrl(url, config)
    -- config.base_url override takes precedence
    if config.base_url then
        return config.base_url
    end
    -- Otherwise use regional endpoint
    local region = config.features and config.features.qwen_region or "international"
    return REGIONAL_ENDPOINTS[region] or REGIONAL_ENDPOINTS.international
end

-- Native web search via DashScope's enable_search (probed live 2026-08-15 on
-- qwen3-max international: forced_search injected ~5.3K tokens of results and
-- answered with current data; the no-search control refused. The
-- compatible-mode wire returns NO sources/citations even with
-- search_options.enable_source, so there is no provenance to harvest — the
-- answer is grounded but "Show Sources" stays empty by wire limitation).
-- Override-first read, same layering as zai.lua/openrouter.lua.
function QwenHandler:customizeRequestBody(request_body, config)
    local enable_web_search = false
    if config.enable_web_search ~= nil then
        enable_web_search = config.enable_web_search
    elseif config.features and config.features.enable_web_search then
        enable_web_search = true
    end
    if enable_web_search then
        request_body.enable_search = true
        -- Effort dial: only forced_search is probe-verified; thorough forces a
        -- search on every request, light/standard leave the search decision to
        -- the server (enable_search alone = model searches when it judges
        -- necessary).
        if ModelConstraints.webSearchEffort(config.features) == "thorough" then
            request_body.search_options = { forced_search = true }
        end
    end
    return request_body
end

-- Add hint for auth errors about region setting
function QwenHandler:enhanceErrorMessage(error_msg, config)
    local err_lower = error_msg:lower()
    if err_lower:find("401") or err_lower:find("auth") or err_lower:find("invalid") or err_lower:find("key") then
        return error_msg .. "\n\nHint: Qwen API keys are region-specific. Check Settings → Advanced → Provider Settings → Qwen Region."
    end
    return error_msg
end

return QwenHandler
