package.path = "./?.lua;" .. package.path

local queue = {}
local inside_wrap = false
local trapper = {
    wrapped = false,
}

function trapper:isWrapped()
    return self.wrapped
end

function trapper:wrap(operation)
    assert(not self.wrapped, "must not nest Trapper wrappers")
    self.wrapped = true
    inside_wrap = true
    operation()
    inside_wrap = false
    self.wrapped = false
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
    queue[#queue + 1] = operation
end

local function drain()
    while #queue > 0 do
        local operation = table.remove(queue, 1)
        operation()
    end
end

local Async = require("mal_async")
local received
Async.run(trapper, ui_manager, function()
    return "search-result"
end, "Searching...", function(result, err)
    assert(not inside_wrap, "UI callback must run after the Trapper wrapper exits")
    received = { result = result, err = err }
end, false, true)

assert(trapper.last_widget == "Searching...", "interactive task should show its label")
assert(trapper.last_simple_string == true, "encoded results should use simple-string transport")
assert(received == nil, "UI callback must be deferred")
drain()
assert(received and received.result == "search-result" and received.err == nil,
    "subprocess result should reach the deferred callback")

received = nil
trapper.cancel_next = true
Async.run(trapper, ui_manager, function()
    return "unexpected"
end, "Background sync", function(result, err)
    received = { result = result, err = err }
end, true, true)
assert(trapper.last_widget == false, "quiet task should use KOReader's invisible trap")
drain()
assert(received and received.result == nil and received.err == "operation_interrupted",
    "cancellation should be reported after leaving Trapper")

received = nil
trapper.wrapped = true
Async.run(trapper, ui_manager, function()
    return "nested-result"
end, "Searching...", function(result, err)
    assert(not inside_wrap, "nested task callback must run outside Trapper")
    received = { result = result, err = err }
end, false, true)
assert(trapper.last_widget == false, "an already wrapped call must wait before starting")
trapper.wrapped = false
drain()
assert(received and received.result == "nested-result",
    "an already wrapped call should restart in a fresh wrapper")

print("async task tests passed")
