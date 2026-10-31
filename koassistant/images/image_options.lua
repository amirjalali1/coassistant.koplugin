--[[--
The picture popup (B537): what one picture is drawn with, on a tap of Generate
Image, at Illustrate… and from a gallery picture's Image settings…, in the
shape of the scope and source popup (the button that draws at the foot).
First the note and the X-Ray entries the prompt writer reads (a passage
picture: at first the entries the passage and the note name, carried entries
among them), both gone after the run. Then the settings (image round S9,
B496), each a button that names it and shows its value, a tap opens its list
(the X-Ray creation form's dials: "Shape: Portrait ▾", two to a row): Prompt
(Write the prompt with AI) beside Style, Shape beside Detail, the provider
beside the model that draws. Those are the Settings rows themselves, built
from the schema through SettingsManager, so a pick is the setting, saved as
Settings → Advanced → Image Generation saves it. The popup stays open under
the pickers it opens (the note box, the entry list, the setting lists), so
every exit of a picker returns to it; a change rebuilds it in place.
docs/image_round_plan.md sections 12 and 13.
]]

local _ = require("koassistant.core.gettext")
local T = require("ffi/util").template

local ImageOptions = {}

-- Each image provider's model row (settings_schema.lua)
local MODEL_ROW = {
    openai = "image_gen_model_openai",
    xai = "image_gen_model_xai",
    gemini = "image_gen_model_gemini",
    openrouter = "image_gen_model_openrouter",
}

-- The longest a note, the picked names or a value show on their button; a
-- typed style shares its row with Prompt
local SHOWN_MAX = 40
local STYLE_MAX = 20

--- A picker's items as the quick-settings popup shows them: a label for an
--- item that only computes one (Custom…). Pure.
function ImageOptions.popupItems(items)
    local out = {}
    for _idx, it in ipairs(items or {}) do
        local copy = {}
        for k, v in pairs(it) do copy[k] = v end
        if not copy.text and copy.text_func then copy.text = copy.text_func() end
        out[#out + 1] = copy
    end
    return out
end

-- A text on one line, cut on a whole character
local function shown(text, max)
    local flat = text:gsub("%s+", " "):match("^%s*(.-)%s*$")
    local head = require("koassistant.request.scope_resolver").utf8Head(flat, max or SHOWN_MAX)
    if #head < #flat then head = head .. "…" end
    return head
end

--- The note's button: Add a note…, or the note's first words. Pure.
function ImageOptions.noteLabel(note)
    if not (type(note) == "string" and note:match("%S")) then return _("Add a note…") end
    return T(_("Note: %1"), shown(note))
end

--- The picks' button: the names on the list, or none. Pure.
function ImageOptions.picksLabel(picked)
    if type(picked) ~= "table" or #picked == 0 then return T(_("X-Ray entries: %1 ▾"), _("none")) end
    return T(_("X-Ray entries: %1 ▾"), shown(table.concat(picked, ", ")))
end

--- A note's entries on the picture's list (B537: the popup shows what the
--- writer reads), changed in place: the entries the note names come first
--- (a note's "this is X" brings X, as before the list); the ones an earlier
--- note brought go when this one does not name them; five at most, room made
--- by the entries only the passage names, never by one picked by hand.
--- Pure. Returns the names the note names that did not fit.
--- @param state table { picked = names, from_note = names }
--- @param data table parsed X-Ray
--- @param note string|nil the note (nil = none now)
--- @param passage string|nil the selection
--- @return table names left out
function ImageOptions.addNoteEntries(state, data, note, passage)
    local PromptWriter = require("koassistant.images.prompt_writer")
    local max = PromptWriter.ENTRIES_MAX
    local function names(list)
        local out = {}
        for _idx, e in ipairs(list) do out[#out + 1] = e.name end
        return out
    end
    local function set(list)
        local out = {}
        for _idx, n in ipairs(list or {}) do out[n:lower()] = true end
        return out
    end
    local note_names = names(PromptWriter.entriesFor(nil, data, nil, note))
    local new_note = set(note_names)
    local by_passage = set(names(PromptWriter.entriesFor(passage, data, 100)))
    local old_note = set(state.from_note)
    -- The list without the earlier note's entries this note does not name,
    -- sorted by what may give way: picked by hand, then named by the passage
    local list, hand, passage_only = {}, {}, {}
    for _idx, n in ipairs(type(state.picked) == "table" and state.picked or {}) do
        local low = n:lower()
        if not (old_note[low] and not new_note[low] and not by_passage[low]) then
            list[#list + 1] = n
            if not new_note[low] then
                if by_passage[low] then passage_only[#passage_only + 1] = n else hand[#hand + 1] = n end
            end
        end
    end
    local take, room, left_out = {}, max, {}
    for _idx, n in ipairs(hand) do
        if room > 0 then take[n:lower()] = true; room = room - 1 end
    end
    for _idx, n in ipairs(note_names) do
        if room > 0 then take[n:lower()] = true; room = room - 1 else left_out[#left_out + 1] = n end
    end
    for _idx, n in ipairs(passage_only) do
        if room > 0 then take[n:lower()] = true; room = room - 1 end
    end
    local out, from_note = {}, {}
    for _idx, n in ipairs(note_names) do
        if take[n:lower()] then
            out[#out + 1] = n
            from_note[#from_note + 1] = n
        end
    end
    for _idx, n in ipairs(list) do
        if take[n:lower()] and not new_note[n:lower()] then out[#out + 1] = n end
    end
    state.picked, state.from_note = out, from_note
    return left_out
end

--- The popup's rows in order, without widgets. Each:
---   { id, gap = true|nil, kind = "buttons", items = { { id, text, enabled, callback } } }
--- Rows of buttons draw as one table; gap starts another below a space. A
--- callback changes a setting or the picture's state and then calls rebuild;
--- one that opens a picker leaves the popup open under it.
--- spec: { writer (the Prompt button), note (offer the note), passage (the
--- selection, read for the entry suggestions), xray (the X-Ray whose entries
--- can be picked, carried ones folded in by PromptWriter.withCarried; nil =
--- no picks), state = { note, picked, from_note } (the picture's own) }.
function ImageOptions.rows(plugin, spec, rebuild)
    local SettingsSchema = require("koassistant.ui.settings_schema")
    local SettingsManager = require("koassistant.ui.settings_manager")
    local ImageGenerator = require("koassistant.images.image_generator")
    local PromptWriter = require("koassistant.images.prompt_writer")
    spec = spec or {}
    local state = spec.state or {}
    local features = plugin.settings:readSetting("features") or {}
    local drawing = ImageGenerator.effectiveProvider(features,
        require("koassistant.core.config_helper").mainProvider(features), plugin.settings)
    local function menuItem(id)
        local item = SettingsSchema:getItemById(id)
        return item and SettingsManager:createMenuItem(plugin, item, SettingsSchema), item
    end
    local function titleOf(mi, fallback)
        return mi and (mi.text_func and mi.text_func() or mi.text) or fallback
    end
    local function picker(label, items)
        plugin:showQuickSettingsPopup(label, ImageOptions.popupItems(items), true, rebuild)
    end
    -- The value a list stands on: its checked item's words
    local function valueOf(items, max)
        for _idx, it in ipairs(items or {}) do
            if it.checked_func and it.checked_func() then
                return shown(it.text or (it.text_func and it.text_func()) or "", max)
            end
        end
    end
    local rows = {}

    -- The picture's own: the note, and the entries the writer reads
    local mine = {}
    if spec.note then
        mine[#mine + 1] = {
            id = "note",
            text = ImageOptions.noteLabel(state.note),
            callback = function()
                ImageGenerator.askNote(state.note, function(text)
                    state.note = text
                    if type(spec.xray) == "table" then
                        local left = ImageOptions.addNoteEntries(state, spec.xray, text, spec.passage)
                        if #left > 0 then
                            require("ui/uimanager"):show(require("ui/widget/infomessage"):new{
                                text = T(_("Not added (the prompt writer reads %1 entries at most): %2"),
                                    PromptWriter.ENTRIES_MAX, table.concat(left, ", ")),
                                timeout = 3,
                            })
                        end
                    end
                    rebuild()
                end)
            end,
        }
    end
    if type(spec.xray) == "table" and #PromptWriter.pickable(spec.xray) > 0 then
        mine[#mine + 1] = {
            id = "picks",
            text = ImageOptions.picksLabel(state.picked),
            -- only the prompt writer reads them
            enabled = not spec.writer or features.image_gen_writer ~= false,
            callback = function()
                ImageGenerator.pickEntries(
                    PromptWriter.pickerTiers(spec.xray, spec.passage, state.note, state.picked),
                    state.picked, function(names)
                        state.picked = names
                        rebuild()
                    end)
            end,
        }
    end
    if #mine > 0 then
        rows[#rows + 1] = { id = "picture", kind = "buttons", items = mine }
    end

    -- How the prompt is made (where a prompt is written) beside the Style,
    -- then Shape and Detail; a tap opens the list (Style's Custom… asks for
    -- the reader's words in a box of its own). Without the Prompt button the
    -- Style has the row to itself.
    local first = {}
    local writer_mi = spec.writer and menuItem("image_gen_writer")
    if writer_mi then
        -- the Write the prompt with AI setting as two choices; a pick that
        -- matches the setting leaves it
        local function choose(on)
            return function()
                if (writer_mi.checked_func() and true or false) ~= on then writer_mi.callback() end
            end
        end
        first[#first + 1] = {
            id = "prompt",
            text = T(_("Prompt: %1 ▾"), writer_mi.checked_func() and _("Written by AI") or _("Passage as is")),
            callback = function()
                picker(_("Prompt"), {
                    { text = _("Written by AI, from the passage, the entries and your note"),
                      checked_func = function() return writer_mi.checked_func() and true or false end,
                      callback = choose(true) },
                    { text = _("The passage as is, with your note and the style"),
                      checked_func = function() return not writer_mi.checked_func() end,
                      callback = choose(false) },
                })
            end,
        }
    end
    local style_mi = menuItem("image_gen_style")
    local styles = plugin:imageStyleItems(rebuild) or {}
    first[#first + 1] = {
        id = "style",
        text = T(_("Style: %1 ▾"), valueOf(styles, writer_mi and STYLE_MAX or nil) or ""),
        callback = function() picker(titleOf(style_mi, _("Style")), styles) end,
    }
    rows[#rows + 1] = { id = "style", gap = #rows > 0 or nil, kind = "buttons", items = first }
    local look = {}
    local shape_mi = menuItem("image_gen_shape")
    if shape_mi then
        look[#look + 1] = { id = "shape", text = T(_("Shape: %1 ▾"), valueOf(shape_mi.sub_item_table) or ""),
            callback = function() picker(titleOf(shape_mi), shape_mi.sub_item_table) end }
    end
    local detail_mi = menuItem("image_gen_detail")
    if detail_mi then
        look[#look + 1] = {
            id = "detail",
            text = T(_("Detail: %1 ▾"), valueOf(detail_mi.sub_item_table) or ""),
            -- grayed in place while the model in use has a single setting
            enabled = not detail_mi.enabled_func or detail_mi.enabled_func() ~= false,
            callback = function() picker(titleOf(detail_mi), detail_mi.sub_item_table) end,
        }
    end
    rows[#rows + 1] = { id = "look", kind = "buttons", items = look }

    -- The provider and the model that draws, side by side; a tap opens the
    -- Settings row's picker, titled as Settings titles it
    local drawn = {}
    local provider_mi, provider_item = menuItem("image_gen_provider")
    if provider_mi then
        local value = features.image_gen_provider
        if not (type(value) == "string" and value ~= "") then value = provider_item.default end
        local text
        for _idx, o in ipairs(provider_item.options or {}) do
            if o.value == value then text = o.text end
        end
        drawn[#drawn + 1] = { id = "provider", text = T(_("Provider: %1 ▾"), text or tostring(value)), callback = function()
            picker(titleOf(provider_mi), provider_mi.sub_item_table)
        end }
    end
    local model_id = MODEL_ROW[drawing]
    local model_mi = model_id and menuItem(model_id)
    if model_mi then
        local value = require("koassistant.request.model_lists").resolveImageModel(drawing,
            features["image_gen_model_" .. drawing])
        local title = titleOf(model_mi)
        drawn[#drawn + 1] = { id = "model", text = T(_("Model: %1 ▾"), value or ""), callback = function()
            local items
            if model_id == "image_gen_model_openrouter" then
                items = plugin:openRouterImageModelItems(rebuild)
            else
                items = model_mi.sub_item_table
            end
            picker(title, items)
        end }
    end
    rows[#rows + 1] = { id = "drawn", kind = "buttons", items = drawn }
    return rows
end

--- Show the popup. spec = { title, passage (the selection, read for the entry
--- suggestions; the reader has just selected it, so it is not shown again),
--- writer (the Prompt button), note (the note), xray (the X-Ray whose entries
--- can be picked), state = { note, picked }, actions = { { text, callback },
--- ... } (each closes the popup first) }. plugin = the KOAssistant instance
--- (its settings, the quick-settings popup and the Style and OpenRouter
--- pickers). Returns the shown window.
function ImageOptions.show(plugin, spec)
    local UIManager = require("ui/uimanager")
    local Blitbuffer = require("ffi/blitbuffer")
    local ButtonTable = require("ui/widget/buttontable")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local Geom = require("ui/geometry")
    local GestureRange = require("ui/gesturerange")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local MovableContainer = require("ui/widget/container/movablecontainer")
    local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
    local Size = require("ui/size")
    local TitleBar = require("ui/widget/titlebar")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local Screen = require("device").screen
    spec = spec or {}
    spec.state = spec.state or {}

    local Device = require("device")
    local current, first_frame_h, scrolled
    local function build()
        local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
        local dialog_w = math.floor(math.min(screen_w, screen_h) * 0.8)
        local content_w = dialog_w - 2 * Size.padding.large
        -- The window first: every widget in it repaints through it, so a row
        -- of the scrolled layout is cropped by the scroll
        local window = InputContainer:new{ dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h } }
        local function rebuild()
            -- A picker's late callback (OpenRouter's catalog arrives after its
            -- fetch) never reopens a popup the reader closed or drew from
            if not (current and UIManager:isWidgetShown(current)) then return end
            scrolled = current._scroll and current._scroll:getScrolledOffset() or nil
            UIManager:close(current)
            build()
        end
        local rows = ImageOptions.rows(plugin, spec, rebuild)
        -- The rows at a width: the column's, or narrower beside a scrollbar
        local function body(width)
            local vgroup = VerticalGroup:new{ align = "left" }
            -- Rows of buttons in one table, in the creation form's smaller
            -- type; a gap starts another table below a space
            local pending = {}
            local function flush()
                if #pending == 0 then return end
                table.insert(vgroup, VerticalSpan:new{ width = Size.padding.default })
                table.insert(vgroup, ButtonTable:new{
                    width = width, buttons = pending, zero_sep = true, show_parent = window,
                })
                pending = {}
            end
            for _idx, row in ipairs(rows) do
                if row.kind == "buttons" and #row.items > 0 then
                    if row.gap then flush() end
                    local line = {}
                    for _j, it in ipairs(row.items) do
                        line[#line + 1] = { text = it.text, id = it.id, enabled = it.enabled ~= false,
                            callback = it.callback, font_size = 16, font_bold = false }
                    end
                    pending[#pending + 1] = line
                end
            end
            flush()
            table.insert(vgroup, VerticalSpan:new{ width = Size.padding.default })
            return vgroup
        end
        local vgroup = body(content_w)

        -- The buttons that draw, at the foot
        local action_rows, line = {}, {}
        for _idx, a in ipairs(spec.actions or {}) do
            local action = a
            line[#line + 1] = {
                text = action.text,
                callback = function()
                    UIManager:close(window)
                    action.callback()
                end,
            }
            if #line == 2 then
                action_rows[#action_rows + 1] = line
                line = {}
            end
        end
        if #line > 0 then action_rows[#action_rows + 1] = line end
        local actions = #action_rows > 0 and ButtonTable:new{
            width = content_w, buttons = action_rows, zero_sep = true, show_parent = window,
        } or nil

        local title_bar = TitleBar:new{
            width = dialog_w,
            align = "left",
            with_bottom_line = true,
            title = spec.title or _("Image settings"),
            title_shrink_font_to_fit = true,
            show_parent = window,
            close_callback = function() UIManager:close(window) end,
        }
        -- Taller than the screen (a small screen held sideways): the rows
        -- scroll, the title and the buttons that draw stay
        local fixed_h = title_bar:getSize().h + (actions and actions:getSize().h or 0) + 2 * Size.padding.default
        local max_body = math.floor(screen_h * 0.98) - fixed_h
        local body_h = vgroup:getSize().h
        local scroll
        if body_h > max_body then
            vgroup = body(dialog_w - ScrollableContainer:getScrollbarWidth() - 2 * Size.padding.large)
            body_h = vgroup:getSize().h
            scroll = ScrollableContainer:new{
                dimen = Geom:new{ w = dialog_w, h = max_body },
                show_parent = window,
                CenterContainer:new{ dimen = Geom:new{ w = dialog_w - ScrollableContainer:getScrollbarWidth(), h = body_h }, vgroup },
            }
        end
        local column = VerticalGroup:new{ align = "left", title_bar }
        if scroll then
            table.insert(column, scroll)
        else
            table.insert(column, CenterContainer:new{ dimen = Geom:new{ w = dialog_w, h = body_h }, vgroup })
        end
        if actions then
            table.insert(column, CenterContainer:new{ dimen = Geom:new{ w = dialog_w, h = actions:getSize().h }, actions })
            table.insert(column, VerticalSpan:new{ width = Size.padding.default })
        end
        local frame = FrameContainer:new{
            radius = Size.radius.window, padding = 0, margin = 0,
            background = Blitbuffer.COLOR_WHITE,
            column,
        }
        local movable = MovableContainer:new{ frame }
        -- The top stays where it opened while rows change (the scope popup's
        -- trick), and the bottom never leaves the screen when a row grows (the
        -- creation form's clamp)
        local frame_h = frame:getSize().h
        if not first_frame_h then first_frame_h = frame_h end
        local y_off = math.floor((frame_h - first_frame_h) / 2)
        local top = math.floor((screen_h - frame_h) / 2) + y_off
        local overflow = top + frame_h - screen_h
        if overflow > 0 then
            y_off = y_off - overflow
            top = top - overflow
        end
        if top < 0 then y_off = y_off - top end
        movable:setMovedOffset({ x = 0, y = y_off })

        window[1] = CenterContainer:new{ dimen = Geom:new{ w = screen_w, h = screen_h }, movable }
        window._frame = frame
        window._rows = rows
        if scroll then
            window._scroll = scroll
            window.cropping_widget = scroll
            if scrolled then scroll:setScrolledOffset(scrolled) end
        end
        window.ges_events = {
            TapClose = { GestureRange:new{ ges = "tap", range = Geom:new{ w = screen_w, h = screen_h } } },
        }
        -- Back closes it, as a ButtonDialog's does
        if Device:hasKeys() then
            window.key_events = { Close = { { Device.input.group.Back } } }
        end
        function window:onTapClose(_arg, ges_ev)
            if ges_ev.pos:notIntersectWith(frame.dimen) then UIManager:close(self) end
            return true
        end
        function window:onClose()
            UIManager:close(self)
            return true
        end
        function window:onCloseWidget()
            UIManager:setDirty(nil, function() return "ui", frame.dimen end)
        end
        function window:onShow()
            UIManager:setDirty(self, function() return "ui", frame.dimen end)
            return true
        end
        current = window
        UIManager:show(window)
    end
    build()
    return current
end

return ImageOptions
