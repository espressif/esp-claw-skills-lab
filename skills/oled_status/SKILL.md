---
{
  "name": "oled_status",
  "description": "Continuously drive the SSD1306 OLED status board (WiFi / volume / radio / time) and expose a notification API that briefly overrides the status view with a message.",
  "author": "ESP-Claw contributor",
  "metadata":
    {
      "category": ["hardware", "ui", "system"],
      "tags": ["oled", "ssd1306", "status", "notification"],
      "peripherals": ["oled", "i2c"],
      "cap_groups": ["cap_lua"],
      "manage_mode": "web"
    }
}
---

# OLED Status Board

Long-running Lua daemon that owns the SSD1306 OLED (128x32, I2C @ GPIO 41/42, addr 0x3C) and renders a live status board:

```
Line 1: WiFi:192.168.1.100
Line 2: Vol:70            (or Vol:MUTE (was 70))
Line 3: Radio:play        (play / idle / off)
Line 4: 14:23:45 UP:2h05m
```

Any script can push a notification onto the daemon's queue. The daemon flips to a full-screen 4-line message view (auto-wraps ASCII 25 chars/line) for `duration_ms`, then falls back to the status board.

## Prerequisites

- Board must have an SSD1306 OLED at I2C addr 0x3C on port 0 with SDA=GPIO41, SCL=GPIO42. (The `esp32_S3_DevKitC_1_voice_breadboard` board is already wired this way via `board_devices.yaml`.)
- No other component should be driving the SSD1306 at the same time. The `oled_ssd1306` skill's `oled_hello.lua` will fight this daemon — don't run both.

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/oled_status_daemon.lua` | The daemon. Runs forever, refreshes at ~1 Hz. Spawn once via `lua_run_script_async` (see router rule below). |
| `scripts/oled_notify.lua` | Push a one-shot message. Args: `{text, duration_ms?}`. |

## Notification Args Schema

For `oled_notify.lua`:

```json
{
  "type": "object",
  "properties": {
    "text": { "type": "string", "minLength": 1 },
    "duration_ms": { "type": "integer", "minimum": 500, "maximum": 60000, "default": 8000 }
  },
  "required": ["text"]
}
```

## Starting the daemon at boot

Install this router rule to auto-launch the daemon after boot completes:

```json
{
  "id": "oled_status_launch_on_boot",
  "description": "Spawn the OLED status daemon when the device finishes booting.",
  "enabled": true,
  "consume_on_match": false,
  "ack": "OLED status daemon launched",
  "match": {
    "source_cap": "app_claw",
    "event_type": "startup",
    "event_key": "boot_completed"
  },
  "actions": [
    {
      "type": "run_script",
      "input": {
        "path": "/fatfs/skills/oled_status/scripts/oled_status_daemon.lua",
        "args": {},
        "name": "oled_status_daemon",
        "exclusive": "oled_status",
        "replace": false,
        "timeout_ms": 0,
        "async": true
      }
    }
  ]
}
```

The `timeout_ms: 0` with `async: true` means "run in background forever". `exclusive: "oled_status"` prevents duplicate daemons if the rule fires more than once.

## Pushing notifications

**From another Lua script** (fire-and-forget):

```lua
local capability = require("capability")
capability.call("lua_run_script", {
  path = "/fatfs/skills/oled_status/scripts/oled_notify.lua",
  args = { text = "喝水时间到了", duration_ms = 5000 },
})
```

(SSD1306 font is ASCII only; Chinese renders as blanks. Use ASCII text or transliterate for OLED.)

**Direct queue push** (skip the wrapper — slightly faster):

```lua
local json = require("json")
local thread = require("thread")
thread.sync.queue_create("oled_status_notify", { depth = 4, item_size = 1024 })
thread.sync.queue_send("oled_status_notify",
  json.encode({ text = "hello", duration_ms = 3000 }), 200)
```

## Behavior

- **Idle**: shows the 4-line status board, refreshed every ~1 s.
- **Notification pending**: shows the wrapped message text for `duration_ms`, then reverts.
- **Overlapping notifications**: newest wins (queue drops oldest on backpressure).
- **Data sources**:
  - WiFi IP via `system.ip()`; SSID/RSSI via `system.info()`
  - Volume via `/fatfs/board_button_volume_master.json` (populated by `board_button_volume` skill)
  - Radio state via `/ramfs/network_radio/status.json` (populated by `network_radio` daemon)
  - Time via `system.date("%H:%M:%S")` (requires SNTP or manual time set)
  - Uptime via `system.uptime()`
- If a data source is missing (e.g. no `board_button_volume` installed), the line degrades gracefully (`Vol:70` default).

## Voice reminder integration

The `voice_reminder` skill's `control_speak.lua` pushes the spoken text to this queue automatically, so speaking a reminder also flashes it on the OLED.

## Extending the status board

Edit `status_lines()` in `oled_status_daemon.lua`. Each of the 4 lines is a plain Lua string sliced to 25 chars before drawing. New data sources can be added by requiring more modules or reading more files.
