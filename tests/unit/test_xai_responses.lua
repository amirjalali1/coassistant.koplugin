-- Unit tests for the xAI Responses API path (responses_api_plan.md R4):
-- routing decision + request builder in koassistant_api/xai.lua. The response
-- side (openai_responses transformer, response.* stream events, usage) is
-- shared with OpenAI and covered by test_openai_responses.lua.
-- No API calls — mock data only.

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."

    package.path = table.concat({
        plugin_dir .. "/?.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
end

setupPaths()
require("mock_koreader")

local XAIHandler = require("koassistant_api.xai")
local ModelConstraints = require("model_constraints")
local TestRunner = require("test_runner"):new()

print("")
print(string.rep("=", 50))
print("  Unit Tests: xAI Responses API")
print(string.rep("=", 50))

local HISTORY = {
    { role = "user", content = "What's new with capybaras?" },
}

local function webConfig(overrides)
    local config = {
        model = "grok-4.5",
        api_key = "test",
        system = { text = "You are helpful." },
        features = { enable_web_search = true },
    }
    for k, v in pairs(overrides or {}) do config[k] = v end
    return config
end

--------------------------------------------------------------------------------
print("\n  [Routing: when the Responses endpoint is used]")
--------------------------------------------------------------------------------

TestRunner:test("web search on + capable model routes to /responses", function()
    local result = XAIHandler:buildRequestBody(HISTORY, webConfig())
    TestRunner:assertEqual(result.parser, "openai_responses", "parser key set")
    TestRunner:assertTrue(result.url:find("/responses", 1, true) ~= nil, "URL is the responses endpoint")
    TestRunner:assertTrue(result.url:find("/chat/completions", 1, true) == nil, "chat completions gone from URL")
    TestRunner:assertTrue(result.body.input ~= nil, "body uses input items")
    TestRunner:assertTrue(result.body.messages == nil, "body has no messages array")
end)

TestRunner:test("grok-4.3 and grok-4.20 slugs are capable (prefix match)", function()
    for _idx, model in ipairs({
        "grok-4.3", "grok-4.20-0309-reasoning", "grok-4.20-0309-non-reasoning",
    }) do
        local result = XAIHandler:buildRequestBody(HISTORY, webConfig({ model = model }))
        TestRunner:assertEqual(result.parser, "openai_responses", model .. " routes to Responses")
    end
end)

TestRunner:test("non-capable model stays on Chat Completions", function()
    local result = XAIHandler:buildRequestBody(HISTORY, webConfig({ model = "grok-build-0.1" }))
    TestRunner:assertTrue(result.parser == nil, "no parser override")
    TestRunner:assertTrue(result.body.messages ~= nil, "chat body")
    TestRunner:assertTrue(result.body.tools == nil, "no web tool on the chat wire")
end)

TestRunner:test("web search off stays on Chat Completions", function()
    local result = XAIHandler:buildRequestBody(HISTORY, webConfig({
        features = { enable_web_search = false },
    }))
    TestRunner:assertTrue(result.parser == nil, "no parser override")
    TestRunner:assertTrue(result.body.messages ~= nil, "chat body")
end)

TestRunner:test("per-action force-off beats global on (Web layering)", function()
    local config = webConfig()
    config.enable_web_search = false
    local result = XAIHandler:buildRequestBody(HISTORY, config)
    TestRunner:assertTrue(result.body.messages ~= nil, "chat body when action pins web off")
end)

TestRunner:test("per-action force-on works without the global", function()
    local config = webConfig({ features = {} })
    config.enable_web_search = true
    local result = XAIHandler:buildRequestBody(HISTORY, config)
    TestRunner:assertEqual(result.parser, "openai_responses", "action-level web-on routes")
end)

TestRunner:test("book-tool sessions ride Responses on capable models (T3 P9)", function()
    local config = webConfig({ features = {} }) -- web OFF: tools alone must route
    config.tools = {
        mode = "AUTO",
        specs = { { name = "toc", description = "d", parameters = { type = "object" } } },
    }
    local result = XAIHandler:buildRequestBody(HISTORY, config)
    TestRunner:assertEqual(result.parser, "openai_responses", "tool session routes to Responses")
    TestRunner:assertEqual(result.body.tools[1].type, "function", "FLAT function def (no nested wrapper)")
    TestRunner:assertEqual(result.body.tools[1].name, "toc", "tool name at top level")
    TestRunner:assertEqual(result.body.tool_choice, "auto", "AUTO mode maps to auto")
    TestRunner:assertEqual(result.body.include[1], "reasoning.encrypted_content",
        "encrypted reasoning requested for stateless replay")
    local has_web = false
    for _idx, t in ipairs(result.body.tools) do
        if t.type == "web_search" then has_web = true end
    end
    TestRunner:assertTrue(not has_web, "no web_search tool when web is off")
end)

TestRunner:test("tool modes map to tool_choice; web-on adds web_search beside tools", function()
    local config = webConfig() -- web ON via features
    config.tools = {
        mode = "ANY",
        specs = { { name = "search_book", description = "d", parameters = { type = "object" } } },
    }
    local result = XAIHandler:buildRequestBody(HISTORY, config)
    TestRunner:assertEqual(result.body.tool_choice, "required", "ANY maps to required")
    TestRunner:assertEqual(result.body.tools[1].type, "web_search", "web_search coexists with book tools")
    TestRunner:assertEqual(result.body.tools[2].type, "function", "book tool after web_search")
    config.tools.mode = "NONE"
    result = XAIHandler:buildRequestBody(HISTORY, config)
    TestRunner:assertEqual(result.body.tool_choice, "none", "NONE maps to none")
end)

TestRunner:test("tool sessions on non-Responses models keep the chat wire end-to-end", function()
    local config = webConfig({ model = "grok-2-vision", features = {} })
    config.tools = {
        mode = "AUTO",
        specs = { { name = "toc", description = "d", parameters = { type = "object" } } },
    }
    local result = XAIHandler:buildRequestBody(HISTORY, config)
    TestRunner:assertTrue(result.parser == nil, "non-capable model stays on chat wire")
    TestRunner:assertTrue(result.body.messages ~= nil, "chat body")
    TestRunner:assertTrue(result.body.tools[1]["function"] ~= nil, "nested function wrapper (chat shape)")
end)

TestRunner:test("_responses_items tool turns replay verbatim into input", function()
    local config = webConfig({ features = {} })
    config.tools = {
        mode = "NONE",
        specs = { { name = "toc", description = "d", parameters = { type = "object" } } },
    }
    local history = {
        { role = "user", content = "Q" },
        { _responses_items = {
            { type = "reasoning", encrypted_content = "blob" },
            { type = "function_call", call_id = "c1", name = "toc", arguments = "{}" },
            { type = "function_call_output", call_id = "c1", output = "chapters" },
        } },
    }
    local result = XAIHandler:buildRequestBody(history, config)
    TestRunner:assertEqual(#result.body.input, 4, "1 user + 3 replayed items")
    TestRunner:assertEqual(result.body.input[2].type, "reasoning", "reasoning item precedes its call")
    TestRunner:assertEqual(result.body.input[4].type, "function_call_output", "our output item last")
end)

--------------------------------------------------------------------------------
print("\n  [Request body shape]")
--------------------------------------------------------------------------------

TestRunner:test("system prompt rides instructions; history becomes input items", function()
    local history = {
        { role = "system", content = "ignored" },
        { role = "user", content = "Q1" },
        { role = "assistant", content = "A1" },
        { role = "user", content = "Q2" },
    }
    local result = XAIHandler:buildRequestBody(history, webConfig())
    TestRunner:assertEqual(result.body.instructions, "You are helpful.", "instructions from config.system")
    TestRunner:assertEqual(#result.body.input, 3, "system filtered from input")
    TestRunner:assertEqual(result.body.input[2].role, "assistant", "assistant role preserved")
end)

TestRunner:test("stateless: store=false always sent", function()
    local result = XAIHandler:buildRequestBody(HISTORY, webConfig())
    TestRunner:assertEqual(result.body.store, false, "store=false")
end)

TestRunner:test("temperature is kept (xAI delta from gpt-5.x)", function()
    local result = XAIHandler:buildRequestBody(HISTORY, webConfig())
    TestRunner:assertEqual(result.body.temperature, 0.7, "default temperature")
    result = XAIHandler:buildRequestBody(HISTORY, webConfig({
        api_params = { temperature = 1.2 },
    }))
    TestRunner:assertEqual(result.body.temperature, 1.2, "api_params temperature wins")
end)

TestRunner:test("max_output_tokens replaces max_tokens", function()
    local result = XAIHandler:buildRequestBody(HISTORY, webConfig({
        api_params = { max_tokens = 4096 },
    }))
    TestRunner:assertEqual(result.body.max_output_tokens, 4096, "max_output_tokens from action")
    TestRunner:assertTrue(result.body.max_tokens == nil, "no max_tokens key")
end)

TestRunner:test("known-ceiling models get the 32K default (raise-where-known)", function()
    -- Item 27: the default is ceiling-based (resolveMaxTokens), not
    -- reasoning-gated — the whole grok-4 family has a known >=32K ceiling.
    local result = XAIHandler:buildRequestBody(HISTORY, webConfig())
    TestRunner:assertEqual(result.body.max_output_tokens, 32768, "grok-4.5 resolves to the 32K target")
    result = XAIHandler:buildRequestBody(HISTORY, webConfig({ model = "grok-4.20-0309-non-reasoning" }))
    TestRunner:assertEqual(result.body.max_output_tokens, 32768, "same family, same known ceiling")
    -- grok-build isn't Responses-capable → chat wire → plain max_tokens field
    result = XAIHandler:buildRequestBody(HISTORY, webConfig({ model = "grok-build-0.1" }))
    TestRunner:assertEqual(result.body.max_tokens, 16384, "unknown-ceiling model keeps the provider default")
end)

TestRunner:test("web_search tool is bare (no context-size dial on xAI)", function()
    local result = XAIHandler:buildRequestBody(HISTORY, webConfig({
        features = { enable_web_search = true, web_search_effort = "thorough" },
    }))
    TestRunner:assertEqual(#result.body.tools, 1, "one tool")
    TestRunner:assertEqual(result.body.tools[1].type, "web_search", "web_search type")
    TestRunner:assertTrue(result.body.tools[1].search_context_size == nil, "no OpenAI-only dial param")
end)

TestRunner:test("routing marker is a {to, reason} table (logAdjustments contract)", function()
    local result = XAIHandler:buildRequestBody(HISTORY, webConfig())
    local marker = result.adjustments and result.adjustments.responses_api
    TestRunner:assertTrue(type(marker) == "table", "marker is a table, never a bare boolean")
    TestRunner:assertTrue(marker.reason ~= nil, "marker carries a reason")
end)

--------------------------------------------------------------------------------
print("\n  [Reasoning mapping]")
--------------------------------------------------------------------------------

TestRunner:test("resolver effort rides nested reasoning.effort", function()
    local result = XAIHandler:buildRequestBody(HISTORY, webConfig({
        api_params = { xai_reasoning = { effort = "high" } },
    }))
    TestRunner:assertEqual(result.body.reasoning.effort, "high", "nested effort")
    TestRunner:assertTrue(result.body.reasoning_effort == nil, "no flat chat-wire param")
end)

TestRunner:test("explicit off sends effort none", function()
    local result = XAIHandler:buildRequestBody(HISTORY, webConfig({
        api_params = { xai_reasoning = { effort = "none" } },
    }))
    TestRunner:assertEqual(result.body.reasoning.effort, "none", "off_option passes through")
end)

TestRunner:test("send_nothing emits no reasoning params", function()
    local result = XAIHandler:buildRequestBody(HISTORY, webConfig())
    TestRunner:assertTrue(result.body.reasoning == nil, "no reasoning object")
    TestRunner:assertTrue(result.body.reasoning_effort == nil, "no flat param")
end)

TestRunner:test("non-reasoning model skips effort with an adjustment note", function()
    local result = XAIHandler:buildRequestBody(HISTORY, webConfig({
        model = "grok-4.20-0309-non-reasoning",
        api_params = { xai_reasoning = { effort = "high" } },
    }))
    TestRunner:assertTrue(result.body.reasoning == nil, "no reasoning object")
    TestRunner:assertTrue(result.adjustments.reasoning_skipped ~= nil, "skip recorded")
end)

TestRunner:test("chat wire still uses flat reasoning_effort", function()
    local result = XAIHandler:buildRequestBody(HISTORY, webConfig({
        features = { enable_web_search = false },
        api_params = { xai_reasoning = { effort = "low" } },
    }))
    TestRunner:assertEqual(result.body.reasoning_effort, "low", "chat-wire param unchanged")
    TestRunner:assertTrue(result.body.reasoning == nil, "no nested object on chat wire")
end)

--------------------------------------------------------------------------------
print("\n  [Capability / UI gating]")
--------------------------------------------------------------------------------

TestRunner:test("supportsWebSearch honors the xai capability list", function()
    TestRunner:assertTrue(ModelConstraints.supportsWebSearch("xai", "grok-4.5"), "grok-4.5 supported")
    TestRunner:assertTrue(ModelConstraints.supportsWebSearch("xai", "grok-4.20-0309-non-reasoning"),
        "grok-4.20 slugs supported")
    TestRunner:assertFalse(ModelConstraints.supportsWebSearch("xai", "grok-build-0.1"),
        "non-capable model gated out")
end)

TestRunner:test("providers label includes xAI", function()
    local label = ModelConstraints.getWebSearchProvidersLabel()
    TestRunner:assertTrue(label:find("xAI", 1, true) ~= nil, "xAI in the derived label")
end)

return TestRunner:summary()
