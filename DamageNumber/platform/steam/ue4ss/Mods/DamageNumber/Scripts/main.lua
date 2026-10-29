local mcu = require("mcu_core")
local config

local function setColor(target, hex)
    for index, channel in ipairs({ "R", "G", "B" }) do
        local value = tonumber(hex:sub(index * 2, index * 2 + 1), 16) / 255
        target[channel] = value <= 0.04045 and value / 12.92 or ((value + 0.055) / 1.055) ^ 2.4
    end
    target.A = 1
end

local function applyConfig()
    local path = "/PBZCombatAsset/UI/DamageNumber/DA_DamageNumberConfig.DA_DamageNumberConfig"
    local asset = StaticFindObject(path)
    if not asset:IsValid() then asset = LoadAsset(path) end
    asset.DamageFont.Size = config.FontSize
    asset.HealFont.Size = config.HealFontSize
    asset.EnemyFontScale = config.EnemyFontScale
    asset.PlayerFontScale = config.PlayerFontScale
    setColor(asset.DefaultDisplayInfo.Color, config.DamageColor)
    asset.DamageTypeDisplayInfos:ForEach(function(_, element)
        setColor(element:get().Color, config.DamageColor)
    end)
    setColor(asset.HealColor, config.HealColor)
    asset.TotalLifetime = config.DisplaySeconds
    asset.MaxActiveNumbers = config.MaxNumbers
    asset.ShootDuration = config.ShootDuration
    asset.FadeOutDuration = config.FadeOutDuration
    asset.InitialScale = config.InitialScale
    asset.RectHalfWidth = config.RectHalfWidth
    asset.RectHalfHeight = config.RectHalfHeight
    asset.XBaseOffset = config.XBaseOffset
    asset.YBaseOffset = config.YBaseOffset
    asset.YStepSize = config.YStepSize
    asset.RandomJitterX = config.RandomJitterX
    asset.RandomJitterY = config.RandomJitterY
    asset.MinPadding = config.MinPadding

    local system = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    system:ExecuteConsoleCommand(nil, "pbz.DamageNumber.Enabled " .. (config.Enabled and "1" or "0"), nil)
    print("[DamageNumber] Config applied.\n")
end

local schema = {
    fields = {
        {key = "DisplaySection", type = "Separator", label = "显示设置"},
        {key = "Enabled", type = "BoolToggle", label = "启用伤害数字", onchange = applyConfig, default = true},
        {key = "MaxNumbers", type = "IntSlider", label = "同时显示的数字上限", onchange = applyConfig, default = 20, min = 1, max = 100, step = 1},

        {key = "FontSection", type = "Separator", label = "字体与颜色"},
        {key = "FontSize", type = "IntSlider", label = "伤害字号", onchange = applyConfig, default = 24, min = 8, max = 96, step = 1},
        {key = "HealFontSize", type = "IntSlider", label = "治疗字号", onchange = applyConfig, default = 24, min = 8, max = 96, step = 1},
        {key = "EnemyFontScale", type = "FloatSlider", label = "敌人数字缩放", onchange = applyConfig, default = 1.0, min = 0.1, max = 3, step = 0.1},
        {key = "PlayerFontScale", type = "FloatSlider", label = "玩家数字缩放", onchange = applyConfig, default = 0.7, min = 0.1, max = 3, step = 0.1},
        {key = "DamageColor", type = "TextBox", label = "伤害颜色", onchange = applyConfig, default = "#FFFFFF",
            description = "十六进制颜色，例如 #FFFFFF。", minLength = 7, maxLength = 7, pattern = "^#%x%x%x%x%x%x$"},
        {key = "HealColor", type = "TextBox", label = "治疗颜色", onchange = applyConfig, default = "#00FF00",
            description = "十六进制颜色，例如 #00FF00。", minLength = 7, maxLength = 7, pattern = "^#%x%x%x%x%x%x$"},

        {key = "AnimationSection", type = "Separator", label = "动画"},
        {key = "DisplaySeconds", type = "FloatSlider", label = "显示时长（秒）", onchange = applyConfig, default = 1.5, min = 0.1, max = 10, step = 0.1},
        {key = "ShootDuration", type = "FloatSlider", label = "弹出时长（秒）", onchange = applyConfig, default = 0.3, min = 0.1, max = 3, step = 0.1},
        {key = "FadeOutDuration", type = "FloatSlider", label = "淡出时长（秒）", onchange = applyConfig, default = 0.3, min = 0.1, max = 3, step = 0.1},
        {key = "InitialScale", type = "FloatSlider", label = "初始缩放", onchange = applyConfig, default = 1.5, min = 0.1, max = 4, step = 0.1},

        {key = "LayoutSection", type = "Separator", label = "位置与布局"},
        {key = "RectHalfWidth", type = "FloatSlider", label = "分布区域半宽", onchange = applyConfig, default = 150, min = 0, max = 600, step = 5},
        {key = "RectHalfHeight", type = "FloatSlider", label = "分布区域半高", onchange = applyConfig, default = 200, min = 0, max = 600, step = 5},
        {key = "XBaseOffset", type = "FloatSlider", label = "水平基础偏移", onchange = applyConfig, default = 60, min = -500, max = 500, step = 5},
        {key = "YBaseOffset", type = "FloatSlider", label = "垂直基础偏移", onchange = applyConfig, default = 30, min = -500, max = 500, step = 5},
        {key = "YStepSize", type = "FloatSlider", label = "纵向步距", onchange = applyConfig, default = 35, min = 0, max = 150, step = 1},
        {key = "RandomJitterX", type = "FloatSlider", label = "水平随机扰动", onchange = applyConfig, default = 15, min = 0, max = 100, step = 1},
        {key = "RandomJitterY", type = "FloatSlider", label = "垂直随机扰动", onchange = applyConfig, default = 10, min = 0, max = 100, step = 1},
        {key = "MinPadding", type = "FloatSlider", label = "最小间距", onchange = applyConfig, default = 5, min = 0, max = 50, step = 1},
    },
}

local err
config, err = mcu.InitFromFile(schema)
if not config then
    print("[DamageNumber] " .. tostring(err) .. "\n")
    return
end

ExecuteInGameThread(applyConfig)
