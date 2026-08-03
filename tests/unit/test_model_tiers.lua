-- Unit tests for the tier system (items 18a-d + 19d, 2026-07-28):
-- canonical 5-tier ladder (frontier/flagship/standard/fast/ultrafast), retired
-- "reasoning" tier read-through, descend-only fallback, and custom_models.lua
-- tier placements via the ModelOverrides seam.
--
-- The array-membership invariant exists because of a real bug: Requesty's
-- standard/fast/ultrafast tiers pointed at google/gemini-3.5-flash, an id that
-- does not exist in the Requesty catalog (and was never in our curated array).
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
}

function TestRunner.assert(condition, message)
    if condition then
        TestRunner.passed = TestRunner.passed + 1
    else
        TestRunner.failed = TestRunner.failed + 1
        print("  FAIL: " .. (message or "assertion failed"))
    end
end

local ModelLists = require("koassistant_model_lists")
local ModelOverrides = require("koassistant_model_overrides")

-- Hermeticity: a developer's local custom_models.lua must not leak in
-- (mock_koreader already does this; explicit here because these tests depend on it)
ModelOverrides._setUserForTests(false)

local CANONICAL = { frontier = true, flagship = true, standard = true, fast = true, ultrafast = true }

print("== tier table shape ==")

-- Only canonical tier names exist
for tier_name in pairs(ModelLists._tiers) do
    TestRunner.assert(CANONICAL[tier_name],
        "unexpected tier name in _tiers: " .. tostring(tier_name))
end
TestRunner.assert(ModelLists._tiers.reasoning == nil, "reasoning tier retired")
TestRunner.assert(ModelLists._tiers.frontier ~= nil, "frontier tier exists")

-- _tier_info matches the tier set
for tier_name in pairs(CANONICAL) do
    TestRunner.assert(ModelLists._tier_info[tier_name] ~= nil,
        "_tier_info missing entry for " .. tier_name)
end
TestRunner.assert(ModelLists._tier_info.reasoning == nil, "_tier_info reasoning entry removed")

print("== every tier id exists in its provider's model array ==")

local function inArray(provider, model_id)
    local arr = ModelLists[provider]
    if type(arr) ~= "table" then return false end
    for _idx, id in ipairs(arr) do
        if id == model_id then return true end
    end
    return false
end

for tier_name, tier_map in pairs(ModelLists._tiers) do
    for provider, model_id in pairs(tier_map) do
        TestRunner.assert(inArray(provider, model_id),
            string.format("_tiers.%s.%s = %q is not in the %s array",
                tier_name, provider, model_id, provider))
    end
end

-- Non-frontier ladder stays complete for every built-in provider (frontier is
-- sparse by design; everything else should resolve without fallback)
for _idx, tier_name in ipairs({ "flagship", "standard", "fast", "ultrafast" }) do
    for _pidx, provider in ipairs(ModelLists.getAllProviders()) do
        TestRunner.assert(ModelLists._tiers[tier_name][provider] ~= nil,
            string.format("built-in provider %s missing from tier %s", provider, tier_name))
    end
end

print("== normalizeTier ==")

TestRunner.assert(ModelLists.normalizeTier("reasoning") == "flagship",
    "legacy reasoning pick reads through to flagship")
TestRunner.assert(ModelLists.normalizeTier("frontier") == "frontier", "frontier passes through")
TestRunner.assert(ModelLists.normalizeTier("ultrafast") == "ultrafast", "ultrafast passes through")
TestRunner.assert(ModelLists.normalizeTier("bogus") == "standard", "unknown tier -> standard")
TestRunner.assert(ModelLists.normalizeTier(nil) == "standard", "nil tier -> standard")

print("== getModelForTier ==")

-- Direct hits
TestRunner.assert(ModelLists.getModelForTier("anthropic", "frontier", false) == "claude-fable-5",
    "anthropic frontier = claude-fable-5")
TestRunner.assert(ModelLists.getModelForTier("anthropic", "flagship", false) == "claude-sonnet-5",
    "anthropic flagship = claude-sonnet-5")

-- Legacy "reasoning" request resolves to the flagship entry, never frontier
TestRunner.assert(ModelLists.getModelForTier("anthropic", "reasoning", true) == "claude-sonnet-5",
    "reasoning alias resolves to flagship model")

-- Fallback only DESCENDS: providers without frontier fall to flagship...
TestRunner.assert(ModelLists.getModelForTier("openai", "frontier", true) == "gpt-5.6-sol",
    "openai frontier request falls back to flagship")
-- ...and without fallback a sparse tier returns nil
TestRunner.assert(ModelLists.getModelForTier("openai", "frontier", false) == nil,
    "openai has no frontier entry")
-- A flagship request never climbs into frontier
TestRunner.assert(ModelLists.getModelForTier("anthropic", "flagship", true) ~= "claude-fable-5",
    "flagship request must not climb to frontier")

-- Unknown provider (e.g. custom without overrides) resolves to nothing
TestRunner.assert(ModelLists.getModelForTier("custom_nope", "fast", true) == nil,
    "custom provider without overrides has no tiers")

print("== custom_models.lua tier placements (item 18b) ==")

ModelOverrides._setUserForTests({
    tiers = {
        custom_lm_studio = { fast = "qwen3-4b-instruct" },
        anthropic = { ultrafast = "claude-haiku-x" },
    },
})

TestRunner.assert(ModelLists.getModelForTier("custom_lm_studio", "fast", false) == "qwen3-4b-instruct",
    "custom provider gets a user-defined tier")
TestRunner.assert(ModelLists.getModelForTier("custom_lm_studio", "standard", true) == "qwen3-4b-instruct",
    "fallback walk consults user tiers per step (standard descends to user fast)")
-- Descend-only: an ultrafast request never climbs back up to fast
TestRunner.assert(ModelLists.getModelForTier("custom_lm_studio", "ultrafast", true) == nil,
    "ultrafast is the floor — no upward fallback")
TestRunner.assert(ModelLists.getModelForTier("anthropic", "ultrafast", false) == "claude-haiku-x",
    "user tier overrides curated entry")
TestRunner.assert(ModelLists.getModelForTier("anthropic", "flagship", false) == "claude-sonnet-5",
    "unrelated curated tiers unaffected by user override")
TestRunner.assert(ModelOverrides.tierOverride("anthropic", "flagship") == nil,
    "tierOverride returns nil where the user has no opinion")

-- Reset the seam so later tests in the same interpreter see no user layer
ModelOverrides._setUserForTests(false)

print("== resolveTierModel (item 18e per-action tier hints + ⚡ fastest walk) ==")

-- "fastest" walks ultrafast toward slower, never frontier
local fastest = ModelLists.resolveTierModel("anthropic", "fastest")
TestRunner.assert(fastest ~= nil, "fastest resolves for a curated provider")
TestRunner.assert(fastest == ModelLists.getModelForTier("anthropic", "ultrafast", false)
    or fastest == ModelLists.getModelForTier("anthropic", "fast", false),
    "fastest picks the quickest listed tier")
TestRunner.assert(fastest ~= "claude-fable-5", "fastest never lands on frontier")

-- Named tiers resolve with the toward-cheaper fallback
TestRunner.assert(ModelLists.resolveTierModel("anthropic", "fast")
    == ModelLists.getModelForTier("anthropic", "fast", true),
    "named tier matches getModelForTier with fallback")

-- No placements → nil (caller keeps the current model)
TestRunner.assert(ModelLists.resolveTierModel("custom_nope", "fastest") == nil,
    "fastest on a provider without tiers returns nil")
TestRunner.assert(ModelLists.resolveTierModel("custom_nope", "fast") == nil,
    "named tier on a provider without tiers returns nil")

-- Strict tier names: garbage and sentinels must NOT normalize into a model switch
TestRunner.assert(ModelLists.resolveTierModel("anthropic", "none") == nil,
    "'none' sentinel resolves to nothing (not normalized to standard)")
TestRunner.assert(ModelLists.resolveTierModel("anthropic", "fastst") == nil,
    "typo'd tier resolves to nothing")
TestRunner.assert(ModelLists.resolveTierModel(nil, "fast") == nil
    and ModelLists.resolveTierModel("anthropic", nil) == nil,
    "nil provider/tier resolve to nothing")

-- User tier placements feed the fastest walk (custom providers work)
ModelOverrides._setUserForTests({
    tiers = {
        custom_lm_studio = { fast = "qwen3-4b-instruct" },
        -- Discriminating never-frontier case: a provider whose ONLY placement is
        -- frontier. The fastest walk must come up empty — if anyone ever appends
        -- "frontier" to the walk list, THIS assertion fails (the anthropic check
        -- above short-circuits at ultrafast and would not).
        custom_only_frontier = { frontier = "giant-model" },
    },
})
TestRunner.assert(ModelLists.resolveTierModel("custom_lm_studio", "fastest") == "qwen3-4b-instruct",
    "fastest walk consults user tier placements on custom providers")
TestRunner.assert(ModelLists.resolveTierModel("custom_only_frontier", "fastest") == nil,
    "fastest walk NEVER consults frontier (frontier-only provider resolves to nothing)")
ModelOverrides._setUserForTests(false)

-- Summary
print(string.format("\n%d passed, %d failed", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
