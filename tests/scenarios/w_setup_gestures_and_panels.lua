-- Wiki shots for the Setup, Gestures and Panels page (docs/assets/wiki_shotlist.txt)
local S = dofile(os.getenv("KOA_PLUGIN") .. "/tests/scenarios/boot.lua")
local W = dofile(S.PLUGIN .. "/tests/scenarios/wiki_lib.lua")(S)
S.features({ provider = "anthropic", api_keys = { anthropic = W.FAKE.anthropic },
    enable_emoji_icons = true, enable_emoji_panel_icons = true })

-- KOReader's default gestures (its Gestures plugin's own table) with Quick
-- Settings on a file browser corner and Quick Actions on a reader corner
do
    local DataStorage = require("datastorage")
    local defaults = dofile("plugins/gestures.koplugin/defaults.lua")
    defaults.gesture_fm.tap_right_bottom_corner = { koassistant_ai_settings = true }
    defaults.gesture_reader.tap_right_bottom_corner = { koassistant_quick_actions = true }
    local gs = require("luasettings"):open(DataStorage:getSettingsDir() .. "/gestures.lua")
    gs:saveSetting("gesture_fm", defaults.gesture_fm)
    gs:saveSetting("gesture_reader", defaults.gesture_reader)
    gs:flush()
end

-- Quick Settings in the file browser, emoji on
S.fileManager()
S.plugin:onKOAssistantAISettings()
S.settle()
S.note("quick settings:", table.concat(S.texts(), " | "))
S.wiki("quick-settings-panel.png")
S.closeAll()

-- Settings → Gestures, and the slot picker of Quick Settings
S.plugin:showGesturesScreen()
S.settle()
S.note("gestures:", table.concat(S.texts(), " | "))
S.wiki("shortcuts-screen.png")
S.tap({ "Quick Settings" })
S.tap({ "^Add a gesture %(file browser%)" })
S.note("slot picker:", table.concat(S.texts(), " | "))
S.wiki("shortcut-slot-picker.png")
S.closeAll()

-- The Setup Wizard's icons step (the emoji display test) and gestures step
local SetupWizard = require("koassistant.ui.setup_wizard")
SetupWizard.stepIcons(S.plugin, { force = true, results = {} }, function() end)
S.settle()
S.note("icons step:", table.concat(S.texts(), " | "))
S.wiki("setup-wizard-emoji.png")
S.closeAll()
SetupWizard.stepGestures(S.plugin, { force = true, results = {} }, function() end)
S.settle()
S.note("gestures step:", table.concat(S.texts(), " | "))
S.wiki("setup-wizard-gestures.png")
S.closeAll()

-- Quick Actions in a book of a group
local book = S.shotsBook("series", 1) or "Mock Series 3"
S.open(book)
W.prose(10)
if S.SHOTS then W.group(S.SHOTS.series_name or "Series", "series", W.seriesBooks()) end
S.plugin:onKOAssistantQuickActions()
S.settle()
S.note("quick actions:", table.concat(S.texts(), " | "))
S.wiki("quick-actions-panel.png")
S.closeAll()

S.finish()
