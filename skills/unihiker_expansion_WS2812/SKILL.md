---
{
  "name": "unihiker_expansion_WS2812",
  "description": "Set WS2812 RGB LEDs on the DFRobot UNIHIKER Expansion board over I2C. This skill controls expansion-board LEDs only, not the UNIHIKER mainboard RGB.",
  "author": "YeezB",
  "metadata":
    {
      "category": ["sensor"],
      "tags": ["rgb", "unihiker", "dfrobot", "expansion board", "i2c"],
      "peripherals": ["ws2812", "led"],
      "cap_groups": ["cap_lua"],
      "manage_mode": "web"
    }
}
---

# UNIHIKER Expansion WS2812

Use this skill when the user asks to set WS2812 or RGB LEDs on a DFRobot UNIHIKER Expansion board (SKU: DFR1216). Chinese name is 行空板扩展板.

This skill controls the two WS2812 LEDs on the UNIHIKER Expansion board only.
Do not use this skill for the UNIHIKER mainboard built-in RGB LED.

Run exactly one bundled Lua script with `lua_run_script`.

If script execution returns an error, report that error directly to the user.
Do not retry with changed arguments in the same turn unless the user explicitly asks.

## Script Args Schema

```json
{
  "type": "object",
  "properties": {
    "bright": {
      "type": "integer",
      "minimum": 0,
      "maximum": 255
    },
    "rgb0": {
      "type": "integer",
      "minimum": 0,
      "maximum": 16777215
    },
    "rgb1": {
      "type": "integer",
      "minimum": 0,
      "maximum": 16777215
    },
    "color": {
      "type": "integer",
      "minimum": 0,
      "maximum": 16777215
    },
    "i2c_port": {
      "type": "integer",
      "minimum": 0,
      "maximum": 1
    },
    "sda": {
      "type": "integer",
      "minimum": 0,
      "maximum": 63
    },
    "scl": {
      "type": "integer",
      "minimum": 0,
      "maximum": 63
    },
    "i2c_freq_hz": {
      "type": "integer",
      "minimum": 10000,
      "maximum": 1000000
    },
    "addr": {
      "type": "integer",
      "minimum": 8,
      "maximum": 119
    }
  }
}
```

## Tool Call Inputs

Set both expansion-board WS2812 LEDs to magenta:

```json
{"path":"{CUR_SKILL_DIR}/scripts/set_ws2812.lua","args":{"bright":30,"color":16711935}}
```

Set RGB0 to red and RGB1 to blue:

```json
{"path":"{CUR_SKILL_DIR}/scripts/set_ws2812.lua","args":{"bright":10,"rgb0":16711680,"rgb1":255}}
```

Set RGB0 yellow and RGB1 magenta at higher brightness:

```json
{"path":"{CUR_SKILL_DIR}/scripts/set_ws2812.lua","args":{"bright":100,"rgb0":16776960,"rgb1":16711935}}
```

Turn off both expansion-board WS2812 LEDs:

```json
{"path":"{CUR_SKILL_DIR}/scripts/set_ws2812.lua","args":{"bright":0,"color":0}}
```

## Recommended Flow

1. Confirm the target is the UNIHIKER Expansion board WS2812 LEDs, not the UNIHIKER mainboard RGB LED.
2. Use default I2C settings unless the user explicitly provides custom wiring.
3. If the user gives one color for RGB灯, use `color` to set both LEDs.
4. Otherwise set `rgb0` and `rgb1` independently.
5. Run `{CUR_SKILL_DIR}/scripts/set_ws2812.lua` and report result or error directly.
