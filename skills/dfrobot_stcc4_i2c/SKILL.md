---
{
  "name": "dfrobot_stcc4_i2c",
  "description": "Detect and read Sensirion STCC4 CO2 concentration over I2C, and also return temperature and humidity. Use this skill when user asks in Chinese or English for STCC4 CO2 check, CO2 ppm reading, air quality check, or temperature/humidity from STCC4, such as 检测STCC4的CO2浓度、读取STCC4二氧化碳浓度、读取空气质量、read STCC4 CO2 concentration, check CO2 ppm, measure STCC4 air quality.",
  "author": "YeezB",
  "metadata": {
    "category": ["sensor"],
    "tags": ["dfrobot", "i2c", "co2", "sensirion", "temperature", "humidity", "air quality"],
    "peripherals": ["stcc4"],
    "cap_groups": ["cap_lua"],
    "manage_mode": "web"
  }
}
---

# dfrobot_stcc4_i2c

Use this skill when the user asks to detect or read Sensirion STCC4 CO2 concentration (ppm). This sensor readout also includes temperature and humidity.

Typical Chinese requests:

- 帮我检测一下 STCC4 的 CO2 浓度
- 读取 STCC4 的二氧化碳浓度
- 看一下 STCC4 的空气质量
- 读取 STCC4 的温湿度和 CO2

Typical English requests:

- Check STCC4 CO2 concentration
- Read STCC4 CO2 ppm
- Measure air quality with STCC4
- Read STCC4 CO2, temperature, and humidity

Run exactly one bundled Lua script with `lua_run_script`.

## Script Args Schema

```json
{
  "type": "object",
  "properties": {
    "action": {
      "type": "string",
      "enum": ["read", "start", "stop"]
    },
    "i2c_port": { "type": "integer", "minimum": 0, "maximum": 1 },
    "sda": { "type": "integer", "minimum": 0, "maximum": 63 },
    "scl": { "type": "integer", "minimum": 0, "maximum": 63 },
    "i2c_freq_hz": { "type": "integer", "minimum": 10000, "maximum": 1000000 },
    "addr": { "type": "integer", "minimum": 8, "maximum": 119 },
    "start_if_needed": { "type": "boolean" },
    "wait_after_start_ms": { "type": "integer", "minimum": 0, "maximum": 5000 },
    "verify_crc": { "type": "boolean" }
  }
}
```

## Tool Call Inputs

```json
{"path":"{CUR_SKILL_DIR}/scripts/read_sensor_data.lua","args":{"action":"read"}}
```

Use explicit address `0x64` and CRC verification:

```json
{"path":"{CUR_SKILL_DIR}/scripts/read_sensor_data.lua","args":{"action":"read","addr":100,"verify_crc":true}}
```

Start continuous measurement only:

```json
{"path":"{CUR_SKILL_DIR}/scripts/read_sensor_data.lua","args":{"action":"start"}}
```

Stop continuous measurement only:

```json
{"path":"{CUR_SKILL_DIR}/scripts/read_sensor_data.lua","args":{"action":"stop"}}
```

## Recommended Flow

1. Confirm sensor wiring and I2C address.
2. If user does not provide address, use STCC4 default address `0x64`.
3. Run `{CUR_SKILL_DIR}/scripts/read_sensor_data.lua` with `action = "read"` to get one sample.
4. Use `start` and `stop` actions only when user explicitly asks to control measurement state.
5. Report script output directly.
