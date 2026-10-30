-- PBZ menu lifecycle; input editors subscribe to their own native events.
local ui = require('native_ui')
local PANEL = '/Game/PBZContent/UI/GameSystem/Settings/W_PBZSettingPanel.W_PBZSettingPanel_C'
local HOST = '/Game/PBZContent/UI/UINew/System/Setting/W_SettingActivateableWidget.W_SettingActivateableWidget_C'
local TABS = '/Game/PBZContent/UI/Foundation/TabbedView/W_OverlayTabList.W_OverlayTabList_C'
local M = {}

function M.start(menu, page)
    local valid, same, address, prop = ui.valid, ui.same, ui.address, ui.prop
    local states = {}
    local recheckHooks = false
    local watchPanel, installHooks, refresh, bindLifecycle

    local function later(delay, callback)
        return ExecuteInGameThreadWithDelay(delay, function()
            local ok, err = pcall(callback)
            if not ok then ui.log('Menu event failed: ' .. tostring(err)) end
        end)
    end
    local function cancel(state, key)
        local id = state[key]
        state[key] = nil
        if id then ui.attempt('Could not cancel menu task', CancelDelayedAction, id) end
    end
    local function close(state, destroy)
        if state.disposed then return end
        state.destroyPending = state.destroyPending or destroy
        if state.closing then return end
        state.closing, state.closed = true, true
        cancel(state, 'pending')
        ui.attempt('Could not deactivate MCU input', ui.setInputActive, state, false)
        if state.registered then ui.attempt('Could not leave MCU page', menu.updateSelection, state, false) end
        state.active = false
        if state.destroyPending then
            for _, entry in pairs(state.lifecycle or {}) do
                ui.attempt('Could not unbind menu lifecycle', entry.release)
            end
            ui.attempt('Could not release MCU inputs', page.clearInputs, state)
            ui.attempt('Could not dispose MCU page', menu.dispose, state)
            if states[state.key] == state then states[state.key] = nil end
            for key in pairs(state) do state[key] = nil end
            state.closed, state.disposed, state.active = true, true, false
        else
            state.closing = nil
        end
    end
    local function visible(state)
        return not state.closed and valid(state.owner) and state.owner:IsVisible()
            and (not valid(state.host) or (state.host:IsVisible() and state.host:IsActivated()))
    end

    local function request(state)
        if not state.closed and not state.pending then
            local id
            id = later(0, function()
                if state.pending == id then refresh(state) end
            end)
            state.pending = id
        end
    end
    refresh = function(state)
        state.pending = nil
        if state.closed then return end
        if not valid(state.owner) then close(state, true); return end
        if not state.lifecycleReady then ui.timed('menu.lifecycle', bindLifecycle, state) end
        if not state.registered then
            if state.attempts > 0 then return end -- Failed mutations are never retried.
            ui.timed('menu.hooks', installHooks)
            local ready, reason = ui.timed('menu.initialize', menu.tryInitialize, state)
            if not ready then
                if reason and state.waitReason ~= reason then
                    ui.log('Waiting for a settings event: ' .. reason)
                    state.waitReason = reason
                end
                return
            end
            state.waitReason = nil
        end
        menu.refreshTabButton(state)
        menu.updateSelection(state, visible(state))
    end

    local originalRefresh = refresh
    refresh = function(state)
        if not state.closed and (not state.registered or (not state.active and valid(state.tabs)
            and ui.fname(state.tabs:GetSelectedTabId()) == 'ModConfigUI')) then
            return ui.timed('menu.refresh', originalRefresh, state)
        end
        return originalRefresh(state)
    end

    bindLifecycle = function(state)
        if state.lifecycleReady then return end
        state.lifecycle = state.lifecycle or {}
        local outer = state.owner
        while valid(outer) do
            if ui.isA(outer, '/Script/CommonUI.CommonActivatableWidget') then
                local host, key = outer, address(outer)
                if ui.isA(host, HOST) then state.host = host end
                if not state.lifecycle[key] then
                    local entry = {}
                    entry.release = ui.lifecycleRelay(state.owner, host, function()
                        if state.disposed or state.closing or state.destroyPending then return end
                        state.closed = false
                        request(state) -- Defer menu/asset work out of the delegate callback.
                        ui.log('Lifecycle activated via delegate: ' .. host:GetFullName())
                    end, function()
                        if state.disposed then return end
                        ui.log('Lifecycle deactivated via delegate: ' .. host:GetFullName())
                        close(state, false)
                    end, function()
                        if state.disposed or state.closing or state.destroyPending then return end
                        state.destroyPending, state.closed = true, true
                        cancel(state, 'pending')
                        ui.setInputActive(state, false)
                        -- Leave Slate teardown before removing tabs or child widgets.
                        state.pending = later(0, function()
                            state.pending = nil
                            close(state, true)
                            ui.log('Lifecycle disposed via Blueprint Destruct: ' .. key)
                        end)
                    end)
                    state.lifecycle[key] = entry
                    ui.log('Lifecycle delegate bound: ' .. host:GetFullName()
                        .. '; active=' .. tostring(host:IsActivated()))
                end
            end
            outer = outer:GetOuter()
        end
        state.lifecycleReady = true
    end

    watchPanel = function(owner, host)
        if not ui.isA(owner, PANEL) or not valid(owner:GetOwningPlayer())
            or not valid(prop(owner, 'WidgetTree')) then return end
        for _, old in pairs(states) do
            if not valid(old.owner) then close(old, true) end
        end
        local key = address(owner)
        local state = states[key]
        if state and state.closing then return end
        if state and state.destroyPending then close(state, true); state = nil end
        if not state then
            state = {key = key, owner = owner, attempts = 0}
            states[key] = state
        end
        if valid(host) then state.host = host end
        state.closed = false
        if not state.registered then menu.observeLayout(state) end
        request(state)
    end
    local function tabChanged(tabs)
        for _, state in pairs(states) do if same(state.tabs, tabs) then request(state) end end
    end

    -- Loaded blueprint callbacks supplement the stable native entry point.
    local function hook(path, callback)
        ui.attempt('Could not attach menu callback ' .. path, ui.hook, path, callback, recheckHooks)
    end
    installHooks = function()
        hook(PANEL .. ':RefreshKey', function(owner)
            local state = states[address(owner)]
            if state and state.active then request(state) end
        end)
        hook(PANEL .. ':BP_OnWidgetDeactivated_Event', function(owner)
            local state = states[address(owner)]
            if state then close(state, false) end
        end)
        for _, name in ipairs({'HandleTabCreation', 'HandleTabRemoval', 'RefreshPadding', 'UpdateTabStyles'}) do
            hook(TABS .. ':' .. name, tabChanged)
        end
        recheckHooks = false
    end
    assert(ui.hook('/Script/CommonUI.CommonTabListWidgetBase:HandleTabButtonSelected', tabChanged), 'Tab selection hook unavailable')
    assert(ui.hook('/Script/GameSettings.GameSettingPanel:RefreshSettingsList', function(owner)
        watchPanel(owner)
    end), 'Settings list refresh hook unavailable')
    RegisterLoadMapPreHook(function()
        -- Check class identity once when settings are next created after travel.
        recheckHooks = true
        -- Release before travel tears down objects (title return and save load).
        for _, state in pairs(states) do
            ui.log('Lifecycle cleanup before map load: ' .. state.key)
            close(state, true)
        end
    end)
end

return M
