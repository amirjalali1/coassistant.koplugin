-- Wiki shots for the Reasoning, Web Search and Book Tools page (docs/assets/wiki_shotlist.txt)
local S = dofile(os.getenv("KOA_PLUGIN") .. "/tests/scenarios/boot.lua")
local W = dofile(S.PLUGIN .. "/tests/scenarios/wiki_lib.lua")(S)
S.features({ provider = "anthropic", api_keys = { anthropic = W.FAKE.anthropic, gemini = W.FAKE.gemini } })

S.open(S.shotsBook("standalone") or "Mock Series 3")
W.prose(12)

-- Settings → Advanced → Reasoning → Per-model reasoning, one provider's list
S.menuPath({ "KOAssistant", "Advanced", "Reasoning", "Per-model reasoning" })
S.note("per-model:", table.concat(S.menuRows(), " | "))
S.menuTap({ "Anthropic" })
S.note("anthropic:", table.concat(S.menuRows(), " | "))
S.wiki("reasoning-per-model.png")
S.closeAll()

-- Quick Settings → the Reasoning tile (the current model's own ladder)
S.plugin:onKOAssistantAISettings()
S.settle()
S.tap({ "Reasoning" })
S.tap({ "Current model" })
S.note("reasoning popup:", table.concat(S.texts(), " | "))
S.wiki("reasoning_popup.png")
S.closeAll()

-- Explain in Context with the Tools chip on: Smart retrieval preselected
W.select(0, 16)
W.highlightMenu()
S.tap("Chat/Action (KOA)")
S.tap({ "^Tools" })
S.tap("Explain in Context")
S.note("source popup:", table.concat(S.texts(), " | "))
S.wiki("smart_retrieval_source.png")
S.finish()
