--[[--
Book page ("Book overview", book page round 2026-08-09): one full-screen view
of everything the plugin holds for ONE book — the artifact rows the View
Artifacts popup shows (same destinations), plus chats, notebook, group
membership and book settings. Strictly a VIEW over existing stores: nothing is
generated here, nothing is stored here, and the popup stays the two-tap fast
path. Entry points: the popup's "Book overview…" row and the X-Ray browser's
◀ at root (live X-Ray views sit one level below this page). Singleton like the
X-Ray browser: show() replaces any open instance, so the browser's level-up
never stacks pages.
]]

local UIManager = require("ui/uimanager")
local Menu = require("ui/widget/menu")
local Screen = require("device").screen
local Constants = require("koassistant_constants")
local T = require("ffi/util").template
local _ = require("koassistant_gettext")

local BookPage = {}

--- Same compact age the View Artifacts popup shows next to artifact names
local function relativeDate(ts)
    ts = tonumber(ts)
    if not ts then return nil end
    local today_t = os.date("*t", os.time())
    today_t.hour, today_t.min, today_t.sec = 0, 0, 0
    local then_t = os.date("*t", ts)
    then_t.hour, then_t.min, then_t.sec = 0, 0, 0
    local days = math.floor((os.time(today_t) - os.time(then_t)) / 86400)
    if days <= 0 then
        return _("today")
    elseif days < 30 then
        return T(_("%1d ago"), days)
    end
    return os.date("%Y-%m-%d", ts)
end

--- One artifact row's destination — the same surface the View Artifacts popup
--- opens for that row (main.lua viewCache and dialogs' openArtifact carry this
--- same chain; the group-flag contract lives on getAvailableArtifactsWithPinned).
--- The page stays open underneath: viewers and popups stack on top of it.
local function openArtifactRow(cache, ctx)
    local plugin, ui, file = ctx.plugin, ctx.ui, ctx.file
    local noop = function() end
    if cache.is_image_group then
        require("koassistant_image_browser").show({
            book_file = file, book_title = ctx.title })
    elseif cache.is_xray_versions_group then
        plugin:_showXrayCheckpointList({ file = file,
            book_title = ctx.title, book_author = ctx.author })
    elseif cache.is_section_xray_group then
        require("koassistant_artifact_browser"):_showSectionXrayGroupPopup(
            cache.data, file, ctx.title, plugin, cache._excluded_section_key, noop)
    elseif cache.is_section_group then
        require("koassistant_artifact_browser"):_showSectionGroupPopup(
            cache.data, file, ctx.title, plugin, cache.section_type,
            cache._excluded_section_key, noop)
    elseif cache.is_wiki_group then
        require("koassistant_artifact_browser"):_showWikiGroupPopup(
            cache.data, file, plugin, ctx.title, noop)
    elseif cache.is_pinned_group then
        require("koassistant_artifact_browser"):_showPinnedGroupPopup(
            cache.data, file, ctx.title, noop)
    elseif cache.is_per_action then
        if ctx.is_open_book then
            plugin:viewCachedAction({ text = cache.name }, cache.key, cache.data)
        else
            plugin:viewCachedAction({ text = cache.name }, cache.key, cache.data,
                { file = file, book_title = ctx.title, book_author = ctx.author })
        end
    else
        plugin:showCacheViewer(cache)
    end
end

--- Show the book page.
--- @param opts table {
---   file = book path (required),
---   plugin = AskGPT instance (required),
---   ui = ReaderUI/FileManager instance or nil,
---   title/author = display strings (resolved from doc_props/filename if absent),
---   enable_emoji = boolean }
function BookPage.show(opts)
    local file = opts and opts.file
    local plugin = opts and opts.plugin
    if not (file and plugin) then return end
    if BookPage._menu then
        UIManager:close(BookPage._menu)
        BookPage._menu = nil
    end

    local ui = opts.ui
    local is_open_book = ui and ui.document and ui.document.file == file or false
    local title = opts.title
    local author = opts.author
    if (not title or title == "") and is_open_book and ui.doc_props then
        title = ui.doc_props.display_title or ui.doc_props.title
        author = author or ui.doc_props.authors
    end
    if not title or title == "" then
        title = file:match("([^/]+)$") or file
    end
    local ctx = { plugin = plugin, ui = ui, file = file,
        title = title, author = author, is_open_book = is_open_book }

    local items = {}

    -- Artifacts (same rows as the View Artifacts popup, aggregation contract:
    -- pinned/images/versions/section/wiki group flags all dispatch)
    local ActionCache = require("koassistant_action_cache")
    local caches = ActionCache.getAvailableArtifactsWithPinned(
        file, nil, is_open_book and ui.document or nil)
    for _idx, cache in ipairs(caches) do
        -- File-browser convention: closed-book viewers need identity stamped
        -- on the row (showCacheViewer prefers explicit over doc_props)
        if not is_open_book and not cache.is_pinned_group then
            cache.book_title = cache.book_title or title
            cache.book_author = cache.book_author or author
            cache.file = cache.file or file
        end
        local mandatory
        if cache.data and not cache.is_pinned_group and not cache.is_section_group
            and not cache.is_wiki_group then
            local parts = {}
            if cache.data.progress_decimal and cache.data.progress_decimal < 1.0 then
                parts[#parts + 1] = math.floor(cache.data.progress_decimal * 100 + 0.5) .. "%"
            end
            local age = relativeDate(cache.data.timestamp)
            if age then parts[#parts + 1] = age end
            if #parts > 0 then mandatory = table.concat(parts, " · ") end
        end
        items[#items + 1] = {
            text = cache.name,
            mandatory = mandatory,
            callback = function() openArtifactRow(cache, ctx) end,
        }
    end

    -- Chats about this book (count from the chat index — no chat loads)
    local chat_index = G_reader_settings:readSetting("koassistant_chat_index", {})
    local chat_count = type(chat_index[file]) == "table"
        and tonumber(chat_index[file].count) or 0
    items[#items + 1] = {
        text = _("Chats"),
        mandatory = tostring(chat_count),
        dim = chat_count == 0,
        callback = chat_count > 0 and function()
            plugin:showChatHistoryForFile(file)
        end or nil,
    }

    -- Notebook (tap = view, hold = edit; opener offers creation when absent)
    local Notebook = require("koassistant_notebook")
    local nb_stats = Notebook.getStats(file)
    items[#items + 1] = {
        text = _("Notebook"),
        mandatory = nb_stats and relativeDate(nb_stats.modified) or _("none"),
        callback = function() plugin:openNotebookForFile(file) end,
        hold_callback = function() plugin:openNotebookForFile(file, true) end,
    }

    -- Group membership (tap = members popup, hold = manage) / add to group
    local GroupsUI = require("koassistant_book_groups_ui")
    if plugin:_inBookGroup(file) then
        items[#items + 1] = {
            text = Constants.getEmojiText("🗂️",
                T(_("Group: %1"), GroupsUI.rowLabel(file)), opts.enable_emoji),
            callback = function() plugin:_showGroupMembersPopup(file, "artifacts") end,
            hold_callback = function()
                GroupsUI.showBookRow(file, { plugin = plugin, ui = ui })
            end,
        }
    else
        items[#items + 1] = {
            text = Constants.getEmojiText("🗂️", _("Add to group…"), opts.enable_emoji),
            callback = function()
                GroupsUI.showBookRow(file, { plugin = plugin, ui = ui })
            end,
        }
    end

    -- Book Settings ("(N customized)" mirrors the settings screen's own count)
    local BookSettings = require("koassistant_book_settings")
    local SafeDocSettings = require("koassistant_doc_settings")
    local ds = SafeDocSettings.resolve(file, ui)
    local customized = ds and BookSettings.countCustomized(ds) or 0
    items[#items + 1] = {
        text = _("Book Settings"),
        mandatory = customized > 0 and T(_("%1 customized"), customized) or nil,
        callback = function()
            BookSettings.show({ plugin = plugin, ui = ui, document_path = file })
        end,
    }

    BookPage._menu = Menu:new{
        title = title,
        subtitle = author and author ~= "" and author or nil,
        item_table = items,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        single_line = true,
        items_font_size = 18,
        items_mandatory_font_size = 14,
        -- NOTE: no close_callback — Menu fires it after EVERY item tap (same
        -- trap the X-Ray browser documents); cleanup via onCloseWidget below
        onMenuSelect = function(_menu, item)
            if item and item.callback then item.callback() end
            return true
        end,
        onMenuHold = function(_menu, item)
            if item and item.hold_callback then item.hold_callback() end
            return true
        end,
    }
    local orig_onCloseWidget = BookPage._menu.onCloseWidget
    BookPage._menu.onCloseWidget = function(menu_self)
        BookPage._menu = nil
        if orig_onCloseWidget then return orig_onCloseWidget(menu_self) end
    end
    UIManager:show(BookPage._menu)
end

return BookPage
