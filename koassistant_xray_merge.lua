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
- A modified entry REPLACES the old one — carry over its existing details (identifying facts, relationships, earlier developments) and add the new; anything you leave out is lost
- To reference an existing entity, use the EXACT name from the entity list above
- Names listed under "dormant" are carried from related books and have NOT appeared in this book yet — they are not existing entries. If an entity you are adding or updating is the same person, place, or thing as a dormant name, include that dormant name among its aliases.
- Include "current_state" (fiction) or "current_position" (nonfiction) ONLY if the sections extend past the previous analysis's coverage — otherwise omit it
- Do not invent entities or events that appear in no section

@@KOA_MERGE_NEVER@@

CRITICAL: Output ONLY valid JSON — no other text. JSON keys must remain in English. Character names, location names, terms, and aliases must be in the same language and script as the source text. All other string values must be written in {response_language}, regardless of the language of the source text.]]

-- Cross-book merge (items 43/44, #90): fold ANOTHER book's X-Ray into this
-- book's main as BACKGROUND. Recurring entities are NEVER rewritten by the
-- model (chained rewrites decay — the field report behind item 44): the model
-- emits background_updates pairs and crossBookTransform attaches them
-- mechanically, so the existing entry survives verbatim on every merge. Only
-- genuinely new carry-over entities arrive as full entries. This book's
-- timeline/current-state stay untouched (prompt + mechanical strip). Same
-- sentinel wire-safety as the section prompts.
XrayMerge.CROSS_BOOK_DELTA_PROMPT = [[Update this X-Ray for "{title}"{author_clause} by folding in the X-Ray of a related book below (for example an earlier book in the same series, or a companion work).

Previous analysis of "{title}" (covers up to %COVERAGE%):
@@KOA_MERGE_MAIN@@

@@KOA_MERGE_INDEX@@

X-Ray of the related book:

@@KOA_MERGE_INPUTS@@

Entity matching is the core of this task: the same person, place, or thing may appear under DIFFERENT names in the two X-Rays — a proper name in one; an epithet, role, or descriptive handle (like "the boy" or "the Keeper") in the other; spelling or translation drift. Before treating any related-book entity as new, check it against every existing entry's name, aliases, AND description. When two entries clearly describe the same person, place, or thing, treat them as the SAME entity and bridge the names through "aliases". When the evidence points that way but is not explicit, still prefer the alias bridge over creating a near-duplicate entry.

Output ONLY a JSON object in this delta format — it will be programmatically merged with the existing data:
- "background_updates": [{"name": "Exact Existing Name", "background": "One to three sentences of background from the related book.", "aliases": ["optional additional alias"]}] — one entry for each entity that appears in BOTH X-Rays (recurring characters, places, concepts, terms). Use the EXACT name from the entity list above. The existing entry is kept exactly as it is and your background text is attached alongside it, so cover only what the related book adds: who or what they were there, what they did, what carries over. This is the ONLY way to touch an existing entity — NEVER repeat an existing entity in the category arrays.
- Category arrays (same JSON keys and structure as the previous analysis): ONLY for entities from the related book that do NOT appear in the previous analysis but matter for understanding "{title}" (recurring or referenced figures, shared places, carried-over concepts). Write their descriptions as background knowledge from the related book.
- Names listed under "dormant" are carried from other related books and have NOT appeared in "{title}" yet — they are not existing entries. If an entity of the related book is the same person, place, or thing as a dormant name, treat it per the rules above (background_updates if it matches an existing entry, category arrays otherwise) and include the dormant name among its aliases.
- OMIT categories with nothing to add — they are preserved as-is
- timeline / argument_development and current_state / current_position belong to "{title}" alone — NEVER include them
- Do not invent entities that appear in neither X-Ray

@@KOA_MERGE_NEVER@@

CRITICAL: Output ONLY valid JSON — no other text. JSON keys must remain in English. Character names, location names, terms, and aliases must be in the same language and script as the source text. All other string values, including all background texts, must be written in {response_language}, regardless of the language of the source text.]]

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
        -- The dormant ledger never rides a prompt (item 49 — zero token cost)
        main = require("koassistant_xray_parser").stripDormantJSON(main_entry.result or ""),
        index = entity_index or "",
        never = XrayMerge.neverLines(never_pairs),
    }
end

--- Cross-book inputs block: ONE related book's X-Ray, labeled by book (the
--- label swap buildInputsBlock's doc anticipated). Rides the sentinel payload,
--- never action.prompt. Pure.
--- @param source table { title, author, entry = cache entry }
--- @return string block
function XrayMerge.buildCrossBookInputsBlock(source)
    local head = string.format('Related book — "%s"%s:', source.title or "?",
        (source.author and source.author ~= "" and (" by " .. source.author)) or "")
    -- Ledger stripped: the model matches/composes/selects on ACTIVE entities
    -- only — dormant carry is code's job (item 49)
    return head .. "\n" .. require("koassistant_xray_parser").stripDormantJSON(
        (source.entry and source.entry.result) or "")
end

--- Accumulate cross-book provenance titles ("A; B"), exact-dup safe. Pure.
--- @param existing string|nil The entry's current merged_from_books
--- @param title string|nil Source book title
--- @return string
function XrayMerge.appendBookProvenance(existing, title)
    title = title or "?"
    if not existing or existing == "" then return title end
    for part in existing:gmatch("([^;]+)") do
        if part:match("^%s*(.-)%s*$") == title then return existing end
    end
    return existing .. "; " .. title
end

--- Cross-book delta prompt + payload (fold one book's X-Ray into this book's
--- JSON main). Pure.
--- @param main_entry table Target live main cache entry (JSON result)
--- @param entity_index string XrayParser.buildEntityIndex output (may be "")
--- @param never_pairs table|nil Target book's reader-confirmed distinct pairs
--- @param source table { title, author, entry }
--- @return string prompt, table payload
function XrayMerge.buildCrossBookPrompt(main_entry, entity_index, never_pairs, source)
    local prompt = fillLiteral(XrayMerge.CROSS_BOOK_DELTA_PROMPT, "%COVERAGE%",
        XrayMerge.coveragePhrase(main_entry))
    return prompt, {
        inputs = XrayMerge.buildCrossBookInputsBlock(source),
        main = require("koassistant_xray_parser").stripDormantJSON(main_entry.result or ""),
        index = entity_index or "",
        never = XrayMerge.neverLines(never_pairs),
    }
end

-- Categories cross-book merges must never touch: append categories (the
-- target's own narrative) and singletons (its reading state). Mirrors the
-- parser's APPEND/SINGLETON sets; everything else is name-matched entities.
local PROTECTED_CATEGORIES = {
    timeline = true,
    argument_development = true,
    current_state = true,
    current_position = true,
    conclusion = true,
    reader_engagement = true,
    -- The dormant carry ledger (item 49) is code-owned — a model-emitted
    -- imitation is stripped from every delta (write-back drops it too)
    __dormant = true,
}

-- NAMED-ENTITY categories: things with an IDENTITY that can recur in another
-- book. Everything else a category list holds — themes, arguments, findings,
-- methodology — is this book's own ANALYSIS of its own text, which neither
-- travels nor means the same thing next door. Governs both the naming canon
-- (what steers another book's naming) and the dormant carry ledger (what a
-- fold may stub for later).
-- Round 26 (device audit): the carry ledger used every non-protected category,
-- so themes dominated it — 5 of 6 entries in one book, ~8 of 17 in the next,
-- pure noise the reader then had to read past in "Carried from earlier books".
local ENTITY_CATEGORIES = {
    characters = true, key_figures = true, locations = true,
    lexicon = true, terminology = true, technical_terms = true,
    core_concepts = true, key_concepts = true,
}
-- Exported for the browser's carried-entities list: the prune happens on the
-- next WRITE, so a RESTORED pre-round-26 version still holds theme stubs
-- (device: "I restored one of the hallvard x rays and that has 17 carried
-- over"). The list filters by the same set, so what the reader sees is
-- consistent regardless of when the ledger was last rewritten.
XrayMerge.ENTITY_CATEGORIES = ENTITY_CATEGORIES

--- name/alias (lowercased) → item, over every entity category. First bind
--- wins (duplicate names are the dedup engine's problem, not ours). Pure.
local function buildEntityLookup(base_data)
    local XrayParser = require("koassistant_xray_parser")
    local lookup = {}
    local function learn(key, item)
        if type(key) == "string" and key ~= "" then
            local norm = key:lower()
            if lookup[norm] == nil then lookup[norm] = item end
        end
    end
    for _idx, cat in ipairs(XrayParser.getCategories(base_data or {})) do
        if not PROTECTED_CATEGORIES[cat.key] and type(cat.items) == "table" then
            for _idx2, item in ipairs(cat.items) do
                learn(XrayParser.getItemName(item, cat.key), item)
                if type(item.aliases) == "table" then
                    for _idx3, alias in ipairs(item.aliases) do learn(alias, item) end
                end
            end
        end
    end
    return lookup
end

--- Union new aliases into an item, case-insensitive, never duplicating the
--- item's own name. Mutates the item.
local function mergeAliasesInto(item, additions)
    if type(additions) ~= "table" then return end
    local aliases = type(item.aliases) == "table" and item.aliases or {}
    local seen = {}
    if type(item.name) == "string" then seen[item.name:lower()] = true end
    if type(item.term) == "string" then seen[item.term:lower()] = true end
    for _idx, a in ipairs(aliases) do
        if type(a) == "string" then seen[a:lower()] = true end
    end
    local added = false
    for _idx, a in ipairs(additions) do
        if type(a) == "string" and a ~= "" and not seen[a:lower()] then
            aliases[#aliases + 1] = a
            seen[a:lower()] = true
            added = true
        end
    end
    if added then item.aliases = aliases end
end

--- Attach cross-book background to existing entities MECHANICALLY (item 44):
--- the matched entry keeps its description verbatim; the background rides the
--- item's `background` array ({ source, text }, per-source replace — see
--- XrayParser.mergeBackground) and optional new aliases are unioned in.
--- Matching is by name OR alias, case-insensitive. Mutates base_data. Pure
--- otherwise.
--- @param base_data table Parsed target X-Ray
--- @param updates table Array of { name, background, aliases? }
--- @param source_title string The related book's title (provenance label)
--- @return number applied, number unmatched
function XrayMerge.applyBackgroundUpdates(base_data, updates, source_title)
    local XrayParser = require("koassistant_xray_parser")
    local applied, unmatched = 0, 0
    if type(base_data) ~= "table" or type(updates) ~= "table" then
        return applied, unmatched
    end
    local lookup = buildEntityLookup(base_data)
    for _idx, upd in ipairs(updates) do
        local name = type(upd) == "table" and type(upd.name) == "string" and upd.name
        local item = name and lookup[name:lower()]
        if item and type(upd.background) == "string" and upd.background ~= "" then
            item.background = XrayParser.mergeBackground(item.background,
                { { source = source_title, text = upd.background } })
            mergeAliasesInto(item, upd.aliases)
            applied = applied + 1
        else
            unmatched = unmatched + 1
        end
    end
    return applied, unmatched
end

--- Transitive background carry (item 49, #90 chained-merge field report): a
--- chained series merge must not lose earlier ancestors — the source's own
--- labeled background lines (e.g. Vol 1's inside Vol 2's X-Ray) are copied
--- MECHANICALLY onto the matching target entity (or onto the delta's kept
--- carry-over entry) with their ORIGINAL source labels intact. Fill-gaps
--- only: a label already present on the receiving item wins, so a fresher
--- direct merge of that ancestor is never overwritten by a stale copy riding
--- in through a chain. Lines labeled with the target book itself are skipped
--- (self-background via out-of-order merges), as are unattributable "?"
--- labels. Mutates base_parsed/delta items; pure otherwise.
--- @param base_parsed table|nil Parsed target X-Ray
--- @param delta table|nil Model delta AFTER the rewrite-drop pass (kept entries only)
--- @param source_parsed table Parsed source X-Ray
--- @param target_title string|nil The target book's title (self-label filter)
--- @return table Distinct labels actually carried (array of strings)
function XrayMerge.carrySourceBackground(base_parsed, delta, source_parsed, target_title)
    local XrayParser = require("koassistant_xray_parser")
    local carried, carried_set = {}, {}
    if type(source_parsed) ~= "table" then return carried end
    -- Self-label filter compares normalized (trimmed, case-folded): the label in
    -- a background line came from an earlier merge's title string, the target
    -- title from live book metadata — casing/whitespace drift between the two
    -- must not let a self-label slip through.
    local function normTitle(s)
        if type(s) ~= "string" then return nil end
        local r = s:lower():gsub("^%s+", ""):gsub("%s+$", "")
        return r
    end
    local target_norm = normTitle(target_title)
    local base_lookup = buildEntityLookup(base_parsed or {})
    -- The delta's kept carry-over entries, keyed like buildEntityLookup
    local delta_lookup = {}
    if type(delta) == "table" then
        for key, arr in pairs(delta) do
            if not PROTECTED_CATEGORIES[key] and type(arr) == "table" then
                for _idx, entry in ipairs(arr) do
                    if type(entry) == "table" then
                        local name = entry.name or entry.term
                        if type(name) == "string" and name ~= ""
                            and delta_lookup[name:lower()] == nil then
                            delta_lookup[name:lower()] = entry
                        end
                        if type(entry.aliases) == "table" then
                            for _idx2, alias in ipairs(entry.aliases) do
                                if type(alias) == "string" and alias ~= ""
                                    and delta_lookup[alias:lower()] == nil then
                                    delta_lookup[alias:lower()] = entry
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    local function findIn(lookup, name, item)
        local hit = type(name) == "string" and name ~= "" and lookup[name:lower()]
        if hit then return hit end
        if type(item.aliases) == "table" then
            for _idx, alias in ipairs(item.aliases) do
                if type(alias) == "string" and alias ~= "" and lookup[alias:lower()] then
                    return lookup[alias:lower()]
                end
            end
        end
    end
    for _idx, cat in ipairs(XrayParser.getCategories(source_parsed)) do
        if not PROTECTED_CATEGORIES[cat.key] and type(cat.items) == "table" then
            for _idx2, item in ipairs(cat.items) do
                if type(item) == "table" and type(item.background) == "table" then
                    local name = XrayParser.getItemName(item, cat.key)
                    local target_item = findIn(base_lookup, name, item)
                        or findIn(delta_lookup, name, item)
                    if target_item then
                        local existing_sources = {}
                        if type(target_item.background) == "table" then
                            for _idx3, b in ipairs(target_item.background) do
                                if type(b) == "table" and type(b.source) == "string" then
                                    existing_sources[b.source] = true
                                end
                            end
                        end
                        local additions = {}
                        for _idx3, b in ipairs(item.background) do
                            if type(b) == "table" and type(b.text) == "string" and b.text ~= ""
                                and type(b.source) == "string" and b.source ~= ""
                                and b.source ~= "?"
                                and normTitle(b.source) ~= target_norm
                                and not existing_sources[b.source] then
                                additions[#additions + 1] = { source = b.source, text = b.text }
                            end
                        end
                        if #additions > 0 then
                            target_item.background = XrayParser.mergeBackground(
                                target_item.background, additions)
                            for _idx3, b in ipairs(additions) do
                                if not carried_set[b.source] then
                                    carried_set[b.source] = true
                                    carried[#carried + 1] = b.source
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return carried
end

--- Carry layer 1 (item 49): source entities that did NOT arrive in this merge
--- become dormant ledger stubs on the target — invisible, token-free carriers
--- that the wake-pass (XrayParser.wakeDormant, run by every write-back)
--- promotes the moment a matching entity appears by any route. The source's
--- own ledger rides along too (transitive skip-volume carry: vol N's artifact
--- + ledger covers 1..N — the "vol 7 needs vol 6's artifact only" invariant).
--- A stub already in the ledger is refreshed by the newer source, its carried
--- background lines unioned. Mutates base_parsed; pure otherwise.
--- @param base_parsed table Parsed target X-Ray (mutated)
--- @param delta table|nil Model delta AFTER the rewrite-drop pass (kept = arriving entities)
--- @param source_parsed table Parsed source X-Ray
--- @param source_title string The source book's title (stub provenance)
--- @return number stubs newly added
function XrayMerge.populateDormant(base_parsed, delta, source_parsed, source_title)
    local XrayParser = require("koassistant_xray_parser")
    if type(base_parsed) ~= "table" or type(source_parsed) ~= "table" then return 0 end
    local DK = XrayParser.DORMANT_KEY
    -- Everything the target can already match: its actives + the delta's
    -- arriving entities (they become actives in the merge right after this)
    local present = buildEntityLookup(base_parsed)
    if type(delta) == "table" then
        for key, arr in pairs(delta) do
            if not PROTECTED_CATEGORIES[key] and type(arr) == "table" then
                for _idx, entry in ipairs(arr) do
                    if type(entry) == "table" then
                        local name = entry.name or entry.term
                        if type(name) == "string" and name ~= ""
                            and present[name:lower()] == nil then
                            present[name:lower()] = entry
                        end
                        if type(entry.aliases) == "table" then
                            for _idx2, alias in ipairs(entry.aliases) do
                                if type(alias) == "string" and alias ~= ""
                                    and present[alias:lower()] == nil then
                                    present[alias:lower()] = entry
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    local ledger = base_parsed[DK]
    if type(ledger) ~= "table" then ledger = {} end
    -- Self-heal ledgers written before round 26: drop stubs from categories
    -- that are analysis, not identity. Stubs with no category recorded are
    -- KEPT (older writes; never destroy what we cannot classify).
    do
        local kept = {}
        for _idx, stub in ipairs(ledger) do
            local cat = type(stub) == "table" and stub.category or nil
            if type(cat) ~= "string" or cat == "" or ENTITY_CATEGORIES[cat] then
                kept[#kept + 1] = stub
            end
        end
        ledger = kept
    end
    local by_name = {}
    for i, stub in ipairs(ledger) do
        if type(stub) == "table" and type(stub.name) == "string" then
            by_name[stub.name:lower()] = i
        end
    end
    local added = 0
    local function stash(stub)
        local key = type(stub.name) == "string" and stub.name ~= ""
            and stub.name:lower() or nil
        if not key then return end
        local at = by_name[key]
        if at then
            -- Newer source refreshes the stub; carried lines are unioned
            stub.background = XrayParser.mergeBackground(ledger[at].background, stub.background)
            ledger[at] = stub
        else
            ledger[#ledger + 1] = stub
            by_name[key] = #ledger
            added = added + 1
        end
    end
    local function isPresent(name, aliases)
        if type(name) == "string" and name ~= "" and present[name:lower()] then return true end
        if type(aliases) == "table" then
            for _idx, a in ipairs(aliases) do
                if type(a) == "string" and a ~= "" and present[a:lower()] then return true end
            end
        end
        return false
    end
    -- (a) source ACTIVES that did not arrive → stubs. Named entities only:
    -- a theme from the previous book is that book's reading of that book
    -- (round 26 audit — themes were most of the ledger).
    for _idx, cat in ipairs(XrayParser.getCategories(source_parsed)) do
        if ENTITY_CATEGORIES[cat.key] and type(cat.items) == "table" then
            for _idx2, item in ipairs(cat.items) do
                if type(item) == "table" then
                    local name = XrayParser.getItemName(item, cat.key)
                    if type(name) == "string" and name ~= ""
                        and not isPresent(name, item.aliases) then
                        local aliases
                        if type(item.aliases) == "table" and #item.aliases > 0 then
                            aliases = {}
                            for _idx3, a in ipairs(item.aliases) do aliases[#aliases + 1] = a end
                        end
                        -- Only cleanly attributable carried lines ride along
                        local bg
                        if type(item.background) == "table" then
                            for _idx3, b in ipairs(item.background) do
                                if type(b) == "table" and type(b.text) == "string" and b.text ~= ""
                                    and type(b.source) == "string" and b.source ~= ""
                                    and b.source ~= "?" then
                                    bg = bg or {}
                                    bg[#bg + 1] = { source = b.source, text = b.text }
                                end
                            end
                        end
                        stash({
                            name = name,
                            aliases = aliases,
                            category = cat.key,
                            description = type(item.description) == "string"
                                and item.description ~= "" and item.description or nil,
                            source = source_title,
                            background = bg,
                        })
                    end
                end
            end
        end
    end
    -- (b) the source's OWN dormant stubs (transitive skip-volume carry).
    -- Deliberately stashed even when they match a target active: an active
    -- source entity delivered its knowledge via the carry above, but a source
    -- DORMANT hasn't — the wake-pass right after the merge promotes it in the
    -- same write.
    if type(source_parsed[DK]) == "table" then
        for _idx, stub in ipairs(source_parsed[DK]) do
            -- Same identity-only filter, so a pre-round-26 ledger's theme
            -- stubs stop propagating down the chain
            if type(stub) == "table" and type(stub.name) == "string" and stub.name ~= ""
                and (type(stub.category) ~= "string" or stub.category == ""
                    or ENTITY_CATEGORIES[stub.category]) then
                stash({
                    name = stub.name,
                    aliases = stub.aliases,
                    category = stub.category,
                    description = stub.description,
                    source = stub.source or source_title,
                    background = stub.background,
                })
            end
        end
    end
    if #ledger > 0 then base_parsed[DK] = ledger end
    return added
end

--- Round 26 (device audit — the round-25 rebuild carry was half a fix): a
--- rebuild replaces the artifact wholesale, so cross-book background already
--- folded onto ACTIVE entities died with it, even though the intent was "a
--- rebuild must never cost knowledge the book already held". Re-stub every
--- outgoing entity that carries background into the ledger (identity + the
--- background verbatim, never the old description — the new read owns that);
--- the wake-pass right after promotes them back onto whatever the fresh X-Ray
--- named, and anything the new read dropped stays honestly carried.
--- @param prev_parsed table The outgoing X-Ray
--- @param parsed table The fresh X-Ray (mutated: ledger populated)
--- @return number added
function XrayMerge.carryActiveBackground(prev_parsed, parsed)
    local XrayParser = require("koassistant_xray_parser")
    if type(prev_parsed) ~= "table" or type(parsed) ~= "table" then return 0 end
    local DK = XrayParser.DORMANT_KEY
    local ledger = type(parsed[DK]) == "table" and parsed[DK] or {}
    local by_name = {}
    for i, stub in ipairs(ledger) do
        if type(stub) == "table" and type(stub.name) == "string" then
            by_name[stub.name:lower()] = i
        end
    end
    local added = 0
    for _idx, cat in ipairs(XrayParser.getCategories(prev_parsed)) do
        if ENTITY_CATEGORIES[cat.key] and type(cat.items) == "table" then
            for _idx2, item in ipairs(cat.items) do
                if type(item) == "table" and type(item.background) == "table"
                    and #item.background > 0 then
                    local name = XrayParser.getItemName(item, cat.key)
                    if type(name) == "string" and name ~= "" then
                        local aliases
                        if type(item.aliases) == "table" and #item.aliases > 0 then
                            aliases = {}
                            for _idx3, a in ipairs(item.aliases) do aliases[#aliases + 1] = a end
                        end
                        local stub = {
                            name = name,
                            aliases = aliases,
                            category = cat.key,
                            background = item.background,
                        }
                        local at = by_name[name:lower()]
                        if at then
                            stub.background = XrayParser.mergeBackground(
                                ledger[at].background, item.background)
                            stub.source = ledger[at].source
                            stub.description = ledger[at].description
                            ledger[at] = stub
                        else
                            ledger[#ledger + 1] = stub
                            by_name[name:lower()] = #ledger
                            added = added + 1
                        end
                    end
                end
            end
        end
    end
    if #ledger > 0 then parsed[DK] = ledger end
    return added
end

--- Nearest eligible carry source: walks the group's predecessors nearest→
--- farthest and returns the FIRST with a valid JSON main X-Ray AND
--- text-extraction consent (its own ledger rides along, so one eligible
--- predecessor carries everything it knows — transitive). Shared by the
--- create-time seed and the naming canon (carry layer 3(iii)).
--- @param file string Target book path
--- @param features table|nil Current settings features (consent resolution)
--- @param provider string|nil Provider id (trusted-provider consent)
--- @param ui table|nil
--- @return table|nil src { file, title, entry, parsed }
function XrayMerge.seedSource(file, features, provider, ui)
    if type(file) ~= "string" or file == "" then return nil end
    local BookGroups = require("koassistant_book_groups")
    local preds = BookGroups.predecessorsOf(file)
    if #preds == 0 then return nil end
    local ActionCache = require("koassistant_action_cache")
    local XrayParser = require("koassistant_xray_parser")
    for i = #preds, 1, -1 do
        local entry = ActionCache.getXrayCache(preds[i])
        if entry and entry.result and XrayParser.isJSON(entry.result)
            and XrayMerge.consentOk({ entry }, features, provider, preds[i], ui) then
            local source_parsed = XrayParser.parse(entry.result)
            if source_parsed and not source_parsed.error then
                return { file = preds[i], title = BookGroups.displayTitle(preds[i], ui),
                    entry = entry, parsed = source_parsed }
            end
        end
    end
    return nil
end

--- Carry layer 3(i): mechanical create-time seed — a fresh (or rebuilt) main
--- X-Ray starts its dormant ledger from the nearest X-Rayed predecessor in
--- the book's group (seedSource), locally and token-free; the artifact's
--- visible content is untouched. Skip-volume wake then works even if the
--- reader never merges, and a complete rebuild recovers the ledger it just
--- dropped.
--- @param file string Target book path
--- @param parsed table Freshly parsed X-Ray data (mutated: ledger populated)
--- @param features table|nil Current settings features (consent resolution)
--- @param provider string|nil Provider id (trusted-provider consent)
--- @param ui table|nil
--- @return number added, string|nil source_title
function XrayMerge.seedDormant(file, parsed, features, provider, ui)
    if type(parsed) ~= "table" then return 0, nil end
    local src = XrayMerge.seedSource(file, features, provider, ui)
    if not src then return 0, nil end
    local added = XrayMerge.populateDormant(parsed, nil, src.parsed, src.title)
    return added, src.title
end

--- Series naming canon (carry layer 3(iii), 2026-08-06): IDENTITY HANDLES —
--- names + up to two aliases, never content — of the predecessor's named
--- entities, plus its dormant ledger's (transitive), framed for the CREATE
--- request. Recurring entities then keep one name from birth and the
--- follow-up fold matches on exact names instead of repairing drift
--- artifact-to-artifact. Injected ONLY when the reader accepted the
--- pre-create fold ask — a declined fold means a fully standalone read.
--- Pure.
--- @param source_parsed table Predecessor's parsed X-Ray
--- @param source_title string|nil
--- @return string|nil block Framed prompt block (nil when nothing to list)
function XrayMerge.namingCanonBlock(source_parsed, source_title)
    if type(source_parsed) ~= "table" then return nil end
    local XrayParser = require("koassistant_xray_parser")
    local order, bucket = {}, {}
    local function put(cat_key, name, aliases)
        if type(name) ~= "string" or name == "" then return end
        if not bucket[cat_key] then
            bucket[cat_key] = {}
            order[#order + 1] = cat_key
        end
        local shown = name
        if type(aliases) == "table" and #aliases > 0 then
            local a = {}
            for i = 1, math.min(2, #aliases) do a[i] = tostring(aliases[i]) end
            shown = shown .. " (" .. table.concat(a, ", ") .. ")"
        end
        bucket[cat_key][#bucket[cat_key] + 1] = shown
    end
    for _idx, cat in ipairs(XrayParser.getCategories(source_parsed)) do
        if ENTITY_CATEGORIES[cat.key] and type(cat.items) == "table" then
            for _idx2, item in ipairs(cat.items) do
                if type(item) == "table" then
                    put(cat.key, XrayParser.getItemName(item, cat.key), item.aliases)
                end
            end
        end
    end
    local ledger = source_parsed[XrayParser.DORMANT_KEY]
    if type(ledger) == "table" then
        for _idx, stub in ipairs(ledger) do
            if type(stub) == "table" and ENTITY_CATEGORIES[stub.category or ""] then
                put(stub.category, stub.name, stub.aliases)
            end
        end
    end
    if #order == 0 then return nil end
    local lines = {}
    for _idx, key in ipairs(order) do
        lines[#lines + 1] = key .. ": " .. table.concat(bucket[key], "; ")
    end
    return "[Series naming reference]\nThis book is part of the same series as \""
        .. (source_title or "?")
        .. "\", whose X-Ray already exists. The names below are for NAMING CONSISTENCY ONLY: "
        .. "if any of these people, places, or terms appear in this book's text — possibly "
        .. "unnamed, renamed, or under an epithet — use the SAME name for your entry, or "
        .. "include the known name in that entry's \"aliases\". Do NOT add entries for names "
        .. "that do not appear in this book's text.\n"
        .. table.concat(lines, "\n")
end

--- Provenance union for cross-book merges: the target's existing list + the
--- source title + the source's OWN provenance — a merge carries the source's
--- ancestor-labeled background along (item 49), so transitive sources are
--- genuinely included and must be recorded, or chained volumes read as
--- gap-ridden (provenanceGap) and "Includes background from" understates.
--- Pure.
--- @param existing string|nil Target's merged_from_books
--- @param source_title string The book being folded in
--- @param source_provenance string|nil That book's own merged_from_books
--- @return string Updated ";"-separated provenance
function XrayMerge.unionProvenance(existing, source_title, source_provenance)
    local out = XrayMerge.appendBookProvenance(existing, source_title)
    for part in (source_provenance or ""):gmatch("([^;]+)") do
        local t = part:match("^%s*(.-)%s*$")
        if t ~= "" then out = XrayMerge.appendBookProvenance(out, t) end
    end
    return out
end

--- Carry layer 3(ii) gap check: which of these titles are missing from a
--- book's merge provenance? Same identity rule as appendBookProvenance
--- (exact title match within the ";"-separated list). Pure.
--- @param titles table Ordered titles that SHOULD have been folded in
--- @param merged_from string|nil The book's merged_from_books value
--- @return table missing Titles not found in the provenance
function XrayMerge.provenanceGap(titles, merged_from)
    local have = {}
    for part in (merged_from or ""):gmatch("([^;]+)") do
        have[part:match("^%s*(.-)%s*$")] = true
    end
    local missing = {}
    for _idx, t in ipairs(titles or {}) do
        if not have[t] then missing[#missing + 1] = t end
    end
    return missing
end

--- Pre-merge transform for cross-book deltas (rides WriteBack.applyXray's
--- transform hook): applies background_updates to the BASE, strips the
--- protected categories, and drops any disobedient full rewrite of an
--- existing entity from the delta (salvaging its aliases) — so a cross-book
--- merge can NEVER replace or shorten what the target book already knows,
--- regardless of model tier. When source_parsed is given, the source's own
--- background lines carry over transitively (see carrySourceBackground);
--- labels actually carried are appended to meta_out.merged_from_books (the
--- SAME table later read by reconcileXrayMeta — the transform runs first).
--- @param source_title string The related book's title
--- @param source_parsed table|nil Parsed source X-Ray (transitive carry input)
--- @param target_title string|nil The target book's title (self-label filter)
--- @param meta_out table|nil applyXray meta table to receive carried labels
--- @return function transform(delta, base_parsed)
function XrayMerge.crossBookTransform(source_title, source_parsed, target_title, meta_out)
    return function(delta, base_parsed)
        if type(delta) ~= "table" or type(base_parsed) ~= "table" then return end
        local updates = delta.background_updates
        delta.background_updates = nil
        local applied, unmatched = XrayMerge.applyBackgroundUpdates(
            base_parsed, updates or {}, source_title)
        for key in pairs(PROTECTED_CATEGORIES) do delta[key] = nil end
        local lookup = buildEntityLookup(base_parsed)
        local dropped = 0
        for key, arr in pairs(delta) do
            if type(arr) == "table" and #arr > 0 then
                local kept = {}
                for _idx, entry in ipairs(arr) do
                    local name = type(entry) == "table" and (entry.name or entry.term)
                    local hit = type(name) == "string" and lookup[name:lower()]
                    if hit then
                        mergeAliasesInto(hit, entry.aliases)
                        dropped = dropped + 1
                    else
                        kept[#kept + 1] = entry
                    end
                end
                if #kept ~= #arr then delta[key] = kept end
            end
        end
        local carried_n = 0
        local stubbed = 0
        if type(source_parsed) == "table" then
            local labels = XrayMerge.carrySourceBackground(
                base_parsed, delta, source_parsed, target_title)
            carried_n = #labels
            if meta_out then
                for _idx, label in ipairs(labels) do
                    meta_out.merged_from_books = XrayMerge.appendBookProvenance(
                        meta_out.merged_from_books, label)
                end
            end
            -- Carry layer 1: whatever did NOT arrive goes dormant instead of
            -- being lost — the wake-pass right after the merge promotes any
            -- stub that already matches
            stubbed = XrayMerge.populateDormant(base_parsed, delta, source_parsed, source_title)
        end
        logger.info("KOAssistant XrayMerge: cross-book background —",
            applied, "applied,", unmatched, "unmatched,", dropped, "rewrites dropped,",
            carried_n, "ancestor labels carried,", stubbed, "gone dormant")
    end
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
    -- Round 25 (device report): merges emit raw delta JSON, and the post-create
    -- fold runs OVER the X-Ray the reader just opened — a full-screen JSON dump
    -- there reads as "it opened the wrong X-Ray". Hidden streaming keeps the
    -- waiting animation, the Show toggle and the cancel affordance. Round 26:
    -- name the work — the placeholder used to be hardcoded quiz wording.
    config.features.hidden_streaming = true
    config.features.hidden_streaming_label = _("Merging X-Ray data")
    config.features.hidden_streaming_note = _("Tap Show to watch it arrive.")
    local bm = {}
    for k, v in pairs(config.features.book_metadata or {}) do bm[k] = v end
    bm.file = opts.file
    -- Identity comes from the TARGET book, NEVER inherited from whatever book
    -- happens to be open — merges can launch from a cross-book-viewed X-Ray
    -- (group nav / artifact browser), and "identity sent and sidecar consulted
    -- must be the same book" (item 46 follow-up). Missing title/author resolve
    -- from the target's own doc_props + AI override.
    local title, author = opts.title, opts.author
    if not title or title == "" or author == nil then
        local ok, ds = pcall(function()
            return require("koassistant_doc_settings").resolve(opts.file, opts.ui)
        end)
        if ok and ds then
            local props = ds:readSetting("doc_props") or {}
            local ok_ov, ov_t, ov_a = pcall(function()
                return require("koassistant_book_settings").getMetadataOverride(ds)
            end)
            if not title or title == "" then
                title = props.display_title or props.title
                if ok_ov and ov_t ~= nil then title = ov_t end
            end
            if author == nil then
                author = props.authors
                if type(author) == "string" and author:find("\n") then
                    author = author:gsub("\n", ", ")
                end
                if ok_ov and ov_a ~= nil then author = ov_a end
            end
        end
    end
    if not title or title == "" then
        title = opts.file:match("([^/]+)%.[^.]+$") or opts.file:match("([^/]+)$") or opts.file
    end
    bm.title = title
    bm.author = author or ""
    bm.author_clause = (bm.author ~= "" and (" by " .. bm.author)) or ""
    -- Stale DOI from another book would flip research mode on a structural merge
    bm.doi = nil
    bm.doi_clause = nil
    config.features.book_metadata = bm
    -- The synthetic identity channel must match the gated one (book identity
    -- reaches the AI via TWO channels — CLAUDE.md): never the open book's string
    config.features.book_context = bm.title .. bm.author_clause
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
                -- Round 26: a fold that never came back logged NOTHING between
                -- its request body and the next UI event, so a silent failure
                -- was indistinguishable from "the fold ran and changed nothing"
                logger.info("KOAssistant XrayMerge: fold into", file, "FAILED:",
                    tostring(meta_or_err or "no response"))
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

-- ==================== Cross-book merge (item 43, #90 v1) ====================
-- Merge, not connect: the source book's X-Ray is read-only INPUT (originals
-- stay untouched and browsable); the result lands in the TARGET book's main
-- via the ordinary delta write-back (the outgoing main is ring-archived —
-- undoable from All versions). No series backend: the picker lists every book
-- the artifact index knows with a JSON main X-Ray; manual pick covers series,
-- same-author, and thematic cases alike. A standalone library-level series
-- artifact stays deferred (§5 decisions 6/7).

--- Run the cross-book merge headlessly and write the result into the target.
--- @param opts table { file (target), ui, plugin, configuration, title, author
---   (TARGET identity for the headless config), main_entry (target JSON main),
---   source = { file, title, author, entry }, on_done(ok, err) }
function XrayMerge.executeCrossBook(opts)
    local Dialogs = require("koassistant_dialogs")
    local ActionCache = require("koassistant_action_cache")
    local WriteBack = require("koassistant_artifact_writeback")
    local XrayParser = require("koassistant_xray_parser")

    local main_entry = opts.main_entry
    local parsed_main = XrayParser.parse(main_entry.result or "")
    if not parsed_main or parsed_main.error then
        if opts.on_done then opts.on_done(false, "main X-Ray is not valid JSON") end
        return
    end
    local entity_index = XrayParser.buildEntityIndex(parsed_main) or ""
    local never_pairs = ActionCache.getNeverMergePairs(opts.file)
    local prompt_text, payload = XrayMerge.buildCrossBookPrompt(
        main_entry, entity_index, never_pairs, opts.source)

    -- Synthetic internal action — same shape as the section merge
    local action = {
        id = "xray_cross_merge",
        text = _("Merge X-Ray from another book"),
        context = "book",
        prompt = prompt_text,
        storage_key = "__SKIP__",
        enable_web_search = false,
        -- No reasoning pin (series-identity round, 2026-08-06): cross-book
        -- entity resolution is a judgment task — the extraction action's
        -- latency "off" would run it at the floor (Gemini 3.x can't disable,
        -- "off" resolves to minimal). nil = stance/model default.
        api_params = XrayMerge.API_PARAMS,
        builtin = true,
    }
    if opts.plugin and opts.plugin.updateConfigFromSettings then
        opts.plugin:updateConfigFromSettings()
    end
    local config, bm = XrayMerge.buildHeadlessConfig(opts, payload)
    local plugin_ref = opts.plugin
    local file = opts.file
    local source = opts.source
    -- One line per fold at DISPATCH (round 26): a fold could previously only be
    -- traced by reconstructing it from picker and extraction lines
    logger.info("KOAssistant XrayMerge: folding", (source and source.title) or "?",
        "into", opts.title or file)
    Dialogs.executeActionForResult(action, config.features.book_context or "", opts.ui, config,
        opts.plugin, bm,
        function(result, meta_or_err)
            if not result then
                -- Round 26: a fold that never came back logged NOTHING between
                -- its request body and the next UI event, so a silent failure
                -- was indistinguishable from "the fold ran and changed nothing"
                logger.info("KOAssistant XrayMerge: fold into", file, "FAILED:",
                    tostring(meta_or_err or "no response"))
                if opts.on_done then opts.on_done(false, tostring(meta_or_err or "no response")) end
                return
            end
            local model_name = type(meta_or_err) == "table"
                and meta_or_err.model ~= "" and meta_or_err.model or nil
            local used_reasoning = type(meta_or_err) == "table"
                and meta_or_err.used_reasoning or nil
            local union = XrayMerge.unionInputMeta({ source.entry })
            -- Item 49 transitive carry: the transform appends carried ancestor
            -- labels to THIS table (reconcileXrayMeta reads it after the
            -- transform has run inside parseXrayAnswer)
            local wb_meta = {
                model = model_name,
                used_reasoning = used_reasoning,
                used_book_text = union.used_book_text,
                used_highlights = union.used_highlights,
                producer = "book_merge",
                merged_from_books = XrayMerge.unionProvenance(
                    main_entry.merged_from_books, source.title,
                    source.entry and source.entry.merged_from_books),
            }
            local source_parsed = XrayParser.parse(
                (source.entry and source.entry.result) or "")
            local ok, res_or_err = WriteBack.applyXray({
                document_path = file,
                answer = result,
                base = main_entry,
                base_entry = main_entry,
                -- Item 44: background attaches mechanically; existing entries
                -- can never be replaced or shortened by this merge. Item 49:
                -- the source's own ancestor background carries over with
                -- original labels (chained merges no longer lose Vol 1)
                transform = XrayMerge.crossBookTransform(source.title,
                    source_parsed, bm.title, wb_meta),
                -- Cross-book knowledge claims NO target pages: progress stays
                -- the base's (floor guard) and coverage_spans union base-only
                -- (slice-1 reconcile — the new pass carries none)
                progress_decimal = tonumber(main_entry.progress_decimal) or 0,
                meta = wb_meta,
                features = config.features,
                refresh_fn = function()
                    if plugin_ref then
                        plugin_ref._file_dialog_row_cache = { file = nil, rows = nil }
                        if plugin_ref._refreshXrayAutoState and plugin_ref.ui
                            and plugin_ref.ui.document and plugin_ref.ui.document.file == file then
                            plugin_ref:_refreshXrayAutoState()
                        end
                    end
                    -- An X-Ray browser open on this book holds a pre-merge
                    -- snapshot (round 25) — reload it in place
                    require("koassistant_xray_browser"):reloadLiveMain(file)
                end,
            })
            if opts.on_done then opts.on_done(ok, not ok and res_or_err or nil) end
        end)
end

--- Post-merge duplicate check (series-identity round, 2026-08-06): run the
--- mechanical duplicate scan on a freshly merged artifact and offer the
--- dedup flow when it finds pairs — a fold that imported a differently-named
--- recurring entity leaves exactly the near-duplicates the scan catches
--- (same name / shared alias / contained name). Description-level twins with
--- no name overlap stay the reader's call. Silent when clean; attended merge
--- paths only.
--- @param opts table { file, ui, plugin, configuration, title, author }
function XrayMerge.maybeOfferDedupScan(opts)
    local ActionCache = require("koassistant_action_cache")
    local XrayParser = require("koassistant_xray_parser")
    local XrayDedup = require("koassistant_xray_dedup")
    local entry = ActionCache.getXrayCache(opts.file)
    if not (entry and entry.result and XrayParser.isJSON(entry.result)) then return end
    local data = XrayParser.parse(entry.result)
    if not data or data.error then return end
    local user_aliases = ActionCache.getUserAliases(opts.file)
    if next(user_aliases) then
        XrayParser.mergeUserAliases(data, user_aliases)
    end
    local found = XrayDedup.findDuplicates(data,
        ActionCache.neverMergePairsFrom(user_aliases))
    if #found == 0 then return end
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    dialog = ButtonDialog:new{
        title = T(_("The merge may have left %1 duplicate entit(y/ies) — the same figure under two names. Review them?"), #found),
        buttons = {
            {{ text = _("Review duplicates…"), callback = function()
                UIManager:close(dialog)
                require("koassistant_xray_dedup").startFlow({
                    file = opts.file, ui = opts.ui, plugin = opts.plugin,
                    configuration = opts.configuration,
                    title = opts.title, author = opts.author,
                })
            end }},
            {{ text = _("Not now"), callback = function() UIManager:close(dialog) end }},
        },
    }
    UIManager:show(dialog)
end

--- Run the organic series chain headlessly: chain[1]→chain[2], 2→3, …
--- (oldest first, the receiving book last) — each hop re-reads BOTH sides
--- fresh (the previous hop just rewrote the source), re-checks consent, and
--- stops loudly naming the hop on failure. Shared by the merge picker's
--- fold-all row and the post-create fold offer (carry layer 3(ii)).
--- @param opts table { chain = ordered {file, title, author, entry} rows,
---   features, provider, ui, plugin, configuration,
---   close_browser (called once the preflight sweep passes), on_done(ok) }
function XrayMerge.runSeriesChain(opts)
    local ActionCache = require("koassistant_action_cache")
    local XrayParser = require("koassistant_xray_parser")
    local InfoMessage = require("ui/widget/infomessage")
    local Notification = require("ui/widget/notification")
    local chain = opts.chain or {}
    local n_merges = #chain - 1
    if n_merges < 1 then return end
    -- Preflight consent sweep (2026-08-05): fail BEFORE the first request
    -- names the blocking book — never stop a paid run midway on a knowable
    -- condition. The per-step checks stay (settings can change mid-run).
    for _cidx, member in ipairs(chain) do
        if not XrayMerge.consentOk({ member.entry }, opts.features, opts.provider, member.file, opts.ui) then
            UIManager:show(InfoMessage:new{
                text = T(_("Cannot start: text-extraction consent is missing for \"%1\"."), member.title),
                timeout = 5,
            })
            return
        end
    end
    if opts.close_browser then opts.close_browser() end
    local function step(idx)
        if idx > n_merges then
            UIManager:show(Notification:new{
                text = T(_("Series chain complete: %1 merges."), n_merges),
            })
            -- Post-merge duplicate check on the final receiving book (the
            -- chain is always attended); earlier hops go unchecked — one
            -- dialog per chain, and the reader can scan any volume manually
            local last = chain[#chain]
            XrayMerge.maybeOfferDedupScan({
                file = last.file, title = last.title, author = last.author,
                ui = opts.ui, plugin = opts.plugin, configuration = opts.configuration,
            })
            if opts.on_done then opts.on_done(true) end
            return
        end
        local src_c = chain[idx]
        local tgt_c = chain[idx + 1]
        -- Both re-read fresh: the previous hop rewrote src
        local fresh_src = ActionCache.getXrayCache(src_c.file)
        local fresh_tgt = ActionCache.getXrayCache(tgt_c.file)
        if not (fresh_src and fresh_src.result and XrayParser.isJSON(fresh_src.result))
            or not (fresh_tgt and fresh_tgt.result and XrayParser.isJSON(fresh_tgt.result)) then
            UIManager:show(InfoMessage:new{
                text = T(_("Stopped at \"%1\": its X-Ray is no longer available."),
                    (fresh_src and fresh_src.result) and tgt_c.title or src_c.title),
                timeout = 4,
            })
            return
        end
        if not XrayMerge.consentOk({ fresh_src }, opts.features, opts.provider, src_c.file, opts.ui)
            or not XrayMerge.consentOk({ fresh_tgt }, opts.features, opts.provider, tgt_c.file, opts.ui) then
            UIManager:show(InfoMessage:new{
                text = T(_("Stopped at \"%1\": text-extraction consent is missing for it."), src_c.title),
                timeout = 5,
            })
            return
        end
        UIManager:show(Notification:new{
            text = T(_("Merging %1 of %2: %3 into %4"), idx, n_merges,
                src_c.title, tgt_c.title),
        })
        XrayMerge.executeCrossBook({
            file = tgt_c.file, ui = opts.ui, plugin = opts.plugin,
            configuration = opts.configuration,
            title = tgt_c.title, author = tgt_c.author,
            main_entry = fresh_tgt,
            source = { file = src_c.file, title = src_c.title,
                author = src_c.author, entry = fresh_src },
            on_done = function(ok, err)
                if ok then
                    step(idx + 1)
                else
                    UIManager:show(InfoMessage:new{
                        text = T(_("Stopped at \"%1\" into \"%2\": %3"), src_c.title,
                            tgt_c.title, tostring(err or "unknown error")),
                        timeout = 5,
                    })
                end
            end,
        })
    end
    step(1)
end

--- Carry layer 3(iii), the PRE-create fold ask (maintainer decision
--- 2026-08-06, replacing the post-create offer): BEFORE an attended fresh
--- main X-Ray of a grouped book whose previous book has an X-Ray, ask once —
--- fold when done / bring the chain up to date / just this book. Accepting
--- injects the naming canon into the create request (recurring entities keep
--- one name from birth) and auto-runs the fold when the create lands
--- (runPostCreateFold). Declining means a fully standalone create — no
--- canon, no fold, no re-ask (the silent seed still runs: declining a merge
--- is not declining carry). When the previous book has no X-Ray, no dialog —
--- the post-create gap note covers that case. Dismissing the dialog aborts
--- the create, like dismissing the source popup.
--- @param opts table { file, ui, configuration }
--- @param proceed function(mode) mode = "single"|"chain"|nil (declined)
--- @return boolean asked False when no dialog applies (proceed NOT called —
---   the caller continues synchronously)
function XrayMerge.preCreateFoldAsk(opts, proceed)
    local BookGroups = require("koassistant_book_groups")
    local preds, group = BookGroups.predecessorsOf(opts.file)
    if #preds == 0 then return false end
    local ActionCache = require("koassistant_action_cache")
    local XrayParser = require("koassistant_xray_parser")
    local nearest = preds[#preds]
    local nearest_entry = ActionCache.getXrayCache(nearest)
    if not (nearest_entry and nearest_entry.result and XrayParser.isJSON(nearest_entry.result)) then
        return false
    end
    local ButtonDialog = require("ui/widget/buttondialog")
    local nearest_title = BookGroups.displayTitle(nearest, opts.ui)
    -- The previous book's own X-Rayed predecessors vs its provenance:
    -- anything missing means its X-Ray does not yet carry those volumes
    local earlier_titles = {}
    for i = 1, #preds - 1 do
        local e = ActionCache.getXrayCache(preds[i])
        if e and e.result and XrayParser.isJSON(e.result) then
            earlier_titles[#earlier_titles + 1] = BookGroups.displayTitle(preds[i], opts.ui)
        end
    end
    local missing = XrayMerge.provenanceGap(earlier_titles, nearest_entry.merged_from_books)
    local ask_text = T(_("\"%1\" (the previous book in %2) has an X-Ray. Fold its knowledge into this book's X-Ray once it is built? Recurring names then stay consistent across the series. The two X-Rays are sent, not the books."),
        nearest_title, (group and group.name) or _("this group"))
    if #missing > 0 then
        ask_text = ask_text .. "\n"
            .. T(_("Note: it has not folded its own earlier book(s) in yet (%1), so their knowledge would not carry over."),
                table.concat(missing, ", "))
    end
    local ask
    local buttons = {
        {{ text = _("Fold it in when done (1 extra request)"), callback = function()
            UIManager:close(ask)
            proceed("single")
        end }},
    }
    if #missing > 0 and #earlier_titles >= 1 then
        buttons[#buttons + 1] = {{
            text = T(_("Bring the series up to date (%1 merges)"), #earlier_titles + 1),
            callback = function()
                UIManager:close(ask)
                proceed("chain")
            end,
        }}
    end
    buttons[#buttons + 1] = {{ text = _("Just this book"), callback = function()
        UIManager:close(ask)
        proceed(nil)
    end }}
    -- Not dismissable: this ask gates the create itself, so a tap outside would
    -- silently abandon the X-Ray with no message ("Just this book" is the
    -- explicit opt-out)
    ask = ButtonDialog:new{ title = ask_text, buttons = buttons, dismissable = false }
    UIManager:show(ask)
    return true
end

--- Execute the accepted pre-create fold once the create landed (carry layer
--- 3(iii), second half): "single" folds the previous book in, "chain" runs
--- the organic chain ending at this book. Everything is re-read fresh from
--- disk — the create just wrote the target, and the ask ran one request ago.
--- Ends with the post-merge duplicate check (single here; the chain nudges
--- from runSeriesChain itself).
--- @param opts table { file, title, author, ui, plugin, configuration,
---   mode = "single"|"chain" }
function XrayMerge.runPostCreateFold(opts)
    local BookGroups = require("koassistant_book_groups")
    local ActionCache = require("koassistant_action_cache")
    local XrayParser = require("koassistant_xray_parser")
    local InfoMessage = require("ui/widget/infomessage")
    local Notification = require("ui/widget/notification")
    local preds = BookGroups.predecessorsOf(opts.file)
    if #preds == 0 then return end
    local main_entry = ActionCache.getXrayCache(opts.file)
    if not (main_entry and main_entry.result and XrayParser.isJSON(main_entry.result)) then return end
    local nearest = preds[#preds]
    local nearest_entry = ActionCache.getXrayCache(nearest)
    if not (nearest_entry and nearest_entry.result and XrayParser.isJSON(nearest_entry.result)) then return end
    local nearest_title = BookGroups.displayTitle(nearest, opts.ui)
    local features = (opts.configuration and opts.configuration.features) or {}
    local provider = (opts.configuration
        and (opts.configuration.provider or opts.configuration.default_provider))
    if opts.mode == "chain" then
        local chain = {}
        for i = 1, #preds - 1 do
            local e = ActionCache.getXrayCache(preds[i])
            if e and e.result and XrayParser.isJSON(e.result) then
                chain[#chain + 1] = { file = preds[i],
                    title = BookGroups.displayTitle(preds[i], opts.ui), entry = e }
            end
        end
        chain[#chain + 1] = { file = nearest, title = nearest_title, entry = nearest_entry }
        chain[#chain + 1] = { file = opts.file, title = opts.title,
            author = opts.author, entry = main_entry }
        XrayMerge.runSeriesChain({
            chain = chain, features = features, provider = provider,
            ui = opts.ui, plugin = opts.plugin, configuration = opts.configuration,
        })
        return
    end
    if not XrayMerge.consentOk({ nearest_entry }, features, provider, nearest, opts.ui)
        or not XrayMerge.consentOk({ main_entry }, features, provider, opts.file, opts.ui) then
        UIManager:show(InfoMessage:new{
            text = _("These X-Rays were built from extracted book text. Enable \"Allow book text extraction\" (or use a trusted provider) to merge them."),
            timeout = 5,
        })
        return
    end
    UIManager:show(Notification:new{ text = T(_("Folding \"%1\" in…"), nearest_title) })
    XrayMerge.executeCrossBook({
        file = opts.file, ui = opts.ui, plugin = opts.plugin,
        configuration = opts.configuration,
        title = opts.title, author = opts.author,
        main_entry = main_entry,
        source = { file = nearest, title = nearest_title, entry = nearest_entry },
        on_done = function(ok, err)
            if ok then
                UIManager:show(Notification:new{
                    text = T(_("Folded \"%1\" into this book's X-Ray."), nearest_title),
                })
                XrayMerge.maybeOfferDedupScan(opts)
            else
                UIManager:show(InfoMessage:new{
                    text = T(_("Merge failed: %1"), tostring(err or "unknown error")),
                    timeout = 5,
                })
            end
        end,
    })
end

--- The one grouped-create case the pre-create ask cannot cover: the previous
--- book has no X-Ray at all. A post-create note names the gap (informational,
--- never a question — there is nothing to run).
--- @param opts table { file, ui }
function XrayMerge.maybeNotePredecessorGap(opts)
    local BookGroups = require("koassistant_book_groups")
    local preds, group = BookGroups.predecessorsOf(opts.file)
    if #preds == 0 then return end
    local ActionCache = require("koassistant_action_cache")
    local XrayParser = require("koassistant_xray_parser")
    local nearest = preds[#preds]
    local nearest_entry = ActionCache.getXrayCache(nearest)
    if nearest_entry and nearest_entry.result and XrayParser.isJSON(nearest_entry.result) then
        return
    end
    UIManager:show(require("ui/widget/infomessage"):new{
        text = T(_("\"%1\" (the previous book in %2) has no X-Ray yet — build one there to carry its knowledge forward."),
            BookGroups.displayTitle(nearest, opts.ui), (group and group.name) or _("this group")),
        timeout = 6,
    })
end

--- Entry point: candidate books → spoiler confirm → run.
--- @param opts table { file (target, required), ui, plugin, configuration
---   (required), title, author, close_browser, on_done(ok, err) }
function XrayMerge.startCrossBookFlow(opts)
    local ActionCache = require("koassistant_action_cache")
    local ButtonDialog = require("ui/widget/buttondialog")
    local InfoMessage = require("ui/widget/infomessage")
    local Notification = require("ui/widget/notification")
    local XrayParser = require("koassistant_xray_parser")

    -- Cross-instance staleness: the consent gates below must see CURRENT settings
    if opts.plugin and opts.plugin.updateConfigFromSettings then
        opts.plugin:updateConfigFromSettings()
    end
    -- Identity fallback from the open document (same rule as startFlow)
    if (not opts.title or opts.title == "") and opts.ui and opts.ui.doc_props
        and opts.ui.document and opts.ui.document.file == opts.file then
        opts.title = opts.ui.doc_props.display_title or opts.ui.doc_props.title
        if not opts.author or opts.author == "" then
            local authors = opts.ui.doc_props.authors or ""
            if authors:find("\n") then authors = authors:gsub("\n", ", ") end
            opts.author = authors
        end
    end
    -- Cross-book-viewed target (group nav / artifact browser): identity from
    -- the TARGET file, never the open book (item 46 follow-up)
    if not opts.title or opts.title == "" then
        opts.title = require("koassistant_book_groups").displayTitle(opts.file, opts.ui)
    end

    local main_entry = ActionCache.getXrayCache(opts.file)
    if not (main_entry and main_entry.result and XrayParser.isJSON(main_entry.result)) then
        UIManager:show(InfoMessage:new{
            text = _("This book needs a main X-Ray before another book's can be merged into it."),
            timeout = 4,
        })
        return
    end

    -- Multi-group target (round 37): the suggestion ordering needs ONE
    -- group's lens — ask which, once per flow (the pick rides opts, so the
    -- Back re-entries below keep it)
    if not opts.group_id then
        local BookGroups = require("koassistant_book_groups")
        local memberships = BookGroups.groupsFor(opts.file)
        if #memberships > 1 then
            local gdialog
            local grows = {}
            for _idx, g in ipairs(memberships) do
                local captured = g
                grows[#grows + 1] = {{
                    text = BookGroups.isOrdered(captured)
                        and T(_("%1 (book %2 of %3)"), captured.name,
                            BookGroups.positionOf(captured, opts.file) or 0, #captured.books)
                        or T(_("%1 (%2 books)"), captured.name, #captured.books),
                    align = "left",
                    callback = function()
                        UIManager:close(gdialog)
                        opts.group_id = captured.id
                        XrayMerge.startCrossBookFlow(opts)
                    end,
                }}
            end
            gdialog = ButtonDialog:new{
                title = T(_("\"%1\" is in several groups — order merge suggestions by which?"), opts.title or "?"),
                buttons = grows,
            }
            UIManager:show(gdialog)
            return
        end
    end

    -- Candidates: every book the artifact index knows about with a JSON main
    -- X-Ray (read on demand — the index only holds books WITH artifacts).
    -- Title/author follow the identity rule: the per-book AI override on the
    -- SOURCE book's sidecar dictates what the prompt calls it.
    local index = G_reader_settings:readSetting("koassistant_artifact_index") or {}
    local candidates = {}
    for path in pairs(index) do
        if path ~= opts.file then
            local ok_read, entry = pcall(ActionCache.getXrayCache, path)
            if ok_read and entry and entry.result and XrayParser.isJSON(entry.result) then
                local title, author
                local ok_ds, ds = pcall(function()
                    return require("koassistant_doc_settings").resolve(path, opts.ui)
                end)
                if ok_ds and ds then
                    local props = ds:readSetting("doc_props") or {}
                    title = props.display_title or props.title
                    author = props.authors
                    if type(author) == "string" and author:find("\n") then
                        author = author:gsub("\n", ", ")
                    end
                    local ov_t, ov_a = require("koassistant_book_settings").getMetadataOverride(ds)
                    if ov_t ~= nil then title = ov_t end
                    if ov_a ~= nil then author = ov_a end
                end
                if not title or title == "" then
                    title = path:match("([^/]+)%.[^.]+$") or path:match("([^/]+)$") or path
                end
                candidates[#candidates + 1] = {
                    file = path, title = title, author = author or "", entry = entry,
                }
            end
        end
    end
    if #candidates == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No other book has an X-Ray yet. Create one in the other book first."),
            timeout = 4,
        })
        return
    end
    table.sort(candidates, function(a, b) return (a.title or "") < (b.title or "") end)
    -- Item 46: group-aware order — predecessors first (nearest on top), then
    -- later group-mates, then everything else; annotates group_name/group_pos/
    -- group_direction for the labels and the directional warning below
    local BookGroups = require("koassistant_book_groups")
    candidates = BookGroups.orderCandidates(candidates, opts.file, nil, opts.group_id)

    local features = (opts.configuration and opts.configuration.features) or {}
    local provider = (opts.configuration
        and (opts.configuration.provider or opts.configuration.default_provider))

    local picker, other_picker
    local function closePickers()
        if picker then UIManager:close(picker) end
        if other_picker then UIManager:close(other_picker) end
    end
    -- Device round 2026-08-05 ("the menus here are really bad"): TIERED picker
    -- — the group tier (fold-all + group-mates) leads, and the index-wide
    -- list moves behind one "Other books…" row instead of burying the group
    -- rows under every X-Rayed book in the library
    local group_rows, other_rows = {}, {}
    for _idx, cand in ipairs(candidates) do
        local captured = cand
        local row_label = captured.title
            .. (captured.author ~= "" and (" (" .. captured.author .. ")") or "")
        if captured.group_name then
            -- An unordered group has no book numbers (round 27) — name it only
            row_label = row_label .. " · " .. (captured.group_pos
                and T(_("%1, book %2"), captured.group_name, captured.group_pos)
                or captured.group_name)
        end
        table.insert(captured.group_name and group_rows or other_rows, {{
            text = row_label,
            align = "left",
            callback = function()
                closePickers()
                -- Read-gate parity, PER BOOK: the source artifact and the
                -- target main are both re-sent; each book's own privacy
                -- override wins (deny beats trusted)
                if not XrayMerge.consentOk({ captured.entry }, features, provider, captured.file, opts.ui)
                    or not XrayMerge.consentOk({ main_entry }, features, provider, opts.file, opts.ui) then
                    UIManager:show(InfoMessage:new{
                        text = _("These X-Rays were built from extracted book text. Enable \"Allow book text extraction\" (or use a trusted provider) to merge them."),
                        timeout = 5,
                    })
                    return
                end
                -- Item 46: earlier feeds later — merging a LATER group-mate is
                -- legal (re-readers) but the spoiler warning names the direction
                local confirm_text = T(_("Merge the X-Ray of \"%1\" into \"%2\"?"), captured.title, opts.title or "?")
                    .. "\n" .. _("Recurring characters, places, and concepts gain that book's background. This brings in everything its X-Ray covers, including its later events. The receiving X-Ray is archived first, so this can be undone from All versions.")
                if captured.group_direction == "after" then
                    confirm_text = confirm_text .. "\n\n" .. T(_("Caution: \"%1\" comes LATER in %2 — its background includes events beyond this book."),
                        captured.title, captured.group_name)
                end
                local confirm
                confirm = ButtonDialog:new{
                    title = confirm_text,
                    buttons = {
                        {{
                            text = _("Merge"),
                            callback = function()
                                UIManager:close(confirm)
                                if opts.close_browser then opts.close_browser() end
                                XrayMerge.executeCrossBook({
                                    file = opts.file,
                                    ui = opts.ui,
                                    plugin = opts.plugin,
                                    configuration = opts.configuration,
                                    title = opts.title,
                                    author = opts.author,
                                    main_entry = main_entry,
                                    source = captured,
                                    on_done = opts.on_done or function(ok, err)
                                        if ok then
                                            UIManager:show(Notification:new{
                                                text = T(_("Merged the X-Ray of \"%1\" into this book."), captured.title),
                                            })
                                            XrayMerge.maybeOfferDedupScan(opts)
                                        else
                                            UIManager:show(InfoMessage:new{
                                                text = T(_("X-Ray merge failed: %1"), tostring(err or "unknown error")),
                                                timeout = 4,
                                            })
                                        end
                                    end,
                                })
                            end,
                        }},
                        {{
                            text = _("Back"),
                            callback = function()
                                UIManager:close(confirm)
                                -- Back one step to the book list, not abandon
                                XrayMerge.startCrossBookFlow(opts)
                            end,
                        }},
                    },
                }
                UIManager:show(confirm)
            end,
        }})
    end
    -- Item 46/49 — THE ORGANIC SERIES CHAIN (maintainer decision 2026-08-06,
    -- replacing the v1 direct-into-target fold-all): each volume's X-Ray folds
    -- into the NEXT volume's (1→2, 2→3, … N-1→N, oldest first), so EVERY
    -- volume ends up carrying its predecessors — the carry stack (verbatim
    -- labeled background + transitive ledger + alias bridge) makes each hop
    -- lossless, and archives land one-per-volume instead of piling on the
    -- last book. Both sides of every hop are re-read fresh: the previous hop
    -- just rewrote the source.
    local predecessors = {}
    for _idx, cand in ipairs(candidates) do
        if cand.group_direction == "before" then
            predecessors[#predecessors + 1] = cand
        end
    end
    table.sort(predecessors, function(a, b) return a.group_pos < b.group_pos end)
    local fold_rows = {}
    if #predecessors >= 2 then
        table.insert(fold_rows, {{
            text = T(_("Fold in earlier books (%1)…"), #predecessors),
            callback = function()
                UIManager:close(picker)
                -- Preflight disclosure (2026-08-05): the candidate list only
                -- ever holds predecessors WITH X-Rays — name the gap instead
                -- of silently skipping X-Ray-less earlier books
                local missing_n = 0
                do
                    local BG = require("koassistant_book_groups")
                    local group = (opts.group_id and BG.byId(opts.group_id))
                        or BG.groupsFor(opts.file)[1]
                    local pos = group and BG.positionOf(group, opts.file)
                    if pos then
                        missing_n = (pos - 1) - #predecessors
                        if missing_n < 0 then missing_n = 0 end
                    end
                end
                -- The chain: predecessors in reading order, this book last
                local chain = {}
                for _pidx, pre in ipairs(predecessors) do chain[#chain + 1] = pre end
                chain[#chain + 1] = { file = opts.file, title = opts.title,
                    author = opts.author, entry = main_entry }
                local n_merges = #chain - 1
                local confirm_title = T(_("Bring %1 up to date: %2 merges, oldest first — each book's X-Ray folds into the next book's (1 into 2, 2 into 3, …)?"),
                        predecessors[1].group_name, n_merges)
                    .. "\n" .. _("Every volume ends up carrying its predecessors' knowledge as labeled background. Each receiving X-Ray is archived first, so every step can be undone from that book's version list.")
                if missing_n > 0 then
                    confirm_title = confirm_title .. "\n"
                        .. T(_("Skipped: %1 earlier book(s) have no X-Ray yet."), missing_n)
                end
                local confirm
                confirm = ButtonDialog:new{
                    title = confirm_title,
                    buttons = {
                        {{ text = _("Merge the series"), callback = function()
                            UIManager:close(confirm)
                            XrayMerge.runSeriesChain({
                                chain = chain, features = features, provider = provider,
                                ui = opts.ui, plugin = opts.plugin,
                                configuration = opts.configuration,
                                close_browser = opts.close_browser,
                                on_done = opts.on_done,
                            })
                        end }},
                        {{ text = _("Back"), callback = function()
                            UIManager:close(confirm)
                            XrayMerge.startCrossBookFlow(opts)
                        end }},
                    },
                }
                UIManager:show(confirm)
            end,
        }})
    end
    -- Assembly (tiered): fold-all first, then group-mates, then the rest
    -- behind one row
    local rows = {}
    for _i, r in ipairs(fold_rows) do rows[#rows + 1] = r end
    local tgt_group = (opts.group_id and BookGroups.byId(opts.group_id))
        or BookGroups.groupsFor(opts.file)[1]
    if tgt_group and #predecessors == 0 and BookGroups.isOrdered(tgt_group) then
        -- Discoverability (device 2026-08-05): the fold-in machinery is
        -- invisible until earlier group-mates HAVE X-Rays — say why.
        -- Unordered groups (round 27) have no "earlier" at all: the absence is
        -- the design, not a gap to explain.
        rows[#rows + 1] = {{
            text = T(_("No earlier book in %1 has an X-Ray yet"), tgt_group.name),
            enabled = false,
        }}
    end
    for _i, r in ipairs(group_rows) do rows[#rows + 1] = r end
    if #group_rows > 0 and #other_rows > 0 then
        rows[#rows + 1] = {{
            text = T(_("Other books with an X-Ray (%1)…"), #other_rows),
            align = "left",
            callback = function()
                UIManager:close(picker)
                local orows = {}
                for _i, r in ipairs(other_rows) do orows[#orows + 1] = r end
                orows[#orows + 1] = {{
                    text = _("Back"),
                    callback = function()
                        UIManager:close(other_picker)
                        XrayMerge.startCrossBookFlow(opts)
                    end,
                }}
                other_picker = ButtonDialog:new{
                    title = T(_("Merge into \"%1\": other books with an X-Ray"), opts.title or "?"),
                    buttons = orows,
                }
                UIManager:show(other_picker)
            end,
        }}
    else
        for _i, r in ipairs(other_rows) do rows[#rows + 1] = r end
    end
    table.insert(rows, {{
        text = _("Manage groups…"),
        callback = function()
            UIManager:close(picker)
            require("koassistant_book_groups_ui").showManager({
                plugin = opts.plugin, ui = opts.ui,
                on_close = function() XrayMerge.startCrossBookFlow(opts) end,
            })
        end,
    }})
    table.insert(rows, {{
        text = _("Cancel"),
        callback = function() UIManager:close(picker) end,
    }})
    picker = ButtonDialog:new{
        -- Naming the TARGET matters: this flow can be launched from another
        -- book's X-Ray via group navigation — "this book" would be ambiguous
        title = T(_("Merge into \"%1\": pick the book to fold in"), opts.title or "?"),
        buttons = rows,
    }
    UIManager:show(picker)
    logger.info("KOAssistant XrayMerge: cross-book picker with", #candidates, "candidates for", opts.file)
end

return XrayMerge
