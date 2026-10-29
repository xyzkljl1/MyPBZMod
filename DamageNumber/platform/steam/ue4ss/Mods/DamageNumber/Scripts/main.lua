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
        {key = "DisplaySection", type = "Separator", label = "Display Settings"},
        {key = "Enabled", type = "BoolToggle", label = "Enable Damage Numbers", onchange = applyConfig, default = true},
        {key = "MaxNumbers", type = "IntSlider", label = "Maximum Visible Numbers", onchange = applyConfig, default = 20, min = 1, max = 100, step = 1},

        {key = "FontSection", type = "Separator", label = "Fonts and Colors"},
        {key = "FontSize", type = "IntSlider", label = "Damage Font Size", onchange = applyConfig, default = 24, min = 8, max = 96, step = 1},
        {key = "HealFontSize", type = "IntSlider", label = "Healing Font Size", onchange = applyConfig, default = 24, min = 8, max = 96, step = 1},
        {key = "EnemyFontScale", type = "FloatSlider", label = "Enemy Number Scale", onchange = applyConfig, default = 1.0, min = 0.1, max = 3, step = 0.1},
        {key = "PlayerFontScale", type = "FloatSlider", label = "Player Number Scale", onchange = applyConfig, default = 0.7, min = 0.1, max = 3, step = 0.1},
        {key = "DamageColor", type = "TextBox", label = "Damage Color", onchange = applyConfig, default = "#FFFFFF",
            description = "Hex color, for example #FFFFFF.", minLength = 7, maxLength = 7, pattern = "^#%x%x%x%x%x%x$"},
        {key = "HealColor", type = "TextBox", label = "Healing Color", onchange = applyConfig, default = "#00FF00",
            description = "Hex color, for example #00FF00.", minLength = 7, maxLength = 7, pattern = "^#%x%x%x%x%x%x$"},

        {key = "AnimationSection", type = "Separator", label = "Animation"},
        {key = "DisplaySeconds", type = "FloatSlider", label = "Display Duration (seconds)", onchange = applyConfig, default = 1.5, min = 0.1, max = 10, step = 0.1},
        {key = "ShootDuration", type = "FloatSlider", label = "Pop-up Duration (seconds)", onchange = applyConfig, default = 0.3, min = 0.1, max = 3, step = 0.1},
        {key = "FadeOutDuration", type = "FloatSlider", label = "Fade-out Duration (seconds)", onchange = applyConfig, default = 0.3, min = 0.1, max = 3, step = 0.1},
        {key = "InitialScale", type = "FloatSlider", label = "Initial Scale", onchange = applyConfig, default = 1.5, min = 0.1, max = 4, step = 0.1},

        {key = "LayoutSection", type = "Separator", label = "Position and Layout"},
        {key = "RectHalfWidth", type = "FloatSlider", label = "Area Half Width", onchange = applyConfig, default = 150, min = 0, max = 600, step = 5},
        {key = "RectHalfHeight", type = "FloatSlider", label = "Area Half Height", onchange = applyConfig, default = 200, min = 0, max = 600, step = 5},
        {key = "XBaseOffset", type = "FloatSlider", label = "Horizontal Base Offset", onchange = applyConfig, default = 60, min = -500, max = 500, step = 5},
        {key = "YBaseOffset", type = "FloatSlider", label = "Vertical Base Offset", onchange = applyConfig, default = 30, min = -500, max = 500, step = 5},
        {key = "YStepSize", type = "FloatSlider", label = "Vertical Spacing", onchange = applyConfig, default = 35, min = 0, max = 150, step = 1},
        {key = "RandomJitterX", type = "FloatSlider", label = "Horizontal Random Jitter", onchange = applyConfig, default = 15, min = 0, max = 100, step = 1},
        {key = "RandomJitterY", type = "FloatSlider", label = "Vertical Random Jitter", onchange = applyConfig, default = 10, min = 0, max = 100, step = 1},
        {key = "MinPadding", type = "FloatSlider", label = "Minimum Spacing", onchange = applyConfig, default = 5, min = 0, max = 50, step = 1},
    },
}

local err
config, err = mcu.InitFromFile(schema)
if not config then
    print("[DamageNumber] " .. tostring(err) .. "\n")
    return
end

ExecuteInGameThread(applyConfig)
