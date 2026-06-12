---
{
  "name": "network_radio",
  "description": "Play, switch, adjust volume, query status, or stop Qingting network radio stations through the board audio output.",
  "author": "ESP-Claw contributor",
  "metadata":
    {
      "category": ["media", "network"],
      "tags": ["audio", "radio", "music", "qingting"],
      "peripherals": ["speaker"],
      "cap_groups": ["cap_lua"],
      "manage_mode": "web"
    }
}
---

# Network Radio

Use this skill when the user asks to play, switch, adjust volume, query status, or stop a network radio station.

Always call the synchronous control script. It starts and controls a background radio player daemon when needed. Do not call the daemon script directly.

The radio uses the board audio output named `audio_dac` by default.

## Available Stations

- 崂山921
- 长沙101.7城市之声
- 上海经典947
- 湖北经典音乐广播
- 成都年代音乐怀旧好声音
- 山东经典音乐广播
- 杭州90.7
- 天津TIKI 100.5

## Control Args Schema

```json
{
  "type": "object",
  "properties": {
    "action": {
      "type": "string",
      "enum": ["play", "switch", "volume", "stop", "status"],
      "default": "status"
    },
    "station": {
      "type": "string",
      "description": "Station title or a distinctive title fragment. Use one of the available station names unless the user provides a direct URL."
    },
    "url": {
      "type": "string",
      "description": "Optional direct http or https MP3 stream URL. If set, it overrides station."
    },
    "title": {
      "type": "string",
      "description": "Display title used when url is provided directly."
    },
    "volume": {
      "type": "integer",
      "minimum": 0,
      "maximum": 100
    },
    "codec_name": {
      "type": "string",
      "default": "audio_dac",
      "description": "Board manager audio output codec name."
    },
    "wait_ms": {
      "type": "integer",
      "default": 8000,
      "minimum": 1000
    }
  },
  "required": ["action"]
}
```

## Tool Call Inputs

Play 上海经典947:

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/control_network_radio.lua",
  "args": {
    "action": "play",
    "station": "上海经典947",
    "volume": 70
  },
  "timeout_ms": 12000
}
```

Switch to 杭州90.7 without changing volume:

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/control_network_radio.lua",
  "args": {
    "action": "switch",
    "station": "杭州90.7"
  },
  "timeout_ms": 12000
}
```

Set volume to 35 without restarting playback:

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/control_network_radio.lua",
  "args": {
    "action": "volume",
    "volume": 35
  },
  "timeout_ms": 12000
}
```

Play a direct stream URL:

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/control_network_radio.lua",
  "args": {
    "action": "play",
    "title": "自定义电台",
    "url": "http://example.com/live.mp3",
    "volume": 70
  },
  "timeout_ms": 12000
}
```

Query current status:

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/control_network_radio.lua",
  "args": {
    "action": "status"
  },
  "timeout_ms": 12000
}
```

Stop the radio:

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/control_network_radio.lua",
  "args": {
    "action": "stop"
  },
  "timeout_ms": 12000
}
```

## Behavior

- `play` starts the background daemon when needed, opens `audio_dac`, and plays the selected station.
- `switch` reuses the daemon, stops the current stream, and starts the new station.
- `volume` calls `output:set_volume()` in the daemon and does not restart playback.
- `status` reads the last daemon status and does not start playback.
- `stop` sends a stop command to the daemon; the daemon stops playback, closes audio resources, records the radio as stopped, and exits.
- The daemon job name is `network_radio_player` and its exclusive group is `audio_output`.
- Runtime commands use `thread.sync` queues named `network_radio_cmd` and `network_radio_reply`; the last status snapshot is stored in RAMFS under `/ramfs/network_radio/status.json`.

## Recommended Flow

1. For play or switch requests, choose the closest station from `Available Stations`.
2. If no close match exists and the user did not provide a URL, ask the user to choose a station.
3. Always run `{CUR_SKILL_DIR}/scripts/control_network_radio.lua` with `lua_run_script` and `timeout_ms: 12000`.
4. Use `action: "play"` when starting radio from idle or when the user simply says to play a station.
5. Use `action: "switch"` when the user asks to change station while radio may already be playing.
6. Use `action: "volume"` when the user asks to set, raise, lower, or adjust volume. Pass an absolute `volume` value from 0 to 100.
7. Use `action: "status"` when the user asks what is playing or current volume.
8. Use `action: "stop"` when the user asks to stop, pause, cancel, quit, close, or turn off the radio.
9. Report the script output directly. If the script returns an error, report that error directly to the user.
