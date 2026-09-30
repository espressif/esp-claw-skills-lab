-- Host contract tests: hardware modules are strict, isolated test doubles.
local root = arg[1] or "."
local cases = 0

local function run(id, options)
    options = options or {}
    local state = { now = 0, frames = 0, active = false, screen_open = false, imu_open = false, audio_open = false, button_open = false, requests = 0, values = {}, logs = {}, texts = {} }
    local width, height = options.width or 320, options.height or 240
    local function integer(v) assert(math.type(v) == "integer", "API requires integer, got " .. tostring(v)) end
    local function draw(...)
        assert(state.active, "drawing outside a frame")
        if options.draw_error then error("injected draw failure") end
        local values = { ... }
        for i = 1, #values - 1 do integer(values[i]) end
    end
    local screen = {}
    function screen:info() return { width = width, height = height, touch_available = not options.no_touch } end
    function screen:close() state.screen_open, state.active = false, false end
    function screen:begin(opts)
        assert(state.screen_open and not state.active, "unbalanced begin/present")
        assert(opts == nil or opts.clear ~= true, "clear must be a color")
        state.active = true
    end
    function screen:present()
        assert(state.active, "present without begin")
        state.active = false
        state.frames = state.frames + 1
        return true
    end
    for _, method in ipairs({ "fill_rect", "stroke_rect", "line", "fill_circle", "stroke_circle", "fill_round_rect", "stroke_round_rect", "fill_triangle" }) do
        screen[method] = function(_, ...) draw(...) end
    end
    function screen:arc(x, y, r, first, last, color)
        draw(x, y, r, color)
        assert(type(first) == "number" and type(last) == "number")
    end
    function screen:measure_text(text, opts)
        local size = opts and opts.font_size or 24
        assert(size >= 8 and size <= 64, "builtin font size out of range")
        return #text * (size // 2), size
    end
    function screen:text(x, y, text, opts)
        draw(x, y, opts or {})
        assert(type(text) == "string")
        if options.capture_text then state.texts[#state.texts + 1] = text end
        if options.text_bounds then
            local tw, th = self:measure_text(text, opts)
            assert(x >= 0 and y >= 0 and x + tw <= width and y + th <= height, "text exceeds screen: " .. text)
        end
        if id == "codex_usage_dashboard" and text:match("^%d+%%$") then
            local value = tonumber(text:match("^(%d+)"))
            if #state.values < 2 then table.insert(state.values, value) end
        end
    end
    function screen:save() assert(state.active) end
    function screen:restore() assert(state.active) end
    function screen:translate(x, y) draw(x, y, {}) end
    function screen:touch()
        assert(not options.no_touch)
        if options.touch then return { points = options.touch(state) } end
        if state.now >= 100 then return { points = {} } end
        if state.frames >= 2 or state.now >= 50 then return { points = { { id = 1, x = width - 20, y = 12 } } } end
        return { points = {} }
    end
    setmetatable(screen, { __close = screen.close })
    local display = {
        open = function(...)
            assert(select('#', ...) == 0, "open must not receive legacy handles")
            if options.display_error then error("injected display failure") end
            assert(not state.screen_open)
            state.screen_open = true
            return screen
        end,
        color = function(r, g, b) integer(r); integer(g); integer(b); return 0xff000000 | r << 16 | g << 8 | b end,
    }
    local function tick(ms)
        integer(ms)
        assert(ms > 0)
        if options.observe then
            local values = {}
            for i = 1, 100 do
                local name, value = debug.getlocal(2, i)
                if not name then break end
                values[name] = value
            end
            options.observe(state, values)
        end
        state.now = state.now + ms
        assert(state.now < (options.max_ms or 10000), "App did not terminate")
        if options.cancel then error("injected cancellation") end
    end
    local imu = { new = function()
        if options.imu_error then error("injected IMU open failure") end
        state.imu_open = true
        return {
            read = function()
                if options.read_error then error("injected IMU read failure") end
                return { accel = { x = 120, y = -120, z = 2048 } }
            end,
            close = function() state.imu_open = false end,
        }
    end }
    local audio = { open_output = function(...)
        assert(select('#', ...) == 0, "obsolete audio open options")
        if options.no_audio then return nil, "audio unavailable" end
        state.audio_open = true
        local rate, channels, bits = options.rate or 48000, options.channels or 2, options.bits or 16
        return {
            info = function() return { sample_rate = rate, channels = channels, bits = bits } end,
            set_volume = function(_, volume) assert(volume == 90); return true end,
            write = function(_, pcm)
                local frame_bytes = channels * (bits // 8)
                assert(#pcm % frame_bytes == 0, "misaligned PCM")
                local expected = math.max(math.ceil(4000 / frame_bytes) * frame_bytes, math.floor(rate * 120 / 1000) * frame_bytes)
                assert(#pcm == expected, "PCM does not match device format")
                return #pcm
            end,
            close = function() state.audio_open = false; return true end,
        }
    end }
    local button = {
        new = function() state.button_open = true; return {} end,
        get_key_level = function() return 1 end,
        off = function() return true end,
        close = function() state.button_open = false; return true end,
    }
    local modules = {
        display = display, delay = { delay_ms = tick }, imu = imu, audio = audio, button = button,
        system = { millis = function() return state.now end, date = options.date or os.date },
        capability = { call = function(name, payload, opts)
            assert(name == "http_request" and payload.method == "GET" and opts.max_output_bytes == 8192)
            state.requests = state.requests + 1
            if options.http_error then return false, nil, "injected HTTP failure" end
            return true, type(options.response) == "function" and options.response(state.requests) or options.response or "HTTP 200\n{}", nil
        end },
        json = { decode = function(body)
            assert(body == "{}", "unexpected response body")
            if options.json_error then error("injected invalid JSON") end
            return options.data or { five_h_pct = 72, weekly_pct = 85, weekly_reset = "3d 4h" }
        end },
    }
    local env = setmetatable({ args = options.args or { run_ms = 100, run_time_ms = 99 } }, { __index = _G })
    env._G = env
    env.require = function(name) assert(modules[name], "unknown module: " .. name); return modules[name] end
    env.print = function(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        state.logs[#state.logs + 1] = table.concat(parts, " ")
    end
    local chunk = assert(loadfile(root .. "/apps/" .. id .. "/scripts/" .. id .. ".lua", "t", env))
    local ok, err = pcall(chunk)
    local logged_error = table.concat(state.logs, "\n"):find("ERROR:", 1, true)
    if options.expect_error then assert(not ok or logged_error, "expected failure: " .. id)
    else assert(ok and not logged_error, tostring(err) .. "\n" .. table.concat(state.logs, "\n")) end
    assert(not state.screen_open and not state.imu_open and not state.audio_open and not state.button_open, "resource leak: " .. id)
    if options.requests then assert(state.requests == options.requests, "unexpected request count") end
    if options.values then assert(table.concat(state.values, ",") == options.values, "unexpected quota values") end
    cases = cases + 1
    return state
end

for _, id in ipairs({ "balance_ball", "clock_dial_demo", "dino", "flappybird", "lcd_touch_paint" }) do
    run(id)
    run(id, { draw_error = true, expect_error = true })
end
run("balance_ball", { imu_error = true, expect_error = true })
run("balance_ball", { read_error = true, expect_error = true })
run("balance_ball", { cancel = true, expect_error = true })
run("balance_ball", { args = { lsb_per_g = 0 }, expect_error = true })
run("clock_dial_demo", { width = 160, height = 160 })
run("flappybird", { bits = 32, channels = 2, rate = 44100 })
run("flappybird", { no_audio = true })
run("flappybird", { bits = 24 })
run("dino", { no_touch = true, expect_error = true })
run("dino", { no_touch = true, args = { input_mode = "button", button_gpio = 0, run_ms = 100 } })
run("flappybird", { no_touch = true })
run("codex_usage_dashboard", { requests = 0 })
run("codex_usage_dashboard", { args = { url = "http://localhost/data.json" }, requests = 1, values = "72,85" })
run("codex_usage_dashboard", { args = { url = "http://localhost/data.json" }, data = { usage = { five_h_pct = 0, weekly_pct = 100 } }, values = "0,100" })
for _, extra in ipairs({ { http_error = true }, { response = "HTTP 500\n{}" }, { response = "HTTP 200 (body truncated)\n{}" }, { json_error = true }, { data = { weekly_pct = 12 } }, { data = { five_h_pct = -1, weekly_pct = 50 } } }) do
    extra.args, extra.requests, extra.values, extra.expect_error = { url = "http://localhost/data.json" }, 1, "", true
    run("codex_usage_dashboard", extra)
end
run("codex_usage_dashboard", { draw_error = true, expect_error = true })
run("codex_usage_dashboard", { cancel = true, expect_error = true })
-- Drive real press/release cycles and inspect state without production test hooks.
local step, paused = 0, nil
local events = { [1] = {280,462}, [3] = {500,335}, [6] = {500,335}, [9] = {500,335}, [12] = {700,335}, [14] = {750,12} }
run("clock_dial_demo", {
    width = 800, height = 480, max_ms = 2000000,
    date = function() return step < 8 and "23595933009" or "00000140110" end,
    touch = function()
        local p = events[step]
        return p and {{id=1, x=p[1], y=p[2]}} or {}
    end,
    observe = function(state, v)
        if step == 2 then assert(v.mode == "focus") end
        if step == 4 then assert(v.phase == "running") end
        if step == 7 then assert(v.phase == "paused"); paused = v.remaining end
        if step == 8 then assert(v.remaining == paused and v.date == "01 / OCT") end
        if step == 10 then assert(v.phase == "running"); state.now = state.now + 1500000 end
        if step == 11 then assert(v.phase == "done" and v.remaining == 0) end
        if step == 13 then assert(v.phase == "ready" and v.remaining == 1500000) end
        step = step + 1
    end,
})
assert(step == 15, "Clock interaction sequence incomplete")
local ring_step = 0
local ring_events = { [1]={280,462}, [3]={236,95}, [4]={386,245}, [6]={500,335}, [8]={236,95}, [9]={86,245}, [11]={700,28}, [14]={750,12} }
run("clock_dial_demo", {
    width=800, height=480,
    touch=function()
        local p=ring_events[ring_step]
        return p and {{id=1,x=p[1],y=p[2]}} or {}
    end,
    observe=function(_, v)
        if ring_step == 5 then assert(v.minutes == 40 and v.phase == "ready") end
        if ring_step == 10 then assert(v.minutes == 40 and v.phase == "running") end
        if ring_step == 12 then assert(v.theme == 2 and v.phase == "running") end
        ring_step=ring_step+1
    end,
})
assert(ring_step == 15)
run("clock_dial_demo", { no_touch = true, cancel = true, expect_error = true })
run("clock_dial_demo", { width = 159, expect_error = true })
for _, id in ipairs({ "dino", "flappybird", "lcd_touch_paint", "balance_ball", "codex_usage_dashboard" }) do
    for _, size in ipairs({ {160, id == "codex_usage_dashboard" and 240 or 160}, {320,240}, {800,480} }) do
        run(id, { width=size[1], height=size[2], args={}, text_bounds=true })
    end
    run(id, { cancel=true, expect_error=true })
    run(id, { display_error=true, expect_error=true })
end
run("lcd_touch_paint", { no_touch=true, expect_error=true })
run("codex_usage_dashboard", { args={url="invalid"}, expect_error=true })
run("codex_usage_dashboard", { args={url="https://example.test"}, response={}, expect_error=true })
local stale = run("codex_usage_dashboard", {
    args={url="https://example.test"}, capture_text=true, requests=2, expect_error=true,
    response=function(n) return n == 1 and "HTTP 200\n{}" or "HTTP 500\n{}" end,
    touch=function(state)
        if state.now == 150 then return {{id=1,x=30,y=220}} end
        if state.now == 300 then return {{id=1,x=300,y=20}} end
        return {}
    end,
})
assert(table.concat(stale.texts, "|"):find("STALE / RETRY", 1, true))
local stale_status
for i, value in ipairs(stale.texts) do if value == "STALE / RETRY" then stale_status = i end end
assert(stale_status and stale.texts[stale_status - 2] == "85%" and stale.texts[stale_status - 5] == "72%", "failed refresh discarded previous quota")
run("codex_usage_dashboard", { args={url="https://example.test"}, data={five_h_pct=50,weekly_pct=70,five_h_reset=string.rep("中文",100).."\nBAD"}, text_bounds=true })
run("codex_usage_dashboard", { no_touch=true, cancel=true, expect_error=true })
run("dino", { args={input_mode="button",button_gpio=0} })
run("flappybird", { args={input_mode="button",button_gpio=0} })
print(string.format("PASS: %d App API/lifecycle cases", cases))
