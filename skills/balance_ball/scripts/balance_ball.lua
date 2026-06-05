-- balance_ball.lua
-- IMU tilt-controlled balance ball game for AnyBoard (ESP32-S3 + ST7789 + BMI270).
-- Tilt the board to roll the ball. A target circle appears at a random position.
-- Hold the ball inside the target for HOLD_FRAMES consecutive frames to score a point.
-- Each score makes the next target smaller.

local bm = require("board_manager")
local display = require("display")
local delay = require("delay")
local imu = require("imu")

-- ============ Parameter Parsing ============
local a = type(args) == "table" and args or {}
local function num_arg(k, d)
    local v = a[k]; if type(v) == "number" then return v end; return d
end
local function bool_arg(k, d)
    local v = a[k]; if type(v) == "boolean" then return v end; return d
end

local RUN_TIME_MS  = math.floor(num_arg("run_ms", 55000))
local FRAME_MS     = math.max(15, math.floor(num_arg("frame_ms", 22)))
local LSB_PER_G   = num_arg("lsb_per_g", 2048.0)

-- axis mapping
local INV_X   = bool_arg("invert_x", false)
local INV_Y   = bool_arg("invert_y", true)
local SWAP_XY = bool_arg("swap_xy", false)

-- ============ Game Parameters ============
local BALL_R      = math.floor(num_arg("ball_r", 8))
local TARGET_R0   = math.floor(num_arg("target_r", 16))
local TARGET_R_MIN = 7
local ACCEL_K     = num_arg("accel_k", 1.8)
local FRICTION    = num_arg("friction", 0.985)
local BOUNCE      = num_arg("bounce", 0.5)
local MAX_SPEED   = num_arg("max_speed", 6.5)
local HOLD_FRAMES = math.floor(num_arg("hold_frames", 14))

-- ============ Colors ============
local BG        = { r = 8,  g = 8,  b = 20  }
local ARENA_BG  = { r = 12, g = 18, b = 35  }
local FRAME_C   = { r = 60, g = 180, b = 220 }
local BALL_C    = { r = 245, g = 245, b = 235 }
local BALL_RIM  = { r = 60, g = 130, b = 200 }
local TARGET_C  = { r = 50, g = 200, b = 180 }
local TARGET_HOT = { r = 80, g = 255, b = 200 }
local TEXT_C    = { r = 200, g = 230, b = 250 }
local TRAIL_C   = { r = 100, g = 180, b = 230 }
local HOLD_BAR_BG = { r = 20, g = 30, b = 50 }
local HOLD_BAR_FG = { r = 80, g = 255, b = 180 }

-- ============ Display Initialization ============
local panel_handle, io_handle, w0, h0, panel_if = bm.get_display_lcd_params("display_lcd")
if not panel_handle then
    print("[ball] get_display_lcd_params failed: " .. tostring(io_handle))
    return
end
local ok, err = pcall(display.init, panel_handle, io_handle, w0, h0, panel_if)
if not ok then
    print("[ball] display init failed: " .. tostring(err))
    return
end
local owned = true

-- use full screen
local W, H = display.width, display.height
local arena_margin = 4
local AX0 = arena_margin
local AY0 = arena_margin + 16  -- leave space at top for score bar
local AX1 = W - arena_margin
local AY1 = H - arena_margin

print(string.format("[ball] screen %dx%d, arena %d,%d - %d,%d", W, H, AX0, AY0, AX1, AY1))

-- ============ IMU ============
local imu_ok, imu_dev = pcall(imu.new)
if not imu_ok or not imu_dev then
    print("[ball] imu.new failed: " .. tostring(imu_dev))
    print("[ball] Is CONFIG_LUA_MODULE_IMU_CHIP_BMI270 enabled in firmware?")
    pcall(display.deinit)
    return
end

local function cleanup()
    if imu_dev then pcall(function() imu_dev:close() end); imu_dev = nil end
    if owned then
        pcall(display.clear_clip_rect)
        pcall(display.end_frame)
        pcall(display.deinit)
        owned = false
    end
end

local diag_count = 3
local function read_accel_g()
    local ok2, data = pcall(function() return imu_dev:read() end)
    if not ok2 or type(data) ~= "table" or type(data.accel) ~= "table" then
        return 0, 0, 0
    end
    local ax = (data.accel.x or 0) / LSB_PER_G
    local ay = (data.accel.y or 0) / LSB_PER_G
    local az = (data.accel.z or 0) / LSB_PER_G
    if diag_count > 0 then
        diag_count = diag_count - 1
        print(string.format("[ball][diag] raw=(%d,%d,%d) g=(%.2f,%.2f,%.2f)",
            data.accel.x or 0, data.accel.y or 0, data.accel.z or 0,
            ax, ay, az))
    end
    if SWAP_XY then ax, ay = ay, ax end
    if INV_X then ax = -ax end
    if INV_Y then ay = -ay end
    return ax, ay, az
end

-- ============ Game State ============
math.randomseed(os.time())

local ball = {
    x = (AX0 + AX1) / 2,
    y = (AY0 + AY1) / 2,
    vx = 0,
    vy = 0,
}

local function spawn_target(r)
    local pad = r + BALL_R + 6
    local tx = AX0 + pad
    local ty = AY0 + pad
    local tw = (AX1 - pad) - (AX0 + pad)
    local th = (AY1 - pad) - (AY0 + pad)
    if tw < 0 then tw = 0 end
    if th < 0 then th = 0 end
    return {
        x = tx + math.random() * tw,
        y = ty + math.random() * th,
        r = r,
    }
end

local target = spawn_target(TARGET_R0)
local target_hold = 0
local score = 0
local trail = {}
local TRAIL_LEN = 5

-- score flash animation
local score_flash = 0  -- remaining flash frames

local function clamp(v, lo, hi)
    if v < lo then return lo end; if v > hi then return hi end; return v
end

-- ============ Rendering ============
local function draw_arena_border()
    display.draw_rect(AX0 + 1, AY0 + 1, AX1 - AX0 - 2, AY1 - AY0 - 2, FRAME_C)
    display.draw_rect(AX0, AY0, AX1 - AX0, AY1 - AY0, FRAME_C)
end

local function draw_score()
    local text = string.format("SCORE  %d", score)
    if score_flash > 0 then
        text = text .. "  +1"
    end
    local col = score_flash > 0 and TARGET_HOT or TEXT_C
    display.draw_text(AX0 + 4, 2,
        text,
        { color = col, font_size = 12, bg = BG })
    -- progress bar background
    local bar_w = AX1 - AX0
    local bar_h = 12
    local bar_y = 2
    display.fill_rect(AX1 - 50, bar_y, 50, bar_h, HOLD_BAR_BG)
    if target_hold > 0 then
        local fw = math.floor(50 * target_hold / HOLD_FRAMES)
        display.fill_rect(AX1 - fw, bar_y, fw, bar_h, HOLD_BAR_FG)
    end
end

local function draw_target(t, hot)
    local col = hot and TARGET_HOT or TARGET_C
    local tx, ty = math.floor(t.x), math.floor(t.y)
    -- outer ring dashed effect: two concentric circles
    display.draw_circle(tx, ty, t.r, col)
    display.draw_circle(tx, ty, t.r - 2, col)
    -- crosshair
    local cross = t.r - 4
    display.draw_line(tx - cross, ty, tx + cross, ty, col)
    display.draw_line(tx, ty - cross, tx, ty + cross, col)
end

local function draw_trail()
    for i = 1, #trail do
        local p = trail[i]
        local r = math.max(1, BALL_R - 2 - (TRAIL_LEN - i))
        display.fill_circle(math.floor(p.x), math.floor(p.y), r, TRAIL_C)
    end
end

local function draw_ball()
    local bx, by = math.floor(ball.x), math.floor(ball.y)
    -- shadow
    display.fill_circle(bx + 1, by + 1, BALL_R, { r = 30, g = 50, b = 80 })
    -- ball body
    display.fill_circle(bx, by, BALL_R, BALL_C)
    display.draw_circle(bx, by, BALL_R, BALL_RIM)
    -- highlight
    display.fill_circle(bx - 2, by - 2, math.max(1, BALL_R // 3),
        { r = 255, g = 255, b = 255 })
end

-- ============ Main Loop ============
display.begin_frame({ clear = true, color = BG })
pcall(display.set_clip_rect, 0, 0, W, H)

print("[ball] ========================================")
print("[ball] Balance Ball game started!")
print("[ball] Tilt the board to roll the ball into the target circle")
print("[ball] Hold inside the circle to score")
print("[ball] ========================================")

local frames = RUN_TIME_MS // FRAME_MS
for f = 1, frames do
    local ax, ay, _ = read_accel_g()

    -- trail recording
    trail[#trail + 1] = { x = ball.x, y = ball.y }
    if #trail > TRAIL_LEN then table.remove(trail, 1) end

    -- physics update
    ball.vx = ball.vx * FRICTION + ax * ACCEL_K
    ball.vy = ball.vy * FRICTION + ay * ACCEL_K
    ball.vx = clamp(ball.vx, -MAX_SPEED, MAX_SPEED)
    ball.vy = clamp(ball.vy, -MAX_SPEED, MAX_SPEED)
    ball.x = ball.x + ball.vx
    ball.y = ball.y + ball.vy

    -- wall collision
    if ball.x - BALL_R < AX0 then
        ball.x = AX0 + BALL_R
        ball.vx = -ball.vx * BOUNCE
    end
    if ball.x + BALL_R > AX1 then
        ball.x = AX1 - BALL_R
        ball.vx = -ball.vx * BOUNCE
    end
    if ball.y - BALL_R < AY0 then
        ball.y = AY0 + BALL_R
        ball.vy = -ball.vy * BOUNCE
    end
    if ball.y + BALL_R > AY1 then
        ball.y = AY1 - BALL_R
        ball.vy = -ball.vy * BOUNCE
    end

    -- target detection
    local dx = ball.x - target.x
    local dy = ball.y - target.y
    local in_target = (dx * dx + dy * dy) <= (target.r * target.r)

    if in_target then
        target_hold = target_hold + 1
        if target_hold >= HOLD_FRAMES then
            score = score + 1
            score_flash = 15
            target_hold = 0
            local new_r = math.max(TARGET_R_MIN, TARGET_R0 - score)
            target = spawn_target(new_r)
            print(string.format("[ball] +1 SCORE! total=%d  next_target_r=%d", score, new_r))
        end
    else
        if target_hold > 0 then
            target_hold = math.max(0, target_hold - 2)
        end
    end

    if score_flash > 0 then score_flash = score_flash - 1 end

    -- rendering
    display.fill_rect(0, 0, W, H, BG)
    display.fill_rect(AX0, AY0, AX1 - AX0, AY1 - AY0, ARENA_BG)
    draw_arena_border()
    draw_target(target, in_target)
    draw_trail()
    draw_ball()
    draw_score()

    if f % 60 == 0 then
        print(string.format("[ball] g=(%+5.2f,%+5.2f)  score=%d  hold=%d/%d",
            ax, ay, score, target_hold, HOLD_FRAMES))
    end

    display.present()
    delay.delay_ms(FRAME_MS)
end

cleanup()
print("[ball] ========================================")
print(string.format("[ball] Game over! Final score: %d", score))
print("[ball] ========================================")
