local i2c = require("i2c")
local delay = require("delay")

local DEFAULT_I2C_PORT = 0
local DEFAULT_SDA = 47
local DEFAULT_SCL = 48
local DEFAULT_I2C_FREQ_HZ = 400000
local DEFAULT_ADDR = 0x64

local CMD_START_CONT_MEASURE = 0x218B
local CMD_STOP_CONT_MEASURE = 0x3F86
local CMD_READ_MEASURE = 0xEC05

local DEFAULT_ACTION = "read"
local DEFAULT_START_IF_NEEDED = true
local DEFAULT_WAIT_AFTER_START_MS = 1200
local DEFAULT_VERIFY_CRC = true

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

local function parse_bool_arg(name, default)
  local value = read_arg(name, default)
  if type(value) ~= "boolean" then
    error(name .. " must be a boolean")
  end
  return value
end

local function parse_action_arg()
  local value = read_arg("action", DEFAULT_ACTION)
  if type(value) ~= "string" then
    error("action must be a string")
  end
  if value ~= "read" and value ~= "start" and value ~= "stop" then
    error("action must be one of: read, start, stop")
  end
  return value
end

local function cleanup(dev, bus)
  if dev then
    pcall(function() dev:close() end)
  end
  if bus then
    pcall(function() bus:close() end)
  end
end

local function write_cmd16(dev, cmd)
  local msb = math.floor(cmd / 256) % 256
  local lsb = cmd % 256
  dev:write({msb, lsb})
end

local function crc8_word(msb, lsb)
  local crc = 0xFF

  crc = crc ~ msb
  for _ = 1, 8 do
    if (crc & 0x80) ~= 0 then
      crc = ((crc << 1) ~ 0x31) & 0xFF
    else
      crc = (crc << 1) & 0xFF
    end
  end

  crc = crc ~ lsb
  for _ = 1, 8 do
    if (crc & 0x80) ~= 0 then
      crc = ((crc << 1) ~ 0x31) & 0xFF
    else
      crc = (crc << 1) & 0xFF
    end
  end

  return crc
end

local function parse_measurement_frame(frame, verify_crc)
  if type(frame) ~= "string" or #frame < 12 then
    error("measurement frame length invalid")
  end

  local co2_msb = string.byte(frame, 1)
  local co2_lsb = string.byte(frame, 2)
  local co2_crc = string.byte(frame, 3)

  local temp_msb = string.byte(frame, 4)
  local temp_lsb = string.byte(frame, 5)
  local temp_crc = string.byte(frame, 6)

  local hum_msb = string.byte(frame, 7)
  local hum_lsb = string.byte(frame, 8)
  local hum_crc = string.byte(frame, 9)

  local stat_msb = string.byte(frame, 10)
  local stat_lsb = string.byte(frame, 11)
  local stat_crc = string.byte(frame, 12)

  if verify_crc then
    if crc8_word(co2_msb, co2_lsb) ~= co2_crc then
      error("CRC mismatch on CO2 field")
    end
    if crc8_word(temp_msb, temp_lsb) ~= temp_crc then
      error("CRC mismatch on temperature field")
    end
    if crc8_word(hum_msb, hum_lsb) ~= hum_crc then
      error("CRC mismatch on humidity field")
    end
    if crc8_word(stat_msb, stat_lsb) ~= stat_crc then
      error("CRC mismatch on status field")
    end
  end

  local co2 = co2_msb * 256 + co2_lsb
  local temp_raw = temp_msb * 256 + temp_lsb
  local hum_raw = hum_msb * 256 + hum_lsb
  local status = stat_msb * 256 + stat_lsb

  local temperature = -45.0 + (175.0 * temp_raw) / 65535.0
  local humidity = -6.0 + (125.0 * hum_raw) / 65535.0

  return co2, temperature, humidity, status
end

local function bool_to_json(v)
  if v then
    return "true"
  end
  return "false"
end

local function print_read_json(addr, co2, temperature, humidity, status, verify_crc)
  print(
    "{"
      .. "\"ok\":true,"
      .. "\"sensor\":\"DFRobot_STCC4\","
      .. "\"unit\":{\"co2\":\"ppm\",\"temperature\":\"C\",\"humidity\":\"%RH\"},"
      .. "\"addr\":" .. addr .. ","
      .. "\"co2_ppm\":" .. co2 .. ","
      .. "\"temperature_c\":" .. string.format("%.2f", temperature) .. ","
      .. "\"humidity_rh\":" .. string.format("%.2f", humidity) .. ","
      .. "\"sensor_status\":" .. status .. ","
      .. "\"crc_verified\":" .. bool_to_json(verify_crc)
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
  local start_if_needed = parse_bool_arg("start_if_needed", DEFAULT_START_IF_NEEDED)
  local wait_after_start_ms = parse_int_arg("wait_after_start_ms", DEFAULT_WAIT_AFTER_START_MS, 0, 5000)
  local verify_crc = parse_bool_arg("verify_crc", DEFAULT_VERIFY_CRC)

  local bus = nil
  local dev = nil

  local ok, err = xpcall(function()
    bus = i2c.new(i2c_port, sda, scl, i2c_freq_hz)
    dev = bus:device(addr)

    if action == "start" then
      write_cmd16(dev, CMD_START_CONT_MEASURE)
      print(string.format("[dfrobot_stcc4_i2c] started continuous measurement addr=0x%02X", addr))
      return
    end

    if action == "stop" then
      write_cmd16(dev, CMD_STOP_CONT_MEASURE)
      print(string.format("[dfrobot_stcc4_i2c] stopped continuous measurement addr=0x%02X", addr))
      return
    end

    if start_if_needed then
      write_cmd16(dev, CMD_START_CONT_MEASURE)
      if wait_after_start_ms > 0 then
        delay.delay_ms(wait_after_start_ms)
      end
    end

    write_cmd16(dev, CMD_READ_MEASURE)
    local frame = dev:read(12)
    local co2, temperature, humidity, status = parse_measurement_frame(frame, verify_crc)

    print(string.format(
      "[dfrobot_stcc4_i2c] ok action=read addr=0x%02X co2=%dppm temp=%.2fC hum=%.2f%% status=%d",
      addr,
      co2,
      temperature,
      humidity,
      status
    ))
    print_read_json(addr, co2, temperature, humidity, status, verify_crc)
  end, debug.traceback)

  cleanup(dev, bus)

  if not ok then
    print("[dfrobot_stcc4_i2c] ERROR: " .. tostring(err))
    error(err)
  end
end

run()
