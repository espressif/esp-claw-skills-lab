---
{
  "name": "dfrobot_matrix_lidar_8x8_i2c",
  "description": "Read 8x8 radar or TOF distance data from a DFRobot MatrixLidar sensor over I2C. Use this when the user asks to read DFRobot matrix lidar data, 8x8 matrix laser radar data, 8x8 TOF data, or says 读取/读一下矩阵雷达数据、8x8雷达数据、激光测距数据. Supports I2C address 0x33 by default.",
  "author": "YeezB",
  "metadata":
    {
      "category": ["sensor"],
      "tags": ["tof", "8x8", "dfrobot", "i2c", "distance"],
      "peripherals": ["matrix_lidar"],
      "cap_groups": ["cap_lua"],
      "manage_mode": "web"
    }
}
---

# DFRobot MatrixLidar 8x8 I2C

Use this skill when the user asks to read data from a DFRobot MatrixLidar, DFRobot matrix radar, 8x8 matrix lidar, 8x8 TOF sensor, or 8x8 matrix laser radar connected over I2C.

Typical user requests include:

- 读一下 DFRobot 矩阵雷达的数据
- 读取 8x8 雷达数据
- 读取 8x8 矩阵激光雷达数据
- 读取 TOF 激光测距矩阵数据
- I2C 地址是 0x33，帮我读一下矩阵雷达

Chinese aliases that should map to this skill include: 矩阵雷达、8x8 雷达、8x8 矩阵激光雷达、TOF 矩阵测距、激光测距矩阵。

Default device assumptions:

- I2C address defaults to `0x33`
- Reads one 8x8 frame of distance values in mm
- Intended for an externally connected DFRobot MatrixLidar sensor on UNIHIKER

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
    },
    "packet_timeout_ms": {
      "type": "integer",
      "minimum": 100,
      "maximum": 20000
    },
    "poll_interval_ms": {
      "type": "integer",
      "minimum": 1,
      "maximum": 200
    }
  }
}
```

## Tool Call Inputs

Read one 8x8 frame with default I2C settings:

```json
{"path":"{CUR_SKILL_DIR}/scripts/get_8x8_data.lua","args":{}}
```

Read one 8x8 frame with custom I2C settings:

```json
{"path":"{CUR_SKILL_DIR}/scripts/get_8x8_data.lua","args":{"i2c_port":0,"sda":47,"scl":48,"i2c_freq_hz":400000,"addr":51}}
```

## Recommended Flow

1. Confirm the MatrixLidar sensor is connected to the expected I2C bus and address.
2. If the user says only "读一下矩阵雷达数据" and does not provide wiring, assume default I2C settings and default address `0x33`.
3. Run `{CUR_SKILL_DIR}/scripts/get_8x8_data.lua`.
4. Report the returned matrix data directly to the user.
