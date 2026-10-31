-- The X-Ray lookup on the real widgets (ref #63). Mock Series 3 also has a
-- section X-Ray ("Chapter 2"), so "Look up in X-Ray" on "Tamsin", which is no
-- one's name, lands on the list across X-Rays. That list offers "Add
-- "Tamsin" as an alias…" first, as the browser's own results list does; the
-- alias goes to Tamsin Vael, her entry opens, and a long-press on "Tamsin"
-- now opens her card (an exact name). The page behind shows the new name
-- underlined as soon as the entry closes, with no page turn.
local S = dofile(os.getenv("KOA_PLUGIN") .. "/tests/scenarios/boot.lua")
S.features({ xray_marking_density = "all" }) -- every occurrence marked

local ui = S.open("Mock Series 3")
local file = ui.document.file
local Dialogs = require("koassistant.ui.dialogs")
local Actions = require("koassistant.prompts.actions")
local ActionCache = require("koassistant.artifacts.action_cache")
local XrayBrowser = require("koassistant.xray.xray_browser")

-- The run folder's books are shared with the scenarios after this one: the
-- names added here are taken back at the end
local aliases_before = ActionCache.getUserAliases(file)

local function lookup(text)
    Dialogs.executeDirectAction(ui, Actions.highlight.xray_lookup, text, S.plugin.configuration, S.plugin)
    S.settle()
end

local function topTitle()
    local w = S.top()
    return w and (w.title_bar and w.title_bar.title or w.title) or ""
end

-- What the page shows now, without asking the marks to redraw
local XrayMarks = require("koassistant.xray.xray_marks")
local function tamsinMarked()
    S.settle()
    for _idx, m in ipairs(XrayMarks._pageMarks() or {}) do
        if m.name == "Tamsin Vael" and m.text == "Tamsin" then return true end
    end
    return false
end

-- ── "Tamsin": the list across X-Rays ──
S.chapter("What the Salt Takes")
S.marks()
S.check(not tamsinMarked(), "the bare \"Tamsin\" on this page is not underlined yet")
S.check(not ActionCache.matchAnyXrayExact(file, "Tamsin"), "\"Tamsin\" is no one's name yet")
lookup("Tamsin")
local rows = S.texts()
S.note("rows:", table.concat(rows, " | "))
S.check(topTitle():find("across", 1, true) ~= nil, "the lookup lands on the list across X-Rays")
S.check(rows[1] == "Add \"Tamsin\" as an alias…", "the list offers the alias first")
S.shot("across")

-- ── The picker suggests Tamsin Vael ──
S.tap("Add \"Tamsin\" as an alias…")
S.note("picker:", table.concat(S.texts(), " | "))
S.shot("picker")
S.tap({ "^Tamsin Vael" })
S.settle()
local rec = ActionCache.getUserAliases(file)["Tamsin Vael"]
local added = false
for _idx, a in ipairs(rec and rec.add or {}) do
    if a == "Tamsin" then added = true end
end
S.check(added, "\"Tamsin\" is recorded as a name of Tamsin Vael")
S.note("on top:", topTitle())
S.check(S.top() == XrayBrowser._detail_viewer and topTitle():find("Tamsin Vael", 1, true) ~= nil,
    "her entry opens")
S.shot("entry")
S.closeAll()
S.check(tamsinMarked(), "the page behind underlines \"Tamsin\" now, with no page turn")

-- ── A long-press on "Tamsin" now opens her card ──
S.check(ActionCache.matchAnyXrayExact(file, "Tamsin"), "\"Tamsin\" is now an exact name, so a long-press opens her card")

-- ── With the underlines off, an edit leaves the name index's pass alone ──
-- (taking the marks down stops it, as it should; an edit after must not
-- stop what Mentions or Chapter Appearances queued since)
S.plugin.settings:readSetting("features").xray_marking = false
S.plugin:syncXrayMarks()
S.settle()
local XrayIndex = require("koassistant.xray.xray_index")
local real_stop, stops = XrayIndex.stop, 0
XrayIndex.stop = function(...)
    stops = stops + 1
    return real_stop(...)
end
local aliases = ActionCache.getUserAliases(file)
aliases["Gil Rook"] = aliases["Gil Rook"] or { add = {} }
table.insert(aliases["Gil Rook"].add, "the grafter")
ActionCache.setUserAliases(file, aliases)
S.settle()
XrayIndex.stop = real_stop
S.check(stops == 0, "with the underlines off, an X-Ray edit stops nothing")

ActionCache.setUserAliases(file, aliases_before)
S.finish()
