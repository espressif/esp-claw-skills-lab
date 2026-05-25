---
{
  "name": "unihiker_expansion_servo_control",
  "description": "Control 180° or 360° servos on a DFRobot UNIHIKER Expansion board over I2C. Requires the expansion board to be connected.",
  "author": "YeezB",
  "metadata":
    {
      "category": ["sensor"],
      "tags": ["unihiker", "dfrobot", "expansion board", "i2c"],
      "peripherals": ["servo"],
      "cap_groups": ["cap_lua"],
      "manage_mode": "web"
    }
}
---

# UNIHIKER Expansion Servo Control

Use this skill when the user asks to set the angle of a 180° servo or set the direction/speed of a 360° servo on a DFRobot UNIHIKER Expansion board (SKU: DFR1216). Chinese name is 行空板扩展板.

Run exactly one bundled Lua script with `lua_run_script`.

If script execution returns an error, report that error directly to the user.
Do not retry with changed arguments in the same turn unless the user explicitly asks.

## Script Args Schema

```json
{
  "type": "object",
  "properties": {
    "mode": {
      "type": "string",
      "enum": ["angle", "servo360"]
    },
    "servo": {
      "type": "integer",
      "minimum": 0,
      "maximum": 5
    },
    "angle": {
      "type": "integer",
      "minimum": 0,
      "maximum": 180
    },
    "direction": {
      "type": "string",
      "enum": ["forward", "backward", "stop"]
    },
    "speed": {
      "type": "integer",
      "minimum": 0,
      "maximum": 100
    },
    "duration_ms": {
      "type": "integer",
      "minimum": 0
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
  },
  "required": ["mode", "servo"]
}
```

## Tool Call Inputs

Set a 180° servo to 90°:

```json
{"path":"{CUR_SKILL_DIR}/scripts/set_servo.lua","args":{"mode":"angle","servo":0,"angle":90}}
```

Set a 360° servo to forward at speed 50:

```json
{"path":"{CUR_SKILL_DIR}/scripts/set_servo.lua","args":{"mode":"servo360","servo":1,"direction":"forward","speed":50}}
```

Stop a 360° servo:

```json
{"path":"{CUR_SKILL_DIR}/scripts/set_servo.lua","args":{"mode":"servo360","servo":1,"direction":"stop","speed":0}}
```

Run a 360° servo for 2 seconds and then stop:

```json
{"path":"{CUR_SKILL_DIR}/scripts/set_servo.lua","args":{"mode":"servo360","servo":2,"direction":"backward","speed":30,"duration_ms":2000}}
```

## Recommended Flow

1. Confirm the expansion board is connected to the expected I2C bus.
2. Use the default UNIHIKER expansion board I2C settings unless the user explicitly provides custom wiring or address values.
3. Choose `mode = "angle"` for 180° servos and `mode = "servo360"` for 360° servos.
4. Run `{CUR_SKILL_DIR}/scripts/set_servo.lua` with the resolved servo number and motion parameters.
5. Report the script output directly to the user, including any error.
