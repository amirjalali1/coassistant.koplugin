--[[
Unit tests: X-Ray merge engine pure halves (koassistant_xray_merge.lua)
— xray_ecosystem_plan.md §6 slice 3. (test_xray_merge.lua covers the PARSER's
programmatic merge; this file covers the ENGINE: prompts, unions, scope, gate.)

Prompt builders (coverage-tagged inputs block, complete + delta contracts),
input-metadata union, combined-section scope, consent gate. Execution/UI are
device territory.

Run: lua tests/unit/test_xray_merge_engine.lua  (auto-discovered by run_tests.lua --unit)
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

-- sectionKeyFor lazily requires koassistant_action_cache (for the section
-- prefix constant) — give it the same minimal mocks the disk-round-trip
-- test files use
_G.G_reader_settings = _G.G_reader_settings or {
    _store = {},
    readSetting = function(self, key, default)
        local v = self._store[key]
        if v == nil then return default end
        return v
    end,
    saveSetting = function(self, key, value) self._store[key] = value end,
    flush = function() end,
}
package.loaded["docsettings"] = package.loaded["docsettings"] or {
    getSidecarDir = function(_self, _doc_path, _force) return "/tmp" end,
    isHashLocationEnabled = function() return false end,
}
package.loaded["util"] = package.loaded["util"] or {
    makePath = function() end,
}
package.loaded["luasettings"] = package.loaded["luasettings"] or {
    open = function() return { readSetting = function() return nil end, close = function() end } end,
}

local XrayMerge = require("koassistant_xray_merge")
local TestRunner = require("test_runner"):new()

print("Running: test_xray_merge_engine")
print("")
print("  [inputs block + prompt builders]")

local SECTIONS = {
    { key = "_xray_section:Ch. 1", label = "Ch. 1",
      data = { result = '{"characters":[{"name":"Jack","description":"a caretaker"}]}',
               scope_page_summary = "pp 1–20", scope_start_page = 1, scope_end_page = 20,
               used_book_text = true, used_highlights = false } },
    { key = "_xray_section:Ch. 3", label = "Ch. 3",
      data = { result = '{"characters":[{"name":"Jack","description":"unraveling"}]}',
               scope_page_summary = "pp 61–80", scope_start_page = 61, scope_end_page = 80,
               used_book_text = true } },
}

TestRunner:test("buildInputsBlock: reading order, coverage tags, raw JSON embedded", function()
    local block = XrayMerge.buildInputsBlock(SECTIONS)
    local pos1 = block:find('Section 1 — "Ch. 1" (pp 1–20):', 1, true)
    local pos2 = block:find('Section 2 — "Ch. 3" (pp 61–80):', 1, true)
    TestRunner:assertTrue(pos1 ~= nil, "section 1 header with coverage tag")
    TestRunner:assertTrue(pos2 ~= nil and pos2 > pos1, "section 2 follows in order")
    TestRunner:assertTrue(block:find('"a caretaker"', 1, true) ~= nil, "JSON embedded verbatim")
end)

TestRunner:test("complete prompt: count filled, JSON rides the sentinel PAYLOAD not the prompt", function()
    local p, payload = XrayMerge.buildCompletePrompt(SECTIONS)
    TestRunner:assertTrue(p:find("Merge these 2 section X-Rays", 1, true) ~= nil, "count filled")
    TestRunner:assertTrue(p:find("{title}", 1, true) ~= nil, "identity stays a standard placeholder")
    TestRunner:assertTrue(p:find("@@KOA_MERGE_INPUTS@@", 1, true) ~= nil,
        "inputs ride the sentinel token")
    -- WIRE-SAFETY INVARIANT: artifact JSON must never be in action.prompt
    TestRunner:assertTrue(p:find("a caretaker", 1, true) == nil, "no JSON in the prompt itself")
    TestRunner:assertTrue(payload.inputs:find('"a caretaker"', 1, true) ~= nil, "JSON in the payload")
    TestRunner:assertTrue(p:find("appears exactly ONCE", 1, true) ~= nil, "dedup contract")
    TestRunner:assertTrue(p:find("from the LAST section only", 1, true) ~= nil, "singleton rule")
    TestRunner:assertTrue(p:find("Output ONLY valid JSON", 1, true) ~= nil, "JSON-only contract")
    TestRunner:assertTrue(p:find("%COUNT%", 1, true) == nil, "no unfilled markers")
end)

TestRunner:test("delta prompt: sentinels carry main/index; coverage filled; contract lines present", function()
    local main_entry = { result = '{"characters":[{"name":"Jack","description":"main v1"}]}',
        progress_decimal = 0.42 }
    local p, payload = XrayMerge.buildDeltaPrompt(SECTIONS, main_entry, "Characters: Jack")
    TestRunner:assertTrue(p:find("covers up to 42% of the book", 1, true) ~= nil, "coverage filled in prompt")
    TestRunner:assertTrue(p:find("@@KOA_MERGE_MAIN@@", 1, true) ~= nil
        and p:find("@@KOA_MERGE_INDEX@@", 1, true) ~= nil
        and p:find("@@KOA_MERGE_INPUTS@@", 1, true) ~= nil, "all sentinels present in prompt")
    TestRunner:assertTrue(p:find("main v1", 1, true) == nil, "no JSON in the prompt itself")
    TestRunner:assertEqual(payload.main, main_entry.result, "main JSON in payload")
    TestRunner:assertEqual(payload.index, "Characters: Jack", "entity index in payload")
    TestRunner:assertTrue(p:find("ONLY the new or changed entries", 1, true) ~= nil, "delta contract")
    TestRunner:assertTrue(p:find("ONLY if the sections extend past", 1, true) ~= nil,
        "singleton regression guard (current_state not forced)")
    TestRunner:assertTrue(p:find("may OVERLAP", 1, true) ~= nil, "overlap guidance")
end)

TestRunner:test("injectPayload: post-build injection, framing, single-pass safety", function()
    local built = "[Context]\nBook: \"T\"\n\n[Request]\nPrevious:\n@@KOA_MERGE_MAIN@@\n\n@@KOA_MERGE_INDEX@@\n\nSections:\n@@KOA_MERGE_INPUTS@@"
    local out = XrayMerge.injectPayload(built, {
        -- hostile content: placeholder literals AND a sentinel token inside the JSON
        main = '{"c":[{"name":"Ada","description":"In context, Ada uses {title} and @@KOA_MERGE_INPUTS@@"}]}',
        index = "Characters: Ada",
        inputs = 'Section 1 — "Ch. 1":\n{"c":[]}',
    })
    TestRunner:assertTrue(out:find("In context, Ada uses {title}", 1, true) ~= nil,
        "hostile JSON survives verbatim (nothing rescans after injection)")
    TestRunner:assertTrue(out:find("Existing entities in previous analysis:\nCharacters: Ada", 1, true) ~= nil,
        "index framed like the update path")
    -- The token INSIDE the main payload must not be re-replaced by the inputs pass
    local first_inputs = out:find('Section 1 — "Ch. 1"', 1, true)
    local token_in_main = out:find("@@KOA_MERGE_INPUTS@@", 1, true)
    TestRunner:assertTrue(token_in_main ~= nil, "token inside injected content left alone (single pass)")
    TestRunner:assertTrue(first_inputs ~= nil, "real token replaced with inputs")
    local out_empty = XrayMerge.injectPayload("A @@KOA_MERGE_INDEX@@ B", { index = "" })
    TestRunner:assertEqual(out_empty, "A  B", "empty index → empty block")
end)

TestRunner:test("coverage phrasing: percent, full-document, unknown bases", function()
    TestRunner:assertEqual(XrayMerge.coveragePhrase({ progress_decimal = 0.42 }),
        "42% of the book", "percent phrasing")
    TestRunner:assertEqual(XrayMerge.coveragePhrase({ full_document = true }),
        "the entire book", "full-document phrasing")
    TestRunner:assertEqual(XrayMerge.coveragePhrase({}),
        "an earlier reading position", "unknown phrasing")
end)

TestRunner:test("sectionKeyFor: sanitized like the manual section writer", function()
    local key = XrayMerge.sectionKeyFor("Ch 3: The Fall")
    TestRunner:assertTrue(key:find(":", 15, true) == nil or key:sub(1, 14) == "_xray_section:",
        "no colons beyond the prefix separator")
    TestRunner:assertEqual(key, "_xray_section:Ch 3- The Fall", "colon replaced (manual-writer parity)")
    local long = string.rep("x", 200)
    TestRunner:assertTrue(#XrayMerge.sectionKeyFor(long) <= #"_xray_section:" + 80, "80-char cap")
end)

print("")
print("  [metadata union + combined scope + consent]")

TestRunner:test("unionInputMeta: any true wins; nil beats explicit false (conservative)", function()
    local u = XrayMerge.unionInputMeta({
        { used_book_text = true, used_highlights = false },
        { used_book_text = false },  -- highlights nil here
    })
    TestRunner:assertEqual(u.used_book_text, true, "any true -> true")
    TestRunner:assertEqual(u.used_highlights, nil, "nil (legacy/unknown) survives over false")
    local u2 = XrayMerge.unionInputMeta({
        { used_book_text = false, used_highlights = false },
        { used_book_text = false, used_highlights = false },
    })
    TestRunner:assertEqual(u2.used_book_text, false, "all explicit false -> false")
end)

TestRunner:test("combinedScope: union range, composite label, xpointers from ends", function()
    local secs = {
        { label = "Ch. 1", data = { scope_start_page = 1, scope_end_page = 20,
            scope_start_xpointer = "xp-start", scope_end_xpointer = "xp-mid" } },
        { label = "Ch. 3", data = { scope_start_page = 61, scope_end_page = 80,
            scope_start_xpointer = "xp-mid2", scope_end_xpointer = "xp-end" } },
    }
    local scope = XrayMerge.combinedScope(secs)
    TestRunner:assertEqual(scope.label, "Ch. 1 – Ch. 3", "composite label (range-picker precedent)")
    TestRunner:assertEqual(scope.start_page, 1, "start from first")
    TestRunner:assertEqual(scope.end_page, 80, "end from last")
    TestRunner:assertEqual(scope.start_xpointer, "xp-start", "start xpointer from first")
    TestRunner:assertEqual(scope.end_xpointer, "xp-end", "end xpointer from last")
    TestRunner:assertTrue(scope.page_summary ~= nil, "page summary built")
    TestRunner:assertEqual(XrayMerge.combinedScope({ secs[1] }).label, "Ch. 1", "single input keeps its label")
end)

TestRunner:test("consentOk: text-derived inputs gate on extraction consent + trusted bypass", function()
    local text_inputs = { { used_book_text = true } }
    TestRunner:assertEqual(XrayMerge.consentOk(text_inputs, { enable_book_text_extraction = true }, "openai"),
        true, "consent on -> allowed")
    TestRunner:assertEqual(XrayMerge.consentOk(text_inputs, {}, "openai"),
        false, "consent off -> blocked")
    TestRunner:assertEqual(XrayMerge.consentOk(text_inputs,
        { trusted_providers = { "openai" } }, "openai"), true, "trusted provider bypasses")
    TestRunner:assertEqual(XrayMerge.consentOk({ { used_book_text = nil } }, {}, "openai"),
        false, "nil/legacy flag treated as text-derived (conservative)")
    TestRunner:assertEqual(XrayMerge.consentOk({ { used_book_text = false } }, {}, "openai"),
        true, "explicit non-text inputs need no consent")
end)

print("")
print("  [cross-book merge (item 43, #90 v1)]")

local function has(haystack, needle)
    return type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil
end

TestRunner:test("buildCrossBookInputsBlock labels by book, carries the JSON", function()
    local block = XrayMerge.buildCrossBookInputsBlock({
        title = "First Book", author = "A. Author",
        entry = { result = '{"characters": []}' },
    })
    TestRunner:assertTrue(has(block, 'Related book — "First Book" by A. Author:'), "book label")
    TestRunner:assertTrue(has(block, '{"characters": []}'), "carries the JSON")
    local no_author = XrayMerge.buildCrossBookInputsBlock({
        title = "Solo", entry = { result = "{}" } })
    TestRunner:assertTrue(has(no_author, 'Related book — "Solo":'), "author-less label")
end)

TestRunner:test("buildCrossBookPrompt: sentinels present, coverage phrased, no raw braces from data", function()
    local prompt, payload = XrayMerge.buildCrossBookPrompt(
        { result = '{"x":1}', progress_decimal = 0.62 },
        "- Said (character)",
        { { "Said", "Saeed" } },
        { title = "Book One", author = "", entry = { result = '{"y":2}' } })
    TestRunner:assertTrue(has(prompt, "@@KOA_MERGE_MAIN@@"), "main sentinel")
    TestRunner:assertTrue(has(prompt, "@@KOA_MERGE_INDEX@@"), "index sentinel")
    TestRunner:assertTrue(has(prompt, "@@KOA_MERGE_INPUTS@@"), "inputs sentinel")
    TestRunner:assertTrue(has(prompt, "@@KOA_MERGE_NEVER@@"), "never sentinel")
    TestRunner:assertTrue(has(prompt, "62% of the book"), "coverage phrase")
    TestRunner:assertTrue(has(prompt, "{response_language}"), "language named locally (round 29)")
    TestRunner:assertTrue(not has(prompt, '{"y":2}'),
        "artifact JSON rides the payload, never the prompt")
    TestRunner:assertEqual(payload.main, '{"x":1}', "payload main")
    TestRunner:assertTrue(has(payload.inputs, '{"y":2}'), "payload inputs")
    TestRunner:assertTrue(has(XrayMerge.neverLines({ { "Said", "Saeed" } }), "Said"), "never lines")
    -- The timeline stays the target book's: the prompt must say so
    TestRunner:assertTrue(has(prompt, "NEVER include them"), "timeline protection")
    -- Item 44: recurring entities ride the mechanical background channel
    TestRunner:assertTrue(has(prompt, "background_updates"), "background_updates contract")
    TestRunner:assertTrue(has(prompt, "NEVER repeat an existing entity"), "no-rewrite rule")
end)

TestRunner:test("appendBookProvenance accumulates and dedups exact titles", function()
    TestRunner:assertEqual(XrayMerge.appendBookProvenance(nil, "Book One"), "Book One")
    TestRunner:assertEqual(XrayMerge.appendBookProvenance("Book One", "Book Two"),
        "Book One; Book Two")
    TestRunner:assertEqual(XrayMerge.appendBookProvenance("Book One; Book Two", "Book One"),
        "Book One; Book Two", "exact re-merge does not duplicate")
    TestRunner:assertEqual(XrayMerge.appendBookProvenance("", "Book One"), "Book One")
end)

print("")
print("  [cross-book mechanical background (item 44)]")

local BASE_JSON = [[{
  "type": "fiction",
  "characters": [
    {"name": "John Smith", "aliases": ["Johnny"], "role": "Supporting",
     "description": "A farmer's son from the northern village."}
  ],
  "locations": [
    {"name": "Northern Village", "description": "A small farming settlement."}
  ],
  "timeline": [
    {"event": "John arrives", "chapter": "Ch 1"}
  ]
}]]

TestRunner:test("applyBackgroundUpdates: attaches by name or alias, never touches the description", function()
    local XrayParser = require("koassistant_xray_parser")
    local data = XrayParser.parse(BASE_JSON)
    local applied, unmatched = XrayMerge.applyBackgroundUpdates(data, {
        { name = "Johnny", background = "Grew up on his father's farm.",
          aliases = { "The Farmer's Son", "Johnny" } },
        { name = "Nobody Known", background = "Should not land." },
    }, "First Book")
    TestRunner:assertEqual(applied, 1, "one applied")
    TestRunner:assertEqual(unmatched, 1, "one unmatched")
    local john = data.characters[1]
    TestRunner:assertEqual(john.description, "A farmer's son from the northern village.",
        "description untouched")
    TestRunner:assertEqual(john.background[1].source, "First Book", "background source")
    TestRunner:assertEqual(john.background[1].text, "Grew up on his father's farm.", "background text")
    local alias_set = table.concat(john.aliases, "|")
    TestRunner:assertTrue(has(alias_set, "The Farmer's Son"), "new alias unioned")
    TestRunner:assertEqual(#john.aliases, 2, "existing alias not duplicated")
end)

TestRunner:test("crossBookTransform: rewrite dropped (aliases salvaged), timeline stripped, new entity lands", function()
    local WriteBack = require("koassistant_artifact_writeback")
    local delta = [[{
      "background_updates": [
        {"name": "John Smith", "background": "Left the farm after the fire."}
      ],
      "characters": [
        {"name": "Johnny", "aliases": ["J.S."], "description": "REWRITE ATTEMPT: teammate of protagonist."},
        {"name": "New Guy", "description": "Carried over from the related book."}
      ],
      "timeline": [
        {"event": "Other book's event", "chapter": "Elsewhere"}
      ]
    }]]
    local parsed, err = WriteBack.parseXrayAnswer(delta, BASE_JSON,
        XrayMerge.crossBookTransform("First Book"))
    TestRunner:assertTrue(parsed ~= nil, "merge parses: " .. tostring(err))
    local john
    for _idx, c in ipairs(parsed.characters) do
        if c.name == "John Smith" then john = c end
    end
    TestRunner:assertEqual(john.description, "A farmer's son from the northern village.",
        "disobedient rewrite must not replace the entry")
    TestRunner:assertEqual(john.background[1].text, "Left the farm after the fire.",
        "background applied")
    TestRunner:assertTrue(has(table.concat(john.aliases, "|"), "J.S."),
        "rewrite's aliases salvaged")
    TestRunner:assertEqual(#parsed.characters, 2, "new entity appended, rewrite dropped")
    TestRunner:assertEqual(parsed.characters[2].name, "New Guy", "carry-over entity lands")
    TestRunner:assertEqual(#parsed.timeline, 1, "related book's events stripped")
    TestRunner:assertEqual(parsed.timeline[1].event, "John arrives", "target timeline intact")
end)

TestRunner:test("re-merging the same book replaces its background instead of duplicating", function()
    local XrayParser = require("koassistant_xray_parser")
    local data = XrayParser.parse(BASE_JSON)
    XrayMerge.applyBackgroundUpdates(data,
        { { name = "John Smith", background = "Old text." } }, "First Book")
    XrayMerge.applyBackgroundUpdates(data,
        { { name = "John Smith", background = "Updated text." } }, "First Book")
    XrayMerge.applyBackgroundUpdates(data,
        { { name = "John Smith", background = "Companion note." } }, "Second Book")
    local bg = data.characters[1].background
    TestRunner:assertEqual(#bg, 2, "one entry per source book")
    TestRunner:assertEqual(bg[1].text, "Updated text.", "same-source re-merge replaces")
    TestRunner:assertEqual(bg[2].source, "Second Book", "second source appends")
end)

TestRunner:test("a background_updates-only delta parses (no category key needed)", function()
    local WriteBack = require("koassistant_artifact_writeback")
    local delta = [[{"background_updates": [
      {"name": "Northern Village", "background": "Founded by settlers in the first book."}
    ]}]]
    local parsed, err = WriteBack.parseXrayAnswer(delta, BASE_JSON,
        XrayMerge.crossBookTransform("First Book"))
    TestRunner:assertTrue(parsed ~= nil, "parses: " .. tostring(err))
    TestRunner:assertEqual(parsed.locations[1].background[1].text,
        "Founded by settlers in the first book.", "location background applied")
    TestRunner:assertEqual(#parsed.characters, 1, "characters untouched")
end)

print("")
print("  [transitive background carry (item 49)]")

TestRunner:test("transitive carry: ancestor labels ride a chained merge, self-label filtered", function()
    local WriteBack = require("koassistant_artifact_writeback")
    local XrayParser = require("koassistant_xray_parser")
    local source_parsed = XrayParser.parse([[{
      "type": "fiction",
      "characters": [
        {"name": "John Smith", "description": "The second book's John.",
         "background": [
           {"source": "Vol 1", "text": "A farmer's son who saved the hero."},
           {"source": "Target Book", "text": "self-label must be skipped"}
         ]},
        {"name": "New Guy", "description": "Second-book newcomer.",
         "background": [{"source": "Vol 1", "text": "Briefly seen at the fair."}]}
      ]
    }]])
    local delta = [[{
      "background_updates": [
        {"name": "John Smith", "background": "Joined the expedition."}
      ],
      "characters": [
        {"name": "New Guy", "description": "Carried over from the second book."}
      ]
    }]]
    local meta = { merged_from_books = "Second Book" }
    local parsed, err = WriteBack.parseXrayAnswer(delta, BASE_JSON,
        XrayMerge.crossBookTransform("Second Book", source_parsed, "Target Book", meta))
    TestRunner:assertTrue(parsed ~= nil, "merge parses: " .. tostring(err))
    local john, new_guy
    for _idx, c in ipairs(parsed.characters) do
        if c.name == "John Smith" then john = c end
        if c.name == "New Guy" then new_guy = c end
    end
    local labels = {}
    for _idx, b in ipairs(john.background) do labels[b.source] = b.text end
    TestRunner:assertEqual(labels["Second Book"], "Joined the expedition.",
        "picked-source line lands")
    TestRunner:assertEqual(labels["Vol 1"], "A farmer's son who saved the hero.",
        "ancestor line carried with its original label")
    TestRunner:assertTrue(labels["Target Book"] == nil, "self-label filtered")
    TestRunner:assertTrue(new_guy ~= nil and type(new_guy.background) == "table",
        "carry-over entry receives its ancestor background")
    TestRunner:assertEqual(new_guy.background[1].source, "Vol 1",
        "carry-over entry keeps the ancestor label")
    TestRunner:assertTrue(has(meta.merged_from_books, "Vol 1"),
        "carried label recorded in merged_from_books")
end)

TestRunner:test("transitive carry never overwrites a fresher direct merge of the same ancestor", function()
    local XrayParser = require("koassistant_xray_parser")
    local base = XrayParser.parse(BASE_JSON)
    base.characters[1].background = { { source = "Vol 1", text = "Fresh direct line." } }
    local source_parsed = XrayParser.parse([[{
      "type": "fiction",
      "characters": [
        {"name": "John Smith", "description": "x",
         "background": [{"source": "Vol 1", "text": "Stale chained copy."}]}
      ]
    }]])
    local carried = XrayMerge.carrySourceBackground(base, nil, source_parsed, "Target Book")
    TestRunner:assertEqual(#carried, 0, "nothing carried when the label already exists")
    TestRunner:assertEqual(base.characters[1].background[1].text, "Fresh direct line.",
        "direct line intact")
end)

TestRunner:test("transitive carry matches by alias and reports the carried label", function()
    local XrayParser = require("koassistant_xray_parser")
    local base = XrayParser.parse(BASE_JSON)
    local source_parsed = XrayParser.parse([[{
      "type": "fiction",
      "characters": [
        {"name": "J. Smith", "aliases": ["Johnny"], "description": "x",
         "background": [{"source": "Vol 1", "text": "Alias-matched line."}]}
      ]
    }]])
    local carried = XrayMerge.carrySourceBackground(base, nil, source_parsed, nil)
    TestRunner:assertEqual(#carried, 1, "one label carried")
    TestRunner:assertEqual(carried[1], "Vol 1", "label reported")
    TestRunner:assertEqual(base.characters[1].background[1].source, "Vol 1",
        "landed on the alias-matched entity")
end)

TestRunner:test("transitive carry self-label filter is normalized (case/whitespace drift)", function()
    local XrayParser = require("koassistant_xray_parser")
    local base = XrayParser.parse(BASE_JSON)
    local source_parsed = XrayParser.parse([[{
      "type": "fiction",
      "characters": [
        {"name": "John Smith", "description": "x",
         "background": [
           {"source": "target book ", "text": "self-label with drifted casing/space"},
           {"source": "Vol 1", "text": "Real ancestor line."}
         ]}
      ]
    }]])
    local carried = XrayMerge.carrySourceBackground(base, nil, source_parsed, "Target Book")
    TestRunner:assertEqual(#carried, 1, "only the real ancestor carried")
    TestRunner:assertEqual(carried[1], "Vol 1", "drifted self-label filtered")
end)

print("")
print("  [dormant carry ledger (item 49 layers 1-2)]")

TestRunner:test("populateDormant: unmatched source actives go dormant; matched do not; protected skipped", function()
    local WriteBack = require("koassistant_artifact_writeback")
    local XrayParser = require("koassistant_xray_parser")
    local source_parsed = XrayParser.parse([[{
      "type": "fiction",
      "characters": [
        {"name": "John Smith", "description": "Matched: carried by background, never stubbed."},
        {"name": "Ines Vardo", "aliases": ["Vardo"], "description": "The island doctor.",
         "background": [{"source": "Vol 0", "text": "Trained on the mainland."}]}
      ],
      "timeline": [ {"event": "protected, skip me", "chapter": "x"} ]
    }]])
    local delta = [[{"background_updates": [
      {"name": "John Smith", "background": "Kept the light."}
    ]}]]
    local parsed, err = WriteBack.parseXrayAnswer(delta, BASE_JSON,
        XrayMerge.crossBookTransform("The Lamp", source_parsed, "Target Book"))
    TestRunner:assertTrue(parsed ~= nil, "parses: " .. tostring(err))
    local ledger = parsed[XrayParser.DORMANT_KEY]
    TestRunner:assertTrue(type(ledger) == "table", "ledger exists")
    TestRunner:assertEqual(#ledger, 1, "only the unmatched active goes dormant")
    TestRunner:assertEqual(ledger[1].name, "Ines Vardo", "stub name")
    TestRunner:assertEqual(ledger[1].source, "The Lamp", "stub provenance")
    TestRunner:assertEqual(ledger[1].category, "characters", "stub category")
    TestRunner:assertEqual(ledger[1].background[1].source, "Vol 0", "carried lines ride the stub")
end)

TestRunner:test("wake-pass: an arriving entity promotes its stub (description + carried lines, alias fold)", function()
    local WriteBack = require("koassistant_artifact_writeback")
    local XrayParser = require("koassistant_xray_parser")
    local json = require("json")
    local base = XrayParser.parse(BASE_JSON)
    base[XrayParser.DORMANT_KEY] = {
        { name = "Ines Vardo", aliases = { "Vardo" }, category = "characters",
          description = "The island doctor.", source = "The Lamp",
          background = { { source = "Vol 0", text = "Trained on the mainland." } } },
    }
    local base_json = json.encode(base, { pretty = true, indent = true })
    -- The new slice introduces her under the alias only
    local delta = [[{"characters": [
      {"name": "Vardo", "description": "A sharp-eyed newcomer to the story."}
    ]}]]
    local parsed, err = WriteBack.parseXrayAnswer(delta, base_json)
    TestRunner:assertTrue(parsed ~= nil, "parses: " .. tostring(err))
    TestRunner:assertEqual(parsed[XrayParser.DORMANT_KEY], nil, "ledger emptied after wake")
    local vardo
    for _idx, c in ipairs(parsed.characters) do
        if c.name == "Vardo" then vardo = c end
    end
    TestRunner:assertTrue(vardo ~= nil, "entity present")
    TestRunner:assertEqual(#vardo.background, 2, "description + carried line attached")
    TestRunner:assertEqual(vardo.background[1].source, "The Lamp", "stub description becomes a source line")
    TestRunner:assertEqual(vardo.background[1].text, "The island doctor.", "stub description text")
    TestRunner:assertEqual(vardo.background[2].source, "Vol 0", "stub's own carried line attached")
    TestRunner:assertTrue(has(table.concat(vardo.aliases or {}, "|"), "Ines Vardo"),
        "the stub's primary name folds in as an alias")
end)

TestRunner:test("model-emitted __dormant dropped (delta AND complete); base ledger survives unrelated updates", function()
    local WriteBack = require("koassistant_artifact_writeback")
    local XrayParser = require("koassistant_xray_parser")
    local json = require("json")
    local base = XrayParser.parse(BASE_JSON)
    base[XrayParser.DORMANT_KEY] = {
        { name = "Sleeper", category = "characters", description = "Waits.", source = "Vol 0" },
    }
    local base_json = json.encode(base, { pretty = true, indent = true })
    local delta = [[{
      "characters": [ {"name": "Unrelated Newcomer", "description": "No stub match."} ],
      "__dormant": [ {"name": "Forgery", "source": "Model", "description": "must be dropped"} ]
    }]]
    local parsed, err = WriteBack.parseXrayAnswer(delta, base_json)
    TestRunner:assertTrue(parsed ~= nil, "parses: " .. tostring(err))
    local ledger = parsed[XrayParser.DORMANT_KEY]
    TestRunner:assertEqual(#ledger, 1, "base ledger intact, forgery dropped")
    TestRunner:assertEqual(ledger[1].name, "Sleeper", "real stub survives")
    local complete = WriteBack.parseXrayAnswer(
        [[{"type":"fiction","characters":[{"name":"A","description":"b"}],
           "__dormant":[{"name":"Forgery"}]}]], nil)
    TestRunner:assertEqual(complete[XrayParser.DORMANT_KEY], nil,
        "complete mode never keeps a model-authored ledger")
end)

TestRunner:test("transitive skip-volume: the source's own ledger rides along and wakes on match", function()
    local WriteBack = require("koassistant_artifact_writeback")
    local XrayParser = require("koassistant_xray_parser")
    local source_parsed = XrayParser.parse([[{
      "type": "fiction",
      "characters": [
        {"name": "Gull Keeper", "description": "Vol 2 newcomer."}
      ]
    }]])
    source_parsed[XrayParser.DORMANT_KEY] = {
        { name = "John Smith", category = "characters",
          description = "Vol 1: a farmer's son.", source = "Vol 1" },
        { name = "Never Seen", category = "characters",
          description = "Still absent.", source = "Vol 1" },
    }
    local delta = [[{"background_updates": []}]]
    local parsed, err = WriteBack.parseXrayAnswer(delta, BASE_JSON,
        XrayMerge.crossBookTransform("Vol 2", source_parsed, "Target Book"))
    TestRunner:assertTrue(parsed ~= nil, "parses: " .. tostring(err))
    TestRunner:assertEqual(parsed.characters[1].background[1].source, "Vol 1",
        "a source dormant matching a target active wakes in the same write")
    local ledger = parsed[XrayParser.DORMANT_KEY]
    TestRunner:assertEqual(#ledger, 2, "unmatched active + transitive stub stay dormant")
end)

TestRunner:test("stripDormantJSON: ledger removed for prompts; no-op without one; prose safe", function()
    local XrayParser = require("koassistant_xray_parser")
    local json = require("json")
    local base = XrayParser.parse(BASE_JSON)
    base[XrayParser.DORMANT_KEY] = { { name = "Sleeper", source = "Vol 0" } }
    local with_ledger = json.encode(base, { pretty = true, indent = true })
    local stripped = XrayParser.stripDormantJSON(with_ledger)
    TestRunner:assertTrue(not stripped:find("__dormant", 1, true), "ledger gone from the prompt copy")
    TestRunner:assertTrue(stripped:find("John Smith", 1, true) ~= nil, "actives intact")
    TestRunner:assertEqual(XrayParser.stripDormantJSON(BASE_JSON), BASE_JSON, "no ledger = unchanged string")
    TestRunner:assertEqual(XrayParser.stripDormantJSON("plain prose"), "plain prose", "prose unchanged")
end)

TestRunner:test("dormant-index bridge: entity index lists dormant IDENTITY HANDLES only", function()
    local XrayParser = require("koassistant_xray_parser")
    local base = XrayParser.parse(BASE_JSON)
    base[XrayParser.DORMANT_KEY] = {
        { name = "Keeper of the Rock", aliases = { "the Keeper" }, category = "characters",
          description = "SECRET-CONTENT-MUST-NOT-LEAK", source = "The Lamp",
          background = { { source = "Vol 0", text = "ALSO-SECRET" } } },
    }
    local index = XrayParser.buildEntityIndex(base)
    TestRunner:assertTrue(index:find("dormant", 1, true) ~= nil, "dormant line present")
    TestRunner:assertTrue(index:find("Keeper of the Rock", 1, true) ~= nil, "stub name listed")
    TestRunner:assertTrue(index:find("the Keeper", 1, true) ~= nil, "stub alias listed")
    TestRunner:assertTrue(not index:find("SECRET", 1, true),
        "descriptions/background NEVER ride the index")
    local clean = XrayParser.parse(BASE_JSON)
    TestRunner:assertTrue(not XrayParser.buildEntityIndex(clean):find("dormant", 1, true),
        "no ledger, no dormant line")
end)

TestRunner:test("bridge end-to-end: model lists a dormant name as alias -> wake connects the drifted names", function()
    local WriteBack = require("koassistant_artifact_writeback")
    local XrayParser = require("koassistant_xray_parser")
    local json = require("json")
    local base = XrayParser.parse(BASE_JSON)
    base[XrayParser.DORMANT_KEY] = {
        { name = "Keeper of the Rock", category = "characters",
          description = "Kept the light for eleven winters.", source = "The Lamp" },
    }
    local base_json = json.encode(base, { pretty = true, indent = true })
    -- The update introduces her under the NEW book's name; the model, seeing
    -- the dormant line in the index, bridges by alias
    local delta = [[{"characters": [
      {"name": "Mira Alvsund", "aliases": ["Keeper of the Rock"],
       "description": "A weathered woman new to this volume."}
    ]}]]
    local parsed, err = WriteBack.parseXrayAnswer(delta, base_json)
    TestRunner:assertTrue(parsed ~= nil, "parses: " .. tostring(err))
    TestRunner:assertEqual(parsed[XrayParser.DORMANT_KEY], nil, "stub woken and gone")
    local mira
    for _idx, c in ipairs(parsed.characters) do
        if c.name == "Mira Alvsund" then mira = c end
    end
    TestRunner:assertEqual(mira.background[1].source, "The Lamp",
        "carried knowledge lands on the drifted-name entity")
    TestRunner:assertEqual(mira.description, "A weathered woman new to this volume.",
        "this book's description untouched")
end)

TestRunner:test("ledger dedup: a re-merge refreshes the stub and unions carried lines", function()
    local XrayParser = require("koassistant_xray_parser")
    local base = XrayParser.parse(BASE_JSON)
    base[XrayParser.DORMANT_KEY] = {
        { name = "Ines Vardo", category = "characters", description = "Old description.",
          source = "Vol 1", background = { { source = "Vol 0", text = "Oldest line." } } },
    }
    local source_parsed = XrayParser.parse([[{
      "type": "fiction",
      "characters": [
        {"name": "Ines Vardo", "description": "Newer description.",
         "background": [{"source": "Vol 1", "text": "Watched the harbor."}]}
      ]
    }]])
    local added = XrayMerge.populateDormant(base, nil, source_parsed, "Vol 2")
    TestRunner:assertEqual(added, 0, "refresh, not a new stub")
    local stub = base[XrayParser.DORMANT_KEY][1]
    TestRunner:assertEqual(stub.description, "Newer description.", "newer source refreshes the stub")
    TestRunner:assertEqual(stub.source, "Vol 2", "provenance follows the newer source")
    TestRunner:assertEqual(#stub.background, 2, "carried lines unioned")
end)

print("")
print("  [carry layer 3: create-time seed + provenance gap]")

TestRunner:test("unionProvenance: chained merges record transitive sources", function()
    -- vol 3 folds vol 2, which itself carries vol 1: all three are included
    local out = XrayMerge.unionProvenance(nil, "Gullstone", "The Lamp")
    TestRunner:assertEqual(out, "Gullstone; The Lamp", "source's own provenance rides")
    out = XrayMerge.unionProvenance(out, "What Vardo Knew", "The Lamp; Gullstone")
    TestRunner:assertEqual(out, "Gullstone; The Lamp; What Vardo Knew",
        "re-listed ancestors dedup by exact title")
    TestRunner:assertEqual(#XrayMerge.provenanceGap({ "The Lamp", "Gullstone" }, out), 0,
        "a chained volume no longer reads as gap-ridden")
end)

TestRunner:test("provenanceGap: exact-title identity within the ;-list", function()
    local missing = XrayMerge.provenanceGap({ "The Lamp", "Gullstone" },
        "The Lamplighter; Gullstone")
    TestRunner:assertEqual(#missing, 1, "substring must not match")
    TestRunner:assertEqual(missing[1], "The Lamp", "the unfolded title is named")
    TestRunner:assertEqual(#XrayMerge.provenanceGap({ "A", "B" }, nil), 2,
        "no provenance at all -> everything missing")
    TestRunner:assertEqual(#XrayMerge.provenanceGap({ "A", "B" }, " A ;B"), 0,
        "whitespace-tolerant, all present -> none missing")
end)

local function withSeedStubs(preds_by_file, caches_by_file, fn)
    local orig_groups = package.loaded["koassistant_book_groups"]
    package.loaded["koassistant_book_groups"] = {
        predecessorsOf = function(file)
            return preds_by_file[file] or {}, nil
        end,
        displayTitle = function(file)
            return file:match("([^/]+)%.epub$") or file
        end,
    }
    local ActionCache = require("koassistant_action_cache")
    local orig_get = ActionCache.getXrayCache
    ActionCache.getXrayCache = function(file) return caches_by_file[file] end
    local ok_run, err = pcall(fn)
    ActionCache.getXrayCache = orig_get
    package.loaded["koassistant_book_groups"] = orig_groups
    if not ok_run then error(err, 0) end
end

local SEED_FRESH_JSON = [[{
  "type": "fiction",
  "characters": [
    {"name": "Mira Alvsund", "description": "The keeper in this volume."}
  ]
}]]

TestRunner:test("seedDormant: nearest X-Rayed predecessor seeds, its ledger rides", function()
    local XrayParser = require("koassistant_xray_parser")
    local vol2_result = [[{
      "type": "fiction",
      "characters": [
        {"name": "Mira Alvsund", "description": "Vol 2 Mira."},
        {"name": "Kell Damsgard", "description": "The harbormaster."}
      ],
      "__dormant": [
        {"name": "Old Tove", "category": "characters", "description": "A netmender.",
         "source": "vol1", "background": [{"source": "vol1", "text": "Mended the nets."}]}
      ]
    }]]
    withSeedStubs(
        { ["/b/vol3.epub"] = { "/b/vol1.epub", "/b/vol2.epub" } },
        { ["/b/vol2.epub"] = { result = vol2_result, used_book_text = false } },
        function()
            local parsed = XrayParser.parse(SEED_FRESH_JSON)
            local added, src = XrayMerge.seedDormant("/b/vol3.epub", parsed, {}, nil, nil)
            TestRunner:assertEqual(src, "vol2", "nearest X-Rayed predecessor is the source")
            TestRunner:assertEqual(added, 2, "unmatched active + riding ledger stub")
            local names = {}
            for _i, s in ipairs(parsed[XrayParser.DORMANT_KEY]) do names[s.name] = s end
            TestRunner:assertTrue(names["Kell Damsgard"] ~= nil, "unmatched active stubbed")
            TestRunner:assertTrue(names["Old Tove"] ~= nil, "predecessor's own ledger rides (transitive)")
            TestRunner:assertTrue(names["Mira Alvsund"] == nil,
                "matched active NOT stubbed - description transfer is merge (model) territory")
        end)
end)

TestRunner:test("seedDormant: walks past X-Ray-less and consent-denied predecessors", function()
    local XrayParser = require("koassistant_xray_parser")
    local vol1_result = [[{
      "type": "fiction",
      "characters": [{"name": "Ines Vardo", "description": "Kept the third watch."}]
    }]]
    withSeedStubs(
        { ["/b/vol4.epub"] = { "/b/vol1.epub", "/b/vol2.epub", "/b/vol3.epub" } },
        {
            -- vol3: no X-Ray at all; vol2: text-built with NO consent (features
            -- empty, no trusted provider) -> denied; vol1: consent-free entry
            ["/b/vol2.epub"] = { result = vol1_result, used_book_text = true },
            ["/b/vol1.epub"] = { result = vol1_result, used_book_text = false },
        },
        function()
            local parsed = XrayParser.parse(SEED_FRESH_JSON)
            local added, src = XrayMerge.seedDormant("/b/vol4.epub", parsed, {}, nil, nil)
            TestRunner:assertEqual(src, "vol1", "denied/missing predecessors skipped, farther one seeds")
            TestRunner:assertEqual(added, 1, "its actives stubbed")
        end)
end)

TestRunner:test("seedDormant: no group -> zero, artifact untouched", function()
    local XrayParser = require("koassistant_xray_parser")
    withSeedStubs({}, {}, function()
        local parsed = XrayParser.parse(SEED_FRESH_JSON)
        local added, src = XrayMerge.seedDormant("/b/solo.epub", parsed, {}, nil, nil)
        TestRunner:assertEqual(added, 0, "nothing seeded")
        TestRunner:assertEqual(src, nil, "no source")
        TestRunner:assertTrue(parsed[XrayParser.DORMANT_KEY] == nil, "no ledger key created")
    end)
end)

TestRunner:test("seedDormant + wake: a skip-volume stub wakes on the fresh book's actives", function()
    local XrayParser = require("koassistant_xray_parser")
    local vol2_result = [[{
      "type": "fiction",
      "characters": [{"name": "Kell Damsgard", "description": "The harbormaster."}],
      "__dormant": [
        {"name": "Mira Alvsund", "category": "characters",
         "description": "Kept the Greenlight through the long dark.",
         "source": "vol1", "background": [{"source": "vol1", "text": "Raised the boy at the light."}]}
      ]
    }]]
    withSeedStubs(
        { ["/b/vol3.epub"] = { "/b/vol1.epub", "/b/vol2.epub" } },
        { ["/b/vol2.epub"] = { result = vol2_result, used_book_text = false } },
        function()
            local parsed = XrayParser.parse(SEED_FRESH_JSON)
            XrayMerge.seedDormant("/b/vol3.epub", parsed, {}, nil, nil)
            local woken = XrayParser.wakeDormant(parsed)
            TestRunner:assertEqual(#woken, 1, "the skip-volume stub wakes at create time")
            local mira = parsed.characters[1]
            TestRunner:assertTrue(type(mira.background) == "table" and #mira.background == 1,
                "carried history attached (per-source replace: description wins its source slot)")
            TestRunner:assertEqual(mira.background[1].source, "vol1",
                "background line carries the original label")
            TestRunner:assertEqual(mira.background[1].text,
                "Kept the Greenlight through the long dark.",
                "the stub description is the promoted line")
            TestRunner:assertEqual(mira.description, "The keeper in this volume.",
                "the fresh book's own description untouched")
        end)
end)

print("")
print("  [series-identity round: prompt hardening + naming canon + manual wake]")

TestRunner:test("cross-book prompt carries the identity-matching instruction", function()
    TestRunner:assertTrue(
        XrayMerge.CROSS_BOOK_DELTA_PROMPT:find("Entity matching is the core", 1, true) ~= nil,
        "the resolution task is stated, not just the delta format")
    TestRunner:assertTrue(
        XrayMerge.CROSS_BOOK_DELTA_PROMPT:find("prefer the alias bridge", 1, true) ~= nil,
        "ambiguity guidance present")
end)

TestRunner:test("namingCanonBlock: identity handles only, canon categories only", function()
    local XrayParser = require("koassistant_xray_parser")
    local source = XrayParser.parse([[{
      "type": "fiction",
      "characters": [
        {"name": "Mira Alvsund", "aliases": ["the Keeper", "Alvsund", "Mira"],
         "description": "SECRET-DESCRIPTION"},
        {"name": "The boy", "description": "A curious child."}
      ],
      "themes": [{"name": "Isolation and Duty", "description": "Excluded label."}],
      "lexicon": [{"term": "Greenlight", "definition": "A flare."}],
      "__dormant": [
        {"name": "Old Tove", "category": "characters", "source": "vol0"},
        {"name": "Story Arc Thing", "category": "timeline", "source": "vol0"}
      ]
    }]])
    local block = XrayMerge.namingCanonBlock(source, "The Lamp")
    TestRunner:assertTrue(block:find("The Lamp", 1, true) ~= nil, "source book named")
    TestRunner:assertTrue(block:find("NAMING CONSISTENCY ONLY", 1, true) ~= nil, "framing present")
    TestRunner:assertTrue(block:find("Mira Alvsund (the Keeper, Alvsund)", 1, true) ~= nil,
        "name + first two aliases, third dropped")
    TestRunner:assertTrue(block:find("The boy", 1, true) ~= nil, "unnamed-handle entity listed")
    TestRunner:assertTrue(block:find("Greenlight", 1, true) ~= nil, "lexicon terms listed")
    TestRunner:assertTrue(block:find("Old Tove", 1, true) ~= nil,
        "the predecessor's own dormant handles ride (transitive)")
    TestRunner:assertTrue(block:find("Isolation and Duty", 1, true) == nil,
        "themes never steer another book's naming")
    TestRunner:assertTrue(block:find("Story Arc Thing", 1, true) == nil,
        "non-canon dormant categories excluded")
    TestRunner:assertTrue(block:find("SECRET%-DESCRIPTION") == nil,
        "identity handles only — never content")
    TestRunner:assertTrue(XrayMerge.namingCanonBlock({ type = "fiction" }, "X") == nil,
        "nothing to list -> nil, no empty frame")
end)

local MANUAL_WAKE_JSON = [[{
  "type": "fiction",
  "characters": [
    {"name": "Tobias Renn", "aliases": ["Toby"], "description": "Found the gullstone."},
    {"name": "Kell Damsgard", "description": "The harbormaster."}
  ],
  "lexicon": [{"term": "Turning", "definition": "The sea deciding something."}],
  "__dormant": [
    {"name": "The boy", "category": "characters",
     "description": "A curious child at the light.", "source": "The Lamp",
     "background": [{"source": "The Lamp", "text": "Asked about everything."}]},
    {"name": "Greenlight", "category": "lexicon",
     "description": "A green flare, neither warning nor invitation.", "source": "The Lamp"}
  ]
}]]

TestRunner:test("removeStub: positional identity, name-verified, ambiguity refused", function()
    local XrayParser = require("koassistant_xray_parser")
    local data = XrayParser.parse(MANUAL_WAKE_JSON)
    local stub = XrayParser.removeStub(data, 1, "The boy")
    TestRunner:assertEqual(stub and stub.name, "The boy", "index+name match removes")
    TestRunner:assertEqual(#data[XrayParser.DORMANT_KEY], 1, "one stub left")
    TestRunner:assertTrue(XrayParser.removeStub(data, 5, "Nobody") == nil, "unknown name refused")
    local stub2 = XrayParser.removeStub(data, 9, "Greenlight")
    TestRunner:assertEqual(stub2 and stub2.name, "Greenlight",
        "stale index falls back to the unambiguous name scan")
    TestRunner:assertTrue(data[XrayParser.DORMANT_KEY] == nil, "empty ledger key dropped")
end)

TestRunner:test("wakeStubInto: reader-asserted identity — background + aliases fold in", function()
    local XrayParser = require("koassistant_xray_parser")
    local data = XrayParser.parse(MANUAL_WAKE_JSON)
    local ok2 = XrayParser.wakeStubInto(data, 1, "The boy", "characters", "Tobias Renn")
    TestRunner:assertTrue(ok2, "wake into existing entry succeeds")
    local toby = data.characters[1]
    TestRunner:assertEqual(toby.description, "Found the gullstone.", "native description untouched")
    TestRunner:assertTrue(type(toby.background) == "table" and #toby.background == 1,
        "carried history attached (per-source, description wins the slot)")
    TestRunner:assertEqual(toby.background[1].source, "The Lamp", "source label kept")
    local has_alias = false
    for _i, a in ipairs(toby.aliases) do
        if a == "The boy" then has_alias = true end
    end
    TestRunner:assertTrue(has_alias, "the stub name becomes an alias — mentions now match")
    TestRunner:assertEqual(#data[XrayParser.DORMANT_KEY], 1, "stub left the ledger")
    TestRunner:assertTrue(
        not XrayParser.wakeStubInto(data, 1, "Greenlight", "characters", "Nobody Here"),
        "unknown target refused, stub kept")
    TestRunner:assertEqual(#data[XrayParser.DORMANT_KEY], 1, "refusal keeps the ledger intact")
end)

TestRunner:test("promoteStub: stub becomes a visible entry in its own category", function()
    local XrayParser = require("koassistant_xray_parser")
    local data = XrayParser.parse(MANUAL_WAKE_JSON)
    TestRunner:assertTrue(XrayParser.promoteStub(data, 1, "The boy"), "character promotes")
    TestRunner:assertEqual(#data.characters, 3, "new visible entry")
    local boy = data.characters[3]
    TestRunner:assertEqual(boy.name, "The boy", "name kept")
    TestRunner:assertEqual(boy.description, "A curious child at the light.", "description verbatim")
    TestRunner:assertTrue(type(boy.background) == "table" and boy.background[1].source == "The Lamp",
        "ancestor lines keep their labels")
    TestRunner:assertTrue(XrayParser.promoteStub(data, 1, "Greenlight"), "lexicon stub promotes")
    local term = data.lexicon[2]
    TestRunner:assertEqual(term.term, "Greenlight", "lexicon shape: term, not name")
    TestRunner:assertEqual(term.definition, "A green flare, neither warning nor invitation.",
        "lexicon shape: definition")
    TestRunner:assertTrue(data[XrayParser.DORMANT_KEY] == nil, "ledger emptied and dropped")
end)

print("")
print("  [round 25: cross-book identity resolution for group navigation]")

local GROUP_NAV_JSON = [[{
  "type": "fiction",
  "characters": [
    {"name": "Alvsund", "aliases": ["The Keeper", "Mira"], "description": "Kept the light."},
    {"name": "Kell Damsgard", "description": "The harbormaster."}
  ],
  "locations": [{"name": "Saltrest", "description": "A coastal town."}],
  "lexicon": [{"term": "Turning", "definition": "The sea deciding something."}],
  "conclusion": {"summary": "It ends."},
  "__dormant": [
    {"name": "Tobias Renn", "aliases": ["Toby"], "category": "characters",
     "description": "Found the gullstone.", "source": "Gullstone"}
  ]
}]]

TestRunner:test("findByIdentity: matches by alias and across categories", function()
    local XrayParser = require("koassistant_xray_parser")
    local data = XrayParser.parse(GROUP_NAV_JSON)
    local item, cat, idx = XrayParser.findByIdentity(data, { "Mira Alvsund", "the keeper" }, "characters")
    TestRunner:assertEqual(item and item.name, "Alvsund", "alias bridges the drifted name")
    TestRunner:assertEqual(cat, "characters", "owning category returned")
    TestRunner:assertEqual(idx, 1, "index returned for nav context")
    -- Category drift: the reader was in Cast, the match lives in World
    local item2, cat2 = XrayParser.findByIdentity(data, { "Saltrest" }, "characters")
    TestRunner:assertEqual(item2 and item2.name, "Saltrest", "found outside the preferred category")
    TestRunner:assertEqual(cat2, "locations", "reports where it actually lives")
    -- Lexicon uses term, not name
    local item3, cat3 = XrayParser.findByIdentity(data, { "Turning" }, nil)
    TestRunner:assertEqual(cat3, "lexicon", "term-keyed categories match too")
    TestRunner:assertTrue(item3 ~= nil, "lexicon item returned")
    TestRunner:assertTrue(XrayParser.findByIdentity(data, { "Nobody At All" }, nil) == nil,
        "no match -> nil (caller falls back a level)")
    TestRunner:assertTrue(XrayParser.findByIdentity(data, {}, nil) == nil, "no handles -> nil")
end)

TestRunner:test("findByIdentity: singleton categories never match", function()
    local XrayParser = require("koassistant_xray_parser")
    local data = XrayParser.parse(GROUP_NAV_JSON)
    -- "conclusion" is a singleton (no navigable entity list) — a stray handle
    -- must not land the reader on it
    TestRunner:assertTrue(XrayParser.findByIdentity(data, { "Conclusion" }, nil) == nil,
        "singletons excluded from identity matching")
end)

TestRunner:test("findDormantByIdentity: carried entity is the honest landing", function()
    local XrayParser = require("koassistant_xray_parser")
    local data = XrayParser.parse(GROUP_NAV_JSON)
    local stub, idx = XrayParser.findDormantByIdentity(data, { "Toby" })
    TestRunner:assertEqual(stub and stub.name, "Tobias Renn", "matched by alias in the ledger")
    TestRunner:assertEqual(idx, 1, "ledger index returned for the detail view")
    TestRunner:assertTrue(XrayParser.findDormantByIdentity(data, { "Kell Damsgard" }) == nil,
        "an ACTIVE entity is not a dormant hit")
    TestRunner:assertTrue(
        XrayParser.findDormantByIdentity({ type = "fiction" }, { "Toby" }) == nil,
        "no ledger -> nil")
end)

local ok = TestRunner:summary()
return ok
