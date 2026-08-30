local Async = {}

-- Trapper callbacks must return before creating or changing UI widgets.
function Async.run(Trapper, UIManager, operation, label, callback, quiet, simple_string)
    local function deliver(result, err)
        UIManager:scheduleIn(0.1, function()
            callback(result, err)
        end)
    end

    local function run()
        local trap = label
        if quiet then trap = false end
        local completed, result = Trapper:dismissableRunInSubprocess(
            operation, trap, simple_string == true)
        if not completed then
            deliver(nil, "operation_interrupted")
            return
        end
        deliver(result)
    end

    if Trapper:isWrapped() then
        UIManager:scheduleIn(0.1, function()
            Trapper:wrap(run)
        end)
        return
    end
    Trapper:wrap(run)
end

return Async
