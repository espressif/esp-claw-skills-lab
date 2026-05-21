-- --------------------------------------------------------------
-- DFRobot UNIHIKER Expansion motor controller over I2C.
-- Register protocol is aligned with DFRobot_UnihikerExpansion setMotor.* APIs.
-- --------------------------------------------------------------

local i2c = require("i2c")
local delay = require("delay")

local DEFAULT_I2C_PORT = 0
local DEFAULT_SDA = 47
local DEFAULT_SCL = 48
local DEFAULT_I2C_FREQ_HZ = 400000
local DEFAULT_ADDR = 0x33
local DEFAULT_PERIOD = 255
local DEFAULT_AUTO_STOP_MS = 0

local REG_MOTOR12_PERIOD_H = 0x00
local REG_MOTOR34_PERIOD_H = 0x02
local REG_MOTOR1_A_DUTY_H = 0x04

local MOTOR_KEYS = {
  "m1_a",
  "m1_b",
  "m2_a",
  "m2_b",
  "m3_a",
  "m3_b",
  "m4_a",
  "m4_b",
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

local function parse_bool_arg(name, default)
  local value = read_arg(name, default)
  if type(value) ~= "boolean" then
    error(name .. " must be a boolean")
  end
  return value
end

local function parse_duty_table(stop_all)
  local duty = {}
  local raw = read_arg("duty", {})
  local i

  if type(raw) ~= "table" then
    error("duty must be an object")
  end

  for _, key in ipairs(MOTOR_KEYS) do
    duty[key] = 0
  end

  for key, value in pairs(raw) do
    local known = false

    for _, allowed_key in ipairs(MOTOR_KEYS) do
      if key == allowed_key then
        known = true
        break
      end
    end

    if not known then
      error("unsupported duty key: " .. tostring(key))
    end
    if type(value) ~= "number" or value % 1 ~= 0 then
      error("duty." .. key .. " must be an integer")
    end
    if value < 0 or value > 65535 then
      error("duty." .. key .. " must be in range 0-65535")
    end
    duty[key] = value
  end

  if stop_all then
    for i = 1, #MOTOR_KEYS do
      duty[MOTOR_KEYS[i]] = 0
    end
  end

  return duty
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

local function write_all_duty(dev, duty)
  for idx, key in ipairs(MOTOR_KEYS) do
    local reg = REG_MOTOR1_A_DUTY_H + (idx - 1) * 2
    write_u16(dev, reg, duty[key])
  end
end

local function build_stop_duty()
  local duty = {}
  for _, key in ipairs(MOTOR_KEYS) do
    duty[key] = 0
  end
  return duty
end

local function run()
  local i2c_port = parse_int_arg("i2c_port", DEFAULT_I2C_PORT, 0, 1)
  local sda = parse_int_arg("sda", DEFAULT_SDA, 0, 63)
  local scl = parse_int_arg("scl", DEFAULT_SCL, 0, 63)
  local i2c_freq_hz = parse_int_arg("i2c_freq_hz", DEFAULT_I2C_FREQ_HZ, 10000, 1000000)
  local addr = parse_int_arg("addr", DEFAULT_ADDR, 0x08, 0x77)
  local period_12 = parse_int_arg("period_12", DEFAULT_PERIOD, 0, 65535)
  local period_34 = parse_int_arg("period_34", DEFAULT_PERIOD, 0, 65535)
  local stop_all = parse_bool_arg("stop_all", false)
  local auto_stop_ms = parse_int_arg("auto_stop_ms", DEFAULT_AUTO_STOP_MS, 0, 3600000)
  local duty = parse_duty_table(stop_all)

  local bus = nil
  local dev = nil

  local ok, err = xpcall(function()
    bus = i2c.new(i2c_port, sda, scl, i2c_freq_hz)
    dev = bus:device(addr)

    write_u16(dev, REG_MOTOR12_PERIOD_H, period_12)
    write_u16(dev, REG_MOTOR34_PERIOD_H, period_34)
    write_all_duty(dev, duty)

    print(string.format(
      "[unihiker_motor] ok addr=0x%02X port=%d sda=%d scl=%d freq=%d period12=%d period34=%d stop_all=%s auto_stop_ms=%d",
      addr,
      i2c_port,
      sda,
      scl,
      i2c_freq_hz,
      period_12,
      period_34,
      tostring(stop_all),
      auto_stop_ms
    ))

    print(string.format(
      "[unihiker_motor] duty m1(%d,%d) m2(%d,%d) m3(%d,%d) m4(%d,%d)",
      duty.m1_a,
      duty.m1_b,
      duty.m2_a,
      duty.m2_b,
      duty.m3_a,
      duty.m3_b,
      duty.m4_a,
      duty.m4_b
    ))

    if auto_stop_ms > 0 and not stop_all then
      local stop_duty = build_stop_duty()

      delay.delay_ms(auto_stop_ms)
      write_all_duty(dev, stop_duty)
      print(string.format("[unihiker_motor] auto stopped after %d ms", auto_stop_ms))
    end
  end, debug.traceback)

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

  if not ok then
    print("[unihiker_motor] ERROR: " .. tostring(err))
    error(err)
  end
end

run()
