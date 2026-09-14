-- whack_mole_game.lua: playable whack-a-mole v1 for esp-claw.
-- One overlay canvas for mole/bomb (cap 140px, <=40KB) plus overlay-sized
-- oval empty holes (same ow x oh, bottom-centered). Not 9 overlay canvases.
-- RST/EXIT use baked rgb565 icon canvases. Color-button fallback.
-- Firmware does not scale canvas pixels; set_zoom/set_size are no-ops.
-- Full-rectangle adaptive layout: landscape HUD column, portrait/square top HUD.
-- Does not use circular-bezel / inscribed-square geometry.

local board_manager = require("board_manager")
local delay = require("delay")
local lvgl = require("lvgl")
local system = require("system")
local logic = require("whack_logic")

-- Bundled local-script sets this true. Hosted WASM sim also takes the
-- display path: it never calls lv_tick_inc, so LVGL freezes after frame 1.
-- Device firmware has no display._claim_owner and keeps the LVGL path.
local EMBEDDED_ASSETS = false
do
    local ok, d = pcall(require, "display")
    if ok and d and type(d._claim_owner) == "function" then
        EMBEDDED_ASSETS = true
    end
end

-- WASM lvgl userdata has no __newindex (obj._role) and some builds
-- fail method lookup; never let that kill the skill.
local obj_extra = {}
local function safe_set_text(obj, text)
    if obj == nil then return end
    pcall(function() obj:set_text(text) end)
end
local function safe_set_style(obj, opts)
    if obj == nil then return end
    pcall(function() obj:set_style(opts) end)
end
local function safe_role(obj, role)
    if obj == nil then return end
    pcall(function() obj._role = role end)
    obj_extra[obj] = obj_extra[obj] or {}
    obj_extra[obj].role = role
end

local COLORS = {
    screen_bg = "#E4EFDE",
    play_bg   = "#E3F3D9",
    panel_bg  = "#FAFBF5",
    border    = "#000000",
    text      = "#1F2A1F",
    dim       = "#6B7A8D",
    rst_bg    = "#FEFDF9",
    empty_bg  = "#5C4033",
    empty_fg  = "#C4B8A8",
    mole_bg   = "#E8A54B",
    mole_fg   = "#2A1A0A",
    bomb_bg   = "#C0392B",
    bomb_fg   = "#FFF4E6",
    done      = "#C25E00",
}

local function kind_style(kind)
    if kind == "mole" then
        return COLORS.mole_bg, COLORS.mole_fg, "MOLE"
    end
    if kind == "bomb" then
        return COLORS.bomb_bg, COLORS.bomb_fg, "BOMB"
    end
    return COLORS.empty_bg, COLORS.empty_fg, ""
end

local function clamp(v, lo, hi)
    v = math.floor(tonumber(v) or 0)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- Disable scrolling / scrollbars. Real esp-claw / mosaico lua_module_lvgl
-- binding is obj:set_scroll({ dir = "none", scrollbar = "off" }). Other
-- names are tried via pcall so a missing method cannot crash the skill.
local function lock_obj(obj)
    if obj == nil then return obj end
    pcall(function()
        obj:set_scroll({ dir = "none", scrollbar = "off" })
    end)
    pcall(function() obj:set_scrollbar_mode("off") end)
    pcall(function() obj:set_scroll_dir("none") end)
    pcall(function() obj.scrollable = false end)
    pcall(function() obj:clear_flag("SCROLLABLE") end)
    pcall(function() obj:clear_flag("LV_OBJ_FLAG_SCROLLABLE") end)
    pcall(function()
        local f = lvgl.LV_OBJ_FLAG_SCROLLABLE
        if f ~= nil then obj:clear_flag(f) end
    end)
    return obj
end

local function mk(kind, parent, opts)
    opts = opts or {}
    if opts.pad == nil then opts.pad = 0 end
    return lock_obj(lvgl[kind](parent, opts))
end

-- align=center is object align; text_align actually centers glyphs.
local function center_text(obj)
    if obj == nil then return obj end
    pcall(function()
        obj:set_style({
            text_align = "center",
            align = "center",
            pad = 0,
            pad_left = 0,
            pad_right = 0,
        })
    end)
    return obj
end

local panel_handle, io_handle, width, height, panel_if =
    board_manager.get_display_lcd_params("display_lcd")

width = math.floor(tonumber(width) or 0)
height = math.floor(tonumber(height) or 0)
if width < 64 then width = 240 end
if height < 64 then height = 240 end

local function assets_dir()
    local src = debug.getinfo(1, "S").source or ""
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    local root = src:match("^(.*)[/\\]scripts[/\\][^/\\]+$")
    if root ~= nil and root ~= "" then
        return root .. "/assets"
    end
    return "/fatfs/skills/whack_mole_game/assets"
end

local function read_all(path)
    local f = io and io.open(path, "rb")
    if f then
        local data = f:read("*a")
        f:close()
        if type(data) == "string" and #data > 0 then return data end
    end
    local ok, storage = pcall(require, "storage")
    if ok and storage and storage.read_file then
        local data = storage.read_file(path)
        if type(data) == "string" and #data > 0 then return data end
    end
    return nil
end

local function parse_rgb565(blob)
    if type(blob) ~= "string" or #blob < 4 then return nil end
    local w = blob:byte(1) + blob:byte(2) * 256
    local h = blob:byte(3) + blob:byte(4) * 256
    if w < 1 or h < 1 or w > 48 or h > 48 then return nil end
    local need = w * h * 2
    if #blob ~= 4 + need then return nil end
    return { w = w, h = h, pix = blob:sub(5) }
end

local function scale_nn(src, dw, dh)
    dw = math.floor(tonumber(dw) or 0)
    dh = math.floor(tonumber(dh) or 0)
    if dw < 1 then dw = 1 end
    if dh < 1 then dh = 1 end
    if src == nil or type(src.pix) ~= "string" then return nil end
    if src.w == dw and src.h == dh and #src.pix == dw * dh * 2 then
        return src.pix
    end
    local sw, sh, pix = src.w, src.h, src.pix
    if sw < 1 or sh < 1 then return nil end
    local rows = {}
    for y = 0, dh - 1 do
        local sy = math.floor(y * sh / dh)
        if sy >= sh then sy = sh - 1 end
        local row = {}
        local sbase = sy * sw * 2
        for x = 0, dw - 1 do
            local sx = math.floor(x * sw / dw)
            if sx >= sw then sx = sw - 1 end
            local i = sbase + sx * 2 + 1
            row[x + 1] = pix:sub(i, i + 1)
        end
        rows[y + 1] = table.concat(row)
    end
    return table.concat(rows)
end

local function load_blob(name)
    local embed = rawget(_G, "__WHACK_EMBED")
    if type(embed) == "table" and type(embed[name]) == "string" then
        local hex = embed[name]
        local data = hex:gsub("..", function(cc)
            return string.char(tonumber(cc, 16))
        end)
        if type(data) == "string" and #data > 0 then return data end
    end
    local dir = assets_dir()
    local data = read_all(dir .. "/" .. name)
    if data == nil and dir ~= "/fatfs/skills/whack_mole_game/assets" then
        data = read_all("/fatfs/skills/whack_mole_game/assets/" .. name)
    end
    return data
end


-- Web WASM path: draw via display.* every frame (no lv_tick_inc / LVGL refresh).
local function run_web_display_sim()
    local display = require("display")
    local touch = require("touch")

    local ok5 = pcall(function()
        display.init(panel_handle, io_handle, width, height, panel_if)
    end)
    if not ok5 then
        display.init(panel_handle, io_handle, width, height)
    end
    pcall(function() display.backlight(true) end)

    local SRC_W, SRC_H = 48, 38
    local short = math.min(width, height)
    local PAD = clamp(short / 60, 4, 14)
    local GAP = clamp(short / 80, 3, 10)
    local RADIUS = clamp(short / 48, 4, 14)
    local BORDER = 1
    if short >= 400 then BORDER = 2 end
    local INNER = GAP
    local FONT_LINE = 28

    -- Same landscape HUD formulas as the LVGL land branch.
    local hud_w = math.floor(0.28 * width)
    local min_hud = math.max(56, math.floor(0.18 * width))
    local max_hud = math.max(min_hud, width - 2 * PAD - GAP - 24)
    if hud_w < min_hud then hud_w = min_hud end
    if hud_w > max_hud then hud_w = max_hud end

    local play_h = height - 2 * PAD
    if play_h < 1 then play_h = 1 end
    local play_w = width - hud_w - 2 * PAD - GAP
    if play_w < 1 then play_w = 1 end
    if play_w < play_h then
        local need = play_h - play_w
        local shrink = hud_w - min_hud
        if shrink > need then shrink = need end
        if shrink > 0 then
            hud_w = hud_w - shrink
            play_w = play_w + shrink
        end
    end
    if play_w < 1 then play_w = 1 end

    local hud_x, hud_y = PAD, PAD
    local hud_h = height - 2 * PAD
    if hud_h < 1 then hud_h = 1 end
    local play_x = PAD + hud_w + GAP
    local play_y = PAD

    if hud_x < 0 then hud_x = 0 end
    if hud_y < 0 then hud_y = 0 end
    if play_x < 0 then play_x = 0 end
    if play_y < 0 then play_y = 0 end
    if hud_w < 1 then hud_w = 1 end
    if hud_h < 1 then hud_h = 1 end
    if play_w < 1 then play_w = 1 end
    if play_h < 1 then play_h = 1 end
    if hud_x + hud_w > width then hud_w = math.max(1, width - hud_x) end
    if hud_y + hud_h > height then hud_h = math.max(1, height - hud_y) end
    if play_x + play_w > width then play_w = math.max(1, width - play_x) end
    if play_y + play_h > height then play_h = math.max(1, height - play_y) end

    local function hole_px_local(pw, ph)
        local iw = pw - 2 * INNER
        local ih = ph - 2 * INNER
        if iw < 3 then iw = pw end
        if ih < 3 then ih = ph end
        local span = math.min(iw, ih)
        local h = math.floor((span - 2 * GAP) / 3)
        if h < 1 then h = math.max(1, math.floor(span / 3)) end
        return h
    end

    local hole = hole_px_local(play_w, play_h)
    local grid = 3 * hole + 2 * GAP
    if grid > play_w or grid > play_h then
        local cap = math.min(play_w, play_h)
        hole = math.max(1, math.floor((cap - 2 * INNER - 2 * GAP) / 3))
        grid = 3 * hole + 2 * GAP
        if grid > cap then
            hole = math.max(1, math.floor(cap / 3))
            grid = 3 * hole
        end
    end
    local gx = math.floor((play_w - grid) / 2)
    local gy = math.floor((play_h - grid) / 2)
    if gx < 0 then gx = 0 end
    if gy < 0 then gy = 0 end

    local HUD_IN = clamp(hud_w / 12, 6, 16)
    if HUD_IN * 2 >= hud_w then
        HUD_IN = math.max(0, math.floor(hud_w / 20))
    end
    local hx = HUD_IN
    local hw = hud_w - 2 * HUD_IN
    if hw < 1 then
        hw = math.max(1, hud_w)
        hx = 0
    end

    -- 6 slots: SCORE, COMBO, TIME, RST, EXIT, status.
    local n = 6
    local gslot = GAP
    if gslot * (n - 1) >= hud_h then gslot = 0 end
    local body = hud_h - gslot * (n - 1)
    if body < n then
        gslot = 0
        body = hud_h
    end
    local st_min = 14
    local btn_min = 24
    local info_want = FONT_LINE * 2
    local st = FONT_LINE
    if st > body - 5 then st = math.max(1, math.floor(body / n)) end
    local btn = math.max(btn_min, math.floor(body * 0.13))
    local info = math.floor((body - st - 2 * btn) / 3)
    if info < 1 then info = 1 end
    if info < info_want then
        local steal = st - st_min
        if steal < 0 then steal = 0 end
        local need = (info_want - info) * 3
        if steal > need then steal = need end
        if steal > 0 then
            st = st - steal
            info = math.floor((body - st - 2 * btn) / 3)
        end
    end
    if info < info_want then
        local need = (info_want - info) * 3
        local room = 2 * (btn - btn_min)
        if room < 0 then room = 0 end
        if room > 0 then
            local steal = need
            if steal > room then steal = room end
            btn = btn - math.floor(steal / 2)
            if btn < btn_min then btn = btn_min end
            info = math.floor((body - st - 2 * btn) / 3)
        end
    end
    if info < 1 then info = 1 end
    if btn < 1 then btn = 1 end
    if st < 1 then st = 1 end
    local hs = { info, info, info, btn, btn, st }
    local sum = gslot * (n - 1)
    for i = 1, n do
        if hs[i] < 1 then hs[i] = 1 end
        sum = sum + hs[i]
    end
    local extra = sum - hud_h
    if extra > 0 then
        for i = n, 1, -1 do
            local take = hs[i] - 1
            if take > extra then take = extra end
            if take > 0 then
                hs[i] = hs[i] - take
                extra = extra - take
            end
            if extra <= 0 then break end
        end
    elseif extra < 0 then
        extra = -extra
        local i = 1
        while extra > 0 do
            hs[i] = hs[i] + 1
            extra = extra - 1
            i = i + 1
            if i > 3 then i = 1 end
        end
    end

    local function make_rect(x, y, w, h)
        return {
            x = math.floor(x), y = math.floor(y),
            w = math.floor(w), h = math.floor(h),
        }
    end
    local function in_rect(px, py, r)
        return px >= r.x and py >= r.y and px < (r.x + r.w) and py < (r.y + r.h)
    end

    local y = 0
    local score_r = make_rect(hud_x + hx, hud_y + y, hw, hs[1])
    y = y + hs[1] + gslot
    local combo_r = make_rect(hud_x + hx, hud_y + y, hw, hs[2])
    y = y + hs[2] + gslot
    local time_r = make_rect(hud_x + hx, hud_y + y, hw, hs[3])
    y = y + hs[3] + gslot
    local rst_r = make_rect(hud_x + hx, hud_y + y, hw, hs[4])
    y = y + hs[4] + gslot
    local exit_r = make_rect(hud_x + hx, hud_y + y, hw, hs[5])
    y = y + hs[5] + gslot
    local st_h = hud_h - y
    if st_h < 1 then st_h = 1 end
    local status_r = make_rect(hud_x + hx, hud_y + y, hw, st_h)

    local cells = {}
    for i = 0, logic.HOLE_COUNT - 1 do
        local col = i % 3
        local row = math.floor(i / 3)
        local bx = gx + col * (hole + GAP)
        local by = gy + row * (hole + GAP)
        if bx < 0 then bx = 0 end
        if by < 0 then by = 0 end
        if bx + hole > play_w then bx = math.max(0, play_w - hole) end
        if by + hole > play_h then by = math.max(0, play_h - hole) end
        cells[i] = {
            bx = bx, by = by,
            hit = make_rect(play_x + bx, play_y + by, hole, hole),
        }
    end

    local function aspect_h(w)
        local h = math.floor(w * SRC_H / SRC_W)
        if h < 1 then h = 1 end
        return h
    end
    local function pick_ow_oh()
        local ow = hole
        if ow > 140 then ow = 140 end
        if ow < 1 then ow = 1 end
        local oh = aspect_h(ow)
        while ow > 1 and ow * oh * 2 > 40960 do
            ow = ow - 1
            oh = aspect_h(ow)
        end
        return ow, oh
    end
    local ow, oh = pick_ow_oh()

    local function cell_sprite_xy(cell, cw, ch)
        local x = cell.bx + math.floor((hole - cw) / 2)
        local y = cell.by + hole - ch
        if x < 0 then x = 0 end
        if y < 0 then y = 0 end
        if x + cw > play_w then x = math.max(0, play_w - cw) end
        if y + ch > play_h then y = math.max(0, play_h - ch) end
        return math.floor(play_x + x), math.floor(play_y + y)
    end

    local mole_src = parse_rgb565(load_blob("mole_sm.rgb565"))
    local bomb_src = parse_rgb565(load_blob("bomb_sm.rgb565"))
    local hole_src = parse_rgb565(load_blob("hole_sm.rgb565"))
    local rst_src = parse_rgb565(load_blob("rst_sm.rgb565"))
    local exit_src = parse_rgb565(load_blob("exit_sm.rgb565"))

    local hole_pix, mole_pix, bomb_pix = nil, nil, nil
    local need = ow * oh * 2
    if hole_src then
        hole_pix = scale_nn(hole_src, ow, oh)
        if type(hole_pix) ~= "string" or #hole_pix ~= need then hole_pix = nil end
    end
    if mole_src then
        mole_pix = scale_nn(mole_src, ow, oh)
        if type(mole_pix) ~= "string" or #mole_pix ~= need then mole_pix = nil end
    end
    if bomb_src then
        bomb_pix = scale_nn(bomb_src, ow, oh)
        if type(bomb_pix) ~= "string" or #bomb_pix ~= need then bomb_pix = nil end
    end

    local function scale_icon(art, bw, bh)
        if art == nil or type(art.pix) ~= "string" then return nil end
        bw = math.floor(tonumber(bw) or 0)
        bh = math.floor(tonumber(bh) or 0)
        if bw < 1 then bw = 1 end
        if bh < 1 then bh = 1 end
        local pad = 4
        if pad * 2 >= math.min(bw, bh) then
            pad = math.max(1, math.floor(math.min(bw, bh) / 6))
        end
        local side = math.min(bw, bh) - 2 * pad
        if side > 40 then side = 40 end
        if side < 1 then side = 1 end
        local sw, sh = art.w, art.h
        if sw < 1 then sw = 1 end
        if sh < 1 then sh = 1 end
        local dw, dh
        if sw >= sh then
            dw = side
            dh = math.max(1, math.floor(side * sh / sw))
        else
            dh = side
            dw = math.max(1, math.floor(side * sw / sh))
        end
        if dw > bw then dw = bw end
        if dh > bh then dh = bh end
        local pix = scale_nn(art, dw, dh)
        if type(pix) ~= "string" or #pix ~= dw * dh * 2 then return nil end
        local cx = math.floor((bw - dw) / 2)
        local cy = math.floor((bh - dh) / 2)
        if cx < 0 then cx = 0 end
        if cy < 0 then cy = 0 end
        return { pix = pix, w = dw, h = dh, cx = cx, cy = cy }
    end
    local rst_sm = scale_icon(rst_src, rst_r.w, rst_r.h)
    local exit_sm = scale_icon(exit_src, exit_r.w, exit_r.h)

    local game = logic.new()
    do
        local t0 = math.floor(tonumber(system.millis()) or 1)
        local t1 = math.floor(tonumber(system.millis()) or 0)
        if t0 < 1 then t0 = 1 end
        if t1 ~= 0 then
            t0 = t0 ~ t1
            if t0 < 1 then t0 = 1 end
        end
        logic.set_seed(game, t0)
    end
    logic.start(game)

    print(string.format(
        "whack web display sim: %dx%d play=%dx%d hole=%d overlay=%dx%d hud=%dx%d",
        width, height, play_w, play_h, hole, ow, oh, hud_w, hud_h))

    local function draw_box(r, title, value)
        pcall(function()
            display.fill_round_rect(r.x, r.y, r.w, r.h, RADIUS, COLORS.panel_bg)
        end)
        pcall(function()
            display.draw_round_rect(r.x, r.y, r.w, r.h, RADIUS, COLORS.border)
        end)
        local ip = clamp(r.w / 10, 8, 18)
        if ip * 2 >= r.w then
            ip = math.max(0, math.floor(r.w / 6))
        end
        local lw = r.w - 2 * ip
        if lw < 1 then
            lw = math.max(1, r.w)
            ip = 0
        end
        if r.h >= FONT_LINE * 2 then
            local title_h = math.floor(r.h * 0.38)
            if title_h < FONT_LINE then title_h = FONT_LINE end
            if title_h + FONT_LINE > r.h then title_h = r.h - FONT_LINE end
            pcall(function()
                display.draw_text_aligned(r.x + ip, r.y, lw, title_h, title, {
                    color = COLORS.dim, font_size = 16,
                    align = "center", valign = "middle",
                })
            end)
            pcall(function()
                display.draw_text_aligned(r.x + ip, r.y + title_h, lw, r.h - title_h,
                    tostring(value), {
                        color = COLORS.text, font_size = 24,
                        align = "center", valign = "middle",
                    })
            end)
        else
            pcall(function()
                display.draw_text_aligned(r.x + ip, r.y, lw, r.h,
                    title .. "  " .. tostring(value), {
                        color = COLORS.text, font_size = 16,
                        align = "center", valign = "middle",
                    })
            end)
        end
    end

    local function draw_hud_btn(r, icon, fallback)
        pcall(function()
            display.fill_round_rect(r.x, r.y, r.w, r.h, RADIUS, COLORS.rst_bg)
        end)
        pcall(function()
            display.draw_round_rect(r.x, r.y, r.w, r.h, RADIUS, COLORS.border)
        end)
        if icon then
            local ok = pcall(function()
                display.draw_pixels(r.x + icon.cx, r.y + icon.cy, icon.pix, {
                    width = icon.w, height = icon.h,
                })
            end)
            if ok then return end
        end
        pcall(function()
            display.draw_text_aligned(r.x, r.y, r.w, r.h, fallback, {
                color = COLORS.text, font_size = 16,
                align = "center", valign = "middle",
            })
        end)
    end

    local function blit(x, y, pix, w, h)
        if type(pix) ~= "string" then return false end
        return pcall(function()
            display.draw_pixels(x, y, pix, { width = w, height = h })
        end)
    end

    local last_hit_key, last_hit_ms = nil, -9999
    local function fire_hit(key, fn)
        local now = math.floor(tonumber(system.millis()) or 0)
        if key == last_hit_key and now > 0 and now - last_hit_ms < 180 then
            return
        end
        last_hit_key = key
        last_hit_ms = now
        fn()
    end

    local function handle_tap(px, py)
        px = math.floor(tonumber(px) or -1)
        py = math.floor(tonumber(py) or -1)
        if in_rect(px, py, rst_r) then
            fire_hit("rst", function() logic.start(game) end)
            return "rst"
        end
        if in_rect(px, py, exit_r) then
            return "exit"
        end
        for i = 0, logic.HOLE_COUNT - 1 do
            if in_rect(px, py, cells[i].hit) then
                fire_hit("h" .. tostring(i), function()
                    if game.state == logic.STATE_FINISHED then
                        logic.start(game)
                    else
                        logic.hit(game, i)
                    end
                end)
                return "hole"
            end
        end
        return nil
    end

    local last_ms = math.floor(tonumber(system.millis()) or 0)
    local frames = 0
    local last_draw_hole, last_draw_kind = -99, nil
    local running = true

    while running do
        local n_ev = 0
        while n_ev < 64 do
            n_ev = n_ev + 1
            local ok_e, ev = pcall(function() return touch.poll() end)
            if not ok_e or ev == nil or ev == false then
                break
            end
            local typ = ev.type or ev.event
            local dragging = ev.dragging
            if typ == "up" or (typ == "down" and not dragging) then
                local px = ev.x or ev.px
                local py = ev.y or ev.py
                if handle_tap(px, py) == "exit" then
                    running = false
                    break
                end
            end
        end
        if not running then break end

        local now_ms = math.floor(tonumber(system.millis()) or 0)
        local dt
        if now_ms > last_ms then
            dt = math.floor(now_ms - last_ms)
            last_ms = now_ms
            if dt < 1 then dt = 16 end
            if dt > 250 then dt = 16 end
        else
            dt = 16
            if now_ms > 0 then last_ms = now_ms end
        end

        logic.update(game, dt)
        frames = frames + 1
        if frames == 1 or frames % 40 == 0 then
            print(string.format("whack tick f=%d elapsed=%d left=%d",
                frames, game.elapsed_ms, logic.remaining_s(game)))
        end

        local kind = "empty"
        local ah = game.active_index
        if ah ~= nil and ah >= 0 then
            kind = logic.hole_kind(game, ah)
        end
        if ah ~= last_draw_hole or kind ~= last_draw_kind then
            last_draw_hole = ah
            last_draw_kind = kind
            local kname = kind
            if kname ~= "mole" and kname ~= "bomb" then kname = "empty" end
            print(string.format("whack draw hole=%s kind=%s",
                tostring(ah), kname))
        end

        pcall(function()
            display.begin_frame({ clear = true, color = COLORS.screen_bg })
        end)

        pcall(function()
            display.fill_round_rect(play_x, play_y, play_w, play_h, RADIUS,
                COLORS.play_bg)
        end)
        pcall(function()
            display.draw_round_rect(play_x, play_y, play_w, play_h, RADIUS,
                COLORS.border)
        end)

        draw_box(score_r, "SCORE", game.score)
        draw_box(combo_r, "COMBO", game.combo)
        draw_box(time_r, "TIME", string.format("%ds", logic.remaining_s(game)))
        draw_hud_btn(rst_r, rst_sm, "RST")
        draw_hud_btn(exit_r, exit_sm, "EXIT")

        for i = 0, logic.HOLE_COUNT - 1 do
            local sx, sy = cell_sprite_xy(cells[i], ow, oh)
            local drew = blit(sx, sy, hole_pix, ow, oh)
            if not drew then
                local cx = math.floor(cells[i].hit.x + hole / 2)
                local cy = math.floor(cells[i].hit.y + hole / 2)
                local rr = math.max(1, math.floor(hole / 2) - 2)
                pcall(function()
                    display.fill_ellipse(cx, cy, rr,
                        math.max(1, math.floor(rr * SRC_H / SRC_W)),
                        COLORS.empty_bg)
                end)
            end
        end

        if ah ~= nil and ah >= 0 then
            local sx, sy = cell_sprite_xy(cells[ah], ow, oh)
            local pix = (kind == "bomb") and bomb_pix or mole_pix
            local drew = blit(sx, sy, pix, ow, oh)
            if not drew then
                local bg = (kind == "bomb") and COLORS.bomb_bg or COLORS.mole_bg
                local cx = math.floor(cells[ah].hit.x + hole / 2)
                local cy = math.floor(cells[ah].hit.y + hole / 2)
                local rr = math.max(1, math.floor(hole / 2) - 2)
                pcall(function()
                    display.fill_ellipse(cx, cy, rr,
                        math.max(1, math.floor(rr * SRC_H / SRC_W)), bg)
                end)
            end
        end

        local st_text = "TAP MOLE"
        local st_color = COLORS.text
        if game.state == logic.STATE_FINISHED then
            st_text = "DONE"
            st_color = COLORS.done
        end
        pcall(function()
            display.draw_text_aligned(status_r.x, status_r.y, status_r.w, status_r.h,
                st_text, {
                    color = st_color, font_size = 16,
                    align = "center", valign = "middle",
                })
        end)

        pcall(function() display.present() end)
        pcall(function() display.end_frame() end)

        pcall(function() delay.delay_ms(16) end)
    end

    pcall(function() display.deinit() end)
end

if EMBEDDED_ASSETS then
    run_web_display_sim()
    return
end

lvgl.init(panel_handle, io_handle, width, height, panel_if, {
    buffer_lines = 40,
    tick_ms = 5,
    task_period_ms = 10,
})

local touch_handle = board_manager.get_lcd_touch_handle("lcd_touch")
if touch_handle ~= nil then
    lvgl.indev_register("touch", touch_handle)
end

local game = logic.new()
do
    local t0 = math.floor(tonumber(system.millis()) or 1)
    local t1 = math.floor(tonumber(system.millis()) or 0)
    if t0 < 1 then t0 = 1 end
    if t1 ~= 0 then
        t0 = t0 ~ t1
        if t0 < 1 then t0 = 1 end
    end
    logic.set_seed(game, t0)
end

local scr = lvgl.create_screen()
pcall(function() scr:set_pos(0, 0) end)
pcall(function() scr:set_size(width, height) end)
scr:set_style({ bg_color = COLORS.screen_bg, pad = 0 })
lock_obj(scr)

-- Chrome scales from the short side so 320x240 still fits and 1024x600
-- is not a tiny island in the middle of the panel.
local short = math.min(width, height)
local PAD = clamp(short / 60, 4, 14)
local GAP = clamp(short / 80, 3, 10)
local RADIUS = clamp(short / 48, 4, 14)
local BORDER = 1
if short >= 400 then BORDER = 2 end
local INNER = GAP
-- Device UI font is NotoSansSC 24px; 28px line boxes leave descent room.
local FONT_LINE = 28

local LAND_RATIO = 1.12
local is_land = width > height * LAND_RATIO
local is_port = height > width * LAND_RATIO

local orient, hud_side
if is_land then
    orient, hud_side = "land", "L"
elseif is_port then
    orient, hud_side = "port", "T"
else
    orient, hud_side = "sq", "T"
end

local function hole_px(pw, ph)
    local iw = pw - 2 * INNER
    local ih = ph - 2 * INNER
    if iw < 3 then iw = pw end
    if ih < 3 then ih = ph end
    local span = math.min(iw, ih)
    local h = math.floor((span - 2 * GAP) / 3)
    if h < 1 then h = math.max(1, math.floor(span / 3)) end
    return h
end

local hud_x, hud_y, hud_w, hud_h
local play_x, play_y, play_w, play_h
local status_x, status_y, status_w, status_h
status_h = 0

if is_land then
    hud_w = math.floor(0.28 * width)
    local min_hud = math.max(56, math.floor(0.18 * width))
    local max_hud = math.max(min_hud, width - 2 * PAD - GAP - 24)
    if hud_w < min_hud then hud_w = min_hud end
    if hud_w > max_hud then hud_w = max_hud end

    play_h = height - 2 * PAD
    if play_h < 1 then play_h = 1 end
    play_w = width - hud_w - 2 * PAD - GAP
    if play_w < 1 then play_w = 1 end
    -- Grow the 3x3 toward min(H-pad, W-hud-pad) by shrinking HUD if needed.
    if play_w < play_h then
        local need = play_h - play_w
        local shrink = hud_w - min_hud
        if shrink > need then shrink = need end
        if shrink > 0 then
            hud_w = hud_w - shrink
            play_w = play_w + shrink
        end
    end
    if play_w < 1 then play_w = 1 end

    hud_x, hud_y = PAD, PAD
    hud_h = height - 2 * PAD
    if hud_h < 1 then hud_h = 1 end
    play_x = PAD + hud_w + GAP
    play_y = PAD
else
    hud_h = clamp(short / 12, 28, 52)
    local status_want = clamp(short / 20, 16, 32)
    hud_x, hud_y = PAD, PAD
    hud_w = width - 2 * PAD
    if hud_w < 1 then hud_w = 1 end
    play_x = PAD
    play_y = PAD + hud_h + GAP
    play_w = width - 2 * PAD
    if play_w < 1 then play_w = 1 end
    local remain_h = height - play_y - PAD
    if remain_h < 1 then remain_h = 1 end
    local st = status_want
    if remain_h - st - GAP < 24 then
        st = remain_h - GAP - 24
        if st < 0 then st = 0 end
    end
    if st < 12 then
        status_h = 0
        play_h = remain_h
    else
        status_h = st
        play_h = remain_h - GAP - status_h
    end
    if play_h < 1 then play_h = 1 end
    if status_h > 0 then
        status_x = PAD
        status_y = play_y + play_h + GAP
        status_w = width - 2 * PAD
        if status_w < 1 then status_w = 1 end
    end
end

-- Never let a computed min-size overflow the parent panel.
if hud_x < 0 then hud_x = 0 end
if hud_y < 0 then hud_y = 0 end
if play_x < 0 then play_x = 0 end
if play_y < 0 then play_y = 0 end
if hud_w < 1 then hud_w = 1 end
if hud_h < 1 then hud_h = 1 end
if play_w < 1 then play_w = 1 end
if play_h < 1 then play_h = 1 end
if hud_x + hud_w > width then hud_w = math.max(1, width - hud_x) end
if hud_y + hud_h > height then hud_h = math.max(1, height - hud_y) end
if play_x + play_w > width then play_w = math.max(1, width - play_x) end
if play_y + play_h > height then play_h = math.max(1, height - play_y) end
if status_h > 0 then
    if status_x < 0 then status_x = 0 end
    if status_y < 0 then status_y = 0 end
    if status_w < 1 then status_w = 1 end
    if status_x + status_w > width then status_w = math.max(1, width - status_x) end
    if status_y + status_h > height then status_h = math.max(1, height - status_y) end
end

local hole = hole_px(play_w, play_h)
local grid = 3 * hole + 2 * GAP
if grid > play_w or grid > play_h then
    local cap = math.min(play_w, play_h)
    hole = math.max(1, math.floor((cap - 2 * INNER - 2 * GAP) / 3))
    grid = 3 * hole + 2 * GAP
    if grid > cap then
        hole = math.max(1, math.floor(cap / 3))
        grid = 3 * hole
    end
end
local gx = math.floor((play_w - grid) / 2)
local gy = math.floor((play_h - grid) / 2)
if gx < 0 then gx = 0 end
if gy < 0 then gy = 0 end


local HUD_IN = clamp(hud_w / 12, 6, 16)
if HUD_IN * 2 >= hud_w then
    HUD_IN = math.max(0, math.floor(hud_w / 20))
end
local hx = HUD_IN
local hw = hud_w - 2 * HUD_IN
if hw < 1 then
    hw = math.max(1, hud_w)
    hx = 0
end

local hud = mk("container", scr, {
    x = hud_x, y = hud_y, w = hud_w, h = hud_h,
    bg_color = COLORS.screen_bg, pad = 0,
})

local play = mk("container", scr, {
    x = play_x, y = play_y, w = play_w, h = play_h,
    bg_color = COLORS.play_bg, radius = RADIUS,
    border_color = COLORS.border, border_width = BORDER, pad = 0,
})

local function info_box(parent, x, y, w, h, title, value)
    if x < 0 then x = 0 end
    if y < 0 then y = 0 end
    if w < 1 then w = 1 end
    if h < 1 then h = 1 end
    local box = mk("container", parent, {
        x = x, y = y, w = w, h = h,
        bg_color = COLORS.panel_bg, radius = RADIUS,
        border_color = COLORS.border, border_width = BORDER, pad = 0,
    })
    local ip = clamp(w / 10, 8, 18)
    if ip * 2 >= w then
        ip = math.max(0, math.floor(w / 6))
    end
    local lw = w - 2 * ip
    if lw < 1 then
        lw = math.max(1, w)
        ip = 0
    end
    local function hud_label(yy, hh, text, color)
        local o = mk("label", box, {
            x = ip, y = yy, w = lw, h = hh,
            text = text, text_color = color, pad = 0,
            align = "center",
        })
        return center_text(o)
    end
    -- Two 24px-font lines need ~28px each. Too-short boxes use one combined
    -- centered label (title prefix kept so set_text still works).
    if h >= FONT_LINE * 2 then
        local title_h = math.floor(h * 0.38)
        if title_h < FONT_LINE then title_h = FONT_LINE end
        if title_h + FONT_LINE > h then title_h = h - FONT_LINE end
        hud_label(0, title_h, title, COLORS.dim)
        return hud_label(title_h, h - title_h, value, COLORS.text)
    end
    local val = hud_label(0, h, title .. "  " .. value, COLORS.text)
    pcall(function() val._title = title end)
    obj_extra[val] = obj_extra[val] or {}
    obj_extra[val].title = title
    return val
end

local function set_info(label, value)
    local meta = obj_extra[label]
    local title = meta and meta.title or nil
    if title == nil then
        local ok, t = pcall(function() return label._title end)
        if ok then title = t end
    end
    if title then
        safe_set_text(label, title .. "  " .. tostring(value))
    else
        safe_set_text(label, tostring(value))
    end
end

local label_score, label_combo, label_time, btn_rst, btn_exit, label_status
local rst_bw, rst_bh, exit_bw, exit_bh = 1, 1, 1, 1
local rst_icon, exit_icon = nil, nil
local running = true

if is_land then
    -- 6 slots: SCORE, COMBO, TIME, RST, EXIT, status.
    -- Info boxes get extra height; status is first to shrink.
    local n = 6
    local g = GAP
    if g * (n - 1) >= hud_h then g = 0 end
    local body = hud_h - g * (n - 1)
    if body < n then
        g = 0
        body = hud_h
    end
    local st_min = 14
    local btn_min = 24
    local info_want = FONT_LINE * 2
    local st = FONT_LINE
    if st > body - 5 then st = math.max(1, math.floor(body / n)) end
    local btn = math.max(btn_min, math.floor(body * 0.13))
    local info = math.floor((body - st - 2 * btn) / 3)
    if info < 1 then info = 1 end
    if info < info_want then
        local steal = st - st_min
        if steal < 0 then steal = 0 end
        local need = (info_want - info) * 3
        if steal > need then steal = need end
        if steal > 0 then
            st = st - steal
            info = math.floor((body - st - 2 * btn) / 3)
        end
    end
    if info < info_want then
        local need = (info_want - info) * 3
        local room = 2 * (btn - btn_min)
        if room < 0 then room = 0 end
        if room > 0 then
            local steal = need
            if steal > room then steal = room end
            btn = btn - math.floor(steal / 2)
            if btn < btn_min then btn = btn_min end
            info = math.floor((body - st - 2 * btn) / 3)
        end
    end
    if info < 1 then info = 1 end
    if btn < 1 then btn = 1 end
    if st < 1 then st = 1 end
    local hs = { info, info, info, btn, btn, st }
    local sum = g * (n - 1)
    for i = 1, n do
        if hs[i] < 1 then hs[i] = 1 end
        sum = sum + hs[i]
    end
    local extra = sum - hud_h
    if extra > 0 then
        -- Overflow: shrink status first, then buttons, then info.
        for i = n, 1, -1 do
            local take = hs[i] - 1
            if take > extra then take = extra end
            if take > 0 then
                hs[i] = hs[i] - take
                extra = extra - take
            end
            if extra <= 0 then break end
        end
    elseif extra < 0 then
        extra = -extra
        local i = 1
        while extra > 0 do
            hs[i] = hs[i] + 1
            extra = extra - 1
            i = i + 1
            if i > 3 then i = 1 end
        end
    end
    local y = 0
    label_score = info_box(hud, hx, y, hw, hs[1], "SCORE", "0")
    y = y + hs[1] + g
    label_combo = info_box(hud, hx, y, hw, hs[2], "COMBO", "0")
    y = y + hs[2] + g
    label_time  = info_box(hud, hx, y, hw, hs[3], "TIME", "30s")
    y = y + hs[3] + g
    btn_rst = mk("button", hud, {
        text = "",
        x = hx, y = y, w = hw, h = hs[4],
        bg_color = COLORS.rst_bg, radius = RADIUS,
        border_color = COLORS.border, border_width = 1, pad = 0,
    })
    safe_set_text(btn_rst, "")
    safe_role(btn_rst, "rst")
    safe_set_style(btn_rst, { text_color = COLORS.text })
    rst_bw, rst_bh = hw, hs[4]
    y = y + hs[4] + g
    btn_exit = mk("button", hud, {
        text = "",
        x = hx, y = y, w = hw, h = hs[5],
        bg_color = COLORS.rst_bg, radius = RADIUS,
        border_color = COLORS.border, border_width = 1, pad = 0,
    })
    safe_set_text(btn_exit, "")
    safe_role(btn_exit, "exit")
    safe_set_style(btn_exit, { text_color = COLORS.text })
    exit_bw, exit_bh = hw, hs[5]
    y = y + hs[5] + g
    local st_h = hud_h - y
    if st_h < 1 then st_h = 1 end
    label_status = center_text(mk("label", hud, {
        x = hx, y = y, w = hw, h = st_h,
        text = "TAP MOLE",
        text_color = COLORS.text, pad = 0,
        align = "center",
    }))
    print(string.format(
        "whack land slots: SCORE=%d COMBO=%d TIME=%d RST=%d EXIT=%d status=%d title_h>=%d",
        hs[1], hs[2], hs[3], hs[4], hs[5], st_h,
        (hs[1] >= FONT_LINE * 2) and FONT_LINE or hs[1]))
else
    local g = GAP
    local btn_w = clamp(hud_h * 1.5, 26, math.floor(hw * 0.18))
    if g * 4 + 2 * btn_w + 3 > hw then
        g = 0
        btn_w = math.max(16, math.floor(hw * 0.16))
    end
    local body = hw - 2 * btn_w - g * 4
    if body < 3 then
        g = 0
        btn_w = math.max(1, math.floor((hw - 3) / 5))
        body = hw - 2 * btn_w
    end
    local box_w = math.floor(body / 3)
    if box_w < 1 then box_w = 1 end
    local x = hx
    local hud_right = hx + hw
    label_score = info_box(hud, x, 0, box_w, hud_h, "SCORE", "0")
    x = x + box_w + g
    label_combo = info_box(hud, x, 0, box_w, hud_h, "COMBO", "0")
    x = x + box_w + g
    label_time  = info_box(hud, x, 0, box_w, hud_h, "TIME", "30s")
    x = x + box_w + g
    local remain = hud_right - x
    if remain < 2 then remain = 2 end
    local rst_w = math.floor((remain - g) / 2)
    if rst_w < 1 then rst_w = 1 end
    btn_rst = mk("button", hud, {
        text = "",
        x = x, y = 0, w = rst_w, h = hud_h,
        bg_color = COLORS.rst_bg, radius = RADIUS,
        border_color = COLORS.border, border_width = 1, pad = 0,
    })
    safe_set_text(btn_rst, "")
    safe_role(btn_rst, "rst")
    safe_set_style(btn_rst, { text_color = COLORS.text })
    rst_bw, rst_bh = rst_w, hud_h
    x = x + rst_w + g
    local ex_w = hud_right - x
    if ex_w < 1 then ex_w = 1 end
    btn_exit = mk("button", hud, {
        text = "",
        x = x, y = 0, w = ex_w, h = hud_h,
        bg_color = COLORS.rst_bg, radius = RADIUS,
        border_color = COLORS.border, border_width = 1, pad = 0,
    })
    safe_set_text(btn_exit, "")
    safe_role(btn_exit, "exit")
    safe_set_style(btn_exit, { text_color = COLORS.text })
    exit_bw, exit_bh = ex_w, hud_h

    if status_h > 0 then
        local sx = status_x + HUD_IN
        local sw = status_w - 2 * HUD_IN
        if sw < 1 then
            sw = math.max(1, status_w)
            sx = status_x
        end
        label_status = center_text(mk("label", scr, {
            x = sx, y = status_y, w = sw, h = status_h,
            text = "TAP MOLE",
            text_color = COLORS.text, pad = 0,
            align = "center",
        }))
    else
        -- No room for a footer strip: reuse a 1-line label inside HUD
        -- at y>=0 without overflowing (bottom-right 1px is last resort).
        label_status = center_text(mk("label", hud, {
            x = hx, y = 0, w = math.max(1, math.floor(hw / 8)),
            h = math.max(1, math.floor(hud_h / 8)),
            text = "TAP MOLE",
            text_color = COLORS.text, pad = 0,
            align = "center",
        }))
    end
end


local show_hole_text = hole >= 36
local holes = {}
local painted = {}
local overlay = nil
local overlay_w, overlay_h = 0, 0
local overlay_mole, overlay_bomb = nil, nil
local overlay_on = -1
local SRC_W, SRC_H = 48, 38

local function bind_hit(obj, idx)
    if obj == nil then return end
    pcall(function()
        obj:on("clicked", function()
            if game.state == logic.STATE_FINISHED then
                logic.start(game)
                return
            end
            logic.hit(game, idx)
        end)
    end)
end

local function paint_color(slot, kind)
    local bg, fg, text = kind_style(kind)
    if not show_hole_text then text = "" end
    slot.btn:set_style({
        bg_color = bg, bg_opa = 255, radius = math.floor(hole / 2),
        border_color = COLORS.border, border_width = 2,
        text_color = fg,
    })
    safe_set_text(slot.btn, text)
end

local function load_sprites()
    local mole = parse_rgb565(load_blob("mole_sm.rgb565"))
    local bomb = parse_rgb565(load_blob("bomb_sm.rgb565"))
    local hole_art = parse_rgb565(load_blob("hole_sm.rgb565"))
    return mole, bomb, hole_art
end

local cells = {}
for i = 0, logic.HOLE_COUNT - 1 do
    local col = i % 3
    local row = math.floor(i / 3)
    local bx = gx + col * (hole + GAP)
    local by = gy + row * (hole + GAP)
    if bx < 0 then bx = 0 end
    if by < 0 then by = 0 end
    if bx + hole > play_w then bx = math.max(0, play_w - hole) end
    if by + hole > play_h then by = math.max(0, play_h - hole) end
    cells[i] = { bx = bx, by = by }
end

local function clamp_in_play(x, y, w, h)
    if x < 0 then x = 0 end
    if y < 0 then y = 0 end
    if x + w > play_w then x = math.max(0, play_w - w) end
    if y + h > play_h then y = math.max(0, play_h - h) end
    return x, y
end

local function cell_canvas_xy(cell, cw, ch)
    local x = cell.bx + math.floor((hole - cw) / 2)
    local y = cell.by + hole - ch
    return clamp_in_play(x, y, cw, ch)
end

local function aspect_h(w)
    local h = math.floor(w * SRC_H / SRC_W)
    if h < 1 then h = 1 end
    return h
end

local function pick_overlay_size()
    local ow = hole
    if ow > 140 then ow = 140 end
    if ow < 1 then ow = 1 end
    local oh = aspect_h(ow)
    while ow > 1 and ow * oh * 2 > 40960 do
        ow = ow - 1
        oh = aspect_h(ow)
    end
    return ow, oh
end

local function unhide_cv(cv)
    if cv == nil then return end
    pcall(function() cv:clear_flag("HIDDEN") end)
    pcall(function() cv:clear_flag("LV_OBJ_FLAG_HIDDEN") end)
end

local function hide_cv(cv)
    if cv == nil then return end
    pcall(function() cv:add_flag("HIDDEN") end)
    pcall(function() cv:add_flag("LV_OBJ_FLAG_HIDDEN") end)
end

local function paint_hole(i, kind)
    local slot = holes[i]
    if slot == nil then return end
    if painted[i] == kind then return end
    painted[i] = kind
    if overlay then
        if kind == "mole" or kind == "bomb" then
            if overlay_on >= 0 and overlay_on ~= i then
                local prev = holes[overlay_on]
                if prev and prev.oval then
                    unhide_cv(prev.oval)
                end
            end
            local ox, oy = cell_canvas_xy(cells[i], overlay_w, overlay_h)
            pcall(function() overlay:set_pos(ox, oy) end)
            local pix = (kind == "bomb") and overlay_bomb or overlay_mole
            if pix then
                pcall(function() overlay:set_rgb565_data(pix, "le") end)
            end
            unhide_cv(overlay)
            if slot.oval then hide_cv(slot.oval) end
            overlay_on = i
        else
            if overlay_on == i then
                hide_cv(overlay)
                overlay_on = -1
            end
            if slot.oval then unhide_cv(slot.oval) end
        end
    else
        paint_color(slot, kind)
    end
end

local ovals = {}
do
    local mole, bomb, hole_art = load_sprites()
    if mole and bomb then
        local ow, oh = pick_overlay_size()
        local om = scale_nn(mole, ow, oh)
        local ob = scale_nn(bomb, ow, oh)
        local ohole = nil
        if hole_art then
            ohole = scale_nn(hole_art, ow, oh)
        end
        local need = ow * oh * 2
        if type(om) == "string" and type(ob) == "string"
            and #om == need and #ob == need then
            -- Hole canvases first, overlay last so the mole sits on top.
            if type(ohole) == "string" and #ohole == need then
                for i = 0, logic.HOLE_COUNT - 1 do
                    local hx, hy = cell_canvas_xy(cells[i], ow, oh)
                    local okh, hv = pcall(function()
                        return lvgl.canvas(play, {
                            x = hx, y = hy, w = ow, h = oh,
                            color_format = "rgb565",
                            bg_color = COLORS.play_bg,
                        })
                    end)
                    if okh and hv ~= nil then
                        lock_obj(hv)
                        local okd = pcall(function()
                            hv:set_rgb565_data(ohole, "le")
                        end)
                        if okd then
                            ovals[i] = hv
                            bind_hit(hv, i)
                        else
                            pcall(function() hv:delete() end)
                        end
                    end
                end
            end
            local ox, oy = cell_canvas_xy(cells[0], ow, oh)
            local ok, cv = pcall(function()
                return lvgl.canvas(play, {
                    x = ox, y = oy, w = ow, h = oh,
                    color_format = "rgb565",
                    bg_color = COLORS.play_bg,
                })
            end)
            if ok and cv ~= nil then
                lock_obj(cv)
                local okd = pcall(function()
                    cv:set_rgb565_data(om, "le")
                end)
                if okd then
                    hide_cv(cv)
                    pcall(function() cv:set_pos(-ow, -oh) end)
                    overlay = cv
                    overlay_w, overlay_h = ow, oh
                    overlay_mole, overlay_bomb = om, ob
                else
                    pcall(function() cv:add_flag("HIDDEN") end)
                    pcall(function() cv:delete() end)
                end
            end
        end
    end
end

if overlay then
    local oval_r = math.floor(overlay_h / 2)
    if oval_r < 1 then oval_r = 1 end
    for i = 0, logic.HOLE_COUNT - 1 do
        if ovals[i] == nil then
            local ox, oy = cell_canvas_xy(cells[i], overlay_w, overlay_h)
            local ov = mk("container", play, {
                x = ox, y = oy, w = overlay_w, h = overlay_h,
                bg_color = COLORS.empty_bg, radius = oval_r,
                border_width = 0, pad = 0,
            })
            bind_hit(ov, i)
            ovals[i] = ov
        end
    end
end

for i = 0, logic.HOLE_COUNT - 1 do
    local bx, by = cells[i].bx, cells[i].by
    local btn
    if overlay then
        btn = mk("button", play, {
            x = bx, y = by, w = hole, h = hole,
            bg_color = COLORS.play_bg, radius = 0,
            border_width = 0, pad = 0, bg_opa = 1,
        })
        safe_set_text(btn, "")
        btn:set_style({
            bg_color = COLORS.play_bg, bg_opa = 1, radius = 0,
            border_width = 0,
        })
        painted[i] = "empty"
    else
        btn = mk("button", play, {
            x = bx, y = by, w = hole, h = hole,
            bg_color = COLORS.empty_bg, radius = math.floor(hole / 2),
            border_color = COLORS.border, border_width = 2, pad = 0,
        })
        safe_set_text(btn, "")
        painted[i] = nil
    end
    bind_hit(btn, i)
    holes[i] = { btn = btn, x = bx, y = by, oval = ovals[i] }
    if not overlay then
        paint_color(holes[i], "empty")
    end
end

if overlay then
    pcall(function()
        overlay:on("clicked", function()
            if game.state == logic.STATE_FINISHED then
                logic.start(game)
                return
            end
            logic.hit(game, game.active_index)
        end)
    end)
end

local function decorate_hud_btn(btn, art, bw, bh, fallback)
    if btn == nil then return nil end
    pcall(function() btn:set_text("") end)
    if art == nil or type(art.pix) ~= "string" then
        pcall(function() btn:set_text(fallback) end)
        return nil
    end
    bw = math.floor(tonumber(bw) or 0)
    bh = math.floor(tonumber(bh) or 0)
    if bw < 1 then bw = 1 end
    if bh < 1 then bh = 1 end
    local pad = 4
    if pad * 2 >= math.min(bw, bh) then
        pad = math.max(1, math.floor(math.min(bw, bh) / 6))
    end
    local side = math.min(bw, bh) - 2 * pad
    if side > 40 then side = 40 end
    if side < 1 then side = 1 end
    local sw, sh = art.w, art.h
    if sw < 1 then sw = 1 end
    if sh < 1 then sh = 1 end
    local dw, dh
    if sw >= sh then
        dw = side
        dh = math.max(1, math.floor(side * sh / sw))
    else
        dh = side
        dw = math.max(1, math.floor(side * sw / sh))
    end
    if dw > bw then dw = bw end
    if dh > bh then dh = bh end
    local pix = scale_nn(art, dw, dh)
    if type(pix) ~= "string" or #pix ~= dw * dh * 2 then
        pcall(function() btn:set_text(fallback) end)
        return nil
    end
    local cx = math.floor((bw - dw) / 2)
    local cy = math.floor((bh - dh) / 2)
    if cx < 0 then cx = 0 end
    if cy < 0 then cy = 0 end
    local ok, cv = pcall(function()
        return lvgl.canvas(btn, {
            x = cx, y = cy, w = dw, h = dh,
            color_format = "rgb565",
            bg_color = COLORS.rst_bg,
        })
    end)
    if not ok or cv == nil then
        pcall(function() btn:set_text(fallback) end)
        return nil
    end
    lock_obj(cv)
    local okd = pcall(function()
        cv:set_rgb565_data(pix, "le")
    end)
    if not okd then
        pcall(function() cv:add_flag("HIDDEN") end)
        pcall(function() cv:delete() end)
        pcall(function() btn:set_text(fallback) end)
        return nil
    end
    pcall(function() cv:align("center", 0, 0) end)
    pcall(function() cv:clear_flag("CLICKABLE") end)
    pcall(function() cv:clear_flag("LV_OBJ_FLAG_CLICKABLE") end)
    return cv
end

rst_icon = decorate_hud_btn(
    btn_rst, parse_rgb565(load_blob("rst_sm.rgb565")), rst_bw, rst_bh, "RST")
exit_icon = decorate_hud_btn(
    btn_exit, parse_rgb565(load_blob("exit_sm.rgb565")), exit_bw, exit_bh, "EXIT")

local art_note
if overlay then
    art_note = string.format("art=overlay %dx%d oval=%dx%d",
        overlay_w, overlay_h, overlay_w, overlay_h)
else
    art_note = "art=off"
end
print(string.format("whack: %dx%d holes=%d %s hud=%s play=%dx%d hole=%d %s",
    width, height, logic.HOLE_COUNT, orient, hud_side, play_w, play_h, hole,
    art_note))


local function on_rst()
    logic.start(game)
end

local function on_exit()
    running = false
end

btn_rst:on("clicked", on_rst)
btn_exit:on("clicked", on_exit)
if rst_icon then
    pcall(function() rst_icon:on("clicked", on_rst) end)
end
if exit_icon then
    pcall(function() exit_icon:on("clicked", on_exit) end)
end

local last_score, last_combo, last_time, last_state = nil, nil, nil, nil

local function refresh()
    local st = game.state
    if game.score ~= last_score then
        last_score = game.score
        set_info(label_score, game.score)
    end
    if game.combo ~= last_combo then
        last_combo = game.combo
        set_info(label_combo, game.combo)
    end
    local tleft = logic.remaining_s(game)
    if tleft ~= last_time then
        last_time = tleft
        set_info(label_time, string.format("%ds", tleft))
    end
    if st ~= last_state then
        last_state = st
        if st == logic.STATE_FINISHED then
            safe_set_text(label_status, "DONE")
            label_status:set_style({ text_color = COLORS.done })
        else
            safe_set_text(label_status, "TAP MOLE")
            label_status:set_style({ text_color = COLORS.text })
        end
        center_text(label_status)
    end
    for i = 0, logic.HOLE_COUNT - 1 do
        paint_hole(i, logic.hole_kind(game, i))
    end
end

-- Hosted simulator may freeze system.millis, os.clock, AND delay.delay_ms
-- (lv_tick_inc is never called). Never busy-wait on those clocks.
local function wall_ms()
    local t = math.floor(tonumber(system.millis()) or 0)
    if t > 0 then return t end
    if os and os.clock then
        local c = os.clock()
        if type(c) == "number" and c > 0 then
            return math.floor(c * 1000)
        end
    end
    return 0
end

local function wait_frame(clock_ok)
    if clock_ok then
        pcall(function() delay.delay_ms(16) end)
        return
    end
    pcall(function() lvgl.process_events(0) end)
end

scr:load()
logic.start(game)
refresh()

local last_ms = wall_ms()
local clock_ok = last_ms > 0
local frames = 0
while running do
    pcall(function() lvgl.process_events(0) end)
    local now_ms = wall_ms()
    local dt
    if clock_ok and now_ms > last_ms then
        dt = math.floor(now_ms - last_ms)
        last_ms = now_ms
        if dt < 1 then dt = 16 end
        if dt > 250 then dt = 16 end
    else
        clock_ok = false
        dt = 16
    end
    logic.update(game, dt)
    frames = frames + 1
    if frames == 1 or frames % 40 == 0 then
        print(string.format("whack tick f=%d elapsed=%d left=%d",
            frames, game.elapsed_ms, logic.remaining_s(game)))
    end
    refresh()
    wait_frame(clock_ok)
end
pcall(function()
    if lvgl.deinit then lvgl.deinit() end
end)
