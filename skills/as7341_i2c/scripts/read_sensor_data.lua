local i2c = require("i2c")
local delay = require("delay")

-- AS7341 (ams OSRAM) — DS000504
local DEFAULT_I2C_PORT = 0
local DEFAULT_SDA = 47
local DEFAULT_SCL = 48
local DEFAULT_I2C_FREQ_HZ = 400000
local DEFAULT_ADDR = 0x39

local REG_ENABLE = 0x80
local REG_ATIME = 0x81
local REG_ID = 0x92
local REG_CH0_DATA_L = 0x95
local REG_STATUS2 = 0xA3
local REG_CFG0 = 0xA9
local REG_CFG1 = 0xAA
local REG_CFG6 = 0xAF
local REG_ASTEP_L = 0xCA
local REG_ASTEP_H = 0xCB

local ENABLE_PON = 0x01
local ENABLE_SP_EN = 0x02
local ENABLE_SMUXEN = 0x10

local STATUS2_AVALID = 0x40
local CFG0_REG_BANK = 0x10
local CFG6_SMUX_WRITE = 0x10

local CHIP_ID = 0x09

local DEFAULT_ACTION = "read"
-- Datasheet recommended: ATIME=29, ASTEP=599 ? ~50 ms
local DEFAULT_ATIME = 29
local DEFAULT_ASTEP = 599
local DEFAULT_GAIN = 7 -- 64x
local DEFAULT_TIMEOUT_MS = 500
local DEFAULT_POLL_INTERVAL_MS = 2

local GAIN_LABELS = {
  [0] = "0.5x",
  [1] = "1x",
  [2] = "2x",
  [3] = "4x",
  [4] = "8x",
  [5] = "16x",
  [6] = "32x",
  [7] = "64x",
  [8] = "128x",
  [9] = "256x",
  [10] = "512x",
}

-- SMUX: F1–F4 + Clear + NIR (Adafruit / ams example mapping)
local SMUX_F1F4_CLEAR_NIR = {
  0x30, 0x01, 0x00, 0x00, 0x00, 0x42, 0x00, 0x00, 0x50, 0x00,
  0x00, 0x00, 0x20, 0x04, 0x00, 0x30, 0x01, 0x50, 0x00, 0x06,
}

-- SMUX: F5–F8 + Clear + NIR
local SMUX_F5F8_CLEAR_NIR = {
  0x00, 0x00, 0x00, 0x40, 0x02, 0x00, 0x10, 0x03, 0x50, 0x10,
  0x03, 0x00, 0x00, 0x00, 0x24, 0x00, 0x00, 0x50, 0x00, 0x06,
}

local function read_arg(name, default)
  if type(args) == "table" and args[name] ~= nil then
    return args[name]
  end
  return default
end

local function parse_int_arg(name, default, min_value, max_value)
  local value = read_arg(name, default)
  if type(value) ~= "number" or value % 1 ~= 0 then
    error(name .. " must be an integer")
  end
  if min_value ~= nil and value < min_value then
    error(string.format("%s must be >= %d", name, min_value))
  end
  if max_value ~= nil and value > max_value then
    error(string.format("%s must be <= %d", name, max_value))
  end
  return value
end

local function parse_action_arg()
  local value = read_arg("action", DEFAULT_ACTION)
  if type(value) ~= "string" then
    error("action must be a string")
  end
  if value ~= "read" and value ~= "probe" then
    error("action must be one of: read, probe")
  end
  return value
end

local function cleanup(dev, bus)
  if dev then
    pcall(function()
      dev:close()
    end)
  end
  if bus then
    pcall(function()
      bus:close()
    end)
  end
end

local function write_reg(dev, reg, value)
  dev:write({ value % 256 }, reg)
end

local function read_reg(dev, reg)
  local frame = dev:read(1, reg)
  if type(frame) ~= "string" or #frame < 1 then
    error(string.format("failed to read register 0x%02X", reg))
  end
  return string.byte(frame, 1)
end

local function modify_reg(dev, reg, set_mask, clear_mask)
  local value = read_reg(dev, reg)
  value = ((value | set_mask) & (~clear_mask)) & 0xFF
  write_reg(dev, reg, value)
end

local function set_reg_bank(dev, low_bank)
  -- REG_BANK=1 selects registers 0x60–0x74; keep 0 for normal spectral regs.
  if low_bank then
    modify_reg(dev, REG_CFG0, CFG0_REG_BANK, 0)
  else
    modify_reg(dev, REG_CFG0, 0, CFG0_REG_BANK)
  end
end

local function power_enable(dev, on)
  if on then
    modify_reg(dev, REG_ENABLE, ENABLE_PON, 0)
  else
    modify_reg(dev, REG_ENABLE, 0, ENABLE_PON)
  end
end

local function spectral_enable(dev, on)
  if on then
    modify_reg(dev, REG_ENABLE, ENABLE_SP_EN, 0)
  else
    modify_reg(dev, REG_ENABLE, 0, ENABLE_SP_EN)
  end
end

local function wait_smux_done(dev, timeout_ms, poll_interval_ms)
  local waited = 0
  while waited <= timeout_ms do
    local enable = read_reg(dev, REG_ENABLE)
    if (enable & ENABLE_SMUXEN) == 0 then
      return
    end
    delay.delay_ms(poll_interval_ms)
    waited = waited + poll_interval_ms
  end
  error("timeout waiting for SMUX command to finish")
end

local function enable_smux(dev, timeout_ms, poll_interval_ms)
  modify_reg(dev, REG_ENABLE, ENABLE_SMUXEN, 0)
  wait_smux_done(dev, timeout_ms, poll_interval_ms)
end

local function write_smux_config(dev, config)
  write_reg(dev, REG_CFG6, CFG6_SMUX_WRITE)
  for i = 1, #config do
    write_reg(dev, i - 1, config[i])
  end
end

local function configure_smux(dev, config, timeout_ms, poll_interval_ms)
  spectral_enable(dev, false)
  write_smux_config(dev, config)
  enable_smux(dev, timeout_ms, poll_interval_ms)
end

local function wait_data_ready(dev, timeout_ms, poll_interval_ms)
  local waited = 0
  while waited <= timeout_ms do
    local status2 = read_reg(dev, REG_STATUS2)
    if (status2 & STATUS2_AVALID) ~= 0 then
      return status2
    end
    delay.delay_ms(poll_interval_ms)
    waited = waited + poll_interval_ms
  end
  error("timeout waiting for spectral data ready (STATUS2.AVALID)")
end

local function read_six_channels(dev)
  local frame = dev:read(12, REG_CH0_DATA_L)
  if type(frame) ~= "string" or #frame < 12 then
    error("channel data frame length invalid")
  end
  local values = {}
  for i = 0, 5 do
    local lo = string.byte(frame, i * 2 + 1)
    local hi = string.byte(frame, i * 2 + 2)
    values[i + 1] = lo + hi * 256
  end
  return values
end

local function measure_bank(dev, smux_config, timeout_ms, poll_interval_ms)
  configure_smux(dev, smux_config, timeout_ms, poll_interval_ms)
  spectral_enable(dev, true)
  wait_data_ready(dev, timeout_ms, poll_interval_ms)
  return read_six_channels(dev)
end

local function verify_chip_id(dev)
  local id = read_reg(dev, REG_ID)
  if (id & 0xFC) ~= ((CHIP_ID << 2) & 0xFC) then
    error(string.format(
      "unexpected AS7341 ID=0x%02X (expected (id&0xFC)==0x%02X)",
      id,
      (CHIP_ID << 2) & 0xFC
    ))
  end
  return id
end

local function tint_ms(atime, astep)
  return ((atime + 1) * (astep + 1) * 2.78) / 1000.0
end

local function apply_timing_and_gain(dev, atime, astep, gain)
  if atime == 0 and astep == 0 then
    error("ATIME and ASTEP must not both be 0")
  end
  write_reg(dev, REG_ATIME, atime)
  write_reg(dev, REG_ASTEP_L, astep % 256)
  write_reg(dev, REG_ASTEP_H, math.floor(astep / 256) % 256)
  write_reg(dev, REG_CFG1, gain)
end

local function print_probe_json(addr, chip_id)
  print(
    "{"
      .. "\"ok\":true,"
      .. "\"sensor\":\"AS7341\","
      .. "\"action\":\"probe\","
      .. "\"addr\":"
      .. addr
      .. ","
      .. "\"chip_id\":"
      .. chip_id
      .. "}"
  )
end

local function print_read_json(addr, chip_id, channels, atime, astep, gain, status2)
  local gain_label = GAIN_LABELS[gain] or tostring(gain)
  print(
    "{"
      .. "\"ok\":true,"
      .. "\"sensor\":\"AS7341\","
      .. "\"action\":\"read\","
      .. "\"unit\":\"counts\","
      .. "\"addr\":"
      .. addr
      .. ","
      .. "\"chip_id\":"
      .. chip_id
      .. ","
      .. "\"atime\":"
      .. atime
      .. ","
      .. "\"astep\":"
      .. astep
      .. ","
      .. "\"gain\":"
      .. gain
      .. ","
      .. "\"gain_label\":\""
      .. gain_label
      .. "\","
      .. "\"tint_ms\":"
      .. string.format("%.3f", tint_ms(atime, astep))
      .. ","
      .. "\"status2\":"
      .. status2
      .. ","
      .. "\"f1\":"
      .. channels.f1
      .. ","
      .. "\"f2\":"
      .. channels.f2
      .. ","
      .. "\"f3\":"
      .. channels.f3
      .. ","
      .. "\"f4\":"
      .. channels.f4
      .. ","
      .. "\"f5\":"
      .. channels.f5
      .. ","
      .. "\"f6\":"
      .. channels.f6
      .. ","
      .. "\"f7\":"
      .. channels.f7
      .. ","
      .. "\"f8\":"
      .. channels.f8
      .. ","
      .. "\"clear\":"
      .. channels.clear
      .. ","
      .. "\"nir\":"
      .. channels.nir
      .. ","
      .. "\"wavelength_nm\":{"
      .. "\"f1\":415,\"f2\":445,\"f3\":480,\"f4\":515,"
      .. "\"f5\":555,\"f6\":590,\"f7\":630,\"f8\":680"
      .. "}"
      .. "}"
  )
end

local function run()
  local action = parse_action_arg()
  local i2c_port = parse_int_arg("i2c_port", DEFAULT_I2C_PORT, 0, 1)
  local sda = parse_int_arg("sda", DEFAULT_SDA, 0, 63)
  local scl = parse_int_arg("scl", DEFAULT_SCL, 0, 63)
  local i2c_freq_hz = parse_int_arg("i2c_freq_hz", DEFAULT_I2C_FREQ_HZ, 10000, 1000000)
  local addr = parse_int_arg("addr", DEFAULT_ADDR, 0x08, 0x77)
  local atime = parse_int_arg("atime", DEFAULT_ATIME, 0, 255)
  local astep = parse_int_arg("astep", DEFAULT_ASTEP, 0, 65534)
  local gain = parse_int_arg("gain", DEFAULT_GAIN, 0, 10)
  local timeout_ms = parse_int_arg("timeout_ms", DEFAULT_TIMEOUT_MS, 50, 5000)
  local poll_interval_ms = parse_int_arg("poll_interval_ms", DEFAULT_POLL_INTERVAL_MS, 1, 50)

  local bus = nil
  local dev = nil

  local ok, err = xpcall(function()
    bus = i2c.new(i2c_port, sda, scl, i2c_freq_hz)
    dev = bus:device(addr)

    set_reg_bank(dev, false)
    local chip_id = verify_chip_id(dev)

    if action == "probe" then
      print(string.format(
        "[as7341_i2c] ok action=probe addr=0x%02X chip_id=0x%02X",
        addr,
        chip_id
      ))
      print_probe_json(addr, chip_id)
      return
    end

    power_enable(dev, true)
    delay.delay_ms(10)
    apply_timing_and_gain(dev, atime, astep, gain)

    -- Pass 1: F1–F4, Clear, NIR
    local low = measure_bank(dev, SMUX_F1F4_CLEAR_NIR, timeout_ms, poll_interval_ms)
    -- Pass 2: F5–F8, Clear, NIR
    local high = measure_bank(dev, SMUX_F5F8_CLEAR_NIR, timeout_ms, poll_interval_ms)
    local status2 = read_reg(dev, REG_STATUS2)

    spectral_enable(dev, false)

    local channels = {
      f1 = low[1],
      f2 = low[2],
      f3 = low[3],
      f4 = low[4],
      clear = high[5],
      nir = high[6],
      f5 = high[1],
      f6 = high[2],
      f7 = high[3],
      f8 = high[4],
    }

    print(string.format(
      "[as7341_i2c] ok action=read addr=0x%02X gain=%s tint=%.1fms F1=%d F2=%d F3=%d F4=%d F5=%d F6=%d F7=%d F8=%d Clear=%d NIR=%d",
      addr,
      GAIN_LABELS[gain] or tostring(gain),
      tint_ms(atime, astep),
      channels.f1,
      channels.f2,
      channels.f3,
      channels.f4,
      channels.f5,
      channels.f6,
      channels.f7,
      channels.f8,
      channels.clear,
      channels.nir
    ))
    print_read_json(addr, chip_id, channels, atime, astep, gain, status2)
  end, debug.traceback)

  cleanup(dev, bus)

  if not ok then
    print("[as7341_i2c] ERROR: " .. tostring(err))
    error(err)
  end
end

run()
