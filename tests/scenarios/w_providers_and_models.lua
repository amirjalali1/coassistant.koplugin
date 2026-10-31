-- Wiki shots for the Providers and Models page (docs/assets/wiki_shotlist.txt).
-- Staged with fake keys only: Anthropic (one entered here, one in
-- apikeys.lua), Gemini (a named one entered here, one in apikeys.lua), one
-- community provider; a custom provider that needs no key; DeepSeek selected
-- without a key; a favorite, a custom tier, a saved Ollama server.
local S = dofile(os.getenv("KOA_PLUGIN") .. "/tests/scenarios/boot.lua")
local W = dofile(S.PLUGIN .. "/tests/scenarios/wiki_lib.lua")(S)
S.features({
    provider = "deepseek",
    api_keys = {
        anthropic = W.FAKE.anthropic,
        gemini = { { key = W.FAKE.gemini, alias = "Phone" } },
        together = "tgp_v1_wikishot00000000000000000000000000000000",
    },
    custom_providers = { {
        id = "custom_home_server", name = "Home Server", base_url = "http://192.168.1.20:8080/v1",
        default_model = "local-model", api_key_required = false,
    } },
    favorite_models = { { provider = "anthropic", model = "claude-opus-5-5" } },
    tier_overrides = { anthropic = { fast = "claude-sonnet-5" } },
    ollama_endpoints = { list = { { url = "http://192.168.1.30:11434", name = "Desk PC" } } },
})
W.fileKeys({ anthropic = "sk-ant-api03-wikishotfile00000000000000000000000000000000000000000",
    gemini = W.FAKE.gemini_file })

S.open(S.shotsBook("standalone") or "Mock Series 3")
W.prose()

-- Settings → Model: the hub
S.openMenu("KOAssistant")
S.menuTap("KOAssistant")
S.menuTap({ "^Model: " })
S.note("hub:", table.concat(S.menuRows(), " | "))
S.wiki("provider-model-hub.png")

-- Anthropic's model menu
S.menuTap("Anthropic")
S.note("anthropic:", table.concat(S.menuRows(), " | "))
S.wiki("model-menu.png")

-- Its Model tiers..., one tier custom
S.menuTap("Model tiers...")
S.note("tiers:", table.concat(S.menuRows(), " | "))
S.wiki("model-tiers.png")
S.menu():backToUpperMenu()
S.menu():backToUpperMenu()
S.settle()

-- Gemini's keys: a named key entered here and one from apikeys.lua
S.menuTap("Gemini")
S.menuTap({ "^API keys" })
S.note("gemini keys:", table.concat(S.texts(), " | "))
S.wiki("api-key-manager.png")
S.closeAll()

-- Ollama's servers: this device and a named one
S.openMenu("KOAssistant")
S.menuTap("KOAssistant")
S.menuTap({ "^Model: " })
S.menuTap("Ollama")
S.menuTap({ "^Server: " })
S.note("servers:", table.concat(S.texts(), " | "))
S.wiki("ollama-servers.png")
S.closeAll()

S.finish()
