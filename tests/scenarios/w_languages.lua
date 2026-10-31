-- Wiki shots for the Languages page (docs/assets/wiki_shotlist.txt)
local S = dofile(os.getenv("KOA_PLUGIN") .. "/tests/scenarios/boot.lua")
local W = dofile(S.PLUGIN .. "/tests/scenarios/wiki_lib.lua")(S)
S.features({ user_languages = "English, Arabic" })

S.open(S.shotsBook("standalone") or "Mock Series 3")
W.prose()
-- Settings → AI Language Settings → Your Languages, two picked
S.menuPath({ "KOAssistant", "AI Language Settings" })
S.note("rows:", table.concat(S.menuRows(), " | "))
S.menuTap({ "^Your Languages" })
S.note("languages:", table.concat(S.menuRows(), " | "))
S.wiki("languages-your-languages.png")
S.finish()
