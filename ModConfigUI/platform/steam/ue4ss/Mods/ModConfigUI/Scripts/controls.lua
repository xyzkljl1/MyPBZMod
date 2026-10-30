-- Control selection, native input behavior and input-specific validation.
-- getValue() returns value (nil when invalid) and raw input; initialRaw is the display baseline.
local ui = require('native_ui')
local numbers = require('number_format')
local function idle() return false end
local function createChoice(owner, state, mod, row, value, changed, unbinds, definition)
    local choices = definition.params.options or {{value = false, label = state.t('off')}, {value = true, label = state.t('on')}}
    local labels, selected = {}, 0
    for index, item in ipairs(choices) do
        labels[index] = FText(item.label)
        if item.value == value then selected = index - 1 end
    end
    local old = row.Rotator_SettingValue
    local library = StaticFindObject('/Script/UMG.Default__WidgetBlueprintLibrary')
    local control = library:Create(owner, old:GetClass(), owner:GetOwningPlayer())
    assert(ui.valid(control), 'Could not create independent native boolean rotator')
    control:PopulateTextLabels(labels)
    control:SetSelectedItem(selected)
    control:SetIsInteractionEnabled(true)
    control:SetIsFocusable(false) -- Hover is visual only; choices are mouse-operated.
    ui.replaceInputControl(row, old, control)
    row.Rotator_SettingValue = control
    local function bindClick(button, delta)
        unbinds[#unbinds + 1] = ui.onClick(button, function()
            if state.active and not state.closed and ui.valid(control) then
                control:SetSelectedItem((control:GetSelectedIndex() + delta) % #choices)
                changed()
            end
        end)
    end
    bindClick(control, 1)
    for _, item in ipairs({{'Button_Decrease', -1}, {'Button_Increase', 1}}) do
        local oldButton = row[item[1]]
        local button = library:Create(owner, oldButton:GetClass(), owner:GetOwningPlayer())
        assert(ui.valid(button), 'Could not create native option arrow')
        ui.replaceInputControl(row, oldButton, button)
        button:SetIsInteractionEnabled(true)
        button:SetIsFocusable(false)
        row[item[1]] = button
        bindClick(button, item[2])
    end
    -- Keep the original arrow images, positions and option indicators.
    for _, name in ipairs({'DecreaseOverlay', 'IncreaseOverlay'}) do
        local overlay = ui.prop(row, name)
        if ui.valid(overlay) then overlay:SetVisibility(4) end
    end
    unbinds[#unbinds + 1] = ui.onOptionSelected(control, function()
        if state.active and not state.closed and (state.expanded or {})[mod] then changed() end
    end)
    return {control = control, initialRaw = value, isEditing = idle,
        getValue = function()
            local current = choices[control:GetSelectedIndex() + 1].value
            return current, current
        end,
        setValue = function(current)
            for index, item in ipairs(choices) do
                if item.value == current then control:SetSelectedItem(index - 1); return end
            end
        end}
end

local function textInput(owner, row, control, wrapper, initialRaw, getValue)
    local slot = ui.replaceInputControl(row, row.Rotator_SettingValue, wrapper)
    ui.hideArrows(row)
    if not ui.isA(slot, '/Script/UMG.CanvasPanelSlot') then
        slot:SetHorizontalAlignment(0) -- Fill the native value area, then center its text.
        slot:SetVerticalAlignment(2)
    end
    return {control = control, initialRaw = initialRaw, getValue = getValue,
        isEditing = function()
            return control:HasKeyboardFocus() or control:HasAnyUserFocus()
                or control:HasUserFocusedDescendants(owner:GetOwningPlayer())
        end}
end

local function createText(owner, state, mod, row, value, changed, unbinds, definition, preview)
    local label = ui.inputTextStyleSource(row)
    assert(ui.valid(label), 'Native text font template is unavailable')
    local control = ui.native(row.WidgetTree, 'EditableText', 'TextInput')
    control:SetFont(label.Font)
    control.WidgetStyle.ColorAndOpacity = label.ColorAndOpacity
    control:SetJustification(1)
    control:SetIsReadOnly(false)
    control:SetIsPassword(false)
    control:SetMinimumDesiredWidth(300)
    control.ClearKeyboardFocusOnCommit = true
    control.RevertTextOnEscape = true
    control.SelectAllTextWhenFocused = true
    control:SetText(FText(value))
    local wrapper, unbind = ui.textInputRelay(owner, row, control, function() changed(true) end, preview and function() preview(ui.fname(control:GetText())) end)
    unbinds[#unbinds + 1] = unbind
    local editor = textInput(owner, row, control, wrapper, value, function()
        local raw = ui.fname(control:GetText())
        return raw, raw
    end)
    editor.setValue = function(current) control:SetText(FText(current)); if preview then preview(current) end end
    editor.wrapper = wrapper
    editor.setHighlighted = function(selected)
        control.WidgetStyle.ColorAndOpacity = selected and row.SelectedColor or row.DefaultColor
        -- Refresh the color with this editor's own font, not the template's selected style.
        control:SetFont(control.WidgetStyle.Font)
    end
    return editor
end

local function createColor(owner, state, mod, row, value, changed, unbinds)
    local swatch = ui.native(row.WidgetTree, 'Border', 'ColorPreview')
    swatch:SetVisibility(3)
    local function preview(raw)
        if not raw:match('^#%x%x%x%x%x%x$') then return end
        local function channel(offset)
            local v = tonumber(raw:sub(offset, offset + 1), 16) / 255
            return v <= 0.04045 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4
        end
        swatch:SetBrushColor({R = channel(2), G = channel(4), B = channel(6), A = 1})
    end
    local editor = createText(owner, state, mod, row, value, changed, unbinds, nil, preview)
    local box = ui.native(row.WidgetTree, 'SizeBox', 'ColorPreviewSize')
    box:SetWidthOverride(42); box:SetHeightOverride(32); box:AddChild(swatch)
    -- Give text and preview separate layout space instead of overlapping them.
    editor.control:RemoveFromParent()
    local content = ui.native(row.WidgetTree, 'HorizontalBox', 'ColorInput')
    local textSlot = content:AddChildToHorizontalBox(editor.control)
    textSlot:SetVerticalAlignment(2)
    textSlot:SetPadding({Left = 0, Top = 0, Right = 12, Bottom = 0})
    content:AddChildToHorizontalBox(box):SetVerticalAlignment(2)
    local slot = editor.wrapper:AddChildToOverlay(content)
    slot:SetHorizontalAlignment(2); slot:SetVerticalAlignment(2)
    preview(value)
    local get = editor.getValue
    editor.getValue = function()
        local raw = get()
        return raw:match('^#%x%x%x%x%x%x$') and raw:upper() or nil, raw
    end
    return editor
end

local function createKey(owner, state, mod, row, value, changed, unbinds, definition)
    local keys = require('mcu_core.key_codes')
    local button = ui.createGameWidget(owner, 'MenuButton_KeyBinding_C')
    button:SetIsInteractionEnabled(true)
    local current, stop = value, nil
    local function display()
        local name = definition.type == 'LuaKey' and keys.names[current] or current
        local library = StaticFindObject('/Script/Engine.Default__KismetInputLibrary')
        local label = name == 'None' and state.t('unbound') or ui.fname(library:Key_GetDisplayName({KeyName = FName(name)}, false))
        button:SetCellText(FText(label))
    end
    ui.replaceInputControl(row, row.Rotator_SettingValue, button)
    ui.hideArrows(row)
    display()
    unbinds[#unbinds + 1] = ui.onClick(button, function()
        if not state.active or state.closed then return end
        stop = ui.captureKey(owner, state, function(name)
            if not keys.codes[name] or name == 'None' then return false end
            current = definition.type == 'LuaKey' and keys.codes[name] or name
            changed(true)
            return true
        end, function()
            stop = nil
            if ui.valid(button) then button:SetEditingVisual(false); display() end
        end)
        button:SetEditingVisual(true)
        button:SetCellText(FText(state.t('press_key')))
    end)
    unbinds[#unbinds + 1] = function() if stop then stop() end end
    return {control = button, initialRaw = value, isEditing = function() return stop ~= nil end,
        getValue = function() return current, current end,
        setValue = function(nextValue) current = nextValue; display() end}
end

local function numberText(value)
    return numbers.text(value)
end

local function createNumericText(owner, state, mod, row, value, changed, unbinds, definition)
    -- Preserve Lua integers/doubles; USpinBox narrows both to a 32-bit float.
    local editor = createText(owner, state, mod, row, numberText(value), changed, unbinds)
    local getText, setText = editor.getValue, editor.setValue
    editor.getValue = function()
        local raw = getText()
        local forbidden = definition.type == 'IntBox' and '[^%d%+%-]' or '[^%d%.%+%-eE]'
        if raw:find(forbidden) then return nil, raw end
        local number = tonumber(raw)
        if number == math.huge or number == -math.huge then number = nil end
        return number, raw
    end
    editor.setValue = function(current) setText(numberText(current)) end
    return editor
end

local function createSlider(owner, state, mod, row, value, changed, unbinds, definition)
    local old, params = row.Slider_SettingValue, definition.params
    local steps = math.floor((params.max - params.min) / params.step + 1e-7)
    assert(steps >= 0 and steps <= 9007199254740991, 'Slider range has too many steps')
    local control = ui.native(row.WidgetTree, 'Slider', 'SchemaSlider', old:GetClass())
    control.IsFocusable = false -- Set before inputRelay builds the Slate slider.
    for _, key in ipairs({'Textstyle', 'TextStyleCJK', 'BarMaterial'}) do
        local resource = ui.prop(old, key)
        if ui.valid(resource) then control[key] = resource end
    end
    for _, key in ipairs({'FilledBarTint', 'UnfilledBarTint'}) do
        local color = ui.prop(old, key)
        if color then for _, channel in ipairs({'R', 'G', 'B', 'A'}) do control[key][channel] = color[channel] end end
    end
    -- Copy brush leaves, avoiding UE4SS's nested Slate-struct conversion.
    for _, name in ipairs({'NormalBarImage', 'HoveredBarImage', 'DisabledBarImage',
        'NormalThumbImage', 'HoveredThumbImage', 'DisabledThumbImage'}) do
        local source, target = old.WidgetStyle[name], control.WidgetStyle[name]
        for _, key in ipairs({'DrawAs', 'Tiling', 'Mirroring', 'ImageType'}) do target[key] = source[key] end
        if ui.valid(source.ResourceObject) then target.ResourceObject = source.ResourceObject end
        for _, key in ipairs({'X', 'Y'}) do target.ImageSize[key] = source.ImageSize[key] end
        for _, key in ipairs({'Left', 'Top', 'Right', 'Bottom'}) do target.Margin[key] = source.Margin[key] end
        target.TintColor.ColorUseRule = source.TintColor.ColorUseRule
        for _, key in ipairs({'R', 'G', 'B', 'A'}) do target.TintColor.SpecifiedColor[key] = source.TintColor.SpecifiedColor[key] end
    end
    control.WidgetStyle.BarThickness = old.WidgetStyle.BarThickness
    control:SetMinValue(0); control:SetMaxValue(1)
    control:SetStepSize(steps > 0 and 1 / steps or 1)
    control:SetLocked(steps == 0)
    local current, previous, captured = value, nil, false
    local left, right, valueSlot
    local function display()
        control:SetDisplayValue(FText('')) -- Use only the label below the thumb.
        ui.setText(row.CurrentValue, numbers.text(current))
        for _, label in ipairs({row.CurrentValue, left, right}) do label:SetVisibility(4) end
        row.CurrentValue:SetRenderOpacity(1)
        local fraction = steps > 0 and ((current - params.min) / params.step) / steps or 0
        fraction = math.max(0, math.min(1, fraction))
        -- The wrapper fills the row; the bar is centered, not at its bottom edge.
        valueSlot:SetMinimum({X = fraction, Y = 0.5})
        valueSlot:SetMaximum({X = fraction, Y = 0.5})
        valueSlot:SetOffsets({Left = (0.5 - fraction) * (ui.prop(row, 'ThumbWidth') or 0),
            Top = 4, Right = 0, Bottom = 0})
    end
    local function setValue(nextValue)
        current = nextValue
        control:SetValue(steps > 0 and ((nextValue - params.min) / params.step) / steps or 0)
        previous = control:GetValue() -- Opening a page must not round or save its initial value.
        display()
    end
    local wrapper, receiver = ui.inputRelay(row, control, 'ProgressBar')
    ui.replaceInputControl(row, old, wrapper)
    row.Slider_SettingValue = control
    row:InitCachedTexts()
    ui.hideArrows(row)
    -- Keep the native font/color, but position the label in slider-local space.
    -- The original text slot sits beside the maximum, and native positioning
    -- assumes a different slider parent hierarchy.
    local valueLayer = ui.native(row.WidgetTree, 'CanvasPanel', 'SliderValueLayer')
    valueLayer:SetVisibility(3) -- HitTestInvisible: never intercept slider input.
    local layerSlot = wrapper:AddChildToOverlay(valueLayer)
    layerSlot:SetHorizontalAlignment(0)
    layerSlot:SetVerticalAlignment(0)
    row.CurrentValue:RemoveFromParent()
    valueSlot = valueLayer:AddChildToCanvas(row.CurrentValue)
    valueSlot:SetAutoSize(true)
    valueSlot:SetAlignment({X = 0.5, Y = 0})
    row.CurrentValue:SetRenderTranslation({X = 0, Y = 0})
    row.CurrentValue:SetVisibility(4)
    local duplicate = ui.prop(row, 'Text_SettingValue')
    if ui.valid(duplicate) and not ui.same(duplicate, row.CurrentValue) then duplicate:SetVisibility(1) end
    right = ui.prop(row, 'RightValue') or ui.prop(row, 'Text_RightValue')
    left = ui.prop(row, 'LeftValue') or ui.prop(row, 'Text_LeftValue')
    ui.setText(left, numbers.text(params.min))
    ui.setText(right, numbers.text(params.max))
    setValue(value)
    unbinds[#unbinds + 1] = ui.onSignal(control, 'OnValueChanged', receiver,
        '/Script/UMG.ProgressBar:SetPercent', function() changed(false) end)
    for _, mode in ipairs({'Mouse', 'Controller'}) do
        unbinds[#unbinds + 1] = ui.onSignal(control, 'On' .. mode .. 'CaptureBegin', receiver,
            '/Script/UMG.Widget:ForceLayoutPrepass', function() captured = true end)
        unbinds[#unbinds + 1] = ui.onSignal(control, 'On' .. mode .. 'CaptureEnd', receiver,
            '/Script/UMG.Widget:InvalidateLayoutAndVolatility', function()
                captured = false
                changed(true)
            end)
    end
    return {control = control, initialRaw = value,
        setValue = setValue,
        setHighlighted = function(selected)
            control:SetForceHovered(selected)
            row.CurrentValue:SetColorAndOpacity(selected and row.SelectedColor or row.DefaultColor)
            display()
        end,
        isEditing = function() return captured or control:HasMouseCapture() end,
        getValue = function()
            local raw = control:GetValue()
            if raw ~= previous then
                local tick = math.floor(math.max(0, math.min(1, raw)) * steps + 0.5)
                current = math.min(params.max, numbers.tick(params.min, params.step, tick))
                previous = raw
            end
            display()
            return current, current
        end}
end

local creators = {ColorBox = createColor, LuaKey = createKey, BPKey = createKey, BoolToggle = createChoice, IntSelect = createChoice, FloatSelect = createChoice,
    TextSelect = createChoice, IntBox = createNumericText, FloatBox = createNumericText,
    TextBox = createText, IntSlider = createSlider, FloatSlider = createSlider}
local M = {}
function M.simpleType(value) return ({boolean = 'BoolToggle', number = 'FloatBox', string = 'TextBox'})[type(value)] end
function M.resolve(definition) return creators[definition.type] end
function M.rowClass(definition)
    return definition.type:find('Slider$') and 'W_SettingsListEntry_Scalar_C' or 'W_SettingsListEntry_Discrete_C'
end

function M.create(owner, state, mod, row, value, changed, definition)
    definition = definition or {type = M.simpleType(value), params = {}}
    local create = assert(M.resolve(definition), 'Unsupported configuration control: ' .. tostring(definition.type))
    local unbinds = {}
    local applying, handling = false, false
    local function destroy()
        for index = #unbinds, 1, -1 do
            ui.attempt('Could not unbind control', table.remove(unbinds, index))
        end
    end
    local ok, editor = pcall(create, owner, state, mod, row, value, function(force)
        if applying or handling or not state.active or state.closed then return end
        handling = true
        local success, err = pcall(changed, force)
        handling = false
        if not success then error(err, 0) end
    end, unbinds, definition)
    if not ok then destroy(); error(editor, 0) end
    local setValue = editor.setValue
    editor.setValue = function(current)
        applying = true
        local success, err = pcall(setValue, current)
        applying = false
        if not success then error(err, 0) end
    end
    editor.destroy = destroy
    return editor
end
return M
