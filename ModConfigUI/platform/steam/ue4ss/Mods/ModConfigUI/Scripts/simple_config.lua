-- MCU simple mode: Mods/<ModName>/<ModName>.config.json, without a schema.
-- The owning mod creates its file and applies settings; this module only edits
-- scalar fields in existing objects, preserving unsupported fields. Requiring it performs no configuration I/O.
-- Usage inside MCU:
--   local configs = require("simple_config")
--   local values, err = configs.read("DamageNumber")
--   local ok, err = configs.update("DamageNumber", { FontSize = 28 })
--   values.FontSize = 30
--   local ok, err = configs.write("DamageNumber", values)
--   local ok, err = configs.reset("DamageNumber") -- delete; owning mod recreates on load
-- read returns a table or nil, error; write/update/reset return true or nil, error.
-- Successful changes optionally notify the owning mod to reload its own file.

local json = require("json")
local configIO = require("mcu_core.config_io")
local UEHelpers = require("UEHelpers")
local background = require('background')
local M = {}
local source = debug.getinfo(1, "S").source:gsub("\\", "/")
local modsDirectory = assert(source:match("^@(.+)/ModConfigUI/Scripts/[^/]+$"),
    "simple_config must be loaded from Mods/ModConfigUI/Scripts")

local function validModName(modName)
    return type(modName) == "string" and modName:match("^[%w_-][%w_. -]*$")
        and not modName:match("[. ]$")
end

local function configPath(modName)
    -- Accept one directory name, never a path supplied by a caller.
    if not validModName(modName) then
        return nil, "Invalid mod directory name"
    end
    local stem = modsDirectory .. "/" .. modName .. "/" .. modName
    return stem .. ".config.json"
end

local function validate(values)
    if type(values) ~= "table" or values == json.null
        or (getmetatable(values) or {}).__jsontype == "array" then
        return nil, "Simple configuration must be a JSON object"
    end
    for key, value in pairs(values) do
        if type(key) ~= "string" then return nil, "Configuration keys must be strings" end
    end
    return true
end

local function editable(value)
    local kind = type(value)
    return kind == 'boolean' or (kind == 'string' and utf8.len(value) ~= nil)
        or (kind == 'number' and value == value and math.abs(value) ~= math.huge)
end

local function notifyReload(modName, complete)
    -- Percent-escape punctuation instead of replacing it: A-B and A_B stay distinct.
    local id = modName:gsub('[^%w_]', function(char)
        return string.format('%%%02x', string.byte(char))
    end)
    local command = 'MCUChangeEvent_' .. id
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            local world = UEHelpers.GetWorld()
            if not world or not world:IsValid() then error('No valid world for reload notification') end
            UEHelpers.GetKismetSystemLibrary():ExecuteConsoleCommand(world, command, nil)
        end)
        if not ok then print('[ModConfigUI] Could not notify ' .. modName .. ': ' .. tostring(err) .. '\n') end
        if complete then complete() end
    end)
end

local function readCurrent(modName)
    local path, err = configPath(modName)
    if not path then return nil, err end
    local values, readError, original = configIO.readObject(path)
    if not values then return nil, readError, path end
    return values, nil, path, original
end

function M.read(modName)
    local values, err = readCurrent(modName)
    return values, err or (not values and "Configuration not found" or nil)
end

-- Only enumerate direct sibling mod directories. PBZ does not use UE4SS's
-- standard Binaries/Win64 layout, so avoid IterateGameDirectories here.
-- dir excludes reparse-point directories; no recursive scan or temporary files.
local directoryNames
local function directories()
    if directoryNames then return directoryNames end
    if modsDirectory:find('["%%!\r\n]') then
        return nil, "Mods directory contains characters unsupported by directory discovery"
    end
    local command = 'dir /b /a:d-l "' .. modsDirectory:gsub("/", "\\") .. '\\*" 2>nul'
    local opened, pipe, openError = pcall(io.popen, command, "r")
    if not opened or not pipe then
        return nil, "Cannot enumerate mods: " .. tostring(opened and openError or pipe)
    end
    local names = {}
    local listed, listError = pcall(function()
        for name in pipe:lines() do
            name = name:gsub("\r$", "")
            if validModName(name) then names[#names + 1] = name end
        end
    end)
    local closed = pipe:close()
    if not listed then return nil, "Cannot enumerate mods: " .. tostring(listError) end
    if not closed then return nil, "Mod directory enumeration failed" end
    table.sort(names)
    directoryNames = names
    return names
end

-- Background reads must not recover/rename .new files while a mod is saving.
local function readOnly(modName)
    local path, err = configPath(modName)
    if not path then return nil, err end
    local file, reason, code = io.open(path, 'rb')
    if not file and code == 2 then file, reason, code = io.open(path .. '.new', 'rb') end
    if not file then return nil, code ~= 2 and reason or nil end
    local text, readError = file:read('*a')
    file:close()
    if not text then return nil, readError end
    text = text:gsub('^\239\187\191', '')
    local values, position, decodeError = json.decode(text, 1, json.null)
    if decodeError or not position or text:sub(position):find('%S') then
        return nil, decodeError or 'Invalid JSON'
    end
    if type(values) ~= 'table' or values == json.null or (getmetatable(values) or {}).__jsontype == 'array' then
        return nil, 'Simple configuration must be a JSON object'
    end
    local fields = {}
    for key, value in pairs(values) do
        if type(key) == 'string' and utf8.len(key) and editable(value) then fields[key] = value end
    end
    return fields
end

local function discover(schemaIds)
    local names, reason = directories()
    if not names then return nil, reason end
    local configs, issues = {}, {}
    for _, name in ipairs(names) do
        if not schemaIds[name:lower()] then
            local values, err = readOnly(name)
            if values then
                configs[#configs + 1] = {name = name, values = values}
            elseif err then issues[#issues + 1] = {name = name, error = err} end
        end
    end
    return configs, issues
end

function M.discover(schemaIds, complete, current)
    background.run('simple.discover', function() return discover(schemaIds) end, complete, current)
end

function M.readAsync(modName, complete, current)
    background.run('simple.read:' .. modName, function() return readOnly(modName) end, complete, current)
end

local function save(modName, changes, replace, expected)
    local supported, err = validate(changes)
    if not supported then return nil, err end
    local current, path, original
    current, err, path, original = readCurrent(modName)
    if not current then return nil, err or "Configuration not found" end
    -- Without a schema, the existing file is the authority for keys and types.
    for key, value in pairs(changes) do
        if current[key] == nil then return nil, "Unknown configuration key: " .. key end
        if editable(current[key]) and (not editable(value) or type(value) ~= type(current[key])) then
            return nil, "Configuration type cannot change: " .. key
        end
        if editable(current[key]) and expected and current[key] ~= expected[key] then
            return nil, "Configuration changed outside this editor: " .. key
        end
    end
    if replace then
        for key in pairs(current) do
            if editable(current[key]) and changes[key] == nil then return nil, "Missing configuration key: " .. key end
        end
    end
    local changed = false
    for key, value in pairs(changes) do
        if editable(current[key]) then
            if current[key] ~= value then changed = true end
            current[key] = value
        end
    end
    if not changed then return true end
    local text
    text, err = configIO.write(current, path, original)
    if not text then return nil, err end
    notifyReload(modName)
    return true
end

-- Save all editable fields; retain unsupported fields from the current file.
function M.write(modName, values)
    return save(modName, values, true)
end

-- Change only the supplied keys, preserving every other setting in the file.
function M.update(modName, changes, expected)
    return save(modName, changes, false, expected)
end

-- The owning mod recreates its defaults on notification or its next load.
function M.reset(modName, complete)
    local path, err = configPath(modName)
    if not path then return nil, err end
    for _, target in ipairs({path .. ".new", path}) do
        local removed, removeError, code = os.remove(target)
        if not removed and code ~= 2 then return nil, "Cannot remove configuration: " .. tostring(removeError) end
    end
    notifyReload(modName, complete and function()
        -- Check once after synchronous command handlers have returned.
        complete(configIO.readObject(path))
    end)
    return true
end

return M
