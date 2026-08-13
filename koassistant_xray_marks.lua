--[[--
Ambient X-Ray marking (A10 slice 2, ref #78): while reading, entities the
book's X-Ray knows are underlined on the page — a passive "this has an entry"
layer with no search session behind it. Tapping a marked word rides the
EXISTING selection intercept (round 9/10) straight to the entity, so this
module paints and nothing else.

Mechanics (donor-verified, xray_marking_plan.md §1/§6):
- Paint = ONE `ReaderView:registerViewModule` widget (public API, zero
  patching); thin `invertRect` strip at each box bottom (underline — full
  invert is the on-demand emphasis style, not the ambient one).
- Per page turn (the scan runs INSIDE the onPageUpdate dispatch, before the
  repaint, so marks ride the page's own refresh — no extra e-ink flash):
  visible-page text once → cheap normalized `find` presence check per term →
  `findAllText` ONLY for terms actually present and never searched this
  session (whole-doc, memoized per term with per-hit page precomputed) →
  boxes for current-page hits via `getScreenBoxesFromPositions` → dedupe →
  store → painted by the view module in the same cycle.
- EPUB page mode only in v1: scroll mode clears (boxes go stale mid-scroll
  with no per-scroll event granularity worth paying for), PDFs are excluded
  (the donor rides the native highlight.temp slot there, which the search
  session also owns — conflict; follow-up).

Spoiler contract (F2, one rule): posture "full" (protection off — research /
finished / explicit off) → mark from the LIVE artifact. Posture "track"
(protected) → live only if its coverage is at or below the reading position;
otherwise the best non-intro ladder checkpoint at or below the position;
none → no marks (the artifact knows nothing spoiler-safe here). The entity
index rebuilds only when the chosen artifact or the user-alias sidecar
changes (mtime+size stamps — stats per turn, parses only on change).

State is module-resident and single-book (reader-scoped, like the
Attachments staging list); a different file swaps it wholesale.
]]

local UIManager = require("ui/uimanager")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")

local XrayMarks = {}

local MODULE_NAME = "koassistant_xray_marks"

-- st = {
--   file, density_first, families (nil = all),
--   stamps,            -- cache+ladder+aliases disk stamp gating the reloads
--   live, ladder,      -- in-memory copies reloaded on stamp change
--   artifact_key,      -- identity of the artifact the entity index came from
--   entities,          -- XrayParser.buildMarkEntities output
--   term_hits = {},    -- term text (lower) -> { {start, e, page}, ... }
--   page_marks,        -- current page: { {x,y,w,h, name}, ... } — the strip
--                      -- is painted from these, the FULL box is the tap
--                      -- target (round 2, d2)
-- }
local st = nil

-- The paint widget: registerViewModule injects .view/.ui; paintTo runs on
-- every view repaint, so it must only READ prepared state.
local paint_widget = {
  paintTo = function(_w, bb, _x, _y)
    local marks = st and st.page_marks
    if not marks then return end
    local Screen = require("device").screen
    local strip = math.max(2, Screen:scaleBySize(2))
    for _i, box in ipairs(marks) do
      if box.x and box.y and box.w and box.h and box.w > 0 and box.h > strip then
        bb:invertRect(box.x, box.y + box.h - strip, box.w, strip)
      end
    end
  end,
}

--- Disk stamp over everything the entity index depends on. Stats only.
local function diskStamps(ActionCache, file)
  local parts = {}
  local cache_path = ActionCache.getPath(file)
  local attr = cache_path and lfs.attributes(cache_path)
  parts[#parts + 1] = attr and (tostring(attr.modification) .. ":" .. tostring(attr.size)) or "-"
  local sidecar = cache_path and cache_path:gsub("[^/]+$", "")
  local lattr = sidecar and lfs.attributes(sidecar .. ActionCache.XRAY_LADDER_FILE)
  parts[#parts + 1] = lattr and (tostring(lattr.modification) .. ":" .. tostring(lattr.size)) or "-"
  local apath = ActionCache.getUserAliasesPath(file)
  local aattr = apath and lfs.attributes(apath)
  parts[#parts + 1] = aattr and (tostring(aattr.modification) .. ":" .. tostring(aattr.size)) or "-"
  return table.concat(parts, "|")
end

--- The F2 artifact pick. Returns the cache/ladder entry to mark from, or nil.
local function pickArtifact(plugin, pageno)
  local XrayParser = require("koassistant_xray_parser")
  local live = st.live
  if not (live and live.result) or live.source_mode == "ai_knowledge"
      or not XrayParser.isJSON(live.result) then
    return nil
  end
  local posture = plugin._xrayPosture and plugin:_xrayPosture() or "track"
  if posture ~= "full" then
    local total = plugin.ui.document:getPageCount()
    local pos_dec = (total and total > 0) and (pageno / total) or nil
    if pos_dec then
      local live_dec = live.full_document and 1.0
          or (tonumber(live.progress_decimal) or 0)
      if live_dec > pos_dec + 0.01 then
        -- Live artifact is ahead of the reader under protection: mark from
        -- the best checkpoint at or below the position instead
        local best
        for _idx, r in ipairs(st.ladder or {}) do
          local p = tonumber(r.progress_decimal)
          if p and r.result and not r.intro and p <= pos_dec + 0.01
              and (not best or p > (tonumber(best.progress_decimal) or 0)) then
            best = r
          end
        end
        return best
      end
    end
  end
  return live
end

--- Reload disk state on stamp change, re-pick the artifact, rebuild the
--- entity index when the pick changed. Cheap when nothing moved.
local function ensureIndex(plugin, pageno)
  local ActionCache = require("koassistant_action_cache")
  local stamps = diskStamps(ActionCache, st.file)
  if stamps ~= st.stamps then
    st.stamps = stamps
    st.live = ActionCache.getXrayCache(st.file)
    st.ladder = ActionCache.getXrayLadder(st.file)
  end
  local art = pickArtifact(plugin, pageno)
  if not art then
    st.entities = nil
    st.artifact_key = nil
    return
  end
  local key = tostring(art.timestamp) .. "|" .. tostring(art.progress_decimal)
      .. "|" .. st.stamps
  if st.artifact_key == key and st.entities then return end
  local XrayParser = require("koassistant_xray_parser")
  local data = XrayParser.parse(art.result)
  if not data then
    st.entities = nil
    st.artifact_key = nil
    return
  end
  XrayParser.mergeUserAliases(data, ActionCache.getUserAliases(st.file))
  st.entities = XrayParser.buildMarkEntities(data)
  st.artifact_key = key
  logger.dbg("KOAssistant marks: entity index rebuilt,", #st.entities, "entities")
end

--- Whole-doc hit list for one term, page precomputed per hit. Memoized by
--- the caller; runs at most once per term per session.
local function searchTerm(document, term)
  local res
  if term.regex then
    res = document:findAllText(term.regex, true, 0, 2000, true)
  else
    res = document:findAllText(term.text, true, 0, 2000, false)
  end
  local hits = {}
  if res then
    for _i, r in ipairs(res) do
      local ok, page = pcall(document.getPageFromXPointer, document, r.start)
      if ok and page then
        hits[#hits + 1] = { start = r.start, e = r["end"], page = page }
      end
    end
  end
  return hits
end

local function dedupeMarks(marks)
  local seen, out = {}, {}
  for _i, b in ipairs(marks) do
    local k = tostring(b.x) .. "|" .. tostring(b.y) .. "|" .. tostring(b.w)
    if not seen[k] then
      seen[k] = true
      out[#out + 1] = b
    end
  end
  return out
end

--- The per-page-turn scan. Called from AskGPT:onPageUpdate (inside the
--- dispatch, before the repaint) and from sync() for the current page.
function XrayMarks.onPageTurn(plugin, pageno)
  if not st then return end
  local ui = plugin and plugin.ui
  if not (ui and ui.document and ui.rolling and pageno) then return end
  if ui.document.file ~= st.file then return end
  if ui.view and ui.view.view_mode == "scroll" then
    st.page_marks = nil
    return
  end

  st.page_marks = nil
  local ok, err = pcall(function()
    ensureIndex(plugin, pageno)
    if not st.entities or #st.entities == 0 then return end

    -- Visible-page text, once, for the presence pre-check (page-level read,
    -- same consent class as the page-exempt extraction)
    local ContextExtractor = require("koassistant_context_extractor")
    local page_text = ContextExtractor:new(ui):getVisiblePageText().text or ""
    if page_text == "" then return end
    local XrayParser = require("koassistant_xray_parser")
    -- The extracted page text is LAYOUT text: line wraps arrive as newlines,
    -- so a wrapped "Danny\nLloyd" must still match the single-space term
    -- (device 2026-08-14 — multi-word entities silently unmarked when they
    -- wrapped). Collapse all whitespace (NBSP included) to single spaces;
    -- term norms are collapsed the same way at index build.
    local hay = XrayParser.normalizeArabic(page_text:lower())
        :gsub("\194\160", " "):gsub("%s+", " ")

    local marks = {}
    for _i, ent in ipairs(st.entities) do
      if not st.families or st.families[ent.family] then
        local ent_done = false
        for _j, term in ipairs(ent.terms) do
          local tkey = term.text:lower()
          local hits = st.term_hits[tkey]
          if not hits and hay:find(term.norm, 1, true) then
            hits = searchTerm(ui.document, term)
            st.term_hits[tkey] = hits
          end
          if hits then
            for _k, h in ipairs(hits) do
              -- pageno+1 covers two-page spreads; off-view positions
              -- return no/off-screen boxes and the y-filter drops them
              if h.page >= pageno and h.page <= pageno + 1 then
                local bok, bxs = pcall(ui.document.getScreenBoxesFromPositions,
                  ui.document, h.start, h.e, true)
                if bok and bxs then
                  local added = false
                  for _b, box in ipairs(bxs) do
                    if box.y and box.y >= 0 and box.h and box.h > 0 then
                      marks[#marks + 1] = { x = box.x, y = box.y,
                        w = box.w, h = box.h, name = ent.name }
                      added = true
                    end
                  end
                  if added then ent_done = true end
                end
              end
              if st.density_first and ent_done then break end
            end
          end
          if st.density_first and ent_done then break end
        end
      end
    end
    if #marks > 0 then
      st.page_marks = dedupeMarks(marks)
    end
  end)
  if not ok then
    logger.warn("KOAssistant marks: scan failed:", err)
    st.page_marks = nil
  end
end

--- d2 tap layer (round 2): entity name under a tap, or nil. The FULL word
--- box is the target (the painted strip alone would be a sliver); small
--- padding helps e-ink finger accuracy. Gated on the tap setting per call.
--- @param plugin table AskGPT instance
--- @param ges table Tap gesture ({pos = {x, y}})
--- @return string|nil entity name
function XrayMarks.tapTarget(plugin, ges)
  local marks = st and st.page_marks
  if not (marks and ges and ges.pos) then return nil end
  local features = plugin and plugin.settings
      and plugin.settings:readSetting("features") or {}
  if features.xray_marking_tap == false then return nil end
  local Screen = require("device").screen
  local pad = Screen:scaleBySize(3)
  local tx, ty = ges.pos.x, ges.pos.y
  for _i, m in ipairs(marks) do
    if tx >= m.x - pad and tx <= m.x + m.w + pad
        and ty >= m.y - pad and ty <= m.y + m.h + pad then
      return m.name
    end
  end
  return nil
end

--- Install/refresh/remove per settings + book state. Call on reader ready,
--- setting changes, and whenever a surface wants marks to reflect NOW.
function XrayMarks.sync(plugin)
  local ui = plugin and plugin.ui
  local features = plugin and plugin.settings
      and plugin.settings:readSetting("features") or {}
  local eligible = features.xray_marking == true
      and ui and ui.document and ui.rolling and ui.view
  if not eligible then
    XrayMarks.teardown(plugin)
    return
  end

  if not (st and st.file == ui.document.file) then
    st = { file = ui.document.file, term_hits = {} }
  end
  st.density_first = (features.xray_marking_density or "first") ~= "all"
  local fam = features.xray_marking_families or "all"
  if fam == "people" then
    st.families = { people = true }
  elseif fam == "people_places" then
    st.families = { people = true, places = true }
  else
    st.families = nil
  end
  -- Settings may have changed what the index feeds on — force a re-pick
  st.artifact_key = nil

  if not ui.view.view_modules[MODULE_NAME] then
    ui.view:registerViewModule(MODULE_NAME, paint_widget)
  end
  local okp, pageno = pcall(ui.document.getCurrentPage, ui.document)
  XrayMarks.onPageTurn(plugin, okp and pageno or nil)
  if ui.dialog then
    UIManager:setDirty(ui.dialog, "ui")
  end
end

function XrayMarks.teardown(plugin)
  local ui = plugin and plugin.ui
  local was_painting = st and st.page_boxes
  st = nil
  if ui and ui.view and ui.view.view_modules
      and ui.view.view_modules[MODULE_NAME] then
    ui.view.view_modules[MODULE_NAME] = nil
    if was_painting and ui.dialog then
      UIManager:setDirty(ui.dialog, "ui")
    end
  end
end

return XrayMarks
