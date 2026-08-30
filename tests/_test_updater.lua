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
stub("device", {})
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

print("updater tests passed")
