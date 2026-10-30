-- MCU schema compilation and value validation. No file or engine access.
local M = {}
local keys = require('mcu_core.key_codes')
local kinds = {
    BoolToggle = 'boolean', IntBox = 'integer', FloatBox = 'number',
    IntSlider = 'integer', FloatSlider = 'number', TextBox = 'string',
    IntSelect = 'integer', FloatSelect = 'number', TextSelect = 'string', Button = 'button', Separator = 'separator',
    ColorBox = 'string', LuaKey = 'integer', BPKey = 'string',
}

local function finite(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end
local function integer(value)
    return finite(value) and math.tointeger(value) ~= nil
end
local function array(value)
    if type(value) ~= 'table' then return false end
    local count = 0
    for key in pairs(value) do
        if not integer(key) or key < 1 then return false end
        count = count + 1
    end
    for index = 1, count do if value[index] == nil then return false end end
    return true
end
local function copy(value)
    if type(value) ~= 'table' then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end
M.copy = copy

function M.validId(id)
    if type(id) ~= 'string' or not id:match('^[A-Za-z0-9_-]+$') or #id > 80 then return false end
    local name = id:upper()
    return name ~= 'CON' and name ~= 'PRN' and name ~= 'AUX' and name ~= 'NUL'
        and not name:match('^COM[1-9]$') and not name:match('^LPT[1-9]$')
end

local function onGrid(value, origin, step, kind)
    if kind == 'integer' then
        return math.tointeger(value) % math.tointeger(step) == math.tointeger(origin) % math.tointeger(step)
    end
    local units = (value - origin) / step
    return finite(units) and math.abs(units - math.floor(units + 0.5)) <= 1e-7
end

function M.validate(field, value)
    local kind, params = field.kind, field.params
    if kind == 'button' or kind == 'separator' then return nil, field.type .. ' has no configuration value' end
    if kind == 'integer' then
        if not integer(value) then return nil, 'Expected an integer representable by Lua' end
    elseif kind == 'number' then
        if not finite(value) then return nil, 'Expected a finite number' end
    elseif type(value) ~= kind then
        return nil, 'Expected ' .. kind
    end
    if field.type == 'ColorBox' then
        return value:match('^#%x%x%x%x%x%x$') ~= nil or nil, 'Expected #RRGGBB'
    elseif field.type == 'LuaKey' then
        return keys.names[value] ~= nil or nil, 'Unsupported keyboard/mouse key code'
    elseif field.type == 'BPKey' then
        return keys.codes[value] ~= nil or nil, 'Unsupported UE keyboard/mouse key name'
    end
    if field.type:find('Select$', 1) then
        for _, option in ipairs(params.options) do if option.value == value then return true end end
        return nil, 'Value is not an allowed option'
    end
    if kind == 'number' or kind == 'integer' then
        if params.min ~= nil and value < params.min then return nil, 'Value is below min' end
        if params.max ~= nil and value > params.max then return nil, 'Value is above max' end
        if field.type:find('Slider$') and params.step and not onGrid(value, params.min or 0, params.step, kind) then
            return nil, 'Value does not match step'
        end
    elseif kind == 'string' then
        local length = utf8.len(value)
        if not length then return nil, 'Text must be valid UTF-8' end
        if params.minLength and length < params.minLength then return nil, 'Text is too short' end
        if params.maxLength and length > params.maxLength then return nil, 'Text is too long' end
        if params.pattern then
            local ok, match = pcall(string.match, value, params.pattern)
            if not ok then return nil, 'Invalid text pattern: ' .. tostring(match) end
            if not match then return nil, 'Text does not match pattern' end
        end
    end
    return true
end

-- Snapshots intentionally omit callbacks and the internal kind field.
function M.validateMetadata(field, value)
    local kind = kinds[field.type]
    if not kind then return nil, 'Unknown control type' end
    return M.validate({type = field.type, kind = kind, params = field.params or {}}, value)
end

local fieldProperties = {key = true, type = true, label = true, description = true,
    default = true, onchange = true, onclick = true}

local function parameters(source, field)
    if source.params ~= nil then return nil, 'Define parameters directly on the field, without params' end
    local allowed = {}
    if field.type == 'ColorBox' or field.type == 'LuaKey' or field.type == 'BPKey' then
        -- These controls have a fixed format, not numeric/text range parameters.
    elseif field.type:find('Select$') then allowed.options = true
    elseif field.kind == 'number' or field.kind == 'integer' then
        allowed = {min = true, max = true, step = field.type:find('Slider$') ~= nil}
    elseif field.kind == 'string' then
        allowed = {minLength = true, maxLength = true, pattern = true}
    end
    for key in pairs(source) do
        if not allowed[key] and not fieldProperties[key] then return nil, 'Unsupported parameter: ' .. tostring(key) end
    end
    local params = {}
    if allowed.options then
        if not array(source.options) or #source.options == 0 then return nil, 'options must be a nonempty ordered array' end
        params.options = {}
        local seen = {}
        for _, option in ipairs(source.options) do
            if type(option) ~= 'table' then return nil, 'Each option must contain value and optional label' end
            local value = option.value
            local valid = field.kind == 'integer' and integer(value)
                or field.kind == 'number' and finite(value)
                or field.kind == 'string' and type(value) == 'string' and utf8.len(value) ~= nil
            if not valid then return nil, 'Option has the wrong value type' end
            if seen[value] then return nil, 'Duplicate option value' end
            if option.label ~= nil and (type(option.label) ~= 'string' or not utf8.len(option.label)) then
                return nil, 'Option label must be valid UTF-8 text'
            end
            seen[value] = true
            params.options[#params.options + 1] = {value = value, label = option.label or tostring(value)}
        end
    elseif allowed.min then
        for _, key in ipairs({'min', 'max', 'step'}) do
            local value = source[key]
            if value ~= nil then
                if not finite(value) or (field.kind == 'integer' and not integer(value)) then
                    return nil, key .. ' has the wrong numeric type'
                end
                params[key] = value
            end
        end
        if params.min and params.max and params.min > params.max then return nil, 'min must not exceed max' end
        if params.step and params.step <= 0 then return nil, 'step must be positive' end
        if field.type:find('Slider$') and (params.min == nil or params.max == nil or params.step == nil) then
            return nil, 'Sliders require min, max and step'
        end
    elseif allowed.minLength then
        for _, key in ipairs({'minLength', 'maxLength'}) do
            local value = source[key]
            if value ~= nil and (not integer(value) or value < 0) then return nil, key .. ' must be a nonnegative integer' end
            params[key] = value
        end
        if params.minLength and params.maxLength and params.minLength > params.maxLength then
            return nil, 'minLength must not exceed maxLength'
        end
        if source.pattern ~= nil then
            if type(source.pattern) ~= 'string' or not pcall(string.match, '', source.pattern) then
                return nil, 'pattern must be a valid Lua pattern'
            end
            params.pattern = source.pattern
        end
    end
    return params
end

local function defaultValue(field)
    local params, kind = field.params, field.kind
    if field.type == 'ColorBox' then return '#FFFFFF' end
    if field.type == 'BPKey' then return 'None' end
    if field.type:find('Select$') then return params.options[1].value end
    if kind == 'boolean' then return false end
    if kind == 'string' then return '' end
    if field.type:find('Slider$') then return params.min end
    local value = 0
    if params.min and value < params.min then value = params.min end
    if params.max and value > params.max then value = params.max end
    return value
end

function M.compile(source, id)
    if type(source) ~= 'table' then return nil, 'schema must be a table' end
    if source.id ~= nil then return nil, 'Do not specify id; InitFromFile uses the calling Mod directory' end
    if not M.validId(id) then return nil, 'Calling Mod directory must be a safe ASCII identifier (1-80 characters)' end
    if not array(source.fields) then return nil, 'fields must be a dense ordered array with explicit keys' end
    if source.updateInPlace ~= nil and type(source.updateInPlace) ~= 'boolean' then return nil, 'updateInPlace must be boolean' end
    if source.onchange ~= nil or source.migrations ~= nil then return nil, 'Use per-field onchange; schema migrations are not supported' end
    local schema = {id = id, updateInPlace = source.updateInPlace ~= false,
        fields = {}, byKey = {}, defaults = {}}
    for index, item in ipairs(source.fields) do
        local function fail(reason) return nil, 'fields[' .. index .. ']: ' .. reason end
        if type(item) ~= 'table' then return fail('Expected a field table') end
        if type(item.key) ~= 'string' or item.key == '' or not utf8.len(item.key) then return fail('key must be nonempty UTF-8 text') end
        if schema.byKey[item.key] then return fail('Duplicate key: ' .. item.key) end
        if not kinds[item.type] then return fail('Unknown type: ' .. tostring(item.type)) end
        if item.control ~= nil or item.order ~= nil then return fail('Use type and the fields array order') end
        for _, key in ipairs({'label', 'description'}) do
            if item[key] ~= nil and (type(item[key]) ~= 'string' or not utf8.len(item[key])) then
                return fail(key .. ' must be valid UTF-8 text')
            end
        end
        local field = {key = item.key, index = index, type = item.type, kind = kinds[item.type], label = item.label or item.key,
            description = item.description, onchange = item.onchange, onclick = item.onclick}
        if field.onchange ~= nil and type(field.onchange) ~= 'function' then return fail('onchange must be a function') end
        if field.kind == 'button' then
            if item.default ~= nil or item.onchange ~= nil then return fail('Button cannot have default or onchange') end
            if type(field.onclick) ~= 'function' then return fail('Button requires onclick') end
        elseif field.kind == 'separator' then
            if item.default ~= nil or item.onchange ~= nil or item.onclick ~= nil then
                return fail('Separator cannot have default, onchange or onclick')
            end
        elseif field.onclick ~= nil then return fail('Only Button supports onclick') end
        local err
        field.params, err = parameters(item, field)
        if not field.params then return fail(err) end
        if field.kind ~= 'button' and field.kind ~= 'separator' then
            if item.default ~= nil then field.default = item.default else field.default = defaultValue(field) end
            local valid, reason = M.validate(field, field.default)
            if not valid then return fail('Invalid default; specify a valid default or correct parameters: ' .. reason) end
            if field.type == 'ColorBox' then field.default = field.default:upper() end
            schema.defaults[field.key] = field.default
        end
        schema.fields[#schema.fields + 1], schema.byKey[field.key] = field, field
    end
    return schema
end

function M.reconcile(schema, saved)
    local values = copy(schema.defaults)
    for key, value in pairs(saved) do
        local field = schema.byKey[key]
        if field and schema.defaults[key] ~= nil and M.validate(field, value) then
            values[key] = field.type == 'ColorBox' and value:upper() or value
        end
    end
    return values
end

function M.metadata(schema)
    local fields = setmetatable({}, {__jsontype = 'array'})
    for _, field in ipairs(schema.fields) do
        fields[#fields + 1] = {key = field.key, type = field.type, label = field.label,
            description = field.description, default = field.default,
            params = setmetatable(copy(field.params), {__jsontype = 'object'})}
    end
    return {id = schema.id, updateInPlace = schema.updateInPlace, fields = fields}
end

return M
