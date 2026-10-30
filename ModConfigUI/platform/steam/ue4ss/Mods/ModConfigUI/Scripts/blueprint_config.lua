-- Typed Blueprint configs use the same schema registry, validation and storage as Lua.
local core = require('mcu_core')
local model = require('mcu_core.schema')
local M = {}
local root = '/Game/Mods/ModConfigUI/Blueprint/'
local componentPath = root .. 'BP_MCUConfigComponent.BP_MCUConfigComponent_C'
local records, started = {}, false
local source = debug.getinfo(1, 'S').source:gsub('\\', '/')
local mods = assert(source:match('^@(.+)/ModConfigUI/Scripts/[^/]+$'))
local function log(message) print('[MCU Blueprint] ' .. tostring(message) .. '\n') end
local function valid(object)
    if object == nil then return false end
    local ok, value = pcall(function() return object:IsValid() end)
    return ok and value
end
local function text(value) return type(value) == 'string' and value or value:ToString() end
local function same(a, b) return valid(a) and valid(b) and a:GetAddress() == b:GetAddress() end
local function members(struct)
    local names, properties = {}, {}
    struct:ForEachProperty(function(property)
        local internal = text(property:GetFName())
        local key, guid = internal:match('^(.-)_%d+_(%x+)$')
        if not key or #guid ~= 32 then key = internal end
        assert(not names[key], 'Ambiguous Blueprint member: ' .. key)
        names[key], properties[key] = internal, property
    end)
    return names, properties
end
local function configType(actor, name)
    local property = actor:Reflection():GetProperty(name)
    assert(valid(property) and property:IsA(PropertyTypes.StructProperty), name .. ' must be a Blueprint struct')
    return property:GetStruct()
end
local function emit(actor, name, ...)
    local found, fn = pcall(function() return actor[name] end)
    if found and valid(fn) then fn(actor, ...) end
end
local function release(record)
    if record.stop then record.stop(); record.stop = nil end
    if valid(record.component) then record.component.IsReady = false end
    if records[record.id:lower()] == record then records[record.id:lower()] = nil end
    record.active = false
end
local function convert(component, actor, id)
    local configStruct = configType(actor, 'Config')
    local configNames, properties = members(configStruct)
    local fieldNames = members(StaticFindObject(root .. 'ST_MCUFieldV1.ST_MCUFieldV1'))
    local optionNames = members(StaticFindObject(root .. 'ST_MCUOptionV1.ST_MCUOptionV1'))
    local defaults = actor:GetClass():GetCDO().Config
    local record = {id = id, actor = actor, component = component, active = true, bindings = {}, keyFields = {}}
    local function alive()
        return record.active and valid(actor) and valid(component) and not component.Ending
    end
    local function assign(values)
        local target = actor.Config
        for key, internal in pairs(record.bindings) do
            if record.keyFields[key] then
                -- A table only overwrites reflected KeyName and leaves FKey's cached
                -- KeyDetails intact. The native setter constructs/copies a full key;
                -- assigning its UScriptStruct uses UE's complete struct copy.
                if not valid(record.keyBuilder) then
                    record.keyBuilder = StaticConstructObject(StaticFindObject('/Script/UMG.InputKeySelector'),
                        component, FName('None'), 0x40)
                    assert(valid(record.keyBuilder), 'Could not create native key converter')
                end
                record.keyBuilder:SetSelectedKey({Key = {KeyName = FName(values[key])}})
                target[internal] = record.keyBuilder.SelectedKey.Key
            else
                target[internal] = values[key]
            end
        end
    end
    record.alive, record.assign = alive, assign
    local fields = {}
    component.Fields:ForEach(function(_, parameter)
        local entry = parameter:get()
        local function get(key) return entry[fieldNames[key]] end
        local key, kind = text(get('Key')), text(get('Type'))
        local field = {key = key, type = kind, label = text(get('Label')), description = text(get('Description'))}
        if field.label == '' then field.label = key end
        if kind == 'Button' then
            field.onclick = function()
                assert(alive(), 'Blueprint owner is no longer active')
                emit(actor, 'OnButtonClicked', key)
            end
        elseif kind ~= 'Separator' then
            field.onchange = function()
                if alive() then emit(actor, 'OnConfigChanged', key) end
            end
            local property = properties[key]
            -- UE4SS does not expose DoubleProperty in its PropertyTypes table.
            -- Inspect the reflected class name instead; do not accept single precision floats.
            local expected = kind == 'BoolToggle' and 'BoolProperty'
                or kind:find('^Int') and 'IntProperty'
                or kind:find('^Float') and 'DoubleProperty'
                or (kind:find('^Text') or kind == 'ColorBox') and 'StrProperty'
                or kind == 'BPKey' and 'StructProperty'
            local actual = property and property:GetFullName():match('^(%S+)')
            assert(expected and actual == expected, key .. ': Config member type does not match ' .. kind
                .. ' (expected ' .. tostring(expected) .. ', got ' .. tostring(actual) .. ')')
            if kind == 'BPKey' then
                assert(same(property:GetStruct(), StaticFindObject('/Script/InputCore.Key')), key .. ': expected Key struct')
                record.keyFields[key] = true
            end
            record.bindings[key] = configNames[key]
            field.default = defaults[configNames[key]]
            if kind == 'BPKey' then field.default = text(field.default.KeyName)
            elseif kind:find('^Text') or kind == 'ColorBox' then field.default = text(field.default) end
            if kind:find('Select$') then
                field.options = {}
                get('Options'):ForEach(function(_, optionParameter)
                    local option = optionParameter:get()
                    local valueName = kind == 'IntSelect' and 'IntValue' or kind == 'FloatSelect' and 'FloatValue' or 'TextValue'
                    local value = option[optionNames[valueName]]
                    if kind == 'TextSelect' then value = text(value) end
                    field.options[#field.options + 1] = {value = value, label = text(option[optionNames.Label])}
                end)
            elseif kind == 'TextBox' then
                if get('MinLength') >= 0 then field.minLength = get('MinLength') end
                if get('MaxLength') >= 0 then field.maxLength = get('MaxLength') end
                local pattern = text(get('Pattern'))
                if pattern ~= '' then field.pattern = pattern end
            elseif kind:find('^Int') or kind:find('^Float') then
                assert(not kind:find('Slider$') or (get('UseMin') and get('UseMax')), key .. ': sliders require UseMin and UseMax')
                if get('UseMin') then field.min = get('Min') end
                if get('UseMax') then field.max = get('Max') end
                if kind:find('Slider$') then field.step = get('Step') end
                if kind:find('^Int') then
                    -- Blueprint integers are int32, even when the schema permits larger Lua integers.
                    field.min = math.max(field.min or -2147483648, -2147483648)
                    field.max = math.min(field.max or 2147483647, 2147483647)
                end
            end
        end
        fields[#fields + 1] = field
    end)
    return record, {fields = fields}, {
        alive = alive,
        changed = function(values)
            if not alive() then return end
            assign(values) -- Publish the full batch before per-field notifications.
        end,
    }
end
local function initialize(component, requested)
    if not valid(component) or component.Ending or (not requested and not component.Requested) then return end
    local actor = component:GetOwner()
    if not valid(actor) then return end
    local id = actor:GetClass():GetFullName():match('/Game/Mods/([^/]+)/')
    assert(model.validId(id), 'Actor must be under /Game/Mods/<ModName>/')
    local old = records[id:lower()]
    if old then
        if same(old.component, component) then return end
        assert(not old.alive(), 'Another live Blueprint instance has already registered ' .. id)
        release(old)
    end
    local record, schema, owner = convert(component, actor, id)
    -- Pure Blueprint mods need a directory even when they ship no Lua scripts.
    local directory = mods .. '/' .. id
    local made = os.execute('if not exist "' .. directory .. '" mkdir "' .. directory .. '"')
    assert(made == true or made == 0, 'Cannot create configuration directory for ' .. id)
    local config, err, stop = core._InitBlueprint(schema, id, owner)
    assert(config, err)
    record.stop = stop
    records[id:lower()] = record
    record.assign(config)
    component.IsReady, component.Error = true, ''
    emit(actor, 'OnConfigReady')
    log(id .. ' ready (' .. #schema.fields .. ' fields)')
end
local function guard(component, fn)
    local ok, err = pcall(fn)
    if not ok then
        if valid(component) then component.Error = tostring(err) end
        log(err)
    end
end
local function eventComponent(context)
    local component = context:get()
    local class = StaticFindObject(componentPath)
    if valid(component) and valid(class) and component:IsA(class) then return component end
end
function M.start()
    if started then return end
    started = true
    -- Name-based events survive class reloads; register once per Lua environment.
    RegisterCustomEvent('MCU_Config_Init', function(context)
        local component = eventComponent(context)
        if component then
            ExecuteInGameThread(function() guard(component, function() initialize(component, true) end) end)
        end
    end)
    RegisterCustomEvent('MCU_Config_Release', function(context)
        local component = eventComponent(context)
        if not component then return end
        guard(component, function()
            for _, record in pairs(records) do
                if same(record.component, component) then release(record); break end
            end
        end)
    end)
    -- Recover components already initialized before Lua startup/restart.
    ExecuteInGameThread(function()
        for _, component in ipairs(FindAllOf('BP_MCUConfigComponent_C') or {}) do
            guard(component, function() initialize(component) end)
        end
    end)
    RegisterLoadMapPreHook(function()
        local old = records
        records = {}
        for _, record in pairs(old) do release(record) end
    end)
end
return M
