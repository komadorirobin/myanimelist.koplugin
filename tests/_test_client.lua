package.path = "./?.lua;" .. package.path

local steps, requests, decoded, timeout_depth = {}, {}, {}, 0
package.loaded["socket.http"] = { request = function(request)
    requests[#requests + 1] = request
    local step = table.remove(steps, 1)
    assert(step, "unexpected HTTP request")
    if request.source then request.form = request.source() end
    if step.check then step.check(request) end
    if step.network_error then return nil, step.network_error end
    local key = tostring(#requests)
    decoded[key] = step.body or {}
    request.sink(key)
    return 1, step.code or 200, {}, "HTTP response"
end }
package.loaded.ltn12 = {
    sink = { table = function(target) return function(chunk) target[#target + 1] = chunk; return 1 end end },
    source = { string = function(value) return function() local body = value; value = nil; return body end end },
}
package.loaded.rapidjson = { decode = function(value) return assert(decoded[value]) end }
package.loaded.socket = { skip = function(n, ...) return select(n + 1, ...) end }
package.loaded.socketutil = {
    set_timeout = function() timeout_depth = timeout_depth + 1 end,
    reset_timeout = function() timeout_depth = timeout_depth - 1 end,
}
package.loaded.util = { urlEncode = function(value)
    return value:gsub("[^%w%-._~]", function(char) return string.format("%%%02X", char:byte()) end)
end }
local Client = require("mal_client")
local now = os.time()
local passed = 0
local function eq(actual, expected)
    assert(actual == expected, "expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function test(name, fn)
    steps, requests, decoded = {}, {}, {}
    fn()
    eq(#steps, 0)
    eq(timeout_depth, 0)
    passed = passed + 1
    print("PASS " .. name)
end
local function config()
    return { client_id = "test-client", client_secret = "test-secret", access_token = "old-access",
        refresh_token = "old-refresh", access_expires_at = now + 3600 }
end
local function token()
    return { access_token = "new-access", refresh_token = "new-refresh", expires_in = 3600 }
end
local function checkRefresh(request)
    eq(request.method, "POST")
    eq(request.url, "https://myanimelist.net/v1/oauth2/token")
    eq(request.headers.Authorization, nil)
    eq(request.form, "client_id=test-client&client_secret=test-secret&grant_type=refresh_token&refresh_token=old-refresh")
end
local function checkBearer(value)
    return function(request) eq(request.headers.Authorization, "Bearer " .. value) end
end

test("search renews an expired token before requesting manga", function()
    local settings = config(); settings.access_expires_at = now - 1
    steps = { { body = token(), check = checkRefresh },
        { body = { data = { { node = { id = 42 } } } }, check = checkBearer("new-access") } }
    local client = Client.new(Client.configFromSettings(settings))
    local body = assert(client:searchManga("The Summer Hikaru Died"))
    eq(body.data[1].node.id, 42)
    assert(requests[2].url:find("/manga?", 1, true))
    eq(settings.access_token, "old-access")
    local result = client:sessionResult({})
    assert(Client.applyToken(settings, result.token))
    eq(settings.access_token, "new-access")
    eq(settings.refresh_token, "new-refresh")
    eq(settings.access_expires_at, result.token.access_expires_at)
end)

test("a fresh saved token still recovers from the pictured invalid_token error", function()
    steps = { { code = 401, body = { error = "invalid_token" }, check = checkBearer("old-access") },
        { body = token(), check = checkRefresh },
        { body = { data = {} }, check = checkBearer("new-access") } }
    assert(Client.new(config()):searchManga("Dementia 21"))
    eq(requests[1].url, requests[3].url)
end)

test("known fresh tokens do not refresh on every search", function()
    steps = { { body = { data = {} }, check = checkBearer("old-access") } }
    local client = Client.new(config())
    assert(client:searchManga("Dogsred"))
    eq(client:sessionResult({}).token, nil)
end)

test("a second rejection stops after one renewal and requests authorization", function()
    steps = { { code = 401 }, { body = token() }, { code = 401 } }
    local client = Client.new(config())
    local body, err = client:searchManga("Dr. Stone")
    eq(body, nil); eq(err, "authorization_required")
    local result = client:sessionResult({})
    eq(result.authorization_required, true)
    eq(result.token.refresh_token, "new-refresh")
    body, err = client:getManga(42)
    eq(err, "authorization_required"); eq(#requests, 3)
end)

test("preemptive renewal does not start another refresh loop on rejection", function()
    local settings = config(); settings.access_expires_at = 0
    steps = { { body = token() }, { code = 401 } }
    local client = Client.new(settings)
    local body, err = client:searchManga("Book")
    eq(body, nil); eq(err, "authorization_required"); eq(#requests, 2)
end)

test("invalid refresh credentials require reconnecting but are not erased", function()
    for code_index, code in ipairs({ 400, 401 }) do
        local settings = config(); settings.access_expires_at = 0
        steps = { { code = code, body = { error = "invalid_grant" } } }
        local client = Client.new(settings)
        local body, err = client:searchManga("Book")
        eq(body, nil); eq(err, "authorization_required")
        eq(settings.access_token, "old-access"); eq(settings.refresh_token, "old-refresh")
        eq(Client.accountState(settings), "authorization_required")
    end
end)

test("temporary refresh errors preserve credentials and do not repeat across a batch", function()
    for error_index, failure in ipairs({ { network_error = "timeout" }, { code = 429 }, { code = 503 } }) do
        requests = {}
        steps = { failure }
        local settings = config(); settings.access_expires_at = 0
        local client = Client.new(settings)
        local body, err = client:getManga(1)
        eq(body, nil); assert(err ~= "authorization_required")
        client:getManga(2)
        eq(#requests, 1)
        eq(client:sessionResult({}).authorization_required, false)
        eq(settings.access_token, "old-access"); eq(settings.refresh_token, "old-refresh")
    end
end)

test("new tokens survive a subsequent non-auth API error", function()
    steps = { { code = 401 }, { body = token() }, { code = 400, body = { error = "invalid_query" } } }
    local client = Client.new(config())
    local body, err = client:searchManga("x")
    eq(body, nil); eq(err, "invalid_query")
    local result = client:sessionResult({})
    eq(result.token.access_token, "new-access"); eq(result.authorization_required, false)
end)

test("public client-ID searches still work without an OAuth token", function()
    steps = { { body = { data = {} }, check = function(request)
        eq(request.headers.Authorization, nil); eq(request.headers["X-MAL-CLIENT-ID"], "test-client")
    end } }
    assert(Client.new{ client_id = "test-client", access_token = "" }:searchManga("Book"))
end)

test("missing refresh tokens give an actionable error after rejection", function()
    local settings = config(); settings.refresh_token = nil
    steps = { { code = 401 } }
    local client = Client.new(settings)
    local body, err = client:searchManga("Book")
    eq(body, nil); eq(err, "authorization_required")
    eq(client:sessionResult({}).authorization_required, true)
end)

test("detail requests and progress writes both renew and retry once", function()
    steps = { { code = 401 }, { body = token() }, { body = { id = 42 } } }
    assert(Client.new(config()):getManga(42))
    eq(requests[1].method, "GET")
    requests = {}
    steps = { { code = 401 }, { body = token() }, { body = { num_volumes_read = 7 } } }
    local updated = assert(Client.new(config()):updateManga(42, { volumes_read = 7, status = "reading" }))
    eq(updated.num_volumes_read, 7)
    eq(requests[1].method, "PUT"); eq(requests[3].method, "PUT")
    eq(requests[1].form, "num_volumes_read=7&status=reading")
    eq(requests[1].form, requests[3].form)
end)

test("malformed token responses cannot replace working credentials", function()
    local settings = config(); settings.access_expires_at = 0
    steps = { { body = { access_token = "", refresh_token = "invalid" } } }
    local client = Client.new(settings)
    local body, err = client:searchManga("Book")
    eq(body, nil); eq(err, "invalid_token_response")
    eq(settings.access_token, "old-access"); eq(settings.refresh_token, "old-refresh")
    eq(client:sessionResult({}).token, nil)
end)

test("an omitted refresh token retains the previous one and expiry survives delivery delay", function()
    local settings = config(); settings.authorization_required = true
    assert(Client.applyToken(settings, { access_token = "renewed", access_expires_at = now + 90 }))
    eq(settings.refresh_token, "old-refresh"); eq(settings.access_expires_at, now + 90)
    eq(settings.authorization_required, nil)
    eq(Client.accountState(settings), "connected")
    settings.access_expires_at = 0; eq(Client.accountState(settings), "renewal_needed")
    settings.access_token = nil; eq(Client.accountState(settings), "not_connected")
end)

test("non-auth failures do not renew tokens or request login", function()
    steps = { { code = 503, body = { error = "unavailable" } } }
    local client = Client.new(config())
    local body, err = client:getManga(42)
    eq(body, nil); eq(err, "unavailable")
    eq(client:sessionResult({}).authorization_required, false)
end)

print("client authentication tests passed: " .. passed)
