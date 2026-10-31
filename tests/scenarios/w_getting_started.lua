-- Wiki shots for the Getting Started page (docs/assets/wiki_shotlist.txt)
local S = dofile(os.getenv("KOA_PLUGIN") .. "/tests/scenarios/boot.lua")
local W = dofile(S.PLUGIN .. "/tests/scenarios/wiki_lib.lua")(S)
-- One key entered in the plugin ([set]) and one in apikeys.lua ((file)); fakes
S.features({ provider = "anthropic", api_keys = { anthropic = W.FAKE.anthropic } })
W.fileKeys({ deepseek = W.FAKE.deepseek })

S.open(S.shotsBook("standalone") or "Mock Series 3")
W.prose()

-- Settings → API Keys & Auth
S.menuPath({ "KOAssistant", "API Keys & Auth" })
S.note("rows:", table.concat(S.menuRows(), " | "))
S.wiki("api-keys-menu.png")
S.closeAll()

-- A passage selected, the highlight menu
W.select(2, 16)
W.highlightMenu()
S.note("highlight menu:", table.concat(S.texts(), " | "))
S.wiki("first-action-highlight-menu.png")
S.closeAll()

S.finish()
