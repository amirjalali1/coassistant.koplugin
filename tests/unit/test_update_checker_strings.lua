-- B474: the update checker's messages (checking, the failures, "You are running the
-- latest version", the dialog titles, the "New version available" header, the release
-- notes window) went to the screen in English whatever the interface language. Every
-- text and title it shows now goes through gettext, and a message that carries a
-- value is a template, never a sentence built by joining translated pieces.
--
-- Run: lua tests/unit/test_update_checker_strings.lua  (or lua tests/run_tests.lua --unit)

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
    return plugin_dir
end
local plugin_dir = setupPaths()
require("mock_koreader")
local TestRunner = require("test_runner"):new()

local function source(rel)
    local f = assert(io.open(plugin_dir .. "/" .. rel, "r"))
    local s = f:read("*a")
    f:close()
    return s
end
local src = source("koassistant/storage/update_checker.lua")

TestRunner:test("no text or title is a bare English literal", function()
    local bare = {}
    local n = 0
    for line in (src .. "\n"):gmatch("(.-)\n") do
        n = n + 1
        local code = line:gsub("%-%-.*$", "")
        -- text = "..." / title = "..." (a key of its own: markdown_text and the like are not)
        if code:find("[^_%w]text%s*=%s*\"") or code:find("[^_%w]title%s*=%s*\"")
                or code:find("^%s*text%s*=%s*\"") or code:find("^%s*title%s*=%s*\"") then
            bare[#bare + 1] = n .. ": " .. line:gsub("^%s+", "")
        end
    end
    TestRunner:assertEqual(#bare, 0, "untranslated:\n" .. table.concat(bare, "\n"))
end)

TestRunner:test("a message with a version in it is a template", function()
    TestRunner:assertTrue(src:find('T(_("You are running the latest version (%1)"), current_version)', 1, true),
        "latest version")
    TestRunner:assertTrue(src:find('T(_("You are running a development version (%1)"), current_version)', 1, true),
        "development version")
    TestRunner:assertFalse(src:find('"You are running the latest version (" ..', 1, true), "no joined sentence")
end)

TestRunner:test("the 'New version available' header is two whole sentences, not a joined fragment", function()
    TestRunner:assertTrue(src:find('_("New pre-release version available!")', 1, true), "pre-release header")
    TestRunner:assertTrue(src:find('_("New version available!")', 1, true), "release header")
    TestRunner:assertFalse(src:find('"pre-release "', 1, true), "no 'pre-release ' fragment to splice in")
end)

TestRunner:test("the checking message and the failure messages are wrapped", function()
    for _idx, text in ipairs({
        "Checking for updates...",
        "Failed to check for updates (timed out). Please try again.",
        "Failed to check for updates. Please check your internet connection.",
        "Failed to check for updates: Empty response from server",
        "Failed to check for updates: Invalid response format",
        "No releases found",
        "Update check failed: invalid current version format",
        "Update check failed: invalid latest version format",
        "KOAssistant Update Available",
        "KOAssistant Pre-release Update",
    }) do
        TestRunner:assertTrue(src:find('_("' .. text .. '")', 1, true), text)
    end
end)

return TestRunner:summary()
