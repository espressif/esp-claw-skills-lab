local capability = require("capability")
local delay = require("delay")
local display = require("display")
local canvas
-- Follow one contact by ID and preserve its last position on release.
local touch_id, touch_x, touch_y = nil, 0, 0
local function poll_touch_snapshot()
    local point
    local points = canvas:touch().points
    for _, candidate in ipairs(points) do
        if touch_id == nil or candidate.id == touch_id then point = candidate; break end
    end
    local was_pressed = touch_id ~= nil
    if point then touch_id, touch_x, touch_y = point.id, point.x, point.y else touch_id = nil end
    return { pressed = point ~= nil, just_pressed = point ~= nil and not was_pressed,
        just_released = point == nil and was_pressed, x = touch_x, y = touch_y }
end
-- Keep alignment local; the display API draws text at an explicit origin.
local function aligned_text(x, y, w, h, text, opts)
    opts = opts or {}
    opts.font_size = math.max(8, math.min(64, math.floor(opts.font_size or 24)))
    if opts.bg then canvas:fill_rect(math.floor(x), math.floor(y), math.floor(w), math.floor(h), opts.bg) end
    local tw, th = canvas:measure_text(text, opts)
    if opts.align == "center" then x = x + (w - tw) // 2 elseif opts.align == "right" then x = x + w - tw end
    if opts.valign == "middle" then y = y + (h - th) // 2 elseif opts.valign == "bottom" then y = y + h - th end
    canvas:text(math.floor(x), math.floor(y), text, opts)
end

local json = require("json")
local storage = require("storage")
local system = require("system")

local DEFAULT_PORT = 8765
local CONFIG_DIR = "Flashback"
local CONFIG_FILE = "config.json"

local LOOP_MS = 50
local CLOCK_TICK_MS = 200
local TOUCH_DEBOUNCE_MS = 300
local HEALTH_RETRY_MS = 3000
local PLAY_TIMEOUT_MS = 2000

local raw_args = type(args) == "table" and args or {}
local cfg = nil
local paths = {}
local touch_handle = nil
local display_started = false
local clock_glyphs = nil
local rgb565_cache = {}
local panel_w = 0
local panel_h = 0
local last_touch_ms = 0
local last_clock_ms = 0
local last_health_ms = -HEALTH_RETRY_MS
local last_minute_key = nil
local host_ready = false
local status_anim = 0

local function now_ms()
    return system.millis()
end

local function current_script_dir()
    if type(debug) ~= "table" or type(debug.getinfo) ~= "function" then
        error("Flashback glyphs_path is required when debug.getinfo is unavailable")
    end
    local source = debug.getinfo(1, "S").source or ""
    local path = string.match(source, "^@(.+)$") or source
    return string.match(path, "^(.*)/[^/]+$") or "."
end

local function current_skill_dir()
    local script_dir = current_script_dir()
    return string.match(script_dir, "^(.*)/scripts$") or script_dir
end

local function valid_ipv4(ip)
    local a, b, c, d = string.match(ip or "", "^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then
        return false
    end
    for _, part in ipairs({ a, b, c, d }) do
        local n = tonumber(part)
        if not n or n < 0 or n > 255 then
            return false
        end
    end
    return true
end

local function pack_rgb565_le(value)
    return string.pack("<I2", value & 0xFFFF)
end

local function alpha_to_rgb565(alpha)
    local cached = rgb565_cache[alpha]
    if cached then
        return cached
    end

    local r5 = (31 * alpha + 127) // 255
    local g6 = (63 * alpha + 127) // 255
    local b5 = (31 * alpha + 127) // 255
    local value = (r5 << 11) | (g6 << 5) | b5
    cached = pack_rgb565_le(value)
    rgb565_cache[alpha] = cached
    return cached
end

local function load_clock_glyphs()
    local path = raw_args.glyphs_path
    if type(path) ~= "string" or path == "" then
        path = storage.join_path(current_skill_dir(), "assets/clock_glyphs.lua")
    end

    local ok, glyphs = pcall(dofile, path)
    if not ok or type(glyphs) ~= "table" or type(glyphs.glyphs) ~= "table" then
        print("[Flashback] clock glyph asset unavailable, using display text fallback: " .. tostring(glyphs))
        clock_glyphs = nil
        return
    end
    clock_glyphs = glyphs
    print("[Flashback] loaded clock glyphs from " .. path)
end

local function ensure_dir(path)
    if not storage.exists(path) then
        storage.mkdir(path)
    end
end

local function init_paths()
    local root = storage.get_root_dir()
    paths.base = storage.join_path(root, CONFIG_DIR)
    paths.config = storage.join_path(paths.base, CONFIG_FILE)
    ensure_dir(paths.base)
end

local function save_config(next_cfg)
    storage.write_file(paths.config, json.encode(next_cfg))
end

local function load_config()
    local next_cfg = {
        port = DEFAULT_PORT,
    }

    if storage.exists(paths.config) then
        local ok, parsed = pcall(function()
            return json.decode(storage.read_file(paths.config))
        end)
        if ok and type(parsed) == "table" then
            next_cfg.host_ip = parsed.host_ip
            next_cfg.port = tonumber(parsed.port) or DEFAULT_PORT
        end
    end

    if type(raw_args.host_ip) == "string" and raw_args.host_ip ~= "" then
        next_cfg.host_ip = raw_args.host_ip
    end
    if raw_args.port ~= nil then
        next_cfg.port = tonumber(raw_args.port) or next_cfg.port
    end

    if not valid_ipv4(next_cfg.host_ip) then
        error("Flashback host IP is not configured. Ask the user for the Windows PC LAN IPv4 address, then run configure_host.lua.")
    end
    if next_cfg.port < 1 or next_cfg.port > 65535 then
        error("Flashback port must be in 1..65535")
    end

    next_cfg.port = math.floor(next_cfg.port)
    save_config(next_cfg)
    return next_cfg
end

local function build_url(path)
    return string.format("http://%s:%d%s", cfg.host_ip, cfg.port, path)
end

local function parse_http_output(output)
    output = tostring(output or "")
    local status = tonumber(string.match(output, "^HTTP%s+(%d+)"))
    local body = string.match(output, "^HTTP%s+%d+[^\n]*\n(.*)$") or ""
    return status, body
end

local function http_request(payload, label, max_output_bytes)
    local ok, out, err = capability.call("http_request", payload, {
        source_cap = "Flashback",
        max_output_bytes = max_output_bytes or 1024,
    })

    if not ok then
        print(string.format("[Flashback] %s failed: err=%s out=%s", label, tostring(err), tostring(out)))
        return nil, nil, tostring(err or out)
    end

    local status, body = parse_http_output(out)
    if not status then
        print(string.format("[Flashback] %s returned unexpected output: %s", label, tostring(out)))
        return nil, nil, tostring(out)
    end
    return status, body, nil
end

local function health_check()
    local status = http_request({
        url = build_url("/health"),
        method = "GET",
        timeout_ms = 2500,
        max_body_bytes = 64,
    }, "GET /health", 512)
    return status == 200
end

local function send_play()
    local status, body = http_request({
        url = build_url("/play"),
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
        },
        body = "{}",
        timeout_ms = PLAY_TIMEOUT_MS,
        max_body_bytes = 512,
    }, "POST /play", 1024)

    if status and status >= 200 and status < 300 then
        print("[Flashback] POST /play OK " .. tostring(body))
        return true
    end
    print("[Flashback] POST /play rejected status=" .. tostring(status))
    return false
end

local function begin_frame(clear)
    canvas:begin(clear ~= false and { clear = "#000000" } or {})
end

local function end_frame(full)
    if full then
        canvas:present({ full = true })
    else
        canvas:present()
    end

end

local function fit_font_size(text, max_w, max_h, start_size, min_size)
    local size = math.min(64, start_size)
    while size >= min_size do
        local ok, tw, th = pcall(function()
            local w, h = canvas:measure_text(text, { font_size = size })
            return w, h
        end)
        if ok and tw <= max_w and th <= max_h then
            return size
        end
        size = size - 2
    end
    return min_size
end

local function draw_center_text(text, y, height, font_size, color)
    aligned_text(0, y, panel_w, height, text, {
        color = color or "#ffffff",
        font_size = font_size,
        align = "center",
        valign = "middle",
    })
end

local function draw_status(title, headline, detail, button)
    begin_frame(true)
    local title_size = fit_font_size(title, panel_w - 24, 28, 18, 12)
    local headline_size = fit_font_size(headline, panel_w - 16, 42, 28, 16)
    local detail_size = fit_font_size(detail, panel_w - 24, 24, 16, 10)
    local button_size = fit_font_size(button, panel_w - 48, 24, 16, 10)

    draw_center_text(title, 24, 28, title_size, { r = 140, g = 140, b = 140 })
    draw_center_text(headline, 78, 48, headline_size, "#ffffff")
    draw_center_text(detail, 118, 28, detail_size, { r = 160, g = 160, b = 160 })

    local dot_y = 160
    local dot_start = (panel_w // 2) - 18
    for i = 0, 3 do
        local on = (status_anim % 4) == i or host_ready
        local radius = on and 3 or 2
        local shade = on and 255 or 70
        canvas:fill_round_rect(dot_start + i * 12 - radius, dot_y - radius,
            radius * 2, radius * 2, radius, { r = shade, g = shade, b = shade })
    end

    local btn_w = math.max(120, math.min(panel_w - 24, panel_w // 2))
    local btn_h = 36
    local btn_x = (panel_w - btn_w) // 2
    local btn_y = panel_h - btn_h - 16
    canvas:fill_round_rect(btn_x, btn_y, btn_w, btn_h, 12, "#ffffff")
    canvas:fill_round_rect(btn_x + 2, btn_y + 2, btn_w - 4, btn_h - 4, 10, "#000000")
    draw_center_text(button, btn_y, btn_h, button_size, "#ffffff")

    status_anim = (status_anim + 1) % 4
    end_frame(true)
end

local function current_clock_text()
    local ok_time, timestamp = pcall(system.time)
    if not ok_time or type(timestamp) ~= "number" or timestamp < 1700000000 then
        return "--:--", -1
    end

    local ok_date, text = pcall(system.date, "%H:%M")
    if not ok_date or type(text) ~= "string" or text == "" then
        return "--:--", -1
    end
    local hour = tonumber(string.sub(text, 1, 2)) or 0
    local minute = tonumber(string.sub(text, 4, 5)) or 0
    return text, hour * 60 + minute
end

local function render_clock_pixels(text)
    if not clock_glyphs then
        return nil
    end

    local glyphs = {}
    local total_w = 0
    local total_h = 0
    local gap = clock_glyphs.gap or 6

    for i = 1, #text do
        local ch = string.sub(text, i, i)
        local glyph = clock_glyphs.glyphs[ch]
        if not glyph or type(glyph.alpha) ~= "string" then
            return nil
        end
        glyphs[i] = glyph
        total_w = total_w + glyph.w
        if i > 1 then
            total_w = total_w + gap
        end
        total_h = math.max(total_h, glyph.h)
    end

    if total_w <= 0 or total_h <= 0 then
        return nil
    end

    local black = alpha_to_rgb565(0)
    local out = {}
    local n = 1
    for y = 1, total_h do
        for i, glyph in ipairs(glyphs) do
            if i > 1 and gap > 0 then
                out[n] = string.rep(black, gap)
                n = n + 1
            end
            local row = y
            if row > glyph.h then
                out[n] = string.rep(black, glyph.w)
                n = n + 1
            else
                local base = (row - 1) * glyph.w
                for x = 1, glyph.w do
                    local alpha = string.byte(glyph.alpha, base + x) or 0
                    out[n] = alpha_to_rgb565(alpha)
                    n = n + 1
                end
            end
        end
    end

    return table.concat(out), total_w, total_h
end

local function draw_clock_with_glyphs(text)
    local pixels, width, height = render_clock_pixels(text)
    if not pixels then
        return false
    end

    local x = math.max(0, (panel_w - width) // 2)
    local y = math.max(0, (panel_h - height) // 2)
    canvas:blit(x, y, pixels, {
        format = "rgb565",
        width = width,
        height = height,
    })
    return true
end

local function draw_clock(force)
    local text, minute_key = current_clock_text()
    if not force and minute_key == last_minute_key then
        return
    end

    last_minute_key = minute_key
    begin_frame(true)
    if not draw_clock_with_glyphs(text) then
        local font_size = fit_font_size(text, panel_w - 16, panel_h // 2, panel_h // 2, 24)
        draw_center_text(text, 0, panel_h, font_size, "#ffffff")
    end
    end_frame(true)
end

local function init_display()
    canvas = display.open()
    display_started = true
    panel_w, panel_h = canvas:info().width, canvas:info().height
    touch_handle = canvas:info().touch_available
end

local function handle_touch()
    if not touch_handle then
        return
    end
    local ok, touch = pcall(function()
        return poll_touch_snapshot()
    end)
    if not ok or type(touch) ~= "table" or not touch.just_pressed then
        return
    end

    local now = now_ms()
    if now - last_touch_ms < TOUCH_DEBOUNCE_MS then
        return
    end
    last_touch_ms = now
    print(string.format("[Flashback] touch (%d,%d) -> POST /play", touch.x or 0, touch.y or 0))
    if not send_play() then
        draw_status("FLASHBACK", "PLAY FAILED", "CHECK WINDOWS HOST", "TAP")
        last_minute_key = nil
    end
end

local function cleanup()
    if display_started then
        if canvas then canvas:close(); canvas = nil end
        display_started = false
    end
end

local function run()
    init_paths()
    cfg = load_config()
    load_clock_glyphs()
    print(string.format("[Flashback] host=%s:%d", cfg.host_ip, cfg.port))

    init_display()
    draw_status("FLASHBACK", "CHECKING HOST", cfg.host_ip .. ":" .. tostring(cfg.port), "WAIT")

    local last_loop = now_ms()
    while true do
        local now = now_ms()

        if not host_ready and now - last_health_ms >= HEALTH_RETRY_MS then
            last_health_ms = now
            host_ready = health_check()
            if host_ready then
                print("[Flashback] Windows host ready")
                draw_status("FLASHBACK", "HOST READY", "TAP SCREEN TO PLAY", "START")
                delay.delay_ms(350)
                last_minute_key = nil
                draw_clock(true)
            else
                draw_status("FLASHBACK", "HOST WAIT", "RUN WINDOWS APP", "WAIT")
            end
        end

        if host_ready then
            handle_touch()
            if now - last_clock_ms >= CLOCK_TICK_MS then
                last_clock_ms = now
                draw_clock(false)
            end
        end

        local elapsed = now - last_loop
        last_loop = now
        local sleep_ms = LOOP_MS - elapsed
        if sleep_ms < 1 then
            sleep_ms = 1
        end
        delay.delay_ms(sleep_ms)
    end
end

local ok, err = xpcall(run, debug.traceback)
cleanup()
if not ok then
    error(err)
end
