package.path = "./?.lua;" .. package.path

local Widget = {}
function Widget:extend(values) return setmetatable(values or {}, { __index = self }) end
function Widget:new(values) return self:extend(values) end
function Widget:getInputText() return self.input end
function Widget:onShowKeyboard() end
for name_index, name in ipairs({ "ui/widget/buttondialog", "ui/widget/checkbutton", "ui/widget/confirmbox",
        "ui/widget/infomessage", "ui/widget/inputdialog", "ui/widget/multiinputdialog",
        "ui/widget/notification", "ui/widget/container/widgetcontainer" }) do
    package.loaded[name] = Widget
end
for name_index, name in ipairs({ "device", "dispatcher", "docsettings", "socket.http", "ltn12",
        "socket", "socketutil", "util", "libs/libkoreader-lfs", "mal_updater" }) do
    package.loaded[name] = {}
end
package.loaded.gettext = function(text) return text end
package.loaded.util.urlEncode = function(value)
    return value:gsub("[^%w%-._~]", function(char) return string.format("%%%02X", char:byte()) end)
end
package.loaded["ui/network/manager"] = { isConnected = function() return true end }
local tasks, shown, messages, encoded, saves = {}, {}, {}, {}, 0
local UI = { scheduleIn = function(self, delay, fn) tasks[#tasks + 1] = fn end,
    show = function(self, widget) shown[#shown + 1] = widget end,
    close = function() end }
package.loaded["ui/uimanager"] = UI
local Trapper = { isWrapped = function() return false end,
    wrap = function(self, fn) fn() end,
    dismissableRunInSubprocess = function(self, operation)
        if self.cancel_next then self.cancel_next = false; return false end
        return true, operation()
    end }
package.loaded["ui/trapper"] = Trapper
package.loaded.rapidjson = { encode = function(value)
    local key = tostring(#encoded + 1); encoded[#encoded + 1] = value; return key
end, decode = function(value) return assert(encoded[tonumber(value)]) end }
G_reader_settings = { saveSetting = function() saves = saves + 1 end, flush = function() end }

local Client = require("mal_client")
local Plugin = dofile("main.lua")
local passed = 0
local function eq(actual, expected)
    assert(actual == expected, "expected " .. tostring(expected) .. ", got " .. tostring(actual)
        .. "\n" .. tostring(messages[#messages] or ""))
end
local function drain()
    local n = 0
    while #tasks > 0 do
        n = n + 1; assert(n < 100, "UI queue did not settle")
        table.remove(tasks, 1)()
    end
end
local function test(name, fn)
    tasks, shown, messages, encoded, saves = {}, {}, {}, {}, 0
    Trapper.cancel_next = false
    fn()
    drain()
    passed = passed + 1
    print("PASS " .. name)
end
local function plugin()
    local p = Plugin:extend{ settings = {
        client_id = "client", client_secret = "secret", access_token = "old-access",
        refresh_token = "old-refresh", access_expires_at = os.time() + 3600,
        mappings = { series = { series_name = "Series", mal_id = 42 } }, pending_links = { new = {} },
        queue = { series = { series_key = "series", mal_id = 42, volumes_read = 2 } },
    } }
    function p:showInfo(text) messages[#messages + 1] = text end
    p.notify = p.showInfo
    return p
end
local function menuState(p)
    local menu = {}; p:addToMainMenu(menu)
    return menu.myanimelist.sub_item_table[1].text_func()
end
local function search(p)
    p:_searchSeries("series", "Series")
    shown[#shown].buttons[1][2].callback()
end
local function rotation()
    return { access_token = "new-access", refresh_token = "new-refresh", expires_in = 3600 }
end

test("the real search dialog renews auth and persists it before showing results", function()
    local p, calls = plugin(), 0
    Client._request = function(client, method, url)
        calls = calls + 1
        if calls == 1 then return nil, "invalid_token", 401 end
        if calls == 2 then
            eq(client.config.client_secret, "secret"); eq(client.config.refresh_token, "old-refresh")
            return rotation()
        end
        eq(client.config.access_token, "new-access")
        return { data = { { node = { id = 42 } } } }
    end
    function p:_showSearchResults(key, label, results)
        eq(self.settings.refresh_token, "new-refresh"); assert(saves > 0)
        eq(key, "series"); eq(results[1].node.id, 42)
        self.results_shown = true
    end
    search(p); drain()
    eq(calls, 3); eq(p.results_shown, true)
    eq(menuState(p), "Account: connected")
end)

test("a rejected session changes the menu and retains all links and queued progress", function()
    local p = plugin()
    local mappings, queue, pending = p.settings.mappings, p.settings.queue, p.settings.pending_links
    p.settings.access_expires_at = 0
    eq(menuState(p), "Account: token renewal pending")
    Client._request = function() return nil, "invalid_grant", 400 end
    search(p); drain()
    eq(menuState(p), "Account: authorization required")
    eq(p:isAuthorized(), false)
    eq(p.settings.mappings, mappings); eq(p.settings.queue, queue); eq(p.settings.pending_links, pending)
    eq(queue.series.volumes_read, 2)
    assert(messages[#messages]:find("Start authorization", 1, true))
end)

test("account workers serialize and use the previously persisted token", function()
    local p, clients, delivered = plugin(), {}, 0
    p:_runAccountOperation(function(client)
        clients[#clients + 1] = client.config.access_token
        Client.applyToken(client.config, rotation())
        client.token_result = rotation()
        return {}
    end, "first", function() delivered = delivered + 1 end)
    p:_runAccountOperation(function(client)
        clients[#clients + 1] = client.config.access_token
        return {}
    end, "second", function() delivered = delivered + 1 end)
    eq(#clients, 1); eq(delivered, 0)
    drain()
    eq(#clients, 2); eq(clients[1], "old-access"); eq(clients[2], "new-access")
    eq(delivered, 2); eq(p._subprocess_running, false)
end)

test("FileManager and ReaderUI instances share the account operation queue", function()
    local manager, reader, next_ran = plugin(), plugin(), false
    reader.settings = manager.settings
    manager:_runAccountOperation(function(client)
        client.token_result = rotation()
        return {}
    end, "manager", function() end)
    reader:_runAccountOperation(function(client)
        eq(client.config.refresh_token, "new-refresh")
        next_ran = true
        return {}
    end, "reader", function() end)
    eq(next_ran, false)
    drain(); eq(next_ran, true)
end)

test("a UI exception cannot lose refreshed credentials or stall the next worker", function()
    local p, next_ran = plugin(), false
    p:_runAccountOperation(function(client)
        client.token_result = rotation()
        return {}
    end, "first", function() error("simulated UI exception") end)
    p:_runAccountOperation(function(client)
        eq(client.config.refresh_token, "new-refresh"); next_ran = true
        return {}
    end, "second", function() end)
    drain()
    eq(next_ran, true); eq(p._subprocess_running, false)
    eq(p.settings.access_token, "new-access")
end)

test("a worker exception after renewal still returns the new credentials", function()
    local p = plugin()
    p:_runAccountOperation(function(client)
        client.token_result = rotation()
        error("simulated post-refresh exception")
    end, "first", function(result)
        assert(result.error:find("post-refresh", 1, true))
        eq(p.settings.refresh_token, "new-refresh")
    end)
    drain(); eq(p.settings.access_token, "new-access")
end)

test("cancellation releases the queue without clearing credentials or reading data", function()
    local p, ran = plugin(), false
    Trapper.cancel_next = true
    p:_runAccountOperation(function() error("cancelled worker ran") end, "cancel", function(result, err)
        eq(result, nil); eq(err, "operation_interrupted")
    end)
    p:_runAccountOperation(function() ran = true; return {} end, "next", function() end)
    drain(); eq(ran, true); eq(p.settings.access_token, "old-access")
    eq(p.settings.queue.series.volumes_read, 2)
end)

test("disconnect discards pending tokens and prevents queued work from reviving the account", function()
    local p, skipped = plugin(), false
    p:_runAccountOperation(function(client) client.token_result = rotation(); return {} end,
        "first", function(result, err) eq(result, nil); eq(err, "account_changed") end)
    p:_runAccountOperation(function() error("stale account worker ran") end,
        "queued", function(result, err) eq(result, nil); eq(err, "account_changed"); skipped = true end)
    p:disconnect(); drain()
    eq(skipped, true); eq(p.settings.access_token, nil); eq(p.settings.refresh_token, nil)
    eq(p.settings.queue.series.volumes_read, 2); eq(menuState(p), "Account: not connected")
end)

test("disconnecting from another instance also invalidates pending account results", function()
    local manager, reader = plugin(), plugin()
    reader.settings = manager.settings
    manager:_runAccountOperation(function(client)
        client.token_result = rotation()
        return {}
    end, "manager", function(result, err) eq(result, nil); eq(err, "account_changed") end)
    reader:disconnect(); drain()
    eq(manager.settings.access_token, nil)
end)

test("a search error after renewal still saves the rotated refresh token", function()
    local p, calls = plugin(), 0
    p.settings.access_expires_at = 0
    Client._request = function()
        calls = calls + 1
        if calls == 1 then return rotation() end
        return nil, "invalid_query", 400
    end
    search(p); drain()
    eq(p.settings.refresh_token, "new-refresh")
    eq(p.settings.authorization_required, nil)
    assert(messages[#messages]:find("invalid_query", 1, true))
end)

test("temporary renewal failure after invalid_token marks renewal pending, not disconnected", function()
    local p, calls = plugin(), 0
    Client._request = function()
        calls = calls + 1
        if calls == 1 then return nil, "invalid_token", 401 end
        return nil, "timeout"
    end
    search(p); drain()
    eq(menuState(p), "Account: token renewal pending")
    eq(p.settings.access_token, "old-access"); eq(p.settings.refresh_token, "old-refresh")
    eq(p.settings.authorization_required, nil)
end)

test("successful browser reauthorization clears the warning without deleting links", function()
    local p = plugin()
    p.settings.authorization_required = true
    p.settings.pkce_verifier = "verifier"
    local mappings, queue = p.settings.mappings, p.settings.queue
    function p:_scheduleSync() self.sync_scheduled = true end
    Client._request = function(client, method, url, opts)
        eq(opts.form.grant_type, "authorization_code")
        return rotation()
    end
    p:finishAuthorization()
    local dialog = shown[#shown]
    dialog.input = "test-code"
    dialog.buttons[1][2].callback()
    drain()
    eq(menuState(p), "Account: connected"); eq(p.settings.pkce_verifier, nil)
    eq(p.settings.mappings, mappings); eq(p.settings.queue, queue)
    eq(p.sync_scheduled, true)
end)

test("ratings refresh uses auth recovery without altering reading progress", function()
    local p, calls = plugin(), 0
    Client._request = function()
        calls = calls + 1
        if calls == 1 then return nil, "invalid_token", 401 end
        if calls == 2 then return rotation() end
        return { mean = 8.2, num_volumes = 10 }
    end
    p:refreshRatings(true); drain()
    eq(p.settings.mappings.series.mal_mean, 8.2)
    eq(p.settings.refresh_token, "new-refresh")
    eq(p.settings.queue.series.volumes_read, 2); eq(p._ratings_running, false)
end)

test("progress PUT rejection recovers while retaining the intended volume count", function()
    local p, calls, updates = plugin(), 0, 0
    Client._request = function(client, method, url, opts)
        calls = calls + 1
        if method == "GET" then return { num_volumes = 10, my_list_status = { num_volumes_read = 1, status = "reading" } } end
        if method == "POST" then return rotation() end
        eq(opts.form.num_volumes_read, 2); updates = updates + 1
        if updates == 1 then return nil, "invalid_token", 401 end
        return { num_volumes_read = 2, status = "reading" }
    end
    p:syncQueue(true); drain()
    eq(calls, 4); eq(updates, 2); eq(p.settings.queue.series, nil)
    eq(p.settings.mappings.series.last_synced, 2)
    eq(p.settings.refresh_token, "new-refresh"); eq(p._sync_running, false)
end)

test("failed authentication and transient refresh errors never discard queued updates", function()
    for code_index, code in ipairs({ 400, 503 }) do
        local p = plugin(); p.settings.access_expires_at = 0
        Client._request = function() return nil, "refresh_error", code end
        p:syncQueue(true); drain()
        eq(p.settings.queue.series.volumes_read, 2)
        eq(p.settings.mappings.series.last_synced, nil)
        eq(p.settings.authorization_required == true, code == 400)
        eq(p._sync_running, false)
    end
end)

print("account workflow tests passed: " .. passed)
