--[[--
Background X-Ray auto-update: trigger gates + cross-instance session state
(docs/xray_background_plan.md).

Gate logic is pure (quiz_chapters precedent — no KOReader deps, unit-testable):
`shouldFire(state, progress_decimal, pageno, now)` answers from its arguments only.
The module additionally holds file-local session state that must survive ReaderUI
plugin-instance teardown on book switch (`last_attempt`, the in-flight flag, the
subprocess cancel handle, and the session failure/success trace): per-instance
`self._*` state would reset the rate limit on every book hop and orphan the
in-flight flag. main.lua owns all event wiring and disk reads.
]]

local XrayAuto = {}

-- Defaults (xray_background_plan.md §10: threshold/cap/cooldown are user dials now;
-- these values back the schema defaults and any state without stamped dials)
XrayAuto.THRESHOLD = 0.05        -- min progress delta before an update is worth firing
XrayAuto.MAX_DELTA = 0.25        -- cap: bigger gaps stay manual (the popup shows size/cost)
XrayAuto.RATE_LIMIT_S = 15 * 60  -- min seconds between background attempts
XrayAuto.JUMP_GUARD_PAGES = 5    -- quiz pattern: a TOC jump moves many pages, a turn 1-3
XrayAuto.SCHEDULE_DELAY_S = 3    -- defer the fire off the page-turn tick
XrayAuto.CATCHUP_DELAY_S = 30    -- session-start catch-up delay (update-checker pattern)
XrayAuto.WATCHDOG_S = 300        -- absolute cancel; don't rely on the child's socket timeout.
                                 -- Device round 1 (T1): thinking-default models take 100s+ per
                                 -- incremental update — 120 killed legitimate runs.

-- Cross-instance session state (file-local module state, NOT self._*)
local last_attempt = nil   -- stamped at SCHEDULE time, not fire time
local in_flight = false
local in_flight_file = nil -- which book the flight belongs to (popup display scoping, T8)
local cancel_fn = nil
local last_failure = nil   -- { file = path, message = string }
local session_updates = 0
local cancelled = false    -- set when an actual flight was cancelled (close/watchdog)
local discarded = false    -- set by the completion guard when it rejects the write
local watchdogged = false  -- set when the WATCHDOG killed the flight (T1: a timeout is a
                           -- visible failure, never a silent cancel)

--- Resolve the user dials (schema: Reading & Library → X-Ray) into gate values.
--- Pure; fallbacks MUST match the schema defaults (5% / 25% / 15 min). An inverted
--- window (max < min) clamps to max = min rather than silently never firing.
--- @param features table settings features (may be nil)
--- @return table { min_gap, max_gap, cooldown_s }
function XrayAuto.dialsFromFeatures(features)
  local f = features or {}
  local min_gap = (tonumber(f.xray_auto_min_gap) or 5) / 100
  local max_gap = (tonumber(f.xray_auto_max_gap) or 25) / 100
  if max_gap < min_gap then max_gap = min_gap end
  return {
    min_gap = min_gap,
    max_gap = max_gap,
    cooldown_s = (tonumber(f.xray_auto_cooldown) or 15) * 60,
  }
end

--- Pure trigger gate. All checks answerable from arguments; disk truth (fresh cache
--- read, WiFi, document type) is the caller's job at fire time. Dial fields on state
--- (min_gap/max_gap/cooldown_s, from dialsFromFeatures) override the module defaults.
--- @param state table { auto_update, eligible, cached_progress, prev_page, min_gap, max_gap, cooldown_s } (may be stale)
--- @param progress_decimal number current position 0..1 (cheap approximation is fine)
--- @param pageno number current page (jump guard)
--- @param now number os.time()
--- @return table { fire = boolean, reason = string }
function XrayAuto.shouldFire(state, progress_decimal, pageno, now)
  if not state or state.auto_update ~= true then
    return { fire = false, reason = "not_opted_in" }
  end
  if state.eligible ~= true then
    return { fire = false, reason = "not_eligible" }
  end
  if type(progress_decimal) ~= "number" or type(state.cached_progress) ~= "number" then
    return { fire = false, reason = "no_progress" }
  end
  local delta = progress_decimal - state.cached_progress
  if delta <= (state.min_gap or XrayAuto.THRESHOLD) then
    return { fire = false, reason = "below_threshold" }
  end
  if delta > (state.max_gap or XrayAuto.MAX_DELTA) then
    return { fire = false, reason = "above_cap" }
  end
  -- Jump guard: no prev_page (first turn after open/refresh) or a big hop = not
  -- sequential reading; the page was still tracked by the caller.
  if not state.prev_page or math.abs((pageno or 0) - state.prev_page) > XrayAuto.JUMP_GUARD_PAGES then
    return { fire = false, reason = "page_jump" }
  end
  -- in_flight before the rate limit: both usually hold together (the limit is
  -- stamped at schedule time), and "in_flight" is the honest reason then
  if in_flight then
    return { fire = false, reason = "in_flight" }
  end
  if last_attempt and now and (now - last_attempt) < (state.cooldown_s or XrayAuto.RATE_LIMIT_S) then
    return { fire = false, reason = "rate_limited" }
  end
  return { fire = true, reason = "ok" }
end

--- Stamp the rate limit at SCHEDULE time (several page turns can pass the gates
--- inside the deferral window; only the first may schedule).
function XrayAuto.markScheduled(now)
  last_attempt = now
end

function XrayAuto.beginFlight(file)
  in_flight = true
  in_flight_file = file
end

function XrayAuto.endFlight()
  in_flight = false
  in_flight_file = nil
  cancel_fn = nil
end

function XrayAuto.isInFlight()
  return in_flight
end

--- Which book the current flight belongs to (nil when idle or unknown). The
--- gate stays global — one background request at a time — but popup DISPLAY
--- scopes to the file so another book's flight can't gray out this book's rows.
function XrayAuto.inFlightFile()
  return in_flight_file
end

--- Mark the current flight as watchdog-killed (called by the watchdog closure
--- right before cancelInFlight, so the outcome classifies as a timeout failure).
function XrayAuto.markWatchdog()
  watchdogged = true
end

--- Store the cancel handle returned by the silent request path (gpt_query
--- `config._register_cancel`). Called from inside the request machinery.
function XrayAuto.registerCancel(fn)
  cancel_fn = fn
end

--- Cancel a background request in flight (document close, watchdog). Safe no-op
--- when idle. The completion guard makes a straggler write impossible either way.
function XrayAuto.cancelInFlight()
  if cancel_fn or in_flight then
    -- Only a real cancellation marks the flag — an idle close must not poison the
    -- NEXT fire's outcome classification
    cancelled = true
  end
  if cancel_fn then
    local fn = cancel_fn
    cancel_fn = nil
    pcall(fn)
  end
  in_flight = false
  in_flight_file = nil
end

--- Consume-once outcome markers so the fire callback classifies results honestly
--- (plan §6: the visible trace must not record a guard-discard as a success, nor a
--- book-close cancel as a failure).
function XrayAuto.markDiscarded()
  discarded = true
end

function XrayAuto.consumeOutcomeFlags()
  local c, d, w = cancelled, discarded, watchdogged
  cancelled, discarded, watchdogged = false, false, false
  return c, d, w
end

function XrayAuto.recordFailure(file, message)
  last_failure = { file = file, message = message }
end

function XrayAuto.clearFailure()
  last_failure = nil
end

--- Session-scoped "last auto-update failed" trace for the scope popup.
--- @param file string book path to match
--- @return string|nil failure message
function XrayAuto.lastFailure(file)
  if last_failure and last_failure.file == file then
    return last_failure.message or "failed"
  end
  return nil
end

function XrayAuto.recordSuccess(file)
  session_updates = session_updates + 1
  if last_failure and last_failure.file == file then
    last_failure = nil
  end
end

function XrayAuto.sessionUpdateCount()
  return session_updates
end

--- Derive background-update eligibility from a fresh per-action "xray" cache entry
--- (the entry the update machinery and scope popup key off). Pure; caller does the
--- disk read. Mirrors the manual incremental path's skips (dialogs.lua): missing
--- entry, complete-track, ai_knowledge source, and legacy non-JSON caches never
--- background-update.
--- @param entry table|nil ActionCache.get(file, "xray") result
--- @param is_json_fn function (result_string) -> boolean  (XrayParser.isJSON)
--- @return boolean eligible, number|nil cached_progress
function XrayAuto.eligibilityFromEntry(entry, is_json_fn)
  if not entry or not entry.result then return false, nil end
  if entry.full_document then return false, nil end
  if entry.source_mode == "ai_knowledge" then return false, nil end
  if is_json_fn and not is_json_fn(entry.result) then return false, nil end
  local p = tonumber(entry.progress_decimal)
  if not p or p >= 1.0 then return false, nil end
  return true, p
end

-- ========================= Version ladder (create-ahead) =========================
-- xray_ecosystem_plan.md §5 decisions 10/11 + §6 slice 1 (ref #73 #90). Pure rung
-- math + the build-chain session state live here (same cross-instance rationale as
-- the flight state above); ladder file I/O lives in koassistant_action_cache.lua.

XrayAuto.LADDER_SPACING = 0.10   -- rung boundaries every 10% (baseline; formula below can widen OR narrow)
XrayAuto.LADDER_TOLERANCE = 0.005
XrayAuto.LADDER_MIN_RUNG_PAGES = 45  -- P2(a) floor: a rung must cover at least ~this many pages
                                     -- (round 10: 30 -> 45 — every rung pays a fixed re-send
                                     -- overhead, so short books get fewer, larger calls;
                                     -- 10% baseline now starts at 450pp, not 300)
XrayAuto.LADDER_MAX_RUNG_PAGES = 100 -- P2(a) v2 ceiling: one rung should not extract much more than this
XrayAuto.LADDER_MIN_SPACING = 0.05   -- call-count bound: never more than ~20 rungs, even on monster books
XrayAuto.LADDER_MAX_SPACING = 0.50   -- tiny books still get a midpoint + final rung
XrayAuto.LADDER_SNAP_WINDOW = 0.03   -- P3: chapter-end snap distance (±3%; narrows with tight spacing)
XrayAuto.LADDER_SEED_MIN = 0.03      -- round 19: below this much read text a seed rung is noise

--- P2(a) formula v2 (§7, device round 2): rung spacing targets a pages-per-rung
--- band. The 10% baseline is narrowed on long books so a single rung never
--- extracts much more than LADDER_MAX_RUNG_PAGES (call SIZE bound — a 1500-page
--- book gets ~7% rungs, not 150-page deltas), widened on short books by the
--- min-pages floor (a novella must not burn a call on a 10-page slice). Spacing
--- is clamped to [LADDER_MIN_SPACING, LADDER_MAX_SPACING]: the floor bounds call
--- COUNT on monster books (size may exceed the ceiling there — the two bounds
--- can't both hold, and count wins past ~2000 pages), the cap keeps tiny books
--- at two rungs. Rounded to whole percents (the cost dialog displays it).
--- @param total_pages number|nil document page count
--- @return number spacing ratio (LADDER_MIN_SPACING..LADDER_MAX_SPACING)
function XrayAuto.ladderSpacingFor(total_pages)
  local pages = tonumber(total_pages)
  if not pages or pages <= 0 then return XrayAuto.LADDER_SPACING end
  local spacing = math.min(XrayAuto.LADDER_SPACING, XrayAuto.LADDER_MAX_RUNG_PAGES / pages)
  spacing = math.max(spacing, XrayAuto.LADDER_MIN_RUNG_PAGES / pages)
  spacing = math.floor(spacing * 100 + 0.5) / 100
  if spacing < XrayAuto.LADDER_MIN_SPACING then return XrayAuto.LADDER_MIN_SPACING end
  if spacing > XrayAuto.LADDER_MAX_SPACING then return XrayAuto.LADDER_MAX_SPACING end
  return spacing
end

--- P3 (§7): snap rung targets to chapter-end boundaries so versions read as
--- "up to the end of a chapter" instead of an arbitrary percent. Pure.
--- Boundaries above 1 - SNAP_WINDOW are ignored (a rung that close to the end
--- is the final rung's job) — which also guarantees the 1.0 rung survives the
--- ordering pass below. A target that lands within the update path's 1%
--- engagement threshold of its predecessor (or the base) is dropped: two rungs
--- collapsing onto one chapter build it once.
--- @param rungs table planLadderRungs output (ascending ratios, last = 1.0)
--- @param boundaries table|nil ascending { ratio, title } chapter ends; fewer than 3 = unusable TOC, no-op
--- @param base_progress number|nil the build base (0..1)
--- @param spacing number|nil the rung spacing (formula v2: narrow spacings shrink
--- the snap distance to 40% of a step so ±window never spans adjacent targets;
--- nil keeps the full LADDER_SNAP_WINDOW — the pre-v2 behavior)
--- @return table targets (ascending ratios), table labels (sparse, parallel: labels[i] = chapter title of targets[i])
function XrayAuto.snapLadderRungs(rungs, boundaries, base_progress, spacing)
  if type(boundaries) ~= "table" or #boundaries < 3 then
    return rungs, {}
  end
  local window = XrayAuto.LADDER_SNAP_WINDOW
  if tonumber(spacing) and spacing * 0.4 < window then
    window = spacing * 0.4
  end
  local targets, labels = {}, {}
  local prev = tonumber(base_progress) or 0
  for _idx, target in ipairs(rungs) do
    local snapped, label = target, nil
    if target < 1.0 - XrayAuto.LADDER_TOLERANCE then
      local best_d
      for _b, b in ipairs(boundaries) do
        local ratio = tonumber(b.ratio)
        if ratio and ratio <= 1.0 - XrayAuto.LADDER_SNAP_WINDOW then
          local d = math.abs(ratio - target)
          if d <= window and (not best_d or d < best_d) then
            best_d = d
            snapped = math.floor(ratio * 1000 + 0.5) / 1000
            label = b.title
          end
        end
      end
    end
    if snapped > prev + 0.01 then
      targets[#targets + 1] = snapped
      if label then labels[#targets] = label end
      prev = snapped
    end
  end
  return targets, labels
end

--- Plan the rung targets for a build: multiples of `spacing` above
--- `base_progress`, plus a final 1.0. Pure; rounded to 3 decimals so float drift
--- never produces 0.30000000000000004-style targets.
--- The first rung must sit at least HALF a step ahead of the base (maintainer
--- 2026-07-26: an X-Ray at 48% must not get a 50% rung — a near-boundary rung
--- spends a whole call on a near-duplicate; the base version itself covers that
--- neighborhood in the version set, staying live until promotion ring-archives
--- it). Half-spacing also always clears the update path's 1% engagement
--- threshold, and scales if spacing ever becomes a dial.
--- @param base_progress number|nil 0..1 (nil/0 = build from nothing)
--- @param spacing number|nil override (default LADDER_SPACING)
--- @return table Ascending array of target ratios (empty when base is ≥ ~99%)
function XrayAuto.planLadderRungs(base_progress, spacing, target_end)
  spacing = spacing or XrayAuto.LADDER_SPACING
  local base = tonumber(base_progress) or 0
  -- Round 16 (unified creation flow): optional target bounds the build — cover
  -- a huge section in prefix steps without paying for the rest of the book yet.
  -- nil/invalid = 1.0 (the pre-target behavior; resume later can extend).
  local goal = tonumber(target_end)
  if not goal or goal <= 0 or goal > 1.0 then goal = 1.0 end
  -- Within 1% of the goal the update path wouldn't engage — nothing to build
  if base >= goal - 0.01 then return {} end
  local rungs = {}
  local n = math.floor((base + spacing / 2 - 1e-9) / spacing) + 1
  local target = math.floor(n * spacing * 1000 + 0.5) / 1000
  while target < goal - XrayAuto.LADDER_TOLERANCE do
    rungs[#rungs + 1] = target
    n = n + 1
    target = math.floor(n * spacing * 1000 + 0.5) / 1000
  end
  rungs[#rungs + 1] = goal
  return rungs
end

--- Round 19 (maintainer: "no openable X-Ray until the first checkpoint"): a
--- from-nothing build whose reader sits BELOW the first spacing rung gets a SEED
--- rung exactly at the reading position, so the very first finished checkpoint
--- is promotable and the reader has a live X-Ray right away. Pure.
--- Returns nil when a base exists (something is already live/promotable), when
--- the reader hasn't read enough to be worth a call (LADDER_SEED_MIN), or when
--- the position is within the goal's engagement threshold (the goal rung IS the
--- seed then). The seed deliberately never snaps to a chapter boundary ahead of
--- the reader — a seed past the position could not promote.
--- @param base_progress number|nil build base 0..1 (nil/0 = from nothing)
--- @param position number|nil reading position 0..1
--- @param goal number|nil build target (nil = 1.0)
--- @return number|nil seed ratio (3 decimals)
function XrayAuto.seedForBuild(base_progress, position, goal)
  local base = tonumber(base_progress) or 0
  if base >= 0.01 then return nil end
  local pos = tonumber(position)
  if not pos or pos < XrayAuto.LADDER_SEED_MIN then return nil end
  local g = tonumber(goal)
  if not g or g <= 0 or g > 1.0 then g = 1.0 end
  if pos >= g - 0.01 then return nil end
  return math.floor(pos * 1000 + 0.5) / 1000
end

--- Full build plan incl. the seed: the tail is planned FROM the seed, so the
--- half-spacing rule naturally drops a spacing rung the seed already covers
--- (a seed at 12% with 15% spacing plans 30% next, not 15%). Pure.
--- @return table ascending rung targets (seed first when present), number|nil seed
function XrayAuto.planBuildRungs(base_progress, spacing, target_end, position)
  local seed = XrayAuto.seedForBuild(base_progress, position, target_end)
  local rungs = XrayAuto.planLadderRungs(seed or base_progress, spacing, target_end)
  if seed then table.insert(rungs, 1, seed) end
  return rungs, seed
end

--- Pick the rung to promote into the live cache: the highest rung at-or-below
--- the reading position (½% tolerance) that is AHEAD of the live entry. Rungs
--- ahead of the reader never qualify (spoiler by definition — same rule as
--- nearestCheckpointIndex); full-document entries never qualify.
--- @param ladder table Rung array (any order)
--- @param live_progress number|nil live cache progress 0..1
--- @param position number|nil reading position 0..1
--- @return table|nil rung entry
function XrayAuto.pickPromotableRung(ladder, live_progress, position)
  if type(position) ~= "number" then return nil end
  local best, best_p
  for _idx, rung in ipairs(ladder or {}) do
    local p = tonumber(rung.progress_decimal)
    if p and not rung.full_document
        and p <= position + XrayAuto.LADDER_TOLERANCE
        and p > (tonumber(live_progress) or 0) + XrayAuto.LADDER_TOLERANCE then
      if not best_p or p > best_p then
        best, best_p = rung, p
      end
    end
  end
  return best
end

-- Build-chain session state (module-local, survives instance teardown like the
-- flight state — though a book close cancels the chain anyway). One build at a
-- time, plugin-wide.
local ladder_build = nil  -- { file, rungs = {targets}, idx, total, cancel_requested }

--- @return table|nil the active build state (nil when idle)
function XrayAuto.ladderBuild()
  return ladder_build
end

--- @param labels table|nil sparse array parallel to rungs (snapLadderRungs output):
--- labels[i] = chapter title for rungs[i], carried into each rung's cache entry
function XrayAuto.beginLadderBuild(file, rungs, labels)
  ladder_build = { file = file, rungs = rungs, labels = labels, idx = 1, total = #rungs }
end

--- Advance to the next rung. Returns the next target ratio, or nil when done.
function XrayAuto.advanceLadderBuild()
  if not ladder_build then return nil end
  ladder_build.idx = ladder_build.idx + 1
  return ladder_build.rungs[ladder_build.idx]
end

function XrayAuto.endLadderBuild()
  ladder_build = nil
end

--- Ask the chain to stop after the current rung completes (a rung mid-network
--- additionally gets cancelInFlight from the caller).
function XrayAuto.requestLadderCancel()
  if ladder_build then ladder_build.cancel_requested = true end
end

return XrayAuto
