--[[
UI Constants for KOAssistant Plugin

Shared sizing and styling constants to ensure consistent appearance
across all dialogs, menus, and widgets.

Usage:
    local UIConstants = require("koassistant_ui.constants")
    local width = UIConstants.DIALOG_WIDTH()
    local height = UIConstants.DIALOG_HEIGHT()
]]

local Device = require("device")
local Screen = Device.screen
local Size = require("ui/size")

local UIConstants = {}

-- Standard dialog sizing (full screen)
-- Used for: Chat History, Domain/Tag browsers, Prompts Manager
function UIConstants.DIALOG_WIDTH()
    return Screen:getWidth()
end

function UIConstants.DIALOG_HEIGHT()
    return Screen:getHeight()
end

-- Expanded chat windows (features.chat_window_size == "expanded").
-- Module-resident so every consumer (viewer, quiz, streaming dialogs) reads one
-- truth without plumbing `features` through constructors that never had it —
-- same push-at-updateConfigFromSettings pattern as ModelOverrides.setGuiTiers,
-- which keeps this file pure-loadable for the tests.
local expanded_windows = false

function UIConstants.setExpandedWindows(on)
    expanded_windows = on and true or false
end

function UIConstants.expandedWindows()
    return expanded_windows
end

-- Bottom band reserved so KOReader's status bar stays readable while a long
-- answer is on screen. Wikipedia's fullpage rule verbatim (dictquicklookup.lua:
-- "We want to let the footer visible (as it can show time, battery level and
-- wifi state, which might be useful when spending time reading...)"), and like
-- theirs it only applies while a reader is up with its footer shown — in the
-- FileManager there is no footer and the band is zero.
function UIConstants.FOOTER_RESERVE()
    if not expanded_windows then return 0 end
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok or not ReaderUI or not ReaderUI.instance then return 0 end
    local view = ReaderUI.instance.view
    if not view or not view.footer_visible or not view.footer then return 0 end
    local ok2, h = pcall(function() return view.footer:getHeight() end)
    return (ok2 and h) or 0
end

-- Region a chat-family window is centred in. Standard mode centres on the whole
-- screen (the 95% sizes below leave the margin); expanded mode shrinks the
-- region instead, so SHORT windows (translate, artifacts) clear the footer too
-- without every height branch having to know about it.
-- opts.compact opts out entirely, like CHAT_WIDTH below — a compact popup must
-- be untouched by the setting, vertical centring included.
function UIConstants.CHAT_REGION(opts)
    if not expanded_windows or (opts and opts.compact) then
        return { x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    end
    local margin = Size.margin.default
    return {
        x = 0,
        y = margin,
        w = Screen:getWidth(),
        h = Screen:getHeight() - 2 * margin - UIConstants.FOOTER_RESERVE(),
    }
end

-- Chat viewer sizing. Standard = 95%, slightly smaller than full screen, with
-- adequate touch-target margins near the screen edges. Expanded = Wikipedia's
-- fullpage geometry (screen minus a hairline, minus the footer band).
-- Used for: ChatGPTViewer (standard/artifact/dictionary/translate), quiz viewer,
-- streaming dialog (large mode).
--
-- opts.compact pins the standard width: compact_view popups are deliberately
-- OUT of the expanded setting. Their dismiss gesture IS the tap outside, and a
-- 60%-tall band with a hairline edge is exactly the geometry where an outside
-- tap stops reading as one.
function UIConstants.CHAT_WIDTH(opts)
    if expanded_windows and not (opts and opts.compact) then
        return Screen:getWidth() - 2 * Size.margin.default
    end
    return math.floor(Screen:getWidth() * 0.95)
end

function UIConstants.CHAT_HEIGHT()
    if expanded_windows then
        return UIConstants.CHAT_REGION().h
    end
    return math.floor(Screen:getHeight() * 0.95)
end

-- Compact dialog sizing (90% width, 60% height)
-- Used for: Smaller dialogs, confirmations
function UIConstants.COMPACT_DIALOG_WIDTH()
    return math.floor(Screen:getWidth() * 0.9)
end

function UIConstants.COMPACT_DIALOG_HEIGHT()
    return math.floor(Screen:getHeight() * 0.6)
end

-- Standard window margin (padding from screen edge)
function UIConstants.WINDOW_MARGIN()
    return Screen:scaleBySize(30)
end

-- Input dialog height ratio (for reply dialogs, etc.)
UIConstants.INPUT_HEIGHT_RATIO = 0.3

-- Menu item threshold for single vs double column layout
UIConstants.MAX_SINGLE_COLUMN = 12

-- Standard text padding and margins
function UIConstants.TEXT_PADDING()
    return Size.padding.large
end

function UIConstants.TEXT_MARGIN()
    return Size.margin.small
end

-- Calculate content width (dialog width minus padding/margins)
function UIConstants.CONTENT_WIDTH()
    return UIConstants.DIALOG_WIDTH() - 2 * Size.padding.large - 2 * Size.margin.small
end

return UIConstants
