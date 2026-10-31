-- A scanned PDF has no text layer: every page reads as "" (or whitespace).
-- The page-based extraction joined the pages with newlines, so a scan of N
-- pages gave N-1 newlines that passed for the book's text: char_count was
-- not 0, the empty-extraction ask never fired and the text-fallback nudge
-- stayed silent while the model got a labelled block of whitespace
-- (docs/research/2026-08-14/T5_vision.md section 3.2). Whitespace alone is
-- now no text at every page-joined extraction; real text is untouched.
--
-- Run: lua tests/unit/test_scanned_pdf_text.lua  (or lua tests/run_tests.lua --unit)

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
require("mock_koreader")
local ContextExtractor = require("koassistant.request.context_extractor")

local TestRunner = { passed = 0, failed = 0 }
function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then self.passed = self.passed + 1; print("    ok   " .. name)
    else self.failed = self.failed + 1; print("    FAIL " .. name); print("      " .. tostring(err)) end
end
function TestRunner:assertEqual(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s: expected %q, got %q", msg or "assert", tostring(expected), tostring(actual)), 2)
    end
end

-- A paging document of `pages` pages; page_text(p) is what getPageText gives
local function extractor(pages, page_text, current)
    local doc = {
        info = { number_of_pages = pages, has_pages = true },
        getPageText = function(_self, p) return page_text(p) end,
    }
    local ui = { document = doc, view = { state = { page = current or pages } } }
    return ContextExtractor:new(ui, { enable_book_text_extraction = true })
end

print("\n  [A scanned PDF's pages are no text (T5 3.2)]")

TestRunner:test("a scan of 41 pages: the whole document is empty, not 40 newlines", function()
    local r = extractor(41, function() return "" end):getFullDocumentText()
    TestRunner:assertEqual(r.text, "", "text")
    TestRunner:assertEqual(r.char_count, 0, "char_count (the empty-extraction ask keys on it)")
end)

TestRunner:test("a scan whose pages hold stray spaces and line breaks is empty too", function()
    local r = extractor(5, function(p) return p % 2 == 0 and "  \n" or "" end):getFullDocumentText()
    TestRunner:assertEqual(r.char_count, 0)
end)

TestRunner:test("up to the position and a page range: empty as well", function()
    local ex = extractor(30, function() return "" end, 12)
    TestRunner:assertEqual(ex:getBookText().char_count, 0, "to the position")
    TestRunner:assertEqual(ex:getPageRangeText(3, 9).char_count, 0, "a page range")
end)

TestRunner:test("a PDF with a text layer keeps its text, joined as before", function()
    local ex = extractor(3, function(p) return "Page " .. p .. " text." end)
    local r = ex:getFullDocumentText()
    TestRunner:assertEqual(r.text, "Page 1 text.\nPage 2 text.\nPage 3 text.")
    TestRunner:assertEqual(r.char_count, #r.text)
    -- one page with text among blank ones is text
    r = extractor(4, function(p) return p == 3 and "Only here." or "" end):getFullDocumentText()
    TestRunner:assertEqual(r.text, "\n\nOnly here.\n", "the blank pages' joins are kept around real text")
end)

print(string.format("\n  test_scanned_pdf_text: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
