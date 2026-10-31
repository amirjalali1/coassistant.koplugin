-- B454: Chat History > View by Domain named a chat's domain through
-- DomainLoader.load(), which reads only the reader's domains/ folder, so chats
-- under the built-in Synthesis or a domain made in Manage Domains were listed
-- under their raw ids ("synthesis", "custom_1"). The names now come from the
-- merged lookup (built-ins, the domains/ folder, the Manage Domains list), the
-- one every other surface uses.
--
-- The browser's own lookup lines are cut from the source and evaluated against
-- the real loader (the test_front_matter_flow pattern): a guard that only greps
-- can pass while the code it names never runs.
--
-- Run: lua tests/unit/test_chat_history_domains.lua  (or lua tests/run_tests.lua --unit)

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
local src = source("koassistant/chat/chat_history_dialog.lua")

-- The lines that build the id -> domain table the browser names domains from
local block = src:match("function ChatHistoryDialog:showChatsByDomainBrowser%(.-\n(    local DomainLoader = require.-)\n%s*%-%- Build menu items for each domain")
assert(block, "the domain lookup in showChatsByDomainBrowser: not found in the source")
local lookup = assert(load("local config = ...\n" .. block .. "\nreturn all_domains", "domain_lookup"))

local MADE_IN_THE_APP = { { id = "custom_1", name = "Reading notes", context = "Notes on what I read." } }

-- The built-in Synthesis stands for "a domain the reader's domains/ folder does not
-- hold" (a file of the reader's own may replace it, so its heading is not asserted)
TestRunner:test("a built-in domain is named, not listed by its id", function()
    local all = lookup({ features = { custom_domains = MADE_IN_THE_APP } })
    TestRunner:assertTrue(all.synthesis, "the built-in Synthesis is in the table")
    TestRunner:assertEqual(type(all.synthesis.name), "string")
    TestRunner:assertTrue(all.synthesis.name ~= "" and all.synthesis.name ~= "synthesis",
        "a name, not the raw id")
end)

TestRunner:test("a domain made in Manage Domains is named, not listed by its id", function()
    local all = lookup({ features = { custom_domains = MADE_IN_THE_APP } })
    TestRunner:assertTrue(all.custom_1, "the app-made domain is in the table")
    TestRunner:assertEqual(all.custom_1.name, "Reading notes")
end)

TestRunner:test("an id nothing defines any more has no entry, so the browser falls back to the id", function()
    local all = lookup({ features = { custom_domains = MADE_IN_THE_APP } })
    TestRunner:assertEqual(all.custom_9, nil)
end)

TestRunner:test("with no configuration the built-ins still resolve", function()
    local all = lookup(nil)
    TestRunner:assertTrue(all.synthesis and all.synthesis.name ~= "synthesis", "the built-in is named")
    TestRunner:assertEqual(all.custom_1, nil)
end)

TestRunner:test("the browser no longer asks the folder-only loader", function()
    TestRunner:assertFalse(block:find("DomainLoader.load()", 1, true), "load() reads only domains/")
end)

return TestRunner:summary()
