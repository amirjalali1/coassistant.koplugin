-- Wiki shots for the Research Mode page (docs/assets/wiki_shotlist.txt)
local S = dofile(os.getenv("KOA_PLUGIN") .. "/tests/scenarios/boot.lua")
local W = dofile(S.PLUGIN .. "/tests/scenarios/wiki_lib.lua")(S)
S.features({ provider = "anthropic", api_keys = { anthropic = W.FAKE.anthropic } })
local BookSettings = require("koassistant.books.book_settings")

S.open(S.shotsBook("nonfiction") or "Mock Series 3")
W.prose(70)
-- The Domain chip's picker on "For this book"
S.plugin:onKOAssistantBookChat()
S.settle()
S.tap("Domain")
S.note("domain picker:", table.concat(S.texts(), " | "))
S.wiki("domain-research-picker.png")
S.closeAll()

-- Research mode on for this book, emoji icons on: the 🔬 Domain chip
W.bookDS():saveSetting(BookSettings.KEY_RESEARCH, true)
W.features({ enable_emoji_icons = true })
S.plugin:onKOAssistantBookChat()
S.settle()
S.note("chips:", table.concat(S.texts(), " | "))
S.wiki("domain-chip-research.png")
S.finish()
