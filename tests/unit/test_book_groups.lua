--[[
Unit tests: Book groups store (koassistant_book_groups.lua) — item 46, #90.

CRUD, manual ordering, first-group neighbor rule, move re-keying policy
(move re-keys / copy never joins / delete keeps), and the merge picker's
earlier-feeds-later candidate ordering.

Run: lua tests/unit/test_book_groups.lua  (auto-discovered by run_tests.lua --unit)
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

package.loaded["koassistant_book_groups"] = nil
local BookGroups = require("koassistant_book_groups")

-- Functional in-memory store (the real one is LuaSettings over a settings-dir file)
local mem = {}
BookGroups._setStoreForTests({
    readSetting = function(_self, key) return mem[key] end,
    saveSetting = function(_self, key, value) mem[key] = value end,
    flush = function() end,
})

local TestRunner = require("test_runner"):new()

print("Running: test_book_groups")
print("")
print("  [store CRUD + ordering]")

TestRunner:test("create / rename / delete round-trip", function()
    local g = BookGroups.create("Wheel of Time")
    TestRunner:assertEqual(g.name, "Wheel of Time", "name stored")
    TestRunner:assertTrue(g.id ~= nil, "id assigned")
    TestRunner:assertEqual(#BookGroups.all(), 1, "listed")
    TestRunner:assertTrue(BookGroups.rename(g.id, "WoT"), "rename ok")
    TestRunner:assertEqual(BookGroups.byId(g.id).name, "WoT", "rename persisted")
    TestRunner:assertTrue(BookGroups.remove(g.id), "delete ok")
    TestRunner:assertEqual(#BookGroups.all(), 0, "gone")
    TestRunner:assertEqual(BookGroups.rename("nope", "x"), false, "rename unknown id fails")
end)

TestRunner:test("addBook: order = add order, duplicates refused", function()
    local g = BookGroups.create("Series")
    TestRunner:assertTrue(BookGroups.addBook(g.id, "/b1.epub"), "add 1")
    TestRunner:assertTrue(BookGroups.addBook(g.id, "/b2.epub"), "add 2")
    TestRunner:assertEqual(BookGroups.addBook(g.id, "/b1.epub"), false, "dup refused")
    local books = BookGroups.byId(g.id).books
    TestRunner:assertEqual(#books, 2, "two members")
    TestRunner:assertEqual(books[1], "/b1.epub", "order kept")
    BookGroups.remove(g.id)
end)

TestRunner:test("moveBook: up/down with clamping", function()
    local g = BookGroups.create("S")
    BookGroups.addBook(g.id, "/a"); BookGroups.addBook(g.id, "/b"); BookGroups.addBook(g.id, "/c")
    TestRunner:assertTrue(BookGroups.moveBook(g.id, "/c", -1), "move up")
    TestRunner:assertEqual(BookGroups.byId(g.id).books[2], "/c", "c now second")
    TestRunner:assertEqual(BookGroups.moveBook(g.id, "/a", -1), false, "clamped at top")
    TestRunner:assertTrue(BookGroups.moveBook(g.id, "/a", 1), "move down")
    TestRunner:assertEqual(BookGroups.byId(g.id).books[1], "/c", "new head")
    BookGroups.remove(g.id)
end)

print("")
print("  [membership + neighbors]")

TestRunner:test("neighbors follow the FIRST containing group; predecessors in order", function()
    local g1 = BookGroups.create("First")
    local g2 = BookGroups.create("Second")
    BookGroups.addBook(g1.id, "/v1"); BookGroups.addBook(g1.id, "/v2"); BookGroups.addBook(g1.id, "/v3")
    BookGroups.addBook(g2.id, "/v2"); BookGroups.addBook(g2.id, "/x")
    local prev, next_p, group = BookGroups.neighbors("/v2")
    TestRunner:assertEqual(group.id, g1.id, "first group wins")
    TestRunner:assertEqual(prev, "/v1", "prev")
    TestRunner:assertEqual(next_p, "/v3", "next")
    local none_prev, none_next = BookGroups.neighbors("/elsewhere")
    TestRunner:assertEqual(none_prev, nil, "no group: nil prev")
    TestRunner:assertEqual(none_next, nil, "no group: nil next")
    local preds = BookGroups.predecessorsOf("/v3")
    TestRunner:assertEqual(#preds, 2, "two predecessors")
    TestRunner:assertEqual(preds[1], "/v1", "oldest first")
    TestRunner:assertEqual(#BookGroups.groupsFor("/v2"), 2, "both memberships listed")
    BookGroups.remove(g1.id); BookGroups.remove(g2.id)
end)

TestRunner:test("updateForMove: move re-keys, copy never joins, delete keeps", function()
    local g = BookGroups.create("S")
    BookGroups.addBook(g.id, "/old.epub"); BookGroups.addBook(g.id, "/other.epub")
    BookGroups.updateForMove("/old.epub", "/new.epub", true)  -- copy
    TestRunner:assertEqual(BookGroups.byId(g.id).books[1], "/old.epub", "copy: unchanged")
    BookGroups.updateForMove("/old.epub", "/new.epub", false) -- move
    TestRunner:assertEqual(BookGroups.byId(g.id).books[1], "/new.epub", "move: re-keyed")
    BookGroups.updateForMove("/other.epub", nil, false)       -- delete
    TestRunner:assertEqual(#BookGroups.byId(g.id).books, 2, "delete: membership kept")
    -- Overwrite-move onto an existing member: no duplicate
    BookGroups.updateForMove("/other.epub", "/new.epub", false)
    TestRunner:assertEqual(#BookGroups.byId(g.id).books, 1, "overwrite-move dedupes")
    BookGroups.remove(g.id)
end)

print("")
print("  [merge picker ordering (earlier feeds later)]")

TestRunner:test("orderCandidates: nearest predecessor first, then later mates, then rest", function()
    local groups = { { id = "g1", name = "Saga", books = { "/v1", "/v2", "/v3", "/v4", "/v5" } } }
    local candidates = {
        { file = "/alpha", title = "Alpha" },
        { file = "/v5", title = "Vol 5" },
        { file = "/v1", title = "Vol 1" },
        { file = "/v2", title = "Vol 2" },
        { file = "/zeta", title = "Zeta" },
    }
    local sorted = BookGroups.orderCandidates(candidates, "/v3", groups)
    TestRunner:assertEqual(sorted[1].file, "/v2", "nearest predecessor on top")
    TestRunner:assertEqual(sorted[2].file, "/v1", "older predecessor second")
    TestRunner:assertEqual(sorted[3].file, "/v5", "later mate after predecessors")
    TestRunner:assertEqual(sorted[4].file, "/alpha", "rest keeps given order")
    TestRunner:assertEqual(sorted[5].file, "/zeta", "rest keeps given order (2)")
    TestRunner:assertEqual(sorted[1].group_direction, "before", "direction annotated")
    TestRunner:assertEqual(sorted[3].group_direction, "after", "later mate flagged")
    TestRunner:assertEqual(sorted[3].group_name, "Saga", "group name annotated")
    TestRunner:assertEqual(sorted[4].group_name, nil, "non-mates unannotated")
end)

TestRunner:test("orderCandidates: group_id lens picks the ordering group (multi-group book)", function()
    local groups = {
        { id = "g1", name = "Saga", books = { "/v1", "/v2", "/shared" } },
        { id = "g2", name = "Papers", books = { "/p1", "/shared", "/p2" } },
    }
    local candidates = {
        { file = "/p2", title = "Paper 2" },
        { file = "/v1", title = "Vol 1" },
        { file = "/p1", title = "Paper 1" },
    }
    -- Lens g2: p1 is the predecessor, p2 the later mate, v1 unannotated rest
    local sorted = BookGroups.orderCandidates(candidates, "/shared", groups, "g2")
    TestRunner:assertEqual(sorted[1].file, "/p1", "g2 predecessor on top")
    TestRunner:assertEqual(sorted[1].group_name, "Papers", "annotated from the lens group")
    TestRunner:assertEqual(sorted[2].file, "/p2", "g2 later mate second")
    TestRunner:assertEqual(sorted[3].file, "/v1", "other group's mate is rest under this lens")
    TestRunner:assertEqual(sorted[3].group_name, nil, "no cross-lens annotation")
    -- No lens: first containing group (g1) wins, as before
    local candidates2 = {
        { file = "/p1", title = "Paper 1" },
        { file = "/v2", title = "Vol 2" },
    }
    local sorted2 = BookGroups.orderCandidates(candidates2, "/shared", groups)
    TestRunner:assertEqual(sorted2[1].file, "/v2", "default lens = first containing group")
end)

TestRunner:test("orderCandidates: current book in no group returns given order", function()
    local groups = { { id = "g1", name = "Saga", books = { "/v1", "/v2" } } }
    local candidates = {
        { file = "/v1", title = "Vol 1" },
        { file = "/b", title = "B" },
    }
    local sorted = BookGroups.orderCandidates(candidates, "/lonely", groups)
    TestRunner:assertEqual(sorted[1].file, "/v1", "order preserved")
    TestRunner:assertEqual(sorted[1].group_name, nil, "no annotations without a shared group")
end)

local ok = TestRunner:summary()
return ok
