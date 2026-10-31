-- Wiki shots for the Privacy and Data page (docs/assets/wiki_shotlist.txt)
local S = dofile(os.getenv("KOA_PLUGIN") .. "/tests/scenarios/boot.lua")
local W = dofile(S.PLUGIN .. "/tests/scenarios/wiki_lib.lua")(S)

local ui = S.open(S.shotsBook("standalone") or "Mock Series 3")
W.prose()

-- Settings → Privacy & Data open
S.menuPath({ "KOAssistant", "Privacy & Data" })
S.check((S.menuRows()[1] or ""):find("^Trusted Providers") ~= nil, "Privacy & Data opens on Trusted Providers")
S.wiki("privacy-data-menu.png")

-- The Trusted Providers dialog with Ollama ticked
S.menuTap({ "^Trusted Providers" })
S.tap("☐ Ollama")
W.scrollTo("☑ Ollama")
S.check(S.find("☑ Ollama") ~= nil, "Ollama is ticked")
S.wiki("trusted-providers-dialog.png")
S.closeAll()

-- Book Settings → Privacy & Data, one row set to Never for this book
local BookSettings = require("koassistant.books.book_settings")
W.bookDS():saveSetting(BookSettings.KEY_HIGHLIGHTS_SHARING, false)
BookSettings.showPrivacyConfig({ plugin = S.plugin, ui = ui })
S.settle()
S.note("book privacy:", table.concat(S.texts(), " | "))
S.wiki("book-privacy-overrides.png")
S.closeAll()

-- Quick Actions with the emoji data access indicators on
W.features({ enable_emoji_icons = true, enable_emoji_panel_icons = true, enable_data_access_indicators = true })
S.plugin:onKOAssistantQuickActions()
S.settle()
S.note("quick actions:", table.concat(S.texts(), " | "))
S.wiki("data-access-indicators.png")
S.closeAll()

S.finish()
