-- English is complete; locale JSON files only override MCU's own UI strings.
local json = require('json')
local root = debug.getinfo(1, 'S').source:gsub('\\', '/'):match('^@(.+)/Scripts/[^/]+$')
local english = {
    mod_tab = 'MOD',
    unbound = 'Unbound',
    press_key = 'Press a key (Esc to cancel)',
    mod_settings = 'Mod Settings',
    off = 'Off',
    on = 'On',
    reset_defaults = 'Reset to Defaults',
    min_value = 'Minimum: {value}',
    max_value = 'Maximum: {value}',
    default_value = 'Default: {value}',
    reset_failed = 'Reset failed',
    reset_done = 'Config deleted. Reload this mod or restart the game.',
    save_failed = '{name} (save failed)',
    no_fields = 'No editable settings.',
    no_configs = 'No editable configurations found.',
    loading_configs = 'Loading configurations...',
    discovery_failed = 'Cannot find configurations. See the UE4SS log.',
    config_read_failed = '{mod}: Cannot read configuration. See the UE4SS log.',
}
local aliases = {zh = 'zh-Hans', ['zh-CN'] = 'zh-Hans', ['zh-SG'] = 'zh-Hans',
    ['zh-TW'] = 'zh-Hant', ['zh-HK'] = 'zh-Hant', ['zh-MO'] = 'zh-Hant'}

local function language()
    local ok, tag = pcall(function()
        local library = StaticFindObject('/Script/Engine.Default__KismetInternationalizationLibrary')
        local value = library:GetCurrentLanguage()
        return type(value) == 'string' and value or value:ToString()
    end)
    if not ok or type(tag) ~= 'string' then return 'en' end
    tag = tag:gsub('_', '-')
    if not tag:match('^%a[%w%-]*$') or tag:find('%-%-') or tag:sub(-1) == '-' then return 'en' end
    local parts = {}
    for part in tag:gmatch('[^-]+') do
        part = part:lower()
        if #parts > 0 then
            if #part == 4 then part = part:sub(1, 1):upper() .. part:sub(2)
            elseif #part == 2 then part = part:upper() end
        end
        parts[#parts + 1] = part
    end
    tag = table.concat(parts, '-')
    return aliases[tag] or tag
end

-- Called only by the background worker; never query UE objects here.
local function load(tag)
    local values, chain = {}, {}
    local parent = tag
    while parent do chain[#chain + 1] = parent; parent = parent:match('^(.*)%-[^-]+$') end
    for index = #chain, 1, -1 do
        local file = root and chain[index] ~= 'en' and io.open(root .. '/locales/' .. chain[index] .. '.json', 'rb')
        if file then
            local text = file:read('*a'); file:close()
            text = (text or ''):gsub('^\239\187\191', '')
            local ok, data, position, err = pcall(json.decode, text, 1, json.null)
            if ok and not err and type(data) == 'table' and position and not text:sub(position):find('%S') then
                for key, value in pairs(data) do
                    if english[key] and type(value) == 'string' and value ~= '' and utf8.len(value) then values[key] = value end
                end
            end
        end
    end
    return values
end

local function translator(values)
    return function(key, args)
        local text = values[key] or english[key] or key
        return (text:gsub('{([%w_]+)}', function(name)
            return args and args[name] ~= nil and tostring(args[name]) or '{' .. name .. '}'
        end))
    end
end

local fallback, cached = translator({}), {}
local function get()
    local tag = language()
    return cached[tag] or fallback, tag
end

local function apply(tag, values)
    cached[tag] = translator(values)
    return cached[tag]
end

return {get = get, load = load, apply = apply}
