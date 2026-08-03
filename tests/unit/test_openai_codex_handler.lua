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

local Handler = require("koassistant_api.openai_codex")
local TestRunner = require("test_runner"):new()

print("")
print(string.rep("=", 50))
print("  Unit Tests: OpenAI Codex Handler")
print(string.rep("=", 50))

local SPECS = {
    {
        name = "search_book",
        description = "Search book text.",
        parameters = { type = "object", properties = { query = { type = "string" } } },
    },
}

local function config(overrides)
    local c = {
        model = "gpt-5.6-terra",
        api_key = "access_token_123",
        system = { text = "You are helpful." },
        oauth = { chatgpt_account_id = "acct_123" },
        features = { enable_streaming = false },
    }
    for k, v in pairs(overrides or {}) do c[k] = v end
    return c
end

TestRunner:test("buildRequestBody targets ChatGPT codex responses endpoint", function()
    local result = Handler:buildRequestBody({ { role = "user", content = "hello" } }, config())
    TestRunner:assertEqual(result.url, "https://chatgpt.com/backend-api/codex/responses", "codex URL")
    TestRunner:assertEqual(result.provider, "openai_codex", "provider id")
    TestRunner:assertEqual(result.parser, "openai_responses", "responses parser")
    TestRunner:assertEqual(result.body.store, false, "stateless request")
    TestRunner:assertEqual(result.body.max_output_tokens, nil, "Codex backend rejects public max_output_tokens")
    TestRunner:assertEqual(result.body.instructions, "You are helpful.", "instructions carried")
end)

TestRunner:test("buildRequestBody uses codex auth headers and account id", function()
    local result = Handler:buildRequestBody({ { role = "user", content = "hello" } }, config())
    TestRunner:assertEqual(result.headers["Authorization"], "Bearer access_token_123", "bearer token")
    TestRunner:assertEqual(result.headers["ChatGPT-Account-ID"], "acct_123", "account header")
    TestRunner:assertEqual(result.headers["User-Agent"], "codex_cli_rs/0.0.0 (KOAssistant)", "user agent")
    TestRunner:assertEqual(result.headers["originator"], "codex_cli_rs", "originator header")
end)

TestRunner:test("buildRequestBody keeps responses tools wire and include for tool turns", function()
    local result = Handler:buildRequestBody({ { role = "user", content = "hello" } }, config({
        tools = { specs = SPECS, mode = "ANY" },
    }))
    TestRunner:assertEqual(result.body.tools[1].type, "function", "flat function tool")
    TestRunner:assertEqual(result.body.tools[1].name, "search_book", "tool name")
    TestRunner:assertEqual(result.body.tool_choice, "required", "ANY => required")
    TestRunner:assertTrue(result.body.include ~= nil, "reasoning include for stateless replay")
end)

TestRunner:test("query preserves built custom headers on the background request", function()
    local captured
    local original = Handler.backgroundRequest
    Handler.backgroundRequest = function(self, url, headers, body)
        captured = { url = url, headers = headers, body = body }
        return function() end
    end

    local result = Handler:query({ { role = "user", content = "hello" } }, config())
    Handler.backgroundRequest = original

    TestRunner:assertTrue(type(result) == "table" and result._background_fn ~= nil, "non-streaming background request returned")
    TestRunner:assertEqual(captured.url, "https://chatgpt.com/backend-api/codex/responses", "request url")
    TestRunner:assertEqual(captured.headers["ChatGPT-Account-ID"], "acct_123", "account header forwarded")
    TestRunner:assertEqual(captured.headers["User-Agent"], "codex_cli_rs/0.0.0 (KOAssistant)", "user agent forwarded")
    TestRunner:assertEqual(captured.headers["originator"], "codex_cli_rs", "originator forwarded")
end)

return TestRunner:summary()
