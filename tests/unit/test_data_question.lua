--[[
Unit tests: the data question's fixes of 2026-10-20 (v0.24.1;
docs/data_question_review_2026-10-20.md).

- Gates: a kind declined for this run (Continue without) reads Never for the run
  alone; an allowance beats a decline; another book's record does not reach this
  one. needs: an optional kind with nothing behind it is not asked, a required one
  stays, and so does one a stored artifact the run reads carries.
- The question's buttons per shape: Continue without when everything asked is
  optional; "Allow once, without …" when a required kind is asked too; a set of
  books asking only the book list keeps Always allow and More… and leaves the
  set's note out; a set asking a book's own data stays Allow once / Cancel.
- The answers: Continue without and Allow once, without … are recorded on the
  run's settings (the question asked again finds nothing); Always allow reaches a
  config copied before the question, in the column it was judged from; More…
  without a book opens Privacy & Data for all books and asks again with the
  file's values.
- One folder rule (scanFolders) and the folders named in the question.
- Source guards: the library dialog keeps an empty pick and every opener starts
  fresh; the X-Ray update and the checkpoint build ask on a private copy; the
  Send records its kinds; the source popup keeps its unread confirm; the next
  read is offered on Ask.

Run: lua tests/run_tests.lua --unit
]]

local plugin_dir
local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({
        plugin_dir .. "/?.lua",
        plugin_dir .. "/?/init.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
end
setupPaths()
require("mock_koreader")

local TestRunner = require("test_runner"):new()
local DataAccess = require("koassistant.ui.data_access")
local Gates = require("koassistant.request.privacy_gates")
local BookSettings = require("koassistant.books.book_settings")
local SDS = require("koassistant.storage.doc_settings")
local UIManager = require("ui/uimanager")
local saved = { resolve = SDS.resolve, show = UIManager.show, close = UIManager.close,
    spc = BookSettings.showPrivacyConfig }
SDS.resolve = function() return nil end  -- no book values in these tests
local shown = {}
UIManager.show = function(_self, w) shown[#shown + 1] = w end
UIManager.close = function() end

local function source(rel)
    local fh = assert(io.open(plugin_dir .. "/" .. rel, "r"))
    local s = fh:read("*a")
    fh:close()
    return s
end

-- A plugin whose settings file is a table
local function makePlugin(store)
    return {
        settings = {
            readSetting = function(_s, key) return store[key] end,
            saveSetting = function(_s, key, value) store[key] = value end,
            flush = function() end,
        },
        updateConfigFromSettings = function() end,
        getProviderDisplayName = function(_s, p) return p end,
    }
end

local function lastButtons()
    local w = shown[#shown]
    local out = {}
    for _r, row in ipairs((w and w.buttons) or {}) do
        for _b, b in ipairs(row) do out[#out + 1] = b.text end
    end
    return table.concat(out, " | ")
end

local function press(text)
    local w = shown[#shown]
    for _r, row in ipairs((w and w.buttons) or {}) do
        for _b, b in ipairs(row) do
            if b.text == text then return b.callback() end
        end
    end
    error("no button " .. text .. " in: " .. lastButtons())
end

local function kindList(needs)
    local out = {}
    for _idx, n in ipairs(needs) do out[#out + 1] = n.kind end
    return table.concat(out, ",")
end

local FIND_SIMILAR = { text = "Find Similar", use_library = true }
local NEXT_READ = { text = "Next Read", use_library = true, use_advanced_stats = true, requires = { "library" } }
local SUGGEST = { text = "Suggest from Library", use_library = true, requires = { "library" } }

print("Running: test_data_question")
print("")
print("  [the gates]")

TestRunner:test("a kind declined for this run reads Never for the run; an allowance beats it", function()
    local f = {}
    Gates.grantOnce(f, "/b/x.epub", { "book_list", habits = false })
    local ctx = Gates.context(f, "anthropic", { path = "/b/x.epub" })
    local state, layer = Gates.resolve("habits", ctx)
    TestRunner:assertEqual(state, "never", "declined")
    TestRunner:assertEqual(layer, "once", "for this run")
    TestRunner:assertEqual((Gates.resolve("book_list", ctx)), "allow", "the allowed kind beside it")
    Gates.grantOnce(f, "/b/x.epub", { "habits" })
    TestRunner:assertEqual((Gates.resolve("habits", Gates.context(f, "anthropic", { path = "/b/x.epub" }))), "allow",
        "an allowance beats a decline")
    Gates.grantOnce(f, "/b/x.epub", { habits = false })
    TestRunner:assertEqual((Gates.resolve("habits", Gates.context(f, "anthropic", { path = "/b/x.epub" }))), "allow",
        "a decline does not undo an allowance")
    Gates.grantOnce(f, "/b/other.epub", { highlights = false })
    TestRunner:assertEqual((Gates.resolve("highlights", Gates.context(f, "anthropic", { path = "/b/x.epub" }))), "ask",
        "another book's record does not reach this one")
end)

TestRunner:test("needs: nothing behind an optional kind, not asked; a required or stored one stays", function()
    local ctx = Gates.context({}, "anthropic", {})
    TestRunner:assertEqual(kindList(Gates.needs(FIND_SIMILAR, ctx, {})), "book_list")
    TestRunner:assertEqual(kindList(Gates.needs(FIND_SIMILAR, ctx, { exists = { book_list = false } })), "",
        "no scan folder: the book list is not asked")
    TestRunner:assertEqual(kindList(Gates.needs(NEXT_READ, ctx, { exists = { habits = false } })), "book_list",
        "no reading statistics: the habits are not asked")
    TestRunner:assertEqual(kindList(Gates.needs(NEXT_READ, ctx, { exists = { book_list = false, habits = false } })),
        "book_list", "a required kind stays (its own check refuses)")
    local reads_xray = { use_highlights = true, use_xray_cache = true }
    TestRunner:assertEqual(kindList(Gates.needs(reads_xray, ctx, { exists = { highlights = false } })), "",
        "no highlights in the book")
    TestRunner:assertEqual(kindList(Gates.needs(reads_xray, ctx, { exists = { highlights = false },
        stamps = { xray = { used_book_text = false, used_highlights = true } } })), "highlights",
        "the X-Ray read along was built with them: still asked")
end)

print("  [the buttons]")

TestRunner:test("everything optional: Continue without, recorded so the question is not asked twice", function()
    local f, ran = {}, nil
    DataAccess.withAccess(makePlugin({ features = {} }), FIND_SIMILAR,
        { features = f, provider = "anthropic", path = "/b/x.epub" }, function(g) ran = g end)
    TestRunner:assertEqual(lastButtons(), "Allow once | Always allow | Continue without | More… | Cancel")
    press("Continue without")
    TestRunner:assertTrue(ran and ran.asked, "the run goes on, answered")
    TestRunner:assertEqual(ran.once.book_list, false, "the decline travels with the run's allowance")
    local before, again = #shown, nil
    DataAccess.withAccess(makePlugin({ features = {} }), FIND_SIMILAR,
        { features = f, provider = "anthropic", path = "/b/x.epub" }, function(g) again = g end)
    TestRunner:assertEqual(#shown, before, "the dispatch's re-entry asks nothing")
    TestRunner:assertEqual(again and again.asked, false, "nothing was asked")
    TestRunner:assertEqual((Gates.resolve("book_list", Gates.context(f, "anthropic", { path = "/b/x.epub" }))), "never",
        "and the gather leaves the list out")
end)

TestRunner:test("a required kind beside an optional one: Allow once, without the optional part", function()
    local f, ran = {}, nil
    DataAccess.withAccess(makePlugin({ features = {} }), NEXT_READ,
        { features = f, provider = "anthropic", path = "/b/x.epub" }, function(g) ran = g end)
    TestRunner:assertEqual(lastButtons(),
        "Allow once | Always allow | Allow once, without your reading habits | More… | Cancel")
    press("Allow once, without your reading habits")
    local ctx = Gates.context(f, "anthropic", { path = "/b/x.epub" })
    TestRunner:assertEqual((Gates.resolve("book_list", ctx)), "allow", "the required list goes, once")
    TestRunner:assertEqual((Gates.resolve("habits", ctx)), "never", "the habits stay out, for this run")
    TestRunner:assertEqual(ran.once[1], "book_list", "the caller's record lists the allowed kind")
    TestRunner:assertEqual(ran.once.habits, false, "and the declined one")
    local before = #shown
    DataAccess.withAccess(makePlugin({ features = {} }), NEXT_READ,
        { features = f, provider = "anthropic", path = "/b/x.epub" }, function() end)
    TestRunner:assertEqual(#shown, before, "asked again: nothing left")
end)

TestRunner:test("a set asking only the book list keeps Always allow and More…, and no set note", function()
    DataAccess.withAccess(makePlugin({ features = {} }), { text = "Recommend", use_library = true },
        { features = {}, provider = "anthropic", books = { { file = "/b/a.epub" }, { file = "/b/b.epub" } } },
        function() end)
    TestRunner:assertEqual(lastButtons(), "Allow once | Always allow | Continue without | More… | Cancel")
    TestRunner:assertTrue(not tostring(shown[#shown].title):find("picked books", 1, true),
        "the set's note concerns each book's own data: left out")
    -- a set asking each book's own data keeps its two answers and its note
    DataAccess.withAccess(makePlugin({ features = {} }),
        { text = "Analyze Notes", use_highlights = true, requires = { "highlights" } },
        { features = {}, provider = "anthropic", books = { { file = "/b/a.epub" }, { file = "/b/b.epub" } } },
        function() end)
    TestRunner:assertEqual(lastButtons(), "Allow once | Cancel")
    TestRunner:assertTrue(tostring(shown[#shown].title):find("picked books", 1, true), "the set's note")
end)

print("  [the answers]")

TestRunner:test("Always allow reaches a config copied before the question", function()
    local store = { features = {} }
    local run_copy = {}
    DataAccess.withAccess(makePlugin(store), SUGGEST,
        { features = run_copy, provider = "anthropic", path = "/b/x.epub" }, function() end)
    press("Always allow")
    TestRunner:assertEqual(store.features.enable_library_scanning, true, "the settings file")
    TestRunner:assertEqual(run_copy.enable_library_scanning, true, "the run's own copy")
    local before = #shown
    DataAccess.withAccess(makePlugin(store), SUGGEST,
        { features = run_copy, provider = "anthropic", path = "/b/x.epub" }, function() end)
    TestRunner:assertEqual(#shown, before, "the run passing the question again is not asked")
end)

TestRunner:test("Always allow writes the column the question was judged from (a trusted provider's)", function()
    local store = { features = {} }
    local run_copy = { trusted_providers = { "anthropic" }, trusted_book_list = "ask" }
    DataAccess.withAccess(makePlugin(store), SUGGEST,
        { features = run_copy, provider = "anthropic", path = "/b/x.epub" }, function() end)
    press("Always allow")
    TestRunner:assertEqual(store.features.trusted_book_list, "allow", "the trusted column")
    TestRunner:assertEqual(store.features.enable_library_scanning, nil, "the column for all providers untouched")
    local before = #shown
    DataAccess.withAccess(makePlugin(store), SUGGEST,
        { features = run_copy, provider = "anthropic", path = "/b/x.epub" }, function() end)
    TestRunner:assertEqual(#shown, before, "no loop")
end)

TestRunner:test("More… without a book opens Privacy & Data for all books and asks again on close", function()
    local opened
    BookSettings.showPrivacyConfig = function(o) opened = o end
    local store = { features = {} }
    local f, ran = {}, nil
    DataAccess.withAccess(makePlugin(store), FIND_SIMILAR,
        { features = f, provider = "anthropic" }, function(g) ran = g end)
    press("More…")
    TestRunner:assertTrue(opened and opened.all_books, "the values for all books")
    TestRunner:assertTrue(ran == nil, "the run waits for the screen")
    store.features.enable_library_scanning = true   -- the reader sets Allow there
    local before = #shown
    opened.on_close()
    BookSettings.showPrivacyConfig = saved.spc
    TestRunner:assertEqual(#shown, before, "judged on the file's values: nothing left to ask")
    TestRunner:assertTrue(ran ~= nil, "the run goes on")
    TestRunner:assertEqual(ran.asked, false, "the merged confirm of a caller shows then")
end)

print("  [the folders]")

TestRunner:test("one folder rule, and the question names the folders", function()
    local p = makePlugin({ features = { library_scan_folders = { "/mnt/Books/Fiction", "/mnt/Books/Non-fiction/" } } })
    TestRunner:assertEqual(#DataAccess.scanFolders(p, false, {}), 2, "the permanent folders")
    p._session_scan_folders = {}
    TestRunner:assertEqual(#DataAccess.scanFolders(p, true, {}), 0,
        "an empty pick in the library dialog is no list, never every folder")
    TestRunner:assertEqual(#DataAccess.scanFolders(p, false, {}), 2, "a book action reads the permanent folders")
    p._session_scan_folders = { "/mnt/Books/Fiction" }
    TestRunner:assertEqual(DataAccess.scanFolders(p, true, {})[1], "/mnt/Books/Fiction", "the dialog's pick")
    TestRunner:assertEqual(DataAccess.folderNames({ "/a/Fiction", "/a/Non-fiction/", "/a/C", "/a/D" }),
        "Fiction, Non-fiction, C, …")
    local list = DataAccess.libraryAmounts({ "/a/Fiction" })
    TestRunner:assertTrue(list and list:find("Fiction", 1, true), "the book list line names its folder")
    TestRunner:assertEqual((DataAccess.libraryAmounts({})), nil, "no folder: no line")
end)

print("  [the call sites]")

TestRunner:test("the library dialog keeps an empty pick and every opener starts fresh", function()
    local dialogs = source("koassistant/ui/dialogs.lua")
    TestRunner:assertTrue(dialogs:find("plugin._session_scan_folders = folders\n", 1, true), "the pick, empty included")
    TestRunner:assertTrue(not dialogs:find("#folders > 0 and folders or nil", 1, true), "never nil for an empty pick")
    local _n, resets = source("main.lua"):gsub("self%._session_scan_folders = nil", "")
    TestRunner:assertEqual(resets, 3, "the three library dialog openers reset the pick")
end)

TestRunner:test("the X-Ray update and the checkpoint build ask on a private copy", function()
    local main = source("main.lua")
    local _n, private = main:gsub("features = da_feats, path = file, ui = self%.ui,", "")
    TestRunner:assertEqual(private, 2, "both askers")
    -- the one asker left on the shared settings is the automatic engine's,
    -- standing-only: no Allow once, so nothing of a run can stay behind
    local _m, shared = main:gsub("features = cf, path = file, ui = self%.ui,", "")
    TestRunner:assertEqual(shared, 1, "one asker on the shared settings")
    local at = main:find("features = cf, path = file, ui = self.ui,", 1, true)
    TestRunner:assertTrue(main:sub(at, at + 400):find("standing_only = true", 1, true),
        "and it is the standing-only one")
end)

TestRunner:test("the Send records its kinds; the popup keeps its unread confirm; the next read on Ask", function()
    local dialogs = source("koassistant/ui/dialogs.lua")
    TestRunner:assertTrue(dialogs:find("history.data_kinds = #kinds > 0 and kinds or nil", 1, true), "the Send's record")
    local main = source("main.lua")
    TestRunner:assertTrue(main:find("if granted and granted.asked then\n                  afterConsent()", 1, true),
        "the popup: the confirm when its question was not answered")
    TestRunner:assertTrue(main:find('NextGates.usable("book_list"', 1, true), "offered unless Never")
end)

print("  [the review's fixes]")

TestRunner:test("one kind asked twice is one line, required when either use is: no skip leaks it", function()
    local kinds = { "nearby_text", { kind = "nearby_text", required = false } }
    local needs = DataAccess.needsFor(nil, { features = { nearby_text_sharing = "ask" }, provider = "anthropic",
        path = "/b/x.epub", kinds = kinds })
    TestRunner:assertEqual(#needs, 1, "one line")
    TestRunner:assertEqual(needs[1].required, true, "required: the page scope needs it")
    DataAccess.withAccess(makePlugin({ features = {} }), nil, { features = { nearby_text_sharing = "ask" },
        provider = "anthropic", path = "/b/x.epub", kinds = kinds, action_name = "Send" }, function() end)
    TestRunner:assertEqual(lastButtons(), "Allow once | Allow for this book | More… | Cancel", "no without")
end)

TestRunner:test("a kind declined for this run is asked again where a later use requires it", function()
    local f = {}
    Gates.grantOnce(f, "/b/x.epub", { highlights = false })
    local ctx = Gates.context(f, "anthropic", { path = "/b/x.epub" })
    TestRunner:assertEqual(Gates.needs({ use_highlights = true, requires = { "highlights" } }, ctx, {})[1].state,
        "ask", "required: asked again, never refused as Never")
    TestRunner:assertEqual(Gates.needs({ use_highlights = true }, ctx, {})[1].state, "never",
        "an optional use stays declined")
    TestRunner:assertEqual(DataAccess.needsFor(nil, { features = f, provider = "anthropic", path = "/b/x.epub",
        kinds = { "highlights" } })[1].state, "ask", "the same through a kinds list")
end)

TestRunner:test("More… for a question judged in the trusted column opens the settings menu", function()
    local opened, cancelled = false, false
    local plugin = makePlugin({ features = {} })
    plugin.onKOAssistantSettings = function() opened = true end
    DataAccess.withAccess(plugin, SUGGEST, { features = { trusted_providers = { "anthropic" }, trusted_book_list = "ask" },
        provider = "anthropic", path = "/b/x.epub", on_cancel = function() cancelled = true end }, function() end)
    press("More…")
    TestRunner:assertTrue(opened, "the trusted providers' values live in the settings menu")
    TestRunner:assertTrue(cancelled, "the run does not go on")
end)

TestRunner:test("the X-Ray chat and the artifact chat record what they carried", function()
    local dialogs = source("koassistant/ui/dialogs.lua")
    TestRunner:assertTrue(dialogs:find("history.data_kinds = (kinds and #kinds > 0) and kinds or nil", 1, true),
        "the artifact chat's record")
    TestRunner:assertTrue(dialogs:find("configuration.features._xray_chat_kinds", 1, true)
        and source("koassistant/xray/xray_browser.lua"):find("config.features._xray_chat_kinds =", 1, true),
        "the X-Ray chat's kinds reach the Send's record")
end)

print("  [the folder window]")

-- Real folders: a remembered folder since removed is not offered again
local DIR_A, DIR_B, DIR_C = plugin_dir .. "/tests", plugin_dir .. "/wiki", plugin_dir .. "/koassistant"

local function buttonOf(text)
    for _r, row in ipairs((shown[#shown] and shown[#shown].buttons) or {}) do
        for _b, b in ipairs(row) do
            if b.text == text then return b end
        end
    end
end

TestRunner:test("on Ask the window is the question: the folders to tick, then the answers", function()
    local store = { features = { library_scan_folders = { DIR_A, DIR_B }, library_recent_folders = { DIR_C, "/gone/away" } } }
    local f, ran = {}, nil
    DataAccess.withAccess(makePlugin(store), FIND_SIMILAR, { features = f, provider = "anthropic", path = "/b/x.epub",
        amounts = { book_list = (DataAccess.windowAmounts()) }, folders = { defaults = { DIR_A } } },
        function(g) ran = g end)
    TestRunner:assertEqual(lastButtons(), "☑ tests | ☐ wiki | ☐ koassistant | + Add folder… | "
        .. "Allow once | Always allow | Continue without | More… | Cancel",
        "the run's folders ticked, the other default one and the recent one unticked, the gone one left out")
    TestRunner:assertTrue(tostring(shown[#shown].title):find("the folders ticked below", 1, true), "the line")
    press("☐ wiki")
    TestRunner:assertEqual(lastButtons(), "☑ tests | ☑ wiki | ☐ koassistant | + Add folder… | "
        .. "Allow once | Always allow | Continue without | More… | Cancel", "a tap ticks, the window drawn again")
    TestRunner:assertTrue(ran == nil, "a tick is not an answer")
    press("Allow once")
    TestRunner:assertTrue(ran and ran.asked, "answered")
    local picked = DataAccess.scanFolders(makePlugin(store), false, f)
    TestRunner:assertEqual(table.concat(picked, ","), DIR_A .. "," .. DIR_B, "the run reads the folders ticked")
    TestRunner:assertEqual((Gates.resolve("book_list", Gates.context(f, "anthropic", { path = "/b/x.epub" }))), "allow")
    TestRunner:assertEqual(#store.features.library_scan_folders, 2, "the default folders untouched")
end)

TestRunner:test("nothing ticked and the action needs the list: its answers wait for a folder", function()
    DataAccess.withAccess(makePlugin({ features = {} }), SUGGEST, { features = {}, provider = "anthropic",
        path = "/b/x.epub", folders = { defaults = {} } }, function() error("must not run") end)
    TestRunner:assertEqual(lastButtons(), "+ Add folder… | Allow once | Always allow | More… | Cancel")
    TestRunner:assertEqual(buttonOf("Allow once").enabled, false, "Allow once waits for a folder")
    TestRunner:assertEqual(buttonOf("Always allow").enabled, false, "so does Always allow")
    TestRunner:assertTrue(tostring(shown[#shown].title):find("Tick or add a folder", 1, true), "the window says why")
end)

TestRunner:test("nothing ticked on a use that can do without: Continue without, the list declined", function()
    local f, ran = {}, nil
    DataAccess.withAccess(makePlugin({ features = {} }), FIND_SIMILAR, { features = f, provider = "anthropic",
        path = "/b/x.epub", folders = { defaults = {} } }, function(g) ran = g end)
    TestRunner:assertEqual(lastButtons(), "+ Add folder… | Continue without | More… | Cancel")
    press("Continue without")
    TestRunner:assertTrue(ran and ran.asked, "the run goes on")
    TestRunner:assertEqual(#DataAccess.scanFolders(makePlugin({ features = {} }), false, f), 0, "no folder for the run")
    TestRunner:assertEqual((Gates.resolve("book_list", Gates.context(f, "anthropic", { path = "/b/x.epub" }))), "never",
        "the list declined for this run")
end)

TestRunner:test("on Allow: Run and Cancel for an action built on the list, no window for one that can do without", function()
    local f, ran = { enable_library_scanning = true }, nil
    DataAccess.withAccess(makePlugin({ features = {} }), SUGGEST, { features = f, provider = "anthropic",
        path = "/b/x.epub", folders = { defaults = { DIR_A } } }, function(g) ran = g end)
    TestRunner:assertEqual(lastButtons(), "☑ tests | + Add folder… | Run | Cancel")
    press("☑ tests")
    TestRunner:assertEqual(buttonOf("Run").enabled, false, "nothing ticked: Run waits")
    press("☐ tests")
    press("Run")
    TestRunner:assertTrue(ran and ran.asked, "Run is an answer")
    TestRunner:assertEqual(DataAccess.scanFolders(makePlugin({ features = {} }), false, f)[1], DIR_A, "the pick")
    local before, direct = #shown, nil
    DataAccess.withAccess(makePlugin({ features = {} }), FIND_SIMILAR, { features = { enable_library_scanning = true },
        provider = "anthropic", path = "/b/x.epub", folders = { defaults = {} } }, function(g) direct = g end)
    TestRunner:assertEqual(#shown, before, "Find Similar on Allow: no window")
    TestRunner:assertEqual(direct and direct.asked, false, "it runs on the folders as they are")
    TestRunner:assertTrue(DataAccess.folderWindowNeed({ { kind = "book_list", state = "never", required = true } }) == nil,
        "Never: no window")
end)

TestRunner:test("+ Add folder…: ticked for this run, remembered, never made a default folder", function()
    local saved_pc, saved_tick, saved_grs = package.loaded["ui/widget/pathchooser"], UIManager.nextTick, G_reader_settings
    package.loaded["ui/widget/pathchooser"] = { new = function(_self, o) return o end }
    UIManager.nextTick = function(_self, fn) fn() end
    G_reader_settings = { readSetting = function() return "/" end }  -- luacheck: ignore
    local store = { features = { library_scan_folders = { DIR_A } } }
    local f, ran = {}, nil
    DataAccess.withAccess(makePlugin(store), SUGGEST, { features = f, provider = "anthropic", path = "/b/x.epub",
        folders = { defaults = { DIR_A } } }, function(g) ran = g end)
    press("+ Add folder…")
    shown[#shown].onConfirm(DIR_B)
    TestRunner:assertEqual(lastButtons(), "☑ tests | ☑ wiki | + Add folder… | Allow once | Always allow | More… | Cancel",
        "the folder chosen is ticked")
    TestRunner:assertEqual(store.features.library_recent_folders[1], DIR_B, "remembered")
    TestRunner:assertEqual(#store.features.library_scan_folders, 1, "never a default folder")
    press("Allow once")
    TestRunner:assertEqual(#DataAccess.scanFolders(makePlugin(store), false, f), 2, "both for this run")
    package.loaded["ui/widget/pathchooser"], UIManager.nextTick, G_reader_settings = saved_pc, saved_tick, saved_grs  -- luacheck: ignore
end)

TestRunner:test("More… keeps the ticks, also when nothing is left to ask after it", function()
    local opened
    BookSettings.showPrivacyConfig = function(o) opened = o end
    local store = { features = { library_scan_folders = { DIR_A }, library_recent_folders = { DIR_B } } }
    local f, ran = {}, nil
    DataAccess.withAccess(makePlugin(store), FIND_SIMILAR, { features = f, provider = "anthropic", path = "/b/x.epub",
        folders = { defaults = { DIR_A } } }, function(g) ran = g end)
    press("☑ tests")
    press("☐ wiki")
    press("More…")
    store.features.enable_library_scanning = true   -- Allow, set on the screen
    opened.on_close()
    BookSettings.showPrivacyConfig = saved.spc
    TestRunner:assertTrue(ran ~= nil, "nothing left to ask: the run goes on")
    TestRunner:assertEqual(table.concat(DataAccess.scanFolders(makePlugin(store), false, f), ","), DIR_B,
        "the folders ticked before More…, not the default one unticked")
end)

TestRunner:test("recent folders: newest first, five kept; the run's pick beats every other folder", function()
    local store = { features = {} }
    local p = makePlugin(store)
    for i = 1, 6 do DataAccess.rememberFolder(p, "/r/" .. i) end
    DataAccess.rememberFolder(p, "/r/3")
    TestRunner:assertEqual(table.concat(store.features.library_recent_folders, ","), "/r/3,/r/6,/r/5,/r/4,/r/2")
    p._session_scan_folders = { "/dialog" }
    TestRunner:assertEqual(DataAccess.scanFolders(p, true, { _data_once = { kinds = {}, folders = { "/run" } } })[1], "/run")
    TestRunner:assertEqual(#DataAccess.folderRows({ "/a" }, { "/a", "/b" }, { "/b", "/c" }), 3, "each folder once")
end)

TestRunner:test("the dispatch: the window asks, its re-entry runs; no folder refusal is left", function()
    local store = { features = { library_scan_folders = { DIR_A } } }
    local cf = { is_book_context = true, book_metadata = { file = "/b/x.epub" }, provider = "anthropic" }
    local reentered = false
    local action = { id = "suggest_from_library", text = "Suggest from Library", use_library = true, requires = { "library" } }
    TestRunner:assertEqual(DataAccess.askForDispatch(makePlugin(store), action, cf, nil, { provider = "anthropic" },
        function() reentered = true end), true, "the window shows")
    press("Allow once")
    TestRunner:assertTrue(reentered, "the answer re-enters the dispatch")
    TestRunner:assertEqual(DataAccess.askForDispatch(makePlugin(store), action, cf, nil, { provider = "anthropic" },
        function() end), false, "the re-entry finds the pick made: nothing shown")
    local main = source("main.lua")
    TestRunner:assertTrue(not main:find("No scan folders configured", 1, true)
        and not main:find("No scan folder is ticked", 1, true), "the folder refusals are gone")
    TestRunner:assertTrue(main:find('require("koassistant.ui.data_access").recentFolders(self)', 1, true),
        "the next read: a default folder or one picked before")
    TestRunner:assertTrue(source("koassistant/ui/dialogs.lua"):find(
        "local library_scan_available = library_toggle_on\n        and #require(\"koassistant.ui.data_access\").scanFolders(plugin, true, {}) > 0", 1, true),
        "the library dialog greys its scan actions until a folder is ticked there")
    local reg = source("koassistant/storage/storage_registry.lua")
    TestRunner:assertTrue(reg:find('"library_recent_folders",', 1, true)
        and reg:find('"index_scan_folders", "library_recent_folders" }', 1, true), "registered, and follows a folder's move")
end)

print("  [the library dialog]")

TestRunner:test("a library dialog run: its own ticks, no window; nothing ticked = no list, or a refusal", function()
    local analyze = { id = "analyze_library", text = "Analyze Library", context = "library",
        use_library = true, requires = { "library" } }
    local recommend = { id = "recommend_books", text = "Recommend", context = "library", use_library = true }
    local p = makePlugin({ features = { library_scan_folders = { DIR_B } } })
    p._session_scan_folders = { DIR_A }
    local cf = { is_library_context = true, provider = "anthropic" }
    TestRunner:assertEqual(DataAccess.askForDispatch(p, analyze, cf, nil, { provider = "anthropic" }, function() end), true)
    TestRunner:assertEqual(lastButtons(), "Allow once | Always allow | More… | Cancel", "the question alone: no folder rows")
    TestRunner:assertTrue(tostring(shown[#shown].title):find("the books in tests", 1, true),
        "it names the folders ticked in the dialog")
    local empty = makePlugin({ features = {} })
    TestRunner:assertEqual(DataAccess.askForDispatch(empty, recommend, { is_library_context = true, provider = "anthropic" },
        nil, { provider = "anthropic" }, function() end), false, "nothing ticked: Recommend runs without the list, unasked")
    local before = #shown
    TestRunner:assertEqual(DataAccess.askForDispatch(empty, analyze, { is_library_context = true, provider = "anthropic" },
        nil, { provider = "anthropic" }, function() error("must not run") end), true)
    TestRunner:assertTrue(#shown == before + 1 and tostring(shown[#shown].text):find("No scan folder is ticked", 1, true),
        "an action that needs the list and slips past the greying is refused")
end)

TestRunner:test("the question lists the library scan before the reading habits read from it", function()
    local text = DataAccess.questionText({ action_name = "Next Read", provider_name = "Anthropic",
        asked = { { kind = "habits" }, { kind = "book_list" } },
        amounts = { book_list = "your library scan: the books in Fiction", habits = "your reading habits for those books" } })
    local list_at, habits_at = text:find("library scan", 1, true), text:find("reading habits", 1, true)
    TestRunner:assertTrue(list_at and habits_at and list_at < habits_at, "the folders' line first")
    -- habits asked alone (the list on Allow): the list is shown beside them
    DataAccess.withAccess(makePlugin({ features = {} }), NEXT_READ, { features = { enable_library_scanning = true },
        provider = "anthropic", path = "/b/x.epub" }, function() end)
    TestRunner:assertTrue(tostring(shown[#shown].title):find("your library scan", 1, true),
        "the books the habits are read from")
end)

TestRunner:test("the library boxes: Library Scan on every editor screen, reading habits under it", function()
    local pm = source("koassistant/ui/prompts_manager.lua")
    local _a, any_ctx = pm:gsub("if state%.context and state%.use_library then", "")
    TestRunner:assertEqual(any_ctx, 2, "the new-action wizard and a custom action's settings")
    TestRunner:assertTrue(pm:find("if state.use_library_base and state.use_library then", 1, true),
        "a built-in action's settings: on the actions that use the library")
    TestRunner:assertTrue(pm:find("override.use_library = state.use_library", 1, true), "a built-in's change is kept")
    TestRunner:assertTrue(pm:find("-- read back, or the save (updatePrompt) would drop it\n        use_library = prompt.use_library or false,", 1, true),
        "a custom action's settings load the flag their save writes")
end)

SDS.resolve = saved.resolve
UIManager.show = saved.show
UIManager.close = saved.close
BookSettings.showPrivacyConfig = saved.spc

return TestRunner:summary()
