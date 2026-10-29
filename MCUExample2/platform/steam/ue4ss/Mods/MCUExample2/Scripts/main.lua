local mcu = require("mcu_schema")

local function printConfig(config)
    for key, value in pairs(config) do
        print("[MCUExample2] " .. key .. " = " .. tostring(value) .. "\n")
    end
end

local function onchange(value, oldValue, config, context)
    print("[MCUExample2] " .. context.key .. ": " .. tostring(oldValue) .. " -> " .. tostring(value) .. "\n")
    printConfig(config)
end

local schema = {
    id = "MCUExample2",
    updateInPlace = true, -- Defaults to true.
    -- If false, implement onchange for every value field and manually assign the received config to your mod's config variable.
    fields = {
        {key = "Enabled", type = "BoolToggle", label = "布尔开关", default = true, onchange = onchange},
        {key = "IntegerValue", type = "IntBox", label = "整数输入", default = 12, onchange = onchange},
        {key = "FloatValue", type = "FloatBox", label = "浮点数输入", default = 1.25, onchange = onchange},
        {
            key = "IntegerSlider", type = "IntSlider", label = "整数滑动条", default = 10,
            params = {min = 0, max = 100, step = 5}, onchange = onchange,
        },
        {
            key = "FloatSlider", type = "FloatSlider", label = "浮点数滑动条", default = 0.5,
            params = {min = 0, max = 1, step = 0.1}, onchange = onchange,
        },
        {
            key = "TextValue", type = "TextBox", label = "文本输入", default = "Hello MCU",
            params = {maxLength = 40}, onchange = onchange,
        },
        {
            key = "IntegerChoice", type = "IntSelect", label = "整数选项", default = 2,
            params = {options = {{value = 1, label = "少"}, {value = 2, label = "中"}, {value = 3, label = "多"}}},
            onchange = onchange,
        },
        {
            key = "FloatChoice", type = "FloatSelect", label = "浮点数选项", default = 1.0,
            params = {options = {{value = 0.5, label = "半倍"}, {value = 1.0, label = "一倍"}, {value = 1.5, label = "一点五倍"}}},
            onchange = onchange,
        },
        {
            key = "TextChoice", type = "TextSelect", label = "文本选项", default = "normal",
            params = {options = {{value = "compact", label = "紧凑"}, {value = "normal", label = "标准"}, {value = "large", label = "宽松"}}},
            onchange = onchange,
        },
        {
            key = "TriggerSomething", type = "Button", label = "触发示例操作",
            onclick = printConfig,
        },
    },
}

local config, err = mcu.InitFromFile(schema)
if not config then
    print("[MCUExample2] " .. tostring(err) .. "\n")
    return
end

-- ForceSaveConfig validates and force-saves the entire config after code changes, without calling onchange.
-- MCU saves UI edits automatically, so you normally do not need to call this function.
-- config = mcu.ForceSaveConfig(config)

printConfig(config)
