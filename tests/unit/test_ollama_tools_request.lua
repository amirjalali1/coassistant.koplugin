-- Unit tests for Ollama book-tool request construction + tool-call parsing.
-- Wire contract probed live on Ollama 0.17.7 (2026-08-14): OpenAI-shaped
-- declarations and replay; call `arguments` arrive as a DECODED OBJECT;
-- tool_choice is silently IGNORED (so mode NONE omits declarations entirely
-- instead — replay without declarations is accepted, and nothing declared
-- means no stray calls in the final pass).

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

local OllamaHandler = require("koassistant_api.ollama")
local ResponseParser = require("koassistant_api.response_parser")
local ToolWire = require("koassistant_api.tool_wire")
local TestRunner = require("test_runner"):new()

print("")
print(string.rep("=", 50))
print("  Unit Tests: Ollama Tool Requests")
print(string.rep("=", 50))

local SPECS = {
    {
        name = "search_book",
        description = "Search book text.",
        parameters = {
            type = "object",
            properties = { query = { type = "string" } },
            required = { "query" },
        },
    },
}

-- Ollama-native tool history: object-form arguments on the echoed call turn.
local TOOL_HISTORY = {
    { role = "user", content = "Where is Daisy first mentioned?" },
    { role = "assistant", content = "", tool_calls = {
        { id = "call_x1", ["function"] = { index = 0, name = "search_book",
            arguments = { query = "Daisy" } } },
    } },
    { role = "tool", tool_call_id = "call_x1", content = "{\"ok\":true,\"total_hits\":2}" },
}

TestRunner:test("declarations: OpenAI shape + tool_choice required on mode ANY", function()
    local result = OllamaHandler:buildRequestBody({
        { role = "user", content = "hi" },
    }, { tools = { specs = SPECS, mode = "ANY" } })
    local body = result.body
    TestRunner:assertEqual(body.tools[1].type, "function", "tool type")
    TestRunner:assertEqual(body.tools[1]["function"].name, "search_book", "function name")
    TestRunner:assertEqual(body.tool_choice, "required",
        "ANY sends required (ignored on 0.17.7, forward-compat)")
end)

TestRunner:test("mode NONE omits declarations AND tool_choice (probed stray-call guard)", function()
    local result = OllamaHandler:buildRequestBody(TOOL_HISTORY,
        { tools = { specs = SPECS, mode = "NONE" } })
    TestRunner:assertTrue(result.body.tools == nil,
        "no declarations on the final pass — tool_choice none is ignored by Ollama, "
        .. "omitting declarations is the structural guard")
    TestRunner:assertTrue(result.body.tool_choice == nil, "no tool_choice either")
end)

TestRunner:test("message loop preserves tool turns (echo with empty content + tool result)", function()
    local result = OllamaHandler:buildRequestBody(TOOL_HISTORY,
        { tools = { specs = SPECS, mode = "AUTO" } })
    local msgs = result.body.messages
    TestRunner:assertEqual(#msgs, 3, "user + assistant tool-call echo + tool result")
    TestRunner:assertEqual(msgs[2].role, "assistant", "echo kept")
    TestRunner:assertTrue(msgs[2].tool_calls ~= nil, "tool_calls kept despite empty content")
    TestRunner:assertEqual(msgs[3].role, "tool", "tool role NOT coerced to user")
    TestRunner:assertEqual(msgs[3].tool_call_id, "call_x1", "tool_call_id kept")
end)

TestRunner:test("no tools in config -> no tools/tool_choice, plain turns unchanged", function()
    local result = OllamaHandler:buildRequestBody({
        { role = "user", content = "hi" },
        { role = "assistant", content = "hello" },
    }, {})
    TestRunner:assertTrue(result.body.tools == nil, "no tools array")
    TestRunner:assertTrue(result.body.tool_choice == nil, "no tool_choice")
    TestRunner:assertEqual(#result.body.messages, 2, "plain history intact")
end)

TestRunner:test("parser: tool_calls emit the neutral shape with object args", function()
    local ok, result = ResponseParser:parseResponse({
        message = {
            role = "assistant",
            content = "",
            tool_calls = {
                { id = "call_a", ["function"] = { index = 0, name = "search_book",
                    arguments = { query = "Daisy" } } },
                -- malformed entry (luajson null sentinel class) must be skipped
                { ["function"] = "garbage" },
            },
        },
        done = true,
    }, "ollama")
    TestRunner:assertTrue(ok, "parse ok")
    TestRunner:assertTrue(type(result) == "table" and result._tool_calls == true, "neutral shape")
    TestRunner:assertEqual(#result.calls, 1, "malformed entry filtered")
    TestRunner:assertEqual(result.calls[1].id, "call_a", "id kept")
    TestRunner:assertEqual(result.calls[1].name, "search_book", "name")
    TestRunner:assertEqual(result.calls[1].args.query, "Daisy",
        "object arguments used directly (no JSON-string decode)")
    TestRunner:assertTrue(result.raw_assistant_turn ~= nil, "raw turn carried for the echo")
end)

TestRunner:test("parser: plain content path unaffected (think tags still extracted)", function()
    local ok, content, reasoning = ResponseParser:parseResponse({
        message = { role = "assistant", content = "<think>hmm</think>Answer." },
        done = true,
    }, "ollama")
    TestRunner:assertTrue(ok, "parse ok")
    TestRunner:assertEqual(content, "Answer.", "content clean")
    TestRunner:assertEqual(reasoning, "hmm", "think tag extracted")
end)

TestRunner:test("ToolWire: ollama adapter registered (openai alias)", function()
    TestRunner:assertTrue(ToolWire.hasAdapter("ollama"), "adapter present")
    -- Round-trip: append a completed turn and rebuild — the handler must accept
    -- the adapter's output shape (this is the exact replay the runner performs).
    local messages = { { role = "user", content = "q" } }
    ToolWire.appendToolTurn("ollama", messages,
        { role = "assistant", content = "", tool_calls = TOOL_HISTORY[2].tool_calls },
        { { call = { id = "call_x1", name = "search_book", args = { query = "Daisy" } },
            result = { ok = true } } })
    TestRunner:assertEqual(#messages, 3, "echo + tool result appended")
    local rebuilt = OllamaHandler:buildRequestBody(messages,
        { tools = { specs = SPECS, mode = "AUTO" } })
    TestRunner:assertEqual(#rebuilt.body.messages, 3, "replayed turns survive the copy loop")
    TestRunner:assertEqual(rebuilt.body.messages[3].tool_call_id, "call_x1", "result keyed")
end)

return TestRunner:summary()
