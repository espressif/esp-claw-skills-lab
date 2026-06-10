local i2c = require("i2c")
local delay = require("delay")
local system = require("system")

local DEFAULT_MODE = "wait_event"
local DEFAULT_TARGET = "any"
local DEFAULT_EDGE = "press"
local DEFAULT_ACTIVE_LEVEL = 0
local DEFAULT_TIMEOUT_MS = 10000
local DEFAULT_POLL_INTERVAL_MS = 2
local DEFAULT_DEBOUNCE_MS = 12

local DEFAULT_I2C_PORT = 0
local DEFAULT_SDA = 47
local DEFAULT_SCL = 48
local DEFAULT_I2C_FREQ_HZ = 400000
local DEFAULT_ADDR = 0x20

local REG_INPUT_PORT_0 = 0x00
local REG_INPUT_PORT_1 = 0x01
local REG_CONFIG_PORT_0 = 0x06
local REG_CONFIG_PORT_1 = 0x07

local BUTTON_A_PORT = 1
local BUTTON_A_BIT = 4 -- P14
local BUTTON_B_PORT = 0
local BUTTON_B_BIT = 2 -- P02

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

local function read_u8_reg(dev, reg)
  local raw = dev:read(1, reg)
  if type(raw) ~= "string" or #raw ~= 1 then
    error(string.format("i2c read reg 0x%02X failed", reg))
  end
  return string.byte(raw, 1)
end

local function write_u8_reg(dev, reg, value)
  dev:write({value % 256}, reg)
end

local function set_bit(value, bit_index)
  return value | (1 << bit_index)
end

local function ensure_button_input_mode(dev)
  local cfg0 = read_u8_reg(dev, REG_CONFIG_PORT_0)
  local cfg1 = read_u8_reg(dev, REG_CONFIG_PORT_1)

  local cfg0_new = set_bit(cfg0, BUTTON_B_BIT)
  local cfg1_new = set_bit(cfg1, BUTTON_A_BIT)

  if cfg0_new ~= cfg0 then
    write_u8_reg(dev, REG_CONFIG_PORT_0, cfg0_new)
  end
  if cfg1_new ~= cfg1 then
    write_u8_reg(dev, REG_CONFIG_PORT_1, cfg1_new)
  end
end

local function bit_to_level(byte_value, bit_index)
  return (byte_value >> bit_index) & 0x01
end

local function read_button_levels(dev)
  local in0 = read_u8_reg(dev, REG_INPUT_PORT_0)
  local in1 = read_u8_reg(dev, REG_INPUT_PORT_1)

  local level_a = bit_to_level(in1, BUTTON_A_BIT)
  local level_b = bit_to_level(in0, BUTTON_B_BIT)

  return {
    a_level = level_a,
    b_level = level_b,
  }
end

local function build_state(levels, active_level)
  return {
    a_level = levels.a_level,
    b_level = levels.b_level,
    a_pressed = (levels.a_level == active_level),
    b_pressed = (levels.b_level == active_level),
  }
end

local function state_to_json(state)
  return "{"
      .. "\"a\":{"
      .. "\"pressed\":" .. tostring(state.a_pressed) .. ","
      .. "\"level\":" .. state.a_level
      .. "},"
      .. "\"b\":{"
      .. "\"pressed\":" .. tostring(state.b_pressed) .. ","
      .. "\"level\":" .. state.b_level
      .. "}"
      .. "}"
end

local function copy_state(state)
  return {
    a_level = state.a_level,
    b_level = state.b_level,
    a_pressed = state.a_pressed,
    b_pressed = state.b_pressed,
  }
end

local function diff_buttons(prev, now)
  local changed = {}
  if prev.a_pressed ~= now.a_pressed then
    changed[#changed + 1] = {
      button = "a",
      edge = now.a_pressed and "press" or "release",
      pressed = now.a_pressed,
      level = now.a_level,
    }
  end
  if prev.b_pressed ~= now.b_pressed then
    changed[#changed + 1] = {
      button = "b",
      edge = now.b_pressed and "press" or "release",
      pressed = now.b_pressed,
      level = now.b_level,
    }
  end
  return changed
end

local function event_matches(event, target, edge)
  local target_ok = (target == "any") or (event.button == target)
  local edge_ok = (edge == "any") or (event.edge == edge)
  return target_ok and edge_ok
end

local function wait_for_button_event(dev, base_state, active_level, target, edge, timeout_ms, poll_interval_ms, debounce_ms)
  local started = system.millis()
  local previous = copy_state(base_state)

  while true do
    local now_ms = system.millis()
    local elapsed = now_ms - started
    if elapsed > timeout_ms then
      return nil, elapsed, previous
    end

    local current = build_state(read_button_levels(dev), active_level)
    local changed = diff_buttons(previous, current)

    if #changed > 0 then
      if debounce_ms > 0 then
        delay.delay_ms(debounce_ms)
        current = build_state(read_button_levels(dev), active_level)
        changed = diff_buttons(previous, current)
      end

      if #changed > 0 then
        for i = 1, #changed do
          local evt = changed[i]
          if event_matches(evt, target, edge) then
            return evt, system.millis() - started, current
          end
        end
        previous = current
      end
    end

    delay.delay_ms(poll_interval_ms)
  end
end

local function run()
  local mode = parse_enum_arg("mode", DEFAULT_MODE, {"read", "wait_event"})
  local target = parse_enum_arg("target", DEFAULT_TARGET, {"a", "b", "any"})
  local edge = parse_enum_arg("edge", DEFAULT_EDGE, {"press", "release", "any"})
  local active_level = parse_int_arg("active_level", DEFAULT_ACTIVE_LEVEL, 0, 1)
  local timeout_ms = parse_int_arg("timeout_ms", DEFAULT_TIMEOUT_MS, 0, 120000)
  local poll_interval_ms = parse_int_arg("poll_interval_ms", DEFAULT_POLL_INTERVAL_MS, 1, 100)
  local debounce_ms = parse_int_arg("debounce_ms", DEFAULT_DEBOUNCE_MS, 0, 100)

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

    ensure_button_input_mode(dev)

    local first_state = build_state(read_button_levels(dev), active_level)

    if mode == "read" then
      print(string.format(
        "[unihiker_button] ok mode=read addr=0x%02X a_pressed=%s b_pressed=%s",
        addr,
        tostring(first_state.a_pressed),
        tostring(first_state.b_pressed)
      ))
      print("{"
          .. "\"ok\":true,"
          .. "\"mode\":\"read\","
          .. "\"addr\":" .. addr .. ","
          .. "\"active_level\":" .. active_level .. ","
          .. "\"state\":" .. state_to_json(first_state)
          .. "}")
      return
    end

    local event, elapsed, final_state = wait_for_button_event(
      dev,
      first_state,
      active_level,
      target,
      edge,
      timeout_ms,
      poll_interval_ms,
      debounce_ms
    )

    if event then
      print(string.format(
        "[unihiker_button] ok mode=wait_event addr=0x%02X event=%s_%s elapsed_ms=%d",
        addr,
        event.button,
        event.edge,
        elapsed
      ))
      print("{"
          .. "\"ok\":true,"
          .. "\"mode\":\"wait_event\","
          .. "\"timed_out\":false,"
          .. "\"elapsed_ms\":" .. elapsed .. ","
          .. "\"event\":{"
          .. "\"button\":\"" .. event.button .. "\","
          .. "\"edge\":\"" .. event.edge .. "\","
          .. "\"pressed\":" .. tostring(event.pressed) .. ","
          .. "\"level\":" .. event.level
          .. "},"
          .. "\"state\":" .. state_to_json(final_state)
          .. "}")
    else
      print(string.format(
        "[unihiker_button] timeout mode=wait_event addr=0x%02X timeout_ms=%d",
        addr,
        timeout_ms
      ))
      print("{"
          .. "\"ok\":true,"
          .. "\"mode\":\"wait_event\","
          .. "\"timed_out\":true,"
          .. "\"elapsed_ms\":" .. elapsed .. ","
          .. "\"state\":" .. state_to_json(final_state)
          .. "}")
    end
  end, debug.traceback)

  cleanup(dev, bus)

  if not ok then
    print("[unihiker_button] ERROR: " .. tostring(err))
    error(err)
  end
end

run()
