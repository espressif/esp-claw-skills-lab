---
{
  "name": "unihiker_expansion_motor_control",
  "description": "Control DFRobot UNIHIKER Expansion board(DFR1261) motors over I2C.",
  "author": "YeezB",
  "metadata":
    {
      "category": ["sensor"],
      "tags": ["unihiker", "dfrobot", "expansion board"],
      "peripherals": ["motor"],
      "cap_groups": ["cap_lua"],
      "manage_mode": "web"
    }
}
---

# UNIHIKER Expansion Motor Control

Use this skill to control motors on a DFRobot UNIHIKER Expansion board (SKU: DFR1216). Chinese name is 行空板扩展板.

Run exactly one script with `lua_run_script`.

If `lua_run_script` returns an error, report that error directly to the user.
Do not retry with changed arguments in the same turn unless the user explicitly asks.

## Tool Call Inputs

Stop all motors:

```json
{"path":"{CUR_SKILL_DIR}/scripts/set_motor.lua","args":{"stop_all":true}}
```

Drive motor1 forward:

```json
{"path":"{CUR_SKILL_DIR}/scripts/set_motor.lua","args":{"period_12":255,"duty":{"m1_a":255,"m1_b":0}}}
```

Drive motor1 reverse:

```json
{"path":"{CUR_SKILL_DIR}/scripts/set_motor.lua","args":{"period_12":255,"duty":{"m1_a":0,"m1_b":255}}}
```

Drive four motors with mixed duty values:

```json
{"path":"{CUR_SKILL_DIR}/scripts/set_motor.lua","args":{"period_12":255,"period_34":255,"duty":{"m1_a":255,"m1_b":0,"m2_a":0,"m2_b":255,"m3_a":50,"m3_b":0,"m4_a":0,"m4_b":50}}}
```

Drive motor1 forward for 2 seconds, then auto stop:

```json
{"path":"{CUR_SKILL_DIR}/scripts/set_motor.lua","args":{"period_12":255,"auto_stop_ms":2000,"duty":{"m1_a":255,"m1_b":0}}}
```

Notes:
- `auto_stop_ms` is optional. Default is `0` (no timer stop).
- When `auto_stop_ms > 0`, the script waits that many milliseconds and then writes all motor duty channels to `0`.

## Recommended Flow

1. Confirm the expansion board is connected to an available I2C bus.
2. Use the script defaults unless the user explicitly provides custom I2C settings.
3. Run `{CUR_SKILL_DIR}/scripts/set_motor.lua` with desired `period_12`, `period_34`, and `duty`.
4. If immediate emergency stop is needed, run the script with `stop_all: true`.
5. Report script output directly to the user, including any error.
