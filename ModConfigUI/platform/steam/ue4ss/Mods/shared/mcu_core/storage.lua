-- schema.id is the installed Mod directory name; persist flat configuration values.
local configIO = require('mcu_core.config_io')
local source = debug.getinfo(1, 'S').source:gsub('\\', '/')
local mods = assert(source:match('^@(.+)/shared/mcu_core/[^/]+$'), 'Unexpected mcu_core installation path')
local M = {}

local function pathFor(id)
    return mods .. '/' .. id .. '/' .. id .. '.schemaconfig.json'
end

function M.load(id) return configIO.readObject(pathFor(id)) end

function M.save(id, config, expected, force)
    return configIO.write(setmetatable(config, {__jsontype = 'object'}), pathFor(id), expected or false, force)
end

return M
