-- Wiki shots for the Contexts and Chat page (docs/assets/wiki_shotlist.txt)
local S = dofile(os.getenv("KOA_PLUGIN") .. "/tests/scenarios/boot.lua")
local W = dofile(S.PLUGIN .. "/tests/scenarios/wiki_lib.lua")(S)
S.features({ provider = "anthropic", api_keys = { anthropic = W.FAKE.anthropic } })

local book = S.shotsBook("series", 1) or "Mock Series 3"
S.open(book)
W.prose(10)
if S.SHOTS then W.group(S.SHOTS.series_name or "Series", "series", W.seriesBooks()) end

-- The highlight menu, at its defaults
W.select(0, 16)
W.highlightMenu()
S.wiki("highlightmenu.png")
S.closeAll()

-- A book chat's input dialog
S.plugin:onKOAssistantBookChat()
S.settle()
S.note("book chat:", table.concat(S.texts(), " | "))
S.wiki("input_dialog_chips.png")

-- Its Scope chip
S.tap("Scope")
S.note("scope:", table.concat(S.texts(), " | "))
S.wiki("scope_chip_popup.png")
S.closeAll()

-- Explain in Context's scope and source popup, from a selection's dialog
W.select(0, 16)
W.highlightMenu()
S.tap("Chat/Action (KOA)")
S.tap("Explain in Context")
S.note("source popup:", table.concat(S.texts(), " | "))
S.wiki("source_selection_popup.png")
S.closeAll()

-- The library dialog with two books picked (launched from a group of two)
local two = { S.shotsBook("standalone"), S.shotsBook("nonfiction") }
if two[1] and two[2] then
    local g = W.group("Reading Pair", "plain", two)
    S.plugin:openLibraryDialogForGroup(g.id)
else
    S.plugin:openLibraryDialog()
end
S.settle()
S.note("library:", table.concat(S.texts(), " | "))
S.wiki("library_dialog.png")
S.closeAll()

S.finish()
