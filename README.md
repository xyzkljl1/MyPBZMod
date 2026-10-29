# ModConfigUI — 开发者接入指南

ModConfigUI（MCU）让玩家在《影之刃零》的原生设置菜单中修改 Mod 配置。你可以选择以下两种接入方式。

下文的 `Mods/` 指 `PBZ/platform/steam/ue4ss/Mods/`。

## 一，轻量接入：simple json

### 你需要做什么

1. 配置文件不存在时，由你的mod创建 `Mods/<ModName>/<ModName>.config.json`。其中`ModName` 必须与 Mod 安装文件夹名称一致。
2. 由你的 Mod 自己读取配置文件。

请只实现从默认值创建和读取操作，不要实现保存配置，以免和MCU保存的配置互相覆盖。

### MCU会做什么
MCU会读取按条件命名好的json配置文件,为其生成UI，并将用户修改后的配置保存回配置文件。

**MCU 修改 JSON 文件后不会通知你的 Mod，也不会更新你的本地变量。 新的配置要么等重启Mod后生效，要么你自己轮询重新加载配置文件。**

你的MOD可以不依赖MCU而运作，但是你需要使用json库实现json读取，MCU 提供了共享的 JSON 库。


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
local json = require("json")
local configPath = "../../../platform/steam/ue4ss/Mods/MyMod/MyMod.config.json"
local config = {
    BooleanValue = true,
    NumberValue = 12.5,
    TextValue = "Hello MCU",
}

for key, value in pairs(json.load(configPath) or {}) do
    config[key] = value
end
json.dump(config, configPath)

for key, value in pairs(config) do
    print("[MyMod] " .. key .. " = " .. tostring(value) .. "\n")
end
```


### 支持的类型

| JSON 值类型 | UI 控件 |
| --- | --- |
| 布尔值 | 开启 / 关闭选项 |
| 有限数值 | 数字输入框 |
| 字符串 | 文本输入框 |

不支持的类型不会生成对应控件，修改配置时不支持的项目会保持原样写回，不保证缩进和字段顺序不变。


### 注意事项

- 对于此种接入方式，“恢复默认值”按钮会直接删除整个配置文件(包括不支持的字段)，并要求用户重启Mod，你的 Mod 应在启动时根据默认值创建配置文件以实现重置。
- `json.load(path)` 在文件无法打开时返回 `nil`，解析失败会抛出异常；`json.dump(value, path)` 写入失败会抛出异常。
- 当前共享 JSON 模块基于 David Heiko Kolf 的 dkjson 2.11（MIT 许可证），并提供 `load` / `dump` 文件辅助接口。

## 二，高级接入： schema 配置（推荐）

### 你需要做什么

1. 将 MCU 列为安装依赖，并通过 `require("mcu_core")` 导入共享模块。
2. 在 Lua 中定义一个 schema，指定配置字段、类型、空间参数、回调等。
3. 调用 `InitFromFile`，**保存它返回的config对象** ，业务代码直接读取其中的配置项。

**不要在MOD里附带配置文件或自己实现文件读写**

### 最小代码示例

在你的 `Mods/<ModName>/Scripts/main.lua` 中：

```lua
local config = require("mcu_core").InitFromFile({
    fields = {{key = "Enabled", type = "BoolToggle"}},
})
print(config.Enabled)
```
(除非显示传入UpdateInPlace = false) 用户在UI上变更配置后，本地文件和在lua中保存的config对象会自动更新。你的业务代码继续使用 `config.Enabled` 即可。
MCU对config对象的修改是单向的，**如果你在mod里修改了config对象，修改不会反映到配置文件或UI上，而是在下一次配置变动时被覆盖**

### MCU_CORE提供的接口

通过 `local mcu = require("mcu_core")` 导入。(`list` 和 `request` 是内部接口不要使用)

#### `InitFromFile(schema)`

```lua
local config, err = mcu.InitFromFile(schema)
```
根据你传入的scheam生成UI
读取位于`Mods/<ModName>/<ModName>.schemaconfig.json`的配置文件并生成config对象返回，如果不存在则使用默认值创建配置文件。

入参 `schema` 是一个 Lua table，不是 JSON 字符串，也不是配置文件路径。结构如下：

```lua
local schema = {
    updateInPlace = true, -- 可选，省略时为 true，名称区分大小写。
    fields = { -- 必填，按顺序排列的字段定义。
        {
            key = "Count", -- 必填，配置键名，同一 schema 内不可重复。
            type = "IntBox", -- 必填，控件类型。
            label = "数量", -- 可选，省略时显示 key。
            description = "要显示的数量", -- 可选，配置说明。
            default = 12, -- 可选，须符合当前字段的类型和限制。
            params = {min = 0, max = 100, step = 1}, -- 是否必填及具体内容取决于 type。
            onchange = function(newValue, oldValue, fullConfig) -- 可选。
                print(newValue)
            end,
        },
        {
            key = "PrintConfig",
            type = "Button",
            label = "打印数量",
            onclick = function(fullConfig) -- Button 必填。
                print(fullConfig.Count)
            end,
        },
    },
}
```

`fields` 使用连续数组形式 `{字段1, 字段2, ...}`，不要写成 `{Count = {...}}`；每个字段都在自己的定义里填写 `key`。`onchange` 和 `onclick` 是 Lua 函数，放在对应字段内，不放在 schema 顶层。Button 不提供 `default` 或 `onchange`，其他类型不提供 `onclick`。不要手动填写 `schema.id`；控件类型、参数和默认值规则见后面的对应章节。

参数:
- `schema.fields`：必填，有序字段数组，具体格式见下文。
- `schema.updateInPlace`：可选，默认为 `true`。 为true时， MCU会自动更新InitFromFile返回的config对象；为fales时则不会，此时你需要自己实现 `OnChange`以更新内存里的配置项 (配置文件仍然会照常自动保存)。
- Mod 名称从调用脚本所在的路径自动取得，即文件夹名=Mod名。
- 成功返回只包含配置值的 `config`，例如 `config.Enabled`/ `config.interval`；失败返回 `nil, err`。
- 初始化不触发 `onchange`。同一 Mod 多次调用初始化会替换此前的注册，旧配置对象不再用于主动保存。

#### `onchange(newValue, oldValue, fullConfig)` 回调

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


#### `ForceSaveConfig(config)`

```lua
local saved, err = mcu.ForceSaveConfig(config)
```
**注意99%的情况下你不需使用此函数**
它并非用于保存变更后的配置，UI产生的配置变动都是自动保存的。
这个函数是用于让你保存一些不能通过UI设置的东西，例如你自己计算的缓存等。

- `config` 必须是当前注册对应的最新 API 配置对象，包含所有值字段，不能传普通副本、未知字段或过期对象。
- 成功返回保存后的配置对象，使用 `config = saved` 接收；失败返回 `nil, err`。
- 不触发 `onchange`，也不能在 `onchange` 内调用。



### 支持的类型

| type | 控件 / 值类型 | params |
| --- | --- | --- |
| `BoolToggle` | 布尔二选一 | 无 |
| `IntBox` | 整数输入框 | 可选 `min/max/step` |
| `FloatBox` | 浮点数输入框 | 可选 `min/max/step` |
| `IntSlider` | 整数滑动条 | 必填 `min/max/step` |
| `FloatSlider` | 浮点数滑动条 | 必填 `min/max/step` |
| `TextBox` | 文本输入框 | 可选 `minLength/maxLength/pattern` |
| `IntSelect` | 整数选项 | 必填 `options` |
| `FloatSelect` | 浮点数选项 | 必填 `options` |
| `TextSelect` | 文本选项 | 必填 `options` |
| `Button` | 操作按钮，不保存配置值 | 无 |

`options` 是非空数组，每项的 `value` 必填、`label` 可选，例如 `{{value = 1, label = "Low"}, {value = 2, label = "High"}}`。保存的是 `value`，不是下标或显示文字。

`step` 必须为正，步长起点为 `min`，未指定 `min` 时为 `0`。整数必须在 Lua 整数可表示的范围内，浮点数必须为有限数值。

文本长度按 UTF-8 字符计算。`pattern` 是 **Lua pattern**，不是正则表达式；需要整串匹配时添加 `^` 和 `$`。

建议明确写出符合限制的 `default`。省略时会自动推导：布尔为 `false`，文本为空，选项取第一项，滑动条取下限，数字输入以 `0` 为基础结合范围和步长推导。若推导值不符合限制，初始化会失败，例如设置 `minLength = 1` 的文本需要非空默认值。

### fields 的必填项与可选项

- **必填：`key`、`type`。** `key` 是配置键名，必须为非空字符串，在当前 schema 内唯一；`type` 指定控件类型。
- **可选：`label`、`description`、`default`、`onchange`。** `label` 省略时使用 `key`；`description` 为说明；`default` 为默认值；`onchange` 为该字段变化后的回调。
- **`params` 是否必填取决于控件类型**，见下表。
- **Button 必须提供 `onclick`，不能提供 `default` 或 `onchange`。** 其他类型不能提供 `onclick`。

`fields` 是有序数组，控件按声明顺序展示。默认值只需在这里定义一次。


### 完整代码示例

示例包含全部控件类型。实际 Mod 只需保留自己需要的字段和回调。

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
        {key = "Enabled", type = "BoolToggle", label = "布尔开关", default = true, onchange = onchange},
        {key = "IntegerValue", type = "IntBox", label = "整数输入", default = 12, onchange = onchange},
        {key = "FloatValue", type = "FloatBox", label = "浮点数输入", default = 1.25, onchange = onchange},
        {
            key = "IntegerSlider", type = "IntSlider", label = "整数滑动条", default = 10,
            params = {min = 0, max = 100, step = 5}, onchange = onchange,
        },
        {
            key = "FloatSlider", type = "FloatSlider", label = "浮点数滑动条", default = 0.5,
            params = {min = 0, max = 1, step = 0.1}, onchange = onchange,
        },
        {
            key = "TextValue", type = "TextBox", label = "文本输入", default = "Hello MCU",
            params = {maxLength = 40}, onchange = onchange,
        },
        {
            key = "IntegerChoice", type = "IntSelect", label = "整数选项", default = 2,
            params = {options = {{value = 1, label = "少"}, {value = 2, label = "多"}}},
            onchange = onchange,
        },
        {
            key = "FloatChoice", type = "FloatSelect", label = "浮点数选项", default = 1.0,
            params = {options = {{value = 0.5, label = "半倍"}, {value = 1.0, label = "一倍"}}},
            onchange = onchange,
        },
        {
            key = "TextChoice", type = "TextSelect", label = "文本选项", default = "normal",
            params = {options = {{value = "compact", label = "紧凑"}, {value = "normal", label = "标准"}}},
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

也可查看仓库中的 [完整 schema 接入示例](MCUExample2/platform/steam/ue4ss/Mods/MCUExample2/Scripts/main.lua)。

### 自动更新与回调

`updateInPlace` 默认为 `true`。保存 `InitFromFile` 返回的配置表后，无需编写回调也能读取更新后的值。但 `local enabled = config.Enabled` 这样的独立变量不会随配置表更新，应在使用时读取 `config.Enabled`。

如果配置变化后还需要执行游戏操作，在对应字段上定义：

```lua
onchange = function(newValue, oldValue, fullConfig)
    -- 根据新值更新游戏状态。
end
```

成功保存或恢复默认值后，仅对实际变化的字段调用 `onchange`，按 schema 声明顺序通知。第三个参数是该次变化的完整配置快照，没有第四个 `context` 参数。回调在所属 Mod 的 Lua 环境、游戏线程中排队执行。

初始化不会触发 `onchange`；需要启动时应用设置，应在 `InitFromFile` 成功后处理返回的配置。丢弃返回值不影响 MCU 注册，但你的 Mod 将没有直接读取启动配置的引用。

如果设置 `updateInPlace = false`，需要为每个值字段提供回调，并自行更新业务代码持有的配置变量：

```lua
local config
local function onchange(newValue, oldValue, fullConfig)
    config = fullConfig
end

local err
config, err = require("mcu_core").InitFromFile({
    updateInPlace = false,
    fields = {
        {key = "Enabled", type = "BoolToggle", default = true, onchange = onchange},
    },
})
if not config then
    print(tostring(err))
    return
end
```

按钮使用 `onclick(fullConfig)`，点击时在所属 Mod 的 Lua 环境、游戏线程执行。按钮本身不是保存操作。

### 主动保存配置

MCU 会自动保存 UI 修改，不需要额外保存按钮，也不需要在 `onchange` 内再次保存。

如果你的 Mod 主动修改了配置并需要写回文件，使用 `ForceSaveConfig`：

```lua
-- config 来自成功的 InitFromFile；Count 是 schema 中已有的字段。
config.Count = 20
local saved, err = require("mcu_core").ForceSaveConfig(config)
if saved then
    config = saved
else
    print(tostring(err))
end
```

它验证并保存完整配置，**不触发 `onchange`**。使用最新的 API 配置对象，不要传普通副本或过期快照，也不要在 `onchange` 内调用。

### 注意事项
当schema变更时，如果旧的值得符合新schema中的范围，则会保留，否则直接抛弃而使用默认值。

- Mod 文件夹名称限 1–80 个 ASCII 字母、数字、下划线或连字符，不能使用 Windows 保留设备名。
- 直接 `require("mcu_core")` 要求共享模块已安装；缺失时会报错，不会自动使用默认值。若要支持未安装 MCU 的情况，需要自己实现可选依赖分支。
- 仅停用 MCU 界面、保留共享模块时，Mod 仍能初始化配置。不要引用 MCU 界面的私有脚本，只使用共享模块公开接口。
- 不随你的 Mod 分发共享模块的重复副本，也不分发运行时生成的 `.schemaconfig.json`。
- Schema 支持单项和全部恢复默认值，会保存恢复后的配置，并对实际变化的字段触发回调。
- MCU 自身文字跟随游戏语言；你提供的 `label`、`description` 和选项文字不会被自动翻译。
