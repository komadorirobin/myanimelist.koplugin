local http = require("socket.http")
local ltn12 = require("ltn12")
local rapidjson = require("rapidjson")
local socket = require("socket")
local socketutil = require("socketutil")
local util = require("util")
local Core = require("mal_core")

local Client = {}
Client.__index = Client

local API_BASE = "https://api.myanimelist.net/v2"
local TOKEN_URL = "https://myanimelist.net/v1/oauth2/token"
local AUTHORIZE_URL = "https://myanimelist.net/v1/oauth2/authorize"

local function formEncode(values)
    local keys = {}
    for key, value in pairs(values or {}) do
        if value ~= nil and value ~= "" then keys[#keys + 1] = key end
    end
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do
        parts[#parts + 1] = util.urlEncode(tostring(key)) .. "=" .. util.urlEncode(tostring(values[key]))
    end
    return table.concat(parts, "&")
end

local function decode(parts)
    local raw = table.concat(parts or {})
    if raw == "" then return {} end
    local ok, body = pcall(rapidjson.decode, raw)
    if not ok or type(body) ~= "table" then
        return nil, "invalid_json"
    end
    return body
end

function Client.new(config)
    return setmetatable({ config = config or {} }, Client)
end

function Client.authorizationUrl(config)
    return AUTHORIZE_URL .. "?" .. formEncode({
        response_type = "code",
        client_id = config.client_id,
        redirect_uri = config.redirect_uri,
        code_challenge = config.pkce_verifier,
        code_challenge_method = "plain",
        state = config.oauth_state,
    })
end

function Client:_request(method, url, opts)
    opts = opts or {}
    local sink = {}
    local headers = {
        ["Accept"] = "application/json",
        ["User-Agent"] = "KOReader-MyAnimeList/1.4.4",
    }
    if self.config.client_id then headers["X-MAL-CLIENT-ID"] = self.config.client_id end
    if opts.authorized and self.config.access_token then
        headers["Authorization"] = "Bearer " .. self.config.access_token
    end
    local body
    if opts.form then
        body = formEncode(opts.form)
        headers["Content-Type"] = "application/x-www-form-urlencoded"
        headers["Content-Length"] = #body
    end
    local request = {
        url = url,
        method = method,
        headers = headers,
        sink = ltn12.sink.table(sink),
        redirect = true,
    }
    if body then request.source = ltn12.source.string(body) end
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local ok, code, response_headers, status = pcall(function()
        return socket.skip(1, http.request(request))
    end)
    socketutil:reset_timeout()
    if not ok then return nil, tostring(code or "network_error") end
    if type(code) ~= "number" then return nil, tostring(status or code or "network_error") end
    local decoded, decode_err = decode(sink)
    if not decoded then return nil, decode_err, code end
    if code < 200 or code >= 300 then
        local message = decoded.message or decoded.error_description or decoded.error or ("HTTP " .. tostring(code))
        if decoded.hint and decoded.hint ~= "" then
            message = message .. " (" .. tostring(decoded.hint) .. ")"
        end
        return nil, message, code, decoded
    end
    return decoded, nil, code, response_headers
end

function Client:exchangeCode(code)
    return self:_request("POST", TOKEN_URL, {
        form = Core.authorizationCodeForm(self.config, code),
    })
end

function Client:refreshToken()
    return self:_request("POST", TOKEN_URL, {
        form = {
            client_id = self.config.client_id,
            client_secret = self.config.client_secret,
            grant_type = "refresh_token",
            refresh_token = self.config.refresh_token,
        },
    })
end

function Client:searchManga(query)
    local url = API_BASE .. "/manga?" .. formEncode({
        q = query,
        limit = 10,
        fields = "id,title,alternative_titles,start_date,media_type,status,num_volumes,num_chapters,mean,my_list_status",
    })
    return self:_request("GET", url, { authorized = self.config.access_token ~= nil })
end

function Client:getManga(id)
    local url = API_BASE .. "/manga/" .. tostring(id) .. "?" .. formEncode({
        fields = "id,title,alternative_titles,media_type,status,num_volumes,num_chapters,mean,my_list_status",
    })
    return self:_request("GET", url, { authorized = true })
end

function Client:updateManga(id, progress)
    return self:_request("PUT", API_BASE .. "/manga/" .. tostring(id) .. "/my_list_status", {
        authorized = true,
        form = {
            status = progress.status,
            num_volumes_read = progress.volumes_read,
        },
    })
end

function Client._formEncode(values) return formEncode(values) end

return Client
