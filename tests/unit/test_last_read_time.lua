--[[
Unit Tests for {time_since_last_read} (B466)

The value is when KOReader's statistics database last recorded the book being
read, not the book file's access time (opening a book reads its file, so that
said "Just now" at every open):
- ContextExtractor.timeSinceText: the wording ladder (pure)
- StatsReader.getLastReadTime: the query and its failure modes (stubbed sqlite)
- ContextExtractor:extractForAction: the reading-position gate is unchanged, the
  database is read only for a prompt that carries the placeholder, and nothing is
  sent when the database has no record of the book

Run: lua tests/run_tests.lua --unit
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

local ContextExtractor = require("koassistant.request.context_extractor")
local StatsReader = require("koassistant.books.stats_reader")

local TestRunner = {
    passed = 0,
    failed = 0,
}

function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        self.passed = self.passed + 1
        print(string.format("  \226\156\147 %s", name))
    else
        self.failed = self.failed + 1
        print(string.format("  \226\156\151 %s: %s", name, tostring(err)))
    end
end

function TestRunner:assertEqual(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s\nExpected: %s\nActual: %s",
            msg or "Values not equal", tostring(expected), tostring(actual)), 2)
    end
end

function TestRunner:assertContains(str, substr, msg)
    if type(str) ~= "string" or not str:find(substr, 1, true) then
        error(string.format("%s\nExpected to contain: %s\nActual: %s",
            msg or "String does not contain substring", tostring(substr), tostring(str)), 2)
    end
end

-- ============================================================
-- The wording ladder (pure)
-- ============================================================

print("\n--- ContextExtractor.timeSinceText ---")

TestRunner:test("under a minute is Just now", function()
    TestRunner:assertEqual(ContextExtractor.timeSinceText(0), "Just now")
    TestRunner:assertEqual(ContextExtractor.timeSinceText(59), "Just now")
end)

TestRunner:test("minutes, singular and plural", function()
    TestRunner:assertEqual(ContextExtractor.timeSinceText(60), "1 minute ago")
    TestRunner:assertEqual(ContextExtractor.timeSinceText(119), "1 minute ago")
    TestRunner:assertEqual(ContextExtractor.timeSinceText(120), "2 minutes ago")
    TestRunner:assertEqual(ContextExtractor.timeSinceText(3599), "59 minutes ago")
end)

TestRunner:test("hours, singular and plural", function()
    TestRunner:assertEqual(ContextExtractor.timeSinceText(3600), "1 hour ago")
    TestRunner:assertEqual(ContextExtractor.timeSinceText(7200), "2 hours ago")
    TestRunner:assertEqual(ContextExtractor.timeSinceText(86399), "23 hours ago")
end)

TestRunner:test("days, singular and plural", function()
    TestRunner:assertEqual(ContextExtractor.timeSinceText(86400), "1 day ago")
    TestRunner:assertEqual(ContextExtractor.timeSinceText(2 * 86400), "2 days ago")
    TestRunner:assertEqual(ContextExtractor.timeSinceText(400 * 86400), "400 days ago")
end)

TestRunner:test("a time ahead of now (clock set back) is Just now", function()
    TestRunner:assertEqual(ContextExtractor.timeSinceText(-5000), "Just now")
end)

-- ============================================================
-- StatsReader.getLastReadTime against a stubbed sqlite module
-- ============================================================

print("\n--- StatsReader.getLastReadTime ---")

--- Run fn with the statistics database replaced by a stub, restoring everything after.
-- stub = { db = path|nil, result = exec's result, exec_error = bool, open_error = bool }
-- Returns what the stub saw: opened (times), mode, sql, closed.
local function withStatsDb(stub, fn)
    local saved_path = StatsReader.getDbPath
    local saved_sq3 = package.loaded["lua-ljsqlite3/init"]
    local seen = { opened = 0, closed = false }
    StatsReader.getDbPath = function() return stub.db end
    package.loaded["lua-ljsqlite3/init"] = {
        open = function(path, mode)
            seen.opened = seen.opened + 1
            seen.path, seen.mode = path, mode
            if stub.open_error then error("unable to open database file") end
            return {
                exec = function(_self, sql)
                    seen.sql = sql
                    if stub.exec_error then error("no such table: page_stat_data") end
                    return stub.result
                end,
                close = function() seen.closed = true end,
            }
        end,
    }
    local ok, err = pcall(fn, seen)
    StatsReader.getDbPath = saved_path
    package.loaded["lua-ljsqlite3/init"] = saved_sq3
    if not ok then error(err, 0) end
end

TestRunner:test("returns the newest page view's time, asked of this book's md5, read-only", function()
    withStatsDb({ db = "/stub/statistics.sqlite3", result = { last_read = { 1700000000 } } }, function(seen)
        TestRunner:assertEqual(StatsReader.getLastReadTime("0123abcdef"), 1700000000)
        TestRunner:assertEqual(seen.mode, "ro", "never writes the reader's statistics")
        TestRunner:assertEqual(seen.path, "/stub/statistics.sqlite3")
        TestRunner:assertContains(seen.sql, "md5 = '0123abcdef'")
        TestRunner:assertContains(seen.sql, "page_stat_data", "page views, not the book row's last_open")
        TestRunner:assertEqual(seen.closed, true, "the connection is closed")
    end)
end)

TestRunner:test("a database number held as text still reads as a number", function()
    withStatsDb({ db = "/stub/s.sqlite3", result = { last_read = { "1700000123" } } }, function()
        TestRunner:assertEqual(StatsReader.getLastReadTime("ABCDEF0123"), 1700000123)
    end)
end)

TestRunner:test("no stored page view for the book is nil, never a guess", function()
    withStatsDb({ db = "/stub/s.sqlite3", result = { last_read = {} } }, function()
        TestRunner:assertEqual(StatsReader.getLastReadTime("0123abcdef"), nil, "MAX over no rows")
    end)
    withStatsDb({ db = "/stub/s.sqlite3", result = nil }, function()
        TestRunner:assertEqual(StatsReader.getLastReadTime("0123abcdef"), nil, "no result at all")
    end)
end)

TestRunner:test("a zero or negative time is not a record", function()
    withStatsDb({ db = "/stub/s.sqlite3", result = { last_read = { 0 } } }, function()
        TestRunner:assertEqual(StatsReader.getLastReadTime("0123abcdef"), nil)
    end)
    withStatsDb({ db = "/stub/s.sqlite3", result = { last_read = { -4 } } }, function()
        TestRunner:assertEqual(StatsReader.getLastReadTime("0123abcdef"), nil)
    end)
end)

TestRunner:test("a failing query is nil and the connection is still closed", function()
    withStatsDb({ db = "/stub/s.sqlite3", exec_error = true }, function(seen)
        TestRunner:assertEqual(StatsReader.getLastReadTime("0123abcdef"), nil)
        TestRunner:assertEqual(seen.closed, true)
    end)
end)

TestRunner:test("a database that cannot be opened is nil", function()
    withStatsDb({ db = "/stub/s.sqlite3", open_error = true }, function()
        TestRunner:assertEqual(StatsReader.getLastReadTime("0123abcdef"), nil)
    end)
end)

TestRunner:test("no statistics database is nil and nothing is opened", function()
    withStatsDb({ db = nil, result = { last_read = { 1700000000 } } }, function(seen)
        TestRunner:assertEqual(StatsReader.getLastReadTime("0123abcdef"), nil)
        TestRunner:assertEqual(seen.opened, 0)
    end)
end)

TestRunner:test("an md5 that is not plain hex never reaches the database", function()
    withStatsDb({ db = "/stub/s.sqlite3", result = { last_read = { 1700000000 } } }, function(seen)
        TestRunner:assertEqual(StatsReader.getLastReadTime("x'; DROP TABLE book;--"), nil)
        TestRunner:assertEqual(StatsReader.getLastReadTime("0123 abcdef"), nil)
        TestRunner:assertEqual(StatsReader.getLastReadTime(""), nil)
        TestRunner:assertEqual(StatsReader.getLastReadTime(nil), nil, "a book never opened has no md5")
        TestRunner:assertEqual(StatsReader.getLastReadTime(12345), nil)
        TestRunner:assertEqual(seen.opened, 0)
    end)
end)

-- ============================================================
-- The extractor: gate, trigger, no record
-- ============================================================

print("\n--- ContextExtractor:extractForAction ({time_since_last_read}) ---")

local BOOK = "/test/books/last_read_b466.epub"

--- Run fn with the sidecar's md5 and the statistics lookup replaced, restoring after.
-- last_read: nil = the database holds no record of the book, else seconds before now.
-- Returns via the table passed to fn: calls (lookups made) and md5 (what was asked).
local function withLastRead(last_read_ago, fn)
    local saved_docsettings = package.loaded["docsettings"]
    local saved_lookup = StatsReader.getLastReadTime
    local seen = { calls = 0 }
    package.loaded["docsettings"] = {
        open = function()
            return { readSetting = function(_self, key)
                if key == "partial_md5_checksum" then return "00ff00ff00ff" end
                return nil
            end }
        end,
    }
    StatsReader.getLastReadTime = function(md5)
        seen.calls = seen.calls + 1
        seen.md5 = md5
        if last_read_ago == nil then return nil end
        return os.time() - last_read_ago
    end
    local ok, err = pcall(fn, seen)
    package.loaded["docsettings"] = saved_docsettings
    StatsReader.getLastReadTime = saved_lookup
    if not ok then error(err, 0) end
end

local function sidecarExtractor(settings)
    settings = settings or {}
    settings.document_path = BOOK
    return ContextExtractor:new(nil, settings)
end

local RECAP_LINE = "I'm at {reading_progress}.\n{time_since_last_read_section}"

TestRunner:test("a closed book: the time since the statistics last saw it read", function()
    withLastRead(3 * 86400 + 100, function(seen)
        local data = sidecarExtractor():extractForAction({ prompt = RECAP_LINE })
        TestRunner:assertEqual(data.time_since_last_read, "3 days ago")
        TestRunner:assertEqual(seen.md5, "00ff00ff00ff", "the md5 in the book's own sidecar")
    end)
end)

TestRunner:test("minutes ago when the last page view was minutes ago", function()
    withLastRead(5 * 60 + 10, function()
        local data = sidecarExtractor():extractForAction({ prompt = RECAP_LINE })
        TestRunner:assertEqual(data.time_since_last_read, "5 minutes ago")
    end)
end)

TestRunner:test("the section form reads Last read: and vanishes without a record", function()
    local MessageBuilder = require("koassistant.request.message_builder")
    local with = MessageBuilder.build({
        prompt = { prompt = RECAP_LINE }, context = "general",
        data = { reading_progress = "42%", time_since_last_read = "3 days ago" },
    })
    TestRunner:assertContains(with, "I'm at 42%.\nLast read: 3 days ago", "the clause with a record")
    local without = MessageBuilder.build({
        prompt = { prompt = RECAP_LINE }, context = "general",
        data = { reading_progress = "42%", time_since_last_read = "" },
    })
    TestRunner:assertContains(without, "I'm at 42%.\n", "the position stays")
    TestRunner:assertEqual(without:find("Last read", 1, true), nil, "no clause without a record")
    TestRunner:assertEqual(without:find("{time_since_last_read", 1, true), nil, "no placeholder left")
end)

TestRunner:test("no record of the book sends nothing: not Recently, not Just now", function()
    withLastRead(nil, function(seen)
        local data = sidecarExtractor():extractForAction({ prompt = RECAP_LINE })
        TestRunner:assertEqual(data.time_since_last_read, "")
        TestRunner:assertEqual(seen.calls, 1)
    end)
end)

TestRunner:test("the reading-position gate is unchanged: off sends nothing and reads nothing", function()
    withLastRead(86400, function(seen)
        local data = sidecarExtractor({ enable_basic_stats = false })
            :extractForAction({ prompt = RECAP_LINE })
        TestRunner:assertEqual(data.time_since_last_read, "")
        TestRunner:assertEqual(data.chapter_title, "")
        TestRunner:assertEqual(seen.calls, 0, "the statistics are not even opened")
    end)
end)

TestRunner:test("the database is read only for a prompt that carries the placeholder", function()
    withLastRead(86400, function(seen)
        local data = sidecarExtractor():extractForAction({ prompt = "Summarize {title}." })
        TestRunner:assertEqual(data.time_since_last_read, "")
        TestRunner:assertEqual(seen.calls, 0)
    end)
end)

TestRunner:test("an update prompt that carries the placeholder reads it too", function()
    withLastRead(2 * 86400 + 5, function(seen)
        local data = sidecarExtractor():extractForAction({
            prompt = "Summarize {title}.",
            update_prompt = RECAP_LINE,
        })
        TestRunner:assertEqual(data.time_since_last_read, "2 days ago")
        TestRunner:assertEqual(seen.calls, 1)
    end)
end)

TestRunner:test("an open book is worded the same way", function()
    withLastRead(2 * 3600 + 50, function(seen)
        local ui = { document = { file = BOOK, info = {} } }
        local extractor = ContextExtractor:new(ui, {})
        extractor.getReadingProgress = function() return { percent = 40, formatted = "40%", decimal = 0.4 } end
        local data = extractor:extractForAction({ prompt = RECAP_LINE })
        TestRunner:assertEqual(data.time_since_last_read, "2 hours ago")
        TestRunner:assertEqual(seen.md5, "00ff00ff00ff")
    end)
end)

TestRunner:test("the file's access time is no longer read for the open book's stats", function()
    local ui = { document = { file = BOOK, info = {} } }
    local stats = ContextExtractor:new(ui, {}):getReadingStats()
    TestRunner:assertEqual(stats.time_since_last_read, nil)
    TestRunner:assertEqual(stats.last_read_timestamp, nil)
    TestRunner:assertEqual(stats.chapters_read, "0", "the rest of the stats are as before")
end)

-- ============================================================
-- Results
-- ============================================================

print(string.format("\n=== Results: %d passed, %d failed ===", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
