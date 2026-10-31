-- Every action that saves its result (use_response_caching) is listed by every
-- artifact surface (B439: Counterarguments was saved but never shown). The key
-- an action caches under is in ActionCache.ARTIFACT_KEYS and ARTIFACT_NAMES,
-- the per-action ones in PER_ACTION_ARTIFACTS, and the section groups View
-- Artifacts walks (SECTION_GROUP_ORDER) are the SECTION_PREFIXES types but
-- xray, each with a group name and a type label.
-- Run: lua tests/unit/test_artifact_keys.lua  (or lua tests/run_tests.lua --unit)

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
end
setupPaths()
require("mock_koreader")
-- The minimal KOReader surface the cache module needs to load (nothing is
-- read or written here), installed only when another test file has not
-- already stubbed it in this process.
package.loaded["docsettings"] = package.loaded["docsettings"] or {
    getSidecarDir = function(_self, _doc_path) return "/nonexistent/book.sdr" end,
    isHashLocationEnabled = function() return false end,
}
package.loaded["util"] = package.loaded["util"] or { makePath = function() end }
package.loaded["luasettings"] = package.loaded["luasettings"] or {
    open = function() return { readSetting = function() return nil end, close = function() end } end,
}
_G.G_reader_settings = _G.G_reader_settings or {
    readSetting = function(_self, _key, default) return default end,
    saveSetting = function() end,
    flush = function() end,
}
local TestRunner = require("test_runner"):new()
local Actions = require("koassistant.prompts.actions")
local ActionCache = require("koassistant.artifacts.action_cache")

-- the key an action's whole-document result is cached under
local function cacheKey(action)
    if action.cache_as_xray then return "_xray_cache" end
    if action.cache_as_analyze then return "_analyze_cache" end
    if action.cache_as_summary then return "_summary_cache" end
    return action.id
end

local function cachingActions()
    local out = {}
    for _idx, ctx in ipairs({ "highlight", "book", "library", "general", "special" }) do
        for _id, action in pairs(Actions[ctx] or {}) do
            if type(action) == "table" and action.use_response_caching then out[#out + 1] = action end
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

local function set(list)
    local s = {}
    for _idx, v in ipairs(list) do s[v] = true end
    return s
end

local function sortedKeys(t)
    local out = {}
    for k in pairs(t) do out[#out + 1] = k end
    table.sort(out)
    return out
end

print("\n  [artifact keys]")

TestRunner:test("every action that saves its result has its key in ARTIFACT_KEYS and ARTIFACT_NAMES", function()
    local keys = set(ActionCache.ARTIFACT_KEYS)
    local missing = {}
    for _idx, action in ipairs(cachingActions()) do
        local key = cacheKey(action)
        if not keys[key] then missing[#missing + 1] = action.id .. " (key " .. key .. ")" end
        if not ActionCache.ARTIFACT_NAMES[key] then missing[#missing + 1] = action.id .. " (no name)" end
    end
    TestRunner:assertEqual(table.concat(missing, ", "), "", "actions missing from the artifact lists")
    TestRunner:assertTrue(#cachingActions() >= 13, "the thirteen artifact actions are found")
end)

TestRunner:test("every ARTIFACT_KEY belongs to an action that saves its result", function()
    local wanted = {}
    for _idx, action in ipairs(cachingActions()) do wanted[cacheKey(action)] = true end
    local extra = {}
    for _idx, key in ipairs(ActionCache.ARTIFACT_KEYS) do
        if not wanted[key] then extra[#extra + 1] = key end
    end
    TestRunner:assertEqual(table.concat(extra, ", "), "", "keys with no action")
end)

TestRunner:test("PER_ACTION_ARTIFACTS is ARTIFACT_KEYS without the document-level caches", function()
    local want = {}
    for _idx, key in ipairs(ActionCache.ARTIFACT_KEYS) do
        if key:sub(1, 1) ~= "_" then want[#want + 1] = key end
    end
    table.sort(want)
    local have = {}
    for key in pairs(ActionCache.PER_ACTION_ARTIFACTS or {}) do have[#have + 1] = key end
    table.sort(have)
    TestRunner:assertEqual(table.concat(have, ","), table.concat(want, ","), "PER_ACTION_ARTIFACTS")
end)

TestRunner:test("the section groups View Artifacts walks are every section type but xray, each named", function()
    local want = {}
    for key in pairs(ActionCache.SECTION_PREFIXES) do
        if key ~= "xray" then want[#want + 1] = key end
    end
    table.sort(want)
    local have = {}
    for _idx, key in ipairs(ActionCache.SECTION_GROUP_ORDER) do have[#have + 1] = key end
    table.sort(have)
    TestRunner:assertEqual(table.concat(have, ","), table.concat(want, ","), "SECTION_GROUP_ORDER")
    local unnamed = {}
    for _idx, key in ipairs(sortedKeys(ActionCache.SECTION_PREFIXES)) do
        if not ActionCache.SECTION_GROUP_NAMES[key] then unnamed[#unnamed + 1] = key .. " (group name)" end
        if not ActionCache.SECTION_TYPE_LABELS[key] then unnamed[#unnamed + 1] = key .. " (type label)" end
    end
    TestRunner:assertEqual(table.concat(unnamed, ", "), "", "section types without a name")
end)

TestRunner:summary()
return TestRunner.failed == 0
