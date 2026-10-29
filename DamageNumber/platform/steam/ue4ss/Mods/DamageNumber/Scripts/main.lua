local config = {
    Enabled = true,
    FontSize = 24,
    HealFontSize = 24,
    EnemyFontScale = 1.0,
    PlayerFontScale = 0.7,
    DamageColor = "#FFFFFF",
    HealColor = "#00FF00",
    DisplaySeconds = 1.5,
    MaxNumbers = 20,
    ShootDuration = 0.3,
    FadeOutDuration = 0.3,
    InitialScale = 1.5,
    RectHalfWidth = 150,
    RectHalfHeight = 200,
    XBaseOffset = 60,
    YBaseOffset = 30,
    YStepSize = 35,
    RandomJitterX = 15,
    RandomJitterY = 10,
    MinPadding = 5,
}

local scripts = debug.getinfo(1, "S").source:match("^@(.+[/\\])")
local json = require("json")
local configPath = scripts .. "../DamageNumber.config.json"
local saved = json.load(configPath)
if saved then
    for key, value in pairs(saved) do config[key] = value end
else
    json.dump(config, configPath)
end

local function setColor(target, hex)
    for index, channel in ipairs({ "R", "G", "B" }) do
        local value = tonumber(hex:sub(index * 2, index * 2 + 1), 16) / 255
        target[channel] = value <= 0.04045 and value / 12.92 or ((value + 0.055) / 1.055) ^ 2.4
    end
    target.A = 1
end

ExecuteInGameThread(function()
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
end)
