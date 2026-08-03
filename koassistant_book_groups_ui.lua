--[[--
Book groups manager UI (xray_ecosystem_plan.md item 46, ref #90).

Small ButtonDialog stack over koassistant_book_groups.lua:
- showManager: all groups → per-group screen; create.
- showGroup: ordered member list (tap a book for move/remove), add books via
  the existing multi-select BookPicker, rename, delete.
- showBookRow: the Book Settings entry — this book's memberships, join/create.

Entry points: main menu row (settings schema "book_groups"), Book Settings
row, and the cross-book merge picker footer.
]]

local UIManager = require("ui/uimanager")
local T = require("ffi/util").template
local _ = require("koassistant_gettext")

local GroupsUI = {}

local function groups() return require("koassistant_book_groups") end

--- Book Settings row value: "None", "Name", or "Name +2".
function GroupsUI.rowLabel(path)
    local list = groups().groupsFor(path)
    if #list == 0 then return _("None") end
    local label = list[1].name
    if #list > 1 then label = label .. " +" .. (#list - 1) end
    return label
end

local function promptName(title, initial, on_done, on_cancel)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = initial or "",
        buttons = {{
            { text = _("Cancel"), id = "close",
                callback = function()
                    UIManager:close(dialog)
                    if on_cancel then on_cancel() end
                end },
            { text = _("Save"), is_enter_default = true,
                callback = function()
                    local name = dialog:getInputText()
                    UIManager:close(dialog)
                    if name and name ~= "" then
                        on_done(name)
                    elseif on_cancel then
                        on_cancel()
                    end
                end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Per-group screen. opts: { plugin, ui, on_close }
function GroupsUI.showGroup(group_id, opts)
    opts = opts or {}
    local ButtonDialog = require("ui/widget/buttondialog")
    local BookGroups = groups()
    local group = BookGroups.byId(group_id)
    if not group then
        if opts.on_close then opts.on_close() end
        return
    end
    local dialog
    local function reopen()
        UIManager:close(dialog)
        GroupsUI.showGroup(group_id, opts)
    end
    local rows = {}
    for i, path in ipairs(group.books) do
        local captured = path
        local title = BookGroups.displayTitle(captured, opts.ui)
        if not BookGroups.fileExists(captured) then
            title = title .. " " .. _("(missing)")
        end
        rows[#rows + 1] = {{
            text = i .. ". " .. title,
            align = "left",
            callback = function()
                -- Same compact arrow dialog as the action/QS ordering managers
                local book_dialog
                book_dialog = ButtonDialog:new{
                    title = title,
                    buttons = {
                        {
                            { text = "\u{2191}", enabled = i > 1, callback = function()
                                UIManager:close(book_dialog)
                                BookGroups.moveBook(group_id, captured, -1)
                                reopen()
                            end },
                            { text = "\u{2193}", enabled = i < #group.books, callback = function()
                                UIManager:close(book_dialog)
                                BookGroups.moveBook(group_id, captured, 1)
                                reopen()
                            end },
                        },
                        {{ text = _("Remove from group"), callback = function()
                            UIManager:close(book_dialog)
                            BookGroups.removeBook(group_id, captured)
                            reopen()
                        end }},
                    },
                    shrink_unneeded_width = true,
                }
                UIManager:show(book_dialog)
            end,
        }}
    end
    if #group.books == 0 then
        rows[#rows + 1] = {{ text = _("No books yet — add some below."), enabled = false }}
    end
    -- Item 48(a): the group as launch surface — library chat/actions with the
    -- members pre-selected (reading order kept; saved chats stamped with the group)
    if #group.books > 0 and opts.plugin and opts.plugin.openLibraryDialogForGroup then
        rows[#rows + 1] = {{
            text = _("Library chat with this group…"),
            callback = function()
                UIManager:close(dialog)
                opts.plugin:openLibraryDialogForGroup(group_id)
            end,
        }}
    end
    rows[#rows + 1] = {{
        text = _("Add books…"),
        callback = function()
            UIManager:close(dialog)
            local BookPicker = require("koassistant_book_picker")
            BookPicker:show({
                on_confirm = function(selected_files)
                    for path in pairs(selected_files or {}) do
                        BookGroups.addBook(group_id, path)
                    end
                    GroupsUI.showGroup(group_id, opts)
                end,
                on_close = function() GroupsUI.showGroup(group_id, opts) end,
            })
        end,
    }}
    rows[#rows + 1] = {{
        text = _("Rename group…"),
        callback = function()
            UIManager:close(dialog)
            promptName(_("Rename group"), group.name, function(name)
                BookGroups.rename(group_id, name)
                GroupsUI.showGroup(group_id, opts)
            end, function() GroupsUI.showGroup(group_id, opts) end)
        end,
    }}
    rows[#rows + 1] = {{
        text = _("Delete group…"),
        callback = function()
            local confirm
            confirm = ButtonDialog:new{
                title = T(_("Delete the group \"%1\"?\nBooks and their artifacts are not touched — only the grouping is removed."), group.name),
                buttons = {
                    {{ text = _("Delete"), callback = function()
                        UIManager:close(confirm)
                        UIManager:close(dialog)
                        BookGroups.remove(group_id)
                        if opts.on_close then opts.on_close() end
                    end }},
                    {{ text = _("Cancel"), callback = function()
                        UIManager:close(confirm)
                    end }},
                },
            }
            UIManager:show(confirm)
        end,
    }}
    rows[#rows + 1] = {{
        text = _("Back"),
        callback = function()
            UIManager:close(dialog)
            if opts.on_close then opts.on_close() end
        end,
    }}
    dialog = ButtonDialog:new{
        title = T(_("Group: %1"), group.name)
            .. "\n" .. _("Order is the reading order — it drives merge suggestions and previous/next navigation."),
        buttons = rows,
    }
    UIManager:show(dialog)
end

--- Top-level manager. opts: { plugin, ui, on_close }
function GroupsUI.showManager(opts)
    opts = opts or {}
    local ButtonDialog = require("ui/widget/buttondialog")
    local BookGroups = groups()
    local dialog
    local rows = {}
    for _idx, group in ipairs(BookGroups.all()) do
        local captured = group
        rows[#rows + 1] = {{
            text = T(_("%1 (%2 books)"), captured.name, #captured.books),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                GroupsUI.showGroup(captured.id, {
                    plugin = opts.plugin, ui = opts.ui,
                    on_close = function() GroupsUI.showManager(opts) end,
                })
            end,
        }}
    end
    if #rows == 0 then
        rows[#rows + 1] = {{
            text = _("No groups yet. A group is an ordered set of books — a series, an author, a project."),
            enabled = false,
        }}
    end
    rows[#rows + 1] = {{
        text = _("New group…"),
        callback = function()
            UIManager:close(dialog)
            promptName(_("New group"), nil, function(name)
                local group = groups().create(name)
                GroupsUI.showGroup(group.id, {
                    plugin = opts.plugin, ui = opts.ui,
                    on_close = function() GroupsUI.showManager(opts) end,
                })
            end, function() GroupsUI.showManager(opts) end)
        end,
    }}
    rows[#rows + 1] = {{
        text = _("Close"),
        callback = function()
            UIManager:close(dialog)
            if opts.on_close then opts.on_close() end
        end,
    }}
    dialog = ButtonDialog:new{
        title = _("Groups"),
        buttons = rows,
    }
    UIManager:show(dialog)
end

--- Book Settings entry for one book. opts: { plugin, ui, on_close }
function GroupsUI.showBookRow(path, opts)
    opts = opts or {}
    local ButtonDialog = require("ui/widget/buttondialog")
    local BookGroups = groups()
    local memberships = BookGroups.groupsFor(path)
    local dialog
    local function reopen()
        UIManager:close(dialog)
        GroupsUI.showBookRow(path, opts)
    end
    local rows = {}
    for _idx, group in ipairs(memberships) do
        local captured = group
        local pos = BookGroups.positionOf(captured, path)
        rows[#rows + 1] = {{
            text = T(_("In %1 (book %2 of %3)"), captured.name, pos, #captured.books),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                GroupsUI.showGroup(captured.id, {
                    plugin = opts.plugin, ui = opts.ui,
                    on_close = reopen,
                })
            end,
        }}
    end
    -- Join an existing group this book isn't in yet
    local joinable = {}
    for _idx, group in ipairs(BookGroups.all()) do
        if not BookGroups.positionOf(group, path) then
            joinable[#joinable + 1] = group
        end
    end
    for _idx, group in ipairs(joinable) do
        local captured = group
        rows[#rows + 1] = {{
            text = T(_("Add to %1"), captured.name),
            align = "left",
            callback = function()
                BookGroups.addBook(captured.id, path)
                reopen()
            end,
        }}
    end
    rows[#rows + 1] = {{
        text = _("New group with this book…"),
        callback = function()
            UIManager:close(dialog)
            promptName(_("New group"), nil, function(name)
                local group = groups().create(name)
                groups().addBook(group.id, path)
                GroupsUI.showBookRow(path, opts)
            end, function() GroupsUI.showBookRow(path, opts) end)
        end,
    }}
    rows[#rows + 1] = {{
        text = _("Back"),
        callback = function()
            UIManager:close(dialog)
            if opts.on_close then opts.on_close() end
        end,
    }}
    dialog = ButtonDialog:new{
        title = T(_("Groups — %1"), BookGroups.displayTitle(path, opts.ui)),
        buttons = rows,
    }
    UIManager:show(dialog)
end

return GroupsUI
