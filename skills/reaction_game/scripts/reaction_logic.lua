-- reaction_logic.lua: pure Rapid Tap / reaction-time rules (no LVGL).
-- Ported from factory_demo ui_app.c (rapid_tap_* + RAPID_TAP_* constants).

local M = {}

M.MAX_ROUNDS   = 5
M.TIMER_MS     = 10
M.WAIT_MIN_MS  = 2000
M.WAIT_MAX_MS  = 5000
M.RESULT_MS    = 1500

M.STATE_STOPPED  = 0
M.STATE_WAITING  = 1
M.STATE_READY    = 2
M.STATE_RESULT   = 3
M.STATE_PAUSED   = 4
M.STATE_FINISHED = 5

M.COLOR_WAIT  = "#EED964"
M.COLOR_READY = "#65C873"
M.COLOR_OOPS  = "#EF8670"

function M.new()
    return {
        state = M.STATE_STOPPED,
        wait_target_ms = 0,
        wait_elapsed_ms = 0,
        ready_elapsed_ms = 0,
        round = 0,
        false_count = 0,
        best_ms = -1,
        last_reaction_ms = -1,
        was_false_start = false,
        title = "",
        subtitle = "",
        play_color = M.COLOR_WAIT,
        rng_state = 1,
    }
end

function M.set_seed(g, seed)
    seed = math.floor(tonumber(seed) or 1)
    if seed < 1 then seed = 1 end
    g.rng_state = seed % 2147483647
    if g.rng_state < 1 then g.rng_state = 1 end
end

-- lv_rand(lo, hi) inclusive, via a 31-bit LCG (test-deterministic).
function M.rand_int(g, lo, hi)
    local x = g.rng_state
    x = (x * 1103515245 + 12345) % 2147483648
    g.rng_state = x
    if hi < lo then lo, hi = hi, lo end
    return lo + (x % (hi - lo + 1))
end

function M.rate(ms)
    ms = math.floor(tonumber(ms) or 0)
    if ms < 0 then ms = 0 end
    if ms < 100 then
        return string.format("%dms", ms), "Lightning Fast"
    elseif ms < 300 then
        return string.format("%dms", ms), "Great Reaction"
    elseif ms < 600 then
        return string.format("%dms", ms), "Nice Try"
    end
    return "Wake Up", ""
end

function M.round_text(g)
    local r = tonumber(g.round) or 0
    return string.format("%d/%d", r, M.MAX_ROUNDS)
end

function M.best_text(g)
    local b = tonumber(g.best_ms)
    if b == nil or b < 0 then
        return "--"
    end
    return string.format("%dms", math.floor(b))
end

function M.false_text(g)
    return tostring(math.floor(tonumber(g.false_count) or 0))
end

function M.begin_round(g)
    if g.round == 0 or g.round > M.MAX_ROUNDS then
        g.round = 1
    end
    g.state = M.STATE_WAITING
    g.wait_target_ms = M.rand_int(g, M.WAIT_MIN_MS, M.WAIT_MAX_MS)
    g.wait_elapsed_ms = 0
    g.ready_elapsed_ms = 0
    g.last_reaction_ms = -1
    g.was_false_start = false
    g.title = "Wait"
    g.subtitle = "Tap when it turns green"
    g.play_color = M.COLOR_WAIT
end

function M.start(g)
    g.round = 1
    g.false_count = 0
    g.best_ms = -1
    g.last_reaction_ms = -1
    g.was_false_start = false
    M.begin_round(g)
end

function M.finish(g)
    g.state = M.STATE_FINISHED
    g.title = "Done"
    if g.best_ms == nil or g.best_ms < 0 then
        g.subtitle = "No valid reaction"
    else
        g.subtitle = string.format("Best %dms", math.floor(g.best_ms))
    end
end

function M.advance_round_or_finish(g)
    if g.round >= M.MAX_ROUNDS then
        M.finish(g)
        return
    end
    g.round = g.round + 1
    M.begin_round(g)
end

function M.show_result(g, reaction_ms)
    reaction_ms = math.floor(tonumber(reaction_ms) or 0)
    if reaction_ms < 0 then reaction_ms = 0 end
    g.last_reaction_ms = reaction_ms
    if g.best_ms < 0 or reaction_ms < g.best_ms then
        g.best_ms = reaction_ms
    end
    g.title, g.subtitle = M.rate(reaction_ms)
    g.state = M.STATE_RESULT
    g.wait_elapsed_ms = 0
    g.was_false_start = false
    -- C leaves the play-area green from READY.
    g.play_color = M.COLOR_READY
end

function M.false_start(g)
    g.false_count = g.false_count + 1
    g.state = M.STATE_RESULT
    g.wait_elapsed_ms = 0
    g.was_false_start = true
    g.last_reaction_ms = -1
    g.title = "Oops"
    g.subtitle = "The green is not ready"
    g.play_color = M.COLOR_OOPS
end

function M.update(g, dt)
    local st = g.state
    if st ~= M.STATE_WAITING and st ~= M.STATE_READY and st ~= M.STATE_RESULT then
        return
    end
    dt = math.floor(tonumber(dt) or 0)
    if dt < 0 then dt = 0 end
    if dt > 250 then dt = 250 end

    if st == M.STATE_WAITING then
        g.wait_elapsed_ms = g.wait_elapsed_ms + dt
        if g.wait_elapsed_ms >= g.wait_target_ms then
            g.state = M.STATE_READY
            g.ready_elapsed_ms = 0
            g.title = "Tap"
            g.subtitle = "Now"
            g.play_color = M.COLOR_READY
        end
    elseif st == M.STATE_READY then
        g.ready_elapsed_ms = g.ready_elapsed_ms + dt
    else
        g.wait_elapsed_ms = g.wait_elapsed_ms + dt
        if g.wait_elapsed_ms >= M.RESULT_MS then
            M.advance_round_or_finish(g)
        end
    end
end

-- Play-area tap. C ignores RESULT / FINISHED / STOPPED / PAUSED.
function M.tap(g)
    if g.state == M.STATE_WAITING then
        M.false_start(g)
        return true
    end
    if g.state == M.STATE_READY then
        M.show_result(g, g.ready_elapsed_ms)
        return true
    end
    return false
end

return M
