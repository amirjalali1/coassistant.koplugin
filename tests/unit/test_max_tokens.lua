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

-- Community-provider low fallbacks pass through untouched
TestRunner.assert(ModelConstraints.resolveMaxTokens("cerebras", "some-model", 4096) == 4096,
    "community provider keeps its conservative 4096 fallback")

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

-- Summary
print(string.format("\n%d passed, %d failed", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
