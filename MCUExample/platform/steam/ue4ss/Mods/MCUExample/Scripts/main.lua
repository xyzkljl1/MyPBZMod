local json = require("json")
local configPath = "../../../platform/steam/ue4ss/Mods/MCUExample/MCUExample.config.json"
local config = {
    BooleanValue = true,
    NumberValue = 12.5,
    TextValue = "Hello MCU",
}

for key, value in pairs(json.load(configPath) or {}) do
    config[key] = value
end
json.dump(config, configPath)

for key, value in pairs(config) do
    print("[MCUExample] " .. key .. " = " .. tostring(value) .. "\n")
end
