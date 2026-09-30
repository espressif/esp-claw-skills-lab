# App 浏览器模拟器

本站负责展示和分发 App，ESP-Claw 仓库的 `pages/simulator` 负责浏览器执行。Skill 不提供在线模拟入口，App 通过 `launcher.json.catalog.simulator` 声明是否开放试玩。

## 实现结构

模拟器读取 App 清单、文件列表和可选 mock，将文件挂载到 WASM 文件系统，再执行原始 Lua 入口。引导脚本设置全局 `args` 并将入口目录加入 `package.path`。

`tools/lua_lvgl_web_sim` 复用原生 display 的颜色、脏区、光栅、文字和帧缓冲代码。浏览器 Lua 绑定和 RAW 显示服务适配负责参数转换、RGB565 到 Canvas 的提交、触摸事件及资源清理。RAW 和 LVGL 共用排他显示会话。

## 支持范围

- 支持屏幕打开/关闭、帧提交、基本图元、内置文字、裁剪、平移和单指触摸。
- 支持正常退出、异常退出及 Stop 清理；更换脚本或分辨率前先停止当前运行。
- 暂不支持 `image`、`blit` 和自定义字体，调用时返回错误。
- 飞鸟无音频；额度看板通过 mock 展示示例数据；平衡球不开放试玩。

浏览器执行不能替代真机的传感器、音频、内存及屏幕性能检查。

## 分发协议

- 索引：`/raw/apps-data.json`，每项包含 `id`、`files` 和布尔字段 `simulator`。
- 文件：`/raw/apps/<id>/<file>`，`files` 中的路径相对于 App 包。
- 参数：`launcher.json.args` 为默认参数，`simulator/mock.json.args` 可覆盖同名顶层字段。
- HTTP mock：使用 `HTTP <status>\n<body>` 响应格式；配置能力 mock 时页面标记示例数据。

修改清单后需要重新生成本站索引。生产环境跨域读取 raw 文件时需配置 CORS。

## 本地联调

在 Skills Lab 仓库启动站点：

```sh
VITE_SIMULATOR_BASE_URL=http://localhost:5174/ pnpm dev --host 127.0.0.1 --port 5173 --strictPort
```

在 ESP-Claw 的 `pages/simulator` 目录启动模拟器：

```sh
VITE_SKILLS_LAB_RAW_BASE=/lab/raw VITE_SKILLS_LAB_WEB_BASE=http://localhost:5173 pnpm dev --port 5174 --strictPort
```

模拟器通过 Vite 代理从本站读取 App。远程开发需同时转发两个端口；公网模拟器无法直接读取开发机文件。

修改 C、兼容头或 HTML shell 后需重新构建 WASM 并执行 `pnpm copy-runtime`。上游 `pages/simulator/run-local.sh` 提供 Docker 构建流程；不同挂载路径使用独立的 CMake 缓存。

## 检查入口

本站提供 `pnpm validate-packages`、`pnpm test`、`pnpm test-apps` 和 `pnpm build`。Lua 主机测试需要 Lua 5.4 或更新版本，使用 API 桩，不访问硬件。

上游模拟器提供 `pnpm test` 和 `pnpm build`；`tools/lua_lvgl_web_sim/tests/display_contract.lua` 可上传到模拟器执行，覆盖图元、帧、触摸和资源契约。这些命令是复现入口，不表示当前修改已经执行验证。
