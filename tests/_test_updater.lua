package.path = "./?.lua;" .. package.path

local trapper = {
    wrapped = false,
}

function trapper:isWrapped()
    return self.wrapped
end

function trapper:wrap(operation)
    self.wrapped = true
    local result = operation()
    self.wrapped = false
    return result
end

function trapper:dismissableRunInSubprocess(operation, widget, simple_string)
    self.last_widget = widget
    self.last_simple_string = simple_string
    if self.cancel_next then
        self.cancel_next = false
        return false
    end
    return true, operation()
end

local ui_manager = {}
function ui_manager:scheduleIn(_, operation)
    operation()
end

local function stub(name, value)
    package.preload[name] = function() return value end
end

stub("ui/widget/confirmbox", { new = function(_, value) return value end })
stub("datastorage", { getDataDir = function() return "/tmp" end })
local device = {}
stub("device", device)
stub("ui/network/manager", {})
stub("ui/widget/notification", { new = function(_, value) return value end })
stub("ui/trapper", trapper)
stub("ui/uimanager", ui_manager)
stub("ltn12", { sink = {} })
stub("rapidjson", {})
stub("socket", {})
stub("socket.http", {})
stub("socketutil", {})
stub("gettext", function(value) return value end)

local runTask = require("mal_updater")._test.runTask
local received
runTask(function()
    return { success = true, marker = "preserved" }
end, "Updating...", function(result)
    received = result
end, false)

assert(trapper.last_widget == "Updating...", "interactive task should use the progress label")
assert(trapper.last_simple_string == false, "table results must use KOReader serialization")
assert(received and received.success and received.marker == "preserved",
    "task result should reach the UI callback")

trapper.cancel_next = true
runTask(function() return { success = true } end, "Updating...", function(result)
    received = result
end, true)
assert(trapper.last_widget == false, "quiet task should use an invisible non-resending trap")
assert(received and received.error == "operation_cancelled", "cancellation should be explicit")

received = nil
runTask(function() error("expected updater failure") end, "Updating...", function(result)
    received = result
end, false)
assert(received and received.stage == "internal" and received.err:match("expected updater failure"),
    "subprocess errors should be returned instead of becoming unknown failures")

local extracted_paths = {}
local Reader = {}
Reader.__index = Reader
function Reader:new() return setmetatable({}, Reader) end
function Reader:open() return true end
function Reader:iterate()
    local entries = {
        { path = "myanimelist.koplugin/" },
        { path = "myanimelist.koplugin/main.lua" },
    }
    local index = 0
    return function()
        index = index + 1
        return entries[index]
    end
end
function Reader:extractToPath(source, destination)
    extracted_paths[#extracted_paths + 1] = { source = source, destination = destination }
    return true
end
function Reader:close() end

package.preload["ffi/archiver"] = function() return { Reader = Reader } end
package.loaded["ffi/archiver"] = nil
local extractArchive = require("mal_updater")._test.extractArchive
local extracted, extract_err = extractArchive("/tmp/update.zip", "/tmp/plugins")
assert(extracted and not extract_err, "the current ffi/archiver path should extract updates")
assert(extracted_paths[2].destination == "/tmp/plugins/myanimelist.koplugin/main.lua",
    "archive entries should stay below the plugin directory")

function Reader:iterate()
    local yielded = false
    return function()
        if yielded then return nil end
        yielded = true
        return { path = "../outside.lua" }
    end
end
extracted, extract_err = extractArchive("/tmp/update.zip", "/tmp/plugins")
assert(not extracted and extract_err == "unsafe_archive_path",
    "archive traversal must be rejected")

package.preload["ffi/archiver"] = function() error("archiver unavailable") end
package.loaded["ffi/archiver"] = nil
local legacy_called = false
device.unpackArchive = function(_, zip_path, parent, strip_root)
    legacy_called = zip_path == "/tmp/update.zip"
        and parent == "/tmp/plugins" and strip_root == false
    return true
end
extracted, extract_err = extractArchive("/tmp/update.zip", "/tmp/plugins")
assert(extracted and not extract_err and legacy_called,
    "older KOReader releases should retain the Device fallback")

print("updater tests passed")
