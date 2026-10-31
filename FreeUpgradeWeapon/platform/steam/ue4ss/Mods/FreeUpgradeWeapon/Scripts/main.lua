local hasMcu, mcu = pcall(require, "mcu_core")
local initConfig = hasMcu and mcu.InitFromFile or function() return {CostPercent = 0} end
local BACKPACK = "/Script/ProjectPBZ.PBZBackPackSubsystem:"
local hooks, stopped = {}, false

local function refreshCosts()
    local backpack = FindFirstOf("PBZBackPackSubsystem")
    if not backpack or not backpack:IsValid() then return end
    for _, component in ipairs(FindAllOf("BP_UIGameplayLogicComponent_C") or {}) do
        if component:IsValid() then
            -- Rebuild only upgrade prices; soul infusion and shop caches are separate.
            component.ItemUpgradeMaterialsCache:Empty()
            component:ReCheckItemUpgradeState(backpack)
        end
    end
end

local function queueRefresh()
    ExecuteInGameThread(function()
        if not stopped then refreshCosts() end
    end)
end

local config, err = initConfig({
    fields = {
        {key = "CostPercent", type = "IntSlider", label = "Upgrade Cost (%)",
            default = 0, min = 0, max = 100, step = 1, onchange = queueRefresh,
            description = "Weapon upgrade material and Dust costs as a percentage of the original price. 0 = free, 100 = original cost. Fractional costs round up. Downgrades refund the original price. Applies when upgrade prices are refreshed."},
    },
})
if not config then
    print("[FreeUpgradeWeapon] " .. tostring(err) .. "\n")
    return
end

local function discount(data)
    if config.CostPercent == 0 then
        data.Materials:Empty()
    else
        data.Materials:ForEach(function(_, amount)
            amount:set(math.ceil(amount:get() * config.CostPercent / 100))
        end)
    end
    data.ConsumeDust = math.ceil(data.ConsumeDust * config.CostPercent / 100)
end

local function hookPrices(name, normalWeapon, levelsField)
    local path = BACKPACK .. name
    local reported = false
    -- UE4SS cdbc0b66 native post callbacks receive the original return value
    -- immediately after Context, before the function's input parameters.
    local pre, post = RegisterHook(path, function() end, function(context, result, weaponID)
        if stopped or config.CostPercent == 100 then return end
        local backpack = context:get()
        local current = backpack:GetWeaponLevel(weaponID:get(), normalWeapon)
        -- This is the returned row copy, not the asset used by native refunds.
        -- Array entry 1 describes level 2. Keep all owned levels at full price
        -- so UI refund previews also retain their original costs.
        local targetLevel, changed = 1, 0
        result:get()[levelsField]:ForEach(function(_, entry)
            targetLevel = targetLevel + 1
            if targetLevel > current then
                discount(entry:get())
                changed = changed + 1
            end
        end)
        if not reported then
            reported = true
            print("[FreeUpgradeWeapon] " .. name .. " adjusted " .. changed .. " future levels at " .. config.CostPercent .. "%.\n")
        end
    end)
    hooks[#hooks + 1] = {path, pre, post}
end

local function stop()
    stopped = true
    for _, hook in ipairs(hooks) do UnregisterHook(table.unpack(hook)) end
    hooks = {}
    ExecuteInGameThread(refreshCosts)
end
ModRef.OnUnload = stop

local ok, message = pcall(function()
    hookPrices("GetMainWeaponTableData", true, "WeaponUpLevelDatas")
    hookPrices("GetShaqiWeaponTableData", false, "ShaChiWeaponUpLevelData")
end)
if not ok then
    stop()
    print("[FreeUpgradeWeapon] Could not install price hooks: " .. tostring(message) .. "\n")
    return
end
queueRefresh()
print("[FreeUpgradeWeapon] Started; upgrade cost " .. config.CostPercent .. "%, original refunds.\n")
