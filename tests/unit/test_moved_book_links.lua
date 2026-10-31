-- B504 (2026-10-19): cross-book X-Ray data names books by path (the fold
-- ledger, carried entries, background lines), and pinned items name their
-- book too. Moving a book inside KOReader re-keyed the indexes, images and
-- groups, not these: a finished AI merge read as never run, a carried entry
-- lost its source, and a book set to Never was judged at a path where it no
-- longer is. XrayMerge.noteMoved queues the move; one sweep rewrites the
-- quoted paths in every book that names them, in one pass, with nothing else
-- changed. B507: a folder's move or rename queues the folder, and every book
-- inside it follows the same way. Real files in a temp folder.
--
-- Run: lua tests/unit/test_moved_book_links.lua  (or lua tests/run_tests.lua --unit)

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
end
setupPaths()

local TMP = "/tmp/koassistant_moved_links_" .. tostring(os.time()) .. "_" .. tostring(math.random(100000))
os.execute(string.format("mkdir -p %q", TMP))

-- Fresh modules over this file's mocks (the suite shares one Lua process)
local saved_loaded = {}
for _idx, name in ipairs({ "koassistant.artifacts.action_cache", "koassistant.xray.xray_merge",
        "koassistant.artifacts.pinned_manager", "koassistant.books.book_groups",
        "docsettings", "util", "luasettings" }) do
    saved_loaded[name] = package.loaded[name]
    package.loaded[name] = nil
end
local saved_settings = _G.G_reader_settings

require("mock_koreader")
local UIManager = require("ui/uimanager")
local had_unschedule = UIManager.unschedule
UIManager.unschedule = UIManager.unschedule or function() end

_G.G_reader_settings = {
    _store = {},
    readSetting = function(self, key, default)
        if key == "document_metadata_folder" then return "doc" end
        local v = self._store[key]
        if v == nil then return default end
        return v
    end,
    saveSetting = function(self, key, value) self._store[key] = value end,
    flush = function() end,
}
-- Each book's sidecar beside it, as KOReader's "book folder" location
package.loaded["docsettings"] = {
    getSidecarDir = function(_self, doc_path) return doc_path:gsub("%.epub$", "") .. ".sdr" end,
    isHashLocationEnabled = function() return false end,
}
package.loaded["util"] = {
    makePath = function(dir) os.execute(string.format("mkdir -p %q", dir)) end,
}
package.loaded["luasettings"] = {
    open = function() return { readSetting = function() return nil end, close = function() end } end,
}
local groups = {}
package.loaded["koassistant.books.book_groups"] = {
    all = function() return groups end,
    groupsFor = function(path)
        local out = {}
        for _idx, g in ipairs(groups) do
            for _j, b in ipairs(g.books) do if b == path then out[#out + 1] = g end end
        end
        return out
    end,
}

local ActionCache = require("koassistant.artifacts.action_cache")
local XrayMerge = require("koassistant.xray.xray_merge")
local PinnedManager = require("koassistant.artifacts.pinned_manager")
local json = require("json")
local TestRunner = require("test_runner"):new()

-- The general and library pinned stores in the temp folder, not the shared one
local had_general, had_library = PinnedManager.GENERAL_PINNED_FILE, PinnedManager.LIBRARY_PINNED_FILE
PinnedManager.GENERAL_PINNED_FILE = TMP .. "/settings/koassistant_pinned_general.lua"
PinnedManager.LIBRARY_PINNED_FILE = TMP .. "/settings/koassistant_pinned_library.lua"
os.execute(string.format("mkdir -p %q", TMP .. "/settings"))

print("Running: test_moved_book_links")

local OLD_A = TMP .. "/old/Series 1.epub"
local NEW_A = TMP .. "/new/Series 1.epub"
local B = TMP .. "/Series 2.epub"
local C = TMP .. "/Other.epub"
local F = TMP .. "/Escaped.epub"

-- KOReader's encoder writes "/" as "\/"; the test encoder may not
local function esc(p) return (p:gsub("/", "\\/")) end

local function xrayNaming(path)
    return json.encode({
        characters = { { name = "Ann", description = "d",
            background = { { source = "Series 1", text = "earlier", file = path } } } },
        __dormant = { { name = "Bob", category = "characters", source = "Series 1", file = path } },
    })
end

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local LEDGER = { { title = "Series 1", file = OLD_A, at = 100, source_ts = 90 } }
local JSON_OLD = xrayNaming(OLD_A)

-- B names A everywhere it can: both live keys, a built checkpoint, an archived version
assert(ActionCache.set(B, "xray", JSON_OLD, 0.5, { timestamp = 12345, progress_page = 50,
    merged_from = LEDGER }))
assert(ActionCache.setXrayCache(B, JSON_OLD, 0.5, { timestamp = 12345, progress_page = 50,
    merged_from = LEDGER }))
assert(ActionCache.set(B, "recap", "A recap that names nothing.", 0.5, { timestamp = 222 }))
assert(ActionCache.pushXrayLadderRung(B, { result = JSON_OLD, progress_decimal = 0.4, progress_page = 40,
    timestamp = 11111, merged_from = LEDGER }))
assert(ActionCache.pushXrayCheckpoint(B, { result = JSON_OLD, progress_decimal = 0.3, progress_page = 30,
    timestamp = 10000, merged_from = LEDGER }, 5))
-- C names nobody
assert(ActionCache.set(C, "xray", xrayNaming(TMP .. "/elsewhere.epub"), 0.2, { timestamp = 333 }))
-- F was written by KOReader's encoder: "\/" in every path
local F_JSON = '{"__dormant":[{"name":"Zed","file":"' .. esc(OLD_A) .. '"}],"characters":[]}'
assert(ActionCache.set(F, "xray", F_JSON, 0.4, { timestamp = 555 }))
-- Pinned items: one in the general store, one in the moved book's own store
assert(PinnedManager.addPin(PinnedManager.GENERAL_KEY, { id = "p1", result = "pinned text",
    document_path = OLD_A, timestamp = 1 }))
assert(PinnedManager.addPin(NEW_A, { id = "p2", result = "own pin", document_path = OLD_A, timestamp = 2 }))

G_reader_settings._store.koassistant_artifact_index = {
    [B] = { count = 2, modified = 12345 }, [C] = { count = 1, modified = 333 }, [F] = { count = 1, modified = 555 },
}

local c_before = readFile(ActionCache.getPath(C))
local enc_old, enc_new = json.encode(OLD_A), json.encode(NEW_A)

XrayMerge.noteMoved(OLD_A, NEW_A)
XrayMerge._sweepMoves(true)

print("\n  [one move]")
TestRunner:test("the live X-Ray names the new path, on both cache keys", function()
    for _idx, entry in ipairs({ ActionCache.get(B, "xray"), ActionCache.getXrayCache(B) }) do
        TestRunner:assertTrue(entry.result:find(enc_new, 1, true) ~= nil, "new path in the result")
        TestRunner:assertTrue(entry.result:find(enc_old, 1, true) == nil, "old path gone")
        TestRunner:assertEqual(entry.merged_from[1].file, NEW_A, "fold ledger")
        TestRunner:assertEqual(entry.merged_from[1].source_ts, 90, "fold version kept")
        TestRunner:assertEqual(entry.timestamp, 12345, "timestamp kept (a fold's version check)")
        TestRunner:assertEqual(entry.progress_page, 50, "progress kept")
    end
    local data = json.decode(ActionCache.get(B, "xray").result)
    TestRunner:assertEqual(data.__dormant[1].file, NEW_A, "carried entry")
    TestRunner:assertEqual(data.characters[1].background[1].file, NEW_A, "background line")
    TestRunner:assertEqual(ActionCache.get(B, "recap").result, "A recap that names nothing.", "other entries as they were")
end)
TestRunner:test("KOReader's escaped form is found and written back escaped", function()
    local result = ActionCache.get(F, "xray").result
    TestRunner:assertTrue(result:find('"' .. esc(NEW_A) .. '"', 1, true) ~= nil, "escaped new path")
    TestRunner:assertTrue(result:find(esc(OLD_A), 1, true) == nil, "escaped old path gone")
    TestRunner:assertEqual(json.decode(result).__dormant[1].file, NEW_A, "decodes to the new path")
end)
TestRunner:test("checkpoints and archived versions follow, identities kept", function()
    local rung = ActionCache.getXrayLadder(B)[1]
    TestRunner:assertTrue(rung.result:find(enc_new, 1, true) ~= nil, "built checkpoint")
    TestRunner:assertEqual(rung.merged_from[1].file, NEW_A, "its ledger")
    TestRunner:assertEqual(rung.timestamp, 11111, "its identity")
    TestRunner:assertEqual(rung.edited_at, nil, "not marked edited")
    local cp = ActionCache.getXrayCheckpoints(B)[1]
    TestRunner:assertTrue(cp.result:find(enc_new, 1, true) ~= nil, "archived version")
    TestRunner:assertEqual(cp.timestamp, 10000, "its identity")
    TestRunner:assertEqual(#ActionCache.getXrayCheckpoints(B), 1, "no version archived by the sweep")
end)
TestRunner:test("pinned items name the new path", function()
    local general = dofile(PinnedManager.GENERAL_PINNED_FILE)
    TestRunner:assertEqual(general[1].document_path, NEW_A, "the general store")
    local own = dofile(PinnedManager.getPath(NEW_A))
    TestRunner:assertEqual(own[1].document_path, NEW_A, "the moved book's own pins")
    -- (read raw: the store's long strings carry their guard newline)
    TestRunner:assertEqual((own[1].result:gsub("\n$", "")), "own pin", "content kept")
end)
TestRunner:test("a book that names nobody moved is not rewritten; no temp file left", function()
    TestRunner:assertEqual(readFile(ActionCache.getPath(C)), c_before, "byte for byte")
    TestRunner:assertEqual(readFile(ActionCache.getPath(B) .. ".tmp"), nil, "the cache written whole")
    TestRunner:assertEqual(readFile(ActionCache.getXrayCheckpointsPath(B) .. ".tmp"), nil, "the versions too")
end)
TestRunner:test("a finished merge still reads as done", function()
    TestRunner:assertTrue(XrayMerge.hasFolded(ActionCache.getXrayCache(B), "Series 1", NEW_A),
        "found at the new path")
end)

print("\n  [moves before the sweep]")
TestRunner:test("a book moved twice maps to its last path; a group's book is swept too", function()
    local P1, P2, P3 = TMP .. "/p1/D.epub", TMP .. "/p2/D.epub", TMP .. "/p3/D.epub"
    local E = TMP .. "/Grouped.epub"
    assert(ActionCache.set(E, "xray", xrayNaming(P1), 0.5, { timestamp = 444 }))
    -- E is not in the artifact index: only the group reaches it
    groups = { { books = { E, P3 } } }
    XrayMerge.noteMoved(P1, P2)
    XrayMerge.noteMoved(P2, P3)
    XrayMerge._sweepMoves(true)
    local data = json.decode(ActionCache.get(E, "xray").result)
    TestRunner:assertEqual(data.__dormant[1].file, P3, "P1 -> P2 -> P3")
end)
TestRunner:test("two books trading places in one batch: each link moves once, by its own move", function()
    local V1, V2, V3 = TMP .. "/s/Vol 1.epub", TMP .. "/s/Vol 2.epub", TMP .. "/s/Vol 3.epub"
    local G = TMP .. "/Vol 4.epub"
    local both = json.encode({ __dormant = {
        { name = "One", file = V1 }, { name = "Two", file = V2 },
    } })
    assert(ActionCache.set(G, "xray", both, 0.5, { timestamp = 666,
        merged_from = { { title = "Vol 1", file = V1 }, { title = "Vol 2", file = V2 } } }))
    groups = { { books = { G, V2, V3 } } }
    -- Vol 2 renamed to Vol 3, then Vol 1 to Vol 2, before the sweep
    XrayMerge.noteMoved(V2, V3)
    XrayMerge.noteMoved(V1, V2)
    XrayMerge._sweepMoves(true)
    local entry = ActionCache.get(G, "xray")
    local data = json.decode(entry.result)
    TestRunner:assertEqual(data.__dormant[1].file, V2, "Vol 1's link is Vol 2 now")
    TestRunner:assertEqual(data.__dormant[2].file, V3, "Vol 2's link is Vol 3 now")
    TestRunner:assertEqual(entry.merged_from[1].file, V2, "ledger: Vol 1")
    TestRunner:assertEqual(entry.merged_from[2].file, V3, "ledger: Vol 2")
end)

print("\n  [a folder moved or renamed (B507)]")
TestRunner:test("every book inside follows: links from outside, siblings' links, pins; a folder named alike stays", function()
    local OLD_DIR, NEW_DIR = TMP .. "/fold/Saga", TMP .. "/fold/Saga (complete)"
    local V1, V2 = OLD_DIR .. "/Vol 1.epub", OLD_DIR .. "/Vol 2.epub"
    local ALIKE = TMP .. "/fold/Saga 2/Other.epub"
    local READER = TMP .. "/Reader.epub"
    os.execute(string.format("mkdir -p %q %q", OLD_DIR, TMP .. "/fold/Saga 2"))
    -- Vol 2 names its sibling; the reader outside names Vol 1 (once escaped,
    -- as KOReader's encoder writes it) and the book in the folder named alike
    assert(ActionCache.set(V2, "xray", xrayNaming(V1), 0.5, { timestamp = 701,
        merged_from = { { title = "Vol 1", file = V1 } } }))
    local reader_json = '{"__dormant":[{"name":"Ann","file":"' .. esc(V1) .. '"},'
        .. '{"name":"Cy","file":"' .. ALIKE .. '"}],"characters":[]}'
    assert(ActionCache.set(READER, "xray", reader_json, 0.5, { timestamp = 702,
        merged_from = { { title = "Vol 1", file = V1 }, { title = "Other", file = ALIKE } } }))
    assert(PinnedManager.addPin(V1, { id = "p3", result = "pin in the folder", document_path = V1, timestamp = 3 }))
    groups = {}
    -- KOReader moves the folder whole (each .sdr inside it goes along), and
    -- the plugin's indexes are re-keyed first (StorageRegistry.followFolderMove)
    assert(os.rename(OLD_DIR, NEW_DIR))
    local N1, N2 = NEW_DIR .. "/Vol 1.epub", NEW_DIR .. "/Vol 2.epub"
    G_reader_settings._store.koassistant_artifact_index = {
        [READER] = { count = 1, modified = 702 }, [N2] = { count = 1, modified = 701 },
    }
    G_reader_settings._store.koassistant_pinned_index = { [N1] = { count = 1 } }
    XrayMerge.noteMoved(OLD_DIR, NEW_DIR, true)
    XrayMerge._sweepMoves(true)
    local reader = ActionCache.get(READER, "xray")
    local data = json.decode(reader.result)
    TestRunner:assertEqual(data.__dormant[1].file, N1, "a link from outside the folder")
    TestRunner:assertTrue(reader.result:find('"' .. esc(N1) .. '"', 1, true) ~= nil, "written back escaped")
    TestRunner:assertEqual(data.__dormant[2].file, ALIKE, "the folder named alike is another folder")
    TestRunner:assertEqual(reader.merged_from[1].file, N1, "ledger: the moved book")
    TestRunner:assertEqual(reader.merged_from[2].file, ALIKE, "ledger: the other one as it was")
    local sibling = ActionCache.get(N2, "xray")
    TestRunner:assertEqual(json.decode(sibling.result).__dormant[1].file, N1, "a sibling's link inside the folder")
    TestRunner:assertEqual(sibling.merged_from[1].file, N1, "its ledger")
    TestRunner:assertEqual(sibling.timestamp, 701, "identity kept")
    local own = dofile(PinnedManager.getPath(N1))
    TestRunner:assertEqual(own[1].document_path, N1, "a pin of a book inside the folder")
end)
TestRunner:test("a book moved, then its folder renamed, before the sweep: the link ends under the new name", function()
    local P_OLD, MID_DIR, END_DIR = TMP .. "/c1/P.epub", TMP .. "/c2", TMP .. "/c3"
    local Q_OLD, Q_END = TMP .. "/d1/Q.epub", TMP .. "/e/Q.epub"
    local LINKS = TMP .. "/Links.epub"
    assert(ActionCache.set(LINKS, "xray", json.encode({ __dormant = {
        { name = "P", file = P_OLD }, { name = "Q", file = Q_OLD },
    } }), 0.5, { timestamp = 801 }))
    G_reader_settings._store.koassistant_artifact_index = { [LINKS] = { count = 1, modified = 801 } }
    groups = {}
    XrayMerge.noteMoved(P_OLD, MID_DIR .. "/P.epub")     -- the book
    XrayMerge.noteMoved(MID_DIR, END_DIR, true)           -- then its folder
    XrayMerge.noteMoved(TMP .. "/d1", TMP .. "/d2", true) -- a folder
    XrayMerge.noteMoved(TMP .. "/d2/Q.epub", Q_END)       -- then a book out of it
    XrayMerge._sweepMoves(true)
    local data = json.decode(ActionCache.get(LINKS, "xray").result)
    TestRunner:assertEqual(data.__dormant[1].file, END_DIR .. "/P.epub", "book, then folder")
    TestRunner:assertEqual(data.__dormant[2].file, Q_END, "folder, then book")
end)

-- Restore what this file replaced (one Lua process runs every suite)
PinnedManager.GENERAL_PINNED_FILE, PinnedManager.LIBRARY_PINNED_FILE = had_general, had_library
UIManager.unschedule = had_unschedule
_G.G_reader_settings = saved_settings
for name, mod in pairs(saved_loaded) do package.loaded[name] = mod end
os.execute(string.format("rm -rf %q", TMP))

local ok = TestRunner:summary()
return ok
