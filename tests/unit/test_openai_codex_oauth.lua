local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({ plugin_dir .. "/?.lua", tests_dir .. "/?.lua", tests_dir .. "/lib/?.lua", package.path }, ";")
end

setupPaths()
require("mock_koreader")

local OAuth = require("koassistant_openai_codex_oauth")
local TestRunner = require("test_runner"):new()

print("")
print(string.rep("=", 50))
print("  Unit Tests: OpenAI Codex OAuth")
print(string.rep("=", 50))

local function b64url(value)
    local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local bits = value:gsub(".", function(char)
        local byte, out = char:byte(), ""
        for i = 8, 1, -1 do
            out = out .. ((byte % 2^i - byte % 2^(i - 1) > 0) and "1" or "0")
        end
        return out
    end) .. "0000"
    local encoded = bits:gsub("%d%d%d?%d?%d?%d?", function(chunk)
        if #chunk < 6 then return "" end
        local index = 0
        for i = 1, 6 do
            if chunk:sub(i, i) == "1" then index = index + 2^(6 - i) end
        end
        return alphabet:sub(index + 1, index + 1)
    end)
    return encoded:gsub("%+", "-"):gsub("/", "_")
end

local function makeJwt(payload)
    return b64url('{"alg":"none"}') .. "." .. b64url(payload) .. ".sig"
end

TestRunner:test("user-code request matches OpenAI's Codex endpoint", function()
    local req = OAuth.buildUserCodeRequest()
    TestRunner:assertEqual(req.url, "https://auth.openai.com/api/accounts/deviceauth/usercode", "endpoint")
    TestRunner:assertEqual(req.headers["Content-Type"], "application/json", "content type")
    TestRunner:assertTrue(req.body:find('"client_id":"app_EMoamEEZ73f0CkXaXp7hrann"', 1, true) ~= nil, "client id")
end)

TestRunner:test("poll request carries device_auth_id and user_code", function()
    local req = OAuth.buildPollRequest("device_123", "ABCD-EFGH")
    TestRunner:assertTrue(req.body:find('"device_auth_id":"device_123"', 1, true) ~= nil, "device auth id")
    TestRunner:assertTrue(req.body:find('"user_code":"ABCD-EFGH"', 1, true) ~= nil, "user code")
    TestRunner:assertTrue(req.body:find("device_code", 1, true) == nil, "generic RFC device_code must not be sent")
end)

TestRunner:test("authorization-code exchange includes OpenAI-provided PKCE verifier", function()
    local req = OAuth.buildTokenExchangeRequest("auth_code", "pkce_verifier")
    TestRunner:assertTrue(req.body:find("grant_type=authorization_code", 1, true) ~= nil, "grant")
    TestRunner:assertTrue(req.body:find("code=auth_code", 1, true) ~= nil, "code")
    TestRunner:assertTrue(req.body:find("code_verifier=pkce_verifier", 1, true) ~= nil, "verifier")
    TestRunner:assertTrue(req.body:find("redirect_uri=https%3A%2F%2Fauth.openai.com%2Fdeviceauth%2Fcallback", 1, true) ~= nil, "redirect")
end)

TestRunner:test("refresh request preserves rotating-token compatibility", function()
    local req = OAuth.buildRefreshRequest("refresh_123")
    TestRunner:assertTrue(req.body:find("grant_type=refresh_token", 1, true) ~= nil, "grant")
    TestRunner:assertTrue(req.body:find("refresh_token=refresh_123", 1, true) ~= nil, "refresh token")
    TestRunner:assertTrue(req.body:find("redirect_uri", 1, true) == nil, "refresh omits redirect URI")
end)

TestRunner:test("JWT parser reads nested OpenAI auth claim", function()
    local token = makeJwt('{"exp":1893456000,"https://api.openai.com/auth":{"chatgpt_account_id":"acct_42"}}')
    local payload = OAuth.parseJwtPayload(token)
    TestRunner:assertEqual(payload.exp, 1893456000, "expiry")
    TestRunner:assertEqual(payload.chatgpt_account_id, "acct_42", "account id")
end)

TestRunner:test("JWT parser rejects malformed tokens", function()
    TestRunner:assertEqual(OAuth.parseJwtPayload("not-a-jwt"), nil, "bad token")
    TestRunner:assertEqual(OAuth.parseJwtPayload("a.b.c"), nil, "bad payload")
end)

TestRunner:test("token normalization derives expiry/account and keeps old refresh token", function()
    local token = makeJwt('{"exp":1893456000,"https://api.openai.com/auth":{"chatgpt_account_id":"acct_99"}}')
    local auth = OAuth.normalizeTokenSet({ access_token = token }, "old_refresh", 1000)
    TestRunner:assertEqual(auth.expires_at, 1893456000, "expiry")
    TestRunner:assertEqual(auth.chatgpt_account_id, "acct_99", "account")
    TestRunner:assertEqual(auth.refresh_token, "old_refresh", "fallback refresh")
end)

TestRunner:test("token normalization falls back to expires_in", function()
    local auth = OAuth.normalizeTokenSet({ access_token = "opaque", refresh_token = "r", expires_in = 3600, chatgpt_account_id = "acct" }, nil, 1000)
    TestRunner:assertEqual(auth.expires_at, 4600, "ttl converted")
end)

TestRunner:test("refresh decision honors expiry skew", function()
    TestRunner:assertTrue(OAuth.shouldRefresh(nil, 1000), "missing")
    TestRunner:assertTrue(OAuth.shouldRefresh({ access_token = "a", expires_at = 1299 }, 1000, 300), "inside skew")
    TestRunner:assertFalse(OAuth.shouldRefresh({ access_token = "a", expires_at = 1401 }, 1000, 300), "outside skew")
end)

TestRunner:test("async token refresh schedules subprocess and saves rotated tokens", function()
    local features = {
        openai_codex_oauth = {
            access_token = "expired_access",
            refresh_token = "old_refresh",
            expires_at = 1,
            chatgpt_account_id = "acct_old",
        },
    }
    local flushed = false
    local settings = {
        readSetting = function(_self, key) return key == "features" and features or nil end,
        saveSetting = function(_self, key, value) if key == "features" then features = value end end,
        flush = function() flushed = true end,
    }
    local pending
    OAuth._setAsyncRunnerForTests(function(request, callback)
        pending = { request = request, callback = callback }
        return 77
    end)

    local callback_auth, callback_err
    local pid = OAuth.resolveAccessTokenAsync(settings, function(auth, err)
        callback_auth, callback_err = auth, err
    end)
    TestRunner:assertEqual(pid, 77, "subprocess pid returned")
    TestRunner:assertEqual(callback_auth, nil, "callback waits for subprocess")
    TestRunner:assertTrue(pending.request.body:find("refresh_token=old_refresh", 1, true) ~= nil, "refresh request")

    local rotated_access = makeJwt('{"exp":1893456000,"https://api.openai.com/auth":{"chatgpt_account_id":"acct_new"}}')
    pending.callback({
        status_code = 200,
        body = string.format('{"access_token":"%s","refresh_token":"new_refresh"}', rotated_access),
    })
    TestRunner:assertEqual(callback_err, nil, "no refresh error")
    TestRunner:assertEqual(callback_auth.refresh_token, "new_refresh", "rotated refresh token")
    TestRunner:assertEqual(callback_auth.chatgpt_account_id, "acct_new", "new account claim")
    TestRunner:assertTrue(flushed, "refreshed credentials flushed")
    TestRunner:assertEqual(features.openai_codex_oauth.refresh_token, "new_refresh", "refreshed credentials saved")
    OAuth._setAsyncRunnerForTests(nil)
end)

TestRunner:test("polling treats 403/404 as pending and 429 as slow_down", function()
    TestRunner:assertEqual(OAuth.classifyPollResponse(403, "").status, "pending", "403")
    TestRunner:assertEqual(OAuth.classifyPollResponse(404, "").status, "pending", "404")
    TestRunner:assertEqual(OAuth.classifyPollResponse(429, "").status, "slow_down", "429")
end)

TestRunner:test("poll success requires authorization_code and code_verifier", function()
    local result = OAuth.classifyPollResponse(200, '{"authorization_code":"code","code_verifier":"verifier","code_challenge":"challenge"}')
    TestRunner:assertEqual(result.status, "authorized", "status")
    TestRunner:assertEqual(result.authorization_code, "code", "code")
    TestRunner:assertEqual(result.code_verifier, "verifier", "verifier")
    TestRunner:assertEqual(OAuth.classifyPollResponse(200, '{"authorization_code":"code"}').status, "error", "missing verifier")
end)

TestRunner:test("device dialog text displays URL code expiry and status", function()
    local text = OAuth.buildDeviceDialogText("ABCD-EFGH", "Not authorized yet.")
    TestRunner:assertTrue(text:find("Unofficial integration", 1, true) ~= nil, "unofficial warning")
    TestRunner:assertTrue(text:find("may stop working", 1, true) ~= nil, "breakage warning")
    TestRunner:assertTrue(text:find("https://auth.openai.com/codex/device", 1, true) ~= nil, "verification URL")
    TestRunner:assertTrue(text:find("ABCD-EFGH", 1, true) ~= nil, "device code")
    TestRunner:assertTrue(text:find("15 minutes", 1, true) ~= nil, "expiry guidance")
    TestRunner:assertTrue(text:find("Not authorized yet.", 1, true) ~= nil, "status")
end)

TestRunner:test("interactive connect waits for KOReader network gate", function()
    local previous = package.loaded["ui/network/manager"]
    local gate_calls = 0
    package.loaded["ui/network/manager"] = {
        runWhenConnected = function(_self, _callback)
            gate_calls = gate_calls + 1
            -- Deliberately do not invoke callback: no dialog or network request may start.
        end,
    }
    OAuth.startInteractiveConnect({ settings = {} })
    package.loaded["ui/network/manager"] = previous
    TestRunner:assertEqual(gate_calls, 1, "network gate")
end)

TestRunner:test("interactive flow keeps one device dialog and polls only on Check", function()
    local module_names = {
        "ui/network/manager", "ui/widget/buttondialog", "ui/widget/notification",
        "ui/widget/infomessage", "ui/uimanager", "device",
    }
    local previous = {}
    for _, name in ipairs(module_names) do previous[name] = package.loaded[name] end

    local shown, closed, pending, terminated = {}, {}, {}, {}
    local ffiutil = package.loaded["ffi/util"]
    local previous_terminate = ffiutil.terminateSubProcess
    ffiutil.terminateSubProcess = function(pid) terminated[#terminated + 1] = pid end
    package.loaded["ui/uimanager"] = {
        show = function(_self, widget) shown[#shown + 1] = widget end,
        close = function(_self, widget) closed[#closed + 1] = widget end,
        scheduleIn = function() end,
    }
    package.loaded["ui/widget/buttondialog"] = {
        new = function(_self, opts)
            function opts:setTitle(title) self.title = title end
            return opts
        end,
    }
    package.loaded["ui/widget/notification"] = { new = function(_self, opts) return opts end }
    package.loaded["ui/widget/infomessage"] = { new = function(_self, opts) return opts end }
    package.loaded["ui/network/manager"] = {
        runWhenConnected = function(_self, callback) callback() end,
    }
    package.loaded["device"] = {
        input = { setClipboardText = function() end },
    }

    OAuth._setAsyncRunnerForTests(function(request, callback)
        pending[#pending + 1] = { request = request, callback = callback }
        return 100 + #pending
    end)

    local settings = {
        readSetting = function() return {} end,
        saveSetting = function() end,
        flush = function() end,
    }
    OAuth.startInteractiveConnect({ settings = settings })
    TestRunner:assertEqual(#pending, 1, "only user-code request starts automatically")
    pending[1].callback({
        status_code = 200,
        body = '{"device_auth_id":"device_1","user_code":"ABCD-EFGH","interval":5}',
    })

    local device_dialog = shown[#shown]
    TestRunner:assertTrue(device_dialog.title:find("ABCD-EFGH", 1, true) ~= nil, "code shown")
    TestRunner:assertFalse(device_dialog.dismissable, "explicit Cancel required")
    TestRunner:assertEqual(#pending, 1, "no automatic authorization poll")

    device_dialog.buttons[1][2].callback()
    TestRunner:assertEqual(#pending, 2, "Check starts one poll")
    pending[2].callback({ status_code = 403, body = "" })
    TestRunner:assertEqual(shown[#shown], device_dialog, "same dialog remains visible")
    TestRunner:assertTrue(device_dialog.title:find("Not authorized yet", 1, true) ~= nil, "pending status")

    device_dialog.buttons[1][2].callback()
    device_dialog.buttons[1][2].callback()
    TestRunner:assertEqual(#pending, 3, "repeated tap cannot overlap a poll")
    device_dialog.buttons[2][1].callback()
    TestRunner:assertEqual(terminated[#terminated], 103, "Cancel terminates active poll")
    local shown_before_stale_callback = #shown
    pending[3].callback({ status_code = 403, body = "" })
    TestRunner:assertEqual(#shown, shown_before_stale_callback, "post-cancel callback ignored")

    OAuth._setAsyncRunnerForTests(nil)
    ffiutil.terminateSubProcess = previous_terminate
    for _, name in ipairs(module_names) do package.loaded[name] = previous[name] end
end)

return TestRunner:summary()
