--[[--
Book page ("Book overview", book page round 2026-08-09): one full-screen view
of everything the plugin holds for ONE book — the artifact rows the View
Artifacts popup shows (same destinations), plus chats, notebook, group
membership and book settings. Strictly a VIEW over existing stores: nothing is
generated here, nothing is stored here, and the popups stay the fast path.

Entry points (EVERY View-Artifacts surface carries a "Book overview…" row):
the open-book View Artifacts popup, the file-browser long-press popup, the
input dialog's View Artifacts popup, the artifact browser's per-book selector,
the response viewer's Artifacts popup — plus the X-Ray browser's bottom-left
up-arrow at root (live X-Ray views sit one level below this page).

Stacking rule: the page is a singleton and one level of ONE navigation cycle.
Rows that open the full-screen X-Ray browser CLOSE the page (the browser's
up-arrow at root returns here freshly built; X there closes everything).
Overlay surfaces (viewers, popups, settings) stack on top; when they close,
the page repaints and lazily REBUILDS its rows if anything was opened since
the last build (paintTo hook + stale flag), so counts and ages stay honest.
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

function BookPage.close()
    if BookPage._menu then
        local menu = BookPage._menu
        BookPage._menu = nil
        UIManager:close(menu)
    end
end

-- Row emoji for artifact rows (2026-08-09 maintainer: specific where an
-- artifact has an obvious icon, the 📦 artifact box as the fallback).
-- Keys: doc-cache keys + per-action ids from getAvailableArtifactsWithPinned.
local ARTIFACT_EMOJI = {
    ["_xray_cache"] = "🩻",
    ["_analyze_cache"] = "🔬",
    ["_summary_cache"] = "📄",
    xray = "🩻",
    xray_simple = "🩻",
    recap = "⏪",
    book_info = "ℹ️",
    analyze_highlights = "📝",
    generate_quiz = "❓",
}

local function artifactEmoji(cache)
    if cache.is_pinned_group then return "📌" end
    if cache.is_image_group then return "🖼️" end
    if cache.is_xray_versions_group then return "🕘" end
    if cache.is_wiki_group then return "📖" end
    if cache.is_section_xray_group then return "🩻" end
    return ARTIFACT_EMOJI[cache.key] or "📦"
end

--- True when this row opens the full-screen X-Ray browser (showCacheViewer's
--- own routing condition) — the one destination the page must NOT sit behind
local function opensXrayBrowser(cache)
    local ActionCache = require("koassistant_action_cache")
    local is_xray_key = cache.key == ActionCache.XRAY_CACHE_KEY
        or (type(cache.key) == "string"
            and cache.key:sub(1, #ActionCache.SECTION_XRAY_PREFIX) == ActionCache.SECTION_XRAY_PREFIX)
    return is_xray_key and cache.data and cache.data.result
        and require("koassistant_xray_parser").isJSON(cache.data.result)
end

--- One artifact row's destination — the same surface the View Artifacts popup
--- opens for that row (main.lua viewCache and dialogs' openArtifact carry this
--- same chain; the group-flag contract lives on getAvailableArtifactsWithPinned).
local function openArtifactRow(cache, ctx)
    local plugin, file = ctx.plugin, ctx.file
    local noop = function() end
    if cache.is_image_group then
        require("koassistant_image_browser").show({
            book_file = file, book_title = ctx.title })
    elseif cache.is_xray_versions_group then
        plugin:_showXrayCheckpointList({ file = file,
            book_title = ctx.title, book_author = ctx.author })
    elseif cache.is_section_xray_group then
        -- Picking a section opens its full-screen browser — same stacking rule
        -- as the main X-Ray row, so the pick closes the page
        require("koassistant_artifact_browser"):_showSectionXrayGroupPopup(
            cache.data, file, ctx.title, plugin, cache._excluded_section_key,
            BookPage.close)
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
        if opensXrayBrowser(cache) then BookPage.close() end
        plugin:showCacheViewer(cache)
    end
end

--- The page's rows, built fresh from disk truth on every call
local function buildItems(ctx)
    local plugin, ui, file = ctx.plugin, ctx.ui, ctx.file
    local items = {}

    -- Artifacts (same rows as the View Artifacts popup, aggregation contract:
    -- pinned/images/versions/section/wiki group flags all dispatch)
    local ActionCache = require("koassistant_action_cache")
    local caches = ActionCache.getAvailableArtifactsWithPinned(
        file, nil, ctx.is_open_book and ui.document or nil)
    for _idx, cache in ipairs(caches) do
        -- File-browser convention: closed-book viewers need identity stamped
        -- on the row (showCacheViewer prefers explicit over doc_props)
        if not ctx.is_open_book and not cache.is_pinned_group then
            cache.book_title = cache.book_title or ctx.title
            cache.book_author = cache.book_author or ctx.author
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
            text = Constants.getEmojiText(artifactEmoji(cache), cache.name, ctx.enable_emoji),
            mandatory = mandatory,
            callback = function() openArtifactRow(cache, ctx) end,
        }
    end

    -- Book Chat/Action (established terminology + 💬, the QA panel's pair) —
    -- the book-context input dialog with its actions; same launcher the
    -- file-browser long-press uses, handles both modes
    items[#items + 1] = {
        text = Constants.getEmojiText("💬", _("Book Chat/Action"), ctx.enable_emoji),
        callback = function()
            plugin:showKOAssistantDialogForFile(file, ctx.title, ctx.author)
        end,
    }

    -- Chat History (count from the chat index — no chat loads).
    -- close_on_up: the page is the level above that chat list — its up-arrow
    -- closes the list back onto the page instead of the all-documents list
    local chat_index = G_reader_settings:readSetting("koassistant_chat_index", {})
    local chat_count = type(chat_index[file]) == "table"
        and tonumber(chat_index[file].count) or 0
    items[#items + 1] = {
        text = Constants.getEmojiText("📜", _("Chat History"), ctx.enable_emoji),
        mandatory = tostring(chat_count),
        dim = chat_count == 0,
        callback = chat_count > 0 and function()
            plugin:showChatHistoryForFile(file, { close_on_up = true })
        end or nil,
    }

    -- Notebook (tap = view, hold = edit; opener offers creation when absent)
    local Notebook = require("koassistant_notebook")
    local nb_stats = Notebook.getStats(file)
    items[#items + 1] = {
        text = Constants.getEmojiText("📓", _("Notebook"), ctx.enable_emoji),
        mandatory = nb_stats and relativeDate(nb_stats.modified) or _("none"),
        callback = function() plugin:openNotebookForFile(file) end,
        hold_callback = function() plugin:openNotebookForFile(file, true) end,
    }

    -- Group membership (tap = members popup, hold = manage) / add to group
    local GroupsUI = require("koassistant_book_groups_ui")
    if plugin:_inBookGroup(file) then
        items[#items + 1] = {
            text = Constants.getEmojiText("🗂️",
                T(_("Group: %1"), GroupsUI.rowLabel(file)), ctx.enable_emoji),
            callback = function() plugin:_showGroupMembersPopup(file, "artifacts") end,
            hold_callback = function()
                GroupsUI.showBookRow(file, { plugin = plugin, ui = ui })
            end,
        }
    else
        items[#items + 1] = {
            text = Constants.getEmojiText("🗂️", _("Add to group…"), ctx.enable_emoji),
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
        text = Constants.getEmojiText("📕", _("Book Settings"), ctx.enable_emoji),
        mandatory = customized > 0 and T(_("%1 customized"), customized) or nil,
        callback = function()
            BookSettings.show({ plugin = plugin, ui = ui, document_path = file })
        end,
    }

    return items
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
    BookPage.close()

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
        title = title, author = author, is_open_book = is_open_book,
        enable_emoji = opts.enable_emoji }
    BookPage._ctx = ctx
    BookPage._stale = nil

    BookPage._menu = Menu:new{
        title = title,
        subtitle = author and author ~= "" and author or nil,
        item_table = buildItems(ctx),
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
            if item and item.callback then
                -- Whatever this opens may change data — rebuild rows on the
                -- repaint that reveals the page again
                BookPage._stale = true
                item.callback()
            end
            return true
        end,
        onMenuHold = function(_menu, item)
            if item and item.hold_callback then
                BookPage._stale = true
                item.hold_callback()
            end
            return true
        end,
    }
    local orig_onCloseWidget = BookPage._menu.onCloseWidget
    BookPage._menu.onCloseWidget = function(menu_self)
        if BookPage._menu == menu_self then BookPage._menu = nil end
        if orig_onCloseWidget then return orig_onCloseWidget(menu_self) end
    end
    -- Lazy in-place refresh: the first repaint after a row opened something
    -- rebuilds the rows from disk truth (flag cleared BEFORE the switch, so
    -- the extra repaint switchItemTable schedules terminates immediately)
    local orig_paintTo = BookPage._menu.paintTo
    BookPage._menu.paintTo = function(menu_self, ...)
        if BookPage._stale and BookPage._menu == menu_self then
            BookPage._stale = nil
            menu_self:switchItemTable(ctx.title, buildItems(ctx))
        end
        return orig_paintTo(menu_self, ...)
    end
    UIManager:show(BookPage._menu)
end

return BookPage
