---
{
  "name": "token_usage",
  "description": "Install or show the token usage dashboard on the device display: Cursor activity, Deepseek balance, standing reminders, weather, hourly telemetry memory, and on-the-hour greeting letters. Requires a display and a PC host running the token usage HTTP server on the same network. Standing reminders are managed locally on the device.",
  "metadata": {
    "cap_groups": [
      "cap_lua"
    ],
    "manage_mode": "web",
    "category": [
      "utility"
    ],
    "peripherals": [
      "display"
    ],
    "tags": [
      "cursor",
      "deepseek",
      "dashboard",
      "token",
      "install",
      "standing"
    ]
  }
}
---

# Token Usage

Installs or runs the token usage dashboard on ESP-Claw. The installer switches the agent persona, registers boot auto-start for the dashboard, saves hourly telemetry into long-term memory, and sends on-the-hour greeting letters to known IM chats.

## When to use

- The user asks to install, set up, or adopt the token usage dashboard, token monitor, or standing reminder screen, in any language.
- The user asks to show, open, or close the dashboard without reinstalling.

Match the user's language when you reply; do not switch language on your own.

## Install

Use this flow when the user wants installation, boot auto-start, hourly memory snapshots, or scheduled greeting letters.

1. Ask for the PC IPv4 address that runs the token usage HTTP server. Do not run the installer without it.
2. Run the installer with `lua_run_script` and the inputs shown below.
3. Wait for the log line `[install_token] install complete` before telling the user that setup is ready.
4. If the script prints `[install_token] ERROR: ...`, report that line to the user and stop.
5. After installation completes successfully, tell the user to restart the device (e.g., press the reset button or use `device_reset`) for the skill to take effect.

Re-running the installer updates the existing router rules and schedules (host, port, or letter language). On memory-constrained boards, the installer skips relaunching the dashboard when it is already running with the same host/port, and stops display jobs before a relaunch when host/port changes or `restart_dashboard=true`.

The hourly greeting schedule uses cron and requires SNTP time sync. The telemetry snapshot uses a relative interval and does not require wall-clock time.

### Install Tool Call Inputs

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/install_token.lua",
  "args": {
    "host": "192.168.1.20",
    "port": 8080,
    "language": "Chinese"
  },
  "timeout_ms": 30000
}
```

- `host` or `pc_ip` is required.
- `port` defaults to `8080`.
- `language` defaults to `Chinese` and controls scheduled greeting letters.
- `restart_dashboard` optional boolean. When true, stop the running dashboard and relaunch it after install even if host/port are unchanged.
- `skip_dashboard_start` optional boolean. When true, update soul/rules/schedules only and do not queue a dashboard start event.

### Install Example

User asks to install the token dashboard and gives a PC IP.
-> `lua_run_script` with the inputs above
-> wait for `[install_token] install complete`
-> Reply in the user's language, confirming boot auto-start, hourly memory snapshots, and on-the-hour greeting letters.

## Show Dashboard

Use this flow when the user only wants to open or refresh the dashboard UI.

Run exactly one bundled Lua script asynchronously with the Lua script execution capability.

If script execution returns an error, report that error directly to the user.
Do not retry with changed arguments or run another script in the same turn unless the user explicitly asks.

### Script Args Schema

```json
{
  "type": "object",
  "properties": {
    "host": {
      "type": "string",
      "description": "PC IPv4 address that runs the token usage HTTP server. Also accepts pc_ip."
    },
    "port": {
      "type": "integer",
      "default": 8080,
      "minimum": 1,
      "maximum": 65535,
      "description": "HTTP port on the PC host."
    },
    "heartbeat_ms": {
      "type": "integer",
      "default": 1000,
      "minimum": 1000,
      "maximum": 60000,
      "description": "Legacy alias for status_poll_ms."
    },
    "status_poll_ms": {
      "type": "integer",
      "default": 1000,
      "minimum": 1000,
      "maximum": 60000,
      "description": "Interval for GET /device-status polling from the PC host."
    },
    "token_poll_ms": {
      "type": "integer",
      "default": 30000,
      "minimum": 1000,
      "maximum": 600000
    },
    "aux_poll_ms": {
      "type": "integer",
      "default": 30000,
      "minimum": 1000,
      "maximum": 600000
    },
    "weather_poll_ms": {
      "type": "integer",
      "default": 600000,
      "minimum": 1000,
      "maximum": 3600000
    },
    "weather_retry_ms": {
      "type": "integer",
      "default": 10000,
      "minimum": 1000,
      "maximum": 600000
    },
    "http_timeout_ms": {
      "type": "integer",
      "default": 5000,
      "minimum": 1000,
      "maximum": 60000
    },
    "instance_id": {
      "type": "string",
      "description": "Optional stable id used for worker queue and async job names."
    }
  }
}
```

### Dashboard Tool Call Inputs

Show the dashboard with PC polling enabled:

```json
{"path":"{CUR_SKILL_DIR}/scripts/token_usage.lua","args":{"host":"192.168.1.20","port":8080},"timeout_ms":0}
```

Show the dashboard UI without PC polling when the host is unknown:

```json
{"path":"{CUR_SKILL_DIR}/scripts/token_usage.lua","args":{},"timeout_ms":0}
```

Use a custom heartbeat interval when push is unavailable:

```json
{"path":"{CUR_SKILL_DIR}/scripts/token_usage.lua","args":{"host":"192.168.1.20","heartbeat_ms":15000},"timeout_ms":0}
```

### Dashboard Recommended Flow

Run the bundled Lua script asynchronously so the LVGL dashboard stays alive:

- Script: `{CUR_SKILL_DIR}/scripts/token_usage.lua`
- Capability: `lua_run_script_async`
- Timeout: `0`
- Name: `token_usage`
- Exclusive: `display`
- Replace: `true`
- Args: optional object

1. Activate the `board_hardware_info` skill and confirm that a `display_lcd` device is listed.
2. If no display is listed, tell the user that the board does not declare a display and stop.
3. Ask for the PC host IP when the user wants live Cursor, Deepseek, standing, or weather data. Pass it as `host` or `pc_ip`.
4. If the host is unknown, run the script with empty `args` to show the local UI without Windows polling.
5. Run `{CUR_SKILL_DIR}/scripts/token_usage.lua` with the resolved `args`.
6. Report the start result or error directly to the user.
7. Use `lua_get_async_job` or `lua_tail_async_job` when the user asks for runtime status or logs.
8. Stop the async Lua job named `token_usage` when the user asks to close the dashboard.

## Configuration

Install and schedule tunables live in **`{CUR_SKILL_DIR}/scripts/token_usage_config.lua`** — snapshot interval, letter cron expression, default letter language, letter persona name, and default port. After editing the config, run `install_token.lua` again to update the scheduler entries and router rules.

## Persona

Installation copies **`{CUR_SKILL_DIR}/soul_token.md`** to `/fatfs/memory/soul.md`. ESP-Claw speaks as a warm desk-side colleague with gentle, good-natured teasing — not a status dashboard. Scheduled hourly letters follow the same voice: human, caring, and concise.

## Behavior

The dashboard script initializes `display_lcd` and optional `lcd_touch`, builds a single-page LVGL dashboard, and keeps running until the async job is stopped.

When `host` is set, the script polls the PC over HTTP in the main loop (no extra Lua worker task):

1. `GET /cursor-status` every `cursor_poll_ms` / `status_poll_ms` (default 1s)
2. `GET /deepseek-balance`, `/deepseek-account-balance`, `/weather` on their own intervals

Polling runs in the same async job as the LVGL UI to avoid spawning a second 32KB Lua task on memory-constrained boards.

The UI merges `cursor_status` and `codex_status` locally for the four-state IDE indicator.

The standing icon is drawn directly on an LVGL canvas in the bottom-left area of the dashboard.

Touching the screen during an active standing reminder window confirms that hour's pill.

After installation, `token_usage_snapshot.lua` runs every hour to sample local environmental sensors (temperature, humidity, pressure, estimated CO2) plus PC data (DeepSeek token balance, account balance, outdoor weather, Cursor/Codex activity) and local standing count from the dashboard state file, append `{CUR_SKILL_DIR}/telemetry_history/`, and call `memory_store` with tags `token_usage,environment,standing,weather,cursor`.

`token_usage_letter.lua` runs synchronously (no async task spawned) every minute via scheduler, but only composes and sends a letter at the top of each clock hour. It reads telemetry history and recent long-term memory (`memory_recall` on the `token_usage` label), then broadcasts the greeting to known IM chats. Letters weave desk air, outdoor weather, standing progress, token trends, and agent workload into everyday language with one caring suggestion — not a technical report. Synchronous execution avoids a 32KB Lua task allocation that would fail when internal DRAM is fragmented.
