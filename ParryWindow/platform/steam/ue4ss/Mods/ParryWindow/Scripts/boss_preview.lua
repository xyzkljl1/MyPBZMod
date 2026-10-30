-- Observe Boss timeline starts. This does not start/stop abilities or edit attacks.
local M = {}
local bosses, active, pending = {}, {}, {}
local player, nextRefresh, attackClass
local stopped=false
local function valid(o) return o~=nil and o:IsValid() end
local function id(o) return valid(o) and o:GetAddress() or nil end
local function read(o,k) local ok,v=pcall(function() return o[k] end); if ok then return v end; return nil end
local function log(s) print('[ParryWindow] '..s..'\n') end
local system

function M.isBoss(actor) return valid(actor) and bosses[id(actor)]~=nil end

function M.refresh(controller)
    if stopped then return end
    if id(controller)~=id(player) then bosses={}; active={}; player=controller; nextRefresh=0 end
    if os.clock()<(nextRefresh or 0) then return end
    nextRefresh=os.clock()+1
    local current={}
    -- FindAllOf returns verified UObject wrappers. Avoid both the unsupported
    -- weak-map keys and the nested return representation of GetBossHPBarInstances.
    -- Only one discovery pass per second; never scan objects in a HUD frame.
    for _,bar in ipairs(FindAllOf('WB_BossHPBar_C') or {}) do
        if valid(bar) and not bar:GetFullName():find('Default__',1,true)
            and id(bar:GetOwningPlayer())==id(controller)
            and bar:IsVisible() then
            local actor=read(bar,'Character')
            if valid(actor) then current[id(actor)]=actor end
        end
    end
    bosses=current
    for key in pairs(active) do if not bosses[key] then active[key]=nil end end
end

local function begin(ability,task,line,rate)
    if stopped or not valid(ability) or not valid(task) or not valid(line) then return end
    local actor=ability:GetAvatarActorFromActorInfo()
    if not M.isBoss(actor) then return end
    if active[id(actor)] and id(active[id(actor)].task)==id(task) then return end
    if not valid(attackClass) then attackClass=StaticFindObject('/Script/PBZDeflectSystem.LGAAction_DurationBulletWithDeflectBase') end
    local attacks={}
    line.Actions:ForEach(function(_,element)
        local event=element:get()
        local action=event.Action
        if valid(action) and valid(attackClass) and action:IsA(attackClass) then
            local kind=action.DeflectBulletType
            if kind==1 or kind==2 or kind==3 or kind==4 then
                -- Authored start + pre-hit duration is a preview, not a received frame.
                -- Native received frames later calibrate the window width.
                local lead=action.bImmediateHitPoint and 0 or action.PreHitPointDuration
                if type(event.StartTime)=='number' and type(lead)=='number' and lead>=0 then
                    attacks[#attacks+1]={time=event.StartTime+lead,action=id(action),
                        index=kind==3 and 2 or 1,window=lead}
                end
            end
        end
    end)
    if #attacks==0 then active[id(actor)]=nil; return end
    table.sort(attacks,function(a,b) return a.time<b.time end)
    local now=system:GetGameTimeInSeconds(actor)
    active[id(actor)]={actor=actor,ability=ability,task=task,line=line,attacks=attacks,
        key=tostring(id(task)),length=math.max(line.SequenceLength,attacks[#attacks].time),
        lastTime=task.CurrentTime,lastGame=now,rate=rate>0 and rate or 1}

end

function M.sample(now)
    local i=1
    while i<=#pending do
        local item=pending[i]
        local task=item.task
        local done=not valid(task) or os.clock()>item.expires
        if not done then
            local ability=read(task,'Ability')
            if valid(ability) and ability.bIsActive then
                local actor=ability:GetAvatarActorFromActorInfo()
                if M.isBoss(actor) then
                    local line=task.Timeline
                    if valid(line) and id(ability:GetPlayTimelineTask())==id(task) then
                        begin(ability,task,line,1)
                        done=true
                    end
                end
            end
        end
        if done then table.remove(pending,i) else i=i+1 end
    end
    local selected={}
    for key,entry in pairs(active) do
        if not valid(entry.actor) or not valid(entry.ability) or not valid(entry.task)
            or not entry.ability.bIsActive or not entry.ability:IsPlayingTimeline(entry.line)
            or id(entry.ability:GetPlayTimelineTask())~=id(entry.task) then
            active[key]=nil
        else
            local current=entry.task.CurrentTime
            local dt=now-entry.lastGame
            if dt>0 and current>entry.lastTime then entry.rate=(current-entry.lastTime)/dt end
            entry.lastTime,entry.lastGame=current,now
            if current<entry.length then
                selected[#selected+1]={key=entry.key,current=current,length=entry.length,
                    attacks=entry.attacks,rate=entry.rate}
            end
        end
    end
    table.sort(selected,function(a,b) return a.key<b.key end)
    return selected
end

function M.start()
    system=StaticFindObject('/Script/Engine.Default__KismetSystemLibrary')
    local function enqueue(task)
        if stopped or not valid(task) then return end
        if #pending<128 then pending[#pending+1]={task=task,expires=os.clock()+2} end
    end
    -- Confirmed on ordinary Skill_02/04/05 and special execution timelines.
    -- Construction can occur before Ability/Timeline fields have been initialized;
    -- inspect on the game thread after construction, with a bounded pending queue.
    NotifyOnNewObject('/Script/LegoAbility.LGATask_PlayTimeline',function(task)
        if stopped then return true end
        ExecuteInGameThread(function() enqueue(task) end)
    end)
    -- Support enabling/restarting this Mod during an already active attack.
    ExecuteInGameThread(function()
        if stopped then return end
        for _,task in ipairs(FindAllOf('LGATask_PlayTimeline') or {}) do
            local ability=read(task,'Ability')
            if valid(ability) and ability.bIsActive then enqueue(task) end
        end
    end)
    log('Boss-only mode: visible Boss health bars + new timeline tasks (task-notify-2).')
end

function M.clear() active={}; bosses={}; pending={}; player=nil; nextRefresh=0 end
function M.stop()
    stopped=true
    M.clear()
end
return M
