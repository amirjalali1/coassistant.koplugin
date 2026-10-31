-- Vault/central notebook names (koassistant/chat/notebook.lua):
--   * the 100-byte cap lands on a whole character (a cut inside a CJK
--     character made a name the filesystem refused)
--   * two books with one generated name: the second takes the next free
--     name instead of sharing (and deleting) the first book's notebook; a
--     book whose recorded file is gone (moved, re-added) adopts it, and so
--     does a file made by hand (no front matter)
-- Real files in a scratch folder; the mocks are the snippet test's.
--
-- Run: lua tests/unit/test_notebook_naming.lua  (or lua tests/run_tests.lua --unit)

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({
        plugin_dir .. "/?.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
end
setupPaths()
require("mock_koreader")

local orig_G_reader_settings = _G.G_reader_settings
local orig_docsettings = package.loaded["docsettings"]
local orig_safe_docsettings = package.loaded["koassistant.storage.doc_settings"]

local tmp = os.tmpname()
os.remove(tmp)
local base = tmp .. "_notebooks"
os.execute("mkdir -p '" .. base .. "'")
local function touch(path) local f = assert(io.open(path, "w")); f:write("book"); f:close() end
local function slurp(path) local f = io.open(path, "r"); if not f then return nil end; local s = f:read("*a"); f:close(); return s end

local grs_store = {
    features = { notebook_save_location = "custom", notebook_custom_path = base },
}
_G.G_reader_settings = {
    readSetting = function(_, key, default)
        if grs_store[key] == nil then return default end
        return grs_store[key]
    end,
    saveSetting = function(_, key, value) grs_store[key] = value end,
    flush = function() end,
}
-- One settings store per book: the ref create() writes is what getPath reads back
local stores = {}
local function storeFor(path)
    if not stores[path] then
        local data = {}
        stores[path] = {
            readSetting = function(_, key) return data[key] end,
            saveSetting = function(_, key, value) data[key] = value end,
            flush = function() end,
            close = function() end,
        }
    end
    return stores[path]
end
package.loaded["docsettings"] = {
    open = function(_, path) return storeFor(path) end,
    getSidecarDir = function(_, path) return path .. ".sdr" end,
    isHashLocationEnabled = function() return false end,
}
package.loaded["koassistant.storage.doc_settings"] = {
    resolve = function(path) return storeFor(path) end,
    overlayCustomProps = function(raw) return raw end,
}
local util_mod = package.loaded["util"]
if not util_mod then util_mod = {}; package.loaded["util"] = util_mod end
if not util_mod.makePath then
    util_mod.makePath = function(dir) os.execute("mkdir -p '" .. dir .. "'") end
end

package.loaded["koassistant.chat.notebook"] = nil
local Notebook = require("koassistant.chat.notebook")
local TestRunner = require("test_runner"):new()

print("")
print(string.rep("=", 50))
print("  Unit Tests: Notebook naming")
print(string.rep("=", 50))

TestRunner:test("the length cap lands on a whole character", function()
    local name = Notebook.generateFilename("/books/x.epub", { title = string.rep("中", 60), authors = "作者" })
    local stem = name:match("^(.*)%.md$")
    TestRunner:assertTrue(stem ~= nil and #stem <= 100, "capped at 100 bytes: " .. tostring(#stem))
    TestRunner:assertTrue(utf8.len(stem) ~= nil, "valid UTF-8 after the cut")
    TestRunner:assertEqual(stem:sub(-3), "中", "ends on a whole character")
end)

local PROPS = { title = "Same Title", authors = "Same Author" }
local A, B, C = base .. "/a.epub", base .. "/b.epub", base .. "/c.epub"
touch(A); touch(B); touch(C)
for _, book in ipairs({ A, B, C }) do storeFor(book):saveSetting("doc_props", PROPS) end

TestRunner:test("the first book creates its notebook under the generated name", function()
    local ok, err = Notebook.create(A)
    TestRunner:assertTrue(ok, "created: " .. tostring(err))
    TestRunner:assertEqual(Notebook.getPath(A), base .. "/Same Author — Same Title.md", "the generated name")
    TestRunner:assertTrue(Notebook.exists(A), "exists for its book")
    local ok2 = Notebook.append(Notebook.getPath(A), "A's note\n")
    TestRunner:assertTrue(ok2, "a note appended")
end)

TestRunner:test("a second book with the same author and title has no notebook yet", function()
    TestRunner:assertFalse(Notebook.exists(B), "the first book's file is not its notebook")
    TestRunner:assertEqual(Notebook.read(B), nil, "and is never read as its notes")
    TestRunner:assertEqual(Notebook.getStats(B), nil, "nor indexed as its notebook")
end)

TestRunner:test("creating the second book's notebook takes the next free name", function()
    local ok, err = Notebook.create(B)
    TestRunner:assertTrue(ok, "created: " .. tostring(err))
    TestRunner:assertEqual(Notebook.getPath(B), base .. "/Same Author — Same Title (2).md", "the next free name")
    TestRunner:assertTrue(Notebook.exists(B), "exists for its book now")
    TestRunner:assertTrue(Notebook.read(B) ~= nil and not Notebook.read(B):find("A's note", 1, true),
        "its own notebook, not the first book's")
    TestRunner:assertEqual(Notebook.getPath(A), base .. "/Same Author — Same Title.md", "the first book keeps its file")
end)

TestRunner:test("a book whose recorded file is gone adopts the notebook of that name", function()
    os.remove(A)  -- the first book moved away or was re-added: its link is lost, the file stays
    TestRunner:assertTrue(Notebook.exists(C), "the orphaned file serves the next book of that name")
    TestRunner:assertTrue((Notebook.read(C) or ""):find("A's note", 1, true) ~= nil, "with its notes")
    local ok = Notebook.create(C)
    TestRunner:assertTrue(ok, "adopted")
    TestRunner:assertEqual(Notebook.getPath(C), base .. "/Same Author — Same Title.md", "linked to that file")
end)

TestRunner:test("a file made by hand (no front matter) serves the book of its name", function()
    local D = base .. "/d.epub"
    touch(D)
    storeFor(D):saveSetting("doc_props", { title = "Hand Made" })
    local f = assert(io.open(base .. "/Hand Made.md", "w")); f:write("# my notes\n"); f:close()
    TestRunner:assertTrue(Notebook.exists(D), "the hand-made file is the book's")
end)

os.execute("rm -rf '" .. base .. "'")
_G.G_reader_settings = orig_G_reader_settings
package.loaded["docsettings"] = orig_docsettings
package.loaded["koassistant.storage.doc_settings"] = orig_safe_docsettings
package.loaded["koassistant.chat.notebook"] = nil

return TestRunner:summary()
