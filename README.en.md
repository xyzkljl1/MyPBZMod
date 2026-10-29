# ModConfigUI — Developer Integration Guide

[中文](README.md) | [English](README.en.md)

[Nexus Mods](https://www.nexusmods.com/phantombladezero/mods/86)

ModConfigUI (MCU) lets players edit Mod configurations in Phantom Blade Zero's native settings menu. You can choose between the following **two** integration methods.

- [Full integration: schema configuration (recommended)](#1-full-integration-schema-configuration-recommended)
- [Lightweight integration: simple json](#2-lightweight-integration-simple-json)

In this guide, `Mods/` refers to `PBZ/platform/steam/ue4ss/Mods/`.

## 1. Full integration: schema configuration (recommended)

### What you need to do

1. List MCU as an installation dependency and import the shared module with `require("mcu_core")`.
2. Define a schema in Lua, specifying configuration fields, types, control parameters, callbacks, and so on.
3. Call `InitFromFile`, **retain the config object it returns**, and read configuration values directly from it in your Mod's code.

**Do not bundle a configuration file with your Mod or implement file reading and writing yourself.**

### What MCU does

MCU generates the UI from your schema. When the user changes a setting, MCU saves the configuration to the file, updates the config object in Lua (controlled by the update option), and calls any registered onchange callbacks (registration is optional).

### Minimal code example

[Jump to the complete code example](#complete-code-example)

In your `Mods/<ModName>/Scripts/main.lua`:

```lua
local config = require("mcu_core").InitFromFile({
    fields = {{key = "Enabled", type = "BoolToggle"}},
})
print(config.Enabled)
```

(Unless you explicitly pass `updateInPlace = false`) when the user changes a setting in the UI, **both the local file and the config object retained in Lua update automatically**. Your Mod's code can continue using `config.Enabled`.

MCU's updates to the config object are one-way. If you modify the config object in your Mod, those changes **will not** be reflected in the configuration file or UI, and will be overwritten on the next configuration change.

### MCU_CORE interfaces and callbacks

Import it with `local mcu = require("mcu_core")`. (`list` and `request` are internal interfaces; do not use them.)

#### 1. `InitFromFile(schema)`

```lua
local config, err = mcu.InitFromFile(schema)
```

Generates the UI from the schema you provide, reads the configuration file at `Mods/<ModName>/<ModName>.schemaconfig.json`, and returns a config object. If the file does not exist, it creates the configuration file using the default values.

**Call this only once.**

The `schema` argument is a Lua table with the following structure:

```lua
local schema = {
    updateInPlace = true, -- Optional; defaults to true. The name is case-sensitive.
    fields = { -- Required: an ordered array, with each entry representing a configuration item.
        {
            key = "Count",
            type = "IntBox",
            label = "Count",
            description = "The number to display",
            default = 12,
            min = 0, max = 100,
            onchange = function(newValue, oldValue, fullConfig)
                print(newValue)
            end,
        },
        {
            key = "PrintConfig",
            type = "Button",
            label = "Print count",
            onclick = function(fullConfig)
                print(fullConfig.Count)
            end,
        },
    },
}
```

For the `fields` format, see the `Supported types` section below. **Note that fields is an array, not an object.**

**Parameters:**

- `schema.fields`: Required. An ordered array of fields; see the format below.
- `schema.updateInPlace`: Optional; defaults to `true`. When true, MCU automatically updates the config object returned by InitFromFile. When false, it does not; you need to implement `onchange` yourself to update the configuration in memory (the configuration file is still saved automatically as usual).
- The Mod name is obtained automatically from the calling script's path: folder name = Mod name.
- On success, returns `config`, containing only configuration values, such as `config.Enabled` / `config.interval`; on failure, returns `nil, err`.
- Initialization does not trigger `onchange`.

#### 2. `onchange(newValue, oldValue, fullConfig)` callback

Set `onchange` (all lowercase) on an individual field in `schema.fields`. See the example below.

```lua
{
    key = "Enabled",
    type = "BoolToggle",
    default = true,
    onchange = function(newValue, oldValue, fullConfig)
        -- DoSomething
    end,
}
```

**Parameters:**

- `newValue`: The field's value after the change.
- `oldValue`: The field's value before the change.
- `fullConfig`: A complete configuration snapshot after this change, containing all value fields, without the schema or callback functions.

**Trigger rules:**

- After an edit or a reset to defaults in MCU is successfully saved, only fields whose values actually changed trigger the callback. Unchanged values, failed saves, initialization, and `ForceSaveConfig` do not trigger it.
- When a change affects multiple fields, their callbacks are called in the declaration order of `fields`.
- Callbacks are queued on the game thread in the owning Mod's Lua environment. No return value is needed. The configuration is saved before the callback; do not call `ForceSaveConfig` here.
- Callback errors are written to the UE4SS log and do not undo the saved configuration.

With `updateInPlace = true`, the config returned by InitFromFile updates automatically. Use onchange only when you need additional actions in response to configuration changes.

With `updateInPlace = false`, only the configuration file updates automatically; the configuration in your Mod's memory does not change. You need to accept the new configuration yourself, for example by assigning `config = fullConfig` in the callback.

#### 3. `onclick(fullConfig)` callback

Set `onclick` (all lowercase) on a Button configuration item in `schema.fields`. Button must provide this callback and cannot set `onchange`.

Button is a virtual configuration item: it does not create an actual saved configuration value and only provides an onclick action.

```lua
{
    key = "PrintConfig",
    type = "Button",
    label = "Print configuration",
    onclick = function(fullConfig)
        for key, value in pairs(fullConfig) do
            print(key .. " = " .. tostring(value))
        end
    end,
}
```

- `fullConfig`: A complete configuration snapshot at the time the button action executes, containing all value fields, without the schema or callback functions.

- Runs on the game thread in the owning Mod's Lua environment when the player clicks the button. Initialization, changes to other settings, and resetting defaults do not trigger it.
- No return value is needed. The button itself does not create a configuration key-value pair, automatically save configuration, or trigger `onchange`.
- Modifying `fullConfig` does not write changes back to the configuration file.

#### 4. `ForceSaveConfig(config)`

```lua
local saved, err = mcu.ForceSaveConfig(config)
```

**Note: you do not need this function in 99% of cases.**

It is not intended for saving configuration changes made through the UI; those are all saved automatically.
This function lets you save changes made proactively by your Mod instead of through user actions.

- `config` must be the latest API configuration object for the current registration, containing all value fields. Do not pass an ordinary copy, unknown fields, or an outdated object.
- On success, returns the saved configuration object; receive it with `config = saved`. On failure, returns `nil, err`.
- Does not trigger `onchange` and cannot be called from within `onchange`.

### Supported types

#### fields format

- **Required: `key`, `type`.** `key` is the configuration key name; it must be a nonempty string unique within the current schema. `type` specifies the control type.
- **Optional: `label`, `description`, `default`, `onchange`.** `label` falls back to `key` when omitted. `description` provides explanatory text. `default` is the default value and is inferred automatically when omitted. `onchange` is the callback.
- **Control parameters: `min`, `max`, etc.** (See the table below.)

`fields` is an ordered array. Controls appear in declaration order. Default values only need to be defined here once.

| type | Control / value type | Field parameters |
| --- | --- | --- |
| `BoolToggle` | Boolean two-option selector | None |
| `IntBox` | Integer input box | Optional `min/max` |
| `FloatBox` | Floating-point input box | Optional `min/max` |
| `IntSlider` | Integer slider | Required `min/max/step` |
| `FloatSlider` | Floating-point slider | Required `min/max/step` |
| `TextBox` | Text input box | Optional `minLength/maxLength/pattern` |
| `IntSelect` | Integer selection | Required `options` |
| `FloatSelect` | Floating-point selection | Required `options` |
| `TextSelect` | Text selection | Required `options` |
| `Button` | Action button; does not save a configuration value | Required `onclick` |
| `Separator` | Divider; does not save a configuration value | None |

`options` is a nonempty array. Each entry requires `value` and optionally provides `label`, for example `{{value = 1, label = "Low"}, {value = 2, label = "High"}}`. The saved value is `value`, not the index or display text.

`step` applies only to sliders and must be positive. Steps start at `min`. Integers must be within Lua's representable integer range; floating-point numbers must be finite.

Text length is counted in UTF-8 characters. `pattern` is a **Lua pattern**, not a regular expression; add `^` and `$` when the entire string must match.

Automatic `default` inference: booleans use `false`, text uses an empty string, selections use the first option, sliders use the lower bound, and numeric inputs are inferred from `0` subject to the range. If the inferred value does not satisfy the constraints, initialization fails. For example, text with `minLength = 1` needs a nonempty default value.

### Complete code example

Source: [MCUExample2](MCUExample2/platform/steam/ue4ss/Mods/MCUExample2/Scripts/main.lua).

```lua
local mcu = require("mcu_core")

local function printConfig(config)
    for key, value in pairs(config) do
        print("[MyMod] " .. key .. " = " .. tostring(value) .. "\n")
    end
end

local function onchange(newValue, oldValue, fullConfig)
    print("[MyMod] Changed: " .. tostring(oldValue) .. " -> " .. tostring(newValue) .. "\n")
    printConfig(fullConfig)
end

local schema = {
    updateInPlace = true,
    fields = {
        {key = "GeneralSection", type = "Separator", label = "General settings"},
        {key = "Enabled", type = "BoolToggle", label = "Boolean toggle", default = true, onchange = onchange},
        {key = "IntegerValue", type = "IntBox", label = "Integer input", default = 12, onchange = onchange},
        {key = "FloatValue", type = "FloatBox", label = "Floating-point input", default = 1.25, onchange = onchange},
        {
            key = "IntegerSlider", type = "IntSlider", label = "Integer slider", default = 10,
            min = 0, max = 100, step = 5, onchange = onchange,
        },
        {
            key = "FloatSlider", type = "FloatSlider", label = "Floating-point slider", default = 0.5,
            min = 0, max = 1, step = 0.1, onchange = onchange,
        },
        {
            key = "TextValue", type = "TextBox", label = "Text input", default = "Hello MCU",
            maxLength = 40, onchange = onchange,
        },
        {
            key = "IntegerChoice", type = "IntSelect", label = "Integer selection", default = 2,
            options = {{value = 1, label = "Low"}, {value = 2, label = "High"}},
            onchange = onchange,
        },
        {
            key = "FloatChoice", type = "FloatSelect", label = "Floating-point selection", default = 1.0,
            options = {{value = 0.5, label = "Half"}, {value = 1.0, label = "One"}},
            onchange = onchange,
        },
        {
            key = "TextChoice", type = "TextSelect", label = "Text selection", default = "normal",
            options = {{value = "compact", label = "Compact"}, {value = "normal", label = "Normal"}},
            onchange = onchange,
        },
        {key = "PrintConfig", type = "Button", label = "Print configuration", onclick = printConfig},
    },
}

local config, err = mcu.InitFromFile(schema)
if not config then
    print("[MyMod] " .. tostring(err) .. "\n")
    return
end

printConfig(config)
```

### Notes

- For this integration method, the reset-to-defaults button restores the defaults from the schema and applies them immediately.
- When the schema changes, an old value is retained if it satisfies the range for the same configuration item in the new schema. Otherwise, it is discarded and the default value is used.
- If only the MCU UI is disabled while the shared module remains installed, the Mod can still initialize its configuration. Do not reference private MCU UI scripts; use only the shared module's public interfaces.
- Do not distribute duplicate copies of the shared module with your Mod, or distribute the runtime-generated `.schemaconfig.json`.
- MCU's own text follows the game language. Mod configuration text defaults to the schema and can be translated using the optional packs below.
- If the same Mod registers a schema and provides the simple JSON described below, only the schema takes effect. Folder names are matched case-insensitively.

### UI language packs

Place a UTF-8 JSON file at `Mods/<ModName>/<ModName>.lang.<language-code>.json`, for example `MyMod.lang.en.json`. It can be bundled with the Mod or installed separately; no Mod code changes are required.

```json
{
  "fields": {
    "Enabled": { "label": "Enabled", "description": "Enable this feature." },
    "TextChoice": {
      "label": "Display Mode",
      "options": [
        { "value": "compact", "label": "Compact" },
        { "value": "normal", "label": "Normal" }
      ]
    }
  }
}
```

**Unlike schema fields, a language pack's `fields` is an unordered object, not an array.**

- Follows the game language. Available codes: `en` (English), `zh-Hans` (Simplified Chinese), `zh-Hant` (Traditional Chinese), `ja` (Japanese), `ko` (Korean), `fr` (French), `de` (German), `es` (Spanish), `ru` (Russian), `pt-BR` (Brazilian Portuguese), `it` (Italian).
- Refreshes when re-entering Mod Settings.
- When a matching language pack exists, MCU looks up entries in its `fields` by `key` (or by `value` for options) and uses their `label` and `description` to override the original schema text.
- Packs only change UI text, not configuration, UI generation, or storage logic. Simple integration does not currently support packs.
- See the [MCUExample2 English pack](MCUExample2/platform/steam/ue4ss/Mods/MCUExample2/MCUExample2.lang.en.json); its default Chinese text remains in the schema.

## 2. Lightweight integration: simple json

### What you need to do

1. When the configuration file does not exist, your Mod creates `Mods/<ModName>/<ModName>.config.json`. `ModName` must match the Mod's installation folder name.
2. Your Mod reads the configuration file itself.
3. Register `MCUChangeEvent_<ModName>` and reload the configuration file when the event is received.

Implement creation from defaults and reading. Do not implement configuration saving, to avoid overwriting configuration saved by MCU and vice versa.

### What MCU does

MCU reads JSON configuration files named according to the requirements, generates their UI, and saves the user's changes back to the configuration file.

MCU does not directly update your local variables. Register the optional notification below to reload your configuration after MCU saves it. Without registration, your Mod decides when to read the file again.

Your Mod can run without depending on MCU, but you need a JSON library to read JSON. You can use your own JSON library or MCU's shared JSON library.

### Configuration example

Prefer having your code automatically generate the configuration file from defaults when it does not exist. Do not bundle the configuration file with your Mod, as this would overwrite the user's local configuration.

```json
{
  "ShootDuration": 0.3,
  "DamageColor": "#FFFFFF",
  "Enabled": true,
  "RectWidth": 150
}
```

### Code example

See the [simple integration example](MCUExample/platform/steam/ue4ss/Mods/MCUExample/Scripts/main.lua).

```lua
local defaults = {
    BooleanValue = true,
    NumberValue = 12.5,
    TextValue = "Hello MCU",
}

local json = require("json")
local configPath = "../../../platform/steam/ue4ss/Mods/MyMod/MyMod.config.json"
local config
local function loadConfig()
    -- When adding settings, initialize config from defaults and overlay file values per key instead of replacing the table.
    config = json.load(configPath)
    if not config then
        config = defaults
        json.dump(config, configPath)
    end

    for key, value in pairs(config) do
        print("[MyMod] " .. key .. " = " .. tostring(value) .. "\n")
    end
end
loadConfig()
```

### ChangeEvent

Register the configuration change event:

```lua
RegisterConsoleCommandGlobalHandler("MCUChangeEvent_MyMod", function()
    loadConfig()
    return true
end)
```

- You can omit this event registration, but configuration changes will then take effect the next time the Mod restarts, unless you reload the configuration through another mechanism.
- The command is `MCUChangeEvent_` followed by the Mod folder name, for example `MCUChangeEvent_MyMod`. Keep letters, digits and underscores; encode every other byte as `%xx`. For example, `My-Mod` uses `MCUChangeEvent_My%2dMod`; a space is `%20` and a dot is `%2e`. Do not replace punctuation with underscores, as that can cause name collisions.
- The event only notifies you that the configuration has changed; it carries no payload.
- Each successful save that changes values sends one notification, including batch edits. Unchanged values, failed saves and simply opening the page do not notify.
- Resetting defaults sends the same notification after deleting the file successfully. The handler should recreate defaults when the file is missing. After the command call returns, MCU checks the file: if recreated, it refreshes the configuration; if still missing, it prompts the user to reload the Mod or restart the game. If the Mod recreates the file later, re-enter Mod Settings to refresh it.
- Notification failure does not undo a saved or deleted file, and notifications are not automatically retried. Your Mod can still load its configuration when MCU is not running.

### Supported types

| JSON value type | UI control |
| --- | --- |
| Boolean | On / Off selector |
| Number | Numeric input box |
| String | Text input box |

Unsupported types do not generate controls. When configuration is edited, unsupported entries are written back with their values unchanged; indentation and field order are not guaranteed to remain unchanged.

### Notes

- For this integration method, resetting defaults deletes the entire configuration file (including unsupported fields). Mods registered for notifications can recreate defaults immediately; otherwise, the Mod recreates them the next time it loads its configuration.
- `json.load(path)` returns `nil` if the file cannot be opened and throws an error if parsing fails. `json.dump(value, path)` throws an error if writing fails.
- The current shared JSON module is based on David Heiko Kolf's dkjson 2.11 (MIT license) and provides `load` / `dump` file helper interfaces.
