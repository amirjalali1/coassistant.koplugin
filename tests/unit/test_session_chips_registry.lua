--[[
Unit tests: Constants.resolveSessionChips — session-chip membership auto-injection.

Guards defaults_propagation_plan.md G1: chips were the ONLY membership list with no injection
pass, so every new chip needed a hand-written `_session_chips_*` migration and forgetting one
hid the chip from existing users forever. The registry replaces that; these tests pin the two
behaviors that must never regress — a NEW chip appears automatically, and a chip the user
deliberately turned OFF is never resurrected.

Run: lua tests/unit/test_session_chips_registry.lua  (auto-discovered by run_tests.lua --unit)
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

local ALL = Constants.SESSION_CHIP_IDS

local function contains(list, id)
    for _idx, v in ipairs(list) do if v == id then return true end end
    return false
end

local function count(list) return #list end

TestRunner:test("never customized -> every chip on", function()
    local got = Constants.resolveSessionChips(nil, nil)
    TestRunner:assertEqual(count(got), count(ALL), "all chips present")
    for _idx, id in ipairs(ALL) do
        TestRunner:assertTrue(contains(got, id), "contains " .. id)
    end
end)

TestRunner:test("NEW chip is auto-injected for an existing user (the G1 regression)", function()
    -- Simulates a saved list from before a chip existed: everything except the last id.
    local saved = {}
    for i = 1, #ALL - 1 do saved[i] = ALL[i] end
    local new_chip = ALL[#ALL]

    local got = Constants.resolveSessionChips(saved, nil)
    TestRunner:assertTrue(contains(got, new_chip),
        "a chip the user has never seen is injected without any migration")
    TestRunner:assertEqual(count(got), count(ALL), "membership is now complete")
end)

TestRunner:test("deliberately removed chip is NOT resurrected", function()
    local removed = ALL[2]
    local saved = {}
    for _idx, id in ipairs(ALL) do
        if id ~= removed then saved[#saved + 1] = id end
    end
    local got = Constants.resolveSessionChips(saved, { removed })
    TestRunner:assertFalse(contains(got, removed), "dismissed chip stays off")
    TestRunner:assertEqual(count(got), count(ALL) - 1, "only that chip is missing")
end)

TestRunner:test("removal + a separate new chip: one stays off, the other appears", function()
    local removed = ALL[1]
    local new_chip = ALL[#ALL]
    -- Saved list predates new_chip AND has `removed` turned off.
    local saved = {}
    for i = 1, #ALL - 1 do
        if ALL[i] ~= removed then saved[#saved + 1] = ALL[i] end
    end
    local got = Constants.resolveSessionChips(saved, { removed })
    TestRunner:assertFalse(contains(got, removed), "dismissed stays off")
    TestRunner:assertTrue(contains(got, new_chip), "unseen chip still injected")
end)

TestRunner:test("result is always in canonical order", function()
    -- Deliberately scrambled saved order must not leak into the render order.
    local scrambled = {}
    for i = #ALL, 1, -1 do scrambled[#scrambled + 1] = ALL[i] end
    local got = Constants.resolveSessionChips(scrambled, nil)
    for i, id in ipairs(ALL) do
        TestRunner:assertEqual(got[i], id, "position " .. i .. " is canonical")
    end
end)

TestRunner:test("unknown/retired ids in a saved list are dropped", function()
    local saved = { "domain", "a_chip_we_deleted" }
    local got = Constants.resolveSessionChips(saved, nil)
    TestRunner:assertFalse(contains(got, "a_chip_we_deleted"), "stale id not rendered")
    TestRunner:assertTrue(contains(got, "domain"), "valid id kept")
end)

TestRunner:test("empty saved list with all dismissed -> no chips", function()
    local dismissed = {}
    for _idx, id in ipairs(ALL) do dismissed[#dismissed + 1] = id end
    local got = Constants.resolveSessionChips({}, dismissed)
    TestRunner:assertEqual(count(got), 0, "user can turn everything off")
end)

local ok = TestRunner:summary()
return ok
