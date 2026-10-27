# Apps

独立 Lua 应用由设备 Launcher 启动，每个包包含 `launcher.json`、使用说明、脚本及所需资源。

| App                     | 功能                 | 浏览器试玩         |
| ----------------------- | -------------------- | ------------------ |
| `clock_dial_demo`       | 双主题时钟与专注计时 | 支持               |
| `lcd_touch_paint`       | 触摸画板             | 支持               |
| `dino`                  | 恐龙跳跃游戏         | 支持               |
| `flappybird`            | 飞鸟游戏             | 支持，无声         |
| `codex_usage_dashboard` | 额度看板             | 支持，使用示例数据 |
| `balance_ball`          | IMU 平衡球           | 不支持             |
| `balance_drop`          | Balance Challenge    | 暂未开放           |
| `shake_dice`            | Shake Dice           | 暂未开放           |
| `flip_hourglass`        | Flip Hourglass       | 暂未开放           |
| `gravity_maze`          | Gravity Maze         | 暂未开放           |
| `pocket_aquarium`       | Pocket Aquarium      | 暂未开放           |
| `fruit_slice`           | Fruit Slice          | 暂未开放           |
| `game_2048`             | 2048                 | 已开放             |
| `game_of_life`          | Game of Life         | 已开放             |
| `jump_prince_game`      | Jump Prince          | 已开放             |
| `maze`                  | Maze                 | 已开放             |
| `music_pinball`         | 音乐弹珠台           | 暂未开放           |
| `mosaico-musical`       | Mosaico Musical      | 已开放，静音模式   |
| `number_puzzle`         | Number Puzzle        | 已开放             |
| `reaction_game`         | Reaction Game        | 已开放             |
| `snake`                 | Snake Animation      | 已开放             |
| `snake_game`            | Snake                | 已开放             |
| `tetris_clock`          | Tetris Clock         | 已开放             |
| `whack_mole_game`       | Whack-a-Mole         | 已开放             |

各 App 均包含与应用内容匹配的 48×48 图标。具体操作、退出方式与硬件要求见各包 README。

`launcher.json` 保存启动配置，`catalog` 扩展字段用于本站分类、描述和模拟器标记。设备忽略此扩展，整个清单不得超过 4096 字节。包不得引用其他 App 或 Skill 的文件。

设备商店的介绍支持中英文：`catalog.description` 保存默认英文，`catalog.description_i18n["zh-cn"]` 保存中文，缺少中文时使用英文。Cloudflare Pages 根据公网 IP 的国家信息选择语言，中国大陆（`CN`）默认中文，其他地区和未知地区默认英文。设备明确指定的 `?lang=en` / `?lang=zh-cn` 优先，其次是 `Accept-Language` 请求头。

语言选择作用于 `/raw/apps-data.json`、`/raw/catalog-data.json` 中的 App 介绍，以及 `/raw/apps/<id>/_metadata.json` 的介绍字段。安装包文件和大小不随语言变化；响应使用 `Content-Language` 标明语言，并禁止共享缓存混用不同地区的响应。设备沿用现有接口即可，在商店刷新目录后更新介绍。

本地 `pnpm dev` 没有公网国家信息，默认英文，可通过 `http://localhost:5173/raw/apps-data.json?lang=zh-cn` 调试中文。生产部署使用项目现有的 `wrangler pages deploy dist` 流程，根目录 `functions/` 中的语言处理函数会一起部署。仅发布静态 `dist/` 文件时仍返回默认英文。

安装到设备 DATA 根目录的 `apps/<id>/`：先写脚本与资源，最后写 `launcher.json`，再通过 `publish_app` 发布。DATA 根目录通过设备存储接口解析，不固定为 `/fatfs`。

浏览器模拟器的实现边界和本地联调方式见 [模拟器说明](../docs/app-simulator-plan.md)。
