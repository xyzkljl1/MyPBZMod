# ModConfigUI — Developer Integration Guide

[中文](README.md) | [English](README.en.md)

[Nexus Mods](https://www.nexusmods.com/phantombladezero/mods/86)

ModConfigUI (MCU) lets players edit Mod configurations in Phantom Blade Zero's native settings menu. You can choose between the following **three** integration methods.

- [Lua integration: schema configuration](#1-lua-integration-schema-configuration)
- [Blueprint integration: schema configuration](#2-blueprint-integration-schema-configuration)
- [Lightweight integration: simple json](#3-lightweight-integration-simple-json)

In this guide, `Mods/` refers to `PBZ/platform/steam/ue4ss/Mods/`.

## 1. Lua integration: schema configuration

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
| `ColorBox` | Color input box with preview | A string in `#RRGGBB` format |
| `LuaKey` | Key binding | UE4SS numeric key code; `0` means unbound |
| `IntSelect` | Integer selection | Required `options` |
| `FloatSelect` | Floating-point selection | Required `options` |
| `TextSelect` | Text selection | Required `options` |
| `Button` | Action button; does not save a configuration value | Required `onclick` |
| `Separator` | Divider; does not save a configuration value | None |

`ColorBox` provides a color preview. Input accepts lowercase and uppercase letters, but values are saved in uppercase.

`LuaKey` captures keyboard or mouse buttons, but does not support key combinations, gamepads, or the mouse wheel. Its configuration value is a UE4SS numeric key code that can be passed directly as the first argument to UE4SS `RegisterKeyBind`, without conversion. It has the same meaning as Lua constants such as `Key.F8`. MCU only updates the configuration value; **it does not rebind the hotkey for you**. (For a Blueprint-compatible `FKey` value, see `BPKey` in the Blueprint schema section.)

`options` is a nonempty array. Each entry requires `value` and optionally provides `label`, for example `{{value = 1, label = "Low"}, {value = 2, label = "High"}}`. The saved value is `value`, not the index or display text.

`step` applies only to sliders and must be positive. Steps start at `min`. Integers must be within Lua's representable integer range; floating-point numbers must be finite.

Text length is counted in UTF-8 characters. `pattern` is a **Lua pattern**, not a regular expression; add `^` and `$` when the entire string must match.

Automatic `default` inference: ColorBox uses `#FFFFFF`, LuaKey uses `0`, booleans use `false`, text uses an empty string, selections use the first option, sliders use the lower bound, and numeric inputs are inferred from `0` subject to the range. If the inferred value does not satisfy the constraints, initialization fails. For example, text with `minLength = 1` needs a nonempty default value.

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
        {key = "Color", type = "ColorBox", label = "Color", default = "#FF8800", onchange = onchange},
        {key = "Hotkey", type = "LuaKey", label = "Hotkey", default = Key.F8, onchange = onchange},
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
- Lua Mods can still initialize their configuration if only the MCU UI is disabled while the shared module remains installed; Blueprint integration requires MCU to be enabled. Do not reference private MCU UI scripts; use only the shared module's public interfaces.
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

## 2. Blueprint integration: schema configuration

Blueprint Mods also use schema configuration. They require MCU to be enabled and a working Blueprint Mod loader, but do not need Lua code or their own JSON file handling. Complete editable example: [MCUExample5](BPMod/MCUExample5/) (UE 5.7.4).

### What you need to do

1. Copy this repository's `BPMod/ModConfigUI/Content/Mods/ModConfigUI/Blueprint/` folder to `Content/Mods/ModConfigUI/Blueprint/` in your UE project. It contains the definitions of `BP_MCUConfigComponent`, `ST_MCUFieldV1`, and `ST_MCUOptionV1`. **These are build dependencies and must not be included in your package.**
2. Add a `BP_MCUConfigComponent` component to your Mod Actor under `/Game/Mods/<ModName>/`. `Fields` uses `ST_MCUFieldV1`, and options use `ST_MCUOptionV1`.
3. Define your own configuration struct containing all the settings you need. Create a `Config` variable of that type in your Mod Actor and assign its default values as the default configuration.
4. Edit the component's `Fields` array to specify control parameters. These determine which controls are created for your settings. Each `Key` must correspond to a member of `Config`.
5. Read configuration values directly from the member pins of `Config` in your Blueprint logic.

### What MCU does

During initialization, MCU automatically loads the configuration file into `Config`. If the file does not exist, it creates one using the defaults in `Config`.
When the user changes settings, MCU updates the `Config` variable and sends the corresponding notifications.

### Code example

[Blueprint example](BPMod/MCUExample5)

### Defining the Blueprint schema in the editor

Open your Mod Actor and show the component panel through **Window → Components**. Select the added `BP_MCUConfigComponent` (named `MCUConfig` in Example5), then search for **Fields** in the Details panel on the right. Do not select the component reference under "My Blueprint → Variables", or edit the default Fields on the shared SDK component itself.

For example, define an Integer member named `IntOptionExample` in your configuration struct, set it to `12` under the Actor's **Class Defaults → Config**, and add the following entry to the component's `Fields`:

```text
Key: IntOptionExample
Type: IntBox
Label: Integer option
Description: An example integer setting.
UseMin: true
Min: 0
UseMax: true
Max: 100
```

`Fields` is the ordered Blueprint schema definition stored on the component. MCU reads it automatically and uses the Actor's `Config` class defaults as the default configuration.

### Supported types and parameters

| Type | Control | Config member type | Parameters |
| --- | --- | --- | --- |
| `BoolToggle` | Boolean two-option selector | Boolean | None |
| `IntBox` / `FloatBox` | Integer / floating-point input box | Integer (32-bit) / Double | Optional bounds; Step is not used |
| `IntSlider` / `FloatSlider` | Integer / floating-point slider | Integer (32-bit) / Double | Enable both bounds and set a positive Step |
| `TextBox` | Text input box | String | Optional length and Pattern |
| `ColorBox` | Color input box with preview | String | Fixed `#RRGGBB` format, saved in uppercase |
| `BPKey` | Single-key binding | Key (FKey) | `None` means unbound; no additional parameters |
| `IntSelect` / `FloatSelect` / `TextSelect` | Option selector | Integer (32-bit) / Double / String | Nonempty Options; saves the option value |
| `Button` | Action button | No member needed | Handle in OnButtonClicked |
| `Separator` | Section heading | No member needed | None |

| Fields parameter | Purpose |
| --- | --- |
| `Key`, `Type`, `Label`, `Description` | Unique member name, control type from the table above, display name, and description on the right; an empty Label falls back to Key |
| `UseMin` / `Min`, `UseMax` / `Max` | Enable numeric bounds; both must be enabled for either Slider type |
| `Step` | Slider step size; not used by Box controls |
| `MinLength`, `MaxLength`, `Pattern` | TextBox length and Lua pattern; `-1` means no length limit, and an empty pattern means no pattern constraint |
| `Options` | Ordered Select options; each entry contains `Label` and the corresponding `IntValue`, `FloatValue`, or `TextValue` |

Apart from Key, nested structs, arrays, and similar configuration values are not supported. Defaults come from `Config` and must satisfy the corresponding constraints. Integers must fit in 32 bits and floating-point values must be finite; slider steps start at Min. TextBox length is counted in UTF-8 characters. Pattern is a Lua pattern, not a regular expression; use `^` and `$` to match the entire string.

Clicking `BPKey` captures a keyboard or mouse button; key combinations, gamepads, and the mouse wheel are not supported. Blueprints can read the FKey directly from Config and pass it to inputs such as `Is Input Key Down` or `Was Input Key Just Pressed`, without conversion. **MCU only updates the setting in `Config`; it does not rebind the hotkey for you.**

### Interfaces and callbacks

The component initializes and unregisters automatically; no manual calls are needed. Initialization failures are written to the UE4SS log.

Add the following ordinary Blueprint functions to the Actor:

| Function | When it is called |
| --- | --- |
| `OnConfigReady()` | Called once after successful initialization and loading the complete `Config` |
| `OnConfigChanged(Key: String)` | After the complete `Config` is updated, called once per setting that actually changed, in field declaration order; Key is the field name, and the new value can be read directly from the corresponding typed member of `Config` |
| `OnButtonClicked(Key: String)` | Called when a Button is clicked; Key is the button field name; does not save configuration |

Matching names are called automatically, without manual binding. `Config` updates automatically; you **do not need** to update the configuration yourself in these functions.

Initialization logic that depends on configuration values should run from `OnConfigReady`, not BeginPlay.

Initialization, invalid values, failed saves, and unchanged values do not trigger `OnConfigChanged`. Resetting all defaults also notifies only the fields that actually changed, one by one, on the game thread.

### Configuration saving, defaults, and language packs

The configuration file is `Mods/<ModName>/<ModName>.schemaconfig.json`. It contains configuration key-value pairs, not Fields; ModName is obtained automatically from the path. If a Mod with the same name has registered a schema, MCU ignores its Simple JSON configuration file.

Optional language packs go in `Mods/<ModName>/<ModName>.lang.<language-code>.json`. They follow the game language and override Fields labels, descriptions, and option labels; missing translations fall back to the original text in Fields. See [UI language packs](#ui-language-packs) for the format and language codes, and the [Example5 Chinese pack](MCUExample5/platform/steam/ue4ss/Mods/MCUExample5/MCUExample5.lang.zh-Hans.json) for an example.

Changes your own logic makes to `Config` are not saved or propagated back to MCU and will be overwritten on the next synchronization. Do not bundle runtime-generated configuration files.

## 3. Lightweight integration: simple json

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
