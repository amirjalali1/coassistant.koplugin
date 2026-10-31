--[[
Unit tests: carried entries follow the groups (B536).

The free carry is mechanical, so what a book holds of it follows its groups as
they are now: a carried row or a history line from a book it no longer takes
from goes when a book leaves, the group is deleted, the books are reordered or
the kind changes. What an AI merge brought stays, and so do a row carried by
hand and the lines of an entry added by hand from the carried list.

The flows run the real seed (XrayMerge.reseedGroup / refreshCarried) over a
real BookGroups store in memory, three invented books, the live X-Rays kept in
a table and the write-back replaced by a function that stores the result: the
same calls main.lua's debounced run makes after a group hook fires.

Run: lua tests/unit/test_xray_carry_groups.lua  (auto-discovered by run_tests.lua --unit)
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
require("mock_koreader")

_G.G_reader_settings = _G.G_reader_settings or {
    _store = {},
    readSetting = function(self, key, default)
        local v = self._store[key]
        if v == nil then return default end
        return v
    end,
    saveSetting = function(self, key, value) self._store[key] = value end,
    flush = function() end,
}
package.loaded["docsettings"] = package.loaded["docsettings"] or {
    getSidecarDir = function(_self, _doc_path, _force) return "/tmp" end,
    isHashLocationEnabled = function() return false end,
}
package.loaded["util"] = package.loaded["util"] or { makePath = function() end }
package.loaded["luasettings"] = package.loaded["luasettings"] or {
    open = function() return { readSetting = function() return nil end, close = function() end } end,
}

-- A fresh groups module over an in-memory store (restored at the end: the
-- suite runs every file in one process)
local orig_groups_mod = package.loaded["koassistant.books.book_groups"]
package.loaded["koassistant.books.book_groups"] = nil
local BookGroups = require("koassistant.books.book_groups")
local mem = {}
BookGroups._setStoreForTests({
    readSetting = function(_self, key) return mem[key] end,
    saveSetting = function(_self, key, value) mem[key] = value end,
    flush = function() end,
})
-- Paths under /s/ are books on this device; anything else is another
-- device's path (or a book gone from disk)
BookGroups.fileExists = function(p) return type(p) == "string" and p:sub(1, 3) == "/s/" end

local json = require("json")
local XrayParser = require("koassistant.xray.xray_parser")
local XrayMerge = require("koassistant.xray.xray_merge")
local ActionCache = require("koassistant.artifacts.action_cache")
local WriteBack = require("koassistant.xray.artifact_writeback")
local TestRunner = require("test_runner"):new()

local A, B, C = "/s/a.epub", "/s/b.epub", "/s/c.epub"

local BOOKS = {
    [A] = [[{"type":"fiction","characters":[
        {"name":"Arlen Voss","description":"A's Arlen."},
        {"name":"Shared One","description":"A's Shared."}],
      "locations":[{"name":"Amber Hall","description":"A's hall."}]}]],
    [B] = [[{"type":"fiction","characters":[
        {"name":"Bryn Hale","description":"B's Bryn."},
        {"name":"Shared One","description":"B's Shared."}]}]],
    [C] = [[{"type":"fiction","characters":[
        {"name":"Cato Mire","description":"C's Cato."},
        {"name":"Shared One","description":"C's Shared."}]}]],
}

local caches, promoted, writes = {}, {}, {}
local orig = {
    getXrayCache = ActionCache.getXrayCache,
    getPromotedStubs = ActionCache.getPromotedStubs,
    getRemovedStubs = ActionCache.getRemovedStubs,
    editLiveXray = WriteBack.editLiveXray,
}
ActionCache.getXrayCache = function(file) return caches[file] end
ActionCache.getPromotedStubs = function(file) return promoted[file] or {} end
ActionCache.getRemovedStubs = function() return {} end
WriteBack.editLiveXray = function(file, apply_fn)
    local entry = caches[file]
    if not (entry and entry.result) then return false, "no_xray" end
    local data = XrayParser.parse(entry.result)
    if not apply_fn(data) then return false, "stale" end
    entry.result = json.encode(data)
    writes[#writes + 1] = file
    return true, nil, data
end

-- Fresh books, a fresh store, one group of the given kind
local function reset(kind, books)
    for k in pairs(mem) do mem[k] = nil end
    caches, promoted, writes = {}, {}, {}
    for _idx, p in ipairs({ A, B, C }) do
        caches[p] = { result = BOOKS[p], timestamp = 1, progress_decimal = 0.5 }
    end
    local g = BookGroups.create("Saga")
    for _idx, p in ipairs(books or { A, B, C }) do BookGroups.addBook(g.id, p) end
    BookGroups.setKind(g.id, kind or BookGroups.KIND_SERIES)
    return g
end

-- The run main.lua makes after a hook: the group's members, then single books
-- (explicit = a leave or a delete asked for them, not a mere write)
local function run(group_id, changed, single, explicit)
    writes = {}
    local memo, done = {}, {}
    local group = group_id and BookGroups.byId(group_id)
    if group then
        XrayMerge.reseedGroup(group, {}, nil, nil, { changed = changed, memo = memo, done = done })
    end
    for _idx, p in ipairs(single or {}) do
        XrayMerge.refreshCarried(p, {}, nil, nil, { memo = memo, done = done, explicit = explicit })
    end
    return #writes
end

local function parsed(file) return XrayParser.parse(caches[file].result) end

-- "name@file" of every carried row
local function rows(file)
    local out = {}
    for _idx, s in ipairs(parsed(file)[XrayParser.DORMANT_KEY] or {}) do
        out[s.name .. "@" .. tostring(s.file)] = true
    end
    return out
end

local function count(set)
    local n = 0
    for _k in pairs(set) do n = n + 1 end
    return n
end

-- The books an entry's history lines come from
local function lines(file, name)
    local out = {}
    for _idx, item in ipairs(parsed(file).characters or {}) do
        if item.name == name then
            for _i, b in ipairs(item.background or {}) do out[tostring(b.file)] = true end
        end
    end
    return out
end

print("Running: test_xray_carry_groups")
print("")
print("  [the seed today, the starting point of every flow]")

TestRunner:test("a series seeds forward: the second book carries the first, the third both", function()
    local g = reset()
    TestRunner:assertTrue(run(g.id, true) >= 2, "the second and third books written")
    local b, c = rows(B), rows(C)
    TestRunner:assertTrue(b["Arlen Voss@" .. A] and b["Amber Hall@" .. A], "book 2 carries book 1's entries")
    TestRunner:assertTrue(c["Bryn Hale@" .. B], "book 3 carries book 2's")
    TestRunner:assertTrue(c["Arlen Voss@" .. A], "and book 1's through book 2's list")
    TestRunner:assertTrue(lines(C, "Shared One")[B] and lines(C, "Shared One")[A],
        "an entry book 3 shares gets a line from each earlier book")
    TestRunner:assertEqual(count(rows(A)), 0, "book 1 carries nothing")
    TestRunner:assertEqual(run(g.id, true), 0, "a second run writes nothing")
end)

print("")
print("  [B536: carried entries follow the group]")

TestRunner:test("a book leaves: the books after it drop its entries, and it drops theirs", function()
    local g = reset()
    run(g.id, true)
    BookGroups.removeBook(g.id, B)
    run(g.id, true, { B }, true)
    local c = rows(C)
    TestRunner:assertTrue(c["Bryn Hale@" .. B] == nil, "book 3 no longer carries the book that left")
    TestRunner:assertTrue(c["Arlen Voss@" .. A] and c["Amber Hall@" .. A], "book 1's entries stay")
    TestRunner:assertTrue(lines(C, "Shared One")[B] == nil, "its history line on a shared entry goes")
    TestRunner:assertTrue(lines(C, "Shared One")[A], "book 1's line stays")
    TestRunner:assertEqual(count(rows(B)), 0, "the book that left carries nothing")
    TestRunner:assertEqual(count(lines(B, "Shared One")), 0, "and keeps no history line from the group")
    TestRunner:assertEqual(parsed(C).characters[1].name, "Cato Mire", "the book's own entries untouched")
    TestRunner:assertEqual(run(g.id, true, { B }, true), 0, "nothing more to do on a second run")
    -- Back in the group (at the end now): it carries what comes before it
    BookGroups.addBook(g.id, B)
    run(g.id, true)
    local b = rows(B)
    TestRunner:assertTrue(b["Cato Mire@" .. C] and b["Arlen Voss@" .. A], "re-added at the end, it carries both again")
    TestRunner:assertTrue(rows(C)["Bryn Hale@" .. B] == nil, "and book 3, now before it, does not carry it")
end)

TestRunner:test("a reorder: a book now later is no longer carried (no spoilers)", function()
    local g = reset()
    run(g.id, true)
    BookGroups.moveBookTo(g.id, B, 3) -- A, C, B
    run(g.id, true)
    local c = rows(C)
    TestRunner:assertTrue(c["Bryn Hale@" .. B] == nil, "the book moved after it leaves its list")
    TestRunner:assertTrue(lines(C, "Shared One")[B] == nil, "and its line")
    TestRunner:assertTrue(c["Arlen Voss@" .. A], "the first book's entries stay")
    TestRunner:assertTrue(rows(B)["Cato Mire@" .. C], "the moved book now carries the one before it")
end)

TestRunner:test("project to series: a book keeps only the books before it", function()
    local g = reset(BookGroups.KIND_PROJECT)
    run(g.id, true)
    TestRunner:assertTrue(rows(A)["Cato Mire@" .. C], "in a project the first book carries the others")
    BookGroups.setKind(g.id, BookGroups.KIND_SERIES)
    run(g.id, true)
    TestRunner:assertEqual(count(rows(A)), 0, "as a series the first book carries nothing")
    TestRunner:assertTrue(count(lines(A, "Shared One")) == 0, "and keeps no line from the later books")
    local b = rows(B)
    TestRunner:assertTrue(b["Arlen Voss@" .. A] and b["Cato Mire@" .. C] == nil, "the second keeps the first, not the third")
end)

TestRunner:test("series to plain: nothing is carried any more", function()
    local g = reset()
    run(g.id, true)
    BookGroups.setKind(g.id, BookGroups.KIND_PLAIN)
    run(g.id, true)
    TestRunner:assertEqual(count(rows(B)) + count(rows(C)), 0, "every carried row goes")
    TestRunner:assertEqual(count(lines(C, "Shared One")), 0, "and every history line")
end)

TestRunner:test("the group deleted: its books stop carrying each other", function()
    local g = reset()
    run(g.id, true)
    BookGroups.remove(g.id)
    run(nil, false, { A, B, C }, true)
    TestRunner:assertEqual(count(rows(B)) + count(rows(C)), 0, "every carried row goes")
    TestRunner:assertEqual(count(lines(B, "Shared One")) + count(lines(C, "Shared One")), 0, "and every history line")
end)

print("")
print("  [what stays]")

TestRunner:test("what an AI merge brought stays when its book leaves", function()
    local g = reset()
    run(g.id, true)
    caches[C].merged_from = { { file = B, title = "b", at = 1 } } -- book 3 AI merged book 2
    BookGroups.removeBook(g.id, B)
    run(g.id, true, { B }, true)
    TestRunner:assertTrue(rows(C)["Bryn Hale@" .. B], "the merged book's entries stay on the list")
    TestRunner:assertTrue(lines(C, "Shared One")[B], "and its history line")
end)

TestRunner:test("a row carried by hand stays; the rest of that book's carry goes", function()
    local g = reset()
    run(g.id, true)
    local data = parsed(B)
    for _idx, s in ipairs(data[XrayParser.DORMANT_KEY]) do
        if s.name == "Arlen Voss" then s.by_hand = true end
    end
    caches[B].result = json.encode(data)
    BookGroups.removeBook(g.id, B)
    run(g.id, true, { B }, true)
    local b = rows(B)
    TestRunner:assertTrue(b["Arlen Voss@" .. A], "the hand-carried row stays")
    TestRunner:assertTrue(b["Amber Hall@" .. A] == nil, "the automatic one goes")
end)

TestRunner:test("carryOne marks its row, and a seed refresh keeps the mark", function()
    local data = XrayParser.parse(BOOKS[C])
    XrayMerge.carryOne(data, { name = "Arlen Voss", description = "A's Arlen." }, "characters",
        { source = "a", file = A })
    local stub = data[XrayParser.DORMANT_KEY][1]
    TestRunner:assertTrue(stub.by_hand == true, "the reader's pick is marked")
    XrayMerge.populateDormant(data, nil, XrayParser.parse(BOOKS[A]), "a", A, nil, C, nil, true)
    for _idx, s in ipairs(data[XrayParser.DORMANT_KEY]) do
        if s.name == "Arlen Voss" then
            TestRunner:assertTrue(s.by_hand == true, "the automatic refresh of the same row keeps it")
        end
    end
end)

TestRunner:test("an entry added by hand from the carried list keeps its lines", function()
    local g = reset()
    run(g.id, true)
    promoted[B] = { ["shared one"] = "Shared One" }
    BookGroups.removeBook(g.id, B)
    run(g.id, true, { B }, true)
    TestRunner:assertTrue(lines(B, "Shared One")[A], "the hand-added entry's line stays")
end)

print("")
print("  [the rule: XrayMerge.carryRule]")

TestRunner:test("cannot judge: kept; a later book: dropped unless merged by this book", function()
    reset()
    local keep = XrayMerge.carryRule(B, { entry_of = function(p) return caches[p] end })
    TestRunner:assertTrue(keep(A, "a"), "an earlier book")
    TestRunner:assertTrue(not keep(C, "c"), "a later book")
    TestRunner:assertTrue(keep("/other/device/a.epub", "a"), "another device's path: kept")
    TestRunner:assertTrue(keep(nil, "?"), "an unattributable line: kept")
    TestRunner:assertTrue(keep(nil, "a"), "a line from before files were recorded, of an earlier book (by title)")
    TestRunner:assertTrue(not keep(nil, "c"), "of a later one: dropped")
    TestRunner:assertTrue(not keep(B, "b"), "the book itself: dropped")
    caches[B].merged_from = { { file = C, title = "c", at = 1 } }
    keep = XrayMerge.carryRule(B, { entry_of = function(p) return caches[p] end })
    TestRunner:assertTrue(keep(C, "c"), "a later book this book AI merged itself: kept")
end)

TestRunner:test("what a source AI merged rides on; a book in two groups keeps what either gives", function()
    local g = reset()
    local X = "/s/x.epub"
    caches[A].merged_from = { { file = X, title = "x", at = 1 } } -- book 1 AI merged an outside book
    local keep = XrayMerge.carryRule(C, { entry_of = function(p) return caches[p] end })
    TestRunner:assertTrue(keep(X, "x"), "an earlier book's AI merge reaches the later books")
    caches[A].merged_from = nil
    local Y = "/s/y.epub"
    local p = BookGroups.create("Shelf")
    BookGroups.addBook(p.id, C)
    BookGroups.addBook(p.id, Y)
    BookGroups.setKind(p.id, BookGroups.KIND_PROJECT)
    keep = XrayMerge.carryRule(C, { entry_of = function(q) return caches[q] end })
    TestRunner:assertTrue(keep(Y, "y") and keep(A, "a"), "both groups' books")
    keep = XrayMerge.carryRule(A, { entry_of = function(q) return caches[q] end })
    TestRunner:assertTrue(not keep(Y, "y"), "never through a book that comes after it in its series")
    BookGroups.remove(g.id)
end)

print("")
print("  [the review's cases]")

local orig_checkpoints = ActionCache.getXrayCheckpoints
local orig_ladder = ActionCache.getXrayLadder

TestRunner:test("an AI merge an update dropped from the record is read back from an archived version", function()
    local g = reset()
    run(g.id, true)
    -- the live entry lost its record (an update wrote it without one); the
    -- version archived before that update still has it
    ActionCache.getXrayCheckpoints = function(file)
        if file == C then return { { result = "{}", merged_from = { { file = B, title = "b" } } } } end
        return {}
    end
    ActionCache.getXrayLadder = function() return {} end
    BookGroups.removeBook(g.id, B)
    run(g.id, true, { B }, true)
    ActionCache.getXrayCheckpoints, ActionCache.getXrayLadder = orig_checkpoints, orig_ladder
    TestRunner:assertTrue(rows(C)["Bryn Hale@" .. B], "the merged book's row stays")
    TestRunner:assertTrue(lines(C, "Shared One")[B], "and its line")
end)

TestRunner:test("a source's own hand-carried row the target may not hold: not seeded, no rewrite every run", function()
    local g = reset()
    run(g.id, true)
    local X = "/s/x.epub"
    local data = parsed(B)
    data[XrayParser.DORMANT_KEY] = data[XrayParser.DORMANT_KEY] or {}
    table.insert(data[XrayParser.DORMANT_KEY], { name = "Xan Orr", category = "characters",
        description = "From an outside book.", source = "x", file = X, by_hand = true })
    caches[B].result = json.encode(data)
    run(g.id, true)
    TestRunner:assertTrue(rows(B)["Xan Orr@" .. X], "the book that carried it by hand keeps it")
    TestRunner:assertTrue(rows(C)["Xan Orr@" .. X] == nil, "the book after it does not get it")
    TestRunner:assertEqual(run(g.id, true), 0, "and nothing is rewritten on the next run")
end)

TestRunner:test("a source another of its groups puts after the book gives nothing", function()
    local g = reset()
    run(g.id, true)
    -- a project listed first holds book 1 and book 3, which the series puts
    -- after book 1: the project's seed would hand book 1 book 3's entries
    local p = BookGroups.create("Shelf")
    BookGroups.addBook(p.id, A)
    BookGroups.addBook(p.id, C)
    BookGroups.setKind(p.id, BookGroups.KIND_PROJECT)
    BookGroups.moveGroupTo(p.id, 1)
    run(g.id, true)
    run(p.id, true)
    TestRunner:assertEqual(run(g.id, true) + run(p.id, true), 0, "nothing rewritten on the next runs")
    TestRunner:assertTrue(rows(A)["Cato Mire@" .. C] == nil, "book 1 never carries book 3, which comes after it in the series")
    BookGroups.remove(p.id)
end)

TestRunner:test("a row whose book is refused keeps the lines of a book still allowed, filed under it", function()
    local g = reset()
    run(g.id, true)
    local D = "/s/d.epub"
    caches[C].merged_from = { { file = A, title = "a" } }
    local data = parsed(C)
    table.insert(data[XrayParser.DORMANT_KEY], { name = "Eda Moss", category = "characters",
        description = "D's Eda.", source = "d", file = D,
        background = { { source = "a", text = "What the AI merge of book 1 said.", file = A } } })
    caches[C].result = json.encode(data)
    run(g.id, true)
    local kept
    for _idx, s2 in ipairs(parsed(C)[XrayParser.DORMANT_KEY] or {}) do
        if s2.name == "Eda Moss" then kept = s2 end
    end
    TestRunner:assertTrue(kept ~= nil, "the row stays")
    TestRunner:assertEqual(kept and kept.file, A, "filed under the allowed book")
    TestRunner:assertTrue(kept and kept.description == nil, "without what the refused book said")
end)

TestRunner:test("an old line whose title names no book here is kept; one naming a book a group holds goes", function()
    reset()
    local keep = XrayMerge.carryRule(C, { entry_of = function(p) return caches[p] end })
    TestRunner:assertTrue(keep(nil, "A Book Renamed Long Ago"), "an unknown title: kept")
    BookGroups.addBook(BookGroups.create("Other").id, "/s/z.epub")
    keep = XrayMerge.carryRule(C, { entry_of = function(p) return caches[p] end })
    TestRunner:assertTrue(not keep(nil, "z"), "the title of a book another group holds, not this one's: dropped")
end)

TestRunner:test("after a mere write, a device that keeps no groups prunes nothing (another device's books)", function()
    local g = reset()
    run(g.id, true)
    BookGroups.remove(g.id)
    TestRunner:assertEqual(run(nil, false, { B, C }, false), 0, "no write")
    TestRunner:assertTrue(count(rows(C)) > 0, "the carried rows stay")
    run(nil, false, { B, C }, true)
    TestRunner:assertEqual(count(rows(C)), 0, "the delete itself (explicit) prunes")
end)

-- Restore what this file replaced
ActionCache.getXrayCache = orig.getXrayCache
ActionCache.getPromotedStubs = orig.getPromotedStubs
ActionCache.getRemovedStubs = orig.getRemovedStubs
WriteBack.editLiveXray = orig.editLiveXray
package.loaded["koassistant.books.book_groups"] = orig_groups_mod

return TestRunner:summary()
