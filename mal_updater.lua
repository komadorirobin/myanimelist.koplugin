local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local ltn12 = require("ltn12")
local rapidjson = require("rapidjson")
local socket = require("socket")
local http = require("socket.http")
local socketutil = require("socketutil")
local _ = require("gettext")

local Updater = {}
local API_URL = "https://api.github.com/repos/komadorirobin/myanimelist.koplugin/releases/latest"
local RELEASES_URL = "https://github.com/komadorirobin/myanimelist.koplugin/releases"
local CHECK_INTERVAL = 24 * 60 * 60
local checking = false

local function sq(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function versionParts(value)
    local parts = {}
    for part in tostring(value or "0"):gsub("^v", ""):gmatch("(%d+)") do
        parts[#parts + 1] = tonumber(part)
    end
    return parts
end

local function isNewer(candidate, installed)
    local a, b = versionParts(candidate), versionParts(installed)
    for index = 1, math.max(#a, #b) do
        local left, right = a[index] or 0, b[index] or 0
        if left ~= right then return left > right end
    end
    return false
end

local function installedVersion()
    local path = DataStorage:getDataDir() .. "/plugins/myanimelist.koplugin/_meta.lua"
    local ok, meta = pcall(dofile, path)
    return ok and meta and meta.version or "0.0.0"
end

local function request(url, sink)
    local request_spec = {
        url = url,
        method = "GET",
        headers = {
            ["Accept"] = "application/vnd.github+json",
            ["User-Agent"] = "KOReader-MyAnimeList-Updater",
        },
        sink = sink,
        redirect = true,
    }
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local ok, code = pcall(function() return socket.skip(1, http.request(request_spec)) end)
    socketutil:reset_timeout()
    if not ok or code ~= 200 then return nil, tostring(code or "network_error") end
    return true
end

local function latestRelease()
    local parts = {}
    local ok, err = request(API_URL, ltn12.sink.table(parts))
    if not ok then return nil, err end
    local decoded_ok, release = pcall(rapidjson.decode, table.concat(parts))
    if not decoded_ok or type(release) ~= "table" then return nil, "invalid_json" end
    local zip_url
    for _, asset in ipairs(release.assets or {}) do
        if asset.name == "myanimelist.koplugin.zip" or tostring(asset.name):match("%.zip$") then
            zip_url = asset.browser_download_url
            break
        end
    end
    if not zip_url then return nil, "release_has_no_zip" end
    return {
        version = tostring(release.tag_name or ""):gsub("^v", ""),
        zip_url = zip_url,
    }
end

local function extract(zip_path, destination)
    local ok_archiver, Archiver = pcall(require, "ffi/archiver")
    if not ok_archiver or not Archiver or not Archiver.Reader then
        return nil, "archive_extractor_unavailable"
    end
    local archive = Archiver.Reader:new()
    if not archive:open(zip_path) then
        local err = archive.err
        archive:close()
        return nil, tostring(err or "archive_open_failed")
    end
    local extract_err
    for entry in archive:iterate() do
        local relative = entry.path and entry.path:match("^[^/]+/(.+)$")
        if relative and relative ~= "" and not relative:find("../", 1, true)
                and relative:sub(1, 1) ~= "/" then
            if not archive:extractToPath(entry.path, destination .. "/" .. relative) then
                extract_err = archive.err or "archive_extract_failed"
                break
            end
        end
    end
    archive:close()
    if extract_err then return nil, tostring(extract_err) end
    return true
end

local function installRelease(release)
    local plugin_dir = DataStorage:getDataDir() .. "/plugins/myanimelist.koplugin"
    local parent = plugin_dir:match("^(.*)/[^/]+$")
    local zip_path = parent .. "/myanimelist-update.zip"
    local staging = plugin_dir .. ".update"
    local backup = plugin_dir .. ".bak"
    os.execute("rm -rf " .. sq(staging) .. " " .. sq(backup))
    local file = io.open(zip_path, "wb")
    if not file then return nil, "could_not_create_download" end
    local ok, err = request(release.zip_url, ltn12.sink.file(file))
    if not ok then pcall(os.remove, zip_path); return nil, err end
    if not lfs.mkdir(staging) and lfs.attributes(staging, "mode") ~= "directory" then
        pcall(os.remove, zip_path)
        return nil, "could_not_create_staging"
    end
    local extracted, extract_err = extract(zip_path, staging)
    pcall(os.remove, zip_path)
    if not extracted or lfs.attributes(staging .. "/main.lua", "mode") ~= "file" then
        os.execute("rm -rf " .. sq(staging))
        return nil, extract_err or "invalid_plugin_archive"
    end
    if not os.rename(plugin_dir, backup) then
        os.execute("rm -rf " .. sq(staging))
        return nil, "could_not_backup_plugin"
    end
    if not os.rename(staging, plugin_dir) then
        os.rename(backup, plugin_dir)
        os.execute("rm -rf " .. sq(staging))
        return nil, "could_not_install_plugin"
    end
    os.execute("rm -rf " .. sq(backup))
    return true
end

local function runWrapped(operation, label, callback, quiet)
    local function run()
        local completed, encoded = Trapper:dismissableRunInSubprocess(function()
            local result, err = operation()
            return rapidjson.encode({ result = result, error = err })
        end, quiet and {} or label, quiet == true)
        if not completed then return end
        local ok, response = pcall(rapidjson.decode, encoded or "")
        if not ok then callback(nil, "invalid_result") else callback(response.result, response.error) end
    end
    if Trapper:isWrapped() then return run() end
    return Trapper:wrap(run)
end

function Updater.check(plugin, interactive)
    if checking then return end
    local now = os.time()
    if not interactive and now - (tonumber(plugin.settings.update_last_check_at) or 0) < CHECK_INTERVAL then return end
    if not interactive and not NetworkMgr:isConnected() then return end
    checking = true
    NetworkMgr:runWhenOnline(function()
        runWrapped(latestRelease, _("Checking for MyAnimeList plugin updates..."), function(release, err)
            checking = false
            plugin.settings.update_last_check_at = os.time()
            plugin:saveSettings()
            if not release then
                if interactive then plugin:showInfo(_("Could not check for plugin updates: ") .. tostring(err)) end
                return
            end
            local current = installedVersion()
            if not isNewer(release.version, current) then
                if interactive then plugin:notify(_("MyAnimeList plugin is up to date.")) end
                return
            end
            local function prompt()
                UIManager:show(ConfirmBox:new{
                    text = string.format(_("MyAnimeList Manga Sync %s is available. Install it now?"), release.version),
                    ok_text = _("Update"),
                    ok_callback = function()
                        runWrapped(function() return installRelease(release) end,
                            _("Updating MyAnimeList plugin..."), function(installed, install_err)
                                if not installed then
                                    plugin:showInfo(_("Plugin update failed: ") .. tostring(install_err))
                                    return
                                end
                                UIManager:show(ConfirmBox:new{
                                    text = _("Plugin updated. Restart KOReader now?"),
                                    ok_text = _("Restart"),
                                    ok_callback = function() UIManager:restartKOReader() end,
                                })
                            end)
                    end,
                })
            end
            if interactive then prompt() else
                UIManager:show(Notification:new{
                    text = string.format(_("MyAnimeList plugin update available: %s"), release.version),
                    timeout = 4,
                })
            end
        end, not interactive)
    end)
end

Updater._test = { isNewer = isNewer }
Updater.RELEASES_URL = RELEASES_URL

return Updater
