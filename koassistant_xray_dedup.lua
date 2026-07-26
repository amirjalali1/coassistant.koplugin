--[[--
X-Ray entity dedup flow (xray_ecosystem_plan.md §6 slice 4, ref #90).

"Find duplicate entities" over the live main X-Ray: a local heuristic scan
(exact name / shared alias / contained name) proposes pairs; the reader
resolves each as Merge (deterministic alias absorb), AI merge (one cheap
request for a combined description), or Never (persistent never-merge pair —
consulted by this scan AND injected into the section-merge prompts).

Merge mechanics (§5 design substance): the kept entry absorbs the dropped
entry's name + aliases BOTH into the stored artifact (so update-prompt entity
indexes steer the model to the kept entry) and into the user-aliases sidecar
(so the absorb survives a from-scratch regeneration via mergeUserAliases).
The dropped entry is removed from the stored JSON; the pre-dedup version is
ring-archived once per dedup session.

WIRE-SAFETY: entity names/descriptions are artifact content — the AI-merge
prompt carries only the @@KOA_MERGE_INPUTS@@ sentinel; the text rides
config.features._merge_payload → XrayMerge.injectPayload after
MessageBuilder.build (never action.prompt).
]]

-- Widget requires stay lazy (inside the UI functions): the pure halves are
-- unit-tested under mock_koreader, which does not stub the dialog widgets.
local UIManager = require("ui/uimanager")
local logger = require("logger")
local T = require("ffi/util").template
local _ = require("koassistant_gettext")

local XrayDedup = {}

-- Small prose output; sampling like conversational actions. The budget must
-- survive always-on reasoning models (an explicit max_tokens suppresses the
-- handlers' reasoning bump, and reasoning shares it) — hence 8192 for what is
-- a paragraph of output, plus reasoning off where the model allows it.
XrayDedup.API_PARAMS = { temperature = 0.7, max_tokens = 8192 }

-- Cap on proposed pairs per scan (the list dialog must stay navigable;
-- resolving pairs frees slots on the next scan)
XrayDedup.MAX_PAIRS = 30

-- Event/phrase and singleton categories: their "names" are descriptive
-- sentences, not entity identifiers — pair proposals there are noise
local SCAN_EXCLUDED = {
    timeline = true,
    argument_development = true,
    reader_engagement = true,
    conclusion = true,
    current_state = true,
    current_position = true,
}

-- Contained-name heuristic ("Jack" ⊂ "Jack Torrance") only where names are
-- proper nouns; concept/term categories legitimately nest ("inflation" vs
-- "grade inflation")
local NAME_CONTAIN_CATEGORIES = {
    characters = true,
    key_figures = true,
    locations = true,
}

-- AI combined-description merge only where `description` is the content field
local AI_MERGE_CATEGORIES = {
    characters = true,
    key_figures = true,
    locations = true,
}

-- English like every model-facing prompt. {title}/{author_clause} are the
-- standard safe placeholders; ALL artifact-derived text rides the sentinel.
XrayDedup.MERGE_PROMPT = [[A reading-companion X-Ray for "{title}"{author_clause} lists the same entity under two entries. Write ONE combined description that unifies the knowledge of both entries below, keeping the same language as the entries' own text.

@@KOA_MERGE_INPUTS@@

Rules:
- Combine complementary details; drop exact repetition
- Keep roughly the length of the longer of the two descriptions
- Output ONLY the combined description text — no preamble, no headings, no JSON, no quotation marks]]

--- Lowercase, trim, collapse inner whitespace. nil for empty/non-strings.
local function normalizeName(name)
    if type(name) ~= "string" then return nil end
    local n = name:lower()
    n = n:gsub("%s+", " ")
    n = n:match("^%s*(.-)%s*$")
    if n == "" then return nil end
    return n
end

--- Entity name for dedup purposes. Deliberately NOT XrayParser.getItemName:
--- its translated "Unknown" fallback would make every unnamed item an exact
--- duplicate of every other.
local function rawName(item)
    local name = item and (item.name or item.term)
    if type(name) ~= "string" or name == "" then return nil end
    return name
end

local function aliasArray(item)
    local aliases = item and item.aliases
    if type(aliases) == "string" then return { aliases } end
    if type(aliases) == "table" then return aliases end
    return {}
end

--- Unordered, case-insensitive pair identity (never-merge list matching).
function XrayDedup.pairKey(name_a, name_b)
    local na = normalizeName(name_a) or ""
    local nb = normalizeName(name_b) or ""
    if na > nb then na, nb = nb, na end
    return na .. "\n" .. nb
end

--- Normalized search-term set for one item: name + aliases ≥3 chars (the
--- countItemOccurrences noise threshold).
local function termSet(item, norm_name)
    local set = {}
    if norm_name then set[norm_name] = true end
    for _idx, alias in ipairs(aliasArray(item)) do
        local a = normalizeName(alias)
        if a and #a > 2 then set[a] = true end
    end
    return set
end

local function tokenize(norm_name)
    local toks = {}
    for raw_tok in norm_name:gmatch("%S+") do
        local tok = raw_tok:gsub("^%p+", ""):gsub("%p+$", "")
        if tok ~= "" then toks[#toks + 1] = tok end
    end
    return toks
end

--- Contained-name heuristic: the shorter name's token sequence is a strict
--- prefix or suffix of the longer's ("Jack" / "Jack Torrance", "The Overlook"
--- / "The Overlook Hotel"). Equal token counts never match (too noisy).
local function containedName(norm_a, norm_b)
    local ta, tb = tokenize(norm_a), tokenize(norm_b)
    if #ta == 0 or #tb == 0 or #ta == #tb then return false end
    local short, long = ta, tb
    if #short > #long then short, long = long, short end
    local short_len = 0
    for _idx, tok in ipairs(short) do short_len = short_len + #tok end
    if short_len < 3 then return false end
    local prefix = true
    for i = 1, #short do
        if short[i] ~= long[i] then
            prefix = false
            break
        end
    end
    if prefix then return true end
    local offset = #long - #short
    for i = 1, #short do
        if short[i] ~= long[offset + i] then return false end
    end
    return true
end

--- Scan parsed X-Ray data for likely duplicate pairs (same category only).
--- Reasons: "exact" (same normalized name), "alias" (name/alias term overlap),
--- "name" (contained name, proper-noun categories only). Pairs on the
--- never-merge list are skipped. Pure.
--- @param data table Parsed X-Ray data (user aliases already merged in for
---   full alias visibility)
--- @param never_pairs table|nil ActionCache.getNeverMergePairs output
--- @return table pairs Array of { cat_key, cat_label, name_a, name_b,
---   item_a, item_b, reason }
--- @return boolean truncated True when more than MAX_PAIRS were found
function XrayDedup.findDuplicates(data, never_pairs)
    local XrayParser = require("koassistant_xray_parser")
    local never = {}
    for _idx, pair in ipairs(never_pairs or {}) do
        never[XrayDedup.pairKey(pair[1], pair[2])] = true
    end
    local results = {}
    local truncated = false
    for _idx, cat in ipairs(XrayParser.getCategories(data or {})) do
        if not SCAN_EXCLUDED[cat.key] and type(cat.items) == "table" and #cat.items > 1 then
            local infos = {}
            for i, item in ipairs(cat.items) do
                local raw = rawName(item)
                local norm = normalizeName(raw)
                if norm then
                    infos[i] = { item = item, name = raw, norm = norm, terms = termSet(item, norm) }
                else
                    infos[i] = false
                end
            end
            for i = 1, #cat.items - 1 do
                local a = infos[i]
                if a then
                    for j = i + 1, #cat.items do
                        local b = infos[j]
                        if b then
                            local reason
                            if a.norm == b.norm then
                                reason = "exact"
                            else
                                for term in pairs(a.terms) do
                                    if b.terms[term] then
                                        reason = "alias"
                                        break
                                    end
                                end
                                if not reason and NAME_CONTAIN_CATEGORIES[cat.key]
                                    and containedName(a.norm, b.norm) then
                                    reason = "name"
                                end
                            end
                            if reason and not never[XrayDedup.pairKey(a.name, b.name)] then
                                if #results >= XrayDedup.MAX_PAIRS then
                                    truncated = true
                                else
                                    results[#results + 1] = {
                                        cat_key = cat.key,
                                        cat_label = cat.label,
                                        name_a = a.name,
                                        name_b = b.name,
                                        item_a = a.item,
                                        item_b = b.item,
                                        -- positional identity: with repeated
                                        -- names, a name-only lookup could act
                                        -- on entries the reader never saw
                                        idx_a = i,
                                        idx_b = j,
                                        reason = reason,
                                    }
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return results, truncated
end

--- Resolve one entity by position (verified against the expected name) with
--- a name-scan fallback ONLY when the name is unambiguous in the category —
--- with repeated names, first-match-wins would act on entries the reader
--- never saw (gate finding, 2026-07-26).
local function findByIndexOrName(items, idx, norm)
    if idx and items[idx] and normalizeName(rawName(items[idx])) == norm then
        return items[idx], idx
    end
    local found_item, found_idx, count = nil, nil, 0
    for i, item in ipairs(items) do
        if normalizeName(rawName(item)) == norm then
            count = count + 1
            if not found_item then found_item, found_idx = item, i end
        end
    end
    if count == 1 then return found_item, found_idx end
    return nil, nil
end

--- Apply one entity merge to parsed X-Ray data (mutates in place): the kept
--- entry absorbs the dropped entry's name + aliases (baked into the stored
--- artifact so update-prompt entity indexes steer the model to the kept
--- entry), the dropped entry is removed. Positional identity (keep_idx /
--- drop_idx from the scan) disambiguates repeated names; when the disk
--- changed underneath AND the name is ambiguous, the merge refuses. Pure.
--- @param merged_description string|nil AI-combined description (nil keeps
---   the kept entry's own)
--- @param keep_idx number|nil Scan-time index of the kept entry
--- @param drop_idx_hint number|nil Scan-time index of the dropped entry
--- @return boolean changed
--- @return table|nil dropped_item The removed entry (for the sidecar absorb)
function XrayDedup.applyMergeToData(data, cat_key, keep_name, drop_name, merged_description, keep_idx, drop_idx_hint)
    local XrayParser = require("koassistant_xray_parser")
    local keep_norm = normalizeName(keep_name)
    local drop_norm = normalizeName(drop_name)
    if not keep_norm or not drop_norm then return false, nil end
    for _idx, cat in ipairs(XrayParser.getCategories(data or {})) do
        if cat.key == cat_key and type(cat.items) == "table" then
            local keep_item = findByIndexOrName(cat.items, keep_idx, keep_norm)
            local drop_item, drop_idx = findByIndexOrName(cat.items, drop_idx_hint, drop_norm)
            if not keep_item or not drop_idx or keep_item == drop_item then
                return false, nil
            end
            local existing = {}
            local seen = { [keep_norm] = true }
            for _idx2, alias in ipairs(aliasArray(keep_item)) do
                local n = normalizeName(alias)
                if n and not seen[n] then
                    existing[#existing + 1] = alias
                    seen[n] = true
                end
            end
            local function addAlias(alias)
                local n = normalizeName(alias)
                if n and not seen[n] then
                    existing[#existing + 1] = alias
                    seen[n] = true
                end
            end
            addAlias(drop_name)
            for _idx2, alias in ipairs(aliasArray(drop_item)) do
                addAlias(alias)
            end
            keep_item.aliases = existing
            if type(merged_description) == "string" and merged_description ~= "" then
                keep_item.description = merged_description
            end
            table.remove(cat.items, drop_idx)
            return true, drop_item
        end
    end
    return false, nil
end

--- Absorb the dropped entity into the kept one's user-aliases sidecar entry
--- (mutates user_aliases in place; caller saves): dropped name + its AI
--- aliases (so the absorb survives a from-scratch regeneration, where the
--- baked artifact aliases are rebuilt without them) + its own user-added
--- terms. Terms the reader explicitly ignored on the kept entry stay ignored.
--- @param user_aliases table ActionCache.getUserAliases output (normalized)
--- @return table user_aliases
function XrayDedup.absorbAliases(user_aliases, keep_name, drop_name, drop_item)
    local entry = user_aliases[keep_name] or {}
    entry.add = entry.add or {}
    entry.ignore = entry.ignore or {}
    local keep_norm = normalizeName(keep_name)
    local seen = {}
    if keep_norm then seen[keep_norm] = true end
    for _idx, alias in ipairs(entry.add) do
        local n = normalizeName(alias)
        if n then seen[n] = true end
    end
    for _idx, alias in ipairs(entry.ignore) do
        local n = normalizeName(alias)
        if n then seen[n] = true end
    end
    local function add(alias)
        local n = normalizeName(alias)
        if n and not seen[n] then
            entry.add[#entry.add + 1] = alias
            seen[n] = true
        end
    end
    add(drop_name)
    for _idx, alias in ipairs(aliasArray(drop_item)) do
        add(alias)
    end
    -- Fold the dropped entity's own user record across, then retire it — an
    -- orphaned record would re-pair the two names as "shared alias" forever
    -- once a regeneration recreates the dropped entity (gate finding)
    local drop_entry = user_aliases[drop_name]
    if drop_entry ~= entry and type(drop_entry) == "table" then
        for _idx, alias in ipairs(type(drop_entry.add) == "table" and drop_entry.add or {}) do
            add(alias)
        end
        -- Terms the reader rejected on the dropped entity stay rejected on
        -- the kept one — unless they're deliberately among its add terms
        for _idx, alias in ipairs(type(drop_entry.ignore) == "table" and drop_entry.ignore or {}) do
            local n = normalizeName(alias)
            if n then
                local in_add, in_ignore = false, false
                for _idx2, a in ipairs(entry.add) do
                    if normalizeName(a) == n then in_add = true break end
                end
                for _idx2, a in ipairs(entry.ignore) do
                    if normalizeName(a) == n then in_ignore = true break end
                end
                if not in_add and not in_ignore then
                    entry.ignore[#entry.ignore + 1] = alias
                end
            end
        end
        user_aliases[drop_name] = nil
    end
    user_aliases[keep_name] = entry
    return user_aliases
end

--- AI-merge prompt + sentinel payload for one pair. The kept entry leads the
--- block; names/roles/descriptions all ride the payload. Side-based ("a"|"b")
--- so equal-name exact pairs stay unambiguous. Pure.
--- @param keep_side string "a" or "b" — which pair member is kept
--- @return string prompt, table payload (XrayMerge.injectPayload shape)
function XrayDedup.buildAiMergePrompt(pair, keep_side)
    local keep_item, keep_label, drop_item, drop_label
    if keep_side == "b" then
        keep_item, keep_label = pair.item_b, pair.name_b
        drop_item, drop_label = pair.item_a, pair.name_a
    else
        keep_item, keep_label = pair.item_a, pair.name_a
        drop_item, drop_label = pair.item_b, pair.name_b
    end
    local function block(label, item, heading)
        local role = type(item.role) == "string" and item.role ~= ""
            and (" (" .. item.role .. ")") or ""
        return heading .. ' — "' .. label .. '"' .. role .. ":\n"
            .. (type(item.description) == "string" and item.description or "")
    end
    local inputs = block(keep_label, keep_item, "Entry to KEEP")
        .. "\n\n"
        .. block(drop_label, drop_item, "Entry being merged into it")
    return XrayDedup.MERGE_PROMPT, { inputs = inputs }
end

--- Trim + unwrap a model reply into a usable description; nil when the shape
--- is unusable (empty, or JSON despite instructions). Pure.
function XrayDedup.cleanDescription(text)
    if type(text) ~= "string" then return nil end
    local t = text:match("^%s*(.-)%s*$") or ""
    local unquoted = t:match('^"(.*)"$')
    if unquoted then t = unquoted end
    if t == "" or t:sub(1, 1) == "{" or t:sub(1, 1) == "[" then return nil end
    return t
end

-- ============================ execution ============================

--- One entity merge against DISK truth: fresh parse → applyMergeToData
--- (positional identity) → re-encode → commitXray (ring-archives the
--- pre-dedup version once per session — per-pair archiving would flood the
--- ring) → sidecar absorb (only AFTER a successful write: an absorbed-but-
--- unwritten state would re-pair the entries as "shared alias").
--- @param state table { archived } session flag (mutated)
--- @param keep_side string "a" or "b" — which pair member is kept
--- @return boolean ok, string|nil err
local function commitEntityMerge(opts, state, pair, keep_side, merged_description)
    local ActionCache = require("koassistant_action_cache")
    local WriteBack = require("koassistant_artifact_writeback")
    local XrayParser = require("koassistant_xray_parser")

    local keep_name = keep_side == "b" and pair.name_b or pair.name_a
    local drop_name = keep_side == "b" and pair.name_a or pair.name_b
    local keep_idx = keep_side == "b" and pair.idx_b or pair.idx_a
    local drop_idx = keep_side == "b" and pair.idx_a or pair.idx_b

    local entry = ActionCache.getXrayCache(opts.file)
    if not entry or not entry.result then
        return false, _("No main X-Ray found on disk.")
    end
    local data = XrayParser.parse(entry.result)
    if not data or data.error then
        return false, _("The stored X-Ray could not be parsed.")
    end
    local changed, dropped_item = XrayDedup.applyMergeToData(
        data, pair.cat_key, keep_name, drop_name, merged_description, keep_idx, drop_idx)
    if not changed then
        return false, _("These entries changed on disk — reopen the duplicate scan.")
    end

    local json = require("json")
    local okj, cache_json = pcall(json.encode, data, { pretty = true, indent = true })
    if not okj or type(cache_json) ~= "string" then
        return false, _("Failed to serialize the updated X-Ray.")
    end

    -- Carry the entry's own metadata through unchanged (coverage and
    -- permission flags are untouched by a dedup); the fresh timestamp marks
    -- the modification — and honestly breaks ladder-rung identity if the live
    -- main was a promoted rung (it is now a reader-modified variant)
    local meta = {}
    for k, v in pairs(entry) do meta[k] = v end
    meta.result = nil
    meta.timestamp = nil
    meta.progress_decimal = nil

    local plugin_ref = opts.plugin
    local file = opts.file
    local ok = WriteBack.commitXray(opts.file, cache_json, entry.progress_decimal or 0, meta, {
        prev = entry,  -- already read fresh above — skips a full cache reload
        limit = state.archived and 0 or nil,
        features = (opts.configuration and opts.configuration.features) or {},
        refresh_fn = function()
            if plugin_ref then
                plugin_ref._file_dialog_row_cache = { file = nil, rows = nil }
                if plugin_ref._refreshXrayAutoState and plugin_ref.ui
                    and plugin_ref.ui.document and plugin_ref.ui.document.file == file then
                    plugin_ref:_refreshXrayAutoState()
                end
            end
        end,
    })
    if not ok then
        return false, _("Cache write failed.")
    end
    state.archived = true

    -- Exact-duplicate merges (equal names) have nothing to absorb — writing
    -- the duplicate's AI aliases to the sidecar would just pollute it
    if normalizeName(keep_name) ~= normalizeName(drop_name) then
        local user_aliases = ActionCache.getUserAliases(opts.file)
        XrayDedup.absorbAliases(user_aliases, keep_name, drop_name, dropped_item)
        ActionCache.setUserAliases(opts.file, user_aliases)
    end

    logger.info("KOAssistant XrayDedup: merged", drop_name, "into", keep_name, "for", file)
    return true, nil
end

--- Headless AI merge request (combined description), then the same commit.
--- on_finished(ok) — callers reopen the pair list only on success (a reopened
--- dialog would paint over the failure message).
local function runAiMerge(opts, state, pair, keep_side, on_finished)
    local Dialogs = require("koassistant_dialogs")
    local XrayMerge = require("koassistant_xray_merge")
    local InfoMessage = require("ui/widget/infomessage")
    local Notification = require("ui/widget/notification")

    local keep_name = keep_side == "b" and pair.name_b or pair.name_a
    local drop_name = keep_side == "b" and pair.name_a or pair.name_b

    -- Per-request settings refresh (XrayMerge.execute parity — the flow-open
    -- refresh can be several merges old by now)
    if opts.plugin and opts.plugin.updateConfigFromSettings then
        opts.plugin:updateConfigFromSettings()
    end

    local prompt_text, payload = XrayDedup.buildAiMergePrompt(pair, keep_side)
    -- Synthetic internal action: no extraction, no web, no chat storage, no
    -- response-side caching (the write below is owned by commitEntityMerge)
    local action = {
        id = "xray_dedup_merge",
        text = _("Merge X-Ray entities"),
        context = "book",
        prompt = prompt_text,
        storage_key = "__SKIP__",
        enable_web_search = false,
        reasoning_config = "off",  -- a two-description rewrite needs no reasoning
        api_params = XrayDedup.API_PARAMS,
        builtin = true,
    }
    local config, bm = XrayMerge.buildHeadlessConfig(opts, payload)
    UIManager:show(Notification:new{ text = _("Merging entries…"), timeout = 2 })
    Dialogs.executeActionForResult(action, "", opts.ui, config, opts.plugin, bm,
        function(result, meta_or_err)
            if not result then
                UIManager:show(InfoMessage:new{
                    text = T(_("AI merge failed: %1"), tostring(meta_or_err or "no response")),
                    timeout = 4,
                })
                on_finished(false)
                return
            end
            local desc = XrayDedup.cleanDescription(result)
            if not desc then
                UIManager:show(InfoMessage:new{
                    text = _("AI merge failed: the model did not return a plain description."),
                    timeout = 4,
                })
                on_finished(false)
                return
            end
            local ok, err = commitEntityMerge(opts, state, pair, keep_side, desc)
            if ok then
                UIManager:show(Notification:new{
                    text = T(_("Merged \"%1\" into \"%2\""), drop_name, keep_name),
                })
            else
                UIManager:show(InfoMessage:new{ text = err, timeout = 4 })
            end
            on_finished(ok)
        end)
end

-- ============================ UI flow ============================

local function reasonLabel(reason)
    if reason == "exact" then return _("same name") end
    if reason == "alias" then return _("shared alias") end
    return _("contained name")
end

--- Byte-safe snippet for pair previews (whitespace-collapsed, UTF-8 boundary
--- respected on the cut).
local function snippet(item)
    local d = type(item.description) == "string" and item.description or ""
    d = d:gsub("%s+", " ")
    if #d > 120 then
        d = d:sub(1, 117)
        -- back off a partial UTF-8 sequence at the cut
        while #d > 0 and d:byte(#d) >= 0x80 and d:byte(#d) < 0xC0 do
            d = d:sub(1, #d - 1)
        end
        if #d > 0 and d:byte(#d) >= 0xC0 then d = d:sub(1, #d - 1) end
        d = d .. "…"
    end
    return d
end

--- Entry point: scan → pair list → per-pair Merge / AI merge / Never.
--- Operates on DISK truth (the caller closes any browser view first — a merge
--- rewrites the data such a view renders).
--- @param opts table { file (required), ui, plugin, configuration (required),
---   title, author }
function XrayDedup.startFlow(opts)
    local ActionCache = require("koassistant_action_cache")
    local XrayParser = require("koassistant_xray_parser")
    local InfoMessage = require("ui/widget/infomessage")
    local Notification = require("ui/widget/notification")
    local ButtonDialog = require("ui/widget/buttondialog")

    -- Cross-instance staleness: the AI-merge consent gate must see CURRENT
    -- settings (revoking text extraction in the other instance must bite here)
    if opts.plugin and opts.plugin.updateConfigFromSettings then
        opts.plugin:updateConfigFromSettings()
    end

    local state = { archived = false }

    local function scan()
        local entry = ActionCache.getXrayCache(opts.file)
        if not entry or not entry.result then
            return { err = _("No main X-Ray found for this book.") }
        end
        local data = XrayParser.parse(entry.result)
        if not data or data.error then
            return { err = _("The main X-Ray is not in structured form — the duplicate scan needs a JSON X-Ray.") }
        end
        -- One sidecar read serves both the alias merge and the never list
        local user_aliases = ActionCache.getUserAliases(opts.file)
        if next(user_aliases) then
            XrayParser.mergeUserAliases(data, user_aliases)
        end
        local never = ActionCache.neverMergePairsFrom(user_aliases)
        local found, truncated = XrayDedup.findDuplicates(data, never)
        return { found = found, truncated = truncated, never = never }
    end

    local showList, showPairOptions, showNeverList  -- forward decls (mutually recursive)

    showPairOptions = function(pair)
        local XrayMerge = require("koassistant_xray_merge")
        local dialog
        local rows = {}
        -- Failure paths show the error WITHOUT reopening the list — a
        -- reopened dialog would paint over the message (gate finding)
        local function afterCommit(ok, err, success_text)
            if ok then
                UIManager:show(Notification:new{ text = success_text })
                showList(true)
            else
                UIManager:show(InfoMessage:new{ text = err, timeout = 4 })
            end
        end
        local function mergeRow(keep_side)
            local keep_name = keep_side == "b" and pair.name_b or pair.name_a
            local drop_name = keep_side == "b" and pair.name_a or pair.name_b
            return {{
                text = T(_("Merge — keep \"%1\""), keep_name),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    local ok, err = commitEntityMerge(opts, state, pair, keep_side, nil)
                    afterCommit(ok, err, T(_("Merged \"%1\" into \"%2\""), drop_name, keep_name))
                end,
            }}
        end
        if pair.reason == "exact" then
            -- Identical names: two "keep X" rows would be indistinguishable —
            -- one row, keep-first (side "a" = the earlier entry)
            rows[#rows + 1] = {{
                text = _("Merge duplicates (keep the first entry)"),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    local ok, err = commitEntityMerge(opts, state, pair, "a", nil)
                    afterCommit(ok, err, T(_("Merged duplicate \"%1\""), pair.name_a))
                end,
            }}
        else
            rows[#rows + 1] = mergeRow("a")
            rows[#rows + 1] = mergeRow("b")
        end
        if AI_MERGE_CATEGORIES[pair.cat_key] then
            rows[#rows + 1] = {{
                text = T(_("AI merge — combined description, keep \"%1\""), pair.name_a),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    -- Read-gate parity with the section merge: re-sending
                    -- text-derived artifact content needs extraction consent —
                    -- checked against CURRENT settings (the flow-open refresh
                    -- can be several merges old by now)
                    if opts.plugin and opts.plugin.updateConfigFromSettings then
                        opts.plugin:updateConfigFromSettings()
                    end
                    local features = (opts.configuration and opts.configuration.features) or {}
                    local provider = opts.configuration
                        and (opts.configuration.provider or opts.configuration.default_provider)
                    local entry = ActionCache.getXrayCache(opts.file)
                    if not XrayMerge.consentOk({ entry or {} }, features, provider) then
                        UIManager:show(InfoMessage:new{
                            text = _("This X-Ray was built from extracted book text. Enable \"Allow book text extraction\" (or use a trusted provider) for AI merge."),
                            timeout = 5,
                        })
                        return
                    end
                    runAiMerge(opts, state, pair, "a", function(ok)
                        if ok then showList(true) end
                    end)
                end,
            }}
        end
        rows[#rows + 1] = {{
            text = _("Never suggest this pair"),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                -- Confirmed: the pair persists across regenerations and also
                -- steers the section-merge prompts
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = T(_("Never suggest merging \"%1\" and \"%2\"?\n\nThis is remembered for this book (you can undo it under \"Never-merge pairs\" in the duplicates list)."),
                        pair.name_a, pair.name_b),
                    ok_text = _("Never merge"),
                    ok_callback = function()
                        ActionCache.addNeverMergePair(opts.file, pair.name_a, pair.name_b)
                        UIManager:show(Notification:new{
                            text = T(_("\"%1\" and \"%2\" will stay separate"), pair.name_a, pair.name_b),
                        })
                        showList(true)
                    end,
                    cancel_callback = function()
                        showPairOptions(pair)
                    end,
                })
            end,
        }}
        rows[#rows + 1] = {{
            text = _("Back"),
            callback = function()
                UIManager:close(dialog)
                showList(false)
            end,
        }}
        dialog = ButtonDialog:new{
            title = T(_("%1 — %2"), pair.cat_label, reasonLabel(pair.reason)) .. "\n\n"
                .. pair.name_a .. ": " .. snippet(pair.item_a) .. "\n\n"
                .. pair.name_b .. ": " .. snippet(pair.item_b),
            buttons = rows,
        }
        UIManager:show(dialog)
    end

    -- Stored never-merge pairs: view + undo (a "Never" tap must not be
    -- permanent-with-no-recourse — gate finding)
    showNeverList = function(never)
        local dialog
        local rows = {}
        for _idx, pair in ipairs(never) do
            local captured = pair
            rows[#rows + 1] = {{
                text = T(_("%1 ↔ %2"), captured[1], captured[2]),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    local ConfirmBox = require("ui/widget/confirmbox")
                    UIManager:show(ConfirmBox:new{
                        text = T(_("Allow suggesting \"%1\" and \"%2\" as duplicates again?"),
                            captured[1], captured[2]),
                        ok_text = _("Allow again"),
                        ok_callback = function()
                            ActionCache.removeNeverMergePair(opts.file, captured[1], captured[2])
                            showList(false)
                        end,
                        cancel_callback = function()
                            showList(false)
                        end,
                    })
                end,
            }}
        end
        rows[#rows + 1] = {{
            text = _("Back"),
            callback = function()
                UIManager:close(dialog)
                showList(false)
            end,
        }}
        dialog = ButtonDialog:new{
            title = _("Never-merge pairs — tap one to allow it again"),
            buttons = rows,
        }
        UIManager:show(dialog)
    end

    showList = function(after_change)
        local res = scan()
        if res.err then
            UIManager:show(InfoMessage:new{ text = res.err, timeout = 4 })
            return
        end
        local found = res.found
        if #found == 0 and #res.never == 0 then
            UIManager:show(InfoMessage:new{
                text = after_change and _("No more likely duplicates.")
                    or _("No likely duplicates found."),
                timeout = 3,
            })
            return
        end
        local dialog
        local rows = {}
        for _idx, pair in ipairs(found) do
            local captured = pair
            rows[#rows + 1] = {{
                text = T(_("%1 ↔ %2 (%3)"), captured.name_a, captured.name_b,
                    reasonLabel(captured.reason)),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    showPairOptions(captured)
                end,
            }}
        end
        if #found == 0 then
            rows[#rows + 1] = {{
                text = after_change and _("No more likely duplicates.")
                    or _("No likely duplicates found."),
                enabled = false,
            }}
        end
        if res.truncated then
            rows[#rows + 1] = {{
                text = T(_("Showing the first %1 — resolve some to see more"), XrayDedup.MAX_PAIRS),
                enabled = false,
            }}
        end
        if #res.never > 0 then
            rows[#rows + 1] = {{
                text = T(_("Never-merge pairs (%1)…"), #res.never),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    showNeverList(res.never)
                end,
            }}
        end
        rows[#rows + 1] = {{
            text = _("Close"),
            callback = function() UIManager:close(dialog) end,
        }}
        dialog = ButtonDialog:new{
            title = T(_("Possible duplicate entities (%1)"), #found),
            buttons = rows,
        }
        UIManager:show(dialog)
    end

    showList(false)
    logger.info("KOAssistant XrayDedup: scan started for", opts.file)
end

return XrayDedup
