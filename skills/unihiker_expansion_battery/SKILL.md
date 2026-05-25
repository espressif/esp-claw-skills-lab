---
{
  "name": "unihiker_expansion_battery",
  "description": "Read battery percentage from a DFRobot UNIHIKER Expansion board over I2C. Requires the expansion board to be connected.",
  "author": "YeezB",
  "metadata":
    {
      "category": ["sensor"],
      "tags": ["unihiker", "dfrobot", "expansion board", "i2c"],
      "peripherals": ["battery"],
      "cap_groups": ["cap_lua"],
      "manage_mode": "web"
    }
}
---

# UNIHIKER Expansion Battery

Use this skill when the user asks to read battery percentage from a DFRobot UNIHIKER Expansion board (SKU: DFR1216). Chinese name is 行空板扩展板.

Run exactly one bundled Lua script with `lua_run_script`.

If script execution returns an error, report that error directly to the user.
Do not retry with changed arguments in the same turn unless the user explicitly asks.

## Script Args Schema

```json
{
  "type": "object",
  "properties": {
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
    },
    "retry_count": {
      "type": "integer",
      "minimum": 1,
      "maximum": 20
    },
    "retry_delay_ms": {
      "type": "integer",
      "minimum": 0,
      "maximum": 1000
    }
  }
}
```

## Tool Call Inputs

Read battery with default wiring:

```json
{"path":"{CUR_SKILL_DIR}/scripts/get_battery.lua","args":{}}
```

Read battery with custom I2C pins:

```json
{"path":"{CUR_SKILL_DIR}/scripts/get_battery.lua","args":{"i2c_port":0,"sda":47,"scl":48,"i2c_freq_hz":400000,"addr":51}}
```

## Recommended Flow

1. Confirm the expansion board is connected to the expected I2C bus.
2. Use default I2C settings unless the user explicitly provides custom wiring.
3. Run `{CUR_SKILL_DIR}/scripts/get_battery.lua`.
4. Report the script output directly to the user, including any error.