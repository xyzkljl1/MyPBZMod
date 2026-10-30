-- Single keyboard/mouse buttons supported by both UE and UE4SS (Windows VK codes).
-- Persist these codes for LuaKey; BPKey persists the UE name instead.
local names = {
    [0] = 'None', [1] = 'LeftMouseButton', [2] = 'RightMouseButton', [4] = 'MiddleMouseButton',
    [5] = 'ThumbMouseButton', [6] = 'ThumbMouseButton2', [8] = 'BackSpace', [9] = 'Tab',
    [13] = 'Enter', [19] = 'Pause', [20] = 'CapsLock', [27] = 'Escape', [32] = 'SpaceBar',
    [33] = 'PageUp', [34] = 'PageDown', [35] = 'End', [36] = 'Home', [37] = 'Left',
    [38] = 'Up', [39] = 'Right', [40] = 'Down', [44] = 'PrintScreen', [45] = 'Insert', [46] = 'Delete',
    [91] = 'LeftCommand', [92] = 'RightCommand', [106] = 'Multiply', [107] = 'Add',
    [109] = 'Subtract', [110] = 'Decimal', [111] = 'Divide', [144] = 'NumLock', [145] = 'ScrollLock',
    [160] = 'LeftShift', [161] = 'RightShift', [162] = 'LeftControl', [163] = 'RightControl',
    [164] = 'LeftAlt', [165] = 'RightAlt', [186] = 'Semicolon', [187] = 'Equals',
    [188] = 'Comma', [189] = 'Hyphen', [190] = 'Period', [191] = 'Slash', [192] = 'Tilde',
    [219] = 'LeftBracket', [220] = 'Backslash', [221] = 'RightBracket', [222] = 'Apostrophe',
}
local digits = {'Zero', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine'}
for i = 0, 9 do names[48 + i], names[96 + i] = digits[i + 1], 'NumPad' .. digits[i + 1] end
for i = 65, 90 do names[i] = string.char(i) end
for i = 1, 12 do names[111 + i] = 'F' .. i end
local codes = {}
for code, name in pairs(names) do codes[name] = code end
return {names = names, codes = codes}
