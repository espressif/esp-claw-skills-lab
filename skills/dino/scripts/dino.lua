local bm = require("board_manager")
local disp = require("display")
local dly = require("delay")
local sys = require("system")

local touch_ok, lcd_touch = pcall(require, "lcd_touch")
local button_ok, button = pcall(require, "button")

local a = type(args) == "table" and args or {}

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function num_arg(k, default)
    local v = a[k]
    if type(v) == "number" then return v end
    return default
end

local function str_arg(k, default)
    local v = a[k]
    if type(v) == "string" and v ~= "" then return v end
    return default
end

local function bool_arg(k, default)
    local v = a[k]
    if type(v) == "boolean" then return v end
    return default
end

local LOOK_PRESETS = {
    classic = { color = "gray", scale = 1.00 },
    chrome = { color = "gray", scale = 1.00 },
    mini_blue = { color = "blue", scale = 0.85 },
    big_orange = { color = "orange", scale = 1.25 },
}

local COLOR_PRESETS = {
    gray = {
        body = { r = 83, g = 83, b = 83 },
        dark = { r = 55, g = 55, b = 55 },
        highlight = { r = 120, g = 120, b = 120 },
        belly = { r = 83, g = 83, b = 83 },
        outline = { r = 45, g = 45, b = 45 },
    },
    green = {
        body = { r = 55, g = 185, b = 80 },
        dark = { r = 25, g = 105, b = 55 },
        highlight = { r = 145, g = 235, b = 135 },
        belly = { r = 225, g = 245, b = 170 },
        outline = { r = 25, g = 65, b = 35 },
    },
    red = {
        body = { r = 220, g = 70, b = 50 },
        dark = { r = 150, g = 30, b = 25 },
        highlight = { r = 250, g = 160, b = 120 },
        belly = { r = 250, g = 210, b = 180 },
        outline = { r = 90, g = 20, b = 15 },
    },
    blue = {
        body = { r = 70, g = 145, b = 235 },
        dark = { r = 35, g = 75, b = 160 },
        highlight = { r = 160, g = 215, b = 255 },
        belly = { r = 220, g = 240, b = 255 },
        outline = { r = 20, g = 45, b = 100 },
    },
    purple = {
        body = { r = 150, g = 95, b = 220 },
        dark = { r = 90, g = 50, b = 145 },
        highlight = { r = 215, g = 175, b = 255 },
        belly = { r = 245, g = 225, b = 255 },
        outline = { r = 60, g = 35, b = 105 },
    },
    orange = {
        body = { r = 245, g = 135, b = 35 },
        dark = { r = 165, g = 75, b = 20 },
        highlight = { r = 255, g = 205, b = 115 },
        belly = { r = 255, g = 235, b = 175 },
        outline = { r = 95, g = 45, b = 15 },
    },
}

local function copy_color(c)
    return { r = c.r, g = c.g, b = c.b }
end

local function rgb(v, fallback)
    if type(v) == "table" and type(v.r) == "number" and type(v.g) == "number" and type(v.b) == "number" then
        return {
            r = clamp(math.floor(v.r), 0, 255),
            g = clamp(math.floor(v.g), 0, 255),
            b = clamp(math.floor(v.b), 0, 255),
        }
    end
    return copy_color(fallback)
end

local look = LOOK_PRESETS[str_arg("preset", "classic")] or LOOK_PRESETS.classic
local RUN_MS = math.floor(num_arg("run_ms", 0))
local FRAME_MS = clamp(math.floor(num_arg("frame_ms", 33)), 16, 1000)
local SCALE = clamp(num_arg("scale", look.scale), 0.70, 1.60)
local COLOR_NAME = str_arg("color", look.color)
local palette_base = COLOR_PRESETS[COLOR_NAME] or COLOR_PRESETS.gray
local PAL = {
    body = rgb(a.body_color, palette_base.body),
    dark = rgb(a.dark_color, palette_base.dark),
    highlight = rgb(a.highlight_color, palette_base.highlight),
    belly = rgb(a.belly_color, palette_base.belly),
    outline = rgb(a.outline_color, palette_base.outline),
}

local GRAVITY = num_arg("gravity", 0.42)
local JUMP_V = num_arg("jump_v", -10.0)
local SCROLL_V0 = num_arg("scroll_v0", 2.1)
local SCROLL_MAX = num_arg("scroll_max", 3.4)
local SCROLL_ACC = num_arg("scroll_acc", 0.00030)
local SPAWN_MIN = math.floor(num_arg("spawn_min", 175))
local SPAWN_MAX = math.floor(num_arg("spawn_max", 300))
local FONT_SIZE_ARG = a.font_size
local INPUT_MODE = str_arg("input_mode", "auto")
local TOUCH_NAME = str_arg("touch_name", "lcd_touch")
local BUTTON_GPIO = a.button_gpio
if type(BUTTON_GPIO) ~= "number" then BUTTON_GPIO = a.key_gpio end
if type(BUTTON_GPIO) == "number" then BUTTON_GPIO = math.floor(BUTTON_GPIO) end
local BUTTON_ACTIVE_LEVEL = math.floor(num_arg("button_active_level", num_arg("key_active_level", 0)))
local BUTTON_LONG_PRESS_MS = math.floor(num_arg("button_long_press_ms", 1500))
local BUTTON_SHORT_PRESS_MS = math.floor(num_arg("button_short_press_ms", 180))
local ENABLE_TOUCH = bool_arg("enable_touch", INPUT_MODE ~= "button")
local ENABLE_BUTTON = bool_arg("enable_button", INPUT_MODE == "button" or INPUT_MODE == "both" or BUTTON_GPIO ~= nil)

local panel, ioh, W, H, pif = bm.get_display_lcd_params("display_lcd")
if not panel then
    print("[dino] ERROR: lcd params failed: " .. tostring(ioh))
    return
end

local ok, err = pcall(disp.init, panel, ioh, W, H, pif)
if not ok then
    print("[dino] ERROR: display init failed: " .. tostring(err))
    return
end

local ready = true
W, H = disp.width, disp.height
local DEFAULT_FZ = clamp(math.floor(H / 12), 14, 24)
local FZ = clamp(math.floor(type(FONT_SIZE_ARG) == "number" and FONT_SIZE_ARG or DEFAULT_FZ), 12, 40)

local touch_handle, button_handle
local touch_consumed, button_last_level = false, nil
local input_sources = {}

local function cleanup()
    if button_handle then
        pcall(button.off, button_handle)
        pcall(button.close, button_handle)
        button_handle = nil
    end
    if ready then
        pcall(disp.end_frame)
        pcall(disp.deinit)
        ready = false
    end
end

local function add_input_source(name)
    input_sources[#input_sources + 1] = name
end

local function init_touch_input()
    if not ENABLE_TOUCH then return false end
    if not touch_ok then
        print("[dino] WARN: require(lcd_touch) failed")
        return false
    end

    local touch_err
    touch_handle, touch_err = bm.get_lcd_touch_handle(TOUCH_NAME)
    if not touch_handle then
        print("[dino] WARN: get_lcd_touch_handle(" .. TOUCH_NAME .. ") failed: " .. tostring(touch_err))
        return false
    end

    local synced, touch_info = pcall(lcd_touch.sync, touch_handle)
    if not synced then
        print("[dino] WARN: lcd_touch.sync failed: " .. tostring(touch_info))
        touch_handle = nil
        return false
    end

    add_input_source("touch:" .. TOUCH_NAME)
    return true
end

local function init_button_input()
    if INPUT_MODE == "auto" and not touch_handle and BUTTON_GPIO == nil then BUTTON_GPIO = 0 end
    if not ENABLE_BUTTON and BUTTON_GPIO == nil then return false end
    if not button_ok then
        print("[dino] WARN: require(button) failed")
        return false
    end

    local handle, err = button.new(BUTTON_GPIO or 0, BUTTON_ACTIVE_LEVEL, BUTTON_LONG_PRESS_MS, BUTTON_SHORT_PRESS_MS)
    if not handle then
        print("[dino] WARN: button.new gpio=" .. tostring(BUTTON_GPIO or 0) .. " failed: " .. tostring(err))
        return false
    end

    button_handle = handle
    local level, level_err = button.get_key_level(button_handle)
    if level == nil then
        print("[dino] WARN: button.get_key_level failed: " .. tostring(level_err))
        pcall(button.close, button_handle)
        button_handle = nil
        return false
    end

    button_last_level = level
    add_input_source("button:gpio" .. tostring(BUTTON_GPIO or 0))
    return true
end

local function init_input()
    init_touch_input()
    init_button_input()

    if #input_sources == 0 then
        print("[dino] ERROR: no input source available; enable touch or pass button_gpio")
        cleanup()
        return false
    end

    return true
end

math.randomseed(math.floor(sys.millis()) & 0x7fffffff)

local function rnd(lo, hi)
    return math.random(lo, hi)
end

local BASE_W, BASE_H = 48, 44
local DW = math.floor(BASE_W * SCALE + 0.5)
local DH = math.floor(BASE_H * SCALE + 0.5)
local DX = math.floor(num_arg("dino_x", 34))
local SEA_H = 24
local TOP_SAFE = math.floor(num_arg("top_safe", clamp(math.floor(H * 0.12), 18, 30)))
local GROUND_MARGIN = math.floor(num_arg("ground_margin", clamp(math.floor(H * 0.11), 22, 34)))
local GY = H - GROUND_MARGIN
local GH = H - GY

local dino_y, dino_vy, on_ground
local obs, gulls, palms, decor, bubbles = {}, {}, {}, {}, {}
local scroll_px, next_spawn, speed, anim_t
local score, best, over = 0, 0, false

local function frame_color(r, g, b) return { r = r, g = g, b = b } end
local function fr(x, y, w, h, r, g, b) disp.fill_rect(x, y, w, h, frame_color(r, g, b)) end
local function dr(x, y, w, h, r, g, b) disp.draw_rect(x, y, w, h, frame_color(r, g, b)) end
local function fc(x, y, r, cr, cg, cb) disp.fill_circle(x, y, r, frame_color(cr, cg, cb)) end
local function frr(x, y, w, h, rd, r, g, b) disp.fill_round_rect(x, y, w, h, rd, frame_color(r, g, b)) end
local function ft(x1, y1, x2, y2, x3, y3, r, g, b) disp.fill_triangle(x1, y1, x2, y2, x3, y3, frame_color(r, g, b)) end
local function fa(cx, cy, ir, ro, sd, ed, r, g, b) disp.fill_arc(cx, cy, ir, ro, sd, ed, frame_color(r, g, b)) end
local function ln(x1, y1, x2, y2, r, g, b) disp.draw_line(x1, y1, x2, y2, frame_color(r, g, b)) end
local function col(c) return c.r, c.g, c.b end

local function init_decor()
    gulls, palms, decor, bubbles = {}, {}, {}, {}
    for i = 1, 4 do gulls[i] = { x = rnd(0, W), y = rnd(24, 78), s = rnd(10, 18), v = (18 + rnd(0, 18)) / 100 } end
    for i = 1, 8 do decor[i] = { x = rnd(0, W * 2), t = rnd(0, 2) } end
end

local function reset()
    dino_y, dino_vy, on_ground = GY - DH, 0, true
    obs = {}
    scroll_px, next_spawn, speed, anim_t = 0, 160, SCROLL_V0, 0
    score, over = 0, false
end

local function consume_press()
    local pressed = false

    if touch_handle then
        local polled, info = pcall(lcd_touch.poll, touch_handle)
        if not polled then
            print("[dino] ERROR: lcd_touch.poll failed: " .. tostring(info))
            return nil
        end

        pressed = pressed or (info.just_pressed == true and not touch_consumed)
        touch_consumed = info.pressed == true
    end

    if button_handle then
        local level, level_err = button.get_key_level(button_handle)
        if level == nil then
            print("[dino] ERROR: button.get_key_level failed: " .. tostring(level_err))
            return nil
        end

        pressed = pressed or (level == BUTTON_ACTIVE_LEVEL and button_last_level ~= BUTTON_ACTIVE_LEVEL)
        button_last_level = level
    end

    return pressed
end

local function input()
    local pressed = consume_press()
    if pressed == nil then return end
    if over then
        if pressed then return "restart" end
        return
    end
    if pressed and on_ground then
        dino_vy = JUMP_V
        on_ground = false
    end
end

local function spawn_obstacle()
    local kind = rnd(1, 3)
    if kind == 1 then
        local w, h = rnd(14, 18), rnd(28, 42)
        obs[#obs + 1] = { x = W + 6, y = GY - h, w = w, h = h, kind = "cactus", scored = false, seed = rnd(0, 6) }
    elseif kind == 2 then
        local w, h = rnd(24, 34), rnd(24, 38)
        obs[#obs + 1] = { x = W + 6, y = GY - h, w = w, h = h, kind = "cactus_pair", scored = false, seed = rnd(0, 5) }
    else
        local w, h = rnd(38, 48), rnd(20, 30)
        obs[#obs + 1] = { x = W + 6, y = GY - h, w = w, h = h, kind = "cactus_cluster", scored = false, seed = rnd(0, 5) }
    end
end

local function step(df)
    anim_t = anim_t + df
    if over then return end

    speed = clamp(speed + SCROLL_ACC * df, SCROLL_V0, SCROLL_MAX)
    if not on_ground then
        dino_vy = dino_vy + GRAVITY * df
        dino_y = dino_y + dino_vy * df
        if dino_y >= GY - DH then
            dino_y, dino_vy, on_ground = GY - DH, 0, true
        end
    end

    local sv = speed * df
    scroll_px = scroll_px + sv
    for i = #obs, 1, -1 do
        local o = obs[i]
        o.x = o.x - sv
        if (not o.scored) and (o.x + o.w) < DX then
            o.scored = true
            score = score + 1
            if score > best then best = score end
        end
        if o.x + o.w < -24 then table.remove(obs, i) end
    end

    next_spawn = next_spawn - sv
    if next_spawn <= 0 then
        spawn_obstacle()
        next_spawn = rnd(SPAWN_MIN, SPAWN_MAX)
    end

    for _, g in ipairs(gulls) do
        g.x = g.x - g.v * df
        if g.x < -12 then
            g.x, g.y, g.s = W + rnd(0, 80), rnd(24, 78), rnd(10, 18)
        end
    end
    for _, p in ipairs(palms) do
        p.x = p.x - 0.55 * df
        if p.x < -30 then p.x, p.h = W + rnd(10, 140), rnd(30, 50) end
    end
    for _, d in ipairs(decor) do
        d.x = d.x - sv * 0.85
        if d.x < -12 then d.x, d.t = W + rnd(30, 200), rnd(0, 2) end
    end
    for _, bu in ipairs(bubbles) do
        bu.y = bu.y - bu.vy * df
        if bu.y < GY - SEA_H - 2 then bu.y, bu.x, bu.r = GY - 1, rnd(0, W), rnd(1, 3) end
    end

    local dx1, dy1 = DX + math.floor(DW * 0.18), dino_y + math.floor(DH * 0.20)
    local dx2, dy2 = DX + DW - math.floor(DW * 0.18), dino_y + DH - math.floor(DH * 0.12)
    for i = 1, #obs do
        local o = obs[i]
        if dx1 < o.x + o.w - 2 and dx2 > o.x + 2 and dy1 < o.y + o.h and dy2 > o.y + 2 then
            over = true
            break
        end
    end
end

local function draw_bg()
    for _, g in ipairs(gulls) do
        local x, y, s = math.floor(g.x), math.floor(g.y), g.s
        ln(x, y + 8, x + 4, y + 4, 210, 210, 210)
        ln(x + 4, y + 4, x + 8, y + 4, 210, 210, 210)
        ln(x + 8, y + 4, x + 12, y, 210, 210, 210)
        ln(x + 12, y, x + s, y, 210, 210, 210)
        ln(x + s, y, x + s + 6, y + 5, 210, 210, 210)
        ln(x + s + 6, y + 5, x + s + 12, y + 5, 210, 210, 210)
        ln(x + s + 12, y + 5, x + s + 16, y + 8, 210, 210, 210)
    end
end

local function draw_ground()
    fr(0, GY, W, 2, 83, 83, 83)
    fr(0, GY + 2, W, GH - 2, 255, 255, 255)
    for _, d in ipairs(decor) do
        local x = math.floor(d.x)
        local y = GY + 9 + (d.t * 4)
        if d.t == 0 then
            fr(x, y, 8, 1, 150, 150, 150)
        elseif d.t == 1 then
            fr(x, y, 3, 1, 170, 170, 170)
            fr(x + 6, y, 6, 1, 170, 170, 170)
        else
            fr(x, y, 2, 2, 185, 185, 185)
        end
    end
    local off = math.floor(scroll_px) % 28
    for x = -off, W, 28 do fr(x, GY + 18, 10, 1, 170, 170, 170) end
end

local function make_scaled_draw(x, y)
    local function sx(v) return x + math.floor(v * SCALE + 0.5) end
    local function sy(v) return y + math.floor(v * SCALE + 0.5) end
    local function sz(v) return math.max(1, math.floor(v * SCALE + 0.5)) end
    return {
        rect = function(px, py, pw, ph, c) fr(sx(px), sy(py), sz(pw), sz(ph), col(c)) end,
        round = function(px, py, pw, ph, rd, c) frr(sx(px), sy(py), sz(pw), sz(ph), sz(rd), col(c)) end,
        circle = function(px, py, pr, c) fc(sx(px), sy(py), sz(pr), col(c)) end,
        tri = function(x1, y1, x2, y2, x3, y3, c) ft(sx(x1), sy(y1), sx(x2), sy(y2), sx(x3), sy(y3), col(c)) end,
        line = function(x1, y1, x2, y2, c) ln(sx(x1), sy(y1), sx(x2), sy(y2), col(c)) end,
    }
end

local function draw_dino(x, y)
    local s = make_scaled_draw(x, y)
    local leg = on_ground and (math.floor(anim_t / 4) % 2) or 2
    local body, cut = PAL.body, { r = 255, g = 255, b = 255 }

    local function block(px, py, pw, ph)
        s.rect(px, py, pw, ph, body)
    end

    local function erase(px, py, pw, ph)
        s.rect(px, py, pw, ph, cut)
    end

    -- Tail: stepped blocks keep the silhouette pixelated while staying editable.
    block(0, 18, 3, 11)
    block(3, 22, 5, 8)
    block(8, 25, 6, 7)
    block(14, 28, 6, 6)

    -- Body and chest.
    block(10, 23, 20, 11)
    block(15, 18, 17, 12)
    block(20, 14, 12, 10)
    block(24, 11, 8, 7)

    -- Neck and head.
    block(28, 4, 8, 19)
    block(31, 0, 18, 12)
    block(34, 12, 15, 7)
    block(40, 19, 8, 2)

    -- Chrome-Dino style negative pixels: eye and mouth notch.
    erase(34, 4, 3, 3)
    erase(41, 12, 8, 4)

    -- Small arm.
    block(31, 24, 8, 3)
    block(38, 27, 3, 4)

    -- Belly/hip mass.
    block(18, 32, 14, 4)

    -- Running legs. Each frame is still procedural parts, not a sprite bitmap.
    if leg == 0 then
        block(14, 35, 5, 8)
        block(11, 42, 8, 2)
        block(27, 35, 4, 6)
        block(27, 40, 7, 2)
    elseif leg == 1 then
        block(14, 35, 4, 6)
        block(14, 40, 7, 2)
        block(27, 35, 5, 8)
        block(27, 42, 8, 2)
    else
        block(15, 35, 4, 7)
        block(27, 35, 4, 7)
    end
end

local function draw_shadow(cx)
    if on_ground then
        fr(cx - math.floor(DW * 0.42), GY + 3, math.floor(DW * 0.84), 2, 225, 225, 225)
    else
        fr(cx - math.floor(DW * 0.28), GY + 4, math.floor(DW * 0.56), 1, 230, 230, 230)
    end
end

local function draw_cactus_part(x, base, h, w)
    fr(x, base - h, w, h, 83, 83, 83)
    fr(x - 5, base - math.floor(h * 0.58), 5, 4, 83, 83, 83)
    fr(x - 7, base - math.floor(h * 0.72), 3, 10, 83, 83, 83)
    fr(x + w, base - math.floor(h * 0.42), 5, 4, 83, 83, 83)
    fr(x + w + 3, base - math.floor(h * 0.58), 3, 9, 83, 83, 83)
end

local function draw_cactus(o)
    local x, y, w, h = math.floor(o.x), o.y, o.w, o.h
    local base = y + h
    if o.kind == "cactus_pair" then
        draw_cactus_part(x + 2, base, h, 5)
        draw_cactus_part(x + w - 9, base, math.max(18, h - 7), 5)
    elseif o.kind == "cactus_cluster" then
        draw_cactus_part(x + 4, base, h, 5)
        draw_cactus_part(x + 17, base, math.max(16, h - 8), 5)
        draw_cactus_part(x + 30, base, math.max(18, h - 3), 5)
    else
        draw_cactus_part(x + (w // 2) - 3, base, h, 6)
    end
end

local function draw_obstacles()
    for i = 1, #obs do
        draw_cactus(obs[i])
    end
end

local TXT = { color = frame_color(0, 0, 0), bg = frame_color(255, 255, 255), font_size = FZ }
local TXT_C = {
    color = frame_color(0, 0, 0),
    bg = frame_color(255, 255, 255),
    font_size = FZ,
    align = "center",
    valign = "middle",
}

local function draw_hud()
    local hi = string.format("HI %05d", best)
    local s = string.format("%05d", score)
    local hi_w = disp.measure_text(hi, { font_size = FZ })
    local score_w = disp.measure_text(s, { font_size = FZ })
    local x = W - hi_w - score_w - 24
    disp.draw_text(x, TOP_SAFE, hi, TXT)
    disp.draw_text(x + hi_w + 18, TOP_SAFE, s, TXT)
end

local function overlay_center(lines)
    local lh = FZ + 8
    local max_w = 0
    for _, text in ipairs(lines) do
        local tw = disp.measure_text(text, { font_size = FZ })
        if tw > max_w then max_w = tw end
    end
    local bw = math.min(W - 10, max_w + 40)
    local bh = #lines * lh + 12
    local bx = (W - bw) // 2
    local by = (H - bh) // 2
    for i, text in ipairs(lines) do
        disp.draw_text_aligned(bx, by + 6 + (i - 1) * lh, bw, FZ, text, TXT_C)
    end
end

local function draw_title_banner()
    overlay_center({ " D I N O ", "PRESS TO JUMP" })
end

local function draw_game_over()
    local lh = FZ + 7
    local y = math.max(TOP_SAFE + FZ + 4, math.floor(H * 0.14))
    disp.draw_text_aligned(0, y, W, FZ, "G A M E  O V E R", TXT_C)
    disp.draw_text_aligned(0, y + lh, W, FZ, string.format("SCORE %d", score), TXT_C)
    disp.draw_text_aligned(0, y + lh * 2, W, FZ, string.format("HI %d", best), TXT_C)
    disp.draw_text_aligned(0, math.min(GY - FZ - 4, y + lh * 3), W, FZ, "PRESS TO RESTART", TXT_C)
end

local function render()
    disp.begin_frame({ clear = true, color = frame_color(255, 255, 255) })
    draw_bg()
    draw_ground()
    draw_obstacles()
    draw_shadow(DX + DW // 2)
    draw_dino(DX, math.floor(dino_y))
    draw_hud()
    if score == 0 and on_ground and #obs == 0 then draw_title_banner() end
    if over then
        draw_game_over()
    end
    disp.present()
    disp.end_frame()
end

if not init_input() then return end
init_decor()
reset()
print(string.format(
    "[dino] ready %dx%d input=%s preset=%s color=%s scale=%.2f run_ms=%d",
    W, H, table.concat(input_sources, "+"), str_arg("preset", "classic"), COLOR_NAME, SCALE, RUN_MS
))

local t0, last = sys.millis(), sys.millis()
local ok2, err2 = xpcall(function()
    while true do
        if RUN_MS > 0 and (sys.millis() - t0) >= RUN_MS then break end
        local now = sys.millis()
        local dt = now - last
        if dt < 0 then dt = 0 end
        last = now
        local df = dt / FRAME_MS
        if df > 3 then df = 3 end
        if input() == "restart" then reset() end
        step(df)
        render()
        local sl = FRAME_MS - (sys.millis() - now)
        if sl > 0 then dly.delay_ms(sl) end
    end
end, debug.traceback)

cleanup()
if not ok2 then print("[dino] ERROR: " .. tostring(err2)) end
print("[dino] done")
