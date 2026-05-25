local i2c = require("i2c")

local DEFAULT_I2C_PORT = 0
local DEFAULT_SDA = 47
local DEFAULT_SCL = 48
local DEFAULT_I2C_FREQ_HZ = 400000
local DEFAULT_ADDR = 0x33

local REG_WS2812 = 0x90
local DATA_ENABLE = 0x01

local DEFAULT_BRIGHT = 10
local DEFAULT_RGB0 = 0xFF0000
local DEFAULT_RGB1 = 0x0000FF

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

local function rgb_to_bytes(rgb)
  local r = math.floor(rgb / 0x10000) % 0x100
  local g = math.floor(rgb / 0x100) % 0x100
  local b = rgb % 0x100
  return r, g, b
end

local function format_rgb(rgb)
  return string.format("0x%06X", rgb)
end

local function run()
  local i2c_port = parse_int_arg("i2c_port", DEFAULT_I2C_PORT, 0, 1)
  local sda = parse_int_arg("sda", DEFAULT_SDA, 0, 63)
  local scl = parse_int_arg("scl", DEFAULT_SCL, 0, 63)
  local i2c_freq_hz = parse_int_arg("i2c_freq_hz", DEFAULT_I2C_FREQ_HZ, 10000, 1000000)
  local addr = parse_int_arg("addr", DEFAULT_ADDR, 0x08, 0x77)

  local bright = parse_int_arg("bright", DEFAULT_BRIGHT, 0, 255)
  local color = read_arg("color", nil)
  local rgb0
  local rgb1

  if color ~= nil then
    if type(color) ~= "number" or color % 1 ~= 0 then
      error("color must be an integer")
    end
    if color < 0 or color > 0xFFFFFF then
      error("color must be in range 0-16777215")
    end
    rgb0 = color
    rgb1 = color
  else
    rgb0 = parse_int_arg("rgb0", DEFAULT_RGB0, 0, 0xFFFFFF)
    rgb1 = parse_int_arg("rgb1", DEFAULT_RGB1, 0, 0xFFFFFF)
  end

  local r0, g0, b0 = rgb_to_bytes(rgb0)
  local r1, g1, b1 = rgb_to_bytes(rgb1)

  local bus = nil
  local dev = nil

  local ok, err = xpcall(function()
    bus = i2c.new(i2c_port, sda, scl, i2c_freq_hz)
    dev = bus:device(addr)

    dev:write({DATA_ENABLE, bright, r0, g0, b0, r1, g1, b1}, REG_WS2812)

    print(string.format(
      "[unihiker_expansion_WS2812] ok bright=%d rgb0=%s rgb1=%s addr=0x%02X port=%d sda=%d scl=%d freq=%d",
      bright,
      format_rgb(rgb0),
      format_rgb(rgb1),
      addr,
      i2c_port,
      sda,
      scl,
      i2c_freq_hz
    ))
  end, debug.traceback)

  cleanup(dev, bus)

  if not ok then
    print("[unihiker_expansion_WS2812] ERROR: " .. tostring(err))
    error(err)
  end
end

run()