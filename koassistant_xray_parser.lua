--- X-Ray JSON parser and renderer
--- Pure data module: no UI dependencies.
--- Handles JSON parsing, markdown rendering, character search, and chapter matching.

local json = require("json")
local logger = require("logger")
local _ = require("koassistant_gettext")
local T = require("ffi/util").template
local JsonRepair = require("koassistant_json_repair")

local XrayParser = {}

-- Arabic diacritics normalization constants (built once)
-- All use string.char() for Lua 5.1 compatibility (no \xNN escapes)
local ARABIC_QUICK_CHECK_D8 = string.char(0xD8)
local ARABIC_QUICK_CHECK_D9 = string.char(0xD9)
local ARABIC_QUICK_CHECK_DB = string.char(0xDB)
-- Tashkeel: U+064B-U+065F (fathah, dammah, kasrah, shadda, sukun, etc.)
local TASHKEEL_PAT = string.char(0xD9) .. "[" .. string.char(0x8B) .. "-" .. string.char(0x9F) .. "]"
-- Quranic annotation signs: U+0610-U+061A
local SIGN_PAT = string.char(0xD8) .. "[" .. string.char(0x90) .. "-" .. string.char(0x9A) .. "]"
-- Quranic marks: U+06D6-U+06DC
local QURAN_MARK_PAT1 = string.char(0xDB) .. "[" .. string.char(0x96) .. "-" .. string.char(0x9C) .. "]"
-- Extended Quranic marks: U+06DE-U+06ED (includes U+06E1 small sukun)
local QURAN_MARK_PAT2 = string.char(0xDB) .. "[" .. string.char(0x9E) .. "-" .. string.char(0xAD) .. "]"
-- Individual characters to strip/replace
local SUPERSCRIPT_ALEF = string.char(0xD9, 0xB0)  -- U+0670 (dagger alef → regular alef)
local TATWEEL          = string.char(0xD9, 0x80)   -- U+0640
local WORD_JOINER      = string.char(0xE2, 0x81, 0xA0) -- U+2060
-- Alef normalization: variants → regular alef (U+0627)
local ALEF             = string.char(0xD8, 0xA7)   -- U+0627 regular alef
local ALEF_WASLA       = string.char(0xD9, 0xB1)   -- U+0671
local ALEF_MADDA       = string.char(0xD8, 0xA2)   -- U+0622
local ALEF_HAMZA_ABOVE = string.char(0xD8, 0xA3)   -- U+0623
local ALEF_HAMZA_BELOW = string.char(0xD8, 0xA5)   -- U+0625
-- Tanwin fathah + alef: accusative ending ًا — strip before tashkeel removal
local TANWIN_FATHAH_ALEF = string.char(0xD9, 0x8B, 0xD8, 0xA7) -- U+064B + U+0627

--- Normalize Arabic text for fuzzy matching.
--- Strips diacritical marks (tashkeel), Quranic annotation marks,
--- and normalizes alef variants to regular alef.
--- No-op on non-Arabic text (fast byte check).
--- @param str string Input string (typically already lowered)
--- @return string Normalized string
function XrayParser.normalizeArabic(str)
    if not str or str == "" then return str end
    -- Quick check: skip if no Arabic-range leading bytes present
    if not str:find(ARABIC_QUICK_CHECK_D8, 1, true)
        and not str:find(ARABIC_QUICK_CHECK_D9, 1, true)
        and not str:find(ARABIC_QUICK_CHECK_DB, 1, true) then
        return str
    end
    -- Strip tanwin fathah + alef (accusative ending ًا) before tashkeel removal,
    -- so "نَارًا" normalizes to "نار" not "نارا"
    str = str:gsub(TANWIN_FATHAH_ALEF, "")
    -- Strip combining marks
    str = str:gsub(TASHKEEL_PAT, "")
    str = str:gsub(SIGN_PAT, "")
    str = str:gsub(QURAN_MARK_PAT1, "")
    str = str:gsub(QURAN_MARK_PAT2, "")
    str = str:gsub(SUPERSCRIPT_ALEF, ALEF)
    str = str:gsub(TATWEEL, "")
    str = str:gsub(WORD_JOINER, "")
    -- Normalize alef variants to regular alef
    str = str:gsub(ALEF_WASLA, ALEF)
    str = str:gsub(ALEF_MADDA, ALEF)
    str = str:gsub(ALEF_HAMZA_ABOVE, ALEF)
    str = str:gsub(ALEF_HAMZA_BELOW, ALEF)
    return str
end

--- Check whether a string contains Arabic script characters.
--- @param str string
--- @return boolean
function XrayParser.containsArabic(str)
    if not str then return false end
    -- Arabic block leading bytes: 0xD8 covers U+0600-U+063F, 0xD9 covers U+0640-U+067F
    return str:find(ARABIC_QUICK_CHECK_D8, 1, true) ~= nil
        or str:find(ARABIC_QUICK_CHECK_D9, 1, true) ~= nil
end

-- SRELL optional combining marks class: tashkeel + superscript alef +
-- Quranic signs + Quranic marks + tatweel + ZWJ/ZWNJ + word joiner
local SRELL_OPT_MARKS = "[\\u064B-\\u065F\\u0670\\u0610-\\u061A\\u06D6-\\u06ED\\u0640\\u200C-\\u200D\\u2060]*"
-- Alef variants: match any alef form in the document
local SRELL_ALEF_CLASS = "[\\u0627\\u0671\\u0622\\u0623\\u0625]"
-- Arabic definite article ال (UTF-8)
local AL_PREFIX = string.char(0xD8, 0xA7, 0xD9, 0x84)
local AL_PREFIX_LEN = #AL_PREFIX

--- Convert a normalized Arabic string to a SRELL regex with optional combining marks.
--- @param normalized string Already-normalized Arabic text
--- @return string regex SRELL regex pattern
local function arabicToRegex(normalized)
    local parts = {}
    local i = 1
    local len = #normalized

    while i <= len do
        local b = normalized:byte(i)
        if b < 128 then
            if b == 0x20 then
                parts[#parts + 1] = "\\s+"
            else
                local ch = normalized:sub(i, i)
                if ch:match("[%.%+%*%?%[%]%^%$%(%)%{%}%|\\]") then
                    parts[#parts + 1] = "\\" .. ch
                else
                    parts[#parts + 1] = ch
                end
            end
            i = i + 1
        elseif b >= 0xC0 and b < 0xE0 then
            local b2 = normalized:byte(i + 1)
            if not b2 then break end
            local cp = (b - 0xC0) * 64 + (b2 - 0x80)
            if cp >= 0x0600 and cp <= 0x06FF then
                if cp == 0x0627 then
                    -- Alef: optional group — dagger alef (U+0670) in Quranic text
                    -- is consumed by preceding OPT_MARKS, so the full alef letter
                    -- may be absent. Making it optional lets "الغاشية" match "ٱلۡغَٰشِيَةِ".
                    parts[#parts + 1] = "(?:" .. SRELL_ALEF_CLASS .. SRELL_OPT_MARKS .. ")?"
                else
                    parts[#parts + 1] = string.format("\\u%04X", cp) .. SRELL_OPT_MARKS
                end
            else
                parts[#parts + 1] = string.format("\\u%04X", cp)
            end
            i = i + 2
        elseif b >= 0xE0 and b < 0xF0 then
            local b2, b3 = normalized:byte(i + 1), normalized:byte(i + 2)
            if not b2 or not b3 then break end
            local cp = (b - 0xE0) * 4096 + (b2 - 0x80) * 64 + (b3 - 0x80)
            parts[#parts + 1] = string.format("\\u%04X", cp)
            i = i + 3
        elseif b >= 0xF0 then
            i = i + 4
        else
            i = i + 1
        end
    end

    return table.concat(parts)
end

--- Strip Arabic definite article ال from the beginning and after spaces.
--- @param normalized string Already-normalized Arabic text
--- @return string stripped Text with ال removed, or original if no ال found
local function stripArabicArticle(normalized)
    local stripped = normalized
    if stripped:sub(1, AL_PREFIX_LEN) == AL_PREFIX then
        stripped = stripped:sub(AL_PREFIX_LEN + 1)
    end
    stripped = stripped:gsub(" " .. AL_PREFIX, " ")
    return stripped
end

--- Build a diacritics-tolerant regex for searching Arabic text.
--- Converts an Arabic search term into a SRELL-compatible regex where each
--- Arabic letter is followed by an optional combining marks class, so that
--- "الفلق" matches "ٱلْفَلَقِ" in diacritized text.
--- Also includes an ال-stripped alternative so "النادي" matches "نَادِيَهُۥ".
--- Returns nil for non-Arabic terms (caller should use plain search).
--- @param term string The search term
--- @return string|nil regex SRELL regex pattern, or nil if not Arabic
function XrayParser.buildArabicSearchRegex(term)
    if not term or term == "" then return nil end
    if not XrayParser.containsArabic(term) then return nil end

    local normalized = XrayParser.normalizeArabic(term:lower())
    local regex = arabicToRegex(normalized)

    -- Also match without ال (definite article) on each word
    local stripped = stripArabicArticle(normalized)
    if stripped ~= normalized and #stripped > 4 then
        regex = regex .. "|" .. arabicToRegex(stripped)
    end

    return regex
end

-- AI responses sometimes return strings for array fields. Normalize to table.
local function ensure_array(val)
    if type(val) == "table" then return val end
    if type(val) == "string" and val ~= "" then return { val } end
    return nil
end

--- Detect whether a cache result string is JSON or legacy markdown
--- Checks for raw JSON, code-fenced JSON, and JSON preceded by text
--- @param result string The cached result text
--- @return boolean is_json True if result appears to be JSON
function XrayParser.isJSON(result)
    if type(result) ~= "string" then return false end
    -- Raw JSON starting with {
    if result:match("^%s*{") then return true end
    -- Code-fenced JSON (```json ... ``` or ``` { ... ```)
    if result:match("```json%s*{") or result:match("```%s*{") then return true end
    -- JSON embedded after some preamble text (look for { within first 200 chars)
    local first_brace = result:find("{")
    if first_brace and first_brace <= 200 then return true end
    return false
end

-- Known category keys for validating parsed X-Ray data
local FICTION_KEYS = { "characters", "locations", "themes", "lexicon", "timeline", "reader_engagement", "current_state", "conclusion" }
local NONFICTION_KEYS = { "key_figures", "locations", "core_concepts", "arguments", "terminology", "argument_development", "reader_engagement", "current_position", "conclusion" }
local ACADEMIC_KEYS = { "key_concepts", "foundations", "methodology", "findings", "referenced_works", "technical_terms", "figures_data", "reader_engagement", "current_position", "conclusion" }

-- Build normalized key → canonical key map for fuzzy matching.
-- Normalizing = lowercase + strip separators (_, -, spaces).
-- Catches all variants: camelCase, PascalCase, kebab-case, concatenated, etc.
local CANONICAL_KEY_MAP = {}
local function normalizeKeyString(key)
    return key:lower():gsub("[_%- ]", "")
end
for _idx, key in ipairs(FICTION_KEYS) do
    CANONICAL_KEY_MAP[normalizeKeyString(key)] = key
end
for _idx, key in ipairs(NONFICTION_KEYS) do
    CANONICAL_KEY_MAP[normalizeKeyString(key)] = key
end
for _idx, key in ipairs(ACADEMIC_KEYS) do
    CANONICAL_KEY_MAP[normalizeKeyString(key)] = key
end

--- Normalize AI-hallucinated key variants to canonical names in-place.
--- Uses normalize-based matching: lowercase + strip separators → match canonical.
--- Unknown keys that don't match any canonical key are silently ignored.
--- @param data table Candidate parsed data
local function normalizeKeyAliases(data)
    if type(data) ~= "table" then return end
    local to_rename = {}
    for key, value in pairs(data) do
        if type(key) == "string" then
            local canonical = CANONICAL_KEY_MAP[normalizeKeyString(key)]
            if canonical and canonical ~= key and not data[canonical] then
                to_rename[key] = { canonical = canonical, value = value }
            end
        end
    end
    for old_key, info in pairs(to_rename) do
        data[info.canonical] = info.value
        data[old_key] = nil
    end
end

-- ============== Parse-time shape normalization (#90 field report) ==============
-- Weak models emit structurally creative JSON: objects where strings belong
-- ({"name": "X", "relationship": "friend"} inside connections), bare strings
-- where objects belong (a timeline of plain strings rendered every Story Arc
-- row as "Unknown"), maps where arrays belong, numbers for strings. Downstream
-- code concatenates these; a single table element crashed renderToMarkdown in
-- an update's on_complete — losing the merged result AND taking KOReader down
-- (issue #90 crash.log 2026-08-07). Normalize once at parse so every consumer
-- (render, browser rows, search, entity index) sees canonical shapes.
-- Well-formed data passes through unchanged; stored artifacts heal on read.

-- Best-effort string coercion for a value that should have been a string.
local function coerceText(val)
    if type(val) == "string" then return val end
    if type(val) == "number" then return tostring(val) end
    if type(val) == "table" then
        -- Objects: prefer the identity fields models actually emit
        local name
        for _idx, f in ipairs({ "name", "term", "event", "text", "title" }) do
            if type(val[f]) == "string" and val[f] ~= "" then
                name = val[f]
                break
            end
        end
        if name then
            local rel = type(val.relationship) == "string" and val.relationship ~= ""
                and val.relationship
                or type(val.role) == "string" and val.role ~= "" and val.role
            if rel then
                return name .. " (" .. rel .. ")"
            end
            return name
        end
        if type(val.description) == "string" and val.description ~= "" then
            return val.description
        end
        -- Last resort: join the object's string values (sorted — pairs order
        -- is nondeterministic and this must be stable across re-parses)
        local parts = {}
        for _k, v in pairs(val) do
            if type(v) == "string" and v ~= "" then parts[#parts + 1] = v end
        end
        table.sort(parts)
        if #parts > 0 then return table.concat(parts, " — ") end
    end
    return nil
end

-- Coerce a should-be-array-of-strings; nil when nothing survives.
local function coerceStringArray(val)
    if type(val) == "string" then
        return val ~= "" and { val } or nil
    end
    if type(val) ~= "table" then return nil end
    local out = {}
    for _idx, v in ipairs(val) do
        local s = coerceText(v)
        if s and s ~= "" then out[#out + 1] = s end
    end
    return #out > 0 and out or nil
end

-- Keep only well-formed background lines ({ source, text [, file] } — the
-- code-owned cross-book shape). Malformed lines are dropped, never coerced.
local function sanitizeBackground(val)
    if type(val) ~= "table" then return nil end
    local out = {}
    for _idx, b in ipairs(val) do
        if type(b) == "table" and type(b.text) == "string" and b.text ~= "" then
            out[#out + 1] = {
                source = type(b.source) == "string" and b.source ~= "" and b.source or "?",
                text = b.text,
                file = type(b.file) == "string" and b.file ~= "" and b.file or nil,
            }
        end
    end
    return #out > 0 and out or nil
end

-- Fields normalized on every entity/event item
local ITEM_STRING_FIELDS = { "name", "term", "event", "role", "description",
    "significance", "importance", "details", "definition", "evidence", "chapter" }
local ITEM_ARRAY_FIELDS = { "aliases", "connections", "references", "characters" }
-- Categories keyed by something other than `name`
local ENTITY_NAME_FIELD = {
    lexicon = "term", terminology = "term", technical_terms = "term",
    timeline = "event", argument_development = "event",
}
local SINGLETON_KEYS = { current_state = true, current_position = true, conclusion = true }
local SINGLETON_ARRAY_FIELDS = { "conflicts", "questions", "questions_addressed",
    "building_toward", "resolutions", "themes_resolved", "key_findings", "implications" }

local function normalizeItem(item, name_field)
    if type(item) == "string" then
        if item == "" then return nil end
        return { [name_field] = item }
    end
    if type(item) ~= "table" then return nil end
    for _idx, f in ipairs(ITEM_STRING_FIELDS) do
        if item[f] ~= nil and type(item[f]) ~= "string" then
            item[f] = coerceText(item[f])
        end
    end
    for _idx, f in ipairs(ITEM_ARRAY_FIELDS) do
        if item[f] ~= nil then
            item[f] = coerceStringArray(item[f])
        end
    end
    if item.background ~= nil then
        item.background = sanitizeBackground(item.background)
    end
    return item
end

--- Normalize category shapes in-place. Idempotent; runs on every successful
--- parse (fresh responses AND stored artifacts). `__dormant` is deliberately
--- untouched — it is code-owned and never model-shaped.
--- @param data table Parsed X-Ray data (mutated)
local function normalizeShapes(data)
    if type(data) ~= "table" then return end
    local seen = {}
    for _i, list in ipairs({ FICTION_KEYS, NONFICTION_KEYS, ACADEMIC_KEYS }) do
        for _j, key in ipairs(list) do
            if not seen[key] then
                seen[key] = true
                local val = data[key]
                if SINGLETON_KEYS[key] then
                    if type(val) == "string" and val ~= "" then
                        val = { summary = val }
                        data[key] = val
                    end
                    if type(val) == "table" then
                        if val.summary ~= nil and type(val.summary) ~= "string" then
                            val.summary = coerceText(val.summary)
                        end
                        for _k, f in ipairs(SINGLETON_ARRAY_FIELDS) do
                            if val[f] ~= nil then val[f] = coerceStringArray(val[f]) end
                        end
                    end
                elseif key == "reader_engagement" then
                    if type(val) == "table" then
                        if val.patterns ~= nil and type(val.patterns) ~= "string" then
                            val.patterns = coerceText(val.patterns)
                        end
                        if val.connections ~= nil and type(val.connections) ~= "string" then
                            val.connections = coerceText(val.connections)
                        end
                        -- notable_highlights: strings AND {passage, why_notable}
                        -- objects are both legal shapes — coerce fields, drop junk
                        if val.notable_highlights ~= nil then
                            local out
                            if type(val.notable_highlights) == "table" then
                                out = {}
                                for _n, h in ipairs(val.notable_highlights) do
                                    if type(h) == "string" then
                                        if h ~= "" then out[#out + 1] = h end
                                    elseif type(h) == "table" then
                                        local passage = coerceText(h.passage)
                                        if passage and passage ~= "" then
                                            out[#out + 1] = { passage = passage,
                                                why_notable = coerceText(h.why_notable) }
                                        end
                                    end
                                end
                            end
                            val.notable_highlights = out and #out > 0 and out or nil
                        end
                    end
                elseif type(val) == "table" then
                    -- Entity/event array category
                    local name_field = ENTITY_NAME_FIELD[key] or "name"
                    local out = {}
                    for _n, item in ipairs(val) do
                        local norm = normalizeItem(item, name_field)
                        if norm then out[#out + 1] = norm end
                    end
                    -- Map-instead-of-array salvage ({"Name": {...}, ...}):
                    -- entries keyed by entity name, no array part at all
                    if #out == 0 and next(val) ~= nil then
                        local names = {}
                        for k, v in pairs(val) do
                            if type(k) == "string" and k ~= "" and type(v) == "table" then
                                names[#names + 1] = k
                            end
                        end
                        table.sort(names)
                        for _n, k in ipairs(names) do
                            local v = val[k]
                            if type(v[name_field]) ~= "string" or v[name_field] == "" then
                                v[name_field] = k
                            end
                            local norm = normalizeItem(v, name_field)
                            if norm then out[#out + 1] = norm end
                        end
                    end
                    data[key] = out
                end
            end
        end
    end
    -- Cross-book merge deltas: background_updates pairs
    if type(data.background_updates) == "table" then
        local out = {}
        for _n, upd in ipairs(data.background_updates) do
            if type(upd) == "table" then
                if upd.name ~= nil and type(upd.name) ~= "string" then
                    upd.name = coerceText(upd.name)
                end
                if upd.background ~= nil and type(upd.background) ~= "string" then
                    upd.background = coerceText(upd.background)
                end
                if upd.aliases ~= nil then
                    upd.aliases = coerceStringArray(upd.aliases)
                end
                out[#out + 1] = upd
            end
        end
        data.background_updates = out
    end
end

--- Check if a table looks like valid X-Ray data (has at least one recognized category key)
--- Also infers and sets the type field if missing.
--- @param data table Candidate parsed data
--- @return boolean valid True if data has recognized X-Ray structure
local function isValidXrayData(data)
    if type(data) ~= "table" then return false end
    -- Check for error response
    if data.error then return true end
    -- Normalize common key variants before checking
    normalizeKeyAliases(data)
    -- Cross-book merge deltas (item 44) may carry ONLY mechanical background
    -- updates — recognize them so such a delta parses without a category key
    if type(data.background_updates) == "table" then return true end
    -- Check for fiction keys
    for _idx, key in ipairs(FICTION_KEYS) do
        if data[key] then
            if not data.type then data.type = "fiction" end
            return true
        end
    end
    -- Check for academic keys (before nonfiction: unique keys come first in array)
    for _idx, key in ipairs(ACADEMIC_KEYS) do
        if data[key] then
            if not data.type then data.type = "academic" end
            return true
        end
    end
    -- Check for non-fiction keys
    for _idx, key in ipairs(NONFICTION_KEYS) do
        if data[key] then
            if not data.type then data.type = "nonfiction" end
            return true
        end
    end
    return false
end

--- Attempt to extract valid JSON from a potentially wrapped response
--- Tries: raw decode, code fence stripping, first-brace-to-last-brace extraction
--- Accepts any table with recognized X-Ray category keys (type field inferred if missing).
--- @param text string The raw AI response
--- @return table|nil data Parsed Lua table, or nil on failure
--- @return string|nil err Error message if all attempts failed
function XrayParser.parse(text)
    if type(text) ~= "string" or text == "" then
        return nil, "empty input"
    end

    -- Attempt 1: direct decode
    local ok, data = pcall(json.decode, text)
    if ok and isValidXrayData(data) then
        normalizeShapes(data)
        return data, nil
    end

    -- Attempt 2: strip markdown code fences (find-based to cross newlines)
    local fence_open = text:find("```json%s*\n") or text:find("```%s*\n")
    local content_start
    if fence_open then
        content_start = text:find("\n", fence_open) + 1
        -- Find the LAST ``` after the opening fence (handles trailing text after fence)
        local fence_close
        local search_pos = content_start
        while true do
            local pos = text:find("\n%s*```", search_pos)
            if pos then
                fence_close = pos
                search_pos = pos + 4
            else
                break
            end
        end
        if fence_close then
            local stripped = text:sub(content_start, fence_close - 1)
            ok, data = pcall(json.decode, stripped)
            if ok and isValidXrayData(data) then
                normalizeShapes(data)
                return data, nil
            end
        end
    end

    -- Attempt 3: extract from first { to last }
    -- If code fence was found, start after it (skip thinking text braces before fence)
    local first_brace = text:find("{", content_start or 1)
    -- Scan backwards (Lua's .* doesn't cross newlines)
    local last_brace
    for i = #text, 1, -1 do
        if text:byte(i) == 125 then -- }
            last_brace = i
            break
        end
    end
    local extracted
    if first_brace and last_brace and last_brace > first_brace then
        extracted = text:sub(first_brace, last_brace)
        ok, data = pcall(json.decode, extracted)
        if ok and isValidXrayData(data) then
            normalizeShapes(data)
            return data, nil
        end
    end

    -- Attempt 4: repair unescaped inner double quotes (a model can leave a raw " inside a
    -- description or alias), then retry the best candidate. Only reached after strict parsing
    -- failed, so it can't make a parseable response worse.
    local candidate = extracted or text
    ok, data = pcall(json.decode, JsonRepair.escapeInnerQuotes(candidate))
    if ok and isValidXrayData(data) then
        logger.dbg("XrayParser: parsed via unescaped-quote repair")
        normalizeShapes(data)
        return data, nil
    end

    return nil, "failed to parse JSON from response"
end

--- True when a model response is well-formed JSON that carries NO X-Ray
--- content — `{}`, `{"background_updates": []}`, `{"characters": []}`, or any
--- object whose every value is an empty table/string. Round 28 (#90 device
--- report: merging two unrelated books reported "response is not a valid
--- X-Ray JSON structure"): for the cross-book merge an empty delta is the
--- CORRECT answer for books that share nothing, but `{}` fails
--- isValidXrayData (no recognized key) and so was indistinguishable from
--- garbage. Callers use this to tell "nothing to merge" from "bad response".
--- @param text string Raw model output
--- @return boolean
function XrayParser.isEmptyDelta(text)
    if type(text) ~= "string" or text == "" then return false end
    local candidate = text
    -- Same fence tolerance as parse()
    local fence_open = text:find("```json%s*\n") or text:find("```%s*\n")
    if fence_open then
        local content_start = text:find("\n", fence_open)
        if content_start then
            local rest = text:sub(content_start + 1)
            local fence_close = rest:find("```")
            candidate = fence_close and rest:sub(1, fence_close - 1) or rest
        end
    end
    local first_brace = candidate:find("{")
    local last_brace
    for i = #candidate, 1, -1 do
        if candidate:byte(i) == 125 then last_brace = i break end
    end
    if not (first_brace and last_brace and last_brace > first_brace) then return false end
    local ok, data = pcall(json.decode, candidate:sub(first_brace, last_brace))
    if not ok or type(data) ~= "table" then return false end
    for _key, value in pairs(data) do
        if type(value) == "table" then
            if next(value) ~= nil then return false end
        elseif type(value) == "string" then
            if value ~= "" then return false end
        elseif value ~= nil then
            return false
        end
    end
    return true
end

--- Check if X-Ray data is fiction type
--- Falls back to key-based detection if type field is missing
--- @param data table Parsed X-Ray data
--- @return boolean
function XrayParser.isFiction(data)
    if data.type then return data.type == "fiction" end
    -- Infer from keys: fiction has "characters", nonfiction has "key_figures"
    return data.characters ~= nil
end

--- Check if X-Ray data is academic type
--- Falls back to key-based detection if type field is missing
--- @param data table Parsed X-Ray data
--- @return boolean
function XrayParser.isAcademic(data)
    if data.type then return data.type == "academic" end
    -- Infer from keys: academic has "key_concepts" and "methodology"
    return data.key_concepts ~= nil and data.methodology ~= nil
end

--- Get the key used for characters/figures in this X-Ray type
--- @param data table Parsed X-Ray data
--- @return string key "characters" for fiction, "key_figures" for non-fiction
function XrayParser.getCharacterKey(data)
    return XrayParser.isFiction(data) and "characters" or "key_figures"
end

--- Get characters/figures array from X-Ray data
--- @param data table Parsed X-Ray data
--- @return table characters Array of character/figure entries
function XrayParser.getCharacters(data)
    local key = XrayParser.getCharacterKey(data)
    return data[key] or {}
end

--- Get the searchable name for an item (name, term, or event depending on type)
--- @param item table An X-Ray item entry
--- @return string|nil name The name to search for, or nil
local function getItemSearchName(item)
    return item.name or item.term or item.event
end

--- Count occurrences of a single item (name + aliases) in pre-lowered text.
--- Finds all match spans from name and aliases, merges overlapping spans,
--- and returns the total unique matches (union semantics, same as regex OR).
--- @param item table An X-Ray item entry (must have name/term/event and optionally aliases)
--- @param text_lower string Already-lowered text to search
--- @return number count Unique match count across name and all aliases (0 if not found or name ≤2 chars)
function XrayParser.countItemOccurrences(item, text_lower)
    local name = getItemSearchName(item)
    if not name or #name <= 2 then return 0 end

    local name_lower = name:lower()

    -- Collect all search terms
    local terms = {}

    -- Handle parenthetical names: "Theosis (Deification)" → "theosis" + "deification"
    local clean_name = name_lower:gsub("%s*%(.-%)%s*", "")
    clean_name = clean_name:match("^%s*(.-)%s*$") or clean_name  -- trim
    local paren_content = name_lower:match("%((.-)%)")

    terms[#terms + 1] = (#clean_name > 2) and clean_name or name_lower

    if paren_content and #paren_content > 2 and not paren_content:match("^%d+$") then
        terms[#terms + 1] = paren_content
    end

    local item_aliases = ensure_array(item.aliases)
    if item_aliases then
        for _idx, alias in ipairs(item_aliases) do
            if #alias > 2 then
                terms[#terms + 1] = alias:lower()
            end
        end
    end

    -- Normalize terms for Arabic diacritics matching
    for i = 1, #terms do
        terms[i] = XrayParser.normalizeArabic(terms[i])
    end

    -- Arabic: also try matching without ال (definite article) on each word.
    -- "النادي" won't substring-match "ناديه" but "نادي" will.
    local term_count = #terms
    for i = 1, term_count do
        local t = terms[i]
        if XrayParser.containsArabic(t) then
            local stripped = stripArabicArticle(t)
            if stripped ~= t and #stripped > 4 then
                terms[#terms + 1] = stripped
            end
        end
    end

    -- Collect all match spans from all terms
    local all_spans = {}
    for _idx, term in ipairs(terms) do
        local spans = XrayParser._collectMatchSpans(text_lower, term)
        for _idx2, span in ipairs(spans) do
            all_spans[#all_spans + 1] = span
        end
    end

    if #all_spans == 0 then return 0 end
    if #all_spans == 1 then return 1 end

    -- Sort by start position
    table.sort(all_spans, function(a, b)
        return a[1] < b[1]
    end)

    -- Merge overlapping spans and count unique matches
    local count = 1
    local current_end = all_spans[1][2]
    for i = 2, #all_spans do
        if all_spans[i][1] > current_end then
            -- No overlap: new distinct match
            count = count + 1
            current_end = all_spans[i][2]
        elseif all_spans[i][2] > current_end then
            -- Overlapping: extend current span (don't increment count)
            current_end = all_spans[i][2]
        end
    end

    return count
end

--- Singleton categories not useful for chapter text matching
local SINGLETON_CATEGORIES = {
    current_state = true,
    current_position = true,
    reader_engagement = true,
    conclusion = true,
}

--- Categories excluded from chapter text matching
--- Event-based categories have descriptive phrases as "names" (not searchable entity names),
--- which produces misleading counts (e.g., "Chapter 5 describes..." matching common words)
local TEXT_MATCH_EXCLUDED = {
    current_state = true,
    current_position = true,
    reader_engagement = true,
    conclusion = true,
    arguments = true,
    argument_development = true,
    timeline = true,
    findings = true,
    figures_data = true,
}
-- Exported: the marks scan's rebuild diagnostics tally what this gate
-- skipped (slice 2 round 5)
XrayParser.TEXT_MATCH_EXCLUDED = TEXT_MATCH_EXCLUDED

--- Resolve a connection/reference string to any X-Ray item
--- Searches all categories: characters, locations, concepts, themes, etc.
--- Connection strings follow the format "Name (relationship)" or just "Name"
--- @param data table Parsed X-Ray data
--- @param connection_string string e.g. "Elizabeth Bennet (love interest)" or "Constantinople"
--- @return table|nil result { item, category_key, name_portion, relationship } or nil if not found
function XrayParser.resolveConnection(data, connection_string)
    if not connection_string or connection_string == "" then return nil end

    -- Extract name portion: everything before the last " (" or the whole string
    local name_portion = connection_string:match("^(.-)%s*%(") or connection_string
    name_portion = name_portion:match("^%s*(.-)%s*$")  -- trim

    -- Extract relationship if present
    local relationship = connection_string:match("%((.-)%)")

    if not name_portion or name_portion == "" then return nil end

    local categories = XrayParser.getCategories(data)
    local normalize = XrayParser.normalizeArabic
    local name_lower = normalize(name_portion:lower())

    -- Build flat list of searchable items with their category keys
    -- Skip singleton categories (current_state, current_position, reader_engagement)
    local searchable = {}
    for _idx, cat in ipairs(categories) do
        if not SINGLETON_CATEGORIES[cat.key] then
            for _idx2, item in ipairs(cat.items) do
                table.insert(searchable, { item = item, category_key = cat.key })
            end
        end
    end

    if #searchable == 0 then return nil end

    -- Pass 1: exact name match (name, term, or event)
    for _idx, entry in ipairs(searchable) do
        local item_name = getItemSearchName(entry.item)
        if item_name and normalize(item_name:lower()) == name_lower then
            return { item = entry.item, category_key = entry.category_key,
                     name_portion = name_portion, relationship = relationship }
        end
    end

    -- Pass 2: alias match (characters/key_figures only)
    for _idx, entry in ipairs(searchable) do
        local aliases = ensure_array(entry.item.aliases)
        if aliases then
            for _idx2, alias in ipairs(aliases) do
                if normalize(alias:lower()) == name_lower then
                    return { item = entry.item, category_key = entry.category_key,
                             name_portion = name_portion, relationship = relationship }
                end
            end
        end
    end

    -- Pass 3: substring match on name (e.g., "Elizabeth" matches "Elizabeth Bennet")
    for _idx, entry in ipairs(searchable) do
        local item_name = getItemSearchName(entry.item)
        if item_name and normalize(item_name:lower()):find(name_lower, 1, true) then
            return { item = entry.item, category_key = entry.category_key,
                     name_portion = name_portion, relationship = relationship }
        end
    end

    return nil
end

--- Get category definitions for building menus
--- @param data table Parsed X-Ray data
--- @return table categories Array of {key, label, items, singular_label}
function XrayParser.getCategories(data)
    if XrayParser.isAcademic(data) then
        local cats = {
            { key = "key_concepts",     label = _("Key Concepts"),     items = data.key_concepts or {} },
            { key = "foundations",       label = _("Foundations"),      items = data.foundations or {} },
            { key = "methodology",      label = _("Methodology"),      items = data.methodology or {} },
            { key = "findings",         label = _("Findings"),         items = data.findings or {} },
            { key = "referenced_works", label = _("Referenced Works"), items = data.referenced_works or {} },
            { key = "technical_terms",  label = _("Technical Terms"),  items = data.technical_terms or {} },
            { key = "figures_data",     label = _("Figures & Data"),   items = data.figures_data or {} },
        }
        if data.reader_engagement then
            table.insert(cats, { key = "reader_engagement", label = _("Reader Engagement"), items = { data.reader_engagement } })
        end
        if data.conclusion then
            table.insert(cats, { key = "conclusion", label = _("Conclusion"), items = { data.conclusion } })
        elseif data.current_position then
            table.insert(cats, { key = "current_position", label = _("Current Position"), items = { data.current_position } })
        end
        return cats
    elseif XrayParser.isFiction(data) then
        local cats = {
            { key = "characters",    label = _("Cast"),          items = data.characters or {} },
            { key = "locations",     label = _("World"),         items = data.locations or {} },
            { key = "themes",        label = _("Ideas"),         items = data.themes or {} },
            { key = "lexicon",       label = _("Lexicon"),       items = data.lexicon or {} },
            { key = "timeline",      label = _("Story Arc"),     items = data.timeline or {} },
        }
        if data.reader_engagement then
            table.insert(cats, { key = "reader_engagement", label = _("Reader Engagement"), items = { data.reader_engagement } })
        end
        -- Complete X-Ray uses conclusion; incremental uses current_state
        if data.conclusion then
            table.insert(cats, { key = "conclusion", label = _("Conclusion"), items = { data.conclusion } })
        elseif data.current_state then
            table.insert(cats, { key = "current_state", label = _("Current State"), items = { data.current_state } })
        end
        return cats
    else
        local cats = {
            { key = "key_figures",          label = _("Key Figures"),          items = data.key_figures or {} },
            { key = "locations",            label = _("Locations"),            items = data.locations or {} },
            { key = "core_concepts",        label = _("Core Concepts"),        items = data.core_concepts or {} },
            { key = "arguments",            label = _("Arguments"),            items = data.arguments or {} },
            { key = "terminology",          label = _("Terminology"),          items = data.terminology or {} },
            { key = "argument_development", label = _("Argument Development"), items = data.argument_development or {} },
        }
        if data.reader_engagement then
            table.insert(cats, { key = "reader_engagement", label = _("Reader Engagement"), items = { data.reader_engagement } })
        end
        -- Complete X-Ray uses conclusion; incremental uses current_position
        if data.conclusion then
            table.insert(cats, { key = "conclusion", label = _("Conclusion"), items = { data.conclusion } })
        elseif data.current_position then
            table.insert(cats, { key = "current_position", label = _("Current Position"), items = { data.current_position } })
        end
        return cats
    end
end

-- Categories that never count as browsable X-Ray content
local NON_ENTITY_KEYS = {
    current_state = true, current_position = true,
    conclusion = true, reader_engagement = true,
}

--- True when parsed data holds at least one entry in any entity/event
--- category. A response that parses but fails this (e.g. a lone
--- current_state, seen from weak models — #90 field report) is not a usable
--- X-Ray CREATE and must not become the artifact. Round 28.
--- @param data table Parsed X-Ray data
--- @return boolean
function XrayParser.hasEntityContent(data)
    if type(data) ~= "table" then return false end
    for _idx, cat in ipairs(XrayParser.getCategories(data)) do
        if not NON_ENTITY_KEYS[cat.key] and type(cat.items) == "table" and #cat.items > 0 then
            return true
        end
    end
    return false
end

--- Round 28 (#90): background is code-owned end-to-end — attached by the
--- cross-book machinery, never model-authored. A model that has SEEN the
--- lines (any prompt carrying artifact JSON) can echo them back mangled or
--- self-labeled, and a rewrite carrying a background field replaces the
--- mechanical one in the merge. Strip every background field from a parsed
--- MODEL RESPONSE before it meets a merge. Never run on stored artifacts.
--- @param data table Freshly parsed model response (mutated)
function XrayParser.dropModelBackground(data)
    if type(data) ~= "table" then return end
    for _idx, cat in ipairs(XrayParser.getCategories(data)) do
        if type(cat.items) == "table" then
            for _idx2, item in ipairs(cat.items) do
                if type(item) == "table" then item.background = nil end
            end
        end
    end
end

--- Get the display name for an item depending on category
--- @param item table The item entry
--- @param category_key string The category key
--- @return string name The display name
function XrayParser.getItemName(item, category_key)
    if category_key == "lexicon" or category_key == "terminology" or category_key == "technical_terms" then
        return item.term or _("Unknown")
    end
    if category_key == "timeline" or category_key == "argument_development" then
        return item.event or _("Unknown")
    end
    if category_key == "reader_engagement" then
        return _("Reader Engagement")
    end
    if category_key == "conclusion" then
        return _("Conclusion")
    end
    return item.name or _("Unknown")
end

--- Merge user-defined aliases into parsed X-Ray data (mutates in place)
--- @param data table Parsed X-Ray data
--- @param user_aliases table Mapping of item name → array of alias strings
--- @return table data The mutated data (for chaining)
function XrayParser.mergeUserAliases(data, user_aliases)
    if not user_aliases or not next(user_aliases) then
        return data
    end
    if not data or type(data) ~= "table" then
        return data
    end

    -- Build case-insensitive lookup: name_lower → { add = {...}, ignore = {...} }
    local lookup = {}
    for name, entry in pairs(user_aliases) do
        if name and type(entry) == "table" then
            local add = entry.add or {}
            local ignore = entry.ignore or {}
            if #add > 0 or #ignore > 0 then
                lookup[name:lower()] = entry
            end
        end
    end
    if not next(lookup) then return data end

    local categories = XrayParser.getCategories(data)
    for _idx, cat in ipairs(categories) do
        for _idx2, item in ipairs(cat.items) do
            local item_name = XrayParser.getItemName(item, cat.key)
            if item_name then
                local user_entry = lookup[item_name:lower()]
                if user_entry then
                    local existing = ensure_array(item.aliases) or {}

                    -- Build ignore set (case-insensitive)
                    local ignore_set = {}
                    for _idx3, ignored in ipairs(user_entry.ignore or {}) do
                        ignore_set[ignored:lower()] = true
                    end

                    -- Remove ignored aliases
                    if next(ignore_set) then
                        local filtered = {}
                        for _idx3, alias in ipairs(existing) do
                            if not ignore_set[alias:lower()] then
                                table.insert(filtered, alias)
                            end
                        end
                        existing = filtered
                    end

                    -- Add user aliases (dedup, case-insensitive)
                    local existing_lower = {}
                    for _idx3, alias in ipairs(existing) do
                        existing_lower[alias:lower()] = true
                    end
                    for _idx3, user_alias in ipairs(user_entry.add or {}) do
                        if not existing_lower[user_alias:lower()] then
                            table.insert(existing, user_alias)
                            existing_lower[user_alias:lower()] = true
                        end
                    end

                    item.aliases = existing
                end
            end
        end
    end

    return data
end

--- Get the secondary text for an item (used as subtitle or mandatory text)
--- @param item table The item entry
--- @param category_key string The category key
--- @return string secondary The secondary display text
function XrayParser.getItemSecondary(item, category_key)
    if category_key == "characters" or category_key == "key_figures" or category_key == "referenced_works" then
        return item.role or ""
    end
    if category_key == "timeline" or category_key == "argument_development" then
        return item.chapter or ""
    end
    if category_key == "lexicon" or category_key == "terminology" or category_key == "technical_terms" then
        return ""
    end
    if category_key == "reader_engagement" then
        return ""
    end
    return ""
end

--- Format a single item's detail text for display
--- @param item table The item entry
--- @param category_key string The category key
--- @return string detail Formatted detail text
function XrayParser.formatItemDetail(item, category_key)
    local parts = {}

    if category_key == "characters" or category_key == "key_figures" or category_key == "referenced_works" then
        local name = item.name or _("Unknown")
        local role = item.role or ""
        if role ~= "" then
            table.insert(parts, name .. " (" .. role .. ")")
        else
            table.insert(parts, name)
        end
        table.insert(parts, "")

        local aliases = ensure_array(item.aliases)
        if aliases and #aliases > 0 then
            table.insert(parts, _("Also known as:") .. " " .. table.concat(aliases, ", "))
            table.insert(parts, "")
        end

        if item.description and item.description ~= "" then
            table.insert(parts, item.description)
            table.insert(parts, "")
        end

        local connections = ensure_array(item.connections)
        if connections and #connections > 0 then
            table.insert(parts, _("Connections:") .. " " .. table.concat(connections, ", "))
        end

    elseif category_key == "locations" or category_key == "core_concepts"
        or category_key == "key_concepts" or category_key == "foundations"
        or category_key == "methodology" or category_key == "figures_data" then
        table.insert(parts, item.name or _("Unknown"))
        table.insert(parts, "")
        if item.description and item.description ~= "" then
            table.insert(parts, item.description)
            table.insert(parts, "")
        end
        if item.details and item.details ~= "" then
            table.insert(parts, _("Details:") .. " " .. item.details)
            table.insert(parts, "")
        end
        local sig = item.significance or item.importance
        if sig and sig ~= "" then
            table.insert(parts, _("Significance:") .. " " .. sig)
            table.insert(parts, "")
        end
        local refs = ensure_array(item.references)
        if refs and #refs > 0 then
            table.insert(parts, _("References:") .. " " .. table.concat(refs, ", "))
        end

    elseif category_key == "themes" or category_key == "arguments" or category_key == "findings" then
        table.insert(parts, item.name or _("Unknown"))
        table.insert(parts, "")
        if item.description and item.description ~= "" then
            table.insert(parts, item.description)
            table.insert(parts, "")
        end
        if item.evidence and item.evidence ~= "" then
            table.insert(parts, _("Evidence:") .. " " .. item.evidence)
            table.insert(parts, "")
        end
        if item.significance and item.significance ~= "" then
            table.insert(parts, _("Significance:") .. " " .. item.significance)
            table.insert(parts, "")
        end
        local refs = ensure_array(item.references)
        if refs and #refs > 0 then
            table.insert(parts, _("References:") .. " " .. table.concat(refs, ", "))
        end

    elseif category_key == "lexicon" or category_key == "terminology" or category_key == "technical_terms" then
        table.insert(parts, item.term or _("Unknown"))
        table.insert(parts, "")
        if item.definition and item.definition ~= "" then
            table.insert(parts, item.definition)
        end

    elseif category_key == "timeline" or category_key == "argument_development" then
        local event = item.event or _("Unknown")
        local chapter = item.chapter or ""
        if chapter ~= "" then
            table.insert(parts, chapter .. ": " .. event)
        else
            table.insert(parts, event)
        end
        table.insert(parts, "")
        if item.significance and item.significance ~= "" then
            table.insert(parts, item.significance)
            table.insert(parts, "")
        end
        local characters = ensure_array(item.characters) or ensure_array(item.references)
        if characters and #characters > 0 then
            table.insert(parts, _("Characters:") .. " " .. table.concat(characters, ", "))
        end

    elseif category_key == "reader_engagement" then
        if item.patterns and item.patterns ~= "" then
            table.insert(parts, _("Patterns:") .. " " .. item.patterns)
            table.insert(parts, "")
        end
        local notable = ensure_array(item.notable_highlights)
        if notable then
            table.insert(parts, _("Notable highlights:"))
            for _idx, h in ipairs(notable) do
                if type(h) == "table" then
                    local passage = h.passage or ""
                    local why = h.why_notable or ""
                    if passage ~= "" then
                        table.insert(parts, "- \"" .. passage .. "\"")
                        if why ~= "" then
                            table.insert(parts, "  " .. why)
                        end
                    end
                elseif type(h) == "string" and h ~= "" then
                    table.insert(parts, "- " .. h)
                end
            end
            table.insert(parts, "")
        end
        if item.connections and item.connections ~= "" then
            table.insert(parts, _("Connections:") .. " " .. item.connections)
        end

    elseif category_key == "current_state" or category_key == "current_position" then
        if item.summary and item.summary ~= "" then
            table.insert(parts, item.summary)
            table.insert(parts, "")
        end
        local conflicts = ensure_array(item.conflicts)
        if conflicts and #conflicts > 0 then
            table.insert(parts, _("Active conflicts:"))
            for _idx, c in ipairs(conflicts) do
                table.insert(parts, "- " .. c)
            end
            table.insert(parts, "")
        end
        local questions = ensure_array(item.questions) or ensure_array(item.questions_addressed)
        if questions and #questions > 0 then
            local label = category_key == "current_position"
                and _("Questions addressed:") or _("Unanswered questions:")
            table.insert(parts, label)
            for _idx, q in ipairs(questions) do
                table.insert(parts, "- " .. q)
            end
            table.insert(parts, "")
        end
        local building = ensure_array(item.building_toward)
        if building and #building > 0 then
            table.insert(parts, _("Building toward:"))
            for _idx, b in ipairs(building) do
                table.insert(parts, "- " .. b)
            end
        end

    elseif category_key == "conclusion" then
        if item.summary and item.summary ~= "" then
            table.insert(parts, item.summary)
            table.insert(parts, "")
        end
        -- Fiction fields
        local resolutions = ensure_array(item.resolutions)
        if resolutions and #resolutions > 0 then
            table.insert(parts, _("Resolutions:"))
            for _idx, r in ipairs(resolutions) do
                table.insert(parts, "- " .. r)
            end
            table.insert(parts, "")
        end
        local themes_resolved = ensure_array(item.themes_resolved)
        if themes_resolved and #themes_resolved > 0 then
            table.insert(parts, _("Themes resolved:"))
            for _idx, t in ipairs(themes_resolved) do
                table.insert(parts, "- " .. t)
            end
            table.insert(parts, "")
        end
        -- Non-fiction fields
        local key_findings = ensure_array(item.key_findings)
        if key_findings and #key_findings > 0 then
            table.insert(parts, _("Key findings:"))
            for _idx, f in ipairs(key_findings) do
                table.insert(parts, "- " .. f)
            end
            table.insert(parts, "")
        end
        local implications = ensure_array(item.implications)
        if implications and #implications > 0 then
            table.insert(parts, _("Implications:"))
            for _idx, i in ipairs(implications) do
                table.insert(parts, "- " .. i)
            end
            table.insert(parts, "")
        end
    end

    -- Show aliases for any category that has them (characters/key_figures handle it above)
    if category_key ~= "characters" and category_key ~= "key_figures" then
        local aliases = ensure_array(item.aliases)
        if aliases and #aliases > 0 then
            table.insert(parts, "")
            table.insert(parts, _("Also known as:") .. " " .. table.concat(aliases, ", "))
        end
    end

    -- Cross-book background (item 44): attached mechanically by the merge,
    -- shown for any category that carries it
    if type(item.background) == "table" then
        for _idx, b in ipairs(item.background) do
            if type(b) == "table" and type(b.text) == "string" and b.text ~= "" then
                if #parts > 0 and parts[#parts] ~= "" then table.insert(parts, "") end
                table.insert(parts, T(_("Background — \"%1\": %2"), b.source or "?", b.text))
            end
        end
    end

    return table.concat(parts, "\n")
end

--- Append machine-facing background lines (cross-book merge, item 44) for one
--- item to a markdown line buffer. English labels like the rest of the render.
local function insertBackgroundLines(lines, item)
    if type(item.background) ~= "table" then return end
    for _idx, b in ipairs(item.background) do
        if type(b) == "table" and type(b.text) == "string" and b.text ~= "" then
            table.insert(lines, "*Background — \"" .. (b.source or "?") .. "\": " .. b.text .. "*")
        end
    end
end

--- Render structured X-Ray data to readable markdown
--- Produces output matching the established X-Ray style for display in chat and {xray_cache_section}
--- @param data table Parsed X-Ray JSON
--- @param title string Book title (optional, for header)
--- @param progress string Reading progress e.g. "42%" (optional, for header)
--- @return string markdown Rendered markdown text
function XrayParser.renderToMarkdown(data, title, progress)
    local lines = {}

    -- Header
    local header = "# Reader's Companion"
    if title and title ~= "" then
        header = header .. ": " .. title
    end
    if progress and progress ~= "" then
        if progress == "Complete" or progress == "100%" then
            header = header .. " (Complete)"
        else
            header = header .. " (Through " .. progress .. ")"
        end
    end
    table.insert(lines, header)
    table.insert(lines, "")

    local type_label
    if XrayParser.isAcademic(data) then
        type_label = "ACADEMIC"
    elseif XrayParser.isFiction(data) then
        type_label = "FICTION"
    else
        type_label = "NON-FICTION"
    end
    table.insert(lines, "**Type: " .. type_label .. "**")
    table.insert(lines, "")

    local categories = XrayParser.getCategories(data)
    for _idx, cat in ipairs(categories) do
        if cat.items and #cat.items > 0 then
            table.insert(lines, "## " .. cat.label)

            if cat.key == "current_state" or cat.key == "current_position" or cat.key == "conclusion" then
                -- Current state / conclusion: render inline
                local state = cat.items[1]
                if state.summary and state.summary ~= "" then
                    table.insert(lines, state.summary)
                    table.insert(lines, "")
                end
                -- current_state fields
                local s_conflicts = ensure_array(state.conflicts)
                if s_conflicts and #s_conflicts > 0 then
                    for _idx2, c in ipairs(s_conflicts) do
                        table.insert(lines, "- " .. c)
                    end
                    table.insert(lines, "")
                end
                local s_questions = ensure_array(state.questions) or ensure_array(state.questions_addressed)
                if s_questions and #s_questions > 0 then
                    for _idx2, q in ipairs(s_questions) do
                        table.insert(lines, "- " .. q)
                    end
                    table.insert(lines, "")
                end
                local s_building = ensure_array(state.building_toward)
                if s_building and #s_building > 0 then
                    for _idx2, b in ipairs(s_building) do
                        table.insert(lines, "- " .. b)
                    end
                    table.insert(lines, "")
                end
                -- conclusion fields (fiction)
                local s_resolutions = ensure_array(state.resolutions)
                if s_resolutions and #s_resolutions > 0 then
                    for _idx2, r in ipairs(s_resolutions) do
                        table.insert(lines, "- " .. r)
                    end
                    table.insert(lines, "")
                end
                local s_themes = ensure_array(state.themes_resolved)
                if s_themes and #s_themes > 0 then
                    for _idx2, t in ipairs(s_themes) do
                        table.insert(lines, "- " .. t)
                    end
                    table.insert(lines, "")
                end
                -- conclusion fields (non-fiction)
                local s_findings = ensure_array(state.key_findings)
                if s_findings and #s_findings > 0 then
                    for _idx2, f in ipairs(s_findings) do
                        table.insert(lines, "- " .. f)
                    end
                    table.insert(lines, "")
                end
                local s_implications = ensure_array(state.implications)
                if s_implications and #s_implications > 0 then
                    for _idx2, i in ipairs(s_implications) do
                        table.insert(lines, "- " .. i)
                    end
                    table.insert(lines, "")
                end
            elseif cat.key == "characters" or cat.key == "key_figures" or cat.key == "referenced_works" then
                for _idx2, char in ipairs(cat.items) do
                    local entry = "**" .. (char.name or "Unknown") .. "**"
                    local desc_parts = {}
                    if char.role and char.role ~= "" then
                        table.insert(desc_parts, char.role)
                    end
                    if char.description and char.description ~= "" then
                        table.insert(desc_parts, char.description)
                    end
                    if #desc_parts > 0 then
                        entry = entry .. ": " .. table.concat(desc_parts, ". ")
                    end
                    table.insert(lines, entry)

                    local c_aliases = ensure_array(char.aliases)
                    if c_aliases and #c_aliases > 0 then
                        table.insert(lines, "*(Also known as: " .. table.concat(c_aliases, ", ") .. ")*")
                    end
                    local c_connections = ensure_array(char.connections)
                    if c_connections and #c_connections > 0 then
                        table.insert(lines, "*Connections: " .. table.concat(c_connections, ", ") .. "*")
                    end
                    insertBackgroundLines(lines, char)
                    table.insert(lines, "")
                end
            elseif cat.key == "locations" or cat.key == "core_concepts"
                or cat.key == "key_concepts" or cat.key == "foundations"
                or cat.key == "methodology" or cat.key == "figures_data" then
                for _idx2, loc in ipairs(cat.items) do
                    local entry = "**" .. (loc.name or "Unknown") .. "**"
                    local desc = loc.description or ""
                    local sig = loc.significance or loc.importance or ""
                    local detail_parts = {}
                    if desc ~= "" then table.insert(detail_parts, desc) end
                    if loc.details and loc.details ~= "" then table.insert(detail_parts, loc.details) end
                    if sig ~= "" then table.insert(detail_parts, sig) end
                    if #detail_parts > 0 then
                        entry = entry .. ": " .. table.concat(detail_parts, ". ")
                    end
                    table.insert(lines, entry)
                    local l_refs = ensure_array(loc.references)
                    if l_refs and #l_refs > 0 then
                        table.insert(lines, "*References: " .. table.concat(l_refs, ", ") .. "*")
                    end
                    insertBackgroundLines(lines, loc)
                    table.insert(lines, "")
                end
            elseif cat.key == "themes" or cat.key == "arguments" or cat.key == "findings" then
                for _idx2, theme in ipairs(cat.items) do
                    local entry = "**" .. (theme.name or "Unknown") .. "**"
                    if theme.description and theme.description ~= "" then
                        entry = entry .. ": " .. theme.description
                    end
                    if theme.evidence and theme.evidence ~= "" then
                        entry = entry .. " " .. theme.evidence
                    end
                    if theme.significance and theme.significance ~= "" then
                        entry = entry .. " " .. theme.significance
                    end
                    table.insert(lines, entry)
                    local t_refs = ensure_array(theme.references)
                    if t_refs and #t_refs > 0 then
                        table.insert(lines, "*References: " .. table.concat(t_refs, ", ") .. "*")
                    end
                    insertBackgroundLines(lines, theme)
                    table.insert(lines, "")
                end
            elseif cat.key == "lexicon" or cat.key == "terminology" or cat.key == "technical_terms" then
                for _idx2, term in ipairs(cat.items) do
                    local entry = "**" .. (term.term or "Unknown") .. "**"
                    if term.definition and term.definition ~= "" then
                        entry = entry .. ": " .. term.definition
                    end
                    table.insert(lines, entry)
                    insertBackgroundLines(lines, term)
                    table.insert(lines, "")
                end
            elseif cat.key == "timeline" or cat.key == "argument_development" then
                for _idx2, event in ipairs(cat.items) do
                    local prefix = ""
                    if event.chapter and event.chapter ~= "" then
                        prefix = "**" .. event.chapter .. ":** "
                    else
                        prefix = "- "
                    end
                    local entry = prefix .. (event.event or "Unknown")
                    if event.significance and event.significance ~= "" then
                        entry = entry .. ": " .. event.significance
                    end
                    local e_characters = ensure_array(event.characters) or ensure_array(event.references)
                    if e_characters and #e_characters > 0 then
                        entry = entry .. " [" .. table.concat(e_characters, ", ") .. "]"
                    end
                    table.insert(lines, "- " .. entry)
                end
                table.insert(lines, "")
            elseif cat.key == "reader_engagement" then
                local engagement = cat.items[1]
                if engagement.patterns and engagement.patterns ~= "" then
                    table.insert(lines, engagement.patterns)
                    table.insert(lines, "")
                end
                local r_notable = ensure_array(engagement.notable_highlights)
                if r_notable and #r_notable > 0 then
                    for _idx2, h in ipairs(r_notable) do
                        if type(h) == "table" then
                            local passage = h.passage or ""
                            local why = h.why_notable or ""
                            if passage ~= "" then
                                table.insert(lines, "- \"" .. passage .. "\"")
                                if why ~= "" then
                                    table.insert(lines, "  " .. why)
                                end
                            end
                        elseif type(h) == "string" and h ~= "" then
                            table.insert(lines, "- " .. h)
                        end
                    end
                    table.insert(lines, "")
                end
                if engagement.connections and engagement.connections ~= "" then
                    table.insert(lines, "*" .. engagement.connections .. "*")
                    table.insert(lines, "")
                end
            end
        end
    end

    -- Belt over the parse-time normalization: a non-string line (unforeseen
    -- shape reaching a raw insert) must cost that line, never the render —
    -- a table here crashed table.concat mid-response (#90 crash.log)
    for i, v in ipairs(lines) do
        if type(v) ~= "string" then lines[i] = "" end
    end
    return table.concat(lines, "\n")
end

--- Search characters/figures by query string
--- Matches against name, aliases, and description (case-insensitive)
--- @param data table Parsed X-Ray data
--- @param query string Search term
--- @return table results Array of {item, match_field} sorted by match quality
function XrayParser.searchCharacters(data, query)
    if not query or query == "" then return {} end

    local characters = XrayParser.getCharacters(data)
    if not characters or #characters == 0 then return {} end

    local query_lower = XrayParser.normalizeArabic(query:lower())
    local results = {}

    local normalize = XrayParser.normalizeArabic
    for _idx, char in ipairs(characters) do
        local match_field = nil

        -- Check name (highest priority)
        if char.name and normalize(char.name:lower()):find(query_lower, 1, true) then
            match_field = "name"
        end

        -- Check aliases
        local s_aliases = ensure_array(char.aliases)
        if not match_field and s_aliases then
            for _idx2, alias in ipairs(s_aliases) do
                if normalize(alias:lower()):find(query_lower, 1, true) then
                    match_field = "alias"
                    break
                end
            end
        end

        -- Check description (lowest priority)
        if not match_field and char.description then
            if normalize(char.description:lower()):find(query_lower, 1, true) then
                match_field = "description"
            end
        end

        if match_field then
            table.insert(results, { item = char, match_field = match_field })
        end
    end

    -- Sort: name matches first, then alias, then description
    local priority = { name = 1, alias = 2, description = 3 }
    table.sort(results, function(a, b)
        return (priority[a.match_field] or 9) < (priority[b.match_field] or 9)
    end)

    return results
end

--- Search across all categories (name, term, event, description, etc.)
--- @param data table Parsed X-Ray data
--- @param query string Search query
--- @param opts table|nil Options: skip_description (bool) to search name+alias only
--- @return table results Array of {item, category_key, category_label, match_field}
function XrayParser.searchAll(data, query, opts)
    if not query or query == "" then return {} end
    local skip_description = opts and opts.skip_description
    -- exact: a handle must BE the query, not merely contain it — the #63
    -- conditional bypass gate ("of" substring-hits inside names, and a
    -- bypass that steals every word from the dictionary is broken); implies
    -- descriptions never match
    local exact = opts and opts.exact
    if exact then skip_description = true end

    local categories = XrayParser.getCategories(data)
    local query_lower = XrayParser.normalizeArabic(query:lower())
    local normalize = XrayParser.normalizeArabic
    -- Arabic: also try ال-stripped query so "النار" finds "نار" and vice versa
    local query_stripped = nil
    if XrayParser.containsArabic(query_lower) then
        local s = stripArabicArticle(query_lower)
        if s ~= query_lower and #s > 4 then query_stripped = s end
    end
    local results = {}

    for _idx, cat in ipairs(categories) do
        -- Skip singleton categories (not useful in search)
        if cat.key ~= "current_state" and cat.key ~= "current_position"
            and cat.key ~= "reader_engagement" and cat.key ~= "conclusion" then
            for _idx2, item in ipairs(cat.items) do
                local match_field = nil
                -- Check primary name/term/event
                local name = item.name or item.term or item.event or ""
                if name ~= "" then
                    local n = normalize(name:lower())
                    if exact then
                        if n == query_lower
                            or (query_stripped and n == query_stripped) then
                            match_field = "name"
                        end
                    elseif n:find(query_lower, 1, true)
                        or (query_stripped and n:find(query_stripped, 1, true)) then
                        match_field = "name"
                    end
                end
                -- Check aliases
                local i_aliases = ensure_array(item.aliases)
                if not match_field and i_aliases then
                    for _idx3, alias in ipairs(i_aliases) do
                        local a = normalize(alias:lower())
                        if exact then
                            if a == query_lower
                                or (query_stripped and a == query_stripped) then
                                match_field = "alias"
                                break
                            end
                        elseif a:find(query_lower, 1, true)
                            or (query_stripped and a:find(query_stripped, 1, true)) then
                            match_field = "alias"
                            break
                        end
                    end
                end
                -- Check description/definition/significance
                if not match_field and not skip_description then
                    local desc = item.description or item.definition or item.significance or ""
                    if desc ~= "" then
                        local d = normalize(desc:lower())
                        if d:find(query_lower, 1, true)
                            or (query_stripped and d:find(query_stripped, 1, true)) then
                            match_field = "description"
                        end
                    end
                end
                if match_field then
                    table.insert(results, {
                        item = item,
                        category_key = cat.key,
                        category_label = cat.label,
                        match_field = match_field,
                    })
                end
            end
        end
    end

    -- Sort: name matches first, then alias, then description
    local priority = { name = 1, alias = 2, description = 3 }
    table.sort(results, function(a, b)
        return (priority[a.match_field] or 9) < (priority[b.match_field] or 9)
    end)

    return results
end

-- One normalization for handle-vs-selection equality: lower + Arabic
-- normalize + whitespace collapse + trim (selections and JSON handles both
-- carry stray spacing).
local function exactKey(s)
    s = XrayParser.normalizeArabic(s:lower()):gsub("\194\160", " "):gsub("%s+", " ")
    return s:match("^%s*(.-)%s*$") or s
end

--- Fold every exact-matchable handle (name/term/event + aliases) of data's
--- entities into `set`. Each handle folds BOTH its raw form and its
--- parenthetical-stripped form — the SAME reduction collectSearchTerms
--- applies for marking/searching, so anything the marks layer underlines is
--- reachable by selecting exactly the underlined words (device 2026-08-14:
--- entity "Poison container (giftbeholder)" was marked as "Poison
--- container" but the raw-handle-only set refused the selection). Skips the
--- singleton categories searchAll skips. Feeds the memoized route index
--- behind the selection intercept (slice 2, ref #63).
--- @param data table Parsed X-Ray data (user aliases already merged)
--- @param set table Accumulator: normalized handle -> true
function XrayParser.foldExactHandles(data, set)
    local function fold(h)
        if type(h) ~= "string" or h == "" then return end
        local k = exactKey(h)
        if k ~= "" then set[k] = true end
        -- Parenthetical-stripped variant: "Theosis (Deification)" → "Theosis"
        local stripped = h:gsub("%s*%(.-%)%s*", " ")
        if stripped ~= h then
            k = exactKey(stripped)
            if k ~= "" then set[k] = true end
        end
    end
    for _idx, cat in ipairs(XrayParser.getCategories(data) or {}) do
        if cat.key ~= "current_state" and cat.key ~= "current_position"
            and cat.key ~= "reader_engagement" and cat.key ~= "conclusion" then
            for _idx2, item in ipairs(cat.items) do
                fold(item.name or item.term or item.event)
                local aliases = ensure_array(item.aliases)
                if aliases then
                    for _idx3, a in ipairs(aliases) do
                        fold(a)
                    end
                end
            end
        end
    end
end

--- The query-side mirror against a foldExactHandles set: normalized
--- equality, plus the ال-stripped query variant for Arabic (query side only
--- — the handle side is never article-stripped, matching searchAll's exact
--- mode).
--- @param set table foldExactHandles accumulator
--- @param query string Raw query text
--- @return boolean
function XrayParser.matchExactHandle(set, query)
    if type(query) ~= "string" or query == "" then return false end
    local q = exactKey(query)
    if q == "" then return false end
    if set[q] then return true end
    if XrayParser.containsArabic(q) then
        local s = stripArabicArticle(q)
        if s ~= q and #s > 4 and set[s] then return true end
    end
    return false
end

--- Entity name + aliases as search terms: array of { text, regex } — regex =
--- the Arabic diacritics-tolerant pattern where applicable (EPUB engine
--- only). Rules: parenthetical strip, >2 chars, case-insensitive dedupe,
--- substring-minimal set (a term containing another term is dropped — the
--- short form already finds every occurrence of the long one, and keeping
--- both would double-count the same physical mention). Moved here from the
--- browser (slice 2) so the mention lists, the native-search launches AND
--- ambient marking share one term truth.
--- @param item table X-Ray entity item
--- @param item_title string|nil Fallback title when the item has no name
--- @return table terms Array of { text, regex? }
function XrayParser.collectSearchTerms(item, item_title)
    local terms, seen = {}, {}
    local function add(t)
        if type(t) ~= "string" then return end
        -- Strip parenthetical: "Theosis (Deification)" → "Theosis"
        t = t:gsub("%s*%(.-%)%s*", " ")
        t = t:match("^%s*(.-)%s*$") or ""
        if #t > 2 then
            local k = t:lower()
            if not seen[k] then
                seen[k] = true
                table.insert(terms, {
                    text = t,
                    regex = XrayParser.buildArabicSearchRegex(t),
                })
            end
        end
    end
    add(item.name or item.term or item.event or item_title)
    local aliases = item.aliases
    if type(aliases) == "string" then aliases = { aliases } end
    if type(aliases) == "table" then
        for _idx, a in ipairs(aliases) do add(a) end
    end
    local minimal = {}
    for i, t in ipairs(terms) do
        local contains_other = false
        local t_lower = t.text:lower()
        for j, u in ipairs(terms) do
            if i ~= j and #u.text < #t.text
                and t_lower:find(u.text:lower(), 1, true) then
                contains_other = true
                break
            end
        end
        if not contains_other then table.insert(minimal, t) end
    end
    return minimal
end

--- Ambient-marking entity list (slice 2, ref #78): one entry per markable
--- entity with its collectSearchTerms terms, its CATEGORY_FAMILY family
--- (unmapped categories are their own family) and a normalized variant of
--- each term for the cheap page-presence pre-check. Category gate =
--- TEXT_MATCH_EXCLUDED, the same truth countItemOccurrences uses.
--- @param data table Parsed X-Ray data (user aliases already merged)
--- @return table entities Array of { name, category_key, family, terms }
function XrayParser.buildMarkEntities(data)
    local out = {}
    for _idx, cat in ipairs(XrayParser.getCategories(data) or {}) do
        if not TEXT_MATCH_EXCLUDED[cat.key] then
            for _idx2, item in ipairs(cat.items) do
                local terms = XrayParser.collectSearchTerms(item, nil)
                if #terms > 0 then
                    for _idx3, t in ipairs(terms) do
                        -- Whitespace-collapsed (NBSP too) to match the
                        -- layout-text haystack the marks scan collapses the
                        -- same way (line wraps arrive as newlines there)
                        t.norm = XrayParser.normalizeArabic(t.text:lower())
                            :gsub("\194\160", " "):gsub("%s+", " ")
                    end
                    table.insert(out, {
                        name = XrayParser.getItemName(item, cat.key),
                        category_key = cat.key,
                        family = XrayParser.CATEGORY_FAMILY[cat.key] or cat.key,
                        terms = terms,
                    })
                end
            end
        end
    end
    return out
end

--- Find all X-Ray items appearing in chapter text
--- @param data table Parsed X-Ray data
--- @param chapter_text string The chapter text content
--- @return table results Array of {item, category_key, category_label, count} sorted by count desc
function XrayParser.findItemsInChapter(data, chapter_text)
    if not chapter_text or chapter_text == "" then return {} end

    local categories = XrayParser.getCategories(data)
    if not categories or #categories == 0 then return {} end

    local text_lower = XrayParser.normalizeArabic(chapter_text:lower())
    local results = {}

    for _idx, cat in ipairs(categories) do
        if not TEXT_MATCH_EXCLUDED[cat.key] then
            for _idx2, item in ipairs(cat.items) do
                local count = XrayParser.countItemOccurrences(item, text_lower)
                if count > 0 then
                    table.insert(results, {
                        item = item,
                        category_key = cat.key,
                        category_label = cat.label,
                        count = count,
                    })
                end
            end
        end
    end

    -- Sort by mention count descending
    table.sort(results, function(a, b)
        return a.count > b.count
    end)

    return results
end

--- Find characters appearing in chapter text using fuzzy name+alias matching
--- @param data table Parsed X-Ray data
--- @param chapter_text string The chapter text content
--- @return table results Array of {item, count} sorted by mention frequency (descending)
function XrayParser.findCharactersInChapter(data, chapter_text)
    if not chapter_text or chapter_text == "" then return {} end

    local characters = XrayParser.getCharacters(data)
    if not characters or #characters == 0 then return {} end

    local text_lower = XrayParser.normalizeArabic(chapter_text:lower())
    local results = {}

    for _idx, char in ipairs(characters) do
        local best_count = XrayParser.countItemOccurrences(char, text_lower)
        if best_count > 0 then
            table.insert(results, { item = char, count = best_count })
        end
    end

    -- Sort by mention count descending
    table.sort(results, function(a, b)
        return a.count > b.count
    end)

    return results
end

--- Check if an ASCII byte is a word character (letter or digit).
--- @param b number Byte value (must be < 128)
--- @return boolean
local function isAsciiWordByte(b)
    if b >= 48 and b <= 57 then return true end   -- 0-9
    if b >= 65 and b <= 90 then return true end   -- A-Z
    if b >= 97 and b <= 122 then return true end  -- a-z
    return false
end

--- Check if the character at a text position is a word character for boundary detection.
--- For ASCII bytes: checks letters and digits.
--- For multi-byte UTF-8: decodes the codepoint and checks known non-word ranges
--- (General Punctuation, Latin-1 symbols, CJK symbols, etc.).
--- @param text string The text
--- @param pos number Byte position to check
--- @param scan_back boolean If true, pos may be a continuation byte (last byte of preceding
---   character); scans back up to 3 bytes to find the leading byte and decode.
--- @return boolean true if it's a word character
local function isWordCharAt(text, pos, scan_back)
    local b = text:byte(pos)
    if not b then return false end

    -- ASCII: simple byte check
    if b < 128 then return isAsciiWordByte(b) end

    -- Multi-byte UTF-8: find the leading byte
    local lead_pos = pos
    if scan_back and b < 0xC0 then
        -- Continuation byte (0x80-0xBF): scan back to find leading byte
        for i = 1, 3 do
            local p = pos - i
            if p < 1 then return true end  -- Can't decode, assume word
            local pb = text:byte(p)
            if pb >= 0xC0 then lead_pos = p; break end
            if pb < 0x80 then return true end  -- Hit ASCII, malformed; assume word
        end
    end

    -- Decode codepoint from leading byte
    local lb = text:byte(lead_pos)
    if not lb or lb < 0xC0 then return true end  -- Can't decode, assume word
    local cp
    if lb < 0xE0 then
        -- 2-byte: U+0080-U+07FF (Latin Extended, Cyrillic, Arabic, Hebrew, etc.)
        local b2 = text:byte(lead_pos + 1)
        if not b2 then return true end
        cp = (lb - 0xC0) * 64 + (b2 - 0x80)
    elseif lb < 0xF0 then
        -- 3-byte: U+0800-U+FFFF (CJK, General Punctuation, symbols, etc.)
        local b2, b3 = text:byte(lead_pos + 1), text:byte(lead_pos + 2)
        if not b2 or not b3 then return true end
        cp = (lb - 0xE0) * 4096 + (b2 - 0x80) * 64 + (b3 - 0x80)
    else
        -- 4-byte: emoji/supplementary — treat as non-word boundary
        return false
    end

    -- Check known non-word Unicode ranges (punctuation, symbols, spaces)
    if cp >= 0x2000 and cp <= 0x206F then return false end  -- General Punctuation (smart quotes, dashes, ellipsis)
    if cp >= 0x00A0 and cp <= 0x00BF then return false end  -- Latin-1 symbols (guillemets, ©, etc.)
    if cp >= 0x2E00 and cp <= 0x2E7F then return false end  -- Supplemental Punctuation
    if cp >= 0x3000 and cp <= 0x303F then return false end  -- CJK Symbols and Punctuation

    -- Everything else (accented letters, Cyrillic, Greek, etc.): word character
    return true
end

--- Check if needle should skip word-boundary checking.
--- Returns true for scripts where byte-level boundary detection is unreliable:
--- - CJK/Thai (3+ byte UTF-8, leading byte >= 0xE0): no word-boundary spaces
--- - Arabic/Hebrew/Syriac (2-byte UTF-8, leading bytes 0xD6-0xDB): have spaces but
---   multi-byte punctuation (،؛؟) makes byte-level boundary check unreliable
--- Latin/Cyrillic/Greek (leading bytes 0xC0-0xD5) still use boundary checking.
--- @param str string Text to check
--- @return boolean
local function skipBoundaryCheck(str)
    for i = 1, #str do
        local b = str:byte(i)
        if b >= 0xE0 then return true end           -- CJK, Thai, etc.
        if b >= 0xD6 and b <= 0xDB then return true end  -- Arabic, Hebrew, Syriac
    end
    return false
end

--- Collect match spans of a substring in text (plain search).
--- For Latin/Cyrillic/Greek: uses word-boundary matching to prevent false positives.
--- For CJK/Thai/Arabic/Hebrew: skips boundary matching (see skipBoundaryCheck).
--- @param text string Haystack (already lowered)
--- @param needle string Needle (already lowered)
--- @return table spans Array of {start, end_pos} pairs
function XrayParser._collectMatchSpans(text, needle)
    local spans = {}
    local pos = 1
    local needle_len = #needle
    local text_len = #text
    local skip_boundaries = skipBoundaryCheck(needle)
    while true do
        local start = text:find(needle, pos, true)
        if not start then break end
        local end_pos = start + needle_len - 1
        if skip_boundaries then
            spans[#spans + 1] = {start, end_pos}
        else
            -- Check word boundaries: character before/after must be non-word
            local before_ok = (start == 1) or not isWordCharAt(text, start - 1, true)
            local after_ok = (end_pos >= text_len) or not isWordCharAt(text, end_pos + 1, false)
            if before_ok and after_ok then
                spans[#spans + 1] = {start, end_pos}
            end
        end
        pos = start + needle_len
    end
    return spans
end

--- Count occurrences of a substring in text (convenience wrapper).
--- @param text string Haystack (already lowered)
--- @param needle string Needle (already lowered)
--- @return number count
function XrayParser._countOccurrences(text, needle)
    return #XrayParser._collectMatchSpans(text, needle)
end

--- Build a compact entity index listing existing names per category.
--- Used in update prompts so the AI uses exact matching strings for existing entities.
--- @param data table Parsed X-Ray data
--- @return string index Multi-line string: "category: Name1 (alias1, alias2); Name2\n..."
function XrayParser.buildEntityIndex(data)
    local categories = XrayParser.getCategories(data)
    if not categories or #categories == 0 then return "" end

    local lines = {}
    for _idx, cat in ipairs(categories) do
        if not SINGLETON_CATEGORIES[cat.key] and cat.items and #cat.items > 0 then
            local names = {}
            for _idx2, item in ipairs(cat.items) do
                local name = getItemSearchName(item)
                if name then
                    local item_aliases = ensure_array(item.aliases)
                    if item_aliases and #item_aliases > 0 then
                        local shown = {}
                        for i = 1, math.min(2, #item_aliases) do
                            shown[i] = item_aliases[i]
                        end
                        name = name .. " (" .. table.concat(shown, ", ") .. ")"
                    end
                    names[#names + 1] = name
                end
            end
            if #names > 0 then
                lines[#lines + 1] = cat.key .. ": " .. table.concat(names, "; ")
            end
        end
    end
    -- Dormant-index alias bridge (item 49 layer 2.5): the ledger's IDENTITY
    -- HANDLES (names + up to 2 aliases — never descriptions or background)
    -- join the index so the model can bridge naming drift wherever it already
    -- runs (updates, merges): it lists a dormant name among an entity's
    -- aliases, and the mechanical wake-pass connects them in the same write.
    local ledger = data[XrayParser.DORMANT_KEY]
    if type(ledger) == "table" and #ledger > 0 then
        local names = {}
        for _idx, stub in ipairs(ledger) do
            if type(stub) == "table" and type(stub.name) == "string" and stub.name ~= "" then
                local name = stub.name
                local stub_aliases = ensure_array(stub.aliases)
                if stub_aliases and #stub_aliases > 0 then
                    local shown = {}
                    for i = 1, math.min(2, #stub_aliases) do
                        shown[i] = stub_aliases[i]
                    end
                    name = name .. " (" .. table.concat(shown, ", ") .. ")"
                end
                names[#names + 1] = name
            end
        end
        if #names > 0 then
            lines[#lines + 1] = "dormant (from related books, not yet in this one): "
                .. table.concat(names, "; ")
        end
    end
    return table.concat(lines, "\n")
end

--- Categories where items use descriptive phrases as names (not stable identifiers).
--- These use pure append during merge instead of name-based matching.
local APPEND_CATEGORIES = {
    timeline = true,
    argument_development = true,
}

--- Merge cross-book background entries (arrays of { source, text }): an
--- addition REPLACES an existing entry from the same source (re-merging an
--- updated book never duplicates) and appends otherwise. Returns a NEW array,
--- nil when nothing valid remains. Pure.
--- @param existing table|nil The item's current background array
--- @param additions table|nil Entries to fold in
--- @return table|nil
function XrayParser.mergeBackground(existing, additions)
    local merged = {}
    -- Round 28 (#90): identity is the source book's FILE PATH when known —
    -- title strings drift (doc_props.title vs display_title vs override gave
    -- the same volume two different labels on one device, so per-source
    -- replace silently duplicated). The label stays display-only. A file-keyed
    -- line also registers its source string, so a legacy line and its
    -- path-keyed successor still collapse to one.
    local by_file = {}
    local by_source = {}
    local function add(entry)
        if type(entry) ~= "table" then return end
        local text = entry.text
        if type(text) ~= "string" or text == "" then return end
        local source = type(entry.source) == "string" and entry.source ~= ""
            and entry.source or "?"
        local file = type(entry.file) == "string" and entry.file ~= ""
            and entry.file or nil
        local line = { source = source, text = text, file = file }
        local idx = file and by_file[file]
        if not idx then
            local sidx = by_source[source]
            if sidx then
                local occ = merged[sidx]
                -- Same source string but two DIFFERENT known files = a real
                -- title collision — keep both lines rather than merge them
                if not (occ.file and file and occ.file ~= file) then
                    idx = sidx
                    -- A replacement never LOSES an identity the slot had
                    line.file = file or occ.file
                end
            end
        end
        if idx then
            merged[idx] = line
        else
            merged[#merged + 1] = line
            idx = #merged
        end
        if line.file then by_file[line.file] = idx end
        by_source[source] = idx
    end
    if type(existing) == "table" then
        for _idx, entry in ipairs(existing) do add(entry) end
    end
    if type(additions) == "table" then
        for _idx, entry in ipairs(additions) do add(entry) end
    end
    if #merged == 0 then return nil end
    return merged
end

--- Merge array category items by name matching (case-insensitive).
--- Matching items are replaced in-place; new items are appended.
--- @param old_items table Existing items array (mutated)
--- @param new_items table New items to merge in
--- @return table old_items The merged array
--- Case-insensitive alias union: keep's aliases first, then new ones not
--- already present. nil when both sides are empty.
local function unionAliases(keep_aliases, new_aliases)
    local out, seen = {}, {}
    for _idx, list in ipairs({ keep_aliases, new_aliases }) do
        if type(list) == "table" then
            for _i, alias in ipairs(list) do
                if type(alias) == "string" and alias ~= "" and not seen[alias:lower()] then
                    seen[alias:lower()] = true
                    out[#out + 1] = alias
                end
            end
        end
    end
    return #out > 0 and out or nil
end

local function mergeArrayCategory(old_items, new_items)
    local lookup = {}
    for i, item in ipairs(old_items) do
        local name = getItemSearchName(item)
        if name then
            lookup[name:lower()] = i
        end
    end
    -- Aliases match too, at LOWER priority than main names (2026-08-09
    -- rename/merge hardening): a delta that re-emits a dedup-dropped or
    -- pre-rename name as its main name must fold into the surviving entry,
    -- not re-create the duplicate. A main name always wins the key; an alias
    -- never shadows another entry's actual name.
    local alias_of = {}
    for i, item in ipairs(old_items) do
        if type(item) == "table" and type(item.aliases) == "table" then
            for _ai, alias in ipairs(item.aliases) do
                if type(alias) == "string" and alias ~= "" then
                    local key = alias:lower()
                    if lookup[key] == nil and alias_of[key] == nil then
                        alias_of[key] = i
                    end
                end
            end
        end
    end
    for _idx, new_item in ipairs(new_items) do
        local name = getItemSearchName(new_item)
        local key = name and name:lower()
        local idx = key and lookup[key]
        local via_alias = false
        if not idx and key then
            idx = alias_of[key]
            via_alias = idx ~= nil
        end
        if idx then
            local keep = old_items[idx]
            -- background is attached mechanically (cross-book merge, item 44)
            -- and never part of the model schema — a rewrite must not shed OR
            -- replace it (round 28: the stored lines always win; model echoes
            -- are dropped at parse, this is the belt for any path that skipped
            -- dropModelBackground)
            new_item.background = keep.background
            if via_alias then
                -- The delta used a secondary name: identity stays the entry's
                -- (a rewrite must not resurrect a renamed/absorbed name as
                -- the main one)
                local keep_name = getItemSearchName(keep)
                if new_item.name ~= nil then new_item.name = keep_name
                elseif new_item.term ~= nil then new_item.term = keep_name
                elseif new_item.event ~= nil then new_item.event = keep_name end
            end
            -- Stored aliases survive the rewrite (dedup absorbs and renames
            -- live there; a model echo that drops them must not shed them)
            new_item.aliases = unionAliases(keep.aliases, new_item.aliases)
            old_items[idx] = new_item
        else
            old_items[#old_items + 1] = new_item
        end
    end
    return old_items
end

--- Append new items to old items without deduplication.
--- Used for timeline/argument_development where names are full sentences.
--- @param old_items table Existing items array (mutated)
--- @param new_items table New items to append
--- @return table old_items The extended array
local function appendCategory(old_items, new_items)
    for _idx, item in ipairs(new_items) do
        old_items[#old_items + 1] = item
    end
    return old_items
end

-- ============== Dormant background ledger (item 49, layers 1-2) ==============
-- A reserved top-level key inside the artifact JSON holding entities CARRIED
-- from related books that have not appeared in THIS book yet — compact stubs
-- { name, aliases, category, description, source, background }. LOCAL-ONLY:
-- stripped from every prompt (zero token cost), invisible to display/search
-- (getCategories never yields it), never authored by the model (write-back
-- drops model-emitted imitations), and it survives XrayParser.merge untouched
-- because merge iterates a fixed key list. The wake-pass below promotes a
-- stub's knowledge into any active entity that matches it.
XrayParser.DORMANT_KEY = "__dormant"

-- What KIND of thing a category holds. Carried knowledge may bridge category
-- drift inside a family (the same figure is `characters` in a novel and
-- `key_figures` in a companion volume) but never across one: a person and a
-- glossary term that share a name are not the same thing (round 26 — a
-- dormant "Keeper" character woke into a "Keeper" lexicon entry on device).
XrayParser.CATEGORY_FAMILY = {
    characters = "people",
    key_figures = "people",
    locations = "places",
    lexicon = "terms",
    terminology = "terms",
    technical_terms = "terms",
    core_concepts = "concepts",
    key_concepts = "concepts",
}

--- Prompt-safe copy of an artifact JSON string: the dormant ledger removed.
--- Returns the input unchanged when no ledger is present (cheap find guard) or
--- when anything about the round-trip fails — a strip failure must never cost
--- the caller the artifact itself. Safe on non-X-Ray strings (prose caches).
--- @param json_str string|nil
--- @return string|nil
function XrayParser.stripDormantJSON(json_str)
    if type(json_str) ~= "string"
        or not json_str:find('"__dormant"', 1, true) then
        return json_str
    end
    local data = XrayParser.parse(json_str)
    if type(data) ~= "table" or data.error or data[XrayParser.DORMANT_KEY] == nil then
        return json_str
    end
    data[XrayParser.DORMANT_KEY] = nil
    local ok, out = pcall(json.encode, data, { pretty = true, indent = true })
    if ok and type(out) == "string" then return out end
    return json_str
end

--- Prompt-safe copy for UPDATE/MERGE requests (round 28, #90): the dormant
--- ledger AND every mechanical background line removed. Background is
--- code-owned — the model can neither use nor legitimately return it, it
--- inflates dense-script prompts (each folded volume adds paragraphs per
--- entity, compounding through a series), and prompt-visible lines invited
--- the echoes this round dropped. Chat contexts ({xray_cache}) deliberately
--- KEEP background — there it is read-only knowledge for the assistant.
--- Same never-fail contract as stripDormantJSON.
--- @param json_str string|nil
--- @return string|nil
function XrayParser.stripForPromptJSON(json_str)
    if type(json_str) ~= "string"
        or (not json_str:find('"__dormant"', 1, true)
            and not json_str:find('"background"', 1, true)) then
        return json_str
    end
    local data = XrayParser.parse(json_str)
    if type(data) ~= "table" or data.error then
        return json_str
    end
    data[XrayParser.DORMANT_KEY] = nil
    XrayParser.dropModelBackground(data)
    local ok, out = pcall(json.encode, data, { pretty = true, indent = true })
    if ok and type(out) == "string" then return out end
    return json_str
end

--- Background lines a stub contributes to an entity that doesn't already
--- carry lines from those source books (fill-gaps-only — an existing entry
--- from the same source book wins, same rule as the transitive carry).
--- Shared by the automatic wake-pass and the manual wake (browser). Pure.
local function stubBackgroundAdditions(stub, existing_background)
    -- Fill-gaps keys: file path when known (round 28 identity), label always
    local existing_sources = {}
    if type(existing_background) == "table" then
        for _idx, b in ipairs(existing_background) do
            if type(b) == "table" then
                if type(b.source) == "string" then existing_sources[b.source] = true end
                if type(b.file) == "string" then existing_sources[b.file] = true end
            end
        end
    end
    local additions = {}
    local function seen(source, file)
        return existing_sources[source] or (file and existing_sources[file])
    end
    local function mark(source, file)
        existing_sources[source] = true
        if file then existing_sources[file] = true end
    end
    if type(stub.description) == "string" and stub.description ~= ""
        and type(stub.source) == "string" and stub.source ~= ""
        and not seen(stub.source, stub.file) then
        additions[#additions + 1] = { source = stub.source, text = stub.description,
            file = type(stub.file) == "string" and stub.file or nil }
        mark(stub.source, stub.file)
    end
    if type(stub.background) == "table" then
        for _idx, b in ipairs(stub.background) do
            if type(b) == "table" and type(b.text) == "string" and b.text ~= ""
                and type(b.source) == "string" and b.source ~= ""
                and not seen(b.source, b.file) then
                additions[#additions + 1] = { source = b.source, text = b.text,
                    file = type(b.file) == "string" and b.file or nil }
                mark(b.source, b.file)
            end
        end
    end
    return additions
end

--- Wake-pass (carry layer 2): any ledger stub whose name/alias matches an
--- ACTIVE entity folds its carried knowledge into that entity's background —
--- fill-gaps-only, an existing entry from the same source book wins (same
--- rule as the transitive carry) — brings its names along as aliases, and
--- leaves the ledger. Runs on EVERY write-back (merge, incremental update,
--- deepen), so an entity entering by any route wakes its history. Mutates
--- data in place. Pure.
--- @param data table Parsed X-Ray
--- @return table woken Array of { name, source } for logging/toasts
function XrayParser.wakeDormant(data)
    local woken = {}
    if type(data) ~= "table" then return woken end
    local ledger = data[XrayParser.DORMANT_KEY]
    if type(ledger) ~= "table" or #ledger == 0 then
        if ledger ~= nil and (type(ledger) ~= "table" or #ledger == 0) then
            data[XrayParser.DORMANT_KEY] = nil
        end
        return woken
    end
    -- name/alias (lowercased) → active item
    -- Round 26: matching is FAMILY-SCOPED. It used to be a single flat
    -- name→item map over every category, so a dormant CHARACTER woke into a
    -- LEXICON entry that merely shared its name ("Keeper", device corpus) —
    -- the term absorbed a person's history and the real person got nothing.
    -- Within a family the drift is real and must still bridge (a figure is
    -- `characters` in a novel and `key_figures` in a companion volume).
    local lookup, family_lookup = {}, {}
    local function learn(key, item, family)
        if type(key) ~= "string" or key == "" then return end
        local norm = key:lower()
        if lookup[norm] == nil then lookup[norm] = item end
        if family then
            family_lookup[family] = family_lookup[family] or {}
            if family_lookup[family][norm] == nil then family_lookup[family][norm] = item end
        end
    end
    for _idx, cat in ipairs(XrayParser.getCategories(data)) do
        if type(cat.items) == "table" then
            -- Round 27: an unmapped category is its OWN family, so the ledger's
            -- new non-entity stubs (themes, findings, arguments — full
            -- inclusion) can only wake inside their own category instead of
            -- falling through to the flat map, which is the same cross-category
            -- bug round 26 fixed for "Keeper". Mapped families still bridge
            -- their synonyms (characters ↔ key_figures).
            local family = XrayParser.CATEGORY_FAMILY[cat.key] or cat.key
            for _idx2, item in ipairs(cat.items) do
                if type(item) == "table" then
                    learn(XrayParser.getItemName(item, cat.key), item, family)
                    if type(item.aliases) == "table" then
                        for _idx3, alias in ipairs(item.aliases) do learn(alias, item, family) end
                    end
                end
            end
        end
    end
    local remaining = {}
    for _idx, stub in ipairs(ledger) do
        local hit
        if type(stub) == "table" then
            -- A stub that knows its category may only wake inside its family
            -- (or, unmapped, inside that category); one with no category
            -- recorded (pre-ledger writes) keeps the flat match
            local stub_cat = type(stub.category) == "string" and stub.category ~= ""
                and stub.category or nil
            local stub_family = stub_cat
                and (XrayParser.CATEGORY_FAMILY[stub_cat] or stub_cat) or nil
            local scope = stub_family and (family_lookup[stub_family] or {}) or lookup
            hit = type(stub.name) == "string" and stub.name ~= ""
                and scope[stub.name:lower()] or nil
            if not hit and type(stub.aliases) == "table" then
                for _idx2, alias in ipairs(stub.aliases) do
                    if type(alias) == "string" and alias ~= "" and scope[alias:lower()] then
                        hit = scope[alias:lower()]
                        break
                    end
                end
            end
        end
        if hit then
            local additions = stubBackgroundAdditions(stub, hit.background)
            if #additions > 0 then
                hit.background = XrayParser.mergeBackground(hit.background, additions)
            end
            -- A stub matched by alias brings the other book's names along
            local function foldAlias(name)
                if type(name) ~= "string" or name == "" then return end
                local norm = name:lower()
                if lookup[norm] ~= nil then return end -- known name (this or another entity)
                local arr = ensure_array(hit.aliases) or {}
                arr[#arr + 1] = name
                hit.aliases = arr
                lookup[norm] = hit
            end
            foldAlias(stub.name)
            if type(stub.aliases) == "table" then
                for _idx2, a in ipairs(stub.aliases) do foldAlias(a) end
            end
            woken[#woken + 1] = { name = stub.name, source = stub.source }
        else
            remaining[#remaining + 1] = stub
        end
    end
    data[XrayParser.DORMANT_KEY] = #remaining > 0 and remaining or nil
    return woken
end

--- Find an ACTIVE entity by any of several identity handles (round 25, cross-
--- book group navigation): the same person can be "Mira Alvsund" in one volume
--- and "the Keeper" in the next, and can drift category between volumes, so
--- match on name AND aliases across every category — preferred category first,
--- then the rest. Pure.
--- @param data table Parsed X-Ray
--- @param names table Identity handles to try (name + aliases of the source item)
--- @param preferred_category string|nil Category key to search first
--- @return table|nil item, string|nil category_key, number|nil index
function XrayParser.findByIdentity(data, names, preferred_category)
    if type(data) ~= "table" or type(names) ~= "table" or #names == 0 then return nil end
    local wanted = {}
    for _idx, n in ipairs(names) do
        if type(n) == "string" and n ~= "" then wanted[n:lower()] = true end
    end
    if not next(wanted) then return nil end
    local function scan(cat)
        if SINGLETON_CATEGORIES[cat.key] or type(cat.items) ~= "table" then return nil end
        for i, item in ipairs(cat.items) do
            if type(item) == "table" then
                local name = XrayParser.getItemName(item, cat.key)
                if type(name) == "string" and wanted[name:lower()] then return item, cat.key, i end
                local aliases = ensure_array(item.aliases)
                if aliases then
                    for _idx2, a in ipairs(aliases) do
                        if type(a) == "string" and wanted[a:lower()] then return item, cat.key, i end
                    end
                end
            end
        end
        return nil
    end
    local categories = XrayParser.getCategories(data)
    if preferred_category then
        for _idx, cat in ipairs(categories) do
            if cat.key == preferred_category then
                local item, key, i = scan(cat)
                if item then return item, key, i end
                break
            end
        end
    end
    for _idx, cat in ipairs(categories) do
        if cat.key ~= preferred_category then
            local item, key, i = scan(cat)
            if item then return item, key, i end
        end
    end
    return nil
end

--- Same identity match against the DORMANT ledger: an entity absent from this
--- book's visible entries may still be carried here from an earlier volume,
--- which is a more honest landing than "not found". Pure.
--- @param data table Parsed X-Ray
--- @param names table Identity handles to try
--- @return table|nil stub, number|nil index
function XrayParser.findDormantByIdentity(data, names)
    if type(data) ~= "table" or type(names) ~= "table" then return nil end
    local ledger = data[XrayParser.DORMANT_KEY]
    if type(ledger) ~= "table" then return nil end
    local wanted = {}
    for _idx, n in ipairs(names) do
        if type(n) == "string" and n ~= "" then wanted[n:lower()] = true end
    end
    if not next(wanted) then return nil end
    for i, stub in ipairs(ledger) do
        if type(stub) == "table" then
            if type(stub.name) == "string" and wanted[stub.name:lower()] then return stub, i end
            if type(stub.aliases) == "table" then
                for _idx2, a in ipairs(stub.aliases) do
                    if type(a) == "string" and wanted[a:lower()] then return stub, i end
                end
            end
        end
    end
    return nil
end

--- Remove one ledger stub, positional identity verified by name (the dedup
--- rule: never act on an entry the reader did not see). Falls back to a
--- name scan ONLY when the name is unambiguous in the ledger. Mutates data.
--- @param data table Parsed X-Ray
--- @param stub_idx number Ledger index at scan time
--- @param stub_name string Expected stub name
--- @return table|nil stub The removed stub (nil = not found / ambiguous)
function XrayParser.removeStub(data, stub_idx, stub_name)
    if type(data) ~= "table" or type(stub_name) ~= "string" then return nil end
    local ledger = data[XrayParser.DORMANT_KEY]
    if type(ledger) ~= "table" then return nil end
    local stub = ledger[stub_idx]
    if not (type(stub) == "table" and stub.name == stub_name) then
        stub = nil
        for i, s in ipairs(ledger) do
            if type(s) == "table" and s.name == stub_name then
                if stub then return nil end -- ambiguous — refuse
                stub, stub_idx = s, i
            end
        end
        if not stub then return nil end
    end
    table.remove(ledger, stub_idx)
    if #ledger == 0 then data[XrayParser.DORMANT_KEY] = nil end
    return stub
end

--- Manual wake INTO an existing entity (series-identity round, 2026-08-06):
--- reader-asserted identity — the chosen ACTIVE item gains the stub's carried
--- background (fill-gaps-only per source) and its names as aliases; the stub
--- leaves the ledger. The manual counterpart of the wake-pass hit branch,
--- and the zero-token fix for cross-volume naming drift the model missed
--- ("the boy" IS Tobias Renn). Target resolved by category + name, ambiguity
--- refused. Mutates data.
--- @param data table Parsed X-Ray
--- @param stub_idx number Ledger index at scan time
--- @param stub_name string Expected stub name
--- @param cat_key string Target item's category key
--- @param item_name string Target item's name (getItemName form)
--- @return boolean ok
function XrayParser.wakeStubInto(data, stub_idx, stub_name, cat_key, item_name)
    if type(data) ~= "table" then return false end
    local target
    for _idx, cat in ipairs(XrayParser.getCategories(data)) do
        if cat.key == cat_key and type(cat.items) == "table" then
            for _idx2, item in ipairs(cat.items) do
                if type(item) == "table"
                    and XrayParser.getItemName(item, cat_key) == item_name then
                    if target then return false end -- ambiguous name — refuse
                    target = item
                end
            end
        end
    end
    if not target then return false end
    local stub = XrayParser.removeStub(data, stub_idx, stub_name)
    if not stub then return false end
    local additions = stubBackgroundAdditions(stub, target.background)
    if #additions > 0 then
        target.background = XrayParser.mergeBackground(target.background, additions)
    end
    local aliases = ensure_array(target.aliases) or {}
    local seen = {}
    if type(target.name) == "string" then seen[target.name:lower()] = true end
    if type(target.term) == "string" then seen[target.term:lower()] = true end
    for _idx, a in ipairs(aliases) do
        if type(a) == "string" then seen[a:lower()] = true end
    end
    local function foldAlias(name)
        if type(name) == "string" and name ~= "" and not seen[name:lower()] then
            aliases[#aliases + 1] = name
            seen[name:lower()] = true
        end
    end
    foldAlias(stub.name)
    if type(stub.aliases) == "table" then
        for _idx, a in ipairs(stub.aliases) do foldAlias(a) end
    end
    if #aliases > 0 then target.aliases = aliases end
    return true
end

--- Manual wake as a NEW visible entry: the stub becomes a full item in its
--- own category — description verbatim, ancestor background lines kept with
--- their labels. Refused when the artifact's type has no such category
--- (cross-type series). Mutates data.
--- @param data table Parsed X-Ray
--- @param stub_idx number Ledger index at scan time
--- @param stub_name string Expected stub name
--- @return boolean ok
function XrayParser.promoteStub(data, stub_idx, stub_name)
    if type(data) ~= "table" then return false end
    local ledger = data[XrayParser.DORMANT_KEY]
    local probe = type(ledger) == "table" and ledger[stub_idx] or nil
    local cat_key
    if type(probe) == "table" and probe.name == stub_name then
        cat_key = probe.category
    else
        for _idx, s in ipairs(type(ledger) == "table" and ledger or {}) do
            if type(s) == "table" and s.name == stub_name then cat_key = s.category end
        end
    end
    if type(cat_key) ~= "string" then return false end
    local valid = false
    for _idx, cat in ipairs(XrayParser.getCategories(data)) do
        if cat.key == cat_key then valid = true break end
    end
    if not valid then return false end
    local stub = XrayParser.removeStub(data, stub_idx, stub_name)
    if not stub then return false end
    local item
    if cat_key == "lexicon" or cat_key == "terminology" or cat_key == "technical_terms" then
        item = { term = stub.name, definition = stub.description or "" }
    else
        item = { name = stub.name, description = stub.description or "" }
    end
    if type(stub.aliases) == "table" and #stub.aliases > 0 then item.aliases = stub.aliases end
    if type(stub.background) == "table" and #stub.background > 0 then item.background = stub.background end
    local arr = data[cat_key]
    if type(arr) ~= "table" then
        arr = {}
        data[cat_key] = arr
    end
    arr[#arr + 1] = item
    return true
end

--- The inverse of promoteStub: a visible entry goes back to the carried list.
--- Round 27 (maintainer: "Add as its own entry could easily be done by accident
--- and there is no way back"). Restricted by its CALLERS to entries that carry
--- cross-book background — those honestly belong to an earlier book, so the
--- carried list is an honest home for them; a native entry of THIS book would
--- be mislabeled there, and a destructive "delete entry" is a separate
--- question. Nothing is marked on promote, so nothing leaks into a prompt:
--- the round trip is inferred from the data itself.
--- @param data table Parsed X-Ray (mutated)
--- @param cat_key string Category holding the entry
--- @param item_name string Entry name (ambiguous names refused, as elsewhere)
--- @return boolean ok
--- Add identity handles to an entry's aliases (Manage ▸ Link, 2026-08-09):
--- case-insensitive dedupe against the main name and existing aliases. Same
--- exact-name find + ambiguity guard as renameItem. Returns true when the
--- entry was found — even if every name was already present (the link is
--- then already recorded). Pure.
--- @param data table Parsed X-Ray
--- @param cat_key string Category key
--- @param item_name string Main name (exact)
--- @param names table Identity handles to add
--- @return boolean ok
function XrayParser.addItemAliases(data, cat_key, item_name, names)
    if type(data) ~= "table" or type(cat_key) ~= "string"
        or type(item_name) ~= "string" or item_name == ""
        or type(names) ~= "table" then
        return false
    end
    local arr = data[cat_key]
    if type(arr) ~= "table" then return false end
    local at
    for i, item in ipairs(arr) do
        if type(item) == "table" and XrayParser.getItemName(item, cat_key) == item_name then
            if at then return false end -- ambiguous name — refuse
            at = i
        end
    end
    if not at then return false end
    local item = arr[at]
    local aliases = ensure_array(item.aliases) or {}
    local seen = { [item_name:lower()] = true }
    for _idx, a in ipairs(aliases) do
        if type(a) == "string" then seen[a:lower()] = true end
    end
    for _idx, n in ipairs(names) do
        if type(n) == "string" and n ~= "" and not seen[n:lower()] then
            seen[n:lower()] = true
            aliases[#aliases + 1] = n
        end
    end
    item.aliases = #aliases > 0 and aliases or nil
    return true
end

--- Rename an entry's main name (Manage ▸ Rename, 2026-08-09). The old name is
--- pushed onto the FRONT of aliases so the model keeps the mapping
--- ({entity_index} shows "New (old, …)", {cached_result} carries the full
--- array) and the alias-aware delta-merge folds late deltas that still use
--- it. Refuses ambiguous names (same guard as demoteToStub). Side stores
--- keyed by the old name are the caller's job (ActionCache.renameEntityKeys).
--- @param data table Parsed X-Ray
--- @param cat_key string Category key
--- @param old_name string Current main name (exact)
--- @param new_name string Replacement main name
--- @return boolean ok
function XrayParser.renameItem(data, cat_key, old_name, new_name)
    if type(data) ~= "table" or type(cat_key) ~= "string"
        or type(old_name) ~= "string" or old_name == ""
        or type(new_name) ~= "string" or new_name == ""
        or old_name == new_name then
        return false
    end
    local arr = data[cat_key]
    if type(arr) ~= "table" then return false end
    local at
    for i, item in ipairs(arr) do
        if type(item) == "table" and XrayParser.getItemName(item, cat_key) == old_name then
            if at then return false end -- ambiguous name — refuse
            at = i
        end
    end
    if not at then return false end
    local item = arr[at]
    if item.name ~= nil then item.name = new_name
    elseif item.term ~= nil then item.term = new_name
    elseif item.event ~= nil then item.event = new_name
    else return false end
    -- Old name → front of aliases; the new name stops being an alias if it
    -- was one (it is the main name now)
    local aliases = { old_name }
    local seen = { [old_name:lower()] = true, [new_name:lower()] = true }
    for _idx, alias in ipairs(type(item.aliases) == "table" and item.aliases or {}) do
        if type(alias) == "string" and alias ~= "" and not seen[alias:lower()] then
            seen[alias:lower()] = true
            aliases[#aliases + 1] = alias
        end
    end
    item.aliases = aliases
    return true
end

function XrayParser.demoteToStub(data, cat_key, item_name)
    if type(data) ~= "table" or type(cat_key) ~= "string" or type(item_name) ~= "string" then
        return false
    end
    local arr = data[cat_key]
    if type(arr) ~= "table" then return false end
    local at
    for i, item in ipairs(arr) do
        if type(item) == "table" and XrayParser.getItemName(item, cat_key) == item_name then
            if at then return false end -- ambiguous name — refuse, as removeStub does
            at = i
        end
    end
    if not at then return false end
    local item = arr[at]
    -- Source: the earliest book that contributed background, so the row reads
    -- "carried from <that book>" exactly as it did before it was promoted
    local source
    if type(item.background) == "table" then
        for _idx, b in ipairs(item.background) do
            if type(b) == "table" and type(b.source) == "string" and b.source ~= "" then
                source = b.source
                break
            end
        end
    end
    if not source then return false end
    local stub = {
        name = item_name,
        category = cat_key,
        source = source,
        description = type(item.description) == "string" and item.description ~= ""
            and item.description or nil,
        background = item.background,
    }
    if type(item.aliases) == "table" and #item.aliases > 0 then
        stub.aliases = {}
        for _idx, a in ipairs(item.aliases) do stub.aliases[#stub.aliases + 1] = a end
    end
    table.remove(arr, at)
    local ledger = data[XrayParser.DORMANT_KEY]
    if type(ledger) ~= "table" then
        ledger = {}
        data[XrayParser.DORMANT_KEY] = ledger
    end
    ledger[#ledger + 1] = stub
    return true
end

--- Merge partial X-Ray update into existing data.
--- The AI outputs only new/changed entries; this merges them into the full dataset.
--- @param old_data table Complete existing X-Ray data (mutated in place)
--- @param new_data table Partial update from AI
--- @return table old_data The merged result
function XrayParser.merge(old_data, new_data)
    if not new_data or type(new_data) ~= "table" then return old_data end
    if not old_data or type(old_data) ~= "table" then return new_data end

    old_data.type = old_data.type or new_data.type

    local keys
    if XrayParser.isAcademic(old_data) then
        keys = ACADEMIC_KEYS
    elseif XrayParser.isFiction(old_data) then
        keys = FICTION_KEYS
    else
        keys = NONFICTION_KEYS
    end
    for _idx, key in ipairs(keys) do
        if new_data[key] ~= nil then
            if SINGLETON_CATEGORIES[key] then
                old_data[key] = new_data[key]
            elseif APPEND_CATEGORIES[key] then
                if type(new_data[key]) == "table" and #new_data[key] > 0 then
                    old_data[key] = appendCategory(old_data[key] or {}, new_data[key])
                end
            else
                if type(new_data[key]) == "table" then
                    old_data[key] = mergeArrayCategory(old_data[key] or {}, new_data[key])
                end
            end
        end
    end

    return old_data
end

return XrayParser
