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

local ok = TestRunner:summary()
return ok
