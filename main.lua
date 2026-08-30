local ButtonDialog = require("ui/widget/buttondialog")
local CheckButton = require("ui/widget/checkbutton")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Dispatcher = require("dispatcher")
local DocSettings = require("docsettings")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local rapidjson = require("rapidjson")
local _ = require("gettext")
local unpack = unpack or table.unpack

local Client = require("mal_client")
local Core = require("mal_core")
local Hooks = require("mal_hooks")
local Scanner = require("mal_scanner")

local PLUGIN_VERSION = "1.3.0"
local DEFAULT_MANGA_ROOT = "/storage/emulated/0/ePubs/Manga"

local MyAnimeList = WidgetContainer:extend{
    name = "myanimelist",
    is_doc_only = false,
}

local defaults = {
    client_id = nil,
    client_secret = nil,
    redirect_uri = "https://myanimelist.net/",
    access_token = nil,
    refresh_token = nil,
    access_expires_at = 0,
    pkce_verifier = nil,
    oauth_state = nil,
    auto_sync = true,
    manga_root = DEFAULT_MANGA_ROOT,
    mappings = {},
    pending_links = {},
    queue = {},
}

local function copyDefaults(settings)
    settings = type(settings) == "table" and settings or {}
    for key, value in pairs(defaults) do
        if settings[key] == nil then
            settings[key] = type(value) == "table" and {} or value
        end
    end
    return settings
end

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function basename(path)
    return tostring(path or ""):gsub("/+$", ""):match("([^/]+)$")
end

local function dirname(path)
    return tostring(path or ""):match("^(.*)/[^/]+$")
end

local function count(values)
    local total = 0
    for _ in pairs(values or {}) do total = total + 1 end
    return total
end

local function envelope(value)
    local ok, encoded = pcall(rapidjson.encode, value)
    if ok then return encoded end
    return '{"error":"result_encode_failed"}'
end

local function decodeEnvelope(value)
    if type(value) ~= "string" then return nil, "no_result" end
    local ok, decoded = pcall(rapidjson.decode, value)
    if not ok or type(decoded) ~= "table" then return nil, "invalid_result" end
    return decoded
end

function MyAnimeList:init()
    self.settings = copyDefaults(G_reader_settings:readSetting("myanimelist", defaults))
    self._recent_events = {}
    self._sync_scheduled = false
    self._sync_running = false
    self._finished_scan_queue = {}
    self._finished_scan_running = false
    Hooks.install(self)
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function MyAnimeList:saveSettings()
    G_reader_settings:saveSetting("myanimelist", self.settings)
    G_reader_settings:flush()
end

function MyAnimeList:isAuthorized()
    return trim(self.settings.client_id) ~= "" and trim(self.settings.access_token) ~= ""
end

function MyAnimeList:notify(text, timeout)
    UIManager:show(Notification:new{ text = text, timeout = timeout or 3 })
end

function MyAnimeList:showInfo(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout or 4 })
end

function MyAnimeList:onDispatcherRegisterActions()
    Dispatcher:registerAction("myanimelist_sync_pending", {
        category = "none",
        event = "MyAnimeListSyncPending",
        title = _("MyAnimeList: sync pending manga"),
        general = true,
    })
end

function MyAnimeList:onMyAnimeListSyncPending()
    self:syncQueue(true)
end

function MyAnimeList:_readStatus(file)
    local ok, ds = pcall(DocSettings.open, DocSettings, file)
    if not ok or not ds then return nil end
    local summary = ds:readSetting("summary")
    pcall(function() ds:close() end)
    return type(summary) == "table" and summary.status or nil
end

function MyAnimeList:_isMangaPath(file)
    local normalized = tostring(file or ""):gsub("\\", "/"):lower()
    local root = trim(self.settings.manga_root):gsub("\\", "/"):lower():gsub("/+$", "")
    if root ~= "" and normalized:sub(1, #root + 1) == root .. "/" then return true end
    return normalized:find("/manga/", 1, true) ~= nil
end

function MyAnimeList:_isMangaFolder(path)
    local normalized = tostring(path or ""):gsub("\\", "/"):lower():gsub("/+$", "")
    local root = trim(self.settings.manga_root):gsub("\\", "/"):lower():gsub("/+$", "")
    if root ~= "" then return normalized:sub(1, #root + 1) == root .. "/" end
    return normalized:find("/manga/", 1, true) ~= nil
end

function MyAnimeList:_resolveFolderSeries(folder)
    if type(folder) ~= "table" or not self:_isMangaFolder(folder.path) then return nil end

    local first_book = folder.first_book
    if type(first_book) ~= "table" and type(folder.books) == "table" then
        first_book = folder.books[1]
    end
    local filepath = type(first_book) == "table" and first_book.filepath or nil
    local resolved = filepath and self:_resolveSeries(filepath) or nil
    if resolved then return resolved end

    local name = trim(folder.label or basename(folder.path))
    name = name:gsub("_", ":"):gsub("%s*:%s*", ": ")
    local key = Core.normalizeSeries(name)
    if name == "" or key == "" then return nil end
    return { key = key, name = name, file = filepath }
end

function MyAnimeList:folderAction(folder)
    local series = self:_resolveFolderSeries(folder)
    if not series then return nil end
    local linked = self.settings.mappings[series.key] ~= nil
    return {
        text = linked and _("Edit MyAnimeList link...") or _("Link folder to MyAnimeList..."),
        callback = function()
            if self.settings.mappings[series.key] then
                self:showSeriesSettings(series.key)
            else
                self:_searchSeries(series.key, series.name, series.name)
            end
        end,
    }
end

function MyAnimeList:_resolveSeries(file)
    if not self:_isMangaPath(file) then return nil end
    local info
    local ok_bim, BIM = pcall(require, "bookinfomanager")
    if ok_bim and BIM and BIM.getBookInfo then
        local ok, result = pcall(BIM.getBookInfo, BIM, file, false)
        if ok then info = result end
    end
    local index = info and Core.integerVolume(info.series_index)
    local series = info and Core.cleanSeriesName(info.series, info.series_index)
    local title = info and info.title or basename(file)
    if not index then index = Core.volumeFromText(title) or Core.volumeFromText(basename(file)) end
    if not series or series == "" then series = basename(dirname(file)) end
    if not series or series == "" or not index then return nil end
    return {
        key = Core.normalizeSeries(series),
        name = series,
        volume = index,
        file = file,
        title = title,
    }
end

function MyAnimeList:onLocalStatusChanged(file, known_status)
    if type(file) ~= "string" or file == "" then return end
    local status = known_status or self:_readStatus(file)
    if status ~= "complete" then return end

    local now = os.time()
    local event_key = file .. "\0" .. status
    if self._recent_events[event_key] and now - self._recent_events[event_key] < 3 then return end
    self._recent_events[event_key] = now

    local series = self:_resolveSeries(file)
    if not series then return end
    local mapping = self.settings.mappings[series.key]
    if not mapping then
        local pending = self.settings.pending_links[series.key] or {
            name = series.name,
            example_file = file,
            volume = 0,
        }
        pending.volume = math.max(tonumber(pending.volume) or 0, series.volume)
        pending.example_file = file
        self.settings.pending_links[series.key] = pending
        self:saveSettings()
        self:notify(string.format(_("MyAnimeList: link %s to sync volume %d."), series.name, series.volume), 4)
        return
    end

    self:_enqueue(mapping, series.volume)
    if self.settings.auto_sync then self:_scheduleSync() end
end

function MyAnimeList:_enqueue(mapping, volume)
    local mal_volume = Core.mapLocalVolume(volume, mapping)
    if not mal_volume then return end
    local id = tostring(mapping.mal_id)
    self.settings.queue[id] = Core.mergeQueue(self.settings.queue[id], {
        mal_id = tonumber(mapping.mal_id),
        series_key = mapping.series_key,
        series_name = mapping.series_name,
        local_volume = Core.integerVolume(volume),
        volumes_read = mal_volume,
        requested_at = os.time(),
    })
    self:saveSettings()
end

function MyAnimeList:_finishFinishedScan(request, highest, matched, total_files)
    local mapping = self.settings.mappings[request.series_key]
    if mapping and highest > 0 then self:_enqueue(mapping, highest) end
    local mal_volume = mapping and Core.mapLocalVolume(highest, mapping) or highest

    self._finished_scan_running = false
    if request.interactive then
        if request.scan_error then
            self:showInfo(_("Could not scan finished volumes: ") .. tostring(request.scan_error))
        elseif highest > 0 then
            self:notify(string.format(
                _("Found %d finished local volumes; highest local volume is %d (MAL progress %d)."),
                matched, highest, mal_volume), 6)
        elseif total_files > 0 then
            self:notify(_("No finished local volumes were found."), 4)
        else
            self:notify(_("No local files were found for that linked series."), 4)
        end
    elseif highest > (tonumber(request.known_volume) or 0) then
        self:notify(string.format(
            _("MyAnimeList: found finished local volumes through %d (MAL progress %d)."),
            highest, mal_volume), 5)
    end

    if self.settings.auto_sync and count(self.settings.queue) > 0 then self:_scheduleSync() end
    UIManager:scheduleIn(0, function() self:_startNextFinishedScan() end)
end

function MyAnimeList:_startNextFinishedScan()
    if self._finished_scan_running then return end
    local request = table.remove(self._finished_scan_queue, 1)
    if not request then return end
    local mapping = self.settings.mappings[request.series_key]
    if not mapping then
        UIManager:scheduleIn(0, function() self:_startNextFinishedScan() end)
        return
    end

    self._finished_scan_running = true
    local ok_scan, files = pcall(Scanner.findSeriesFiles,
        self.settings.manga_root, request.series_key, request.example_file)
    if not ok_scan or type(files) ~= "table" then
        request.scan_error = tostring(files or "scan_failed")
        self:_finishFinishedScan(request, 0, 0, 0)
        return
    end
    if request.interactive then
        self:notify(string.format(_("Scanning %s for finished volumes..."), mapping.series_name), 3)
    end
    if #files == 0 then
        self:_finishFinishedScan(request, 0, 0, 0)
        return
    end

    local index, highest, matched = 1, 0, 0
    local matched_volumes = {}
    local function step()
        local last = math.min(index + 7, #files)
        while index <= last do
            local file = files[index]
            local status = self:_readStatus(file)
            local resolved = status == "complete" and self:_resolveSeries(file) or nil
            local next_highest, is_match = Core.finishedVolume(
                highest, request.series_key, resolved, status)
            highest = next_highest
            if is_match and not matched_volumes[resolved.volume] then
                matched_volumes[resolved.volume] = true
                matched = matched + 1
            end
            index = index + 1
        end
        if index <= #files then
            UIManager:scheduleIn(0, step)
        else
            self:_finishFinishedScan(request, highest, matched, #files)
        end
    end
    UIManager:scheduleIn(0, step)
end

function MyAnimeList:scanFinishedVolumes(series_key, example_file, interactive, known_volume)
    if not self.settings.mappings[series_key] then return end
    self._finished_scan_queue[#self._finished_scan_queue + 1] = {
        series_key = series_key,
        example_file = example_file,
        interactive = interactive == true,
        known_volume = tonumber(known_volume) or 0,
    }
    self:_startNextFinishedScan()
end

function MyAnimeList:showFinishedVolumeScanner()
    local keys = Core.sortedKeys(self.settings.mappings)
    if #keys == 0 then self:notify(_("No manga series are linked.")); return end
    local rows = {}
    local dialog
    for _, key in ipairs(keys) do
        local series_key = key
        local mapping = self.settings.mappings[series_key]
        rows[#rows + 1] = {{
            text = string.format("%s -> %s", mapping.series_name, mapping.mal_title),
            callback = function()
                UIManager:close(dialog)
                self:scanFinishedVolumes(series_key, nil, true)
            end,
        }}
    end
    dialog = ButtonDialog:new{ title = _("Scan finished volumes"), buttons = rows }
    UIManager:show(dialog)
end

function MyAnimeList:_scheduleSync()
    if self._sync_scheduled or self._sync_running or not self:isAuthorized() then return end
    self._sync_scheduled = true
    UIManager:scheduleIn(2, function()
        self._sync_scheduled = false
        if NetworkMgr:isConnected() then self:syncQueue(false) end
    end)
end

function MyAnimeList:_runSubprocess(operation, label, callback, quiet)
    local function invokeCallback(result, err)
        local ok, callback_err = xpcall(function()
            callback(result, err)
        end, debug.traceback)
        if not ok then
            self:showInfo(_("MyAnimeList operation failed: ") .. tostring(callback_err), 10)
        end
    end

    local function protectedOperation()
        local ok, result = xpcall(operation, debug.traceback)
        if not ok then return envelope({ error = tostring(result) }) end
        return result
    end

    local function run()
        local trap = quiet and {} or label
        local completed, encoded = Trapper:dismissableRunInSubprocess(protectedOperation, trap, true)
        if not completed then
            invokeCallback(nil, "operation_interrupted")
            return
        end
        local result, err = decodeEnvelope(encoded)
        if not result then
            invokeCallback(nil, err)
        else
            invokeCallback(result)
        end
    end
    if Trapper:isWrapped() then return run() end
    return Trapper:wrap(run)
end

local function applyTokenResult(settings, token)
    if type(token) ~= "table" or not token.access_token then return false end
    settings.access_token = token.access_token
    if token.refresh_token then settings.refresh_token = token.refresh_token end
    settings.access_expires_at = os.time() + (tonumber(token.expires_in) or 3600)
    return true
end

function MyAnimeList:syncQueue(interactive)
    if self._sync_running then
        if interactive then self:notify(_("A MyAnimeList sync is already running.")) end
        return
    end
    if not self:isAuthorized() then
        if interactive then self:showInfo(_("Connect MyAnimeList first.")) end
        return
    end
    if interactive and not NetworkMgr:isConnected() then
        NetworkMgr:runWhenOnline(function() self:syncQueue(true) end)
        return
    end
    local queue_keys = Core.sortedKeys(self.settings.queue)
    if #queue_keys == 0 then
        if interactive then self:notify(_("There are no pending MyAnimeList updates.")) end
        return
    end

    local config = {
        client_id = self.settings.client_id,
        client_secret = self.settings.client_secret,
        access_token = self.settings.access_token,
        refresh_token = self.settings.refresh_token,
        access_expires_at = self.settings.access_expires_at,
    }
    local jobs = {}
    for _, key in ipairs(queue_keys) do
        local item = self.settings.queue[key]
        local mapping = item and self.settings.mappings[item.series_key]
        if item and mapping then
            jobs[#jobs + 1] = {
                queue_key = key,
                item = item,
                total_volumes = mapping.total_volumes,
                last_synced = mapping.last_synced,
            }
        end
    end
    self._sync_running = true
    self:_runSubprocess(function()
        local client = Client.new(config)
        local result = { successes = {}, failures = {}, token = nil }
        if tonumber(config.access_expires_at or 0) <= os.time() + 60 and config.refresh_token then
            local token, refresh_err = client:refreshToken()
            if not token then return envelope({ error = refresh_err or "token_refresh_failed" }) end
            config.access_token = token.access_token
            config.refresh_token = token.refresh_token or config.refresh_token
            config.access_expires_at = os.time() + (tonumber(token.expires_in) or 3600)
            client = Client.new(config)
            result.token = token
        end
        for _, job in ipairs(jobs) do
            local detail, detail_err, detail_code = client:getManga(job.item.mal_id)
            if not detail and detail_code == 401 and config.refresh_token then
                local token = client:refreshToken()
                if token then
                    config.access_token = token.access_token
                    config.refresh_token = token.refresh_token or config.refresh_token
                    config.access_expires_at = os.time() + (tonumber(token.expires_in) or 3600)
                    client = Client.new(config)
                    result.token = token
                    detail, detail_err = client:getManga(job.item.mal_id)
                end
            end
            if not detail then
                result.failures[#result.failures + 1] = { key = job.queue_key, error = detail_err }
            else
                local total = tonumber(detail.num_volumes) or tonumber(job.total_volumes) or 0
                local plan = Core.planUpdate(job.item, detail.my_list_status, total, job.last_synced)
                local updated, update_err = detail.my_list_status, nil
                if plan.changed then updated, update_err = client:updateManga(job.item.mal_id, plan) end
                if updated then
                    result.successes[#result.successes + 1] = {
                        key = job.queue_key,
                        series_key = job.item.series_key,
                        volumes_read = plan.volumes_read,
                        status = plan.status,
                        total_volumes = total,
                    }
                else
                    result.failures[#result.failures + 1] = { key = job.queue_key, error = update_err }
                end
            end
        end
        return envelope(result)
    end, _("Syncing manga with MyAnimeList..."), function(result, transport_err)
        self._sync_running = false
        if not result then
            if interactive then self:showInfo(_("MyAnimeList sync failed: ") .. tostring(transport_err)) end
            return
        end
        if result.token and applyTokenResult(self.settings, result.token) then self:saveSettings() end
        if result.error then
            if interactive then self:showInfo(_("MyAnimeList sync failed: ") .. tostring(result.error)) end
            return
        end
        for _, item in ipairs(result.successes or {}) do
            local queued = self.settings.queue[item.key]
            if not queued or (tonumber(queued.volumes_read) or 0) <= (tonumber(item.volumes_read) or 0) then
                self.settings.queue[item.key] = nil
            end
            local mapping = self.settings.mappings[item.series_key]
            if mapping then
                mapping.last_synced = math.max(tonumber(mapping.last_synced) or 0, tonumber(item.volumes_read) or 0)
                mapping.total_volumes = tonumber(item.total_volumes) or mapping.total_volumes
                mapping.last_status = item.status
            end
        end
        self:saveSettings()
        local success_count = #(result.successes or {})
        local failure_count = #(result.failures or {})
        if interactive or failure_count > 0 then
            self:notify(string.format(_("MyAnimeList: %d updated, %d failed."), success_count, failure_count), 4)
        end
    end, not interactive)
end

function MyAnimeList:editApiSettings()
    local dialog
    dialog = MultiInputDialog:new{
        title = _("MyAnimeList API client"),
        fields = {
            { text = self.settings.client_id or "", hint = _("Client ID") },
            { text = self.settings.client_secret or "", hint = _("Client secret (optional)"), text_type = "password" },
            { text = self.settings.redirect_uri or "https://myanimelist.net/", hint = _("Redirect URI") },
        },
        description = _("Create an API client on MyAnimeList. The redirect URI entered here must exactly match that client."),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local client_id, secret, redirect = unpack(dialog:getFields())
                self.settings.client_id = trim(client_id) ~= "" and trim(client_id) or nil
                self.settings.client_secret = trim(secret) ~= "" and trim(secret) or nil
                self.settings.redirect_uri = trim(redirect) ~= "" and trim(redirect) or "https://myanimelist.net/"
                self:saveSettings()
                UIManager:close(dialog)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function MyAnimeList:startAuthorization()
    if trim(self.settings.client_id) == "" then
        self:showInfo(_("Enter a MyAnimeList client ID first."))
        return
    end
    local seed = os.time() + math.floor((os.clock() or 0) * 100000)
    self.settings.pkce_verifier = Core.newPkceVerifier(seed)
    self.settings.oauth_state = Core.newPkceVerifier(seed + 7919):sub(1, 32)
    self:saveSettings()
    local url = Client.authorizationUrl(self.settings)
    if Device:canOpenLink() then
        Device:openLink(url)
        self:showInfo(_("Authorize KOReader in the browser. Then return and choose 'Finish authorization' to paste the callback URL or code."), 7)
    else
        self:showInfo(url, 10)
    end
end

function MyAnimeList:finishAuthorization()
    if not self.settings.pkce_verifier then
        self:showInfo(_("Start authorization first."))
        return
    end
    local dialog
    dialog = InputDialog:new{
        title = _("Finish MyAnimeList authorization"),
        input = "",
        input_hint = _("Callback URL or authorization code"),
        description = _("Paste the final browser URL, or only its code parameter."),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Connect"), is_enter_default = true, callback = function()
                local entered = dialog:getInputText()
                local returned_state = Core.extractQueryParameter(entered, "state")
                if returned_state and returned_state ~= self.settings.oauth_state then
                    self:showInfo(_("The authorization state did not match. Start authorization again."))
                    return
                end
                local code = Core.extractAuthorizationCode(entered)
                if not code then self:showInfo(_("No authorization code was found.")); return end
                UIManager:close(dialog)
                local config = {
                    client_id = self.settings.client_id,
                    client_secret = self.settings.client_secret,
                    redirect_uri = self.settings.redirect_uri,
                    pkce_verifier = self.settings.pkce_verifier,
                }
                self:_runSubprocess(function()
                    local token, err = Client.new(config):exchangeCode(code)
                    return envelope({ token = token, error = err })
                end, _("Connecting to MyAnimeList..."), function(result, err)
                    if not result or not result.token then
                        self:showInfo(_("Could not connect to MyAnimeList: ") .. tostring((result and result.error) or err))
                        return
                    end
                    applyTokenResult(self.settings, result.token)
                    self.settings.pkce_verifier = nil
                    self.settings.oauth_state = nil
                    self:saveSettings()
                    self:notify(_("MyAnimeList connected."))
                    self:_scheduleSync()
                end, false)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function MyAnimeList:disconnect()
    self.settings.access_token = nil
    self.settings.refresh_token = nil
    self.settings.access_expires_at = 0
    self:saveSettings()
    self:notify(_("MyAnimeList disconnected."))
end

function MyAnimeList:_searchSeries(series_key, display_name, initial_query)
    if trim(self.settings.client_id) == "" then
        self:showInfo(_("Enter a MyAnimeList client ID first."))
        return
    end
    local dialog
    dialog = InputDialog:new{
        title = _("Search MyAnimeList"),
        input = initial_query or display_name or "",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Search"), is_enter_default = true, callback = function()
                local query = trim(dialog:getInputText())
                if query == "" then return end
                UIManager:close(dialog)
                local config = {
                    client_id = self.settings.client_id,
                    access_token = self.settings.access_token,
                }
                self:_runSubprocess(function()
                    local body, err = Client.new(config):searchManga(query)
                    return envelope({ body = body, error = err })
                end, _("Searching MyAnimeList..."), function(result, err)
                    if not result or not result.body then
                        self:showInfo(_("MyAnimeList search failed: ") .. tostring((result and result.error) or err))
                        return
                    end
                    local results = type(result.body.data) == "table" and result.body.data or {}
                    UIManager:scheduleIn(0.1, function()
                        self:_showSearchResults(series_key, display_name or query, results)
                    end)
                end, false)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function MyAnimeList:_showSearchResults(series_key, display_name, results)
    if type(results) ~= "table" or #results == 0 then
        self:showInfo(_("No manga matched that search."))
        return
    end
    local rows = {}
    local dialog
    for _, result in ipairs(results) do
        local node = result.node or result
        if node and node.id then
            local volumes = tonumber(node.num_volumes) or 0
            local suffix = volumes > 0 and string.format(" (%d %s)", volumes, _("volumes")) or ""
            rows[#rows + 1] = {{
                text = tostring(node.title or node.id) .. suffix,
                callback = function()
                    UIManager:close(dialog)
                    self:showSeriesSettings(series_key, display_name, node)
                end,
            }}
        end
    end
    if #rows == 0 then
        self:showInfo(_("No manga matched that search."))
        return
    end
    dialog = ButtonDialog:new{ title = _("Choose manga"), buttons = rows }
    UIManager:show(dialog)
end

function MyAnimeList:_saveMapping(series_key, display_name, node, format)
    local key = series_key or Core.normalizeSeries(display_name)
    local pending = self.settings.pending_links[key]
    format = type(format) == "table" and format or {}
    self.settings.mappings[key] = {
        series_key = key,
        series_name = display_name,
        mal_id = tonumber(node.id),
        mal_title = node.title,
        total_volumes = tonumber(node.num_volumes) or 0,
        last_synced = 0,
        omnibus = format.omnibus == true,
        omnibus_size = Core.integerVolume(format.omnibus_size) or 3,
    }
    self.settings.pending_links[key] = nil
    local known_volume = pending and tonumber(pending.volume) or 0
    if known_volume > 0 then
        self:_enqueue(self.settings.mappings[key], known_volume)
    else
        self:saveSettings()
    end
    self:notify(string.format(_("Linked %s to %s."), display_name, tostring(node.title)))
    self:scanFinishedVolumes(key, pending and pending.example_file, false, known_volume)
end

function MyAnimeList:showSeriesSettings(series_key, display_name, node)
    local mapping = self.settings.mappings[series_key]
    local editing = mapping ~= nil and node == nil
    local dialog, omnibus_checkbox
    local default_size = tonumber(mapping and mapping.omnibus_size) or 3
    local buttons = {
        { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
    }
    if editing then
        buttons[#buttons + 1] = {
            text = _("Unlink"),
            callback = function()
                UIManager:close(dialog)
                UIManager:show(ConfirmBox:new{
                    text = string.format(_("Unlink %s from MyAnimeList?"), mapping.series_name),
                    ok_text = _("Unlink"),
                    ok_callback = function()
                        self.settings.mappings[series_key] = nil
                        self:saveSettings()
                    end,
                })
            end,
        }
    end
    buttons[#buttons + 1] = {
        text = _("Save"),
        is_enter_default = true,
        callback = function()
            local fields = dialog:getFields()
            local omnibus_size = Core.integerVolume(fields[1])
            if omnibus_checkbox.checked and (not omnibus_size or omnibus_size < 2) then
                self:showInfo(_("Enter at least 2 volumes per omnibus."))
                return
            end
            omnibus_size = omnibus_size or default_size
            UIManager:close(dialog)
            if editing then
                mapping.omnibus = omnibus_checkbox.checked == true
                mapping.omnibus_size = omnibus_size
                self:saveSettings()
                self:notify(mapping.omnibus
                    and string.format(_("Omnibus sync enabled: %d MAL volumes per local volume."), omnibus_size)
                    or _("Omnibus sync disabled."), 4)
                self:scanFinishedVolumes(series_key, nil, false, 0)
            else
                self:_saveMapping(series_key, display_name, node, {
                    omnibus = omnibus_checkbox.checked == true,
                    omnibus_size = omnibus_size,
                })
            end
        end,
    }

    dialog = MultiInputDialog:new{
        title = editing
            and string.format(_("Sync settings: %s"), mapping.series_name)
            or _("Series sync settings"),
        fields = {
            {
                text = tostring(default_size),
                hint = _("MAL volumes in each omnibus"),
                input_type = "number",
            },
        },
        description = _("For omnibus editions, local volume N becomes N multiplied by this value. Progress is capped at MyAnimeList's official volume total."),
        buttons = { buttons },
    }
    omnibus_checkbox = CheckButton:new{
        text = _("This local series uses omnibus editions"),
        checked = mapping and mapping.omnibus == true or false,
        parent = dialog,
    }
    dialog:addWidget(omnibus_checkbox)
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function MyAnimeList:showPendingSeries()
    local keys = Core.sortedKeys(self.settings.pending_links)
    if #keys == 0 then self:notify(_("There are no unlinked finished manga series.")); return end
    local rows = {}
    local dialog
    for _, key in ipairs(keys) do
        local pending = self.settings.pending_links[key]
        rows[#rows + 1] = {{
            text = string.format("%s (%s %d)", pending.name, _("volume"), tonumber(pending.volume) or 0),
            callback = function()
                UIManager:close(dialog)
                self:_searchSeries(key, pending.name, pending.name)
            end,
        }}
    end
    dialog = ButtonDialog:new{ title = _("Link pending manga"), buttons = rows }
    UIManager:show(dialog)
end

function MyAnimeList:linkSeriesManually()
    local dialog
    dialog = InputDialog:new{
        title = _("Local series name"),
        input = "",
        input_hint = _("Example: Attack on Titan"),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Next"), is_enter_default = true, callback = function()
                local name = trim(dialog:getInputText())
                if name == "" then return end
                UIManager:close(dialog)
                self:_searchSeries(Core.normalizeSeries(name), name, name)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function MyAnimeList:showLinkedSeries()
    local keys = Core.sortedKeys(self.settings.mappings)
    if #keys == 0 then self:notify(_("No manga series are linked.")); return end
    local rows = {}
    local dialog
    for _, key in ipairs(keys) do
        local series_key = key
        local mapping = self.settings.mappings[series_key]
        local format = mapping.omnibus
            and string.format(" · %s ×%d", _("omnibus"), tonumber(mapping.omnibus_size) or 3)
            or ""
        rows[#rows + 1] = {{
            text = string.format("%s -> %s%s", mapping.series_name, mapping.mal_title, format),
            callback = function()
                UIManager:close(dialog)
                self:showSeriesSettings(series_key)
            end,
        }}
    end
    dialog = ButtonDialog:new{ title = _("Linked manga series"), buttons = rows }
    UIManager:show(dialog)
end

function MyAnimeList:editMangaRoot()
    local dialog
    dialog = InputDialog:new{
        title = _("Manga folder"),
        input = self.settings.manga_root or DEFAULT_MANGA_ROOT,
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local root = trim(dialog:getInputText())
                self.settings.manga_root = root ~= "" and root or DEFAULT_MANGA_ROOT
                self:saveSettings()
                UIManager:close(dialog)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function MyAnimeList:addToMainMenu(menu_items)
    local Updater = require("mal_updater")
    menu_items.myanimelist = {
        text = _("MyAnimeList Manga Sync"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text_func = function()
                    return self:isAuthorized() and _("Account: connected") or _("Account: not connected")
                end,
                sub_item_table = {
                    { text = _("API client settings"), keep_menu_open = true, callback = function() self:editApiSettings() end },
                    { text = _("Create a MyAnimeList API client"), callback = function()
                        if Device:canOpenLink() then Device:openLink("https://myanimelist.net/apiconfig/create") end
                    end },
                    { text = _("Start authorization"), keep_menu_open = true, callback = function() self:startAuthorization() end },
                    { text = _("Finish authorization"), keep_menu_open = true, callback = function() self:finishAuthorization() end },
                    { text = _("Disconnect"), enabled_func = function() return self:isAuthorized() end,
                      callback = function() self:disconnect() end },
                },
            },
            {
                text_func = function() return string.format(_("Pending updates: %d"), count(self.settings.queue)) end,
                callback = function() self:syncQueue(true) end,
            },
            {
                text = _("Sync automatically"),
                checked_func = function() return self.settings.auto_sync end,
                callback = function()
                    self.settings.auto_sync = not self.settings.auto_sync
                    self:saveSettings()
                    if self.settings.auto_sync then self:_scheduleSync() end
                end,
            },
            {
                text_func = function() return string.format(_("Link pending manga (%d)"), count(self.settings.pending_links)) end,
                callback = function() self:showPendingSeries() end,
            },
            { text = _("Link a series manually"), callback = function() self:linkSeriesManually() end },
            { text_func = function() return string.format(_("Linked series (%d)"), count(self.settings.mappings)) end,
              callback = function() self:showLinkedSeries() end },
            { text = _("Scan finished volumes"), enabled_func = function() return count(self.settings.mappings) > 0 end,
              callback = function() self:showFinishedVolumeScanner() end },
            { text = _("Manga folder"), keep_menu_open = true, callback = function() self:editMangaRoot() end, separator = true },
            { text = _("Check for plugin update"), callback = function() Updater.check(self, true) end },
            { text = _("About"), callback = function()
                self:showInfo(string.format(_("MyAnimeList Manga Sync v%s\n\nFinished local volumes update num_volumes_read on MyAnimeList. Progress is never reduced automatically."), PLUGIN_VERSION), 8)
            end },
        },
    }
end

function MyAnimeList:onStart()
    -- Some optional integrations load after this plugin during startup.
    -- Retrying is safe because each hook carries its own installation marker.
    Hooks.install(self)
    if self.settings.auto_sync and count(self.settings.queue) > 0 then self:_scheduleSync() end
    require("mal_updater").check(self, false)
end

function MyAnimeList:onNetworkConnected()
    if self.settings.auto_sync and count(self.settings.queue) > 0 then self:_scheduleSync() end
end

return MyAnimeList
