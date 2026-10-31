-- The release zip, and what every installed updater needs from it (B379).
-- Readers update with the version they have installed: its updater dofiles the
-- new _meta.lua inside its own process and looks for main.lua and _meta.lua at
-- the top of the zip's one folder. tests/tools/updater_e2e.sh runs real
-- updates (the last release's updater and this tree's) with KOReader's own
-- archive code; these are the static rules that keep it passing.
--
-- Run: lua tests/unit/test_release_zip.lua  (or lua tests/run_tests.lua --unit)

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
    return plugin_dir
end
local plugin_dir = setupPaths()
local TestRunner = require("test_runner"):new()

local function read(rel)
    local f = assert(io.open(plugin_dir .. "/" .. rel, "r"), rel)
    local s = f:read("*a")
    f:close()
    return s
end

print("\n  [the zip]")

TestRunner:test("the release workflow builds its zip with the build script (one zip: the tested one is the downloaded one)", function()
    local workflow = read(".github/workflows/release.yml")
    TestRunner:assertTrue(workflow:find("sh scripts/build_release_zip.sh HEAD build/koassistant.koplugin.zip", 1, true) ~= nil,
        "release.yml runs scripts/build_release_zip.sh")
    TestRunner:assertTrue(workflow:find("--exclude=", 1, true) == nil, "release.yml keeps no exclude list of its own")
    local script = read("scripts/build_release_zip.sh")
    for _idx, name in ipairs({ "docs", "tests", "scripts", "hooks", "wiki", "screenshots", "*.pot", ".luacheckrc", "OWNER", ".gitignore", ".git-blame-ignore-revs" }) do
        TestRunner:assertTrue(script:find("--exclude='" .. name .. "'", 1, true) ~= nil, "the script leaves out " .. name)
    end
end)

TestRunner:test("the transitional shims list names old paths that are gone and modules that exist", function()
    local f = io.open(plugin_dir .. "/scripts/release_shims.txt", "r")
    if not f then return end   -- the list is deleted at the v0.25.0 open; nothing to check then
    local n = 0
    for line in f:lines() do
        if not line:match("^%s*#") and not line:match("^%s*$") then
            local old, mod = line:match("^(%S+) (%S+)$")
            TestRunner:assertTrue(old ~= nil, "a line is '<old path> <module id>': " .. line)
            TestRunner:assertTrue(io.open(plugin_dir .. "/" .. old, "r") == nil, old .. " must not exist in the tree (the zip writes it)")
            local new_rel = mod:gsub("%.", "/") .. ".lua"
            local g = io.open(plugin_dir .. "/" .. new_rel, "r")
            TestRunner:assertTrue(g ~= nil, mod .. " must be a module of the tree")
            if g then g:close() end
            n = n + 1
        end
    end
    f:close()
    TestRunner:assertTrue(n > 0, "the list is not empty")
    TestRunner:assertTrue(read("scripts/build_release_zip.sh"):find("release_shims.txt", 1, true) ~= nil, "the build script writes the shims")
end)

TestRunner:test("main.lua and _meta.lua stay at the top: every updater checks both there", function()
    TestRunner:assertTrue(io.open(plugin_dir .. "/main.lua", "r") ~= nil, "main.lua")
    TestRunner:assertTrue(io.open(plugin_dir .. "/_meta.lua", "r") ~= nil, "_meta.lua")
end)

TestRunner:test("_meta.lua needs nothing an older updater's process lacks", function()
    local meta = read("_meta.lua")
    TestRunner:assertTrue(meta:find("require%(") == nil, "no bare require: an older updater's process reads" ..
        " this file to check the version and cannot resolve the modules of a newer layout")
    TestRunner:assertTrue(meta:find('pcall%(require, "koassistant%.core%.gettext"%)') ~= nil, "the gettext module, under pcall")
    TestRunner:assertTrue(meta:find("if not ok then", 1, true) ~= nil, "a fallback when it cannot be loaded")
    TestRunner:assertTrue(meta:find('version = "[^"]+"'), "a version the updater compares with the tag")
end)

print("\n  [the updater]")

TestRunner:test("its deletes never follow a link", function()
    local uc = read("koassistant/storage/update_checker.lua")
    TestRunner:assertFalse(uc:find("ffiutil%.purgeDir[,(]"),
        "no purgeDir call: it empties a linked folder's target")
    TestRunner:assertTrue(uc:find('lfs.symlinkattributes(path, "mode")', 1, true), "purgeTree reads the link itself")
end)

TestRunner:test("any .git, a folder or a worktree's file, is a checkout it never replaces", function()
    local uc = read("koassistant/storage/update_checker.lua")
    TestRunner:assertFalse(uc:find('".git", "mode") == "directory"', 1, true), "the guard is not folder-only")
    TestRunner:assertFalse(uc:find('".git", "mode") ~= "directory"', 1, true), "Update Now is not folder-only")
end)

TestRunner:test("the download is checked before anything is extracted", function()
    local uc = read("koassistant/storage/update_checker.lua")
    local body = uc:match("performUpdate = function%(update_info%)(.-)\nend\n")
    TestRunner:assertTrue(body, "performUpdate found")
    local check = body and body:find("verifyDownload(archive_path, update_info)", 1, true)
    local extract = body and body:find("extractUpdateArchive(archive_path, staging_path)", 1, true)
    TestRunner:assertTrue(check and extract and check < extract, "verify, then extract")
    TestRunner:assertTrue(uc:find('asset.digest:match("^sha256:(%x+)$")', 1, true),
        "the release's sha256 is what the download must match")
end)

return TestRunner:summary()
