-- Optional schema display translations. Never change registry snapshots or configuration values.
local json = require('json')
local model = require('mcu_core.schema')
local source = debug.getinfo(1, 'S').source:gsub('\\', '/')
local modsDirectory = assert(source:match('^@(.+)/ModConfigUI/Scripts/[^/]+$'))
local M = {}

local function object(value)
    return type(value) == 'table' and value ~= json.null
        and (getmetatable(value) or {}).__jsontype ~= 'array'
end

local function readPack(path)
    local file, err, code = io.open(path, 'rb')
    if not file then return nil, code ~= 2 and err or nil end
    local text, readError = file:read('*a')
    file:close()
    if not text then return nil, readError end
    text = text:gsub('^\239\187\191', '')
    local ok, pack, position, reason = pcall(json.decode, text, 1, json.null)
    if not ok or reason or not position or text:sub(position):find('%S')
        or not object(pack) or not object(pack.fields) then
        return nil, 'Expected a JSON object with a fields object'
    end
    return pack
end

function M.fields(schema, language)
    -- Both names are supplied by MCU, not by the language pack.
    if not model.validId(schema.id) or not language:match('^[%a][%w%-]*$') then return schema.fields end
    local path = modsDirectory .. '/' .. schema.id .. '/' .. schema.id .. '.lang.' .. language .. '.json'
    local pack, err = readPack(path)
    if err then print('[ModConfigUI] Cannot read language pack ' .. path .. ': ' .. tostring(err) .. '\n') end
    if not pack then return schema.fields end
    local fields = model.copy(schema.fields)
    for _, field in ipairs(fields) do
        local translated = pack.fields[field.key]
        if object(translated) then
            for _, name in ipairs({'label', 'description'}) do
                if type(translated[name]) == 'string' and utf8.len(translated[name]) then field[name] = translated[name] end
            end
            if field.type:find('Select$') and type(translated.options) == 'table' then
                for _, option in ipairs(field.params.options) do
                    for _, translation in ipairs(translated.options) do
                        if object(translation) and translation.value == option.value
                            and type(translation.label) == 'string' and utf8.len(translation.label) then
                            option.label = translation.label
                            break
                        end
                    end
                end
            end
        end
    end
    return fields
end

return M
