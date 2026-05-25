local i2c = require("i2c")
local delay = require("delay")

local DEFAULT_I2C_PORT = 0
local DEFAULT_SDA = 47
local DEFAULT_SCL = 48
local DEFAULT_I2C_FREQ_HZ = 400000
local DEFAULT_ADDR = 0x33

local REG_IR_SEND = 0x24
local REG_IR_RECV = 0x88
local DATA_ENABLE = 0x01
local DATA_DISABLE = 0x00

local DEFAULT_MODE = "send_get"
local DEFAULT_DATA = 0x12345678
local DEFAULT_TIMEOUT_MS = 2000
local DEFAULT_POLL_INTERVAL_MS = 100

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

local function parse_enum_arg(name, default, allowed_values)
  local value = read_arg(name, default)
  if type(value) ~= "string" then
    error(name .. " must be a string")
  end
  for i = 1, #allowed_values do
    if value == allowed_values[i] then
      return value
    end
  end
  error(name .. " must be one of: " .. table.concat(allowed_values, ", "))
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

local function format_hex_u32(value)
  return string.format("0x%08X", value)
end

local function send_ir(dev, value)
  local b1 = math.floor(value / 0x1000000) % 0x100
  local b2 = math.floor(value / 0x10000) % 0x100
  local b3 = math.floor(value / 0x100) % 0x100
  local b4 = value % 0x100

  dev:write({DATA_ENABLE, b1, b2, b3, b4}, REG_IR_SEND)
end

local function read_ir_once(dev)
  local raw = dev:read(5, REG_IR_RECV)
  local flag = string.byte(raw, 1)
  if flag == DATA_DISABLE then
    return nil
  end
  local b1 = string.byte(raw, 2)
  local b2 = string.byte(raw, 3)
  local b3 = string.byte(raw, 4)
  local b4 = string.byte(raw, 5)
  return (((b1 * 256 + b2) * 256 + b3) * 256 + b4)
end

local function poll_ir(dev, timeout_ms, poll_interval_ms)
  local elapsed = 0
  while elapsed <= timeout_ms do
    local value = read_ir_once(dev)
    if value ~= nil then
      return value, elapsed
    end
    if elapsed == timeout_ms then
      break
    end
    local wait_ms = poll_interval_ms
    if elapsed + wait_ms > timeout_ms then
      wait_ms = timeout_ms - elapsed
    end
    if wait_ms > 0 then
      delay.delay_ms(wait_ms)
    end
    elapsed = elapsed + wait_ms
  end
  return nil, elapsed
end

local function run()
  local mode = parse_enum_arg("mode", DEFAULT_MODE, {"send", "get", "send_get"})
  local data = parse_int_arg("data", DEFAULT_DATA, 0, 0xFFFFFFFF)
  local timeout_ms = parse_int_arg("timeout_ms", DEFAULT_TIMEOUT_MS, 0, 60000)
  local poll_interval_ms = parse_int_arg("poll_interval_ms", DEFAULT_POLL_INTERVAL_MS, 10, 5000)
  local i2c_port = parse_int_arg("i2c_port", DEFAULT_I2C_PORT, 0, 1)
  local sda = parse_int_arg("sda", DEFAULT_SDA, 0, 63)
  local scl = parse_int_arg("scl", DEFAULT_SCL, 0, 63)
  local i2c_freq_hz = parse_int_arg("i2c_freq_hz", DEFAULT_I2C_FREQ_HZ, 10000, 1000000)
  local addr = parse_int_arg("addr", DEFAULT_ADDR, 0x08, 0x77)

  local bus = nil
  local dev = nil

  local ok, err = xpcall(function()
    bus = i2c.new(i2c_port, sda, scl, i2c_freq_hz)
    dev = bus:device(addr)

    if mode == "send" or mode == "send_get" then
      send_ir(dev, data)
      print(string.format("[unihiker_expansion_ir] sent=%s", format_hex_u32(data)))
    end

    if mode == "get" or mode == "send_get" then
      local value, elapsed = poll_ir(dev, timeout_ms, poll_interval_ms)
      if value ~= nil then
        print(string.format("[unihiker_expansion_ir] received=%s elapsed_ms=%d", format_hex_u32(value), elapsed))
      else
        print(string.format("[unihiker_expansion_ir] no data within timeout_ms=%d", timeout_ms))
      end
    end

    print(string.format(
      "[unihiker_expansion_ir] ok mode=%s addr=0x%02X port=%d sda=%d scl=%d freq=%d",
      mode,
      addr,
      i2c_port,
      sda,
      scl,
      i2c_freq_hz
    ))
  end, debug.traceback)

  cleanup(dev, bus)

  if not ok then
    print("[unihiker_expansion_ir] ERROR: " .. tostring(err))
    error(err)
  end
end

run()