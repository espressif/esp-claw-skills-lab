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
-- Rasterize elliptical food decorations with horizontal spans.
local function fill_ellipse(cx, cy, rx, ry, color)
    rx, ry = math.floor(rx), math.floor(ry)
    if rx < 1 or ry < 1 then return end
    for dy = -ry, ry do
        local dx = math.floor(rx * math.sqrt(math.max(0, 1 - dy * dy / (ry * ry))))
        canvas:fill_rect(math.floor(cx) - dx, math.floor(cy) + dy, dx * 2 + 1, 1, color)
    end
end

local function aligned_text(x, y, w, h, text, opts)
    opts = opts or {}
    opts.font_size = math.max(8, math.min(64, math.floor(opts.font_size or 24)))
    if opts.bg then canvas:fill_rect(math.floor(x), math.floor(y), math.floor(w), math.floor(h), opts.bg) end
    local tw, th = canvas:measure_text(text, opts)
    if opts.align == "center" then x = x + (w - tw) // 2 elseif opts.align == "right" then x = x + w - tw end
    if opts.valign == "middle" then y = y + (h - th) // 2 elseif opts.valign == "bottom" then y = y + h - th end
    canvas:text(math.floor(x), math.floor(y), text, opts)
end

local delay = require("delay")
local system_ok, system = pcall(require, "system")
local audio_ok, audio = pcall(require, "audio")

local a = type(args) == "table" and args or {}

local function int_arg(name, default)
    local value = a[name]
    if type(value) == "number" then
        return math.floor(value)
    end
    return default
end

local function now_ms()
    if system_ok and system and system.millis then
        return system.millis()
    end
    return math.floor(os.clock() * 1000)
end

local function rgb(r, g, b)
    return { r = math.floor(r), g = math.floor(g), b = math.floor(b) }
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function lerp(a0, b0, t)
    return a0 + (b0 - a0) * t
end

local function mix_color(a0, b0, t)
    return rgb(lerp(a0.r, b0.r, t), lerp(a0.g, b0.g, t), lerp(a0.b, b0.b, t))
end

local RUN_TIME_MS = math.max(0, int_arg("run_time_ms", 0))
local TARGET_SIZE = int_arg("target_size", 0)
if TARGET_SIZE > 0 then TARGET_SIZE = clamp(TARGET_SIZE, 160, 1600) end
local GRID_N = clamp(int_arg("grid_size", 15), 12, 30)
local FRAME_MS = 16
local START_STEP_MS = 300
local MIN_STEP_MS = 140
local SOUND_VOLUME = 84
local UAC_FLUSH_PCM_BYTES = 4000

local OUTPUT_SAMPLE_RATE, output_channels = 16000, 1
local opened, open_err = pcall(display.open)
if not opened then error("display.open failed: " .. tostring(open_err)) end
canvas = open_err
local width, height = canvas:info().width, canvas:info().height
local screen_ready = true
local audio_output = nil
local previous_volume
local sfx = {}
local pending_sfx = nil

local function cleanup()
    if audio_output then
        if previous_volume then pcall(audio_output.set_volume, audio_output, previous_volume) end
        pcall(audio_output.close, audio_output)
        audio_output = nil
    end
    if screen_ready then

        if canvas then canvas:close(); canvas = nil end
        screen_ready = false
    end
end

if width <= 0 or height <= 0 then
    print("[snake_game] ERROR: invalid display size")
    cleanup()
    return
end

if not canvas:info().touch_available then
    cleanup()
    error("built-in touch is unavailable")
end

local function build_tone(freq_hz, duration_ms, amp)
    local rate = OUTPUT_SAMPLE_RATE
    local frames = math.floor(rate * duration_ms / 1000)
    if frames <= 0 then
        return string.rep("\0", UAC_FLUSH_PCM_BYTES)
    end

    local chunks = {}
    local phase_value = 0
    local phase_step = 2 * math.pi * freq_hz / rate
    for i = 1, frames do
        local raw = math.sin(phase_value) >= 0 and 1 or -1
        local fade = 1
        if i > frames * 0.7 then
            fade = (frames - i) / math.max(1, frames * 0.3)
        end
        local sample = math.floor(raw * amp * fade)
        phase_value = phase_value + phase_step
        sample = clamp(sample, -32768, 32767)
        local u = sample < 0 and sample + 65536 or sample
        chunks[i] = string.rep(string.char(u % 256, math.floor(u / 256) % 256), output_channels)
    end

    local pcm = table.concat(chunks)
    if #pcm < UAC_FLUSH_PCM_BYTES then
        pcm = pcm .. string.rep("\0", ((UAC_FLUSH_PCM_BYTES + output_channels * 2 - 1) // (output_channels * 2)) * output_channels * 2 - #pcm)
    end
    return pcm
end

local function init_audio()
    if not audio_ok then
        print("[snake_game] WARN: audio unavailable")
        return
    end

    local out_ok, out = pcall(function()
        return audio.open_output()
    end)
    if not out_ok or not out then
        print("[snake_game] WARN: audio init failed: " .. tostring(out))
        return
    end

    local format = out:info()
    if format.bits ~= 16 then
        out:close()
        print("[snake_game] WARN: sound effects require 16-bit PCM")
        return
    end
    OUTPUT_SAMPLE_RATE, output_channels = format.sample_rate, format.channels
    audio_output = out
    previous_volume = out:get_volume()
    out:set_volume(SOUND_VOLUME)
    sfx.start = build_tone(660, 90, 11000)
    sfx.turn = build_tone(420, 45, 7500)
    sfx.food = build_tone(980, 85, 13000)
    sfx.crash = build_tone(150, 240, 12000)
end

local function request_sfx(name)
    if sfx[name] then pending_sfx = sfx[name] end
end

local function drain_sfx()
    if not pending_sfx or not audio_output then return end
    local wrote, write_err = audio_output:write(pending_sfx)
    if wrote or (write_err and not tostring(write_err):find("busy", 1, true)) then
        pending_sfx = nil
    end
end

init_audio()

local BG = rgb(2, 8, 20)
local BG_STAR = rgb(22, 62, 104)
local PANEL = rgb(5, 18, 38)
local PANEL_ALT = rgb(7, 25, 50)
local BOARD_BG = rgb(3, 14, 31)
local GRID_LINE = rgb(12, 43, 72)
local BORDER = rgb(32, 111, 172)
local BORDER_HI = rgb(102, 224, 255)
local TEXT = rgb(238, 251, 255)
local SUBTEXT = rgb(116, 178, 211)
local CYAN = rgb(75, 218, 255)
local CYAN_DIM = rgb(19, 92, 137)
local WHITE_BLUE = rgb(190, 239, 255)
local SHADOW = rgb(1, 4, 12)

local BODY_PALETTE = {
    rgb(89, 224, 255),
    rgb(92, 157, 255),
    rgb(139, 112, 255),
    rgb(226, 96, 241),
    rgb(255, 102, 158),
    rgb(255, 183, 84),
    rgb(128, 241, 191),
}

local short_side = math.min(width, height)
local pad = math.max(6, math.floor(short_side * 0.025))
local gap = math.max(8, math.floor(short_side * 0.025))
local landscape = width >= 560 and width / height >= 1.25
local board_x, board_y, board_size, cell
local hud_x, hud_y, hud_w, hud_h

if landscape then
    hud_w = clamp(math.floor(width * 0.27), 180, math.floor(width * 0.34))
    hud_x = width - pad - hud_w
    hud_y = pad
    hud_h = height - pad * 2
    local available_w = hud_x - gap - pad
    local available_h = height - pad * 2
    cell = math.max(4, math.floor(math.min(available_w, available_h) / GRID_N))
    if TARGET_SIZE > 0 then cell = math.min(cell, math.floor(TARGET_SIZE / GRID_N)) end
    board_size = cell * GRID_N
    board_x = pad + math.floor((available_w - board_size) / 2)
    board_y = pad + math.floor((available_h - board_size) / 2)
else
    hud_x = pad
    hud_y = pad
    hud_w = width - pad * 2
    hud_h = clamp(math.floor(height * 0.18), 58, 112)
    local available_w = width - pad * 2
    local available_h = height - hud_h - gap - pad * 2
    cell = math.max(4, math.floor(math.min(available_w, available_h) / GRID_N))
    if TARGET_SIZE > 0 then cell = math.min(cell, math.floor(TARGET_SIZE / GRID_N)) end
    board_size = cell * GRID_N
    board_x = pad + math.floor((available_w - board_size) / 2)
    board_y = hud_y + hud_h + gap + math.floor((available_h - board_size) / 2)
end

local swipe_threshold = clamp(math.floor(short_side * 0.05), 20, 36)
local title_font = clamp(math.floor(short_side * 0.075), 22, 40)
local stat_font = clamp(math.floor(short_side * 0.042), 14, 24)
local small_font = clamp(math.floor(short_side * 0.027), 10, 15)
local pause_h = landscape and clamp(math.floor(hud_h * 0.09), 34, 44) or math.max(30, hud_h - 16)
local pause_w = landscape and hud_w or clamp(math.floor(hud_w * 0.18), 72, 112)
local pause_x = landscape and hud_x or hud_x + hud_w - pause_w - 8
local pause_y = hud_y + 8
if landscape then
    local cards_y = hud_y + title_font + small_font + 18
    local card_gap = math.max(5, math.floor(hud_h * 0.014))
    local card_h = clamp(math.floor(hud_h * 0.115), 38, 58)
    local status_y = cards_y + (card_h + card_gap) * 3 + math.max(8, gap)
    pause_y = math.min(status_y + small_font * 2 + 12, hud_y + hud_h - pause_h)
end

local snake = {}
local food = { x = 1, y = 1 }
local dir = "right"
local pending_dir = "right"
local score = 0
local best = 0
local phase = "ready"
local won = false
local touch_down = nil
local last_step_ms = 0
local step_ms = START_STEP_MS

math.randomseed((os.time() or 1) + width * 13 + height * 29 + now_ms())

local DIRS = {
    up = { dx = 0, dy = -1 },
    down = { dx = 0, dy = 1 },
    left = { dx = -1, dy = 0 },
    right = { dx = 1, dy = 0 },
}

local OPPOSITE = {
    up = "down",
    down = "up",
    left = "right",
    right = "left",
}

local function cell_center(x, y)
    return board_x + math.floor((x - 0.5) * cell), board_y + math.floor((y - 0.5) * cell)
end

local function occupies(x, y, max_index)
    local last = max_index or #snake
    for i = 1, last do
        if snake[i].x == x and snake[i].y == y then return true end
    end
    return false
end

local function place_food()
    local free = {}
    for y = 1, GRID_N do
        for x = 1, GRID_N do
            if not occupies(x, y) then free[#free + 1] = { x = x, y = y } end
        end
    end
    if #free == 0 then
        won = true
        phase = "game_over"
        return
    end
    food = free[math.random(1, #free)]
end

local function update_speed()
    step_ms = math.max(MIN_STEP_MS, START_STEP_MS - math.floor(score / 5) * 10)
end

local function reset_game(start_dir)
    local next_dir = start_dir or "right"
    local delta = DIRS[next_dir]
    local cx = math.floor(GRID_N / 2) + 1
    local cy = math.floor(GRID_N / 2) + 1
    snake = {
        { x = cx, y = cy },
        { x = cx - delta.dx, y = cy - delta.dy },
        { x = cx - delta.dx * 2, y = cy - delta.dy * 2 },
    }
    dir = next_dir
    pending_dir = next_dir
    score = 0
    won = false
    phase = start_dir and "playing" or "ready"
    touch_down = nil
    update_speed()
    place_food()
    last_step_ms = now_ms()
    if start_dir then request_sfx("start") end
end

local function set_direction(next_dir)
    if not DIRS[next_dir] or next_dir == OPPOSITE[dir] then return false end
    if next_dir ~= pending_dir then
        pending_dir = next_dir
        request_sfx("turn")
    end
    return true
end

local function step_game()
    if phase ~= "playing" then return { idle = true } end
    dir = pending_dir
    local delta = DIRS[dir]
    local head = snake[1]
    local nx = head.x + delta.dx
    local ny = head.y + delta.dy
    local eating = nx == food.x and ny == food.y

    if nx < 1 or nx > GRID_N or ny < 1 or ny > GRID_N then
        phase = "game_over"
        request_sfx("crash")
        return { game_over = true }
    end

    local check_until = eating and #snake or (#snake - 1)
    if occupies(nx, ny, check_until) then
        phase = "game_over"
        request_sfx("crash")
        return { game_over = true }
    end

    table.insert(snake, 1, { x = nx, y = ny })
    if eating then
        score = score + 1
        if score > best then best = score end
        update_speed()
        request_sfx("food")
        place_food()
    else
        table.remove(snake)
    end
    return { moved = true, eating = eating }
end

local function draw_background()
    canvas:fill_rect(0, 0, canvas:info().width, canvas:info().height, BG)
    for i = 1, 30 do
        local x = (i * 83 + 17) % width
        local y = (i * 47 + 29) % height
        canvas:fill_rect(x, y, i % 5 == 0 and 2 or 1, i % 5 == 0 and 2 or 1, BG_STAR)
    end
end

local function draw_stat_card(x, y, w, h, label, value, accent)
    local radius = math.max(4, math.floor(h * 0.12))
    canvas:fill_round_rect(x, y, w, h, radius, PANEL_ALT)
    canvas:stroke_round_rect(x, y, w, h, radius, accent)
    local label_w = math.floor(w * 0.52)
    aligned_text(x + 10, y, label_w - 10, h, label, {
        color = SUBTEXT, font_size = small_font, align = "left", valign = "middle", bg = PANEL_ALT,
    })
    aligned_text(x + label_w, y, w - label_w - 10, h, tostring(value), {
        color = accent, font_size = stat_font, align = "right", valign = "middle", bg = PANEL_ALT,
    })
end

local function draw_pause_button()
    local active = phase == "playing" or phase == "paused"
    local color = active and CYAN or CYAN_DIM
    local label = phase == "paused" and "RESUME" or "PAUSE"
    canvas:fill_round_rect(pause_x, pause_y, pause_w, pause_h, 6, PANEL_ALT)
    canvas:stroke_round_rect(pause_x, pause_y, pause_w, pause_h, 6, color)
    aligned_text(pause_x, pause_y, pause_w, pause_h, label, {
        color = color, font_size = small_font, align = "center", valign = "middle", bg = PANEL_ALT,
    })
end

local function draw_hud()
    if landscape then
        canvas:fill_rect(hud_x, hud_y, hud_w, hud_h, BG)
        aligned_text(hud_x, hud_y, hud_w, title_font + 8, "SNAKE", {
            color = TEXT, font_size = title_font, align = "center", valign = "middle", bg = BG,
        })
        aligned_text(hud_x, hud_y + title_font + 2, hud_w, small_font + 8, "DATA STREAM", {
            color = CYAN, font_size = small_font, align = "center", valign = "middle", bg = BG,
        })

        local cards_y = hud_y + title_font + small_font + 18
        local card_gap = math.max(5, math.floor(hud_h * 0.014))
        local card_h = clamp(math.floor(hud_h * 0.115), 38, 58)
        draw_stat_card(hud_x, cards_y, hud_w, card_h, "SCORE", score, CYAN)
        draw_stat_card(hud_x, cards_y + card_h + card_gap, hud_w, card_h, "BEST", best, WHITE_BLUE)
        draw_stat_card(hud_x, cards_y + (card_h + card_gap) * 2, hud_w, card_h,
            "LEVEL", 1 + math.floor(score / 5), CYAN)
        local status_y = cards_y + (card_h + card_gap) * 3 + math.max(8, gap)
        canvas:line(hud_x + 8, status_y, hud_x + hud_w - 8, status_y, CYAN_DIM)
        aligned_text(hud_x, status_y + 5, hud_w, small_font * 2, "SWIPE TO STEER", {
            color = SUBTEXT, font_size = small_font, align = "center", valign = "middle", bg = BG,
        })
        draw_pause_button()
    else
        canvas:fill_round_rect(hud_x, hud_y, hud_w, hud_h, 7, PANEL)
        canvas:stroke_round_rect(hud_x, hud_y, hud_w, hud_h, 7, BORDER)
        local title_w = math.floor(hud_w * 0.25)
        aligned_text(hud_x + 6, hud_y, title_w, hud_h, "SNAKE", {
            color = CYAN, font_size = title_font, align = "left", valign = "middle", bg = PANEL,
        })
        local stats_x = hud_x + title_w
        local stats_w = pause_x - stats_x - 6
        local score_w = math.floor(stats_w * 0.38)
        local best_w = math.floor(stats_w * 0.36)
        local level_w = stats_w - score_w - best_w
        aligned_text(stats_x, hud_y, score_w, hud_h, "SCORE " .. tostring(score), {
            color = TEXT, font_size = small_font, align = "left", valign = "middle", bg = PANEL,
        })
        aligned_text(stats_x + score_w, hud_y, best_w, hud_h, "BEST " .. tostring(best), {
            color = TEXT, font_size = small_font, align = "left", valign = "middle", bg = PANEL,
        })
        aligned_text(stats_x + score_w + best_w, hud_y, level_w, hud_h,
            "LV " .. tostring(1 + math.floor(score / 5)), {
            color = CYAN, font_size = small_font, align = "right", valign = "middle", bg = PANEL,
        })
        draw_pause_button()
    end
end

local function draw_board_shell()
    local radius = math.max(5, math.floor(cell * 0.35))
    canvas:fill_round_rect(board_x + 4, board_y + 5, board_size, board_size, radius, SHADOW)
    canvas:fill_round_rect(board_x, board_y, board_size, board_size, radius, BOARD_BG)
    canvas:stroke_round_rect(board_x, board_y, board_size, board_size, radius, BORDER_HI)
    canvas:stroke_round_rect(board_x + 2, board_y + 2, board_size - 4, board_size - 4, radius, BORDER)
end

local function draw_board_base()
    draw_board_shell()
    for i = 0, GRID_N do
        local p = i * cell
        canvas:line(board_x + p, board_y, board_x + p, board_y + board_size, GRID_LINE)
        canvas:line(board_x, board_y + p, board_x + board_size, board_y + p, GRID_LINE)
    end
end

local function body_color(index)
    local unlocked = clamp(1 + (#snake - 3), 1, #BODY_PALETTE)
    if #snake <= 1 or unlocked == 1 then return BODY_PALETTE[1] end
    local scaled = (index - 1) / (#snake - 1) * (unlocked - 1)
    local left = math.floor(scaled) + 1
    local right = math.min(unlocked, left + 1)
    return mix_color(BODY_PALETTE[left], BODY_PALETTE[right], scaled - math.floor(scaled))
end

local function body_radius(index)
    local base = math.max(3, math.floor(cell * 0.36))
    local from_tail = #snake - index
    if from_tail >= 2 then return base end
    return math.max(2, math.floor(base * (0.6 + from_tail * 0.2)))
end

local function draw_link(a0, b0, radius, color, ox, oy)
    local ax, ay = cell_center(a0.x, a0.y)
    local bx, by = cell_center(b0.x, b0.y)
    ax, ay, bx, by = ax + ox, ay + oy, bx + ox, by + oy
    if ax == bx then
        canvas:fill_rect(ax - radius, math.min(ay, by), radius * 2 + 1, math.abs(by - ay) + 1, color)
    else
        canvas:fill_rect(math.min(ax, bx), ay - radius, math.abs(bx - ax) + 1, radius * 2 + 1, color)
    end
end

local function draw_snake_body()
    for i = 1, #snake - 1 do
        local radius = math.min(body_radius(i), body_radius(i + 1)) + 2
        draw_link(snake[i], snake[i + 1], radius, SHADOW, 2, 3)
    end
    for i = #snake, 2, -1 do
        local x, y = cell_center(snake[i].x, snake[i].y)
        canvas:fill_circle(x + 2, y + 3, body_radius(i) + 2, SHADOW)
    end

    for i = 1, #snake - 1 do
        local radius = math.min(body_radius(i), body_radius(i + 1))
        draw_link(snake[i], snake[i + 1], radius, body_color(i + 0.5), 0, 0)
    end
    for i = #snake, 2, -1 do
        local x, y = cell_center(snake[i].x, snake[i].y)
        canvas:fill_circle(x, y, body_radius(i), body_color(i))
    end
end

local function local_point(cx, cy, forward, side, f, s)
    return math.floor(cx + forward.dx * f + side.dx * s),
        math.floor(cy + forward.dy * f + side.dy * s)
end

local function draw_snake_head()
    local head = snake[1]
    local cx, cy = cell_center(head.x, head.y)
    local forward = DIRS[dir]
    local side = { dx = -forward.dy, dy = forward.dx }
    local rx = math.max(6, math.floor(cell * (forward.dx ~= 0 and 0.54 or 0.41)))
    local ry = math.max(6, math.floor(cell * (forward.dy ~= 0 and 0.54 or 0.41)))
    local shift = math.floor(cell * 0.12)
    cx = cx + forward.dx * shift
    cy = cy + forward.dy * shift

    fill_ellipse(cx + 2, cy + 3, rx + 2, ry + 2, SHADOW)
    fill_ellipse(cx, cy, rx + 1, ry + 1, CYAN_DIM)
    fill_ellipse(cx, cy, rx, ry, WHITE_BLUE)

    local nose_f = math.floor(cell * 0.34)
    local nose_half = math.max(2, math.floor(cell * 0.12))
    local nx, ny = local_point(cx, cy, forward, side, nose_f, 0)
    local bx1, by1 = local_point(cx, cy, forward, side, math.floor(cell * 0.02), -nose_half)
    local bx2, by2 = local_point(cx, cy, forward, side, math.floor(cell * 0.02), nose_half)
    canvas:fill_triangle(nx, ny, bx1, by1, bx2, by2, CYAN)

    local core_f = math.floor(cell * 0.05)
    local core_r = math.max(2, math.floor(cell * 0.12))
    local core_x, core_y = local_point(cx, cy, forward, side, core_f, 0)
    canvas:fill_circle(core_x, core_y, core_r + 2, rgb(11, 54, 89))
    canvas:fill_circle(core_x, core_y, core_r, CYAN)
    canvas:fill_circle(core_x - side.dx, core_y - side.dy, math.max(1, core_r // 3), TEXT)

    local fin_f = -math.floor(cell * 0.15)
    local fin_side = math.max(3, math.floor(cell * 0.25))
    local tail_x, tail_y = local_point(cx, cy, forward, side, -math.floor(cell * 0.38), 0)
    local f1x, f1y = local_point(cx, cy, forward, side, fin_f, -fin_side)
    local f2x, f2y = local_point(cx, cy, forward, side, fin_f, fin_side)
    canvas:line(tail_x, tail_y, f1x, f1y, CYAN)
    canvas:line(tail_x, tail_y, f2x, f2y, CYAN)
end

local function draw_data_cursor(cx, cy, r, color)
    local arm = r + math.max(2, math.floor(r * 0.55))
    canvas:line(cx - arm, cy, cx - r, cy, CYAN_DIM)
    canvas:line(cx + r, cy, cx + arm, cy, CYAN_DIM)
    canvas:line(cx, cy - arm, cx, cy - r, CYAN_DIM)
    canvas:line(cx, cy + r, cx, cy + arm, CYAN_DIM)
    canvas:stroke_round_rect(cx - r, cy - r, r * 2, r * 2, 2, color)
end

local function draw_food()
    local cx, cy = cell_center(food.x, food.y)
    local r = math.max(4, math.floor(cell * 0.28))
    draw_data_cursor(cx, cy, r, CYAN)
    canvas:fill_rect(cx - math.max(1, r // 3), cy - math.max(1, r // 3),
        math.max(3, r * 2 // 3), math.max(3, r * 2 // 3), TEXT)
end

local function draw_overlay()
    if phase == "playing" then return end
    local panel_w = math.min(math.floor(board_size * 0.74), 390)
    local panel_h = clamp(math.floor(board_size * 0.20), 68, 96)
    local x = board_x + math.floor((board_size - panel_w) / 2)
    local y = phase == "ready"
        and board_y + board_size - panel_h - math.max(8, math.floor(cell * 0.5))
        or board_y + math.floor((board_size - panel_h) / 2)
    local accent = CYAN
    local title = phase == "ready" and "READY?"
        or (phase == "paused" and "PAUSED" or (won and "YOU WIN!" or "GAME OVER"))
    local hint = phase == "ready" and "SWIPE TO START"
        or (phase == "paused" and "TAP RESUME" or "SWIPE TO RESTART")
    canvas:fill_round_rect(x + 4, y + 5, panel_w, panel_h, 9, SHADOW)
    canvas:fill_round_rect(x, y, panel_w, panel_h, 9, PANEL)
    canvas:stroke_round_rect(x, y, panel_w, panel_h, 9, accent)
    aligned_text(x, y + 4, panel_w, math.floor(panel_h * 0.52), title, {
        color = TEXT, font_size = clamp(math.floor(panel_h * 0.28), 18, 28),
        align = "center", valign = "middle", bg = PANEL,
    })
    aligned_text(x, y + math.floor(panel_h * 0.52), panel_w, math.floor(panel_h * 0.38), hint, {
        color = CYAN, font_size = small_font, align = "center", valign = "middle", bg = PANEL,
    })
end

local function draw_board_content()
    if phase == "ready" then
        draw_board_shell()
        draw_overlay()
        return
    end
    draw_board_base()
    draw_food()
    draw_snake_body()
    draw_snake_head()
    draw_overlay()
end

local function render(full, refresh_hud)
    canvas:begin(full and { clear = BG } or {})
    if full then draw_background() end
    if full or refresh_hud then draw_hud() end
    draw_board_content()
    canvas:present()

end

local function direction_from_swipe(dx, dy)
    if math.abs(dx) < swipe_threshold and math.abs(dy) < swipe_threshold then return nil end
    if math.abs(dx) > math.abs(dy) then return dx > 0 and "right" or "left" end
    return dy > 0 and "down" or "up"
end

local function handle_touch()
    local polled, info = pcall(poll_touch_snapshot)
    if not polled then
        print("[snake_game] ERROR: screen touch failed: " .. tostring(info))
        return nil
    end
    if info.pressed then
        if not touch_down then touch_down = { x = info.x, y = info.y } end
    elseif info.just_released then
        if not touch_down then return false end
        local dx = info.x - touch_down.x
        local dy = info.y - touch_down.y
        touch_down = nil
        if math.abs(dx) < swipe_threshold and math.abs(dy) < swipe_threshold
            and info.x >= pause_x and info.x <= pause_x + pause_w
            and info.y >= pause_y and info.y <= pause_y + pause_h then
            return "toggle_pause"
        end
        local action = direction_from_swipe(dx, dy)
        return action or false
    end
    return false
end

reset_game(nil)
render(true, true)
print(string.format("[snake_game] ready screen=%dx%d board=%dx%d grid=%d swipe=%d run_ms=%d",
    width, height, board_size, board_size, GRID_N, swipe_threshold, RUN_TIME_MS))
print("[snake_game] swipe up/down/left/right to start and steer")

local run_ok, run_err = xpcall(function()
    local run_start = now_ms()
    while RUN_TIME_MS == 0 or now_ms() - run_start < RUN_TIME_MS do
        drain_sfx()
        local action = handle_touch()
        if action == nil then break end
        if action then
            if action == "toggle_pause" then
                if phase == "playing" then
                    phase = "paused"
                    render(true, true)
                elseif phase == "paused" then
                    phase = "playing"
                    last_step_ms = now_ms()
                    render(true, true)
                end
            elseif phase == "ready" then
                reset_game(action)
                render(true, true)
            elseif phase == "game_over" then
                reset_game(action)
                render(true, true)
            elseif phase == "playing" then
                set_direction(action)
            end
        end

        local now = now_ms()
        if phase == "playing" and now - last_step_ms >= step_ms then
            last_step_ms = now
            local change = step_game()
            render(false, change.eating)
        end
        delay.delay_ms(FRAME_MS)
    end
end, debug.traceback)

cleanup()
if not run_ok then print("[snake_game] ERROR: " .. tostring(run_err)) end
print("[snake_game] done")
