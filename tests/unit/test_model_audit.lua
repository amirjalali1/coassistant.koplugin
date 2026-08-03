-- Unit tests for the pure helpers in tests/model_audit.lua (agenda item 20):
-- diff/noise/snapshot classification, ceiling parsing, reasoning evidence,
-- and draft-stanza emission. No API calls (the probe engine itself is live-only).
--
-- Run: lua tests/run_tests.lua --unit

-- Setup paths
local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."

    package.path = table.concat({
        plugin_dir .. "/?.lua",
        plugin_dir .. "/koassistant_api/?.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")

    return plugin_dir, tests_dir
end

setupPaths()

-- Load mocks BEFORE any plugin modules
require("mock_koreader")

-- Test framework
local TestRunner = {
    passed = 0,
    failed = 0,
    current_suite = "",
}

function TestRunner:suite(name)
    self.current_suite = name
    print("\n== " .. name .. " ==")
end

function TestRunner:check(name, condition, detail)
    if condition then
        self.passed = self.passed + 1
        print("  PASS: " .. name)
    else
        self.failed = self.failed + 1
        print("  FAIL: " .. name .. (detail and ("  [" .. tostring(detail) .. "]") or ""))
    end
end

local ModelAudit = require("model_audit")

--==========================================================================
TestRunner:suite("Noise filter")

TestRunner:check("openai whisper-1 is noise", ModelAudit.isNoise("openai", "whisper-1") ~= nil)
TestRunner:check("openai text-embedding-3-large is noise",
    ModelAudit.isNoise("openai", "text-embedding-3-large") ~= nil)
TestRunner:check("openai gpt-5.7 is NOT noise", ModelAudit.isNoise("openai", "gpt-5.7") == nil)
TestRunner:check("openai *-pro is noise (responses-only variants)",
    ModelAudit.isNoise("openai", "gpt-5.6-sol-pro") ~= nil)
TestRunner:check("gemini gemma is noise", ModelAudit.isNoise("gemini", "gemma-3-27b-it") ~= nil)
TestRunner:check("gemini-2.5-pro is NOT noise (-pro list is openai-only)",
    ModelAudit.isNoise("gemini", "gemini-2.5-pro") == nil)
TestRunner:check("mistral mistral-large is NOT noise",
    ModelAudit.isNoise("mistral", "mistral-large-2512") == nil)

--==========================================================================
TestRunner:suite("Snapshot/alias detection")

local curated_set = { ["gpt-4o"] = true, ["gemini-2.5-flash"] = true, ["claude-sonnet-5"] = true }
TestRunner:check("dated snapshot maps to curated base",
    ModelAudit.isSnapshotOf("gpt-4o-2024-08-06", curated_set) == "gpt-4o")
TestRunner:check("-001 suffix maps to curated base",
    ModelAudit.isSnapshotOf("gemini-2.5-flash-001", curated_set) == "gemini-2.5-flash")
TestRunner:check("-latest alias maps to curated base",
    ModelAudit.isSnapshotOf("claude-sonnet-5-latest", curated_set) ~= nil)
TestRunner:check("genuinely new id is not a snapshot",
    ModelAudit.isSnapshotOf("gpt-5.7", curated_set) == nil)
TestRunner:check("dated id with uncurated base is not a snapshot",
    ModelAudit.isSnapshotOf("gpt-6-2027-01-01", curated_set) == nil)

local latest_set = { ["magistral-medium-latest"] = true, ["codestral-latest"] = true }
TestRunner:check("mistral YYMM snapshot maps to curated -latest alias",
    ModelAudit.isSnapshotOf("magistral-medium-2509", latest_set) == "magistral-medium-latest")
TestRunner:check("codestral-2508 maps to codestral-latest",
    ModelAudit.isSnapshotOf("codestral-2508", latest_set) == "codestral-latest")
TestRunner:check("YYMM id with uncurated alias is not a snapshot",
    ModelAudit.isSnapshotOf("devstral-2512", latest_set) == nil)

--==========================================================================
TestRunner:suite("diffLists")

local NOW = 1785000000  -- fixed fake "now" so the test is deterministic
local fetched = {
    ["m-a"] = {},                                          -- curated, present
    ["m-new"] = { created = NOW - 86400 },                 -- fresh
    ["m-old"] = { created = NOW - 300 * 86400 },           -- released long ago
    ["m-a-2025-01-01"] = {},                               -- snapshot of curated
    ["whisper-x"] = {},                                    -- noise (openai list)
    ["m-undated"] = {},                                    -- no timestamp -> treat recent
}
local diff = ModelAudit.diffLists("openai", { "m-a", "m-b" }, fetched, NOW)

TestRunner:check("known counted", diff.known == 1, diff.known)
TestRunner:check("fresh id lands in new", #diff.new == 2 and diff.new[1] == "m-new" or diff.new[2] == "m-new")
TestRunner:check("undated id lands in new (loud beats silent)",
    (diff.new[1] == "m-undated" or diff.new[2] == "m-undated") and #diff.new == 2)
TestRunner:check("old id lands in stale", #diff.stale == 1 and diff.stale[1] == "m-old")
TestRunner:check("snapshot bucketed", #diff.snapshots == 1 and diff.snapshots[1] == "m-a-2025-01-01")
TestRunner:check("noise bucketed", #diff.ignored == 1 and diff.ignored[1] == "whisper-x")
TestRunner:check("curated-but-absent flagged removed", #diff.removed == 1 and diff.removed[1] == "m-b")

local diff_no_now = ModelAudit.diffLists("openai", { "m-a", "m-b" }, fetched, nil)
TestRunner:check("without `now` everything uncurated is new",
    #diff_no_now.new == 3 and #diff_no_now.stale == 0)

local skip_diff = ModelAudit.diffLists("anthropic", { "claude-opus-4-8" },
    { ["claude-opus-4-6"] = {}, ["claude-opus-4-8"] = {} }, NOW)
TestRunner:check("deliberate skip bucketed with its reason",
    #skip_diff.deliberate == 1 and skip_diff.deliberate[1].id == "claude-opus-4-6"
    and type(skip_diff.deliberate[1].reason) == "string")
TestRunner:check("deliberate skip stays out of new", #skip_diff.new == 0)

--==========================================================================
TestRunner:suite("modelTimestamp")

TestRunner:check("epoch `created` passes through", ModelAudit.modelTimestamp({ created = 123 }) == 123)
local iso_ts = ModelAudit.modelTimestamp({ created_at = "2026-07-24T10:00:00Z" })
TestRunner:check("ISO created_at parses to a number", type(iso_ts) == "number")
TestRunner:check("no timestamp -> nil", ModelAudit.modelTimestamp({}) == nil)
TestRunner:check("non-table -> nil", ModelAudit.modelTimestamp(nil) == nil)

--==========================================================================
TestRunner:suite("parseCeiling")

TestRunner:check("anthropic-style ceiling parsed",
    ModelAudit.parseCeiling(
        "max_tokens: 10000000 > 128000, which is the maximum allowed number of output tokens for claude-opus-5",
        10000000) == 128000)
TestRunner:check("date-like model-id digits do not poison the parse",
    ModelAudit.parseCeiling(
        "max_tokens: 10000000 > 8192, which is the maximum for claude-haiku-4-5-20251001",
        10000000) == 8192)
TestRunner:check("no candidate number -> nil",
    ModelAudit.parseCeiling("invalid request: streaming is required", 10000000) == nil)
TestRunner:check("echo of the sent value alone -> nil",
    ModelAudit.parseCeiling("max_tokens 10000000 is invalid", 10000000) == nil)

--==========================================================================
TestRunner:suite("errText / reasoningEvidence")

TestRunner:check("nested error.message extracted",
    ModelAudit.errText({ error = { message = "boom" } }) == "boom")
TestRunner:check("string error extracted", ModelAudit.errText({ error = "plain" }) == "plain")
TestRunner:check("falls back to raw text", ModelAudit.errText(nil, "raw body") == "raw body")

TestRunner:check("reasoning_tokens evidence",
    ModelAudit.reasoningEvidence({ usage = { completion_tokens_details = { reasoning_tokens = 42 } } })
        == "reasoning_tokens=42")
TestRunner:check("reasoning_content evidence",
    ModelAudit.reasoningEvidence({ choices = { { message = { reasoning_content = "hm" } } } }) ~= nil)
TestRunner:check("<think> tag evidence",
    ModelAudit.reasoningEvidence({ choices = { { message = { content = "<think>x</think>ok" } } } }) ~= nil)
TestRunner:check("plain completion -> no evidence",
    ModelAudit.reasoningEvidence({ choices = { { message = { content = "ok" } } },
                                   usage = { completion_tokens_details = { reasoning_tokens = 0 } } }) == nil)

--==========================================================================
TestRunner:suite("draftStanzas: anthropic adaptive (opus-5-shaped)")

local afacts = {
    family = "anthropic", provider = "anthropic", model = "claude-test-9",
    reachable = true, default_reasoning = true, temp_ok = false, disable_ok = true,
    adaptive_ok = true, budget_ok = false,
    ladder = { "low", "medium", "high", "xhigh", "max" },
    efforts = { low = true, medium = true, high = true, xhigh = true, max = true },
    ceiling = 128000, tools_ok = true, probes = {},
}
local acurrent = ModelAudit.currentResolution("anthropic", "claude-test-9")
local atext = table.concat(ModelAudit.draftStanzas(afacts, acurrent), "\n")

TestRunner:check("adaptive_thinking flagged for curation",
    atext:find('adaptive_thinking', 1, true) and atext:find("NEEDS CURATION", 1, true) ~= nil)
TestRunner:check("no_sampling_params capability drafted",
    atext:find('no_sampling_params', 1, true) ~= nil)
TestRunner:check("tools already covered (claude family entry)",
    atext:find("already covered", 1, true) ~= nil)
TestRunner:check("profile stanza: adaptive_effort + default on",
    atext:find('{ match = "claude-test-9", axis = "adaptive_effort", default_state = "on",', 1, true) ~= nil)
TestRunner:check("full effort ladder in options",
    atext:find('options = { "low", "medium", "high", "xhigh", "max" }', 1, true) ~= nil)
TestRunner:check("needs_no_sampling flag drafted",
    atext:find("needs_no_sampling = true", 1, true) ~= nil)
TestRunner:check("minimal stance = off (disable accepted)",
    atext:find('minimal = { state = "off" }', 1, true) ~= nil)
TestRunner:check("maximum stance = max",
    atext:find('maximum = { state = "on", option = "max" }', 1, true) ~= nil)
TestRunner:check("ceiling stanza drafted",
    atext:find('["claude-test-9"] = 128000', 1, true) ~= nil)

--==========================================================================
TestRunner:suite("draftStanzas: openai gated effort (gpt-5.6-shaped)")

local ofacts = {
    family = "openai", provider = "openai", model = "gpt-9-test",
    reachable = true, default_reasoning = false, temp_ok = false,
    needs_max_completion_tokens = true, disable_ok = true,
    ladder = { "none", "minimal", "low", "medium", "high", "xhigh", "max" },
    efforts = { none = true, minimal = true, low = true, medium = true,
                high = true, xhigh = true, max = false },
    ceiling = 128000, tools_ok = true, probes = {},
}
local ocurrent = ModelAudit.currentResolution("openai", "gpt-9-test")
local otext = table.concat(ModelAudit.draftStanzas(ofacts, ocurrent), "\n")

TestRunner:check("temperature constraint stanza drafted",
    otext:find('["gpt-9-test"] = { temperature = 1.0 },', 1, true) ~= nil)
TestRunner:check("profile: effort axis, default off",
    otext:find('axis = "effort", default_state = "off",', 1, true) ~= nil)
TestRunner:check('options exclude "none", keep minimal..xhigh, drop rejected max',
    otext:find('options = { "minimal", "low", "medium", "high", "xhigh" }', 1, true) ~= nil)
TestRunner:check('off_option = "none" drafted',
    otext:find('off_option = "none"', 1, true) ~= nil)
TestRunner:check("reasoning_gated drafted (efforts accepted, default OFF)",
    otext:find("reasoning_gated", 1, true) ~= nil)
TestRunner:check("max_completion_tokens note points at openai.lua",
    otext:find("openai.lua", 1, true) ~= nil)
TestRunner:check("model_lists reminder present",
    otext:find("koassistant_model_lists.lua", 1, true) ~= nil)

--==========================================================================
TestRunner:suite("draftStanzas: binary axis (deepseek-shaped)")

local bfacts = {
    family = "openai", provider = "deepseek", model = "deepseek-test-x",
    reachable = true, default_reasoning = true, temp_ok = true,
    binary = true, binary_on_ok = true, binary_off_ok = true, disable_ok = true,
    efforts = {}, tools_ok = true, probes = {},
}
local bcurrent = ModelAudit.currentResolution("deepseek", "deepseek-test-x")
local btext = table.concat(ModelAudit.draftStanzas(bfacts, bcurrent), "\n")

TestRunner:check("binary profile stanza drafted",
    btext:find('axis = "binary", default_state = "on",', 1, true) ~= nil)
TestRunner:check("binary can_disable/can_enable from probes",
    btext:find("can_disable = true, can_enable = true },", 1, true) ~= nil)
TestRunner:check("no temperature constraint drafted when temp accepted",
    btext:find("temperature = 1.0", 1, true) == nil)

--==========================================================================
TestRunner:suite("looksLikeSSE + tool_choice/stream wire notes")

TestRunner:check("SSE: leading data line", ModelAudit.looksLikeSSE('data: {"x":1}\n\n') == true)
TestRunner:check("SSE: event line after preamble",
    ModelAudit.looksLikeSSE(': ping\nevent: message_start\ndata: {}\n') == true)
TestRunner:check("SSE: plain JSON body is not SSE",
    ModelAudit.looksLikeSSE('{"choices":[{"message":{}}]}') == false)
TestRunner:check("SSE: nil-safe", ModelAudit.looksLikeSSE(nil) == false)

local zfacts = {
    family = "openai", provider = "zai", model = "glm-test-x",
    reachable = true, default_reasoning = true, temp_ok = true,
    binary = true, binary_on_ok = true, binary_off_ok = true, disable_ok = true,
    efforts = {}, tools_ok = true, probes = {},
    tool_choice_any_ok = false, tool_choice_any_thinking_off = true,
    tool_choice_none_ok = false, stream_ok = false,
}
local zcurrent = ModelAudit.currentResolution("zai", "glm-test-x")
local ztext = table.concat(ModelAudit.draftStanzas(zfacts, zcurrent), "\n")

TestRunner:check("gather-mode rejection note drafted (Z.AI class)",
    ztext:find("runner-incompatible as-is", 1, true) ~= nil)
TestRunner:check("thinking-disabled accommodation note drafted",
    ztext:find("thinking disabled - deepseek-style", 1, true) ~= nil)
TestRunner:check("final-pass (none) rejection note drafted",
    ztext:find("final pass needs an accommodation", 1, true) ~= nil)
TestRunner:check("stream-not-honored note drafted",
    ztext:find("stream=true not honored", 1, true) ~= nil)
TestRunner:check("no wire notes when tool_choice/stream fine",
    btext:find("runner-incompatible", 1, true) == nil
    and btext:find("stream=true not honored", 1, true) == nil)

-- Summary
print(string.format("\n%d passed, %d failed", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
