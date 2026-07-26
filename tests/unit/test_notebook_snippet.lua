--[[
Unit Tests for the notebook snippet capture path (koassistant_notebook.lua)

Covers:
- Notebook.formatSnippet() — pure formatter: Note vs Highlight headers, separator shape
- Notebook.appendSnippet() — sentinel/nil/empty-text rejection with user-displayable errors
- appendSnippet() round-trip against a real temp file (custom vault mode, index update)

Run: lua tests/run_tests.lua --unit
     or directly: lua tests/unit/test_notebook_snippet.lua (from repo root)
]]

-- Setup test environment
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

-- Save originals for teardown (suite runs all files in one Lua process)
local orig_G_reader_settings = _G.G_reader_settings
local orig_docsettings = package.loaded["docsettings"]
local orig_safe_docsettings = package.loaded["koassistant_doc_settings"]

-- G_reader_settings mock (LuaSettings-shaped: readSetting(key, default))
local grs_store = {}
_G.G_reader_settings = {
    readSetting = function(_, key, default)
        if grs_store[key] == nil then return default end
        return grs_store[key]
    end,
    saveSetting = function(_, key, value) grs_store[key] = value end,
    flush = function() end,
}

-- DocSettings mock (only the surface koassistant_notebook touches on these paths)
package.loaded["docsettings"] = {
    open = function() return { readSetting = function() return nil end, close = function() end } end,
    getSidecarDir = function(_, path) return "/tmp/koassistant_test_sdr" .. path .. ".sdr" end,
    isHashLocationEnabled = function() return false end,
}
package.loaded["koassistant_doc_settings"] = {
    resolve = function() return nil end,
}
-- util.makePath (used by Notebook.append). The suite runs all files in ONE Lua
-- process — an earlier test may already hold a "util" mock without makePath, so
-- extend whatever is there instead of replacing it.
local util_mod = package.loaded["util"]
if not util_mod then
    util_mod = {}
    package.loaded["util"] = util_mod
end
if not util_mod.makePath then
    util_mod.makePath = function(dir) os.execute("mkdir -p '" .. dir .. "'") end
end

-- Force a fresh module load so OUR mocks (not an earlier test file's) are captured
package.loaded["koassistant_notebook"] = nil
local Notebook = require("koassistant_notebook")

local TestRunner = { passed = 0, failed = 0 }

local function check(name, cond, detail)
    if cond then
        TestRunner.passed = TestRunner.passed + 1
        print("PASS: " .. name)
    else
        TestRunner.failed = TestRunner.failed + 1
        print("FAIL: " .. name .. (detail and ("\n      " .. tostring(detail)) or ""))
    end
end

local TS = "2026-07-16 10:30"

local function runFormatSnippetTests()
    print("\n--- formatSnippet ---")

    local plain = Notebook.formatSnippet("some text", nil, TS)
    check("no page_info → Note header",
        plain == "\n---\n\n*Note (" .. TS .. "):*\n\nsome text\n", plain)

    local page_only = Notebook.formatSnippet("t", { page = 42 }, TS)
    check("page only → Highlight header with page + timestamp",
        page_only:find("*Highlight (Page 42 • " .. TS .. "):*", 1, true) ~= nil, page_only)

    local page_progress = Notebook.formatSnippet("t", { page = 42, progress = 37 }, TS)
    check("page + progress",
        page_progress:find("*Highlight (Page 42 • 37% • " .. TS .. "):*", 1, true) ~= nil, page_progress)

    local full = Notebook.formatSnippet("t", { page = 42, progress = 37, chapter = "Chapter One" }, TS)
    check("page + progress + chapter",
        full:find("*Highlight (Page 42 • 37% • Chapter One • " .. TS .. "):*", 1, true) ~= nil, full)

    local no_page = Notebook.formatSnippet("t", { progress = 37, chapter = "Chapter One" }, TS)
    check("progress/chapter without page → Note header (page is the discriminator)",
        no_page:find("*Note (" .. TS .. "):*", 1, true) ~= nil, no_page)

    local sep = Notebook.formatSnippet("t", nil, TS)
    check("entry starts with separator and ends with newline",
        sep:sub(1, 6) == "\n---\n\n" and sep:sub(-1) == "\n", sep)
end

-- Defaults sweep D13: full_qa used to be byte-identical to qa even though the
-- setting promised "all context messages". Attach-chip attachments are what makes
-- it differ — these lock that in so it can't silently collapse back.
local function runFormatEntryTests()
    print("\n--- formatEntry content tiers (D13) ---")

    local PAGE = { timestamp = TS, page = 12 }
    local data = {
        action_name = "Explain",
        highlighted_text = "the selected phrase",
        follow_up = "why does this matter?",
        response = "Because of X.",
        attachments = { "[Note from the reader]\nvillain's motive is revenge" },
    }

    local full = Notebook.formatEntry(data, PAGE, "full_qa")
    check("full_qa renders an Attached section",
        full:find("**Attached:**", 1, true) ~= nil, full)
    check("full_qa includes the attachment text",
        full:find("villain's motive is revenge", 1, true) ~= nil, full)
    check("full_qa still has highlight, question and response",
        full:find("the selected phrase", 1, true) and full:find("why does this matter?", 1, true)
        and full:find("Because of X.", 1, true), full)

    local qa = Notebook.formatEntry(data, PAGE, "qa")
    check("qa does NOT render attachments",
        qa:find("**Attached:**", 1, true) == nil
        and qa:find("villain's motive", 1, true) == nil, qa)
    check("qa keeps highlight + question + response",
        qa:find("the selected phrase", 1, true) and qa:find("why does this matter?", 1, true)
        and qa:find("Because of X.", 1, true), qa)

    local response_only = Notebook.formatEntry(data, PAGE, "response")
    check("response tier drops attachments, highlight and question",
        response_only:find("**Attached:**", 1, true) == nil
        and response_only:find("the selected phrase", 1, true) == nil
        and response_only:find("why does this matter?", 1, true) == nil
        and response_only:find("Because of X.", 1, true) ~= nil, response_only)

    -- The common case: nothing attached. full_qa must stay identical to qa.
    local bare = {
        action_name = "Explain",
        highlighted_text = "the selected phrase",
        follow_up = "why?",
        response = "Because.",
    }
    check("with no attachments, full_qa == qa (no stray heading)",
        Notebook.formatEntry(bare, PAGE, "full_qa") == Notebook.formatEntry(bare, PAGE, "qa"))

    check("empty attachments table is treated as none",
        Notebook.formatEntry({ response = "R", attachments = {} }, PAGE, "full_qa")
            :find("**Attached:**", 1, true) == nil)
end

-- saveChat renders a multi-turn chat as first-question + last-answer, so attachments
-- must be scoped to the first exchange or a later round's attachment would be printed
-- next to an unrelated question (review finding, 2026-07-26).
local function runSaveChatScopeTests()
    print("\n--- saveChat attachment scoping (D13) ---")

    local function fakeHistory(messages)
        return { prompt_action = "Explain", getMessages = function() return messages end }
    end

    local captured
    local orig_format = Notebook.formatEntry
    Notebook.formatEntry = function(data, ...) captured = data; return orig_format(data, ...) end

    -- getPageInfo falls back to ReaderUI.instance when no ui is passed
    local orig_readerui = package.loaded["apps/reader/readerui"]
    package.loaded["apps/reader/readerui"] = { instance = nil }

    local tmpdir = "/tmp/koassistant_savechat_test_" .. tostring(os.time())
    os.execute("mkdir -p '" .. tmpdir .. "'")
    local doc_path = "/tmp/books/scope_book.epub"
    Notebook.init({ readSetting = function(_, key)
        if key == "features" then
            return { notebook_save_location = "custom", notebook_custom_path = tmpdir }
        end
    end })
    grs_store["koassistant_notebook_index"] = { [doc_path] = { filename = "Scope Book.md" } }
    local f = assert(io.open(tmpdir .. "/Scope Book.md", "w"))
    f:write("# Notebook: Scope Book\n")
    f:close()

    -- Round 1 attaches a note; round 2 attaches a different one after the first answer.
    Notebook.saveChat(doc_path, fakeHistory({
        { role = "user", content = "[Context] ctx", is_context = true },
        { role = "user", content = "ATTACH-ROUND-1", is_context = true },
        { role = "user", content = "question 1", is_context = false },
        { role = "assistant", content = "answer 1" },
        { role = "user", content = "ATTACH-ROUND-2", is_context = true },
        { role = "user", content = "question 2", is_context = false },
        { role = "assistant", content = "answer 2" },
    }), nil, nil, "full_qa", "test-model")

    local joined = table.concat(captured.attachments or {}, "|")
    check("first-round attachment is kept", joined:find("ATTACH-ROUND-1", 1, true) ~= nil, joined)
    check("later-round attachment is NOT pooled in",
        joined:find("ATTACH-ROUND-2", 1, true) == nil, joined)

    Notebook.formatEntry = orig_format
    package.loaded["apps/reader/readerui"] = orig_readerui
    Notebook.init(nil)
    grs_store["koassistant_notebook_index"] = nil
    os.execute("rm -rf '" .. tmpdir .. "'")
end

local function runGuardTests()
    print("\n--- appendSnippet guards ---")

    local ok, err = Notebook.appendSnippet(nil, "text")
    check("nil document_path → false + error", ok == false and type(err) == "string", err)

    local ok2, err2 = Notebook.appendSnippet("__GENERAL_CHATS__", "text")
    check("general sentinel → false + error", ok2 == false and type(err2) == "string", err2)

    local ok3, err3 = Notebook.appendSnippet("__LIBRARY_CHATS__", "text")
    check("library sentinel → false + error", ok3 == false and type(err3) == "string", err3)

    local ok4, err4 = Notebook.appendSnippet("/tmp/some_book.epub", "")
    check("empty text → false + error", ok4 == false and type(err4) == "string", err4)

    local ok5 = Notebook.appendSnippet("/tmp/some_book.epub", nil)
    check("nil text → false", ok5 == false)
end

local function runRoundTripTests()
    print("\n--- appendSnippet round-trip (custom vault mode, pre-existing notebook) ---")

    local tmpdir = "/tmp/koassistant_snippet_test_" .. tostring(os.time())
    os.execute("mkdir -p '" .. tmpdir .. "'")
    local doc_path = "/tmp/books/test_book.epub"
    local nb_file = tmpdir .. "/Test Book.md"

    -- Custom vault mode via plugin settings; index fast-path supplies the filename
    -- (avoids DocSettings-driven filename generation — not under test here)
    local features = { notebook_save_location = "custom", notebook_custom_path = tmpdir }
    Notebook.init({ readSetting = function(_, key)
        if key == "features" then return features end
    end })
    grs_store["koassistant_notebook_index"] = { [doc_path] = { filename = "Test Book.md" } }

    -- Pre-create the notebook so exists() passes without create()
    local f = assert(io.open(nb_file, "w"))
    f:write("# Notebook: Test Book\n")
    f:close()

    local ok, err = Notebook.appendSnippet(doc_path, "captured passage",
        { page_info = { page = 7, progress = 12 }, timestamp = TS })
    check("append succeeds", ok == true, err)

    local rf = assert(io.open(nb_file, "r"))
    local content = rf:read("*a")
    rf:close()
    check("file contains formatted Highlight entry",
        content:find("*Highlight (Page 7 • 12% • " .. TS .. "):*", 1, true) ~= nil, content)
    check("file contains the snippet text",
        content:find("captured passage", 1, true) ~= nil)

    local index = grs_store["koassistant_notebook_index"]
    check("index entry refreshed with stats",
        index and index[doc_path] and index[doc_path].size ~= nil
        and index[doc_path].filename == "Test Book.md")

    -- Reset module-level settings ref so later suites see the default path
    Notebook.init(nil)
    grs_store["koassistant_notebook_index"] = nil
    os.execute("rm -rf '" .. tmpdir .. "'")
end

local function teardown()
    -- Restore shared-process state so later suite files don't inherit our mocks
    _G.G_reader_settings = orig_G_reader_settings
    package.loaded["docsettings"] = orig_docsettings
    package.loaded["koassistant_doc_settings"] = orig_safe_docsettings
    package.loaded["koassistant_notebook"] = nil
end

local function runAll()
    print("=== test_notebook_snippet ===")
    runFormatSnippetTests()
    runFormatEntryTests()
    runSaveChatScopeTests()
    runGuardTests()
    runRoundTripTests()
    teardown()
    print(string.format("\n=== Results: %d passed, %d failed ===\n", TestRunner.passed, TestRunner.failed))
    return TestRunner.failed == 0
end

-- Run tests if executed directly
if arg and arg[0] and arg[0]:match("test_notebook_snippet%.lua$") then
    local success = runAll()
    os.exit(success and 0 or 1)
end

return {
    runAll = runAll,
    TestRunner = TestRunner,
}
