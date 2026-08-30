local Core = {}

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

function Core.normalizeSeries(value)
    local normalized = trim(value):lower()
    normalized = normalized:gsub("_", ":")
    normalized = normalized:gsub("[%s%p]+", " ")
    return trim(normalized)
end

function Core.cleanSeriesName(value, series_index)
    local name = trim(value)
    local index = tonumber(series_index)
    if index then
        local literal = tostring(index):gsub("%.0$", "")
        name = name:gsub("%s*[#/]%s*" .. literal:gsub("%.", "%%.") .. "%s*$", "")
    end
    name = name:gsub("[%s/#%-]+$", "")
    return trim(name)
end

function Core.volumeFromText(value)
    local text = tostring(value or "")
    local patterns = {
        "[Vv]ol%.?%s*(%d+)",
        "[Vv]olume%s*(%d+)",
        "#%s*(%d+)",
        "[%s_%-](%d+)%s*$",
    }
    for _, pattern in ipairs(patterns) do
        local number = tonumber(text:match(pattern))
        if number and number >= 1 then return number end
    end
    return nil
end

function Core.integerVolume(value)
    local number = tonumber(value)
    if not number or number < 1 then return nil end
    return math.floor(number)
end

function Core.finishedVolume(current, target_key, resolved, status)
    local highest = tonumber(current) or 0
    if status ~= "complete" or type(resolved) ~= "table"
            or resolved.key ~= target_key then
        return highest, false
    end
    local volume = Core.integerVolume(resolved.volume)
    if not volume then return highest, false end
    return math.max(highest, volume), true
end

function Core.mergeQueue(existing, candidate)
    if type(candidate) ~= "table" or not candidate.mal_id then return existing end
    if type(existing) ~= "table" then
        local copy = {}
        for key, value in pairs(candidate) do copy[key] = value end
        return copy
    end
    local merged = {}
    for key, value in pairs(existing) do merged[key] = value end
    for key, value in pairs(candidate) do
        if key ~= "volumes_read" then merged[key] = value end
    end
    merged.volumes_read = math.max(
        tonumber(existing.volumes_read) or 0,
        tonumber(candidate.volumes_read) or 0)
    return merged
end

function Core.planUpdate(queue_item, remote_status, total_volumes, last_synced)
    remote_status = type(remote_status) == "table" and remote_status or {}
    local requested = tonumber(queue_item and queue_item.volumes_read) or 0
    local remote = tonumber(remote_status.num_volumes_read) or 0
    local previous = tonumber(last_synced) or 0
    local progress = math.max(requested, remote, previous)
    local total = tonumber(total_volumes) or 0
    local status
    if remote_status.status == "completed" then
        status = "completed"
    elseif total > 0 and progress >= total then
        status = "completed"
    else
        status = "reading"
    end
    return {
        volumes_read = progress,
        status = status,
        changed = progress ~= remote or status ~= remote_status.status,
    }
end

function Core.extractAuthorizationCode(value)
    local text = trim(value)
    local code = text:match("[?&]code=([^&#]+)")
    if not code and not text:find("[/?&=]", 1) then code = text end
    if not code then return nil end
    return (code:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end):gsub("+", " "))
end

function Core.extractQueryParameter(value, name)
    local encoded = tostring(value or ""):match("[?&]" .. tostring(name) .. "=([^&#]+)")
    if not encoded then return nil end
    return (encoded:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end):gsub("+", " "))
end

function Core.newPkceVerifier(seed)
    local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
    local random = io.open("/dev/urandom", "rb")
    if random then
        local bytes = random:read(64)
        random:close()
        if type(bytes) == "string" and #bytes == 64 then
            local out = {}
            for index = 1, #bytes do
                local offset = (bytes:byte(index) % #chars) + 1
                out[index] = chars:sub(offset, offset)
            end
            return table.concat(out)
        end
    end

    -- Android and Linux expose /dev/urandom. This deterministic fallback keeps
    -- authorization usable on unusual ports where that device is unavailable.
    local state = tonumber(seed) or os.time()
    local out = {}
    for index = 1, 64 do
        state = (state * 1103515245 + 12345 + index * 97) % 2147483647
        local offset = (state % #chars) + 1
        out[index] = chars:sub(offset, offset)
    end
    return table.concat(out)
end

function Core.sortedKeys(values)
    local keys = {}
    for key in pairs(values or {}) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

return Core
