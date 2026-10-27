---
{
  "name": "as7341_i2c",
  "author": "KKChung <quasite@gmail.com>",
  "description": "Detect and read ams OSRAM AS7341 11-channel multi-spectral color sensor data over I2C (F1-F8, Clear, NIR). Use this skill when the user asks in Chinese or English to read AS7341 color/spectral data, such as 读取AS7341颜色/光谱数据、读一下AS7341?AS7341 spectral channels?read AS7341 F1-F8 Clear NIR, measure color with AS7341. Default I2C address 0x39.",
  "metadata": {
    "category": ["sensor"],
    "tags": ["as7341", "i2c", "color", "spectral", "multispectral", "nir", "ams", "osram"],
    "peripherals": [],
    "cap_groups": ["cap_lua"]
  }
}
---

# as7341_i2c

Use this skill when the user asks to detect or read the ams OSRAM **AS7341** 11-channel multi-spectral / color sensor over I2C.

Typical Chinese requests:

- 帮我读取一下 AS7341 的颜色 / 光谱数据
- 读一下 AS7341 的 F1-F8 / Clear / NIR
- 检测 AS7341 是否在线
- AS7341 测一下当前光谱

Typical English requests:

- Read AS7341 spectral / color channels
- Check AS7341 chip ID / probe AS7341
- Measure F1-F8, Clear, and NIR with AS7341
- Read AS7341 at I2C address 0x39

Default device assumptions:

- I2C address `0x39`
- Chip ID register `0x92` expected pattern `(id & 0xFC) == 0x24` (WHOAMI `0x09`)
- One sample returns spectral channels **F1-F8**, **Clear**, and **NIR** (raw ADC counts)
- Recommended integration defaults from datasheet DS000504: `ATIME=29`, `ASTEP=599` (~50 ms), gain `64x`
- Default bus pins follow other ESP-Claw I2C sensor skills: `i2c_port=0`, `sda=47`, `scl=48`, `400 kHz`

Hardware notes (from AS7341 datasheet):

- 8 visible bands (F1~415 nm ... F8~680 nm) + Clear + NIR; only 6 ADCs, so two SMUX passes are required
- Integration time: `(ATIME + 1) x (ASTEP + 1) x 2.78 us`
- Do not set both ATIME and ASTEP to 0

Run exactly one bundled Lua script with `lua_run_script`.

If script execution returns an error, report that error directly to the user.
Do not retry with changed arguments in the same turn unless the user explicitly asks.

## Script Args Schema

```json
{
  "type": "object",
  "properties": {
    "action": {
      "type": "string",
      "enum": ["read", "probe"]
    },
    "i2c_port": { "type": "integer", "minimum": 0, "maximum": 1 },
    "sda": { "type": "integer", "minimum": 0, "maximum": 63 },
    "scl": { "type": "integer", "minimum": 0, "maximum": 63 },
    "i2c_freq_hz": { "type": "integer", "minimum": 10000, "maximum": 1000000 },
    "addr": { "type": "integer", "minimum": 8, "maximum": 119 },
    "atime": { "type": "integer", "minimum": 0, "maximum": 255 },
    "astep": { "type": "integer", "minimum": 0, "maximum": 65534 },
    "gain": { "type": "integer", "minimum": 0, "maximum": 10 },
    "timeout_ms": { "type": "integer", "minimum": 50, "maximum": 5000 },
    "poll_interval_ms": { "type": "integer", "minimum": 1, "maximum": 50 }
  }
}
```

`gain` maps to CFG1 AGAIN: `0=0.5x`, `1=1x`, `2=2x`, `3=4x`, `4=8x`, `5=16x`, `6=32x`, `7=64x`, `8=128x`, `9=256x`, `10=512x`.

## Tool Call Inputs

Read one full spectral sample with defaults:

```json
{"path":"{CUR_SKILL_DIR}/scripts/read_sensor_data.lua","args":{"action":"read"}}
```

Probe / detect the sensor only:

```json
{"path":"{CUR_SKILL_DIR}/scripts/read_sensor_data.lua","args":{"action":"probe"}}
```

Custom I2C wiring and higher gain:

```json
{"path":"{CUR_SKILL_DIR}/scripts/read_sensor_data.lua","args":{"action":"read","i2c_port":0,"sda":47,"scl":48,"i2c_freq_hz":400000,"addr":57,"gain":9,"atime":29,"astep":599}}
```

## Recommended Flow

1. Confirm AS7341 wiring (3.3 V, GND, SDA, SCL) and I2C address.
2. If the user does not provide an address, use default `0x39`.
3. For "检测 / probe / is it connected", run with `action = "probe"`.
4. For "读取颜色 / 光谱数据", run with `action = "read"` (default).
5. Report script output directly (human-readable line + JSON).

## Output Fields (read)

| Field | Meaning |
| --- | --- |
| `f1` ... `f8` | Visible spectral channels (nm centers ~ 415 / 445 / 480 / 515 / 555 / 590 / 630 / 680) |
| `clear` | Clear / unfiltered channel |
| `nir` | Near-infrared channel |
| `atime` / `astep` / `gain` / `tint_ms` | Timing and gain used for the sample |
| `addr` | 7-bit I2C address |
