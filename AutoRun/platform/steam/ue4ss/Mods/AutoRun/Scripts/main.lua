-- Hold the original sprint action each frame; leave movement rules to the game.
local RESTART_EVENT = "/Script/Engine.PlayerController:ClientRestart"
local ACTION_PATH = "/SGameLocomotionDriver/Input/IA_Sprint.IA_Sprint"
local PRESSED, EMPTY = { X = 1.0, Y = 0.0, Z = 0.0 }, {}
local state = { enabled = true, stopped = false }
AutoRun = state

local function valid(object) return object ~= nil and object:IsValid() end

local function bindController(controller)
    if state.stopped or not valid(controller) or not controller:IsLocalPlayerController() then return end
    state.controller, state.pawn, state.subsystem = controller, nil, nil
end

local function injectSprint()
    if state.stopped or not state.enabled or not valid(state.controller) then return end
    local controller, pawn = state.controller, state.controller.Pawn
    if not valid(pawn) then return end
    if not valid(state.pawn) or pawn:GetAddress() ~= state.pawn:GetAddress() or not valid(state.subsystem) then
        local playerClass = StaticFindObject("/Script/ProjectPBZ.PBZCharacter_Player")
        local inputClass = StaticFindObject("/Script/EnhancedInput.EnhancedInputLocalPlayerSubsystem")
        local library = StaticFindObject("/Script/Engine.Default__SubsystemBlueprintLibrary")
        if not (valid(playerClass) and valid(inputClass) and valid(library)) then return end
        if not pawn:IsA(playerClass) then return end
        local subsystem = library:GetLocalPlayerSubSystemFromPlayerController(controller, inputClass)
        if not valid(subsystem) then return end
        state.pawn, state.subsystem = pawn, subsystem
    end
    if not valid(state.action) then state.action = StaticFindObject(ACTION_PATH) end
    if not valid(state.action) or controller:IsMoveInputIgnored() then return end
    state.subsystem:InjectInputVectorForAction(state.action, PRESSED, EMPTY, EMPTY)
end

function state.Stop()
    state.stopped = true
    if state.frameTimer then CancelDelayedAction(state.frameTimer); state.frameTimer = nil end
    if state.preHook then
        UnregisterHook(RESTART_EVENT, state.preHook, state.postHook)
        state.preHook, state.postHook = nil, nil
    end
    state.controller, state.pawn, state.subsystem, state.action = nil, nil, nil, nil
    -- Frame-scoped input expires automatically; no release call is needed.
end

function state.SetEnabled(enabled)
    state.enabled = not not enabled
end

if not EngineTickAvailable then
    state.stopped = true
    print("[AutoRun] Not started: UE4SS EngineTick is required.\n")
    return
end

-- Events update the controller; the existing frame callback binds its current pawn.
state.preHook, state.postHook = RegisterHook(RESTART_EVENT, function(context)
    bindController(context:get())
end)
state.frameTimer = LoopInGameThreadAfterFrames(1, function()
    local ok, message = pcall(injectSprint)
    if not ok then
        state.Stop()
        print("[AutoRun] Stopped: " .. tostring(message) .. "\n")
    end
end)
ModRef.OnUnload = state.Stop
ExecuteInGameThread(function()
    if state.stopped or valid(state.controller) then return end
    for _, controller in ipairs(FindAllOf("PlayerController") or {}) do
        bindController(controller)
        if valid(state.controller) then break end
    end
end)
print("[AutoRun] Loaded. Sprint input each frame; controller discovery on startup and ClientRestart only.\n")
