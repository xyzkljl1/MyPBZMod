-- Configuration groups and persistence; control-specific behavior lives in controls.lua.
local ui = require('native_ui')
local controls = require('controls')
local simpleConfigs = require('simple_config')
local schemaConfigs = require('schema_config')
local encode = require('mcu_core.config_io').encode
local i18n = require('i18n')
local modLocalization = require('mod_localization')
local M = {}
local valid, native, createGameWidget = ui.valid, ui.native, ui.createGameWidget
local rowTitle, addRow, log = ui.rowTitle, ui.addRow, ui.log

local function selectEntry(entry, selected)
    if not valid(entry.row) then return end
    entry.row:SetSelected(selected)
    if entry.editor and entry.editor.setHighlighted then entry.editor.setHighlighted(selected) end
end

function M.clearHighlight(state)
    local previous = state.highlighted
    state.highlighted = nil
    if previous then ui.attempt('Could not clear row highlight', selectEntry, previous, false) end
    ui.showDetails(state, nil)
end

local function watchHighlight(state, entry, button)
    return ui.onHighlight(entry.row, function(entered)
        if state.closed or not state.active then return end
        if entered then
            if state.highlighted ~= entry then
                M.clearHighlight(state)
                state.highlighted = entry
                selectEntry(entry, true)
                ui.showDetails(state, entry.definition)
            end
        elseif state.highlighted == entry and not entry.row:IsHovered()
            and not entry.row:HasUserFocusedDescendants(state.owner:GetOwningPlayer()) then
            M.clearHighlight(state)
        end
    end, button)
end

local function clearInputs(state, keepInputs, keepActions)
    ui.attempt('Could not clear highlight', M.clearHighlight, state)
    local inputs, actions = state.inputs or {}, state.actions or {}
    for index = #inputs, (keepInputs or 0) + 1, -1 do
        ui.attempt('Could not release input', table.remove(inputs, index).editor.destroy)
    end
    for index = #actions, (keepActions or 0) + 1, -1 do
        ui.attempt('Could not unbind action', table.remove(actions, index))
    end
    state.inputs, state.actions = inputs, actions
end

local function currentGroup(state, group)
    return state.groups and state.groups[group.name] == group and valid(group.body)
end

local function syncGroup(state, group, config)
    if group.snapshot and config.snapshot and group.snapshot.epoch == config.snapshot.epoch
        and group.snapshot.revision > config.snapshot.revision then return end
    group.values, group.snapshot = config.values, config.snapshot
    if state.closed or not currentGroup(state, group) then return end
    group.body:SetIsEnabled(not group.actionPending)
    for _, field in ipairs(state.inputs) do
        if field.mod == group.name and valid(field.control) then
            local _, raw = field.editor.getValue()
            local reset = group.resetFields and (group.resetFields.key == nil or group.resetFields.key == field.key)
            if reset or (not field.pending and not field.editor.isEditing() and raw == field.savedRaw) then
                field.editor.setValue(config.values[field.key])
                local _, updatedRaw = field.editor.getValue()
                field.saved, field.savedRaw, field.lastRaw = config.values[field.key], updatedRaw, updatedRaw
                field.failedRaw = nil
                rowTitle(field.row, field.label)
            end
        end
    end
    group.resetFields = nil
end

local function pollInputs(state, force, onlyField, onlyMod)
    local pending = {}
    for _, field in ipairs(onlyField and {onlyField} or state.inputs or {}) do
        local control = field.control
        local selected = (not onlyField or field == onlyField) and (not onlyMod or field.mod == onlyMod)
        local visibleInput = (state.expanded or {})[field.mod]
        local group = state.groups[field.mod]
        if selected and not group.actionPending and (force or visibleInput) and valid(control) then
            local value, raw = field.editor.getValue()
            if raw ~= field.lastRaw then
                field.lastRaw = raw
                field.failedRaw = nil
                rowTitle(field.row, field.label)
            end
            local editing = field.editor.isEditing()
            if (raw ~= field.savedRaw or field.pending) and raw ~= field.pendingRaw
                and raw ~= field.failedRaw and (force or not editing) then
                if group.snapshot and value ~= nil and not schemaConfigs.validate(field.definition, value) then
                    value = nil
                end
                if value == nil then
                    field.editor.setValue(field.saved)
                    local _, restoredRaw = field.editor.getValue()
                    field.savedRaw, field.lastRaw, field.failedRaw = restoredRaw, restoredRaw, nil
                    rowTitle(field.row, field.label)
                elseif value == field.saved and not field.pending then
                    field.savedRaw = raw -- Formatting-only numeric changes do not write.
                    rowTitle(field.row, field.label)
                else
                    local batch = pending[field.mod]
                    if not batch then
                        batch = {changes = {}, expected = {}, fields = {}}
                        pending[field.mod] = batch
                    end
                    batch.changes[field.key] = value
                    batch.expected[field.key] = field.saved
                    batch.fields[#batch.fields + 1] = {field = field, raw = raw, value = value}
                end
            elseif raw == field.savedRaw and field.failedRaw ~= nil then
                field.failedRaw = nil
                rowTitle(field.row, field.label)
            end
        end
    end
    for mod, batch in pairs(pending) do
        local group, token = state.groups[mod], {}
        for _, change in ipairs(batch.fields) do change.field.pending, change.field.pendingRaw = token, change.raw end
        local function complete(updated, err)
            if err then log('Could not save ' .. group.id .. ': ' .. tostring(err)) end
            if not state.groups or state.groups[mod] ~= group then return end
            for _, change in ipairs(batch.fields) do
                local field = change.field
                if updated then field.saved, field.savedRaw = updated.values[field.key], change.raw end
                if field.pending == token then
                    field.pending, field.pendingRaw = nil, nil
                    if updated then field.failedRaw = nil else field.failedRaw = change.raw end
                    if not state.closed and valid(field.row) then
                        rowTitle(field.row, updated and field.label or state.t('save_failed', {name = field.label}))
                    end
                end
            end
            if updated then syncGroup(state, group, {values = updated.values, snapshot = group.snapshot and updated})
            elseif not state.closed and state.refreshValues then state.refreshValues() end
        end
        if group.snapshot then
            local ok, err = schemaConfigs.request(group.snapshot, 'save', batch.changes, complete)
            if not ok then complete(nil, err) end
        else
            local ok, err = simpleConfigs.update(group.id, batch.changes, batch.expected)
            if ok then for key, value in pairs(batch.changes) do group.values[key] = value end end
            complete(ok and {values = group.values}, err)
        end
    end
end

local function addConfigInput(owner, state, group, definition)
    local value = group.values[definition.key]
    local row = createGameWidget(owner, controls.rowClass(definition))
    rowTitle(row, definition.label)
    local field = {mod = group.name, key = definition.key, label = definition.label,
        definition = definition, row = row, saved = value}
    local editor = controls.create(owner, state, group.name, row, value, function(force)
        pollInputs(state, force ~= false, field)
    end, definition)
    field.editor, field.control = editor, editor.control
    field.savedRaw, field.lastRaw = editor.initialRaw, editor.initialRaw
    -- Track the editor before later decoration can fail, so rollback unbinds it.
    state.inputs[#state.inputs + 1] = field
    local destroy, unbind = editor.destroy, watchHighlight(state, field)
    editor.destroy = function()
        if state.highlighted == field then ui.attempt('Could not clear highlight', M.clearHighlight, state) end
        unbind()
        if destroy then destroy() end
    end
    addRow(group.body, row)
end

local function actionHeading(owner, state, container, text, action, prominent, rightAligned, definition)
    local overlay = native(owner.WidgetTree, 'Overlay', 'GroupHeading')
    local row = createGameWidget(owner, prominent and 'W_SettingsListEntry_Collection_Category_C'
        or 'W_SettingsListEntry_Action_C')
    rowTitle(row, text)
    ui.emphasizeHeading(row, prominent and 1.6 or 1)
    overlay:AddChildToOverlay(row)
    local button = createGameWidget(owner, 'W_SettingBaseButton_C')
    local slot = overlay:AddChildToOverlay(button)
    slot:SetHorizontalAlignment(0)
    slot:SetVerticalAlignment(0)
    button:SetVisibility(0)
    button:SetIsEnabled(true)
    button:SetIsInteractionEnabled(true)
    button:SetIsFocusable(true)
    local unbindClick = ui.onClick(button, function()
        if state.active and not state.closed then M.clearHighlight(state); action() end
    end)
    local unbindHighlight
    local function unbind() unbindClick(); if unbindHighlight then unbindHighlight() end end
    state.actions[#state.actions + 1] = unbind
    unbindHighlight = watchHighlight(state, {row = row, definition = definition}, button)
    if rightAligned then
        for _, name in ipairs({'Text_SettingName', 'SettingName', 'LocText_SettingName'}) do
            local label = ui.prop(row, name)
            if valid(label) then label:SetJustification(2) end
        end
        local box = native(owner.WidgetTree, 'SizeBox', 'ResetButton')
        box:SetWidthOverride(600) -- Native UI design units; keeps the hit area on the right.
        box:AddChild(overlay)
        container:AddChildToVerticalBox(box):SetHorizontalAlignment(2)
    else addRow(container, overlay) end
    return row, button, unbind
end

local populateGroup
local function addModGroup(owner, state, config)
    local mod = config.key
    state.expanded = state.expanded or {}
    local group = {name = mod, id = config.name, values = config.values, fields = config.fields,
        snapshot = config.snapshot, body = native(owner.WidgetTree, 'VerticalBox', 'ModGroup')}
    local function updateHeading()
        local expanded = state.expanded[mod] == true
        rowTitle(group.heading, (expanded and '-  ' or '+  ') .. group.id
            .. (group.snapshot and ' (Schema Config)' or ' (Simple Config)'))
        group.body:SetVisibility(expanded and 4 or 1)
    end
    group.updateHeading = updateHeading
    group.heading, group.button = actionHeading(owner, state, state.rows, '', function()
        if state.expanded[mod] then
            pollInputs(state, true, nil, mod)
            for _, input in ipairs(state.inputs) do
                if input.mod == mod and input.failedRaw ~= nil then return end
            end
        end
        state.expanded[mod] = not state.expanded[mod]
        if state.expanded[mod] then
            populateGroup(owner, state, group)
            if state.refreshValues then state.refreshValues() end
        end
        updateHeading()
    end, true)
    updateHeading()
    addRow(state.rows, group.body)
    state.groups[mod] = group
    return group
end

local function schemaAction(state, group, action, key, row, label)
    if group.actionPending then return end
    if action == 'button' then
        pollInputs(state, true, nil, group.name)
        for _, field in ipairs(state.inputs) do
            if field.mod == group.name and field.failedRaw ~= nil then return end
        end
    end
    group.actionPending = true
    group.body:SetIsEnabled(false)
    local function complete(updated, err)
        group.actionPending = false
        if err then log('Could not ' .. action .. ' ' .. group.id .. ': ' .. tostring(err)) end
        if not currentGroup(state, group) then return end
        if updated then
            if action == 'reset' then group.resetFields = {key = key} end
            syncGroup(state, group, {values = updated.values, snapshot = updated})
        end
        if state.closed then return end
        group.body:SetIsEnabled(true)
        if valid(row) then rowTitle(row, updated and label or state.t('save_failed', {name = label})) end
        if not updated and state.refreshValues then state.refreshValues() end
    end
    local ok, err = schemaConfigs.request(group.snapshot, action, key, complete)
    if not ok then complete(nil, err) end
end

local function addResetButton(owner, state, group)
    group.resetRow, group.resetButton, group.resetUnbind = actionHeading(owner, state, group.body,
        state.t('reset_defaults'), function()
        if group.snapshot then
            schemaAction(state, group, 'reset', nil, group.resetRow, state.t('reset_defaults'))
            return
        end
        local ok, err = simpleConfigs.reset(group.id)
        if not ok then
            rowTitle(group.resetRow, state.t('reset_failed'))
            log('Could not reset ' .. group.name .. ': ' .. tostring(err))
            return
        end
        for index = #state.inputs, 1, -1 do
            local input = state.inputs[index]
            if input.mod == group.name then
                table.remove(state.inputs, index)
                ui.attempt('Could not release input', input.editor.destroy)
            end
        end
        ui.attempt('Could not unbind reset', group.resetUnbind)
        group.body:ClearChildren()
        group.resetPending = true
        local status = createGameWidget(owner, 'W_SettingsListEntry_Collection_Category_C')
        rowTitle(status, state.t('reset_done'))
        addRow(group.body, status)
    end, false, true)
end

local function addHeading(owner, state, text, container)
    local row = createGameWidget(owner, 'W_SettingsListEntry_Collection_Category_C')
    rowTitle(row, text)
    addRow(container or state.rows, row)
    return row
end

populateGroup = function(owner, state, group)
    if group.built then return end
    local inputCount, actionCount = #state.inputs, #state.actions
    local ok, err = pcall(function()
        for _, definition in ipairs(group.fields) do
            if definition.type == 'Separator' then
                ui.addSeparator(owner, group.body, definition.label)
            elseif definition.type == 'Button' then
                local row
                row = actionHeading(owner, state, group.body, definition.label, function()
                    schemaAction(state, group, 'button', definition.key, row, definition.label)
                end, false, false, definition)
            else
                addConfigInput(owner, state, group, definition)
            end
        end
        if #group.fields == 0 then addHeading(owner, state, state.t('no_fields'), group.body) end
        addResetButton(owner, state, group)
    end)
    if ok then group.built = true; return end
    clearInputs(state, inputCount, actionCount)
    ui.attempt('Could not clear incomplete group', function()
        if valid(group.body) then group.body:ClearChildren() end
    end)
    group.resetRow, group.resetButton, group.resetUnbind = nil, nil, nil
    state.expanded[group.name] = false
    group.updateHeading()
    log('Could not build ' .. group.name .. ': ' .. tostring(err) .. '; expand again to retry.')
end

local function refreshConfigRows(owner, state)
    local t, language = i18n.get()
    state.t, state.language = t, language
    local ticket = {}
    state.refreshTicket = ticket
    local function render(items)
        if state.refreshTicket ~= ticket or state.closed or not valid(state.rows) then return end
        -- Get the registry first: a schema mod's simple file must not even be read.
        local schemaIds = {}
        for _, snapshot in ipairs(items) do schemaIds[snapshot.schema.id:lower()] = true end
        local configs, issues = simpleConfigs.discover(schemaIds)
        if not configs then
            log('Configuration discovery failed: ' .. tostring(issues))
            configs, issues = {}, {{name = 'simple', error = tostring(issues)}}
        end
        local combined, shape = {}, {}
        for _, config in ipairs(configs) do
            local keys, fields = {}, {}
            for key in pairs(config.values) do keys[#keys + 1] = key end
            table.sort(keys)
            for _, key in ipairs(keys) do
                fields[#fields + 1] = {key = key, label = key, type = controls.simpleType(config.values[key]), params = {}}
            end
            combined[#combined + 1] = {key = 'simple:' .. config.name, name = config.name, values = config.values, fields = fields}
        end
        for _, snapshot in ipairs(items) do
            combined[#combined + 1] = {key = 'schema:' .. snapshot.schema.id:lower(), name = snapshot.schema.id,
                values = snapshot.values, fields = modLocalization.fields(snapshot.schema, language), snapshot = snapshot}
        end
        table.sort(combined, function(a, b) return a.key < b.key end)
        local rebuild = false
        for _, config in ipairs(combined) do
            shape[#shape + 1] = {config.key, config.fields, config.snapshot and config.snapshot.epoch}
            local group = (state.groups or {})[config.key]
            if not group or group.resetPending or not valid(group.body) then rebuild = true end
        end
        local signature = encode({shape, language, issues})
        rebuild = rebuild or state.catalogNames ~= signature
        for _, field in ipairs(state.inputs or {}) do
            if not valid(field.control) then rebuild = true; break end
        end
        if not rebuild then
            for _, config in ipairs(combined) do syncGroup(state, state.groups[config.key], config) end
            return
        end
        -- Defer structural changes during edits or an outstanding request.
        if state.active then
            for _, group in pairs(state.groups or {}) do
                if group.actionPending or (group.snapshot and schemaConfigs.busy(group.snapshot)) then return end
            end
            for _, field in ipairs(state.inputs or {}) do
                if valid(field.control) then
                    local _, raw = field.editor.getValue()
                    if field.pending or field.editor.isEditing() or raw ~= field.savedRaw then return end
                end
            end
        end
        local offset = state.scroll:GetScrollOffset()
        clearInputs(state)
        state.rows:ClearChildren()
        state.groups = {}
        for _, config in ipairs(combined) do
            local group = addModGroup(owner, state, config)
            if state.expanded[config.key] then populateGroup(owner, state, group) end
        end
        if #combined == 0 then addHeading(owner, state, state.t('no_configs')) end
        for _, issue in ipairs(issues) do
            addHeading(owner, state, state.t('config_read_failed', {mod = issue.name}))
            log('Skipping ' .. issue.name .. ': ' .. tostring(issue.error))
        end
        state.scroll:SetScrollOffset(offset)
        state.catalogNames = signature
    end
    schemaConfigs.list(function(items, err)
        if state.refreshTicket ~= ticket or state.disposed then return end
        if not items then log('Schema discovery failed: ' .. tostring(err)); return end
        render(items)
    end)
end

local function buildPage(owner, state)
    local scroll = native(owner.WidgetTree, 'ScrollBox', 'ConfigScroll')
    state.page, state.scroll = scroll, scroll
    scroll:SetVisibility(0)
    scroll:SetClipping(1)
    scroll:SetAllowOverScroll(false)
    scroll:SetScrollbarThickness({X = 4, Y = 4})
    scroll:SetScrollWhenFocusChanges(1) -- InstantScroll: focused inputs remain visible.
    local rows = native(owner.WidgetTree, 'VerticalBox', 'ConfigRows')
    rows:SetVisibility(4)
    local slot = scroll:AddChild(rows)
    assert(valid(slot), 'Could not attach configuration rows')
    slot:SetHorizontalAlignment(0)
    state.rows = rows
    state.refreshValues = function() refreshConfigRows(owner, state) end
    refreshConfigRows(owner, state)
    ui.mountPage(owner, state)
    return scroll
end


M.clearInputs, M.pollInputs = clearInputs, pollInputs
M.buildPage = buildPage
return M
