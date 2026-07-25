-- Model Overrides — the non-curated layers of capability resolution (agenda item 19).
--
-- Two data layers, both lazy-loaded on first use:
--   USER    <plugin_dir>/custom_models.lua — hand-written grants/denies, reasoning
--           profiles, param constraints, output caps (see custom_models.lua.sample).
--           Highest precedence at every model_constraints.lua chokepoint.
--   DERIVED <settings_dir>/koassistant_model_caps.lua — machine-owned cache of
--           provider-reported metadata (today: OpenRouter supported_parameters,
--           fetched per-model in main.lua). Consulted AFTER the curated lists.
--
-- This module is pure-loadable: no top-level KOReader requires (unit tests run it
-- under plain lua). File IO happens inside pcall on first access; when the KOReader
-- environment is absent everything degrades to "no data".
--
-- prefixMatch is duplicated from model_constraints.lua (4 lines) so the require
-- direction stays one-way: model_constraints → here, never back.

local ModelOverrides = {}

-- Test seams: inject layers directly (also skips file loading).
ModelOverrides._user = nil     -- parsed custom_models.lua content
ModelOverrides._derived = nil  -- parsed koassistant_model_caps.lua content

local function prefixMatch(model, pattern)
    if not model or not pattern then return false end
    return model == pattern or model:match("^" .. pattern:gsub("%-", "%%-")) ~= nil
end

local function pluginDir()
    local str = debug.getinfo(1, "S").source:sub(2)
    return str:match("(.*/)")
end

local function settingsCapsPath()
    local ok, DataStorage = pcall(require, "datastorage")
    if not ok then return nil end
    return DataStorage:getSettingsDir() .. "/koassistant_model_caps.lua"
end

local function loadLuaFile(path)
    if not path then return nil end
    local f = io.open(path, "r")
    if not f then return nil end
    f:close()
    local ok, data = pcall(dofile, path)
    if ok and type(data) == "table" then return data end
    return nil
end

local function ensureUser()
    if ModelOverrides._user == nil then
        ModelOverrides._user = loadLuaFile(pluginDir() .. "custom_models.lua") or false
    end
    return ModelOverrides._user or nil
end

local function ensureDerived()
    if ModelOverrides._derived == nil then
        ModelOverrides._derived = loadLuaFile(settingsCapsPath()) or false
    end
    return ModelOverrides._derived or nil
end

--- User capability grant/deny for a provider/model. Longest matching prefix wins;
--- "" matches every model of the provider (lowest priority).
--- @return boolean|nil true=grant, false=deny, nil=no opinion
function ModelOverrides.capabilityOverride(provider, model, capability)
    local user = ensureUser()
    local map = user and user.capabilities and user.capabilities[provider]
    map = map and map[capability]
    if type(map) ~= "table" then return nil end
    local best, best_len
    for prefix, granted in pairs(map) do
        if type(prefix) == "string" and prefixMatch(model, prefix) then
            if not best_len or #prefix > best_len then
                best, best_len = granted, #prefix
            end
        end
    end
    if best == nil then return nil end
    return best and true or false
end

--- First user reasoning profile matching the model (array order = user's order).
--- @return table|nil profile (builtin shape, optionally + `wire` for custom providers)
function ModelOverrides.findProfile(provider, model)
    local user = ensureUser()
    local list = user and user.reasoning_profiles and user.reasoning_profiles[provider]
    if type(list) ~= "table" then return nil end
    for _idx, p in ipairs(list) do
        if type(p) == "table" and p.match and prefixMatch(model, p.match) then
            return p
        end
    end
    return nil
end

--- User param constraints for a provider/model (like ModelConstraints[provider]
--- entries: { temperature = 1.0, ... }). Longest matching prefix wins.
--- @return table|nil
function ModelOverrides.constraintsFor(provider, model)
    local user = ensureUser()
    local map = user and user.constraints and user.constraints[provider]
    if type(map) ~= "table" then return nil end
    local best, best_len
    for prefix, values in pairs(map) do
        if type(prefix) == "string" and type(values) == "table"
                and prefixMatch(model, prefix) then
            if not best_len or #prefix > best_len then
                best, best_len = values, #prefix
            end
        end
    end
    return best
end

--- User output-token ceiling for a provider/model. Longest matching prefix wins.
--- @return number|nil
function ModelOverrides.maxOutputTokens(provider, model)
    local user = ensureUser()
    local map = user and user.max_output_tokens and user.max_output_tokens[provider]
    if type(map) ~= "table" then return nil end
    local best, best_len
    for prefix, cap in pairs(map) do
        if type(prefix) == "string" and type(cap) == "number"
                and prefixMatch(model, prefix) then
            if not best_len or #prefix > best_len then
                best, best_len = cap, #prefix
            end
        end
    end
    return best
end

--- Derived (provider-reported) support for a wire parameter, e.g. "tools",
--- "reasoning". Exact model id only — derived data is never prefix-matched.
--- @return boolean|nil true/false when metadata exists for the model, nil when not
function ModelOverrides.derivedParam(provider, model, param)
    local derived = ensureDerived()
    local entry = derived and derived[provider] and derived[provider][model]
    if not entry or type(entry.params) ~= "table" then return nil end
    return entry.params[param] == true
end

-- Flat serializer for the derived cache (shape: provider -> model -> {fetched, params}).
local function serializeDerived(data)
    local out = { "-- Auto-generated by KOAssistant (provider model metadata cache).",
                  "-- Safe to delete; re-fetched via the custom-models menu.",
                  "return {", string.format("    version = %d,", data.version or 1) }
    for provider, models in pairs(data) do
        if type(models) == "table" and provider ~= "version" then
            out[#out + 1] = string.format("    [%q] = {", provider)
            for model, entry in pairs(models) do
                local params = {}
                for p, v in pairs(entry.params or {}) do
                    if v == true then params[#params + 1] = string.format("[%q]=true", p) end
                end
                table.sort(params)
                out[#out + 1] = string.format("        [%q] = { fetched = %d, params = { %s } },",
                    model, entry.fetched or 0, table.concat(params, ", "))
            end
            out[#out + 1] = "    },"
        end
    end
    out[#out + 1] = "}"
    return table.concat(out, "\n")
end

--- Record fetched metadata for a model and persist the cache.
--- @param provider string e.g. "openrouter"
--- @param model string exact model id
--- @param params table set-table of supported wire params ({ tools = true, ... })
--- @return boolean persisted
function ModelOverrides.recordDerived(provider, model, params)
    local derived = ensureDerived() or { version = 1 }
    derived[provider] = derived[provider] or {}
    derived[provider][model] = { fetched = os.time(), params = params or {} }
    ModelOverrides._derived = derived
    local path = settingsCapsPath()
    if not path then return false end
    local f = io.open(path, "w")
    if not f then return false end
    f:write(serializeDerived(derived))
    f:close()
    return true
end

--- Test seams / reload hooks. nil re-arms lazy file loading; false = "loaded,
--- nothing there" (same sentinel the lazy loader stores for a missing file).
function ModelOverrides._setUserForTests(tbl)
    ModelOverrides._user = tbl
end
function ModelOverrides._setDerivedForTests(tbl)
    ModelOverrides._derived = tbl
end

return ModelOverrides
