--[[--
Plugin-scoped logger (issue #104).

KOReader's log level is GLOBAL. Routine plugin tracing belongs at `dbg` so it
stays out of the user's crash.log, but raising the global level to see it again
also unleashes core's ~700 dbg lines (`blitFrom` on every paint), which buries
the very output you turned it on for.

So the plugin's `dbg` is switched by the plugin's own Console Debug setting
instead of by the global level, using `logger.LvDEBUG` -- which emits at DEBUG
regardless of what the level is set to. `info`/`warn`/`err` fall through to
KOReader's logger untouched, so they keep obeying the global level as normal.

Plugin files require THIS module as `logger`, so the ~280 `logger.dbg(...)`
call sites are unchanged and no file gains an upvalue (the 60-upvalue LuaJIT
cap in main.lua / koassistant_dialogs.lua leaves no room for new file-locals).

@module koassistant_logger
]]

local logger = require("logger")

local noop = function() end

-- info/warn/err resolve through __index at call time, so they always pick up
-- whatever KOReader's setLevel last installed.
local KoaLogger = setmetatable({}, { __index = logger })

KoaLogger.dbg = noop

--- Turn the plugin's own debug tracing on or off.
--- @param enabled boolean value of features.debug
function KoaLogger.setEnabled(enabled)
    KoaLogger.dbg = enabled and logger.LvDEBUG or noop
end

return KoaLogger
