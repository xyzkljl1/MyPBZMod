-- UE4SS Lua states are isolated. Share JSON messages, never Lua callbacks.
-- A dedicated console command dispatches each request on the game thread.
-- The receiver writes its reply before ExecuteConsoleCommand returns; no polling.
local json = require('json')
local encode = require('mcu_core.config_io').encode
local UEHelpers = require('UEHelpers')
local model = require('mcu_core.schema')
local M = {}
local prefix = 'MCU.SchemaConfig.v1.'

local function log(err) print('[mcu_core] ' .. tostring(err) .. '\n') end
local function decode(text)
    if type(text) ~= 'string' then return nil end
    local ok, value, position, err = pcall(json.decode, text, 1, json.null)
    if ok and not err and position and not text:sub(position):find('%S') and type(value) == 'table' then return value end
end
local function get(key) return ModRef:GetSharedVariable(prefix .. key) end
local function set(key, value) ModRef:SetSharedVariable(prefix .. key, value) end
local function validSnapshot(snapshot, id)
    if type(snapshot) ~= 'table' or type(snapshot.schema) ~= 'table'
        or not model.validId(snapshot.schema.id) or snapshot.schema.id:lower() ~= id
        or type(snapshot.schema.fields) ~= 'table' or type(snapshot.values) ~= 'table'
        or type(snapshot.revision) ~= 'number' or not math.tointeger(snapshot.revision) or snapshot.revision < 0
        or type(snapshot.epoch) ~= 'number' or not math.tointeger(snapshot.epoch) or snapshot.epoch < 1 then return false end
    for _, field in ipairs(snapshot.schema.fields) do
        if type(field) ~= 'table' or type(field.key) ~= 'string' or type(field.type) ~= 'string'
            or type(field.label) ~= 'string' or not utf8.len(field.label)
            or type(field.params) ~= 'table' then return false end
    end
    return snapshot.epoch == get(id .. '.epoch')
end
local function commandFor(id, epoch) return 'mcu_schema_' .. id .. '__' .. tostring(epoch) end
local function notify(callback, value, err)
    if callback then
        local ok, reason = pcall(callback, value, err)
        if not ok then log('Remote callback failed: ' .. tostring(reason)) end
    end
end

local function receive(endpoint)
    local id = endpoint.id
    if not endpoint.active or get(id .. '.epoch') ~= endpoint.epoch then
        endpoint.active = false
        return
    end
    local sequence = get(id .. '.requestSeq')
    if sequence == nil or sequence == endpoint.seen then return end
    endpoint.seen = sequence
    local request = decode(get(id .. '.request'))
    local reply = {sequence = sequence, epoch = endpoint.epoch, ok = false}
    if not request or request.epoch ~= endpoint.epoch or request.sequence ~= sequence then
        reply.error = 'Stale or malformed request'
    else
        local handled, result, reason = pcall(endpoint.handler, request)
        if handled and result then reply.ok, reply.result = true, result
        else reply.error = tostring(handled and reason or result) end
    end
    set(id .. '.reply', encode(reply))
end

function M.register(id, snapshot, handler)
    id = id:lower()
    local endpoint = {id = id, handler = handler, active = true}
    ExecuteInGameThread(function()
        if not endpoint.active then return end
        local epoch = (get(id .. '.epoch') or 0) + 1
        endpoint.epoch = epoch
        set(id .. '.epoch', epoch)
        endpoint.seen = get(id .. '.requestSeq') or 0
        -- Different Lua states must not register handlers under the same name.
        -- Including the session also prevents an old command reaching a new owner.
        RegisterConsoleCommandGlobalHandler(commandFor(id, epoch), function()
            local ok, err = pcall(receive, endpoint)
            if not ok then log('Request processing failed for ' .. id .. ': ' .. tostring(err)) end
            return true
        end)
        local registry = decode(get('registry')) or {}
        registry[id] = true
        set('registry', encode(registry))
        snapshot.epoch = epoch
        set(id .. '.snapshot', encode(snapshot))
    end)
    return endpoint
end

function M.unregister(endpoint)
    endpoint.active, endpoint.handler = false, nil
    ExecuteInGameThread(function()
        if endpoint.epoch and get(endpoint.id .. '.epoch') == endpoint.epoch then
            set(endpoint.id .. '.snapshot', nil)
            local registry = decode(get('registry')) or {}
            registry[endpoint.id] = nil
            set('registry', encode(registry))
        end
    end)
end

function M.publish(endpoint, snapshot)
    ExecuteInGameThread(function()
        if endpoint.active and endpoint.epoch and get(endpoint.id .. '.epoch') == endpoint.epoch then
            snapshot.epoch = endpoint.epoch
            set(endpoint.id .. '.snapshot', encode(snapshot))
        end
    end)
end

-- Async metadata lookup for the future UI. No disk scans or UI integration.
function M.list(callback)
    ExecuteInGameThread(function()
        local ok, result = pcall(function()
            local items = {}
            for id in pairs(decode(get('registry')) or {}) do
                if model.validId(id) then
                    local snapshot = decode(get(id .. '.snapshot'))
                    if validSnapshot(snapshot, id) then items[#items + 1] = snapshot end
                end
            end
            table.sort(items, function(a, b) return a.schema.id < b.schema.id end)
            return items
        end)
        if ok then notify(callback, result) else notify(callback, nil, tostring(result)) end
    end)
end

-- request(id, action, payload, expectedRevision, callback)
-- Scheduled once on the game thread; command dispatch and reply reading are synchronous.
-- An unacknowledged request remains pending and is never automatically retried.
function M.request(id, action, payload, revision, callback, expectedEpoch)
    ExecuteInGameThread(function()
        local dispatched = false
        local ok, failure = pcall(function()
            id = id:lower()
            local snapshot = decode(get(id .. '.snapshot'))
            if not validSnapshot(snapshot, id) then notify(callback, nil, 'Configuration is not registered'); return end
            if expectedEpoch and expectedEpoch ~= snapshot.epoch then notify(callback, nil, 'Configuration was reinitialized'); return end
            local sequence = get(id .. '.requestSeq') or 0
            local pending = decode(get(id .. '.request'))
            if pending and pending.epoch == snapshot.epoch and pending.sequence == sequence
                and get(id .. '.consumedSeq') ~= sequence then
                notify(callback, nil, 'Another request is pending'); return
            end
            sequence = sequence + 1
            local request = {sequence = sequence, epoch = snapshot.epoch, action = action,
                payload = payload, revision = revision}
            local encoded, text = pcall(encode, request)
            if not encoded then notify(callback, nil, tostring(text)); return end
            local ready, world, system = pcall(function()
                local world = UEHelpers.GetWorld()
                local system = UEHelpers.GetKismetSystemLibrary()
                if not world or not world:IsValid() or not system or not system:IsValid() then
                    error('No valid world or console command library')
                end
                return world, system
            end)
            if not ready then notify(callback, nil, tostring(world)); return end
            set(id .. '.request', text)
            set(id .. '.requestSeq', sequence)
            set(id .. '.reply', nil)
            dispatched = true
            local sent, reason = pcall(function()
                system:ExecuteConsoleCommand(world, commandFor(id, snapshot.epoch), nil)
            end)
            if get(id .. '.epoch') ~= snapshot.epoch then notify(callback, nil, 'Configuration was reinitialized'); return end
            local reply = decode(get(id .. '.reply'))
            if reply and reply.sequence == sequence and reply.epoch == snapshot.epoch then
                set(id .. '.consumedSeq', sequence)
                if reply.ok then notify(callback, reply.result) else notify(callback, nil, reply.error) end
            else
                notify(callback, nil, (sent and 'Configuration command returned no reply' or 'Command dispatch failed: ' .. tostring(reason))
                    .. '; outcome is unknown, do not retry automatically')
            end
        end)
        if not ok then
            notify(callback, nil, tostring(failure) .. (dispatched and '; outcome is unknown, do not retry automatically' or ''))
        end
    end)
end

return M
