--[[
Capitals calibration (B533 S3, docs/xray_names_matching_plan.md sections 4.6
and 8): which X-Ray names the automatic capitals rule would set to capitals
only, from each book's own usage, with the counts and the lowercase uses, for
the maintainer to read before the rule ships. A false switch is a name whose
lowercase uses are real mentions.

Runs inside a headless run (KOReader's LuaJIT and its case fold, a fresh
home; nothing of a real home is read):

  KOA_CAPS=/path/manifest.lua sh tests/scenarios/run.sh <scratch dir> tests/tools/caps_calibration.lua

manifest.lua returns a list of books:
  { { label = "…", text = "/path/book.txt", xrays = { "/path/answer.txt", … } }, … }
text: UTF-8 plain text, paragraphs separated by blank lines (wrapped lines of
a paragraph are joined). xrays: X-Rays as the plugin stores them or a model's
answer (the plugin's own parse); the names of several are judged together.
Optional: KOA_CAPS_MIN_P (3), KOA_CAPS_MIN_L (1), KOA_CAPS_SHARE (0.25),
KOA_CAPS_CONTEXTS (4, lowercase uses shown per switched name).

Each name and alias of the matchable categories is judged as capitals only
judges it (its forms and the capitals each requires: matchTermSet's caps;
occurrences inside a longer name of another entry left out). Per occurrence:
  P      mid-sentence with every capital the name requires
  L      with none of them
  start  sentence-initial and requiring only its first word's capital
  caps   written in capitals; mixed: some of its capitals
The rule switches a name when P >= min P, L >= min L and P >= share x (P + L).
The report lands in the run folder (caps_report.md).
]]

local S = dofile(os.getenv("KOA_PLUGIN") .. "/tests/scenarios/boot.lua")
local XrayParser = require("koassistant.xray.xray_parser")
local bit = require("bit")

-- The shipped rule's numbers (XrayParser.AUTO_CAPS) unless a run asks others
local MIN_P = tonumber(os.getenv("KOA_CAPS_MIN_P") or "") or XrayParser.AUTO_CAPS.min_p
local MIN_L = tonumber(os.getenv("KOA_CAPS_MIN_L") or "") or XrayParser.AUTO_CAPS.min_l
local SHARE = tonumber(os.getenv("KOA_CAPS_SHARE") or "") or XrayParser.AUTO_CAPS.share
local CONTEXTS = tonumber(os.getenv("KOA_CAPS_CONTEXTS") or "") or 4

local function readFile(path)
    local f = assert(io.open(path, "rb"), "cannot read " .. tostring(path))
    local data = f:read("*a")
    f:close()
    return data
end

--- Paragraphs: blocks between blank lines, their lines joined.
local function paragraphs(text)
    local out = {}
    text = text:gsub("\r\n?", "\n")
    for block in (text .. "\n\n"):gmatch("(.-)\n%s*\n") do
        local p = block:gsub("\n", " "):match("^%s*(.-)%s*$")
        if p ~= "" then out[#out + 1] = p end
    end
    return out
end

--- Whether byte s of a paragraph starts a sentence: the plugin's own rule
--- (XrayParser.startsSentence, the one the name index records)
local function sentenceInitial(para, s)
    return XrayParser.startsSentence(para:sub(1, s - 1))
end

local function hasLowerAscii(s) return s:find("%l") ~= nil end
local function upperCount(s)
    local n = 0
    for _c in s:gmatch("%u") do n = n + 1 end
    return n
end

--- The names to judge: each name and alias of the matchable categories, once
--- per entry, with the entry they belong to (for its containing forms).
local function namesOf(data)
    local out = {}
    for _idx, cat in ipairs(XrayParser.getCategories(data) or {}) do
        if not XrayParser.TEXT_MATCH_EXCLUDED[cat.key] then
            for _j, item in ipairs(cat.items or {}) do
                local main = XrayParser.getItemName(item, cat.key)
                local seen = {}
                local list = { main }
                for _k, a in ipairs(type(item.aliases) == "table" and item.aliases or {}) do list[#list + 1] = a end
                for _k, n in ipairs(list) do
                    if type(n) == "string" and #n > 2 and not seen[n:lower()] then
                        seen[n:lower()] = true
                        out[#out + 1] = { name = n, entry = main, item = item, cat = cat.key }
                    end
                end
            end
        end
    end
    return out
end

local function context(para, s, e)
    local a = math.max(1, s - 60)
    local b = math.min(#para, e + 60)
    -- whole characters only
    while a > 1 and para:byte(a) and para:byte(a) >= 0x80 and para:byte(a) < 0xC0 do a = a - 1 end
    while b < #para and para:byte(b + 1) and para:byte(b + 1) >= 0x80 and para:byte(b + 1) < 0xC0 do b = b + 1 end
    return (a > 1 and "…" or "") .. para:sub(a, s - 1) .. "«" .. para:sub(s, e) .. "»"
        .. para:sub(e + 1, b) .. (b < #para and "…" or "")
end

local manifest_path = assert(os.getenv("KOA_CAPS"), "KOA_CAPS: the manifest's path")
local books = dofile(manifest_path)
local lines = {}
local function out(fmt, ...) lines[#lines + 1] = select("#", ...) > 0 and string.format(fmt, ...) or fmt end
out("# Capitals calibration (B533 S3)")
out("")
out("Rule: P >= %d, L >= %d, P >= %d%% of P + L. P = mid-sentence with the name's capitals, L = none of them.", MIN_P, MIN_L, math.floor(SHARE * 100))

for _bidx, book in ipairs(books) do
    local paras = paragraphs(readFile(book.text))
    local normed = {}
    for i, p in ipairs(paras) do
        normed[i] = { norm = XrayParser.matchNormalize(p), keep = XrayParser.matchNormalizeKeepCase(p) }
    end
    -- the names of every X-Ray given, judged once each
    local names, by_name, datas = {}, {}, {}
    for _idx, path in ipairs(book.xrays or {}) do
        local data = XrayParser.parse(readFile(path))
        if data then
            datas[#datas + 1] = data
            for _j, n in ipairs(namesOf(data)) do
                local key = n.name:lower()
                if not by_name[key] then
                    by_name[key] = n
                    n.data = data
                    names[#names + 1] = n
                end
            end
        else
            S.note("could not parse", path)
        end
    end
    local rows = {}
    local no_caps, never_lower = 0, 0
    for _idx, n in ipairs(names) do
        local item = { name = n.name, aliases = {}, _caps = { [n.name:lower()] = true } }
        local set = XrayParser.matchTermSet(item)
        local handles = XrayParser.containingMatchHandles(n.data, n.item)
        local r = { name = n.name, entry = n.entry, cat = n.cat, P = 0, L = 0, start = 0, caps = 0, mixed = 0, lower = {} }
        if not (set and set.caps and next(set.caps)) then
            no_caps = no_caps + 1
        else
            for _pi, t in ipairs(normed) do
                local norm, keep = t.norm, t.keep
                for _k, occ in ipairs(XrayParser.occurrencesIn(norm, set, handles, nil)) do
                    local s, e = occ[1], occ[2]
                    local seg = keep:sub(s, e)
                    local req = set.caps[occ.form]
                    if req and XrayParser.foldCase(seg) == norm:sub(s, e) then
                        local evidence = req
                        if bit.band(evidence, 1) == 1 and sentenceInitial(keep, s) then evidence = evidence - 1 end
                        local mask = XrayParser.capsMask(seg)
                        if evidence == 0 then
                            r.start = r.start + 1
                        elseif not hasLowerAscii(seg) and upperCount(seg) >= 2 then
                            r.caps = r.caps + 1
                        elseif XrayParser.capsPass(mask, evidence) then
                            r.P = r.P + 1
                        elseif bit.band(mask, evidence) == 0 then
                            r.L = r.L + 1
                            if #r.lower < CONTEXTS then r.lower[#r.lower + 1] = context(keep, s, e) end
                        else
                            r.mixed = r.mixed + 1
                        end
                    end
                end
            end
            r.switch = r.P >= MIN_P and r.L >= MIN_L and r.P >= SHARE * (r.P + r.L)
            if r.L == 0 then never_lower = never_lower + 1 end
            rows[#rows + 1] = r
        end
    end
    table.sort(rows, function(a, b)
        if (a.switch and 1 or 0) ~= (b.switch and 1 or 0) then return a.switch end
        if a.L ~= b.L then return a.L > b.L end
        return a.P > b.P
    end)
    local switched = 0
    for _idx, r in ipairs(rows) do if r.switch then switched = switched + 1 end end
    out("")
    out("## %s", book.label or book.text)
    out("")
    out("%d X-Ray answers, %d names judged; %d require no capital (nothing to switch), %d never written in lowercase, %d would switch.",
        #datas, #names, no_caps, never_lower, switched)
    out("")
    out("| switch | name | entry | P | L | start | caps | mixed |")
    out("|---|---|---|---|---|---|---|---|")
    for _idx, r in ipairs(rows) do
        if r.switch or r.L > 0 then
            out("| %s | %s | %s | %d | %d | %d | %d | %d |", r.switch and "yes" or "", r.name,
                r.entry ~= r.name and r.entry or "", r.P, r.L, r.start, r.caps, r.mixed)
        end
    end
    out("")
    out("Names written both ways but kept (L >= 1, no switch) are listed too; names never written in lowercase are left out.")
    for _idx, r in ipairs(rows) do
        if r.switch then
            out("")
            out("**%s** (P %d, L %d): its lowercase uses, which capitals only would stop matching:", r.name, r.P, r.L)
            for _j, c in ipairs(r.lower) do out("- %s", c) end
        end
    end
    S.note(string.format("%s: %d names, %d would switch", book.label or book.text, #names, switched))
end

local report = S.RUN .. "/caps_report.md"
local f = assert(io.open(report, "w"))
f:write(table.concat(lines, "\n"), "\n")
f:close()
S.note("report:", report)
S.check(true, "calibration written")
S.finish()
