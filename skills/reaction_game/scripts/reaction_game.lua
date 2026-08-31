-- reaction_game.lua: playable Rapid Tap / reaction-time v1 for esp-claw.
-- LVGL widgets only. HUD icons are 32x32 RGB565 canvases (same as whack).
-- Full-rectangle adaptive layout: landscape HUD column, portrait/square top HUD.
-- Does not use circular-bezel / inscribed-square geometry.

local board_manager = require("board_manager")
local delay = require("delay")
local lvgl = require("lvgl")
local system = require("system")
local logic = require("reaction_logic")

local COLORS = {
    screen_bg = "#F3EDCD",
    panel_bg  = "#FAFBF5",
    border    = "#000000",
    text      = "#1F2A1F",
    dim       = "#6B7A8D",
    rst_bg    = "#FEFDF9",
    wait      = "#EED964",
    ready     = "#65C873",
    oops      = "#EF8670",
    done      = "#C25E00",
}

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

-- FatFS-safe assets dir: skill_root/assets from this script's source.
-- Never join scripts/../assets (SquareLine / FatFS reject that form).
local function resolve_assets_dir()
    local src
    pcall(function()
        local info = debug.getinfo(1, "S")
        if info then src = info.source end
    end)
    if type(src) == "string" then
        if src:sub(1, 1) == "@" then src = src:sub(2) end
        src = src:gsub("\\", "/")
        local skill_root = src:match("^(.*)/scripts/[^/]+$")
        if skill_root and skill_root ~= "" then
            return skill_root .. "/assets"
        end
    end
    return "/fatfs/skills/reaction_game/assets"
end

local function join_path(dir, name)
    dir = tostring(dir or ""):gsub("\\", "/")
    if dir == "" then
        return name
    end
    if dir:sub(-1) == "/" then
        return dir .. name
    end
    return dir .. "/" .. name
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

local function load_hud_art(stem)
    local dirs = {
        resolve_assets_dir(),
        "/fatfs/skills/reaction_game/assets",
        "/skills/reaction_game/assets",
    }
    local seen = {}
    for _, d in ipairs(dirs) do
        local p = join_path(d, stem .. ".rgb565")
        if not seen[p] then
            seen[p] = true
            local art = parse_rgb565(read_all(p))
            if art then
                print("reaction art " .. stem .. " -> " .. p)
                return art
            end
        end
    end
    print("reaction art " .. stem .. " missing")
    return nil
end

local ART = {
    rst = load_hud_art("Restart"),
    exit = load_hud_art("Exit"),
}
local use_art = (ART.rst ~= nil) or (ART.exit ~= nil)

local panel_handle, io_handle, width, height, panel_if =
    board_manager.get_display_lcd_params("display_lcd")

width = math.floor(tonumber(width) or 0)
height = math.floor(tonumber(height) or 0)
if width < 64 then width = 240 end
if height < 64 then height = 240 end

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
logic.set_seed(game, math.floor(tonumber(system.millis()) or 1))

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

local hud_x, hud_y, hud_w, hud_h
local play_x, play_y, play_w, play_h
local status_x, status_y, status_w, status_h
status_h = 0

if is_land then
    hud_w = math.floor(0.26 * width)
    -- Keep room for centered 24px words (ROUND/FALSE) plus inset.
    local min_hud = math.max(96, FONT_LINE * 4, math.floor(0.20 * width))
    local play_min = math.max(160, math.floor(0.55 * width))
    local max_hud = math.max(min_hud, width - 2 * PAD - GAP - play_min)
    if hud_w < min_hud then hud_w = min_hud end
    if hud_w > max_hud then hud_w = max_hud end

    play_h = height - 2 * PAD
    if play_h < 1 then play_h = 1 end
    play_w = width - hud_w - 2 * PAD - GAP
    if play_w < 1 then play_w = 1 end

    hud_x, hud_y = PAD, PAD
    hud_h = height - 2 * PAD
    if hud_h < 1 then hud_h = 1 end
    play_x = PAD + hud_w + GAP
    play_y = PAD
else
    hud_h = clamp(short / 10, FONT_LINE + 6, 72)
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

print(string.format("reaction: %dx%d %s hud=%s play=%dx%d",
    width, height, orient, hud_side, play_w, play_h))

local hud = mk("container", scr, {
    x = hud_x, y = hud_y, w = hud_w, h = hud_h,
    bg_color = COLORS.screen_bg, pad = 0,
})

-- Play area is a button so the whole remaining rectangle is tappable.
local play = mk("button", scr, {
    x = play_x, y = play_y, w = play_w, h = play_h,
    bg_color = COLORS.wait, radius = RADIUS,
    border_color = COLORS.border, border_width = BORDER, pad = 0,
})
play:set_text("")

local info_titles = {}

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
    -- Inset so 24px glyphs are not flush against the 1-2px border.
    -- align=center is object align; text_align is what actually centers glyphs.
    local inset = clamp(w / 8, 8, 18)
    if inset * 2 >= w then inset = math.max(2, math.floor(w / 6)) end
    local lw = w - 2 * inset
    if lw < 1 then
        lw = math.max(1, w)
        inset = 0
    end
    local function hud_label(yy, hh, text, color)
        local o = mk("label", box, {
            x = inset, y = yy, w = lw, h = hh,
            text = text, text_color = color, pad = 0,
            align = "center",
        })
        pcall(function()
            o:set_style({
                text_align = "center",
                align = "center",
                pad = 0,
                pad_left = 0,
                pad_right = 0,
            })
        end)
        return o
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
    info_titles[val] = title
    return val
end

local function set_info(label, value)
    local prefix = info_titles[label]
    if prefix then
        label:set_text(prefix .. "  " .. tostring(value))
    else
        label:set_text(tostring(value))
    end
end

local label_round, label_best, label_false, btn_rst, btn_exit, label_status
local running = true

if is_land then
    -- 6 slots: ROUND, BEST, FALSE, RST, EXIT, status.
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
    label_round = info_box(hud, 0, y, hud_w, hs[1], "ROUND", "1/5")
    y = y + hs[1] + g
    label_best  = info_box(hud, 0, y, hud_w, hs[2], "BEST", "--")
    y = y + hs[2] + g
    label_false = info_box(hud, 0, y, hud_w, hs[3], "FALSE", "0")
    y = y + hs[3] + g
    btn_rst = mk("button", hud, {
        x = 0, y = y, w = hud_w, h = hs[4],
        bg_color = COLORS.rst_bg, radius = RADIUS,
        border_color = COLORS.border, border_width = 1, pad = 0,
    })
    btn_rst:set_text("RST")
    btn_rst:set_style({ text_color = COLORS.text })
    y = y + hs[4] + g
    btn_exit = mk("button", hud, {
        x = 0, y = y, w = hud_w, h = hs[5],
        bg_color = COLORS.rst_bg, radius = RADIUS,
        border_color = COLORS.border, border_width = 1, pad = 0,
    })
    btn_exit:set_text("EXIT")
    btn_exit:set_style({ text_color = COLORS.text })
    y = y + hs[5] + g
    local st_h = hud_h - y
    if st_h < 1 then st_h = 1 end
    label_status = mk("label", hud, {
        x = 0, y = y, w = hud_w, h = st_h,
        text = "WAIT",
        text_color = COLORS.text, pad = 0,
        align = "center",
    })
    print(string.format(
        "reaction land slots: ROUND=%d BEST=%d FALSE=%d RST=%d EXIT=%d status=%d title_h>=%d",
        hs[1], hs[2], hs[3], hs[4], hs[5], st_h,
        (hs[1] >= FONT_LINE * 2) and FONT_LINE or hs[1]))
else
    local g = GAP
    local btn_w = clamp(hud_h * 1.5, 26, math.floor(hud_w * 0.18))
    if g * 4 + 2 * btn_w + 3 > hud_w then
        g = 0
        btn_w = math.max(16, math.floor(hud_w * 0.16))
    end
    local body = hud_w - 2 * btn_w - g * 4
    if body < 3 then
        g = 0
        btn_w = math.max(1, math.floor((hud_w - 3) / 5))
        body = hud_w - 2 * btn_w
    end
    local box_w = math.floor(body / 3)
    if box_w < 1 then box_w = 1 end
    local x = 0
    label_round = info_box(hud, x, 0, box_w, hud_h, "ROUND", "1/5")
    x = x + box_w + g
    label_best  = info_box(hud, x, 0, box_w, hud_h, "BEST", "--")
    x = x + box_w + g
    label_false = info_box(hud, x, 0, box_w, hud_h, "FALSE", "0")
    x = x + box_w + g
    local remain = hud_w - x
    if remain < 2 then remain = 2 end
    local rst_w = math.floor((remain - g) / 2)
    if rst_w < 1 then rst_w = 1 end
    btn_rst = mk("button", hud, {
        x = x, y = 0, w = rst_w, h = hud_h,
        bg_color = COLORS.rst_bg, radius = RADIUS,
        border_color = COLORS.border, border_width = 1, pad = 0,
    })
    btn_rst:set_text("RST")
    btn_rst:set_style({ text_color = COLORS.text })
    x = x + rst_w + g
    local ex_w = hud_w - x
    if ex_w < 1 then ex_w = 1 end
    btn_exit = mk("button", hud, {
        x = x, y = 0, w = ex_w, h = hud_h,
        bg_color = COLORS.rst_bg, radius = RADIUS,
        border_color = COLORS.border, border_width = 1, pad = 0,
    })
    btn_exit:set_text("EXIT")
    btn_exit:set_style({ text_color = COLORS.text })

    if status_h > 0 then
        label_status = mk("label", scr, {
            x = status_x, y = status_y, w = status_w, h = status_h,
            text = "WAIT",
            text_color = COLORS.text, pad = 0,
            align = "center",
        })
    else
        label_status = mk("label", hud, {
            x = 0, y = 0, w = math.max(1, math.floor(hud_w / 8)),
            h = math.max(1, math.floor(hud_h / 8)),
            text = "WAIT",
            text_color = COLORS.text, pad = 0,
            align = "center",
        })
    end
end

local function decorate_hud_btn(btn, art)
    if not use_art or btn == nil or art == nil then return end
    if type(lvgl.canvas) ~= "function" then return end
    local ok, cv = pcall(function()
        return lvgl.canvas(btn, {
            x = 4, y = 4, w = art.w, h = art.h,
            color_format = "rgb565",
            bg_color = COLORS.rst_bg,
        })
    end)
    if not ok or cv == nil then return end
    local okd = pcall(function()
        cv:set_rgb565_data(art.pix, "le")
    end)
    if not okd then return end
    lock_obj(cv)
    pcall(function() cv:align("center", 0, 0) end)
    -- Keep the caption on tight HUD slots (portrait / 320x240).
    pcall(function() btn:set_text("") end)
end
decorate_hud_btn(btn_rst, ART.rst)
decorate_hud_btn(btn_exit, ART.exit)

-- Title / subtitle / play-round stay inside the play rectangle.
local inner = math.max(INNER, 4)
local lw = play_w - 2 * inner
if lw < 1 then lw = math.max(1, play_w) inner = 0 end
local title_h = FONT_LINE * 2
local sub_h = FONT_LINE * 3
local rnd_h = FONT_LINE
if play_h < title_h + sub_h + rnd_h + 2 * inner then
    title_h = FONT_LINE
    sub_h = FONT_LINE
    if play_h < title_h + sub_h + rnd_h + 2 * inner then
        rnd_h = 0
    end
end
if title_h < 1 then title_h = 1 end
if sub_h < 1 then sub_h = 1 end
local block = title_h + GAP + sub_h
if rnd_h > 0 then block = block + GAP + rnd_h end
local ty = math.floor((play_h - block) / 2)
if ty < inner then ty = inner end
if ty + block > play_h then
    local over = ty + block - play_h
    ty = ty - over
    if ty < 0 then ty = 0 end
end
if ty + title_h > play_h then title_h = math.max(1, play_h - ty) end
local sy = ty + title_h + GAP
if sy + sub_h > play_h then
    sub_h = math.max(1, play_h - sy)
end
if sy < 0 then sy = 0 end
local ry = sy + sub_h + GAP
if rnd_h > 0 and ry + rnd_h > play_h then
    rnd_h = math.max(0, play_h - ry)
end

local label_title = mk("label", play, {
    x = inner, y = ty, w = lw, h = title_h,
    text = "Wait", text_color = COLORS.text, pad = 0,
    align = "center",
})
local label_sub = mk("label", play, {
    x = inner, y = sy, w = lw, h = sub_h,
    text = "Tap when it turns green", text_color = COLORS.text, pad = 0,
    align = "center",
})
local label_play_round = nil
if rnd_h > 0 then
    label_play_round = mk("label", play, {
        x = inner, y = ry, w = lw, h = rnd_h,
        text = "ROUND 1/5", text_color = COLORS.dim, pad = 0,
        align = "center",
    })
end

play:on("clicked", function()
    logic.tap(game)
end)

btn_rst:on("clicked", function()
    logic.start(game)
end)

btn_exit:on("clicked", function()
    running = false
end)

local last_round, last_best, last_false, last_state
local last_title, last_sub, last_color

local function status_for(st)
    if st == logic.STATE_FINISHED then
        return "DONE", COLORS.done
    end
    if st == logic.STATE_READY then
        return "TAP", COLORS.text
    end
    if st == logic.STATE_RESULT then
        if game.was_false_start then
            return "OOPS", COLORS.oops
        end
        return "OK", COLORS.text
    end
    return "WAIT", COLORS.text
end

local function refresh()
    local st = game.state
    local rtxt = logic.round_text(game)
    if rtxt ~= last_round then
        last_round = rtxt
        set_info(label_round, rtxt)
        if label_play_round then
            label_play_round:set_text("ROUND " .. rtxt)
        end
    end
    local btxt = logic.best_text(game)
    if btxt ~= last_best then
        last_best = btxt
        set_info(label_best, btxt)
    end
    local ftxt = logic.false_text(game)
    if ftxt ~= last_false then
        last_false = ftxt
        set_info(label_false, ftxt)
    end
    if game.title ~= last_title then
        last_title = game.title
        label_title:set_text(tostring(game.title or ""))
    end
    if game.subtitle ~= last_sub then
        last_sub = game.subtitle
        label_sub:set_text(tostring(game.subtitle or ""))
    end
    if game.play_color ~= last_color then
        last_color = game.play_color
        play:set_style({
            bg_color = game.play_color,
            bg_opa = 255,
            radius = RADIUS,
            border_color = COLORS.border,
            border_width = BORDER,
            text_color = COLORS.text,
        })
    end
    if st ~= last_state then
        last_state = st
        local stext, scolor = status_for(st)
        label_status:set_text(stext)
        label_status:set_style({ text_color = scolor })
    end
end

scr:load()
logic.start(game)
refresh()

local last_ms = system.millis()
while running do
    lvgl.process_events(0)
    local now_ms = system.millis()
    local dt = math.floor(now_ms - last_ms)
    if dt < 0 or dt > 1000 then dt = 16 end
    last_ms = now_ms
    logic.update(game, dt)
    refresh()
    delay.delay_ms(16)
end
pcall(function()
    if lvgl.deinit then lvgl.deinit() end
end)
