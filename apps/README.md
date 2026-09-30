# Apps

独立 Lua 应用由设备 Launcher 启动，每个包包含 `launcher.json`、使用说明、脚本及所需资源。

| App | 功能 | 浏览器试玩 |
| --- | --- | --- |
| `clock_dial_demo` | 双主题时钟与专注计时 | 支持 |
| `lcd_touch_paint` | 触摸画板 | 支持 |
| `dino` | 恐龙跳跃游戏 | 支持 |
| `flappybird` | 飞鸟游戏 | 支持，无声 |
| `codex_usage_dashboard` | 额度看板 | 支持，使用示例数据 |
| `balance_ball` | IMU 平衡球 | 不支持 |

应用均提供 48×48 JPEG 图标和右上角退出按钮。具体操作与硬件要求见各包的 README。

`launcher.json` 保存启动配置，`catalog` 扩展字段用于本站分类、描述和模拟器标记。设备忽略此扩展，整个清单不得超过 4096 字节。包不得引用其他 App 或 Skill 的文件。

安装到设备 DATA 根目录的 `apps/<id>/`：先写脚本与资源，最后写 `launcher.json`，再通过 `publish_app` 发布。DATA 根目录通过设备存储接口解析，不固定为 `/fatfs`。

浏览器模拟器的实现边界和本地联调方式见 [模拟器说明](../docs/app-simulator-plan.md)。
