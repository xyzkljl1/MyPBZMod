-- PBZ menu lifecycle; input editors subscribe to their own native events.
local ui = require('native_ui')
local PANEL = '/Game/PBZContent/UI/GameSystem/Settings/W_PBZSettingPanel.W_PBZSettingPanel_C'
local HOST = '/Game/PBZContent/UI/UINew/System/Setting/W_SettingActivateableWidget.W_SettingActivateableWidget_C'
local TABS = '/Game/PBZContent/UI/Foundation/TabbedView/W_OverlayTabList.W_OverlayTabList_C'
local M = {}

function M.start(menu, page)
    local valid, same, address, prop = ui.valid, ui.same, ui.address, ui.prop
    local states = {}
    local watchPanel, installHooks, refresh

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
        ui.attempt('Could not release input hooks', ui.setInputActive, state, false)
        if state.registered then ui.attempt('Could not leave MCU page', menu.updateSelection, state, false) end
        state.active = false
        if state.destroyPending then
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
        if not state.registered then
            if state.attempts > 0 then return end -- Failed mutations are never retried.
            installHooks()
            local ready, reason = menu.tryInitialize(state)
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
    refresh = function(state) return ui.timed('menu.refresh', originalRefresh, state) end

    watchPanel = function(owner, host)
        if not ui.isA(owner, PANEL) or not valid(owner:GetOwningPlayer())
            or not valid(prop(owner, 'WidgetTree')) then return end
        for _, old in pairs(states) do
            if not valid(old.owner) then close(old, true) end
        end
        local key = address(owner)
        local state = states[key]
        if state and state.closing then return end
        if not state then
            state = {key = key, owner = owner, attempts = 0}
            states[key] = state
            -- PBZ: panel -> WidgetTree -> W_SettingWidget -> WidgetTree -> settings host.
            local outer = owner
            for _ = 1, 4 do if valid(outer) then outer = outer:GetOuter() end end
            if ui.isA(outer, HOST) then state.host = outer end
        end
        if valid(host) then state.host = host end
        state.closed = false
        if not state.registered then menu.observeLayout(state) end
        request(state)
    end
    local function hostOpened(host)
        local settings = prop(host, 'W_SettingWidget')
        watchPanel(valid(settings) and prop(settings, 'Settings_Panel'), host)
    end
    local function hostClosed(host, destroy)
        for _, state in pairs(states) do if same(state.host, host) then close(state, destroy) end end
    end
    local function tabChanged(tabs)
        for _, state in pairs(states) do if same(state.tabs, tabs) then request(state) end end
    end

    local function ancestorClosed(widget, destroy)
        for _, state in pairs(states) do
            local outer = state.owner
            while valid(outer) do
                if same(outer, widget) then close(state, destroy); break end
                outer = outer:GetOuter()
            end
        end
    end

    -- Loaded blueprint callbacks supplement the stable native entry point.
    local function hook(path, callback)
        ui.attempt('Could not attach menu callback ' .. path, ui.hook, path, callback)
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
        hook(HOST .. ':BP_OnActivated', hostOpened)
        hook(HOST .. ':BP_OnDeactivated', function(host) hostClosed(host, false) end)
        hook(HOST .. ':Destruct', function(host) hostClosed(host, true) end)
        for _, name in ipairs({'HandleTabCreation', 'HandleTabRemoval', 'RefreshPadding', 'UpdateTabStyles'}) do
            hook(TABS .. ':' .. name, tabChanged)
        end
    end
    assert(ui.hook('/Script/CommonUI.CommonTabListWidgetBase:HandleTabButtonSelected', tabChanged), 'Tab selection hook unavailable')
    assert(ui.hook('/Script/GameSettings.GameSettingPanel:RefreshSettingsList', function(owner)
        watchPanel(owner)
    end), 'Settings list refresh hook unavailable')
    -- The in-game menu has a different host from title-screen settings. Match
    -- its owning widget chain instead of relying on the title host's events.
    assert(ui.hook('/Script/CommonUI.CommonActivatableWidget:BP_OnDeactivated', function(widget)
        ancestorClosed(widget, false)
    end), 'Menu deactivation hook unavailable')
    assert(ui.hook('/Script/UMG.UserWidget:Destruct', function(widget)
        ancestorClosed(widget, true)
    end), 'Menu destruction hook unavailable')
    RegisterLoadMapPreHook(function()
        -- Release before travel tears down objects (title return and save load).
        for _, state in pairs(states) do close(state, true) end
    end)
end

return M
