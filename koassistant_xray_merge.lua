--[[--
X-Ray merge engine v1 (xray_ecosystem_plan.md §6 slice 3, ref #90).

Merges section X-Rays into the main X-Ray or into a combined (coarser-span)
section artifact. AI merge is THE mechanism — independently-generated section
X-Rays describe recurring entities with section-local knowledge only, so a
programmatic name-match merge would be lossy last-writer-wins (§5 design
substance); XrayParser.merge is only safe on model-authored deltas, which is
exactly what the into-main prompt asks for.

WIRE-SAFETY INVARIANT (gate finding, 2026-07-26): artifact JSON must NEVER ride
action.prompt — the early placeholder passes strip lines ("In context…"/{context})
and substitute placeholder literals INSIDE it — and must not ride the late
{cached_result}-style channels either (the identity and cache-section passes
rescan content injected there). The payloads travel through
config.features._merge_payload → message_data → injectPayload, which splices
them over brace-free @@KOA_MERGE_*@@ sentinel tokens AFTER MessageBuilder.build
has finished (single left-to-right scan; nothing runs afterward).

Three shapes, two write paths:
- sections → EXISTING JSON main (DELTA): update-prompt shape → applyXray with
  base (delta merge, sticky flags, coverage floor, archive, both keys).
- sections → NEW/LEGACY main (REPLACE): one-shot complete merge → applyXray
  complete mode; the old main (if any) is ring-archived; metadata comes from
  the inputs alone (the old main's content is NOT in the result). Requires a
  computable coverage ratio (book open) — a replace must never write a
  guessed claim.
- sections → COMBINED SECTION ("Part I" from chapters, ≥2 inputs): one-shot →
  section entry with the union scope (sanitized key + overwrite confirm, like
  the manual section writer; sections have no ring).

Inputs are KEPT. Coverage gaps WARN, never block; material beyond the reader/
main coverage also warns. The series axis reuses this input shape later
(coverage-tagged artifact list — §5 decision 9 seams).
]]

-- Widget requires stay lazy (inside the UI functions): the pure halves of this
-- module (prompt builders, unions, scope, consent gate) are unit-tested under
-- mock_koreader, which does not stub the dialog widgets.
local UIManager = require("ui/uimanager")
local logger = require("logger")
local T = require("ffi/util").template
local _ = require("koassistant_gettext")

local XrayMerge = {}

-- Mirrors the xray action's sampling shape (prompts/actions.lua): structural
-- JSON work, large possible output.
XrayMerge.API_PARAMS = { temperature = 0.5, max_tokens = 65536 }

-- English like every model-facing prompt (never translated). {title} and
-- {author_clause} are standard message_builder placeholders (small, safe).
-- The @@KOA_MERGE_*@@ SENTINELS are brace-free tokens replaced by
-- injectPayload AFTER MessageBuilder.build has finished — the artifact JSON
-- never passes through any placeholder machinery (wire-safety invariant).
-- %COUNT% / %COVERAGE% are module-filled plain text.
XrayMerge.COMPLETE_PROMPT = [[Merge these %COUNT% section X-Rays of "{title}"{author_clause} into ONE combined X-Ray.

Each section below is a complete X-Ray of one part of the book, listed in reading order. The same character, location, or concept may appear in several sections, each described with only that section's knowledge — your job is to combine those into single, unified entries.

@@KOA_MERGE_INPUTS@@

Output ONE complete merged JSON object using exactly the same JSON keys and structure as the sections. Rules:
- Every entity that appears in ANY section appears exactly ONCE in the output
- When sections describe the same entity, write ONE description that combines their knowledge in reading order; union their aliases and connections
- timeline / argument_development: concatenate entries in section order (do not deduplicate events)
- current_state / current_position: take it from the LAST section only
- Do not invent entities or events that appear in no section

@@KOA_MERGE_NEVER@@

CRITICAL: Output ONLY valid JSON — no other text. JSON keys must remain in English. Character names, location names, terms, and aliases must be in the same language and script as the source text. All other string values must be written in {response_language}, regardless of the language of the source text.]]

XrayMerge.DELTA_PROMPT = [[Update this X-Ray for "{title}"{author_clause} by folding in the %COUNT% section X-Rays below.

Previous analysis (covers up to %COVERAGE%):
@@KOA_MERGE_MAIN@@

@@KOA_MERGE_INDEX@@

Section X-Rays to fold in (each covers one part of the book, listed in reading order; their content may OVERLAP the previous analysis — fold in only what is new or richer):

@@KOA_MERGE_INPUTS@@

Output ONLY the new or changed entries as a JSON object. Use exactly the same JSON keys and structure as the previous analysis. Your output will be programmatically merged with the existing data, so:
- OMIT categories entirely if nothing changed in them — they will be preserved as-is
- When adding a new entry to a category, include ONLY the new entries in that category's array
- When a section reveals significant new information about an existing entity, output the COMPLETE updated entry with all fields (it will replace the old version)
- To reference an existing entity, use the EXACT name from the entity list above
- Include "current_state" (fiction) or "current_position" (nonfiction) ONLY if the sections extend past the previous analysis's coverage — otherwise omit it
- Do not invent entities or events that appear in no section

@@KOA_MERGE_NEVER@@

CRITICAL: Output ONLY valid JSON — no other text. JSON keys must remain in English. Character names, location names, terms, and aliases must be in the same language and script as the source text. All other string values must be written in {response_language}, regardless of the language of the source text.]]

--- Coverage-tagged inputs block (the shape the series merge reuses later:
--- swap section labels for book labels). Rides the {incremental_book_text}
--- late channel — never action.prompt. Pure.
--- @param sections table Array of { label, data = { result, scope_page_summary } }
--- @return string block
function XrayMerge.buildInputsBlock(sections)
    local parts = {}
    for i, sec in ipairs(sections) do
        local pages = sec.data and sec.data.scope_page_summary
        local coverage = pages and pages ~= "" and (" (" .. pages .. ")") or ""
        parts[#parts + 1] = string.format('Section %d — "%s"%s:\n%s',
            i, sec.label or "?", coverage, (sec.data and sec.data.result) or "")
    end
    return table.concat(parts, "\n\n")
end

--- Literal single-pass replace with advance (no Lua patterns; the search
--- position moves past each replacement so injected content is never
--- rescanned). Pure.
local function fillLiteral(text, marker, value)
    local out = text
    local from = 1
    while true do
        local s, e = out:find(marker, from, true)
        if not s then return out end
        out = out:sub(1, s - 1) .. value .. out:sub(e + 1)
        from = s + #value
    end
end

--- Coverage phrase for the delta prompt's %COVERAGE% slot. Pure.
function XrayMerge.coveragePhrase(main_entry)
    if main_entry.full_document then
        return "the entire book"
    end
    local p = tonumber(main_entry.progress_decimal)
    if p then
        return math.floor(p * 100 + 0.5) .. "% of the book"
    end
    return "an earlier reading position"
end

--- Never-merge pair lines for the @@KOA_MERGE_NEVER@@ payload slot. The NAMES
--- are artifact-derived content — they ride the sentinel payload, never the
--- prompt (wire-safety invariant applies to them like any artifact text). Pure.
--- @param never_pairs table|nil ActionCache.getNeverMergePairs output
--- @return string lines ("" when none)
function XrayMerge.neverLines(never_pairs)
    if not never_pairs or #never_pairs == 0 then return "" end
    local lines = {}
    for _idx, pair in ipairs(never_pairs) do
        lines[#lines + 1] = '- "' .. pair[1] .. '" and "' .. pair[2] .. '"'
    end
    return table.concat(lines, "\n")
end

--- One-shot complete merge prompt + its sentinel payload. Pure.
--- @param never_pairs table|nil Reader-confirmed distinct pairs (§6 slice 4)
--- @return string prompt, table payload (see injectPayload)
function XrayMerge.buildCompletePrompt(sections, never_pairs)
    return fillLiteral(XrayMerge.COMPLETE_PROMPT, "%COUNT%", tostring(#sections)), {
        inputs = XrayMerge.buildInputsBlock(sections),
        never = XrayMerge.neverLines(never_pairs),
    }
end

--- Delta merge prompt + payload (fold sections into an existing JSON main).
--- @param main_entry table Live main cache entry (JSON result)
--- @param entity_index string XrayParser.buildEntityIndex output (may be "")
--- @param never_pairs table|nil Reader-confirmed distinct pairs (§6 slice 4)
--- @return string prompt, table payload
function XrayMerge.buildDeltaPrompt(sections, main_entry, entity_index, never_pairs)
    local prompt = fillLiteral(XrayMerge.DELTA_PROMPT, "%COUNT%", tostring(#sections))
    prompt = fillLiteral(prompt, "%COVERAGE%", XrayMerge.coveragePhrase(main_entry))
    return prompt, {
        inputs = XrayMerge.buildInputsBlock(sections),
        main = main_entry.result or "",
        index = entity_index or "",
        never = XrayMerge.neverLines(never_pairs),
    }
end

--- Replace the sentinel tokens with the artifact JSON. Called from
--- handlePredefinedPrompt AFTER MessageBuilder.build has finished — every
--- placeholder pass has already run, so nothing can strip lines or substitute
--- placeholder literals inside the injected JSON. ONE left-to-right scan over
--- the ORIGINAL message with an output buffer: replacements are never
--- rescanned, by ANY token — sequential per-token passes would let a token
--- literal inside one payload be replaced by a later token's pass. Pure.
--- @param message string The built consolidated message
--- @param payload table { inputs, main, index, never } from the prompt builders
--- @return string message with payload injected
function XrayMerge.injectPayload(message, payload)
    if type(message) ~= "string" or type(payload) ~= "table" then return message end
    local index_block = ""
    if payload.index and payload.index ~= "" then
        -- Same framing as the incremental update path (message_builder.lua)
        index_block = "Existing entities in previous analysis:\n" .. payload.index
    end
    local never_block = ""
    if payload.never and payload.never ~= "" then
        never_block = "These are DIFFERENT entities (reader-confirmed) — never merge them into one entry:\n"
            .. payload.never
    end
    local values = {
        ["@@KOA_MERGE_INPUTS@@"] = payload.inputs or "",
        ["@@KOA_MERGE_MAIN@@"] = payload.main or "",
        ["@@KOA_MERGE_INDEX@@"] = index_block,
        ["@@KOA_MERGE_NEVER@@"] = never_block,
    }
    local out = {}
    local pos = 1
    while true do
        local best_s, best_e, best_v
        for token, value in pairs(values) do
            local s, e = message:find(token, pos, true)
            if s and (not best_s or s < best_s) then
                best_s, best_e, best_v = s, e, value
            end
        end
        if not best_s then
            out[#out + 1] = message:sub(pos)
            break
        end
        out[#out + 1] = message:sub(pos, best_s - 1)
        out[#out + 1] = best_v
        pos = best_e + 1
    end
    return table.concat(out)
end

--- Union permission metadata across the inputs (sticky-true: the merged
--- artifact contains every input's material). nil beats explicit false — the
--- read gates treat nil/legacy as "used" (conservative). Pure.
--- @param entries table Array of cache entries (section .data tables)
--- @return table { used_book_text, used_highlights }
function XrayMerge.unionInputMeta(entries)
    local function unionFlag(field)
        local saw_nil = false
        for _idx, e in ipairs(entries) do
            if e[field] == true then return true end
            if e[field] == nil then saw_nil = true end
        end
        if saw_nil then return nil end
        return false
    end
    return {
        used_book_text = unionFlag("used_book_text"),
        used_highlights = unionFlag("used_highlights"),
    }
end

--- Scope fields for a combined-section target: union range, composite label
--- (range-picker "A – B" precedent). Pure; sections assumed sorted by start.
--- @param sections table getSections-shaped array (sorted)
--- @return table scope { label, start_page, end_page, start_xpointer, end_xpointer, page_summary }
function XrayMerge.combinedScope(sections)
    local first = sections[1]
    local last = sections[#sections]
    local label
    if #sections == 1 or first.label == last.label then
        label = first.label
    else
        label = (first.label or "?") .. " – " .. (last.label or "?")
    end
    local start_page = first.data and first.data.scope_start_page
    local end_page = last.data and last.data.scope_end_page
    local page_summary
    if start_page and end_page then
        page_summary = T(_("pp %1–%2"), start_page, end_page)
    end
    return {
        label = label,
        start_page = start_page,
        end_page = end_page,
        start_xpointer = first.data and first.data.scope_start_xpointer,
        end_xpointer = last.data and last.data.scope_end_xpointer,
        page_summary = page_summary,
    }
end

--- Text-extraction read gate for the merge: the inputs are text-DERIVED
--- artifacts, and sending them must respect the same dynamic permission the
--- cache read gates enforce (revoked consent blocks injection — it must block
--- re-sending through a merge too). Trusted providers bypass, as everywhere.
--- The book's per-book privacy override (book_file, optional) wins in both
--- directions — deny beats trusted.
--- @return boolean allowed
function XrayMerge.consentOk(entries, features, provider, book_file, ui)
    local needs_text = false
    for _idx, e in ipairs(entries) do
        if e.used_book_text ~= false then
            needs_text = true
            break
        end
    end
    if not needs_text then return true end
    if book_file then
        local ok, ds = pcall(function()
            return require("koassistant_doc_settings").resolve(book_file, ui)
        end)
        if ok and ds then
            local ov = require("koassistant_book_settings").effectivePrivacyOverrides(ds).book_text
            if ov ~= nil then return ov end
        end
    end
    if features and features.enable_book_text_extraction == true then return true end
    for _idx, trusted_id in ipairs((features and features.trusted_providers) or {}) do
        if trusted_id == provider then return true end
    end
    return false
end

-- ============================ execution ============================

--- Config copy for a headless artifact request (never the shared module
--- table; the nested book_metadata gets a fresh copy too — CLAUDE.md Config
--- Copy Pattern), with the sentinel payload riding the consume-once
--- _merge_payload transient. Shared with the entity dedup flow (§6 slice 4).
--- Caller is responsible for updateConfigFromSettings beforehand.
--- @param opts table { configuration, file, title, author }
--- @param payload table injectPayload payload
--- @return table config, table bm (the fresh book_metadata)
function XrayMerge.buildHeadlessConfig(opts, payload)
    local config = {}
    for k, v in pairs(opts.configuration or {}) do config[k] = v end
    config.features = {}
    for k, v in pairs((opts.configuration or {}).features or {}) do config.features[k] = v end
    config.features.is_book_context = true
    config.features.is_general_context = nil
    config.features.is_library_context = nil
    local bm = {}
    for k, v in pairs(config.features.book_metadata or {}) do bm[k] = v end
    bm.file = opts.file
    bm.title = opts.title or bm.title
    bm.author = opts.author or bm.author or ""
    bm.author_clause = (bm.author ~= "" and (" by " .. bm.author)) or ""
    -- Stale DOI from another book would flip research mode on a structural merge
    bm.doi = nil
    bm.doi_clause = nil
    config.features.book_metadata = bm
    -- Wire-safety: the payloads ride the late sentinel injection, never action.prompt
    config.features._merge_payload = payload
    return config, bm
end

--- Run the merge headlessly and write the result.
--- @param opts table { file, ui, plugin, configuration, sections (getSections
---   rows, sorted), target = "main"|"section", main_entry, delta_mode,
---   coverage_ratio (flow-aware 0..1 or nil), title, author, on_done(ok, err) }
function XrayMerge.execute(opts)
    local Dialogs = require("koassistant_dialogs")
    local ActionCache = require("koassistant_action_cache")
    local WriteBack = require("koassistant_artifact_writeback")
    local XrayParser = require("koassistant_xray_parser")

    local into_main = opts.target == "main"
    local delta_mode = opts.delta_mode and into_main

    -- Reader-confirmed distinct pairs steer the model's entity merging (§6
    -- slice 4 — same list the duplicate scan consults)
    local never_pairs = ActionCache.getNeverMergePairs(opts.file)

    local prompt_text, payload
    if delta_mode then
        local parsed_main = XrayParser.parse(opts.main_entry.result)
        local entity_index = parsed_main and XrayParser.buildEntityIndex(parsed_main) or ""
        prompt_text, payload = XrayMerge.buildDeltaPrompt(opts.sections, opts.main_entry, entity_index, never_pairs)
    else
        prompt_text, payload = XrayMerge.buildCompletePrompt(opts.sections, never_pairs)
    end

    -- Synthetic internal action: no extraction, no web, no chat storage, no
    -- response-side caching (the write below is owned by the write-back seam)
    local action = {
        id = "xray_merge",
        text = _("Merge X-Ray"),
        context = "book",
        prompt = prompt_text,
        storage_key = "__SKIP__",
        enable_web_search = false,
        reasoning_config = "off",  -- xray-action parity (T2): structural JSON merge, no reasoning
        api_params = XrayMerge.API_PARAMS,
        builtin = true,
    }

    if opts.plugin and opts.plugin.updateConfigFromSettings then
        opts.plugin:updateConfigFromSettings()
    end
    local config, bm = XrayMerge.buildHeadlessConfig(opts, payload)

    local input_entries = {}
    for _idx, sec in ipairs(opts.sections) do input_entries[#input_entries + 1] = sec.data end

    local plugin_ref = opts.plugin
    local file = opts.file
    Dialogs.executeActionForResult(action, config.features.book_context or "", opts.ui, config,
        opts.plugin, bm,
        function(result, meta_or_err)
            if not result then
                if opts.on_done then opts.on_done(false, tostring(meta_or_err or "no response")) end
                return
            end
            -- model_info is unreliable on this seam (may be "" — pre-existing);
            -- nil lets reconciliation fall back to the base's model
            local model_name = type(meta_or_err) == "table"
                and meta_or_err.model ~= "" and meta_or_err.model or nil
            local used_reasoning = type(meta_or_err) == "table"
                and meta_or_err.used_reasoning or nil
            local union = XrayMerge.unionInputMeta(input_entries)
            -- Timeline slice 1: honest input coverage — the union of every
            -- input's spans, holes preserved (spaced-apart sections no longer
            -- overstate in metadata). The base's own spans union in via
            -- reconcileXrayMeta on the delta path.
            local input_spans
            for _idx, e in ipairs(input_entries) do
                input_spans = WriteBack.unionSpans(input_spans, WriteBack.spansFromEntry(e))
            end

            if into_main then
                local ok, res_or_err = WriteBack.applyXray({
                    document_path = file,
                    answer = result,
                    -- REPLACE mode (no/legacy main): metadata comes from the
                    -- inputs alone — the old main's content is not in the result,
                    -- so no flag inheritance and no coverage floor from it
                    base = delta_mode and opts.main_entry or nil,
                    base_entry = delta_mode and opts.main_entry or nil,
                    progress_decimal = opts.coverage_ratio or 0,
                    meta = {
                        model = model_name,
                        used_reasoning = used_reasoning,
                        used_book_text = union.used_book_text,
                        used_highlights = union.used_highlights,
                        merged_from_sections = #opts.sections,
                        coverage_spans = input_spans,
                        producer = "section_merge",
                    },
                    features = config.features,
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
                if ok then
                    -- Stamp the inputs as folded-in (T15): section list + merge
                    -- picker read this. A section regeneration clears it (fresh
                    -- set() carries no merged_to_main); a main redo merely makes
                    -- it historical (informational, timestamped).
                    local keys = {}
                    for _idx, sec in ipairs(opts.sections) do keys[#keys + 1] = sec.key end
                    ActionCache.markSectionsMerged(file, keys, os.time())
                end
                if opts.on_done then opts.on_done(ok, not ok and res_or_err or nil, opts.target) end
            else
                -- Combined-section target: validate, then write a section entry
                -- with the union scope (section conventions: progress 1.0 +
                -- full_document; sanitized key like the manual section writer;
                -- overwrite was confirmed in the flow)
                local parsed, err, cache_json = WriteBack.parseXrayAnswer(result)
                if not parsed then
                    if opts.on_done then opts.on_done(false, err or "parse failed") end
                    return
                end
                local scope = XrayMerge.combinedScope(opts.sections)
                -- Display label in VISIBLE pages when possible (manual-writer
                -- parity; scope_* fields stay raw for extraction math)
                local doc = opts.ui and opts.ui.document
                if doc and doc.file == file and scope.start_page and scope.end_page
                    and doc.hasHiddenFlows and doc:hasHiddenFlows() and doc.getPageNumberInFlow then
                    scope.page_summary = T(_("pp %1–%2"),
                        doc:getPageNumberInFlow(scope.start_page) or scope.start_page,
                        doc:getPageNumberInFlow(scope.end_page) or scope.end_page)
                end
                local ok = ActionCache.set(file, XrayMerge.sectionKeyFor(scope.label), cache_json, 1.0, {
                    model = model_name,
                    used_reasoning = used_reasoning,
                    used_book_text = union.used_book_text,
                    used_highlights = union.used_highlights,
                    full_document = true,
                    merged_from_sections = #opts.sections,
                    coverage_spans = input_spans,
                    producer = "section_merge",
                    scope_label = scope.label,
                    scope_start_page = scope.start_page,
                    scope_end_page = scope.end_page,
                    scope_start_xpointer = scope.start_xpointer,
                    scope_end_xpointer = scope.end_xpointer,
                    scope_page_summary = scope.page_summary,
                })
                if ok and plugin_ref then
                    plugin_ref._file_dialog_row_cache = { file = nil, rows = nil }
                end
                if opts.on_done then opts.on_done(ok == true, ok ~= true and "cache write failed" or nil, opts.target) end
            end
        end)
end

--- Cache key for a combined section — same sanitization as the manual section
--- writer (main.lua): colons conflict with the key separator, 80-char cap. Pure.
function XrayMerge.sectionKeyFor(label)
    local ActionCache = require("koassistant_action_cache")
    local cache_label = (label or "?"):gsub(":", "-")
    if #cache_label > 80 then cache_label = cache_label:sub(1, 80) end
    return ActionCache.SECTION_PREFIXES.xray .. cache_label
end

-- ============================ UI flow ============================

local function showWarningsThenRun(opts, warnings)
    if #warnings == 0 then
        XrayMerge.execute(opts)
        return
    end
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    dialog = ButtonDialog:new{
        title = table.concat(warnings, "\n\n"),
        buttons = {
            {{
                text = _("Merge anyway"),
                callback = function()
                    UIManager:close(dialog)
                    XrayMerge.execute(opts)
                end,
            }},
            {{
                text = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            }},
        },
    }
    UIManager:show(dialog)
end

--- Combined-section pre-check: overwrite confirm when the sanitized key
--- already exists (mirrors the manual section writer's replace confirm).
local function confirmSectionOverwriteThenRun(opts, warnings)
    local ActionCache = require("koassistant_action_cache")
    local ButtonDialog = require("ui/widget/buttondialog")
    local scope = XrayMerge.combinedScope(opts.sections)
    local existing = ActionCache.get(opts.file, XrayMerge.sectionKeyFor(scope.label))
    if not existing then
        showWarningsThenRun(opts, warnings)
        return
    end
    local dialog
    dialog = ButtonDialog:new{
        title = T(_("A Section X-Ray named '%1' already exists. Replace it?"), scope.label),
        buttons = {
            {{
                text = _("Replace"),
                callback = function()
                    UIManager:close(dialog)
                    showWarningsThenRun(opts, warnings)
                end,
            }},
            {{
                text = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            }},
        },
    }
    UIManager:show(dialog)
end

local function pickTargetThenRun(opts)
    local ButtonDialog = require("ui/widget/buttondialog")
    local WriteBack = require("koassistant_artifact_writeback")
    local XrayParser = require("koassistant_xray_parser")
    local sections = opts.sections

    local scoped = {}
    for _idx, sec in ipairs(sections) do
        scoped[#scoped + 1] = {
            label = sec.label,
            start_page = sec.data.scope_start_page,
            end_page = sec.data.scope_end_page,
        }
    end
    local coverage = WriteBack.coverageFromInputs(scoped)
    -- Flow-aware ratio (raw scope pages ÷ raw total misclaims on hidden-flow
    -- books — gate finding): page_ratio_fn maps a raw page to a visible-page
    -- ratio; nil when the book isn't open
    local coverage_ratio
    if opts.page_ratio_fn and coverage.end_page and coverage.end_page > 0 then
        coverage_ratio = opts.page_ratio_fn(coverage.end_page)
    end
    opts.coverage_ratio = coverage_ratio

    -- Full parse validation, not the shallow isJSON sniff: a prose main with an
    -- early brace must fall through to REPLACE, not select delta and fail after
    -- the API spend
    local delta_mode = false
    if opts.main_entry ~= nil then
        local parsed_main = XrayParser.parse(opts.main_entry.result or "")
        delta_mode = parsed_main ~= nil and not parsed_main.error
    end
    opts.delta_mode = delta_mode

    local function warningsFor(target)
        local warnings = {}
        for _idx, gap in ipairs(coverage.gaps) do
            warnings[#warnings + 1] = T(
                _("No section X-Ray covers pp %1–%2 (between \"%3\" and \"%4\"). The merged result will have a gap there."),
                gap.from_page, gap.to_page, gap.after_label or "?", gap.before_label or "?")
        end
        if target == "main" then
            -- Base-coverage gap (device round 1 T4): a delta merge whose first
            -- selected section starts past the main's covered range leaves a hole
            -- no input fills — the between-inputs loop above can't see it
            local base_page = delta_mode and not opts.main_entry.full_document
                and tonumber(opts.main_entry.progress_page) or nil
            local first_start = scoped[1] and tonumber(scoped[1].start_page)
            if base_page and first_start and first_start > base_page + 1 then
                warnings[#warnings + 1] = T(
                    _("The main X-Ray covers up to p. %1 and the first selected section starts at p. %2. The pages between are in neither."),
                    base_page, first_start)
            end
            -- Raising the main's claim / passing the reader = spoiler-relevant
            local main_p = delta_mode and tonumber(opts.main_entry.progress_decimal) or nil
            local reader_p = opts.reading_decimal
            if coverage_ratio and reader_p and coverage_ratio > reader_p + 0.01 then
                warnings[#warnings + 1] = T(
                    _("The selected sections cover text beyond your reading position (%1%). The merged X-Ray will contain later material."),
                    math.floor(reader_p * 100 + 0.5))
            elseif coverage_ratio and main_p and not opts.main_entry.full_document
                and coverage_ratio > main_p + 0.01 then
                warnings[#warnings + 1] = T(
                    _("The selected sections extend beyond the X-Ray's current coverage (%1%). Its coverage claim will rise to %2%."),
                    math.floor(main_p * 100 + 0.5), math.floor(coverage_ratio * 100 + 0.5))
            end
        end
        return warnings
    end

    local main_row_text
    if delta_mode then
        main_row_text = _("Merge into main X-Ray")
    elseif opts.main_entry and opts.main_entry.result then
        -- Legacy/non-JSON main: its content can't be merged — this is a replace
        main_row_text = _("Replace main X-Ray (old version is archived)")
    else
        main_row_text = _("Create main X-Ray from sections")
    end
    local scope_preview = XrayMerge.combinedScope(sections)

    -- Into-main coverage requirements:
    -- DELTA: the floor holds the main's claim, so a missing ratio is safe when
    -- the main already covers every selected section (or is complete-track).
    -- REPLACE/CREATE: the result's claim IS the ratio — never write a guess.
    local main_possible
    if delta_mode then
        main_possible = coverage_ratio ~= nil
            or opts.main_entry.full_document
            or (tonumber(opts.main_entry.progress_page)
                and (coverage.end_page or math.huge) <= tonumber(opts.main_entry.progress_page))
    else
        main_possible = coverage_ratio ~= nil
    end

    local dialog
    local rows = {}
    if main_possible then
        table.insert(rows, {{
            text = main_row_text,
            callback = function()
                UIManager:close(dialog)
                opts.target = "main"
                showWarningsThenRun(opts, warningsFor("main"))
            end,
        }})
    else
        table.insert(rows, {{
            text = T(_("%1 (open the book first)"), main_row_text),
            enabled = false,
        }})
    end
    if #sections >= 2 then
        table.insert(rows, {{
            text = T(_("Create combined section X-Ray (\"%1\")"), scope_preview.label or "?"),
            callback = function()
                UIManager:close(dialog)
                opts.target = "section"
                confirmSectionOverwriteThenRun(opts, warningsFor("section"))
            end,
        }})
    else
        table.insert(rows, {{
            text = _("Create combined section X-Ray: select at least two sections"),
            enabled = false,
        }})
    end
    table.insert(rows, {{
        text = _("Cancel"),
        callback = function() UIManager:close(dialog) end,
    }})
    dialog = ButtonDialog:new{
        title = T(_("Merge %1 section X-Rays into…"), #sections),
        buttons = rows,
    }
    UIManager:show(dialog)
end

--- Entry point: section multi-select → target → warnings → run.
--- @param opts table { file (required), ui, plugin, configuration (required),
---   title, author, on_done(ok, err) — optional override for the default
---   notification }
function XrayMerge.startFlow(opts)
    local ActionCache = require("koassistant_action_cache")
    local ButtonDialog = require("ui/widget/buttondialog")
    local InfoMessage = require("ui/widget/infomessage")
    local Notification = require("ui/widget/notification")
    local XrayParser = require("koassistant_xray_parser")

    -- Cross-instance staleness: the consent gate below must see CURRENT
    -- settings (revoking text extraction in the other instance must bite here)
    if opts.plugin and opts.plugin.updateConfigFromSettings then
        opts.plugin:updateConfigFromSettings()
    end

    -- Identity fallback from the open document (browser callers pass these in;
    -- the popup path may not)
    if (not opts.title or opts.title == "") and opts.ui and opts.ui.doc_props
        and opts.ui.document and opts.ui.document.file == opts.file then
        opts.title = opts.ui.doc_props.display_title or opts.ui.doc_props.title
        if not opts.author or opts.author == "" then
            local authors = opts.ui.doc_props.authors or ""
            if authors:find("\n") then authors = authors:gsub("\n", ", ") end
            opts.author = authors
        end
    end

    local all_sections = ActionCache.getSections(opts.file, ActionCache.SECTION_PREFIXES.xray)
    local sections = {}
    for _idx, sec in ipairs(all_sections) do
        if sec.data and sec.data.result and XrayParser.isJSON(sec.data.result) then
            sections[#sections + 1] = sec
        end
    end
    if #sections == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No section X-Rays to merge. Generate some first (X-Ray popup → Generate Section X-Ray)."),
            timeout = 3,
        })
        return
    end

    local main_entry = ActionCache.getXrayCache(opts.file)
    if main_entry and not main_entry.result then main_entry = nil end

    -- Read-gate parity: revoked text-extraction consent blocks re-sending
    -- text-derived artifacts (trusted provider bypasses, as everywhere)
    local features = (opts.configuration and opts.configuration.features) or {}
    local provider = (opts.configuration and (opts.configuration.provider or opts.configuration.default_provider))
    local gate_entries = {}
    for _idx, sec in ipairs(sections) do gate_entries[#gate_entries + 1] = sec.data end
    if main_entry then gate_entries[#gate_entries + 1] = main_entry end
    if not XrayMerge.consentOk(gate_entries, features, provider, opts.file, opts.ui) then
        UIManager:show(InfoMessage:new{
            text = _("These X-Rays were built from extracted book text. Enable \"Allow book text extraction\" (or use a trusted provider) to merge them."),
            timeout = 5,
        })
        return
    end

    -- Coverage context: a raw-page → flow-aware-ratio mapper (hidden-flow books
    -- would misclaim on raw ÷ raw-total math) + the reading position
    local page_ratio_fn, reading_decimal
    if opts.ui and opts.ui.document and opts.ui.document.file == opts.file then
        local doc = opts.ui.document
        local total = doc.info and doc.info.number_of_pages
        if total and total > 0 then
            local ContextExtractor = require("koassistant_context_extractor")
            local visible_total = ContextExtractor.getFlowFingerprint(doc)
            if visible_total and visible_total > 0 then
                page_ratio_fn = function(page)
                    local vp = doc.getPageNumberInFlow and doc:getPageNumberInFlow(page) or page
                    return math.min(1.0, vp / visible_total)
                end
            else
                page_ratio_fn = function(page)
                    return math.min(1.0, page / total)
                end
            end
            local okp, progress = pcall(function()
                return ContextExtractor:new(opts.ui):getReadingProgress()
            end)
            reading_decimal = okp and progress and tonumber(progress.decimal) or nil
        end
    end

    -- Multi-select, ●/○ toggle rows rebuilt on tap (chip-manager idiom).
    -- Pre-selected = sections NOT yet folded into the main (T15) — re-merging
    -- already-merged content just re-sends it; already-merged rows stay
    -- pickable and are labeled. (No merged sections at all → everything
    -- selected, the original common case.)
    local selected = {}
    for _idx, sec in ipairs(sections) do
        if not sec.data.merged_to_main then selected[sec.key] = true end
    end

    local current_picker
    local showPicker  -- forward decl (toggle rows close-and-rebuild)
    showPicker = function()
        if current_picker then
            UIManager:close(current_picker)
            current_picker = nil
        end
        local dialog  -- declared BEFORE the rows so their closures capture it
        local rows = {}
        local count = 0
        for _idx, sec in ipairs(sections) do
            if selected[sec.key] then count = count + 1 end
        end
        for _idx, sec in ipairs(sections) do
            local captured = sec
            local detail_parts = {}
            local pages = sec.data.scope_page_summary
            if pages and pages ~= "" then detail_parts[#detail_parts + 1] = pages end
            if sec.data.merged_to_main then detail_parts[#detail_parts + 1] = _("merged") end
            local detail = #detail_parts > 0
                and (" (" .. table.concat(detail_parts, ", ") .. ")") or ""
            table.insert(rows, {{
                text = (selected[captured.key] and "● " or "○ ") .. (captured.label or "?") .. detail,
                align = "left",
                callback = function()
                    selected[captured.key] = not selected[captured.key] or nil
                    showPicker()
                end,
            }})
        end
        table.insert(rows, {{
            text = T(_("Merge %1 selected…"), count),
            enabled = count >= 1,
            callback = function()
                UIManager:close(dialog)
                current_picker = nil
                local picked = {}
                for _idx, sec in ipairs(sections) do
                    if selected[sec.key] then picked[#picked + 1] = sec end
                end
                pickTargetThenRun({
                    file = opts.file,
                    ui = opts.ui,
                    plugin = opts.plugin,
                    configuration = opts.configuration,
                    sections = picked,
                    main_entry = main_entry,
                    page_ratio_fn = page_ratio_fn,
                    reading_decimal = reading_decimal,
                    title = opts.title,
                    author = opts.author,
                    on_done = opts.on_done or function(ok, err, target)
                        if not ok then
                            UIManager:show(InfoMessage:new{
                                text = T(_("X-Ray merge failed: %1"), tostring(err or "unknown error")),
                                timeout = 4,
                            })
                            return
                        end
                        if target ~= "main" or #picked == 0 then
                            UIManager:show(Notification:new{
                                text = T(_("X-Ray merge complete (%1 sections)"), #picked),
                            })
                            return
                        end
                        -- Into-main merges keep their inputs by design (merge is
                        -- additive) — but ask, so the section list doesn't read
                        -- as "the merge didn't take" (device rounds 1+2, T5)
                        local ActionCache2 = require("koassistant_action_cache")
                        local choice
                        choice = ButtonDialog:new{
                            title = T(_("Merged %1 section X-Rays into the main X-Ray."), #picked)
                                .. "\n" .. _("Keep them as separate section X-Rays too?"),
                            buttons = {
                                {{
                                    text = _("Keep sections"),
                                    callback = function() UIManager:close(choice) end,
                                }},
                                {{
                                    text = T(_("Delete the %1 merged sections"), #picked),
                                    callback = function()
                                        UIManager:close(choice)
                                        for _idx, sec in ipairs(picked) do
                                            ActionCache2.clear(opts.file, sec.key)
                                        end
                                        UIManager:show(Notification:new{
                                            text = T(_("Deleted %1 section X-Rays."), #picked),
                                        })
                                    end,
                                }},
                            },
                        }
                        UIManager:show(choice)
                    end,
                })
            end,
        }})
        table.insert(rows, {{
            text = _("Cancel"),
            callback = function()
                UIManager:close(dialog)
                current_picker = nil
            end,
        }})
        dialog = ButtonDialog:new{
            title = _("Merge section X-Rays: pick inputs"),
            buttons = rows,
        }
        current_picker = dialog
        UIManager:show(dialog)
    end
    -- Flow is really starting — retire the caller's browser only now, so the
    -- no-sections/consent-blocked early returns above leave it intact (T11)
    if opts.close_browser then opts.close_browser() end
    showPicker()
    logger.info("KOAssistant XrayMerge: flow started with", #sections, "sections for", opts.file)
end

return XrayMerge
