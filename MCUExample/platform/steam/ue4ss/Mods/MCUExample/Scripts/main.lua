local defaults = {
    BooleanValue = true,
    NumberValue = 12.5,
    TextValue = "Hello MCU",
}

local json = require("json")
local configPath = "../../../platform/steam/ue4ss/Mods/MCUExample/MCUExample.config.json"
local config

local function loadConfig()
    -- NOTICE: When adding settings, initialize config from defaults and overlay file values per key instead of replacing the table.
    config = json.load(configPath)
    if not config then
        config = defaults
        json.dump(config, configPath)
    end

    for key, value in pairs(config) do
        print("[MCUExample] " .. key .. " = " .. tostring(value) .. "\n")
    end
end

loadConfig()

-- Reload config
RegisterConsoleCommandGlobalHandler("MCUChangeEvent_MCUExample", function()
    loadConfig()
    return true
end)
