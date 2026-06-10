---
{
  "name": "unihiker_button",
  "description": "Read UNIHIKER K10 A/B buttons connected through XL9535 (I2C address 0x20). Supports event-wait style calls to avoid missing short presses.",
  "author": "YeezB",
  "metadata":
    {
      "category": ["hardware"],
      "tags": ["unihiker", "k10", "xl9535", "i2c", "interrupt-like"],
      "peripherals": ["button"],
      "cap_groups": ["cap_lua"],
      "manage_mode": "web"
    }
}
---

# UNIHIKER Button (XL9535)

Use this skill when the user asks to read UNIHIKER K10 A/B button status, wait for button press, or detect button events from the XL9535 IO expander.

Typical user requests include:

- 当按下 UNIHIKER / 行空板 K10 的 A 键后，执行 xxx
- 当按下 UNIHIKER / 行空板 K10 的 B 键后，执行 xxx
- 监听行空板 K10 的 A/B 按键事件
- 等待 A 键按下再继续执行
- 等待 B 键释放后执行下一步

Chinese aliases that should map to this skill include: 行空板 K10 按键、A 键、B 键、按键中断、按键事件监听。

Hardware mapping for this skill:

- XL9535 I2C address: `0x20`
- B button: `P02`
- A button: `P14`

The script provides two main modes:

- `read`: read current A/B button state once.
- `wait_event`: block until button edge event (press/release) is detected, which is better than sparse app-side polling.

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
      "enum": ["read", "wait_event"]
    },
    "target": {
      "type": "string",
      "enum": ["a", "b", "any"]
    },
    "edge": {
      "type": "string",
      "enum": ["press", "release", "any"]
    },
    "active_level": {
      "type": "integer",
      "minimum": 0,
      "maximum": 1
    },
    "timeout_ms": {
      "type": "integer",
      "minimum": 0,
      "maximum": 120000
    },
    "poll_interval_ms": {
      "type": "integer",
      "minimum": 1,
      "maximum": 100
    },
    "debounce_ms": {
      "type": "integer",
      "minimum": 0,
      "maximum": 100
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

Read current A/B button states once:

```json
{"path":"{CUR_SKILL_DIR}/scripts/unihiker_button.lua","args":{"mode":"read"}}
```

Wait up to 10 seconds for any button press/release event:

```json
{"path":"{CUR_SKILL_DIR}/scripts/unihiker_button.lua","args":{"mode":"wait_event","target":"any","edge":"any","timeout_ms":10000}}
```

Wait only for A button press:

```json
{"path":"{CUR_SKILL_DIR}/scripts/unihiker_button.lua","args":{"mode":"wait_event","target":"a","edge":"press","timeout_ms":10000}}
```

## Recommended Flow

1. Confirm XL9535 is connected on the expected I2C bus and address (`0x20` by default).
2. For reactive logic, prefer `wait_event` instead of periodic app-side polling.
3. Use small `poll_interval_ms` (for example `1` to `5`) and suitable `debounce_ms` (for example `8` to `20`) for stable button events.
4. Run `{CUR_SKILL_DIR}/scripts/unihiker_button.lua`.
5. Report script output directly to the user.
