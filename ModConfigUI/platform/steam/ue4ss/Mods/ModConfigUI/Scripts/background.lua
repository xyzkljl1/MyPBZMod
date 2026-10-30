-- Serial file/data work. Queue ownership and completion remain on the game thread.
local M, queue, running = {}, {}, false
local function drain()
    if running then return end
    local job = table.remove(queue, 1)
    while job and not job.current() do job = table.remove(queue, 1) end
    if not job then return end
    running = true
    ExecuteAsync(function()
        local ok, values, err = pcall(job.work)
        ExecuteInGameThread(function()
            running = false
            if job.current() then
                if not ok then values, err = nil, values end
                local called, failure = pcall(job.complete, values, err)
                if not called then print('[ModConfigUI] Background callback failed (' .. job.label .. '): ' .. tostring(failure) .. '\n') end
            end
            drain()
        end)
    end)
end

function M.run(label, work, complete, current)
    queue[#queue + 1] = {label = label, work = work, complete = complete, current = current}
    drain()
end
return M
