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
---
--- KOReader's own verbose logging counts as on: someone who enabled it has
--- already accepted a flooded log and is almost certainly collecting a bug
--- report, so "verbose" reading as "verbose except this plugin" would just
--- waste the report. Their flag cannot reach us on its own -- `dbg` here is a
--- real field, so it shadows the __index fallthrough and the global level
--- never touches it.
---
--- Re-read per call rather than cached: the KOReader toggle can flip
--- mid-session and we do not hook it. Callers re-sync often (every
--- updateConfigFromSettings), and the result is a plain assignment, so the
--- ~280 call sites keep the cheapest possible off path -- a noop, no branch,
--- which matters at the per-page X-Ray marking sites.
---
--- @param enabled boolean value of features.debug
function KoaLogger.setEnabled(enabled)
    if not enabled then
        local ok, koreader_dbg = pcall(require, "dbg")
        enabled = ok and koreader_dbg.is_on or false
    end
    KoaLogger.dbg = enabled and logger.LvDEBUG or noop
end

return KoaLogger
