-- B486 on the real widgets: a picture that records Gil Rook (Mock Series 3)
-- shows as "Pictures (1)…" on his entry's More… and opens the gallery on
-- him. The picture is planted through the plugin's own save; nothing is drawn
-- by a provider. (B535's picks are the picture popup's, s06.)
local S = dofile(os.getenv("KOA_PLUGIN") .. "/tests/scenarios/boot.lua")
-- An image provider with a key so Illustrate… is offered beside it (a fake
-- key in the run's own settings; the network is blocked)
S.features({ image_gen_provider = "openai", api_keys = { openai = "sk-scenario-not-a-key" } })

local ui = S.open("Mock Series 3")
local file = ui.document.file
local ActionCache = require("koassistant.artifacts.action_cache")
local XrayParser = require("koassistant.xray.xray_parser")
local XrayBrowser = require("koassistant.xray.xray_browser")
local ImageGenerator = require("koassistant.images.image_generator")

local data = XrayParser.parse(ActionCache.getXrayCache(file).result)
XrayParser.mergeUserAliases(data, ActionCache.getUserAliases(file))

-- ── A picture of Gil Rook, saved as a drawn one is ──
local Blitbuffer = require("ffi/blitbuffer")
local bb = Blitbuffer.new(240, 320, Blitbuffer.TYPE_BB8)
bb:fill(Blitbuffer.Color8(0xCC))
bb:paintRect(60, 80, 120, 160, Blitbuffer.Color8(0x33))
local png = S.RUN .. "/planted.png"
bb:writePNG(png)
local f = assert(io.open(png, "rb"))
local bytes = f:read("*a")
f:close()
local saved = ImageGenerator.saveImage(bytes, "Gil Rook", { file = file, title = "Mock Series 3 - The Orchard" },
    "A grafter up a ladder in the salt-apple rows.", nil,
    { entries = { "Gil Rook" }, provider = "openai", model = "scenario" })
S.check(saved ~= nil, "a picture of Gil Rook is saved with the entry it shows")

-- ── His entry's More… ──
local gil
for _idx, item in ipairs(data.characters or {}) do
    if item.name == "Gil Rook" then gil = item end
end
XrayBrowser:show(data, { title = "Mock Series 3 - The Orchard", book_file = file, plugin = S.plugin,
    configuration = S.plugin.configuration, enable_emoji = false }, ui)
S.settle()
XrayBrowser:showItemDetail(gil, "characters", "Gil Rook")
S.settle()
XrayBrowser:_showEntityManagePopup(gil, "characters", "Gil Rook", nil, nil, XrayBrowser._detail_viewer, true, {})
S.settle()
local more = table.concat(S.texts(), " | ")
S.note("More…:", more)
S.check(more:find("Pictures (1)…", 1, true) ~= nil, "More… offers Pictures (1)…")
S.check(more:find("Illustrate…", 1, true) ~= nil, "beside Illustrate…")
S.shot("more")
S.tap("Pictures (1)…")
local grid = S.top()
local title = grid and grid.title_bar and grid.title_bar.title or (grid and grid.title)
S.note("the gallery:", tostring(title))
S.check(type(title) == "string" and title:find("Gil Rook", 1, true) ~= nil, "the gallery opens on Gil Rook's pictures")
S.shot("gallery")
S.UIManager:close(grid)
S.settle()

-- Tamsin Vael has no picture: Illustrate… alone
local tamsin
for _idx, item in ipairs(data.characters or {}) do
    if item.name == "Tamsin Vael" then tamsin = item end
end
S.UIManager:close(S.top())
XrayBrowser:_showEntityManagePopup(tamsin, "characters", "Tamsin Vael", nil, nil, nil, true, {})
S.settle()
S.check(not table.concat(S.texts(), " | "):find("Pictures", 1, true), "an entry without pictures has no Pictures row")
S.UIManager:close(S.top())
S.settle()

S.finish()
