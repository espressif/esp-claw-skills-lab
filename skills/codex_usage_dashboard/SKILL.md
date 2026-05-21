---
{
  "name": "codex_usage_dashboard",
  "description": "Show a Codex usage quota dashboard on the board display from a configured JSON endpoint, including 5-hour and weekly reset status.",
  "metadata":
    {
      "category": ["utility", "ai"],
      "tags": ["codex", "usage", "quota", "dashboard"],
      "peripherals": ["display"],
      "cap_groups": ["cap_lua", "cap_http_request", "cap_time"],
      "manage_mode": "web"
    }
}
---

# Codex Usage Dashboard

Use this skill when the user asks to show, start, open, launch, or display the Codex usage dashboard, quota dashboard, usage meter, 5-hour quota, or weekly quota on the device screen.

This skill runs one Lua dashboard app that uses the board LCD with LVGL and periodically fetches usage data from its configured JSON endpoint.

<img width="1448" height="1086" alt="image" src="https://github.com/user-attachments/assets/5a0379ca-8c78-49e5-ba0a-5fa5f7d18393" />

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
2. Before proceeding, you must verify both prerequisites with the user:
   - Confirm that the Codex usage plugin is installed.
   - Ask for and obtain the JSON endpoint URL or IP address.

3. Do not continue unless both prerequisites are satisfied. Confirmation of plugin installation alone is insufficient; the JSON endpoint URL or IP address must also be provided.

4. If the user needs guidance to install the plugin or configure the endpoint, MUST first tell the user that they can view the installation guide here:
   - `https://github.com/2002-luzi/codex-plugins`

   Then retrieve instructions from:
   - `https://raw.githubusercontent.com/2002-luzi/codex-plugins/refs/heads/main/README.md`
   - `https://raw.githubusercontent.com/2002-luzi/codex-plugins/refs/heads/main/plugins/codex-usage-lan-plugin/README.md`

   Use that information to guide the user through plugin installation and endpoint setup.

5. Confirm the script path is `/fatfs/skills/codex_usage_dashboard/scripts/codex_usage_dashboard.lua`.
6. Start it with `lua_run_script_async` using name `codex_usage_dashboard`, exclusive group `display`, `replace: true`, and `timeout_ms: 0`.
7. Report that the dashboard is running, or report the Lua error directly.
8. If the user asks to stop, close, quit, cancel, or clear the display/dashboard, call `lua_stop_async_job` with name `codex_usage_dashboard`.

## Behavior

- Draws a pixel-style `CODEX USAGE` dashboard.
- Shows current local time.
- Fetches usage JSON once at startup, then every 60 seconds.
- Displays 5-hour quota percentage and reset countdown.
- Displays weekly quota percentage and reset countdown.
- Keeps processing LVGL events until the async job is stopped.
