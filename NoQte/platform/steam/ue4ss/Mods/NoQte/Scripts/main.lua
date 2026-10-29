ExecuteInGameThread(function()
    local system = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    if not system:IsValid() then error("[NoQte] KismetSystemLibrary unavailable") end
    for _, name in ipairs({ "PBZPSOTest.SkipQTE", "PBZPSOCombatTest.SkipQTE" }) do
        system:ExecuteConsoleCommand(nil, name .. " 1", nil)
        print(string.format("[NoQte] %s = %s\n", name, tostring(system:GetConsoleVariableIntValue(name))))
    end
end)
