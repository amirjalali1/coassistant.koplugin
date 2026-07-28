--[[
Unit tests: X-Ray background auto-update gate module (koassistant_xray_auto.lua)
+ the checkpoint ring (trim logic pure; push/get as a real disk round-trip).

Gate matrix per docs/xray_background_plan.md §3: opt-in, eligibility, threshold,
cap, jump guard, rate limit (stamped at schedule time), in-flight exclusion.

Run: lua tests/unit/test_xray_auto.lua  (auto-discovered by run_tests.lua --unit)
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

-- Fresh module (module-level state must start clean)
package.loaded["koassistant_xray_auto"] = nil
local XrayAuto = require("koassistant_xray_auto")
local TestRunner = require("test_runner"):new()

print("Running: test_xray_auto")
print("")
print("  [shouldFire gate matrix]")

local NOW = 1000000
local function baseState(overrides)
    local s = { auto_update = true, eligible = true, cached_progress = 0.30, prev_page = 100 }
    for k, v in pairs(overrides or {}) do s[k] = v end
    return s
end

TestRunner:test("fires when all gates pass", function()
    local v = XrayAuto.shouldFire(baseState(), 0.40, 101, NOW)
    TestRunner:assertEqual(v.fire, true, "should fire")
end)

TestRunner:test("nil state / not opted in blocks", function()
    TestRunner:assertEqual(XrayAuto.shouldFire(nil, 0.40, 101, NOW).fire, false, "nil state")
    local v = XrayAuto.shouldFire(baseState({ auto_update = false }), 0.40, 101, NOW)
    TestRunner:assertEqual(v.reason, "not_opted_in", "opt-in gate")
end)

TestRunner:test("ineligible cache blocks", function()
    local v = XrayAuto.shouldFire(baseState({ eligible = false }), 0.40, 101, NOW)
    TestRunner:assertEqual(v.reason, "not_eligible", "eligibility gate")
end)

TestRunner:test("missing progress numbers block", function()
    -- (nil can't ride through the overrides table — build the state explicitly)
    local v = XrayAuto.shouldFire({ auto_update = true, eligible = true, prev_page = 100 }, 0.40, 101, NOW)
    TestRunner:assertEqual(v.reason, "no_progress", "cached progress required")
    v = XrayAuto.shouldFire(baseState(), nil, 101, NOW)
    TestRunner:assertEqual(v.reason, "no_progress", "current progress required")
end)

TestRunner:test("delta at/below threshold blocks; just above fires", function()
    local v = XrayAuto.shouldFire(baseState(), 0.30 + XrayAuto.THRESHOLD, 101, NOW)
    TestRunner:assertEqual(v.reason, "below_threshold", "delta == threshold must not fire")
    v = XrayAuto.shouldFire(baseState(), 0.30 + XrayAuto.THRESHOLD + 0.001, 101, NOW)
    TestRunner:assertEqual(v.fire, true, "delta just above threshold fires")
end)

TestRunner:test("delta above cap blocks (offline-day gaps stay manual)", function()
    local v = XrayAuto.shouldFire(baseState(), 0.30 + XrayAuto.MAX_DELTA + 0.01, 101, NOW)
    TestRunner:assertEqual(v.reason, "above_cap", "cap gate")
    -- Exactly-at-cap uses binary-exact values (0.50 - 0.25 == 0.25) to dodge float noise
    local at_cap = baseState({ cached_progress = 0.25 })
    v = XrayAuto.shouldFire(at_cap, 0.25 + XrayAuto.MAX_DELTA, 101, NOW)
    TestRunner:assertEqual(v.fire, true, "delta == cap still fires (inclusive)")
end)

TestRunner:test("jump guard: no prev_page or big hop blocks", function()
    -- (nil can't ride through the overrides table — build the state explicitly)
    local v = XrayAuto.shouldFire(
        { auto_update = true, eligible = true, cached_progress = 0.30 }, 0.40, 101, NOW)
    TestRunner:assertEqual(v.reason, "page_jump", "first turn after open must not fire")
    v = XrayAuto.shouldFire(baseState({ prev_page = 90 }), 0.40, 101, NOW)
    TestRunner:assertEqual(v.reason, "page_jump", "11-page hop is a jump")
    v = XrayAuto.shouldFire(baseState({ prev_page = 96 }), 0.40, 101, NOW)
    TestRunner:assertEqual(v.fire, true, "5-page hop is sequential reading")
end)

TestRunner:test("rate limit stamped at schedule time binds and expires", function()
    XrayAuto.markScheduled(NOW)
    local v = XrayAuto.shouldFire(baseState(), 0.40, 101, NOW + 60)
    TestRunner:assertEqual(v.reason, "rate_limited", "within the window")
    v = XrayAuto.shouldFire(baseState(), 0.40, 101, NOW + XrayAuto.RATE_LIMIT_S)
    TestRunner:assertEqual(v.fire, true, "window elapsed")
end)

TestRunner:test("in-flight blocks; endFlight releases", function()
    XrayAuto.beginFlight()
    local v = XrayAuto.shouldFire(baseState(), 0.40, 101, NOW + XrayAuto.RATE_LIMIT_S)
    TestRunner:assertEqual(v.reason, "in_flight", "in-flight gate")
    XrayAuto.endFlight()
    v = XrayAuto.shouldFire(baseState(), 0.40, 101, NOW + XrayAuto.RATE_LIMIT_S)
    TestRunner:assertEqual(v.fire, true, "released")
end)

print("")
print("  [user dials (§10)]")

TestRunner:test("dialsFromFeatures: defaults match module constants", function()
    local d = XrayAuto.dialsFromFeatures(nil)
    TestRunner:assertEqual(d.min_gap, XrayAuto.THRESHOLD, "default min gap")
    TestRunner:assertEqual(d.max_gap, XrayAuto.MAX_DELTA, "default max gap")
    TestRunner:assertEqual(d.cooldown_s, XrayAuto.RATE_LIMIT_S, "default cooldown")
end)

TestRunner:test("dialsFromFeatures: custom values convert; inverted window clamps", function()
    local d = XrayAuto.dialsFromFeatures({
        xray_auto_min_gap = 10, xray_auto_max_gap = 40, xray_auto_cooldown = 5 })
    TestRunner:assertEqual(d.min_gap, 0.10, "percent to decimal")
    TestRunner:assertEqual(d.max_gap, 0.40, "percent to decimal")
    TestRunner:assertEqual(d.cooldown_s, 300, "minutes to seconds")
    d = XrayAuto.dialsFromFeatures({ xray_auto_min_gap = 20, xray_auto_max_gap = 10 })
    TestRunner:assertEqual(d.max_gap, d.min_gap, "inverted window clamps to min")
end)

TestRunner:test("shouldFire honors state gap overrides", function()
    local past_limit = NOW + XrayAuto.RATE_LIMIT_S  -- earlier markScheduled(NOW) still stands
    local v = XrayAuto.shouldFire(baseState({ min_gap = 0.10 }), 0.38, 101, past_limit)
    TestRunner:assertEqual(v.reason, "below_threshold", "raised min gap blocks a default-firing delta")
    v = XrayAuto.shouldFire(baseState({ min_gap = 0.10 }), 0.45, 101, past_limit)
    TestRunner:assertEqual(v.fire, true, "fires past the raised min gap")
    v = XrayAuto.shouldFire(baseState({ max_gap = 0.50 }), 0.70, 101, past_limit)
    TestRunner:assertEqual(v.fire, true, "raised max gap allows a default-blocked delta")
end)

TestRunner:test("shouldFire honors state cooldown override (0 = none)", function()
    local T0 = NOW + 10000
    XrayAuto.markScheduled(T0)
    local v = XrayAuto.shouldFire(baseState({ cooldown_s = 60 }), 0.40, 101, T0 + 30)
    TestRunner:assertEqual(v.reason, "rate_limited", "inside the shortened window")
    v = XrayAuto.shouldFire(baseState({ cooldown_s = 60 }), 0.40, 101, T0 + 61)
    TestRunner:assertEqual(v.fire, true, "past the shortened window")
    v = XrayAuto.shouldFire(baseState({ cooldown_s = 0 }), 0.40, 101, T0 + 1)
    TestRunner:assertEqual(v.fire, true, "zero cooldown never rate-limits")
end)

TestRunner:test("in-flight reason wins over the rate limit (log honesty)", function()
    -- Both gates usually hold together (the limit is stamped at schedule time);
    -- the decline must report the flight, not the cooldown
    local T1 = NOW + 20000
    XrayAuto.markScheduled(T1)
    XrayAuto.beginFlight()
    local v = XrayAuto.shouldFire(baseState(), 0.40, 101, T1 + 1)
    TestRunner:assertEqual(v.reason, "in_flight", "in_flight masks rate_limited")
    XrayAuto.endFlight()
    v = XrayAuto.shouldFire(baseState(), 0.40, 101, T1 + 1)
    TestRunner:assertEqual(v.reason, "rate_limited", "cooldown reported once the flight ends")
end)

print("")
print("  [session state helpers]")

TestRunner:test("cancelInFlight calls the handle once and clears state", function()
    local calls = 0
    XrayAuto.beginFlight()
    XrayAuto.registerCancel(function() calls = calls + 1 end)
    XrayAuto.cancelInFlight()
    XrayAuto.cancelInFlight()
    TestRunner:assertEqual(calls, 1, "cancel handle fires once")
    TestRunner:assertEqual(XrayAuto.isInFlight(), false, "flight cleared")
end)

TestRunner:test("outcome flags: idle close doesn't poison; cancel/discard consumed once", function()
    XrayAuto.consumeOutcomeFlags()  -- drain state left by the previous test's cancel
    -- Idle close (no flight, no handle) must NOT mark cancelled
    XrayAuto.cancelInFlight()
    local c, d = XrayAuto.consumeOutcomeFlags()
    TestRunner:assertEqual(c, false, "idle close is not a cancellation")
    TestRunner:assertEqual(d, false, "nothing discarded")
    -- A real in-flight cancel marks cancelled, consumed exactly once
    XrayAuto.beginFlight()
    XrayAuto.cancelInFlight()
    c, d = XrayAuto.consumeOutcomeFlags()
    TestRunner:assertEqual(c, true, "in-flight cancel recorded")
    c, d = XrayAuto.consumeOutcomeFlags()
    TestRunner:assertEqual(c, false, "consumed once")
    -- Guard discard marks discarded, consumed exactly once
    XrayAuto.markDiscarded()
    c, d = XrayAuto.consumeOutcomeFlags()
    TestRunner:assertEqual(d, true, "discard recorded")
    c, d = XrayAuto.consumeOutcomeFlags()
    TestRunner:assertEqual(d, false, "consumed once")
end)

TestRunner:test("watchdog flag rides the outcome; flight file scopes the display", function()
    XrayAuto.consumeOutcomeFlags()
    -- Watchdog kill (T1): marked before the cancel, consumed exactly once
    XrayAuto.beginFlight("/books/a.epub")
    TestRunner:assertEqual(XrayAuto.inFlightFile(), "/books/a.epub", "flight carries its file")
    XrayAuto.markWatchdog()
    XrayAuto.cancelInFlight()
    local c, _d, w = XrayAuto.consumeOutcomeFlags()
    TestRunner:assertEqual(c, true, "watchdog cancel still records the cancel")
    TestRunner:assertEqual(w, true, "watchdog kill recorded")
    TestRunner:assertEqual(XrayAuto.inFlightFile(), nil, "flight file cleared on cancel")
    local _c2, _d2, w2 = XrayAuto.consumeOutcomeFlags()
    TestRunner:assertEqual(w2, false, "watchdog flag consumed once")
    -- A plain cancel never reports a watchdog kill
    XrayAuto.beginFlight("/books/b.epub")
    XrayAuto.cancelInFlight()
    local _c3, _d3, w3 = XrayAuto.consumeOutcomeFlags()
    TestRunner:assertEqual(w3, false, "plain cancel is not a timeout")
    -- endFlight clears the file too
    XrayAuto.beginFlight("/books/c.epub")
    XrayAuto.endFlight()
    TestRunner:assertEqual(XrayAuto.inFlightFile(), nil, "flight file cleared on end")
end)

TestRunner:test("failure trace is per-file and cleared by success", function()
    XrayAuto.recordFailure("/books/a.epub", "boom")
    TestRunner:assertEqual(XrayAuto.lastFailure("/books/a.epub"), "boom", "recorded")
    TestRunner:assertEqual(XrayAuto.lastFailure("/books/b.epub"), nil, "other file unaffected")
    XrayAuto.recordSuccess("/books/a.epub")
    TestRunner:assertEqual(XrayAuto.lastFailure("/books/a.epub"), nil, "success clears failure")
end)

print("")
print("  [eligibilityFromEntry]")

local function isJSON(s) return s:sub(1, 1) == "{" end

TestRunner:test("eligible incremental JSON entry", function()
    local ok, p = XrayAuto.eligibilityFromEntry(
        { result = "{}", progress_decimal = 0.4 }, isJSON)
    TestRunner:assertEqual(ok, true, "eligible")
    TestRunner:assertEqual(p, 0.4, "cached progress returned")
end)

TestRunner:test("ineligible entries: missing, complete-track, ai_knowledge, legacy, done", function()
    TestRunner:assertEqual(XrayAuto.eligibilityFromEntry(nil, isJSON), false, "missing entry")
    TestRunner:assertEqual(XrayAuto.eligibilityFromEntry(
        { result = "{}", progress_decimal = 0.4, full_document = true }, isJSON), false, "complete track")
    TestRunner:assertEqual(XrayAuto.eligibilityFromEntry(
        { result = "{}", progress_decimal = 0.4, source_mode = "ai_knowledge" }, isJSON), false, "ai_knowledge")
    TestRunner:assertEqual(XrayAuto.eligibilityFromEntry(
        { result = "# markdown", progress_decimal = 0.4 }, isJSON), false, "legacy markdown")
    TestRunner:assertEqual(XrayAuto.eligibilityFromEntry(
        { result = "{}", progress_decimal = 1.0 }, isJSON), false, "already at 100%")
end)

print("")
print("  [checkpoint ring]")

-- Section-level mocks (ActionCache requires KOReader modules at load — mock first;
-- shared by all checkpoint tests below, TMP_ROOT removed before summary)
local TMP_ROOT = "/tmp/koassistant_xray_auto_test_" .. tostring(os.time()) .. "_" .. tostring(math.random(10000))
local SIDECAR_DIR = TMP_ROOT .. "/book.sdr"
os.execute(string.format("mkdir -p %q", SIDECAR_DIR))
package.loaded["koassistant_action_cache"] = nil
package.loaded["koassistant_gettext"] = nil
package.loaded["docsettings"] = nil
package.loaded["util"] = nil
package.loaded["luasettings"] = nil
require("mock_koreader")
_G.G_reader_settings = {
    _store = {},
    readSetting = function(self, key, default)
        local v = self._store[key]
        if v == nil then return default end
        return v
    end,
    saveSetting = function(self, key, value) self._store[key] = value end,
    flush = function() end,
}
package.loaded["docsettings"] = {
    getSidecarDir = function(_self, _doc_path, _force) return SIDECAR_DIR end,
    isHashLocationEnabled = function() return false end,
}
package.loaded["util"] = {
    makePath = function(dir) os.execute(string.format("mkdir -p %q", dir)) end,
}
package.loaded["luasettings"] = {
    open = function() return { readSetting = function() return nil end, close = function() end } end,
}
local ActionCache = require("koassistant_action_cache")
local DOC_PATH = TMP_ROOT .. "/book.epub"

TestRunner:test("trimCheckpoints keeps the newest N", function()
    local list = {}
    for i = 1, 8 do list[i] = { progress_decimal = i } end
    ActionCache.trimCheckpoints(list, 5)
    TestRunner:assertEqual(#list, 5, "trimmed to limit")
    TestRunner:assertEqual(list[1].progress_decimal, 1, "head (newest) kept")

    -- Real push/get round-trip: ring order, cap, and tricky-result serialization
    for i = 1, 7 do
        local ok = ActionCache.pushXrayCheckpoint(DOC_PATH, {
            result = '{"n": ' .. i .. ', "s": "with \\"quotes\\" and ]] closer"}',
            progress_decimal = i / 10,
            progress_page = i * 10,
            timestamp = 1700000000 + i,
        })
        TestRunner:assertEqual(ok, true, "push " .. i .. " succeeds")
    end
    local ring = ActionCache.getXrayCheckpoints(DOC_PATH)
    TestRunner:assertEqual(#ring, ActionCache.XRAY_CHECKPOINT_LIMIT, "ring capped")
    TestRunner:assertEqual(ring[1].progress_decimal, 0.7, "newest first")
    TestRunner:assertEqual(ring[#ring].progress_decimal, 0.3, "oldest surviving = push 3")
    TestRunner:assertEqual(ring[1].result, '{"n": 7, "s": "with \\"quotes\\" and ]] closer"}',
        "result round-trips losslessly")
    TestRunner:assertEqual(ring[1].progress_page, 70, "progress_page kept")
    TestRunner:assertEqual(ring[1].timestamp, 1700000007, "original timestamp kept")
    assert(type(ring[1].archived_at) == "number", "archived_at stamped")

    ActionCache.clearXrayCheckpoints(DOC_PATH)
    TestRunner:assertEqual(#ActionCache.getXrayCheckpoints(DOC_PATH), 0, "clear removes the ring")
end)

TestRunner:test("checkpoint metadata round-trips (incl. explicit false)", function()
    ActionCache.clearXrayCheckpoints(DOC_PATH)
    ActionCache.pushXrayCheckpoint(DOC_PATH, {
        result = '{"v": 1}',
        progress_decimal = 0.4,
        progress_page = 40,
        timestamp = 1700000001,
        used_highlights = true,
        used_annotations = false,
        used_book_text = false,
        model = "test-model",
        source_mode = "extract",
        flow_visible_pages = 123,
    })
    local ring = ActionCache.getXrayCheckpoints(DOC_PATH)
    TestRunner:assertEqual(ring[1].used_highlights, true, "used_highlights kept")
    TestRunner:assertEqual(ring[1].used_annotations, false, "explicit false kept")
    TestRunner:assertEqual(ring[1].used_book_text, false, "used_book_text false kept")
    TestRunner:assertEqual(ring[1].model, "test-model", "model kept")
    TestRunner:assertEqual(ring[1].source_mode, "extract", "source_mode kept")
    TestRunner:assertEqual(ring[1].flow_visible_pages, 123, "flow_visible_pages kept")
    ActionCache.clearXrayCheckpoints(DOC_PATH)
end)

TestRunner:test("checkpointLimitFromFeatures parity + clamps; push honors limit", function()
    TestRunner:assertEqual(ActionCache.checkpointLimitFromFeatures(nil), 5, "nil features -> schema default 5")
    TestRunner:assertEqual(ActionCache.checkpointLimitFromFeatures({}),
        ActionCache.XRAY_CHECKPOINT_LIMIT, "fallback equals module constant")
    TestRunner:assertEqual(ActionCache.checkpointLimitFromFeatures({ xray_versions_kept = 2 }), 2, "custom value")
    TestRunner:assertEqual(ActionCache.checkpointLimitFromFeatures({ xray_versions_kept = 0 }), 0, "zero allowed")
    TestRunner:assertEqual(ActionCache.checkpointLimitFromFeatures({ xray_versions_kept = -3 }), 0, "negative clamps to 0")
    TestRunner:assertEqual(ActionCache.checkpointLimitFromFeatures({ xray_versions_kept = 99 }), 20, "upper clamp")

    ActionCache.clearXrayCheckpoints(DOC_PATH)
    for i = 1, 4 do
        ActionCache.pushXrayCheckpoint(DOC_PATH, {
            result = '{"n": ' .. i .. '}', progress_decimal = i / 10, timestamp = 1700000000 + i,
        }, 2)
    end
    TestRunner:assertEqual(#ActionCache.getXrayCheckpoints(DOC_PATH), 2, "ring capped at custom limit")
    TestRunner:assertEqual(ActionCache.pushXrayCheckpoint(DOC_PATH, {
        result = '{"n": 5}', progress_decimal = 0.5, timestamp = 1700000005,
    }, 0), false, "limit 0 = no archiving")
    TestRunner:assertEqual(#ActionCache.getXrayCheckpoints(DOC_PATH), 2, "ring untouched at limit 0")
    ActionCache.clearXrayCheckpoints(DOC_PATH)
end)

TestRunner:test("getXrayCheckpointCount: header fast-path + pre-header fallback", function()
    ActionCache.clearXrayCheckpoints(DOC_PATH)
    for i = 1, 3 do
        ActionCache.pushXrayCheckpoint(DOC_PATH, {
            result = '{"n": ' .. i .. '}', progress_decimal = i / 10, timestamp = 1700000000 + i,
        })
    end
    TestRunner:assertEqual(ActionCache.getXrayCheckpointCount(DOC_PATH), 3, "header count")
    -- Simulate a v1 (pre-header) ring file: strip the first line
    local path = ActionCache.getXrayCheckpointsPath(DOC_PATH)
    local f = io.open(path, "r")
    local content = f:read("*a")
    f:close()
    content = content:gsub("^%-%- count: %d+\n", "")
    f = io.open(path, "w")
    f:write(content)
    f:close()
    TestRunner:assertEqual(ActionCache.getXrayCheckpointCount(DOC_PATH), 3, "pre-header fallback parses")
    ActionCache.clearXrayCheckpoints(DOC_PATH)
    TestRunner:assertEqual(ActionCache.getXrayCheckpointCount(DOC_PATH), 0, "cleared -> 0")
end)

TestRunner:test("nearestCheckpointIndex: at-or-below, tolerance, ties, complete excluded", function()
    local ring = {
        { progress_decimal = 0.60 },              -- newest
        { progress_decimal = 0.45 },
        { progress_decimal = 0.30 },
        { progress_decimal = 1.0, full_document = true },
        { progress_decimal = 0.10 },              -- oldest
    }
    TestRunner:assertEqual(ActionCache.nearestCheckpointIndex(ring, 0.50), 2, "0.45 nearest below 0.50")
    TestRunner:assertEqual(ActionCache.nearestCheckpointIndex(ring, 0.35), 3, "0.30 nearest below 0.35")
    TestRunner:assertEqual(ActionCache.nearestCheckpointIndex(ring, 0.05), nil, "all ahead -> nil")
    -- Half-percent tolerance: a 0.598 reader matches the 0.60 version
    TestRunner:assertEqual(ActionCache.nearestCheckpointIndex(ring, 0.598), 1, "tolerance catches near-equal")
    -- Complete versions never qualify (whole-book spoilers), even past everything else
    TestRunner:assertEqual(ActionCache.nearestCheckpointIndex(
        { { progress_decimal = 1.0, full_document = true } }, 0.99), nil, "complete excluded")
    -- Tie: two entries at the same progress -> newest (lowest index)
    TestRunner:assertEqual(ActionCache.nearestCheckpointIndex(
        { { progress_decimal = 0.30 }, { progress_decimal = 0.30 } }, 0.40), 1, "tie -> newest")
end)

TestRunner:test("removeXrayCheckpoint removes by index; bad index refused", function()
    ActionCache.clearXrayCheckpoints(DOC_PATH)
    for i = 1, 3 do
        ActionCache.pushXrayCheckpoint(DOC_PATH, {
            result = '{"n": ' .. i .. '}', progress_decimal = i / 10, timestamp = 1700000000 + i,
        })
    end
    -- ring is newest-first: [3, 2, 1]; remove the middle (n=2)
    TestRunner:assertEqual(ActionCache.removeXrayCheckpoint(DOC_PATH, 2), true, "remove succeeds")
    local ring = ActionCache.getXrayCheckpoints(DOC_PATH)
    TestRunner:assertEqual(#ring, 2, "one removed")
    TestRunner:assertEqual(ring[1].progress_decimal, 0.3, "head intact")
    TestRunner:assertEqual(ring[2].progress_decimal, 0.1, "tail intact")
    TestRunner:assertEqual(ActionCache.removeXrayCheckpoint(DOC_PATH, 9), false, "bad index refused")
    ActionCache.removeXrayCheckpoint(DOC_PATH, 1)
    ActionCache.removeXrayCheckpoint(DOC_PATH, 1)
    TestRunner:assertEqual(#ActionCache.getXrayCheckpoints(DOC_PATH), 0, "ring empty after removing all")
end)

TestRunner:test("restoreXrayCheckpoint swaps live and archived versions (move semantics)", function()
    ActionCache.clearXrayCheckpoints(DOC_PATH)
    -- Live cache = B (current, both keys); archived = A (older, own metadata)
    local b_meta = { model = "model-B", used_book_text = true, used_highlights = true, progress_page = 50 }
    ActionCache.setXrayCache(DOC_PATH, '{"live": "B"}', 0.5, b_meta)
    ActionCache.set(DOC_PATH, "xray", '{"live": "B"}', 0.5, b_meta)
    ActionCache.pushXrayCheckpoint(DOC_PATH, {
        result = '{"old": "A"}', progress_decimal = 0.3, progress_page = 30,
        timestamp = 1700000100, used_book_text = false, used_highlights = false, model = "model-A",
    })

    local ok = ActionCache.restoreXrayCheckpoint(DOC_PATH, 1)
    TestRunner:assertEqual(ok, true, "restore succeeds")

    local live = ActionCache.getXrayCache(DOC_PATH)
    TestRunner:assertEqual(live.result, '{"old": "A"}', "A is live")
    TestRunner:assertEqual(live.progress_decimal, 0.3, "progress restored")
    TestRunner:assertEqual(live.timestamp, 1700000100, "original generation time preserved")
    TestRunner:assertEqual(live.used_book_text, false, "archived flag wins over outgoing entry's")
    TestRunner:assertEqual(live.model, "model-A", "archived model wins")
    local per_action = ActionCache.get(DOC_PATH, "xray")
    TestRunner:assertEqual(per_action and per_action.result, '{"old": "A"}', "per-action key updated too")

    local ring = ActionCache.getXrayCheckpoints(DOC_PATH)
    TestRunner:assertEqual(#ring, 1, "ring did not grow")
    TestRunner:assertEqual(ring[1].result, '{"live": "B"}', "outgoing live took the slot")
    TestRunner:assertEqual(ring[1].progress_decimal, 0.5, "with its progress")
end)

TestRunner:test("restore: pre-metadata checkpoint inherits the outgoing entry's flags", function()
    ActionCache.clearXrayCheckpoints(DOC_PATH)
    ActionCache.setXrayCache(DOC_PATH, '{"live": "C"}', 0.6,
        { model = "model-C", used_book_text = true, used_highlights = true })
    -- Pre-metadata checkpoint: only the v1 archive fields
    ActionCache.pushXrayCheckpoint(DOC_PATH, {
        result = '{"old": "legacy"}', progress_decimal = 0.2, timestamp = 1700000200,
    })
    local ok = ActionCache.restoreXrayCheckpoint(DOC_PATH, 1)
    TestRunner:assertEqual(ok, true, "restore succeeds")
    local live = ActionCache.getXrayCache(DOC_PATH)
    TestRunner:assertEqual(live.used_book_text, true, "falls back to outgoing flags (sticky-true superset)")
    TestRunner:assertEqual(live.used_highlights, true, "fallback used_highlights")
    TestRunner:assertEqual(live.model, "model-C", "fallback model")
end)

print("")
print("  [auto-create window]")

TestRunner:test("create mode: cached_progress 0 fires only inside the gap window", function()
    -- Auto-create rides the normal gates with cached_progress = 0 (§5 decision 1):
    -- min_gap = too early, max_gap = too far into the book (stays manual)
    local FAR = NOW + 100000  -- past every rate-limit stamp earlier tests left behind
    local s = baseState({ cached_progress = 0 })
    TestRunner:assertEqual(XrayAuto.shouldFire(s, 0.04, 101, FAR).reason, "below_threshold",
        "before min gap: too early")
    TestRunner:assertEqual(XrayAuto.shouldFire(s, 0.10, 101, FAR).fire, true,
        "early-book window fires")
    TestRunner:assertEqual(XrayAuto.shouldFire(s, 0.30, 101, FAR).reason, "above_cap",
        "past max gap: first X-Ray stays manual")
end)

print("")
print("  [version ladder]")

TestRunner:test("planLadderRungs: spacing multiples above base, final 1.0, float-clean", function()
    local from_zero = XrayAuto.planLadderRungs(0)
    TestRunner:assertEqual(#from_zero, 10, "from nothing: 10 rungs")
    TestRunner:assertEqual(from_zero[1], 0.1, "first rung 10%")
    TestRunner:assertEqual(from_zero[3], 0.3, "no float drift (0.3 exact)")
    TestRunner:assertEqual(from_zero[10], 1.0, "final rung 100%")

    -- First rung must be at least HALF a step ahead of the base: a 48% X-Ray
    -- must NOT get a 50% rung (near-duplicate for a full call's price)
    local near = XrayAuto.planLadderRungs(0.48)
    TestRunner:assertEqual(near[1], 0.6, "48% base skips the 50% near-duplicate")
    TestRunner:assertEqual(#near, 5, "48% base: 5 rungs (60..90 + 100)")
    TestRunner:assertEqual(XrayAuto.planLadderRungs(0.45)[1], 0.5, "exactly half a step qualifies")

    local mid = XrayAuto.planLadderRungs(0.37)
    TestRunner:assertEqual(#mid, 6, "base 37%: 6 rungs (50..90 + 100 — 40% is under half a step)")
    TestRunner:assertEqual(mid[1], 0.5, "first rung at least half a step above base")
    TestRunner:assertEqual(mid[6], 1.0, "ends at 100%")

    -- Base ON a rung boundary starts at the NEXT one
    TestRunner:assertEqual(XrayAuto.planLadderRungs(0.4)[1], 0.5, "boundary base skips its own rung")
    -- Near-boundary float (0.4 stored as 0.39999...) treated as the boundary
    TestRunner:assertEqual(XrayAuto.planLadderRungs(0.399)[1], 0.5, "tolerance absorbs float drift")

    local tail = XrayAuto.planLadderRungs(0.95)
    TestRunner:assertEqual(#tail, 1, "near the end: just the final rung")
    TestRunner:assertEqual(tail[1], 1.0, "which is 100%")
    TestRunner:assertEqual(#XrayAuto.planLadderRungs(1.0), 0, "complete base: nothing to build")
    TestRunner:assertEqual(#XrayAuto.planLadderRungs(0.995), 0,
        "within 1% of the end: update path can't engage, nothing to build")
end)

TestRunner:test("ladderSpacingFor: 10% baseline, min-pages floor, tiny-book clamp", function()
    TestRunner:assertEqual(XrayAuto.ladderSpacingFor(nil), 0.1, "no page count: baseline")
    TestRunner:assertEqual(XrayAuto.ladderSpacingFor(0), 0.1, "zero pages: baseline")
    TestRunner:assertEqual(XrayAuto.ladderSpacingFor(600), 0.1, "long book: baseline 10%")
    TestRunner:assertEqual(XrayAuto.ladderSpacingFor(450), 0.1, "450 pages: floor lands exactly on baseline")
    TestRunner:assertEqual(XrayAuto.ladderSpacingFor(300), 0.15, "300 pages: 45-page floor -> 15%")
    TestRunner:assertEqual(XrayAuto.ladderSpacingFor(200), 0.23, "200 pages: 45-page floor -> 23%")
    TestRunner:assertEqual(XrayAuto.ladderSpacingFor(100), 0.45, "novella: 45%")
    TestRunner:assertEqual(XrayAuto.ladderSpacingFor(40), 0.5, "tiny book clamps at 50%")
    TestRunner:assertEqual(XrayAuto.ladderSpacingFor(220), 0.2,
        "whole-percent rounding (45/220 -> 20.45 -> 20%)")
    TestRunner:assertEqual(#XrayAuto.planLadderRungs(0, XrayAuto.ladderSpacingFor(100)), 3,
        "novella ladder: 45/90/100 — 3 calls, not 10")
end)

TestRunner:test("planLadderRungs: target_end bounds the build", function()
    local rungs = XrayAuto.planLadderRungs(0, 0.1, 0.6)
    TestRunner:assertEqual(#rungs, 6, "0->60% at 10%: 6 rungs")
    TestRunner:assertEqual(rungs[#rungs], 0.6, "final rung = the target, not 1.0")
    local mid = XrayAuto.planLadderRungs(0.3, 0.1, 0.6)
    TestRunner:assertEqual(#mid, 3, "30->60% at 10%: 3 rungs")
    TestRunner:assertEqual(mid[1], 0.4, "first rung past the base")
    TestRunner:assertEqual(#XrayAuto.planLadderRungs(0.59, 0.1, 0.6), 0,
        "base within 1% of target: nothing to build")
    TestRunner:assertEqual(XrayAuto.planLadderRungs(0, 0.1, nil)[10], 1.0,
        "nil target keeps the 1.0 behavior")
    TestRunner:assertEqual(XrayAuto.planLadderRungs(0, 0.1, 1.5)[10], 1.0,
        "invalid target clamps to 1.0")
end)

TestRunner:test("ladderSpacingFor v2: max-pages ceiling narrows spacing on long books", function()
    TestRunner:assertEqual(XrayAuto.ladderSpacingFor(1000), 0.1,
        "1000 pages: ceiling lands exactly on baseline (100-page rungs)")
    TestRunner:assertEqual(XrayAuto.ladderSpacingFor(1500), 0.07,
        "1500 pages: narrowed to 7% (~100-page rungs, not 150)")
    TestRunner:assertEqual(XrayAuto.ladderSpacingFor(2000), 0.05,
        "2000 pages: 5% (100-page rungs, 20 calls)")
    TestRunner:assertEqual(XrayAuto.ladderSpacingFor(3000), 0.05,
        "monster book: call-count floor wins over the size ceiling")
    TestRunner:assertEqual(#XrayAuto.planLadderRungs(0, XrayAuto.ladderSpacingFor(3000)), 20,
        "5% spacing from nothing = 19 partial rungs + 1.0")
end)

TestRunner:test("snapLadderRungs: narrow spacing shrinks the snap window", function()
    -- spacing 5%: window becomes 2% (0.4 * spacing), so a boundary 2.5% away
    -- must NOT capture the target (it would under the default 3% window)
    local t, l = XrayAuto.snapLadderRungs({ 0.50, 1.0 }, {
        { ratio = 0.475, title = "Near" }, { ratio = 0.2, title = "B" }, { ratio = 0.8, title = "C" },
    }, 0, 0.05)
    TestRunner:assertEqual(t[1], 0.5, "boundary 2.5% away ignored under the scaled 2% window")
    TestRunner:assertEqual(l[1], nil, "no label for the unsnapped target")
    -- inside the scaled window it still snaps
    local t2, l2 = XrayAuto.snapLadderRungs({ 0.50, 1.0 }, {
        { ratio = 0.49, title = "Close" }, { ratio = 0.2, title = "B" }, { ratio = 0.8, title = "C" },
    }, 0, 0.05)
    TestRunner:assertEqual(t2[1], 0.49, "1% away snaps under the scaled window")
    TestRunner:assertEqual(l2[1], "Close", "label rides")
    -- nil spacing keeps the legacy full window (back-compat)
    local t3 = XrayAuto.snapLadderRungs({ 0.50, 1.0 }, {
        { ratio = 0.475, title = "Near" }, { ratio = 0.2, title = "B" }, { ratio = 0.8, title = "C" },
    }, 0)
    TestRunner:assertEqual(t3[1], 0.475, "no spacing arg: 3% window still captures")
end)

TestRunner:test("snapLadderRungs: chapter-end snap, window, dedup, final rung survives", function()
    local rungs = XrayAuto.planLadderRungs(0)  -- 0.1..0.9 + 1.0
    local bounds = {
        { ratio = 0.12, title = "One" },
        { ratio = 0.28, title = "Two" },
        { ratio = 0.55, title = "Three" },
        { ratio = 0.71, title = "Four" },
    }
    local targets, labels = XrayAuto.snapLadderRungs(rungs, bounds, 0)
    TestRunner:assertEqual(targets[1], 0.12, "0.10 snaps to the chapter end at 0.12")
    TestRunner:assertEqual(labels[1], "One", "carries the chapter title")
    TestRunner:assertEqual(targets[2], 0.2, "no boundary within 3%: raw target kept")
    TestRunner:assertEqual(labels[2], nil, "raw targets carry no label")
    TestRunner:assertEqual(targets[3], 0.28, "0.30 snaps DOWN to 0.28")
    TestRunner:assertEqual(targets[5], 0.5, "0.55 is outside the 3% window of 0.50")
    TestRunner:assertEqual(targets[7], 0.71, "0.70 snaps up to 0.71")
    TestRunner:assertEqual(labels[7], "Four", "label rides")
    TestRunner:assertEqual(targets[#targets], 1.0, "final rung stays 1.0, never snapped")
    TestRunner:assertEqual(labels[#targets], nil, "final rung unlabeled")

    local t2, l2 = XrayAuto.snapLadderRungs(rungs, { { ratio = 0.5, title = "Only" } }, 0)
    TestRunner:assertEqual(t2, rungs, "fewer than 3 boundaries: passthrough (unusable TOC)")
    TestRunner:assertEqual(next(l2), nil, "and no labels")

    local t3 = XrayAuto.snapLadderRungs({ 0.9, 1.0 }, {
        { ratio = 0.3, title = "A" }, { ratio = 0.6, title = "B" }, { ratio = 0.99, title = "Z" },
    }, 0.85)
    TestRunner:assertEqual(t3[1], 0.9, "a boundary inside the final 3% is ignored")
    TestRunner:assertEqual(t3[2], 1.0, "so the final rung is never displaced")

    local t4 = XrayAuto.snapLadderRungs({ 0.30, 0.33, 1.0 }, {
        { ratio = 0.31, title = "A" }, { ratio = 0.05, title = "B" }, { ratio = 0.07, title = "C" },
    }, 0)
    TestRunner:assertEqual(#t4, 2, "two rungs collapsing onto one chapter build it once")
    TestRunner:assertEqual(t4[1], 0.31, "the snapped rung")
    TestRunner:assertEqual(t4[2], 1.0, "plus the final rung")

    -- Labels ride the build state per-index (skip-ahead advances idx, staying aligned)
    XrayAuto.beginLadderBuild("/x.epub", targets, labels)
    TestRunner:assertEqual(XrayAuto.ladderBuild().labels[1], "One", "labels stored on the build")
    XrayAuto.endLadderBuild()

    -- chapter_label survives the ladder sidecar serializer (field parity)
    ActionCache.clearXrayLadder(DOC_PATH)
    ActionCache.pushXrayLadderRung(DOC_PATH, {
        result = '{"x":1}', progress_decimal = 0.28, timestamp = 1700000000,
        chapter_label = "Two \"quoted\" title",
    })
    local disk = ActionCache.getXrayLadder(DOC_PATH)
    TestRunner:assertEqual(disk[1] and disk[1].chapter_label, "Two \"quoted\" title",
        "chapter_label round-trips through the ring serializer")
    ActionCache.clearXrayLadder(DOC_PATH)
end)

TestRunner:test("pickPromotableRung: at-or-below position, ahead of live, complete excluded", function()
    local ladder = {
        { progress_decimal = 0.2, result = "a" },
        { progress_decimal = 0.4, result = "b" },
        { progress_decimal = 0.6, result = "c" },
        { progress_decimal = 1.0, result = "d", full_document = true },
    }
    local pick = XrayAuto.pickPromotableRung(ladder, 0.2, 0.45)
    TestRunner:assertEqual(pick and pick.progress_decimal, 0.4, "highest rung <= position, ahead of live")
    TestRunner:assertEqual(XrayAuto.pickPromotableRung(ladder, 0.4, 0.45), nil,
        "live already at the covering rung -> nothing")
    pick = XrayAuto.pickPromotableRung(ladder, 0.4, 0.599)
    TestRunner:assertEqual(pick and pick.progress_decimal, 0.6, "half-percent tolerance at the boundary")
    TestRunner:assertEqual(XrayAuto.pickPromotableRung(ladder, 0.6, 1.0), nil,
        "full-document rungs never promote")
    pick = XrayAuto.pickPromotableRung(ladder, nil, 0.25)
    TestRunner:assertEqual(pick and pick.progress_decimal, 0.2, "nil live treated as 0 (install case)")
    TestRunner:assertEqual(XrayAuto.pickPromotableRung(ladder, 0.2, nil), nil, "no position -> nil")
    TestRunner:assertEqual(XrayAuto.pickPromotableRung(nil, 0.2, 0.5), nil, "no ladder -> nil")
end)

TestRunner:test("ladder build state: begin/advance/cancel/end", function()
    TestRunner:assertEqual(XrayAuto.ladderBuild(), nil, "idle by default")
    XrayAuto.beginLadderBuild("/x.epub", { 0.4, 0.5, 1.0 })
    local b = XrayAuto.ladderBuild()
    TestRunner:assertEqual(b.idx, 1, "starts at rung 1")
    TestRunner:assertEqual(b.total, 3, "total stamped")
    TestRunner:assertEqual(XrayAuto.advanceLadderBuild(), 0.5, "advance returns next target")
    TestRunner:assertEqual(XrayAuto.advanceLadderBuild(), 1.0, "then the last")
    TestRunner:assertEqual(XrayAuto.advanceLadderBuild(), nil, "then nil (done)")
    XrayAuto.requestLadderCancel()
    TestRunner:assertEqual(XrayAuto.ladderBuild().cancel_requested, true, "cancel flag set")
    XrayAuto.endLadderBuild()
    TestRunner:assertEqual(XrayAuto.ladderBuild(), nil, "ended")
end)

TestRunner:test("ladder disk round-trip: ascending order, replace-within-tolerance, O(1) count", function()
    ActionCache.clearXrayLadder(DOC_PATH)
    -- Push out of order; expect ascending on read
    for _idx, p in ipairs({ 0.4, 0.2, 0.6 }) do
        local ok_push = ActionCache.pushXrayLadderRung(DOC_PATH, {
            result = '{"rung": ' .. tostring(p) .. '}', progress_decimal = p,
            progress_page = math.floor(p * 100), timestamp = 1700000000 + math.floor(p * 10),
            used_book_text = true, model = "m",
        })
        TestRunner:assertEqual(ok_push, true, "push " .. tostring(p) .. " succeeds")
    end
    local ladder = ActionCache.getXrayLadder(DOC_PATH)
    TestRunner:assertEqual(#ladder, 3, "three rungs")
    TestRunner:assertEqual(ladder[1].progress_decimal, 0.2, "ascending: lowest first")
    TestRunner:assertEqual(ladder[3].progress_decimal, 0.6, "highest last")
    TestRunner:assertEqual(ActionCache.getXrayLadderCount(DOC_PATH), 3, "header count")
    TestRunner:assertEqual(ActionCache.highestXrayLadderProgress(ladder), 0.6, "highest progress")

    -- Same-progress re-push replaces, never duplicates (resume overlap)
    ActionCache.pushXrayLadderRung(DOC_PATH, {
        result = '{"rung": "0.4 v2"}', progress_decimal = 0.402, timestamp = 1700009999,
    })
    ladder = ActionCache.getXrayLadder(DOC_PATH)
    TestRunner:assertEqual(#ladder, 3, "replaced within tolerance, not appended")
    TestRunner:assertEqual(ladder[2].result, '{"rung": "0.4 v2"}', "newer rung content wins")

    ActionCache.clearXrayLadder(DOC_PATH)
    TestRunner:assertEqual(ActionCache.getXrayLadderCount(DOC_PATH), 0, "cleared -> 0")
end)

TestRunner:test("promoteXrayLadderRung: copy semantics, conditional ring push, flag fallback", function()
    ActionCache.clearXrayLadder(DOC_PATH)
    ActionCache.clearXrayCheckpoints(DOC_PATH)
    ActionCache.clearXrayCache(DOC_PATH)
    ActionCache.clear(DOC_PATH, "xray")

    -- No live entry at all: promotion INSTALLS the rung (build-from-nothing case)
    ActionCache.pushXrayLadderRung(DOC_PATH, {
        result = '{"rung": "20"}', progress_decimal = 0.2, progress_page = 20,
        timestamp = 1700000020, used_book_text = true, used_highlights = false, model = "m-20",
    })
    local ladder = ActionCache.getXrayLadder(DOC_PATH)
    local ok_install = ActionCache.promoteXrayLadderRung(DOC_PATH, ladder[1], 5)
    TestRunner:assertEqual(ok_install, true, "install succeeds without a live entry")
    local live = ActionCache.getXrayCache(DOC_PATH)
    TestRunner:assertEqual(live.result, '{"rung": "20"}', "rung is live (doc key)")
    TestRunner:assertEqual(live.timestamp, 1700000020, "rung generation time preserved")
    local pa = ActionCache.get(DOC_PATH, "xray")
    TestRunner:assertEqual(pa and pa.result, '{"rung": "20"}', "per-action key updated too")
    TestRunner:assertEqual(#ActionCache.getXrayCheckpoints(DOC_PATH), 0,
        "no ring push when nothing was live")
    TestRunner:assertEqual(#ActionCache.getXrayLadder(DOC_PATH), 1, "rung STAYS in the ladder (copy)")

    -- Live == a ladder rung: promotion must NOT ring-archive it (dup guard)
    ActionCache.pushXrayLadderRung(DOC_PATH, {
        result = '{"rung": "40"}', progress_decimal = 0.4, progress_page = 40,
        timestamp = 1700000040, used_book_text = true, model = "m-40",
    })
    ladder = ActionCache.getXrayLadder(DOC_PATH)
    local ok_step = ActionCache.promoteXrayLadderRung(DOC_PATH, ladder[2], 5)
    TestRunner:assertEqual(ok_step, true, "promotion over a rung-identical live succeeds")
    TestRunner:assertEqual(#ActionCache.getXrayCheckpoints(DOC_PATH), 0,
        "no ring dup: outgoing live was itself a rung")
    TestRunner:assertEqual(ActionCache.getXrayCache(DOC_PATH).result, '{"rung": "40"}', "live moved forward")

    -- Live NOT a rung (manual update happened): promotion ring-archives it
    ActionCache.setXrayCache(DOC_PATH, '{"manual": "45"}', 0.45,
        { model = "m-manual", used_book_text = true, used_highlights = true, progress_page = 45 })
    ActionCache.set(DOC_PATH, "xray", '{"manual": "45"}', 0.45, { model = "m-manual" })
    ActionCache.pushXrayLadderRung(DOC_PATH, {
        result = '{"rung": "60"}', progress_decimal = 0.6, progress_page = 60,
        timestamp = 1700000060, model = "m-60",
        -- no used_* flags on this rung: promotion falls back to the live entry's
    })
    ladder = ActionCache.getXrayLadder(DOC_PATH)
    local ok_over = ActionCache.promoteXrayLadderRung(DOC_PATH, ladder[3], 5)
    TestRunner:assertEqual(ok_over, true, "promotion over a manual live succeeds")
    local ring = ActionCache.getXrayCheckpoints(DOC_PATH)
    TestRunner:assertEqual(#ring, 1, "manual live was ring-archived")
    TestRunner:assertEqual(ring[1].result, '{"manual": "45"}', "with its content")
    live = ActionCache.getXrayCache(DOC_PATH)
    TestRunner:assertEqual(live.result, '{"rung": "60"}', "rung is live")
    TestRunner:assertEqual(live.used_highlights, true, "missing rung flag falls back to live's (superset)")

    ActionCache.clearXrayLadder(DOC_PATH)
    ActionCache.clearXrayCheckpoints(DOC_PATH)
    ActionCache.clearXrayCache(DOC_PATH)
    ActionCache.clear(DOC_PATH, "xray")
end)

TestRunner:test("clearAll clears companion files (ladder resurrection guard)", function()
    ActionCache.pushXrayLadderRung(DOC_PATH, {
        result = '{"r": 1}', progress_decimal = 0.2, timestamp = 1700000001,
    })
    ActionCache.pushXrayCheckpoint(DOC_PATH, {
        result = '{"c": 1}', progress_decimal = 0.1, timestamp = 1700000002,
    })
    ActionCache.clearAll(DOC_PATH)
    TestRunner:assertEqual(ActionCache.getXrayLadderCount(DOC_PATH), 0,
        "delete-all clears the ladder (no promotion resurrection)")
    TestRunner:assertEqual(#ActionCache.getXrayCheckpoints(DOC_PATH), 0,
        "delete-all clears the ring (no orphan)")
end)

os.execute(string.format("rm -rf %q", TMP_ROOT))

local ok = TestRunner:summary()
return ok
