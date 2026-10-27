-- Physics uses a fixed 360-unit playfield and 240 Hz collision steps.
local M = {}
local STEP, RADIUS, MAX_SPEED = 1 / 240, 6, 580
local MELODIES = { { 1, 2, 3 }, { 3, 1, 2, 3 }, { 2, 1, 3, 2, 3 } }
local function clamp(v, a, b) return math.max(a, math.min(b, v)) end

function M.new(best)
    return { x = 295, y = 205, vx = 0, vy = 0, time = 0, debt = 0, phase = "ready", lives = 3,
        score = 0, best = best or 0, combo = 0, last_hit = -10, hits = 0, melody = 1, progress = 0, energy = 0, fever_until = 0, events = {},
        left = 0, right = 0, flash = {}, bumpers = {
            { x = 125, y = 129, r = 19, note = 0 },
            { x = 235, y = 129, r = 19, note = 4 },
            { x = 180, y = 193, r = 22, note = 7 },
        }, targets = { { x = 129, y = 77, r = 10, note = 9 }, { x = 180, y = 65, r = 10, note = 12 }, { x = 231, y = 77, r = 10, note = 14 } } }
end

function M.sequence(s) return MELODIES[s.melody] end
function M.fever(s) return s.time < s.fever_until end

local function emit(s, kind, note, x, y)
    s.events[#s.events + 1] = { kind = kind, note = note or 0, x = x or s.x, y = y or s.y }
end

function M.launch(s)
    if s.phase ~= "ready" then return false end
    s.x, s.y, s.vx, s.vy = 295, 205, -240, -350
    s.phase, s.save_until, s.debt = "playing", s.time + 4, 0
    emit(s, "launch")
    return true
end

function M.flipper(s, side)
    local left = side == "left"
    local amount = left and s.left or s.right
    local angle = (24 - 52 * amount) * math.pi / 180
    local x = left and 98 or 262
    return x, 276, x + (left and 1 or -1) * 64 * math.cos(angle), 276 + 64 * math.sin(angle)
end

local function hit(s, item, key, bumper)
    if s.time - (s.flash[key] or -10) < 0.09 then return end
    s.flash[key] = s.time
    s.combo = s.time - s.last_hit < 2.5 and s.combo + 1 or 1
    s.last_hit, s.hits = s.time, s.hits + 1
    local multiplier = math.min(5, 1 + s.combo // 4)
    local fever = M.fever(s)
    s.score = s.score + 100 * multiplier * (fever and 2 or 1)
    local kind = fever and "fever_note" or "note"
    if not fever and bumper == M.sequence(s)[s.progress + 1] then
        s.progress = s.progress + 1
        kind = "melody"
        if s.progress == #M.sequence(s) then
            s.progress, s.energy = 0, s.energy + 1
            s.melody = s.melody % #MELODIES + 1
            s.score, s.flash.bonus = s.score + 1000, s.time
            kind = "bonus"
            if s.energy == 3 then
                s.energy, s.fever_until = 0, s.time + 15
                kind = "fever"
            end
        end
    end
    s.best = math.max(s.best, s.score)
    emit(s, kind, item.note, item.x, item.y)
end

local function circle(s, item, key, bumper)
    local dx, dy = s.x - item.x, s.y - item.y
    local radius = item.r + RADIUS
    local distance = math.sqrt(dx * dx + dy * dy)
    if distance >= radius then return end
    local nx, ny = 0, -1
    if distance > 0.0001 then nx, ny = dx / distance, dy / distance end
    s.x, s.y = item.x + nx * (radius + 0.1), item.y + ny * (radius + 0.1)
    local speed = s.vx * nx + s.vy * ny
    if speed < 0 then
        s.vx, s.vy = s.vx - (1.85 * speed - 65) * nx, s.vy - (1.85 * speed - 65) * ny
        hit(s, item, key, bumper)
    end
end

local function segment(s, ax, ay, bx, by, thickness, kick)
    local dx, dy = bx - ax, by - ay
    local u = clamp(((s.x - ax) * dx + (s.y - ay) * dy) / (dx * dx + dy * dy), 0, 1)
    local px, py = ax + u * dx, ay + u * dy
    local nx, ny = s.x - px, s.y - py
    local d = math.sqrt(nx * nx + ny * ny)
    local radius = RADIUS + thickness
    if d >= radius then return end
    if d < 0.0001 then nx, ny = 0, -1 else nx, ny = nx / d, ny / d end
    s.x, s.y = px + nx * (radius + 0.1), py + ny * (radius + 0.1)
    local speed = s.vx * nx + s.vy * ny
    if speed < 0 then
        s.vx, s.vy = s.vx - 1.8 * speed * nx, s.vy - 1.8 * speed * ny
    end
    if kick and ny < -0.2 and s.time - (s.last_flip or -10) > 0.10 then
        s.vx, s.vy = kick * (120 + 130 * u), -420 - 90 * u
        s.last_flip = s.time
        emit(s, "flip")
    end
end

function M.update(s, dt, left, right)
    s.events = {}
    -- Bound catch-up work after a suspended frame; never integrate a large jump.
    s.debt = s.debt + clamp(dt, 0, 0.1)
    while s.debt >= STEP do
        s.debt, s.time = s.debt - STEP, s.time + STEP
        s.left = clamp(s.left + (left and 14 or -10) * STEP, 0, 1)
        s.right = clamp(s.right + (right and 14 or -10) * STEP, 0, 1)
        if s.time - s.last_hit > 2.5 then s.combo = 0 end
        if s.phase == "lost" and s.time >= s.next_ball then
            s.phase = s.lives > 0 and "ready" or "over"
            s.x, s.y = 295, 205
        end
        if s.phase == "playing" then
            s.vy = s.vy + 290 * STEP
            local speed = math.sqrt(s.vx * s.vx + s.vy * s.vy)
            if speed > MAX_SPEED then s.vx, s.vy = s.vx * MAX_SPEED / speed, s.vy * MAX_SPEED / speed end
            s.x, s.y = s.x + s.vx * STEP, s.y + s.vy * STEP
            if s.x < 36 then s.x, s.vx = 36, math.abs(s.vx) * 0.92 end
            if s.x > 324 then s.x, s.vx = 324, -math.abs(s.vx) * 0.92 end
            if s.y < 53 then s.y, s.vy = 53, math.abs(s.vy) * 0.92 end
            segment(s, 90, 49, 30, 125, 1)
            segment(s, 270, 49, 330, 125, 1)
            for i, item in ipairs(s.bumpers) do circle(s, item, i, i) end
            for i, item in ipairs(s.targets) do circle(s, item, i + 3) end
            segment(s, 30, 225, 94, 274, 3)
            segment(s, 330, 225, 266, 274, 3)
            for _, side in ipairs({ "left", "right" }) do
                local ax, ay, bx, by = M.flipper(s, side)
                local active = side == "left" and left or side == "right" and right
                segment(s, ax, ay, bx, by, 5, active and (side == "left" and 1 or -1) or nil)
            end
            if s.y > 312 then
                s.vx, s.vy, s.combo = 0, 0, 0
                if s.time < s.save_until then
                    s.phase = "ready"
                    M.launch(s)
                    s.save_until = 0
                    emit(s, "save")
                else
                    s.lives, s.phase, s.next_ball = s.lives - 1, "lost", s.time + 0.8
                    s.fever_until = 0
                    emit(s, "lost")
                end
            end
        end
    end
    return s.events
end

return M
