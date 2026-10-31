-- Wiki shots for the Spoiler Protection page (docs/assets/wiki_shotlist.txt)
local S = dofile(os.getenv("KOA_PLUGIN") .. "/tests/scenarios/boot.lua")
local W = dofile(S.PLUGIN .. "/tests/scenarios/wiki_lib.lua")(S)
S.features({ provider = "anthropic", api_keys = { anthropic = W.FAKE.anthropic } })

S.open(S.shotsBook("standalone") or "Mock Series 3")
W.prose(12)
-- The Spoiler chip's long-press picker, from a book chat's input dialog
S.plugin:onKOAssistantBookChat()
S.settle()
S.hold({ "^Spoiler" })
S.note("spoiler picker:", table.concat(S.texts(), " | "))
S.wiki("spoiler-chip-picker.png")
S.finish()
