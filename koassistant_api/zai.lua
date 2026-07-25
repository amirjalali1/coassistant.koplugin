--[[--
Z.AI API Handler

OpenAI-compatible handler for Z.AI (Zhipu AI) GLM models.
GLM-4.5+ models support reasoning via `reasoning_content` response field
(like DeepSeek) and toggleable thinking via request parameter.

Chat completions endpoint: https://api.z.ai/api/paas/v4/chat/completions
Docs: https://docs.z.ai/api-reference/llm/chat-completion

@module zai
]]

local OpenAICompatibleHandler = require("koassistant_api.openai_compatible")
local ModelConstraints = require("model_constraints")

local ZaiHandler = OpenAICompatibleHandler:new()

-- Regional endpoints for Z.AI
-- Same API key works on both endpoints
local REGIONAL_ENDPOINTS = {
    international = "https://api.z.ai/api/paas/v4/chat/completions",
    china = "https://open.bigmodel.cn/api/paas/v4/chat/completions",
}

function ZaiHandler:getProviderName()
    return "Z.AI"
end

function ZaiHandler:getProviderKey()
    return "zai"
end

-- Use regional endpoint based on zai_region setting
function ZaiHandler:customizeUrl(url, config)
    if config.base_url then
        return config.base_url
    end
    local region = config.features and config.features.zai_region or "international"
    return REGIONAL_ENDPOINTS[region] or REGIONAL_ENDPOINTS.international
end

-- Add hint for auth errors about region setting
function ZaiHandler:enhanceErrorMessage(error_msg, config)
    local err_lower = error_msg:lower()
    if err_lower:find("401") or err_lower:find("auth") or err_lower:find("invalid") or err_lower:find("key") then
        return error_msg .. "\n\nHint: Check Settings → Advanced → Provider Settings → Z.AI Region."
    end
    return error_msg
end

function ZaiHandler:customizeRequestBody(body, config)
    local model = body.model or ""

    -- Thinking parameter (GLM-4.5+ models)
    -- Apply when explicitly set by dialogs (enabled or disabled).
    -- When nil: don't send anything — let API defaults apply
    -- (GLM-4.5+ thinks by default)
    if config.api_params and config.api_params.zai_thinking then
        body.thinking = config.api_params.zai_thinking

        -- Z.AI requires temperature=1.0 when thinking is enabled.
        -- Without this, the API returns an error if temp != 1.0.
        -- Only force when explicitly enabling; disabling doesn't constrain temp.
        if config.api_params.zai_thinking.type == "enabled" then
            body.temperature = 1.0
        end
    end

    -- Web search: the chat completions wire accepts a web_search tool; Z.AI runs
    -- the search server-side, injects results into the prompt, and echoes a
    -- web_search results array (link/title/content) in the response — on the
    -- final chunk when streaming. Verified live 2026-07-25 on glm-5.2 AND
    -- glm-4.7-flash (an older note here claimed only /api/paas/v4/tools worked;
    -- no longer true). search_result=true is what makes the results array come
    -- back — required for "Show Sources" provenance.
    -- Override-first read, same layering as openrouter.lua.
    local enable_web_search = false
    if config.enable_web_search ~= nil then
        enable_web_search = config.enable_web_search
    elseif config.features and config.features.enable_web_search then
        enable_web_search = true
    end
    if enable_web_search then
        -- Engine choice matters: the API default (search_std) is a Chinese-web
        -- index that returns SEO junk for international queries (field report
        -- 2026-07-25; all six engines probed — jina/bing return real sources,
        -- GitHub/Reddit vs translation-spam). Overridable for Chinese-language
        -- use via Settings → Advanced → Provider Settings (zai_search_engine).
        local engine = (config.features and config.features.zai_search_engine)
            or "search_pro_jina"
        local web_search = { enable = true, search_result = true, search_engine = engine }
        -- Effort dial: count IS honored (probed: count=3 → 3 sources; values
        -- above the 10 default clamp silently, so thorough can't raise the
        -- result count — it asks for fuller snippets instead).
        local effort = ModelConstraints.webSearchEffort(config.features)
        if effort == "light" then
            web_search.count = 3
        elseif effort == "thorough" then
            web_search.content_size = "high"
        end
        body.tools = body.tools or {}
        table.insert(body.tools, { type = "web_search", web_search = web_search })
    end

    return body
end

return ZaiHandler
