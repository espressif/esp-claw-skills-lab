local i2c = require("i2c")
local delay = require("delay")

local DEFAULT_I2C_PORT = 0
local DEFAULT_SDA = 47
local DEFAULT_SCL = 48
local DEFAULT_I2C_FREQ_HZ = 400000
local DEFAULT_ADDR = 0x33

local REG_BATTERY = 0x87
local DEFAULT_RETRY_COUNT = 10
local DEFAULT_RETRY_DELAY_MS = 20

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

local function run()
  local i2c_port = parse_int_arg("i2c_port", DEFAULT_I2C_PORT, 0, 1)
  local sda = parse_int_arg("sda", DEFAULT_SDA, 0, 63)
  local scl = parse_int_arg("scl", DEFAULT_SCL, 0, 63)
  local i2c_freq_hz = parse_int_arg("i2c_freq_hz", DEFAULT_I2C_FREQ_HZ, 10000, 1000000)
  local addr = parse_int_arg("addr", DEFAULT_ADDR, 0x08, 0x77)
  local retry_count = parse_int_arg("retry_count", DEFAULT_RETRY_COUNT, 1, 20)
  local retry_delay_ms = parse_int_arg("retry_delay_ms", DEFAULT_RETRY_DELAY_MS, 0, 1000)

  local bus = nil
  local dev = nil

  local ok, err = xpcall(function()
    bus = i2c.new(i2c_port, sda, scl, i2c_freq_hz)
    dev = bus:device(addr)

    for attempt = 1, retry_count do
      local value = dev:read_byte(REG_BATTERY)

      if value >= 0 and value <= 100 then
        print(string.format(
          "[unihiker_expansion_battery] battery=%d%% addr=0x%02X port=%d sda=%d scl=%d freq=%d attempt=%d",
          value,
          addr,
          i2c_port,
          sda,
          scl,
          i2c_freq_hz,
          attempt
        ))
        return
      end

      if attempt < retry_count and retry_delay_ms > 0 then
        delay.delay_ms(retry_delay_ms)
      end
    end

    error("battery read failed or out of range after retries")
  end, debug.traceback)

  cleanup(dev, bus)

  if not ok then
    print("[unihiker_expansion_battery] ERROR: " .. tostring(err))
    error(err)
  end
end

run()