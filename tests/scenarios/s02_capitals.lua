-- B533 S2 and S3, capitals on the real reader: The Drowned (Mock Series 3)
-- is written "the drowned trees" and "the Drowned" in "Rented Quiet", "the
-- Drowned" in "Instruments" and "The Grove Warden", and "the drowned rows" in
-- "What the Salt Takes". Until the name index has the book every name
-- matches any case. Once it has, the automatic capitals (S3) set The Drowned
-- to capitals only (three times mid-sentence with its capital, twice
-- without), so only "the Drowned" is underlined and counted, and KOReader's
-- own search after a mention gets the case-sensitive pattern (crengine's
-- regex engine). Any case, picked, overrides the rule; Capitals only,
-- picked, holds; back to automatic restores it. Last, the name index read
-- in the background as on a device: the page repaints on its own when it
-- lands, and a layout left from an earlier text of the book is not read.
local S = dofile(os.getenv("KOA_PLUGIN") .. "/tests/scenarios/boot.lua")
S.features({ xray_marking_density = "all" }) -- every occurrence marked

local ui = S.open("Mock Series 3")
local XrayParser = require("koassistant.xray.xray_parser")
local XrayIndex = require("koassistant.xray.xray_index")
local XrayBrowser = require("koassistant.xray.xray_browser")
local ActionCache = require("koassistant.artifacts.action_cache")
local file = ui.document.file
local total = ui.document.info.number_of_pages

local function drownedMarks(opts)
    local out = {}
    for _idx, m in ipairs(S.marks(opts)) do
        if m.name == "The Drowned" then out[#out + 1] = m.words or "?" end
    end
    return out
end
-- whether "the drowned trees" and "the Drowned" are underlined
local function cases(marks)
    local lower, cap = false, false
    for _idx, w in ipairs(marks) do
        if w:find("drowned", 1, true) then lower = true end
        if w:find("Drowned", 1, true) then cap = true end
    end
    return lower, cap
end

-- The entry as every surface reads it: the reader's names and the automatic capitals
local function theDrowned()
    local data = XrayParser.parse(ActionCache.getXrayCache(file).result)
    XrayParser.mergeUserAliases(data, ActionCache.matchOverlay(file))
    for _idx, item in ipairs(data.characters or {}) do
        if item.name == "The Drowned" then return item end
    end
end

-- The reader's pick on the names screen: "capitals", "any", or nil (automatic)
local function pick(how)
    local all = ActionCache.getUserAliases(file)
    local entry = all["The Drowned"] or { add = {}, ignore = {} }
    entry.case = how and { ["the drowned"] = how } or nil
    all["The Drowned"] = entry
    ActionCache.setUserAliases(file, all)
end

local rented = S.chapter("Rented Quiet")
local salt
for _idx, t in ipairs(ui.toc.toc or {}) do
    if t.title and t.title:find("What the Salt Takes", 1, true) then salt = t.page end
end

-- ── Before the name index has the book: any case ──
local lower, cap = cases(drownedMarks())
S.check(lower and cap, "no index yet: \"the drowned trees\" and \"the Drowned\" are both underlined")
S.shot("any_case")

-- ── The name index learns the book (the pass the marks ask for, run here
-- at once over every form of the X-Ray's names and its carried rows) ──
local data = XrayParser.parse(ActionCache.getXrayCache(file).result)
XrayParser.mergeUserAliases(data, ActionCache.getUserAliases(file))
local forms, seen = {}, {}
local function addForms(item)
    local set = XrayParser.matchTermSet(item)
    for _idx, f in ipairs(set and set.all or {}) do
        if not seen[f] then
            seen[f] = true
            forms[#forms + 1] = f
        end
    end
end
for _idx, cat in ipairs(XrayParser.getCategories(data)) do
    if not XrayParser.TEXT_MATCH_EXCLUDED[cat.key] then
        for _i, item in ipairs(cat.items or {}) do addForms(item) end
    end
end
for _idx, stub in ipairs(data[XrayParser.DORMANT_KEY] or {}) do addForms(stub) end
local stamp = XrayIndex.stamp(ui)
S.check(stamp ~= nil, "the layout has a stamp")
XrayIndex.store(file, stamp, XrayIndex.scan(ui.document, forms, 1, total))

local auto = ActionCache.autoCaps(file)
local switched = {}
for n in pairs(auto) do switched[#switched + 1] = n end
table.sort(switched)
S.note("automatic capitals:", table.concat(switched, ", "))
S.check(auto["the drowned"] == true, "the book writes \"the Drowned\" both ways: capitals only, automatically")
S.check(not auto["gil rook"] and not auto["tamsin vael"], "names never written in lowercase stay any case")

S.chapter("Rented Quiet")
lower, cap = cases(drownedMarks())
S.check(cap and not lower, "automatic: only \"the Drowned\" is underlined")
S.shot("automatic")

local item = theDrowned()
local set = XrayParser.matchTermSet(item)
S.check(set and set.caps ~= nil, "the matcher holds the capitals rule")
local layout = XrayIndex.layout(file, stamp)
local counts = XrayIndex.entityPages(layout, set, nil)
S.check(counts and counts[rented] == 1 and counts[salt] == nil,
    "automatic: the index counts one in \"Rented Quiet\", none in \"What the Salt Takes\"")

-- ── KOReader's search after a mention: the browser's pattern ──
local pattern, cased = XrayBrowser._buildSearchPattern(XrayParser.collectSearchTerms(item))
S.note("pattern:", tostring(pattern), "case-sensitive:", tostring(cased))
S.check(cased == true and type(pattern) == "string", "the session is case-sensitive with a pattern")
local flags = 0x0001
for _idx, st in ipairs(ui.search.search_types or {}) do
    if st.regex then flags = st.flags or flags end
end
local plain = ui.document:findAllText("the drowned", true, 3, 100, false, 0x00FF) or {}
local hits = pattern and ui.document:findAllText(pattern, false, 3, 100, true, flags) or {}
S.note("any-case search:", #plain, "| the pattern:", #hits)
S.check(#plain == 5, "any case, KOReader's search finds five")
S.check(#hits == 3, "the pattern, case-sensitive, finds the three \"the Drowned\"")

-- ── A mention's search window: its magnifier opens on the entry's name ──
-- (not on the reader's own last search, and never on the pattern)
ui.search.last_search_text = "orchard"
local own_type = ui.search.current_search_type
local view = XrayParser.parse(ActionCache.getXrayCache(file).result)
XrayParser.mergeUserAliases(view, ActionCache.matchOverlay(file))
XrayBrowser:show(view, { title = "Mock Series 3 - The Orchard", book_file = file, plugin = S.plugin,
    configuration = S.plugin.configuration, enable_emoji = false }, ui)
S.settle()
XrayBrowser:_gotoMentionAndSearch("characters", "The Drowned", { page = rented },
    XrayParser.collectSearchTerms(item), nil)
S.settle()
local window = ui.search.search_dialog
S.check(window ~= nil and S.UIManager:isWidgetShown(window), "a mention opens KOReader's search window")
local magnifier
for _idx, b in ipairs(window and S.buttons(window) or {}) do
    if b.button.icon == "appbar.search" then magnifier = b.button end
end
S.check(magnifier ~= nil, "the search window has its magnifier")
if magnifier then magnifier.callback() end
S.settle()
local box = ui.search.input_dialog
S.note("the search box:", tostring(box and box:getInputText()))
S.check(box ~= nil and box:getInputText() == "The Drowned", "the magnifier opens the search box on \"The Drowned\"")
S.check(ui.search.current_search_type == own_type, "the search type stays the reader's own")
S.shot("search_box")
S.closeAll()

-- ── Any case, picked: the rule stays off the name ──
pick("any")
S.chapter("Rented Quiet")
lower, cap = cases(drownedMarks())
S.check(lower and cap, "Any case: \"the drowned trees\" is underlined again")
S.check(XrayParser.matchTermSet(theDrowned()).caps == nil, "and the matcher takes any case")

-- ── Capitals only, picked ──
pick("capitals")
S.chapter("Rented Quiet")
lower, cap = cases(drownedMarks())
S.check(cap and not lower, "Capitals only: only \"the Drowned\"")
S.shot("capitals_only")

-- ── Back to automatic ──
pick(nil)
S.chapter("Rented Quiet")
lower, cap = cases(drownedMarks())
S.check(cap and not lower, "back to automatic: the book's usage decides again")

-- ── The background pass, as on a device: the index gone, the book opened
-- again (child processes refused: the pass cannot start), then allowed and
-- asked again; the page repaints when it lands, with no page turn ──
S.close()
os.remove(XrayIndex.path(file))
ui = S.open("Mock Series 3")
S.chapter("Rented Quiet")
lower, cap = cases(drownedMarks())
S.check(lower and cap, "the index gone: any case again")
S.allowForks()
XrayIndex.request(ui, {}) -- the marks' request from the opening, asked again
local landed = S.waitFor(function()
    return XrayIndex.layout(file, XrayIndex.stamp(ui)) ~= nil and not XrayIndex.busy(file)
end, 30)
S.check(landed, "the background pass lands")
S.settle()
lower, cap = cases(drownedMarks({ as_drawn = true }))
S.check(cap and not lower, "the page repaints on its own: only \"the Drowned\" underlined")

-- ── The index also holding an earlier version of the book's text (the book
-- replaced, or the fixture generated again over an indexed copy): that
-- layout, though it holds more forms, is left out ──
local older = { ["an older form"] = "" }
for f in pairs(XrayIndex.layout(file, XrayIndex.stamp(ui)).forms) do older[f] = "" end
XrayIndex.store(file, "1:1:1", older)
S.check(ActionCache.autoCaps(file)["the drowned"] == true,
    "an earlier text's layout with more forms changes nothing: capitals only, automatically")

S.finish()
