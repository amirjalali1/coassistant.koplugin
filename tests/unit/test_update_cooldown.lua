-- The automatic update check's session gate (#121, B556): one check per session
-- after a success, never two at once, and no retry within the cooldown of the
-- last attempt, success or failure. The file browser's and the reader's plugin
-- instances share the checker module and each init schedules a check: with
-- Wi-Fi on but GitHub unreachable, every switch between them used to fork again.
--
-- Run: lua tests/unit/test_update_cooldown.lua  (or lua tests/run_tests.lua --unit)

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({
        plugin_dir .. "/?.lua",
        plugin_dir .. "/koassistant/api/?.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
end
setupPaths()
require("mock_koreader")
local UpdateChecker = require("koassistant.storage.update_checker")
local TestRunner = require("test_runner"):new()

local COOLDOWN = UpdateChecker.AUTO_CHECK_COOLDOWN
local NOW = 1000000
local reason = UpdateChecker.autoCheckSkipReason

TestRunner:test("the cooldown is the 30 minutes the wiki states", function()
    TestRunner:assertEqual(COOLDOWN, 30 * 60, "AUTO_CHECK_COOLDOWN")
end)

TestRunner:test("a fresh session may check", function()
    UpdateChecker._setAutoState()
    TestRunner:assertEqual(reason(NOW), nil, "nothing recorded yet")
end)

TestRunner:test("a success holds for the whole session", function()
    UpdateChecker._setAutoState({ done = true, last_attempt = NOW - 10 * COOLDOWN })
    TestRunner:assertEqual(reason(NOW), "done", "done beats an old attempt")
end)

TestRunner:test("a running check is never doubled", function()
    UpdateChecker._setAutoState({ inflight = true })
    TestRunner:assertEqual(reason(NOW), "inflight", "inflight")
end)

TestRunner:test("a failed attempt is tried again after the cooldown, not before", function()
    UpdateChecker._setAutoState({ last_attempt = NOW - COOLDOWN + 1 })
    TestRunner:assertEqual(reason(NOW), "cooldown", "one second short of the cooldown")
    UpdateChecker._setAutoState({ last_attempt = NOW - COOLDOWN })
    TestRunner:assertEqual(reason(NOW), nil, "the cooldown over")
    UpdateChecker._setAutoState({ last_attempt = NOW })
    TestRunner:assertEqual(reason(NOW), "cooldown", "an attempt this very second")
end)

TestRunner:test("checkForUpdates(auto) returns before any fork while in cooldown", function()
    -- The mock's runInSubProcess raises: reaching it would fail the pcall.
    UpdateChecker._setAutoState({ last_attempt = os.time() })
    local ok, err = pcall(UpdateChecker.checkForUpdates, true)
    TestRunner:assertTrue(ok, "no subprocess started: " .. tostring(err))
    TestRunner:assertEqual(reason(os.time()), "cooldown", "the skipped call recorded no attempt")
end)

UpdateChecker._setAutoState() -- the suite runs every file in one process

return TestRunner:summary()
