-- MCU schema API (shared code runs in the calling mod's Lua state).
-- InitFromFile(schema) -> config | nil, error; id comes from the calling Mod directory.
-- ForceSaveConfig(config) -> config | nil, error (full save, no onchange)
-- list(callback) -> callback(snapshots)
-- request(id, action, payload, revision, callback, expectedEpoch?) -> true (queued) | nil, error
-- Remote save requests compare only the keys in their patch and notify changes.
-- fields is an ordered array. Config objects contain values only.
-- Persist all values, including defaults; valid saved values survive schema updates.
-- onchange(value, oldValue, configSnapshot) and onclick(config)
-- run on the game thread in the defining mod's Lua environment. Initialization
-- does not call onchange. Manual-mode consumers assign the returned/new snapshot.
local model = require('mcu_core.schema')
local storage = require('mcu_core.storage')
local transport = require('mcu_core.transport')
local M = {}
local handles = setmetatable({}, {__mode = 'k'})
local records = {}
local commit, invokeButton

local function log(message) print('[mcu_core] ' .. tostring(message) .. '\n') end
local function replace(target, values)
    for key in pairs(target) do target[key] = nil end
    for key, value in pairs(values) do target[key] = value end
end
local function handle(record, values, revision)
    local config = model.copy(values)
    handles[config] = {record = record, revision = revision}
    return config
end
local function snapshot(record)
    return {schema = model.metadata(record.schema),
        values = setmetatable(model.copy(record.values), {__jsontype = 'object'}), revision = record.revision,
        epoch = record.endpoint and record.endpoint.epoch}
end
local function lookup(config)
    local entry = handles[config]
    if not entry or not entry.record.active or (entry.record.endpoint and not entry.record.endpoint.active) then
        return nil, 'Unknown or superseded config object'
    end
    local record = entry.record
    if record.inOnchange then return nil, 'ForceSaveConfig cannot run inside onchange' end
    if entry.revision ~= record.revision then return nil, 'Stale config object; use the latest returned config' end
    return record
end
local function restore(record)
    if record.schema.updateInPlace then replace(record.current, record.values) end
end
local function changedFields(record, values, candidates)
    local changed = {}
    -- Candidate keys have already been validated by the caller.
    for key in pairs(candidates) do
        if record.values[key] ~= values[key] then
            changed[#changed + 1] = {field = record.schema.byKey[key], old = record.values[key], value = values[key]}
        end
    end
    table.sort(changed, function(a, b) return a.field.index < b.field.index end)
    return changed
end

local function notify(record, changed, values, revision)
    if #changed == 0 then return end
    local event = {changed = changed, values = values, revision = revision}
    record.events[#record.events + 1] = event
    if record.notifyQueued then return end
    record.notifyQueued = true
    ExecuteInGameThread(function()
        record.notifyQueued = false
        local events = record.events
        record.events = {}
        if not record.active then return end
        for _, item in ipairs(events) do
            for _, change in ipairs(item.changed) do
                if not record.active then return end
                local field = change.field
                if field.onchange then
                    -- Each handler gets an isolated value snapshot, not callbacks or
                    -- schema metadata. A handler cannot corrupt another notification.
                    local config = handle(record, item.values, item.revision)
                    record.inOnchange = true
                    local ok, err = pcall(field.onchange, change.value, change.old, config)
                    record.inOnchange = false
                    if not ok then log(record.schema.id .. '.' .. field.key .. ' onchange failed: ' .. tostring(err)) end
                end
            end
        end
    end)
end

local function persist(record, values, force)
    local text, err = storage.save(record.schema.id, values, record.diskText, force)
    if not text then restore(record); return nil, err end
    record.diskText, record.values = text, values
    record.revision = record.revision + 1
    if record.schema.updateInPlace then
        replace(record.current, values)
        handles[record.current].revision = record.revision
    else
        record.current = handle(record, values, record.revision)
    end
    transport.publish(record.endpoint, snapshot(record))
    return record.current
end

commit = function(record, values, candidates)
    local changed = changedFields(record, values, candidates)
    if #changed == 0 then
        restore(record)
        return record.current
    end
    local config, err = persist(record, values)
    if not config then return nil, err end
    notify(record, changed, values, record.revision)
    return config
end

function M.ForceSaveConfig(config)
    local record, err = lookup(config)
    if not record then return nil, err end
    local values = {}
    for key, value in pairs(config) do
        local field = record.schema.byKey[key]
        if record.schema.defaults[key] == nil then restore(record); return nil, 'Unknown value key: ' .. tostring(key) end
        local valid, reason = model.validate(field, value)
        if not valid then restore(record); return nil, key .. ': ' .. reason end
        values[key] = value
    end
    for key in pairs(record.schema.defaults) do
        if values[key] == nil then restore(record); return nil, 'Missing configuration key: ' .. key end
    end
    return persist(record, values, true)
end

local function applyChanges(record, patch)
    if type(patch) ~= 'table' then restore(record); return nil, 'Changes must be a key/value table' end
    local values = model.copy(record.values)
    for key, value in pairs(patch) do
        local field = record.schema.byKey[key]
        if record.schema.defaults[key] == nil then restore(record); return nil, 'Unknown value key: ' .. tostring(key) end
        local valid, reason = model.validate(field, value)
        if not valid then restore(record); return nil, key .. ': ' .. reason end
        values[key] = value
    end
    return commit(record, values, patch)
end

local function resetValues(record, key)
    local values, candidates
    if key ~= nil then
        local field = record.schema.byKey[key]
        if record.schema.defaults[key] == nil then return nil, 'Unknown value key: ' .. tostring(key) end
        values = model.copy(record.values)
        values[key] = field.default
        candidates = {[key] = field.default}
    else
        values = model.copy(record.schema.defaults)
        candidates = values
    end
    return commit(record, values, candidates)
end

invokeButton = function(record, key)
    local field = record.schema.byKey[key]
    if not field or field.kind ~= 'button' then return nil, 'Unknown button: ' .. tostring(key) end
    local ok, err = pcall(field.onclick, handle(record, record.values, record.revision))
    if not ok then log(record.schema.id .. '.' .. key .. ' onclick failed: ' .. tostring(err)); return nil, tostring(err) end
    return true
end

function M.InitFromFile(source)
    local level, id = 2
    while not id do
        local caller = debug.getinfo(level, 'S')
        if not caller then break end
        local path = caller.source:gsub('\\', '/'):gsub('^@', '')
        id = ('/' .. path):match('/[Mm]ods/([^/]+)/[Ss]cripts/')
        level = level + 1
    end
    if not id then return nil, 'InitFromFile must be called from Mods/<ModName>/Scripts/' end
    local compiled, err = model.compile(source, id)
    if not compiled then return nil, err end
    local document, diskText
    document, err, diskText = storage.load(compiled.id)
    if err then return nil, err end
    document = document or {}
    -- Only current fields with currently allowed values survive an upgrade.
    local values = model.reconcile(compiled, document)
    local text
    text, err = storage.save(compiled.id, values, diskText)
    if not text then return nil, err end
    local id = compiled.id:lower()
    if records[id] then
        local old = records[id]
        old.active, old.events = false, {}
        if old.endpoint then old.endpoint.active, old.endpoint.handler = false, nil end
    end
    local record = {schema = compiled, values = values,
        diskText = text, revision = 0, active = true, events = {}}
    record.current = handle(record, record.values, record.revision)
    records[id] = record
    record.endpoint = transport.register(id, snapshot(record), function(request)
        if not record.active then return nil, 'Configuration was reinitialized' end
        if request.revision ~= record.revision then return nil, 'Stale configuration revision' end
        local result, reason
        if request.action == 'save' then
            result, reason = applyChanges(record, request.payload)
        elseif request.action == 'reset' then result, reason = resetValues(record, request.payload)
        elseif request.action == 'button' then result, reason = invokeButton(record, request.payload)
        else return nil, 'Unknown action' end
        if not result then return nil, reason end
        return snapshot(record)
    end)
    return record.current
end

-- Remote metadata/commands are scheduled on the game thread without polling.
-- The receiving mod retains its functions and performs all writes.
-- Callbacks return a serializable snapshot.
M.list = transport.list
function M.request(id, action, payload, revision, callback, expectedEpoch)
    if not model.validId(id) then return nil, 'Invalid configuration id' end
    if action ~= 'save' and action ~= 'reset' and action ~= 'button' then return nil, 'Unknown action' end
    if type(revision) ~= 'number' or math.tointeger(revision) == nil or revision < 0 then return nil, 'A valid expected revision is required' end
    if callback ~= nil and type(callback) ~= 'function' then return nil, 'Callback must be a function' end
    if expectedEpoch ~= nil and (type(expectedEpoch) ~= 'number' or math.tointeger(expectedEpoch) == nil or expectedEpoch < 1) then
        return nil, 'Invalid expected session'
    end
    -- Freeze the outgoing message before the caller can mutate its patch.
    -- Only scalar configuration values (or a scalar button/reset key) are valid.
    if action == 'save' then
        if type(payload) ~= 'table' then return nil, 'Save requires a patch' end
        local patch = {}
        for key, value in pairs(payload) do
            local kind = type(value)
            if type(key) ~= 'string' or (kind ~= 'boolean' and kind ~= 'number' and kind ~= 'string') then
                return nil, 'Save patch must contain string keys and scalar values'
            end
            patch[key] = value
        end
        payload = patch
    elseif payload ~= nil and type(payload) ~= 'string' then return nil, 'Button/reset key must be a string' end
    transport.request(id, action, payload, revision, callback, expectedEpoch)
    return true
end

return M
