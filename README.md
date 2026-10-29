# ModConfigUI — 开发者接入指南

[中文](README.md) | [English](README.en.md)

ModConfigUI（MCU）让玩家在《影之刃零》的原生设置菜单中修改 Mod 配置。你可以选择以下**两种**接入方式。

下文的 `Mods/` 指 `PBZ/platform/steam/ue4ss/Mods/`。

## 一，完全接入： schema 配置（推荐）

### 你需要做什么

1. 将 MCU 列为安装依赖，并通过 `require("mcu_core")` 导入共享模块。
2. 在 Lua 中定义一个 schema，指定配置字段、类型、空间参数、回调等。
3. 调用 `InitFromFile`，**保存它返回的config对象** ，业务代码直接读取其中的配置项。

**不要在MOD里附带配置文件或自己实现文件读写**

### MCU会做什么

根据你的schema生成对应ui，用户修改配置后保存到配置文件，并更新lua内的config对象(通过开关控制)，并调用注册的onchange事件(可选注册回调)。

### 最小代码示例

在你的 `Mods/<ModName>/Scripts/main.lua` 中：

```lua
local config = require("mcu_core").InitFromFile({
    fields = {{key = "Enabled", type = "BoolToggle"}},
})
print(config.Enabled)
```
(除非显示传入UpdateInPlace = false) 用户在UI上变更配置后，**本地文件和在lua中保存的config对象会自动更新**。你的业务代码继续使用 `config.Enabled` 即可。

MCU对config对象的修改是单向的，如果你在mod里修改了config对象，修改**不会**反映到配置文件或UI上，而是在下一次配置变动时被覆盖。

### MCU_CORE的接口和回调

通过 `local mcu = require("mcu_core")` 导入。(`list` 和 `request` 是内部接口不要使用)

#### 1.`InitFromFile(schema)`

```lua
local config, err = mcu.InitFromFile(schema)
```
根据你传入的scheam生成UI，读取位于`Mods/<ModName>/<ModName>.schemaconfig.json`的配置文件并生成config对象返回，如果不存在则使用默认值创建配置文件。
应当只调用一次。

入参 `schema` 是一个 Lua table，结构如下：

```lua
local schema = {
    updateInPlace = true, -- 可选，省略时为 true，名称区分大小写。
    fields = { -- 必填，有序数组，每个表示一个配置项
        {
            key = "Count",
            type = "IntBox",
            label = "数量",
            description = "要显示的数量",
            default = 12,
            min = 0, max = 100,
            onchange = function(newValue, oldValue, fullConfig)
                print(newValue)
            end,
        },
        {
            key = "PrintConfig",
            type = "Button",
            label = "打印数量",
            onclick = function(fullConfig)
                print(fullConfig.Count)
            end,
        },
    },
}
```

`fields` 格式参考下方`支持的类型`章节，**注意fields是数组而非对象**

参数:
- `schema.fields`：必填，有序字段数组，具体格式见下文。
- `schema.updateInPlace`：可选，默认为 `true`。 为true时， MCU会自动更新InitFromFile返回的config对象；为false时则不会，此时你需要自己实现 `OnChange`以更新内存里的配置项 (配置文件仍然会照常自动保存)。
- Mod 名称从调用脚本所在的路径自动取得，即文件夹名=Mod名。
- 成功返回只包含配置值的 `config`，例如 `config.Enabled`/ `config.interval`；失败返回 `nil, err`。
- 初始化不触发 `onchange`。


#### 2.`onchange(newValue, oldValue, fullConfig)` 回调

在 `schema.fields` 的具体字段中设置 `onchange`（全小写），具体写法见下方章节。

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

参数：

- `newValue`：当前字段修改后的值。
- `oldValue`：当前字段修改前的值。
- `fullConfig`：本次修改后的完整配置快照，包含所有值字段，不包含 schema 或回调函数。

触发规则：

- MCU 中的修改或恢复默认值成功保存后，仅对实际变化的字段触发；值没有变化、保存失败、初始化和 `ForceSaveConfig` 都不会触发。
- 一次修改涉及多个字段时，按 `fields` 的声明顺序分别调用对应回调。
- 回调在所属 Mod 的 Lua 环境、游戏线程中排队执行，不需要返回值。配置已在回调前保存，不要在这里调用 `ForceSaveConfig`。
- 回调报错会写入 UE4SS 日志，不会撤销已经保存的配置。

`updateInPlace = true` 时，InitFromFile返回的config会自动更新，仅需在onchange里执行配置变动所需的额外操作时即可。

`updateInPlace = false` 时，仅配置文件会自动更新，你的Mod内存里的配置项不会改变，你需要自行接收新配置，例如在回调中执行 `config = fullConfig`。


#### 3.`onclick(fullConfig)` 回调

在 `schema.fields` 的 Button 类型配置中设置 `onclick`（全小写）。Button 必须提供此回调，不能设置`onchange`。
Button是一个虚拟配置项，不产生实际会保存的配置，只提供onclick操作，

```lua
{
    key = "PrintConfig",
    type = "Button",
    label = "打印配置",
    onclick = function(fullConfig)
        for key, value in pairs(fullConfig) do
            print(key .. " = " .. tostring(value))
        end
    end,
}
```

- - `fullConfig`：按钮操作执行时的完整配置快照，包含所有值字段，不包含 schema 或回调函数。


- 玩家点击该按钮时，在所属 Mod 的 Lua 环境、游戏线程中执行；初始化、修改其他配置和恢复默认值不会触发。
- 不需要返回值。按钮自身不产生配置键值，也不会自动保存配置或触发 `onchange`。
- 修改 `fullConfig` 不会写回配置文件。

#### 4.`ForceSaveConfig(config)`

```lua
local saved, err = mcu.ForceSaveConfig(config)
```
**注意99%的情况下你不需使用此函数**
它并非用于保存变更后的配置，UI产生的配置变动都是自动保存的。
这个函数用于让你保存一些不通过用户操作而是通过mod主动修改的东西。

- `config` 必须是当前注册对应的最新 API 配置对象，包含所有值字段，不能传普通副本、未知字段或过期对象。
- 成功返回保存后的配置对象，使用 `config = saved` 接收；失败返回 `nil, err`。
- 不触发 `onchange`，也不能在 `onchange` 内调用。



### 支持的类型

#### fields 格式

- **必填：`key`、`type`。** `key` 是配置键名，必须为非空字符串，在当前 schema 内唯一；`type` 指定控件类型。
- **可选：`label`、`description`、`default`、`onchange`。** `label` 省略时使用 `key`；`description` 为说明；`default` 为默认值，不填时会自动推断；`onchange` 为回调。
- **控件参数: `min`、`max`等** (见下表)

`fields` 是有序数组，控件按声明顺序展示。默认值只需在这里定义一次。

####

| type | 控件 / 值类型 | 字段参数 |
| --- | --- | --- |
| `BoolToggle` | 布尔二选一 | 无 |
| `IntBox` | 整数输入框 | 可选 `min/max` |
| `FloatBox` | 浮点数输入框 | 可选 `min/max` |
| `IntSlider` | 整数滑动条 | 必填 `min/max/step` |
| `FloatSlider` | 浮点数滑动条 | 必填 `min/max/step` |
| `TextBox` | 文本输入框 | 可选 `minLength/maxLength/pattern` |
| `IntSelect` | 整数选项 | 必填 `options` |
| `FloatSelect` | 浮点数选项 | 必填 `options` |
| `TextSelect` | 文本选项 | 必填 `options` |
| `Button` | 操作按钮，不保存配置值 | 必填`onclick` |
| `Separator` | 分割线，不保存配置值 | 无 |

其中`options` 是非空数组，每项的 `value` 必填、`label` 可选，例如 `{{value = 1, label = "Low"}, {value = 2, label = "High"}}`。保存的是 `value`，不是下标或显示文字。

`step` 仅用于滑动条，必须为正，步长起点为 `min`。整数必须在 Lua 整数可表示的范围内，浮点数必须为有限数值。

文本长度按 UTF-8 字符计算。`pattern` 是 **Lua pattern**，不是正则表达式；需要整串匹配时添加 `^` 和 `$`。

`default`自动推导：布尔为 `false`，文本为空，选项取第一项，滑动条取下限，数字输入以 `0` 为基础结合范围推导。若推导值不符合限制，初始化会失败，例如设置 `minLength = 1` 的文本需要非空默认值。


### 完整代码示例

源码：[MCUExample2](MCUExample2/platform/steam/ue4ss/Mods/MCUExample2/Scripts/main.lua)。

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
        {key = "GeneralSection", type = "Separator", label = "基本设置"},
        {key = "Enabled", type = "BoolToggle", label = "布尔开关", default = true, onchange = onchange},
        {key = "IntegerValue", type = "IntBox", label = "整数输入", default = 12, onchange = onchange},
        {key = "FloatValue", type = "FloatBox", label = "浮点数输入", default = 1.25, onchange = onchange},
        {
            key = "IntegerSlider", type = "IntSlider", label = "整数滑动条", default = 10,
            min = 0, max = 100, step = 5, onchange = onchange,
        },
        {
            key = "FloatSlider", type = "FloatSlider", label = "浮点数滑动条", default = 0.5,
            min = 0, max = 1, step = 0.1, onchange = onchange,
        },
        {
            key = "TextValue", type = "TextBox", label = "文本输入", default = "Hello MCU",
            maxLength = 40, onchange = onchange,
        },
        {
            key = "IntegerChoice", type = "IntSelect", label = "整数选项", default = 2,
            options = {{value = 1, label = "少"}, {value = 2, label = "多"}},
            onchange = onchange,
        },
        {
            key = "FloatChoice", type = "FloatSelect", label = "浮点数选项", default = 1.0,
            options = {{value = 0.5, label = "半倍"}, {value = 1.0, label = "一倍"}},
            onchange = onchange,
        },
        {
            key = "TextChoice", type = "TextSelect", label = "文本选项", default = "normal",
            options = {{value = "compact", label = "紧凑"}, {value = "normal", label = "标准"}},
            onchange = onchange,
        },
        {key = "PrintConfig", type = "Button", label = "打印配置", onclick = printConfig},
    },
}

local config, err = mcu.InitFromFile(schema)
if not config then
    print("[MyMod] " .. tostring(err) .. "\n")
    return
end

printConfig(config)
```

### 注意事项

- 对于此种接入方式，恢复默认值按钮会根据scheam恢复默认配置并立刻生效。
- 当schema变更时，如果旧的值得符合新schema中同一配置项的范围，则会保留，否则直接抛弃而使用默认值。
- 仅停用 MCU 界面、保留共享模块时，Mod 仍能初始化配置。不要引用 MCU 界面的私有脚本，只使用共享模块公开接口。
- 不要随你的 Mod 分发共享模块的重复副本，也不要分发运行时生成的 `.schemaconfig.json`。
- MCU 自身文字跟随游戏语言；Mod 配置文字默认使用 schema，可通过下述语言包提供翻译。
- 同一个 Mod 既注册 schema 又提供下方的simple json时，只有schema生效，文件夹名匹配不区分大小写。


### UI语言包

将 UTF-8 JSON 文件放在 `Mods/<ModName>/<ModName>.lang.<语言代码>.json`例如 `MyMod.lang.en.json`，可随 Mod 发布或单独安装，无需修改MOD代码。

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
**语言包的fields是无序对象而非数组，和schema不同**

- 跟随游戏语言，可选代码：`en`（英语）、`zh-Hans`（简体中文）、`zh-Hant`（繁体中文）、`ja`（日语）、`ko`（韩语）、`fr`（法语）、`de`（德语）、`es`（西班牙语）、`ru`（俄语）、`pt-BR`（巴西葡萄牙语）、`it`（意大利语）
- 重新进入 Mod 配置页时刷新。
- 如果存在对应语言包，则从语言包的 `fields` 根据 `key`(options则按 `value` 匹配) 查找对应 `label`、`description` 覆盖原来的schema里的值。
- 语言包只改变UI文字，不改变配置、UI生成和存储逻辑。Simple 接入暂不支持语言包。
- 可参考 [MCUExample2 英文语言包](MCUExample2/platform/steam/ue4ss/Mods/MCUExample2/MCUExample2.lang.en.json)；其中文默认文字仍在 schema 中。

## 二，轻量接入：simple json

### 你需要做什么

1. 配置文件不存在时，由你的mod创建 `Mods/<ModName>/<ModName>.config.json`。其中`ModName` 必须与 Mod 安装文件夹名称一致。
2. 由你的 Mod 自己读取配置文件。
3. 注册MCUChangeEvent_[ModName]，并在接收到事件时重新载入配置文件。

请实现从默认值创建和读取操作，不要实现保存配置，以免和MCU保存的配置互相覆盖。

### MCU会做什么
MCU会读取按条件命名好的json配置文件,为其生成UI，并将用户修改后的配置保存回配置文件。

MCU 不直接更新你的本地变量。可以注册下方的可选通知，在 MCU 保存后自行重载配置；未注册时，仍由 Mod 自己决定何时重新读取文件。

你的MOD可以不依赖MCU而运作，但是你需要使用json库实现json读取，你可以使用自己的json库或MCU 提供的共享 JSON 库。


### 配置示例

注意你最好让程序在不存在配置文件时根据默认值自动生成，而不要将配置文件打包进入MOD，因为这会覆盖用户的本地配置。
```json
{
  "ShootDuration": 0.3,
  "DamageColor": "#FFFFFF",
  "Enabled": true,
  "RectWidth": 150
}
```

### 代码示例

见 [simple 接入示例](MCUExample/platform/steam/ue4ss/Mods/MCUExample/Scripts/main.lua)。

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

注册配置变更事件

```lua
RegisterConsoleCommandGlobalHandler("MCUChangeEvent_MyMod", function()
    loadConfig()
    return true
end)
```

- 你可以不注册这个事件，但这意味着下次重启mod时变更的配置才会生效(除非你自己通过其它方式重新载入配置)
- 命令名为 `MCUChangeEvent_` 加 Mod 文件夹名，例如 `MCUChangeEvent_MyMod`。字母、数字、下划线原样保留，其它字符按字节写成 `%xx`；例如 `My-Mod` 对应 `MCUChangeEvent_My%2dMod`，空格为 `%20`，点为 `%2e`。不要用下划线替换这些字符，以免不同 Mod 重名。
- 事件只会通知你配置变更了，不携带任何信息。
- 成功保存实际变化后，每次保存只通知一次；批量修改多个字段也只通知一次。未改变、保存失败或仅打开页面不通知。
- 恢复默认值时，删除文件成功后发送同一通知；处理函数应在文件不存在时生成默认配置。命令调用返回后，MCU 检查文件：已生成则刷新配置，仍不存在才提示重新加载 Mod 或重启游戏。若 Mod 延迟生成文件，重新进入 Mod 设置页时刷新。
- 通知处理失败不撤销已经保存或删除的文件，也不会自动重试。未运行 MCU 时，Mod 仍可正常自行加载配置。


### 支持的类型

| JSON 值类型 | UI 控件 |
| --- | --- |
| 布尔值 | 开启 / 关闭选项 |
| 数值 | 数字输入框 |
| 字符串 | 文本输入框 |

不支持的类型不会生成对应控件，修改配置时不支持的项目会保持原样写回，不保证缩进和字段顺序不变。


### 注意事项

- 对于此种接入方式，“恢复默认值”按钮会直接删除整个配置文件（包括不支持的字段）。已注册通知的 Mod 可立即重新生成默认配置；未注册时，由 Mod 在下次加载配置时创建。
- `json.load(path)` 在文件无法打开时返回 `nil`，解析失败会抛出异常；`json.dump(value, path)` 写入失败会抛出异常。
- 当前共享 JSON 模块基于 David Heiko Kolf 的 dkjson 2.11（MIT 许可证），并提供 `load` / `dump` 文件辅助接口。
