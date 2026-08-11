--[[--
Book page ("Book Hub" — renamed from "Book Overview" with A4's shape work
2026-08-11; internal ids/settings keys keep book_overview): one full-screen
view of everything the plugin holds for ONE book — the TOP-LEVEL artifact rows
the View Artifacts popup shows (same destinations; the versions group and
section-scoped groups are filtered off the page — they stay reachable from the
X-Ray browser, the action popups and the View-Artifacts popups), plus chats,
notebook, group membership and book settings. Strictly a VIEW over existing
stores: nothing is generated here, nothing is stored here, and the popups stay
the fast path.
Book-level operations (refresh index / export all / delete all / browse all
books) live behind the title-bar hamburger, the X-Ray browser's idiom.

Entry points (EVERY View-Artifacts surface carries a "Book Hub…" row):
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

--- The page's user-facing name, in ONE place (renamed "Book Overview" →
--- "Book Hub", A4 2026-08-11) — entry points must call these rather than
--- hardcode. One string can't reach here (would cycle the require graph) and
--- is renamed alongside: Constants.getQuickActionUtilityText's
--- book_overview entry, and nothing else.
function BookPage.pageName()
    return _("Book Hub")
end

--- Entry-row form used by the View-Artifacts popups
function BookPage.entryLabel()
    return _("Book Hub…")
end

function BookPage.close()
    if BookPage._menu then
        local menu = BookPage._menu
        BookPage._menu = nil
        UIManager:close(menu)
    end
end

-- Row emoji for artifact rows (2026-08-11 maintainer: the 📦 artifact box for
-- ALL artifacts for now — the per-type map is parked until icons are
-- reconsidered; pinned and images keep their system-wide identities).
local function artifactEmoji(cache)
    if cache.is_pinned_group then return "📌" end
    if cache.is_image_group then return "🖼️" end
    return "📦"
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
--- The versions/section branches are currently unreachable (buildItems filters
--- those groups off the page) but stay: the planned row-visibility settings
--- re-open them, and the dispatch must keep covering the full contract.
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
        -- Maintainer 2026-08-11: the page lists TOP-LEVEL artifacts only.
        -- The X-Ray versions group lives in the X-Ray browser, section-scoped
        -- groups (section X-Rays, section quizzes/summaries/analyses) in their
        -- action popups and the artifact browser — the View-Artifacts popups
        -- still list all of them, so nothing orphans. The planned hamburger
        -- row-visibility settings are where this pruning gets revisited.
        if not (cache.is_xray_versions_group or cache.is_section_xray_group
                or cache.is_section_group) then
            -- File-browser convention: closed-book viewers need identity stamped
            -- on the row (showCacheViewer prefers explicit over doc_props)
            if not ctx.is_open_book and not cache.is_pinned_group then
                cache.book_title = cache.book_title or ctx.title
                cache.book_author = cache.book_author or ctx.author
                cache.file = cache.file or file
            end
            local mandatory
            if not cache.is_pinned_group and not cache.is_wiki_group then
                -- ONE formatter with the View-Artifacts popups and the artifact
                -- browser (A4 parity): percent always when tracked + compact age
                mandatory = Constants.formatArtifactMeta(cache.data)
            end
            -- Quiz opens its ACTION popup when the book is open (View/Update/New
            -- Quiz — the quiz viewer has no redo controls, unlike the artifact
            -- viewers); a closed book can't quiz, so it falls through to viewing.
            -- The action id AND cache key are "quiz" (prompts/actions.lua:1637)
            local row_callback
            if cache.key == "quiz" and ctx.is_open_book then
                row_callback = function() plugin:executeBookLevelAction("quiz") end
            else
                row_callback = function() openArtifactRow(cache, ctx) end
            end
            items[#items + 1] = {
                text = Constants.getEmojiText(artifactEmoji(cache), cache.name, ctx.enable_emoji),
                mandatory = mandatory,
                callback = row_callback,
            }
        end
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
    local nb_rel = nb_stats and Constants.formatRelativeTime(nb_stats.modified) or ""
    items[#items + 1] = {
        text = Constants.getEmojiText("📓", _("Notebook"), ctx.enable_emoji),
        mandatory = nb_rel ~= "" and nb_rel or _("none"),
        callback = function() plugin:openNotebookForFile(file) end,
        hold_callback = function() plugin:openNotebookForFile(file, true) end,
    }

    -- Search in book (KOReader's own fulltext search) — open book only, and
    -- the page closes first: search navigates the BOOK, which must not sit
    -- hidden under a full-screen menu
    if ctx.is_open_book and ui.search then
        items[#items + 1] = {
            text = Constants.getEmojiText("🔍", _("Search in book"), ctx.enable_emoji),
            callback = function()
                BookPage.close()
                ui.search:onShowFulltextSearchInput()
            end,
        }
    end

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

    -- Open Book (closed-book views only) — the X-Ray browser's reopen
    -- pattern: a module-level pending marker survives the plugin
    -- re-instantiation ReaderUI causes, and onReaderReady (main.lua) re-shows
    -- the overview for the same book
    if not ctx.is_open_book then
        items[#items + 1] = {
            text = Constants.getEmojiText("📖", _("Open Book"), ctx.enable_emoji),
            callback = function()
                BookPage._pending_reopen = { book_file = file }
                BookPage.close()
                require("apps/reader/readerui"):showReader(file)
            end,
        }
    end

    return items
end

--- Export every top-level artifact to files in a chosen folder (A4 hamburger).
--- Same per-artifact format/filenames as the viewer's Export button; sections,
--- wiki entries and pinned items are not included (each has its own surface).
local function exportAllArtifacts(ctx)
    local ActionCache = require("koassistant_action_cache")
    local Export = require("koassistant_export")
    local InfoMessage = require("ui/widget/infomessage")
    local caches = ActionCache.getAvailableArtifactsWithPinned(ctx.file)
    local exportable = {}
    for _idx, cache in ipairs(caches) do
        if cache.data and type(cache.data.result) == "string" then
            exportable[#exportable + 1] = cache
        end
    end
    if #exportable == 0 then
        UIManager:show(InfoMessage:new{ text = _("Nothing to export.") })
        return
    end
    -- Default folder: same resolution as the viewer's export
    local DataStorage = require("datastorage")
    local features = ctx.plugin.settings and ctx.plugin.settings.data
        and ctx.plugin.settings.data.features or {}
    local dir_option = features.export_save_directory or "exports_folder"
    local default_path
    if dir_option == "custom" and features.export_custom_path and features.export_custom_path ~= "" then
        default_path = features.export_custom_path
    elseif dir_option == "exports_folder" or dir_option == "ask" then
        default_path = DataStorage:getDataDir() .. "/koassistant_exports"
    else
        default_path = DataStorage:getDataDir()
    end
    local PathChooser = require("ui/widget/pathchooser")
    UIManager:show(PathChooser:new{
        title = _("Select export folder"),
        path = default_path,
        show_hidden = false,
        select_directory = true,
        select_file = false,
        onConfirm = function(selected_path)
            local n = 0
            for _idx, cache in ipairs(exportable) do
                local filename = Export.getCacheFilename(
                    ctx.title, cache.name, cache.data.timestamp)
                local formatted = Export.formatCacheContent(cache.data.result, {
                    cache_type = cache.name,
                    book_title = ctx.title,
                    book_author = ctx.author,
                    progress_decimal = cache.data.progress_decimal,
                    model = cache.data.model,
                    timestamp = cache.data.timestamp,
                }, "markdown")
                local ok = Export.saveToFile(formatted, selected_path .. "/" .. filename)
                if ok then n = n + 1 end
            end
            UIManager:show(InfoMessage:new{
                text = T(_("Exported %1 of %2 artifacts."), n, #exportable),
            })
        end,
    })
end

--- Delete-all confirm (A4 hamburger). ActionCache.clearAll takes the X-Ray's
--- checkpoint ring and version ladder with it by construction; chats,
--- notebook, pinned items and generated images live in other stores.
local function confirmDeleteAll(ctx)
    local ConfirmBox = require("ui/widget/confirmbox")
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(ConfirmBox:new{
        text = T(_("Delete ALL artifacts for \"%1\"?\n\nThis removes the X-Ray (with its archived versions and checkpoints), summaries, analyses, wiki entries and every other cached artifact. Chats, notebook, pinned items and generated images are kept.\n\nThis cannot be undone."), ctx.title),
        ok_text = _("Delete"),
        ok_callback = function()
            require("koassistant_action_cache").clearAll(ctx.file)
            BookPage._stale = true
            UIManager:show(InfoMessage:new{ text = _("Artifacts deleted."), timeout = 2 })
        end,
    })
end

--- Title-bar hamburger (A4): book-level operations — the X-Ray browser's
--- title_bar_left_icon idiom; the page was the only full-screen KOA surface
--- without one
local function showHamburger(ctx)
    local ButtonDialog = require("ui/widget/buttondialog")
    local InfoMessage = require("ui/widget/infomessage")
    local dialog
    dialog = ButtonDialog:new{
        title = ctx.title,
        buttons = {
            {{
                text = _("Refresh index"),
                callback = function()
                    UIManager:close(dialog)
                    -- The heal-on-open trio (main.lua) — artifacts, notebook,
                    -- pinned — then rebuild rows on the reveal repaint
                    require("koassistant_action_cache").refreshIndex(ctx.file)
                    require("koassistant_notebook").refreshIndexEntry(ctx.file)
                    require("koassistant_pinned_manager").refreshIndex(ctx.file)
                    BookPage._stale = true
                    UIManager:show(InfoMessage:new{ text = _("Index refreshed."), timeout = 2 })
                end,
            }},
            {{
                text = _("Export all artifacts…"),
                callback = function()
                    UIManager:close(dialog)
                    exportAllArtifacts(ctx)
                end,
            }},
            {{
                text = _("Browse all books…"),
                callback = function()
                    UIManager:close(dialog)
                    -- Overlay, not replacement: closing the browser reveals
                    -- the page again (stale rebuild keeps counts honest)
                    BookPage._stale = true
                    ctx.plugin:showArtifactBrowser()
                end,
            }},
            {{
                text = _("Delete all artifacts…"),
                callback = function()
                    UIManager:close(dialog)
                    confirmDeleteAll(ctx)
                end,
            }},
        },
    }
    UIManager:show(dialog)
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

    -- Popup-path parity (A4): every popup entry heals the artifact index on
    -- open; artifacts discovered through this read-only view now do too
    require("koassistant_action_cache").refreshIndex(file)

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
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = function() showHamburger(ctx) end,
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
