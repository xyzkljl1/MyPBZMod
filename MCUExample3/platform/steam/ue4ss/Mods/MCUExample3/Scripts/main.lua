local mcu = require("mcu_core")
local config = mcu.InitFromFile({
    fields = {{key = "Enabled", type = "BoolToggle", label = "FirstConfig", default = true}},
})
print("[MCUExample3] Enabled = " .. tostring(config.Enabled) .. "\n")
