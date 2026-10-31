-- Wiki shots for the Image Generation page (docs/assets/wiki_shotlist.txt)
local S = dofile(os.getenv("KOA_PLUGIN") .. "/tests/scenarios/boot.lua")
local W = dofile(S.PLUGIN .. "/tests/scenarios/wiki_lib.lua")(S)
-- An image provider with a (fake) key: the rows are live
S.features({ image_gen_provider = "openai", api_keys = { openai = W.FAKE.openai } })

local ui = S.open(S.shotsBook("standalone") or "Mock Series 3")
W.prose()

-- Settings → Advanced → Image Generation, Provider set to OpenAI
S.menuPath({ "KOAssistant", "Advanced", "Image Generation" })
S.note("rows:", table.concat(S.menuRows(), " | "))
S.wiki("image-generation-settings.png")
S.wiki("image_gen_settings.png")
S.closeAll()

-- A tap of Generate Image on a passage: the picture popup
local text = W.select(2, 16).text
local Actions = require("koassistant.prompts.actions")
require("koassistant.ui.dialogs").executeDirectAction(ui, Actions.highlight.image_gen, text,
    S.plugin.configuration, S.plugin)
S.settle()
S.wiki("picture-popup.png")
S.closeAll()

S.finish()
