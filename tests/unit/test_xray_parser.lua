-- Unit tests for koassistant_xray_parser.lua JSON extraction + shared unescaped-quote repair.

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({
        plugin_dir .. "/?.lua", tests_dir .. "/?.lua", tests_dir .. "/lib/?.lua", package.path,
    }, ";")
end
setupPaths()
require("mock_koreader")

local XrayParser = require("koassistant_xray_parser")

local TestRunner = { passed = 0, failed = 0 }
function TestRunner:suite(name) print(string.format("\n  [%s]", name)) end
function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then self.passed = self.passed + 1; print("    ✓ " .. name)
    else self.failed = self.failed + 1; print("    ✗ " .. name); print("      Error: " .. tostring(err)) end
end
function TestRunner:ok(v, msg) if not v then error(msg or "expected truthy") end end
function TestRunner:eq(a, b, msg)
    if a ~= b then error(string.format("%s: expected %q, got %q", msg or "eq", tostring(b), tostring(a))) end
end

TestRunner:suite("XrayParser.parse — well-formed")
TestRunner:test("raw fiction JSON", function()
    local d = XrayParser.parse('{"characters":[{"name":"Jack","description":"a man"}]}')
    TestRunner:ok(d); TestRunner:ok(d.characters)
end)
TestRunner:test("fenced JSON", function()
    local d = XrayParser.parse('```json\n{"characters":[{"name":"Wendy","description":"his wife"}]}\n```')
    TestRunner:ok(d); TestRunner:ok(d.characters)
end)
TestRunner:test("JSON with leading thinking text + trailing prose", function()
    local d = XrayParser.parse('Here is the X-Ray:\n```json\n{"characters":[{"name":"Danny","description":"the son"}]}\n```\nHope that helps.')
    TestRunner:ok(d); TestRunner:ok(d.characters)
end)

TestRunner:suite("XrayParser.parse — unescaped inner quotes (shared repair)")
TestRunner:test("raw double quotes in a description are recovered", function()
    local txt = '```json\n{"characters":[{"name":"Jack","description":"He says "all work and no play" repeatedly, echoing the "spirit" of the hotel."}]}\n```'
    local d, e = XrayParser.parse(txt)
    TestRunner:ok(d, "should recover via repair: " .. tostring(e))
    TestRunner:ok(d.characters)
    TestRunner:ok(d.characters[1].description:find("all work and no play"), "description content preserved")
end)
TestRunner:test("repair does not corrupt valid X-Ray", function()
    local d = XrayParser.parse('{"key_figures":[{"name":"Kant","description":"a philosopher"}],"core_concepts":[]}')
    TestRunner:ok(d); TestRunner:ok(d.key_figures)
end)

TestRunner:suite("round 28 — parse-time shape normalization (#90 field report)")
TestRunner:test("timeline of plain strings becomes {event} objects (fixes 'Unknown' rows)", function()
    local d = XrayParser.parse('{"characters":[{"name":"Jack"}],"timeline":["Jack arrives","The snow falls"]}')
    TestRunner:ok(d)
    TestRunner:eq(d.timeline[1].event, "Jack arrives")
    TestRunner:eq(XrayParser.getItemName(d.timeline[2], "timeline"), "The snow falls")
end)
TestRunner:test("connection objects coerce to 'Name (relationship)' strings", function()
    local d = XrayParser.parse('{"characters":[{"name":"Jack","connections":[{"name":"Wendy","relationship":"wife"},"Danny (son)"]}]}')
    TestRunner:ok(d)
    TestRunner:eq(d.characters[1].connections[1], "Wendy (wife)")
    TestRunner:eq(d.characters[1].connections[2], "Danny (son)")
end)
TestRunner:test("alias objects and numeric fields coerce; render survives (crash.log shape)", function()
    local d = XrayParser.parse('{"characters":[{"name":"Jack","role":{"description":"Protagonist"},"aliases":[{"name":"The Caretaker"}]}],"current_state":{"summary":{"text":"Deep winter"},"conflicts":[{"name":"Cabin fever"}]}}')
    TestRunner:ok(d)
    TestRunner:eq(d.characters[1].role, "Protagonist")
    TestRunner:eq(d.characters[1].aliases[1], "The Caretaker")
    TestRunner:eq(d.current_state.summary, "Deep winter")
    TestRunner:eq(d.current_state.conflicts[1], "Cabin fever")
    local ok, md = pcall(XrayParser.renderToMarkdown, d, "The Overlook", "35%")
    TestRunner:ok(ok, "render must not crash: " .. tostring(md))
    TestRunner:ok(md:find("The Caretaker", 1, true), "alias rendered")
end)
TestRunner:test("map-instead-of-array category salvaged, keys become names", function()
    local d = XrayParser.parse('{"characters":{"Jack":{"role":"Protagonist"},"Wendy":{"role":"Supporting"}}}')
    TestRunner:ok(d)
    TestRunner:eq(#d.characters, 2)
    TestRunner:eq(d.characters[1].name, "Jack") -- sorted for stability
end)
TestRunner:test("string current_state becomes {summary}; background arrays keep their shape", function()
    local d = XrayParser.parse('{"characters":[{"name":"Jack","background":[{"source":"Vol 1","text":"He was a teacher.","file":"/books/v1.epub"},{"bogus":true}]}],"current_state":"All is calm."}')
    TestRunner:ok(d)
    TestRunner:eq(d.current_state.summary, "All is calm.")
    TestRunner:eq(#d.characters[1].background, 1, "malformed background line dropped")
    TestRunner:eq(d.characters[1].background[1].file, "/books/v1.epub")
end)

TestRunner:suite("round 28 — hasEntityContent / dropModelBackground / merge belt")
TestRunner:test("hasEntityContent: lone current_state is NOT a usable create", function()
    local d = XrayParser.parse('{"current_state":{"summary":"Nine years past, at the northern front..."}}')
    TestRunner:ok(d, "current_state-only still parses")
    TestRunner:ok(not XrayParser.hasEntityContent(d), "but holds no entity content")
    local d2 = XrayParser.parse('{"characters":[{"name":"Almark"}]}')
    TestRunner:ok(XrayParser.hasEntityContent(d2))
end)
TestRunner:test("dropModelBackground strips echoed background from a response", function()
    local d = XrayParser.parse('{"characters":[{"name":"Jack","background":[{"source":"Vol 4","text":"echoed junk"}]}]}')
    XrayParser.dropModelBackground(d)
    TestRunner:eq(d.characters[1].background, nil)
end)
TestRunner:test("merge: a rewrite carrying background NEVER replaces the stored lines", function()
    local old = XrayParser.parse('{"characters":[{"name":"Jack","description":"old","background":[{"source":"Vol 1","text":"mechanical truth"}]}]}')
    local new = XrayParser.parse('{"characters":[{"name":"Jack","description":"new","background":[{"source":"Vol 4","text":"model echo"}]}]}')
    local merged = XrayParser.merge(old, new)
    TestRunner:eq(merged.characters[1].description, "new", "rewrite lands")
    TestRunner:eq(#merged.characters[1].background, 1)
    TestRunner:eq(merged.characters[1].background[1].text, "mechanical truth")
end)

TestRunner:suite("round 28 — mergeBackground file identity")
TestRunner:test("same file under two drifted labels collapses to one line", function()
    local merged = XrayParser.mergeBackground(
        { { source = "アルマーク４　武術大会編", text = "old", file = "/b/v4.epub" } },
        { { source = "アルマーク 04 武術大会編 (MFブックス)", text = "new", file = "/b/v4.epub" } })
    TestRunner:eq(#merged, 1)
    TestRunner:eq(merged[1].text, "new")
end)
TestRunner:test("legacy line gains the file key from its successor; label-only still dedupes", function()
    local merged = XrayParser.mergeBackground(
        { { source = "Vol 1", text = "old" } },
        { { source = "Vol 1", text = "new", file = "/b/v1.epub" } })
    TestRunner:eq(#merged, 1)
    TestRunner:eq(merged[1].file, "/b/v1.epub")
    TestRunner:eq(merged[1].text, "new")
end)
TestRunner:test("two DIFFERENT files sharing one label stay separate", function()
    local merged = XrayParser.mergeBackground(
        { { source = "Collected", text = "a", file = "/b/one.epub" } },
        { { source = "Collected", text = "b", file = "/b/two.epub" } })
    TestRunner:eq(#merged, 2)
end)

TestRunner:suite("round 28 — isEmptyDelta (no-overlap merges are an ANSWER)")
TestRunner:test("content-free JSON is recognized, in every shape a model emits", function()
    for _idx, s in ipairs({ "{}", '{"background_updates": []}', '{"characters": []}',
        '```json\n{"background_updates": []}\n```', '{"background_updates": [], "characters": []}' }) do
        TestRunner:ok(XrayParser.isEmptyDelta(s), "empty: " .. s:gsub("\n", "\\n"))
    end
end)
TestRunner:test("anything with real content is NOT empty", function()
    for _idx, s in ipairs({ '{"background_updates": [{"name":"X","background":"y"}]}',
        '{"characters":[{"name":"Jack"}]}', '{"error":"I cannot do this"}',
        "These two books share nothing.", "" }) do
        TestRunner:ok(not XrayParser.isEmptyDelta(s), "not empty: " .. s)
    end
end)
TestRunner:test("the empty delta the merge prompt asks for still PARSES as valid data", function()
    -- Both facts matter: parse() accepts it (so a merge that returns it is not
    -- an error), and isEmptyDelta flags it (so the caller reports "no overlap")
    local d = XrayParser.parse('{"background_updates": []}')
    TestRunner:ok(d, "parses")
    TestRunner:ok(XrayParser.isEmptyDelta('{"background_updates": []}'), "and is flagged empty")
end)

TestRunner:suite("round 28 — stripForPromptJSON")
TestRunner:test("background and dormant stripped; entities and state kept", function()
    local src = '{"characters":[{"name":"Jack","description":"kept","background":[{"source":"Vol 1","text":"hidden"}]}],"current_state":{"summary":"kept"},"__dormant":[{"name":"Ghost","category":"characters"}]}'
    local out = XrayParser.stripForPromptJSON(src)
    TestRunner:ok(not out:find("hidden", 1, true), "background gone")
    TestRunner:ok(not out:find("__dormant", 1, true), "ledger gone")
    TestRunner:ok(out:find("kept", 1, true), "content kept")
end)
TestRunner:test("prose and background-free JSON pass through untouched", function()
    local prose = "This recap has a background section in prose."
    TestRunner:eq(XrayParser.stripForPromptJSON(prose), prose)
    local plain = '{"characters":[{"name":"Jack"}]}'
    TestRunner:eq(XrayParser.stripForPromptJSON(plain), plain)
end)

print("")
print(string.rep("-", 50))
print(string.format("  Results: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
print(string.rep("-", 50))
return TestRunner.failed == 0
