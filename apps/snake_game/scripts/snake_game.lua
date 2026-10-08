local display = require("display")
local delay = require("delay")
local system = require("system")
local audio_ok, audio = pcall(require, "audio")
local a = type(args) == "table" and args or {}

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function int_arg(name, default)
    local value = a[name]
    return type(value) == "number" and value == value and math.abs(value) < math.huge and math.floor(value) or default
end
local function now_ms() return system.millis() end

local RUN_TIME_MS = math.max(0, int_arg("run_time_ms", 0))
local GRID_N = clamp(int_arg("grid_size", 15), 12, 30)
local TARGET_SIZE = int_arg("target_size", 0)
if TARGET_SIZE > 0 then TARGET_SIZE = clamp(TARGET_SIZE, 160, 1600) end
local START_STEP_MS, MIN_STEP_MS, FRAME_MS = 300, 140, 16
local SOUND_VOLUME, UAC_FLUSH_PCM_BYTES = 84, 4000
local OUTPUT_SAMPLE_RATE, output_channels = 16000, 1
local assets = assert(debug.getinfo(1, "S").source:match("^@(.*)/scripts/[^/]+$"), "cannot resolve Snake path") .. "/assets/"
local canvas = display.open()
local info = canvas:info()
local width, height = info.width, info.height
local audio_output, previous_volume, pending_sfx
local sfx, fonts = {}, {}
local font_sizes = {12, 18, 24, 36, 48}

local function cleanup()
    if audio_output then
        if previous_volume then pcall(audio_output.set_volume, audio_output, previous_volume) end
        pcall(audio_output.close, audio_output)
    end
    for _, font in pairs(fonts) do font:close() end
    canvas:close()
end

if width < 160 or height < 160 or not info.touch_available then
    canvas:close()
    error("[snake_game] touch display of at least 160x160 required")
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
    if not audio_ok or type(audio.open_output) ~= "function" then
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


-- One compact HUD leaves the rest of the screen for the board.
local C = { bg = "#101D22", board = "#182E32", rim = "#30494D", dot = "#243D40",
    text = "#EFF8F3", muted = "#94AAA9", mint = "#7CE6AC", shade = "#389D79",
    shine = "#B9F6CC", orange = "#FFA24B", orange_dark = "#CA683A", shadow = "#0B171B" }
local scale = clamp(math.min(width, height) / 240, 0.8, 2)
local function px(v) return math.floor(v * scale + 0.5) end
local pad, header, footer = px(10), px(42), px(22)
local available_w, available_h = width - pad * 2 - 8, height - header - footer - 8
if TARGET_SIZE > 0 then
    available_w, available_h = math.min(available_w, TARGET_SIZE), math.min(available_h, TARGET_SIZE)
end
local cell = math.max(2, math.floor(math.min(available_w, available_h) / GRID_N))
local cols, rows = math.floor(available_w / cell), math.floor(available_h / cell)
local board_w, board_h = cols * cell, rows * cell
local board_x, board_y = (width - board_w) // 2, header + (height - header - footer - board_h) // 2
local button = px(30)
local exit_x, pause_x = width - pad - button, width - pad - button * 2 - px(6)
local button_y = (header - button) // 2
local swipe_threshold = math.max(12, px(16))
local snake, food = {}, { x = 1, y = 1 }
local dir, pending_dir = "right", "right"
local score, best, phase, won = 0, 0, "ready", false
local touch_down, touch_id
local last_step_ms, step_ms = 0, START_STEP_MS
local DIRS = { up = { dx = 0, dy = -1 }, down = { dx = 0, dy = 1 }, left = { dx = -1, dy = 0 }, right = { dx = 1, dy = 0 } }
local OPPOSITE = { up = "down", down = "up", left = "right", right = "left" }
math.randomseed(os.time() + now_ms())

local function occupies(x, y, max_index)
    local last = max_index or #snake
    for i = 1, last do
        if snake[i].x == x and snake[i].y == y then return true end
    end
    return false
end

local function place_food()
    local free = 0
    for y = 1, rows do
        for x = 1, cols do
            if not occupies(x, y) then
                free = free + 1
                if math.random(free) == 1 then food = { x = x, y = y } end
            end
        end
    end
    if free == 0 then won, phase = true, "game_over" end
end

local function update_speed()
    step_ms = math.max(MIN_STEP_MS, START_STEP_MS - math.floor(score / 5) * 10)
end

local function reset_game(start_dir)
    local next_dir = start_dir or "right"
    local delta = DIRS[next_dir]
    local cx = math.floor(cols / 2) + 1
    local cy = math.floor(rows / 2) + 1
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

    if nx < 1 or nx > cols or ny < 1 or ny > rows then
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

-- Text is measured, never wrapped or painted over rounded corners.
local function text(x, y, w, h, value, size, color, centered)
    value = tostring(value)
    local opts = { color = color }
    local tw, th
    for i = #font_sizes, 1, -1 do
        local size_px = font_sizes[i]
        if size_px <= px(size) + 2 or i == 1 then
            if not fonts[size_px] then fonts[size_px] = display.load_font(assets .. "ui-" .. size_px .. ".dfn") end
            opts.font = fonts[size_px]
            tw, th = canvas:measure_text(value, opts)
            if (tw <= w and th <= h) or i == 1 then break end
        end
    end
    canvas:text(math.floor(x + (centered and (w - tw) / 2 or 0)), math.floor(y + (h - th) / 2), value, opts)
end

local function inside(x, y, bx, by, bw, bh)
    return x >= bx and x < bx + bw and y >= by and y < by + bh
end

local function draw_hud()
    canvas:fill_rect(0, 0, width, header, C.bg)
    local score_x = pad
    if width >= px(275) then
        text(pad, 0, px(64), header, "SNAKE", 18, C.text)
        score_x = pad + px(72)
    end
    local stats_w = pause_x - score_x - px(8)
    text(score_x, 0, stats_w * 0.44, header, string.format("%02d", score), 24, C.mint)
    local best_x, best_w = score_x + stats_w * 0.46, stats_w * 0.54
    if best_w < 60 then
        text(best_x, 0, best_w, header // 2, "BEST", 12, C.muted, true)
        text(best_x, header // 2, best_w, header - header // 2, best, 12, C.muted, true)
    else
        text(best_x, 0, best_w, header, "BEST " .. best, 12, C.muted)
    end
    for _, x in ipairs({pause_x, exit_x}) do canvas:fill_round_rect(x, button_y, button, button, px(8), C.rim) end
    local cx, cy, r = pause_x + button // 2, button_y + button // 2, px(5)
    local color = (phase == "playing" or phase == "paused") and C.text or C.muted
    if phase == "paused" then
        canvas:fill_triangle(cx - r + 1, cy - r - 1, cx - r + 1, cy + r + 1, cx + r + 2, cy, color)
    else
        canvas:fill_rect(cx - r, cy - r, px(3), r * 2, color)
        canvas:fill_rect(cx + r - px(3), cy - r, px(3), r * 2, color)
    end
    cx = exit_x + button // 2
    canvas:line(cx - r, cy - r, cx + r, cy + r, C.text)
    canvas:line(cx + r, cy - r, cx - r, cy + r, C.text)
end

local function cell_origin(point)
    return board_x + (point.x - 1) * cell, board_y + (point.y - 1) * cell
end

local function draw_snake()
    local inset = math.max(1, cell // 10)
    local size, depth = cell - inset, math.max(1, cell // 8)
    for i = #snake, 1, -1 do
        local x, y = cell_origin(snake[i])
        x, y = x + inset, y + inset
        local radius = math.max(1, size // 4)
        if i < #snake then
            local nx, ny = cell_origin(snake[i + 1])
            local bx, by = math.min(x, nx + inset), math.min(y, ny + inset)
            local bw, bh = math.abs(x - nx - inset) + size, math.abs(y - ny - inset) + size
            canvas:fill_round_rect(bx, by, bw, bh, radius, C.shade)
            canvas:fill_round_rect(bx, by, bw, bh - depth, radius, C.mint)
        end
        canvas:fill_round_rect(x, y, size, size, radius, C.shade)
        canvas:fill_round_rect(x, y, size, size - depth, radius, C.mint)
        if size >= 8 then canvas:fill_round_rect(x + 2, y + 1, size - 4, depth, depth // 2, C.shine) end
        if i == 1 and size >= 5 then
            local d, eye = DIRS[dir], math.max(1, cell // 12)
            local cx, cy = x + size // 2, y + (size - depth) // 2
            for _, side in ipairs({-1, 1}) do
                local ex = cx + d.dx * size // 5 - d.dy * side * size // 4
                local ey = cy + d.dy * size // 5 + d.dx * side * size // 4
                canvas:fill_circle(ex, ey, eye, C.bg)
            end
        end
    end
end

local function draw_food()
    if won then return end
    local x, y = cell_origin(food)
    local cx, cy, r = x + cell // 2, y + cell // 2 + 1, math.max(1, cell // 3)
    canvas:fill_circle(cx, cy + 1, r, C.orange_dark)
    canvas:fill_circle(cx, cy, r, C.orange)
    if cell >= 8 then
        canvas:fill_circle(cx - r // 3, cy - r // 3, math.max(1, r // 3), "#FFE0A5")
        canvas:line(cx, cy - r, cx + math.max(1, r // 2), cy - r - 2, C.mint)
    end
end

local function draw_overlay()
    if phase == "playing" then return end
    local w, h = math.min(board_w - px(12), px(214)), math.min(board_h - 8, px(76))
    local x = board_x + (board_w - w) // 2
    local y = phase == "ready" and board_y + board_h - h - px(6) or board_y + (board_h - h) // 2
    local title = phase == "ready" and "Let's play" or phase == "paused" and "Paused" or won and "You win!" or "Nice run!"
    local hint = phase == "ready" and "Swipe or tap to start" or phase == "paused" and "Tap to resume" or "Tap to play again"
    canvas:fill_round_rect(x, y + 3, w, h, px(12), C.shadow)
    canvas:fill_round_rect(x, y, w, h, px(12), C.bg)
    text(x + 6, y + px(5), w - 12, px(30), title, 23, phase == "game_over" and C.orange or C.text, true)
    if phase == "game_over" then
        text(x + 6, y + px(32), w - 12, px(16), "Score " .. score, 12, C.mint, true)
    end
    text(x + 6, y + h - px(25), w - 12, px(20), hint, 12, C.muted, true)
end

local function render(full, refresh_hud)
    canvas:begin(full and { clear = C.bg } or {})
    if full or refresh_hud then draw_hud() end
    canvas:fill_round_rect(board_x - 4, board_y - 4, board_w + 8, board_h + 8, px(10), C.rim)
    canvas:fill_round_rect(board_x - 3, board_y - 3, board_w + 6, board_h + 6, px(9), C.board)
    for y = 1, rows do
        for x = 1, cols do
            canvas:fill_rect(board_x + (x - 1) * cell + cell // 2, board_y + (y - 1) * cell + cell // 2, 1, 1, C.dot)
        end
    end
    draw_food()
    draw_snake()
    draw_overlay()
    if full then text(0, height - footer, width, footer, "Swipe to steer", 12, C.muted, true) end
    canvas:present()
end

local function hit_button(x, y)
    if inside(x, y, exit_x, button_y, button, button) then return "exit" end
    if inside(x, y, pause_x, button_y, button, button) then return "pause" end
end

local function swipe(dx, dy)
    if math.max(math.abs(dx), math.abs(dy)) < swipe_threshold then return nil end
    if math.abs(dx) > math.abs(dy) then return dx > 0 and "right" or "left" end
    return dy > 0 and "down" or "up"
end

-- A button owns its contact; a drag turns once without waiting for release.
local function handle_touch()
    local point
    for _, p in ipairs(canvas:touch().points) do
        if touch_id == nil or p.id == touch_id then point = p; break end
    end
    if point then
        if not touch_down then
            touch_id = point.id
            touch_down = { x = point.x, y = point.y, last_x = point.x, last_y = point.y, button = hit_button(point.x, point.y) }
        end
        touch_down.last_x, touch_down.last_y = point.x, point.y
        if not touch_down.button and not touch_down.used then
            local action = swipe(point.x - touch_down.x, point.y - touch_down.y)
            if action then touch_down.used = true; return action end
        end
    elseif touch_down then
        local t = touch_down
        touch_down, touch_id = nil, nil
        if t.used then return end
        if t.button then
            if t.button == hit_button(t.last_x, t.last_y) and not swipe(t.last_x - t.x, t.last_y - t.y) then return t.button end
        elseif inside(t.x, t.y, board_x, board_y, board_w, board_h) and inside(t.last_x, t.last_y, board_x, board_y, board_w, board_h) then
            return "tap"
        end
    end
end

local run_ok, run_err = xpcall(function()
    init_audio()
    reset_game(nil)
    -- A small preview makes the start screen recognizable before the first move.
    local cx, cy = cols // 2, math.max(3, rows // 3)
    snake = { {x=cx+2,y=cy}, {x=cx+1,y=cy}, {x=cx,y=cy}, {x=cx-1,y=cy}, {x=cx-2,y=cy}, {x=cx-2,y=cy-1} }
    food = { x = math.min(cols, cx + 5), y = cy }
    render(true, true)
    print(string.format("[snake_game] ready screen=%dx%d grid=%dx%d", width, height, cols, rows))
    local run_start = now_ms()
    while RUN_TIME_MS == 0 or now_ms() - run_start < RUN_TIME_MS do
        drain_sfx()
        local action = handle_touch()
        if action == "exit" then break end
        if action == "pause" or (action == "tap" and phase == "paused") then
            if phase == "playing" or phase == "paused" then
                phase = phase == "playing" and "paused" or "playing"
                last_step_ms = now_ms()
                render(false, true)
            end
        elseif action and (action == "tap" or DIRS[action]) then
            if phase == "ready" or phase == "game_over" then
                reset_game(action == "tap" and "right" or action)
                render(false, true)
            elseif phase == "playing" and DIRS[action] then
                set_direction(action)
            end
        end
        local now = now_ms()
        if phase == "playing" and now - last_step_ms >= step_ms then
            last_step_ms = now
            local change = step_game()
            render(false, change.eating or change.game_over)
        end
        delay.delay_ms(FRAME_MS)
    end
end, debug.traceback)
cleanup()
if not run_ok then print("[snake_game] ERROR: " .. tostring(run_err)) end
print("[snake_game] done")
