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

local RUN_TIME_MS = int_arg("run_time_ms", 600000)
local TARGET_SIZE = clamp(int_arg("target_size", 480), 240, 800)
local SHUFFLE_STEPS = clamp(int_arg("shuffle_steps", 140), 20, 800)
local PERF_LOG = int_arg("perf_log", 1) ~= 0
local FRAME_MS = 16
local TAP_SLOP = 18
local SWIPE_THRESHOLD = 44
local SOUND_VOLUME = 84
local UAC_FLUSH_PCM_BYTES = 4000

local function log_perf(label, message)
    if PERF_LOG then
        print("[number_puzzle][perf] " .. label .. " " .. message)
    end
end

local output_codec, board_output_rate, output_channels, output_bits =
    bm.get_audio_codec_output_params("audio_dac")
local OUTPUT_SAMPLE_RATE = int_arg("sample_rate_hz", board_output_rate or 16000)

local panel, io, width, height, panel_if = bm.get_display_lcd_params("display_lcd")
if not panel then
    print("[number_puzzle] ERROR: get_display_lcd_params(display_lcd) failed: " .. tostring(io))
    return
end

local ok, err = pcall(display.init, panel, io, width, height, panel_if)
if not ok then
    print("[number_puzzle] ERROR: display.init failed: " .. tostring(err))
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
    print("[number_puzzle] ERROR: invalid display size")
    cleanup()
    return
end

if not touch_ok then
    print("[number_puzzle] ERROR: require(lcd_touch) failed")
    cleanup()
    return
end

local touch_err
touch_handle, touch_err = bm.get_lcd_touch_handle("lcd_touch")
if not touch_handle then
    print("[number_puzzle] ERROR: get_lcd_touch_handle(lcd_touch) failed: " .. tostring(touch_err))
    cleanup()
    return
end

local synced, sync_err = pcall(lcd_touch.sync, touch_handle)
if not synced then
    print("[number_puzzle] ERROR: lcd_touch.sync failed: " .. tostring(sync_err))
    cleanup()
    return
end

local function build_tone(freq_hz, duration_ms, amp)
    local rate = OUTPUT_SAMPLE_RATE
    local frames = math.floor(rate * duration_ms / 1000)
    if frames <= 0 then
        return string.rep("\0", UAC_FLUSH_PCM_BYTES)
    end

    local chunks = {}
    local phase = 0
    local step = 2 * math.pi * freq_hz / rate
    for i = 1, frames do
        local raw = math.sin(phase) >= 0 and 1 or -1
        local fade = 1
        if i > frames * 0.68 then
            fade = (frames - i) / math.max(1, frames * 0.32)
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
        print("[number_puzzle] WARN: audio unavailable")
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
        print("[number_puzzle] WARN: audio init failed: " .. tostring(out))
        return
    end

    audio_output = out
    sfx.shuffle = build_tone(620, 90, 12000)
    sfx.move = build_tone(380, 50, 9000)
    sfx.block = build_tone(150, 75, 8500)
    sfx.win = build_tone(1040, 220, 13000)
    pending_sfx = sfx.shuffle
end

local function request_sfx(name)
    if sfx[name] then
        pending_sfx = sfx[name]
    end
end

local function drain_sfx()
    if not pending_sfx or not audio_output then
        return false, 0
    end
    local t0 = now_ms()
    local pcm = pending_sfx
    local wrote, write_err = audio_output:write(pcm)
    if wrote or (write_err and not tostring(write_err):find("busy", 1, true)) then
        pending_sfx = nil
    end
    return true, now_ms() - t0
end

init_audio()

local stage = math.min(TARGET_SIZE, width, height)
local sx = math.floor((width - stage) / 2)
local sy = math.floor((height - stage) / 2)
local margin = math.max(14, math.floor(stage * 0.05))
local header_h = math.max(70, math.floor(stage * 0.17))
local gap = math.max(6, math.floor(stage * 0.018))
local board_size = stage - margin * 2 - header_h
board_size = board_size - (board_size % 4)
local cell = math.floor((board_size - gap * 5) / 4)
board_size = cell * 4 + gap * 5
local board_x = sx + math.floor((stage - board_size) / 2)
local board_y = sy + header_h + math.floor((stage - header_h - board_size) / 2)
local compact_header = stage < 480
local toolbar_gap = compact_header and 5 or 7
local new_w = compact_header and 58 or 68
local new_h = compact_header and 26 or 54
local time_w = compact_header and 72 or 84
local moves_w = compact_header and 68 or 80
local new_x = sx + stage - margin - new_w
local new_y = compact_header and sy + 40 or sy + 9
local time_x = new_x - toolbar_gap - time_w
local moves_x = time_x - toolbar_gap - moves_w

local BG = rgb(54, 34, 20)
local STAGE_BG = rgb(104, 67, 36)
local PANEL = rgb(126, 82, 42)
local GRID = rgb(96, 57, 28)
local EMPTY = rgb(72, 43, 24)
local TILE = rgb(224, 162, 82)
local TILE_DARK = rgb(132, 78, 34)
local TILE_ALT = rgb(239, 185, 104)
local TILE_ALT_DARK = rgb(150, 92, 38)
local TEXT = rgb(255, 239, 203)
local DARK_TEXT = rgb(57, 34, 20)
local SUBTEXT = rgb(244, 203, 144)
local GREEN = rgb(129, 194, 102)
local RED = rgb(191, 75, 56)
local FRAME_LINE = rgb(246, 189, 105)
local SHADOW = rgb(38, 22, 13)

local board = {}
local empty_x = 4
local empty_y = 4
local moves = 0
local best_moves = 0
local start_ms = now_ms()
local run_start_ms = now_ms()
local won = false
local touch_down = nil

math.randomseed((os.time() or 1) + width * 19 + height * 23 + now_ms())

local function set_solved()
    local n = 1
    board = {}
    for y = 1, 4 do
        board[y] = {}
        for x = 1, 4 do
            if x == 4 and y == 4 then
                board[y][x] = 0
            else
                board[y][x] = n
                n = n + 1
            end
        end
    end
    empty_x = 4
    empty_y = 4
end

local function is_solved()
    local n = 1
    for y = 1, 4 do
        for x = 1, 4 do
            if x == 4 and y == 4 then
                if board[y][x] ~= 0 then return false end
            elseif board[y][x] ~= n then
                return false
            end
            n = n + 1
        end
    end
    return true
end

local function tile_xy(x, y)
    return board_x + gap + (x - 1) * (cell + gap), board_y + gap + (y - 1) * (cell + gap)
end

local function legal_neighbors()
    local cells = {}
    if empty_x > 1 then cells[#cells + 1] = { x = empty_x - 1, y = empty_y } end
    if empty_x < 4 then cells[#cells + 1] = { x = empty_x + 1, y = empty_y } end
    if empty_y > 1 then cells[#cells + 1] = { x = empty_x, y = empty_y - 1 } end
    if empty_y < 4 then cells[#cells + 1] = { x = empty_x, y = empty_y + 1 } end
    return cells
end

local function swap_with_empty(x, y)
    board[empty_y][empty_x] = board[y][x]
    board[y][x] = 0
    empty_x = x
    empty_y = y
end

local function shuffle_board()
    local last_x, last_y = nil, nil
    for _ = 1, SHUFFLE_STEPS do
        local choices = legal_neighbors()
        local filtered = {}
        for _, c in ipairs(choices) do
            if not (c.x == last_x and c.y == last_y) then
                filtered[#filtered + 1] = c
            end
        end
        if #filtered > 0 then
            choices = filtered
        end
        local pick = choices[math.random(1, #choices)]
        last_x, last_y = empty_x, empty_y
        swap_with_empty(pick.x, pick.y)
    end
end

local function new_game()
    set_solved()
    repeat
        shuffle_board()
    until not is_solved()
    moves = 0
    won = false
    start_ms = now_ms()
    touch_down = nil
    request_sfx("shuffle")
end

local function adjacent_to_empty(x, y)
    return math.abs(x - empty_x) + math.abs(y - empty_y) == 1
end

local function elapsed_seconds()
    return math.max(0, math.floor((now_ms() - start_ms) / 1000))
end

local function remaining_seconds()
    return math.max(0, math.ceil((RUN_TIME_MS - (now_ms() - run_start_ms)) / 1000))
end

local function format_time(sec)
    local m = math.floor(sec / 60)
    local s = sec % 60
    return string.format("%02d:%02d", m, s)
end

local function tile_at_point(px, py)
    if px >= new_x and px <= new_x + new_w and py >= new_y and py <= new_y + new_h then
        return "new"
    end
    if px < board_x or py < board_y or px >= board_x + board_size or py >= board_y + board_size then
        return nil
    end
    local rel_x = px - board_x
    local rel_y = py - board_y
    local x = math.floor(rel_x / (cell + gap)) + 1
    local y = math.floor(rel_y / (cell + gap)) + 1
    if x < 1 or x > 4 or y < 1 or y > 4 then return nil end
    local inner_x = rel_x - (x - 1) * (cell + gap)
    local inner_y = rel_y - (y - 1) * (cell + gap)
    if inner_x < gap or inner_y < gap then return nil end
    if board[y][x] == 0 then return nil end
    return { x = x, y = y }
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

local function tile_for_swipe(direction)
    local x = empty_x
    local y = empty_y
    if direction == "left" then
        x = empty_x + 1
    elseif direction == "right" then
        x = empty_x - 1
    elseif direction == "up" then
        y = empty_y + 1
    elseif direction == "down" then
        y = empty_y - 1
    end
    if x < 1 or x > 4 or y < 1 or y > 4 then
        return { blocked = true }
    end
    return { x = x, y = y }
end

local function draw_tile_at(px, py, value)
    if value == 0 then return end
    local color = (value % 2 == 0) and TILE or TILE_ALT
    local border = (value % 2 == 0) and TILE_DARK or TILE_ALT_DARK
    display.fill_rect(px + 2, py + 3, cell, cell, SHADOW)
    display.fill_rect(px, py, cell, cell, color)
    display.draw_rect(px, py, cell, cell, border)
    display.fill_rect(px + 5, py + 6, cell - 10, 2, rgb(255, 214, 137))
    display.draw_text_aligned(px, py, cell, cell, tostring(value), {
        color = DARK_TEXT,
        font_size = value >= 10 and 27 or 31,
        align = "center",
        valign = "middle",
        bg = color,
    })
end

local function draw_empty_cell(x, y)
    local px, py = tile_xy(x, y)
    display.fill_rect(px + 2, py + 3, cell, cell, GRID)
    display.fill_rect(px, py, cell, cell, EMPTY)
    display.draw_rect(px, py, cell, cell, rgb(115, 68, 32))
end

local function draw_cell(x, y)
    local px, py = tile_xy(x, y)
    draw_empty_cell(x, y)
    draw_tile_at(px, py, board[y][x])
end

local function draw_info()
    local font_size = compact_header and 12 or 13
    display.fill_rect(moves_x, new_y, moves_w, new_h, GRID)
    display.draw_rect(moves_x, new_y, moves_w, new_h, PANEL)
    display.fill_rect(time_x, new_y, time_w, new_h, GRID)
    display.draw_rect(time_x, new_y, time_w, new_h, PANEL)
    if compact_header then
        display.draw_text_aligned(moves_x, new_y, moves_w, new_h, "MOVES " .. tostring(moves), {
            color = TEXT, font_size = font_size, align = "center", valign = "middle", bg = GRID,
        })
        display.draw_text_aligned(time_x, new_y, time_w, new_h, "TIME " .. format_time(remaining_seconds()), {
            color = TEXT, font_size = font_size, align = "center", valign = "middle", bg = GRID,
        })
    else
        local label_h = 22
        display.draw_text_aligned(moves_x, new_y + 2, moves_w, label_h, "MOVES", {
            color = TEXT, font_size = 12, align = "center", valign = "middle", bg = GRID,
        })
        display.draw_text_aligned(moves_x, new_y + label_h - 1, moves_w, new_h - label_h, tostring(moves), {
            color = FRAME_LINE, font_size = 19, align = "center", valign = "middle", bg = GRID,
        })
        display.draw_text_aligned(time_x, new_y + 2, time_w, label_h, "TIME", {
            color = TEXT, font_size = 12, align = "center", valign = "middle", bg = GRID,
        })
        display.draw_text_aligned(time_x, new_y + label_h - 1, time_w, new_h - label_h,
            format_time(remaining_seconds()), {
            color = FRAME_LINE, font_size = 16, align = "center", valign = "middle", bg = GRID,
        })
    end
end

local function draw_stage()
    display.clear(BG)
    display.fill_rect(sx, sy, stage, stage, STAGE_BG)
    display.draw_rect(sx, sy, stage, stage, FRAME_LINE)
    local title_x = sx + margin
    local title_y = compact_header and sy + 5 or sy + 9
    local title_w = compact_header and 106 or math.min(120, moves_x - title_x - toolbar_gap)
    local title_h = compact_header and 32 or 54
    display.fill_round_rect(title_x, title_y, title_w, title_h, 6, PANEL)
    display.draw_round_rect(title_x, title_y, title_w, title_h, 6, FRAME_LINE)
    display.draw_text_aligned(title_x, title_y + 2, title_w, math.floor(title_h / 2), "Number", {
        color = TEXT,
        font_size = compact_header and 14 or 18,
        align = "center",
        valign = "middle",
        bg = PANEL,
    })
    display.draw_text_aligned(title_x, title_y + math.floor(title_h / 2) - 2,
        title_w, math.ceil(title_h / 2), "Puzzle", {
        color = SUBTEXT,
        font_size = compact_header and 14 or 18,
        align = "center",
        valign = "middle",
        bg = PANEL,
    })

    display.fill_rect(new_x + 2, new_y + 3, new_w, new_h, SHADOW)
    display.fill_rect(new_x, new_y, new_w, new_h, TILE_ALT)
    display.draw_rect(new_x, new_y, new_w, new_h, TILE_ALT_DARK)
    display.draw_text_aligned(new_x, new_y, new_w, new_h, "NEW", {
        color = DARK_TEXT,
        font_size = compact_header and 14 or 16,
        align = "center",
        valign = "middle",
        bg = TILE_ALT,
    })

    draw_info()

    display.fill_rect(board_x + 4, board_y + 5, board_size, board_size, SHADOW)
    display.fill_rect(board_x, board_y, board_size, board_size, GRID)
    display.draw_rect(board_x, board_y, board_size, board_size, FRAME_LINE)
    for y = 1, 4 do
        for x = 1, 4 do
            draw_empty_cell(x, y)
        end
    end
end

local function draw_board(skip_x, skip_y)
    for y = 1, 4 do
        for x = 1, 4 do
            if not (x == skip_x and y == skip_y) then
                local px, py = tile_xy(x, y)
                draw_tile_at(px, py, board[y][x])
            end
        end
    end
end

local function draw_overlay()
    if not won then return end
    local panel_w = math.floor(board_size * 0.76)
    local panel_h = 118
    local x = board_x + math.floor((board_size - panel_w) / 2)
    local y = board_y + math.floor((board_size - panel_h) / 2)
    display.fill_round_rect(x + 4, y + 5, panel_w, panel_h, 10, SHADOW)
    display.fill_round_rect(x, y, panel_w, panel_h, 10, rgb(86, 53, 29))
    display.draw_round_rect(x, y, panel_w, panel_h, 10, GREEN)
    display.draw_text_aligned(x, y + 15, panel_w, 34, "SOLVED!", {
        color = GREEN,
        font_size = 28,
        align = "center",
        valign = "middle",
        bg = rgb(21, 25, 32),
    })
    display.draw_text_aligned(x, y + 55, panel_w, 24, "moves " .. tostring(moves) .. "   " .. format_time(elapsed_seconds()), {
        color = TEXT,
        font_size = 16,
        align = "center",
        valign = "middle",
        bg = rgb(21, 25, 32),
    })
    display.draw_text_aligned(x, y + 82, panel_w, 22, "tap NEW to shuffle", {
        color = SUBTEXT,
        font_size = 14,
        align = "center",
        valign = "middle",
        bg = rgb(21, 25, 32),
    })
end

local function render()
    local t0 = now_ms()
    display.begin_frame({ clear = true, color = BG })
    draw_stage()
    draw_board(nil, nil)
    draw_overlay()
    display.present()
    display.end_frame()
    return now_ms() - t0
end

local function render_partial(change)
    local t0 = now_ms()
    display.begin_frame({ clear = false })
    if change and change.moved then
        draw_cell(change.from_x, change.from_y)
        draw_cell(change.to_x, change.to_y)
    end
    draw_info()
    if won then
        draw_overlay()
    end
    display.present()
    display.end_frame()
    return now_ms() - t0
end

local function render_partial_clock()
    local t0 = now_ms()
    display.begin_frame({ clear = false })
    draw_info()
    display.present()
    display.end_frame()
    return now_ms() - t0
end

local function move_tile(x, y)
    if won then
        request_sfx("block")
        return { blocked = true }
    end
    if not adjacent_to_empty(x, y) then
        request_sfx("block")
        return { blocked = true }
    end

    local value = board[y][x]
    local old_empty_x, old_empty_y = empty_x, empty_y
    board[y][x] = 0
    board[old_empty_y][old_empty_x] = value
    empty_x = x
    empty_y = y
    moves = moves + 1
    request_sfx("move")

    if is_solved() then
        won = true
        if best_moves == 0 or moves < best_moves then
            best_moves = moves
        end
        request_sfx("win")
    end

    return {
        moved = true,
        from_x = x,
        from_y = y,
        to_x = old_empty_x,
        to_y = old_empty_y,
    }
end

local function handle_touch()
    local polled, info = pcall(lcd_touch.poll, touch_handle)
    if not polled then
        print("[number_puzzle] ERROR: lcd_touch.poll failed: " .. tostring(info))
        return nil
    end

    if info.pressed then
        if not touch_down then
            touch_down = { x = info.x, y = info.y }
        end
        return false
    elseif info.just_released then
        if not touch_down then
            return false
        end
        local dx = info.x - touch_down.x
        local dy = info.y - touch_down.y
        local released_x = info.x
        local released_y = info.y
        touch_down = nil
        local direction = direction_from_swipe(dx, dy)
        if direction then
            return tile_for_swipe(direction)
        end
        if math.abs(dx) > TAP_SLOP or math.abs(dy) > TAP_SLOP then
            return false
        end
        return tile_at_point(released_x, released_y) or false
    end

    return false
end

local init_t0 = now_ms()
new_game()
local init_render_ms = render()
print(string.format("[number_puzzle] ready screen=%dx%d stage=%dx%d shuffle_steps=%d run_ms=%d",
    width, height, stage, stage, SHUFFLE_STEPS, RUN_TIME_MS))
print("[number_puzzle] tap a tile adjacent to the blank space, or swipe to move a tile into the blank")
log_perf("startup", string.format("new_game=%dms render=%dms", now_ms() - init_t0 - init_render_ms, init_render_ms))

local run_ok, run_err = xpcall(function()
    local last_clock_second = remaining_seconds()
    while now_ms() - run_start_ms < RUN_TIME_MS do
        local loop_t0 = now_ms()
        local sfx_attempted, sfx_ms = drain_sfx()
        local touch_t0 = now_ms()
        local action = handle_touch()
        local touch_ms = now_ms() - touch_t0
        if action == nil then break end
        if action then
            local action_name = "move"
            local force_full_render = false
            local change = nil
            local move_t0 = now_ms()
            if action == "new" then
                new_game()
                action_name = "new"
                force_full_render = true
            elseif action.blocked then
                request_sfx("block")
                action_name = "blocked"
            else
                change = move_tile(action.x, action.y)
                if change and change.blocked then
                    action_name = "blocked"
                end
            end
            local move_ms = now_ms() - move_t0
            local render_ms = force_full_render and render() or render_partial(change)
            last_clock_second = remaining_seconds()
            log_perf("action", string.format(
                "kind=%s touch=%dms move=%dms render=%dms sfx_before=%s/%dms total=%dms",
                action_name,
                touch_ms,
                move_ms,
                render_ms,
                tostring(sfx_attempted),
                sfx_ms,
                now_ms() - loop_t0
            ))
        else
            local clock_second = remaining_seconds()
            if clock_second ~= last_clock_second then
                last_clock_second = clock_second
                local render_ms = render_partial_clock()
                log_perf("clock", string.format("touch=%dms render=%dms total=%dms", touch_ms, render_ms, now_ms() - loop_t0))
            end
        end
        delay.delay_ms(FRAME_MS)
    end
end, debug.traceback)

cleanup()
if not run_ok then
    print("[number_puzzle] ERROR: " .. tostring(run_err))
end
print("[number_puzzle] done")
