local bm = require("board_manager")
local display = require("display")
local delay = require("delay")
local system_ok, system = pcall(require, "system")
local touch_ok, lcd_touch = pcall(require, "lcd_touch")
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
    return { r = r, g = g, b = b }
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local RUN_TIME_MS = int_arg("run_time_ms", 180000)
local TARGET_SIZE = clamp(int_arg("target_size", 480), 240, 800)
local FRAME_MS = 16
local SWIPE_THRESHOLD = 44
local SOUND_VOLUME = 84
local UAC_FLUSH_PCM_BYTES = 4000

local output_codec, board_output_rate, output_channels, output_bits =
    bm.get_audio_codec_output_params("audio_dac")
local OUTPUT_SAMPLE_RATE = int_arg("sample_rate_hz", board_output_rate or 16000)

local panel, io, width, height, panel_if = bm.get_display_lcd_params("display_lcd")
if not panel then
    print("[game_2048] ERROR: get_display_lcd_params(display_lcd) failed: " .. tostring(io))
    return
end

local ok, err = pcall(display.init, panel, io, width, height, panel_if)
if not ok then
    print("[game_2048] ERROR: display.init failed: " .. tostring(err))
    return
end

local screen_ready = true
width = display.width
height = display.height

local touch_handle = nil
local audio_output = nil
local sfx = {}
local pending_sfx = nil

local function cleanup()
    if audio_output then
        pcall(audio_output.close, audio_output)
        audio_output = nil
    end
    if screen_ready then
        pcall(display.end_frame)
        pcall(display.deinit)
        screen_ready = false
    end
end

if width <= 0 or height <= 0 then
    print("[game_2048] ERROR: invalid display size")
    cleanup()
    return
end

if not touch_ok then
    print("[game_2048] ERROR: require(lcd_touch) failed")
    cleanup()
    return
end

local touch_err
touch_handle, touch_err = bm.get_lcd_touch_handle("lcd_touch")
if not touch_handle then
    print("[game_2048] ERROR: get_lcd_touch_handle(lcd_touch) failed: " .. tostring(touch_err))
    cleanup()
    return
end

local synced, sync_err = pcall(lcd_touch.sync, touch_handle)
if not synced then
    print("[game_2048] ERROR: lcd_touch.sync failed: " .. tostring(sync_err))
    cleanup()
    return
end

local function build_tone(freq_hz, duration_ms, amp, wave)
    local rate = OUTPUT_SAMPLE_RATE
    local frames = math.floor(rate * duration_ms / 1000)
    if frames <= 0 then
        return string.rep("\0", UAC_FLUSH_PCM_BYTES)
    end

    local chunks = {}
    local phase = 0
    local step = 2 * math.pi * freq_hz / rate
    for i = 1, frames do
        local raw
        if wave == "square" then
            raw = math.sin(phase) >= 0 and 1 or -1
        else
            raw = math.sin(phase)
        end
        local fade = 1
        if i > frames * 0.72 then
            fade = (frames - i) / math.max(1, frames * 0.28)
        end
        local sample = math.floor(raw * amp * fade)
        phase = phase + step
        if sample > 32767 then sample = 32767 end
        if sample < -32768 then sample = -32768 end
        local u = sample < 0 and sample + 65536 or sample
        chunks[i] = string.char(u % 256, math.floor(u / 256) % 256)
    end

    local pcm = table.concat(chunks)
    if #pcm < UAC_FLUSH_PCM_BYTES then
        pcm = pcm .. string.rep("\0", UAC_FLUSH_PCM_BYTES - #pcm)
    end
    return pcm
end

local function init_audio()
    if not audio_ok or not output_codec then
        print("[game_2048] WARN: audio unavailable")
        return
    end

    local out_ok, out = pcall(function()
        return audio.new_output({
            codec = output_codec,
            sample_rate = OUTPUT_SAMPLE_RATE,
            channels = output_channels,
            bits = output_bits,
            volume = SOUND_VOLUME,
        })
    end)
    if not out_ok or not out then
        print("[game_2048] WARN: audio init failed: " .. tostring(out))
        return
    end

    audio_output = out
    sfx.start = build_tone(660, 80, 12000, "square")
    sfx.move = build_tone(360, 48, 9000, "square")
    sfx.merge = build_tone(920, 80, 13000, "square")
    sfx.block = build_tone(150, 70, 9000, "square")
    sfx.over = build_tone(180, 240, 11000, "square")
    pending_sfx = sfx.start
end

local function request_sfx(name)
    if sfx[name] then
        pending_sfx = sfx[name]
    end
end

local function drain_sfx()
    if not pending_sfx or not audio_output then
        return
    end
    local pcm = pending_sfx
    local wrote, write_err = audio_output:write(pcm)
    if wrote or (write_err and not tostring(write_err):find("busy", 1, true)) then
        pending_sfx = nil
    end
end

init_audio()

local stage = math.min(TARGET_SIZE, width, height)
local sx = math.floor((width - stage) / 2)
local sy = math.floor((height - stage) / 2)
local margin = math.max(10, math.floor(stage * 0.028))
local header_h = math.max(52, math.floor(stage * 0.135))
local gap = math.max(5, math.floor(stage * 0.014))
local board_size = stage - margin * 2 - header_h
board_size = board_size - (board_size % 4)
local cell = math.floor((board_size - gap * 5) / 4)
board_size = cell * 4 + gap * 5
local board_x = sx + math.floor((stage - board_size) / 2)
local board_y = sy + header_h + math.floor((stage - header_h - board_size) / 2)

local BG = rgb(248, 245, 239)
local STAGE_BG = rgb(248, 245, 239)
local PANEL = rgb(157, 143, 132)
local GRID = rgb(187, 175, 165)
local EMPTY = rgb(205, 196, 187)
local BOARD_SHADOW = rgb(222, 214, 205)
local SEPARATOR = rgb(216, 207, 197)
local TEXT = rgb(255, 250, 244)
local TITLE_TEXT = rgb(91, 84, 77)
local SUBTEXT = rgb(239, 232, 224)
local GOLD = rgb(237, 194, 46)
local RED = rgb(246, 94, 59)
local GHOST_COLORS = {
    rgb(230, 222, 213),
    rgb(218, 207, 197),
    rgb(205, 192, 181),
    rgb(192, 177, 165),
}
local GHOST_VALUES = {
    "0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
    "16", "32", "64", "128", "256", "512", "1024", "2048",
}

local TILE_COLORS = {
    [2] = rgb(238, 228, 218),
    [4] = rgb(237, 224, 200),
    [8] = rgb(242, 177, 121),
    [16] = rgb(245, 149, 99),
    [32] = rgb(246, 124, 95),
    [64] = rgb(246, 94, 59),
    [128] = rgb(237, 207, 114),
    [256] = rgb(237, 204, 97),
    [512] = rgb(237, 200, 80),
    [1024] = rgb(237, 197, 63),
    [2048] = rgb(237, 194, 46),
}

local DARK_TEXT = rgb(91, 84, 77)

local board = {}
local score = 0
local best = 0
local game_over = false
local won = false
local touch_down = nil

math.randomseed((os.time() or 1) + width * 17 + height * 31 + now_ms())

local function empty_board()
    board = {}
    for y = 1, 4 do
        board[y] = {}
        for x = 1, 4 do
            board[y][x] = 0
        end
    end
end

local function tile_xy(x, y)
    return board_x + gap + (x - 1) * (cell + gap), board_y + gap + (y - 1) * (cell + gap)
end

local function random_empty_cells(b)
    local cells = {}
    for y = 1, 4 do
        for x = 1, 4 do
            if b[y][x] == 0 then
                cells[#cells + 1] = { x = x, y = y }
            end
        end
    end
    return cells
end

local function add_random_tile()
    local cells = random_empty_cells(board)
    if #cells == 0 then return false end
    local pick = cells[math.random(1, #cells)]
    board[pick.y][pick.x] = math.random(1, 10) == 10 and 4 or 2
    return true
end

local function has_moves()
    if #random_empty_cells(board) > 0 then return true end
    for y = 1, 4 do
        for x = 1, 4 do
            local v = board[y][x]
            if x < 4 and board[y][x + 1] == v then return true end
            if y < 4 and board[y + 1][x] == v then return true end
        end
    end
    return false
end

local function reset_game()
    empty_board()
    score = 0
    game_over = false
    won = false
    add_random_tile()
    add_random_tile()
    request_sfx("start")
end

local function copy_empty()
    local b = {}
    for y = 1, 4 do
        b[y] = { 0, 0, 0, 0 }
    end
    return b
end

local function coords_for(direction, line)
    local coords = {}
    for i = 1, 4 do
        local x, y
        if direction == "left" then
            x, y = i, line
        elseif direction == "right" then
            x, y = 5 - i, line
        elseif direction == "up" then
            x, y = line, i
        else
            x, y = line, 5 - i
        end
        coords[i] = { x = x, y = y }
    end
    return coords
end

local function slide(direction)
    local next_board = copy_empty()
    local movements = {}
    local moved = false
    local merged = false

    for line = 1, 4 do
        local coords = coords_for(direction, line)
        local target_i = 1
        local last_target = nil
        local target_merged = { false, false, false, false }

        for scan_i = 1, 4 do
            local src = coords[scan_i]
            local value = board[src.y][src.x]
            if value ~= 0 then
                if last_target and next_board[last_target.y][last_target.x] == value and not target_merged[target_i - 1] then
                    next_board[last_target.y][last_target.x] = value * 2
                    target_merged[target_i - 1] = true
                    score = score + value * 2
                    if score > best then best = score end
                    if value * 2 >= 2048 then won = true end
                    movements[#movements + 1] = {
                        from_x = src.x, from_y = src.y,
                        to_x = last_target.x, to_y = last_target.y,
                        value = value, merge = true,
                    }
                    moved = moved or src.x ~= last_target.x or src.y ~= last_target.y
                    merged = true
                else
                    local dst = coords[target_i]
                    next_board[dst.y][dst.x] = value
                    last_target = dst
                    movements[#movements + 1] = {
                        from_x = src.x, from_y = src.y,
                        to_x = dst.x, to_y = dst.y,
                        value = value, merge = false,
                    }
                    moved = moved or src.x ~= dst.x or src.y ~= dst.y
                    target_i = target_i + 1
                end
            end
        end
    end

    if not moved and not merged then
        request_sfx("block")
        return false, {}, false
    end

    board = next_board
    return true, movements, merged
end

local function tile_color(value)
    return TILE_COLORS[value] or rgb(58, 138, 205)
end

local function tile_text_color(value)
    if value <= 4 then return DARK_TEXT end
    return TEXT
end

local function draw_bold_text_aligned(x, y, w, h, text, style)
    display.draw_text_aligned(x, y, w, h, text, style)
    display.draw_text_aligned(x + 1, y, w, h, text, {
        color = style.color,
        font_size = style.font_size,
        align = style.align,
        valign = style.valign,
    })
end

local function draw_bold_text(x, y, text, style)
    display.draw_text(x, y, text, style)
    display.draw_text(x + 1, y, text, {
        color = style.color,
        font_size = style.font_size,
    })
end

local function draw_number_background()
    local function draw_layer(zone_x, zone_w, spacing, sizes, salt)
        if zone_w < 24 then return end
        local cols = math.ceil(zone_w / spacing) + 1
        local rows = math.ceil(height / spacing) + 1
        for row = 0, rows - 1 do
            for col = 0, cols - 1 do
                local i = row * cols + col + 1
                local value = GHOST_VALUES[1 + ((i * 7 + col * 5 + row * 3 + salt) % #GHOST_VALUES)]
                local font_size = sizes[1 + ((i * 5 + row * 3 + salt) % #sizes)]
                if #value >= 4 then
                    font_size = math.min(font_size, 16)
                elseif #value == 3 then
                    font_size = math.min(font_size, 20)
                end
                local text_w = math.max(font_size, math.floor(font_size * 0.55 * #value))
                local jitter_x = ((row * 11 + col * 7 + salt) % math.max(3, math.floor(spacing * 0.54)))
                    - math.floor(spacing * 0.27)
                local jitter_y = ((row * 5 + col * 13 + salt) % math.max(3, math.floor(spacing * 0.46)))
                    - math.floor(spacing * 0.23)
                local x = zone_x + col * spacing + jitter_x - math.floor(text_w * 0.18)
                local y = row * spacing + jitter_y - math.floor(font_size * 0.18)
                if x < zone_x + zone_w and x + text_w > zone_x then
                    draw_bold_text(x, y, value, {
                        color = GHOST_COLORS[1 + ((i + row + salt) % #GHOST_COLORS)],
                        font_size = font_size,
                    })
                end
            end
        end
    end

    local left_w = sx
    local right_x = sx + stage
    local right_w = width - right_x
    draw_layer(0, left_w, 62, { 28, 32, 36, 40, 44, 48 }, 3)
    draw_layer(0, left_w, 40, { 12, 16, 20, 24, 28 }, 11)
    draw_layer(right_x, right_w, 62, { 28, 32, 36, 40, 44, 48 }, 7)
    draw_layer(right_x, right_w, 40, { 12, 16, 20, 24, 28 }, 17)
end

local function draw_tile_at(px, py, value, scale)
    if value == 0 then return end
    scale = scale or 1
    local size = math.floor(cell * scale)
    local ox = math.floor((cell - size) / 2)
    local x = px + ox
    local y = py + ox
    local radius = math.max(4, math.floor(size * 0.08))
    local font_size = cell >= 78 and 32 or (cell >= 62 and 28 or (cell >= 46 and 24 or 20))
    if value >= 1024 then
        font_size = cell >= 72 and 24 or (cell >= 46 and 16 or 12)
    elseif value >= 128 then
        font_size = cell >= 72 and 28 or (cell >= 46 and 20 or 16)
    end
    display.fill_round_rect(x, y, size, size, radius, tile_color(value))
    draw_bold_text_aligned(x, y, size, size, tostring(value), {
        color = tile_text_color(value),
        font_size = font_size,
        align = "center",
        valign = "middle",
        bg = tile_color(value),
    })
end

local function draw_stage()
    display.clear(BG)
    draw_number_background()
    if sx > 0 or sy > 0 then
        display.fill_round_rect(sx, sy, stage, stage, 0, STAGE_BG)
    end
    if sx > 0 then
        display.fill_rect(sx - 2, sy, 5, stage, SEPARATOR)
        display.fill_rect(sx + stage, sy, 5, stage, SEPARATOR)
    end

    local compact = stage < 360
    local score_w = compact and 52 or clamp(math.floor(stage * 0.17), 68, 88)
    local score_h = compact and 44 or clamp(math.floor(stage * 0.115), 46, 56)
    local score_gap = compact and 4 or math.max(6, math.floor(stage * 0.015))
    local score_y = sy + (compact and 8 or 16)
    local title_w = compact and 48 or clamp(math.floor(board_size * 0.20), 68, 82)
    local title_color = TILE_COLORS[2048]
    display.fill_round_rect(board_x, score_y, title_w, score_h, 5, title_color)
    draw_bold_text_aligned(board_x, score_y, title_w, score_h, "2048", {
        color = TEXT,
        font_size = compact and 16 or 24,
        align = "center",
        valign = "middle",
        bg = title_color,
    })

    local score_x = board_x + board_size - score_w * 2 - score_gap
    display.fill_round_rect(score_x, score_y, score_w, score_h, 5, PANEL)
    display.draw_text_aligned(score_x, score_y + 3, score_w, math.floor(score_h * 0.36), "SCORE", {
        color = SUBTEXT,
        font_size = 12,
        align = "center",
        valign = "middle",
        bg = PANEL,
    })
    display.draw_text_aligned(score_x, score_y + math.floor(score_h * 0.34), score_w,
        math.floor(score_h * 0.58), tostring(score), {
        color = TEXT,
        font_size = compact and 16 or 20,
        align = "center",
        valign = "middle",
        bg = PANEL,
    })

    local best_x = score_x + score_w + score_gap
    display.fill_round_rect(best_x, score_y, score_w, score_h, 5, PANEL)
    display.draw_text_aligned(best_x, score_y + 3, score_w, math.floor(score_h * 0.36), "BEST", {
        color = SUBTEXT,
        font_size = 12,
        align = "center",
        valign = "middle",
        bg = PANEL,
    })
    display.draw_text_aligned(best_x, score_y + math.floor(score_h * 0.34), score_w,
        math.floor(score_h * 0.58), tostring(best), {
        color = TEXT,
        font_size = compact and 16 or 20,
        align = "center",
        valign = "middle",
        bg = PANEL,
    })

    display.fill_round_rect(board_x + 3, board_y + 4, board_size, board_size, 10, BOARD_SHADOW)
    display.fill_round_rect(board_x, board_y, board_size, board_size, 10, GRID)
    for y = 1, 4 do
        for x = 1, 4 do
            local px, py = tile_xy(x, y)
            display.fill_round_rect(px, py, cell, cell, 7, EMPTY)
        end
    end
end

local function draw_board(skip_dest)
    for y = 1, 4 do
        for x = 1, 4 do
            if not (skip_dest and skip_dest[y] and skip_dest[y][x]) then
                local px, py = tile_xy(x, y)
                draw_tile_at(px, py, board[y][x], 1)
            end
        end
    end
end

local function draw_overlay()
    if not game_over and not won then return end
    local title = game_over and "GAME OVER" or "2048!"
    local sub = game_over and "swipe to restart" or "keep going"
    local panel_w = math.floor(board_size * 0.72)
    local panel_h = 104
    local x = board_x + math.floor((board_size - panel_w) / 2)
    local y = board_y + math.floor((board_size - panel_h) / 2)
    local c = game_over and RED or GOLD
    display.fill_round_rect(x, y, panel_w, panel_h, 10, STAGE_BG)
    display.draw_round_rect(x, y, panel_w, panel_h, 10, c)
    draw_bold_text_aligned(x, y + 18, panel_w, 34, title, {
        color = c,
        font_size = 28,
        align = "center",
        valign = "middle",
        bg = STAGE_BG,
    })
    draw_bold_text_aligned(x, y + 58, panel_w, 24, sub, {
        color = TITLE_TEXT,
        font_size = 16,
        align = "center",
        valign = "middle",
        bg = STAGE_BG,
    })
end

local function render()
    display.begin_frame({ clear = true, color = BG })
    draw_stage()
    draw_board(nil)
    draw_overlay()
    display.present()
    display.end_frame()
end

local function finish_move(merged)
    add_random_tile()
    if not has_moves() then
        game_over = true
        request_sfx("over")
    elseif merged then
        request_sfx("merge")
    else
        request_sfx("move")
    end
end

local function direction_from_swipe(dx, dy)
    if math.abs(dx) < SWIPE_THRESHOLD and math.abs(dy) < SWIPE_THRESHOLD then
        return nil
    end
    if math.abs(dx) > math.abs(dy) then
        return dx > 0 and "right" or "left"
    end
    return dy > 0 and "down" or "up"
end

local function handle_touch()
    local polled, info = pcall(lcd_touch.poll, touch_handle)
    if not polled then
        print("[game_2048] ERROR: lcd_touch.poll failed: " .. tostring(info))
        return nil
    end

    if info.pressed then
        if not touch_down then
            touch_down = { x = info.x, y = info.y }
        end
        return false
    elseif info.just_released then
        if touch_down then
            local direction = direction_from_swipe(info.x - touch_down.x, info.y - touch_down.y)
            touch_down = nil
            return direction or false
        end
        touch_down = nil
    end

    return false
end

reset_game()
render()
print(string.format("[game_2048] ready screen=%dx%d stage=%dx%d run_ms=%d", width, height, stage, stage, RUN_TIME_MS))
print("[game_2048] swipe on the LCD to slide tiles")

local run_ok, run_err = xpcall(function()
    local start = now_ms()
    while now_ms() - start < RUN_TIME_MS do
        drain_sfx()
        local direction = handle_touch()
        if direction == nil then break end
        if direction then
            if game_over then
                reset_game()
            else
                local moved, _, merged = slide(direction)
                if moved then
                    finish_move(merged)
                elseif not has_moves() then
                    game_over = true
                    request_sfx("over")
                end
            end
            render()
        end
        delay.delay_ms(FRAME_MS)
    end
end, debug.traceback)

cleanup()
if not run_ok then
    print("[game_2048] ERROR: " .. tostring(run_err))
end
print("[game_2048] done")
