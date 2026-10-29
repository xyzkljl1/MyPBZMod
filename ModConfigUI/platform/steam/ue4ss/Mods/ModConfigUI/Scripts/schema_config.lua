-- UI-side snapshots and per-Mod FIFO requests. No configuration file I/O.
local api = require('mcu_core')
local model = require('mcu_core.schema')
local entries = {}
local M = {validate = model.validateMetadata}

local function notify(callback, snapshot, err)
    local ok, reason = pcall(callback, snapshot, err)
    if not ok then print('[ModConfigUI] Schema UI callback failed: ' .. tostring(reason) .. '\n') end
end

function M.list(callback)
    api.list(function(items, err)
        if not items then notify(callback, nil, err); return end
        for index, snapshot in ipairs(items) do
            local key = snapshot.schema.id:lower()
            local entry = entries[key]
            if not entry or entry.snapshot.epoch ~= snapshot.epoch then
                entry = {snapshot = snapshot, queue = {}}
                entries[key] = entry
            elseif snapshot.revision >= entry.snapshot.revision then
                entry.snapshot = snapshot
            end
            items[index] = entry.snapshot
        end
        callback(items)
    end)
end

local drain
drain = function(key, entry)
    if entry.busy or #entry.queue == 0 then return end
    local item = table.remove(entry.queue, 1)
    local snapshot = entry.snapshot
    entry.busy = true
    local finished = false
    local function complete(updated, err)
        if finished then return end
        finished, entry.busy = true, false
        if entries[key] ~= entry or (updated and updated.epoch ~= snapshot.epoch) then
            updated, err = nil, 'Configuration was reinitialized'
        end
        if updated then
            if updated.revision >= entry.snapshot.revision then entry.snapshot = updated end
        else
            -- A missing reply may already have caused side effects. Never replay it.
            if err and (err:find('outcome is unknown', 1, true) or err == 'Another request is pending') then
                entry.blocked = err
            end
            local waiting = entry.queue
            entry.queue = {}
            for _, pending in ipairs(waiting) do notify(pending.callback, nil, err) end
            M.list(function() end) -- Refresh the revision, without resending edits.
        end
        notify(item.callback, updated and entry.snapshot, err)
        drain(key, entry)
    end
    if entries[key] ~= entry then complete(nil, 'Configuration was reinitialized'); return end
    local ok, accepted, err = pcall(api.request, snapshot.schema.id, item.action, item.payload,
        snapshot.revision, complete, snapshot.epoch)
    if not ok or not accepted then complete(nil, ok and err or accepted) end
end

function M.request(snapshot, action, payload, callback)
    local key = snapshot.schema.id:lower()
    local entry = entries[key]
    if not entry or entry.snapshot.epoch ~= snapshot.epoch then return nil, 'Configuration was reinitialized' end
    if entry.snapshot.revision ~= snapshot.revision then return nil, 'Stale configuration revision' end
    if entry.blocked then return nil, entry.blocked end
    entry.queue[#entry.queue + 1] = {action = action, payload = model.copy(payload), callback = callback}
    drain(key, entry)
    return true
end

function M.busy(snapshot)
    local entry = entries[snapshot.schema.id:lower()]
    return entry and (entry.busy or #entry.queue > 0) or false
end

return M
