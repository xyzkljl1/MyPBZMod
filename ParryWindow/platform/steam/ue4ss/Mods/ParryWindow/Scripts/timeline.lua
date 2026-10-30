-- One authored timeline, with independent hit windows and one progress cursor.
local M={}
local function clamp(v,lo,hi) return math.max(lo,math.min(hi,v)) end

function M.sample(combo,now,baseSeconds,fps,nativeFrames,liveSeconds,track)
    if not combo or combo.length<=0 or combo.current>=combo.length then return nil end
    if track.key~=combo.key then
        track.key=combo.key
        track.length=combo.length
        track.ranges={}
        track.received={}
        track.scales={}
    end
    -- Native corrections affect only their hit window, never the pointer/axis.
    for _,real in ipairs(nativeFrames or {}) do
        local best,distance
        for i,attack in ipairs(combo.attacks) do
            if attack.action==real.action then
                local delta=math.abs((attack.time-combo.current)/combo.rate-(real.hit-now))
                if not distance or delta<distance then best,distance=i,delta end
            end
        end
        if best then
            local attack=combo.attacks[best]
            local seconds=real.kind==2 and real.hit-real.availableFrom or liveSeconds
            local previous=track.received[best]
            if seconds and seconds>=0 and real.hit>now and attack.time>combo.current
                and (not previous or previous.handle~=real.handle or previous.seconds~=seconds) then
                local scale=(attack.time-combo.current)/(real.hit-now)
                track.scales[best]=scale
                if real.kind==2 then
                    track.ranges[best]={start=math.max(0,attack.time-seconds*scale),finish=attack.time}
                end
                track.received[best]={handle=real.handle,seconds=seconds}
            end
        end
    end
    local cursor=clamp(combo.current/track.length,0,1)
    if not fps or fps<=0 then
        return {key=combo.key,cursor=cursor,windows={}}
    end
    local total=math.max(1,math.floor(track.length*fps+.5))
    local windows,frames,hits={},{},{}
    for i,attack in ipairs(combo.attacks) do
        hits[i]=clamp(math.floor(attack.time*fps+.5),0,total)
        -- Recompute every upcoming green window, even before a received frame exists
        -- or after the native query moves to another hit. Finished hits stay fixed.
        if attack.index~=2 and (attack.time>combo.current or not track.ranges[i]) then
            if liveSeconds then
                local scale=track.scales[i] or combo.rate
                track.ranges[i]={start=math.max(0,attack.time-liveSeconds*scale),finish=attack.time}
            else
                track.ranges[i]=nil
            end
        end
        frames[i]='--'
        local interval=track.ranges[i]
        local seconds=attack.index==2 and attack.window or nil
        if interval or seconds then
            local first=interval and interval.start or math.max(0,attack.time-seconds)
            local finish=interval and interval.finish or attack.time
            first=clamp(math.floor(first*fps+.5),0,total)
            finish=clamp(math.floor(finish*fps+.5),0,total)
            frames[i]=finish-first
            if finish>first then windows[#windows+1]={first=first,last=finish,kind=attack.index or 1} end
        end
    end
    table.sort(windows,function(a,b) return a.first<b.first end)
    local merged={}
    for _,window in ipairs(windows) do
        local last=merged[#merged]
        if last and last.kind==window.kind and window.first<=last.last then last.last=math.max(last.last,window.last)
        else merged[#merged+1]=window end
    end
    return {key=combo.key,cursor=cursor,windows=merged,windowFrames=frames,totalFrames=total,hits=hits}
end
return M
