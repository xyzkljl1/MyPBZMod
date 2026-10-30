-- Use the game's targeting rules to lock on when attacking.
local mcu = require("mcu_core")
local RESTART = "/Script/Engine.PlayerController:ClientRestart"
local INPUT_READY = "/Script/SGameInputSystem.AbilityInputComponent:OnRestarted"
local SIGNAL = "/Script/Engine.BlueprintAsyncActionBase:Activate"
local HIT_CLASS = "/PBZCombatAsset/Prototypes/Bullet/Events/PBZ_BulletEvent_MarkBulletHitTarget.PBZ_BulletEvent_MarkBulletHitTarget_C"
local HIT = HIT_CLASS .. ":Trigger"
local ATTACKS = { "IA_AttackL_Press", "IA_AttackH_Press" }
if AutoLock and AutoLock.Stop then AutoLock.Stop() end
local config, err = mcu.InitFromFile({
    fields = {
        {key = "Mode", type = "TextSelect", label = "Auto-lock Mode", default = "attack",
            description = "Keep the current target. On Attack: search once on a light/heavy attack press, without holding repeats or retries. On Hit: include zero-damage hits and lock the hit enemy only if alive and targetable. Event-driven; no polling.",
            options = {
                {value = "off", label = "Off"},
                {value = "attack", label = "On Attack"},
                {value = "hit", label = "On Hit"},
            }},
    },
})
if not config then
    print("[AutoLock] " .. tostring(err) .. "\n")
    return
end
local state = { stopped = false, hooks = {}, listeners = {}, hits = {} }
AutoLock = state

local function valid(object) return object ~= nil and object:IsValid() end
local function same(a, b) return valid(a) and valid(b) and a:GetAddress() == b:GetAddress() end

local function guarded(callback, ...)
    if state.stopped then return end
    local ok, message = pcall(callback, ...)
    if not ok then
        state.stopped = true
        ExecuteInGameThread(state.Stop)
        print("[AutoLock] Stopped: " .. tostring(message) .. "\n")
    end
end

local queueUpdate
local function onHit(_, sourceBullet, eventData)
    if state.stopped or config.Mode ~= "hit" then return end
    if not valid(state.controller) then return end
    local pawn, target = state.controller.Pawn, eventData:get().EventActor
    if not valid(pawn) or not valid(target) or pawn:GetAddress() == target:GetAddress() then return end
    -- Destructible/environmental actors may also receive bullet hit events.
    local characterClass = StaticFindObject("/Script/ProjectPBZ.PBZCharacter")
    if not valid(characterClass) or not target:IsA(characterClass) then return end
    local bullet = sourceBullet:get()
    if not valid(bullet) then return end
    local source = bullet.BulletOwnerAvatar
    if not valid(source) or source:GetAddress() ~= pawn:GetAddress() then return end
    local factions = StaticFindObject("/Script/SGameCombatSystem.Default__FactionUtils")
    if not valid(factions) then return end
    if factions:GetFactionRelation(pawn, target) ~= 2 then return end -- Hostile
    -- Retain actors only; event parameters expire when the callback returns.
    state.hits[#state.hits + 1] = { pawn = pawn, target = target }
    queueUpdate()
end

local function lockHitTarget(hits, pawn)
    local handler = state.targeting.CurrentHandler
    if not valid(handler) then handler = state.targeting.DefaultTargetHandler end
    if not valid(handler) then return end
    local candidates = {}
    handler:FindTargetsRated({}, candidates)
    for _, hit in ipairs(hits) do
        if valid(hit.pawn) and hit.pawn:GetAddress() == pawn:GetAddress() and valid(hit.target) then
            local attributes = hit.target.AttributeSetBase
            if valid(attributes) and attributes.Health.CurrentValue > 0 then
                for _, candidate in ipairs(candidates) do
                    local socket = candidate:get().Target
                    if valid(socket.Component) then
                        local owner = socket.Component:GetOwner()
                        if valid(owner) and owner:GetAddress() == hit.target:GetAddress()
                            and state.targeting:IsTargetValid(handler.ValidatorTag, socket)
                            and state.targeting:SetLockTarget(socket) then return end
                    end
                end
            end
        end
    end
end

local function update()
    local hits, attackPawn = state.hits, state.attackPawn
    state.hits, state.attackPawn, state.pending = {}, nil, false
    if state.stopped or not valid(state.controller) then return end
    local controller, pawn = state.controller, state.controller.Pawn
    if not valid(pawn) then return end
    if not valid(state.pawn) or state.pawn:GetAddress() ~= pawn:GetAddress()
        or not valid(state.targeting) then
        local playerClass = StaticFindObject("/Script/ProjectPBZ.PBZCharacter_Player")
        local targetingClass = StaticFindObject("/Script/SGameCombatSystem.TargetingComponent")
        if not (valid(playerClass) and valid(targetingClass)) then return end
        if not pawn:IsA(playerClass) then return end
        local targeting = pawn:GetComponentByClass(targetingClass)
        if not valid(targeting) then return end
        state.pawn, state.targeting = pawn, targeting
    end
    if controller:IsMoveInputIgnored() then return end
    local attributes = pawn.AttributeSetBase
    if not valid(attributes) or attributes.Health.CurrentValue <= 0 then return end
    if state.targeting:HasLockTarget() then return end
    if config.Mode == "attack" and same(attackPawn, pawn) then
        -- Zero duration searches immediately without starting the game's retry window.
        state.targeting:TryLockTarget(0)
    elseif config.Mode == "hit" and #hits > 0 then
        lockHitTarget(hits, pawn)
    end
end

queueUpdate = function()
    if state.pending then return end
    state.pending = true
    -- One dispatch per batch of events, never a recurring timer.
    ExecuteInGameThread(function() guarded(update) end)
end

local function clearInput()
    for _, listener in ipairs(state.listeners) do
        if valid(listener) then
            if valid(state.receiver) then listener.OnTrigger:Remove(state.receiver, FName("Activate")) end
            listener:EndAction()
        end
    end
    state.listeners, state.inputPawn, state.input = {}, nil, nil
    if valid(state.gameInstance) and valid(state.receiver) then
        local refs = state.gameInstance.ReferencedObjects
        for index = 1, refs:GetArrayNum() do
            if same(refs[index], state.receiver) then refs[index] = nil; break end
        end
    end
    state.receiver, state.gameInstance = nil, nil
end

local function bindController(controller)
    if not valid(controller) or not controller:IsLocalPlayerController() then return end
    state.controller = controller
    local pawn = controller.Pawn
    if not valid(pawn) then clearInput(); return end
    local playerClass = StaticFindObject("/Script/ProjectPBZ.PBZCharacter_Player")
    if not valid(playerClass) or not pawn:IsA(playerClass) then clearInput(); return end
    local inputClass = StaticFindObject("/Script/SGameInputSystem.AbilityInputComponent")
    local abilityInput = pawn:GetComponentByClass(inputClass)
    if not valid(abilityInput) or not valid(abilityInput.SGameInput) then clearInput(); return end
    if same(state.inputPawn, pawn) and same(state.input, abilityInput.SGameInput) then return end
    clearInput()
    state.inputPawn, state.input = pawn, abilityInput.SGameInput
    local library = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    state.gameInstance = library:GetGameInstance(pawn)
    -- A private, inert UFUNCTION receiver bridges native delegates to Lua. Keep
    -- it directly under the transient package to avoid UE 5.7 soft-subpath issues.
    state.receiver = StaticConstructObject(StaticFindObject("/Script/Engine.BlueprintAsyncActionBase"),
        StaticFindObject("/Engine/Transient"), FName("None"), 0x40)
    assert(valid(state.receiver) and valid(state.gameInstance), "Input receiver unavailable")
    local refs = state.gameInstance.ReferencedObjects
    local slot = refs:GetArrayNum() + 1
    for index = 1, refs:GetArrayNum() do
        if not valid(refs[index]) then slot = index; break end
    end
    refs[slot] = state.receiver -- Lua UObject wrappers alone do not prevent Unreal GC.
    local factory = StaticFindObject("/Script/SGameInputSystem.Default__AbilityAsync_WaitSInputTrigger")
    for _, name in ipairs(ATTACKS) do
        local action = StaticFindObject("/PBZInput/InputActions/" .. name .. "." .. name)
        assert(valid(action), "Attack input unavailable: " .. name)
        -- CreateAsync registers with the game instance; EndAction releases it.
        local listener = factory:CreateAsync(pawn, action, false, false)
        assert(valid(listener), "Attack input subscription failed: " .. name)
        state.listeners[#state.listeners + 1] = listener
        listener.OnTrigger:Add(state.receiver, FName("Activate"))
        listener:Activate()
        assert(valid(listener.InputComponent), "Attack input listener did not activate: " .. name)
    end
    print("[AutoLock] Attack input subscriptions ready.\n")
end

local function queueBind(controller)
    ExecuteInGameThread(function() guarded(bindController, controller) end)
end

function state.Stop()
    state.stopped = true
    local ok, message = pcall(clearInput)
    if not ok then print("[AutoLock] Input cleanup failed: " .. tostring(message) .. "\n") end
    for _, hook in ipairs(state.hooks) do
        UnregisterHook(hook.path, hook.pre, hook.post)
    end
    state.hooks = {}
    state.controller, state.pawn, state.targeting = nil, nil, nil
    state.hits, state.attackPawn = {}, nil
end

local function addHook(path, callback, postCallback)
    local pre, post = RegisterHook(path, callback, postCallback or function() end)
    state.hooks[#state.hooks + 1] = { path = path, pre = pre, post = post }
end

ModRef.OnUnload = state.Stop
if not EngineTickAvailable then
    state.stopped = true
    print("[AutoLock] Not started: UE4SS EngineTick is required.\n")
    return
end

local ok, message = pcall(function()
    addHook(RESTART, function() end, function(context) guarded(queueBind, context:get()) end)
    addHook(INPUT_READY, function() end, function(_, pawn)
        guarded(function()
            local actor = pawn:get()
            if valid(actor) then queueBind(actor:GetController()) end
        end)
    end)
    addHook(SIGNAL, function(context)
        guarded(function()
            if config.Mode == "attack" and same(context:get(), state.receiver) then
                state.attackPawn = state.inputPawn
                queueUpdate()
            end
        end)
    end)
    ExecuteInGameThread(function()
        guarded(function()
            -- The Blueprint hit event may not be loaded yet at the title screen.
            if not valid(StaticFindObject(HIT)) then LoadAsset(HIT_CLASS) end
            addHook(HIT, function(...) guarded(onHit, ...) end)
            for _, controller in ipairs(FindAllOf("PlayerController") or {}) do
                if valid(controller) and controller:IsLocalPlayerController() then
                    bindController(controller)
                    break
                end
            end
            print("[AutoLock] Event hooks ready; no polling. Mode=" .. config.Mode .. "\n")
        end)
    end)
end)
if not ok then
    state.Stop()
    print("[AutoLock] Not started: " .. tostring(message) .. "\n")
    return
end
print("[AutoLock] Loaded. MCU schema configuration ready.\n")
