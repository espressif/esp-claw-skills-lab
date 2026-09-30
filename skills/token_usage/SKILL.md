---
{
  "name": "token_usage",
  "description": "Install, show, open, or close the token usage dashboard on the board display. Shows Cursor/Codex activity, Deepseek balance, standing reminders, and weather. Requires a display and a PC host running the token usage HTTP server on the same network.",
  "metadata":
    {
      "cap_groups": ["cap_lua", "cap_http_request", "cap_router_mgr", "cap_scheduler", "claw_memory", "cap_im_wechat", "cap_im_feishu", "cap_im_qq", "cap_im_tg", "cap_im_local"],
      "category": ["utility", "ai"],
      "peripherals": ["display"],
      "tags": ["cursor", "deepseek", "dashboard", "token", "install", "standing"]
    }
}
---

# Token Usage

在用户要求查看 Cursor/Codex 工作状态、DeepSeek 用量、天气或久坐提醒时使用。打开面板与安装自动化是两个独立操作；仅打开界面不运行安装器。

## 前提

- 设备具有显示屏；触摸由 LVGL 自动接入。
- 实时工作状态、余额和天气需要同一网络内运行 Token Usage HTTP 服务的 PC，提供 `host` 或 `pc_ip` 与 `port`（默认 8080）。访问目标必须在 HTTP allowlist 中。
- 环境传感器和 LED 灯带为可选硬件，缺失时记录错误并保持其他功能。
- 定时问候依赖已同步的本地时间、PC 提供的模型配置及已建立的 IM 会话。

## 打开面板

调用 `lua_run_script_async`：

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/token_usage.lua",
  "name": "token_usage",
  "exclusive": "display",
  "replace": false,
  "timeout_ms": 0,
  "args": { "host": "192.168.1.20", "port": 8080 }
}
```

不知道 PC 地址而只想查看本地界面时可用空 `args`。同名任务已运行时先查看状态；只有用户明确要求重启或替换占用显示的任务时才使用 `replace: true`。

- 查询状态：`lua_get_async_job`，参数 `{"name":"token_usage"}`。
- 查看日志：`lua_tail_async_job`，使用返回的游标增量读取。
- 关闭面板：`lua_stop_async_job`，参数 `{"name":"token_usage","wait_ms":3000}`。

可选脚本参数：

| 参数 | 默认值 | 用途 |
| --- | --- | --- |
| `status_poll_ms` / `cursor_poll_ms` | 1000 | 工作状态轮询，500–60000 ms |
| `token_poll_ms` | 30000 | 用量轮询，1000–600000 ms |
| `aux_poll_ms` | 30000 | 余额等数据轮询，1000–600000 ms |
| `weather_poll_ms` | 600000 | 天气轮询，1000–3600000 ms |
| `weather_retry_ms` | 10000 | 天气重试间隔，1000–600000 ms |
| `http_timeout_ms` | 5000 | 单次 HTTP 超时，1000–60000 ms |
| `boot_delay_ms` | 3000 | 启动延迟 |
| `led_gpio` / `led_count` | 27 / 5 | 可选提醒灯带，先确认硬件连接 |

当前界面使用 `lvgl.init(options)`，不再获取板级 LCD/触摸裸句柄。点击右上角 `>` 切换用量页和环境页，点击用量页右下角 `OK` 确认本次起身；旧版原始触摸轮询滑动改为 LVGL 控件事件。

## 安装自动化

仅当用户要求安装以下自动化时运行安装器：替换 agent persona、开机启动面板、按小时采集遥测、向已有 IM 会话发送每小时问候。提前说明这四项行为；仅要求查看用量时不要安装。

通过 `lua_run_script` 执行：

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/install_token.lua",
  "args": { "host": "192.168.1.20", "port": 8080, "language": "Chinese" },
  "timeout_ms": 30000
}
```

- `host` 或 `pc_ip` 必填；已有上下文提供地址时直接使用。
- `language` 默认 `Chinese`，用于问候信。
- `restart_dashboard: true` 仅在用户要求重启当前面板时传入；只停止名为 `token_usage` 的任务。
- `skip_dashboard_start: true` 只更新 persona、路由和定时配置，跳过本次启动与重启。
- 重装按固定 id 更新本 Skill 的路由和定时任务，不直接重写共享配置文件。
- 等到 `[install_token] install complete` 再报告安装步骤完成。面板异步启动的结果需查看对应任务，不能把事件入队当成显示成功。
- 失败后报告实际错误，不自行修改参数反复重试。

安装器读取 `{CUR_SKILL_DIR}/soul_token.md`，写入 DATA 根目录的 `memory/soul.md`。开机路由匹配 `app_claw` 的 `boot_completed` 事件；定时参数从 `event.payload.user_payload` 读取。已有面板在运行时默认保留，更新的 PC 地址在下一次启动生效。

## 数据与包资源

`{CUR_SKILL_DIR}/scripts/token_usage_config.lua` 保存默认配置；在源码包中修改后重新部署并运行安装器更新自动化。SYSTEM 中的包文件按只读处理。

脚本通过 `storage.get_root_dir()` 和 `storage.join_path(...)` 将可写数据统一放在 DATA 根目录的 `token_usage/`：

- `standing_state.json`：起身提醒完成情况。
- `telemetry_history/`：每日遥测 JSON。
- `last_sent.txt`：每小时问候去重记录。

旧版写在包目录下的历史数据不再作为默认数据源；如需保留，先将对应数据搬到上述 DATA 目录。不要覆盖已有 DATA 历史文件。

`{CUR_SKILL_DIR}/scripts/token_usage_snapshot.lua` 按配置间隔采集环境、天气、用量和工作状态，追加历史并调用 `memory_store`。CO2 数值由气体电阻估算，不是直接测量。

`{CUR_SKILL_DIR}/scripts/token_usage_letter.lua` 每分钟由 scheduler 同步调用，在配置的发送分钟生成每小时问候。读取历史和 `memory_recall`，通过已有会话对应的 IM 能力发送；没有会话时跳过。该流程不会新增长驻任务。修改发送分钟使用配置项 `letter_send_minute`，默认 0。
