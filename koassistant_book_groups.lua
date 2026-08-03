--[[--
Book groups (xray_ecosystem_plan.md item 46, ref #90).

A group is a named, manually ORDERED list of documents — the order is the
reading/spoiler order and is the single ordering truth for every consumer:
merge suggestions (earlier feeds later), prev/next artifact navigation, and
the future series X-Ray ("build through volume N"). Nothing here is
series-specific: series, projects, and paper sets are the same object.

Storage: settings_dir/koassistant_book_groups.lua via LuaSettings —
{ version = 1, next_id = N, groups = { { id, name, books = {path,...} } } }.
A settings-dir FILE (not a G_reader_settings key) because groups are
user-authored data the backup manager must cover; global keys are
rebuildable-index territory. Registered in koassistant_storage_registry.lua.

Path identity: file paths, re-keyed on MOVE by the DocSettings.updateLocation
patch (main.lua). COPY does not join groups (a duplicate file is not a series
member); DELETE keeps the entry — missing files show "(missing)" and are
removed manually, never auto-pruned (a book on a removed SD card must not
fall out of its series). Index rebuild/prune must NOT touch groups.

Pure-loadable: UI-free; disk access goes through LuaSettings lazily.
]]

local logger = require("logger")

local BookGroups = {}

local settings  -- lazy LuaSettings handle

local function store()
    if not settings then
        local DataStorage = require("datastorage")
        local LuaSettings = require("luasettings")
        settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/koassistant_book_groups.lua")
    end
    return settings
end

--- Test seam: inject a fake LuaSettings-like handle (readSetting/saveSetting/flush).
function BookGroups._setStoreForTests(s)
    settings = s
end

local function load()
    local data = store():readSetting("book_groups")
    if type(data) ~= "table" or type(data.groups) ~= "table" then
        data = { version = 1, next_id = 1, groups = {} }
    end
    data.next_id = tonumber(data.next_id) or 1
    return data
end

local function save(data)
    store():saveSetting("book_groups", data)
    store():flush()
end

--- All groups, in creation order. Returns the live stored array — treat as
--- read-only; mutate through the API below.
--- @return table Array of { id, name, books }
function BookGroups.all()
    return load().groups
end

function BookGroups.byId(id)
    for _idx, group in ipairs(load().groups) do
        if group.id == id then return group end
    end
    return nil
end

--- @return table The created group
function BookGroups.create(name)
    local data = load()
    local group = {
        id = "g" .. data.next_id,
        name = (type(name) == "string" and name ~= "") and name or "?",
        books = {},
    }
    data.next_id = data.next_id + 1
    data.groups[#data.groups + 1] = group
    save(data)
    return group
end

function BookGroups.rename(id, name)
    if type(name) ~= "string" or name == "" then return false end
    local data = load()
    for _idx, group in ipairs(data.groups) do
        if group.id == id then
            group.name = name
            save(data)
            return true
        end
    end
    return false
end

function BookGroups.remove(id)
    local data = load()
    for i, group in ipairs(data.groups) do
        if group.id == id then
            table.remove(data.groups, i)
            save(data)
            return true
        end
    end
    return false
end

local function indexOf(group, path)
    for i, p in ipairs(group.books or {}) do
        if p == path then return i end
    end
    return nil
end

--- Append a book (no duplicates; order = add order until reordered).
--- @return boolean added
function BookGroups.addBook(id, path)
    if type(path) ~= "string" or path == "" then return false end
    local data = load()
    for _idx, group in ipairs(data.groups) do
        if group.id == id then
            if indexOf(group, path) then return false end
            group.books[#group.books + 1] = path
            save(data)
            return true
        end
    end
    return false
end

function BookGroups.removeBook(id, path)
    local data = load()
    for _idx, group in ipairs(data.groups) do
        if group.id == id then
            local i = indexOf(group, path)
            if not i then return false end
            table.remove(group.books, i)
            save(data)
            return true
        end
    end
    return false
end

--- Move a book by delta positions (-1 = up/earlier, 1 = down/later), clamped.
--- @return boolean moved
function BookGroups.moveBook(id, path, delta)
    local data = load()
    for _idx, group in ipairs(data.groups) do
        if group.id == id then
            local i = indexOf(group, path)
            if not i then return false end
            local j = math.max(1, math.min(#group.books, i + (tonumber(delta) or 0)))
            if j == i then return false end
            table.remove(group.books, i)
            table.insert(group.books, j, path)
            save(data)
            return true
        end
    end
    return false
end

--- Every group containing the path, in creation order.
function BookGroups.groupsFor(path)
    local out = {}
    for _idx, group in ipairs(load().groups) do
        if indexOf(group, path) then out[#out + 1] = group end
    end
    return out
end

function BookGroups.positionOf(group, path)
    return indexOf(group, path)
end

--- Ordered neighbors of a book in its FIRST containing group (a book in
--- several groups navigates along the first one — documented limitation).
--- @return string|nil prev_path, string|nil next_path, table|nil group
function BookGroups.neighbors(path)
    local group = BookGroups.groupsFor(path)[1]
    if not group then return nil, nil, nil end
    local i = indexOf(group, path)
    return group.books[i - 1], group.books[i + 1], group
end

--- Paths BEFORE the book in its first containing group, in group order
--- (book 1 first) — the "fold in all earlier books" input.
--- @return table paths, table|nil group
function BookGroups.predecessorsOf(path)
    local group = BookGroups.groupsFor(path)[1]
    if not group then return {}, nil end
    local out = {}
    for _idx, p in ipairs(group.books) do
        if p == path then break end
        out[#out + 1] = p
    end
    return out, group
end

--- updateLocation hook (main.lua patch): MOVE re-keys memberships; COPY does
--- not join groups; DELETE keeps the entry (missing-file policy above).
function BookGroups.updateForMove(old_path, new_path, copy)
    if copy or not new_path or not old_path then return end
    local data = load()
    local changed = false
    for _idx, group in ipairs(data.groups) do
        local i = indexOf(group, old_path)
        if i then
            -- The new path may already be a member (odd overwrite-move): drop
            -- the old slot instead of duplicating
            if indexOf(group, new_path) then
                table.remove(group.books, i)
            else
                group.books[i] = new_path
            end
            changed = true
        end
    end
    if changed then
        save(data)
        logger.info("KOAssistant BookGroups: re-keyed moved book in groups")
    end
end

--- Does the file exist on disk? (Missing members stay listed, marked.)
function BookGroups.fileExists(path)
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok or not lfs then return true end
    return lfs.attributes(path, "mode") == "file"
end

--- Display title for any group member: AI metadata override > doc_props >
--- filename. Same identity rule as the merge picker.
function BookGroups.displayTitle(path, ui)
    local title
    local ok, ds = pcall(function()
        return require("koassistant_doc_settings").resolve(path, ui)
    end)
    if ok and ds then
        local props = ds:readSetting("doc_props") or {}
        title = props.display_title or props.title
        local ok_ov, ov_title = pcall(function()
            return require("koassistant_book_settings").getMetadataOverride(ds)
        end)
        if ok_ov and ov_title ~= nil then title = ov_title end
    end
    if not title or title == "" then
        title = path:match("([^/]+)%.[^.]+$") or path:match("([^/]+)$") or path
    end
    return title
end

--- Order merge-picker candidates by group relation to the current book
--- (item 46 "earlier feeds later"): predecessors first, NEAREST predecessor
--- on top (book N-1, then N-2, …), then later group-mates in group order,
--- then everything else in the order given (caller pre-sorts alphabetically).
--- Annotates group-mates in place: group_name, group_pos, group_direction
--- ("before"/"after") — the confirm dialog's directional warning reads these.
--- Pure when `groups` is passed (tests); defaults to the stored groups.
--- @param candidates table Array of { file, ... } (mutated: annotations only)
--- @param current_path string The target book
--- @param groups table|nil Override for tests
--- @return table New sorted array (same candidate tables)
function BookGroups.orderCandidates(candidates, current_path, groups)
    groups = groups or load().groups
    local group, cur_pos
    for _idx, g in ipairs(groups) do
        local i = indexOf(g, current_path)
        if i then group, cur_pos = g, i break end
    end
    local before, after, rest = {}, {}, {}
    for _idx, cand in ipairs(candidates or {}) do
        local pos = group and indexOf(group, cand.file)
        if pos then
            cand.group_name = group.name
            cand.group_pos = pos
            cand.group_direction = pos < cur_pos and "before" or "after"
            if pos < cur_pos then before[#before + 1] = cand
            else after[#after + 1] = cand end
        else
            rest[#rest + 1] = cand
        end
    end
    table.sort(before, function(a, b) return a.group_pos > b.group_pos end)
    table.sort(after, function(a, b) return a.group_pos < b.group_pos end)
    local out = {}
    for _idx, list in ipairs({ before, after, rest }) do
        for _idx2, cand in ipairs(list) do out[#out + 1] = cand end
    end
    return out
end

return BookGroups
