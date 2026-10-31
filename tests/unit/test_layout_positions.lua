-- B503 (2026-10-19): a saved artifact remembers where its text ended as a raw
-- page number, and page numbers belong to one layout (screen, font, margins,
-- rotation). An update read its slice from that page number in today's
-- layout: another device or a font change made it skip text or read it again.
-- ContextExtractor.pageXPointer / savedPageNow / entryInLayout keep the page's
-- text position and move a base into the current layout before new work
-- builds on it; WriteBack.scaleSpans carries its coverage spans along.
--
-- Run: lua tests/unit/test_layout_positions.lua  (or lua tests/run_tests.lua --unit)

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
local ContextExtractor = require("koassistant.request.context_extractor")
local WriteBack = require("koassistant.xray.artifact_writeback")
local TestRunner = require("test_runner"):new()

print("Running: test_layout_positions")

-- One text of 10,000 units laid out at `per` units a page. A position is
-- "u<offset>", the same text in every layout; its page depends on the layout.
local TEXT = 10000
local function layoutDoc(per, opts)
    opts = opts or {}
    local N = math.ceil(TEXT / per)
    local doc = { info = { number_of_pages = N, has_pages = opts.has_pages or false }, file = "/books/a.epub" }
    function doc:getPageXPointer(p)
        if p < 1 or p > N then return "" end
        return "u" .. ((p - 1) * per)
    end
    function doc:getPageFromXPointer(xp)
        local k = tonumber(tostring(xp):match("^u(%d+)$"))
        if not k then return 1 end
        return math.floor(k / per) + 1
    end
    function doc:isXPointerInDocument(xp)
        local k = tonumber(tostring(xp):match("^u(%d+)$"))
        return k ~= nil and k < TEXT
    end
    if opts.flows then
        function doc:hasHiddenFlows() return true end
        function doc:getPageFlow() return 0 end
        function doc:getTotalPagesInFlow() return N end
        function doc:getPageNumberInFlow(p) return p end
    end
    return doc
end

local A = layoutDoc(25)   -- 400 pages
local B = layoutDoc(40)   -- 250 pages: another device, a bigger font

print("\n  [pageXPointer]")
TestRunner:test("a page's position; none for page 0, past the end, or a page-based document", function()
    TestRunner:assertEqual(ContextExtractor.pageXPointer(A, 200), "u4975", "page 200 starts at unit 4975")
    TestRunner:assertEqual(ContextExtractor.pageXPointer(A, 0), nil, "page 0")
    TestRunner:assertEqual(ContextExtractor.pageXPointer(A, 401), nil, "past the end")
    TestRunner:assertEqual(ContextExtractor.pageXPointer(layoutDoc(25, { has_pages = true }), 5), nil, "PDF")
end)

print("\n  [savedPageNow]")
local SAVED = { progress_page = 200, progress_decimal = 0.5, progress_xpointer = "u4975" }
TestRunner:test("by position: the same page in the same layout, its page in another", function()
    local p, moved, by_pos = ContextExtractor.savedPageNow(A, SAVED)
    TestRunner:assertEqual(p, 200, "same layout")
    TestRunner:assertFalse(moved, "not moved")
    TestRunner:assertTrue(by_pos, "found by position")
    p, moved = ContextExtractor.savedPageNow(B, SAVED)
    TestRunner:assertEqual(p, 125, "unit 4975 is on page 125 at 40 a page")
    TestRunner:assertTrue(moved, "moved")
end)
TestRunner:test("saved before positions: kept in its own layout", function()
    local p, moved = ContextExtractor.savedPageNow(A, { progress_page = 200, progress_decimal = 0.5 })
    TestRunner:assertEqual(p, 200, "page holds at its share")
    TestRunner:assertFalse(moved, "not moved")
end)
TestRunner:test("saved before positions, fewer pages now: back to its share, early, never late", function()
    local p, moved, by_pos = ContextExtractor.savedPageNow(B, { progress_page = 200, progress_decimal = 0.5 })
    TestRunner:assertTrue(moved, "detected: page 200 of 250 sits past 50%")
    TestRunner:assertFalse(by_pos, "no position")
    TestRunner:assertTrue(p <= 125 and p >= 118, "starts at or a little before the true page 125, got " .. tostring(p))
    -- A checkpoint in a long layout read on a short one (60 pages): its share
    -- runs to the end of its page and beyond, its text ended where it starts
    local short = layoutDoc(167)
    local true_page = short:getPageFromXPointer(A:getPageXPointer(199))
    p = ContextExtractor.savedPageNow(short, { progress_page = 199, progress_decimal = 0.4999 })
    TestRunner:assertTrue(p <= true_page, "never past the true page " .. true_page .. ", got " .. tostring(p))
end)
TestRunner:test("saved before positions, at or before its share: kept (more pages now; a raised share)", function()
    local p, moved = ContextExtractor.savedPageNow(A, { progress_page = 100, progress_decimal = 0.5 })
    TestRunner:assertEqual(p, 100, "more pages now: starts early, reads some text twice, skips none")
    TestRunner:assertFalse(moved, "not moved")
    p, moved = ContextExtractor.savedPageNow(A,
        { progress_page = 100, progress_decimal = 0.6, producer = "book_merge" })
    TestRunner:assertEqual(p, 100, "a share an AI merge of sections raised, whatever its later producer")
    TestRunner:assertFalse(moved, "not moved")
    p, moved = ContextExtractor.savedPageNow(layoutDoc(25, { flows = true }),
        { progress_page = 200, progress_decimal = 0.5, flow_visible_pages = 400 })
    TestRunner:assertEqual(p, 200, "hidden flows, the same layout")
    TestRunner:assertFalse(moved, "not moved")
end)
TestRunner:test("whole-book claims, the introduction, page-based documents, a stranger's position", function()
    local p, moved = ContextExtractor.savedPageNow(B, { progress_page = 400, progress_decimal = 1 })
    TestRunner:assertEqual(p, 250, "the last page of any layout")
    TestRunner:assertTrue(moved, "moved")
    -- A section merge reaching the end keeps its base's page and position:
    -- the position answers first, so the same layout moves nothing
    p, moved = ContextExtractor.savedPageNow(A,
        { progress_page = 160, progress_decimal = 1, progress_xpointer = A:getPageXPointer(160) })
    TestRunner:assertEqual(p, 160, "found by position")
    TestRunner:assertFalse(moved, "not moved")
    p, moved = ContextExtractor.savedPageNow(B, { progress_page = 0, progress_decimal = 0, intro = true })
    TestRunner:assertEqual(p, 0, "introduction")
    TestRunner:assertFalse(moved, "not moved")
    p, moved = ContextExtractor.savedPageNow(layoutDoc(40, { has_pages = true }), SAVED)
    TestRunner:assertEqual(p, 200, "page-based")
    TestRunner:assertFalse(moved, "not moved")
    p, moved = ContextExtractor.savedPageNow(B,
        { progress_page = 200, progress_decimal = 0.5, progress_xpointer = "/not/this/book" })
    TestRunner:assertTrue(moved and p <= 125, "an invalid position falls back to the share")
end)

print("\n  [entryInLayout]")
TestRunner:test("the entry itself when nothing moved", function()
    TestRunner:assertTrue(rawequal(ContextExtractor.entryInLayout(A, SAVED), SAVED), "same table")
end)
TestRunner:test("moved: a copy with the page, the spans and a position; the original untouched", function()
    local entry = { progress_page = 200, progress_decimal = 0.5, progress_xpointer = "u4975",
        coverage_spans = "1-200", result = "{}", timestamp = 7 }
    local now = ContextExtractor.entryInLayout(B, entry)
    TestRunner:assertFalse(rawequal(now, entry), "a copy")
    TestRunner:assertEqual(now.progress_page, 125, "page")
    TestRunner:assertEqual(now.coverage_spans, "1-125", "spans moved with it")
    TestRunner:assertEqual(now.progress_xpointer, "u4975", "its own position kept")
    TestRunner:assertEqual(now.timestamp, 7, "identity kept")
    TestRunner:assertEqual(entry.progress_page, 200, "original untouched")
    TestRunner:assertEqual(entry.coverage_spans, "1-200", "original spans untouched")
    local legacy = ContextExtractor.entryInLayout(B, { progress_page = 200, progress_decimal = 0.5 })
    TestRunner:assertEqual(legacy.progress_xpointer,
        ContextExtractor.pageXPointer(B, legacy.progress_page), "a legacy entry gets its page's position")
end)
TestRunner:test("a whole-book claim's spans are not scaled by its page", function()
    -- A section merge reaching the end without a position: its page says
    -- "the end", not where its spans end
    local whole = { progress_page = 160, progress_decimal = 1, coverage_spans = "1-160,300-400" }
    local now = ContextExtractor.entryInLayout(A, whole)
    TestRunner:assertEqual(now.progress_page, 400, "the end of this layout")
    TestRunner:assertEqual(now.coverage_spans, "1-160,300-400", "spans as recorded")
    local same = { progress_page = 160, progress_decimal = 1, coverage_spans = "1-160,300-400",
        progress_xpointer = A:getPageXPointer(160) }
    TestRunner:assertTrue(rawequal(ContextExtractor.entryInLayout(A, same), same), "by position: untouched")
end)
TestRunner:test("the update's slice starts where the base's text ended", function()
    -- dialogs: from_raw = base.progress_page / total, getBookTextRange floors it back
    local base = ContextExtractor.entryInLayout(B, SAVED)
    local from = math.max(1, math.floor(base.progress_page / 250 * 250 + 1e-9))
    TestRunner:assertEqual(B:getPageFromXPointer("u4975"), from, "the page holding the old end")
end)

print("\n  [scaleSpans]")
TestRunner:test("bounds scaled, starts down and ends up, holes kept, adjacency kept", function()
    TestRunner:assertEqual(WriteBack.scaleSpans("1-200,301-400", 0.625), "1-125,188-250", "holes")
    TestRunner:assertEqual(WriteBack.scaleSpans("1-200,201-300", 0.625), "1-188", "adjacent spans stay one")
    TestRunner:assertEqual(WriteBack.scaleSpans("1-125", 1.6), "1-200", "the other way")
    TestRunner:assertEqual(WriteBack.scaleSpans("3-5", nil), "3-5", "no ratio: as is")
    TestRunner:assertEqual(WriteBack.scaleSpans(nil, 2), nil, "no spans")
end)

print("\n  [write-back pairs a page with its own position]")
TestRunner:test("a pass with its own page never inherits the base's position", function()
    local base = { progress_page = 100, progress_xpointer = "u2475" }
    local meta = WriteBack.reconcileXrayMeta(base, { progress_page = 150 })
    TestRunner:assertEqual(meta.progress_page, 150, "the pass's page")
    TestRunner:assertEqual(meta.progress_xpointer, nil, "not the base's position")
    meta = WriteBack.reconcileXrayMeta(base, { model = "m" })
    TestRunner:assertEqual(meta.progress_page, 100, "inherited page")
    TestRunner:assertEqual(meta.progress_xpointer, "u2475", "with its position")
    meta = WriteBack.reconcileXrayMeta(base, { progress_page = 150, progress_xpointer = "u3725" })
    TestRunner:assertEqual(meta.progress_xpointer, "u3725", "the pass's own position")
    meta = WriteBack.reconcileXrayMeta(base, { progress_xpointer = "u3725" })
    TestRunner:assertEqual(meta.progress_page, nil, "a position never pairs with the base's page either")
end)

print("\n  [every site (source guard)]")
local function read(rel)
    local f = assert(io.open(plugin_dir .. "/" .. rel, "r"))
    local s = f:read("*a")
    f:close()
    return s
end
TestRunner:test("the update moves its base into this layout before reading its page", function()
    local src = read("koassistant/ui/dialogs.lua")
    local base_at = src:find("updateBaseFor(message_data", 1, true)
    local norm_at = src:find("entryInLayout(ui.document, cached_entry)", 1, true)
    local read_at = src:find("local from_page = cached_entry.progress_page", 1, true)
    TestRunner:assertTrue(base_at and norm_at and read_at, "all three present")
    TestRunner:assertTrue(base_at < norm_at and norm_at < read_at, "normalized between the load and the read")
end)
TestRunner:test("every save of a page saves its position", function()
    local src = read("koassistant/ui/dialogs.lua")
    local pages, positions = 0, 0
    for _ in src:gmatch("progress_page = message_data") do pages = pages + 1 end
    for _ in src:gmatch("progress_xpointer = [^\n]*message_data%.progress_xpointer") do positions = positions + 1 end
    TestRunner:assertTrue(pages >= 4, "the four save sites")
    TestRunner:assertEqual(positions, pages, "a position beside every page")
    local cache = read("koassistant/artifacts/action_cache.lua")
    TestRunner:assertTrue(cache:find('"progress_page", "progress_xpointer"', 1, true) ~= nil, "checkpoint copy fields")
    TestRunner:assertTrue(cache:find("progress_xpointer = entry.progress_xpointer", 1, true) ~= nil, "restore")
    TestRunner:assertTrue(cache:find("progress_xpointer = rung.progress_xpointer", 1, true) ~= nil, "promote")
end)
TestRunner:test("the section merge and the search's browser read ranges in this layout", function()
    local merge = read("koassistant/xray/xray_merge.lua")
    TestRunner:assertTrue(merge:find("main_entry = ContextExtractor.entryInLayout(doc, main_entry)", 1, true) ~= nil,
        "the main's coverage")
    TestRunner:assertTrue(merge:find("opts.section_range(sec.data)", 1, true) ~= nil, "the picker's ranges")
    TestRunner:assertTrue(merge:find("opts.section_range(e)", 1, true) ~= nil, "the inputs' spans")
    TestRunner:assertTrue(merge:find("table.sort(sections, function(a, b) return starts[a] < starts[b] end)", 1, true)
        ~= nil, "the sections in this layout's text order")
    TestRunner:assertTrue(merge:find("main_possible = coverage_ratio ~= nil or main_whole\n", 1, true)
        ~= nil, "no merge into the main judged on stored pages alone")
    local browser = read("koassistant/xray/xray_browser.lua")
    TestRunner:assertTrue(browser:find("group.scope_start or group.cache_entry.scope_start_page", 1, true) ~= nil,
        "the search's scope")
end)
TestRunner:test("only a request about the open book updates from the open document", function()
    local src = read("koassistant/ui/dialogs.lua")
    local at = src:find("current_progress > cached_progress + 0.01 and prompt.update_prompt", 1, true)
    TestRunner:assertTrue(at ~= nil, "the update condition")
    local cond = src:sub(at, at + 300)
    TestRunner:assertTrue(cond:find("samePath(ui.document.file, cache_file)", 1, true) ~= nil,
        "the cache's book is the open document")
end)

print("\n  [section ranges]")
TestRunner:test("a section position this document does not hold keeps the stored pages", function()
    -- action_cache loads with a docsettings module; this check reads no file,
    -- and the suite's later files get back what they had (one Lua process)
    local had_ds = package.loaded["docsettings"]
    local had_ac = package.loaded["koassistant.artifacts.action_cache"]
    package.loaded["docsettings"] = had_ds or { getSidecarDir = function() return "/nonexistent.sdr" end }
    local ok_ac, ActionCache = pcall(require, "koassistant.artifacts.action_cache")
    package.loaded["docsettings"] = had_ds
    package.loaded["koassistant.artifacts.action_cache"] = had_ac
    assert(ok_ac, tostring(ActionCache))
    local sp, ep = ActionCache.getSectionPageRange({ scope_start_xpointer = "/other/edition",
        scope_end_xpointer = "/other/edition2", scope_start_page = 40, scope_end_page = 60 }, A)
    TestRunner:assertEqual(sp, 40, "start as stored")
    TestRunner:assertEqual(ep, 60, "end as stored")
    sp, ep = ActionCache.getSectionPageRange({ scope_start_xpointer = "u4975",
        scope_end_xpointer = "u6000", scope_start_page = 1, scope_end_page = 2 }, B)
    TestRunner:assertEqual(sp, 125, "a held position finds its page")
    TestRunner:assertEqual(ep, 150, "the end position's page, exclusive")
end)

local ok = TestRunner:summary()
return ok
