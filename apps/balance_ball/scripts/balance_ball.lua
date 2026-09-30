-- balance_ball.lua
-- IMU tilt-controlled balance ball game using the board sensor.
-- Tilt the board to roll the ball. A target circle appears at a random position.
-- Hold the ball inside the target for HOLD_FRAMES consecutive frames to score a point.
-- Each score makes the next target smaller.

local system = require("system")
local display = require("display")
local delay = require("delay")
local imu = require("imu")

local function main()
    -- ============ Parameter Parsing ============
    local a = type(args) == "table" and args or {}
    local function num_arg(k, d, lo, hi)
        local v = a[k]
        if v == nil then return d end
        assert(type(v) == "number" and v == v and v >= lo and v <= hi, "invalid args." .. k)
        return v
    end
    local function bool_arg(k, d)
        local v = a[k]; if type(v) == "boolean" then return v end; return d
    end

    local RUN_TIME_MS  = math.floor(num_arg("run_ms", 0, 0, 86400000))
    local FRAME_MS     = math.max(15, math.floor(num_arg("frame_ms", 22, 15, 1000)))
    local LSB_PER_G   = num_arg("lsb_per_g", 2048.0, 1, 65536)

    -- axis mapping
    local INV_X   = bool_arg("invert_x", false)
    local INV_Y   = bool_arg("invert_y", true)
    local SWAP_XY = bool_arg("swap_xy", false)

    -- ============ Game Parameters ============
    local BALL_R      = math.floor(num_arg("ball_r", 8, 2, 32))
    local TARGET_R0   = math.floor(num_arg("target_r", 16, 7, 64))
    local TARGET_R_MIN = 7
    local ACCEL_K     = num_arg("accel_k", 1.8, 0.01, 20)
    local FRICTION    = num_arg("friction", 0.985, 0, 1)
    local BOUNCE      = num_arg("bounce", 0.5, 0, 1)
    local MAX_SPEED   = num_arg("max_speed", 6.5, 0.1, 32)
    local HOLD_FRAMES = math.floor(num_arg("hold_frames", 14, 1, 1000))

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

    -- The screen scope releases display ownership on return, failure, or cancellation.
    local screen <close> = display.open()
    local info = screen:info()
    local W, H = info.width, info.height
    local AX0, AY0, AX1, AY1 = 4, 38, W - 4, H - 24
    assert(AX1 - AX0 > 2 * (TARGET_R0 + BALL_R + 6) and AY1 - AY0 > 2 * (TARGET_R0 + BALL_R + 6), "screen too small for configured radii")

    local imu_dev = imu.new()
    -- IMU userdata has close() but no __close metamethod.
    local imu_guard <close> = setmetatable({}, { __close = function()
        local ok, err = pcall(imu_dev.close, imu_dev)
        if not ok then print("[ball] ERROR: IMU close failed: " .. tostring(err)) end
    end })

    local diag_count = 3
    local function read_accel_g()
        local data = imu_dev:read()
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
    math.randomseed(system.millis())

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
    local in_target = false
    local score = 0
    local paused = false
    local touch_id, touch_control, press_x, press_y, moved
    local trail = {}
    local TRAIL_LEN = 5

    -- score flash animation
    local score_flash = 0  -- remaining flash frames

    local function clamp(v, lo, hi)
        if v < lo then return lo end; if v > hi then return hi end; return v
    end

    -- ============ Rendering ============
    local function draw_arena_border()
        screen:stroke_rect(AX0 + 1, AY0 + 1, AX1 - AX0 - 2, AY1 - AY0 - 2, FRAME_C)
        screen:stroke_rect(AX0, AY0, AX1 - AX0, AY1 - AY0, FRAME_C)
    end

    local function draw_score()
        local text = string.format("%03d", score)
        if W >= 280 then text = "SCORE  " .. text end
        screen:text(10, 11, text, { color = score_flash > 0 and TARGET_HOT or TEXT_C, font_size = W >= 300 and 20 or 16 })
        for _, x in ipairs({ W - 80, W - 40 }) do screen:fill_round_rect(x, 4, 32, 32, 9, HOLD_BAR_BG) end
        screen:line(W - 29, 15, W - 19, 25, TEXT_C)
        screen:line(W - 19, 15, W - 29, 25, TEXT_C)
        if paused then screen:fill_triangle(W - 68, 13, W - 68, 27, W - 57, 20, TEXT_C)
        else
            screen:fill_rect(W - 70, 13, 4, 14, TEXT_C)
            screen:fill_rect(W - 62, 13, 4, 14, TEXT_C)
        end
        local bar_w = W - 16
        screen:fill_round_rect(8, H - 16, bar_w, 8, 4, HOLD_BAR_BG)
        if target_hold > 0 then screen:fill_rect(8, H - 16, math.floor(bar_w * target_hold / HOLD_FRAMES), 8, HOLD_BAR_FG) end
        if paused then
            local bw = math.min(W - 24, 200)
            screen:fill_round_rect((W - bw) // 2, H // 2 - 24, bw, 48, 12, BG)
            local tw = screen:measure_text("PAUSED", { font_size = 20 })
            screen:text((W - tw) // 2, H // 2 - 10, "PAUSED", { color = TEXT_C, font_size = 20 })
        end
    end

    local function draw_target(t, hot)
        local col = hot and TARGET_HOT or TARGET_C
        local tx, ty = math.floor(t.x), math.floor(t.y)
        -- outer ring dashed effect: two concentric circles
        screen:stroke_circle(tx, ty, t.r, col)
        screen:stroke_circle(tx, ty, t.r - 2, col)
        -- crosshair
        local cross = t.r - 4
        screen:line(tx - cross, ty, tx + cross, ty, col)
        screen:line(tx, ty - cross, tx, ty + cross, col)
    end

    local function draw_trail()
        for i = 1, #trail do
            local p = trail[i]
            local r = math.max(1, BALL_R - 2 - (TRAIL_LEN - i))
            screen:fill_circle(math.floor(p.x), math.floor(p.y), r, TRAIL_C)
        end
    end

    local function draw_ball()
        local bx, by = math.floor(ball.x), math.floor(ball.y)
        -- shadow
        screen:fill_circle(bx + 1, by + 1, BALL_R, { r = 30, g = 50, b = 80 })
        -- ball body
        screen:fill_circle(bx, by, BALL_R, BALL_C)
        screen:stroke_circle(bx, by, BALL_R, BALL_RIM)
        -- highlight
        screen:fill_circle(bx - 2, by - 2, math.max(1, BALL_R // 3),
            { r = 255, g = 255, b = 255 })
    end

    -- ============ Main Loop ============
    print("[ball] ready; tilt to score, tap EXIT to return")
    local started = system.millis()
    while RUN_TIME_MS == 0 or system.millis() - started < RUN_TIME_MS do
        if info.touch_available then
            local point
            for _, p in ipairs(screen:touch().points) do if not touch_id or p.id == touch_id then point = p; break end end
            if point then
                if not touch_id then
                    touch_id, press_x, press_y, moved = point.id, point.x, point.y, false
                    touch_control = point.y >= 4 and point.y < 36 and (point.x >= W - 40 and point.x < W - 8 and "exit" or (point.x >= W - 80 and point.x < W - 48 and "pause")) or nil
                end
                moved = moved or math.abs(point.x - press_x) > 8 or math.abs(point.y - press_y) > 8
            elseif touch_id then
                if not moved and touch_control == "exit" then break end
                if not moved and touch_control == "pause" then paused = not paused end
                touch_id, touch_control = nil, nil
            end
        end
        if not paused then
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
            in_target = (dx * dx + dy * dy) <= (target.r * target.r)

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

        end

        -- rendering
        screen:begin({ clear = BG })
        screen:fill_rect(AX0, AY0, AX1 - AX0, AY1 - AY0, ARENA_BG)
        draw_arena_border()
        draw_target(target, in_target)
        draw_trail()
        draw_ball()
        draw_score()

        screen:present()
        delay.delay_ms(FRAME_MS)
    end

    print(string.format("[ball] done; score=%d", score))
end

local ok, err = xpcall(main, debug.traceback)
if not ok then
    print("[ball] ERROR: " .. tostring(err))
    error(err, 0)
end
