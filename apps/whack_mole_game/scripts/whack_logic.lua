-- whack_logic.lua: pure spawn/hit rules for 打地鼠 (no LVGL).
-- Ported from factory_demo ui_app.c (WHACK_* constants + timer/click).

local M = {}

M.HOLE_COUNT   = 9
M.GAME_MS      = 30000
M.TIMER_MS     = 50
M.SPAWN_MIN_MS = 500
M.SPAWN_MAX_MS = 1000
M.BOMB_PCT     = 30
M.MOLE_PTS     = 100
M.BOMB_PTS     = -200

M.STATE_IDLE     = 0
M.STATE_RUNNING  = 1
M.STATE_PAUSED   = 2
M.STATE_FINISHED = 3

-- Park-Miller modulus (2^31-1). State stays in 1 .. m-1.
local PM_A = 16807
local PM_M = 2147483647
local PM_Q = 127773
local PM_R = 2836
local PM_MAX = 2147483646

function M.new()
    return {
        state = M.STATE_IDLE,
        elapsed_ms = 0,
        spawn_elapsed_ms = 0,
        spawn_target_ms = 0,
        score = 0,
        combo = 0,
        misses = 0,
        active_index = -1,
        last_index = -1,
        active_is_bomb = false,
        rng_state = 1,
    }
end

function M.set_seed(g, seed)
    seed = math.floor(tonumber(seed) or 1)
    if seed < 1 then seed = 1 end
    if seed > PM_MAX then
        seed = seed % PM_MAX
        if seed < 1 then seed = 1 end
    end
    g.rng_state = seed
end

-- Park-Miller / Schrage: all muls stay inside the 2^53 mantissa.
-- Map to [lo, hi] with high bits (not x % n) so all holes are reachable.
function M.rand_int(g, lo, hi)
    local x = g.rng_state
    if x < 1 then x = 1 end
    if x > PM_MAX then x = PM_MAX end
    local hi_s = math.floor(x / PM_Q)
    local lo_s = x % PM_Q
    local t = PM_A * lo_s - PM_R * hi_s
    if t <= 0 then t = t + PM_M end
    g.rng_state = t
    if hi < lo then lo, hi = hi, lo end
    local n = hi - lo + 1
    local v = lo + math.floor(t / PM_M * n)
    if v > hi then v = hi end
    if v < lo then v = lo end
    return v
end

function M.remaining_s(g)
    local left = M.GAME_MS - (g.elapsed_ms or 0)
    if left < 0 then left = 0 end
    return math.floor(left / 1000)
end

function M.hole_kind(g, index)
    if g.active_index < 0 or index ~= g.active_index then
        return "empty"
    end
    if g.active_is_bomb then
        return "bomb"
    end
    return "mole"
end

function M.spawn(g)
    if g.state ~= M.STATE_RUNNING then
        return
    end
    g.active_index = -1
    local idx = 0
    if M.HOLE_COUNT <= 1 then
        idx = 0
    else
        repeat
            idx = M.rand_int(g, 0, M.HOLE_COUNT - 1)
        until idx ~= g.last_index
    end
    g.active_index = idx
    g.last_index = idx
    g.active_is_bomb = M.rand_int(g, 0, 99) < M.BOMB_PCT
    g.spawn_elapsed_ms = 0
    g.spawn_target_ms = M.rand_int(g, M.SPAWN_MIN_MS, M.SPAWN_MAX_MS)
end

function M.start(g)
    g.state = M.STATE_RUNNING
    g.elapsed_ms = 0
    g.spawn_elapsed_ms = 0
    g.spawn_target_ms = 0
    g.score = 0
    g.combo = 0
    g.misses = 0
    g.active_index = -1
    g.last_index = -1
    g.active_is_bomb = false
    M.spawn(g)
end

function M.finish(g)
    g.state = M.STATE_FINISHED
    g.elapsed_ms = M.GAME_MS
    g.active_index = -1
    g.active_is_bomb = false
end

function M.update(g, dt)
    if g.state ~= M.STATE_RUNNING then
        return
    end
    dt = math.floor(tonumber(dt) or 0)
    if dt < 0 then dt = 0 end
    if dt > 250 then dt = 250 end

    g.elapsed_ms = g.elapsed_ms + dt
    if g.elapsed_ms >= M.GAME_MS then
        M.finish(g)
        return
    end

    g.spawn_elapsed_ms = g.spawn_elapsed_ms + dt
    if g.spawn_elapsed_ms >= g.spawn_target_ms then
        -- timeout: the popped target escaped -> miss
        g.combo = 0
        g.misses = g.misses + 1
        M.spawn(g)
    end
end

-- Tap hole index (0-based). Empty hole is ignored (C). Active mole/bomb scores.
function M.hit(g, index)
    if g.state ~= M.STATE_RUNNING then
        return false
    end
    index = math.floor(tonumber(index) or -1)
    if index ~= g.active_index then
        return false
    end
    if g.active_is_bomb then
        g.score = g.score + M.BOMB_PTS
        g.combo = 0
    else
        g.score = g.score + M.MOLE_PTS
        g.combo = g.combo + 1
    end
    M.spawn(g)
    return true
end

return M
