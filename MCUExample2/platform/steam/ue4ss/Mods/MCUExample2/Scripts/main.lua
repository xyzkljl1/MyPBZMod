local mcu = require("mcu_core")

local function printConfig(config)
    for key, value in pairs(config) do
        print("[MCUExample2] " .. key .. " = " .. tostring(value) .. "\n")
    end
end

local function onchange(value, oldValue, config)
    print("[MCUExample2] Changed: " .. tostring(oldValue) .. " -> " .. tostring(value) .. "\n")
    printConfig(config)
end

local schema = {
    updateInPlace = false, -- Defaults to true.
    -- If false, implement onchange for every value field and manually assign the received config to your mod's config variable.
    fields = {
        {key = "ColorOptionExample", type = "ColorBox", label = "Color preview", default = "#FF8800",
            description = "Enter #RRGGBB. Preview while typing; Enter or focus loss saves.", onchange = onchange},
        {key = "KeyOptionExample", type = "LuaKey", label = "Key binding", default = Key.F8,
            description = "Click and press one key. Esc cancels. The value is a UE4SS numeric key code.", onchange = onchange},
        {key = "GeneralSection", type = "Separator", label = "基本设置"},
        {key = "Enabled", type = "BoolToggle", label = "布尔开关", default = true,
            description = "点击当前值切换开启或关闭，修改后打印配置。", onchange = onchange},
        {key = "IntegerValue", type = "IntBox", label = "整数输入", default = 12,
            description = "输入整数，回车或移开焦点后保存。", onchange = onchange},
        {key = "FloatValue", type = "FloatBox", label = "浮点数输入", default = 1.25,
            description = "输入小数，不限制步长；回车或移开焦点后保存。", onchange = onchange},
        {
            key = "IntegerSlider", type = "IntSlider", label = "整数滑动条", default = 10,
            description = "拖动滑块选择整数，每次变化 5；松开后保存并打印配置。",
            min = 0, max = 100, step = 5, onchange = onchange,
        },
        {
            key = "FloatSlider", type = "FloatSlider", label = "浮点数滑动条", default = 0.5,
            description = "拖动滑块选择 0 到 1 之间的数值，步长为 0.1。",
            min = 0, max = 1, step = 0.1, onchange = onchange,
        },
        {
            key = "TextValue", type = "TextBox", label = "文本输入", default = "Hello MCU",
            description = "输入最多 40 个字符的文本，回车或移开焦点后保存。",
            maxLength = 40, onchange = onchange,
        },
        {
            key = "IntegerChoice", type = "IntSelect", label = "整数选项", default = 2,
            description = "使用左右箭头选择少、中或多，保存的是对应整数 1、2 或 3。",
            options = {{value = 1, label = "少"}, {value = 2, label = "中"}, {value = 3, label = "多"}},
            onchange = onchange,
        },
        {
            key = "FloatChoice", type = "FloatSelect", label = "浮点数选项", default = 1.0,
            description = "使用左右箭头选择倍率，保存的是选项对应的小数。",
            options = {{value = 0.5, label = "半倍"}, {value = 1.0, label = "一倍"}, {value = 1.5, label = "一点五倍"}},
            onchange = onchange,
        },
        {
            key = "TextChoice", type = "TextSelect", label = "文本选项", default = "normal",
            description = "使用左右箭头选择显示模式，保存的是 compact、normal 或 large。",
            options = {{value = "compact", label = "紧凑"}, {value = "normal", label = "标准"}, {value = "large", label = "宽松"}},
            onchange = onchange,
        },
        {
            key = "TriggerSomething", type = "Button", label = "这是一个按钮",
            description = "点击后打印当前配置，不修改任何配置值。",
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
