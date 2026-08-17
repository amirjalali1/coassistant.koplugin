-- Unit tests for ollama's per-request num_ctx sizing (audit quick win).
-- Guards a device-confirmed silent-truncation bug: ollama allocates the
-- context PER REQUEST (default 4096) and silently truncates longer prompts.

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({
        plugin_dir .. "/?.lua", tests_dir .. "/?.lua", tests_dir .. "/lib/?.lua", package.path,
    }, ";")
end
setupPaths()
require("mock_koreader")

local OllamaHandler = require("koassistant_api/ollama")

local TestRunner = { passed = 0, failed = 0 }
function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then self.passed = self.passed + 1; print("    ✓ " .. name)
    else self.failed = self.failed + 1; print("    ✗ " .. name); print("      Error: " .. tostring(err)) end
end
function TestRunner:eq(a, b, msg)
    if a ~= b then error(string.format("%s: expected %s, got %s",
        msg or "eq", tostring(b), tostring(a)), 2) end
end

local function build(messages, config)
    config = config or {}
    config.model = config.model or "llama3.2"
    return OllamaHandler:buildRequestBody(messages, config)
end

print("")
print(string.rep("=", 50))
print("  Unit Tests: Ollama num_ctx Sizing")
print(string.rep("=", 50))

TestRunner:test("tiny prompt sits on the 8192 floor", function()
    local r = build({ { role = "user", content = "hello" } })
    TestRunner:eq(r.body.options.num_ctx, 8192, "floor bucket")
end)

TestRunner:test("a ~60K-char prompt lands in the 32768 bucket", function()
    -- needed = ceil(60000/3) + 4096 = 24096 -> next power-of-two bucket 32768
    local r = build({ { role = "user", content = string.rep("a", 60000) } })
    TestRunner:eq(r.body.options.num_ctx, 32768, "power-of-two bucket above needed")
end)

TestRunner:test("oversized prompt clamps at the 65536 ceiling (residual truncation is deliberate)", function()
    local r = build({ { role = "user", content = string.rep("a", 300000) } })
    TestRunner:eq(r.body.options.num_ctx, 65536, "documented ceiling, not accidental")
end)

TestRunner:test("explicit api_params.num_ctx wins untouched", function()
    local r = build({ { role = "user", content = string.rep("a", 60000) } },
        { api_params = { num_ctx = 4096 } })
    TestRunner:eq(r.body.options.num_ctx, 4096, "user override passes through")
end)

TestRunner:test("system text counts toward the bucket", function()
    -- 30000 sys + 30000 user = 60000 chars -> 32768 like the single-message case
    local r = OllamaHandler:buildRequestBody(
        { { role = "user", content = string.rep("b", 30000) } },
        { model = "llama3.2", system = { text = string.rep("s", 30000) } })
    TestRunner:eq(r.body.options.num_ctx, 32768, "system message is part of the prompt")
end)

print("")
print(string.rep("-", 50))
print(string.format("  Results: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
print(string.rep("-", 50))
return TestRunner.failed == 0
