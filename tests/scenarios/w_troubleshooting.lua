-- Wiki shots for the Troubleshooting page (docs/assets/wiki_shotlist.txt)
local S = dofile(os.getenv("KOA_PLUGIN") .. "/tests/scenarios/boot.lua")
local W = dofile(S.PLUGIN .. "/tests/scenarios/wiki_lib.lua")(S)

S.open(S.shotsBook("standalone") or "Mock Series 3")
W.prose()
-- Settings → Privacy & Data, its second page with the Text Extraction row
S.menuPath({ "KOAssistant", "Privacy & Data" })
S.menu():updateItems(2)
S.settle()
S.wiki("troubleshooting-privacy-table.png")
S.finish()
