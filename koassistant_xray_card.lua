--[[--
Compact entity card (A10 point-4 v1, ref #78 / #63): ONE landing surface for
exact entity hits — the ambient-mark tap and both selection intercepts all
open this instead of jumping straight into the full browser entry.

Two tiers (maintainer design 2026-08-14):
- The CARD is the identification tier: name, category, the description's
  first sentence. It may draw from the NEWEST BUILT checkpoint even when that
  is ahead of the reader — "know who characters are when they first appear"
  — which is the deliberate, bounded peek.
- "Full entry" is the position tier: it resolves against the INSTALLED
  artifact via the existing exact-match lookup path (browser detail, natural
  back stack). An entity that exists ONLY ahead reveals its full entry
  behind a confirm while spoiler protection is on; with protection off the
  live artifact is the newest anyway (promotion), so no split exists.

The module is UI + pure resolution only; routing and the landing preference
(`features.xray_card_landing`) live in main.lua's AskGPT:openXrayCard.
]]

local UIManager = require("ui/uimanager")
local T = require("ffi/util").template
local _ = require("koassistant_gettext")

local XrayCard = {}

--- First sentence of a description, capped — the identification line.
--- Pure (unit-testable). Sentence end = period/question/exclamation (ASCII +
--- Arabic ؟ / ۔) followed by whitespace; falls back to a word-boundary cap.
--- @param desc string|nil
--- @return string ("" when nothing usable)
function XrayCard.firstSentence(desc)
    if type(desc) ~= "string" then return "" end
    local s = desc:match("^%s*(.-)%s*$") or ""
    if s == "" then return "" end
    local cut = s:find("[%.!%?]%s") or s:find("؟%s") or s:find("۔%s")
    local first = cut and s:sub(1, cut) or s
    if #first > 220 then
        first = first:sub(1, 220):gsub("%s+%S*$", "") .. "…"
    end
    return first
end

--- The item's description-ish text, whatever field the category uses.
local function itemText(item)
    if type(item) ~= "table" then return "" end
    for _idx, f in ipairs({ "description", "definition", "significance", "summary" }) do
        if type(item[f]) == "string" and item[f] ~= "" then return item[f] end
    end
    return ""
end

--- Resolve an exact entity hit across the live main X-Ray, every section
--- X-Ray, and the newest built checkpoint AHEAD of the live one (in that
--- order — position truth first, the identification peek last).
--- @param file string book path
--- @param query string the tapped/selected text
--- @return table|nil hit { name, item, category_key, category_label,
---   source = "live"|"section"|"ahead", ahead_progress, query }
function XrayCard.resolve(file, query)
    if not file or type(query) ~= "string" or query == "" then return nil end
    local ActionCache = require("koassistant_action_cache")
    local XrayParser = require("koassistant_xray_parser")
    local user_aliases = ActionCache.getUserAliases(file)

    local function findIn(result)
        if type(result) ~= "string" or not XrayParser.isJSON(result) then return nil end
        local data = XrayParser.parse(result)
        if type(data) ~= "table" or data.error then return nil end
        XrayParser.mergeUserAliases(data, user_aliases)
        local results = XrayParser.searchAll(data, query, { exact = true })
        if results and #results > 0 then return results[1] end
    end

    local function makeHit(r, source, ahead_progress)
        return {
            name = XrayParser.getItemName(r.item, r.category_key),
            item = r.item,
            category_key = r.category_key,
            category_label = r.category_label,
            source = source,
            ahead_progress = ahead_progress,
            query = query,
        }
    end

    local live = ActionCache.getXrayCache(file)
    local live_p = 0
    if live and live.result then
        live_p = live.full_document and 1.0 or tonumber(live.progress_decimal) or 0
        if live.source_mode ~= "ai_knowledge" then
            local r = findIn(live.result)
            if r then return makeHit(r, "live") end
        end
    end
    for _idx, sec in ipairs(ActionCache.getSectionXrays(file)) do
        if sec.data and sec.data.result then
            local r = findIn(sec.data.result)
            if r then return makeHit(r, "section") end
        end
    end
    -- The identification peek: the newest built rung past the live coverage
    local best
    for _idx, rg in ipairs(ActionCache.getXrayLadder(file)) do
        local p = rg.full_document and 1.0 or tonumber(rg.progress_decimal) or 0
        if rg.result and not rg.intro and p > live_p + 0.005 then
            if not best or p > best.p then best = { rung = rg, p = p } end
        end
    end
    if best then
        local r = findIn(best.rung.result)
        if r then return makeHit(r, "ahead", best.p) end
    end
    return nil
end

--- Show the card. opts.on_full(hit) opens the full entry (router-owned).
function XrayCard.show(hit, opts)
    local ButtonDialog = require("ui/widget/buttondialog")
    local parts = { hit.name or "" }
    if type(hit.category_label) == "string" and hit.category_label ~= "" then
        parts[1] = parts[1] .. "  ·  " .. hit.category_label
    end
    local ident = XrayCard.firstSentence(itemText(hit.item))
    if ident ~= "" then
        parts[#parts + 1] = ident
    end
    if hit.source == "ahead" and hit.ahead_progress then
        -- Transparency: the identification came from ahead of the reader
        parts[#parts + 1] = T(_("(from the checkpoint built to %1%)"),
            math.floor(hit.ahead_progress * 100 + 0.5))
    end
    local dialog
    dialog = ButtonDialog:new{
        title = table.concat(parts, "\n\n"),
        title_align = "left",
        buttons = {
            {
                {
                    text = _("Full entry…"),
                    callback = function()
                        UIManager:close(dialog)
                        if opts and opts.on_full then opts.on_full(hit) end
                    end,
                },
                {
                    text = _("Close"),
                    callback = function() UIManager:close(dialog) end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

--- Full detail of an AHEAD-only entity (v1: a plain TextViewer — the browser
--- stack renders the LIVE artifact, and this entity is not in it yet; the
--- browser-hosted ahead view is a recorded follow-up).
function XrayCard.showFullDetail(hit)
    local TextViewer = require("ui/widget/textviewer")
    local item = hit.item or {}
    local parts = {}
    local text = itemText(item)
    if text ~= "" then parts[#parts + 1] = text end
    if type(item.aliases) == "table" and #item.aliases > 0 then
        local ok_names = {}
        for _idx, a in ipairs(item.aliases) do
            if type(a) == "string" and a ~= "" then ok_names[#ok_names + 1] = a end
        end
        if #ok_names > 0 then
            parts[#parts + 1] = T(_("Also: %1"), table.concat(ok_names, ", "))
        end
    end
    if type(item.connections) == "string" and item.connections ~= "" then
        parts[#parts + 1] = T(_("Connections: %1"), item.connections)
    elseif type(item.connections) == "table" and #item.connections > 0 then
        local lines = {}
        for _idx, c in ipairs(item.connections) do
            if type(c) == "string" and c ~= "" then lines[#lines + 1] = "• " .. c end
        end
        if #lines > 0 then
            parts[#parts + 1] = _("Connections:") .. "\n" .. table.concat(lines, "\n")
        end
    end
    if type(item.background) == "table" and #item.background > 0 then
        local lines = {}
        for _idx, b in ipairs(item.background) do
            if type(b) == "table" and type(b.text) == "string" and b.text ~= "" then
                lines[#lines + 1] = "• " .. b.text
            end
        end
        if #lines > 0 then
            parts[#parts + 1] = _("From earlier books:") .. "\n" .. table.concat(lines, "\n")
        end
    end
    if #parts == 0 then parts[1] = _("(no description)") end
    UIManager:show(TextViewer:new{
        title = hit.name or "",
        text = table.concat(parts, "\n\n"),
        justified = false,
    })
end

return XrayCard
