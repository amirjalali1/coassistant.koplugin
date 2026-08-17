-- Unit tests for Dialogs.quickPresetForces (release-blocking six-pack [1]):
-- THE quick-preset facet-off rule, previously hand-duplicated at ~12
-- dispatch/label/toast sites. Table-driven so the maintainer's governance
-- matrix reads as data.

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

local QPF = require("koassistant_dialogs").quickPresetForces

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

print("")
print(string.rep("=", 50))
print("  Unit Tests: Quick Preset Forces")
print(string.rep("=", 50))

-- The governance matrix as data: { facet, quick_on, features, action, expected }
local CASES = {
    { "web off: quick on, component default-on, untouched",
        "web", true, {}, nil, true },
    { "web survives: the touch mark is the pin",
        "web", true, { _session_web_touched = true }, nil, false },
    { "web survives: action explicitly forces web on (matrix rule)",
        "web", true, {}, { enable_web_search = true }, false },
    { "web off: an action that merely ALLOWS web (nil flag) is not exempt",
        "web", true, {}, { enable_web_search = nil }, true },
    { "web survives: preset component disabled",
        "web", true, { quick_preset_web_off = false }, nil, false },
    { "web survives: quick not on",
        "web", false, {}, nil, false },
    { "tools off: quick on, untouched",
        "tools", true, {}, nil, true },
    { "tools off: NO action exemption even when the action forces web on (deliberate asymmetry)",
        "tools", true, {}, { enable_web_search = true }, true },
    { "tools survives: the touch mark is the pin",
        "tools", true, { _session_tools_touched = true }, nil, false },
    { "tools survives: preset component disabled",
        "tools", true, { quick_preset_tools_off = false }, nil, false },
    { "unknown facet never forces",
        "reasoning", true, {}, nil, false },
    { "nil features never forces",
        "web", true, nil, nil, false },
}

for _idx, case in ipairs(CASES) do
    local name, facet, quick_on, features, action, expected =
        case[1], case[2], case[3], case[4], case[5], case[6]
    TestRunner:test(name, function()
        TestRunner:eq(QPF(facet, quick_on, features, action), expected)
    end)
end

print("")
print(string.rep("-", 50))
print(string.format("  Results: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
print(string.rep("-", 50))
return TestRunner.failed == 0
