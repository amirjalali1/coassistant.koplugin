-- Unit tests for Dialogs.applyQuickReplyOverrides (release-blocking six-pack [2]):
-- the reply-time re-derivation of web/tools/model/reasoning from the
-- _quick_reply_orig baseline — stash, pin-beats-preset, full revert, and the
-- {follow=true} reasoning sentinel with the wire-key wipe.

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({
        plugin_dir .. "/?.lua", tests_dir .. "/?.lua", tests_dir .. "/lib/?.lua", package.path,
    }, ";")
end
setupPaths()
require("mock_koreader")

local Dialogs = require("koassistant_dialogs")

local TestRunner = { passed = 0, failed = 0 }
function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then self.passed = self.passed + 1; print("    ✓ " .. name)
    else self.failed = self.failed + 1; print("    ✗ " .. name); print("      Error: " .. tostring(err)) end
end
function TestRunner:ok(v, msg) if not v then error(msg or "expected truthy", 2) end end
function TestRunner:eq(a, b, msg)
    if a ~= b then error(string.format("%s: expected %s, got %s",
        msg or "eq", tostring(b), tostring(a)), 2) end
end

local function makeConfig(features)
    return {
        provider = "anthropic",
        model = "claude-sonnet-5",
        provider_settings = { anthropic = { model = "claude-sonnet-5" } },
        enable_web_search = true,
        api_params = { temperature = 0.7 },
        features = features,
    }
end

print("")
print(string.rep("=", 50))
print("  Unit Tests: Quick Reply Overrides")
print(string.rep("=", 50))

TestRunner:test("first quick call stashes the baseline and forces web+tools off", function()
    local f = { _session_quick_answer = true, _tools_active = true }
    local cfg = makeConfig(f)
    Dialogs.applyQuickReplyOverrides(cfg, nil)
    TestRunner:ok(f._quick_reply_orig, "baseline stashed")
    TestRunner:eq(f._quick_reply_orig.enable_web_search, true, "stash holds the pre-quick web value")
    TestRunner:eq(cfg.enable_web_search, false, "preset forces web off")
    TestRunner:eq(f._tools_active, false, "preset forces tools off")
    TestRunner:eq(cfg.provider, "anthropic", "no model mode configured: provider untouched")
    TestRunner:eq(type(cfg.api_params._reasoning), "table", "reasoning decision attached")
end)

TestRunner:test("a touched facet (pin) survives the quick preset", function()
    local f = { _session_quick_answer = true, _session_web_touched = true }
    local cfg = makeConfig(f)
    Dialogs.applyQuickReplyOverrides(cfg, nil)
    TestRunner:eq(cfg.enable_web_search, true, "pinned web keeps its baked value under quick")
    TestRunner:eq(f._tools_active, false, "untouched tools facet still forced off")
end)

TestRunner:test("clearing every pick restores the stash and drops it", function()
    local f = { _session_quick_answer = true, _tools_active = true }
    local cfg = makeConfig(f)
    Dialogs.applyQuickReplyOverrides(cfg, nil)
    TestRunner:eq(cfg.enable_web_search, false, "precondition: quick applied")
    f._session_quick_answer = nil
    Dialogs.applyQuickReplyOverrides(cfg, nil)
    TestRunner:eq(cfg.enable_web_search, true, "web restored from the stash")
    TestRunner:eq(f._tools_active, true, "tools restored from the stash")
    TestRunner:eq(cfg.provider, "anthropic", "provider restored")
    TestRunner:eq(cfg.model, "claude-sonnet-5", "model restored")
    TestRunner:eq(cfg.api_params.temperature, 0.7, "api_params restored")
    TestRunner:eq(cfg.api_params.thinking, nil, "reply-decision wire keys do not survive the revert")
    TestRunner:eq(f._quick_reply_orig, nil, "stash dropped so a later pick re-stashes fresh")
end)

TestRunner:test("{follow=true} reasoning sentinel wipes stale wire keys and re-resolves", function()
    local f = { _session_reasoning = { follow = true } }
    local cfg = makeConfig(f)
    -- A stale reasoning wire key from a previous decision, captured into the
    -- stash on first call — the wipe must clear it before re-resolution.
    cfg.api_params.thinking = { type = "enabled", budget_tokens = 999 }
    Dialogs.applyQuickReplyOverrides(cfg, nil)
    local thinking = cfg.api_params.thinking
    TestRunner:ok(not (type(thinking) == "table" and thinking.budget_tokens == 999),
        "stale wire key from the previous decision is gone")
    TestRunner:eq(type(cfg.api_params._reasoning), "table", "fresh decision attached")
    -- follow = resolve WITHOUT a session layer: default stance on this model
    -- sends nothing, so no forced off/on state may remain on the wire
    TestRunner:eq(cfg.api_params._reasoning.send_nothing, true,
        "sentinel resolves stance-only (model API default)")
end)

print("")
print(string.rep("-", 50))
print(string.format("  Results: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
print(string.rep("-", 50))
return TestRunner.failed == 0
