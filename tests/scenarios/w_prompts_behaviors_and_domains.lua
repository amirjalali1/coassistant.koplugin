-- Wiki shots for the Prompts, Behaviors and Domains page (docs/assets/wiki_shotlist.txt)
local S = dofile(os.getenv("KOA_PLUGIN") .. "/tests/scenarios/boot.lua")
local W = dofile(S.PLUGIN .. "/tests/scenarios/wiki_lib.lua")(S)
S.features({ provider = "anthropic", api_keys = { anthropic = W.FAKE.anthropic } })
local BookSettings = require("koassistant.books.book_settings")
-- One behavior "in behaviors/", staged in memory (a wiki run loads none of
-- the plugin folder's own)
if S.userBehaviors then
    S.userBehaviors.warm_and_brief = { name = "Warm and Brief",
        text = "Answer warmly and briefly, in plain words.", external = true, source = "folder" }
end

S.open(S.shotsBook("standalone") or "Mock Series 3")
W.prose(12)
-- The Domain & Research picker from the Domain chip, on the book: a domain
-- picked and a Background written
local ds = W.bookDS()
ds:saveSetting(BookSettings.KEY_DOMAIN, "synthesis")
ds:saveSetting(BookSettings.KEY_BACKGROUND, "Reading this aloud with my niece: keep explanations light.")
S.plugin:onKOAssistantBookChat()
S.settle()
-- (the chip carries the domain's name once one is set)
S.tap("Synthesis")
S.note("domain picker:", table.concat(S.texts(), " | "))
S.wiki("domain_research_picker.png")
S.closeAll()

-- Manage Behaviors with one file in behaviors/
S.menuPath({ "KOAssistant", "Actions & Prompts", { "^Manage Behaviors" } })
S.note("behaviors on page", tostring(W.listPageWith("FOLDER")))
S.wiki("manage_behaviors.png")
S.finish()
