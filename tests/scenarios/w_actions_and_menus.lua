-- Wiki shots for the Actions and Menus page (docs/assets/wiki_shotlist.txt)
local S = dofile(os.getenv("KOA_PLUGIN") .. "/tests/scenarios/boot.lua")
local W = dofile(S.PLUGIN .. "/tests/scenarios/wiki_lib.lua")(S)
S.features({ provider = "anthropic", api_keys = { anthropic = W.FAKE.anthropic },
    favorite_models = { { provider = "anthropic", model = "claude-opus-5-5" },
        { provider = "anthropic", model = "claude-haiku-5-5" } } })
-- One action made in the plugin (★, a book action that reads the position:
-- [reading]) and one built-in book action with an edit (⚙), so the three
-- marks share a page of Manage Actions
W.preSetting("custom_actions", { {
    text = "Where Was I?", context = "book", use_reading_progress = true,
    prompt = "In a few lines, remind me where I am in {title}: {reading_progress}.",
} })
W.preSetting("builtin_action_overrides", { ["book:xray"] = { temperature = 0.4 } })

local ui = S.open(S.shotsBook("standalone") or "Mock Series 3")
W.prose(12)
local PromptsManager = require("koassistant.ui.prompts_manager")

-- Manage Actions: the page with the ★ action (and the ⚙ one before it)
local pm = PromptsManager:new(S.plugin)
pm:show()
S.settle()
local list = S.top()
local star_page
for i, it in ipairs(list.item_table or {}) do
    if type(it.text) == "string" and it.text:find("★", 1, true) and not it.text:find("= custom", 1, true) then
        star_page = math.floor((i - 1) / list.perpage) + 1
        break
    end
end
if star_page then list:onGotoPage(star_page) end
S.settle()
S.note("manage actions page", tostring(star_page), ":", table.concat(S.texts(), " | "):sub(1, 400))
S.wiki("actionmanager.png")

-- Hold a built-in: Action Details
local Actions = require("koassistant.prompts.actions")
local explain = S.plugin.action_service:getAction("highlight", "explain")
pm:showPromptDetails(explain or Actions.highlight.explain)
S.settle()
S.note("details:", table.concat(S.texts(), " | "))
S.wiki("action_details.png")
S.closeAll()

-- A new highlight action, Step 3/3: Settings (the editor's own defaults)
local pm2 = PromptsManager:new(S.plugin)
function pm2:showStep1_NameAndContext(state)
    state.name = "Explain for a Child"
    state.context = "highlight"
    state.prompt = "Explain this passage in words a ten-year-old knows:\n\n{highlighted_text}"
    self:showStep3_Settings(state)
end
pm2:showPromptEditor()
S.settle()
S.note("step 3:", table.concat(S.texts(), " | "))
S.wiki("action_editor_settings.png")
S.closeAll()

-- Settings → Menus & Buttons → Highlight Menu Actions
S.menuPath({ "KOAssistant", "Menus & Buttons", "Highlight Menu Actions" })
S.note("highlight menu actions:", table.concat(S.texts(), " | "):sub(1, 400))
S.wiki("highlight_menu_manager.png")
S.closeAll()

-- The highlight menu, then a long-press on one of its actions
W.select(2, 14)
W.highlightMenu()
require("koassistant.ui.action_hold").show(S.plugin, explain or Actions.highlight.explain,
    { surface = "highlight", run = function() end })
S.settle()
S.note("hold menu:", table.concat(S.texts(), " | "))
S.wiki("action_hold_menu.png")
S.closeAll()

-- The model button first in the highlight menu, its list open
W.select(2, 14)
W.highlightMenu()
S.tap({ "^Model: " })
S.note("model list:", table.concat(S.texts(), " | "))
S.wiki("model_button_list.png")
S.closeAll()

S.finish()
