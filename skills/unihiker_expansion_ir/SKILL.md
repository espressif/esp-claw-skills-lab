---
{
  "name": "unihiker_expansion_ir",
  "description": "Send and receive IR data on a DFRobot UNIHIKER Expansion board over I2C. Requires the expansion board to be connected.",
  "author": "YeezB",
  "metadata":
    {
      "category": ["sensor"],
      "tags": ["infrared", "unihiker", "dfrobot", "expansion board", "i2c"],
      "peripherals": ["ir"],
      "cap_groups": ["cap_lua"],
      "manage_mode": "web"
    }
}
---

# UNIHIKER Expansion IR

Use this skill when the user asks to send IR code, read IR code, or self-send and self-receive IR data on a DFRobot UNIHIKER Expansion board (SKU: DFR1216). Chinese name is 行空板扩展板.

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
      "enum": ["send", "get", "send_get"]
    },
    "data": {
      "type": "integer",
      "minimum": 0,
      "maximum": 4294967295
    },
    "timeout_ms": {
      "type": "integer",
      "minimum": 0,
      "maximum": 60000
    },
    "poll_interval_ms": {
      "type": "integer",
      "minimum": 10,
      "maximum": 5000
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

Send one IR code only:

```json
{"path":"{CUR_SKILL_DIR}/scripts/ir_send_get.lua","args":{"mode":"send","data":305419896}}
```

Read one IR code only:

```json
{"path":"{CUR_SKILL_DIR}/scripts/ir_send_get.lua","args":{"mode":"get","timeout_ms":2000,"poll_interval_ms":100}}
```

Self-send and self-receive in one call:

```json
{"path":"{CUR_SKILL_DIR}/scripts/ir_send_get.lua","args":{"mode":"send_get","data":305419896,"timeout_ms":2000,"poll_interval_ms":100}}
```

## Recommended Flow

1. Confirm the expansion board is connected to the expected I2C bus.
2. Use default I2C settings unless the user explicitly provides custom wiring.
3. Use `mode = "send_get"` when user asks for self-send/self-receive in one operation.
4. Run `{CUR_SKILL_DIR}/scripts/ir_send_get.lua` with resolved args.
5. Report script output directly to the user, including any error.
