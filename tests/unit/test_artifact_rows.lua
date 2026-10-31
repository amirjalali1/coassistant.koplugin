-- The View-Artifacts rows as one list and one opener (B490,
-- docs/artifact_rows_plan.md): every row of the aggregation names its kind
-- without a count, the one opener sends every row where it belongs, Browse by
-- type lists every kind, and the browser's walk finds books with only pins or
-- only pictures. The aggregation runs for real on stubbed data sources; the
-- destinations are recorders. Every stub is restored at the end.
-- Run: lua tests/unit/test_artifact_rows.lua  (or lua tests/run_tests.lua --unit)

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
-- The plugin modules loaded before this file; the ones it loads (and which
-- hold its stubs) are dropped at the end so no later file inherits them
local loaded_before = {}
for name in pairs(package.loaded) do loaded_before[name] = true end

-- Module stubs this file installs; the previous values come back at the end
local saved_loaded = {}
local function stubModule(name, value)
    if saved_loaded[name] == nil then saved_loaded[name] = { value = package.loaded[name] } end
    package.loaded[name] = value
end

local function classStub()
    local C = {}
    function C:new(o) return setmetatable(o or {}, { __index = self }) end
    return C
end

-- doc_props for getBookMetadata: the file name as the title
stubModule("docsettings", {
    open = function(_self, path)
        return { readSetting = function(_s, key)
            if key == "doc_props" then return { title = "Title of " .. path:match("([^/]+)$") } end
        end }
    end,
    -- each storage location its own folder, so the sidecar migration a cache
    -- read tries never finds the current file at an "alternate" place
    getSidecarDir = function(_self, path, loc) return path .. (loc and ("." .. loc) or "") .. ".sdr" end,
    isHashLocationEnabled = function() return false end,
})
-- The widgets the browser shows: kept as tables, and UIManager records the
-- last one shown (Browse by type's dialog, its type list)
stubModule("ui/widget/confirmbox", classStub())
stubModule("ui/widget/menu", classStub())
stubModule("ui/widget/buttondialog", classStub())
local last_shown
stubModule("ui/uimanager", {
    show = function(_self, widget) last_shown = widget end,
    close = function() end,
    scheduleIn = function() end,
    nextTick = function(_self, fn) fn() end,
})
package.loaded["util"] = package.loaded["util"] or { makePath = function() end }
package.loaded["luasettings"] = package.loaded["luasettings"] or {
    open = function() return { readSetting = function() return nil end, close = function() end } end,
}

local saved_settings = _G.G_reader_settings
local settings_store = {}
local settings_saved = {}
_G.G_reader_settings = {
    readSetting = function(_self, key, default)
        if settings_store[key] == nil then return default end
        return settings_store[key]
    end,
    saveSetting = function(_self, key, value)
        settings_store[key] = value
        settings_saved[key] = true
    end,
    flush = function() end,
}

local TestRunner = require("test_runner"):new()
local ActionCache = require("koassistant.artifacts.action_cache")
local PinnedManager = require("koassistant.artifacts.pinned_manager")
-- A fresh copy, so it holds this file's docsettings stub
local saved_browser = package.loaded["koassistant.artifacts.artifact_browser"]
package.loaded["koassistant.artifacts.artifact_browser"] = nil
local ArtifactBrowser = require("koassistant.artifacts.artifact_browser")
-- The real section popups (the opener's tests replace them with recorders)
local real_section_popup = ArtifactBrowser._showSectionGroupPopup
local real_section_xray_popup = ArtifactBrowser._showSectionXrayGroupPopup

-- Field stubs on real modules; restored at the end
local saved_fields = {}
local function stubField(tbl, key, value)
    saved_fields[#saved_fields + 1] = { tbl = tbl, key = key, value = tbl[key] }
    tbl[key] = value
end

-- ---------------------------------------------------------------------------
-- The fixture: every kind of row the aggregation lists, over two books
-- ---------------------------------------------------------------------------

local BOOK_A, BOOK_B = "/books/a.epub", "/books/b.epub"
local function entry(result, ts) return { result = result, timestamp = ts } end

local caches = {
    [BOOK_A] = {
        _xray_cache = entry('{"characters":[]}', 100),
        _summary_cache = entry("A summary.", 90),
        recap = entry("A recap.", 80),
    },
    [BOOK_B] = {
        recap = entry("B recap.", 120),
    },
}
local sections = {
    [BOOK_A] = {
        [ActionCache.SECTION_XRAY_PREFIX] = {
            { key = "_xray_section:1", label = "Part 1", data = entry('{"characters":[]}', 60) },
            { key = "_xray_section:2", label = "Part 2", data = entry('{"characters":[]}', 70) },
        },
        [ActionCache.SECTION_PREFIXES.summary] = {
            { key = "_summary_section:1", label = "Part 1", data = entry("Section summary.", 50) },
        },
    },
}
local wikis = {
    [BOOK_A] = {
        { key = "_wiki:a1", label = "One", data = entry("w", 40) },
        { key = "_wiki:a2", label = "Two", data = entry("w", 41) },
        { key = "_wiki:a3", label = "Three", data = entry("w", 42) },
    },
    [BOOK_B] = { { key = "_wiki:b1", label = "Four", data = entry("w", 130) } },
}
local pins = {
    [BOOK_A] = { { id = "p1", name = "Pin one", result = "r", timestamp = 30 },
        { id = "p2", name = "Pin two", result = "r", timestamp = 35 } },
}
local IMAGE_BOOKS = { [BOOK_A] = { count = 4, modified = 20 } }

-- The real getters, for the parse count at the end
local real_getters = { get = ActionCache.get, getSections = ActionCache.getSections,
    getSectionXrays = ActionCache.getSectionXrays, getWikiEntries = ActionCache.getWikiEntries }

stubField(ActionCache, "get", function(path, key)
    local book = caches[path]
    return book and book[key]
end)
stubField(ActionCache, "getSections", function(path, prefix)
    return (sections[path] or {})[prefix] or {}
end)
stubField(ActionCache, "getSectionXrays", function(path)
    return ActionCache.getSections(path, ActionCache.SECTION_XRAY_PREFIX)
end)
stubField(ActionCache, "getWikiEntries", function(path) return wikis[path] or {} end)
stubField(ActionCache, "getXrayCheckpointCount", function(path) return path == BOOK_A and 2 or 0 end)
stubField(ActionCache, "getXrayLadderCount", function() return 0 end)
stubField(PinnedManager, "getPinnedForDocument", function(path) return pins[path] or {} end)

local function rowsOf(path)
    return ActionCache.getAvailableArtifactsWithPinned(path, nil, nil, { image_books = IMAGE_BOOKS })
end

local function byKey(rows)
    local out = {}
    for _idx, row in ipairs(rows) do out[row.key] = row end
    return out
end

print("\n  [the aggregation's rows]")

TestRunner:test("the fixture lists every kind of row", function()
    local keys = {}
    for _idx, row in ipairs(rowsOf(BOOK_A)) do keys[#keys + 1] = row.key end
    table.sort(keys)
    TestRunner:assertEqual(table.concat(keys, ","),
        "_generated_images,_pinned_artifacts,_summary_cache,_summary_sections,"
        .. "_wiki_entries,_xray_cache,_xray_sections,_xray_versions,recap", "book A's rows")
end)

TestRunner:test("every row names its kind without a count", function()
    for _idx, path in ipairs({ BOOK_A, BOOK_B }) do
        for _idx2, row in ipairs(rowsOf(path)) do
            TestRunner:assertTrue(type(row.type_name) == "string" and row.type_name ~= "",
                row.key .. " has a type_name")
            TestRunner:assertTrue(not row.type_name:find("%(%d+%)"),
                row.key .. "'s type_name carries no count: " .. tostring(row.type_name))
        end
    end
    local rows = byKey(rowsOf(BOOK_A))
    TestRunner:assertEqual(rows._xray_sections.type_name, "Section X-Rays")
    TestRunner:assertEqual(rows._summary_sections.type_name, "Section Summaries")
    TestRunner:assertEqual(rows._wiki_entries.type_name, "AI Wiki Entries")
    TestRunner:assertEqual(rows._pinned_artifacts.type_name, "Pinned Artifacts")
    TestRunner:assertEqual(rows._generated_images.type_name, "Generated Images")
    TestRunner:assertEqual(rows.recap.type_name, rows.recap.name, "a saved result's kind is its name")
end)

TestRunner:test("every section kind has a name without a count", function()
    local missing = {}
    for key in pairs(ActionCache.SECTION_PREFIXES) do
        if not ActionCache.SECTION_KIND_NAMES[key] then missing[#missing + 1] = key end
    end
    table.sort(missing)
    TestRunner:assertEqual(table.concat(missing, ","), "", "SECTION_KIND_NAMES")
end)

-- The group flags the aggregation sets, read from its source: a new kind of
-- group row fails here until the fixture above lists it, so the opener and
-- Browse by type below are proven on it too
local function aggregationGroupFlags()
    local f = assert(io.open(plugin_dir .. "/koassistant/artifacts/action_cache.lua", "r"))
    local src = f:read("*a")
    f:close()
    local from = src:find("function ActionCache.getAvailableArtifacts(", 1, true)
    local to = src:find("function ActionCache.getXrayCache(", 1, true)
    assert(from and to and to > from, "the aggregation's source is found")
    local flags = {}
    for flag in src:sub(from, to):gmatch("(is_[%w_]+_group) = true") do flags[flag] = true end
    return flags
end

TestRunner:test("the fixture covers every group flag the aggregation sets", function()
    local seen = {}
    for _idx, row in ipairs(rowsOf(BOOK_A)) do
        for k, v in pairs(row) do
            if v == true and type(k) == "string" and k:match("^is_.+_group$") then seen[k] = true end
        end
    end
    local flags = aggregationGroupFlags()
    local missing = {}
    for flag in pairs(flags) do
        if not seen[flag] then missing[#missing + 1] = flag end
    end
    table.sort(missing)
    TestRunner:assertTrue(next(flags) ~= nil, "group flags found in the source")
    TestRunner:assertEqual(table.concat(missing, ","), "", "group flags the fixture lacks")
end)

-- ---------------------------------------------------------------------------
-- The section popups: a page range is recomputed from the open book only
-- when the sections are that book's (Browse by type opens any book's)
-- ---------------------------------------------------------------------------

print("\n  [section popups]")

local unpackArgs = table.unpack or unpack

TestRunner:test("another book's section popup shows its stored range; the open book's is recomputed", function()
    local asked = 0
    local function readerWith(file)
        return { ui = { document = { file = file, info = { number_of_pages = 10 },
            getPageFromXPointer = function() asked = asked + 1; return 4 end } } }
    end
    local secs = { { key = "_summary_section:1", label = "Part 1",
        data = { scope_page_summary = "pp 3–9", scope_start_xpointer = "/body/DocFragment[2]", timestamp = 50 } } }
    for _idx, popup in ipairs({
        { real_section_popup, function(reader) return { secs, BOOK_A, "Book A", reader, "summary", nil, nil } end },
        { real_section_xray_popup, function(reader) return { secs, BOOK_A, "Book A", reader, nil, nil } end },
    }) do
        asked, last_shown = 0, nil
        local args = popup[2](readerWith("/books/open.epub"))
        popup[1](ArtifactBrowser, unpackArgs(args, 1, 7))
        TestRunner:assertEqual(asked, 0, "another book's document is not asked")
        local text = last_shown and last_shown.buttons[1][1].text or ""
        TestRunner:assertTrue(text:find("pp 3–9", 1, true) ~= nil, "the stored range: " .. text)
        asked, last_shown = 0, nil
        args = popup[2](readerWith(BOOK_A))
        popup[1](ArtifactBrowser, unpackArgs(args, 1, 7))
        text = last_shown and last_shown.buttons[1][1].text or ""
        TestRunner:assertTrue(asked > 0 and text:find("pp 4–10", 1, true) ~= nil,
            "the open book's own range is recomputed: " .. text)
    end
end)

-- ---------------------------------------------------------------------------
-- The one opener
-- ---------------------------------------------------------------------------

print("\n  [the opener]")

local events = {}
local function record(s) events[#events + 1] = s end
local last_on_select, last_popup_author, last_viewer_info
local plugin = {
    viewCachedAction = function(_self, _action, key, _data, opts)
        record("viewCachedAction " .. key .. " " .. tostring(opts and opts.file))
    end,
    showCacheViewer = function(_self, info)
        last_viewer_info = info
        record("showCacheViewer " .. info.key .. " " .. tostring(info.file) .. " " .. tostring(info.book_title))
    end,
    _showXrayCheckpointList = function(_self, opts)
        record("versions " .. tostring(opts and opts.file)
            .. (opts and opts.close_browser and " close_browser" or ""))
    end,
}
for _idx, popup in ipairs({ "_showSectionXrayGroupPopup", "_showSectionGroupPopup",
        "_showWikiGroupPopup", "_showPinnedGroupPopup" }) do
    local name = popup
    stubField(ArtifactBrowser, name, function(_self, ...)
        -- on_select is the last function each popup takes (select: the
        -- excluded section key before it is nil)
        local on_select
        for i = select("#", ...), 1, -1 do
            local v = select(i, ...)
            if type(v) == "function" then on_select = v; break end
        end
        last_on_select = on_select
        local selecting = false
        for i = 1, select("#", ...) do
            local v = select(i, ...)
            if type(v) == "table" and v.select_mode then selecting = true end
        end
        last_popup_author = select(select("#", ...), ...)
        record("popup " .. name .. (selecting and " select" or ""))
    end)
end
stubModule("koassistant.images.image_browser", {
    show = function(opts) record("gallery " .. tostring(opts and opts.book_file)) end,
    count = function() return 5 end,
})

local function open(row)
    events, last_on_select = {}, nil
    ArtifactBrowser.openRow(row, {
        plugin = plugin, file = BOOK_A, title = "Book A", author = "Someone",
        before_open = function(dest) record("before " .. tostring(dest)) end,
    })
    return table.concat(events, " | ")
end

TestRunner:test("each row reaches its destination, after before_open", function()
    local rows = byKey(rowsOf(BOOK_A))
    TestRunner:assertEqual(open(rows._xray_cache),
        "before xray | showCacheViewer _xray_cache " .. BOOK_A .. " Book A", "the X-Ray row")
    TestRunner:assertEqual(open(rows._summary_cache),
        "before viewer | showCacheViewer _summary_cache " .. BOOK_A .. " Book A", "a document cache")
    TestRunner:assertEqual(open(rows.recap),
        "before viewer | viewCachedAction recap " .. BOOK_A, "a per-action artifact")
    TestRunner:assertEqual(open(rows._generated_images), "before gallery | gallery " .. BOOK_A, "images")
    TestRunner:assertEqual(open(rows._xray_versions), "before versions | versions " .. BOOK_A, "versions")
end)

TestRunner:test("a group row opens its popup; before_open waits for the pick", function()
    local rows = byKey(rowsOf(BOOK_A))
    local cases = {
        { rows._xray_sections, "popup _showSectionXrayGroupPopup", "before xray" },
        { rows._summary_sections, "popup _showSectionGroupPopup", "before viewer" },
        { rows._wiki_entries, "popup _showWikiGroupPopup", "before viewer" },
        { rows._pinned_artifacts, "popup _showPinnedGroupPopup", "before viewer" },
    }
    for _idx, case in ipairs(cases) do
        TestRunner:assertEqual(open(case[1]), case[2], case[1].key .. " opens its popup only")
        TestRunner:assertTrue(type(last_on_select) == "function", case[1].key .. " passes on_select")
        events = {}
        last_on_select()
        TestRunner:assertEqual(table.concat(events, " | "), case[3], case[1].key .. "'s pick")
    end
end)

TestRunner:test("the versions list gets the surface's close_browser", function()
    local rows = byKey(rowsOf(BOOK_A))
    events = {}
    ArtifactBrowser.openRow(rows._xray_versions, { plugin = plugin, file = BOOK_A, title = "Book A",
        close_browser = function() end })
    TestRunner:assertEqual(table.concat(events, " | "), "versions " .. BOOK_A .. " close_browser")
end)

TestRunner:test("in select mode a saved result is attached, a refusal keeps the picker", function()
    stubModule("koassistant.request.attachments", {
        makeArtifact = function(name, key, _data, title)
            if key == "recap" then return { name = name, key = key, title = title } end
            return nil, "refused " .. key
        end,
    })
    local attached
    local opts = { select_mode = { on_select = function(entry) attached = entry end } }
    local rows = byKey(rowsOf(BOOK_A))
    local function pick(row)
        events, attached = {}, nil
        ArtifactBrowser.openRow(row, { plugin = plugin, file = BOOK_A, title = "Book A", opts = opts,
            before_open = function(dest) record("before " .. dest) end })
        return table.concat(events, " | ")
    end
    TestRunner:assertEqual(pick(rows.recap), "before viewer", "the picker closes")
    TestRunner:assertTrue(attached ~= nil and attached.key == "recap" and attached.title == "Book A",
        "the entry reaches the select callback")
    TestRunner:assertEqual(pick(rows._summary_cache), "", "a refusal closes nothing")
    TestRunner:assertTrue(attached == nil, "and attaches nothing")
    TestRunner:assertEqual(pick(rows._wiki_entries), "popup _showWikiGroupPopup select",
        "a group popup picks in select mode")
end)

TestRunner:test("no row of the fixture falls through to a viewer it does not belong in", function()
    for _idx, row in ipairs(rowsOf(BOOK_A)) do
        local trail = open(row)
        local is_group = row.is_section_group or row.is_wiki_group or row.is_pinned_group
            or row.is_image_group or row.is_xray_versions_group
        if is_group then
            TestRunner:assertTrue(not trail:find("Viewer") and not trail:find("viewCachedAction"),
                row.key .. " stays out of the viewers: " .. trail)
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Browse by type
-- ---------------------------------------------------------------------------

print("\n  [Browse by type]")

local function kindsFixture(extra)
    return ArtifactBrowser.typeKinds({
        { path = BOOK_A, title = "Book A", rows = rowsOf(BOOK_A) },
        { path = BOOK_B, title = "Book B", rows = rowsOf(BOOK_B) },
    }, extra)
end

TestRunner:test("every kind the books hold is listed, counted in artifacts", function()
    local kinds = kindsFixture({ general = { count = 2, modified = 5 }, images = 5 })
    local got = {}
    for _idx, kind in ipairs(kinds) do got[#got + 1] = kind.key .. "=" .. kind.count end
    TestRunner:assertEqual(table.concat(got, " "),
        "_generated_images=5 _wiki_entries=4 _pinned_artifacts=4 recap=2 _xray_sections=2 "
        .. "_summary_sections=1 _summary_cache=1 _xray_cache=1",
        "kinds, most first, ties by name")
end)

TestRunner:test("names carry no count; the X-Ray versions and per-book image rows stay out", function()
    local kinds = kindsFixture({ images = 5 })
    for _idx, kind in ipairs(kinds) do
        TestRunner:assertTrue(not kind.name:find("%(%d+%)"), kind.key .. ": " .. kind.name)
        TestRunner:assertTrue(kind.key ~= "_xray_versions", "no versions kind")
        if kind.key == "_generated_images" then
            TestRunner:assertTrue(kind.gallery == true, "images open the gallery")
            TestRunner:assertEqual(#kind.items, 0, "no per-book image rows")
        end
    end
end)

TestRunner:test("pins outside any book join the Pinned kind", function()
    local kinds = kindsFixture({ general = { count = 2, modified = 5 }, library = { count = 1, modified = 6 } })
    local pinned
    for _idx, kind in ipairs(kinds) do
        if kind.key == "_pinned_artifacts" then pinned = kind end
    end
    TestRunner:assertTrue(pinned ~= nil, "a Pinned kind")
    TestRunner:assertEqual(pinned.count, 5, "two in the book, two general, one library")
    local which = {}
    for _idx, item in ipairs(pinned.items) do which[#which + 1] = item.pinned or item.path end
    TestRunner:assertEqual(table.concat(which, ","), BOOK_A .. ",general,library")
end)

TestRunner:test("General pins alone make a Pinned kind; no pictures, no images kind", function()
    local kinds = ArtifactBrowser.typeKinds({}, { general = { count = 1 }, images = 0 })
    TestRunner:assertEqual(#kinds, 1)
    TestRunner:assertEqual(kinds[1].key .. " " .. kinds[1].name, "_pinned_artifacts Pinned Artifacts")
end)

-- ---------------------------------------------------------------------------
-- The browser's walk across books
-- ---------------------------------------------------------------------------

print("\n  [the walk across books]")

TestRunner:test("books with only pins or only pictures are listed; a stale entry is dropped", function()
    settings_store.koassistant_artifact_index = {
        [BOOK_A] = { count = 3, modified = 10 },
        ["/books/stale.epub"] = { count = 1, modified = 1 },
    }
    stubField(ActionCache, "getPath", function(path) return path .. ".sdr/koassistant_cache.lua" end)
    stubModule("libs/libkoreader-lfs", {
        attributes = function(path, what)
            if path == BOOK_A .. ".sdr/koassistant_cache.lua" then
                return what == "mode" and "file" or { mode = "file" }
            end
        end,
    })
    stubField(PinnedManager, "getPinnedIndex", function()
        return {
            ["/books/pinonly.epub"] = { count = 1, modified = 20 },
            [PinnedManager.GENERAL_KEY] = { count = 2, modified = 5 },
        }
    end)
    stubModule("koassistant.images.image_generator", {
        booksWithImages = function()
            return { ["/books/imgonly.epub"] = { count = 2, modified = 30, book_title = "Pictures" } }
        end,
    })
    local books, image_books = ArtifactBrowser.artifactBooks()
    local got = {}
    for _idx, book in ipairs(books) do got[#got + 1] = book.path .. "=" .. book.title end
    TestRunner:assertEqual(table.concat(got, " "),
        "/books/imgonly.epub=Pictures /books/pinonly.epub=Title of pinonly.epub "
        .. BOOK_A .. "=Title of a.epub", "newest first, titles")
    TestRunner:assertTrue(image_books["/books/imgonly.epub"] ~= nil, "the images map comes back")
    TestRunner:assertTrue(settings_store.koassistant_artifact_index["/books/stale.epub"] == nil
        and settings_saved.koassistant_artifact_index == true, "the stale entry is dropped and saved")
end)

-- ---------------------------------------------------------------------------
-- The surface itself: the walk, the aggregation and the kinds together
-- ---------------------------------------------------------------------------

print("\n  [Browse by type, end to end]")

local function buttonTexts(dialog)
    local out = {}
    for _idx, row in ipairs(dialog.buttons or {}) do out[#out + 1] = row[1].text end
    return out
end

TestRunner:test("the dialog lists every kind; a kind opens its list, images the gallery", function()
    settings_store.koassistant_artifact_index = {
        [BOOK_A] = { count = 3, modified = 100 },
        [BOOK_B] = { count = 1, modified = 120 },
    }
    stubModule("libs/libkoreader-lfs", {
        attributes = function(path, what)
            if path == BOOK_A .. ".sdr/koassistant_cache.lua" or path == BOOK_B .. ".sdr/koassistant_cache.lua" then
                return what == "mode" and "file" or { mode = "file" }
            end
        end,
    })
    stubField(PinnedManager, "getPinnedIndex", function()
        return {
            [BOOK_A] = { count = 2, modified = 35 },
            [PinnedManager.GENERAL_KEY] = { count = 2, modified = 5 },
        }
    end)
    stubModule("koassistant.images.image_generator", { booksWithImages = function() return IMAGE_BOOKS end })
    stubField(ArtifactBrowser, "getAskGPTInstance", function() return plugin end)

    last_shown = nil
    ArtifactBrowser:showBrowseByType({})
    TestRunner:assertTrue(last_shown ~= nil and last_shown.title == "Browse by type", "the dialog is shown")
    TestRunner:assertEqual(table.concat(buttonTexts(last_shown), " | "),
        "Generated Images (5) | AI Wiki Entries (4) | Pinned Artifacts (4) | Recap (2) | "
        .. "Section X-Rays (2) | Section Summaries (1) | Summary (1) | X-Ray (1) | Cancel")

    local dialog = last_shown
    local function tap(label)
        for _idx, row in ipairs(dialog.buttons) do
            if row[1].text == label then events = {}; row[1].callback(); return end
        end
        error("no button " .. label)
    end
    tap("Generated Images (5)")
    TestRunner:assertEqual(table.concat(events, " | "), "gallery nil", "the gallery's own list of places")

    tap("Pinned Artifacts (4)")
    local list = last_shown
    TestRunner:assertEqual(list.title, "Pinned Artifacts (all books)", "the kind's list")
    local items = {}
    for _idx, item in ipairs(list.item_table) do items[#items + 1] = item.text .. " [" .. tostring(item.mandatory) .. "]" end
    TestRunner:assertEqual(items[1], "General (Pinned) [2 \u{00B7} " .. require("koassistant.core.constants").formatRelativeTime(5) .. "]",
        "the general pins first")
    TestRunner:assertTrue(items[2] ~= nil and items[2]:find("^Title of a%.epub %[2") ~= nil, "then the book: " .. tostring(items[2]))

    tap("Section X-Rays (2)")
    events = {}
    last_shown.item_table[1].callback()
    TestRunner:assertEqual(table.concat(events, " | "), "popup _showSectionXrayGroupPopup",
        "a book's row opens that book's popup")
end)

-- ---------------------------------------------------------------------------
-- The surfaces on the one opener, end to end: the row a reader taps reaches
-- its destination, with the surface's own chrome closed
-- ---------------------------------------------------------------------------

print("\n  [the surfaces]")

local function tapButton(dialog, prefix)
    for _idx, row in ipairs(dialog.buttons or {}) do
        local text = row[1] and row[1].text or ""
        if text:sub(1, #prefix) == prefix then
            events = {}
            row[1].callback()
            return table.concat(events, " | ")
        end
    end
    error("no button starting " .. prefix)
end

TestRunner:test("the artifact browser's selector opens rows through the opener", function()
    stubModule("apps/reader/readerui", { instance = nil })
    stubModule("koassistant.images.image_generator", { booksWithImages = function() return IMAGE_BOOKS end })
    local closed = {}
    stubField(package.loaded["ui/uimanager"], "close", function(_self, w) closed[#closed + 1] = w end)

    last_shown = nil
    ArtifactBrowser:showArtifactSelector(BOOK_A, "Book A", {})
    local selector = last_shown
    TestRunner:assertTrue(selector ~= nil and selector.title == "Book A", "the selector is shown")
    TestRunner:assertEqual(tapButton(selector, "Recap"), "viewCachedAction recap " .. BOOK_A, "a saved result")
    TestRunner:assertTrue(closed[#closed] == selector, "the selector closed before the viewer")
    TestRunner:assertEqual(tapButton(selector, "Previous X-Ray Versions"),
        "versions " .. BOOK_A .. " close_browser", "the versions list gets the deferred close")
    TestRunner:assertEqual(tapButton(selector, "View Section X-Rays"), "popup _showSectionXrayGroupPopup",
        "a group row opens its popup")

    -- Select mode (Attach): no image or versions rows; a pick attaches
    local attached
    last_shown = nil
    ArtifactBrowser:showArtifactSelector(BOOK_A, "Book A",
        { select_mode = { on_select = function(entry) attached = entry end } })
    local texts = {}
    for _idx, row in ipairs(last_shown.buttons) do texts[#texts + 1] = row[1].text end
    local joined = table.concat(texts, " | ")
    TestRunner:assertTrue(not joined:find("Generated Images", 1, true)
        and not joined:find("X-Ray Versions", 1, true), "no image or versions rows: " .. joined)
    tapButton(last_shown, "Recap")
    TestRunner:assertTrue(attached ~= nil and attached.key == "recap", "the pick is attached")
end)

-- The X-Ray browser, fresh, so it holds this file's UIManager
stubModule("ui/event", classStub())
stubModule("ui/widget/textviewer", classStub())
stubModule("device", {
    screen = {
        getWidth = function() return 800 end,
        getHeight = function() return 600 end,
        scaleBySize = function(_self, n) return n end,
    },
    isTouchDevice = function() return false end,
    hasKeys = function() return false end,
})
local saved_xray_browser = package.loaded["koassistant.xray.xray_browser"]
package.loaded["koassistant.xray.xray_browser"] = nil
local XrayBrowser = require("koassistant.xray.xray_browser")

TestRunner:test("the X-Ray browser opens its other artifacts through the opener", function()
    local closed = {}
    stubField(package.loaded["ui/uimanager"], "close", function(_self, w) closed[#closed + 1] = w end)
    local function host()
        closed, events = {}, {}
        return setmetatable({ metadata = { plugin = plugin, book_file = BOOK_A, title = "Book A",
            book_author = "Someone" }, menu = "MENU", _artifacts_dialog = "DIALOG" }, { __index = XrayBrowser })
    end
    local rows = byKey(rowsOf(BOOK_A))
    local h = host()
    h:_openArtifact(rows.recap)
    TestRunner:assertEqual(table.concat(closed, ","), "DIALOG", "a saved result: the popup closes, the browser stays")
    TestRunner:assertEqual(table.concat(events, " | "), "viewCachedAction recap " .. BOOK_A)
    h = host()
    h:_openArtifact(rows._xray_cache)
    TestRunner:assertEqual(table.concat(closed, ","), "DIALOG,MENU", "another X-Ray browser: this one closes first")
    h = host()
    h:_openArtifact(rows._xray_versions)
    TestRunner:assertEqual(table.concat(closed, ","), "DIALOG,MENU", "the versions list: this one closes first")
    h = host()
    h:_openArtifact(rows._generated_images)
    TestRunner:assertEqual(table.concat(closed, ","), "DIALOG", "the gallery opens on top")
    h = host()
    h:_openArtifact(rows._wiki_entries)
    TestRunner:assertEqual(#closed, 0, "a group's popup stacks on the Other Artifacts popup")
    last_on_select()
    TestRunner:assertEqual(table.concat(closed, ","), "DIALOG", "a pick closes the Other Artifacts popup")
end)

TestRunner:test("the section X-Rays' AI merge row closes the surface only once the merge starts", function()
    local merged
    local merger = setmetatable({ _startSectionXrayMergeFlow = function(_self, path, opts)
        merged = { path = path, opts = opts }
    end }, { __index = plugin })
    local closed_surface = 0
    last_shown = nil
    real_section_xray_popup(ArtifactBrowser, sections[BOOK_A][ActionCache.SECTION_XRAY_PREFIX],
        BOOK_A, "Book A", merger, nil, function() closed_surface = closed_surface + 1 end, nil, "Someone")
    local tapped = false
    for _idx, row in ipairs(last_shown.buttons) do
        if row[1].text == "AI merge section X-Rays…" then row[1].callback(); tapped = true end
    end
    TestRunner:assertTrue(tapped, "the merge row is there")
    TestRunner:assertEqual(closed_surface, 0, "nothing under the popup closes before the flow starts")
    TestRunner:assertTrue(merged ~= nil and merged.path == BOOK_A and merged.opts.book_author == "Someone",
        "the flow gets the book")
    merged.opts.close_browser()
    TestRunner:assertEqual(closed_surface, 1, "the flow closes the surface when it starts (T11)")
end)

TestRunner:test("the book's author reaches the group popups and their viewers", function()
    local rows = byKey(rowsOf(BOOK_A))
    events, last_popup_author = {}, nil
    ArtifactBrowser.openRow(rows._summary_sections, { plugin = plugin, file = BOOK_A, title = "Book A",
        author = "Someone" })
    TestRunner:assertEqual(last_popup_author, "Someone", "the popup gets the author")
    last_viewer_info = nil
    last_shown = nil
    real_section_popup(ArtifactBrowser, sections[BOOK_A][ActionCache.SECTION_PREFIXES.summary],
        BOOK_A, "Book A", plugin, "summary", nil, nil, nil, "Someone")
    last_shown.buttons[1][1].callback()
    TestRunner:assertTrue(last_viewer_info ~= nil and last_viewer_info.book_author == "Someone",
        "a pick's viewer carries it")
end)

TestRunner:test("the open book's own props fill a title or author a surface did not pass", function()
    local rows = byKey(rowsOf(BOOK_A))
    local reader = setmetatable({ ui = { document = { file = BOOK_A },
        doc_props = { display_title = "Shown Title", authors = "Author A" } } }, { __index = plugin })
    last_viewer_info = nil
    ArtifactBrowser.openRow(rows._summary_cache, { plugin = reader, file = BOOK_A, title = "Book A" })
    TestRunner:assertEqual(last_viewer_info.book_title .. " / " .. tostring(last_viewer_info.book_author),
        "Book A / Author A", "a given title stays, the author comes from the open book")
    ArtifactBrowser.openRow(rows._summary_cache, { plugin = reader, file = BOOK_A })
    TestRunner:assertEqual(last_viewer_info.book_title, "Shown Title", "no title given: the open book's")
    last_viewer_info = nil
    ArtifactBrowser.openRow(rows._summary_cache, { plugin = reader, file = BOOK_B, title = "Book B" })
    TestRunner:assertTrue(last_viewer_info.book_author == nil, "another book's author is not the open book's")
end)

TestRunner:test("pins outside any book, opened from Browse by type, go back to its list", function()
    stubField(PinnedManager, "getGeneralPinned", function()
        return { { id = "g1", name = "A general pin", result = "r", timestamp = 5 } }
    end)
    local kinds = ArtifactBrowser.typeKinds({}, { general = { count = 1, modified = 5 } })
    last_shown = nil
    ArtifactBrowser:_showTypeList(kinds[1], plugin, {})
    local type_list = last_shown
    type_list.item_table[1].callback()
    local pinned_list = last_shown
    TestRunner:assertTrue(pinned_list ~= type_list and pinned_list.title == "General (Pinned)",
        "the general pins open")
    pinned_list.onReturn()
    TestRunner:assertTrue(last_shown == pinned_list, "back rebuilds no browser over the type list")
end)

TestRunner:test("the Book Hub lists a book's section quizzes under Quiz, open or closed", function()
    -- a fresh copy, so it shows its popup through this file's UIManager
    stubModule("koassistant.books.book_page", nil)
    local BookPage = require("koassistant.books.book_page")
    local WITH_QUIZ, SECTIONS_ONLY = "/books/q.epub", "/books/s.epub"
    local quiz_sections = { [ActionCache.SECTION_PREFIXES.quiz] = {
        { key = "quiz_section:1", label = "Part 1", data = entry("q", 11) } } }
    caches[WITH_QUIZ] = { quiz = entry('{"questions":[]}', 10) }
    sections[WITH_QUIZ], sections[SECTIONS_ONLY] = quiz_sections, quiz_sections
    local function keysOf(rows)
        local keys = {}
        for _idx, row in ipairs(rows) do keys[#keys + 1] = row.key end
        return table.concat(keys, ",")
    end
    local rows = rowsOf(WITH_QUIZ)
    TestRunner:assertEqual(keysOf(rows), "quiz,_quiz_sections", "the aggregation lists both")
    local taken = BookPage.takeSectionQuizzes(rows)
    TestRunner:assertEqual(keysOf(rows), "quiz", "the page lists the Quiz row only")
    TestRunner:assertTrue(taken ~= nil and taken.key == "_quiz_sections", "and keeps the section quizzes for it")
    local only = rowsOf(SECTIONS_ONLY)
    TestRunner:assertTrue(BookPage.takeSectionQuizzes(only) == nil, "without a Quiz row nothing is taken")
    TestRunner:assertEqual(keysOf(only), "_quiz_sections", "and their own row stays")

    local hub_plugin = setmetatable({
        executeBookLevelAction = function(_self, id) record("action " .. id) end,
    }, { __index = plugin })
    local function quiz(sections_row, is_open)
        events, last_shown = {}, nil
        BookPage.openQuiz(rows[1], sections_row, { plugin = hub_plugin, file = WITH_QUIZ, title = "Q",
            is_open_book = is_open })
        return table.concat(events, " | ")
    end
    TestRunner:assertEqual(quiz(taken, true), "action quiz", "an open book's Quiz opens the quiz popup")
    TestRunner:assertEqual(quiz(nil, false), "viewCachedAction quiz " .. WITH_QUIZ,
        "a closed book without section quizzes opens the quiz")
    TestRunner:assertEqual(quiz(taken, false), "", "a closed book with section quizzes asks first")
    local dialog = last_shown
    TestRunner:assertTrue(dialog ~= nil and #dialog.buttons == 3, "the quiz, the section quizzes, Cancel")
    TestRunner:assertEqual(tapButton(dialog, "View Quiz"), "viewCachedAction quiz " .. WITH_QUIZ, "the quiz")
    TestRunner:assertEqual(tapButton(dialog, "View Section Quizzes (1)"), "popup _showSectionGroupPopup",
        "the section quizzes' popup")
    caches[WITH_QUIZ], sections[WITH_QUIZ], sections[SECTIONS_ONLY] = nil, nil, nil

    -- the page takes them for every book and its Quiz row goes through openQuiz
    local f = assert(io.open(plugin_dir .. "/koassistant/books/book_page.lua", "r"))
    local src = f:read("*a")
    f:close()
    TestRunner:assertTrue(src:find("local quiz_sections = BookPage.takeSectionQuizzes(caches)\n", 1, true) ~= nil,
        "the page takes the section quizzes whether the book is open or not")
    TestRunner:assertTrue(src:find("row_callback = function() BookPage.openQuiz(cache, quiz_sections, ctx) end", 1, true) ~= nil,
        "the Quiz row opens through openQuiz")
end)

-- ---------------------------------------------------------------------------
-- One source of truth: the group flags are the aggregation's contract with
-- the artifact browser (openRow, rowMeta, rowLabel, typeKinds, the selector's
-- select-mode filter). Every other surface labels rows through rowLabel or
-- rowMeta and opens them through openRow, so none reads a flag itself; the
-- Book Hub's row emoji and its versions prune are the only reads allowed.
-- ---------------------------------------------------------------------------

print("\n  [one source of truth]")

TestRunner:test("no file but the aggregation and the artifact browser reads the group flags", function()
    local OWNERS = {
        ["koassistant/artifacts/action_cache.lua"] = true,
        ["koassistant/artifacts/artifact_browser.lua"] = true,
    }
    local ALLOWED = {
        ["koassistant/books/book_page.lua"] = {
            'if cache.is_pinned_group then return "📌" end',
            'if cache.is_image_group then return "🖼️" end',
            "if not cache.is_xray_versions_group or cache.is_orphan then",
        },
    }
    local files = { "main.lua" }
    local list = assert(io.popen('cd "' .. plugin_dir .. '" && find koassistant -name "*.lua"'))
    for rel in list:lines() do files[#files + 1] = rel end
    list:close()
    TestRunner:assertTrue(#files > 50, "the plugin's files are found")
    local offenders = {}
    for _idx, rel in ipairs(files) do
        if not OWNERS[rel] then
            local f = assert(io.open(plugin_dir .. "/" .. rel, "r"))
            local n = 0
            for line in f:lines() do
                n = n + 1
                if line:find("is_[%w_]+_group") or line:find("is_per_action", 1, true) then
                    local allowed = false
                    for _idx2, text in ipairs(ALLOWED[rel] or {}) do
                        if line:find(text, 1, true) then allowed = true end
                    end
                    if not allowed then offenders[#offenders + 1] = rel .. ":" .. n end
                end
            end
            f:close()
        end
    end
    TestRunner:assertEqual(table.concat(offenders, ", "), "",
        "group flags read outside the aggregation and the artifact browser (label rows with rowLabel/rowMeta, open them with openRow)")
end)

TestRunner:test("a row's label: a saved result's progress and age, a group's own name", function()
    local rows = byKey(rowsOf(BOOK_A))
    TestRunner:assertEqual(ArtifactBrowser.rowLabel(rows._wiki_entries), "AI Wiki Entries (3)")
    TestRunner:assertEqual(ArtifactBrowser.rowLabel(rows._generated_images), "Generated Images (4)")
    TestRunner:assertTrue(ArtifactBrowser.rowMeta(rows._pinned_artifacts) == nil, "a group row has no meta")
    local stamped = { name = "Recap", data = { result = "r", progress_decimal = 0.06, timestamp = os.time() } }
    TestRunner:assertEqual(ArtifactBrowser.rowLabel(stamped), "Recap (6%, today)")
end)

-- ---------------------------------------------------------------------------
-- The X-Ray versions list and its actions act on the book they are opened
-- for (B492): a row for another book passes that book, and these resolve the
-- named book first, the open book only when none is named
-- ---------------------------------------------------------------------------

print("\n  [the versions list's book]")

TestRunner:test("the versions list and the version actions resolve the named book first", function()
    local f = assert(io.open(plugin_dir .. "/main.lua", "r"))
    local src = f:read("*a")
    f:close()
    -- whitespace folded, so a resolution split over two lines is caught too
    local flat = src:gsub("%s+", " ")
    TestRunner:assertTrue(not flat:find("self.ui.document.file) or (opts and opts.file)", 1, true),
        "no function takes the open book before the book it is given")
    for _idx, fn in ipairs({ "_showXrayCheckpointList", "_showXrayLadderRungOptions",
            "_showXrayCheckpointOptions", "_switchToCompleteXrayRung", "_switchBackToPositionRung",
            "_installAheadXrayRung", "_showSectionXrayList" }) do
        local from = src:find("function AskGPT:" .. fn .. "(", 1, true)
        TestRunner:assertTrue(from ~= nil, fn .. " is found")
        local body = src:sub(from, from + 1200)
        TestRunner:assertTrue(body:find("local file = (opts and opts.file) or (self.ui", 1, true) ~= nil,
            fn .. " resolves the named book first")
    end
end)

-- ---------------------------------------------------------------------------
-- B491: a listing parses the book's cache once (it parsed it 23 times: once
-- per saved kind, per section kind and for the wiki entries). Last in the
-- file: it puts the real getters back over the fixture's.
-- ---------------------------------------------------------------------------

print("\n  [one parse per listing]")

TestRunner:test("a listing parses the book's cache once", function()
    local parses = 0
    -- loadCache asks for the path once per parse; nil = an empty cache
    stubField(ActionCache, "getPath", function() parses = parses + 1 return nil end)
    for name, fn in pairs(real_getters) do stubField(ActionCache, name, fn) end
    ActionCache.getAvailableArtifactsWithPinned(BOOK_A, nil, nil, { image_books = {} })
    TestRunner:assertEqual(parses, 1, "one parse per listing")
end)

-- ---------------------------------------------------------------------------

for i = #saved_fields, 1, -1 do
    local s = saved_fields[i]
    s.tbl[s.key] = s.value
end
for name, saved in pairs(saved_loaded) do package.loaded[name] = saved.value end
package.loaded["koassistant.artifacts.artifact_browser"] = saved_browser
package.loaded["koassistant.xray.xray_browser"] = saved_xray_browser
for name in pairs(package.loaded) do
    if not loaded_before[name] and name:match("^koassistant%.") then package.loaded[name] = nil end
end
_G.G_reader_settings = saved_settings

TestRunner:summary()
return TestRunner.failed == 0
