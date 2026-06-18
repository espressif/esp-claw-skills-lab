-- token_usage_env.lua
-- BME690 environmental sensor polling and env-page widget updates.

local M = {}

local TEMP_OFFSET = 5.0
local HUMIDITY_AVG_COUNT = 5
local BME69X_GASM_VALID_MSK = 0x20
local COLOR_LABEL = "#bebebe"

local STATUS_COLOR = {
    l1 = "#4caf50",
    l2 = "#64dd17",
    l3 = "#ffd600",
    l4 = "#ff6d00",
    l5 = "#d50000",
}

local function temperature_desc(celsius)
    local x100 = math.floor(celsius * 100 + 0.5)
    if x100 >= 1800 and x100 <= 2600 then
        return "Comfortable", STATUS_COLOR.l1
    end
    if x100 >= 1000 and x100 < 1800 then
        return "Bit Cool", STATUS_COLOR.l2
    end
    if x100 > 2600 and x100 <= 3300 then
        return "Bit Warm", STATUS_COLOR.l2
    end
    if x100 >= 0 and x100 < 1000 then
        return "Too Cold", STATUS_COLOR.l3
    end
    if x100 > 3300 and x100 <= 4000 then
        return "Too Hot", STATUS_COLOR.l4
    end
    if x100 < 0 then
        return "Freezing", STATUS_COLOR.l5
    end
    return "Very Hot", STATUS_COLOR.l5
end

local function humidity_desc(avg)
    local x100 = math.floor(avg * 100 + 0.5)
    if x100 >= 3000 and x100 <= 6000 then
        return "Just Right", STATUS_COLOR.l1
    end
    if x100 >= 2000 and x100 < 3000 then
        return "Bit Dry", STATUS_COLOR.l2
    end
    if x100 > 6000 and x100 <= 7500 then
        return "Bit Humid", STATUS_COLOR.l2
    end
    if x100 >= 1000 and x100 < 2000 then
        return "Too Dry", STATUS_COLOR.l3
    end
    if x100 > 7500 and x100 <= 8500 then
        return "Too Humid", STATUS_COLOR.l3
    end
    return "Way Off", STATUS_COLOR.l4
end

local function pressure_desc(hpa)
    local x10 = math.floor(hpa * 10 + 0.5)
    if x10 >= 10100 and x10 <= 10200 then
        return "Just Right", STATUS_COLOR.l1
    end
    if x10 >= 10000 and x10 < 10100 then
        return "Bit Stuffy", STATUS_COLOR.l2
    end
    if x10 > 10200 and x10 <= 10300 then
        return "Bit Dry", STATUS_COLOR.l2
    end
    if x10 >= 9900 and x10 < 10000 then
        return "Too Stuffy", STATUS_COLOR.l3
    end
    if x10 > 10300 and x10 <= 10450 then
        return "Too Dry", STATUS_COLOR.l3
    end
    if x10 < 9900 then
        return "Stormy", STATUS_COLOR.l4
    end
    return "Very Dry", STATUS_COLOR.l4
end

local function co2_desc(ppm)
    if ppm < 600 then
        return "Fresh", STATUS_COLOR.l1
    end
    if ppm < 1000 then
        return "Good", STATUS_COLOR.l2
    end
    if ppm < 1500 then
        return "OK", STATUS_COLOR.l3
    end
    return "Stuffy", STATUS_COLOR.l4
end

local sensor_ok, environmental_sensor = pcall(require, "environmental_sensor")

local LOG10 = math.log(10)

local function log10(value)
    return math.log(value) / LOG10
end

local function gas_valid(sample)
    if not sample or not sample.gas_resistance or sample.gas_resistance <= 0 then
        return false
    end
    if sample.status then
        return (sample.status & BME69X_GASM_VALID_MSK) ~= 0
    end
    return true
end

local function estimate_co2_ppm(gas_ohm)
    if not gas_ohm or gas_ohm <= 0 then
        return nil
    end
    local log_r = log10(gas_ohm)
    local ppm = math.floor(3500 - 400 * log_r)
    if ppm < 400 then
        ppm = 400
    end
    if ppm > 3000 then
        ppm = 3000
    end
    return ppm
end

local function push_humidity(state, value)
    state.humidity_history = state.humidity_history or {}
    state.humidity_index = (state.humidity_index or 0) % HUMIDITY_AVG_COUNT + 1
    state.humidity_history[state.humidity_index] = value
    if (state.humidity_count or 0) < HUMIDITY_AVG_COUNT then
        state.humidity_count = (state.humidity_count or 0) + 1
    end
    local sum = 0
    for i = 1, state.humidity_count do
        sum = sum + state.humidity_history[i]
    end
    return sum / state.humidity_count
end

function M.init()
    local state = {
        available = false,
        sensor = nil,
        last_sample = nil,
        last_poll_ms = 0,
        humidity_history = {},
        humidity_index = 0,
        humidity_count = 0,
    }

    if not sensor_ok or not environmental_sensor then
        print("[token_usage] environmental_sensor module unavailable")
        return state
    end

    local ok, sensor = pcall(environmental_sensor.new, "environmental_sensor")
    if ok and sensor then
        state.available = true
        state.sensor = sensor
        print("[token_usage] environmental sensor opened: " .. tostring(sensor:name()))
    else
        print("[token_usage] environmental sensor open failed: " .. tostring(sensor))
    end

    return state
end

function M.close(state)
    if not state or not state.sensor then
        return
    end
    pcall(function()
        state.sensor:close()
    end)
    state.sensor = nil
    state.available = false
end

function M.poll_if_due(state, now_ms, interval_ms)
    if not state or not state.available or not state.sensor then
        return false
    end

    interval_ms = interval_ms or 3000
    if (now_ms - (state.last_poll_ms or 0)) < interval_ms then
        return false
    end
    state.last_poll_ms = now_ms

    local ok, sample = pcall(function()
        return state.sensor:read()
    end)
    if ok and type(sample) == "table" then
        state.last_sample = sample
        return true
    end

    print("[token_usage] environmental sensor read failed: " .. tostring(sample))
    return false
end

function M.update_widgets(controller, state)
    if not controller or not state then
        return
    end

    local sample = state.last_sample
    if not sample then
        for i = 1, 4 do
            controller:update_env_tile(i, "--", "No Data", COLOR_LABEL)
        end
        return
    end

    local temp = sample.temperature
    if type(temp) == "number" then
        temp = temp - TEMP_OFFSET
        local desc, color = temperature_desc(temp)
        controller:update_env_tile(1, string.format("%.1f", temp), desc, color)
    else
        controller:update_env_tile(1, "--", "No Data", COLOR_LABEL)
    end

    local humidity = sample.humidity
    if type(humidity) == "number" then
        local avg = push_humidity(state, humidity)
        local desc, color = humidity_desc(avg)
        controller:update_env_tile(2, string.format("%.1f", avg), desc, color)
    else
        controller:update_env_tile(2, "--", "No Data", COLOR_LABEL)
    end

    local pressure = sample.pressure
    if type(pressure) == "number" then
        local hpa = pressure / 100.0
        local desc, color = pressure_desc(hpa)
        controller:update_env_tile(3, string.format("%.0f", hpa), desc, color)
    else
        controller:update_env_tile(3, "--", "No Data", COLOR_LABEL)
    end

    if gas_valid(sample) then
        local ppm = estimate_co2_ppm(sample.gas_resistance)
        local desc, color = co2_desc(ppm)
        controller:update_env_tile(4, tostring(ppm), desc, color)
    else
        controller:update_env_tile(4, "--", "No Data", COLOR_LABEL)
    end
end

return M
