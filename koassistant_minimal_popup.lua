--[[--
Minimal chrome-less response popup ("minimal popup" view mode).

A small anchored window with just the response text: no title bar, no buttons.
Tap inside = hand off to the full viewer (on_expand); tap outside = dismiss.
Anchors next to the highlight via MovableContainer's `anchor` when selection
geometry is available (EPUB — sboxes are already screen coordinates; paging/PDF
and geometry-less launches fall back to centered). Deliberately independent of
KOReader's own "highlight dialog position" setting: this mode is opted into via
the plugin's Translation Settings and always anchors when it can.

Consumers: actions registered in the Minimal Popup settings
(features.minimal_popup_actions — Translate and Quick Define by default;
showResponseDialog decides; this module never reads settings). "When it fits"
mode rides opts.only_if_fits: the caller asks this module whether the whole
response fits without the ellipsis (hasOverflow — rendered lines, so script
density and font size are handled by construction) and falls back to the full
viewer when it does not.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local MovableContainer = require("ui/widget/container/movablecontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Screen = Device.screen

local MinimalPopup = InputContainer:extend{
    text = nil,             -- the response text (plain text, never markdown)
    selection_data = nil,   -- {sboxes, ...} captured at highlight time (read-only!)
    ui = nil,               -- ReaderUI-like (paging check only)
    para_direction_rtl = nil,  -- nil = auto-detect per paragraph
    lang = nil,             -- BCP-ish language hint for xtext, optional
    on_expand = nil,        -- tap inside the popup
    on_close = nil,         -- dismissed without expanding
}

function MinimalPopup:buildAnchor()
    if not MovableContainer.ensureAnchor then return nil end -- older KOReader
    local boxes = self.selection_data and self.selection_data.sboxes
    if not boxes or #boxes == 0 then return nil end
    if not self.ui or self.ui.paging then return nil end -- EPUB only for now
    return function()
        local box0, box1 = boxes[1], boxes[#boxes]
        if not (box0 and box0.y and box0.h and box1 and box1.y and box1.h) then return nil end
        if box0.y > box1.y then box0, box1 = box1, box0 end
        -- Stale-coordinates guard (rotation/page turn while the request was in
        -- flight): off-screen boxes fall back to centered.
        if box0.y < 0 or (box1.y + box1.h) > Screen:getHeight() then return nil end
        -- Fresh table, never a live sbox: ensureAnchor writes defaults onto the
        -- table it is given, and selection_data is shared by reference with
        -- KOReader (SKIP_DEEP_COPY). x/w left nil = centered horizontally.
        -- Padding keeps the popup from abutting the selection.
        local pad = Size.padding.small
        return { y = box0.y - pad, h = (box1.y + box1.h) - box0.y + 2 * pad }, true -- prefer below
    end
end

function MinimalPopup:init()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local padding = Size.padding.large
    self.width = math.floor(screen_w * 0.85)
    local max_text_h = math.floor(screen_h * 0.45)
    -- Same face the chat viewer renders plain text with
    self.textw = TextBoxWidget:new{
        text = self.text,
        face = Font:getFace("x_smallinfofont"),
        width = self.width - 2 * padding,
        height = max_text_h,               -- cap; shrinks to content below it
        height_adjust = true,
        height_overflow_show_ellipsis = true, -- overflow hint: tap to expand
        para_direction_rtl = self.para_direction_rtl,
        auto_para_direction = self.para_direction_rtl == nil,
        lang = self.lang,
    }
    self.frame = FrameContainer:new{
        radius = Size.radius.window,
        bordersize = Size.border.window,
        padding = padding,
        background = Blitbuffer.COLOR_WHITE,
        self.textw,
    }
    self.movable = MovableContainer:new{
        anchor = self:buildAnchor(),
        self.frame,
    }
    self[1] = WidgetContainer:new{
        align = "center",
        dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h },
        self.movable,
    }
    if Device:isTouchDevice() then
        self.ges_events = {
            Tap = {
                GestureRange:new{
                    ges = "tap",
                    range = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h },
                },
            },
        }
    end
end

--- Did the response overflow the popup's height cap (ellipsis showing)?
-- Reads TextBoxWidget's own overflow condition — the exact test it uses to
-- decide `height_overflow_show_ellipsis` (#vertical_string_list >
-- lines_per_page after init). Language- and font-agnostic: this is rendered
-- lines, not characters, so CJK/Arabic density and the user's font size are
-- accounted for by construction. Defensive nil-checks in case a future
-- KOReader renames the internals (then: never overflows → popup always shown,
-- same as "Always" mode — degraded but not broken).
function MinimalPopup:hasOverflow()
    local tw = self.textw
    if tw and tw.vertical_string_list and tw.lines_per_page then
        return #tw.vertical_string_list > tw.lines_per_page
    end
    return false
end

function MinimalPopup:onTap(_arg, ges)
    if ges.pos:intersectWith(self.frame.dimen) then
        UIManager:close(self)
        if self.on_expand then self.on_expand() end
    else
        UIManager:close(self)
        if self.on_close then self.on_close() end
    end
    return true
end

function MinimalPopup:onClose()
    UIManager:close(self)
    if self.on_close then self.on_close() end
    return true
end

function MinimalPopup:onShow()
    UIManager:setDirty(self, function()
        return "ui", self.movable.dimen
    end)
    return true
end

function MinimalPopup:onCloseWidget()
    UIManager:setDirty(nil, function()
        return "partial", self.movable.dimen
    end)
end

--- Convenience for the response flow: pull the latest assistant message out of
-- a MessageHistory, resolve RTL from the caller-supplied language, show.
-- @param opts { history, selection_data, ui, rtl_language, only_if_fits,
--               on_expand, on_close }
--        rtl_language: the language the response renders in (caller resolves
--        which setting that is — translation vs dictionary language); nil =
--        auto-detect direction per paragraph.
--        only_if_fits: "When it fits" mode — build the popup, and if the whole
--        response does not fit without the ellipsis, discard it and return
--        false so the caller opens the full viewer instead.
-- @return boolean shown (false = nothing to show / does not fit; caller
--         should fall back to the full viewer)
function MinimalPopup.showForResponse(opts)
    opts = opts or {}
    local msgs = opts.history and opts.history.getMessages and opts.history:getMessages()
    local text
    if msgs then
        for i = #msgs, 1, -1 do
            local m = msgs[i]
            if m.role == "assistant" and m.content and m.content ~= "" then
                text = m.content
                break
            end
        end
    end
    if not text then return false end
    local para_direction_rtl = nil
    if opts.rtl_language then
        local ok, Languages = pcall(require, "koassistant_languages")
        if ok and Languages and Languages.isRTL and Languages.isRTL(opts.rtl_language) then
            para_direction_rtl = true
        end
    end
    local popup = MinimalPopup:new{
        text = text,
        selection_data = opts.selection_data,
        ui = opts.ui,
        para_direction_rtl = para_direction_rtl,
        on_expand = opts.on_expand,
        on_close = opts.on_close,
    }
    if opts.only_if_fits and popup:hasOverflow() then
        popup:free()  -- constructed but never shown — release the text blitbuffers
        return false
    end
    UIManager:show(popup)
    return true
end

return MinimalPopup
