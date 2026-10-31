-- B480: a failed request is a notice that stays until tapped. It used to be a
-- 3-second toast, so "No API key found" or a 401 could be gone before it was
-- read. The reader's own cancel keeps the short toast; the rate-limit, overload
-- and account-wall refusals keep their persistent dialog with a retry button.
--
-- showRequestError is cut from the dialogs source and evaluated against stub
-- widgets (the test_front_matter_flow pattern): a guard that only greps can
-- pass while the code it names never runs.
--
-- Run: lua tests/unit/test_request_error_display.lua  (or lua tests/run_tests.lua --unit)

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
local TestRunner = require("test_runner"):new()

local function source(rel)
    local f = assert(io.open(plugin_dir .. "/" .. rel, "r"))
    local s = f:read("*a")
    f:close()
    return s
end
local dialogs_src = source("koassistant/ui/dialogs.lua")

local body = dialogs_src:match("(local function showRequestError%(.-\nend\n)\n%-%- Helper function to determine prompt context")
assert(body, "showRequestError: not found in the source")

--- A fresh showRequestError over stub widgets. `translate` stands in for gettext.
-- Returns the function and the list of widgets it showed.
local function build(translate)
    local shown = {}
    local UI = {
        show = function(_self, widget) table.insert(shown, widget) end,
        close = function() end,
    }
    local IM = { new = function(_self, o) o.kind = "notice"; return o end }
    local BD = { new = function(_self, o) o.kind = "dialog"; return o end }
    local MC = {
        isBillingWall = function(t) return type(t) == "string" and t:find("credit balance", 1, true) ~= nil end,
        isRateLimitError = function(t) return type(t) == "string" and t:find("rate limit", 1, true) ~= nil end,
        isOverloadError = function(t) return type(t) == "string" and t:find("overloaded", 1, true) ~= nil end,
    }
    local chunk = assert(load(
        "local ModelConstraints, UIManager, ButtonDialog, InfoMessage, _, ERROR_DIALOG_MAX_CHARS = ...\n"
            .. body .. "\nreturn showRequestError",
        "showRequestError"))
    return chunk(MC, UI, BD, IM, translate or function(s) return s end, 400), shown
end

local retry = function() end

print("\n  [a failure stays until tapped]")

TestRunner:test("a missing key is a notice with no timeout", function()
    local show, shown = build()
    show("Error: No API key found for anthropic.")
    TestRunner:assertEqual(#shown, 1)
    TestRunner:assertEqual(shown[1].kind, "notice")
    TestRunner:assertEqual(shown[1].timeout, nil, "it stays until tapped")
end)

TestRunner:test("a refused request (401) with a retry on offer is still a notice with no timeout", function()
    local show, shown = build()
    show("Error: 401 invalid x-api-key", retry)
    TestRunner:assertEqual(shown[1].kind, "notice")
    TestRunner:assertEqual(shown[1].timeout, nil)
end)

TestRunner:test("the caller's toast length does not shorten a failure", function()
    local show, shown = build()
    show("Error: 401 invalid x-api-key", retry, 6)
    TestRunner:assertEqual(shown[1].timeout, nil, "6 was the recoverable-input toast; a failure has none")
end)

print("\n  [the reader's cancel keeps the short toast]")

TestRunner:test("a cancel is a 3-second toast by default", function()
    local show, shown = build()
    show("Request cancelled by user.")
    TestRunner:assertEqual(shown[1].kind, "notice")
    TestRunner:assertEqual(shown[1].timeout, 3)
end)

TestRunner:test("a cancel uses the caller's timeout", function()
    local show, shown = build()
    show("Request cancelled by user.", nil, 6)
    TestRunner:assertEqual(shown[1].timeout, 6)
end)

TestRunner:test("a cancel behind \"Error: \" or followed by the recovery hint is still a toast", function()
    local show, shown = build()
    show("Error: Request cancelled by user.")
    show("Request cancelled by user.\n\nYour typed input was saved.", retry, 6)
    TestRunner:assertEqual(shown[1].timeout, 3)
    TestRunner:assertEqual(shown[2].timeout, 6)
end)

TestRunner:test("the stream's English cancel is a toast under a translated interface", function()
    local show, shown = build(function(s)
        if s == "Request cancelled by user." then return "Anfrage abgebrochen." end
        return s
    end)
    show("Request cancelled by user.")          -- the stream's untranslated wording
    show("Anfrage abgebrochen.")                -- the translated wording
    TestRunner:assertEqual(shown[1].timeout, 3)
    TestRunner:assertEqual(shown[2].timeout, 3)
end)

print("\n  [the refusals with their own handling are unchanged]")

TestRunner:test("rate limit, overload and account wall keep the dialog with a retry", function()
    for _idx, text in ipairs({ "rate limit exceeded", "model is overloaded", "credit balance is too low" }) do
        local show, shown = build()
        show(text, retry)
        TestRunner:assertEqual(shown[1].kind, "dialog", text)
        TestRunner:assertEqual(shown[1].timeout, nil)
    end
end)

TestRunner:test("without a retry even a refusal falls back to the notice, which stays", function()
    local show, shown = build()
    show("rate limit exceeded")
    TestRunner:assertEqual(shown[1].kind, "notice")
    TestRunner:assertEqual(shown[1].timeout, nil)
end)

print("\n  [every request-error toast goes through it]")

TestRunner:test("no \"Error: \" notice is built by hand any more", function()
    TestRunner:assertFalse(dialogs_src:find('InfoMessage:new{%s*text = _%("Error: "%)'),
        "an InfoMessage with a timeout beside showRequestError would vanish again")
end)

return TestRunner:summary()
