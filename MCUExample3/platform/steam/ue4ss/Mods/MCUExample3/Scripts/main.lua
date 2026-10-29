local mcu = require("mcu_schema")
local config = mcu.InitFromFile({
    id = "MCUExample3",
    fields = {{key = "Enabled", type = "BoolToggle", label = "FirstConfig", default = true}},
})
print("[MCUExample3] Enabled = " .. tostring(config.Enabled) .. "\n")
