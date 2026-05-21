---
{
  "name": "codex_usage_dashboard",
  "description": "Show a Codex usage quota dashboard on the board display from a configured JSON endpoint, including 5-hour and weekly reset status.",
  "metadata": {
    "cap_groups": [
      "cap_lua"
    ],
    "manage_mode": "readonly"
  }
}
---

# Codex Usage Dashboard

Use this skill when the user asks to show, start, open, launch, or display the Codex usage dashboard, quota dashboard, usage meter, 5-hour quota, or weekly quota on the device screen.

This skill runs one Lua dashboard app that uses the board LCD with LVGL and periodically fetches usage data from its configured JSON endpoint.

## Prerequisites

- The board must have a supported LCD display available as `display_lcd`.
- The Lua runtime must include `board_manager`, `lvgl`, `capability`, `json`, and `system` modules.
- Users must install a companion Codex plugin on their PC, which provides the JSON endpoint.
- The `http_request` capability must allow that endpoint.

## Script Args Schema

```json
{
  "type": "object",
  "properties": {
    "url": {
      "type": "string",
      "description": "Codex usage JSON endpoint, for example http://192.168.1.10:8000/data.json",
      "pattern": "^https?://"
    }
  },
  "additionalProperties": false
}
```

## Tool Call Inputs

Run asynchronously because the dashboard stays active until stopped:

```json
{
  "path": "/fatfs/skills/codex_usage_dashboard/scripts/codex_usage_dashboard.lua",
  "args": {
    "url": "http://<pc-ip>:8000/data.json"
  },
  "name": "codex_usage_dashboard",
  "exclusive": "display",
  "replace": true,
  "timeout_ms": 0
}
```

## Recommended Flow

1. Use board hardware info first if display availability is uncertain.
2. Confirm with the user if the Codex usage plugin is installed. 
3. Ask the user for the the JSON endpoint url or ip address.
   - If the user requires a guidance to install the plugin or set up the endpoint, find the information from `https://raw.githubusercontent.com/2002-luzi/codex-plugins/refs/heads/main/README.md` and `https://raw.githubusercontent.com/2002-luzi/codex-plugins/refs/heads/main/plugins/codex-usage-lan-plugin/README.md`. Guide the user how to install the plugin and set up the endpoint.
4. Confirm the script path is `/fatfs/skills/codex_usage_dashboard/scripts/codex_usage_dashboard.lua`.
5. Start it with `lua_run_script_async` using name `codex_usage_dashboard`, exclusive group `display`, `replace: true`, and `timeout_ms: 0`.
6. Report that the dashboard is running, or report the Lua error directly.
7. If the user asks to stop, close, quit, cancel, or clear the display/dashboard, call `lua_stop_async_job` with name `codex_usage_dashboard`.

## Behavior

- Draws a pixel-style `CODEX USAGE` dashboard.
- Shows current local time.
- Fetches usage JSON once at startup, then every 60 seconds.
- Displays 5-hour quota percentage and reset countdown.
- Displays weekly quota percentage and reset countdown.
- Keeps processing LVGL events until the async job is stopped.
