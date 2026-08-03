--[[
Core Constants for KOAssistant Plugin

Centralized definitions for values used across multiple modules.
Prevents drift when adding features or changing configuration.

Pattern follows: koassistant_ui/constants.lua (UI sizing constants)

Usage:
    local Constants = require("koassistant_constants")
    for _idx, ctx in ipairs(Constants.getAllContexts()) do
        -- Process each context
    end
]]

local _ = require("koassistant_gettext")

local Constants = {}

-- Internal sentinel: queryChatGPT's stream on_complete returns this as `err` when the ⚡
-- quick-answer retry button was tapped, so BookToolRunner.queryWith intercepts it and
-- re-runs the send with quick posture instead of treating it as a failure (input safety
-- net S3). Never user-visible.
Constants.QUICK_RETRY_SENTINEL = "__koassistant_quick_retry__"

-- Context types (used in actions, message building, dialogs)
-- These are the four standard contexts for AI interactions
Constants.CONTEXTS = {
    HIGHLIGHT = "highlight",      -- Selected text context
    BOOK = "book",                -- Single book metadata
    LIBRARY = "library",          -- Multiple books
    GENERAL = "general",          -- Standalone questions
}

-- Compound contexts (shorthand for multiple contexts)
-- These are convenience values that expand to multiple standard contexts
Constants.COMPOUND_CONTEXTS = {
    BOTH = "both",                            -- highlight + book
    HIGHLIGHT_GENERAL = "highlight+general",  -- highlight + general
    BOOK_GENERAL = "book+general",            -- book + general
    BOTH_GENERAL = "both+general",            -- highlight + book + general
}

--- Get ordered list of all standard contexts
--- Returns contexts in display order (not alphabetical)
--- @return table: Array of context names ["highlight", "book", "library", "general"]
function Constants.getAllContexts()
    return {
        Constants.CONTEXTS.HIGHLIGHT,
        Constants.CONTEXTS.BOOK,
        Constants.CONTEXTS.LIBRARY,
        Constants.CONTEXTS.GENERAL,
    }
end

--- Expand compound context to individual contexts
--- Handles special compound values like "both", "book+general", etc.
--- @param context string: Context name (can be compound or standard)
--- @return table: Array of individual context names
function Constants.expandContext(context)
    if context == "both" then
        return { "highlight", "book" }
    elseif context == "highlight+general" then
        return { "highlight", "general" }
    elseif context == "book+general" then
        return { "book", "general" }
    elseif context == "both+general" then
        return { "highlight", "book", "general" }
    else
        -- Return as single-item array for standard contexts
        return { context }
    end
end

--- Check if a context name is valid
--- Validates against both standard and compound contexts
--- @param context string: Context name to validate
--- @return boolean: true if valid context (standard or compound)
function Constants.isValidContext(context)
    -- Check standard contexts
    for _idx, ctx in ipairs(Constants.getAllContexts()) do
        if context == ctx then return true end
    end

    -- Check compound contexts
    for _idx, compound in pairs(Constants.COMPOUND_CONTEXTS) do
        if context == compound then return true end
    end

    return false
end

-- GitHub repository URLs
-- Used for update checking and HTTP headers (OpenRouter)
-- Single source of truth for repository location
Constants.GITHUB = {
    REPO_OWNER = "zeeyado",
    REPO_NAME = "koassistant.koplugin",
    URL = "https://github.com/zeeyado/koassistant.koplugin",
    -- per_page=5: the checker only needs the newest releases; the default (30, with
    -- full markdown bodies) is hundreds of KB json.decode'd on the UI thread
    API_URL = "https://api.github.com/repos/zeeyado/koassistant.koplugin/releases?per_page=5",
}

-- Text extraction defaults (single source of truth)
-- Referenced by: context_extractor (fallback), settings_schema (UI default)
-- Callers should NOT hardcode their own fallbacks — pass nil to let extractor use these
Constants.EXTRACTION_DEFAULTS = {
    MAX_BOOK_TEXT_CHARS = 4000000,
    MAX_PDF_PAGES = 2000,
}

-- Threshold for "large extraction" warning (in characters)
-- ~125K tokens — at this point most models except Gemini are near their context limit
Constants.LARGE_EXTRACTION_THRESHOLD = 500000

-- Quick Actions Panel Utilities
-- Non-action items shown in the Quick Actions panel (below the actions)
-- Each utility has: id (settings key suffix), callback (method name), default (enabled by default)
-- Display text is handled by consumers using gettext
-- Settings path: features.qa_show_{id}
Constants.QUICK_ACTION_UTILITIES = {
    { id = "translate_page",     callback = "onKOAssistantTranslatePage",       default = true },
    { id = "new_book_chat",      callback = "onKOAssistantBookChat",            default = true },
    { id = "continue_last_chat", callback = "onKOAssistantContinueLastOpened",  default = true },
    { id = "general_chat",       callback = "startGeneralChat",                 default = true },
    { id = "chat_history",       callback = "onKOAssistantChatHistory",         default = true },
    { id = "notebook",           callback = "onKOAssistantNotebook",            default = true },
    { id = "view_caches",        callback = "viewCache",                        default = true },  -- "View Artifacts": single button, opens cache picker
    { id = "book_settings",      callback = "onKOAssistantBookSettings",        default = true },  -- per-book settings (domain, research, AI title/author)
    { id = "ai_quick_settings",  callback = "onKOAssistantAISettings",          default = true },
}

--- Get display text for a Quick Action utility
--- Must be called from a context where _ (gettext) is available
--- @param id string: Utility ID
--- @param _ function: gettext function
--- @return string: Translated display text
function Constants.getQuickActionUtilityText(id, _)
    local texts = {
        translate_page = _("Translate Page"),
        new_book_chat = _("Book Chat/Action"),
        continue_last_chat = _("Continue Last Chat"),
        general_chat = _("General Chat/Action"),
        chat_history = _("Chat History"),
        notebook = _("Notebook"),
        view_caches = _("View Artifacts"),
        ai_quick_settings = _("Quick Settings"),
        book_settings = _("Book Settings"),
    }
    return texts[id]
end

-- Quick Settings Panel Default Order
-- Defines the default sequence of items in the Quick Settings panel
-- Used as fallback when no user-customized order is stored
-- Settings path: features.qs_show_{id} (visibility toggles)
Constants.QS_ITEMS_DEFAULT_ORDER = {
    "provider", "model", "behavior", "domain",
    "temperature", "extended_thinking", "web_search",
    "book_tools",
    "h_bypass", "d_bypass",
    "language", "translation_language", "dictionary_language",
    "text_extraction",
    "chat_history", "browse_notebooks", "browse_artifacts",
    "library_actions",
    "general_chat", "continue_last_chat",
    "new_book_chat", "manage_actions", "quick_actions",
    "more_settings",
}

-- QS items that only appear when a book is open (dynamic)
Constants.QS_DYNAMIC_ITEMS = { new_book_chat = true, quick_actions = true }

-- Session chips shown above the input field, in CANONICAL render order (order is fixed;
-- only membership is user-configurable, via the input dialog's gear menu → "Toolbar
-- buttons"). Membership persists in features.session_chips, removals in
-- features._dismissed_session_chips.
--
-- ADDING A CHIP: append the id here and it reaches existing users automatically —
-- resolveSessionChips() injects any id they have never seen. Do NOT write a
-- `_session_chips_*` migration; that pattern is retired (defaults_propagation_plan.md G1,
-- which is exactly the bug this registry removes: three hand-written migrations were needed
-- for scope/attach/quick, and forgetting one silently hid the chip forever).
Constants.SESSION_CHIP_IDS = {
    "domain", "web_search", "book_tools", "quick", "scope", "attach", "spoiler",
}

--- Reconcile a saved session-chip membership list against the canonical registry.
--- PURE (no settings/UI access) so it is unit-testable and safe to call on every render.
---
--- Mirrors the auto-injection that action lists already get from action_service's
--- processActionList: unseen ids are added, deliberately removed ids stay removed, unknown
--- ids (a chip we deleted) are dropped, and the result is always in canonical order.
---
--- @param saved table|nil     features.session_chips (nil = never customized → full default)
--- @param dismissed table|nil features._dismissed_session_chips (ids the user turned off)
--- @return table ordered array of chip ids to render
function Constants.resolveSessionChips(saved, dismissed)
    -- Never customized: everything on.
    if type(saved) ~= "table" then
        local all = {}
        for _idx, id in ipairs(Constants.SESSION_CHIP_IDS) do all[#all + 1] = id end
        return all
    end

    local member = {}
    for _idx, id in ipairs(saved) do member[id] = true end
    local is_dismissed = {}
    for _idx, id in ipairs(dismissed or {}) do is_dismissed[id] = true end

    local result = {}
    for _idx, id in ipairs(Constants.SESSION_CHIP_IDS) do
        -- Saved membership wins; anything the user has never decided on is injected.
        if member[id] or not is_dismissed[id] then
            result[#result + 1] = id
        end
    end
    return result
end

-- Actions registered for the minimal popup view by default (Minimal Popup
-- settings). Actions are just actions — "minimal popup" is not an action type
-- but a registration: highlight actions on this list open their response in the
-- chrome-less anchored popup (koassistant_minimal_popup.lua) per the
-- minimal_popup_mode setting (off / "short" = when it fits / always);
-- everything else keeps its normal view.
Constants.DEFAULT_MINIMAL_POPUP_ACTIONS = {
    "translate", "quick_define",
}

--- Resolve the minimal-popup action registry into a lookup set. PURE.
--- nil saved list = never customized → defaults (read-through, so new default
--- registrations reach never-customized users automatically). A user-edited list
--- is taken verbatim — including empty (deliberate "none"); later default
--- additions won't resurrect for editors (discoverable in the picker, accepted).
--- @param saved table|nil features.minimal_popup_actions (array of action ids)
--- @return table set: { [action_id] = true }
function Constants.resolveMinimalPopupActions(saved)
    local list = type(saved) == "table" and saved or Constants.DEFAULT_MINIMAL_POPUP_ACTIONS
    local set = {}
    for _idx, id in ipairs(list) do set[id] = true end
    return set
end

--- Get display text for a Quick Settings item
--- @param id string: QS item ID
--- @param _ function: gettext function
--- @return string: Translated display text
function Constants.getQsItemText(id, _)
    local texts = {
        provider = _("Provider"),
        model = _("Model"),
        behavior = _("Behavior"),
        domain = _("Domain"),
        temperature = _("Temperature"),
        extended_thinking = _("Reasoning"),
        web_search = _("Web Search"),
        book_tools = _("Book Tools"),
        language = _("Language"),
        translation_language = _("Translation Language"),
        dictionary_language = _("Dictionary Language"),
        h_bypass = _("H.Bypass"),
        d_bypass = _("D.Bypass"),
        text_extraction = _("Text Extraction"),
        chat_history = _("Chat History"),
        browse_notebooks = _("Browse Notebooks"),
        browse_artifacts = _("Browse Artifacts"),
        library_actions = _("Library Chat/Action"),
        general_chat = _("General Chat/Action"),
        continue_last_chat = _("Continue Last Chat"),
        new_book_chat = _("Book Chat/Action"),
        manage_actions = _("Manage Actions"),
        quick_actions = _("Quick Actions"),
        more_settings = _("More Settings"),
    }
    return texts[id] or id
end

--- Get text with optional emoji prefix
--- Returns emoji version if enable_emoji_icons is true, otherwise text-only version
--- @param emoji string: The emoji to show when enabled (e.g., "🔍")
--- @param text string: The text to show (e.g., "Web ON")
--- @param enable_emoji boolean: Whether emoji icons are enabled
--- @return string: Either "🔍 Web ON" or "Web ON" depending on setting
function Constants.getEmojiText(emoji, text, enable_emoji)
    if enable_emoji then
        return emoji .. " " .. text
    end
    return text
end

--- Format a timestamp as relative time string (e.g., "3d ago", "1m2d ago")
--- @param timestamp number Unix timestamp
--- @return string Relative time string, or empty if invalid
function Constants.formatRelativeTime(timestamp)
    if not timestamp then return "" end
    local now = os.time()
    if now - timestamp < 0 then return "" end
    local today_t = os.date("*t", now)
    today_t.hour, today_t.min, today_t.sec = 0, 0, 0
    local cached_t = os.date("*t", timestamp)
    cached_t.hour, cached_t.min, cached_t.sec = 0, 0, 0
    local days = math.floor((os.time(today_t) - os.time(cached_t)) / 86400)
    if days == 0 then
        return _("today")
    elseif days < 30 then
        return string.format(_("%dd ago"), days)
    else
        local months = math.floor(days / 30)
        local years = math.floor(days / 365)
        if years == 0 then
            local rd = days - (months * 30)
            if rd > 0 then
                return string.format(_("%dm%dd ago"), months, rd)
            else
                return string.format(_("%dm ago"), months)
            end
        else
            local rm = months - (years * 12)
            if rm > 0 then
                return string.format(_("%dy%dm ago"), years, rm)
            else
                return string.format(_("%dy ago"), years)
            end
        end
    end
end

return Constants
