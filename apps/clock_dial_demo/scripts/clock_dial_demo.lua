local display = require("display")
local delay = require("delay")
local system = require("system")

local pi, sin, cos = math.pi, math.sin, math.cos
local function round(v) return math.floor(v + 0.5) end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

-- Small vector glyphs keep device and simulator typography identical.
local glyphs = {
    A = {{0,6,0,2,2,0,4,2,4,6},{0,3,4,3}}, B = {{0,6,0,0,3,0,4,1,4,2,3,3,0,3},{3,3,4,4,4,5,3,6,0,6}},
    C = {{4,1,3,0,1,0,0,1,0,5,1,6,3,6,4,5}}, D = {{0,6,0,0,2,0,4,2,4,4,2,6,0,6}},
    E = {{4,0,0,0,0,6,4,6},{0,3,3,3}}, F = {{4,0,0,0,0,6},{0,3,3,3}},
    G = {{4,1,3,0,1,0,0,1,0,5,1,6,4,6,4,3,2,3}}, H = {{0,0,0,6},{4,0,4,6},{0,3,4,3}},
    I = {{0,0,4,0},{2,0,2,6},{0,6,4,6}}, J = {{0,0,4,0,4,5,3,6,1,6,0,5}},
    K = {{0,0,0,6},{4,0,0,3,4,6}}, L = {{0,0,0,6,4,6}}, M = {{0,6,0,0,2,3,4,0,4,6}},
    N = {{0,6,0,0,4,6,4,0}}, O = {{1,0,3,0,4,1,4,5,3,6,1,6,0,5,0,1,1,0}},
    P = {{0,6,0,0,3,0,4,1,4,2,3,3,0,3}}, Q = {{1,0,3,0,4,1,4,5,3,6,1,6,0,5,0,1,1,0},{2,4,4,6}},
    R = {{0,6,0,0,3,0,4,1,4,2,3,3,0,3},{2,3,4,6}}, S = {{4,1,3,0,1,0,0,1,0,2,1,3,3,3,4,4,4,5,3,6,1,6,0,5}},
    T = {{0,0,4,0},{2,0,2,6}}, U = {{0,0,0,5,1,6,3,6,4,5,4,0}}, V = {{0,0,0,3,2,6,4,3,4,0}},
    W = {{0,0,0,6,2,3,4,6,4,0}}, X = {{0,0,4,6},{4,0,0,6}}, Y = {{0,0,2,3,4,0},{2,3,2,6}}, Z = {{0,0,4,0,0,6,4,6}},
    ["0"] = {{1,0,3,0,4,1,4,5,3,6,1,6,0,5,0,1,1,0}}, ["1"] = {{0,1,2,0,2,6},{0,6,4,6}},
    ["2"] = {{0,1,1,0,3,0,4,1,4,2,0,6,4,6}}, ["3"] = {{0,0,3,0,4,1,4,2,3,3,1,3},{3,3,4,4,4,5,3,6,0,6}},
    ["4"] = {{3,6,3,0,0,4,4,4}}, ["5"] = {{4,0,0,0,0,3,3,3,4,4,4,5,3,6,0,6}},
    ["6"] = {{4,0,1,0,0,1,0,5,1,6,3,6,4,5,4,4,3,3,0,3}}, ["7"] = {{0,0,4,0,1,6}},
    ["8"] = {{1,0,3,0,4,1,4,2,3,3,1,3,0,2,0,1,1,0},{1,3,0,4,0,5,1,6,3,6,4,5,4,4,3,3}},
    ["9"] = {{4,3,1,3,0,2,0,1,1,0,3,0,4,1,4,5,3,6,0,6}},
    ["-"] = {{0,3,4,3}}, ["/"] = {{0,6,4,0}}, ["+"] = {{0,3,4,3},{2,1,2,5}},
}
local themes = {
    { bg = "#E9E5DC", ink = "#28342F", muted = "#7E8379", accent = "#DB582C", soft = "#DED9CE", face = "#F9F6EE", rim = "#B5B6AB", edge = "#D8D6CA", shine = "#FFFEF8", track = "#DDDCD1", hand = "#394740", shadow = "#BAB9AE", button = "#293B33", button_text = "#F9F6EE", tick = "#909589" },
    { bg = "#171D21", ink = "#F0EADD", muted = "#8D9A9C", accent = "#FA8751", soft = "#283237", face = "#242D32", rim = "#536166", edge = "#354147", shine = "#7D8A8C", track = "#465257", hand = "#DCE4DA", shadow = "#101518", button = "#E4E9DF", button_text = "#1B2926", tick = "#7B8A8D" },
}
-- Pack palette colors once instead of parsing hex during each draw.
for _, palette in ipairs(themes) do
    for key, hex in pairs(palette) do palette[key] = display.color(tonumber(hex:sub(2, 3), 16), tonumber(hex:sub(4, 5), 16), tonumber(hex:sub(6, 7), 16)) end
end
local weekdays = { "SUNDAY", "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY" }
local months = { "JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC" }

local function main()
    local screen <close> = display.open()
    local info = screen:info()
    local w, h = info.width, info.height
    assert(w >= 160 and h >= 160, "clock requires at least 160x160 pixels")
    local compact = math.min(w, h) < 220
    local wide = w >= 300 and w / h >= 1.3
    local margin = compact and 8 or (wide and round(w * 0.04) or 16)
    local header = compact and 24 or (wide and math.min(56, round(h * 0.12)) or 36)
    local cx, cy, radius, panel_x, panel_w
    if wide then
        cx, cy = round(w * 0.295), round(h * 0.51)
        radius = math.floor(math.min(w * 0.235, cy - header - 15, h - 50 - cy))
        panel_x, panel_w = round(w * 0.58), w - round(w * 0.58) - margin
    else
        local top, bottom = header + (compact and 8 or 26), h - (compact and 54 or 84)
        cx, cy = w // 2, (top + bottom) // 2
        radius = math.floor(math.min(w / 2 - 18, (bottom - top) / 2 - 8))
    end
    local mode_h = compact and 22 or 28
    local mode_w = math.min(w - margin * 2, wide and round(radius * 1.65) or 224)
    local mode_x, mode_y = cx - mode_w // 2, h - mode_h - (compact and 2 or 8)
    local theme_box = { x = w - margin - (compact and 52 or 108), y = 4, w = compact and 26 or 68, h = header - 4 }
    local exit_box = { x = w - margin - (compact and 22 or 28), y = 4, w = compact and 28 or 36, h = header - 4 }
    local clock_box = { x = mode_x, y = mode_y, w = mode_w // 2, h = mode_h }
    local focus_box = { x = mode_x + mode_w // 2, y = mode_y, w = mode_w - mode_w // 2, h = mode_h }
    local action_box = wide and { x = panel_x, y = round(h * 0.66), w = round(panel_w * 0.66), h = math.max(28, round(h * 0.085)) }
        or { x = cx - math.min(100, radius) // 2, y = cy + round(radius * 0.28), w = math.min(100, radius), h = compact and 18 or 28 }
    local reset_box = wide and { x = action_box.x + action_box.w + 6, y = action_box.y, w = panel_w - action_box.w - 6, h = action_box.h }
        or { x = cx - 36, y = h - (compact and 45 or 72), w = 72, h = compact and 20 or 26 }
    if compact and not wide then
        action_box = { x = 8, y = h - 45, w = w // 2 - 12, h = 20 }
        reset_box = { x = w // 2 + 4, y = h - 45, w = w // 2 - 12, h = 20 }
    end
    local theme, mode, phase = 1, "clock", "ready"
    local minutes, remaining, deadline = 25, 25 * 60000, 0
    local gesture, tilt_x, tilt_y, target_x, target_y = nil, 0, 0, 0, 0
    local full, running = true, true
    local started, last_now, last_poll = system.millis(), system.millis(), -1000
    local wall, wall_anchor, wall_key, date, weekday = 0, started, "", "", ""
    local panel_key, last_timer_second = "", -1
    local ticks = {}
    for i = 0, 59 do ticks[i] = { sin(i * pi / 30), -cos(i * pi / 30) } end

    local function stroke(x1, y1, x2, y2, thickness, color)
        x1, y1, x2, y2 = round(x1), round(y1), round(x2), round(y2)
        if thickness < 2 then screen:line(x1, y1, x2, y2, color); return end
        local dx, dy = x2 - x1, y2 - y1
        local len = math.sqrt(dx * dx + dy * dy)
        local r = math.max(1, round(thickness / 2))
        if len > 0 then
            local nx, ny = round(-dy * thickness / (2 * len)), round(dx * thickness / (2 * len))
            screen:fill_triangle(x1 + nx, y1 + ny, x1 - nx, y1 - ny, x2 + nx, y2 + ny, color)
            screen:fill_triangle(x1 - nx, y1 - ny, x2 - nx, y2 - ny, x2 + nx, y2 + ny, color)
        end
        screen:fill_circle(x1, y1, r, color)
        screen:fill_circle(x2, y2, r, color)
    end
    local function advance(char) return char == " " and 3.2 or (char == ":" and 2.6 or 5.6) end
    local function measure(text, size)
        local units = 0
        for i = 1, #text do units = units + advance(text:sub(i, i)) end
        return (units - 1.6) * size / 6
    end
    local function text(x, y, value, size, color, centered)
        if centered then x = x - measure(value, size) / 2 end
        local scale, weight = size / 6, math.max(1, size * 0.055)
        for i = 1, #value do
            local char = value:sub(i, i)
            if char == ":" then
                screen:fill_circle(round(x + scale * 0.4), round(y + scale * 2), math.max(1, round(weight)), color)
                screen:fill_circle(round(x + scale * 0.4), round(y + scale * 4), math.max(1, round(weight)), color)
            elseif glyphs[char] then
                for _, path in ipairs(glyphs[char]) do
                    for j = 1, #path - 2, 2 do stroke(x + path[j] * scale, y + path[j + 1] * scale, x + path[j + 2] * scale, y + path[j + 3] * scale, weight, color) end
                end
            end
            x = x + advance(char) * scale
        end
    end
    local function inside(box, x, y) return x >= box.x and y >= box.y and x < box.x + box.w and y < box.y + box.h end
    local function button(box, title, selected, pressed)
        local c = themes[theme]
        local bg = selected and c.button or c.soft
        screen:fill_round_rect(box.x, box.y + (pressed and 1 or 0), box.w, box.h, math.min(10, box.h // 2), bg)
        local size = math.min(compact and 8 or 10, (box.w - 12) / measure(title, 1))
        text(box.x + box.w / 2, box.y + (box.h - size) / 2, title, size, selected and c.button_text or c.muted, true)
    end
    local function poll_clock(now)
        if now - last_poll < 100 then return end
        last_poll = now
        local stamp = system.date("%H%M%S%w%d%m")
        if type(stamp) ~= "string" or not stamp:match("^%d%d%d%d%d%d%d%d%d%d%d$") then error("invalid system date") end
        local key = stamp:sub(1, 6)
        if key ~= wall_key then
            wall = tonumber(stamp:sub(1, 2)) * 3600 + tonumber(stamp:sub(3, 4)) * 60 + tonumber(stamp:sub(5, 6))
            wall_anchor, wall_key = now, key
            if date ~= stamp:sub(8, 9) .. " / " .. months[tonumber(stamp:sub(10, 11))] then full = true end
            weekday = weekdays[tonumber(stamp:sub(7, 7)) + 1]
            date = stamp:sub(8, 9) .. " / " .. months[tonumber(stamp:sub(10, 11))]
        end
    end
    local function activate(target, now)
        if target == "exit" then running = false
        elseif target == "theme" then theme = 3 - theme
        elseif target == "clock" or target == "focus" then mode = target
        elseif target == "reset" then phase, remaining = "ready", minutes * 60000
        elseif target == "action" then
            if mode == "clock" then mode = "focus"
            elseif phase == "running" then phase, remaining = "paused", math.max(0, deadline - now)
            else
                if phase == "done" then remaining = minutes * 60000 end
                phase, deadline = "running", now + remaining
            end
        end
        full = true
    end
    local function touch(now)
        if not info.touch_available then return end
        local points = screen:touch().points
        local point
        for _, p in ipairs(points) do if not gesture or p.id == gesture.id then point = p; break end end
        if point then
            local dx, dy = point.x - cx, point.y - cy
            local distance = math.sqrt(dx * dx + dy * dy)
            if not gesture then
                local target
                if inside(exit_box, point.x, point.y) then target = "exit"
                elseif inside(theme_box, point.x, point.y) then target = "theme"
                elseif inside(clock_box, point.x, point.y) then target = "clock"
                elseif inside(focus_box, point.x, point.y) then target = "focus"
                elseif (wide or mode == "focus") and inside(action_box, point.x, point.y) then target = "action"
                elseif mode == "focus" and inside(reset_box, point.x, point.y) then target = "reset"
                elseif distance <= radius + 8 then
                    target = mode == "focus" and distance > radius * 0.66 and phase ~= "running" and "ring" or "dial"
                end
                gesture = { id = point.id, target = target, x = point.x, y = point.y, distance = 0, angle = math.atan(dy, dx), value = minutes }
                full = true
            end
            gesture.distance = math.max(gesture.distance, math.abs(point.x - gesture.x), math.abs(point.y - gesture.y))
            if gesture.target == "dial" then
                target_x, target_y = clamp(dx / radius, -1, 1) * 4, clamp(dy / radius, -1, 1) * 4
            elseif gesture.target == "ring" then
                local angle = math.atan(dy, dx)
                local delta = (angle - gesture.angle + pi) % (2 * pi) - pi
                gesture.angle, gesture.value = angle, clamp(gesture.value + delta * 30 / pi, 5, 60)
                local value = clamp(round(gesture.value / 5) * 5, 5, 60)
                if value ~= minutes then minutes, phase, remaining, full = value, "ready", value * 60000, true end
            end
        elseif gesture then
            if gesture.distance < 8 and gesture.target ~= "dial" and gesture.target ~= "ring" then activate(gesture.target, now) end
            gesture, target_x, target_y, full = nil, 0, 0, true
        end
    end
    local function hand(x, y, length, tail, width, angle, color)
        local dx, dy = sin(angle), -cos(angle)
        local nx, ny = cos(angle) * width / 2, sin(angle) * width / 2
        local tx, ty, bx, by = x + dx * length, y + dy * length, x - dx * tail, y - dy * tail
        screen:fill_triangle(round(bx + nx), round(by + ny), round(bx - nx), round(by - ny), round(tx), round(ty), color)
        screen:fill_circle(round(x), round(y), math.max(1, round(width / 2)), color)
    end
    local function draw_dial(now)
        local c = themes[theme]
        local entry = clamp((now - started) / 450, 0, 1)
        local r = round(radius * (0.94 + 0.06 * (1 - (1 - entry) ^ 3)))
        local x, y = cx + round(tilt_x), cy + round(tilt_y)
        local pad = 14
        screen:fill_rect(cx - radius - pad, cy - radius - pad, radius * 2 + pad * 2, radius * 2 + pad * 2, c.bg)
        screen:fill_circle(cx, cy + 9, r + 4, c.soft)
        screen:fill_circle(cx, cy + 6, r + 1, c.shadow)
        screen:fill_circle(cx, cy + 3, r, c.rim)
        screen:fill_circle(cx, cy, r, c.shine)
        screen:fill_circle(cx, cy + 1, r - 2, c.edge)
        screen:fill_circle(x, y + 1, r - 7, c.rim)
        screen:fill_circle(x, y + 2, r - 9, c.face)
        screen:arc(cx, cy, r - 1, 205, 300, c.shine)
        screen:arc(x, y + 1, r - 8, 205, 320, c.shadow)
        local outer = r - math.max(13, round(r * 0.10))
        for i = 0, (compact and mode == "focus") and -1 or 59 do
            local t, major = ticks[i], i % 5 == 0
            local inner = outer - (major and math.max(4, round(r * 0.06)) or math.max(2, round(r * 0.025)))
            stroke(x + t[1] * inner, y + t[2] * inner, x + t[1] * outer, y + t[2] * outer, major and (r >= 100 and 2 or 1) or 1, major and c.ink or c.tick)
        end
        if mode == "clock" then
            if r >= 55 then
                local fs, nr = math.max(9, round(r * 0.105)), r * 0.66
                text(x, y - nr - fs / 2, "12", fs, c.ink, true)
                text(x + nr, y - fs / 2, "3", fs, c.ink, true)
                text(x, y + nr - fs / 2, "6", fs, c.ink, true)
                text(x - nr, y - fs / 2, "9", fs, c.ink, true)
                if r > 105 then text(x, y - r * 0.35, "MOMENT", 9, c.muted, true) end
            end
            local seconds = wall + clamp((now - wall_anchor) / 1000, 0, 0.999)
            local hour_angle, minute_angle, second_angle = seconds * pi / 21600, seconds * pi / 1800, seconds * pi / 30
            local hour_len, min_len = r * 0.43, r * 0.62
            local hw, mw = math.max(4, r * 0.055), math.max(3, r * 0.038)
            hand(x + 2, y + 4, hour_len, r * 0.09, hw, hour_angle, c.edge)
            hand(x + 2, y + 4, min_len, r * 0.11, mw, minute_angle, c.edge)
            hand(x, y, hour_len, r * 0.09, hw, hour_angle, c.hand)
            hand(x, y, min_len, r * 0.11, mw, minute_angle, c.hand)
            stroke(x - sin(second_angle) * r * 0.18, y + cos(second_angle) * r * 0.18, x + sin(second_angle) * r * 0.77, y - cos(second_angle) * r * 0.77, r >= 110 and 2 or 1, c.accent)
            screen:fill_circle(x, y + 2, math.max(4, round(r * 0.05)), c.shadow)
            screen:fill_circle(x, y, math.max(4, round(r * 0.05)), c.ink)
            screen:fill_circle(x, y, math.max(2, round(r * 0.023)), c.accent)
            screen:fill_circle(x - 1, y - 1, 1, c.shine)
        else
            local fraction = phase == "ready" and minutes / 60 or remaining / (minutes * 60000)
            if phase == "done" then fraction = 0.97 + 0.03 * sin(now / 450) end
            local rr, thickness = r - 5, math.max(3, round(r * 0.027))
            for j = 0, thickness - 1 do
                screen:stroke_circle(cx, cy, rr - j, c.track)
                if fraction > 0 then screen:arc(cx, cy, rr - j, -90, -90 + 360 * fraction, c.accent) end
            end
            local angle = fraction * 2 * pi
            screen:fill_circle(round(cx + sin(angle) * (rr - thickness / 2)), round(cy - cos(angle) * (rr - thickness / 2)), math.max(3, thickness), c.accent)
            local total = math.ceil(remaining / 1000)
            local value = phase == "done" and "DONE" or string.format("%02d:%02d", total // 60, total % 60)
            local size = compact and 10 or math.max(12, math.min(48, math.floor(r * 0.35)))
            text(x, y - size / 2 - ((wide or compact) and 0 or 8), value, size, c.ink, true)
            if r >= 70 then text(x, y - r * 0.46, phase == "running" and "FOCUS TIME" or "YOUR MOMENT", 8, c.muted, true) end
            if not wide and not compact then button(action_box, phase == "running" and "PAUSE" or (phase == "paused" and "RESUME" or "START"), true, gesture and gesture.target == "action") end
        end
    end
    local function draw_panel()
        local c = themes[theme]
        local time = string.format("%02d:%02d", wall // 3600, (wall // 60) % 60)
        if wide then
            local py = round(h * 0.25)
            screen:fill_rect(panel_x - 3, header, panel_w + 6, h - header, c.bg)
            text(panel_x, py, mode == "clock" and weekday or "MAKE ROOM", math.max(8, math.min(12, panel_w // 16)), c.muted)
            text(panel_x, py + round(h * 0.082), mode == "clock" and time or "FOCUS", math.min(64, math.floor(panel_w / 4.6)), c.ink)
            text(panel_x, py + round(h * 0.26), mode == "clock" and date or (phase == "running" and "ONE THING AT A TIME" or (phase == "done" and "A MOMENT WELL SPENT" or "TURN THE RING")), math.max(8, math.min(12, panel_w // 19)), c.muted)
            screen:fill_rect(panel_x, round(h * 0.60), panel_w, 1, c.edge)
            local label = mode == "clock" and (phase == "done" and "TIME IS UP" or "TRY FOCUS") or (phase == "running" and "PAUSE" or (phase == "paused" and "RESUME" or "START"))
            button(action_box, label, mode == "focus", gesture and gesture.target == "action")
            if mode == "focus" then button(reset_box, "RESET", false, gesture and gesture.target == "reset") end
            if h >= 300 then text(panel_x, h - 30, mode == "clock" and "LESS RUSH / MORE MOMENT" or "BREATHE / BEGIN AGAIN", math.max(8, math.min(10, panel_w // 23)), c.muted) end
        else
            local y = h - (compact and 44 or 72)
            screen:fill_rect(0, y - 3, w, mode_y - y, c.bg)
            if mode == "clock" then text(cx, y, time, compact and 15 or 28, c.ink, true)
            else
                button(reset_box, "RESET", false, gesture and gesture.target == "reset")
                if compact then button(action_box, phase == "running" and "PAUSE" or (phase == "paused" and "RESUME" or "START"), true, gesture and gesture.target == "action") end
            end
        end
    end
    local function draw_header()
        local c = themes[theme]
        screen:fill_circle(margin + 3, header // 2, compact and 2 or 3, c.accent)
        text(margin + (compact and 10 or 16), (header - (compact and 9 or 13)) / 2, "MOMENT", compact and 9 or 13, c.ink)
        if not wide and not compact then text(cx, header + 7, weekday:sub(1, 3) .. " / " .. date, 9, c.muted, true) end
        if not compact then button(theme_box, theme == 1 and "LIGHT" or "DARK", false, gesture and gesture.target == "theme")
        else screen:fill_circle(theme_box.x + theme_box.w // 2, header // 2, 5, c.ink); screen:fill_circle(theme_box.x + theme_box.w // 2 + 3, header // 2 - 2, 4, c.bg) end
        local ex, ey = exit_box.x + exit_box.w // 2, header // 2
        stroke(ex - 3, ey - 3, ex + 3, ey + 3, 1, c.muted)
        stroke(ex + 3, ey - 3, ex - 3, ey + 3, 1, c.muted)
    end

    print("[clock_dial_demo] ready: MOMENT")
    while running do
        local now = system.millis()
        local dt = clamp(now - last_now, 0, 250)
        last_now = now
        poll_clock(now)
        if phase == "running" then
            remaining = math.max(0, deadline - now)
            if remaining == 0 then phase, full = "done", true end
        end
        touch(now)
        if not running then break end
        local factor = 1 - math.exp(-dt / 75)
        tilt_x, tilt_y = tilt_x + (target_x - tilt_x) * factor, tilt_y + (target_y - tilt_y) * factor
        local moving = math.abs(target_x - tilt_x) + math.abs(target_y - tilt_y) > 0.05
        if not moving then tilt_x, tilt_y = target_x, target_y end
        local timer_second = math.ceil(remaining / 1000)
        local key = mode .. phase .. wall_key:sub(1, 4) .. date .. theme
        local dial_dirty = full or mode == "clock" or moving or phase == "done" or now - started < 450 or timer_second ~= last_timer_second
        if dial_dirty or key ~= panel_key then
            screen:begin(full and { clear = themes[theme].bg } or nil)
            if full then draw_header() end
            if dial_dirty then draw_dial(now) end
            if full or key ~= panel_key then draw_panel() end
            if full then
                button(clock_box, "CLOCK", mode == "clock", gesture and gesture.target == "clock")
                button(focus_box, "FOCUS", mode == "focus", gesture and gesture.target == "focus")
            end
            screen:present()
            panel_key, last_timer_second, full = key, timer_second, false
        end
        delay.delay_ms((mode == "clock" or moving or gesture or phase == "done" or now - started < 450) and 50 or 100)
    end
end

local ok, err = xpcall(main, debug.traceback)
if not ok then
    print("[clock_dial_demo] ERROR: " .. tostring(err))
    error(err, 0)
end
