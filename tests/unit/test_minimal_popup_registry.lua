--[[
Unit tests: Constants.resolveMinimalPopupActions — the Minimal Popup action registry.

Pins the read-through contract: nil saved list = defaults (so new default registrations
reach never-customized users automatically), a user-edited list is taken verbatim
INCLUDING empty (a deliberate "none" must never snap back to the defaults), and the
result is a set keyed by action id.

Run: lua tests/unit/test_minimal_popup_registry.lua  (auto-discovered by run_tests.lua --unit)
]]

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."

    package.path = table.concat({
        plugin_dir .. "/?.lua",
        plugin_dir .. "/?/init.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
end
setupPaths()

local TestRunner = require("test_runner"):new()
local Constants = require("koassistant_constants")

local function count(set)
    local n = 0
    for _k in pairs(set) do n = n + 1 end
    return n
end

TestRunner:test("nil saved list resolves to the defaults", function()
    local set = Constants.resolveMinimalPopupActions(nil)
    for _idx, id in ipairs(Constants.DEFAULT_MINIMAL_POPUP_ACTIONS) do
        TestRunner:assertTrue(set[id] == true, id .. " registered by default")
    end
    TestRunner:assertEqual(count(set), #Constants.DEFAULT_MINIMAL_POPUP_ACTIONS,
        "nothing beyond the defaults")
end)

TestRunner:test("defaults include translate and quick_define", function()
    local set = Constants.resolveMinimalPopupActions(nil)
    TestRunner:assertTrue(set["translate"] == true, "translate is a default")
    TestRunner:assertTrue(set["quick_define"] == true, "quick_define is a default")
end)

TestRunner:test("edited list is verbatim — defaults do not bleed back in", function()
    local set = Constants.resolveMinimalPopupActions({ "my_custom_action" })
    TestRunner:assertTrue(set["my_custom_action"] == true, "user entry kept")
    TestRunner:assertTrue(set["translate"] == nil, "removed default stays removed")
    TestRunner:assertEqual(count(set), 1, "exactly the saved entries")
end)

TestRunner:test("empty edited list means none (never snaps back to defaults)", function()
    local set = Constants.resolveMinimalPopupActions({})
    TestRunner:assertEqual(count(set), 0, "deliberate empty list respected")
end)

TestRunner:test("non-table garbage falls back to defaults", function()
    local set = Constants.resolveMinimalPopupActions("translate")
    TestRunner:assertTrue(set["translate"] == true and set["quick_define"] == true,
        "string value treated as never-customized")
end)

local ok = TestRunner:summary()
return ok
