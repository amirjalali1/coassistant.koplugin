-- Unit tests for the custom-provider reasoning wire translation (audit quick
-- win): customizeRequestBody turns the neutral api_params.custom_reasoning
-- record into the user-declared wire. Every built-in provider's translation is
-- tested; custom is the highest-variance one and was the only one missing.

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

local CustomOpenAIHandler = require("koassistant_api/custom_openai")

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

local function customize(body, cr)
    return CustomOpenAIHandler:customizeRequestBody(body,
        { api_params = cr and { custom_reasoning = cr } or {} })
end

print("")
print(string.rep("=", 50))
print("  Unit Tests: Custom Provider Reasoning Wire")
print(string.rep("=", 50))

TestRunner:test("wire=effort ON writes reasoning_effort", function()
    local body = customize({ model = "some-model" },
        { wire = "effort", on = true, effort = "high" })
    TestRunner:eq(body.reasoning_effort, "high")
end)

TestRunner:test("wire=effort OFF with off_option writes the off value", function()
    local body = customize({ model = "some-model" },
        { wire = "effort", on = false, off_option = "none" })
    TestRunner:eq(body.reasoning_effort, "none")
end)

TestRunner:test("wire=effort OFF without off_option leaves the field untouched", function()
    local body = customize({ model = "some-model" },
        { wire = "effort", on = false })
    TestRunner:eq(body.reasoning_effort, nil)
end)

TestRunner:test("wire=enable_thinking writes a REAL boolean both ways", function()
    local on = customize({ model = "m" }, { wire = "enable_thinking", on = true })
    TestRunner:eq(on.chat_template_kwargs.enable_thinking, true)
    local off = customize({ model = "m" }, { wire = "enable_thinking", on = false })
    TestRunner:eq(off.chat_template_kwargs.enable_thinking, false, "off is boolean false, never nil")
end)

TestRunner:test("needs_temp_1 forces 1.0 only while reasoning is ON", function()
    local on = customize({ model = "m", temperature = 0.3 },
        { wire = "effort", on = true, effort = "low", needs_temp_1 = true })
    TestRunner:eq(on.temperature, 1.0, "forced while on")
    local off = customize({ model = "m", temperature = 0.3 },
        { wire = "effort", on = false, needs_temp_1 = true })
    TestRunner:eq(off.temperature, 0.3, "not forced while off")
end)

TestRunner:test("gpt-5-family rename: max_tokens becomes max_completion_tokens", function()
    local body = customize({ model = "gpt-5-anything", max_tokens = 100 }, nil)
    TestRunner:eq(body.max_completion_tokens, 100)
    TestRunner:eq(body.max_tokens, nil)
end)

print("")
print(string.rep("-", 50))
print(string.format("  Results: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
print(string.rep("-", 50))
return TestRunner.failed == 0
