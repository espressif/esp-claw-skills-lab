-- planter_config.lua
--
-- All user-tunable knobs for the planter skill. Edit this file to retune
-- behavior or rewire hardware.

return {
    -- Hardware wiring -------------------------------------------------------
    soil_adc_gpio  = 8,             -- Soil moisture ADC input pin
    light_adc_gpio = 3,             -- Light sensor ADC input pin
    dht_gpio       = 21,            -- DHT11 temperature/humidity data pin
    relay_gpio     = 1,             -- Pump relay control pin (high = on)
    touch_device   = "touch_keys",  -- Touch device name in board_manager

    -- Watering policy -------------------------------------------------------
    -- Soil ADC <= this triggers one pump pulse. Should fall inside the S0
    -- (VeryDry) range of soil_levels.
    soil_pump_threshold_mv = 450,
    -- Single pump pulse duration (ms).
    pump_pulse_ms = 5000,
    -- Cooldown after each pulse (ms). No new pulse fires during cooldown
    -- even if soil still reads dry.
    pump_cooldown_ms = 120 * 1000,

    -- Soil moisture levels (mV; lower = drier). Last entry must be math.huge.
    -- S0 / S5 drive the dry / wet expressions.
    soil_levels = {
        { code = "S0", name = "VeryDry",   max = 450 },
        { code = "S1", name = "Dry",       max = 800 },
        { code = "S2", name = "SlightDry", max = 1200 },
        { code = "S3", name = "Moderate",  max = 1600 },
        { code = "S4", name = "Wet",       max = 2100 },
        { code = "S5", name = "VeryWet",   max = math.huge },
    },

    -- Light levels (mV; lower = brighter). L0 / L5 drive the dark / light
    -- expressions.
    light_levels = {
        { code = "L5", name = "VeryBright", max = 400 },
        { code = "L4", name = "Bright",     max = 700 },
        { code = "L3", name = "Moderate",   max = 1100 },
        { code = "L2", name = "Dim",        max = 1400 },
        { code = "L1", name = "Dark",       max = 1700 },
        { code = "L0", name = "VeryDark",   max = math.huge },
    },

    -- Temperature thresholds (Celsius). Below cold -> "TC" (cold expression);
    -- above hot -> "TH" (hot expression); otherwise "TN".
    temp_cold_c = 15,
    temp_hot_c  = 32,

    -- Air humidity thresholds (percent). No behavior is gated on humidity
    -- today; codes are recorded only for the letter to describe.
    hum_dry_pct = 30,
    hum_wet_pct = 70,

    -- Sentinel written into any *_code field when the underlying read fails.
    -- Consumers (e.g. planter_letter) treat this value as "no data".
    code_not_connected = "NC",
}
