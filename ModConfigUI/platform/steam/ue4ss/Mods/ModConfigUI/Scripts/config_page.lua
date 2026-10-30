-- Configuration groups and persistence; control-specific behavior lives in controls.lua.
local ui = require('native_ui')
local controls = require('controls')
local simpleConfigs = require('simple_config')
local schemaConfigs = require('schema_config')
local encode = require('mcu_core.config_io').encode
local i18n = require('i18n')
local modLocalization = require('mod_localization')
local background = require('background')
local M = {}
local valid, native, createGameWidget = ui.valid, ui.native, ui.createGameWidget
local rowTitle, addRow, log = ui.rowTitle, ui.addRow, ui.log
local refreshGroup, updateGroup, simpleConfig

local function invalidateRefresh(state, group)
    state.refreshTicket, group.refreshTicket = nil, nil
end

local function selectEntry(entry, selected)
    if not valid(entry.row) then return end
    entry.row:SetSelected(selected)
    -- Keep the color override consistent with native paper selection visuals.
    for _, name in ipairs({'Text_SettingName', 'SettingName', 'LocText_SettingName'}) do
        ui.setTextColor(ui.prop(entry.row, name), selected)
    end
    ui.setTextColor(entry.title, selected)
    if entry.editor and entry.editor.setHighlighted then entry.editor.setHighlighted(selected) end
end

function M.clearHighlight(state)
    local previous = state.highlighted
    state.highlighted = nil
    if previous then ui.attempt('Could not clear row highlight', selectEntry, previous, false) end
    ui.showDetails(state, nil)
end

local function watchHighlight(state, entry, eventHost)
    return ui.onHighlight(eventHost, function(entered)
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
    end)
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
        invalidateRefresh(state, group)
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
            elseif not state.closed then refreshGroup(state, group) end
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
    local eventHost = ui.eventRow(owner, row)
    local editor = controls.create(owner, state, group.name, row, value, function(force)
        pollInputs(state, force ~= false, field)
    end, definition, eventHost)
    field.editor, field.control = editor, editor.control
    field.savedRaw, field.lastRaw = editor.initialRaw, editor.initialRaw
    -- Track the editor before later decoration can fail, so rollback unbinds it.
    state.inputs[#state.inputs + 1] = field
    local destroy, unbind = editor.destroy, watchHighlight(state, field, eventHost)
    editor.destroy = function()
        if state.highlighted == field then ui.attempt('Could not clear highlight', M.clearHighlight, state) end
        unbind()
        if destroy then destroy() end
    end
    addRow(group.body, eventHost)
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
    button:SetIsFocusable(false)
    local eventHost = ui.eventRow(owner, overlay)
    local unbindClick = ui.onClick(eventHost, button, function()
        if state.active and not state.closed then M.clearHighlight(state); action() end
    end)
    local unbindHighlight
    local function unbind() unbindClick(); if unbindHighlight then unbindHighlight() end end
    state.actions[#state.actions + 1] = unbind
    local entry = {row = row, definition = definition}
    unbindHighlight = watchHighlight(state, entry, eventHost)
    if rightAligned then
        row.Slot:SetHorizontalAlignment(0)
        row.Slot:SetVerticalAlignment(0)
        for _, name in ipairs({'Text_SettingName', 'SettingName', 'LocText_SettingName'}) do
            local source = ui.prop(row, name)
            if valid(source) then
                -- Keep native row animations away from the independent reset title.
                source:RemoveFromParent()
                local label = native(row.WidgetTree, 'TextBlock', 'ResetTitle')
                label:SetFont(source.Font)
                rowTitle(row, text, label)
                entry.title = label
                local labelSlot = overlay:AddChildToOverlay(label)
                labelSlot:SetHorizontalAlignment(0)
                labelSlot:SetVerticalAlignment(2)
                labelSlot:SetPadding({Left = 32, Top = 0, Right = 32, Bottom = 0})
                label:SetJustification(2)
                label:SetVisibility(3) -- HitTestInvisible; the button receives clicks.
                break
            end
        end
        local box = native(owner.WidgetTree, 'SizeBox', 'ResetButton')
        box:SetWidthOverride(600) -- Native UI design units; keeps the hit area on the right.
        local contentSlot = box:AddChild(eventHost)
        contentSlot:SetHorizontalAlignment(0)
        contentSlot:SetVerticalAlignment(0)
        container:AddChildToVerticalBox(box):SetHorizontalAlignment(3) -- Right
    else addRow(container, eventHost) end
    return row, button, unbind, entry.title
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
            refreshGroup(state, group)
        end
        updateHeading()
    end, true)
    updateHeading()
    addRow(state.rows, group.body)
    state.groups[mod] = group
    return group
end

local function schemaAction(state, group, action, key, row, label, title)
    if group.actionPending then return end
    if action == 'button' then
        pollInputs(state, true, nil, group.name)
        for _, field in ipairs(state.inputs) do
            if field.mod == group.name and field.failedRaw ~= nil then return end
        end
    end
    invalidateRefresh(state, group)
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
        if valid(row) then rowTitle(row, updated and label or state.t('save_failed', {name = label}), title) end
        if not updated then refreshGroup(state, group) end
    end
    local ok, err = schemaConfigs.request(group.snapshot, action, key, complete)
    if not ok then complete(nil, err) end
end

local function addResetButton(owner, state, group)
    group.resetRow, group.resetButton, group.resetUnbind, group.resetTitle = actionHeading(owner, state, group.body,
        state.t('reset_defaults'), function()
        if group.snapshot then
            schemaAction(state, group, 'reset', nil, group.resetRow, state.t('reset_defaults'), group.resetTitle)
            return
        end
        if group.actionPending then return end
        invalidateRefresh(state, group)
        group.actionPending = true
        group.body:SetIsEnabled(false)
        local ok, err = simpleConfigs.reset(group.id, function(values, readError)
            group.actionPending = false
            if readError then log('Could not read reset configuration ' .. group.id .. ': ' .. tostring(readError)) end
            if state.closed or not currentGroup(state, group) then return end
            group.body:SetIsEnabled(true)
            group.resetPending = true
            updateGroup(state, group, values and simpleConfig(group.id, values),
                readError and state.t('config_read_failed', {mod = group.id}) or state.t('reset_done'))
        end)
        if not ok then
            group.actionPending = false
            group.body:SetIsEnabled(true)
            rowTitle(group.resetRow, state.t('reset_failed'), group.resetTitle)
            log('Could not reset ' .. group.name .. ': ' .. tostring(err))
        end
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
    if ok then
        group.actions = {}
        for index = actionCount + 1, #state.actions do group.actions[state.actions[index]] = true end
        group.built = true
        return
    end
    clearInputs(state, inputCount, actionCount)
    ui.attempt('Could not clear incomplete group', function()
        if valid(group.body) then group.body:ClearChildren() end
    end)
    group.resetRow, group.resetButton, group.resetUnbind, group.resetTitle = nil, nil, nil, nil
    state.expanded[group.name] = false
    group.updateHeading()
    log('Could not build ' .. group.name .. ': ' .. tostring(err) .. '; expand again to retry.')
end

local originalPopulate = populateGroup
populateGroup = function(owner, state, group)
    return ui.timed('group.expand:' .. group.name, originalPopulate, owner, state, group)
end

simpleConfig = function(name, values)
    local keys, fields = {}, {}
    for key, value in pairs(values) do
        if type(key) == 'string' and utf8.len(key) and controls.simpleType(value) then keys[#keys + 1] = key end
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
        fields[#fields + 1] = {key = key, label = key, type = controls.simpleType(values[key]), params = {}}
    end
    return {key = 'simple:' .. name, name = name, values = values, fields = fields}
end

local function schemaConfig(snapshot, fields)
    return {key = 'schema:' .. snapshot.schema.id:lower(), name = snapshot.schema.id,
        values = snapshot.values, fields = fields or snapshot.schema.fields, snapshot = snapshot}
end

updateGroup = function(state, group, config, message)
    if config and group.snapshot and config.snapshot and group.snapshot.epoch == config.snapshot.epoch
        and group.snapshot.revision > config.snapshot.revision then return end
    local rebuild = not config or group.resetPending or encode(group.fields) ~= encode(config.fields)
        or (group.snapshot and config.snapshot and group.snapshot.epoch ~= config.snapshot.epoch)
    if rebuild then
        M.clearHighlight(state)
        for index = #state.inputs, 1, -1 do
            if state.inputs[index].mod == group.name then
                ui.attempt('Could not release input', table.remove(state.inputs, index).editor.destroy)
            end
        end
        for index = #state.actions, 1, -1 do
            if (group.actions or {})[state.actions[index]] then
                ui.attempt('Could not unbind action', table.remove(state.actions, index))
            end
        end
        group.actions, group.built, group.resetPending = nil, false, false
        group.body:ClearChildren()
        state.catalogNames = nil -- Reconcile the catalog on the next page entry.
    end
    if config then
        group.fields = config.fields
        syncGroup(state, group, config)
        if state.expanded[group.name] then populateGroup(state.owner, state, group) end
    else
        group.resetPending = true
        addHeading(state.owner, state, message, group.body)
    end
end

refreshGroup = function(state, group)
    if group.actionPending then return end
    local ticket = {}
    state.refreshTicket, group.refreshTicket = nil, ticket
    local function current()
        return group.refreshTicket == ticket and not state.closed and not state.disposed and currentGroup(state, group)
    end
    local function complete(config, err)
        if not current() then return end
        if err then log('Could not refresh ' .. group.id .. ': ' .. tostring(err)); return end
        updateGroup(state, group, config, state.t('config_read_failed', {mod = group.id}))
    end
    -- The registry exposes list(); only this group's snapshot/UI is applied.
    schemaConfigs.list(function(items, err)
        if not current() then return end
        if not items then complete(nil, err); return end
        for _, snapshot in ipairs(items) do
            if snapshot.schema.id:lower() == group.id:lower() then
                if group.snapshot then
                    local language = state.language
                    background.run('schema.localize', function()
                        return modLocalization.fields(snapshot.schema, language)
                    end, function(fields, reason)
                        if reason then log('Could not load language pack: ' .. tostring(reason)) end
                        complete(schemaConfig(snapshot, fields))
                    end, current)
                else state.refreshValues() end -- Replace a simple group that has registered a schema.
                return
            end
        end
        if group.snapshot then complete(nil); return end
        simpleConfigs.readAsync(group.id, function(values, err)
            complete(values and simpleConfig(group.id, values), err)
        end, current)
    end)
end

local function refreshConfigRows(owner, state)
    local t, language = i18n.get()
    state.t, state.language = t, language
    local ticket = {}
    state.refreshTicket = ticket
    for _, group in pairs(state.groups or {}) do group.refreshTicket = nil end
    local function current()
        return state.refreshTicket == ticket and not state.closed and not state.disposed and valid(state.rows)
    end
    local function render(items, configs, issues, localized)
        if not current() then return end
        state.t = i18n.apply(language, localized.strings)
        ui.refreshLanguage(state)
        if not configs then
            log('Configuration discovery failed: ' .. tostring(issues))
            configs, issues = {}, {{name = 'simple', error = tostring(issues)}}
        end
        local combined, shape = {}, {}
        for _, config in ipairs(configs) do
            combined[#combined + 1] = simpleConfig(config.name, config.values)
        end
        for _, snapshot in ipairs(items) do
            combined[#combined + 1] = schemaConfig(snapshot, localized.fields[snapshot.schema.id])
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
        if not current() then return end
        if not items then
            log('Schema discovery failed: ' .. tostring(err))
            if state.loadingRow then rowTitle(state.loadingRow, state.t('discovery_failed')) end
            return
        end
        -- Resolve registered schemas before reading any simple files.
        local schemaIds = {}
        for _, snapshot in ipairs(items) do schemaIds[snapshot.schema.id:lower()] = true end
        background.run('locales.load', function()
            local localized = {strings = i18n.load(language), fields = {}}
            for _, snapshot in ipairs(items) do
                localized.fields[snapshot.schema.id] = modLocalization.fields(snapshot.schema, language)
            end
            return localized
        end, function(localized, reason)
            if reason then log('Could not load language packs: ' .. tostring(reason)) end
            localized = localized or {strings = {}, fields = {}}
            simpleConfigs.discover(schemaIds, function(configs, issues)
                if not current() then return end
                state.loadingRow = nil
                ui.timed('catalog.render', render, items, configs, issues, localized)
            end, current)
        end, current)
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
    state.t, state.language = i18n.get()
    state.loadingRow = addHeading(owner, state, state.t('loading_configs'))
    state.refreshValues = function() refreshConfigRows(owner, state) end
    refreshConfigRows(owner, state)
    ui.mountPage(owner, state)
    return scroll
end


M.clearInputs, M.pollInputs = clearInputs, pollInputs
M.buildPage = buildPage
return M
