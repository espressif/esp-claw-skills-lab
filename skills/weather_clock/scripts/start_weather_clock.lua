local arg_schema = require("arg_schema")
local board_manager = require("board_manager")
local capability = require("capability")
local delay = require("delay")
local json = require("json")
local lvgl = require("lvgl")
local storage = require("storage")
local system = require("system")
local thread = require("thread")

local DEFAULT_LOCATION = "Shanghai"
local DEFAULT_TIMEZONE = "Asia/Shanghai"

local WEATHER_REFRESH_MS = 60 * 60 * 1000
local CLOCK_REFRESH_MS = 1000
local LOOP_MS = 100
local HTTP_TIMEOUT_MS = 12000
local CONFIG_POLL_MS = 2000
local CONTROL_QUEUE_DEPTH = 8
local CONTROL_QUEUE_ITEM_SIZE = 2048
local CONTROL_APP_ID = "weather_clock"
local CONFIG_DIR = "weather_clock"
local CONFIG_FILE = "config.json"
local COMMAND_FILE = "command.json"

local raw_args = type(args) == "table" and args or {}
local ctx = arg_schema.parse(args, {})

ctx.location = type(raw_args.location) == "string" and raw_args.location ~= "" and raw_args.location or DEFAULT_LOCATION
ctx.timezone = type(raw_args.timezone) == "string" and raw_args.timezone ~= "" and raw_args.timezone or DEFAULT_TIMEZONE
ctx.api_key = type(raw_args.api_key) == "string" and raw_args.api_key ~= "" and raw_args.api_key
    or type(raw_args.key) == "string" and raw_args.key ~= "" and raw_args.key
    or ""
ctx.mode = raw_args.mode == "query" and "query" or "switch"

local panel_w = 0
local panel_h = 0
local touch_registered = false
local fonts = {}
local ui = {}
local paths = {}
local active_config_sig = nil
local active_command_sig = nil
local control_queue = nil
local control_worker_job = nil
local last_config_check_ms = -CONFIG_POLL_MS
local update_weather_labels
local state = {
    location = ctx.location,
    api_key = ctx.api_key,
    timezone = ctx.timezone,
    weather = nil,
    manual_icon = nil,
    last_clock_text = nil,
    last_date_text = nil,
    last_weather_ms = -WEATHER_REFRESH_MS,
    force_weather = true,
}

local ICON_KINDS = {
    clear = true,
    sunny = "clear",
    sun = "clear",
    cloudy = true,
    cloud = "cloudy",
    partly = true,
    partly_cloudy = "partly",
    rain = true,
    rainy = "rain",
    thunder = true,
    thunderstorm = "thunder",
    snow = true,
    snowy = "snow",
    wind = true,
    windy = "wind",
    fog = true,
    foggy = "fog",
    night = true,
}

local function normalize_icon_kind(value)
    value = string.lower(tostring(value or ""))
    value = string.gsub(value, "%s+", "_")
    value = string.gsub(value, "%-", "_")
    if value == "auto" or value == "default" or value == "reset" or value == "weather" then
        return nil, true
    end
    local mapped = ICON_KINDS[value]
    if mapped == true then
        return value, true
    elseif type(mapped) == "string" then
        return mapped, true
    end
    return nil, false
end

local function now_ms()
    return system.millis()
end

local function ensure_dir(path)
    if not storage.exists(path) then
        storage.mkdir(path)
    end
end

local function init_paths()
    paths.base = storage.join_path(storage.get_root_dir(), CONFIG_DIR)
    paths.config = storage.join_path(paths.base, CONFIG_FILE)
    paths.command = storage.join_path(paths.base, COMMAND_FILE)
    ensure_dir(paths.base)
end

local function current_script_dir()
    if type(debug) ~= "table" or type(debug.getinfo) ~= "function" then
        error("weather_control_server path is required when debug.getinfo is unavailable")
    end
    local source = debug.getinfo(1, "S").source or ""
    local path = string.match(source, "^@(.+)$") or source
    return string.match(path, "^(.*)/[^/]+$") or "."
end

local function parse_http_output(output)
    output = tostring(output or "")
    local status = tonumber(string.match(output, "^HTTP%s+(%d+)"))
    local body = string.match(output, "^HTTP%s+%d+[^\n]*\n(.*)$") or ""
    return status, body
end

local function http_get(url, label, max_body_bytes)
    print("[weather_clock] HTTP " .. tostring(label))
    local ok, out, err = capability.call("http_request", {
        url = url,
        method = "GET",
        timeout_ms = HTTP_TIMEOUT_MS,
        max_body_bytes = max_body_bytes or 8192,
    }, {
        source_cap = "weather_clock",
        max_output_bytes = (max_body_bytes or 8192) + 128,
    })

    if not ok then
        return nil, tostring(err or out)
    end

    local status, body = parse_http_output(out)
    if not status then
        return nil, "unexpected HTTP output for " .. label
    end
    if status < 200 or status >= 300 then
        local ok_json, data = pcall(function()
            return json.decode(body)
        end)
        if ok_json and type(data) == "table" and type(data.status) == "string" then
            return nil, string.format("%s returned HTTP %d: %s", label, status, data.status)
        end
        return nil, string.format("%s returned HTTP %d", label, status)
    end
    return body, nil
end

local function url_encode(text)
    text = tostring(text or "")
    text = string.gsub(text, "\n", " ")
    return (string.gsub(text, "([^%w%-%._~ ])", function(c)
        return string.format("%%%02X", string.byte(c))
    end):gsub(" ", "%%20"))
end

local function safe_date(fmt)
    local ok_time, timestamp = pcall(system.time)
    if not ok_time or type(timestamp) ~= "number" or timestamp < 1700000000 then
        return nil
    end

    local ok, text = pcall(system.date, fmt)
    if ok and type(text) == "string" and text ~= "" then
        return text
    end
    return nil
end

local function load_font(size, cache_size)
    local path = storage.join_path(storage.get_root_dir(), "fonts", "NotoSansSC-Regular.ttf")
    if not storage.exists(path) then
        return nil
    end
    local ok, font = pcall(lvgl.font_load, path, {
        size = size,
        cache_size = cache_size or 96,
    })
    if ok and font and font.is_valid and font:is_valid() then
        return font
    end
    return nil
end

local function font(size_name)
    return fonts[size_name]
end

local function set_text(label, text)
    if label then
        label:set_text(tostring(text or ""))
    end
end

local function ascii_text(text, fallback)
    text = tostring(text or "")
    if text == "" then
        return fallback or ""
    end
    if string.find(text, "[^\032-\126]") then
        return fallback or "Location"
    end
    return text
end

local function config_signature(cfg)
    return string.format("%s|%s|%s",
        tostring(cfg.location or ""),
        tostring(cfg.timezone or ""),
        tostring(cfg.api_key or ""))
end

local function normalized_config(source)
    source = type(source) == "table" and source or {}
    local cfg = {}
    cfg.location = type(source.location) == "string" and source.location ~= "" and source.location or DEFAULT_LOCATION
    cfg.timezone = type(source.timezone) == "string" and source.timezone ~= "" and source.timezone or DEFAULT_TIMEZONE
    cfg.api_key = type(source.api_key) == "string" and source.api_key ~= "" and source.api_key
        or type(source.key) == "string" and source.key ~= "" and source.key
        or ""
    return cfg
end

local function load_config()
    if not paths.config or not storage.exists(paths.config) then
        return nil
    end
    local ok, parsed = pcall(function()
        return json.decode(storage.read_file(paths.config))
    end)
    if ok and type(parsed) == "table" then
        return normalized_config(parsed)
    end
    print("[weather_clock] ignored invalid config")
    return nil
end

local function save_config(cfg)
    storage.write_file(paths.config, json.encode(normalized_config(cfg)))
end

local function clear_command()
    if paths.command and storage.exists(paths.command) then
        pcall(storage.remove, paths.command)
    end
    active_command_sig = nil
end

local function raw_args_have_config()
    return type(raw_args.location) == "string" and raw_args.location ~= ""
        or type(raw_args.timezone) == "string" and raw_args.timezone ~= ""
        or type(raw_args.api_key) == "string" and raw_args.api_key ~= ""
        or type(raw_args.key) == "string" and raw_args.key ~= ""
end

local function display_config(cfg)
    cfg = normalized_config(cfg)
    ctx.location = cfg.location
    ctx.timezone = cfg.timezone
    if cfg.api_key ~= "" then
        ctx.api_key = cfg.api_key
    end

    state.location = ascii_text(ctx.location, DEFAULT_LOCATION)
    state.api_key = ctx.api_key
    state.timezone = ctx.timezone
    state.weather = nil
    state.force_weather = true

    if ui.location then
        update_weather_labels()
    end
end

local function apply_config(cfg, persist)
    cfg = normalized_config(cfg)
    display_config(cfg)
    active_config_sig = config_signature(cfg)

    if persist then
        save_config(cfg)
    end
end

local function apply_startup_config()
    local saved = load_config()
    if saved then
        apply_config(saved, false)
    end

    if raw_args_have_config() then
        apply_config({
            location = ctx.location,
            timezone = ctx.timezone,
            api_key = ctx.api_key,
        }, ctx.mode ~= "query")
        clear_command()
    elseif not saved then
        apply_config({
            location = DEFAULT_LOCATION,
            timezone = DEFAULT_TIMEZONE,
            api_key = ctx.api_key,
        }, true)
    end
end

local function poll_config(now)
    if now - last_config_check_ms < CONFIG_POLL_MS then
        return
    end
    last_config_check_ms = now
    local cfg = load_config()
    if cfg then
        local sig = config_signature(cfg)
        if sig ~= active_config_sig then
            print("[weather_clock] config changed; refreshing weather for " .. tostring(cfg.location))
            apply_config(cfg, false)
        end
    end

    if not paths.command or not storage.exists(paths.command) then
        return
    end
    local ok, command = pcall(function()
        return json.decode(storage.read_file(paths.command))
    end)
    if not ok or type(command) ~= "table" then
        return
    end

    local mode = type(command.mode) == "string" and command.mode or "query"
    local command_cfg = normalized_config(command)
    local command_sig = mode .. "|" .. tostring(command.seq or "") .. "|" .. config_signature(command_cfg)
    if command_sig == active_command_sig then
        return
    end
    active_command_sig = command_sig

    if mode == "switch" then
        print("[weather_clock] switch request; refreshing weather for " .. tostring(command_cfg.location))
        apply_config(command_cfg, true)
    else
        print("[weather_clock] query request; displaying weather for " .. tostring(command_cfg.location))
        display_config(command_cfg)
    end
end

local function init_control_queue()
    control_queue = "weather_clock_ctrl"
    pcall(function()
        thread.sync.queue_delete(control_queue)
    end)
    local ok, err = thread.sync.queue_create(control_queue, {
        depth = CONTROL_QUEUE_DEPTH,
        item_size = CONTROL_QUEUE_ITEM_SIZE,
    })
    if not ok then
        error("weather control queue create failed: " .. tostring(err))
    end
end

local function start_control_server()
    local worker_path = storage.join_path(current_script_dir(), "weather_control_server.lua")
    control_worker_job = "weather_clock_control"
    local ok, output = thread.start(worker_path, {
        app_id = CONTROL_APP_ID,
        queue_name = control_queue,
    }, {
        timeout_ms = 0,
        name = control_worker_job,
        exclusive = control_worker_job,
        replace = true,
    })
    if not ok then
        error("weather control server start failed: " .. tostring(output))
    end
end

local function process_icon_event(event)
    local raw_icon = event.icon or event.kind or event.weather_icon
    local icon, valid = normalize_icon_kind(raw_icon)
    if not valid then
        print("[weather_clock] icon request ignored: unknown icon " .. tostring(raw_icon))
        return
    end
    state.manual_icon = icon
    if icon then
        print("[weather_clock] manual icon set to " .. tostring(icon))
    else
        print("[weather_clock] manual icon cleared; using weather icon")
    end
    if ui.icon then
        update_weather_labels()
    end
end

local function process_control_event(event)
    if type(event) ~= "table" then
        return
    end
    if event.type == "icon" then
        process_icon_event(event)
        return
    end
    if event.type ~= "control" then
        return
    end
    local mode = event.mode == "query" and "query" or "switch"
    local cfg = normalized_config(event)
    if cfg.api_key == "" and state.api_key ~= "" then
        cfg.api_key = state.api_key
    end
    if cfg.api_key == "" then
        print("[weather_clock] control ignored: missing api_key")
        return
    end
    if mode == "query" then
        print("[weather_clock] control query; refreshing weather for " .. tostring(cfg.location))
        display_config(cfg)
    else
        print("[weather_clock] control switch; refreshing weather for " .. tostring(cfg.location))
        apply_config(cfg, true)
    end
end

local function process_control_events()
    if not control_queue then
        return
    end
    while true do
        local payload = thread.sync.queue_recv(control_queue, 0)
        if not payload then
            return
        end
        local ok, event = pcall(function()
            return json.decode(payload)
        end)
        if ok then
            process_control_event(event)
        end
    end
end

local function apply_font(obj, size_name)
    local f = font(size_name)
    if obj and f then
        obj:set_style({ font = f })
    end
end

local function label(parent, opts, size_name)
    local obj = lvgl.label(parent, opts)
    apply_font(obj, size_name)
    return obj
end

local function obj(parent, opts)
    return lvgl.object(parent, opts)
end

local function line(parent, x, y, w, h, points, color, width)
    local line_width = width or 2
    local min_x = 0
    local min_y = 0
    local max_x = w or 0
    local max_y = h or 0

    for _, p in ipairs(points or {}) do
        if type(p.x) == "number" and type(p.y) == "number" then
            min_x = math.min(min_x, p.x)
            min_y = math.min(min_y, p.y)
            max_x = math.max(max_x, p.x)
            max_y = math.max(max_y, p.y)
        end
    end

    local pad = math.max(2, line_width)
    local shifted = {}
    for i, p in ipairs(points or {}) do
        shifted[i] = {
            x = math.floor((p.x or 0) - min_x + pad),
            y = math.floor((p.y or 0) - min_y + pad),
        }
    end

    return lvgl.line(parent, {
        x = math.floor(x + min_x - pad),
        y = math.floor(y + min_y - pad),
        w = math.floor(max_x - min_x + pad * 2),
        h = math.floor(max_y - min_y + pad * 2),
        points = shifted,
        line_color = color,
        line_width = line_width,
    })
end

local function scaled_points(scale, coords)
    local points = {}
    for i, p in ipairs(coords) do
        points[i] = {
            x = p[1] * scale,
            y = p[2] * scale,
        }
    end
    return points
end

local function circle(parent, x, y, size, color)
    return obj(parent, {
        x = x,
        y = y,
        w = size,
        h = size,
        bg_color = color,
        bg_opa = 255,
        border_width = 0,
        radius = size // 2,
        pad = 0,
    })
end

local function round_rect(parent, x, y, w, h, radius, color)
    return obj(parent, {
        x = x,
        y = y,
        w = w,
        h = h,
        bg_color = color,
        bg_opa = 255,
        border_width = 0,
        radius = radius,
        pad = 0,
    })
end

local function filled_polygon(parent, x, y, coords, scale, color)
    local points = scaled_points(scale, coords)
    local min_x, min_y = points[1].x, points[1].y
    local max_x, max_y = min_x, min_y
    for _, p in ipairs(points) do
        min_x = math.min(min_x, p.x)
        min_y = math.min(min_y, p.y)
        max_x = math.max(max_x, p.x)
        max_y = math.max(max_y, p.y)
    end

    local pad = math.max(2, scale)
    local w = math.floor(max_x - min_x + pad * 2 + 1)
    local h = math.floor(max_y - min_y + pad * 2 + 1)
    local shifted = {}
    for i, p in ipairs(points) do
        shifted[i] = {
            x = p.x - min_x + pad,
            y = p.y - min_y + pad,
        }
    end

    local canvas = lvgl.canvas(parent, {
        x = math.floor(x + min_x - pad),
        y = math.floor(y + min_y - pad),
        w = w,
        h = h,
        color_format = "argb8888",
    })
    canvas:fill_bg("#000000", 0)

    for py = 0, h - 1 do
        local scan_y = py + 0.5
        local crosses = {}
        for i = 1, #shifted do
            local p1 = shifted[i]
            local p2 = shifted[(i % #shifted) + 1]
            if (p1.y <= scan_y and p2.y > scan_y) or (p2.y <= scan_y and p1.y > scan_y) then
                crosses[#crosses + 1] = p1.x + (scan_y - p1.y) * (p2.x - p1.x) / (p2.y - p1.y)
            end
        end
        table.sort(crosses)
        for i = 1, #crosses - 1, 2 do
            local x1 = math.max(0, math.floor(crosses[i]))
            local x2 = math.min(w - 1, math.ceil(crosses[i + 1]))
            for px = x1, x2 do
                canvas:set_px(px, py, color, 255)
            end
        end
    end
    return canvas
end

local function set_current_temperature(min_value, max_value)
    local min_n = tonumber(min_value)
    local max_n = tonumber(max_value)
    if min_n and max_n then
        set_text(ui.current_temp_value, string.format("%.0f-%.0f", min_n, max_n))
    elseif max_n then
        set_text(ui.current_temp_value, string.format("%.0f", max_n))
    elseif min_n then
        set_text(ui.current_temp_value, string.format("%.0f", min_n))
    else
        set_text(ui.current_temp_value, "--")
    end
end

local function draw_sun(parent, x, y, scale)
    local yellow = "#FFD947"
    local cx = x + 28 * scale
    local cy = y + 28 * scale
    local r = 13 * scale
    circle(parent, cx - r, cy - r, r * 2, yellow)
    local rays = {
        { 28, 0, 28, 10 }, { 28, 46, 28, 56 }, { 0, 28, 10, 28 }, { 46, 28, 56, 28 },
        { 8, 8, 15, 15 }, { 41, 41, 48, 48 }, { 8, 48, 15, 41 }, { 41, 15, 48, 8 },
    }
    for _, p in ipairs(rays) do
        line(parent, x + p[1] * scale, y + p[2] * scale, math.max(2, math.abs(p[3] - p[1]) * scale + 4),
            math.max(2, math.abs(p[4] - p[2]) * scale + 4), {
                { x = 0, y = 0 },
                { x = (p[3] - p[1]) * scale, y = (p[4] - p[2]) * scale },
            }, yellow, 3)
    end
end

local function draw_cloud(parent, x, y, scale)
    local white = "#ffffff"
    circle(parent, x + 13 * scale, y + 18 * scale, 20 * scale, white)
    circle(parent, x + 30 * scale, y + 8 * scale, 26 * scale, white)
    circle(parent, x + 51 * scale, y + 20 * scale, 24 * scale, white)
    round_rect(parent, x + 8 * scale, y + 29 * scale, 58 * scale, 18 * scale, 9 * scale, white)
end

local function draw_partly(parent, x, y, scale)
    draw_sun(parent, x + 18 * scale, y, scale)
    draw_cloud(parent, x, y + 25 * scale, scale)
end

local function draw_rain(parent, x, y, scale, thunder)
    draw_cloud(parent, x, y, scale)
    local blue = "#5FD9FF"
    local drops = {
        { 18, 54, 10 }, { 36, 54, 10 }, { 54, 54, 10 }, { 26, 70, 9 }, { 46, 70, 9 },
    }
    for _, d in ipairs(drops) do
        line(parent, x + d[1] * scale, y + d[2] * scale, 8 * scale, 12 * scale, {
            { x = 5 * scale, y = 0 },
            { x = 0, y = d[3] * scale },
        }, blue, 3)
    end
    if thunder then
        filled_polygon(parent, x + 39 * scale, y + 1 * scale, {
            { 10.7, 6.9 },
            { 16.4, 0 },
            { 15.6, 4.4 },
            { 20.9, 4.4 },
            { 13.3, 13.1 },
            { 16.4, 6.9 },
        }, scale * 2, "#FFD947")
    end
end

local function draw_snow(parent, x, y, scale)
    local blue = "#5FD9FF"
    line(parent, x + 36 * scale, y, 2, 70 * scale, {
        { x = 0, y = 0 },
        { x = 0, y = 68 * scale },
    }, blue, 3)
    line(parent, x + 5 * scale, y + 17 * scale, 64 * scale, 38 * scale, {
        { x = 0, y = 0 },
        { x = 62 * scale, y = 36 * scale },
    }, blue, 3)
    line(parent, x + 5 * scale, y + 53 * scale, 64 * scale, 38 * scale, {
        { x = 0, y = 0 },
        { x = 62 * scale, y = -36 * scale },
    }, blue, 3)
    local arms = {
        { 24, 8, 36, 18 }, { 48, 8, 36, 18 },
        { 24, 62, 36, 52 }, { 48, 62, 36, 52 },
        { 9, 30, 23, 27 }, { 14, 14, 23, 27 },
        { 9, 40, 23, 43 }, { 14, 56, 23, 43 },
        { 63, 30, 49, 27 }, { 58, 14, 49, 27 },
        { 63, 40, 49, 43 }, { 58, 56, 49, 43 },
    }
    for _, p in ipairs(arms) do
        line(parent, x + p[1] * scale, y + p[2] * scale, 16 * scale, 16 * scale, {
            { x = 0, y = 0 },
            { x = (p[3] - p[1]) * scale, y = (p[4] - p[2]) * scale },
        }, blue, 2)
    end
end

local function draw_wind(parent, x, y, scale)
    local blue = "#5FD9FF"
    line(parent, x, y, 72 * scale, 24 * scale, scaled_points(scale, {
        { 0, 20 }, { 12, 20 }, { 26, 20 }, { 40, 20 }, { 47, 19 },
        { 53, 15 }, { 55, 10 }, { 53, 5 }, { 48, 2 }, { 42, 1 },
    }), blue, 3)
    line(parent, x + 4 * scale, y + 18 * scale, 72 * scale, 26 * scale, scaled_points(scale, {
        { 0, 16 }, { 14, 16 }, { 32, 16 }, { 50, 16 }, { 60, 15 },
        { 68, 11 }, { 72, 6 }, { 70, 2 }, { 65, 0 }, { 60, 0 },
    }), blue, 3)
    line(parent, x + 4 * scale, y + 42 * scale, 66 * scale, 30 * scale, scaled_points(scale, {
        { 0, 0 }, { 16, 0 }, { 34, 0 }, { 48, 0 }, { 57, 3 },
        { 63, 9 }, { 65, 16 }, { 62, 23 }, { 56, 27 }, { 49, 26 },
    }), blue, 3)
end

local function draw_fog(parent, x, y, scale)
    local blue = "#5FD9FF"
    for i = 0, 2 do
        line(parent, x, y + (16 + i * 20) * scale, 78 * scale, 3, {
            { x = 0, y = 0 },
            { x = 76 * scale, y = 0 },
        }, blue, 3)
    end
end

local function draw_night(parent, x, y, scale)
    local yellow = "#FFD947"
    circle(parent, x + 8 * scale, y + 10 * scale, 48 * scale, yellow)
    circle(parent, x + 28 * scale, y + 3 * scale, 48 * scale, "#0b1220")
    line(parent, x + 56 * scale, y + 2 * scale, 24 * scale, 24 * scale, scaled_points(scale, {
        { 10, 0 }, { 13, 7 }, { 21, 7 }, { 15, 12 }, { 18, 20 },
        { 10, 15 }, { 2, 20 }, { 5, 12 }, { 0, 7 }, { 7, 7 }, { 10, 0 },
    }), yellow, 2)
end

local function draw_icon(kind)
    ui.icon:clean()
    local scale = panel_w >= 300 and 2 or 1
    local x = panel_w >= 300 and 26 or 18
    local y = panel_w >= 300 and 22 or 18
    if kind == "clear" then
        draw_sun(ui.icon, x + 4 * scale, y + 10 * scale, scale)
    elseif kind == "partly" then
        draw_partly(ui.icon, x - 6 * scale, y - 4 * scale, scale)
    elseif kind == "rain" then
        draw_rain(ui.icon, x - 2 * scale, y + 4 * scale, scale, false)
    elseif kind == "thunder" then
        draw_rain(ui.icon, x - 2 * scale, y + 4 * scale, scale, true)
    elseif kind == "snow" then
        draw_snow(ui.icon, x + 4 * scale, y + 2 * scale, scale)
    elseif kind == "wind" then
        draw_wind(ui.icon, x - 4 * scale, y + 12 * scale, scale)
    elseif kind == "fog" then
        draw_fog(ui.icon, x + 4 * scale, y + 18 * scale, scale)
    elseif kind == "night" then
        draw_night(ui.icon, x + 2 * scale, y + 4 * scale, scale)
    else
        draw_cloud(ui.icon, x - 4 * scale, y + 14 * scale, scale)
    end
end

local function weather_kind(code, text)
    code = tonumber(code) or 3
    if code == 0 then
        return "clear", "Clear"
    elseif code == 1 then
        return "clear", "Clear"
    elseif code == 2 or code == 3 or code == 5 or code == 6 then
        return "partly", "Partly Cloudy"
    elseif code == 4 or code == 7 or code == 8 or code == 9 then
        return "cloudy", "Cloudy"
    elseif code == 10 or code == 13 or code == 14 or code == 15 or code == 16 or code == 17 or code == 18
        or code == 19 or code == 20 then
        if code >= 15 and code <= 18 then
            return "rain", "Heavy Rain"
        end
        return "rain", "Rain"
    elseif code == 11 or code == 12 then
        return "thunder", "Thunderstorm"
    elseif code >= 21 and code <= 25 then
        return "snow", "Snow"
    elseif code == 26 or code == 27 or code == 28 or code == 29 or code == 32 or code == 33
        or code == 34 or code == 35 or code == 36 then
        return "wind", "Wind"
    elseif code == 30 or code == 31 then
        return "fog", "Fog"
    end
    if string.find(string.lower(tostring(text or "")), "rain") then
        return "rain", "Rain"
    end
    return "cloudy", "Cloudy"
end

local function maybe_night(kind)
    if kind ~= "clear" then
        return kind
    end
    local hh = safe_date("%H")
    local hour = tonumber(hh)
    if hour and (hour < 6 or hour >= 18) then
        return "night"
    end
    return kind
end

local function temp_number(value)
    local n = tonumber(value)
    if not n then
        return "--"
    end
    return string.format("%.0f", n)
end

local function ensure_seniverse_config()
    if type(state.api_key) == "string" and state.api_key ~= ""
        and type(state.location) == "string" and state.location ~= "" then
        return true, nil
    end
    return false, "Seniverse api_key and location are required"
end

local function seniverse_result(body, label)
    local ok, data = pcall(function()
        return json.decode(body)
    end)
    if not ok or type(data) ~= "table" then
        return nil, "invalid " .. label .. " JSON"
    end
    if type(data.status) == "string" then
        return nil, data.status
    end
    if type(data.results) ~= "table" or type(data.results[1]) ~= "table" then
        return nil, "missing " .. label .. " results"
    end
    return data.results[1], nil
end

local function update_time_text(value)
    value = tostring(value or "")
    local hhmm = string.match(value, "T(%d%d:%d%d)")
    return hhmm or safe_date("%H:%M") or "--:--"
end

local function fetch_weather()
    local ok_config, config_err = ensure_seniverse_config()
    if not ok_config then
        return nil, config_err
    end

    local common = "key=" .. url_encode(state.api_key)
        .. "&location=" .. url_encode(state.location)
        .. "&language=en&unit=c"
    local now_url = "http://api.seniverse.com/v3/weather/now.json?" .. common
    local daily_url = "http://api.seniverse.com/v3/weather/daily.json?" .. common .. "&start=0&days=2"

    local now_body, err = http_get(now_url, "Seniverse now", 12000)
    if not now_body then
        return nil, err
    end
    local daily_body, daily_err = http_get(daily_url, "Seniverse daily", 16000)
    if not daily_body then
        return nil, daily_err
    end

    local now_result, now_err = seniverse_result(now_body, "now")
    if not now_result then
        return nil, now_err
    end
    local daily_result, result_err = seniverse_result(daily_body, "daily")
    if not daily_result then
        return nil, result_err
    end

    local now = type(now_result.now) == "table" and now_result.now or {}
    local source_daily = type(daily_result.daily) == "table" and daily_result.daily or {}
    local location = type(now_result.location) == "table" and now_result.location
        or type(daily_result.location) == "table" and daily_result.location
        or {}

    local kind, desc = weather_kind(now.code, now.text)
    kind = maybe_night(kind)
    local daily = {
        time = {},
        weather_code = {},
        temperature_2m_max = {},
        temperature_2m_min = {},
    }
    for i = 1, math.min(2, #source_daily) do
        local item = source_daily[i]
        if type(item) == "table" then
            daily.time[i] = item.date
            daily.weather_code[i] = item.code_day
            daily.temperature_2m_max[i] = item.high
            daily.temperature_2m_min[i] = item.low
        end
    end

    return {
        location = ascii_text(location.name, state.location),
        kind = kind,
        desc = desc,
        code = now.code,
        temperature = now.temperature,
        daily = daily,
        fetched_at = update_time_text(now_result.last_update or daily_result.last_update),
    }, nil
end

local function daily_line(daily, index, fallback_name, show_name)
    local dates = type(daily.time) == "table" and daily.time or {}
    local codes = type(daily.weather_code) == "table" and daily.weather_code or {}
    local maxs = type(daily.temperature_2m_max) == "table" and daily.temperature_2m_max or {}
    local mins = type(daily.temperature_2m_min) == "table" and daily.temperature_2m_min or {}
    local _, desc = weather_kind(codes[index])
    local name = index == 1 and "Today" or "Tomorrow"
    if type(dates[index]) == "string" and dates[index] ~= "" then
        if show_name == false then
            name = string.sub(dates[index], 6)
        else
            name = name .. " " .. string.sub(dates[index], 6)
        end
    elseif show_name == false then
        name = "--"
    end
    if not codes[index] then
        return fallback_name
    end
    return string.format("%s  %s  %s/%s C",
        name,
        desc,
        temp_number(mins[index]),
        temp_number(maxs[index])
    )
end

local function daily_temperature_range(daily, index)
    local maxs = type(daily.temperature_2m_max) == "table" and daily.temperature_2m_max or {}
    local mins = type(daily.temperature_2m_min) == "table" and daily.temperature_2m_min or {}
    return mins[index], maxs[index]
end

function update_weather_labels()
    local weather = state.weather
    if not weather then
        set_text(ui.location, ascii_text(state.location or DEFAULT_LOCATION, DEFAULT_LOCATION))
        set_current_temperature(nil)
        set_text(ui.current_desc, "Loading")
        set_text(ui.tomorrow, "--")
        draw_icon(state.manual_icon or "cloudy")
        return
    end

    set_text(ui.location, ascii_text(weather.location, DEFAULT_LOCATION))
    local today_min, today_max = daily_temperature_range(weather.daily, 1)
    set_current_temperature(today_min, today_max or weather.temperature)
    set_text(ui.current_desc, weather.desc)
    set_text(ui.tomorrow, daily_line(weather.daily, 2, "--", false))
    set_text(ui.status, "Updated " .. tostring(weather.fetched_at))
    draw_icon(state.manual_icon or weather.kind)
end

local function update_clock_labels(force)
    local clock_text = safe_date("%H:%M")
    local date_text = safe_date("%Y-%m-%d")
    if not clock_text then
        clock_text = "--:--"
        date_text = "Waiting for SNTP"
    end

    if force or clock_text ~= state.last_clock_text then
        set_text(ui.clock, clock_text)
        state.last_clock_text = clock_text
    end
    if force or date_text ~= state.last_date_text then
        set_text(ui.date, date_text)
        state.last_date_text = date_text
    end
end

local function build_ui()
    fonts.clock = load_font(panel_w >= 300 and 62 or 44, 64)
    fonts.large = load_font(panel_w >= 300 and 30 or 24, 96)
    fonts.medium = load_font(panel_w >= 300 and 20 or 17, 96)
    fonts.small = load_font(panel_w >= 300 and 16 or 13, 96)

    local scr = lvgl.create_screen()
    scr:set_style({ bg_color = "#0b1220" })

    local root = lvgl.container(scr, {
        x = 0,
        y = 0,
        w = panel_w,
        h = panel_h,
        bg_color = "#0b1220",
        bg_opa = 255,
        border_width = 0,
        pad = 0,
    })

    ui.clock = label(root, {
        text = "--:--",
        x = 10,
        y = 6,
        w = panel_w - 20,
        h = panel_w >= 300 and 76 or 56,
        text_color = "#ffffff",
        align = "top_mid",
    }, "clock")

    ui.date = label(root, {
        text = "",
        x = 10,
        y = panel_w >= 300 and 76 or 58,
        w = panel_w - 20,
        h = 24,
        text_color = "#9fb3c8",
        align = "top_mid",
    }, "small")

    local top_y = panel_w >= 300 and 110 or 86
    local icon_size = math.max(96, math.min(150, panel_w // 2 - 8))
    ui.icon = lvgl.container(root, {
        x = 4,
        y = top_y - 20,
        w = icon_size,
        h = icon_size,
        bg_opa = 0,
        border_width = 0,
        pad = 0,
    })

    local right_x = icon_size + 8
    local right_w = panel_w - right_x - 8
    local temp_dot_offset = math.max(36, math.min(44, right_w - 60))
    local temp_unit_offset = temp_dot_offset + 10
    ui.location = label(root, {
        text = DEFAULT_LOCATION,
        x = right_x,
        y = top_y + 2,
        w = right_w,
        h = 24,
        text_color = "#9fb3c8",
    }, "small")
    ui.current_temp_value = label(root, {
        text = "--",
        x = right_x,
        y = top_y + 26,
        w = right_w - 52,
        h = 42,
        text_color = "#ffffff",
    }, "medium")
    ui.current_temp_dot = circle(root, right_x + temp_dot_offset + 1, top_y + 33, 6, "#ffffff")
    ui.current_temp_unit = label(root, {
        text = "C",
        x = right_x + temp_unit_offset - 2,
        y = top_y + 30,
        w = 20,
        h = 28,
        text_color = "#ffffff",
    }, "medium")
    ui.current_desc = label(root, {
        text = "Loading",
        x = right_x,
        y = top_y + 55,
        w = right_w,
        h = 30,
        text_color = "#FFD947",
    }, "medium")

    local bottom_status_y = panel_h - 39
    local bottom_tomorrow_y = bottom_status_y - 30

    ui.tomorrow = label(root, {
        text = "--",
        x = 15,
        y = bottom_tomorrow_y + 5,
        w = panel_w - 25,
        h = 28,
        text_color = "#ffffff",
    }, "small")

    ui.status = label(root, {
        text = "Ready",
        x = 15,
        y = bottom_status_y + 3,
        w = panel_w - 25,
        h = 20,
        text_color = "#73869c",
    }, "small")

    scr:load()
    update_clock_labels(true)
    update_weather_labels()
end

local function refresh_weather()
    set_text(ui.status, "Updating...")
    local weather, err = fetch_weather()
    if weather then
        state.weather = weather
        print(string.format("[weather_clock] weather updated location=%s code=%s temp=%s desc=%s",
            tostring(weather.location), tostring(weather.code), tostring(weather.temperature), tostring(weather.desc)))
    else
        print("[weather_clock] weather update failed: " .. tostring(err))
        set_text(ui.status, "Update failed")
    end
    update_weather_labels()
end

local function init_lvgl()
    board_manager.init_device("display_lcd")
    board_manager.init_device("lcd_touch")

    local panel_handle, io_handle, width, height, panel_if =
        board_manager.get_display_lcd_params("display_lcd")
    if not panel_handle then
        error("display_lcd not available")
    end

    lvgl.init(panel_handle, io_handle, width, height, panel_if, {
        buffer_lines = 40,
        tick_ms = 5,
        task_period_ms = 10,
    })
    panel_w = width
    panel_h = height

    local touch_handle = board_manager.get_lcd_touch_handle("lcd_touch")
    if touch_handle then
        local ok = pcall(lvgl.indev_register, "touch", touch_handle)
        touch_registered = ok
    end
end

local function cleanup()
    if control_worker_job then
        pcall(function()
            thread.stop(control_worker_job, 500)
        end)
        control_worker_job = nil
    end
    if control_queue then
        pcall(function()
            thread.sync.queue_delete(control_queue)
        end)
        control_queue = nil
    end
    if touch_registered then
        pcall(lvgl.indev_unregister, "touch")
        touch_registered = false
    end
    pcall(lvgl.deinit)
    for _, f in pairs(fonts) do
        if f and f.delete then
            pcall(function()
                f:delete()
            end)
        end
    end
end

local function run()
    init_paths()
    apply_startup_config()
    init_control_queue()
    start_control_server()
    init_lvgl()
    build_ui()
    print(string.format("[weather_clock] started location=%s api_key=%s timezone=%s",
        tostring(ctx.location), ctx.api_key ~= "" and "set" or "missing", tostring(ctx.timezone)))

    local last_clock_ms = -CLOCK_REFRESH_MS
    while true do
        local now = now_ms()
        process_control_events()
        poll_config(now)

        if state.force_weather or now - state.last_weather_ms >= WEATHER_REFRESH_MS then
            state.force_weather = false
            state.last_weather_ms = now
            refresh_weather()
        end

        if now - last_clock_ms >= CLOCK_REFRESH_MS then
            last_clock_ms = now
            update_clock_labels(false)
        end

        lvgl.process_events(LOOP_MS)
        delay.delay_ms(10)
    end
end

local ok, err = xpcall(run, debug.traceback)
cleanup()
if not ok then
    print("[weather_clock] ERROR: " .. tostring(err))
    error(err)
end
