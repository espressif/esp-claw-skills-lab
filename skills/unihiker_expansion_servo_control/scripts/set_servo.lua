local i2c = require("i2c")
local delay = require("delay")

local DEFAULT_I2C_PORT = 0
local DEFAULT_SDA = 47
local DEFAULT_SCL = 48
local DEFAULT_I2C_FREQ_HZ = 400000
local DEFAULT_ADDR = 0x33

local REG_SERVO0_DUTY_H = 0x18
local SERVO_COUNT = 6

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

local function parse_string_arg(name, default)
  local value = read_arg(name, default)
  if type(value) ~= "string" then
    error(name .. " must be a string")
  end
  return value
end

local function parse_enum_arg(name, default, allowed_values)
  local value = parse_string_arg(name, default)
  for i = 1, #allowed_values do
    if value == allowed_values[i] then
      return value
    end
  end
  error(name .. " must be one of: " .. table.concat(allowed_values, ", "))
end

local function to_u16_bytes(value)
  return {
    math.floor(value / 256) % 256,
    value % 256,
  }
end

local function write_u16(dev, reg, value)
  dev:write(to_u16_bytes(value), reg)
end

local function servo_reg(servo)
  return REG_SERVO0_DUTY_H + servo * 2
end

local function servo_angle_to_period(angle)
  if angle > 180 then
    angle = 180
  end
  if angle < 0 then
    angle = 0
  end
  return math.floor(500 + angle * 11)
end

local function servo360_to_period(direction, speed)
  if speed > 100 then
    speed = 100
  end
  if speed < 0 then
    speed = 0
  end

  if direction == "backward" then
    return math.floor(1550 + speed * 4.5)
  elseif direction == "forward" then
    return math.floor(1450 - speed * 4.5)
  elseif direction == "stop" then
    return 1500
  end

  error("direction must be forward, backward, or stop")
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
  local mode = parse_enum_arg("mode", "angle", {"angle", "servo360"})
  local servo = parse_int_arg("servo", nil, 0, SERVO_COUNT - 1)
  local i2c_port = parse_int_arg("i2c_port", DEFAULT_I2C_PORT, 0, 1)
  local sda = parse_int_arg("sda", DEFAULT_SDA, 0, 63)
  local scl = parse_int_arg("scl", DEFAULT_SCL, 0, 63)
  local i2c_freq_hz = parse_int_arg("i2c_freq_hz", DEFAULT_I2C_FREQ_HZ, 10000, 1000000)
  local addr = parse_int_arg("addr", DEFAULT_ADDR, 0x08, 0x77)

  local bus = nil
  local dev = nil

  local ok, err = xpcall(function()
    if mode == "angle" then
      local angle = parse_int_arg("angle", nil, 0, 180)
      local period = servo_angle_to_period(angle)

      bus = i2c.new(i2c_port, sda, scl, i2c_freq_hz)
      dev = bus:device(addr)
      write_u16(dev, servo_reg(servo), period)

      print(string.format(
        "[unihiker_expansion_servo_control] ok mode=angle servo=%d angle=%d period=%d addr=0x%02X port=%d sda=%d scl=%d freq=%d",
        servo,
        angle,
        period,
        addr,
        i2c_port,
        sda,
        scl,
        i2c_freq_hz
      ))

      local duration_ms = parse_int_arg("duration_ms", 0, 0, 3600000)
      if duration_ms > 0 then
        delay.delay_ms(duration_ms)
        print(string.format("[unihiker_expansion_servo_control] settled after %d ms", duration_ms))
      end
      return
    end

    local direction = parse_enum_arg("direction", "stop", {"forward", "backward", "stop"})
    local speed = parse_int_arg("speed", 0, 0, 100)
    local duration_ms = parse_int_arg("duration_ms", 0, 0, 3600000)
    local period = servo360_to_period(direction, speed)

    bus = i2c.new(i2c_port, sda, scl, i2c_freq_hz)
    dev = bus:device(addr)
    write_u16(dev, servo_reg(servo), period)

    print(string.format(
      "[unihiker_expansion_servo_control] ok mode=servo360 servo=%d direction=%s speed=%d period=%d addr=0x%02X port=%d sda=%d scl=%d freq=%d",
      servo,
      direction,
      speed,
      period,
      addr,
      i2c_port,
      sda,
      scl,
      i2c_freq_hz
    ))

    if duration_ms > 0 and direction ~= "stop" then
      delay.delay_ms(duration_ms)
      write_u16(dev, servo_reg(servo), 1500)
      print(string.format("[unihiker_expansion_servo_control] auto-stopped after %d ms", duration_ms))
    end
  end, debug.traceback)

  cleanup(dev, bus)

  if not ok then
    print("[unihiker_expansion_servo_control] ERROR: " .. tostring(err))
    error(err)
  end
end

run()