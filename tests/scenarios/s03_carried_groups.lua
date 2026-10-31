-- B536, carried entries follow the group, on the real reader with the
-- plugin's own hooks: Mock Series 2 leaves the series and comes back, the
-- series turns plain and back, then the project is deleted (its second book
-- records an AI merge of the first, which stays). The group edits are the
-- ones the Group Hub makes (BookGroups), in the run's own home.
local S = dofile(os.getenv("KOA_PLUGIN") .. "/tests/scenarios/boot.lua")
S.features({ xray_marking_density = "all" })

local ui = S.open("Mock Series 3")
local BookGroups = require("koassistant.books.book_groups")
local XrayParser = require("koassistant.xray.xray_parser")
local ActionCache = require("koassistant.artifacts.action_cache")
local V2, V3 = S.book("Mock Series 2"), ui.document.file
local PA, PB = S.book("Mock Project A"), S.book("Mock Project B")

local function group(name)
    for _idx, g in ipairs(BookGroups.all()) do
        if g.name == name then return g end
    end
end
local series, project = group("Mock Series"), group("Mock Project")
S.check(series and project, "the fixture's groups are in the run's home")

-- name -> the book its row comes from, for a book's carried list
local function carried(file)
    local out, n = {}, 0
    local entry = ActionCache.getXrayCache(file)
    local data = entry and XrayParser.parse(entry.result) or {}
    for _idx, s in ipairs(data[XrayParser.DORMANT_KEY] or {}) do
        out[s.name] = s.file
        n = n + 1
    end
    return out, n
end
local function from(file, book)
    local n = 0
    for _name, f in pairs((carried(file))) do
        if f == book then n = n + 1 end
    end
    return n
end
local function lineFrom(file, name, book)
    local data = XrayParser.parse(ActionCache.getXrayCache(file).result)
    for _idx, cat in ipairs(XrayParser.getCategories(data)) do
        for _i, item in ipairs(cat.items or {}) do
            if XrayParser.getItemName(item, cat.key) == name then
                for _b, b in ipairs(item.background or {}) do
                    if b.file == book then return true end
                end
            end
        end
    end
    return false
end
local function marked(chapter)
    S.chapter(chapter)
    local out = {}
    for _idx, m in ipairs(S.marks()) do out[m.name] = true end
    return out
end

-- ── As generated ──
local v1 = S.book("Mock Series 1")
S.check(from(V3, V2) > 0 and from(V3, v1) > 0, "book 3 carries books 2 and 1")
local m = marked("A Face From the Water")
S.check(m["Elias Penrose"] and m["Saltmere"], "Elias Penrose (book 2) and Saltmere are underlined")

-- ── An earlier book's entry of another kind than this book's ──
-- (book 2's character "the Warden", alias "Warden"; book 3's term "Warden"):
-- found by the X-Ray's search, its read-only view says it is on the carried
-- list, not "already in this book's X-Ray"
local XrayBrowser = require("koassistant.xray.xray_browser")
local view_data = XrayParser.parse(ActionCache.getXrayCache(V3).result)
XrayParser.mergeUserAliases(view_data, ActionCache.matchOverlay(V3))
XrayBrowser:show(view_data, { title = "Mock Series 3 - The Orchard", book_file = V3, plugin = S.plugin,
    configuration = S.plugin.configuration, enable_emoji = false }, ui)
S.settle()
XrayBrowser:showSearchResults("Warden")
S.settle()
local verdict
-- the rows under "From Mock Series 2 - The Ferry" are indented
for _idx, it in ipairs(S.top().item_table or {}) do
    if it.text == "  the Warden" and it.callback then
        it.callback()
        S.settle()
        verdict = table.concat(S.texts(), " | ")
        break
    end
end
S.note("book 2's \"the Warden\":", tostring(verdict))
S.check(verdict and verdict:find("Already on this book's carried list", 1, true) ~= nil
    and not verdict:find("Already in this book's X-Ray", 1, true),
    "book 2's character \"the Warden\" is on the carried list, not this book's term \"Warden\"")
S.closeAll()

-- ── Book 2 leaves the series ──
BookGroups.removeBook(series.id, V2)
S.settle()
S.check(from(V3, V2) == 0, "book 3 no longer carries the book that left")
S.check(from(V3, v1) > 0, "book 1's entries stay")
S.check(carried(V3)["Zeph Umber"] == v1, "book 3 now takes from book 1 directly (Zeph Umber)")
S.check(lineFrom(V3, "Oswin Tarr", V2), "the entry added by hand keeps its book 2 line")
S.check(lineFrom(V3, "Tamsin Vael", v1), "Tamsin Vael keeps her book 1 line")
local _left, left_n = carried(V2)
S.check(left_n == 0, "the book that left carries nothing")
m = marked("A Face From the Water")
S.check(not m["Elias Penrose"], "Elias Penrose is no longer underlined")
S.check(m["Saltmere"], "Saltmere still is (book 1 has it)")
S.shot("book2_left")

-- ── Back at its place ──
BookGroups.addBook(series.id, V2)
S.settle()
S.check(from(V3, V2) == 0, "added back at the end, after book 3: still not carried")
BookGroups.moveBookTo(series.id, V2, 2)
S.settle()
S.check(from(V3, V2) > 0, "moved back to second place: carried again")
m = marked("A Face From the Water")
S.check(m["Elias Penrose"], "and Elias Penrose is underlined again")

-- ── Plain, then series again ──
BookGroups.setKind(series.id, BookGroups.KIND_PLAIN)
S.settle()
local _p, plain_n = carried(V3)
S.check(plain_n == 0, "a plain group: book 3 carries nothing")
S.check(not lineFrom(V3, "Tamsin Vael", v1), "and Tamsin Vael's book 1 line goes")
BookGroups.setKind(series.id, BookGroups.KIND_SERIES)
S.settle()
S.check(from(V3, V2) > 0 and from(V3, v1) > 0, "a series again: books 1 and 2 carried again")

-- ── The project deleted: the AI merge stays ──
S.check(carried(PB)["Maren Kessler"] == PA, "Project B carries Maren Kessler from Project A")
BookGroups.remove(project.id)
S.settle()
S.check(carried(PB)["Maren Kessler"] == PA,
    "deleted group: Project B keeps it, its X-Ray records an AI merge of Project A")
S.check(from(PA, PB) == 0, "Project A, which merged nothing, carries nothing from B")

-- ── A checkpoint install keeps the AI-merge record of the version it replaces ──
local live = ActionCache.getXrayCache(V3)
local meta = {}
for k, v in pairs(live) do meta[k] = v end
meta.result = nil
meta.merged_from = { { file = V2, title = "Mock Series 2 - The Ferry", at = 1 } }
meta.merged_from_books = "Mock Series 2 - The Ferry"
ActionCache.setXrayCache(V3, live.result, live.progress_decimal, meta)
local rung = (ActionCache.getXrayLadder(V3) or {})[1]
S.check(rung ~= nil, "book 3 has a built checkpoint")
if rung then
    ActionCache.promoteXrayLadderRung(V3, rung, 0)
    local after = ActionCache.getXrayCache(V3)
    S.check(after.merged_from and after.merged_from[1] and after.merged_from[1].file == V2,
        "the install keeps the record of the AI merge the replaced version held")
end
S.settle()

S.finish()
