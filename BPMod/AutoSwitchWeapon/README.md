# AutoSwitchWeapon 蓝图工程

使用 UE 5.7.4。此工程保留可编辑的未 Cook 蓝图，Mod 默认在杀气低于 30% 时通过游戏原生换武器输入切换。只有在轻、重攻击期间检测到杀气实际下降，才保护当时的具体攻击，等待其结束后重新判断；未消耗杀气的攻击照常允许切换，保护不会延续到之后的免费攻击。运行时由 BPModLoaderMod 加载，无需本 Mod 自带 Lua，不使用轮询。

配置采用 MCU Lite（simple）格式，首次运行生成 `platform/steam/ue4ss/Mods/AutoSwitchWeapon/AutoSwitchWeapon.config.json`，不随安装包发布：

| English option | Default | Behavior |
| --- | --- | --- |
| `ThresholdPercent` | `30` | 在杀气百分比严格低于该值时尝试切换，应用范围 0–100；MCU 显示数值输入框。 |
| `ProtectShachiAttacks` | `true` | 不打断实际消耗杀气的招式；关闭后允许在这些招式中切换，MCU 显示开关。 |

启动时读取配置，原生设置面板或其所属外层菜单关闭后安排一次性延后读取，让本轮关闭流程完成输入保存。多个关闭通知合并处理；若游戏仍暂停，则在恢复运行后读取。文件不存在则重新生成默认值，配置未变化时不重复应用。无需文件时间检查、轮询或本 Mod 的 Lua。MCU 保存后须退出原生设置菜单才生效；MCU 重置删除配置后，也在退出设置菜单时恢复默认值，包括直接关闭游戏内外层菜单的情况。手动修改同一文件也遵循此规则。游戏菜单类或原生菜单事件发生变化时可能需要更新兼容性。

关闭招式保护会清除当前保护并停止记录后续消耗；重新开启后保护之后检测到的消耗。消耗判定依据杀气实际下降，不能区分攻击扣费和攻击期间因受击等其他原因造成的杀气损失。

首次打开前，在本目录执行 `python build.py editor-build-source`，然后打开 `AutoSwitchWeapon.uproject`，编辑 `Content/Mods/AutoSwitchWeapon/ModActor`。需要 UE 支持的 C++ 编译工具。该命令在 `_temp/AutoSwitchWeapon` 编译，并自动将五个编辑器模块及其匹配的加载清单复制到正式工程的 `Binaries/Win64`；中间文件留在临时目录，编辑器模块不随 Mod 发布且已被 Git 忽略。仅执行 `editor-build` 不会安装这些模块，正式工程缺少模块时应执行 `editor-build-source` 后重新打开，不要忽略模块缺失提示继续加载蓝图。正式工程保留正常编辑器插件，命令行裁剪只应用于临时构建副本。

保存蓝图后，按顺序执行以下构建阶段：

```powershell
python build.py editor-build
python build.py cook
python build.py iostore
python build.py pak
python build.py verify
python build.py publish
```

该流程使用当前可编辑资产，不会重新生成或覆盖手工蓝图。游戏挂载路径仍为 `ProjectPBZ/Content/Paks/LogicMods`，正式目录发布三个容器、上传用 `modinfo.ini`，以及安装到 `platform/steam/ue4ss/Mods/AutoSwitchWeapon/modinfo.ini` 的同版本元数据。安装用元数据确保配置目录存在；两处版本号须保持一致。

只有需要从生成器重新制作蓝图时，才在 `editor-build` 后执行 `python build.py create --overwrite-blueprint`。**这会覆盖可编辑的 ModActor，包括全部手工蓝图修改**；执行前应先保存需要保留的修改。更新生成器时须同步生成资产，并通过其自动回归验证后再打包。
