-- BLE air mouse: BMI270 IMU -> quaternion pose mapping -> ble_hid mouse_move.
-- LCD: top=right / bottom=left click; mid strip = scroll wheel; SVG trackball icon.

local arg_schema = require("arg_schema")
local ble_hid = require("ble_hid")
local board_manager = require("board_manager")
local delay = require("delay")
local display = require("display")
local imu = require("imu")
local lcd_touch = require("lcd_touch")
local system = require("system")
local pose_mapping = require("pose_mapping")

local DEFAULT_NAME = "esp-claw-airmouse"
-- Keep HID notify rate moderate: each mouse_move also reads protocol_mode in esp_hid.
local DEFAULT_INTERVAL_MS = 20
local DEFAULT_GAIN = 20
local DEFAULT_DEAD_X = 0.05
local DEFAULT_DEAD_Y = 0.05
local DEFAULT_MAX_DX = 20
local DEFAULT_MAX_DY = 20

-- lua_module_imu BMI270: ±16 g / ±2000 dps, 16-bit raw LSB
local ACCEL_LSB_TO_G = 16.0 / 32768.0
local GYRO_LSB_TO_DPS = 2000.0 / 32768.0

local ARG_SCHEMA = {
    interval_ms = arg_schema.int({ default = DEFAULT_INTERVAL_MS, min = 5 }),
    gain = arg_schema.int({ default = DEFAULT_GAIN, floor = false }),
    dead_x = arg_schema.int({ default = DEFAULT_DEAD_X, floor = false }),
    dead_y = arg_schema.int({ default = DEFAULT_DEAD_Y, floor = false }),
    max_dx = arg_schema.int({ default = DEFAULT_MAX_DX, min = 1, max = 127 }),
    max_dy = arg_schema.int({ default = DEFAULT_MAX_DY, min = 1, max = 127 }),
}

local raw = type(args) == "table" and args or {}
local ctx = arg_schema.parse(raw, ARG_SCHEMA)
ctx.name = (type(raw.name) == "string" and raw.name ~= "") and raw.name or DEFAULT_NAME

local COLOR = {
    bg_top = { r = 28, g = 36, b = 48 },
    bg_bot = { r = 18, g = 24, b = 34 },
    line = { r = 90, g = 110, b = 140 },
    accent_r = { r = 220, g = 120, b = 90 },
    accent_l = { r = 90, g = 180, b = 140 },
    flash_r = { r = 80, g = 40, b = 30 },
    flash_l = { r = 30, g = 70, b = 50 },
    -- From provided SVG icon
    arrow = { r = 0x5F, g = 0xD9, b = 0xFF },
    arrow_shade = { r = 0x51, g = 0xBC, b = 0xDD },
    stroke = "white",
}

-- 5x7 caps for rotated labels.
local FONT_5X7 = {
    E = { "#####", "#....", "#....", "####.", "#....", "#....", "#####" },
    F = { "#####", "#....", "#....", "####.", "#....", "#....", "#...." },
    G = { ".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".###." },
    H = { "#...#", "#...#", "#...#", "#####", "#...#", "#...#", "#...#" },
    I = { ".###.", "..#..", "..#..", "..#..", "..#..", "..#..", ".###." },
    L = { "#....", "#....", "#....", "#....", "#....", "#....", "#####" },
    R = { "####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#" },
    T = { "#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.." },
}

local function rgb(c)
    return c
end

local screen = {
    ready = false,
    width = 0,
    height = 0,
    mid_y = 0,
    wheel_band = 36,
    touch = nil,
}

-- Draw ASCII label rotated 90° CCW (readable in portrait).
local function draw_text_rot90_ccw(cx, cy, text, color, scale)
    scale = scale or 2
    local glyphs = {}
    local gw, gh = 5, 7
    local gap = 1
    for i = 1, #text do
        local g = FONT_5X7[text:sub(i, i)]
        if g then
            glyphs[#glyphs + 1] = g
        end
    end
    if #glyphs == 0 then
        return
    end

    local src_w = #glyphs * (gw + gap) - gap
    local src_h = gh
    local dst_w = src_h * scale
    local dst_h = src_w * scale
    local ox = cx - dst_w // 2
    local oy = cy - dst_h // 2

    for gi = 1, #glyphs do
        local glyph = glyphs[gi]
        local base_x = (gi - 1) * (gw + gap)
        for row = 1, gh do
            local pattern = glyph[row]
            for col = 1, gw do
                if pattern:sub(col, col) == "#" then
                    local sx = base_x + col - 1
                    local sy = row - 1
                    local dx = sy
                    local dy = src_w - 1 - sx
                    display.fill_rect(
                        ox + dx * scale,
                        oy + dy * scale,
                        scale,
                        scale,
                        color)
                end
            end
        end
    end
end

local function iround(v)
    return math.floor(v + 0.5)
end

-- Map SVG viewBox (124x127) point into screen pixels around icon center.
local function svg_xy(sx, sy, ox, oy, scale)
    return iround(ox + sx * scale), iround(oy + sy * scale)
end

local function stroke_ellipse(cx, cy, rx, ry, color, width)
    width = width or 1
    local half = width // 2
    for i = 0, width - 1 do
        local dr = i - half
        local arx = rx + dr
        local ary = ry + dr
        if arx > 0 and ary > 0 then
            display.draw_ellipse(cx, cy, arx, ary, color)
        end
    end
end

local function stroke_line(x0, y0, x1, y1, color, width)
    width = width or 1
    if width <= 1 then
        display.draw_line(x0, y0, x1, y1, color)
        return
    end
    local half = width // 2
    for d = -half, width - half - 1 do
        display.draw_line(x0 + d, y0, x1 + d, y1, color)
        display.draw_line(x0, y0 + d, x1, y1 + d, color)
    end
end

-- Draw SVG trackball icon rotated 90° CCW; ball interior is hollow (stroke only).
local function draw_svg_icon()
    -- Original viewBox 0 0 124 127; after 90° CCW → 127 x 124
    local src_w, src_h = 124, 127
    local vb_w, vb_h = src_h, src_w
    local max_h = screen.height - 16
    local max_w = screen.width - 70 -- leave left strip for labels
    local scale = math.min(max_w / vb_w, max_h / vb_h)
    local icon_w = vb_w * scale
    local icon_h = vb_h * scale
    local ox = (screen.width - icon_w) / 2 + 18
    local oy = (screen.height - icon_h) / 2

    -- 90° CCW: (x, y) -> (y, src_w - x)
    local function rot(sx, sy)
        return sy, src_w - sx
    end

    local function P(sx, sy)
        local rx, ry = rot(sx, sy)
        return svg_xy(rx, ry, ox, oy, scale)
    end

    local function tri(ax, ay, bx, by, cx, cy, color)
        local x1, y1 = P(ax, ay)
        local x2, y2 = P(bx, by)
        local x3, y3 = P(cx, cy)
        display.fill_triangle(x1, y1, x2, y2, x3, y3, color)
    end

    -- Direction arrows (fill) — same SVG points, transformed by P()
    tri(62, 1.5, 72.2996, 11.9062, 51.7005, 11.9062, COLOR.arrow)
    tri(62, 125.375, 51.7004, 114.969, 72.2995, 114.969, COLOR.arrow)
    tri(122.375, 64, 111.969, 74.2995, 111.969, 53.7005, COLOR.arrow)
    tri(1.5, 64, 11.9063, 53.7005, 11.9063, 74.2995, COLOR.arrow)

    -- Arrow shade accents
    tri(111.875, 68, 118.375, 61, 122.375, 63.5, COLOR.arrow_shade)
    tri(122.375, 63.5, 111.875, 73, 111.875, 68, COLOR.arrow_shade)
    tri(59.5, 122.375, 67, 115.375, 71, 115.875, COLOR.arrow_shade)
    tri(71, 115.875, 62, 125.375, 59.5, 122.375, COLOR.arrow_shade)
    tri(6.5, 69.5, 11.5, 64, 12.5, 72.5, COLOR.arrow_shade)
    tri(12.5, 72.5, 9, 72.5, 6.5, 69.5, COLOR.arrow_shade)
    tri(60, 12, 66, 5.5, 71.5, 11.5, COLOR.arrow_shade)
    tri(71.5, 11.5, 65, 12, 60, 12, COLOR.arrow_shade)

    -- Trackball outline only (no interior fill). Ellipse axes swap after 90° CCW.
    local bx, by = P(62, 63.5)
    local rx = iround(38.0 * scale) -- was ry
    local ry = iround(32.5 * scale) -- was rx
    local sw = math.max(2, iround(3 * scale))
    stroke_ellipse(bx, by, rx, ry, COLOR.stroke, sw)

    -- Diameter line (was horizontal through center)
    local lx0, ly0 = P(29.5, 63.5)
    local lx1, ly1 = P(94.5, 63.5)
    stroke_line(lx0, ly0, lx1, ly1, COLOR.stroke, sw)

    -- Trackball knob (outline only); radii swapped after rotation
    local kx, ky = P(61.5, 44)
    local knrx = iround(10.0 * scale)
    local knry = iround(4.5 * scale)
    stroke_ellipse(kx, ky, knrx, knry, COLOR.stroke, sw)
    local kx0, ky0 = P(61.5, 25.5)
    local kx1, ky1 = P(61.5, 34.05)
    local kx2, ky2 = P(61.5, 54.95)
    local kx3, ky3 = P(61.5, 63.5)
    stroke_line(kx0, ky0, kx1, ky1, COLOR.stroke, sw)
    stroke_line(kx2, ky2, kx3, ky3, COLOR.stroke, sw)

    local function outline_tri(ax, ay, bx, by, cx, cy)
        local x1, y1 = P(ax, ay)
        local x2, y2 = P(bx, by)
        local x3, y3 = P(cx, cy)
        display.draw_triangle(x1, y1, x2, y2, x3, y3, COLOR.stroke)
    end
    outline_tri(62, 1.5, 72.2996, 11.9062, 51.7005, 11.9062)
    outline_tri(62, 125.375, 51.7004, 114.969, 72.2995, 114.969)
    outline_tri(122.375, 64, 111.969, 74.2995, 111.969, 53.7005)
    outline_tri(1.5, 64, 11.9063, 53.7005, 11.9063, 74.2995)
end

local function draw_ui(flash_zone)
    if not screen.ready then
        return
    end

    local w = screen.width
    local h = screen.height
    local mid = screen.mid_y
    local top_color = COLOR.bg_top
    local bot_color = COLOR.bg_bot
    if flash_zone == "right" then
        top_color = COLOR.flash_r
    elseif flash_zone == "left" then
        bot_color = COLOR.flash_l
    end

    display.begin_frame({ clear = true, color = "black" })
    display.fill_rect(0, 0, w, mid, rgb(top_color))
    display.fill_rect(0, mid, w, h - mid, rgb(bot_color))
    display.fill_rect(0, mid - 1, w, 2, rgb(COLOR.line))

    -- Labels on the left strip, fully inside each half (avoid clipping).
    draw_text_rot90_ccw(18, mid // 2, "RIGHT", COLOR.accent_r, 2)
    draw_text_rot90_ccw(18, mid + (h - mid) // 2, "LEFT", COLOR.accent_l, 2)

    draw_svg_icon()

    if display.present_full then
        display.present_full()
    else
        display.present()
    end
end

local function init_screen()
    local panel_handle, io_handle, width, height, panel_if =
        board_manager.get_display_lcd_params("display_lcd")
    if not panel_handle then
        -- print("airmouse: display unavailable: " .. tostring(io_handle))
        return
    end

    local ok, err = pcall(display.init, panel_handle, io_handle, width, height, panel_if)
    if not ok then
        -- print("airmouse: display.init failed: " .. tostring(err))
        return
    end

    screen.width = display.width
    screen.height = display.height
    if screen.width <= 0 or screen.height <= 0 then
        -- print("airmouse: invalid display size")
        pcall(display.deinit)
        return
    end
    screen.mid_y = screen.height // 2
    screen.ready = true

    local touch_handle, touch_err = board_manager.get_lcd_touch_handle("lcd_touch")
    if not touch_handle then
        -- print("airmouse: touch unavailable: " .. tostring(touch_err))
    else
        local sync_ok, sync_err = pcall(lcd_touch.sync, touch_handle)
        if not sync_ok then
            -- print("airmouse: lcd_touch.sync failed: " .. tostring(sync_err))
        else
            screen.touch = touch_handle
        end
    end

    draw_ui(nil)
    -- print(string.format(
    --     "airmouse: LCD %dx%d split at y=%d (top=right, bottom=left)",
    --     screen.width, screen.height, screen.mid_y))
end

-- Touch: top/bottom = right/left; mid band = scroll wheel.
-- Short taps use mouse_button("click") for tight pulses (double-click friendly);
-- press-and-hold / drag uses down/up.
local WHEEL_PIXELS_PER_NOTCH = 12
local TAP_MAX_HOLD_MS = 280
local TAP_MOVE_SLOP_PX = 14
local DOUBLE_CLICK_MS = 600
local held_button = nil
local touch_mode = nil -- "button" | "wheel" | nil
local wheel_accum = 0
local last_tap = { button = nil, t_ms = 0 }
local press = {
    active = false,
    button = nil,
    zone = nil,
    t0 = 0,
    x0 = 0,
    y0 = 0,
    hid_down = false,
}

local function zone_for_y(y)
    local band = screen.wheel_band or 36
    if math.abs((y or 0) - screen.mid_y) <= band then
        return "wheel", "wheel"
    end
    if y < screen.mid_y then
        return "right", "right"
    end
    return "left", "left"
end

local function release_held_button(redraw)
    if not held_button then
        return
    end
    local button = held_button
    held_button = nil
    local ok, err = ble_hid.mouse_button(button, "up")
    if not ok then
        -- print("airmouse: mouse_button(" .. button .. ", up) failed: " .. tostring(err))
    end
    if redraw ~= false then
        draw_ui(nil)
    end
end

local function begin_drag_if_needed(info)
    if not press.active or press.hid_down or not press.button then
        return
    end
    local now = system.millis()
    local held = now - press.t0
    local dx = (info.x or press.x0) - press.x0
    local dy = (info.y or press.y0) - press.y0
    local moved = (math.abs(dx) + math.abs(dy)) >= TAP_MOVE_SLOP_PX
    if held < TAP_MAX_HOLD_MS and not moved then
        return
    end
    local ok, err = ble_hid.mouse_button(press.button, "down")
    if not ok then
        -- print("airmouse: mouse_button(" .. press.button .. ", down) failed: " .. tostring(err))
        return
    end
    press.hid_down = true
    held_button = press.button
    -- Drag / long-press: show zone flash once.
    draw_ui(press.zone)
end

-- Swipe → wheel (signs flipped for panel orientation): left = up, right = down.
local function swipe_to_wheel_delta(dx, dy)
    dx = dx or 0
    dy = dy or 0
    if math.abs(dx) >= math.abs(dy) then
        return dx
    end
    return -dy
end

local function handle_wheel_move(info, connected)
    if not connected then
        return
    end
    local slide = swipe_to_wheel_delta(info.dx, info.dy)
    if slide == 0 then
        return
    end
    wheel_accum = wheel_accum + slide
    while math.abs(wheel_accum) >= WHEEL_PIXELS_PER_NOTCH do
        local step = (wheel_accum > 0) and 1 or -1
        wheel_accum = wheel_accum - step * WHEEL_PIXELS_PER_NOTCH
        local ok, err = ble_hid.mouse_scroll(step)
        if not ok then
            -- print("airmouse: mouse_scroll failed: " .. tostring(err))
            break
        end
    end
end

local function handle_touch(connected)
    if not screen.touch then
        return
    end

    local ok, info = pcall(lcd_touch.poll, screen.touch)
    if not ok or type(info) ~= "table" then
        return
    end

    if info.just_pressed then
        local button, zone = zone_for_y(info.y or 0)
        wheel_accum = 0

        if zone == "wheel" then
            if held_button then
                release_held_button(false)
            end
            press.active = false
            touch_mode = "wheel"
            screen._ui_pressed = true
            -- print(string.format("airmouse: wheel zone @ (%s,%s)", tostring(info.x), tostring(info.y)))
            return
        end

        touch_mode = "button"
        press.active = true
        press.button = button
        press.zone = zone
        press.t0 = system.millis()
        press.x0 = info.x or 0
        press.y0 = info.y or 0
        press.hid_down = false

        if not connected then
            -- print(string.format("airmouse: touch %s ignored (not connected) x=%s y=%s",
            --     button, tostring(info.x), tostring(info.y)))
            screen._ui_pressed = true
            return
        end

        if held_button and held_button ~= button then
            release_held_button(false)
        end

        -- Defer HID until release (tap→click) or hold/move (drag→down).
        -- Skip UI redraw here so double-tap stays inside the host window.
        return
    end

    if info.pressed and touch_mode == "wheel" and (info.moved or info.dx or info.dy) then
        handle_wheel_move(info, connected)
        return
    end

    if info.pressed and touch_mode == "button" and connected then
        begin_drag_if_needed(info)
        return
    end

    if info.just_released then
        if touch_mode == "wheel" then
            touch_mode = nil
            wheel_accum = 0
            screen._ui_pressed = false
            press.active = false
            return
        end

        touch_mode = nil
        if not press.active then
            if screen._ui_pressed then
                screen._ui_pressed = false
                draw_ui(nil)
            end
            return
        end

        local button = press.button
        local was_drag = press.hid_down
        press.active = false

        if not connected then
            screen._ui_pressed = false
            draw_ui(nil)
            return
        end

        if was_drag then
            release_held_button(true)
            last_tap.button = nil
            -- print(string.format("airmouse: %s drag-up @ (%s,%s) held=%.0fms",
            --     button, tostring(info.x), tostring(info.y), info.held_ms or 0))
            return
        end

        -- Short tap: emit a fixed-length click pulse (not finger-hold length).
        local now = system.millis()
        local is_double = (last_tap.button == button)
            and ((now - last_tap.t_ms) <= DOUBLE_CLICK_MS)

        local click_ok, click_err = ble_hid.mouse_button(button, "click")
        if not click_ok then
            -- print("airmouse: mouse_button(" .. tostring(button) .. ", click) failed: " .. tostring(click_err))
        elseif is_double then
            -- print(string.format("airmouse: %s double-click @ (%s,%s) gap=%dms",
            --     button, tostring(info.x), tostring(info.y), now - last_tap.t_ms))
            last_tap.button = nil
            last_tap.t_ms = 0
        else
            -- print(string.format("airmouse: %s click @ (%s,%s)",
            --     button, tostring(info.x), tostring(info.y)))
            last_tap.button = button
            last_tap.t_ms = now
        end

        -- Never redraw/block between taps — full-frame present would miss the 2nd tap.
        screen._ui_pressed = false
    end
end

local ok, err = ble_hid.init({ name = ctx.name })
if not ok then
    error("ble_hid.init failed: " .. tostring(err))
end

ok, err = ble_hid.start({ name = ctx.name })
if not ok then
    error("ble_hid.start failed: " .. tostring(err))
end

-- print(string.format("airmouse: advertising as %s — pair from host Bluetooth settings", ctx.name))

init_screen()

local sensor = imu.new()
local pose = pose_mapping.create({
    gain = ctx.gain,
    dead_x = ctx.dead_x,
    dead_y = ctx.dead_y,
    max_dx = ctx.max_dx,
    max_dy = ctx.max_dy,
})

local was_connected = false
local was_ready = false
local send_fail_streak = 0

local function hid_is_ready(status)
    if type(status) ~= "table" then
        return false
    end
    if status.ready ~= nil then
        return status.ready
    end
    -- Older firmware without status.ready: require connected + encrypted when present.
    if status.encrypted ~= nil then
        return status.connected and status.encrypted
    end
    return status.connected
end

while true do
    local status = ble_hid.status()
    local ready = hid_is_ready(status)
    handle_touch(ready)

    if not status.connected then
        if was_connected then
            -- print("airmouse: host disconnected, waiting...")
            was_connected = false
            was_ready = false
            send_fail_streak = 0
            if held_button then
                held_button = nil
                touch_mode = nil
                wheel_accum = 0
                pcall(ble_hid.release_all)
                draw_ui(nil)
            end
            pose = pose_mapping.create({
                gain = ctx.gain,
                dead_x = ctx.dead_x,
                dead_y = ctx.dead_y,
                max_dx = ctx.max_dx,
                max_dy = ctx.max_dy,
            })
        end
        delay.delay_ms(50)
    elseif not ready then
        if not was_connected then
            -- print("airmouse: host connected, waiting for encryption...")
            was_connected = true
        end
        -- Do not spam HID notifies until the link is encrypted / ready.
        delay.delay_ms(50)
    else
        if not was_ready then
            -- print("airmouse: link ready (encrypted), starting cursor mapping")
            was_connected = true
            was_ready = true
            send_fail_streak = 0
            -- Brief settle so host can enable CCCD before first reports.
            delay.delay_ms(300)
        end

        local sample = sensor:read()
        local now_us = system.millis() * 1000
        local accel = {
            sample.accel.x * ACCEL_LSB_TO_G,
            sample.accel.y * ACCEL_LSB_TO_G,
            sample.accel.z * ACCEL_LSB_TO_G,
        }
        local gyro = {
            sample.gyro.x * GYRO_LSB_TO_DPS,
            sample.gyro.y * GYRO_LSB_TO_DPS,
            sample.gyro.z * GYRO_LSB_TO_DPS,
        }

        local dx, dy = pose_mapping.update_cursor(pose, accel, gyro, now_us)
        if dx ~= 0 or dy ~= 0 then
            local moved, move_err = ble_hid.mouse_move(dx, dy)
            if not moved then
                send_fail_streak = send_fail_streak + 1
                if send_fail_streak == 1 or send_fail_streak % 20 == 0 then
                    -- print("airmouse: mouse_move failed: " .. tostring(move_err))
                end
                -- Back off hard: notify ENOTCONN / ESP_FAIL while host is still settling.
                delay.delay_ms(math.min(500, 80 + send_fail_streak * 20))
            else
                send_fail_streak = 0
            end
        end

        delay.delay_ms(ctx.interval_ms)
    end
end
