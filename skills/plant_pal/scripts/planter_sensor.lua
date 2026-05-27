local bm = require("board_manager")
local adc = require("adc")
local gpio = require("gpio")
local delay = require("delay")
local system = require("system")
local thread = require("thread")
local json = require("json")
local storage = require("storage")

local cfg = require("planter_config")

local has_env_sensor, environmental_sensor = pcall(require, "environmental_sensor")
local has_touch, touch = pcall(require, "touch")
local has_display, display = pcall(require, "display")
local has_eaf, display_eaf = pcall(require, "display_eaf")
local has_image, image = pcall(require, "image")

if not has_env_sensor then
    print("[planter_sensor] environmental_sensor module missing; temp/humidity will be N/A")
end
if not has_touch then
    print("[planter_sensor] touch module missing; touch keys disabled")
end

local SOIL_ADC_GPIO  = cfg.soil_adc_gpio
local LIGHT_ADC_GPIO = cfg.light_adc_gpio
local DHT_GPIO       = cfg.dht_gpio
local RELAY_GPIO     = cfg.relay_gpio
local TOUCH_DEVICE   = cfg.touch_device
local RELAY_SELF_TEST_MS = 150

local UI_QUEUE = "planter_ui_cmd"
local UI_QUEUE_DEPTH = 4
local UI_QUEUE_ITEM_SIZE = 256
local UI_ICON_DEFAULT_MS = 3000

local LOOP_MS = 50
local SENSOR_INTERVAL_MS = 1500
local DISPLAY_RETRY_MS = 2000
local TOUCH_WINDOW_MS = 60 * 1000
local TOUCH_ANGER_COUNT = 4
local TOUCH_SHOW_MS = 3000
local TOUCH_ANGER_SHOW_MS = 3000
local CONFIG_RELOAD_CHECK_MS = 2000

local function script_dir()
    local src = debug.getinfo(1, "S").source or ""
    if src:sub(1, 1) == "@" then
        src = src:sub(2)
    end
    return (src:match("(.+)/[^/]+$")) or "."
end

local function normalize_path(path)
    local parts = {}
    for seg in string.gmatch(path, "[^/]+") do
        if seg == ".." then
            if #parts > 0 then
                table.remove(parts)
            end
        elseif seg ~= "." and seg ~= "" then
            parts[#parts + 1] = seg
        end
    end
    local prefix = (string.sub(path, 1, 1) == "/") and "/" or ""
    return prefix .. table.concat(parts, "/")
end

local EAF_DIR = normalize_path(script_dir() .. "/../eaf")
local HISTORY_DIR = normalize_path(script_dir() .. "/../sensor_history")
local CONFIG_PATH = normalize_path(script_dir() .. "/planter_config.lua")
local last_cfg_mtime = nil

local function try_reload_config(force)
    local info, err = storage.stat(CONFIG_PATH)
    if not info then
        if force then
            print("[planter_sensor] config stat failed: " .. tostring(err))
        end
        return
    end
    local mtime = info.mtime
    if (not force) and last_cfg_mtime ~= nil and mtime == last_cfg_mtime then
        return
    end
    if last_cfg_mtime == nil then
        last_cfg_mtime = mtime
        return
    end
    package.loaded["planter_config"] = nil
    local ok, new_cfg = pcall(require, "planter_config")
    if ok and type(new_cfg) == "table" then
        cfg = new_cfg
        last_cfg_mtime = mtime
        print(string.format("[planter_sensor] config reloaded (mtime=%s)", tostring(mtime)))
    else
        print("[planter_sensor] config reload failed: " .. tostring(new_cfg))
    end
end

-- One JSON file per day under HISTORY_DIR; <=24 entries keyed by "YYYY-MM-DDTHH".
local SAVE_CHECK_MS = 60 * 1000
local HISTORY_MAX_ENTRIES_PER_DAY = 24

local EAF_HI = EAF_DIR .. "/hi.eaf"
local EAF_TOUCH = EAF_DIR .. "/touch.eaf"
local EAF_TOUCH_ANGER = EAF_DIR .. "/touch_anger.eaf"
local EAF_COLD = EAF_DIR .. "/cold.eaf"
local EAF_HOT = EAF_DIR .. "/hot.eaf"
local EAF_DRY = EAF_DIR .. "/dry.eaf"
local EAF_WET = EAF_DIR .. "/wet.eaf"
local EAF_DARK = EAF_DIR .. "/dark.eaf"
local EAF_LIGHT = EAF_DIR .. "/light.eaf"

local ALL_EAFS = {
    EAF_COLD, EAF_HOT, EAF_DRY, EAF_WET, EAF_DARK, EAF_LIGHT,
    EAF_TOUCH, EAF_TOUCH_ANGER, EAF_HI,
}

-- Corner overlays composited on top of the base EAF in the same frame.
local OVERLAY_W = 64
local OVERLAY_H = 64
local OVERLAY_PAD = 8
local OVERLAY_ASSETS = {
    mail = EAF_DIR .. "/mail.jpg",
}

local function classify(mv, table_levels)
    if mv == nil then
        return nil
    end
    for _, level in ipairs(table_levels) do
        if mv <= level.max then
            return level
        end
    end
    return table_levels[#table_levels]
end

local function code_from_levels(mv, table_levels)
    local level = classify(mv, table_levels)
    return level and level.code or cfg.code_not_connected
end

local function temp_code_of(t)
    if t == nil then return cfg.code_not_connected end
    if t < cfg.temp_cold_c then return "TC" end
    if t > cfg.temp_hot_c then return "TH" end
    return "TN"
end

local function hum_code_of(h)
    if h == nil then return cfg.code_not_connected end
    if h < cfg.hum_dry_pct then return "HD" end
    if h > cfg.hum_wet_pct then return "HW" end
    return "HN"
end

local function open_adc(gpio_num)
    local ok, handle = pcall(function()
        return adc.new(gpio_num)
    end)
    if not ok then
        return nil, handle
    end
    return handle
end

local function read_adc_mv(handle)
    if not handle then
        return nil, "adc handle unavailable"
    end
    local ok, value = pcall(function()
        return handle:read()
    end)
    if not ok then
        return nil, value
    end
    return value
end

local function open_dht_sensor()
    if not has_env_sensor then
        return nil, "environmental_sensor module not built into firmware"
    end
    local ok, sensor_or_err = pcall(function()
        return environmental_sensor.new({
            type = "dht",
            pin = DHT_GPIO,
            sensor_type = "dht11",
        })
    end)
    if not ok then
        return nil, sensor_or_err
    end
    return sensor_or_err
end

local function read_dht_once(sensor)
    if not sensor then
        return nil, nil, "dht sensor unavailable"
    end
    local ok, sample_or_err = pcall(function()
        return sensor:read()
    end)
    if not ok then
        return nil, nil, sample_or_err
    end
    return sample_or_err.temperature, sample_or_err.humidity
end

local relay_state = 0

local function relay_init()
    gpio.set_direction(RELAY_GPIO, "output")
    gpio.set_level(RELAY_GPIO, 1)
    delay.delay_ms(RELAY_SELF_TEST_MS)
    gpio.set_level(RELAY_GPIO, 0)
    relay_state = 0
end

local function relay_set(on)
    local target = on and 1 or 0
    if target == relay_state then
        return
    end
    gpio.set_level(RELAY_GPIO, target)
    relay_state = target
    print(string.format("[planter_sensor] relay -> %s (pump %s)",
        target == 1 and "ON" or "OFF",
        target == 1 and "running" or "stopped"))
end

local function init_display()
    if not has_display then
        return nil, "display module unavailable"
    end

    local panel_handle, io_handle, width, height, panel_if = bm.get_display_lcd_params("display_lcd")
    if not panel_handle then
        return nil, io_handle
    end

    local ok, err = pcall(display.init, panel_handle, io_handle, width, height, panel_if)
    if not ok then
        return nil, err
    end

    return {
        width = display.width,
        height = display.height,
    }
end

local function capture_sample(soil_adc, light_adc, dht_sensor)
    local soil_mv = read_adc_mv(soil_adc)
    local light_mv = read_adc_mv(light_adc)
    local temperature, humidity = read_dht_once(dht_sensor)
    return {
        timestamp = system.date("%Y-%m-%d %H:%M:%S"),
        soil_mv = soil_mv,
        soil_level = classify(soil_mv, cfg.soil_levels),
        light_mv = light_mv,
        light_level = classify(light_mv, cfg.light_levels),
        temperature = temperature,
        humidity = humidity,
    }
end

local function hour_key_now()
    return system.date("%Y-%m-%dT%H")
end

local function history_path_for(day)
    return storage.join_path(HISTORY_DIR, day .. ".json")
end

local function load_day(path)
    if not storage.exists(path) then
        return {}
    end
    local ok, content = pcall(storage.read_file, path)
    if not ok or type(content) ~= "string" or content == "" then
        return {}
    end
    local parse_ok, data = pcall(json.decode, content)
    if not parse_ok or type(data) ~= "table" then
        return {}
    end
    return data
end

local function save_day(path, list)
    local enc_ok, payload = pcall(json.encode, list)
    if not enc_ok then
        return false, payload
    end
    return pcall(storage.write_file, path, payload)
end

local function sample_to_record(sample, hk, pump_pulses)
    return {
        hour = hk,
        timestamp = sample.timestamp,
        soil_mv = sample.soil_mv,
        soil_code = code_from_levels(sample.soil_mv, cfg.soil_levels),
        light_mv = sample.light_mv,
        light_code = code_from_levels(sample.light_mv, cfg.light_levels),
        temperature = sample.temperature,
        temp_code = temp_code_of(sample.temperature),
        humidity = sample.humidity,
        hum_code = hum_code_of(sample.humidity),
        pump_pulses = pump_pulses,
    }
end

local function upsert_hour(list, record)
    for i, entry in ipairs(list) do
        if entry.hour == record.hour then
            list[i] = record
            return list
        end
    end
    list[#list + 1] = record
    while #list > HISTORY_MAX_ENTRIES_PER_DAY do
        table.remove(list, 1)
    end
    return list
end

local last_saved_hour = nil

-- Pump pulse counter is declared here (before try_persist) because
-- try_persist captures pump_pulses_snapshot / pump_pulses_reset; Lua
-- locals are only visible after their declaration, so forward refs
-- would silently bind to (nil) globals and crash on first call.
local pump_pulses_running = 0

local function pump_pulses_snapshot()
    return pump_pulses_running
end

local function pump_pulses_reset()
    pump_pulses_running = 0
end

-- Writes one entry per wall-clock hour. The pump pulse counter is read
-- BEFORE reset, so each new entry's pump_pulses field captures the just-
-- finished hour.
local function try_persist(sample, force)
    if not sample then
        return
    end
    local hk = hour_key_now()
    if (not force) and hk == last_saved_hour then
        return
    end
    local pulses_for_record = pump_pulses_snapshot()
    local day = system.date("%Y-%m-%d")
    local path = history_path_for(day)
    local list = load_day(path)
    upsert_hour(list, sample_to_record(sample, hk, pulses_for_record))
    local ok, err = save_day(path, list)
    if ok then
        last_saved_hour = hk
        pump_pulses_reset()
        print(string.format("[planter_sensor] history saved %s pulses=%d (%d entries) -> %s",
            hk, pulses_for_record, #list, path))
    else
        print("[planter_sensor] history save failed: " .. tostring(err))
    end
end

-- Pump state machine: idle -> pumping (cfg.pump_pulse_ms) -> cooldown
-- (cfg.pump_cooldown_ms) -> idle. Driven every LOOP_MS tick so the pulse/
-- cooldown timing does not depend on the slower sensor sampling cadence.
-- The persistor owns the pulse-counter reset (see try_persist).
local pump_state = "idle"
local pump_state_until_ms = 0

local function pump_tick(now_ms, latest_soil_mv)
    if pump_state == "pumping" then
        if now_ms >= pump_state_until_ms then
            relay_set(false)
            pump_state = "cooldown"
            pump_state_until_ms = now_ms + cfg.pump_cooldown_ms
        end
        return
    end

    if pump_state == "cooldown" then
        if now_ms >= pump_state_until_ms then
            pump_state = "idle"
        end
        return
    end

    if latest_soil_mv ~= nil and latest_soil_mv <= cfg.soil_pump_threshold_mv then
        relay_set(true)
        pump_state = "pumping"
        pump_state_until_ms = now_ms + cfg.pump_pulse_ms
        pump_pulses_running = pump_pulses_running + 1
        print(string.format("[planter_sensor] pump pulse #%d (soil=%dmV)",
            pump_pulses_running, latest_soil_mv))
    end
end

local touch_until_ms = 0
local touch_anger_until_ms = 0
local touch_times = {}

local overlay_frames = {}
local ui_overlay_kind = nil
local ui_overlay_until_ms = 0

local function load_overlay_assets()
    if not has_image then
        print("[planter_sensor] image module unavailable; overlays disabled")
        return
    end
    for kind, path in pairs(OVERLAY_ASSETS) do
        local ok, err = pcall(function()
            local src = image.load_file(path)
            local rgb = image.convert(src, image.RGB565)
            local small = image.resize(rgb, {
                width = OVERLAY_W,
                height = OVERLAY_H,
                filter = "bilinear",
            })
            src:release()
            rgb:release()
            overlay_frames[kind] = small
        end)
        if not ok then
            print("[planter_sensor] overlay load failed (" .. kind .. " <- " ..
                  path .. "): " .. tostring(err))
        end
    end
end

local function init_ui_queue()
    -- queue_create may error if the queue already exists across script
    -- restarts; that is fine, we only need the queue to exist.
    local ok, err = pcall(function()
        thread.sync.queue_create(UI_QUEUE, {
            depth = UI_QUEUE_DEPTH,
            item_size = UI_QUEUE_ITEM_SIZE,
        })
    end)
    if not ok then
        print("[planter_sensor] queue_create(" .. UI_QUEUE .. ") note: " .. tostring(err))
    end
end

local function handle_ui_cmd(cmd, now_ms)
    if type(cmd) ~= "table" or cmd.kind ~= "show_icon" then
        print("[planter_sensor] unsupported ui cmd: " .. tostring(cmd and cmd.kind))
        return
    end
    if not overlay_frames[cmd.icon] then
        print("[planter_sensor] unknown or unloaded ui icon: " .. tostring(cmd.icon))
        return
    end
    local duration = tonumber(cmd.duration_ms) or UI_ICON_DEFAULT_MS
    if duration < 0 then duration = 0 end
    ui_overlay_kind = cmd.icon
    ui_overlay_until_ms = now_ms + duration
    print(string.format("[planter_sensor] ui cmd: show_icon=%s for %dms",
        cmd.icon, duration))
end

local function poll_ui_cmd(now_ms)
    -- Non-blocking drain so a burst from peers does not stretch across ticks.
    while true do
        local payload, err = thread.sync.queue_recv(UI_QUEUE, 0)
        if not payload then
            return
        end
        local ok, cmd = pcall(json.decode, payload)
        if ok then
            handle_ui_cmd(cmd, now_ms)
        else
            print("[planter_sensor] ui payload decode failed: " .. tostring(cmd) ..
                  " raw=" .. tostring(payload))
        end
        _ = err
    end
end

local current_eaf_path = nil
local eaf_frame_index = 0
local eaf_total_frames = 1
local eaf_total_cap = {}
local eaf_failed_logged = {}

local EAF_DRAW_OPTS = { rotate_ccw90 = false }

local function eaf_is_portrait_planter_path(path)
    if not path then
        return false
    end
    local prefix = EAF_DIR .. "/"
    return string.sub(path, 1, #prefix) == prefix
end

local function eaf_effective_total(path, reported)
    if not reported or reported < 1 then
        return 1
    end
    local cap = eaf_total_cap[path]
    if cap then
        return (reported < cap) and reported or cap
    end
    if eaf_is_portrait_planter_path(path) and reported > 1 then
        return reported - 1
    end
    return reported
end

local function on_touch_pressed(now_ms)
    local kept = {}
    for _, t in ipairs(touch_times) do
        if now_ms - t <= TOUCH_WINDOW_MS then
            kept[#kept + 1] = t
        end
    end
    kept[#kept + 1] = now_ms
    touch_times = kept

    if #touch_times >= TOUCH_ANGER_COUNT then
        touch_anger_until_ms = now_ms + TOUCH_ANGER_SHOW_MS
        touch_until_ms = 0
    else
        touch_until_ms = now_ms + TOUCH_SHOW_MS
    end
end

-- Picks the base EAF (overlays are composited on top separately).
-- Priority: touch reactions > environmental (temp -> soil -> light) > idle hi.
local function pick_active_eaf(sample, now_ms)
    if now_ms < touch_anger_until_ms then return EAF_TOUCH_ANGER end
    if now_ms < touch_until_ms then return EAF_TOUCH end
    if sample then
        if sample.temperature ~= nil then
            if sample.temperature < cfg.temp_cold_c then return EAF_COLD end
            if sample.temperature > cfg.temp_hot_c then return EAF_HOT end
        end
        if sample.soil_level then
            if sample.soil_level.code == "S0" then return EAF_DRY end
            if sample.soil_level.code == "S5" then return EAF_WET end
        end
        if sample.light_level then
            if sample.light_level.code == "L0" then return EAF_DARK end
            if sample.light_level.code == "L5" then return EAF_LIGHT end
        end
    end
    return EAF_HI
end

local function active_overlay_frame(now_ms)
    if not ui_overlay_kind or now_ms >= ui_overlay_until_ms then
        return nil
    end
    return overlay_frames[ui_overlay_kind]
end

local function render_eaf(path, now_ms)
    if not has_display or not has_eaf then
        return true
    end
    if path ~= current_eaf_path then
        eaf_frame_index = 0
        eaf_total_frames = eaf_total_cap[path] or 1
        pcall(function() display_eaf.release() end)
        current_eaf_path = path
    end
    local frame_to_render = eaf_frame_index % eaf_total_frames
    local reported_total
    local ok, err = pcall(function()
        display.begin_frame({ clear = true, color = "black" })
        local _, _, total = display_eaf.draw_file(0, 0, path, frame_to_render, EAF_DRAW_OPTS)
        reported_total = (total and total > 0) and total or 1
        local overlay = active_overlay_frame(now_ms)
        if overlay then
            local ox = display.width - OVERLAY_W - OVERLAY_PAD
            local oy = OVERLAY_PAD
            display.draw_image(ox, oy, overlay)
        end
        display.present()
    end)
    if ok then
        local effective_total = eaf_effective_total(path, reported_total)
        eaf_total_cap[path] = effective_total
        eaf_total_frames = effective_total
        eaf_frame_index = (frame_to_render + 1) % effective_total
    else
        if frame_to_render > 0 then
            eaf_total_cap[path] = frame_to_render
            eaf_total_frames = frame_to_render
        else
            eaf_total_cap[path] = 1
            eaf_total_frames = 1
        end
        eaf_frame_index = 0
        if not eaf_failed_logged[path] then
            eaf_failed_logged[path] = true
            print("[planter_sensor] eaf render failed (" .. tostring(path) .. ", frame " ..
                  tostring(frame_to_render) .. "): " .. tostring(err) ..
                  " (valid frames 0.." .. tostring(eaf_total_frames - 1) .. ")")
        end
        return false
    end
    return true
end

local function warmup_eafs()
    if not has_display or not has_eaf then
        return true
    end
    local all_ok = true
    for _, path in ipairs(ALL_EAFS) do
        local ok, err = pcall(function()
            display.begin_frame({ clear = true, color = "black" })
            display_eaf.draw_file(0, 0, path, 0, EAF_DRAW_OPTS)
            display.present()
        end)
        if not ok then
            all_ok = false
            print("[planter_sensor] warmup " .. path .. " failed: " .. tostring(err))
            break
        end
    end
    pcall(function() display_eaf.release() end)
    return all_ok
end

local board_info, board_err = bm.get_board_info()
if not board_info then
    error("[planter_sensor] get_board_info failed: " .. tostring(board_err))
end
print("[planter_sensor] board: " .. tostring(board_info.name))

local soil_adc, soil_open_err = open_adc(SOIL_ADC_GPIO)
local light_adc, light_open_err = open_adc(LIGHT_ADC_GPIO)
if not soil_adc then
    print("[planter_sensor] soil adc open failed: " .. tostring(soil_open_err))
end
if not light_adc then
    print("[planter_sensor] light adc open failed: " .. tostring(light_open_err))
end

local dht_sensor, dht_open_err = open_dht_sensor()
if not dht_sensor then
    print("[planter_sensor] dht open failed: " .. tostring(dht_open_err))
end

local touch_keys
if has_touch then
    local touch_open_ok, touch_open_err = pcall(function()
        touch_keys = touch.new(TOUCH_DEVICE)
    end)
    if not touch_open_ok or not touch_keys then
        print("[planter_sensor] touch open failed: " .. tostring(touch_open_err))
        touch_keys = nil
    else
        print("[planter_sensor] touch opened: " .. tostring(touch_keys:name()))
    end
end

local display_ctx, display_err = init_display()
if not display_ctx then
    print("[planter_sensor] display unavailable: " .. tostring(display_err))
end
local next_display_retry_ms = display_ctx and 0 or (system.millis() + DISPLAY_RETRY_MS)

print("[planter_sensor] starting relay self-test on GPIO" .. RELAY_GPIO)
relay_init()
print("[planter_sensor] relay self-test done")

if display_ctx and not warmup_eafs() then
    print("[planter_sensor] display warmup failed; retrying init in " .. tostring(DISPLAY_RETRY_MS) .. "ms")
    display_ctx = nil
    current_eaf_path = nil
    next_display_retry_ms = system.millis() + DISPLAY_RETRY_MS
end
load_overlay_assets()
init_ui_queue()

local mkdir_ok, mkdir_err = pcall(storage.mkdir, HISTORY_DIR)
if not mkdir_ok then
    print("[planter_sensor] history mkdir note: " .. tostring(mkdir_err))
end
print("[planter_sensor] wall-clock at boot: " .. tostring(system.date()))
print("[planter_sensor] history dir: " .. HISTORY_DIR)
print("[planter_sensor] config path:  " .. CONFIG_PATH)
try_reload_config(true)

print("[planter_sensor] entering resident EAF state-machine loop")

local prev_pressed = {}
local last_sample = nil
local last_sensor_ms = -SENSOR_INTERVAL_MS
local last_save_check_ms = -SAVE_CHECK_MS
local last_cfg_check_ms = -CONFIG_RELOAD_CHECK_MS
local startup_persist_done = false

while true do
    local now_ms = system.millis()

    if now_ms - last_cfg_check_ms >= CONFIG_RELOAD_CHECK_MS then
        last_cfg_check_ms = now_ms
        try_reload_config(false)
    end

    poll_ui_cmd(now_ms)

    if now_ms - last_sensor_ms >= SENSOR_INTERVAL_MS then
        last_sensor_ms = now_ms
        last_sample = capture_sample(soil_adc, light_adc, dht_sensor)

        -- Force one write so peers always find at least one entry.
        if not startup_persist_done then
            try_persist(last_sample, true)
            startup_persist_done = true
        end
    end

    pump_tick(now_ms, last_sample and last_sample.soil_mv or nil)

    if now_ms - last_save_check_ms >= SAVE_CHECK_MS then
        last_save_check_ms = now_ms
        try_persist(last_sample, false)
    end

    if touch_keys then
        local read_ok, touch_sample = pcall(function()
            return touch_keys:read()
        end)
        if read_ok and touch_sample and touch_sample.keys then
            for _, key in ipairs(touch_sample.keys) do
                local was_pressed = prev_pressed[key.index] or false
                if key.pressed and not was_pressed then
                    print(string.format("[planter_sensor] touch key%d (gpio%d) pressed", key.index, key.gpio))
                    on_touch_pressed(now_ms)
                end
                prev_pressed[key.index] = key.pressed and true or false
            end
        elseif not read_ok then
            print("[planter_sensor] touch read failed: " .. tostring(touch_sample))
        end
    end

    if not display_ctx and has_display and now_ms >= next_display_retry_ms then
        display_ctx, display_err = init_display()
        if display_ctx then
            print("[planter_sensor] display recovered")
            current_eaf_path = nil
            eaf_failed_logged = {}
        else
            next_display_retry_ms = now_ms + DISPLAY_RETRY_MS
        end
    end

    if display_ctx then
        local path = pick_active_eaf(last_sample, now_ms)
        if not render_eaf(path, now_ms) then
            print("[planter_sensor] display lost; retrying init in " .. tostring(DISPLAY_RETRY_MS) .. "ms")
            display_ctx = nil
            current_eaf_path = nil
            next_display_retry_ms = now_ms + DISPLAY_RETRY_MS
            pcall(function() display_eaf.release() end)
        end
    end

    delay.delay_ms(LOOP_MS)
end
