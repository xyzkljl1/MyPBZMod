-- PBZ widgets, layout, tab integration and native input events.
local M = {}
local numbers = require('number_format')
local TAG, TAB_ID = '[ModConfigUI] ', 'ModConfigUI'
local classCache, assetAttempts = {}, {}
local serial = 0
local assets = {
    W_SettingsListEntry_Collection_Category_C = '/Game/PBZContent/UI/Settings/Editors/W_SettingsListEntry_Collection_Category.W_SettingsListEntry_Collection_Category_C',
    W_SettingsListEntry_Discrete_C = '/Game/PBZContent/UI/Settings/Editors/W_SettingsListEntry_Discrete.W_SettingsListEntry_Discrete_C',
    W_SettingsListEntry_Scalar_C = '/Game/PBZContent/UI/Settings/Editors/W_SettingsListEntry_Scalar.W_SettingsListEntry_Scalar_C',
    W_SettingsListEntry_Action_C = '/Game/PBZContent/UI/Settings/Editors/W_SettingsListEntry_Action.W_SettingsListEntry_Action_C',
}

local function log(value) print(TAG .. tostring(value) .. '\n') end
local function attempt(label, callback, ...)
    local ok, result = pcall(callback, ...)
    if not ok then log(label .. ': ' .. tostring(result)) end
    return ok, result
end
local function valid(object)
    if object == nil then return false end
    local ok, result = pcall(function() return object:IsValid() end)
    return ok and result
end
local function prop(object, key)
    local ok, value = pcall(function() return object[key] end)
    if ok then return value end
end
local function unwrap(value)
    local ok, result = pcall(function() return value:get() end)
    if ok then return result end
    return value
end
local function fullName(object)
    if valid(object) then return object:GetFullName() end
    return '<invalid>'
end
local function address(object) return tostring(object:GetAddress()) end
local function fname(value)
    local ok, text = pcall(function() return value:ToString() end)
    if ok then return text end
    return tostring(value)
end
local function same(a, b)
    return valid(a) and valid(b) and address(a) == address(b)
end
local function isA(object, path)
    local class = StaticFindObject(path)
    return valid(object) and valid(class) and object:IsA(class)
end
local function native(tree, className, suffix, class)
    class = class or StaticFindObject('/Script/UMG.' .. className)
    assert(valid(class), 'Native class missing: ' .. className)
    serial = serial + 1
    local widget = StaticConstructObject(class, tree,
        FName('ModConfigUI_' .. suffix .. '_' .. serial), 0x40)
    assert(valid(widget), 'Construction failed: ' .. className)
    return widget
end

local function gameClass(shortName)
    if valid(classCache[shortName]) then return classCache[shortName] end
    local path = assets[shortName]
    if path then
        local class = StaticFindObject(path)
        if valid(class) then classCache[shortName] = class; return class end
    end
    for _, object in ipairs(FindAllOf(shortName) or {}) do
        if valid(object) then
            classCache[shortName] = object:GetClass()
            return classCache[shortName]
        end
    end
    -- Resolve loaded classes first; only paths verified in ObjectDump may be loaded.
    for _, class in ipairs(FindAllOf('WidgetBlueprintGeneratedClass') or {}) do
        if valid(class) and fname(class:GetFName()) == shortName then
            classCache[shortName] = class
            return class
        end
    end
    if assets[shortName] and (not assetAttempts[shortName] or os.time() - assetAttempts[shortName] >= 5) then
        assetAttempts[shortName] = os.time()
        local loaded = LoadAsset(assets[shortName])
        if valid(loaded) and isA(loaded, '/Script/CoreUObject.Class') then
            classCache[shortName] = loaded
            return loaded
        end
        local class = StaticFindObject(assets[shortName])
        if valid(class) then classCache[shortName] = class; return class end
    end

end

local function createGameWidget(owner, shortName)
    local class = gameClass(shortName)
    assert(valid(class), 'Game widget not loaded: ' .. shortName .. '; open an audio/gameplay settings page first')
    local library = StaticFindObject('/Script/UMG.Default__WidgetBlueprintLibrary')
    assert(valid(library), 'WidgetBlueprintLibrary is unavailable')
    local widget = library:Create(owner, class, owner:GetOwningPlayer())
    assert(valid(widget), 'Create failed for ' .. shortName)
    -- Row shells are unbound to GameSetting; independent inputs replace their controls.
    widget.TickFrequency = 0 -- EWidgetTickFrequency::Never (verified in UE 5.7.4)
    widget:SetVisibility(4) -- SelfHitTestInvisible: children can receive input.
    return widget
end

local function setText(widget, value)
    if not valid(widget) then return false end
    if isA(widget, '/Script/ProjectPBZ.PBZCommonLocText') then
        widget:SetPBZFormatText(FText(value))
    else
        widget:SetText(FText(value))
    end
    return true
end
local function setFields(widget, fields, value)
    local count = 0
    for _, field in ipairs(fields) do
        if setText(prop(widget, field), value) then count = count + 1 end
    end
    return count
end
local function rowTitle(row, value)
    assert(setFields(row, {'Text_SettingName', 'SettingName', 'LocText_SettingName'}, value) > 0,
        'Game row has no supported title widget: ' .. fullName(row))
end

local function inputTextStyleSource(row)
    -- The base rotator binds MyText. Some cooked variants also expose Text,
    -- but that blueprint-specific field is not populated in every settings host.
    local rotator = prop(row, 'Rotator_SettingValue')
    for _, field in ipairs({'MyText', 'Text'}) do
        local label = valid(rotator) and prop(rotator, field) or nil
        if valid(label) and prop(label, 'Font') ~= nil then return label end
    end
    -- The row's title provides a native-font fallback before the value label is ready.
    for _, field in ipairs({'LocText_SettingName', 'Text_SettingName', 'SettingName'}) do
        local label = prop(row, field)
        if valid(label) and prop(label, 'Font') ~= nil then return label end
    end
end

local function addRow(page, row)
    local slot = page:AddChildToVerticalBox(row)
    assert(valid(slot), 'Could not add game row')
    slot:SetHorizontalAlignment(0) -- Fill; let the game widget keep its own height.
end

function M.addSeparator(owner, page, text)
    local line = createGameWidget(owner, 'W_SecondTabLine_C')
    assert(setText(line.LineText, text), 'Native separator text is unavailable')
    -- Select the text branch of the native text/image title switcher.
    local child = line.LineText
    while valid(child) and not same(child, line) do
        local parent = child:GetParent()
        if not valid(parent) then break end
        if isA(parent, '/Script/UMG.WidgetSwitcher') then parent:SetActiveWidget(child) end
        child = parent
    end
    line:SetVisibility(3) -- HitTestInvisible: decorative, including its children.
    local box = native(owner.WidgetTree, 'SizeBox', 'Separator')
    box:SetMinDesiredHeight(100)
    box:AddChild(line)
    addRow(page, box)
    line:SetRenderOpacity(1)
end

local function listLayout(owner)
    local list = prop(owner, 'ListView_Settings')
    local switcher = prop(owner, 'WidgetSwitcher_65')
    if not valid(list) or not valid(switcher) or not valid(prop(list, 'Slot')) then
        return nil, 'native settings list/slot not ready'
    end
    local chain, child = {}, list
    for _ = 1, 24 do
        local parent = child:GetParent()
        if not valid(parent) or not valid(prop(child, 'Slot')) then break end
        if same(parent, switcher) then
            return {list = list, parent = list:GetParent(), slot = list.Slot,
                switcher = switcher, nativePage = child, rootSlot = child.Slot, chain = chain}
        end
        local kind
        for _, candidate in ipairs({'CanvasPanel', 'Overlay', 'SizeBox'}) do
            if isA(parent, '/Script/UMG.' .. candidate) then kind = candidate; break end
        end
        if not kind then return nil, 'unsupported layout ancestor: ' .. fullName(parent) end
        chain[#chain + 1] = {source = parent, slot = child.Slot, kind = kind}
        child = parent
    end
    return nil, 'native list is outside the expected page switcher'
end

local function margin(value)
    return {Left = value.Left, Top = value.Top, Right = value.Right, Bottom = value.Bottom}
end

local function slotStyle(slot)
    local padding = prop(slot, 'Padding')
    return {padding = padding and margin(padding),
        horizontal = prop(slot, 'HorizontalAlignment'), vertical = prop(slot, 'VerticalAlignment')}
end

local function applySlotStyle(slot, style)
    if style.padding then slot:SetPadding(style.padding) end
    if style.horizontal ~= nil then slot:SetHorizontalAlignment(style.horizontal) end
    if style.vertical ~= nil then slot:SetVerticalAlignment(style.vertical) end
end

local function copyLayoutSlot(source, target)
    if isA(source, '/Script/UMG.CanvasPanelSlot') then
        local anchors, alignment = source:GetAnchors(), source:GetAlignment()
        target:SetMinimum({X = anchors.Minimum.X, Y = anchors.Minimum.Y})
        target:SetMaximum({X = anchors.Maximum.X, Y = anchors.Maximum.Y})
        target:SetAlignment({X = alignment.X, Y = alignment.Y})
        target:SetOffsets(margin(source:GetOffsets()))
        target:SetAutoSize(source:GetAutoSize())
        target:SetZOrder(source:GetZOrder())
    else
        applySlotStyle(target, slotStyle(source))
    end
end

local function layoutContainer(owner, edge)
    local container = native(owner.WidgetTree, edge.kind, 'Layout')
    if edge.kind == 'SizeBox' then
        for _, field in ipairs({'WidthOverride', 'HeightOverride', 'MinDesiredWidth',
            'MinDesiredHeight', 'MaxDesiredWidth', 'MaxDesiredHeight', 'MinAspectRatio', 'MaxAspectRatio'}) do
            if prop(edge.source, 'bOverride_' .. field) then container['Set' .. field](container, edge.source[field]) end
        end
    end
    return container
end

local function mountDetails(owner, state, copies)
    local source = prop(owner, 'Details_Settings')
    if not valid(source) then return end
    local chain, child, target, fallback = {}, source
    for _ = 1, 24 do
        local parent = child:GetParent()
        if not valid(parent) or not valid(prop(child, 'Slot')) then break end
        if copies[address(parent)] then target = copies[address(parent)]; break end
        local kind
        for _, candidate in ipairs({'CanvasPanel', 'Overlay', 'SizeBox'}) do
            if isA(parent, '/Script/UMG.' .. candidate) then kind = candidate; break end
        end
        if not kind then break end
        if not fallback and kind ~= 'SizeBox' then fallback = {parent = parent, child = child, count = #chain} end
        chain[#chain + 1] = {source = parent, slot = child.Slot, kind = kind}
        child = parent
    end
    local count = #chain
    if not target then
        if not fallback then log('Native details layout is not supported: ' .. fullName(source)); return end
        target, child, count = fallback.parent, fallback.child, fallback.count
        state.nativeDetailsRoot = child -- Outside the switcher: restore it when leaving MCU.
    end
    local library = StaticFindObject('/Script/UMG.Default__WidgetBlueprintLibrary')
    local view = library:Create(owner, source:GetClass(), owner:GetOwningPlayer())
    assert(valid(view), 'Could not create native settings details')
    state.detailsView = view
    local content = view
    for index = 1, count do
        local edge = chain[index]
        local container = layoutContainer(owner, edge)
        copyLayoutSlot(edge.slot, container:AddChild(content))
        content = container
    end
    state.detailsRoot = content
    copyLayoutSlot(child.Slot, target:AddChild(content))
    content:SetVisibility(1)
    for _, name in ipairs({'Text_SettingName', 'RichText_Description', 'RichText_DynamicDetails',
        'RichText_WarningDetails', 'RichText_DisabledDetails', 'Box_DetailsExtension'}) do
        local widget = prop(view, name)
        if valid(widget) then widget:SetVisibility(1) end
    end
end

function M.setDetailsActive(state, active)
    if valid(state.detailsRoot) then state.detailsRoot:SetVisibility(active and 4 or 1) end
    local original = state.nativeDetailsRoot
    if not valid(original) then return end
    if active and state.detailsPreviousVisibility == nil then
        state.detailsPreviousVisibility = original:GetVisibility()
        original:SetVisibility(1)
    elseif not active and state.detailsPreviousVisibility ~= nil then
        if original:GetVisibility() == 1 then original:SetVisibility(state.detailsPreviousVisibility) end
        state.detailsPreviousVisibility = nil
    end
end

function M.showDetails(state, definition)
    local view = state.detailsView
    if not valid(view) then return end
    local lines, params = {}, definition and definition.params or {}
    for _, key in ipairs({'min', 'max'}) do
        if params[key] ~= nil then lines[#lines + 1] = state.t(key .. '_value', {value = numbers.text(params[key])}) end
    end
    if definition and definition.default ~= nil then
        local value = definition.default
        local text = type(value) == 'number' and numbers.text(value) or tostring(value)
        if type(value) == 'boolean' then text = state.t(value and 'on' or 'off') end
        if text == '' then text = '""' end
        for _, option in ipairs(params.options or {}) do
            if option.value == value and option.label ~= text then text = option.label .. ' (' .. text .. ')'; break end
        end
        lines[#lines + 1] = state.t('default_value', {value = text})
    end
    local text = definition and definition.description or ''
    for _, item in ipairs({{'RichText_Description', text}, {'RichText_DynamicDetails', table.concat(lines, '\n')}}) do
        local label = prop(view, item[1])
        if setText(label, item[2]) then label:SetVisibility(item[2] ~= '' and 4 or 1) end
    end
end

local function mountPage(owner, state)
    local layout, content = state.layout, state.page
    local copies = {}
    state.switcher = layout.switcher
    -- Clone only invisible layout containers on the list-to-switcher path.
    -- Original widgets, parents, slots, list items and visibility are never changed.
    for _, edge in ipairs(layout.chain) do
        local container = layoutContainer(owner, edge)
        copies[address(edge.source)] = container
        local slot = container:AddChild(content)
        assert(valid(slot), 'Could not build isolated layout container')
        copyLayoutSlot(edge.slot, slot)
        content = container
        state.page = content
    end
    local slot = state.switcher:AddChild(content)
    assert(valid(slot), 'Could not append isolated Mod page')
    copyLayoutSlot(layout.rootSlot, slot)
    state.lastNativePage = state.switcher:GetActiveWidget()
    assert(same(layout.list:GetParent(), layout.parent) and same(layout.list.Slot, layout.slot),
        'Native list parent/slot changed during installation')
    mountDetails(owner, state, copies)
end

local function unmountPage(state)
    M.setDetailsActive(state, false)
    if valid(state.detailsRoot) then state.detailsRoot:RemoveFromParent() end
    state.detailsRoot, state.detailsView, state.nativeDetailsRoot = nil, nil, nil
    if valid(state.page) then state.page:RemoveFromParent() end
end

local function interactivePath(control, row)
    control:SetIsEnabled(true)
    control:SetVisibility(0)
    local parent = control:GetParent()
    for _ = 1, 24 do
        if not valid(parent) then break end
        parent:SetIsEnabled(true)
        parent:SetVisibility(4)
        if isA(parent, '/Script/UMG.WidgetSwitcher') then
            parent:SetActiveWidget(control)
        end
        control, parent = parent, parent:GetParent()
    end
    row:SetIsEnabled(true)
    row:SetVisibility(4)
end

local function replaceInputControl(row, old, replacement)
    local parent, source = old:GetParent(), old.Slot
    assert(valid(parent) and valid(source), 'Native input control has no layout slot')
    local slot
    if isA(parent, '/Script/UMG.ContentWidget') then
        local style = slotStyle(source)
        slot = parent:SetContent(replacement)
        assert(valid(slot), 'Could not replace input')
        applySlotStyle(slot, style)
    else
        slot = parent:AddChild(replacement)
        assert(valid(slot), 'Could not attach independent input')
        copyLayoutSlot(source, slot)
        if isA(source, '/Script/UMG.HorizontalBoxSlot') or isA(source, '/Script/UMG.VerticalBoxSlot') then
            local size = source.Size
            slot:SetSize({Value = size.Value, SizeRule = size.SizeRule})
        end
        old:SetVisibility(1)
    end
    interactivePath(replacement, row)
    return slot
end

local function hideArrows(row)
    for _, field in ipairs({'Button_Decrease', 'Button_Increase', 'DecreaseOverlay', 'IncreaseOverlay'}) do
        local button = prop(row, field)
        -- Native selection animations restore visibility; detached arrows stay absent.
        if valid(button) then button:RemoveFromParent() end
    end
end

local function emphasizeHeading(row, scale)
    row:SetIsEnabled(true)
    row:SetRenderOpacity(1)
    for _, field in ipairs({'Text_SettingName', 'SettingName', 'LocText_SettingName'}) do
        local label = prop(row, field)
        if valid(label) then
            local font = label.Font
            font.Size = math.floor(font.Size * (scale or 1.6) + 0.5)
            label:SetFont(font)
            local color = label.ColorAndOpacity
            color.ColorUseRule = 0 -- UseColor_Specified
            color.SpecifiedColor.R, color.SpecifiedColor.G = 1, 1
            color.SpecifiedColor.B, color.SpecifiedColor.A = 1, 1
            label:SetColorAndOpacity(color)
            if prop(row, 'DefaultColor') ~= nil then row.DefaultColor = color end
            label:SetRenderOpacity(1)
            label:SetIsEnabled(true)
            local parent = label:GetParent()
            while valid(parent) and not same(parent, row) do
                parent:SetRenderOpacity(1)
                parent = parent:GetParent()
            end
            break
        end
    end
end

local hooks, clicks, options, enters, leaves, signals = {}, {}, {}, {}, {}, {}
local inputHooks, activePages = {}, {}

local function unhook(path)
    local hook = hooks[path]
    if not hook then return end
    hook.active = false -- Invalidate before UE4SS queues removal (or throws).
    UnregisterHook(path, hook.pre, hook.post)
    hooks[path] = nil
end

-- Fixed PBZ functions only; native puerts overrides need the post-hook argument.
function M.hook(path, callback)
    local fn = StaticFindObject(path)
    if not valid(fn) then return false end
    if hooks[path] and hooks[path].active and same(hooks[path].fn, fn) then return true end
    if hooks[path] then unhook(path) end
    local hook = {fn = fn, active = true} -- Identity is unique to this registration.
    local function dispatch(context)
        if not hook.active or hooks[path] ~= hook then return end
        local object = unwrap(context)
        if valid(object) then attempt('Native event failed: ' .. path, callback, object) end
    end
    local pre, post
    if fn:GetFunctionFlags() & 0x400 ~= 0 then pre, post = RegisterHook(path, function() end, dispatch)
    else pre, post = RegisterHook(path, dispatch) end
    hook.pre, hook.post = pre, post
    hooks[path] = hook
    return true
end

function M.inputHook(path, callback)
    if not valid(StaticFindObject(path)) then return false end
    inputHooks[path] = callback
    if next(activePages) then return M.hook(path, callback) end
    return true
end

function M.setInputActive(state, active)
    activePages[state] = active and true or nil
    local enabled = next(activePages) ~= nil
    local changed = 0
    for path, callback in pairs(inputHooks) do
        if enabled and (not hooks[path] or not hooks[path].active) then
            if M.hook(path, callback) then changed = changed + 1 end
        elseif not enabled and hooks[path] then
            unhook(path)
            changed = changed + 1
        end
    end
    if changed > 0 then log('Input hooks ' .. (enabled and 'enabled: ' or 'released: ') .. changed) end
end

local function dispatch(entries, object)
    if not valid(object) then return end
    local entry = entries[address(object)]
    if entry and same(entry.object, object) then attempt('UI callback failed', entry.callback) end
end
local function bind(entries, object, callback)
    local key, entry = address(object), {object = object, callback = callback}
    entries[key] = entry
    return function() if entries[key] == entry then entries[key] = nil end end
end
function M.onClick(button, callback) return bind(clicks, button, callback) end
local function inputWrapper(row, control)
    local wrapper = native(row.WidgetTree, 'Overlay', 'InputWrapper')
    local slot = wrapper:AddChildToOverlay(control)
    slot:SetHorizontalAlignment(0)
    slot:SetVerticalAlignment(2)
    return wrapper
end

-- The hidden blueprint child owns text delegate binding and stays alive with the row.
-- Only its dedicated function is hooked; inputHooks handles menu activation/cleanup.
function M.textInputRelay(owner, row, control, callback)
    local package = '/Game/Mods/ModConfigUI/W_TextInputBridge'
    local classPath = package .. '.W_TextInputBridge_C'
    local class = StaticFindObject(classPath)
    if not valid(class) then
        local registry = StaticFindObject('/Script/AssetRegistry.Default__AssetRegistryHelpers')
        class = registry:GetAsset({PackageName = FName(package), AssetName = FName('W_TextInputBridge_C')})
    end
    assert(valid(class), 'MCU text bridge is unavailable; install ModConfigUI.pak/.utoc/.ucas and restart the game')
    local library = StaticFindObject('/Script/UMG.Default__WidgetBlueprintLibrary')
    local receiver = library:Create(owner, class, owner:GetOwningPlayer())
    assert(valid(receiver), 'Could not create MCU text bridge')
    receiver.TickFrequency = 0
    receiver:SetVisibility(1)
    local wrapper = inputWrapper(row, control)
    wrapper:AddChildToOverlay(receiver)
    local path = classPath .. ':MCUTextCommitted'
    local entries = signals[path]
    if not entries then entries = {}; signals[path] = entries end
    assert(M.inputHook(path, function(object) dispatch(entries, object) end), 'MCU text commit function unavailable')
    local unbind = bind(entries, receiver, callback)
    local ok, err = pcall(function() receiver:BindInput(control) end)
    if not ok then unbind(); receiver:RemoveFromParent(); error(err, 0) end
    return wrapper, function()
        unbind()
        if valid(receiver) then
            if valid(control) then receiver:UnbindInput() end
            receiver:RemoveFromParent()
        end
    end
end

-- Slider delegates still use a collapsed native receiver until their migration.
function M.inputRelay(row, control, className)
    local wrapper = inputWrapper(row, control)
    -- UE 5.7 uses UTF-8 soft subpaths; this UE4SS build copies them as UTF-16
    -- when Add/Remove constructs a weak delegate reference. A package-level
    -- receiver has an empty subpath, avoiding that incompatible string copy.
    -- The panel slot holds it for GC; the transient package does not root it.
    local package = StaticFindObject('/Engine/Transient')
    assert(isA(package, '/Script/CoreUObject.Package'), 'Transient package unavailable')
    local receiver = StaticConstructObject(StaticFindObject('/Script/UMG.' .. className),
        package, FName('None'), 0x40) -- Let Unreal assign a unique object name.
    assert(valid(receiver) and same(receiver:GetOuter(), package), 'Invalid input event receiver outer')
    receiver:SetVisibility(1)
    wrapper:AddChildToOverlay(receiver)
    return wrapper, receiver
end
function M.onSignal(control, event, receiver, path, callback)
    local entries = signals[path]
    if not entries then entries = {}; signals[path] = entries end
    assert(M.inputHook(path, function(object) dispatch(entries, object) end), 'Input receiver unavailable: ' .. path)
    local unbind = bind(entries, receiver, callback)
    local name = FName(path:match(':([^:]+)$'))
    local ok, err = pcall(function() control[event]:Add(receiver, name) end)
    if not ok then unbind(); error(err, 0) end
    return function()
        unbind()
        if valid(control) and valid(receiver) then control[event]:Remove(receiver, name) end
    end
end
function M.onHighlight(row, callback, button)
    local source = button or prop(row, 'Background') or row
    if not button then
        -- SelfHitTestInvisible only hits children, leaving the blank part of a row inert.
        row:SetVisibility(0)
        source:SetVisibility(0)
        local path = row:GetClass():GetFullName():match('^[^ ]+ (.+)$')
        M.inputHook(path .. ':OnMouseEnter', function(object) dispatch(enters, object) end)
        M.inputHook(path .. ':OnMouseLeave', function(object) dispatch(leaves, object) end)
    end
    local prefix = button and '/Script/CommonUI.CommonButtonBase:'
        or '/Game/PBZContent/UI/Settings/Editors/W_SettingEntryBackground.W_SettingEntryBackground_C:'
    M.inputHook(prefix .. (button and 'BP_OnHovered' or 'OnMouseEnter'), function(object) dispatch(enters, object) end)
    M.inputHook(prefix .. (button and 'BP_OnUnhovered' or 'OnMouseLeave'), function(object) dispatch(leaves, object) end)
    M.inputHook('/Script/UMG.UserWidget:OnAddedToFocusPath', function(object) dispatch(enters, object) end)
    M.inputHook('/Script/UMG.UserWidget:OnRemovedFromFocusPath', function(object) dispatch(leaves, object) end)
    local bindings = {
        bind(enters, source, function() callback(true) end),
        bind(leaves, source, function() callback(false) end),
    }
    if not same(source, row) then
        bindings[#bindings + 1] = bind(enters, row, function() callback(true) end)
        bindings[#bindings + 1] = bind(leaves, row, function() callback(false) end)
    end
    return function() for _, unbind in ipairs(bindings) do unbind() end end
end

-- PBZ navigation requires BOTH the ID and a visible descriptor, then selects the
-- existing CommonUI button. Append only MCU metadata; never rebuild native tabs.
function M.navigationTab(tabs, include)
    local descriptors, descriptor = tabs.PreregisteredTabInfoArray
    for index = 1, descriptors:GetArrayNum() do
        if fname(descriptors[index].TabId) == TAB_ID then descriptor = descriptors[index]; break end
    end
    if include and not descriptor then
        local index = descriptors:GetArrayNum() + 1
        -- Indexed assignment appends a zero-initialized struct. No brush conversion.
        local button = tabs:GetTabButtonBaseByID(FName(TAB_ID))
        descriptors[index] = {TabId = FName(TAB_ID), bHidden = false,
            TabButtonType = button:GetClass(), TabText = {ValueCache = FText('MOD')}}
        descriptor = descriptors[index]
    end
    -- On disposal leave the small descriptor hidden until its owner is collected.
    if descriptor then descriptor.bHidden = not include end
    local ids, previous, found = {}, {}, false
    local array = tabs.TabButtonIDs
    for index = 1, array:GetArrayNum() do
        local name = fname(array[index])
        local id = FName(name)
        previous[#previous + 1] = id
        if name == TAB_ID then found = true end
        if name ~= TAB_ID or include then ids[#ids + 1] = id end
    end
    if found == include then return end
    if include then ids[#ids + 1] = FName(TAB_ID) end
    -- UE4SS's table assignment replaces FScriptArray. Free its old allocation first.
    array:Empty()
    local ok, err = pcall(function() tabs.TabButtonIDs = ids end)
    if not ok then
        tabs.TabButtonIDs:Empty()
        tabs.TabButtonIDs = previous
        error(err)
    end
    tabs:ResetTabSwitchTracking()
end
function M.onOptionSelected(object, callback)
    assert(M.inputHook('/Game/PBZContent/UI/Settings/Editors/W_SettingBaseRotator.W_SettingBaseRotator_C:BP_OnOptionSelected',
        function(rotator) dispatch(options, rotator) end), 'PBZ rotator event unavailable')
    return bind(options, object, callback)
end
function M.startInputEvents()
    assert(M.inputHook('/Script/CommonUI.CommonButtonBase:HandleButtonClicked',
        function(object) dispatch(clicks, object) end), 'Button click event unavailable')
end

function M.menu(page)
    local function initialize(owner, state)
        local tabs = prop(owner, 'W_OverlayTabList_C')
        assert(valid(tabs), 'Native settings tab list is missing')
        assert(tabs:GetTabCount() > 0, 'Native tab list is not initialized yet')
        state.tabs = tabs
        local originalButtons = {}
        for index = 0, tabs:GetTabCount() - 1 do
            local id = tabs:GetTabIdAtIndex(index)
            originalButtons[#originalButtons + 1] = {id = id, button = tabs:GetTabButtonBaseByID(id)}
            assert(fname(id) ~= TAB_ID,
                'A previous UI instance is still loaded; restart the game')
        end
        -- Validate required dependencies BEFORE creating any UI. No auto-retry that
        -- repeatedly constructs half a page while assets are still loading.
        for _, className in ipairs({'W_SettingsListEntry_Collection_Category_C',
            'W_SettingsListEntry_Discrete_C'}) do
            assert(valid(gameClass(className)), 'Game widget not loaded: ' .. className
                .. '; native widget disappeared after readiness check')
        end
        local buttonClass = gameClass('W_SystemMenu_TabButton_OnlyText_C')
        if not valid(buttonClass) then
            local nativeButton = tabs:GetTabButtonBaseByID(tabs:GetTabIdAtIndex(0))
            assert(valid(nativeButton), 'No native tab button class available')
            buttonClass = nativeButton:GetClass()
        end
        page.buildPage(owner, state)
        local insertionIndex = tabs:GetTabCount()
        -- Append, so CommonUI does not remove/recreate all existing tab buttons.
        -- Avoid nested descriptor/brush conversions; use the base CommonUI API.
        local result = tabs:RegisterTab(FName(TAB_ID), buttonClass, nil, insertionIndex)
        local button = tabs:GetTabButtonBaseByID(FName(TAB_ID))
        assert(result ~= false and valid(button), 'RegisterTab did not create a button')
        for _, original in ipairs(originalButtons) do
            assert(same(original.button, tabs:GetTabButtonBaseByID(original.id)),
                'An original tab button was replaced during append')
        end

        state.registered = true
        M.navigationTab(tabs, true)
        state.button = button
        -- Use the game's existing text style and tab selection visuals. A temporary
        -- MOD label avoids copying any brush structs across the broken conversion.
        local label = prop(button, 'Text')
        assert(setText(label, state.t('mod_tab')), 'Native tab has no supported text label')
        label:SetVisibility(0)
        for _, field in ipairs({'IconImage', 'BloomImage', 'LazyImage_Icon'}) do
            local icon = prop(button, field)
            if valid(icon) then icon:SetVisibility(1) end
        end
        log('Mod settings tab ready: ' .. fullName(owner))
    end

    local function titleWidget(owner)
        local line = prop(owner, 'W_SecondTabLine')
        return valid(line) and prop(line, 'LineText') or nil
    end

    local function refreshTabButton(state)
        -- CommonUI may rebuild tab buttons after RegisterTab returns. Style the
        -- current button, not a reference to a button discarded by that rebuild.
        local button = state.tabs:GetTabButtonBaseByID(FName(TAB_ID))
        if not valid(button) then return end
        M.navigationTab(state.tabs, true)
        if state.styledButton ~= address(button) or state.styledLanguage ~= state.language then
            local label = prop(button, 'Text')
            assert(setText(label, state.t('mod_tab')), 'Native tab has no supported text label')
            label:SetVisibility(0)
            for _, field in ipairs({'IconImage', 'BloomImage', 'LazyImage_Icon'}) do
                local icon = prop(button, field)
                if valid(icon) then icon:SetVisibility(1) end
            end
            state.button = button
            state.styledButton = address(button)
            state.styledLanguage = state.language
        end
        local child = button
        for _ = 1, 8 do
            local slot = prop(child, 'Slot')
            local parent = child:GetParent()
            if not valid(parent) then break end
            if isA(slot, '/Script/UMG.HorizontalBoxSlot') then
                if state.tabSpacingSlot ~= address(slot) then
                    state.tabSpacingSlot = address(slot)
                    state.tabSpacingLeft = slot.Padding.Left + 32
                end
                if slot.Padding.Left ~= state.tabSpacingLeft then
                    local padding = margin(slot.Padding)
                    padding.Left = state.tabSpacingLeft
                    slot:SetPadding(padding)
                end
                break
            end
            child = parent
        end
    end

    local function updateSelection(state, visible)
        local owner, tabs, wasActive = state.owner, state.tabs, state.active
        if not valid(owner) or not valid(tabs) or not valid(state.page) then
            state.active = false
            M.setInputActive(state, false)
            return
        end
        local active = fname(tabs:GetSelectedTabId()) == TAB_ID and visible
        M.setInputActive(state, active)
        if active then
            if not wasActive then
                local title = titleWidget(owner)
                if valid(title) then state.previousTitle = title:GetText() end
                if state.refreshValues then state.refreshValues() end
                refreshTabButton(state)
                state.ownedTitle = state.t('mod_settings')
            end
            if valid(state.switcher) and not same(state.switcher:GetActiveWidget(), state.page) then
                state.switcher:SetActiveWidget(state.page)
            end
            local title = titleWidget(owner)
            if valid(title) and not wasActive then setText(title, state.ownedTitle) end
            state.active = true
            M.setDetailsActive(state, true)
        else
            state.active = false -- Block input callbacks before saving/restoring.
            if wasActive then attempt('Could not save pending settings', page.pollInputs, state, true) end
            page.clearHighlight(state)
            M.setDetailsActive(state, false)
            attempt('Could not restore native page', function()
                if not valid(state.switcher) then return end
                if same(state.switcher:GetActiveWidget(), state.page) and valid(state.lastNativePage) then
                    state.switcher:SetActiveWidget(state.lastNativePage)
                end
                local current = state.switcher:GetActiveWidget()
                if valid(current) and not same(current, state.page) then state.lastNativePage = current end
            end)
            if wasActive then attempt('Could not restore native title', function()
                local title = titleWidget(owner)
                if valid(title) and state.previousTitle and fname(title:GetText()) == state.ownedTitle then
                    title:SetText(state.previousTitle)
                end
            end) end
        end
    end

    local function dispose(state)
        M.setInputActive(state, false)
        state.registered = false
        -- A pre-existing tab that this Lua instance did not create is never removed.
        if state.page ~= nil and valid(state.tabs) then
            attempt('Could not remove MCU tab', function()
                if valid(state.tabs:GetTabButtonBaseByID(FName(TAB_ID))) then
                    state.tabs:RemoveTab(FName(TAB_ID))
                end
                M.navigationTab(state.tabs, false)
            end)
        end
        attempt('Could not detach MCU page', unmountPage, state)
        state.page, state.rows, state.scroll, state.groups, state.refreshValues = nil, nil, nil, nil, nil
        state.layout, state.pendingLayout, state.lastNativePage = nil, nil, nil
        state.tabs, state.button = nil, nil
    end

    local function observeLayout(state)
        state.pendingLayout = listLayout(state.owner)
    end

    local function tryInitialize(state)
        local owner, previous = state.owner, state.pendingLayout
        state.pendingLayout = nil
        if not valid(owner:GetOwningPlayer()) or not valid(prop(owner, 'WidgetTree')) then
            return false, 'owning player/widget tree not ready'
        end
        local tabs = prop(owner, 'W_OverlayTabList_C')
        if not valid(tabs) or tabs:GetTabCount() == 0 then return false, 'native tabs not ready' end
        local layout, reason = listLayout(owner)
        for _, className in ipairs({'W_SettingsListEntry_Collection_Category_C', 'W_SettingsListEntry_Discrete_C'}) do
            if not valid(gameClass(className)) then layout, reason = nil, 'waiting for ' .. className; break end
        end
        if not layout then return false, reason end
        if not previous then return false, 'waiting for a settings layout observation' end
        for _, key in ipairs({'list', 'parent', 'slot', 'switcher', 'nativePage', 'rootSlot'}) do
            if not same(previous[key], layout[key]) then return false, 'native layout changed' end
        end
        state.layout = layout
        state.attempts = 1 -- Never repeat a failed mutation.
        if valid(tabs:GetTabButtonBaseByID(FName(TAB_ID))) then
            log('An existing UI instance is still loaded; restart the game to apply this version.')
            return nil
        end
        local ok, err = pcall(initialize, owner, state)
        if not ok then
            attempt('Could not release MCU inputs', page.clearInputs, state)
            dispose(state)
            state.page, state.registered = nil, false
            log('UI initialization failed (automatic retry disabled): ' .. tostring(err))
            return nil
        end
        return true
    end


    return {observeLayout = observeLayout, tryInitialize = tryInitialize, refreshTabButton = refreshTabButton,
        updateSelection = updateSelection, dispose = dispose}
end

M.valid, M.same, M.address, M.prop, M.isA = valid, same, address, prop, isA
M.fname, M.log, M.attempt = fname, log, attempt
M.native, M.createGameWidget = native, createGameWidget
M.rowTitle, M.inputTextStyleSource = rowTitle, inputTextStyleSource
M.setText = setText
M.replaceInputControl, M.hideArrows, M.addRow = replaceInputControl, hideArrows, addRow
M.emphasizeHeading, M.mountPage = emphasizeHeading, mountPage
return M
