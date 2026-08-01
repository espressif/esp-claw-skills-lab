---
{
  "name": "board_button_volume",
  "description": "Bridge physical volume buttons on the board (vol_up / vol_down / combo-mute) to the running network_radio daemon. Adjusts the daemon volume live; supports single-click, long-press repeat, and combo mute toggle.",
  "author": "ESP-Claw contributor",
  "metadata":
    {
      "category": ["hardware", "audio", "ui"],
      "tags": ["button", "volume", "mute", "radio"],
      "peripherals": ["button", "speaker"],
      "cap_groups": ["cap_lua"],
      "manage_mode": "web"
    }
}
---

# Board Button Volume Bridge

Adapts physical **volume up / down** buttons (and their two-key combo used as mute) into live volume changes for the `network_radio` skill.

Not called directly by the LLM in normal use — the firmware's `board_button_events` C component publishes trigger events, and a router rule (see below) invokes `apply_volume_delta.lua` for each event.

## Requirements

- The board must expose `vol_up` and `vol_down` as `gpio_ctrl` devices in `board_devices.yaml`. Firmware's `board_button_events` component picks these up automatically.
- The `network_radio` skill must be installed and its daemon should be running (state `playing` or `idle`) for volume changes to have an audible effect. Otherwise the script logs and returns without error.

## Event Contract

`board_button_events` publishes the following trigger events (via `claw_event_router_publish_trigger`):

| source_cap | event_type | event_key | payload | Emitted when |
|------------|-----------|-----------|---------|--------------|
| `board_button` | `vol_up`   | `click` | `{"delta":10}` | Single click on vol_up |
| `board_button` | `vol_up`   | `hold`  | `{"delta":10}` | Long-press hold repeat on vol_up |
| `board_button` | `vol_down` | `click` | `{"delta":10}` | Single click on vol_down |
| `board_button` | `vol_down` | `hold`  | `{"delta":10}` | Long-press hold repeat on vol_down |
| `board_button` | `mute`     | `toggle`| `{}`           | Both keys pressed within combo window |

Firmware Kconfig knobs (component `Board Button Events`) tune:

- `BOARD_BUTTON_EVENTS_LONG_PRESS_MS` (default 500 ms)
- `BOARD_BUTTON_EVENTS_HOLD_INTERVAL_MS` (default 150 ms)
- `BOARD_BUTTON_EVENTS_COMBO_WINDOW_MS` (default 200 ms)
- `BOARD_BUTTON_EVENTS_DELTA_PERCENT` (default 10)

## Script Args Schema

```json
{
  "type": "object",
  "properties": {
    "event_type": {
      "type": "string",
      "enum": ["vol_up", "vol_down", "mute"]
    },
    "event_key": {
      "type": "string",
      "description": "click | hold | toggle (informational, not required)"
    },
    "delta": {
      "type": ["integer", "number"],
      "default": 10,
      "minimum": 1,
      "maximum": 100
    },
    "delta_str": {
      "type": "string",
      "description": "Accepted as an alternative to delta since router templates render values as strings."
    }
  },
  "required": ["event_type"]
}
```

## Behavior

- `vol_up`: read current volume from `/ramfs/network_radio/status.json`, add `delta` (clamped 0-100), call `network_radio` control with `action=volume`.
- `vol_down`: same, subtract `delta`.
- `mute`: if current volume > 0, save it to `<data_root>/board_button_volume_mute.json` and set volume to 0. If already muted (volume = 0), restore the saved volume (or 70 as fallback).
- If the network_radio daemon is not running (state absent, `stopped`, or `ended`), the script logs and returns without error.
- If the computed new volume equals the current volume, the script skips the update.

## Router Rules (install once)

Install this single rule to route every board_button event to the script:

```json
{
  "id": "board_button_volume_apply",
  "description": "Route physical volume buttons to the network_radio volume control.",
  "enabled": true,
  "consume_on_match": true,
  "ack": "board_button {{event.event_type}}/{{event.event_key}}",
  "match": {
    "source_cap": "board_button"
  },
  "actions": [
    {
      "type": "run_script",
      "input": {
        "path": "/fatfs/skills/board_button_volume/scripts/apply_volume_delta.lua",
        "args": {
          "event_type": "{{event.event_type}}",
          "event_key": "{{event.event_key}}",
          "delta_str": "{{event.payload.delta}}"
        },
        "timeout_ms": 4000
      }
    }
  ]
}
```

Install with the `router_add_rule` capability (or the console's router editor). Verify with `router_list_rules`.

## Manual Test

Trigger the script directly to verify network_radio integration without touching the physical buttons:

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/apply_volume_delta.lua",
  "args": {
    "event_type": "vol_down",
    "delta": 20
  },
  "timeout_ms": 4000
}
```

## Future

When adding a global master-volume path that affects TTS and other audio outputs (not just network_radio), extend this script to branch on active audio source, or add a sibling script and update the router rule. The firmware-side event contract stays the same.
