-- The documentation system (docs/wiki_system.md): wiki/ is the reference and
-- README.md the front door. These rules keep both navigable and in step with
-- the code without anyone remembering them:
--   - the sidebar lists every page once and every listed page exists
--   - page names are ASCII; links use one syntax ([text](Page#anchor)), never
--     .md (the live wiki has no files) or [[wikilinks]]; every link resolves
--     to a page and a heading; images are absolute URLs
--   - every "Settings → A → B" path in the pages and the README is a path of
--     the KOAssistant menu as koassistant/ui/settings_schema.lua defines it, so a
--     menu reorganization lists every sentence it made stale
--   - README.md stays under its size ceiling
--   - wiki/Settings-Reference.md equals tests/tools/gen_settings_reference.lua's
--     output (a schema change is followed by regenerating it)
--   - the release-notes draft's <!-- wiki: --> tags name existing pages
--   - the release zip leaves wiki/ out
--   - every "Settings → …" path inside a _("...") string of the plugin's code
--     is a path of the menu too (in-app notices went stale through two reorgs, B152)
--   - the Providers page's generated tables equal tests/tools/gen_provider_tables.lua's
--     output, every built-in provider has a display name there, and the provider
--     tables of the wiki and the README list every provider with its status
--
-- Run: lua tests/unit/test_wiki_pages.lua  (or lua tests/run_tests.lua --unit)

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({
        plugin_dir .. "/?.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
    return plugin_dir, tests_dir
end
local plugin_dir, tests_dir = setupPaths()
require("mock_koreader")
local TestRunner = require("test_runner"):new()

local README_MAX_LINES = 600

local function read(rel)
    local f = io.open(plugin_dir .. "/" .. rel, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function listPages()
    local names = {}
    local h = io.popen('ls "' .. plugin_dir .. '/wiki"/*.md 2>/dev/null')
    if h then
        for line in h:lines() do
            local name = line:match("([^/]+)%.md$")
            if name then names[#names + 1] = name end
        end
        h:close()
    end
    table.sort(names)
    return names
end

-- Fenced code blocks and inline code spans are examples, not headings, links
-- or menu paths; every check reads the text without them.
local function stripCode(text)
    local out = {}
    local in_fence = false
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        if line:match("^%s*```") then
            in_fence = not in_fence
            out[#out + 1] = ""
        elseif in_fence then
            out[#out + 1] = ""
        else
            out[#out + 1] = (line:gsub("`[^`\n]*`", "``"))
        end
    end
    return table.concat(out, "\n")
end

local pages = listPages()
local page_text = {}
for _idx, name in ipairs(pages) do page_text[name] = stripCode(read("wiki/" .. name .. ".md") or "") end
local function isPage(name) return page_text[name] ~= nil end
local function isStub(name)
    local t = page_text[name] or ""
    return t:match("^#[^\n]*\n+Moved to %[[^%]]+%]%([^%)]+%)%.?%s*$") ~= nil
end

-- GitHub's heading anchors: lowercase, punctuation dropped (the non-ASCII
-- kinds too: …, →), spaces to hyphens, a repeated heading gets -1, -2, ...
-- Headings are ASCII (docs/wiki_system.md section 3), so dropping every byte
-- above 127 is GitHub's rule for them.
local function slug(heading)
    local s = heading:lower():gsub("[^%w%s%-_]", ""):gsub("%s", "-")
    return s
end
local function headingSlugs(text)
    local seen, slugs = {}, {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        local h = line:match("^#+%s+(.-)%s*$")
        if h then
            -- a trailing " <!-- ... -->" or "{#id}" is not part of the anchor
            h = h:gsub("%s*<!%-%-.-%-%->%s*$", "")
            local s = slug(h)
            local n = seen[s] or 0
            seen[s] = n + 1
            if n > 0 then s = s .. "-" .. n end
            slugs[s] = true
        end
    end
    for id in text:gmatch('<a id="([^"]+)"') do slugs[id] = true end
    return slugs
end
local readme = stripCode(read("README.md") or "")
local readme_slugs = headingSlugs(readme)
local page_slugs = {}
for name, text in pairs(page_text) do page_slugs[name] = headingSlugs(text) end

print("\n  [the wiki: pages and sidebar]")

TestRunner:test("every page name is ASCII letters, digits and hyphens", function()
    local bad = {}
    for _idx, name in ipairs(pages) do
        if not name:match("^[A-Za-z0-9_%-]+$") then bad[#bad + 1] = name end
    end
    TestRunner:assertEqual(table.concat(bad, ", "), "", "non-ASCII or odd page names")
end)

TestRunner:test("the sidebar lists every page once, and only pages that exist", function()
    local sidebar = page_text["_Sidebar"] or ""
    TestRunner:assertTrue(#sidebar > 0, "wiki/_Sidebar.md exists")
    local counts = {}
    for target in sidebar:gmatch("%]%(([^)#]+)%)") do counts[target] = (counts[target] or 0) + 1 end
    local problems = {}
    for target, n in pairs(counts) do
        if not isPage(target) then problems[#problems + 1] = "listed but missing: " .. target end
        if n > 1 then problems[#problems + 1] = "listed twice: " .. target end
    end
    for _idx, name in ipairs(pages) do
        if name ~= "_Sidebar" and name ~= "_Footer" and not isStub(name) and not counts[name] then
            problems[#problems + 1] = "page not in the sidebar: " .. name
        end
    end
    table.sort(problems)
    TestRunner:assertEqual(table.concat(problems, "\n      "), "", "sidebar")
end)

TestRunner:test("every page starts with one H1", function()
    local problems = {}
    for _idx, name in ipairs(pages) do
        if name ~= "_Sidebar" and name ~= "_Footer" then
            local text = page_text[name]
            local first = text:match("^(#[^\n]*)")
            if not first or first:match("^##") then problems[#problems + 1] = name .. " (no H1 first)" end
            local _, h1s = text:gsub("\n# ", "")
            if h1s > 0 then problems[#problems + 1] = name .. " (a second H1)" end
        end
    end
    TestRunner:assertEqual(table.concat(problems, ", "), "", "H1")
end)

print("\n  [the wiki: links]")

local WIKI_URL = "https://github.com/zeeyado/koassistant.koplugin/wiki/"

-- Every [text](target) in `text`; returns a list of problems. `where` names
-- the file; `self_slugs` are the file's own anchors; links to wiki pages are
-- "Page", "Page#anchor" or the live wiki's URL.
local function checkLinks(where, text, self_slugs)
    local problems = {}
    local function bad(msg) problems[#problems + 1] = where .. ": " .. msg end
    if text:find("[[", 1, true) and where ~= "README.md" then bad("uses [[wikilinks]]; links are [text](Page)") end
    for pre, target in text:gmatch("(!?)%[[^%]]*%]%(([^)]+)%)") do
        target = target:gsub("%s+\"[^\"]*\"$", "")  -- a title after the url
        local is_image = pre == "!"
        if is_image then
            if not target:match("^https://raw%.githubusercontent%.com/") and not target:match("^https://") then
                bad("image must be an absolute URL: " .. target)
            end
        elseif target:match("^https?://") or target:match("^mailto:") then
            if target:sub(1, #WIKI_URL) == WIKI_URL then
                local rest = target:sub(#WIKI_URL + 1)
                local page, anchor = rest:match("^([^#]+)#?(.*)$")
                if not isPage(page) then bad("wiki URL to a missing page: " .. rest)
                elseif anchor ~= "" and not page_slugs[page][anchor] then bad("wiki URL to a missing heading: " .. rest) end
            end
        elseif target:match("^#") then
            local anchor = target:sub(2)
            if not self_slugs[anchor] then bad("no heading for #" .. anchor) end
        else
            local page, anchor = target:match("^([^#]+)#?(.*)$")
            if where == "README.md" then
                local f = io.open(plugin_dir .. "/" .. page, "r")
                if f then f:close() else bad("relative link to nothing in the repository (the wiki is linked by URL): " .. target) end
            elseif page:match("%.md$") then
                bad("link with .md (the live wiki has no files): " .. target)
            elseif page:match("/") then
                bad("link with a path: " .. target)
            elseif not isPage(page) then
                bad("link to a missing page: " .. target)
            elseif anchor ~= "" and not page_slugs[page][anchor] then
                bad("link to a missing heading: " .. target)
            end
        end
    end
    return problems
end

TestRunner:test("every link in the wiki resolves to a page and a heading", function()
    local problems = {}
    for _idx, name in ipairs(pages) do
        for _j, p in ipairs(checkLinks(name, page_text[name], page_slugs[name])) do problems[#problems + 1] = p end
    end
    table.sort(problems)
    TestRunner:assertEqual(table.concat(problems, "\n      "), "", "wiki links")
end)

TestRunner:test("every link in the README resolves (its own anchors, the wiki's pages)", function()
    local problems = checkLinks("README.md", readme, readme_slugs)
    table.sort(problems)
    TestRunner:assertEqual(table.concat(problems, "\n      "), "", "README links")
end)

print("\n  [the wiki: menu paths]")

-- The KOAssistant menu as a tree of labels. A header is transparent (its rows
-- are its siblings); a row with a computed label (text_func) matches any text;
-- a row's choices count as its children so a path may end in a value.
local Schema = require("koassistant.ui.settings_schema")
local Gen = dofile(tests_dir .. "/tools/gen_settings_reference.lua")
local function norm(label)
    return (tostring(label):gsub("%.%.%.$", ""):gsub("…$", ""):gsub("^%s+", ""):gsub("%s+$", ""))
end
-- a computed label ("Model: gpt (OpenAI)") is matched by its static head
-- ("Model"), from the generator's table of what each such row shows
local function dynamicPrefix(id)
    local shown = id and Gen.DYNAMIC_LABELS[id]
    if not shown then return nil end
    return norm(shown:match("^([^:…%(]+)"))
end
local function buildNode(items)
    local children = {}
    for _idx, item in ipairs(items or {}) do
        local node = { dynamic = type(item.text) ~= "string", label = type(item.text) == "string" and norm(item.text) or nil,
                       header = item.type == "header", children = {}, id = item.id, prefix = nil,
                       -- a submenu the plugin builds at run time (no items here) takes any path below it
                       runtime = item.type == "submenu" and not item.items }
        if node.dynamic then node.prefix = dynamicPrefix(item.id) end
        if item.items then node.children = buildNode(item.items) end
        if item.options then
            for _j, o in ipairs(item.options) do
                node.children[#node.children + 1] = { label = norm(o.label or o.text or tostring(o.value)), children = {} }
            end
        end
        children[#children + 1] = node
    end
    return children
end
local MENU = buildNode(Schema.items)
-- "Settings" is also written for a few of KOReader's own menus in old text;
-- the wiki writes those as "KOReader's gear menu → ..." instead.
local STOP = "[%*,;:%)%]\"'|…`]"
-- the rest of the current line up to " →" or a stop character: one segment
local function segmentOf(rest)
    local line = rest:match("^([^\n]*)") or ""
    local a = line:match("^(.-)%s→") or line
    local b = line:match("^(.-)" .. STOP) or line
    local seg = (#a < #b) and a or b
    seg = seg:gsub("%s+$", "")
    if #seg > 60 then seg = seg:sub(1, 57) .. "..." end
    return seg
end
-- the same segment, untruncated, for matching a computed row
local function rawSegment(rest)
    local line = rest:match("^([^\n]*)") or ""
    local a = line:match("^(.-)%s→") or line
    local b = line:match("^(.-)" .. STOP) or line
    local seg = (#a < #b) and a or b
    return (seg:gsub("%s+$", ""))
end

local function matchLevel(level, rest)
    -- longest static label first; then a dynamic row
    local best, best_len
    for _idx, node in ipairs(level) do
        if node.label and node.label ~= "" and rest:sub(1, #node.label) == node.label then
            local after = rest:sub(#node.label + 1, #node.label + 1)
            local after3 = rest:sub(#node.label + 1, #node.label + 3)
            if after == "" or after:match("[%s%*,;:%.%)%]\"'|…`]") or after3 == "..." then
                if not best_len or #node.label > best_len then best, best_len = node, #node.label end
            end
        end
    end
    if best then return best, best_len end
    for _idx, node in ipairs(level) do
        if node.dynamic then
            local seg = rawSegment(rest)
            if seg ~= "" and (not node.prefix or seg:sub(1, #node.prefix) == node.prefix) then return node, #seg end
        end
    end
    return nil
end

local function checkPath(rest)
    local level, trail = MENU, {}
    while true do
        local node, len = matchLevel(level, rest)
        if not node then
            local seg = segmentOf(rest)
            if #trail == 0 then return false, "not a row of the KOAssistant menu: " .. seg end
            return false, "no row '" .. seg .. "' under Settings → " .. table.concat(trail, " → ")
        end
        trail[#trail + 1] = rest:sub(1, len)
        rest = rest:sub(len + 1):gsub("^%.%.%.", ""):gsub("^…", "")
        local arrow = rest:match("^%s*→%s*")
        if not arrow or node.runtime then return true end
        rest = rest:sub(#arrow + 1)
        if node.header then
            -- rows under a header are its siblings
        else
            level = node.children
        end
        if #level == 0 then
            return false, "'" .. table.concat(trail, " → ") .. "' has no rows under it (then '" .. segmentOf(rest) .. "')"
        end
    end
end

local function checkPaths(where, text)
    local problems = {}
    local pos = 1
    while true do
        local s, e = text:find("Settings%s*→%s*", pos)
        if not s then break end
        pos = e + 1
        local before = text:sub(math.max(1, s - 24), s - 1)
        -- "Book Settings", "Display Settings", "Quick Settings"...: a capitalized word
        -- before "Settings" names another menu; "KOAssistant Settings" is this one
        local prev_word = before:match("([%w&']+)%s+$")
        local other_menu = prev_word and prev_word:match("^%u") and prev_word ~= "KOAssistant"
        if not other_menu then
            local line_no = select(2, text:sub(1, s):gsub("\n", "")) + 1
            local rest = text:sub(e + 1)
            local ok, why = checkPath(rest)
            if not ok then problems[#problems + 1] = string.format("%s:%d: %s", where, line_no, why) end
        end
    end
    return problems
end

TestRunner:test("every 'Settings → …' path in the wiki is a path of the KOAssistant menu", function()
    local problems = {}
    for _idx, name in ipairs(pages) do
        if name ~= "Settings-Reference" then
            for _j, p in ipairs(checkPaths(name, page_text[name])) do problems[#problems + 1] = p end
        end
    end
    TestRunner:assertEqual(table.concat(problems, "\n      "), "", "menu paths")
end)

TestRunner:test("every 'Settings → …' path in the README is a path of the KOAssistant menu", function()
    local problems = checkPaths("README.md", readme)
    TestRunner:assertEqual(table.concat(problems, "\n      "), "", "README menu paths")
end)

-- The _("...") and _('...') literals of a Lua source, unescaped enough for a path check.
local function gettextStrings(src)
    local out = {}
    local pos = 1
    while true do
        local _s, e, q = src:find("_%(%s*([\"'])", pos)
        if not _s then break end
        local i = e + 1
        local buf = {}
        while i <= #src do
            local c = src:sub(i, i)
            if c == "\\" then
                local n = src:sub(i + 1, i + 1)
                buf[#buf + 1] = (n == "n" and "\n") or (n == "t" and "\t") or n
                i = i + 2
            elseif c == q then
                break
            else
                buf[#buf + 1] = c
                i = i + 1
            end
        end
        out[#out + 1] = table.concat(buf)
        pos = i + 1
    end
    return out
end

TestRunner:test("every 'Settings → …' path in the plugin's user-facing strings is a path of the KOAssistant menu", function()
    local problems = {}
    for _idx, cmd in ipairs({ 'ls "' .. plugin_dir .. '"/*.lua', 'find "' .. plugin_dir .. '/koassistant" -name "*.lua" | sort' }) do
        local h = io.popen(cmd .. ' 2>/dev/null')
        if h then
            for path in h:lines() do
                local rel = path:sub(#plugin_dir + 2)
                local f = io.open(path, "r")
                if f then
                    local src = f:read("*a")
                    f:close()
                    local strings = gettextStrings(src)
                    if #strings > 0 then
                        for _j, problem in ipairs(checkPaths(rel, table.concat(strings, "\n"))) do
                            problems[#problems + 1] = problem
                        end
                    end
                end
            end
            h:close()
        end
    end
    TestRunner:assertEqual(table.concat(problems, "\n      "), "", "menu paths in the code's strings")
end)

print("\n  [the README and the generated page]")

TestRunner:test("README.md stays the front door (under " .. README_MAX_LINES .. " lines)", function()
    local _, n = (read("README.md") or ""):gsub("\n", "")
    TestRunner:assertTrue(n <= README_MAX_LINES, "README.md has " .. n .. " lines; the detail belongs on a wiki page")
end)

TestRunner:test("wiki/Settings-Reference.md is the generator's output", function()
    local expected = Gen.generate(Schema)
    TestRunner:assertEqual(read("wiki/Settings-Reference.md") == expected, true,
        "run: lua tests/tools/gen_settings_reference.lua")
end)

TestRunner:test("every computed menu label has its static form in the generator", function()
    local missing = {}
    local function walk(items)
        for _idx, item in ipairs(items or {}) do
            if type(item.text) ~= "string" and item.type ~= "header" and not Gen.DYNAMIC_LABELS[item.id or ""] then
                missing[#missing + 1] = tostring(item.id)
            end
            if item.items then walk(item.items) end
        end
    end
    walk(Schema.items)
    table.sort(missing)
    TestRunner:assertEqual(table.concat(missing, ", "), "", "add to DYNAMIC_LABELS in gen_settings_reference.lua")
end)

TestRunner:test("the generator's owner pages exist", function()
    local missing = {}
    for id, page in pairs(Gen.OWNERS) do
        if not isPage(page) then missing[#missing + 1] = id .. " -> " .. page end
    end
    table.sort(missing)
    TestRunner:assertEqual(table.concat(missing, ", "), "", "OWNERS")
end)

TestRunner:test("the release-notes draft's wiki tags name pages that exist", function()
    local h = io.popen('ls "' .. plugin_dir .. '/docs"/release_notes_v*.md 2>/dev/null | sort -V | tail -n 1')
    local draft = h and h:read("*l")
    if h then h:close() end
    if not draft or draft == "" then return end  -- docs/ is local; nothing to check on a clean clone
    local f = io.open(draft, "r")
    local text = f:read("*a")
    f:close()
    local missing = {}
    for tags in text:gmatch("<!%-%- wiki:(.-)%-%->") do
        for name in tags:gmatch("%S+") do
            if name ~= "none" and not isPage(name) then missing[#missing + 1] = name end
        end
    end
    table.sort(missing)
    TestRunner:assertEqual(table.concat(missing, ", "), "", "tags in " .. draft)
end)

TestRunner:test("the release zip leaves wiki/ out", function()
    -- release.yml builds the zip with the script, so the script's list is the one list
    TestRunner:assertTrue((read("scripts/build_release_zip.sh") or ""):find("--exclude='wiki'", 1, true) ~= nil, "build_release_zip.sh")
    TestRunner:assertTrue((read(".github/workflows/release.yml") or ""):find("scripts/build_release_zip.sh", 1, true) ~= nil, "release.yml runs it")
end)

print("\n  [the provider tables]")

local ModelLists = require("koassistant.request.model_lists")
local GenP = dofile(tests_dir .. "/tools/gen_provider_tables.lua")

TestRunner:test("the Providers page's generated tables are the generator's output", function()
    local text = read(GenP.PAGE) or ""
    local blocks = GenP.generate(ModelLists)
    local stale = {}
    for _idx, name in ipairs(GenP.BLOCKS) do
        local have = GenP.extract(text, name)
        if have == nil then
            stale[#stale + 1] = name .. " (markers missing)"
        elseif have ~= blocks[name] then
            stale[#stale + 1] = name
        end
    end
    TestRunner:assertEqual(table.concat(stale, ", "), "", "run: lua tests/tools/gen_provider_tables.lua")
end)

TestRunner:test("every built-in provider has a display name and a place in the provider generator", function()
    local ordered = {}
    for _idx, id in ipairs(GenP.ORDER) do ordered[id] = true end
    local missing = {}
    for _idx, id in ipairs(ModelLists.getAllProviders()) do
        if not GenP.NAMES[id] then missing[#missing + 1] = id .. " (no name)" end
        if not ordered[id] then missing[#missing + 1] = id .. " (not in ORDER)" end
    end
    table.sort(missing)
    TestRunner:assertEqual(table.concat(missing, ", "), "", "Gen.NAMES / Gen.ORDER in gen_provider_tables.lua")
end)

TestRunner:test("the provider tables of the wiki and the README list every built-in provider with its status", function()
    local problems = {}
    local function check(rel, rowOf)
        local text = read(rel) or ""
        for _idx, id in ipairs(ModelLists.getAllProviders()) do
            local row = rowOf(text, id)
            local want = ModelLists.isCommunity(id) and "| Docs-based* |" or "| Tested |"
            if not row then
                problems[#problems + 1] = rel .. ": no row for " .. id
            elseif not row:find(want, 1, true) then
                problems[#problems + 1] = rel .. ": " .. id .. " should read " .. want
            end
        end
    end
    -- the wiki's table tags each row with the id; the README's names the provider
    check("wiki/Providers-and-Models.md", function(text, id)
        for line in text:gmatch("[^\n]+") do
            if line:sub(1, 1) == "|" and line:find("(`" .. id .. "`)", 1, true) then return line end
        end
    end)
    check("README.md", function(text, id)
        local head = "| **" .. (GenP.NAMES[id] or id) .. "** |"
        for line in text:gmatch("[^\n]+") do
            if line:sub(1, #head) == head then return line end
        end
    end)
    table.sort(problems)
    TestRunner:assertEqual(table.concat(problems, "\n      "), "", "provider tables")
end)

TestRunner:summary()
return TestRunner.failed == 0
