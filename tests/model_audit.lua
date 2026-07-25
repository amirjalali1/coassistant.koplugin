#!/usr/bin/env lua
-- Model Audit & Capability Probe (agenda item 20)
--
-- Turns model updates from archaeology into a reviewed diff:
--   1. DISCOVERY - fetch each provider's live model list (endpoints from
--      ModelLists._docs[provider].api_list) and diff against our curated arrays.
--   2. PROBE - for a chosen model, run the empirical capability battery that
--      /models endpoints do NOT report: temperature acceptance, reasoning
--      default on/off, effort ladder (incl. xhigh/max), disable support,
--      output-token ceiling, tools acceptance.
--   3. DRAFT - emit copy-pasteable stanzas for model_constraints.lua plus
--      reminders for koassistant_model_lists.lua. NEVER auto-applied - a
--      human reviews the diff and places tiers by hand.
--
-- Usage:
--   lua tests/model_audit.lua                          # discovery diff, all keyed providers
--   lua tests/model_audit.lua anthropic gemini         # discovery diff, subset
--   lua tests/model_audit.lua --probe anthropic claude-opus-5   # probe one model (LIVE calls)
--   lua tests/model_audit.lua --probe-new              # discovery, then probe each NEW model
--   lua tests/model_audit.lua --probe-new openai       # ... for one provider
--   Options: --verbose   full error bodies + ignored-id lists
--
-- Probes make real API micro-requests (max_tokens 32..1024); a full battery is
-- ~10-14 requests, fractions of a cent on most providers. Perplexity caveat:
-- every request also bills one web search.
--
-- Requires luarocks modules (luasocket, luasec, dkjson). Run this FIRST:
--   eval "$(luarocks --lua-version 5.5 path)"
-- (without it HTTP/JSON are unavailable and the script aborts with this hint).

-- Setup package path for plugin modules (same pattern as inspect.lua)
local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local script_dir = script_path:match("(.*/)") or "./"
    local plugin_dir = script_dir:gsub("tests/$", ""):gsub("/$", "")
    if plugin_dir == "" then plugin_dir = "." end
    package.path = script_dir .. "lib/?.lua;" ..
                   script_dir .. "?.lua;" ..
                   plugin_dir .. "/?.lua;" ..
                   package.path
    return plugin_dir
end
setupPaths()

-- Real network is required for everything this tool does; detect BEFORE the
-- mocks kick in (mock_koreader stubs ssl.https when luasocket is absent).
local HAS_NETWORK = pcall(require, "ssl.https")

-- Load mocks so plugin modules resolve under plain lua. Side benefit: the
-- hermeticity block empties the custom_models.lua / derived-cache override
-- layers, so "current resolution" below reflects what SHIPS (curated +
-- family fallbacks), not this machine's local overrides.
require("mock_koreader")

local JSON_OK, json = pcall(require, "json")
local ModelLists = require("koassistant_model_lists")
local ModelConstraints = require("model_constraints")
local Defaults = require("koassistant_api.defaults")
local TestConfig = require("test_config")

local ModelAudit = {}

--------------------------------------------------------------------------------
-- Output helpers
--------------------------------------------------------------------------------

local C = {
    red = "\27[31m", green = "\27[32m", yellow = "\27[33m",
    cyan = "\27[36m", dim = "\27[90m", bold = "\27[1m", off = "\27[0m",
}

local function printf(fmt, ...)
    print(string.format(fmt, ...))
end

local function banner(text)
    printf("\n%s== %s %s%s", C.bold, text, string.rep("=", math.max(4, 74 - #text)), C.off)
end

--------------------------------------------------------------------------------
-- Pure helpers (unit-tested via tests/unit/test_model_audit.lua)
--------------------------------------------------------------------------------

-- Plain-substring fragments that mark a fetched id as not-a-chat-model (or not
-- a curation target). Matched lowercase, plain find. Humans review the diff;
-- --verbose prints what was ignored, so misclassification is visible.
ModelAudit.NOISE = {
    common = {
        "embed", "rerank", "whisper", "tts", "audio", "moderation",
        "transcribe", "dall-e", "image", "ocr", "guard", "sora", "imagen",
        "veo", "vision-preview", "deep-research",
    },
    openai = {
        "davinci", "babbage", "text-", "realtime", "computer-use", "codex",
        "search-preview", "chatgpt", "instruct", "-pro",
    },
    gemini = {
        "gemma", "aqa", "learnlm", "-live", "banana", "robotics", "computer-use",
        "lyria", "antigravity", "omni", "customtools",  -- music gen / IDE agent / speech / variant
    },
    mistral = {
        "open-mistral", "open-mixtral", "voxtral", "moderation",
        "codestral", "devstral", "-code", "fim", "vibe", "leanstral",  -- coding/agent side products
    },
    xai = { "imagine" },  -- image/video gen
}

-- Returns the matching fragment (truthy) when the id should be ignored.
function ModelAudit.isNoise(provider, id)
    local lower = id:lower()
    local function hit(list)
        if not list then return nil end
        for _i, frag in ipairs(list) do
            if lower:find(frag, 1, true) then return frag end
        end
        return nil
    end
    return hit(ModelAudit.NOISE.common) or hit(ModelAudit.NOISE[provider])
end

-- Dated/numbered snapshots and -latest aliases of an id we already curate are
-- not "new models" (gpt-4o vs gpt-4o-2024-08-06, gemini -001, mistral -2509).
-- Each candidate base is also checked against the curated "-latest" alias,
-- since Mistral is curated via aliases (magistral-medium-2509 -> *-latest).
function ModelAudit.isSnapshotOf(id, curated_set)
    local candidates = {}
    local function addBase(base)
        if base then table.insert(candidates, base) end
    end
    addBase(id:match("^(.-)%-%d%d%d%d%-%d%d%-%d%d$"))   -- -YYYY-MM-DD
    addBase(id:match("^(.-)%-%d%d%d%d$"))               -- -YYMM (mistral) / -MMDD
    addBase(id:match("^(.-)%-%d%d%d$"))                 -- -001 / -002
    addBase(id:match("^(.-)%-latest$"))
    for _i, base in ipairs(candidates) do
        if curated_set[base] then return base end
        if curated_set[base .. "-latest"] then return base .. "-latest" end
    end
    return nil
end

-- Release timestamp from list metadata: OpenAI-shaped lists report `created`
-- (epoch), Anthropic reports `created_at` (ISO). nil when unavailable.
function ModelAudit.modelTimestamp(meta)
    if type(meta) ~= "table" then return nil end
    if type(meta.created) == "number" then return meta.created end
    if type(meta.created_at) == "string" then
        local y, mo, d = meta.created_at:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
        if y then
            return os.time({ year = tonumber(y), month = tonumber(mo),
                             day = tonumber(d), hour = 12 })
        end
    end
    return nil
end

ModelAudit.RECENT_SECONDS = 180 * 86400  -- uncurated ids older than this go to `stale`

-- curated: array of ids; fetched: map id -> meta; now: os.time() (nil = no
-- staleness split, everything uncurated lands in `new`).
-- Returns { new={}, stale={}, removed={}, snapshots={}, ignored={}, known=n }.
function ModelAudit.diffLists(provider, curated, fetched, now)
    local result = { new = {}, stale = {}, removed = {}, snapshots = {}, ignored = {}, known = 0 }
    local curated_set = {}
    for _i, id in ipairs(curated) do curated_set[id] = true end

    local fetched_ids = {}
    for id in pairs(fetched) do table.insert(fetched_ids, id) end
    table.sort(fetched_ids)

    for _i, id in ipairs(fetched_ids) do
        if curated_set[id] then
            result.known = result.known + 1
        elseif ModelAudit.isSnapshotOf(id, curated_set) then
            table.insert(result.snapshots, id)
        elseif ModelAudit.isNoise(provider, id) then
            table.insert(result.ignored, id)
        else
            -- No timestamp = assume recent (loud beats silent for a discovery tool)
            local ts = ModelAudit.modelTimestamp(fetched[id])
            if now and ts and (now - ts) > ModelAudit.RECENT_SECONDS then
                table.insert(result.stale, id)
            else
                table.insert(result.new, id)
            end
        end
    end
    for _i, id in ipairs(curated) do
        if not fetched[id] then table.insert(result.removed, id) end
    end
    return result
end

-- Extract a human-readable error message from a decoded error body.
function ModelAudit.errText(decoded, raw)
    if type(decoded) == "table" then
        local e = decoded.error
        if type(e) == "table" and type(e.message) == "string" then return e.message end
        if type(e) == "string" then return e end
        if type(decoded.message) == "string" then return decoded.message end
    end
    return tostring(raw or ""):sub(1, 400)
end

-- Parse the output-token ceiling out of an oversized-max_tokens error.
-- Takes the largest number that is >= 1024 and BELOW the absurd value we sent
-- (excludes echoes of our own value and large date-like ids such as 20251001).
function ModelAudit.parseCeiling(err, sent)
    local best
    for num in tostring(err):gmatch("%d+") do
        local n = tonumber(num)
        if n and n >= 1024 and n < sent and (not best or n > best) then best = n end
    end
    return best
end

-- Reasoning evidence in an OpenAI-wire success response (nil = none found).
function ModelAudit.reasoningEvidence(decoded)
    if type(decoded) ~= "table" then return nil end
    local usage = decoded.usage
    if type(usage) == "table" then
        local det = usage.completion_tokens_details
        if type(det) == "table" and type(det.reasoning_tokens) == "number"
                and det.reasoning_tokens > 0 then
            return "reasoning_tokens=" .. det.reasoning_tokens
        end
    end
    local choice = type(decoded.choices) == "table" and decoded.choices[1]
    local msg = type(choice) == "table" and choice.message
    if type(msg) == "table" then
        if type(msg.reasoning_content) == "string" and #msg.reasoning_content > 0 then
            return "reasoning_content present"
        end
        if type(msg.reasoning) == "string" and #msg.reasoning > 0 then
            return "reasoning field present"
        end
        if type(msg.content) == "string" and msg.content:find("<think>", 1, true) then
            return "<think> tags in content"
        end
    end
    return nil
end

--------------------------------------------------------------------------------
-- HTTP (lazy-required so the pure helpers stay loadable without luarocks)
--------------------------------------------------------------------------------

local function httpGet(url, headers)
    local https = require("ssl.https")
    local ltn12 = require("ltn12")
    local chunks = {}
    local ok, code = https.request({
        url = url, method = "GET", headers = headers,
        sink = ltn12.sink.table(chunks),
    })
    local text = table.concat(chunks)
    if not ok then return nil, "network: " .. tostring(code) end
    if code ~= 200 then
        return nil, string.format("HTTP %s: %s", tostring(code), text:sub(1, 300))
    end
    return text
end

-- POST JSON; returns http_code (number|string), decoded (table|nil), raw text.
local function httpPostJson(url, headers, body_tbl)
    local https = require("ssl.https")
    local ltn12 = require("ltn12")
    local payload = json.encode(body_tbl)
    local chunks = {}
    local hdrs = { ["Content-Type"] = "application/json",
                   ["Content-Length"] = tostring(#payload) }
    for k, v in pairs(headers or {}) do hdrs[k] = v end
    local ok, code = https.request({
        url = url, method = "POST", headers = hdrs,
        source = ltn12.source.string(payload),
        sink = ltn12.sink.table(chunks),
    })
    local text = table.concat(chunks)
    if not ok then return nil, nil, "network: " .. tostring(code) end
    local decoded
    if text ~= "" then
        local dok, d = pcall(json.decode, text)
        if dok and type(d) == "table" then decoded = d end
    end
    return tonumber(code) or code, decoded, text
end

--------------------------------------------------------------------------------
-- Discovery
--------------------------------------------------------------------------------

local function bearerHeaders(key)
    return { ["Authorization"] = "Bearer " .. key }
end

-- {data=[{id=...}]} -> map id -> meta (type-checked: luajson-null paranoia)
local function parseOpenAIShapedList(data)
    if type(data) ~= "table" or type(data.data) ~= "table" then
        return nil, "unexpected response shape"
    end
    local out = {}
    for _i, m in ipairs(data.data) do
        if type(m) == "table" and type(m.id) == "string" then out[m.id] = m end
    end
    return out
end

local DISCOVERY = {
    anthropic = {
        query = "?limit=1000",
        headers = function(key)
            return { ["x-api-key"] = key, ["anthropic-version"] = "2023-06-01" }
        end,
        parse = parseOpenAIShapedList,
    },
    openai   = { headers = bearerHeaders, parse = parseOpenAIShapedList },
    deepseek = { headers = bearerHeaders, parse = parseOpenAIShapedList },
    mistral  = {
        headers = bearerHeaders,
        parse = function(data)
            local models, err = parseOpenAIShapedList(data)
            if not models then return nil, err end
            -- Mistral reports capabilities; drop ids that can't chat at all.
            for id, m in pairs(models) do
                local caps = type(m) == "table" and m.capabilities
                if type(caps) == "table" and caps.completion_chat == false then
                    models[id] = nil
                end
            end
            return models
        end,
    },
    xai = { headers = bearerHeaders, parse = parseOpenAIShapedList },
    -- zai's list endpoint OMITS some serving ids (glm-4.7-flash probed alive
    -- 2026-07-25 while absent from the list) - soften REMOVED to verify-first.
    zai = { headers = bearerHeaders, parse = parseOpenAIShapedList, incomplete_list = true },
    gemini = {
        query = function(key) return "?key=" .. key .. "&pageSize=1000" end,
        parse = function(data)
            if type(data) ~= "table" or type(data.models) ~= "table" then
                return nil, "unexpected response shape"
            end
            local out = {}
            for _i, m in ipairs(data.models) do
                if type(m) == "table" and type(m.name) == "string" then
                    local can_generate = false
                    for _j, method in ipairs(type(m.supportedGenerationMethods) == "table"
                                             and m.supportedGenerationMethods or {}) do
                        if method == "generateContent" then can_generate = true end
                    end
                    if can_generate then
                        out[m.name:match("models/(.+)") or m.name] = m
                    end
                end
            end
            return out
        end,
    },
    -- Marketplaces: hundreds of backend models; "new" is meaningless noise.
    -- Instead we verify our curated ids still exist and cross-check their
    -- reported supported_parameters against our resolution layer.
    openrouter = { headers = bearerHeaders, parse = parseOpenAIShapedList, marketplace = true },
}

local function fetchProviderList(provider, api_key)
    local docs = ModelLists._docs[provider]
    local url = docs and docs.api_list
    if not url then return nil, "no list endpoint documented (_docs.api_list)" end
    local adapter = DISCOVERY[provider]
    if not adapter then return nil, "no discovery adapter" end

    if adapter.query then
        url = url .. (type(adapter.query) == "function" and adapter.query(api_key) or adapter.query)
    end
    local headers = adapter.headers and adapter.headers(api_key) or nil
    local text, err = httpGet(url, headers)
    if not text then return nil, err end
    local dok, data = pcall(json.decode, text)
    if not dok or type(data) ~= "table" then return nil, "response not valid JSON" end
    local models, perr = adapter.parse(data)
    if not models then return nil, perr end
    return models, nil, data
end

-- Cross-check one curated OpenRouter id's supported_parameters against our
-- resolution layer. Returns a list of mismatch strings (empty = consistent).
local function openrouterMismatches(id, meta)
    local params = type(meta) == "table" and meta.supported_parameters
    if type(params) ~= "table" then return {} end
    local set = {}
    for _i, p in ipairs(params) do
        if type(p) == "string" then set[p] = true end
    end
    local mismatches = {}
    local our_tools = ModelConstraints.supportsCapability("openrouter", id, "tools")
    if set.tools and not our_tools then
        table.insert(mismatches, "reports tools, we resolve false")
    elseif our_tools and not set.tools then
        table.insert(mismatches, "we resolve tools, endpoint doesn't report it")
    end
    local profile = ModelConstraints.getReasoningProfile("openrouter", id)
    local we_reason = profile and profile.axis ~= "none"
    if set.reasoning and not we_reason then
        table.insert(mismatches, "reports reasoning, our profile is none/passthrough")
    elseif we_reason and not set.reasoning and not (profile and profile.generic) then
        table.insert(mismatches, "curated reasoning profile, endpoint doesn't report reasoning")
    end
    return mismatches
end

-- Runs discovery for one provider, prints the report, returns diff (or nil).
local function runDiscovery(provider, api_key, verbose)
    banner(provider)
    local curated = ModelLists[provider]
    if type(curated) ~= "table" or #curated == 0 then
        printf("  %sskipped: no curated model array%s", C.dim, C.off)
        return nil
    end
    if not TestConfig.isValidApiKey(api_key) and provider ~= "ollama" then
        printf("  %sskipped: no API key in apikeys.lua%s", C.dim, C.off)
        return nil
    end

    local fetched, err = fetchProviderList(provider, api_key)
    if not fetched then
        printf("  %sfetch failed:%s %s", C.red, C.off, tostring(err))
        return nil
    end

    if DISCOVERY[provider].marketplace then
        local total = 0
        for _ignored in pairs(fetched) do total = total + 1 end
        printf("  marketplace: %d live ids (new-model diff suppressed) - checking %d curated ids",
            total, #curated)
        for _i, id in ipairs(curated) do
            if not fetched[id] then
                printf("  %s- REMOVED%s  %s  %s!! users' saved picks will 400%s",
                    C.red, C.off, id, C.red, C.off)
            else
                local mismatches = openrouterMismatches(id, fetched[id])
                if #mismatches > 0 then
                    printf("  %s? %s%s: %s", C.yellow, id, C.off, table.concat(mismatches, "; "))
                elseif verbose then
                    printf("  %s= %s ok%s", C.dim, id, C.off)
                end
            end
        end
        return { new = {}, removed = {} }
    end

    local diff = ModelAudit.diffLists(provider, curated, fetched, os.time())
    printf("  fetched %d chat-relevant ids - curated %d - older uncurated %d - snapshots %d - ignored %d",
        diff.known + #diff.new + #diff.stale + #diff.snapshots, #curated,
        #diff.stale, #diff.snapshots, #diff.ignored)
    if #diff.new > 0 then
        printf("  %sNEW%s (not in koassistant_model_lists.lua):", C.green, C.off)
        for _i, id in ipairs(diff.new) do
            printf("    + %-40s %sprobe: lua tests/model_audit.lua --probe %s %s%s",
                id, C.dim, provider, id, C.off)
        end
    end
    if #diff.stale > 0 then
        printf("  %solder uncurated (released >180d ago, deliberate skips?): %s%s",
            C.dim, table.concat(diff.stale, ", "), C.off)
    end
    if #diff.removed > 0 then
        if DISCOVERY[provider].incomplete_list then
            printf("  %sABSENT FROM LIST%s (this provider's list endpoint is known-incomplete):",
                C.yellow, C.off)
            for _i, id in ipairs(diff.removed) do
                printf("    - %s  %sverify: lua tests/model_audit.lua --probe %s %s%s",
                    id, C.dim, provider, id, C.off)
            end
        else
            printf("  %sREMOVED%s (curated but absent from the live list):", C.red, C.off)
            for _i, id in ipairs(diff.removed) do
                printf("    - %s  %s!! users' saved picks will 400 - verify, plan migration%s",
                    id, C.red, C.off)
            end
        end
    end
    if #diff.new == 0 and #diff.removed == 0 then
        printf("  %sin sync%s", C.green, C.off)
    end
    if verbose then
        if #diff.snapshots > 0 then
            printf("  %ssnapshots: %s%s", C.dim, table.concat(diff.snapshots, ", "), C.off)
        end
        if #diff.ignored > 0 then
            printf("  %signored (noise filter): %s%s", C.dim, table.concat(diff.ignored, ", "), C.off)
        end
    end
    return diff
end

--------------------------------------------------------------------------------
-- Probe engine
--------------------------------------------------------------------------------

local PROBE_PROMPT = "Reply with only: ok"
-- The reasoning-default baseline needs a prompt worth thinking about: ADAPTIVE
-- models skip thinking on trivial prompts, which would misread as "default OFF"
-- (bit the first claude-opus-5 probe run - it thinks by default, but not for "ok").
local REASONING_PROBE_PROMPT = "If a book has 300 pages and I read 40 percent and then 25 more pages, what page am I on? Reply with only the number."
local ABSURD_MAX_TOKENS = 10000000

-- One dummy property everywhere: dkjson encodes EMPTY tables as [], which
-- providers reject where an object is required (properties/input_schema).
local function dummyProps()
    return { ping = { type = "string", description = "Any value." } }
end

local function newFacts(family, provider, model)
    return { family = family, provider = provider, model = model,
             efforts = {}, probes = {} }
end

-- HTTP 429 (quota/rate limit) proves nothing about a capability — record it as
-- inconclusive (nil) rather than rejection, so quota noise can't poison a draft
-- (bit a gemini-3.5-flash battery: free-tier per-minute quota mid-ladder).
local function verdict(code)
    if code == 200 then return true end
    if code == 429 then return nil end
    return false
end

local function recordProbe(facts, name, ok, detail)
    table.insert(facts.probes, { name = name, ok = ok, detail = detail })
    local mark
    if ok then
        mark = C.green .. "OK" .. C.off
    elseif ok == nil then
        mark = C.yellow .. "INCONCLUSIVE (quota/rate limit - retry)" .. C.off
    else
        mark = C.red .. "REJECTED" .. C.off
    end
    printf("  [%2d] %-38s %s  %s%s%s",
        #facts.probes, name, mark, C.dim, tostring(detail or ""):sub(1, 90), C.off)
end

-- ---- Anthropic wire ---------------------------------------------------------

local ANTHROPIC_LADDER = { "low", "medium", "high", "xhigh", "max" }

local function probeAnthropic(model, api_key, verbose)
    local facts = newFacts("anthropic", "anthropic", model)
    local url = Defaults.ProviderDefaults.anthropic.base_url
    local headers = { ["x-api-key"] = api_key, ["anthropic-version"] = "2023-06-01" }

    local function req(extra, max_toks, prompt)
        local body = { model = model, max_tokens = max_toks or 32,
                       messages = { { role = "user", content = prompt or PROBE_PROMPT } } }
        for k, v in pairs(extra or {}) do body[k] = v end
        return httpPostJson(url, headers, body)
    end

    -- 1. baseline: reachable? does it think by default?
    local code, decoded, raw = req(nil, 1024, REASONING_PROBE_PROMPT)
    if code ~= 200 then
        recordProbe(facts, "baseline (bare request)", false, ModelAudit.errText(decoded, raw))
        printf("  %sbaseline failed - aborting battery (bad model id / key?)%s", C.red, C.off)
        return facts
    end
    facts.reachable = true
    local has_thinking = false
    for _i, block in ipairs(type(decoded.content) == "table" and decoded.content or {}) do
        if type(block) == "table" and block.type == "thinking" then has_thinking = true end
    end
    facts.default_reasoning = has_thinking
    facts.evidence = has_thinking and "thinking block in bare response" or "no thinking block"
    recordProbe(facts, "baseline (bare request)", true,
        facts.evidence .. " -> default " .. (has_thinking and "ON" or "OFF"))

    -- 2. sampling params
    local tcode, tdec, traw = req({ temperature = 0.7 })
    facts.temp_ok = verdict(tcode)
    if not facts.temp_ok then facts.temp_err = ModelAudit.errText(tdec, traw) end
    recordProbe(facts, "temperature=0.7", facts.temp_ok, facts.temp_err)

    -- 3. explicit disable
    local dcode, ddec, draw = req({ thinking = { type = "disabled" } })
    facts.disable_ok = verdict(dcode)
    if not facts.disable_ok then facts.disable_err = ModelAudit.errText(ddec, draw) end
    recordProbe(facts, 'thinking={type="disabled"}', facts.disable_ok, facts.disable_err)

    -- 4. adaptive + effort ladder
    facts.ladder = ANTHROPIC_LADDER
    for _i, effort in ipairs(ANTHROPIC_LADDER) do
        local ecode, edec, eraw = req({
            thinking = { type = "adaptive" },
            output_config = { effort = effort },
        })
        facts.efforts[effort] = verdict(ecode)
        if ecode == 200 then facts.adaptive_ok = true end
        recordProbe(facts, "adaptive effort=" .. effort, verdict(ecode),
            ecode ~= 200 and ModelAudit.errText(edec, eraw) or nil)
    end
    if facts.adaptive_ok == nil then facts.adaptive_ok = false end

    -- 5. legacy budget mode
    local bcode, bdec, braw = req({
        thinking = { type = "enabled", budget_tokens = 2048 } }, 4096)
    facts.budget_ok = verdict(bcode)
    if not facts.budget_ok then facts.budget_err = ModelAudit.errText(bdec, braw) end
    recordProbe(facts, "extended thinking (budget_tokens)", facts.budget_ok, facts.budget_err)

    -- 6. output ceiling from oversized max_tokens error text
    local ccode, cdec, craw = req(nil, ABSURD_MAX_TOKENS)
    if ccode == 429 then
        recordProbe(facts, "output ceiling (oversized max_tokens)", nil,
            ModelAudit.errText(cdec, craw))
    elseif ccode ~= 200 then
        local err = ModelAudit.errText(cdec, craw)
        facts.ceiling = ModelAudit.parseCeiling(err, ABSURD_MAX_TOKENS)
        recordProbe(facts, "output ceiling (oversized max_tokens)", facts.ceiling ~= nil,
            facts.ceiling and ("ceiling=" .. facts.ceiling) or err)
    else
        recordProbe(facts, "output ceiling (oversized max_tokens)", false,
            "accepted?! no ceiling error - verify by hand")
    end

    -- 7. tools sanity
    local wcode, wdec, wraw = req({
        tools = { { name = "ping", description = "Connectivity test.",
                    input_schema = { type = "object", properties = dummyProps() } } },
    })
    facts.tools_ok = verdict(wcode)
    if not facts.tools_ok then facts.tools_err = ModelAudit.errText(wdec, wraw) end
    recordProbe(facts, "tools (minimal function def)", facts.tools_ok, facts.tools_err)

    if verbose and facts.temp_err then printf("  %stemp error: %s%s", C.dim, facts.temp_err, C.off) end
    return facts
end

-- ---- OpenAI-compatible chat wire -------------------------------------------

local OPENAI_LADDER = { "none", "minimal", "low", "medium", "high", "xhigh", "max" }

-- Per-provider chat-wire probe configs. url defaults to ProviderDefaults.
local OPENAI_FAMILY = {
    openai     = { effort_key = "reasoning_effort" },
    xai        = { effort_key = "reasoning_effort" },
    perplexity = { effort_key = "reasoning_effort",
                   cost_note = "every Perplexity request also bills one web search" },
    groq       = { effort_key = "reasoning_effort" },
    together   = { effort_key = "reasoning_effort" },
    fireworks  = { effort_key = "reasoning_effort" },
    deepseek   = { binary_key = "thinking" },   -- {type="enabled"/"disabled"}
    zai        = { binary_key = "thinking" },
    mistral    = {},                            -- no reasoning params (magistral always-on)
    openrouter = { reasoning_obj = true,        -- reasoning={effort=..}/{enabled=false}
                   extra_headers = { ["HTTP-Referer"] = "https://github.com/zeeyado/koassistant.koplugin",
                                     ["X-Title"] = "KOAssistant model audit" } },
}

local function probeOpenAIFamily(provider, model, api_key, verbose)
    local facts = newFacts("openai", provider, model)
    local fam = OPENAI_FAMILY[provider]
    local pd = Defaults.ProviderDefaults[provider]
    local url = fam.url or (pd and pd.base_url)
    if not url then
        printf("  %sno chat endpoint known for %s%s", C.red, provider, C.off)
        return facts
    end
    if fam.cost_note then printf("  %snote: %s%s", C.yellow, fam.cost_note, C.off) end
    local headers = bearerHeaders(api_key)
    for k, v in pairs(fam.extra_headers or {}) do headers[k] = v end

    -- token param dance: start with max_tokens, fall back to max_completion_tokens
    local token_key = "max_tokens"
    local function req(extra, max_toks, prompt)
        local body = { model = model,
                       messages = { { role = "user", content = prompt or PROBE_PROMPT } } }
        body[token_key] = max_toks or 256
        for k, v in pairs(extra or {}) do body[k] = v end
        return httpPostJson(url, headers, body)
    end

    -- 1. baseline (+ max_completion_tokens detection)
    local code, decoded, raw = req(nil, 1024, REASONING_PROBE_PROMPT)
    if code ~= 200 then
        local err = ModelAudit.errText(decoded, raw)
        if err:find("max_completion_tokens", 1, true) then
            token_key = "max_completion_tokens"
            facts.needs_max_completion_tokens = true
            code, decoded, raw = req(nil, 1024, REASONING_PROBE_PROMPT)
        end
    end
    if code ~= 200 then
        recordProbe(facts, "baseline (bare request)", false, ModelAudit.errText(decoded, raw))
        printf("  %sbaseline failed - aborting battery (bad model id / key?)%s", C.red, C.off)
        return facts
    end
    facts.reachable = true
    facts.evidence = ModelAudit.reasoningEvidence(decoded)
    facts.default_reasoning = facts.evidence ~= nil
    -- A handful of reasoning tokens on a math prompt is a weak ON signal
    -- (could be bookkeeping overhead rather than a reasoning default).
    local rt = facts.evidence and tonumber(facts.evidence:match("^reasoning_tokens=(%d+)$"))
    facts.weak_reasoning_evidence = (rt ~= nil and rt < 64) or nil
    recordProbe(facts, "baseline (bare request)", true,
        (facts.evidence or "no reasoning evidence") ..
        " -> default " .. (facts.default_reasoning and "ON" or "OFF") ..
        (facts.weak_reasoning_evidence and " (weak signal - verify)" or "") ..
        (facts.needs_max_completion_tokens and " (needs max_completion_tokens)" or ""))

    -- 2. temperature
    local tcode, tdec, traw = req({ temperature = 0.7 }, 32)
    facts.temp_ok = verdict(tcode)
    if not facts.temp_ok then facts.temp_err = ModelAudit.errText(tdec, traw) end
    recordProbe(facts, "temperature=0.7", facts.temp_ok, facts.temp_err)

    -- 3. reasoning controls
    if fam.effort_key then
        facts.ladder = OPENAI_LADDER
        for _i, effort in ipairs(OPENAI_LADDER) do
            local ecode, edec, eraw = req({ [fam.effort_key] = effort })
            facts.efforts[effort] = verdict(ecode)
            recordProbe(facts, fam.effort_key .. "=" .. effort, verdict(ecode),
                ecode ~= 200 and ModelAudit.errText(edec, eraw) or nil)
        end
        facts.disable_ok = facts.efforts.none
    elseif fam.binary_key then
        facts.binary = true
        local oncode, ondec, onraw = req({ [fam.binary_key] = { type = "enabled" } })
        facts.binary_on_ok = verdict(oncode)
        recordProbe(facts, fam.binary_key .. '={type="enabled"}', facts.binary_on_ok,
            not facts.binary_on_ok and ModelAudit.errText(ondec, onraw) or nil)
        local offcode, offdec, offraw = req({ [fam.binary_key] = { type = "disabled" } })
        facts.binary_off_ok = verdict(offcode)
        facts.disable_ok = facts.binary_off_ok
        recordProbe(facts, fam.binary_key .. '={type="disabled"}', facts.binary_off_ok,
            not facts.binary_off_ok and ModelAudit.errText(offdec, offraw) or nil)
    elseif fam.reasoning_obj then
        facts.ladder = OPENAI_LADDER
        for _i, effort in ipairs(OPENAI_LADDER) do
            local ecode, edec, eraw = req({ reasoning = { effort = effort } })
            facts.efforts[effort] = verdict(ecode)
            recordProbe(facts, "reasoning.effort=" .. effort, verdict(ecode),
                ecode ~= 200 and ModelAudit.errText(edec, eraw) or nil)
        end
        local offcode, offdec, offraw = req({ reasoning = { enabled = false } })
        facts.disable_ok = verdict(offcode)
        recordProbe(facts, "reasoning.enabled=false", facts.disable_ok,
            not facts.disable_ok and ModelAudit.errText(offdec, offraw) or nil)
    end

    -- 4. output ceiling
    local ccode, cdec, craw = req(nil, ABSURD_MAX_TOKENS)
    if ccode == 429 then
        recordProbe(facts, "output ceiling (oversized " .. token_key .. ")", nil,
            ModelAudit.errText(cdec, craw))
    elseif ccode ~= 200 then
        local err = ModelAudit.errText(cdec, craw)
        facts.ceiling = ModelAudit.parseCeiling(err, ABSURD_MAX_TOKENS)
        recordProbe(facts, "output ceiling (oversized " .. token_key .. ")",
            facts.ceiling ~= nil, facts.ceiling and ("ceiling=" .. facts.ceiling) or err)
    else
        recordProbe(facts, "output ceiling (oversized " .. token_key .. ")", false,
            "accepted (provider may clamp silently) - check docs")
    end

    -- 5. tools sanity
    local wcode, wdec, wraw = req({
        tools = { { type = "function",
                    ["function"] = { name = "ping", description = "Connectivity test.",
                                     parameters = { type = "object", properties = dummyProps() } } } },
    })
    facts.tools_ok = verdict(wcode)
    if not facts.tools_ok then facts.tools_err = ModelAudit.errText(wdec, wraw) end
    recordProbe(facts, "tools (minimal function def)", facts.tools_ok, facts.tools_err)

    -- 6. OpenRouter bonus: per-model endpoints metadata (what the derive layer reads)
    if provider == "openrouter" then
        local text = httpGet("https://openrouter.ai/api/v1/models/" .. model .. "/endpoints", headers)
        if text then
            local dok, data = pcall(json.decode, text)
            local endpoints = dok and type(data) == "table" and type(data.data) == "table"
                and type(data.data.endpoints) == "table" and data.data.endpoints
            if endpoints then
                local union = {}
                for _i, ep in ipairs(endpoints) do
                    for _j, p in ipairs(type(ep) == "table" and type(ep.supported_parameters) == "table"
                                        and ep.supported_parameters or {}) do
                        if type(p) == "string" then union[p] = true end
                    end
                end
                facts.meta = union
                local names = {}
                for p in pairs(union) do table.insert(names, p) end
                table.sort(names)
                printf("  %ssupported_parameters: %s%s", C.dim, table.concat(names, ", "), C.off)
            end
        end
    end

    if verbose and facts.temp_err then printf("  %stemp error: %s%s", C.dim, facts.temp_err, C.off) end
    return facts
end

-- ---- Gemini wire ------------------------------------------------------------

local GEMINI_LEVELS = { "minimal", "low", "medium", "high" }

local function probeGemini(model, api_key, verbose)
    local facts = newFacts("gemini", "gemini", model)
    local base = ModelLists._docs.gemini.api_list  -- .../v1beta/models
    local url = base .. "/" .. model .. ":generateContent?key=" .. api_key

    -- 0. metadata (free): output limit, temperature range
    local mtext = httpGet(base .. "/" .. model .. "?key=" .. api_key)
    if mtext then
        local mok, mdata = pcall(json.decode, mtext)
        if mok and type(mdata) == "table" then
            facts.meta = mdata
            if type(mdata.outputTokenLimit) == "number" then
                facts.ceiling = mdata.outputTokenLimit
            end
            printf("  %smetadata: outputTokenLimit=%s inputTokenLimit=%s maxTemperature=%s%s",
                C.dim, tostring(mdata.outputTokenLimit), tostring(mdata.inputTokenLimit),
                tostring(mdata.maxTemperature), C.off)
        end
    end

    local function req(gen_extra, extra, max_toks, prompt)
        local body = {
            contents = { { parts = { { text = prompt or PROBE_PROMPT } } } },
            generationConfig = { maxOutputTokens = max_toks or 256 },
        }
        for k, v in pairs(gen_extra or {}) do body.generationConfig[k] = v end
        for k, v in pairs(extra or {}) do body[k] = v end
        return httpPostJson(url, nil, body)
    end

    -- 1. baseline: thoughtsTokenCount?
    local code, decoded, raw = req(nil, nil, 1024, REASONING_PROBE_PROMPT)
    if code ~= 200 then
        recordProbe(facts, "baseline (bare request)", false, ModelAudit.errText(decoded, raw))
        printf("  %sbaseline failed - aborting battery (bad model id / key?)%s", C.red, C.off)
        return facts
    end
    facts.reachable = true
    local um = type(decoded.usageMetadata) == "table" and decoded.usageMetadata
    local thoughts = um and type(um.thoughtsTokenCount) == "number" and um.thoughtsTokenCount or 0
    facts.default_reasoning = thoughts > 0
    facts.evidence = thoughts > 0 and ("thoughtsTokenCount=" .. thoughts) or "no thoughts tokens"
    recordProbe(facts, "baseline (bare request)", true,
        facts.evidence .. " -> default " .. (facts.default_reasoning and "ON" or "OFF"))

    -- 2. temperature (metadata usually allows; probe confirms)
    local tcode, tdec, traw = req({ temperature = 0.7 }, nil, 32)
    facts.temp_ok = verdict(tcode)
    if not facts.temp_ok then facts.temp_err = ModelAudit.errText(tdec, traw) end
    recordProbe(facts, "temperature=0.7", facts.temp_ok, facts.temp_err)

    -- 3. thinkingLevel ladder (Gemini 3 effort axis)
    facts.ladder = GEMINI_LEVELS
    local any_level = false
    for _i, level in ipairs(GEMINI_LEVELS) do
        local ecode, edec, eraw = req({ thinkingConfig = { thinkingLevel = level:upper() } }, nil, 32)
        facts.efforts[level] = verdict(ecode)
        if ecode == 200 then any_level = true end
        recordProbe(facts, "thinkingLevel=" .. level:upper(), verdict(ecode),
            ecode ~= 200 and ModelAudit.errText(edec, eraw) or nil)
    end
    facts.adaptive_ok = any_level  -- effort-style control accepted

    -- 4. thinkingBudget (2.5 budget axis; 0 = disable)
    local zcode, zdec, zraw = req({ thinkingConfig = { thinkingBudget = 0 } }, nil, 32)
    facts.disable_ok = verdict(zcode)
    recordProbe(facts, "thinkingBudget=0 (disable)", facts.disable_ok,
        not facts.disable_ok and ModelAudit.errText(zdec, zraw) or nil)
    local bcode, bdec, braw = req({ thinkingConfig = { thinkingBudget = 1024 } }, nil, 32)
    facts.budget_ok = verdict(bcode)
    recordProbe(facts, "thinkingBudget=1024", facts.budget_ok,
        not facts.budget_ok and ModelAudit.errText(bdec, braw) or nil)

    -- 5. tools sanity
    local wcode, wdec, wraw = req(nil, {
        tools = { { functionDeclarations = { { name = "ping", description = "Connectivity test.",
                    parameters = { type = "object", properties = dummyProps() } } } } },
    }, 32)
    facts.tools_ok = verdict(wcode)
    if not facts.tools_ok then facts.tools_err = ModelAudit.errText(wdec, wraw) end
    recordProbe(facts, "tools (functionDeclarations)", facts.tools_ok, facts.tools_err)
    printf("  %sgoogle_search grounding: not probed (separate quota) - set per family/docs%s",
        C.dim, C.off)

    if verbose and facts.temp_err then printf("  %stemp error: %s%s", C.dim, facts.temp_err, C.off) end
    return facts
end

--------------------------------------------------------------------------------
-- Current resolution + draft stanzas
--------------------------------------------------------------------------------

local AUDIT_CAPS = {
    "tools", "reasoning", "reasoning_gated", "thinking", "adaptive_thinking",
    "extended_thinking", "thinking_budget", "no_sampling_params",
}

function ModelAudit.currentResolution(provider, model)
    local caps = {}
    for _i, cap in ipairs(AUDIT_CAPS) do
        caps[cap] = ModelConstraints.supportsCapability(provider, model, cap)
    end
    local params = { temperature = 0.7 }
    params = ModelConstraints.apply(provider, model, params)
    return {
        profile = ModelConstraints.getReasoningProfile(provider, model),
        caps = caps,
        temp_after_apply = params and params.temperature,
        clamped = ModelConstraints.clampMaxTokens(provider, model, ABSURD_MAX_TOKENS),
    }
end

local function orderedAccepted(facts, exclude)
    local out = {}
    for _i, e in ipairs(facts.ladder or {}) do
        if facts.efforts[e] and not (exclude and exclude[e]) then
            table.insert(out, e)
        end
    end
    return out
end

local function quoteList(list)
    local parts = {}
    for _i, v in ipairs(list) do table.insert(parts, string.format("%q", v)) end
    return table.concat(parts, ", ")
end

local function mark(needs_curation)
    return needs_curation and (C.yellow .. "  <-- NEEDS CURATION" .. C.off)
        or (C.dim .. "  (already covered by current resolution)" .. C.off)
end

-- Pure-ish (uses facts + current only): returns printable lines.
function ModelAudit.draftStanzas(facts, current)
    local lines = {}
    local function add(fmt, ...)
        table.insert(lines, select("#", ...) > 0 and string.format(fmt, ...) or fmt)
    end
    local provider, model = facts.provider, facts.model
    local profile = current.profile or {}

    add("%s-- DRAFT for model_constraints.lua (REVIEW - never auto-applied) ------------%s",
        C.bold, C.off)

    -- Capability list deltas
    add("-- capabilities.%s:", provider)
    local function capLine(cap, probed, note)
        if probed == nil then return end
        if probed then
            add('--   %-20s += "%s"%s%s', cap, model, note or "", mark(not current.caps[cap]))
        elseif current.caps[cap] then
            add('--   %-20s currently resolves TRUE but the probe result disagrees %s<-- investigate%s',
                cap, C.red, C.off)
        end
    end
    if facts.family == "anthropic" then
        capLine("adaptive_thinking", facts.adaptive_ok)
        capLine("extended_thinking", facts.budget_ok)
        capLine("no_sampling_params", facts.temp_ok == false)
        capLine("tools", facts.tools_ok)
    elseif facts.family == "gemini" then
        capLine("thinking", facts.default_reasoning or facts.adaptive_ok or facts.budget_ok)
        capLine("thinking_budget", facts.budget_ok)
        capLine("tools", facts.tools_ok)
    else
        local reasons = facts.default_reasoning or facts.disable_ok
            or #orderedAccepted(facts) > 0 or facts.binary_on_ok
        capLine("reasoning", reasons or false)
        if provider == "openai" and reasons and facts.default_reasoning == false then
            capLine("reasoning_gated", true, "  (efforts accepted, default OFF)")
        end
        if facts.binary then capLine("thinking", facts.binary_on_ok) end
        capLine("tools", facts.tools_ok)
        if provider == "openai" and facts.tools_ok == false then
            add("--   NOTE: probe uses the chat wire; this plugin runs gpt-5.x function tools")
            add("--   over the Responses API (openai.lua R3) - a chat-wire rejection does not")
            add("--   prove tools are absent")
        end
    end

    -- Temperature constraint (non-anthropic wire: forced value, not capability)
    if facts.temp_ok == false and facts.family ~= "anthropic" then
        local covered = current.temp_after_apply ~= 0.7
        add("-- ModelConstraints.%s (forced params):%s", provider, mark(not covered))
        add('    ["%s"] = { temperature = 1.0 },', model)
    end

    -- Reasoning profile stanza
    local axis, options
    if facts.family == "anthropic" then
        axis = facts.adaptive_ok and "adaptive_effort"
            or (facts.budget_ok and "budget") or "none"
        options = orderedAccepted(facts)
    elseif facts.binary then
        axis = (facts.binary_on_ok or facts.binary_off_ok) and "binary" or "none"
    else
        options = orderedAccepted(facts, { none = true })
        axis = #options > 0 and "effort"
            or (facts.family == "gemini" and facts.budget_ok and "budget") or "none"
    end

    local profile_differs = (profile.axis or "none") ~= axis
        or (axis ~= "none" and (profile.default_state == "on") ~= (facts.default_reasoning == true))
    if axis == "none" then
        add("-- reasoning profile: no controls accepted -> axis \"none\" / passthrough%s",
            mark(profile_differs))
    else
        add("-- reasoning_profiles.%s - insert BEFORE any family fallback entries:%s",
            provider, mark(profile_differs))
        if facts.family == "anthropic" and facts.adaptive_ok and not facts.default_reasoning then
            add('-- CAUTION: default_state "off" inferred from one prompt; adaptive models may')
            add("-- skip thinking even on the math probe - verify against the model announcement")
        end
        if facts.weak_reasoning_evidence then
            add('-- CAUTION: default_state "on" rests on a small reasoning-token count - verify')
        end
        local default_state = facts.default_reasoning and "on" or "off"
        local can_disable = facts.disable_ok and true or false
        if axis == "binary" then
            add('    { match = "%s", axis = "binary", default_state = "%s",', model, default_state)
            add('      can_disable = %s, can_enable = %s },',
                tostring(can_disable), tostring(facts.binary_on_ok and true or false))
        else
            local default_option = facts.efforts and facts.efforts.high and "high"
                or (options and options[1]) or "medium"
            add('    { match = "%s", axis = "%s", default_state = "%s",', model, axis, default_state)
            add('      can_disable = %s, can_enable = true,', tostring(can_disable))
            if options and #options > 0 then
                add('      options = { %s }, default_option = "%s",', quoteList(options), default_option)
            end
            local minimal = can_disable and '{ state = "off" }'
                or string.format('{ state = "on", option = "%s" }', options and options[1] or "low")
            local maximum = string.format('{ state = "on", option = "%s" }',
                options and options[#options] or "high")
            add('      stance_map = { minimal = %s, maximum = %s },', minimal, maximum)
            local flags = {}
            if facts.family == "anthropic" and facts.temp_ok == false then
                table.insert(flags, "needs_no_sampling = true")
            end
            if facts.efforts and facts.efforts.none and facts.family ~= "anthropic" then
                table.insert(flags, 'off_option = "none"')
            end
            add('      %s},', #flags > 0 and (table.concat(flags, ", ") .. " ") or "")
        end
    end

    -- Output ceiling
    if facts.ceiling then
        local covered = current.clamped == facts.ceiling
        add("-- _max_output_tokens.%s:%s", provider, mark(not covered))
        add('    ["%s"] = %d,', model, facts.ceiling)
    end

    -- Wire notes that live outside model_constraints.lua
    if facts.needs_max_completion_tokens then
        add("%s-- NOTE: needs max_completion_tokens - check the prefix rule in koassistant_api/openai.lua%s",
            C.yellow, C.off)
    end

    add("%s-- koassistant_model_lists.lua (HUMAN decisions) ---------------------------%s",
        C.bold, C.off)
    add('--   %s array: add "%s" (position matters - first entry = provider default)', provider, model)
    add("--   _tiers: place by price/positioning (reasoning/flagship/standard/fast/ultrafast)")
    add("--   then run: lua tests/run_tests.lua --models %s", provider)
    return lines
end

--------------------------------------------------------------------------------
-- Probe dispatch
--------------------------------------------------------------------------------

local function probeModel(provider, model, api_key, verbose)
    banner("PROBE " .. provider .. " / " .. model)
    if not TestConfig.isValidApiKey(api_key) then
        printf("  %sno API key for %s in apikeys.lua%s", C.red, provider, C.off)
        return nil
    end
    printf("  %s~10-14 micro-requests (max_tokens 32..1024) - fractions of a cent%s", C.dim, C.off)

    local facts
    if provider == "anthropic" then
        facts = probeAnthropic(model, api_key, verbose)
    elseif provider == "gemini" then
        facts = probeGemini(model, api_key, verbose)
    elseif OPENAI_FAMILY[provider] then
        facts = probeOpenAIFamily(provider, model, api_key, verbose)
    else
        printf("  %sno probe adapter for %q yet%s (have: anthropic, gemini, %s)",
            C.red, provider, C.off, "openai/deepseek/xai/zai/mistral/perplexity/openrouter/groq/together/fireworks")
        return nil
    end

    if facts and facts.reachable then
        print("")
        local current = ModelAudit.currentResolution(provider, model)
        for _i, line in ipairs(ModelAudit.draftStanzas(facts, current)) do
            print(line)
        end
    end
    return facts
end

--------------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------------

local MAX_PROBE_NEW = 10

local function main()
    -- arg parsing
    local providers, verbose = {}, false
    local mode, probe_provider, probe_model = "discover", nil, nil
    local i = 1
    while i <= #arg do
        local a = arg[i]
        if a == "--help" or a == "-h" then
            print("Usage: lua tests/model_audit.lua [providers...] [--probe <provider> <model>] " ..
                  "[--probe-new] [--verbose]")
            os.exit(0)
        elseif a == "--verbose" or a == "-v" then
            verbose = true
        elseif a == "--probe" then
            mode = "probe"
            probe_provider, probe_model = arg[i + 1], arg[i + 2]
            i = i + 2
            if not probe_provider or not probe_model then
                print("--probe needs <provider> <model>")
                os.exit(1)
            end
        elseif a == "--probe-new" then
            mode = "probe-new"
        elseif a:match("^%-") then
            printf("unknown option: %s (see --help)", a)
            os.exit(1)
        else
            table.insert(providers, a)
        end
        i = i + 1
    end

    if not HAS_NETWORK or not JSON_OK then
        print("Real HTTP/JSON modules unavailable (luasocket/luasec/dkjson).")
        print("Run this first, then retry:")
        print('  eval "$(luarocks --lua-version 5.5 path)"')
        os.exit(1)
    end
    require("socket.http").TIMEOUT = 60
    pcall(function() require("ssl.https").TIMEOUT = 60 end)

    local apikeys = TestConfig.loadApiKeys()

    if mode == "probe" then
        local facts = probeModel(probe_provider, probe_model, apikeys[probe_provider], verbose)
        os.exit((facts and facts.reachable) and 0 or 1)
    end

    -- discovery (both "discover" and "probe-new" start here)
    if #providers == 0 then
        local skipped = {}
        for _i, p in ipairs(ModelLists.getAllProviders()) do
            if DISCOVERY[p] then
                table.insert(providers, p)
            else
                table.insert(skipped, p)
            end
        end
        table.sort(providers)
        table.sort(skipped)
        printf("%sno discovery adapter (validate via --models instead): %s%s",
            C.dim, table.concat(skipped, ", "), C.off)
    end

    local to_probe = {}
    for _i, provider in ipairs(providers) do
        if not DISCOVERY[provider] then
            banner(provider)
            local docs = ModelLists._docs[provider]
            printf("  %sskipped: %s%s", C.dim,
                (docs and docs.api_list) and "no discovery adapter yet"
                or "no public list endpoint - validate via: lua tests/run_tests.lua --models "
                   .. provider, C.off)
        else
            local diff = runDiscovery(provider, apikeys[provider], verbose)
            if diff then
                for _j, id in ipairs(diff.new) do
                    table.insert(to_probe, { provider = provider, model = id })
                end
            end
        end
    end

    if mode == "probe-new" then
        if #to_probe == 0 then
            print("\nNothing new to probe.")
        else
            printf("\n%d new model(s) to probe.", #to_probe)
            for idx, entry in ipairs(to_probe) do
                if idx > MAX_PROBE_NEW then
                    printf("%sstopping at %d probes - rerun with --probe %s %s (and beyond) for the rest%s",
                        C.yellow, MAX_PROBE_NEW, entry.provider, entry.model, C.off)
                    break
                end
                probeModel(entry.provider, entry.model, apikeys[entry.provider], verbose)
            end
        end
    elseif #to_probe > 0 then
        printf("\n%sTip:%s probe new ids with --probe (or all at once with --probe-new).",
            C.bold, C.off)
    end
end

-- Run main() only when executed directly (unit tests require this file as a
-- lib; the path-boundary anchor keeps test_model_audit.lua from matching).
if arg and arg[0]
        and (arg[0]:match("^model_audit%.lua$") or arg[0]:match("/model_audit%.lua$")) then
    main()
end

return ModelAudit
