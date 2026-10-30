local mcu = require("mcu_core")

local function setSkip(name, enabled)
    local system = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    if not system:IsValid() then error("[NoQte] KismetSystemLibrary unavailable") end
    system:ExecuteConsoleCommand(nil, name .. (enabled and " 1" or " 0"), nil)
    print(string.format("[NoQte] %s = %s\n", name, tostring(system:GetConsoleVariableIntValue(name))))
end

local config, err = mcu.InitFromFile({
    fields = {
        {
            key = "SkipQTE", type = "BoolToggle", label = "跳过 QTE", default = true,
            description = "开启跳过，关闭恢复游戏原有 QTE 流程。",
            onchange = function(enabled) setSkip("PBZPSOTest.SkipQTE", enabled) end,
        },
        {
            key = "SkipCombatQTE", type = "BoolToggle", label = "跳过战斗 QTE", default = true,
            description = "独立控制战斗 QTE 是否跳过。",
            onchange = function(enabled) setSkip("PBZPSOCombatTest.SkipQTE", enabled) end,
        },
    },
})
if not config then
    print("[NoQte] " .. tostring(err) .. "\n")
    return
end

ExecuteInGameThread(function()
    setSkip("PBZPSOTest.SkipQTE", config.SkipQTE)
    setSkip("PBZPSOCombatTest.SkipQTE", config.SkipCombatQTE)
end)
