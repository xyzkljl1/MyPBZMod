-- Apply one infinite SprintSpeed buff per local player; never renew it.
-- Relative to the game's working directory (ProjectPBZ/Binaries/Win64).
local config = dofile("../../../platform/steam/ue4ss/Mods/FasterRun/FasterRun.config.lua")
local SPEED_MULTIPLIER = config.SpeedMultiplier
assert(type(SPEED_MULTIPLIER) == "number" and SPEED_MULTIPLIER >= 1 and SPEED_MULTIPLIER < math.huge,
    "FasterRun.config.lua: SpeedMultiplier must be a finite number >= 1")
local PAWN_KEY, HANDLE_KEY = "FasterRun.OwnedPawn", "FasterRun.OwnedHandle"
local MULTIPLIER_KEY = "FasterRun.OwnedMultiplier"
local RESTART_EVENT = "/Script/Engine.PlayerController:ClientRestart"
if FasterRun and FasterRun.Stop then FasterRun.Stop() end
local state = { enabled = true, stopped = false }
FasterRun = state

local function valid(object) return object ~= nil and object:IsValid() end
local function log(message) print("[FasterRun] " .. message .. "\n") end
local function owned()
    local id = ModRef:GetSharedVariable(HANDLE_KEY)
    local handle = type(id) == "number" and id >= 0
        and { Handle = id, bPassedFiltersAndWasExecuted = true } or nil
    return ModRef:GetSharedVariable(PAWN_KEY), handle
end

local function release(attributes, abilities)
    local path, handle = owned()
    if handle and abilities:IsActiveGameplayEffectHandleActive(handle) then
        local pawn = type(path) == "string" and StaticFindObject(path) or nil
        assert(valid(pawn), "Cannot locate the previous buff owner")
        attributes:RemoveAttributeBuff(pawn, handle)
        assert(not abilities:IsActiveGameplayEffectHandleActive(handle), "Could not remove owned buff")
    end
    ModRef:SetSharedVariable(HANDLE_KEY, -1)
    ModRef:SetSharedVariable(PAWN_KEY, "")
    ModRef:SetSharedVariable(MULTIPLIER_KEY, 0)
end

local function update(attributes, abilities)
    if not state.enabled or SPEED_MULTIPLIER == 1 then release(attributes, abilities); return end
    local playerClass = StaticFindObject("/Script/ProjectPBZ.PBZCharacter_Player")
    if not valid(playerClass) then return end
    local pawn
    for _, controller in ipairs(FindAllOf("PlayerController") or {}) do
        if valid(controller) and controller:IsLocalPlayerController() then
            local candidate = controller.Pawn
            if valid(candidate) and candidate:IsA(playerClass) then pawn = candidate; break end
        end
    end
    if not pawn then return end
    local path = pawn:GetFullName():match("^%S+ (.+)$")
    local previousPath, handle = owned()
    if previousPath == path and handle and abilities:IsActiveGameplayEffectHandleActive(handle)
        and ModRef:GetSharedVariable(MULTIPLIER_KEY) == SPEED_MULTIPLIER then return end
    -- Replace the owned buff once when configuration changes or migrating an old version.
    release(attributes, abilities)

    local config = pawn["Actor Config"]
    if not valid(config) then return end
    -- Reuse the native attribute, including its FFieldPath.
    local attribute = config["Sprint Parameters"].WalkSpeedAttribute
    local added = attributes:AddAttributeBuff(pawn, attribute, 1, SPEED_MULTIPLIER, -1.0)
    assert(added and type(added.Handle) == "number" and added.Handle >= 0, "Game rejected sprint buff")
    -- Keep ownership across hot reloads; store a path instead of a stale UObject pointer.
    ModRef:SetSharedVariable(PAWN_KEY, path)
    ModRef:SetSharedVariable(HANDLE_KEY, added.Handle)
    ModRef:SetSharedVariable(MULTIPLIER_KEY, SPEED_MULTIPLIER)
    log(string.format("Applied once: SprintSpeed x%.1f; infinite; %s", SPEED_MULTIPLIER, path))
end

function state.Stop()
    state.stopped = true
    if state.pending then CancelDelayedAction(state.pending); state.pending = nil end
    if state.preHook then
        UnregisterHook(RESTART_EVENT, state.preHook, state.postHook)
        state.preHook, state.postHook = nil, nil
    end
    -- Unload may run off the game thread. Use SetEnabled(false) before unloading
    -- to remove the buff; otherwise it lasts until the owning character is destroyed.
end

local function refresh()
    if state.stopped then return end
    local attributes = StaticFindObject("/Script/SGameAttributes.Default__AttributeUtils")
    local abilities = StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary")
    if not valid(attributes) or not valid(abilities) then return end
    local ok, message = pcall(update, attributes, abilities)
    if not ok then
        state.Stop()
        local cleaned, reason = pcall(release, attributes, abilities)
        log("Stopped: " .. tostring(message))
        if not cleaned then log("Cleanup failed: " .. tostring(reason)) end
    end
end

function state.SetEnabled(enabled)
    if state.stopped then return end
    state.enabled = not not enabled
    ExecuteInGameThread(refresh)
end

local function scheduleRefresh()
    if state.stopped or state.pending then return end
    -- Let ClientRestart finish assigning/initializing the pawn before reading it.
    state.pending = ExecuteInGameThreadAfterFrames(1, function()
        state.pending = nil
        refresh()
    end)
end

state.preHook, state.postHook = RegisterHook(RESTART_EVENT, function(context)
    local controller = context:get()
    if valid(controller) and controller:IsLocalPlayerController() then scheduleRefresh() end
end)
ModRef.OnUnload = state.Stop
scheduleRefresh() -- Also handle a player that already exists when the mod loads.
log(string.format("Loaded. Sprint multiplier %.1f; ClientRestart event; no polling.", SPEED_MULTIPLIER))
