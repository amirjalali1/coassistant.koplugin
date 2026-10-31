--[[
Headless scenario boot (docs/test_automation_plan.md, layer 2): KOReader's own
frontend on its dummy framebuffer, a fresh home inside a scratch run folder,
this plugin linked from the working tree, the mock books and groups generated
into the run folder. Nothing of the maintainer's is read or written: the home
is asserted to sit inside the run folder, the API keys are never loaded (an
empty table stands in for apikeys.lua before the plugin loads), every network
path is blocked and a blocked call fails the scenario.

Run through tests/scenarios/run.sh, which makes the run folder, generates the
fixture and runs each scenario as:
  cd <KOReader.app>/Contents/koreader && KO_HOME=<run>/home KOA_RUN=<run> \
      KOA_PLUGIN=<working tree> ./luajit <working tree>/tests/scenarios/<s>.lua

A scenario:
  local S = dofile(os.getenv("KOA_PLUGIN") .. "/tests/scenarios/boot.lua")
  local ui = S.open("Mock Series 3")
  S.check(cond, "what it shows")
  S.shot("name")            -- <run>/shots/<scenario>_name.png, for the session to view
  S.finish()                -- PASS/FAIL summary, exit code

Wiki shots (tests/scenarios/wiki_shots.sh sets these; every one is off by
default): KOA_SCREEN=WxH draws on a screen of that size (a Kobo Clara's
1072x1448) instead of 600x800, grayscale as before; EMULATE_READER_DPI is
KOReader's own; KOA_EMOJI registers the emoji font the plugin installs as a UI
fallback when the desktop's user font folder holds it (read only); KOA_BOOKS
names a books folder run.sh copied into <run>/Books, its roles (series,
standalone, nonfiction) read from the koashots.lua it carries (S.shotsBook).
S.wiki("name.png") writes <run>/wiki/name.png for a manifest name of
docs/assets/wiki_shotlist.txt; S.openMenu / S.menuTap walk KOReader's main
menu; S.fileManager opens the file browser on a folder.
]]

local S = {}

local PLUGIN = assert(os.getenv("KOA_PLUGIN"), "KOA_PLUGIN unset")
local RUN = assert(os.getenv("KOA_RUN"), "KOA_RUN unset")
local HOME = assert(os.getenv("KO_HOME"), "KO_HOME unset")
-- The home is the run's own, never a real one
assert(HOME:sub(1, #RUN + 1) == RUN .. "/", "KO_HOME must be inside the run folder")
S.PLUGIN, S.RUN, S.HOME = PLUGIN, RUN, HOME
S.BOOKS = RUN .. "/Books"
S.NAME = (arg and arg[0] or "scenario"):match("([^/]+)%.lua$") or "scenario"

require("setupkoenv")
require("dbg"):turnOff()
local logger = require("logger")
logger:setLevel(logger.levels.warn)
local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")

G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
-- Only this plugin loads: the stock plugins stay out of the run
do
    local disabled = {}
    for entry in lfs.dir("plugins") do
        local name = entry:match("^(.+)%.koplugin$")
        if name then disabled[name] = true end
    end
    -- a wiki shot shows a device, where KOReader's Gestures plugin runs
    if os.getenv("KOA_SCREEN") then disabled.gestures = nil end
    G_reader_settings:saveSetting("plugins_disabled", disabled)
    G_reader_settings:saveSetting("koassistant_last_update_check", os.time())
end
-- KOA_EMOJI: the plugin's emoji font as a UI fallback, before ui/font loads
-- (it reads the fallbacks once); only when the user font folder has it
if os.getenv("KOA_EMOJI") then
    local font = (os.getenv("HOME") or "") .. "/Library/Fonts/NotoEmoji-Regular.ttf"
    if lfs.attributes(font, "mode") == "file" then
        G_reader_settings:saveSetting("font_ui_fallbacks", { font })
        S.EMOJI = true
    end
end

-- ── Results ─────────────────────────────────────────────────────────────────
local passed, failed = 0, 0
function S.check(cond, what)
    if cond then
        passed = passed + 1
        print("  PASS " .. what)
    else
        failed = failed + 1
        print("  FAIL " .. what)
    end
    return cond
end
function S.note(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    print("    " .. table.concat(parts, " "))
end

-- ── The screen and input, headless ──────────────────────────────────────────
einkfb = require("ffi/framebuffer") --luacheck: ignore
einkfb.dummy = true --luacheck: ignore
-- KOA_SCREEN: the dummy buffer the SDL framebuffer makes (600x800) swapped for
-- one of this size, in the base init its own init ends with
do
    local spec = os.getenv("KOA_SCREEN")
    if spec and spec ~= "" then
        local w, h = spec:match("^(%d+)x(%d+)$")
        assert(w, "KOA_SCREEN must be WxH, e.g. 1072x1448")
        w, h = tonumber(w), tonumber(h)
        local BB = require("ffi/blitbuffer")
        local base_init = einkfb.init --luacheck: ignore
        einkfb.init = function(self) --luacheck: ignore
            if self.dummy and not (self.bb and self.bb:getWidth() == w and self.bb:getHeight() == h) then
                if self.bb then self.bb:free() end
                self.bb = BB.new(w, h)
                self.bb:fill(BB.COLOR_WHITE)
            end
            return base_init(self)
        end
    end
end
local Device = require("device")
-- Wiki shots draw a Kobo: no keyboard, no keys, no D-pad. KOReader's Menu
-- takes its boxed shortcut letters from hasKeyboard when it loads, and a
-- keyed device gets a focus frame on a dialog's first button; so before
-- anything loads ui/widget/menu
if os.getenv("KOA_SCREEN") then
    local no = function() return false end
    Device.hasKeyboard, Device.hasKeys, Device.hasDPad, Device.hasScreenKB = no, no, no, no
    local Menu = package.loaded["ui/widget/menu"]
    if Menu then Menu.is_enable_shortcut = false end
end
local Screen = Device.screen
Screen:init()
require("document/canvascontext"):init(Device)
Device.input.dummy = true
S.Screen = Screen

-- ── The network and the keys, kept out ──────────────────────────────────────
local blocked = {}
local function block(name)
    return function()
        blocked[#blocked + 1] = name
        error("scenario: network blocked (" .. name .. ")", 2)
    end
end
package.loaded["apikeys"] = {}
do
    local http = require("socket.http")
    http.request = block("socket.http.request")
    local ok_https, https = pcall(require, "ssl.https")
    if ok_https and type(https) == "table" then https.request = block("ssl.https.request") end
    local socket = require("socket")
    socket.connect = block("socket.connect")
    -- No child processes either: a request's child would connect on its own
    -- (the name index's background pass is refused too; it says so and the
    -- marks fall back to once per page)
    local ffiutil = require("ffi/util")
    local real_fork = ffiutil.runInSubProcess
    ffiutil.runInSubProcess = function()
        S.forks_refused = (S.forks_refused or 0) + 1
        return false
    end
    --- Child processes allowed from here on, for a scenario that needs the
    --- name index's background pass as a device runs it (the child inherits
    --- every block above)
    function S.allowForks()
        ffiutil.runInSubProcess = real_fork
    end
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr.isOnline = function() return false end
    NetworkMgr.isConnected = function() return false end
    NetworkMgr.isWifiOn = function() return false end
end

local UIManager = require("ui/uimanager")
S.UIManager = UIManager

-- The plugin's own modules, for the scenarios and for the request block
package.path = PLUGIN .. "/?.lua;" .. package.path
do
    local GptQuery = require("koassistant.request.gpt_query")
    GptQuery.query = block("gpt_query.query")
    local BaseHandler = require("koassistant.api.base")
    for _idx, fn in ipairs({ "backgroundRequest", "fetchInSubprocess", "fetchAsync",
            "resolveForSubprocess", "connectSSLInSubprocess" }) do
        if BaseHandler[fn] then BaseHandler[fn] = block("BaseHandler." .. fn) end
    end
end

-- Wiki shots: the plugin is linked from the working tree, whose own
-- behaviors/ and domains/ folders hold the maintainer's files; a wiki run
-- loads none of them, only what a scenario stages in S.userBehaviors /
-- S.userDomains (id -> { name, text, external = true, source = "folder" })
if os.getenv("KOA_SCREEN") then
    S.userBehaviors, S.userDomains = {}, {}
    local function staged(t)
        return function()
            local out = {}
            for k, v in pairs(t) do out[k] = v end
            return out
        end
    end
    require("koassistant.prompts.behavior_loader").load = staged(S.userBehaviors)
    require("koassistant.prompts.domain_loader").load = staged(S.userDomains)
end

--- The plugin's settings before it loads (features merged over its defaults)
function S.features(values)
    local LuaSettings = require("luasettings")
    local s = LuaSettings:open(DataStorage:getSettingsDir() .. "/koassistant_settings.lua")
    local f = s:readSetting("features") or {}
    for k, v in pairs(values) do f[k] = v end
    s:saveSetting("features", f)
    s:flush()
end
S.features({ auto_check_updates = false })

--- Every scheduled task now (the 2 s debounces, the marks' settle)
function S.settle(rounds)
    for _i = 1, rounds or 3 do
        UIManager:shiftScheduledTasksBy(-1e9)
        UIManager:setInputTimeout(0)
        UIManager:handleInput()
    end
end

--- Settle until cond() holds, in real time (a child process at work), at
--- most `seconds`; returns whether it held
function S.waitFor(cond, seconds)
    local ffi = require("ffi")
    pcall(ffi.cdef, "int usleep(unsigned int usec);")
    for _i = 1, math.ceil((seconds or 10) * 5) do
        S.settle(1)
        if cond() then return true end
        ffi.C.usleep(200000)
    end
    return cond() and true or false
end

-- The EPUB files under a folder, at any depth, in a stable order
local function epubsUnder(dir, out)
    out = out or {}
    if lfs.attributes(dir, "mode") ~= "directory" then return out end
    local entries = {}
    for entry in lfs.dir(dir) do
        if entry ~= "." and entry ~= ".." then entries[#entries + 1] = entry end
    end
    table.sort(entries)
    for _idx, entry in ipairs(entries) do
        local path = dir .. "/" .. entry
        local mode = lfs.attributes(path, "mode")
        if mode == "directory" and not entry:match("%.sdr$") then
            epubsUnder(path, out)
        elseif mode == "file" and entry:match("%.epub$") then
            out[#out + 1] = path
        end
    end
    return out
end

--- A book of the run by part of its file name: the fixture's folders first,
--- then anything else under <run>/Books (a KOA_BOOKS copy), or a full path
function S.book(part)
    if part:sub(1, 1) == "/" and lfs.attributes(part, "mode") == "file" then return part end
    for _idx, folder in ipairs({ "Mock Series", "Mock Project", "Mock Shelf" }) do
        local dir = S.BOOKS .. "/" .. folder
        if lfs.attributes(dir, "mode") == "directory" then
            for entry in lfs.dir(dir) do
                if entry:match("%.epub$") and entry:find(part, 1, true) then
                    return dir .. "/" .. entry
                end
            end
        end
    end
    for _idx, path in ipairs(epubsUnder(S.BOOKS)) do
        if path:match("[^/]+$"):find(part, 1, true) then return path end
    end
    error("no book matches " .. tostring(part))
end

-- The KOA_BOOKS copy and its roles (koassistant shots books: koashots.lua in
-- that folder, untracked, names the files; tracked files never name them)
do
    local src = os.getenv("KOA_BOOKS")
    if src and src ~= "" then
        local dir = S.BOOKS .. "/" .. src:gsub("/+$", ""):match("[^/]+$")
        if lfs.attributes(dir, "mode") == "directory" then
            S.SHOTS_DIR = dir
            local ok, roles = pcall(dofile, dir .. "/koashots.lua")
            if ok and type(roles) == "table" then S.SHOTS = roles end
        end
    end
end

--- A shots book by its role ("series" with its place, 1 first; "standalone";
--- "nonfiction"): its path in the run's copy, or nil without KOA_BOOKS
function S.shotsBook(role, n)
    local roles = S.SHOTS
    if not roles then return nil end
    local rel = roles[role]
    if type(rel) == "table" then rel = rel[n or 1] end
    return type(rel) == "string" and (S.SHOTS_DIR .. "/" .. rel) or nil
end

local current_ui, current_fm
--- Open a book in the reader (the plugins load with it); returns the ReaderUI
function S.open(part)
    if current_ui then S.close() end
    if current_fm then S.closeFileManager() end
    local DocumentRegistry = require("document/documentregistry")
    local ReaderUI = require("apps/reader/readerui")
    local file = S.book(part)
    local doc = DocumentRegistry:openDocument(file)
    assert(doc, "could not open " .. file)
    current_ui = ReaderUI:new{ dimen = Screen:getSize(), document = doc }
    UIManager:show(current_ui)
    S.settle()
    UIManager:forceRePaint()
    S.ui = current_ui
    S.plugin = current_ui.koassistant
    return current_ui
end

function S.close()
    if not current_ui then return end
    current_ui:onClose()
    UIManager:close(current_ui)
    S.settle(1)
    current_ui, S.ui, S.plugin = nil, nil, nil
end

--- Open KOReader's file browser on a folder (the plugins load with it; the
--- folder becomes the home folder, so its path shows as Home); returns it
function S.fileManager(dir)
    if current_ui then S.close() end
    if current_fm then S.closeFileManager() end
    dir = dir or S.SHOTS_DIR or S.BOOKS
    G_reader_settings:saveSetting("home_dir", dir)
    G_reader_settings:saveSetting("lastdir", dir)
    local FileManager = require("apps/filemanager/filemanager")
    FileManager:showFiles(dir)
    S.settle()
    UIManager:forceRePaint()
    current_fm = FileManager.instance
    S.fm = current_fm
    S.plugin = current_fm and current_fm.koassistant
    return current_fm
end

function S.closeFileManager()
    if not current_fm then return end
    current_fm:onClose()
    S.settle(1)
    current_fm, S.fm, S.plugin = nil, nil, nil
end

--- Go to the chapter of this title (its first page)
function S.chapter(title)
    local ui = assert(current_ui, "no book open")
    for _idx, item in ipairs(ui.toc.toc or ui.document:getToc() or {}) do
        if item.title and item.title:find(title, 1, true) then
            ui:handleEvent(require("ui/event"):new("GotoPage", item.page))
            S.settle()
            UIManager:forceRePaint()
            return item.page
        end
    end
    error("no chapter " .. tostring(title))
end

--- The visible page's X-Ray marks, after the deferred scan: { {name, text, x, y, w, h, words} }
--- with `words` = the text under the mark, read back from the page.
--- opts.as_drawn: the marks the page holds now, with no fresh scan
function S.marks(opts)
    local XrayMarks = require("koassistant.xray.xray_marks")
    if not (opts and opts.as_drawn) then
        XrayMarks.sync(S.plugin)
        S.settle()
    end
    local out = {}
    for _idx, m in ipairs(XrayMarks._pageMarks() or {}) do
        local words
        local ok, sel = pcall(current_ui.document.getTextFromPositions, current_ui.document,
            { x = m.x + 1, y = m.y + math.floor(m.h / 2) },
            { x = m.x + m.w - 1, y = m.y + math.floor(m.h / 2) }, true)
        if ok and type(sel) == "table" then words = sel.text end
        out[#out + 1] = { name = m.name, text = m.text, words = words,
            x = m.x, y = m.y, w = m.w, h = m.h }
    end
    return out
end

--- The window on top (the last shown)
function S.top()
    local stack = UIManager._window_stack
    return stack[#stack] and stack[#stack].widget
end

--- The buttons a dialog shows, top to bottom: { { text, button }, ... }; in a
--- window built by hand (no button table of its own), every Button and
--- CheckButton (a radio row's too) in its widget tree, `checked` set for those
function S.buttons(w)
    w = w or S.top()
    local out = {}
    -- ButtonDialog's field, then InputDialog's (either may be missing)
    for _idx, field in ipairs({ "buttontable", "button_table" }) do
        local bt = w and w[field]
        for _r, row in ipairs(bt and bt.buttons_layout or {}) do
            for _c, b in ipairs(row) do out[#out + 1] = { text = b.text, button = b } end
        end
    end
    if #out == 0 and type(w) == "table" and not w.item_table then
        local seen = {}
        local function walk(node, depth)
            if type(node) ~= "table" or seen[node] or depth > 40 then return end
            seen[node] = true
            if type(node.text) == "string" and (node.onTapSelectButton or node.onTapCheckButton) then
                local checked
                if node.onTapCheckButton then checked = node.checked == true end
                out[#out + 1] = { text = node.text, button = node, checked = checked }
                return
            end
            for i = 1, #node do walk(node[i], depth + 1) end
            -- a scrolled body keeps its content as the first child too
            if node.cropping_widget then walk(node.cropping_widget, depth + 1) end
        end
        walk(w, 0)
    end
    return out
end

-- A tap on what S.buttons found, as a finger would
local function press(b)
    if b.onTapCheckButton then
        b:onTapCheckButton()
    else
        b:onTapSelectButton()
    end
end

--- The texts of S.buttons, or of a menu's rows
function S.texts(w)
    w = w or S.top()
    local out = {}
    for _idx, b in ipairs(S.buttons(w)) do out[#out + 1] = b.text end
    if #out == 0 and w and w.item_table then
        for _idx, it in ipairs(w.item_table) do out[#out + 1] = it.text end
    end
    return out
end

--- Tap the button, or the menu row, with exactly this text (or matching a
--- Lua pattern given as { pattern }): in `w`, or in the windows from the top
--- down (an input box sits under its keyboard); fails naming what is there
function S.tap(text, w)
    local function hit(t)
        if type(text) == "table" then return type(t) == "string" and t:find(text[1]) ~= nil end
        return t == text
    end
    local stack = UIManager._window_stack
    local windows = {}
    if w then
        windows[1] = w
    else
        for i = #stack, 1, -1 do windows[#windows + 1] = stack[i].widget end
    end
    local seen = {}
    for _idx, win in ipairs(windows) do
        for _j, b in ipairs(S.buttons(win)) do
            seen[#seen + 1] = b.text
            if hit(b.text) then
                press(b.button)
                S.settle()
                UIManager:forceRePaint()
                return b.text, win
            end
        end
        for _j, it in ipairs(win and win.item_table or {}) do
            seen[#seen + 1] = it.text
            if hit(it.text) then
                win:onMenuSelect(it)
                S.settle()
                UIManager:forceRePaint()
                return it.text, win
            end
        end
    end
    error("nothing to tap named " .. tostring(type(text) == "table" and text[1] or text)
        .. "; there: " .. table.concat(seen, " | "))
end

--- Long-press the button with this text (or a { pattern }) in the window on
--- top, or the first window from the top that has it
function S.hold(text)
    local stack = UIManager._window_stack
    for i = #stack, 1, -1 do
        for _j, b in ipairs(S.buttons(stack[i].widget)) do
            local t = b.text
            if (type(text) == "table" and type(t) == "string" and t:find(text[1])) or t == text then
                b.button:onHoldSelectButton()
                S.settle()
                UIManager:forceRePaint()
                return t
            end
        end
    end
    error("nothing to hold named " .. tostring(type(text) == "table" and text[1] or text))
end

--- Close every window above the reader (or the file browser)
function S.closeAll()
    local stack = UIManager._window_stack
    for i = #stack, 1, -1 do
        local w = stack[i] and stack[i].widget
        if w and w ~= current_ui and w ~= current_fm then UIManager:close(w) end
    end
    -- what the closes scheduled runs now, not over the next window
    S.settle()
end

--- The first window from the top that shows a button or row with this text
function S.find(text)
    local stack = UIManager._window_stack
    for i = #stack, 1, -1 do
        local win = stack[i].widget
        for _j, t in ipairs(S.texts(win)) do
            if t == text then return win end
        end
    end
end

-- ── KOReader's main menu (the reader's, or the file browser's) ───────────────
local function itemText(item)
    if type(item) ~= "table" then return nil end
    if item.text_func then
        local ok, t = pcall(item.text_func)
        if ok then return t end
    end
    return item.text
end
S.itemText = itemText

local function menuHolder()
    local holder = (current_ui and current_ui.menu) or (current_fm and current_fm.menu)
    return assert(holder, "no reader or file browser open")
end

--- The main menu's TouchMenu, when it is open
function S.menu()
    local holder = menuHolder()
    local c = holder.menu_container
    return c and UIManager:isWidgetShown(c) and c[1] or nil
end

-- A row's text matches with or without the emoji Emoji Menu Icons puts first
local function hits(text, t)
    if type(t) ~= "string" then return false end
    local bare = t:gsub("^[\128-\255]+[\128-\255%s]*%s", "")
    if type(text) == "table" then return t:find(text[1]) ~= nil or bare:find(text[1]) ~= nil end
    return t == text or bare == text
end

-- Show the page of the menu's current list that holds this item
local function showItemPage(menu, item)
    for i, it in ipairs(menu.item_table) do
        if it == item then
            local per = menu.perpage or menu.max_per_page_default or 10
            menu:updateItems(math.floor((i - 1) / per) + 1)
            return
        end
    end
end

--- Open the main menu on the tab holding a row with this text (default:
--- KOAssistant's), the page with that row shown; returns the TouchMenu
function S.openMenu(row)
    row = row or "KOAssistant"
    local holder = menuHolder()
    -- a container closed from outside (S.closeAll) is still referenced
    if holder.menu_container and not UIManager:isWidgetShown(holder.menu_container) then
        holder.menu_container = nil
    end
    if not holder.menu_container then holder:onShowMenu() end
    S.settle()
    local menu = holder.menu_container[1]
    for i, tab in ipairs(menu.tab_item_table) do
        for _j, item in ipairs(tab) do
            if hits(row, itemText(item)) then
                -- the tab icon's own tap: the bar marks it, the list switches
                menu.bar:switchToTab(i)
                showItemPage(menu, item)
                S.settle()
                UIManager:forceRePaint()
                return menu
            end
        end
    end
    error("no main menu tab has a row " .. tostring(type(row) == "table" and row[1] or row))
end

--- Tap a row of the open main menu's current list by its text (or a Lua
--- pattern given as { pattern }): a submenu opens in place, a row's own dialog
--- over it; the page with the row is shown first. Returns the item.
function S.menuTap(row)
    local menu = assert(S.menu(), "the main menu is not open")
    local seen = {}
    for _idx, item in ipairs(menu.item_table) do
        local t = itemText(item)
        seen[#seen + 1] = tostring(t)
        if hits(row, t) then
            showItemPage(menu, item)
            menu:onMenuSelect(item)
            S.settle()
            UIManager:forceRePaint()
            return item
        end
    end
    error("no menu row " .. tostring(type(row) == "table" and row[1] or row) .. "; there: " .. table.concat(seen, " | "))
end

--- Walk the main menu: S.menuPath({ "KOAssistant", "Privacy & Data" }) opens
--- the tab of the first row and taps each in turn
function S.menuPath(rows)
    S.openMenu(rows[1])
    for _idx, row in ipairs(rows) do S.menuTap(row) end
    return S.menu()
end

--- The rows of the open main menu's current list (their texts)
function S.menuRows()
    local menu = S.menu()
    local out = {}
    for _idx, item in ipairs(menu and menu.item_table or {}) do out[#out + 1] = tostring(itemText(item)) end
    return out
end

function S.closeMenu()
    local holder = menuHolder()
    if holder.menu_container then
        local menu = holder.menu_container[1]
        menu:closeMenu()
        S.settle()
    end
end

-- ── Wiki shots ──────────────────────────────────────────────────────────────
local manifest
local function manifestNames()
    if manifest then return manifest end
    manifest = {}
    local f = io.open(PLUGIN .. "/docs/assets/wiki_shotlist.txt", "r")
    if f then
        for line in f:lines() do
            local name = line:match("^%s*([^#|%s][^|]-)%s*|")
            if name then manifest[name] = true end
        end
        f:close()
    end
    return manifest
end

--- A wiki shot: the screen as <run>/wiki/<name>, for a name of the manifest
--- (docs/assets/wiki_shotlist.txt; another name is written too, with a note)
function S.wiki(name)
    lfs.mkdir(RUN .. "/wiki")
    -- the whole stack painted again, bottom to top: nothing of a closed
    -- window survives into a final
    UIManager:setDirty("all", "full")
    UIManager:forceRePaint()
    if not manifestNames()[name] then S.note("not a manifest name:", name) end
    local path = RUN .. "/wiki/" .. name
    Screen.bb:writePNG(path)
    print("    wiki: " .. path)
    return path
end

--- A screenshot for the session to view
function S.shot(name)
    lfs.mkdir(RUN .. "/shots")
    UIManager:forceRePaint()
    local path = RUN .. "/shots/" .. S.NAME .. "_" .. name .. ".png"
    Screen.bb:writePNG(path)
    print("    shot: " .. path)
    return path
end

function S.finish()
    S.check(#blocked == 0, "nothing tried the network" .. (#blocked > 0
        and (" (" .. table.concat(blocked, ", ") .. ")") or ""))
    pcall(S.close)
    pcall(S.closeFileManager)
    print(string.format("%s: %d passed, %d failed", S.NAME, passed, failed))
    os.exit(failed == 0 and 0 or 1)
end

return S
