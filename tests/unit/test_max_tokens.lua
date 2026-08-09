-- Unit tests for the max_tokens story (item 27, raise-where-known, 2026-08-06):
-- resolveMaxTokens raises the DEFAULT request to min(MAX_TOKENS_TARGET, known
-- ceiling) so reasoning/thinking (billed against the same budget everywhere)
-- can never starve the answer, while unknown models keep the provider's
-- field-proven fallback — missing curation degrades to old behavior, never to
-- a 400. clampMaxTokens keeps protecting EXPLICIT pins with the same table.
-- Born from issue #98 (reasoning-only completions under starved max_tokens).
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

local TestRunner = {
    passed = 0,
    failed = 0,
}

function TestRunner.assert(condition, message)
    if condition then
        TestRunner.passed = TestRunner.passed + 1
    else
        TestRunner.failed = TestRunner.failed + 1
        print("  FAIL: " .. message)
    end
end

local ModelConstraints = require("model_constraints")
local ModelOverrides = require("koassistant_model_overrides")

print("test_max_tokens: resolveMaxTokens / clampMaxTokens (item 27)")

local FALLBACK = 16384
local TARGET = ModelConstraints.MAX_TOKENS_TARGET

TestRunner.assert(TARGET == 32768, "MAX_TOKENS_TARGET is 32768")

-- Known big-ceiling models resolve to the target
local raised = {
    { "anthropic", "claude-sonnet-5" },
    { "anthropic", "claude-fable-5" },
    { "openai", "gpt-5.6-terra" },
    { "openai", "gpt-5.4-nano" },
    { "gemini", "gemini-3.6-flash" },
    { "gemini", "gemini-2.5-flash" },
    { "deepseek", "deepseek-v4-pro" },
    { "xai", "grok-4.5" },
    { "zai", "glm-5.2" },
    { "openrouter", "anthropic/claude-sonnet-5" },
    { "openrouter", "google/gemini-3.6-flash" },
    { "openrouter", "openai/gpt-5.6-sol" },
}
for _idx, c in ipairs(raised) do
    TestRunner.assert(ModelConstraints.resolveMaxTokens(c[1], c[2], FALLBACK) == TARGET,
        c[1] .. "/" .. c[2] .. " resolves to the 32K target")
end

-- Known LOW ceilings cap the default below the fallback (the load-bearing rows)
TestRunner.assert(ModelConstraints.resolveMaxTokens("openrouter", "qwen/qwen3-235b-a22b", FALLBACK) == 8192,
    "openrouter qwen3-235b caps the default at its 8192 ceiling")
TestRunner.assert(ModelConstraints.resolveMaxTokens("openrouter", "perplexity/sonar-pro", FALLBACK) == 8000,
    "openrouter sonar-pro caps the default at its 8000 ceiling")
TestRunner.assert(ModelConstraints.resolveMaxTokens("perplexity", "sonar-pro", FALLBACK) == 8192,
    "direct sonar-pro caps the default at its curated ceiling")

-- Unknown models keep the provider fallback (never a raise, never a 400 risk)
local unknown = {
    { "anthropic", "some-future-model" },
    { "gemini", "gemini-1.5-pro" },
    { "mistral", "mistral-large-latest" },
    { "openrouter", "x-ai/grok-4.3" },
    { "custom_lmstudio", "local-model" },
}
for _idx, c in ipairs(unknown) do
    TestRunner.assert(ModelConstraints.resolveMaxTokens(c[1], c[2], FALLBACK) == FALLBACK,
        c[1] .. "/" .. c[2] .. " (unknown ceiling) keeps the fallback")
end

-- Community providers with NO ceiling data keep their conservative fallback.
-- Their live catalogs justify it and disprove a flat raise: vercel's gateway
-- floor is 4000, featherless has a 2048 context floor, hyperbolic publishes
-- nothing at all (checked 2026-08-09).
for _idx, prov in ipairs({ "hyperbolic", "featherless", "vercel", "chutes" }) do
    TestRunner.assert(ModelConstraints.resolveMaxTokens(prov, "some-model", 4096) == 4096,
        prov .. " has no ceiling data -> keeps its conservative 4096 fallback")
end

-- Community hosts WITH catalog-verified ceilings do get the raise, including
-- for models the user fetched later (provider-wide "" entry).
TestRunner.assert(ModelConstraints.resolveMaxTokens("cerebras", "gpt-oss-120b", 16384) == TARGET,
    "cerebras (catalog: 40960 on every model) reaches the target")
TestRunner.assert(ModelConstraints.resolveMaxTokens("cerebras", "a-model-we-never-listed", 16384) == TARGET,
    "cerebras provider-wide entry covers fetched models too")
TestRunner.assert(ModelConstraints.resolveMaxTokens("deepinfra", "anything", 16384) == 16384,
    "deepinfra's documented 16384 output cap bounds the ask")

-- A per-model ceiling must WIN over the provider-wide raise, and must cap an
-- explicit pin. novita's llama-3.3-70b-instruct is the sharp case: its output
-- cap equals its entire 12288 context, so anything larger is an instant 400.
TestRunner.assert(ModelConstraints.resolveMaxTokens("novita", "meta-llama/llama-3.3-70b-instruct", 4096) == 12288,
    "novita llama-3.3 resolves to its real 12288 cap")
TestRunner.assert(ModelConstraints.clampMaxTokens("novita", "meta-llama/llama-3.3-70b-instruct", 65536) == 12288,
    "X-Ray's 65536 pin clamps to novita llama-3.3's 12288 cap instead of 400ing")
TestRunner.assert(ModelConstraints.resolveMaxTokens("novita", "deepseek/deepseek-v4-pro", 4096) == TARGET,
    "novita deepseek-v4 prefix entry (393216) reaches the target")
TestRunner.assert(ModelConstraints.resolveMaxTokens("novita", "gryphe/mythomax-l2-13b", 4096) == 4096,
    "an unlisted novita model keeps the conservative fallback (its real cap is 3200)")

-- clampMaxTokens still protects explicit pins with the same table
TestRunner.assert(ModelConstraints.clampMaxTokens("openrouter", "qwen/qwen3-235b-a22b", 65536) == 8192,
    "explicit 65536 pin clamps to qwen3-235b's 8192 ceiling")
TestRunner.assert(ModelConstraints.clampMaxTokens("anthropic", "claude-sonnet-5", 65536) == 65536,
    "explicit 65536 pin passes under sonnet-5's 128K ceiling")
TestRunner.assert(ModelConstraints.clampMaxTokens("mistral", "mistral-large-latest", 65536) == 65536,
    "no ceiling data -> explicit value passes through")

-- User override layer (custom_models.lua) feeds both directions
ModelOverrides._setUserForTests({
    max_output_tokens = {
        mistral = {
            ["mistral-large-latest"] = 65536,
            ["ministral-8b-latest"] = 8192,
        },
    },
})
TestRunner.assert(ModelConstraints.resolveMaxTokens("mistral", "mistral-large-latest", FALLBACK) == TARGET,
    "user-declared big ceiling raises the default to the target")
TestRunner.assert(ModelConstraints.resolveMaxTokens("mistral", "ministral-8b-latest", FALLBACK) == 8192,
    "user-declared low ceiling caps the default")
TestRunner.assert(ModelConstraints.clampMaxTokens("mistral", "ministral-8b-latest", 30000) == 8192,
    "user-declared low ceiling clamps explicit pins")
ModelOverrides._setUserForTests(false)

-- The reasoning-headroom net (dialogs.ensureReasoningHeadroom) must fire for
-- models we do not RECOGNIZE, not just models we know reason: anything from
-- "Fetch models", any custom/local provider model, gets the passthrough profile
-- and reports mode "off", so a mode-only gate skipped exactly the models most
-- likely to starve (#98). `profile.unknown` is that seam — it must be set for
-- unrecognized models and NOT set for a curated axis="none" entry, which is a
-- model we positively know does not reason.
do
    local unknown_cases = {
        { "openai", "totally-made-up-model" },
        { "custom_lmstudio", "some-local-llm" },
        { "ollama", "gemma4" },
    }
    for _idx, c in ipairs(unknown_cases) do
        local prof = ModelConstraints.getReasoningProfile(c[1], c[2])
        TestRunner.assert(prof.unknown == true,
            c[1] .. "/" .. c[2] .. " is unrecognized -> profile.unknown must be true")
    end

    local known_cases = {
        { "anthropic", "claude-sonnet-5" },      -- known reasoner
        { "openrouter", "perplexity/sonar" },    -- CURATED axis="none": known NOT to reason
    }
    for _idx, c in ipairs(known_cases) do
        local prof = ModelConstraints.getReasoningProfile(c[1], c[2])
        TestRunner.assert(prof.unknown == nil,
            c[1] .. "/" .. c[2] .. " is curated -> profile.unknown must NOT be set")
    end
end

-- Summary
print(string.format("\n%d passed, %d failed", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
