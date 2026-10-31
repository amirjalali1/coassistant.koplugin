--[[
Flow tests (docs/test_automation_plan.md, layer 1): the plugin's REAL dialog
code, driven without KOReader. install() swaps UIManager's show/close and the
dialog widgets' :new for recorders: every widget shown lands on a stack the
test reads (texts, title) and taps (a button's callback, run as a finger
would). The module tables are patched in place, so a module that captured one
at load sees the recorder too; restore() puts every field back (one Lua process
runs the whole suite).

    local Recorder = require("ui_recorder")
    local ui = Recorder.install()
    ... open something ...
    ui:texts()               -- the top widget's buttons (or its text)
    ui:tap("Illustrate")     -- run that button's callback
    ui:type("at night")      -- what an InputDialog's getInputText returns
    ui:tapOutside()          -- a tap outside the top dialog (or the Back key)
    ui:restore()
]]

local Recorder = {}

local WIDGETS = {
    "ui/widget/buttondialog", "ui/widget/inputdialog", "ui/widget/confirmbox",
    "ui/widget/multiconfirmbox", "ui/widget/infomessage", "ui/widget/notification",
    "ui/widget/textviewer",
}

local R = {}
R.__index = R

function Recorder.install()
    local self = setmetatable({ stack = {}, shown = {}, saved = { modules = {} } }, R)
    local UIManager = require("ui/uimanager")
    self.UIManager = UIManager
    self.saved.show = rawget(UIManager, "show")
    self.saved.close = rawget(UIManager, "close")
    self.saved.isWidgetShown = rawget(UIManager, "isWidgetShown")
    UIManager.show = function(_um, w)
        self.stack[#self.stack + 1] = w
        self.shown[#self.shown + 1] = w
    end
    UIManager.close = function(_um, w)
        for i = #self.stack, 1, -1 do
            if self.stack[i] == w then
                table.remove(self.stack, i)
                break
            end
        end
    end
    UIManager.isWidgetShown = function(_um, w)
        for _idx, s in ipairs(self.stack) do
            if s == w then return true end
        end
        return false
    end
    for _idx, name in ipairs(WIDGETS) do
        local mod = package.loaded[name]
        local fresh = mod == nil
        if fresh then
            mod = {}
            package.loaded[name] = mod
        end
        self.saved.modules[name] = { mod = mod, fresh = fresh, new = rawget(mod, "new") }
        mod.new = function(cls, o)
            o = o or {}
            o._widget = name
            o.getInputText = o.getInputText or function(w) return w._typed or w.input end
            o.onShowKeyboard = o.onShowKeyboard or function() end
            return setmetatable(o, { __index = cls })
        end
    end
    return self
end

--- The widget on top, or nil.
function R:top()
    return self.stack[#self.stack]
end

-- A ButtonDialog's or InputDialog's buttons (rows), or a ConfirmBox's two
local function buttonsOf(w)
    local out = {}
    if type(w) ~= "table" then return out end
    if type(w.buttons) == "table" then
        for _idx, row in ipairs(w.buttons) do
            for _j, b in ipairs(type(row) == "table" and row or {}) do
                if type(b) == "table" and b.text then out[#out + 1] = b end
            end
        end
    end
    if w.ok_callback or w.ok_text then
        out[#out + 1] = { text = w.ok_text or "OK", callback = w.ok_callback }
        out[#out + 1] = { text = w.cancel_text or "Cancel", callback = w.cancel_callback }
    end
    return out
end

--- The texts of a widget's buttons (the top one by default), or its text.
function R:texts(w)
    w = w or self:top()
    local out = {}
    for _idx, b in ipairs(buttonsOf(w)) do out[#out + 1] = b.text end
    if #out == 0 and type(w) == "table" and w.text then out[1] = w.text end
    return out
end

--- Whether a widget (the top one by default) has a button with this text.
function R:has(text, w)
    for _idx, t in ipairs(self:texts(w)) do
        if t == text then return true end
    end
    return false
end

--- Run the callback of the button with this text, as a tap would. Fails on a
--- missing or disabled button, naming what is there.
function R:tap(text, w)
    w = w or self:top()
    for _idx, b in ipairs(buttonsOf(w)) do
        if b.text == text then
            if b.enabled == false then error("the button is disabled: " .. text, 2) end
            if b.callback then b.callback() end
            return true
        end
    end
    error(string.format("no button %q in: %s", tostring(text), table.concat(self:texts(w), " | ")), 2)
end

--- Type into an InputDialog (the top one by default).
function R:type(text, w)
    (w or self:top())._typed = text
end

--- A tap outside a ButtonDialog (the top one by default), or the Back key:
--- its tap_close_callback, then the close, as KOReader's onClose runs them.
function R:tapOutside(w)
    w = w or self:top()
    if w.tap_close_callback then w.tap_close_callback() end
    self.UIManager:close(w)
end

function R:restore()
    local UIManager = self.UIManager
    UIManager.show = self.saved.show
    UIManager.close = self.saved.close
    UIManager.isWidgetShown = self.saved.isWidgetShown
    for name, s in pairs(self.saved.modules) do
        if s.fresh then
            package.loaded[name] = nil
        else
            s.mod.new = s.new
        end
    end
end

return Recorder
