local timeline = require('timeline')
local view = require('view')
local preview = require('boss_preview')
local config, configError = require('mcu_core').InitFromFile({
    fields = {
        {key='BarWidthMode',type='TextSelect',label='Bar Width Mode',default='fixed_bar',
            description='Fixed Bar Width: every combo uses the same total width. Fixed Frame Width: each frame uses 4 UI units, so longer combos have longer bars. Changes apply to the next combo.',
            options={
                {value='fixed_bar',label='Fixed Bar Width'},
                {value='fixed_frame',label='Fixed Frame Width'},
            }},
        {key='offsetX',type='IntBox',label='offsetX',default=0,
            description='Horizontal UI offset. Positive moves right; negative moves left.'},
        {key='offsetY',type='IntBox',label='offsetY',default=0,
            description='Vertical UI offset. Positive moves down; negative moves up.'},
    },
})
if not config then print('[ParryWindow] '..tostring(configError)..'\n'); return end
local stopped, timer, hud, passive, pawn, controller, component, system
local nextDiscovery, nextUiAttempt = 0, 0
local cleanedStale=false
local tracks, reported = {}, {}
local displayTrack = {}
local function valid(o) return o ~= nil and o:IsValid() end
local function same(a,b) return valid(a) and valid(b) and a:GetAddress()==b:GetAddress() end
local function log(s) print('[ParryWindow] '..s..'\n') end
local function once(key,s)
    if not reported[key] then reported[key]=true; log(s) end
end
local function read(o,key)
    local ok,value=pcall(function() return o[key] end)
    if ok then return value end
    return nil
end
local function clear()
    view.destroy(hud)
    hud,passive,pawn,controller,component=nil,nil,nil,nil,nil
    tracks={}
    displayTrack={}
    preview.clear()
end

local function discover()
    if os.clock()<nextDiscovery then return false end
    nextDiscovery=os.clock()+2
    -- Global object discovery is limited to player acquisition, never the HUD update.
    for _,ability in ipairs(FindAllOf('BP_PlayerDeflectPassive_C') or {}) do
        if valid(ability) and not ability:GetFullName():find('Default__',1,true) then
            local avatar=ability:GetAvatarActorFromActorInfo()
            local pc=valid(avatar) and avatar:GetController() or nil
            local dc=read(ability,'Deflect Component')
            if valid(pc) and pc:IsLocalPlayerController() and valid(dc) then
                passive,pawn,controller,component=ability,avatar,pc,dc
                system=StaticFindObject('/Script/Engine.Default__KismetSystemLibrary')
                log('Bound local player; native frame queries ready.')
                return true
            end
        end
    end
    return false
end

local function parryWindow(now)
    -- This Blueprint getter returns the concrete active-difficulty data asset.
    -- Component caches can remain null; interface getters are not needed here.
    local global=pawn['Get Global Config'](pawn)
    if not valid(global) then once('config-missing','Active global config is not ready.'); return nil,nil end
    local combat,mechanic=read(global,'Combat Config'),read(global,'Mechanic Config')
    if not valid(combat) or not valid(mechanic) then
        once('config-fields','Missing combat/mechanic settings in '..global:GetFullName())
        return nil,nil
    end
    local fps=read(mechanic,'Logic Frame Rate')
    local frames=read(combat,'Deflect Perfect Window Frames')
    if type(fps)~='number' or fps<=0 or type(frames)~='number' then
        once('config-values','Invalid timing fields: frames='..tostring(frames)..', rate='..tostring(fps))
        return nil,nil
    end
    local baseSeconds=frames/fps
    local seconds=baseSeconds
    -- Give Perfect Window increments this counter BEFORE asking for the multiplier.
    -- Predict the next input without changing the passive ability's state.
    local cooldown=read(combat,'Deflect Quickclick Punish Cooldown')
    local last=read(passive,'Last Deflect Click')
    local counter=0
    if type(cooldown)=='number' and type(last)=='number' and now-last<cooldown then
        counter=passive['Current Perfect Window Counter']+1
    end
    seconds=seconds*global['Get Deflect Quickclick Punish Multiplier'](global,counter)
    return seconds,fps,baseSeconds
end

local function nearest(dodge,index,now)
    -- This getter does not consume frames or activate abilities. Existing Mods may
    -- filter its result; use the native handle, including valid handle zero.
    local handle=component:GetNearestValidReceivedFrame(360,9999,dodge,-1,{})
    if type(handle)~='number' or handle<0 or not component.ReceiveFrames:Contains(handle) then
        tracks[index]=nil
        return nil
    end
    local frame=component.ReceiveFrames:Find(handle):get()
    if frame.IsHit or type(frame.HitGameTime)~='number' or frame.HitGameTime<=now then
        tracks[index]=nil
        return nil
    end
    local action=frame.SourceAction:Get()
    if not valid(action) then tracks[index]=nil; return nil end
    if not preview.isBoss(action:GetAvatarActor()) then tracks[index]=nil; return nil end
    local previous=tracks[index]
    if not previous or previous.handle~=handle or previous.hit~=frame.HitGameTime then
        previous={handle=handle,hit=frame.HitGameTime,kind=index,
            availableFrom=now,action=action:GetAddress()}
        tracks[index]=previous
    end
    return previous
end

local function renderCombo(combos,now,seconds,fps,baseSeconds)
    local combo=combos[1]
    for _,candidate in ipairs(combos) do
        if candidate.key==displayTrack.key then combo=candidate; break end
    end
    if not combo then
        displayTrack={}
        view.render(hud,nil)
        return
    end
    local nativeFrames,seen={},{}
    for index=1,2 do
        local real=nearest(index==2,index,now)
        if real then
            local key=tostring(real.handle)..':'..tostring(real.action)
            if not seen[key] then seen[key]=true; nativeFrames[#nativeFrames+1]=real end
        end
    end
    view.render(hud,timeline.sample(combo,now,baseSeconds,fps,nativeFrames,seconds,displayTrack),config.BarWidthMode,config.offsetX,config.offsetY)
end

local function update()
    if stopped then return end
    if pawn~=nil and not valid(pawn) then clear() end
    if valid(pawn) then
        if not valid(passive) or not valid(controller) or not valid(component)
            or not same(controller.Pawn,pawn) or not same(component:GetOwner(),pawn) then clear() end
    end
    if not valid(pawn) and not discover() then return end
    local now=system:GetGameTimeInSeconds(pawn)
    local refreshed,refreshError=pcall(preview.refresh,controller)
    if not refreshed then once('boss-refresh:'..tostring(refreshError),'Boss discovery error: '..tostring(refreshError)) end
    if not hud then
        if os.clock()<nextUiAttempt then return end
        nextUiAttempt=os.clock()+5
        if not cleanedStale then view.cleanupStale(); cleanedStale=true end
        local ok,result=pcall(view.create,pawn,controller)
        if not ok then once('ui:'..tostring(result),'HUD not ready: '..tostring(result)); return end
        hud=result
        log('Native UMG HUD ready; one complete combo bar, all hit windows, one frame per cell, no input capture.')
    end
    local seconds,fps,baseSeconds
    local ok,err=pcall(function() seconds,fps,baseSeconds=parryWindow(now) end)
    if not ok then once('settings:'..tostring(err),'Parry timing unavailable: '..tostring(err)) end
    local sampled,predicted=pcall(preview.sample,now)
    if not sampled then
        once('boss-sample:'..tostring(predicted),'Boss preview unavailable: '..tostring(predicted))
        predicted={}
    end
    renderCombo(predicted,now,seconds,fps,baseSeconds)
end

local function safeUpdate()
    if stopped then return end
    local ok,err=pcall(update)
    if not ok then
        -- Stop on an unexpected API failure rather than spamming errors at 60 Hz.
        stopped=true
        pcall(preview.stop)
        pcall(clear)
        log('Stopped after error: '..tostring(err))
        if timer then CancelDelayedAction(timer); timer=nil end
    end
end

ModRef.OnUnload=function()
    stopped=true
    preview.stop()
    if timer then CancelDelayedAction(timer); timer=nil end
    -- UI removal must run on the game thread. The marker name also permits a
    -- subsequent instance to remove stale HUDs after an interrupted unload.
    ExecuteInGameThread(function() pcall(clear) end)
end

if not EngineTickAvailable then log('Not started: UE4SS EngineTick is required.'); return end
preview.start()
timer=LoopInGameThreadWithDelay(16,safeUpdate)
log('Started. Waiting for local player; timing display only, no input or gameplay changes.')
