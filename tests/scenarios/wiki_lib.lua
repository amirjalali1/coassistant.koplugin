--[[
Staging helpers for the wiki shots (tests/scenarios/w_*.lua, run by
tests/scenarios/wiki_shots.sh). Everything staged lives in the run folder:
fake keys that never leave it (the network is blocked), groups and backups
in the run's home, selections made by stepping words from a page's start (no
book text is quoted in a tracked file).

    local S = dofile(os.getenv("KOA_PLUGIN") .. "/tests/scenarios/boot.lua")
    local W = dofile(S.PLUGIN .. "/tests/scenarios/wiki_lib.lua")(S)
]]

return function(S)
    local W = {}
    local UIManager = S.UIManager

    -- Fake keys, shaped like real ones, never sent anywhere
    W.FAKE = {
        anthropic = "sk-ant-api03-wikishot0000000000000000000000000000000000000000000000",
        openai = "sk-proj-wikishot00000000000000000000000000000000000000000000",
        gemini = "AIzaSyWikiShot000000000000000000000000",
        gemini_file = "AIzaSyWikiShotFile00000000000000000000",
        xai = "xai-wikishot000000000000000000000000000000000000000000000000000",
        openrouter = "sk-or-v1-wikishot0000000000000000000000000000000000000000000000000",
        deepseek = "sk-wikishot-fake-0000000000000000",
    }

    --- The plugin's settings, now (the live instance's store and the file)
    function W.features(values)
        local plugin = assert(S.plugin, "no plugin loaded")
        local f = plugin.settings:readSetting("features") or {}
        for k, v in pairs(values) do f[k] = v end
        plugin.settings:saveSetting("features", f)
        plugin.settings:flush()
        if plugin.updateConfigFromSettings then plugin:updateConfigFromSettings() end
        return f
    end

    --- A top-level setting of the plugin's settings file, before the plugin
    --- loads (an action list, the built-in action edits)
    function W.preSetting(key, value)
        local DataStorage = require("datastorage")
        local s = require("luasettings"):open(DataStorage:getSettingsDir() .. "/koassistant_settings.lua")
        s:saveSetting(key, value)
        s:flush()
    end

    --- Keys "in apikeys.lua" (the boot's stand-in table, filled in memory)
    function W.fileKeys(keys)
        local t = package.loaded["apikeys"]
        for k, v in pairs(keys) do t[k] = v end
    end

    --- Turn to a page of the open book
    function W.page(n)
        local ui = assert(S.ui, "no book open")
        ui:handleEvent(require("ui/event"):new("GotoPage", n))
        S.settle()
        UIManager:forceRePaint()
    end

    --- The first page from `from` on that is a full page of prose (a
    --- contents page or a title page is short of text), or `from`
    function W.prosePage(from, min_chars)
        local doc = assert(S.ui, "no book open").document
        local n = doc:getPageCount()
        for p = from or 1, math.min(n - 1, (from or 1) + 60) do
            local ok, text = pcall(doc.getTextFromXPointers, doc, doc:getPageXPointer(p), doc:getPageXPointer(p + 1))
            if ok and type(text) == "string" and #text >= (min_chars or 850)
                    and not text:find("CHAPTER [IVX]+%..-CHAPTER [IVX]+%.") then
                return p
            end
        end
        return from or 1
    end

    --- Turn to the first full page of prose from `from` on; returns its number
    function W.prose(from)
        local p = W.prosePage(from or 8)
        W.page(p)
        return p
    end

    --- Select `count` words on the page, after skipping `skip` words from its
    --- start, as a long-press and drag would; returns the selection
    function W.select(skip, count)
        local ui = assert(S.ui, "no book open")
        local doc = ui.document
        local xp = doc:getXPointer()
        local s = xp
        for _i = 1, skip or 0 do s = doc:getNextVisibleWordStart(s) or s end
        local e = s
        for _i = 1, count or 8 do e = doc:getNextVisibleWordEnd(e) or e end
        local boxes = doc:getScreenBoxesFromPositions(s, e, true)
        assert(boxes and #boxes > 0, "no word boxes to select")
        local b0, b1 = boxes[1], boxes[#boxes]
        local pos0 = { x = b0.x + 1, y = b0.y + math.floor(b0.h / 2), page = ui.view.state.page }
        local pos1 = { x = b1.x + b1.w - 1, y = b1.y + math.floor(b1.h / 2), page = ui.view.state.page }
        local hl = ui.highlight
        hl.hold_pos = pos0
        hl.holdpan_pos = pos1
        hl.selected_text = doc:getTextFromPositions(pos0, pos1)
        UIManager:setDirty(ui.dialog, "ui")
        S.settle()
        return hl.selected_text
    end

    --- The highlight menu on the current selection
    function W.highlightMenu()
        S.ui.highlight:onShowHighlightMenu()
        S.settle()
        UIManager:forceRePaint()
        return S.top()
    end

    --- A group through the plugin's own store: name, kind ("series",
    --- "project", "plain") and its books in order; returns the group
    function W.group(name, kind, books)
        local BookGroups = require("koassistant.books.book_groups")
        local g = BookGroups.create(name)
        if kind then BookGroups.setKind(g.id, kind) end
        for _idx, path in ipairs(books or {}) do BookGroups.addBook(g.id, path) end
        S.settle()
        return g
    end

    --- The three series books (or the mock series when there is no copy)
    function W.seriesBooks()
        local out = {}
        for i = 1, 3 do
            local p = S.shotsBook("series", i)
            if p then out[#out + 1] = p end
        end
        return out
    end

    --- Scroll the top window's scrolling body so the row with this text shows
    --- (a ButtonDialog taller than the screen)
    function W.scrollTo(text, w)
        w = w or S.top()
        local scroll = w and w.cropping_widget
        if not scroll then return false end
        for _idx, b in ipairs(S.buttons(w)) do
            if b.text == text or (type(text) == "table" and b.text:find(text[1])) then
                -- paint once so every button knows its place
                UIManager:forceRePaint()
                local dimen = b.button.dimen
                local top = scroll.dimen and scroll.dimen.y or 0
                if dimen and dimen.y then
                    local current = scroll:getScrolledOffset()
                    local want = math.max(0, current.y + (dimen.y - top) - math.floor(scroll.dimen.h / 3))
                    scroll:setScrolledOffset({ x = 0, y = want })
                    UIManager:setDirty(w, "ui")
                    S.settle()
                    UIManager:forceRePaint()
                    return true
                end
            end
        end
        return false
    end

    --- Turn the list on top (a full-screen Menu) to the page holding the row
    --- that matches this Lua pattern; returns the page
    function W.listPageWith(pattern)
        local list = S.top()
        for i, it in ipairs(list and list.item_table or {}) do
            if type(it.text) == "string" and it.text:find(pattern) then
                local page = math.floor((i - 1) / list.perpage) + 1
                list:onGotoPage(page)
                S.settle()
                UIManager:forceRePaint()
                return page
            end
        end
    end

    --- The book's settings object, as the plugin reads it
    function W.bookDS(path)
        return require("koassistant.storage.doc_settings").resolve(path or S.ui.document.file, S.ui)
    end

    return W
end
