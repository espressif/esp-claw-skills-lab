-- token_usage_config.lua
local system = require("system")

local M = {}

M.DEFAULT_SCRIPT_PATH = "/fatfs/skills/token_usage/scripts/token_usage.lua"
M.default_port = 8080
M.memory_interval_hours = 1
M.letter_send_minute = 0
M.letter_cron_expr = "0 * * * *"
M.default_letter_language = "Chinese"
M.letter_persona_name = "ESP-Claw"
M.PILL_TOTAL = 12
M.RING_START_ANGLE = 270
M.LED_CHASE_INTERVAL_MS = 250
M.LED_CHASE_STEP_MS = 200

M.COLOR = {
    bg = "#000000",
    panel = "#292929",
    panel_soft = "#353535",
    pill_gray = "#565656",
    white = "#ffffff",
    text_dim = "#a8a8a8",
    text_muted = "#7f7f7f",
    blue = "#5fd9ff",
    green = "#6fe666",
    yellow = "#ffd947",
    orange = "#ff9762",
    red = "#fd5154",
}

M.LAYOUT = {
    top_y = 25,
    panel_x = 18,
    panel_y = 49,
    panel_w = 119,
    panel_h = 138,
    panel_radius = 20,
    radio_x = 32,
    radio_size = 20,
    radio_y0 = 60,
    radio_step = 31,
    label_x = 60,
    usage_box_x = 132,
    usage_box_y = 49,
    usage_box_w = 152,
    usage_box_h = 148,
    ring_x = 30,
    ring_y = 4,
    ring_size = 92,
    ring_width = 16,
    usage_title_y = 30,
    usage_pct_y = 44,
    model_line1_y = 98,
    model_line2_y = 114,
    pill_y = 205,
    pill_w = 10,
    pill_h = 17,
    pill_radius = 6,
    pill_step = 16,
    pill_x0 = 51,
    date_x = 20,
    weekday_x = 70,
    time_x = 108,
    weather_x = 150,
    weather_dot_x = 165,
    weather_icon_x = 180,
    weather_icon_y = 20,
    city_x = 210,
    person_x = 30,
    person_y = 201,
    person_w = 16,
    person_h = 24,
}

function M.as_string(value, default)
    if type(value) == "string" and value ~= "" then
        return value
    end
    return default
end

function M.as_int(value, default, min_value, max_value)
    if type(value) ~= "number" then
        return default
    end
    local out = math.floor(value)
    if min_value ~= nil and out < min_value then
        out = min_value
    end
    if max_value ~= nil and out > max_value then
        out = max_value
    end
    return out
end

function M.as_bool(value, default)
    if type(value) == "boolean" then
        return value
    end
    return default
end

function M.sanitize_id(text, fallback)
    local value = M.as_string(text, fallback)
    value = value:gsub("[^%w_-]", "_")
    if value == "" then
        return fallback
    end
    return value
end

function M.trim_text(value, max_len)
    local out = value
    if type(out) ~= "string" then
        out = tostring(out or "")
    end
    if max_len and #out > max_len then
        return string.sub(out, 1, max_len)
    end
    return out
end

function M.normalize_http_text(text)
    local out = tostring(text or "")
    out = out:gsub("\r\n", "\n")
    out = out:gsub("\r", "\n")
    return out
end

function M.preview_text(text, max_len)
    local out = M.trim_text(text, max_len or 160)
    out = out:gsub("\n", "\\n")
    return out
end

function M.contains_ci(haystack, needle)
    if type(haystack) ~= "string" or type(needle) ~= "string" or needle == "" then
        return false
    end
    return string.find(string.lower(haystack), string.lower(needle), 1, true) ~= nil
end

function M.coerce_text(value, max_len)
    if type(value) == "string" then
        return M.trim_text(value, max_len)
    end
    if type(value) == "number" then
        return M.trim_text(tostring(value), max_len)
    end
    return nil
end

function M.build_ctx(raw_args)
    raw_args = type(raw_args) == "table" and raw_args or {}
    return {
        host = M.as_string(raw_args.host, M.as_string(raw_args.pc_ip, "")),
        port = M.as_int(raw_args.port, 8080, 1, 65535),
        script_path = M.as_string(raw_args.script_path, M.DEFAULT_SCRIPT_PATH),
        cursor_poll_ms = M.as_int(raw_args.status_poll_ms or raw_args.cursor_poll_ms, 1000, 500, 60000),
        token_poll_ms = M.as_int(raw_args.token_poll_ms, 30000, 1000, 600000),
        aux_poll_ms = M.as_int(raw_args.aux_poll_ms, 30000, 1000, 600000),
        weather_poll_ms = M.as_int(raw_args.weather_poll_ms, 600000, 1000, 3600000),
        weather_retry_ms = M.as_int(raw_args.weather_retry_ms, 10000, 1000, 600000),
        http_timeout_ms = M.as_int(raw_args.http_timeout_ms, 5000, 1000, 60000),
        instance_id = M.sanitize_id(raw_args.instance_id, tostring(system.millis())),
        led_gpio = M.as_int(raw_args.led_gpio, 27, 0, 48),
        led_count = M.as_int(raw_args.led_count, 5, 1, 64),
    }
end

function M.pct_color_hex(pct)
    if pct < 80 then
        return M.COLOR.blue
    end
    if pct < 90 then
        return M.COLOR.yellow
    end
    return M.COLOR.red
end

function M.state_color_hex(state_index, hook_status)
    if state_index == 0 then
        return M.COLOR.blue
    end
    if state_index == 1 then
        if hook_status == "yellow" then
            return M.COLOR.yellow
        end
        if hook_status == "red" then
            return M.COLOR.red
        end
        return M.COLOR.green
    end
    if state_index == 2 then
        return M.COLOR.red
    end
    return M.COLOR.orange
end

function M.now_ms()
    return system.millis()
end

function M.date_field(fmt)
    local ok, value = pcall(system.date, fmt)
    if ok and type(value) == "string" then
        return value
    end
    return nil
end

function M.current_time_info()
    local month = tonumber(M.date_field("%m"))
    local day = tonumber(M.date_field("%d"))
    local weekday_num = tonumber(M.date_field("%w"))
    local weekday_name = M.date_field("%a")
    local hour = tonumber(M.date_field("%H"))
    local minute = tonumber(M.date_field("%M"))
    local yday = tonumber(M.date_field("%j"))
    local year = tonumber(M.date_field("%Y"))

    if not month or not day or not weekday_num or not weekday_name or not hour or not minute or not yday or not year then
        return nil
    end

    return {
        date_text = string.format("%02d/%02d", month, day),
        weekday_text = weekday_name,
        weekday_num = weekday_num,
        time_text = string.format("%02d:%02d", hour, minute),
        hour = hour,
        minute = minute,
        day_key = string.format("%04d-%03d", year, yday),
    }
end

return M
