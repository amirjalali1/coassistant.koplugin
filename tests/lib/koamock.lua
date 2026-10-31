--[[
The koamock fixture (tests/fixtures/mock_series/spec.lua) as test data: the
invented books gen.lua writes to disk, read straight from the spec with their
paths filled under a fixed base. Nothing is written.

    local KoaMock = require("koamock")
    local data, path = KoaMock.xray("Mock Series 3")   -- parsed, a fresh table
]]

local KoaMock = {}

KoaMock.BASE = "/koamock"

local spec
local function specPath()
    local here = debug.getinfo(1, "S").source:match("@?(.*)")
    local lib_dir = here:match("(.+)/[^/]+$") or "."
    local tests_dir = lib_dir:match("(.+)/[^/]+$") or "."
    return tests_dir .. "/fixtures/mock_series/spec.lua"
end

function KoaMock.spec()
    if not spec then spec = dofile(specPath()) end
    return spec
end

--- A book's number in the spec, by number or by a plain text in its filename.
function KoaMock.book(key)
    local books = KoaMock.spec().books
    if type(key) == "number" then return key, books[key] end
    for n, b in ipairs(books) do
        if b.filename:find(key, 1, true) then return n, b end
    end
    error("no koamock book matches: " .. tostring(key), 2)
end

--- Where book n lives under the base, as gen.lua names it.
function KoaMock.path(key)
    local n, b = KoaMock.book(key)
    assert(b, "no koamock book " .. tostring(n))
    return KoaMock.BASE .. "/" .. b.folder .. "/" .. b.filename
end

--- A JSON string with its __PATH:n__ placeholders filled.
function KoaMock.fill(json)
    return (json:gsub("__PATH:(%d+)__", function(n) return KoaMock.path(tonumber(n)) end))
end

--- A book's hand-added record (B400) as ActionCache.getPromotedStubs gives it:
--- lowercased name -> the stored spelling.
function KoaMock.promoted(key)
    local _n, b = KoaMock.book(key)
    local set = {}
    for _idx, name in ipairs((b.aliases or {})["__dormant_promoted"] or {}) do
        set[name:lower()] = name
    end
    return set
end

--- A book's live X-Ray, parsed by the real parser (a fresh table each call),
--- and the book's path.
function KoaMock.xray(key)
    local n, b = KoaMock.book(key)
    assert(b.xray, b.filename .. " has no planted X-Ray")
    local XrayParser = require("koassistant.xray.xray_parser")
    return XrayParser.parse(KoaMock.fill(b.xray.json)), KoaMock.path(n)
end

return KoaMock
