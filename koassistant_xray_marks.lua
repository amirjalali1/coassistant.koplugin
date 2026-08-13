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

Spoiler stance (round 5, per the standing round-7 ruling): the LIVE X-Ray is
the marking truth in every posture — installed content already reveals
through its coverage, and demoting to an at-position checkpoint silently
split the mark set from the lookup set (entities added as the X-Ray grew
existed for lookup/tap yet never marked). All section X-Rays fold in,
range-free, for the same one-truth reason. The entity index rebuilds only
when the cache or user-alias sidecar changes on disk (mtime+size stamps —
stats per turn, parses only on change).

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
--   stamps,            -- cache+aliases disk stamp gating the reloads
--   live,              -- in-memory live entry, reloaded on stamp change
--   sections,          -- { {key, sp, ep, stamp, data} } ranges resolved on
--                      -- stamp change; in-range filter per turn is pure
--                      -- arithmetic (round 3: section-only entities were
--                      -- invisible to marking)
--   artifact_key,      -- identity of the artifacts the entity index came from
--   entities,          -- XrayParser.buildMarkEntities output (main + in-range sections)
--   term_hits = {},    -- term text (lower) -> { {start, e, page}, ... }
--   page_marks,        -- current page: { {x,y,w,h, name}, ... } — FULL word
--                      -- boxes, the tap targets (round 2, d2)
--   paint_boxes,       -- same-line-merged union rects the strips paint from
--                      -- (round 3: overlapping invertRect strips XOR each
--                      -- other back to normal — "only 'on' of Kubrickon")
-- }
local st = nil

-- The paint widget: registerViewModule injects .view/.ui; paintTo runs on
-- every view repaint, so it must only READ prepared state.
local paint_widget = {
  paintTo = function(_w, bb, _x, _y)
    local boxes = st and st.paint_boxes
    if not boxes then return end
    local Screen = require("device").screen
    local strip = math.max(2, Screen:scaleBySize(2))
    for _i, box in ipairs(boxes) do
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
  local apath = ActionCache.getUserAliasesPath(file)
  local aattr = apath and lfs.attributes(apath)
  parts[#parts + 1] = aattr and (tostring(aattr.modification) .. ":" .. tostring(aattr.size)) or "-"
  return table.concat(parts, "|")
end

--- The artifact behind the marks: the LIVE X-Ray, always (round 5). The
--- earlier draft demoted to a ladder checkpoint at-or-below the reading
--- position under spoiler protection — but that contradicts the standing
--- round-7 ruling ("installed content already reveals through its coverage;
--- a complete install reveals everything"), and it silently split the mark
--- set from the lookup set: entities added as the X-Ray grew (the minor
--- ones) existed for lookup/tap yet never marked. Installed = revealed;
--- marked = findable, one truth. ai_knowledge/non-JSON lineages never mark.
local function pickArtifact()
  local XrayParser = require("koassistant_xray_parser")
  local live = st.live
  if not (live and live.result) or live.source_mode == "ai_knowledge"
      or not XrayParser.isJSON(live.result) then
    return nil
  end
  return live
end

--- Reload disk state on stamp change, re-pick the artifacts, rebuild the
--- entity index when the pick changed. Cheap when nothing moved.
local function ensureIndex(plugin, pageno)
  local ActionCache = require("koassistant_action_cache")
  local stamps = diskStamps(ActionCache, st.file)
  if stamps ~= st.stamps then
    st.stamps = stamps
    st.live = ActionCache.getXrayCache(st.file)
    -- Section X-Rays (round 3): entities that live only in a section were
    -- invisible to marking while every LOOKUP surface searches sections
    -- too. Ranges resolve once per disk change (the real resolver — an
    -- exclusive end xpointer and last-section/hidden-flow handling live
    -- there); the per-turn in-range filter is pure arithmetic.
    st.sections = {}
    local doc = plugin.ui and plugin.ui.document
    for _idx, sec in ipairs(ActionCache.getSectionXrays(st.file)) do
      if sec.data and sec.data.result then
        local okr, sp, ep = pcall(ActionCache.getSectionPageRange, sec.data, doc)
        if okr and sp and ep then
          st.sections[#st.sections + 1] = { key = sec.key, sp = sp, ep = ep,
            stamp = tostring(sec.data.timestamp), data = sec.data }
        end
      end
    end
  end
  local art = pickArtifact()
  -- Round 5: ALL section X-Rays fold in, range-free — the lookup/intercept
  -- surfaces search every section regardless of range (searchAllXrays), so
  -- a section-only entity was findable-but-never-marked outside its span
  -- (device: ents jumped 153→181 across a section boundary while "Danny
  -- Lloyd" matched lookups everywhere and marks nowhere). Marked = findable,
  -- one truth; the spoiler angle is covered by the round-7 ruling (installed
  -- content reveals through its coverage — sections are installed content).
  if not art and #(st.sections or {}) == 0 then
    st.entities = nil
    st.artifact_key = nil
    return
  end
  local key = art and (tostring(art.timestamp) .. "|" .. tostring(art.progress_decimal)) or "-"
  for _idx, s in ipairs(st.sections or {}) do
    key = key .. "|" .. s.key .. ":" .. s.stamp
  end
  key = key .. "|" .. st.stamps
  if st.artifact_key == key and st.entities then return end
  local XrayParser = require("koassistant_xray_parser")
  local user_aliases = ActionCache.getUserAliases(st.file)
  local ents = {}
  local included, skipped = {}, {}
  local function addFrom(result)
    local data = XrayParser.parse(result)
    if not data then return end
    XrayParser.mergeUserAliases(data, user_aliases)
    for _idx, e in ipairs(XrayParser.buildMarkEntities(data)) do
      ents[#ents + 1] = e
      included[e.category_key] = (included[e.category_key] or 0) + 1
    end
    -- Tally what the category gate dropped — the one line that separates
    -- "entity in a non-marking category" from "entity not in this artifact"
    -- on the next logged round
    for _idx, cat in ipairs(XrayParser.getCategories(data) or {}) do
      if XrayParser.TEXT_MATCH_EXCLUDED[cat.key] and #cat.items > 0 then
        skipped[cat.key] = (skipped[cat.key] or 0) + #cat.items
      end
    end
  end
  if art then addFrom(art.result) end
  for _idx, s in ipairs(st.sections or {}) do addFrom(s.data.result) end
  st.entities = #ents > 0 and ents or nil
  st.artifact_key = key
  local function tally(t)
    local parts = {}
    for k, v in pairs(t) do parts[#parts + 1] = k .. "=" .. v end
    table.sort(parts)
    return table.concat(parts, " ")
  end
  local src = "none"
  if art then
    local pct = art.full_document and 100
        or math.floor((tonumber(art.progress_decimal) or 0) * 100 + 0.5)
    src = (art == st.live and "live@" or "checkpoint@") .. pct .. "%"
  end
  logger.info("KOAssistant marks: index rebuilt from " .. src
    .. " +" .. tostring(#(st.sections or {})) .. " sections: "
    .. tally(included) .. (next(skipped) and (" | skipped: " .. tally(skipped)) or ""))
end

-- Word-boundary honesty for plain terms (round 3, device: "Kubrick" marked
-- inside "Kubrickon"): crengine's own word segmentation arrives as
-- matched_word_prefix/suffix — leftover LETTERS in the same word mean a
-- mid-word substring match, dropped for marking. Possessive tails ('s) and
-- pure punctuation stay markable ("Kubrick's" must mark). Arabic regex
-- terms are exempt: their pattern already consumes article/diacritic
-- variants, and attached-prefix morphology needs the looseness.
local function blockingAffix(s)
  if not s or s == "" then return false end
  if s == "'s" or s == "\226\128\153s" then return false end
  if s:find("%a") or s:find("[\128-\255]") then return true end
  return false
end

--- Whole-doc hit list for one term, page precomputed per hit. Memoized by
--- the caller; runs at most once per term per session.
--- Search flags are LOAD-BEARING (round 4, the unmarked "Danny Lloyd"):
--- without them crengine matches nothing across DOM text-node boundaries
--- (MATCH_ACROSS_TEXT_NODES) and folds no NBSP/soft-hyphen/curly-apostrophe
--- (FOLD_* / IGNORE_FORMAT_CONTROL_CHARS) — a styled or NBSP-joined name
--- passes the page-TEXT presence check yet returns zero search hits, and
--- the empty result memoizes. 0x00FF = stock's default-search flag set;
--- regex rides 0x0001 exactly like stock's regex search type.
local function searchTerm(document, term)
  local res
  if term.regex then
    res = document:findAllText(term.regex, true, 1, 2000, true, 0x0001)
  else
    res = document:findAllText(term.text, true, 1, 2000, false, 0x00FF)
  end
  local hits = {}
  if res then
    for _i, r in ipairs(res) do
      local keep = true
      if not term.regex and (blockingAffix(r.matched_word_prefix)
          or blockingAffix(r.matched_word_suffix)) then
        keep = false
      end
      if keep then
        local ok, page = pcall(document.getPageFromXPointer, document, r.start)
        if ok and page then
          hits[#hits + 1] = { start = r.start, e = r["end"], page = page }
        end
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

-- Union overlapping same-line boxes into single paint rects (round 3):
-- invertRect is self-cancelling, so two entities matching overlapping spans
-- (Arabic article variants, main+section duplicates) XOR each other back to
-- normal — the "only the 'on' of Kubrickon marked" artifact. Tap targets
-- keep the raw per-entity boxes; only the painted strips merge.
local function mergeLineBoxes(marks)
  local rows = {}
  for _i, m in ipairs(marks) do
    local placed = false
    for _j, row in ipairs(rows) do
      if math.abs(row.y - m.y) < math.max(row.h, m.h) / 2 then
        row.boxes[#row.boxes + 1] = m
        placed = true
        break
      end
    end
    if not placed then
      rows[#rows + 1] = { y = m.y, h = m.h, boxes = { m } }
    end
  end
  local out = {}
  for _i, row in ipairs(rows) do
    table.sort(row.boxes, function(a, b) return a.x < b.x end)
    local cur
    for _j, b in ipairs(row.boxes) do
      if cur and b.x <= cur.x + cur.w then
        local right = math.max(cur.x + cur.w, b.x + b.w)
        local bottom = math.max(cur.y + cur.h, b.y + b.h)
        cur.y = math.min(cur.y, b.y)
        cur.w = right - cur.x
        cur.h = bottom - cur.y
      else
        cur = { x = b.x, y = b.y, w = b.w, h = b.h }
        out[#out + 1] = cur
      end
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
    st.paint_boxes = nil
    return
  end

  -- A live search session owns the page visuals: our findAllText shares
  -- crengine's selection state with the session's hit highlighting, so a
  -- scan mid-session ERASES the highlights (round 3, device: "hits are no
  -- longer highlighted"). The session flag is set by the onShowSearchDialog
  -- wrap BEFORE the initial jump (do_search runs before UIManager:show, so
  -- isWidgetShown alone misses the first hit); once the dialog has been
  -- seen shown, its close ends the session and marks resume.
  local search = ui.search
  local sd = search and search.search_dialog
  if sd and UIManager:isWidgetShown(sd) then
    search._koassistant_search_session = "shown"
    st.page_marks = nil
    st.paint_boxes = nil
    return
  end
  local sess = search and search._koassistant_search_session
  if sess == true then
    st.page_marks = nil
    st.paint_boxes = nil
    return
  elseif sess then
    -- Was shown, now closed: session over
    search._koassistant_search_session = nil
  end

  st.page_marks = nil
  st.paint_boxes = nil
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

    -- Diagnosis lines (features.debug only): which terms went present this
    -- turn, which entities marked, and the collapsed page text itself —
    -- enough to replay a presence miss offline (round 3, the unmarked
    -- Danny Lloyd hunt)
    local dbg = plugin.settings
        and (plugin.settings:readSetting("features") or {}).debug
        and { present = {}, marked = {} } or nil

    local marks = {}
    for _i, ent in ipairs(st.entities) do
      if not st.families or st.families[ent.family] then
        local ent_done = false
        for _j, term in ipairs(ent.terms) do
          local tkey = term.text:lower()
          local hits = st.term_hits[tkey]
          if not hits and hay:find(term.norm, 1, true) then
            if dbg then table.insert(dbg.present, term.text) end
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
        if dbg and ent_done then table.insert(dbg.marked, ent.name) end
      end
    end
    if #marks > 0 then
      st.page_marks = dedupeMarks(marks)
      st.paint_boxes = mergeLineBoxes(st.page_marks)
    end
    if dbg then
      logger.info("KOAssistant marks dbg: page " .. tostring(pageno)
        .. " ents=" .. tostring(#st.entities)
        .. " fresh_present=[" .. table.concat(dbg.present, ", ") .. "]"
        .. " marked=[" .. table.concat(dbg.marked, ", ") .. "]"
        .. " boxes=" .. tostring(st.page_marks and #st.page_marks or 0))
      logger.info("KOAssistant marks dbg hay: " .. hay)
    end
  end)
  if not ok then
    logger.warn("KOAssistant marks: scan failed:", err)
    st.page_marks = nil
    st.paint_boxes = nil
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
