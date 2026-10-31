--[[--
The Generated Images grid (image round S7, B062): one page of thumbnails at
a time, 3 by 3 held upright and 4 by 2 held sideways, each with a line naming
the picture, KOReader's page chevrons below (as Menu). Tap = on_tap(item),
hold = on_hold(item), ☰ = on_menu(); swipes and page keys turn pages, a
swipe down closes. Before a page is built, before_page(items) may make the
thumbnails it lacks.

items = { { thumb = path|nil (nil = a placeholder), label = string, ... } };
setItems(items) after a change keeps the page where it can.
]]

local Blitbuffer = require("ffi/blitbuffer")
local logger = require("koassistant.core.logger")
local BD = require("ui/bidi")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local RenderImage = require("ui/renderimage")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local _ = require("koassistant.core.gettext")
local T = require("ffi/util").template

-- One cell: the thumbnail framed (or a placeholder) over a line naming it
local GridCell = InputContainer:extend{
    item = nil,
    width = nil,
    height = nil,
    grid = nil,
}

function GridCell:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = {
        TapSelect = { GestureRange:new{ ges = "tap", range = self.dimen } },
        HoldSelect = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
    local inner_w = self.width - 2 * Size.padding.small
    local label = TextWidget:new{
        text = self.item.label or "",
        face = Font:getFace("cfont", 16),
        max_width = inner_w,
    }
    local box = Geom:new{
        w = inner_w,
        h = math.max(1, self.height - label:getSize().h - 3 * Size.padding.small),
    }
    local picture
    -- Decoded here, not through ImageWidget's file cache (8 MiB shared with
    -- the icons), and fitted to the box so the frame hugs the picture
    local bb = self.item.thumb and RenderImage:renderImageFile(self.item.thumb, false)
    if bb then
        local fit_w, fit_h = box.w - 2 * Size.border.thin, box.h - 2 * Size.border.thin
        local scale = math.min(fit_w / bb:getWidth(), fit_h / bb:getHeight())
        -- scaleBlitBuffer frees the decoded one when it makes a new one
        bb = RenderImage:scaleBlitBuffer(bb, math.max(1, math.floor(bb:getWidth() * scale)),
            math.max(1, math.floor(bb:getHeight() * scale)))
        picture = FrameContainer:new{
            bordersize = Size.border.thin,
            padding = 0,
            margin = 0,
            ImageWidget:new{ image = bb, image_disposable = true },
        }
    else
        picture = FrameContainer:new{
            bordersize = Size.border.thin,
            padding = 0,
            margin = 0,
            CenterContainer:new{
                dimen = Geom:new{ w = box.w - 2 * Size.border.thin, h = box.h - 2 * Size.border.thin },
                TextWidget:new{
                    text = _("No preview"),
                    face = Font:getFace("cfont", 14),
                    max_width = box.w - 2 * Size.padding.small,
                },
            },
        }
    end
    self[1] = CenterContainer:new{
        dimen = Geom:new{ w = self.width, h = self.height },
        VerticalGroup:new{
            align = "center",
            CenterContainer:new{ dimen = box, picture },
            VerticalSpan:new{ width = Size.padding.small },
            label,
        },
    }
end

function GridCell:onTapSelect()
    if self.grid.on_tap then self.grid.on_tap(self.item) end
    return true
end

function GridCell:onHoldSelect()
    if self.grid.on_hold then self.grid.on_hold(self.item) end
    return true
end

local ImageGrid = InputContainer:extend{
    title = "",
    items = nil,
    on_tap = nil,
    on_hold = nil,
    on_menu = nil,
    on_close = nil,
    before_page = nil,
    page = 1,
}

--- Columns and rows for a screen: 3 by 3 held upright, 4 by 2 sideways. Pure.
function ImageGrid.shape(w, h)
    if w > h then return 4, 2 end
    return 3, 3
end

function ImageGrid:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.covers_fullscreen = true -- hint for UIManager:_repaint()
    -- pictures: a window closing over the grid repaints it dithered (as
    -- CoverBrowser's mosaic does)
    self.dithered = true
    self.items = self.items or {}
    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
            NextPage = { { Device.input.group.PgFwd } },
            PrevPage = { { Device.input.group.PgBack } },
        }
    end
    if Device:isTouchDevice() then
        self.ges_events = {
            Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        }
    end
    self.title_bar = TitleBar:new{
        width = self.dimen.w,
        fullscreen = true,
        title = self.title,
        left_icon = self.on_menu and "appbar.menu" or nil,
        left_icon_tap_callback = function() if self.on_menu then self.on_menu() end end,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }
    local first, left, right, last = "chevron.first", "chevron.left", "chevron.right", "chevron.last"
    if BD.mirroredUILayout() then
        left, right = right, left
        first, last = last, first
    end
    local function chevron(icon, fn)
        return Button:new{ icon = icon, callback = fn, bordersize = 0, show_parent = self }
    end
    self.first_chev = chevron(first, function() self:goToPage(1) end)
    self.prev_chev = chevron(left, function() self:onPrevPage() end)
    self.next_chev = chevron(right, function() self:onNextPage() end)
    self.last_chev = chevron(last, function() self:goToPage(self:pageCount()) end)
    self:update()
end

function ImageGrid:perPage()
    local cols, rows = ImageGrid.shape(self.dimen.w, self.dimen.h)
    return cols * rows
end

function ImageGrid:pageCount()
    return math.max(1, math.ceil(#self.items / self:perPage()))
end

--- Build the current page (the page is clamped to the items there are).
function ImageGrid:update()
    local cols, rows = ImageGrid.shape(self.dimen.w, self.dimen.h)
    local per_page = cols * rows
    local count = self:pageCount()
    self.page = math.min(math.max(self.page, 1), count)
    local page_items = {}
    local from = (self.page - 1) * per_page + 1
    for i = from, math.min(from + per_page - 1, #self.items) do
        page_items[#page_items + 1] = self.items[i]
    end
    if self.before_page then self.before_page(page_items) end
    logger.dbg("KOAssistant images: grid page", self.page, "of", self:pageCount(), cols .. "x" .. rows, #page_items, "pictures")

    local page_text = TextWidget:new{
        text = T(_("Page %1 of %2"), self.page, count),
        face = Font:getFace("cfont", 20),
    }
    self.first_chev:enableDisable(self.page > 1)
    self.prev_chev:enableDisable(self.page > 1)
    self.next_chev:enableDisable(self.page < count)
    self.last_chev:enableDisable(self.page < count)
    local spacer = HorizontalSpan:new{ width = Size.span.horizontal_default }
    local footer = HorizontalGroup:new{
        self.first_chev, spacer, self.prev_chev, spacer, page_text,
        spacer, self.next_chev, spacer, self.last_chev,
    }

    local margin = Size.padding.default
    local gap = Size.padding.large
    local grid_w = self.dimen.w - 2 * margin
    local grid_h = self.dimen.h - self.title_bar:getHeight() - footer:getSize().h - 2 * margin
    local cell_w = math.floor((grid_w - (cols - 1) * gap) / cols)
    local cell_h = math.floor((grid_h - (rows - 1) * gap) / rows)

    -- free the page being replaced (the thumbnails it decoded)
    if self.page_group then self.page_group:free() end
    local body
    if #page_items == 0 then
        body = CenterContainer:new{
            dimen = Geom:new{ w = grid_w, h = grid_h },
            TextWidget:new{ text = _("No generated images."), face = Font:getFace("cfont", 20) },
        }
    else
        body = VerticalGroup:new{ align = "left" }
        for r = 1, rows do
            local row = HorizontalGroup:new{ align = "top" }
            for c = 1, cols do
                local item = page_items[(r - 1) * cols + c]
                if c > 1 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
                if item then
                    row[#row + 1] = GridCell:new{ item = item, width = cell_w, height = cell_h, grid = self }
                end
            end
            if #row > 0 then
                if r > 1 then body[#body + 1] = VerticalSpan:new{ width = gap } end
                body[#body + 1] = row
            end
        end
    end
    self.page_group = body

    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        width = self.dimen.w,
        height = self.dimen.h,
        OverlapGroup:new{
            dimen = self.dimen:copy(),
            allow_mirroring = false,
            VerticalGroup:new{
                align = "left",
                self.title_bar,
                VerticalSpan:new{ width = margin },
                HorizontalGroup:new{
                    HorizontalSpan:new{ width = margin },
                    body,
                },
            },
            BottomContainer:new{
                dimen = self.dimen:copy(),
                footer,
            },
        },
    }
end

-- Pictures want a dithered refresh on e-ink
function ImageGrid:refresh()
    UIManager:setDirty(self, function()
        return "ui", self.dimen, true
    end)
end

function ImageGrid:onShow()
    self:refresh()
    return true
end

--- New items (after a deletion or a new picture); the page stays where it can.
function ImageGrid:setItems(items, page)
    self.items = items or {}
    if page then self.page = page end
    self:update()
    self:refresh()
end

function ImageGrid:goToPage(page)
    self.page = page
    self:update()
    self:refresh()
end

function ImageGrid:onNextPage()
    local count = self:pageCount()
    if count <= 1 then return true end
    self:goToPage(self.page < count and self.page + 1 or 1)
    return true
end

function ImageGrid:onPrevPage()
    local count = self:pageCount()
    if count <= 1 then return true end
    self:goToPage(self.page > 1 and self.page - 1 or count)
    return true
end

function ImageGrid:onSwipe(_arg, ges_ev)
    local direction = BD.flipDirectionIfMirroredUILayout(ges_ev.direction)
    if direction == "west" then
        self:onNextPage()
    elseif direction == "east" then
        self:onPrevPage()
    elseif direction == "south" then
        self:onClose()
    elseif direction ~= "north" then
        -- a diagonal swipe: a full refresh, as everywhere in KOReader
        UIManager:setDirty(nil, "full")
    end
    return true
end

function ImageGrid:onClose()
    UIManager:close(self)
    if self.on_close then self.on_close() end
    return true
end

function ImageGrid:onCloseWidget()
    if self.page_group then
        self.page_group:free()
        self.page_group = nil
    end
    UIManager:setDirty(nil, function()
        return "ui", self.dimen
    end)
end

return ImageGrid
