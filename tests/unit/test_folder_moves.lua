-- B507 (2026-10-19): a folder moved or renamed in KOReader's file browser.
-- KOReader moves the folder whole and re-keys its own History, Collections
-- and folder settings through ReadHistory:updateItemsByPath; it never calls
-- DocSettings.updateLocation for the books inside. main.lua patches that call
-- to run StorageRegistry.followFolderMove, which re-keys every list of the
-- plugin's that names a book or a folder by path: the indexes, the groups,
-- the pictures, the per-book store memo, the moved-book sweep (X-Ray links,
-- pinned items) and the folder settings. The sweep itself is tested in
-- test_moved_book_links, the groups, pictures and store memo in their own
-- files; this file tests the rule, the walk and the hook.
--
-- Run: lua tests/unit/test_folder_moves.lua  (or lua tests/run_tests.lua --unit)

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
local PLUGIN_DIR = setupPaths()

require("mock_koreader")
local TestRunner = require("test_runner"):new()
local SafeDocSettings = require("koassistant.storage.doc_settings")

print("Running: test_folder_moves")

print("\n  [the rule]")
TestRunner:test("inFolder: inside at any depth; a folder named alike is another folder", function()
    TestRunner:assertTrue(SafeDocSettings.inFolder("/b/Saga/1.epub", "/b/Saga"), "inside")
    TestRunner:assertTrue(SafeDocSettings.inFolder("/b/Saga/sub/2.epub", "/b/Saga"), "deeper")
    TestRunner:assertTrue(not SafeDocSettings.inFolder("/b/Saga 2/x.epub", "/b/Saga"), "alike")
    TestRunner:assertTrue(not SafeDocSettings.inFolder("/b/Saga", "/b/Saga"), "the folder itself is not inside")
    TestRunner:assertTrue(not SafeDocSettings.inFolder("/b/x.epub", ""), "no folder")
    TestRunner:assertTrue(not SafeDocSettings.inFolder(nil, "/b"), "no path")
end)
TestRunner:test("movedPath: the folder and everything inside follow; nil outside", function()
    TestRunner:assertEqual(SafeDocSettings.movedPath("/b/Saga/1.epub", "/b/Saga", "/c/Done"), "/c/Done/1.epub")
    TestRunner:assertEqual(SafeDocSettings.movedPath("/b/Saga", "/b/Saga", "/c/Done"), "/c/Done", "the folder")
    TestRunner:assertEqual(SafeDocSettings.movedPath("/b/Saga 2/x.epub", "/b/Saga", "/c/Done"), nil, "alike")
    TestRunner:assertEqual(SafeDocSettings.movedPath("__GENERAL_CHATS__", "/b/Saga", "/c/Done"), nil, "a key")
    TestRunner:assertEqual(SafeDocSettings.movedPath(nil, "/b/Saga", "/c/Done"), nil, "nothing")
end)

-- The walk: every module it calls recorded, over a fake settings store
local MOCKED = { "koassistant.books.book_groups", "koassistant.images.image_generator",
    "koassistant.storage.book_store", "koassistant.xray.xray_merge", "koassistant.storage.storage_registry" }
local saved_loaded = {}
for _idx, name in ipairs(MOCKED) do
    saved_loaded[name] = package.loaded[name]
    package.loaded[name] = nil
end
local saved_settings = _G.G_reader_settings

local calls
local function record(name) return function(...) calls[#calls + 1] = { name, ... } end end
package.loaded["koassistant.books.book_groups"] = {
    updateForFolderMove = function(old_dir, new_dir)
        calls[#calls + 1] = { "groups", old_dir, new_dir }
        return 2
    end,
}
package.loaded["koassistant.images.image_generator"] = { updateIndexForMove = record("images") }
package.loaded["koassistant.storage.book_store"] = { invalidateUnder = record("store") }
package.loaded["koassistant.xray.xray_merge"] = { noteMoved = record("links") }
local Registry = require("koassistant.storage.storage_registry")

local flushes
local function fakeGlobal(store)
    flushes = 0
    _G.G_reader_settings = {
        _store = store,
        readSetting = function(self, key) return self._store[key] end,
        saveSetting = function(self, key, value) self._store[key] = value end,
        flush = function() flushes = flushes + 1 end,
    }
end
local function fakeSettings(features)
    local s = { data = { features = features }, saved = 0, flushed = 0 }
    function s:readSetting(key) return self.data[key] end
    function s:saveSetting(key, value) self.data[key] = value; self.saved = self.saved + 1 end
    function s:flush() self.flushed = self.flushed + 1 end
    return s
end

print("\n  [the walk]")
TestRunner:test("the indexes re-key every book inside; groups, pictures, store memo and links follow", function()
    calls = {}
    fakeGlobal({
        koassistant_chat_index = { ["/b/Saga/1.epub"] = { count = 2 }, ["/b/Saga 2/x.epub"] = { count = 1 },
            ["__GENERAL_CHATS__"] = { count = 5 } },
        koassistant_artifact_index = { ["/b/Saga/sub/2.epub"] = { count = 1 }, ["/b/other.epub"] = { count = 3 } },
        koassistant_pinned_index = { ["/b/other.epub"] = { count = 1 } },
    })
    local count, changed = Registry.followFolderMove("/b/Saga/", "/b/Done", nil)
    local chat = G_reader_settings._store.koassistant_chat_index
    TestRunner:assertEqual(chat["/b/Done/1.epub"].count, 2, "chat index: re-keyed (trailing slash dropped)")
    TestRunner:assertEqual(chat["/b/Saga/1.epub"], nil, "the old key gone")
    TestRunner:assertEqual(chat["/b/Saga 2/x.epub"].count, 1, "a folder named alike stays")
    TestRunner:assertEqual(chat["__GENERAL_CHATS__"].count, 5, "the general chats key stays")
    local art = G_reader_settings._store.koassistant_artifact_index
    TestRunner:assertEqual(art["/b/Done/sub/2.epub"].count, 1, "a subfolder's book")
    TestRunner:assertEqual(art["/b/other.epub"].count, 3, "outside stays")
    TestRunner:assertEqual(flushes, 1, "one flush for every index")
    TestRunner:assertEqual(count, 4, "two index entries and two group members")
    TestRunner:assertEqual(changed, false, "no settings handed")
    local seen = {}
    for _idx, c in ipairs(calls) do seen[c[1]] = c end
    TestRunner:assertEqual(seen.groups[2], "/b/Saga", "groups by the folder")
    TestRunner:assertEqual(seen.images[5], true, "pictures by the folder")
    TestRunner:assertEqual(seen.links[2], "/b/Saga", "the sweep: old folder")
    TestRunner:assertEqual(seen.links[3], "/b/Done", "the sweep: new folder")
    TestRunner:assertEqual(seen.links[4], true, "the sweep: as a folder")
    local order = {}
    for i, c in ipairs(calls) do order[c[1]] = order[c[1]] or i end
    TestRunner:assertTrue(order.groups < order.links, "groups re-keyed before the sweep is queued")
end)
TestRunner:test("the folder settings follow: scan lists, the notebook and export folders", function()
    calls = {}
    fakeGlobal({})
    local settings = fakeSettings({
        library_scan_folders = { "/b/Saga", "/b/Saga/sub", "/b/Saga 2" },
        index_scan_folders = { "/b" },
        notebook_custom_path = "/b/Saga/notes",
        export_custom_path = "/exports",
    })
    local count, changed = Registry.followFolderMove("/b/Saga", "/b/Done", settings)
    local f = settings.data.features
    TestRunner:assertEqual(f.library_scan_folders[1], "/b/Done", "the folder itself")
    TestRunner:assertEqual(f.library_scan_folders[2], "/b/Done/sub", "a folder inside")
    TestRunner:assertEqual(f.library_scan_folders[3], "/b/Saga 2", "a folder named alike")
    TestRunner:assertEqual(f.index_scan_folders[1], "/b", "a parent stays")
    TestRunner:assertEqual(f.notebook_custom_path, "/b/Done/notes", "the notebook folder")
    TestRunner:assertEqual(f.export_custom_path, "/exports", "outside stays")
    TestRunner:assertTrue(changed, "reported")
    TestRunner:assertEqual(settings.saved, 1, "saved once")
    TestRunner:assertEqual(settings.flushed, 1, "flushed once")
    TestRunner:assertEqual(count, 2, "the groups' two")
end)
TestRunner:test("nothing to follow: the same folder, an empty name, no paths", function()
    calls = {}
    fakeGlobal({})
    TestRunner:assertEqual(Registry.followFolderMove("/b/Saga", "/b/Saga", nil), 0, "same folder")
    TestRunner:assertEqual(Registry.followFolderMove("/", "/b", nil), 0, "the root")
    TestRunner:assertEqual(Registry.followFolderMove(nil, "/b", nil), 0, "no path")
    TestRunner:assertEqual(#calls, 0, "no module touched")
end)

-- The hook: main.lua's patch, cut from the source and run over a fake
-- ReadHistory, so the hand-off is the code that ships
print("\n  [the hook in main.lua]")
local function patchSource()
    local f = assert(io.open(PLUGIN_DIR .. "/main.lua", "r"))
    local src = f:read("*a")
    f:close()
    local start = src:find("function AskGPT:patchReadHistoryForFolderMoves()", 1, true)
    assert(start, "the patch is in main.lua")
    local stop = src:find("\nend\n", start, true)
    return src:sub(start, stop + 4)
end

local function installPatch(follow, live)
    local log = {}
    local history = { _koassistant_patched = nil }
    function history.updateItemsByPath(_self, old_dir, new_dir)
        log[#log + 1] = { "history", old_dir, new_dir }
    end
    local env = setmetatable({
        AskGPT = {},
        FileManager = { instance = live and { koassistant = live } or nil },
        StorageRegistry = { followFolderMove = function(...)
            log[#log + 1] = { "follow", ... }
            return follow(...)
        end },
        logger = { dbg = function() end, warn = function(...) log[#log + 1] = { "warn", ... } end },
        require = function(name)
            if name == "readhistory" then return history end
            return require(name)
        end,
    }, { __index = _G })
    local chunk = assert(load(patchSource(), "main.lua patch", "t", env))
    chunk()
    env.AskGPT.patchReadHistoryForFolderMoves({})
    return history, log
end

TestRunner:test("KOReader's re-key runs first, then the walk with the browser's settings", function()
    local refreshed = 0
    local live = { settings = { tag = "live settings" } }
    function live:updateConfigFromSettings() refreshed = refreshed + 1 end
    local history, log = installPatch(function() return 3, true end, live)
    history:updateItemsByPath("/b/Saga", "/b/Done")
    TestRunner:assertEqual(log[1][1], "history", "KOReader's own first")
    TestRunner:assertEqual(log[2][1], "follow", "then the plugin's lists")
    TestRunner:assertEqual(log[2][2], "/b/Saga", "old folder")
    TestRunner:assertEqual(log[2][3], "/b/Done", "new folder")
    TestRunner:assertEqual(log[2][4].tag, "live settings", "the file browser instance's settings")
    TestRunner:assertEqual(refreshed, 1, "the live config re-read when a folder setting moved")
end)
TestRunner:test("a failure in the walk never breaks KOReader's move; installed once", function()
    local history, log = installPatch(function() error("disk full") end, nil)
    history:updateItemsByPath("/b/Saga", "/b/Done")
    TestRunner:assertEqual(log[1][1], "history", "KOReader's re-key ran")
    TestRunner:assertEqual(log[3][1], "warn", "the failure logged")
    TestRunner:assertTrue(history._koassistant_patched, "marked")
    local wrapped = history.updateItemsByPath
    -- A second plugin instance starting leaves the patch as it is
    local env_require = function(name) if name == "readhistory" then return history end return require(name) end
    local env = setmetatable({ AskGPT = {}, FileManager = {}, StorageRegistry = {}, logger = {},
        require = env_require }, { __index = _G })
    assert(load(patchSource(), "main.lua patch", "t", env))()
    env.AskGPT.patchReadHistoryForFolderMoves({})
    TestRunner:assertTrue(history.updateItemsByPath == wrapped, "not wrapped twice")
end)

-- Restore what this file replaced (one Lua process runs every suite)
_G.G_reader_settings = saved_settings
for _idx, name in ipairs(MOCKED) do package.loaded[name] = saved_loaded[name] end

local ok = TestRunner:summary()
return ok
