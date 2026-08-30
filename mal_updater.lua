local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
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

local function safeArchivePath(path)
    path = tostring(path or "")
    if path == "" or path:sub(1, 1) == "/" or path:find("\\", 1, true) then return false end
    local first
    for part in path:gmatch("[^/]+") do
        first = first or part
        if part == ".." then return false end
    end
    return first == "myanimelist.koplugin"
end

-- KOReader removed Device:unpackArchive in July 2026. Prefer the core
-- libarchive reader and retain the old helper only for older releases.
local function extractArchive(zip_path, parent)
    local has_archiver, Archiver = pcall(require, "ffi/archiver")
    if has_archiver and type(Archiver) == "table" and Archiver.Reader then
        local arc = Archiver.Reader:new()
        if not arc:open(zip_path) then
            local open_err = arc.err
            arc:close()
            return nil, tostring(open_err or "could_not_open_archive")
        end
        local extracted_any = false
        local extract_err
        for entry in arc:iterate() do
            if not safeArchivePath(entry.path) then
                extract_err = "unsafe_archive_path"
                break
            end
            if not arc:extractToPath(entry.path, parent .. "/" .. entry.path) then
                extract_err = tostring(arc.err or "archive_extract_failed")
                break
            end
            extracted_any = true
        end
        if not extract_err and arc.err then extract_err = tostring(arc.err) end
        arc:close()
        if extract_err then return nil, extract_err end
        if not extracted_any then return nil, "empty_archive" end
        return true
    end

    if type(Device.unpackArchive) == "function" then
        local ok, err = Device:unpackArchive(zip_path, parent, false)
        if ok then return true end
        return nil, tostring(err or "archive_extract_failed")
    end
    return nil, "archive_extractor_unavailable"
end

local function installRelease(release)
    local plugin_dir = DataStorage:getDataDir() .. "/plugins/myanimelist.koplugin"
    local parent = plugin_dir:match("^(.*)/[^/]+$")
    local zip_path = parent .. "/myanimelist-update.zip"
    pcall(os.remove, zip_path)
    local file = io.open(zip_path, "wb")
    if not file then
        return { success = false, stage = "download", err = "could_not_create_download" }
    end
    local ok, err = request(release.zip_url, ltn12.sink.file(file))
    pcall(function() file:close() end)
    if not ok then
        pcall(os.remove, zip_path)
        return { success = false, stage = "download", err = err }
    end

    local extracted, extract_err = extractArchive(zip_path, parent)
    pcall(os.remove, zip_path)
    if not extracted then
        return { success = false, stage = "extract", err = extract_err or "archive_extract_failed" }
    end

    local ok_meta, meta = pcall(dofile, plugin_dir .. "/_meta.lua")
    local main_file = io.open(plugin_dir .. "/main.lua", "rb")
    if main_file then main_file:close() end
    if not main_file or not ok_meta or not meta or tostring(meta.version) ~= tostring(release.version) then
        return { success = false, stage = "verify", err = "installed_version_mismatch" }
    end
    return { success = true }
end

local function runTask(operation, label, callback, quiet)
    local function protectedOperation()
        local ok, result = xpcall(operation, debug.traceback)
        if ok then return result end
        return {
            success = false,
            error = tostring(result),
            stage = "internal",
            err = tostring(result),
        }
    end

    local function run()
        local trap_widget = label
        if quiet then trap_widget = false end
        local completed, result = Trapper:dismissableRunInSubprocess(
            protectedOperation,
            trap_widget,
            false
        )
        if not completed then
            result = { error = "operation_cancelled", stage = "cancelled", err = "operation_cancelled" }
        elseif result == nil then
            result = {
                success = false,
                error = "subprocess_returned_no_result",
                stage = "subprocess",
                err = "subprocess_returned_no_result",
            }
        end
        -- Leave the Trapper coroutine before opening dialogs or starting another task.
        UIManager:scheduleIn(0.1, function() callback(result) end)
    end

    if Trapper:isWrapped() then
        UIManager:scheduleIn(0.1, function() Trapper:wrap(run) end)
    else
        Trapper:wrap(run)
    end
end

function Updater.check(plugin, interactive)
    if checking then return end
    local now = os.time()
    if not interactive and now - (tonumber(plugin.settings.update_last_check_at) or 0) < CHECK_INTERVAL then return end
    if not interactive and not NetworkMgr:isConnected() then return end
    checking = true
    NetworkMgr:runWhenOnline(function()
        runTask(function()
            local release, err = latestRelease()
            return release or { error = err }
        end, _("Checking for MyAnimeList plugin updates..."), function(release)
            checking = false
            plugin.settings.update_last_check_at = os.time()
            plugin:saveSettings()
            if not release or release.error then
                if interactive then
                    plugin:showInfo(_("Could not check for plugin updates: ")
                        .. tostring(release and release.error or "unknown_error"))
                end
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
                        UIManager:scheduleIn(0.1, function()
                            runTask(
                                function() return installRelease(release) end,
                                _("Updating MyAnimeList plugin..."),
                                function(result)
                                    if not result or not result.success then
                                        local stage = result and result.stage or "unknown"
                                        local install_err = result and result.err or "unknown_error"
                                        plugin:showInfo(string.format(
                                            _("Plugin update failed during %s: %s"),
                                            tostring(stage), tostring(install_err)))
                                        return
                                    end
                                    UIManager:show(ConfirmBox:new{
                                        text = _("Plugin updated. Restart KOReader now?"),
                                        ok_text = _("Restart"),
                                        ok_callback = function() UIManager:restartKOReader() end,
                                    })
                                end
                            )
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

Updater._test = {
    extractArchive = extractArchive,
    isNewer = isNewer,
    runTask = runTask,
}
Updater.RELEASES_URL = RELEASES_URL

return Updater
