-- The plugin's folders, from this file's own location: it sits at
-- koassistant/core/paths.lua, two levels below the plugin's root. ONE copy:
-- every module that needs the root (the reader's files, locale/, fonts/,
-- _meta.lua, the built-in prompts) asks here instead of reading its own
-- location, which stopped meaning the root when the modules moved into folders.
local Paths = {}

local here = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
local root, found = here:gsub("koassistant/core/$", "")
if found ~= 1 then
    -- Never guess: the updater moves the folder this names aside, and the
    -- reader's files are read from it.
    error("koassistant: paths.lua expected under koassistant/core/, found at " .. here)
end
if root == "" then root = "./" end
Paths.ROOT = root                                    -- ends with "/"
Paths.CODE = Paths.ROOT .. "koassistant/"            -- the modules and the built-in prompts

-- The plugin's own _meta.lua, read by path and once (B384): require("_meta")
-- returns whichever plugin's _meta.lua KOReader loaded first, since every
-- plugin shares one package.loaded, and assistant.koplugin loads before this one.
local meta
function Paths.meta()
    if not meta then meta = dofile(Paths.ROOT .. "_meta.lua") end
    return meta
end

return Paths
