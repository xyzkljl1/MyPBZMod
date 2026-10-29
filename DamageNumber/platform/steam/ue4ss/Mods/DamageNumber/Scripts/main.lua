ExecuteInGameThread(function()
    local system = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    if not system:IsValid() then error("[DamageNumber] KismetSystemLibrary unavailable") end
    system:ExecuteConsoleCommand(nil, "pbz.DamageNumber.Enabled 1", nil)
    print("[DamageNumber] pbz.DamageNumber.Enabled = "
        .. tostring(system:GetConsoleVariableIntValue("pbz.DamageNumber.Enabled")) .. "\n")
end)
