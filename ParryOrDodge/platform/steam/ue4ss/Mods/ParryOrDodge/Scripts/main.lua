-- Supplement the local player's native frame query; keep the native counter pipeline.
local QUERY = "/Script/PBZDeflectSystem.DeflectComponent:GetNearestValidReceivedFrame"
local IMPACT = "/PBZDeflectSystem/Abilities/BP_StanceAction_Base_Player.BP_StanceAction_Base_Player_C:On Impact"
local config, err = require("mcu_core").InitFromFile({
    fields = {
        { key = "ParryRed", type = "BoolToggle", label = "Parry Red Attacks", default = true,
          description = "Perfectly parry red attacks and enter the native counter flow. Holding ordinary block does not keep this active." },
        { key = "DodgeBlue", type = "BoolToggle", label = "Counter Blue Attacks with Perfect Dodge", default = true,
          description = "Trigger native counters when perfectly dodging blue attacks. Preserve native timing, range and counter selection." },
    },
})
if not config then print("[ParryOrDodge] " .. tostring(err) .. "\n"); return end

local busy, stopped = false, false
local cachedPawn, passive, system, attackClass, playerClass
local lastMatch, matchLogs = {}, 0
local redComponent, redFrames, impactPre, impactPost, counterUtils
redFrames = {}
local function valid(object) return object ~= nil and object:IsValid() end
local function same(a, b) return valid(a) and valid(b) and a:GetAddress() == b:GetAddress() end

local function counterRed(context, handle, result, _, _, _, _, broken)
    if stopped or not config.ParryRed then return end
    local ability = context:get()
    if not valid(ability) then return end
    local component = ability["Deflect Component"]
    if not valid(component) or component:GetAddress() ~= redComponent then return end
    local pending = redFrames[handle:get()]
    if not pending or pending.done then return end
    pending.done = true -- Consume before calling game code, including re-entrant callbacks.
    local data = result:get()
    local action = data.SourceAction:Get()
    if broken:get() or not ability:IsAbilityRunning()
        or data.DeflectResult.TagName:ToString() ~= "Deflect.Result.Perfect"
        or not valid(action) or action:GetAddress() ~= pending.action
        or action.DeflectBulletType ~= 3
        or math.abs(data.HitGameTime - pending.time) > 0.01 then return end
    local pawn = component:GetOwner()
    if not same(pawn, ability:GetAvatarActorFromActorInfo()) then return end
    local controller = pawn:GetController()
    if not valid(controller) or not controller:IsLocalPlayerController() then return end
    if not valid(data.SourceAvatar) then return end
    -- If the game already prepared this frame, leave its immediate/delayed counter alone.
    local prepared = component.PerfectDodgeResultData
    if prepared.HitGameTime == data.HitGameTime and same(prepared.SourceAction:Get(), action) then return end
    if not valid(counterUtils) then
        counterUtils = StaticFindObject("/PBZDeflectSystem/BPL_DeflectUtils.Default__BPL_DeflectUtils_C")
    end
    if not valid(counterUtils) then return end
    -- Native entry handles ability activation, temporary tags and counter selection.
    component.PerfectDodgeResultData = data
    counterUtils["Dodge After Deflect"](counterUtils, pawn, pawn)
    print(string.format("[ParryOrDodge] Red perfect parry frame %d: native counter entry called.\n", handle:get()))
end

local function watchRedImpact()
    if impactPre then return true end
    -- The first red stance query occurs after its Blueprint has loaded; no polling.
    if not valid(StaticFindObject(IMPACT)) then return false end
    impactPre, impactPost = RegisterHook(IMPACT, function(...)
        local ok, message = pcall(counterRed, ...)
        if not ok then
            stopped = true
            print("[ParryOrDodge] Disabled after counter error: " .. tostring(message) .. "\n")
        end
        -- Blueprint POST observer must not override any return value.
    end)
    return true
end

local function perfectDeadline(pawn)
    if not same(pawn, cachedPawn) then cachedPawn, passive = pawn, nil end
    if not valid(passive) then
        for _, candidate in ipairs(FindAllOf("BP_PlayerDeflectPassive_C") or {}) do
            if valid(candidate) and same(candidate:GetAvatarActorFromActorInfo(), pawn) then
                passive = candidate
                break
            end
        end
    end
    if not valid(passive) or not passive["Stance Key Down"] then return nil end
    if not valid(system) then system = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end
    if not valid(system) then return nil end
    local deadline = passive["Perfect Window"]
    -- Observed field is an absolute game-time deadline, not a duration.
    if type(deadline) ~= "number" or deadline <= 0 or system:GetGameTimeInSeconds(pawn) > deadline then return nil end
    return deadline
end

local function supplement(context, returned, angle, maxTime, isDodge, currentHandle, outFrame)
    if returned:get() >= 0 then return nil end -- Includes valid handle zero.
    local dodge = isDodge:get()
    if (dodge and not config.DodgeBlue) or (not dodge and not config.ParryRed) then return nil end
    local component = context:get()
    if not valid(component) then return nil end
    local pawn = component:GetOwner()
    if not valid(pawn) then return nil end
    if not valid(playerClass) then playerClass = StaticFindObject("/Script/ProjectPBZ.PBZCharacter_Player") end
    if not valid(playerClass) or not pawn:IsA(playerClass) then return nil end
    local controller = pawn:GetController()
    if not valid(controller) or not controller:IsLocalPlayerController() then return nil end

    local deadline
    if not dodge then
        deadline = perfectDeadline(pawn)
        if deadline == nil then return nil end
    end
    -- The recursive hook is suppressed by busy. The original angle/time/current-handle
    -- filters still run; no receive frame is changed, consumed, or duplicated here.
    local discardedOutput = {}
    local handle = component:GetNearestValidReceivedFrame(
        angle:get(), maxTime:get(), not dodge, currentHandle:get(), discardedOutput)
    if type(handle) ~= "number" or handle < 0 then return nil end
    local received = component.ReceiveFrames
    if not received:Contains(handle) then return nil end
    local candidate = received:Find(handle):get()
    local action = candidate.SourceAction:Get()
    if not valid(attackClass) then
        attackClass = StaticFindObject("/Script/PBZDeflectSystem.LGAAction_DurationBulletWithDeflectBase")
    end
    if not valid(action) or not valid(attackClass) or not action:IsA(attackClass) then return nil end
    local expectedType = dodge and 2 or 3 -- BlueEye / RedEye; never normal or power attacks.
    if action.DeflectBulletType ~= expectedType or candidate.IsDodge ~= (not dodge) then return nil end
    if not dodge and candidate.HitGameTime > deadline then return nil end
    if not dodge and not watchRedImpact() then return nil end

    -- Copy the native UScriptStruct, including weak references and interface data.
    -- Rebuilding this from a Lua table risks losing native data. Return the new
    -- handle only after the matching output frame has been copied successfully.
    outFrame:set(candidate)
    if not dodge then
        local address = component:GetAddress()
        if redComponent ~= address then redComponent, redFrames = address, {} end
        local existing = redFrames[handle]
        if not existing or existing.action ~= action:GetAddress() or existing.time ~= candidate.HitGameTime then
            redFrames[handle] = { action = action:GetAddress(), time = candidate.HitGameTime }
        end
        for id, frame in pairs(redFrames) do
            if candidate.HitGameTime - frame.time > 5 then redFrames[id] = nil end
        end
    end
    local key = tostring(component:GetAddress()) .. ":" .. tostring(dodge)
    if matchLogs < 20 and lastMatch[key] ~= handle then
        lastMatch[key], matchLogs = handle, matchLogs + 1
        print(string.format("[ParryOrDodge] Matched %s frame %d for %s; native counter outcome pending.\n",
            dodge and "blue" or "red", handle, dodge and "dodge" or "parry"))
    end
    return handle
end

-- Native POST ABI in UE4SS cdbc0b66: Context, ReturnValue, then declared parameters.
local pre, post = RegisterHook(QUERY, function() end, function(...)
    if busy or stopped then return nil end
    busy = true
    local ok, result = pcall(supplement, ...)
    busy = false
    if not ok then
        stopped = true
        print("[ParryOrDodge] Disabled after error: " .. tostring(result) .. "\n")
        return nil
    end
    return result -- nil preserves the original; only an accepted handle overrides it.
end)
ModRef.OnUnload = function()
    stopped = true
    UnregisterHook(QUERY, pre, post)
    if impactPre then UnregisterHook(IMPACT, impactPre, impactPost) end
    redFrames = {}
end
print("[ParryOrDodge] 1.0 loaded. Local-player queries only; no polling.\n")
