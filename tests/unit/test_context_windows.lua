-- Unit tests for ModelConstraints.checkContextWindow (model-aware extraction
-- pre-check, model_tooling_plan.md queue item 2). Pure, no API calls.
--
-- Run: lua tests/run_tests.lua --unit  (or directly from the repo root)

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({
        plugin_dir .. "/?.lua",
        plugin_dir .. "/koassistant_api/?.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
end
setupPaths()

require("mock_koreader")
local ModelConstraints = require("model_constraints")

local TestRunner = { passed = 0, failed = 0 }
function TestRunner:check(name, condition)
    if condition then
        self.passed = self.passed + 1
        print("  PASS: " .. name)
    else
        self.failed = self.failed + 1
        print("  FAIL: " .. name)
    end
end

print("== checkContextWindow: fail-open contract ==")

TestRunner:check("unknown provider -> nil (no claim)",
    ModelConstraints.checkContextWindow("groq", "llama-3.3-70b-versatile", 10000000) == nil)
TestRunner:check("unknown model in known provider -> nil (no matching prefix)",
    ModelConstraints.checkContextWindow("xai", "totally-new-9", 10000000) == nil)
TestRunner:check("nil chars -> nil",
    ModelConstraints.checkContextWindow("gemini", "gemini-3.6-flash", nil) == nil)
TestRunner:check("zero chars -> nil",
    ModelConstraints.checkContextWindow("gemini", "gemini-3.6-flash", 0) == nil)

print("== checkContextWindow: verdicts ==")

-- grok-build: 256000-token window; threshold = 0.9 * 256000 = 230400 tokens;
-- est = chars/4.
local ex_small = ModelConstraints.checkContextWindow("xai", "grok-build-0.1", 800000)
TestRunner:check("under the window -> exceeded false (800K chars ~ 200K tokens vs 256K window)",
    ex_small == false)
local ex_big, win_big, est_big =
    ModelConstraints.checkContextWindow("xai", "grok-build-0.1", 1000000)
TestRunner:check("over the window -> exceeded true (1M chars ~ 250K tokens vs 256K window)",
    ex_big == true)
TestRunner:check("window and estimate returned for the message",
    win_big == 256000 and est_big == 250000)

print("== checkContextWindow: prefix matching ==")

local _ex1, win1 = ModelConstraints.checkContextWindow("anthropic", "claude-sonnet-5", 400000)
TestRunner:check("family prefix matches (claude-sonnet-5 -> claude 200K)", win1 == 200000)
local _ex2, win2 = ModelConstraints.checkContextWindow("xai", "grok-4.6", 400000)
TestRunner:check("exact id wins (grok-4.6 -> 500K)", win2 == 500000)
TestRunner:check("escaped dot: gemini-2x5-x must NOT match the gemini-2.5 prefix",
    ModelConstraints.checkContextWindow("gemini", "gemini-2x5-flash", 10000000) == nil)
local ex3 = ModelConstraints.checkContextWindow("gemini", "gemini-3.6-flash", 400000)
TestRunner:check("1M-window model: 400K chars is comfortably under", ex3 == false)

print(string.format("\n%d passed, %d failed", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
