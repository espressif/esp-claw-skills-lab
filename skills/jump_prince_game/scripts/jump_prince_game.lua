-- jump_prince_game.lua: entry script for the Jump Prince skill (esp-claw).
--
-- Run via lua_run_script_async:
--   path:      {CUR_SKILL_DIR}/scripts/jump_prince_game.lua
--   args:      { assets_dir = "{CUR_SKILL_DIR}/assets" }   -- required
--   name:      jump_prince_game
--   exclusive: display
--   timeout:   0                                           -- until cancelled
--
-- Layout is FULL-RECTANGLE (no circular safe-area, no lock_obj(scr)):
-- header on top, controls on the bottom, playfield FILLS the leftover
-- rectangle with SQUARE tiles. Width/height always come from board_manager
-- (never assume 800x480 or 480x480).
--
-- vis_tile = min(floor(W/MAP_W), floor(avail_h/MAP_H)), min 8.
-- vis_w=16*vis_tile, vis_h=12*vis_tile, centered in leftover (letterbox
-- extra pixels, do not stretch tiles). Header/control shrink slightly when
-- that lets the map reach the width-limited tile size.
--   800x480: preferred chrome 64+76, leftover 340 -> vis_tile 28, 448x336.
--   480x480: shrink chrome so vis_tile can be 30 and fill 480x360.
--
-- Device (WEB_SIM false): tiled .spr RGB565 canvases at vis_tile. Never a
-- full-playfield canvas, never PNG decode. Tiles/player sit on `scr`.
-- Web sim: WASM LVGL without lv_tick_inc never flushes later widgets, so
-- many lvgl.image/canvas tiles only show the first row. WEB_SIM therefore
-- draws the 16x12 map each frame through display.begin_frame / blit /
-- present / end_frame (software framebuffer, same as snake_game).

local board_manager = require("board_manager")
local delay_ok, delay = pcall(require, "delay")
if not delay_ok then delay = nil end
local lvgl = require("lvgl")
local storage_ok, storage = pcall(require, "storage")
if not storage_ok then storage = nil end
local system_ok, system = pcall(require, "system")
if not system_ok then system = nil end
local touch_mod_ok, lcd_touch = pcall(require, "lcd_touch")
if not touch_mod_ok then lcd_touch = nil end

do
    local src = debug.getinfo(1, "S").source or ""
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    src = src:gsub("\\", "/")
    local scripts_dir = src:match("^(.*)/[^/]+$")
    if scripts_dir and package and package.path then
        package.path = scripts_dir .. "/?.lua;" .. package.path
    end
end

local logic = require("jp_logic")
local spr = require("jp_spr")
local input = require("jp_input")

-- Web simulator: keep WEB_SIM for storage/delay/system fallbacks.
-- WASM lv_conf is LV_COLOR_DEPTH 32 + LODEPNG/FS_STDIO; rgb565 canvas
-- buffers often composite blank. Device uses .spr + RGB565 canvas.
-- WEB_SIM draws lvgl.image PNGs exported from the same .spr files.
-- Detect the same way other skills do (args, source path, WASM userdata).
local WEB_SIM = false

local function source_path()
    local src = debug.getinfo(1, "S").source or ""
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    return src:gsub("\\", "/")
end

local function detect_web_sim()
    if type(args) == "table" then
        if args.simulator == true or args.web_sim == true or args.sim == true then
            return true
        end
        if args.simulator == "web" then
            return true
        end
    end
    local src = source_path()
    if src:find("^/skills/") or src:find("^/uploads/") then
        return true
    end
    return false
end

local function mark_sim_from_obj(obj)
    if WEB_SIM or obj == nil then
        return
    end
    -- WASM lvgl userdata has no __newindex (same as whack_mole_game).
    local ok = pcall(function() obj._jp_probe = true end)
    if not ok then
        WEB_SIM = true
    end
end

local function now_ms()
    if system_ok and system and system.millis then
        local ok, t = pcall(system.millis)
        if ok and type(t) == "number" then
            return t
        end
    end
    if os and os.clock then
        return math.floor(os.clock() * 1000)
    end
    return 0
end

local function sleep_ms(ms)
    ms = tonumber(ms) or 0
    if ms <= 0 then return end
    if delay_ok and delay and delay.delay_ms then
        pcall(delay.delay_ms, ms)
        return
    end
    if os and os.clock then
        local t0 = os.clock()
        while os.clock() - t0 < (ms / 1000) do end
    end
end

local function join_path(a, b)
    if storage and storage.join_path then
        local ok, p = pcall(storage.join_path, a, b)
        if ok and type(p) == "string" then
            return p
        end
    end
    a = tostring(a or ""):gsub("\\", "/"):gsub("/+$", "")
    return a .. "/" .. tostring(b)
end

local function read_bytes(path)
    if storage and storage.read_file then
        local ok, data = pcall(storage.read_file, path)
        if ok and type(data) == "string" and #data > 0 then
            return data
        end
    end
    if io and io.open then
        local ok, f = pcall(io.open, path, "rb")
        if ok and f then
            local data = f:read("*a")
            f:close()
            if type(data) == "string" and #data > 0 then
                return data
            end
        end
    end
    return nil
end

local TILE_PALETTE = { "#8B6914", "#6B4F2A", "#A67C52", "#5C4033", "#7a5a32", "#9A7B4F" }


-- LVGL objects scroll by default; that steals touches and draws a
-- scrollbar on the header. Same helper as whack_mole_game.
-- Player-facing stage: spawn is screen_index=5 (bottom). Climbing
-- decreases screen_index, so Stage = 6 - screen_index, clamped 1..5.
local function stage_num(screen_index)
    local n = 6 - (tonumber(screen_index) or 0)
    if n < 1 then n = 1 end
    if n > 5 then n = 5 end
    return n
end

local function lock_obj(obj)
    if obj == nil then return obj end
    pcall(function()
        obj:set_scroll({ dir = "none", scrollbar = "off" })
    end)
    pcall(function() obj:set_scrollbar_mode("off") end)
    pcall(function() obj:set_scroll_dir("none") end)
    pcall(function() obj.scrollable = false end)
    pcall(function() obj:clear_flag("SCROLLABLE") end)
    return obj
end

local COLORS = {
    sky = "#cfe3f5",
    panel = "#182235",
    text = "#f5f7fa",
    accent = "#ffd166",
}

local function parse_args()
    if type(args) ~= "table" then
        return {}
    end
    return {
        assets_dir = args.assets_dir,
        tile_px = tonumber(args.tile_px),
    }
end

local function hex_to_rgb565le(hex)
    local r = tonumber(hex:sub(2, 3), 16) or 0
    local g = tonumber(hex:sub(4, 5), 16) or 0
    local b = tonumber(hex:sub(6, 7), 16) or 0
    local v = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
    return string.char(v & 0xFF, (v >> 8) & 0xFF)
end

local function scale_sprite(sp, dest_w, dest_h)
    local pal = {}
    for idx, hex in pairs(sp.colors) do
        pal[idx] = hex_to_rgb565le(hex)
    end
    local trans = sp.transparent
    local step_x = sp.w / dest_w
    local step_y = sp.h / dest_h
    local rows, masks = {}, {}
    local zero = string.char(0, 0)
    for py = 0, dest_h - 1 do
        local src_row = math.min(sp.h - 1, math.floor(py * step_y))
        local row_base = src_row * sp.w
        local pix_parts, mask_parts = {}, {}
        for px = 0, dest_w - 1 do
            local sx = math.min(sp.w - 1, math.floor(px * step_x))
            local idx = sp.pix:byte(row_base + sx + 1)
            if idx == trans or pal[idx] == nil then
                pix_parts[#pix_parts + 1] = zero
                mask_parts[#mask_parts + 1] = "\0"
            else
                pix_parts[#pix_parts + 1] = pal[idx]
                mask_parts[#mask_parts + 1] = "\1"
            end
        end
        rows[py + 1] = table.concat(pix_parts)
        masks[py + 1] = table.concat(mask_parts)
    end
    return { w = dest_w, h = dest_h, rows = rows, masks = masks }
end

local function blit_scaled(dst_rows, scaled, dx, dy, field_w, field_h)
    for sy = 0, scaled.h - 1 do
        local ty = dy + sy
        if ty >= 0 and ty < field_h then
            local mask = scaled.masks[sy + 1]
            local src = scaled.rows[sy + 1]
            local dst = dst_rows[ty + 1]
            local i = 1
            while i <= scaled.w do
                if mask:byte(i) == 0 then
                    i = i + 1
                else
                    local j = i + 1
                    while j <= scaled.w and mask:byte(j) ~= 0 do
                        j = j + 1
                    end
                    local x0 = dx + i - 1
                    local x1 = dx + j - 1
                    local si = i
                    if x0 < 0 then
                        si = si - x0
                        x0 = 0
                    end
                    if x1 > field_w then
                        x1 = field_w
                    end
                    if x1 > x0 then
                        local src_from = (si - 1) * 2 + 1
                        local src_to = src_from + (x1 - x0) * 2 - 1
                        dst = dst:sub(1, x0 * 2)
                            .. src:sub(src_from, src_to)
                            .. dst:sub(x1 * 2 + 1)
                    end
                    i = j
                end
            end
            dst_rows[ty + 1] = dst
        end
    end
end

local function obj_set_pos(obj, x, y)
    if not obj then return false end
    if pcall(function() obj:set_pos(x, y) end) then return true end
    local okx = pcall(function() obj:set_x(x) end)
    local oky = pcall(function() obj:set_y(y) end)
    return okx or oky
end

local function obj_delete(obj)
    if not obj then return end
    pcall(function() obj:delete() end)
end

local function main()
    local cfg = parse_args()
    if not cfg.assets_dir or cfg.assets_dir == "" then
        local src = debug.getinfo(1, "S").source
        if src:sub(1, 1) == "@" then src = src:sub(2) end
        src = src:gsub("\\", "/")
        local skill_root = src:match("^(.*)/scripts/[^/]+$")
        if skill_root then
            cfg.assets_dir = skill_root .. "/assets"
        else
            local script_dir = src:match("^(.*)/") or "."
            cfg.assets_dir = script_dir .. "/assets"
        end
    end
    print("jp: assets_dir=" .. tostring(cfg.assets_dir))

    WEB_SIM = detect_web_sim()
    local bank_path = join_path(cfg.assets_dir, "sprites.bin")
    print("jp: loading sprites " .. bank_path .. " sim=" .. tostring(WEB_SIM))
    local bank = nil
    local raw_bank = read_bytes(bank_path)
    if raw_bank then
        local ok_bank, loaded = pcall(spr.load_bank, raw_bank)
        if ok_bank then
            bank = loaded
        else
            print("jp: sprite bank decode failed " .. tostring(loaded))
        end
    else
        print("jp: sprite bank missing at " .. bank_path)
    end
    if not bank then
        -- Widget tiles still play in the web simulator without RGB565.
        WEB_SIM = true
    end

    local USE_PNG = false
    local function sprite_png_file(name)
        return join_path(cfg.assets_dir, name .. ".png")
    end
    local function sprite_png_src(name)
        local path = sprite_png_file(name):gsub("\\", "/")
        return path
    end
    if WEB_SIM then
        if read_bytes(sprite_png_file("tile_0_0")) and read_bytes(sprite_png_file("player_r0")) then
            USE_PNG = true
            print("jp: web sim using lvgl.image png sprites")
        else
            print("jp: web sim png missing; will try rgb565 canvas")
        end
    end

    local sprite_cache = {}
    local scaled_cache = {}
    local packed_cache = {}

    local function get_sprite(name)
        if not bank then
            return nil
        end
        if not sprite_cache[name] then
            local ok, decoded = pcall(spr.decode_named, bank, name)
            if not ok or not decoded then
                return nil
            end
            sprite_cache[name] = decoded
        end
        return sprite_cache[name]
    end

    local function tile_sprite_name(sx, sy)
        return string.format("tile_%d_%d", sx, sy)
    end

    local panel_handle, io_handle, width, height, panel_if =
        board_manager.get_display_lcd_params("display_lcd")

    -- WEB_SIM: take the software framebuffer BEFORE lvgl.init so present()
    -- actually owns the panel (snake_game / game_of_life do this).
    local disp = nil
    local disp_ready = false
    local image_mod = nil
    if WEB_SIM then
        local okd, dmod = pcall(require, "display")
        if okd and type(dmod) == "table" then
            disp = dmod
            local oki, ierr = pcall(disp.init, panel_handle, io_handle, width, height, panel_if)
            if oki then
                disp_ready = true
                pcall(function()
                    if disp.backlight then disp.backlight(true) end
                end)
                print("jp: web sim display.init before lvgl")
            else
                print("jp: display.init (pre-lvgl) failed " .. tostring(ierr))
            end
        else
            print("jp: require(display) failed " .. tostring(dmod))
        end
        local oki, im = pcall(require, "image")
        if oki and type(im) == "table" then
            image_mod = im
        end
        local ok_lv, lv_err = pcall(lvgl.init, panel_handle, io_handle, width, height, panel_if, {
            buffer_lines = 40,
            tick_ms = 5,
            task_period_ms = 10,
        })
        if not ok_lv then
            print("jp: lvgl.init after display skipped/failed " .. tostring(lv_err))
        end
    else
        lvgl.init(panel_handle, io_handle, width, height, panel_if, {
            buffer_lines = 40,
            tick_ms = 5,
            task_period_ms = 10,
        })
    end

    local touch_handle = board_manager.get_lcd_touch_handle("lcd_touch")
    if touch_handle ~= nil then
        lvgl.indev_register("touch", touch_handle)
    end

    -- Preferred chrome on a 480-tall panel: header 64, controls 76.
    -- Shrink toward mins when that lets vis_tile reach floor(W/MAP_W).
    local MIN_HEADER_H = 44
    local MIN_CONTROL_H = 56
    local HEADER_H = math.max(56, math.floor(height * 0.135))
    if HEADER_H > 72 then HEADER_H = 72 end
    local CONTROL_H = math.max(72, math.floor(height * 0.16))
    if CONTROL_H > 80 then CONTROL_H = 80 end
    local tile_from_w = math.floor(width / logic.MAP_W)
    local chrome_for_w = height - tile_from_w * logic.MAP_H
    if chrome_for_w >= (MIN_HEADER_H + MIN_CONTROL_H)
        and (HEADER_H + CONTROL_H) > chrome_for_w then
        local rest = chrome_for_w
        local h = math.floor(rest * HEADER_H / (HEADER_H + CONTROL_H))
        if h < MIN_HEADER_H then h = MIN_HEADER_H end
        local c = rest - h
        if c < MIN_CONTROL_H then
            c = MIN_CONTROL_H
            h = rest - c
        end
        if h >= MIN_HEADER_H and c >= MIN_CONTROL_H then
            HEADER_H = h
            CONTROL_H = c
        end
    end

    local scr = lvgl.create_screen()
    pcall(function() scr:set_pos(0, 0) end)
    pcall(function() scr:set_size(width, height) end)
    scr:set_style({ bg_color = COLORS.sky, pad = 0, border_width = 0 })
    mark_sim_from_obj(scr)
    if WEB_SIM and not USE_PNG then
        if read_bytes(sprite_png_file("tile_0_0")) and read_bytes(sprite_png_file("player_r0")) then
            USE_PNG = true
            print("jp: web sim using lvgl.image png sprites")
        end
    end
    if WEB_SIM then
        print("jp: web sim png=" .. tostring(USE_PNG))
    end

    local avail_w = width
    local avail_h = height - HEADER_H - CONTROL_H
    if avail_h < 32 then
        avail_h = math.max(32, height - HEADER_H - 8)
    end

    local header = lock_obj(lvgl.container(scr, {
        x = 0, y = 0, w = width, h = HEADER_H,
        bg_color = COLORS.panel,
        pad = 0,
        border_width = 0,
        scrollbar = "off",
    }))
    pcall(function() header:set_size(width, HEADER_H) end)
    pcall(function() header:set_pos(0, 0) end)
    pcall(function() header:set_style({ border_width = 0, pad = 0 }) end)
    local label_y = math.floor((HEADER_H - 22) / 2)
    if label_y < 8 then label_y = 8 end
    -- Centered so left Exit/Pause and right Restart icons have room.
    local label_stage = lvgl.label(header, {
        x = math.floor((width - 90) / 2), y = label_y,
        text = "Stage 1",
        text_color = COLORS.text,
    })

    local MIN_TILE_PX = 8
    local vis_tile = cfg.tile_px or math.min(
        math.floor(avail_w / logic.MAP_W),
        math.floor(avail_h / logic.MAP_H))
    if vis_tile < MIN_TILE_PX then vis_tile = MIN_TILE_PX end

    local vis_w = vis_tile * logic.MAP_W
    local vis_h = vis_tile * logic.MAP_H
    local vis_x = math.floor((width - vis_w) / 2)
    local vis_y = HEADER_H + math.floor((avail_h - vis_h) / 2)

    print(string.format(
        "jp: display %dx%d vis_tile=%d vis=%dx%d xy=%d,%d header=%d ctrl=%d avail=%dx%d",
        width, height, vis_tile, vis_w, vis_h, vis_x, vis_y,
        HEADER_H, CONTROL_H, avail_w, avail_h))

    local tile_px = vis_tile
    local field_w, field_h = vis_w, vis_h
    -- Never allocate a full-playfield RGB565 canvas: 448x336 is ~301KB and
    -- redrawing it every fall-frame (Lua string concat + blit) freezes the
    -- device. Grid of per-tile canvases plus one player overlay is the path
    -- that was playable.
    local render_mode = "grid"
    local canvas = nil
    local field_bg = nil
    local cell_free = {}
    local cell_at = {}
    local player_cv = nil
    local player_spr = nil
    local player_frames = {}
    local player_can_move = false
    local player_alloc_failed = false

    local function try_make_canvas(parent, x, y, w, h, color_format)
        local opts = {
            x = x,
            y = y,
            w = w,
            h = h,
            bg_color = COLORS.sky,
            border_width = 0,
            pad = 0,
        }
        if color_format then
            opts.color_format = color_format
        elseif not WEB_SIM then
            opts.color_format = "rgb565"
        end
        local ok, obj = pcall(lvgl.canvas, parent, opts)
        if ok and obj then
            lock_obj(obj)
            pcall(function() obj:clear_flag("CLICKABLE") end)
            pcall(function() obj:set_style({ border_width = 0, pad = 0 }) end)
            pcall(function() obj:set_size(w, h) end)
            pcall(function() obj:fill_bg(COLORS.sky) end)
            return obj
        end
        return nil, tostring(obj)
    end

    local function try_make_sim_canvas(parent, x, y, w, h)
        -- WASM is LV_COLOR_DEPTH 32; rgb565 buffers often composite blank.
        local formats = { nil, "true_color", "argb8888", "xrgb8888", "rgb888", "rgb565" }
        for _, fmt in ipairs(formats) do
            local obj = try_make_canvas(parent, x, y, w, h, fmt)
            if obj then
                return obj
            end
        end
        return nil
    end

    local function try_make_image(parent, x, y, w, h, src)
        if type(lvgl.image) ~= "function" then
            return nil
        end
        local srcs = { src }
        if type(src) == "string" and src:sub(1, 2) == "A:" then
            srcs[#srcs + 1] = src:sub(3)
        elseif type(src) == "string" then
            srcs[#srcs + 1] = "A:" .. src
        end
        for _, s in ipairs(srcs) do
            local ok, obj = pcall(lvgl.image, parent, {
                x = x, y = y, w = w, h = h,
                src = s,
                border_width = 0,
                pad = 0,
            })
            if ok and obj then
                lock_obj(obj)
                pcall(function() obj:clear_flag("CLICKABLE") end)
                pcall(function() obj:set_size(w, h) end)
                pcall(function() obj:set_width(w) end)
                pcall(function() obj:set_height(h) end)
                pcall(function()
                    obj:set_style({ border_width = 0, pad = 0, bg_opa = 0 })
                end)
                return obj
            end
        end
        return nil
    end

    print(string.format(
        "jp: skip vis canvas vis_tile=%d vis=%dx%d rgb565=%dB (grid only)",
        vis_tile, vis_w, vis_h, vis_w * vis_h * 2))

    -- WEB_SIM only: software framebuffer. Do not create dozens of lvgl
    -- tile widgets (WASM without lv_tick_inc never flushes later ones).
    if WEB_SIM and not disp_ready then
        local okd, dmod = pcall(require, "display")
        if okd and type(dmod) == "table" then
            disp = dmod
            local oki, ierr = pcall(disp.init, panel_handle, io_handle, width, height, panel_if)
            if oki then
                disp_ready = true
                pcall(function()
                    if disp.backlight then disp.backlight(true) end
                end)
                print("jp: web sim display framebuffer ready (late)")
            else
                print("jp: display.init failed " .. tostring(ierr))
            end
        else
            print("jp: require(display) failed " .. tostring(dmod))
        end
        if image_mod == nil then
            local oki, im = pcall(require, "image")
            if oki and type(im) == "table" then
                image_mod = im
            end
        end
    end
    if WEB_SIM and disp_ready then
        print("jp: web sim display framebuffer ready")
        if image_mod then
            print("jp: web sim image module ready")
        end
    end

    if not disp_ready then
        -- Device (and sim fallback): sky only on scr. Tiles are NOT children.
        field_bg = lock_obj(lvgl.container(scr, {
            x = vis_x, y = vis_y, w = vis_w, h = vis_h,
            bg_color = COLORS.sky,
            pad = 0,
            border_width = 0,
            scrollbar = "off",
        }))
        pcall(function() field_bg:set_size(vis_w, vis_h) end)
        pcall(function() field_bg:set_pos(vis_x, vis_y) end)
        pcall(function() field_bg:clear_flag("CLICKABLE") end)
        pcall(function()
            field_bg:set_style({ border_width = 0, pad = 0, bg_color = COLORS.sky })
        end)
        print("jp: render=grid cell=" .. tostring(vis_tile) .. "x" .. tostring(vis_tile)
            .. " (sprite tiles + player)")
    else
        print("jp: render=display cell=" .. tostring(vis_tile) .. "x" .. tostring(vis_tile)
            .. " map=" .. tostring(logic.MAP_W) .. "x" .. tostring(logic.MAP_H)
            .. " vis=" .. tostring(vis_w) .. "x" .. tostring(vis_h))
    end

    local sky_px = hex_to_rgb565le(COLORS.sky)
    local sky_row = string.rep(sky_px, field_w)
    local sky_tile_row = string.rep(sky_px, tile_px)

    local function get_scaled(name)
        if scaled_cache[name] then
            return scaled_cache[name]
        end
        local sp = get_sprite(name)
        if not sp then
            return nil
        end
        scaled_cache[name] = scale_sprite(sp, tile_px, tile_px)
        return scaled_cache[name]
    end

    local function packed_tile(name)
        if packed_cache[name] then
            return packed_cache[name]
        end
        local scaled = get_scaled(name)
        if not scaled then
            return nil
        end
        local rows = {}
        for y = 1, tile_px do
            rows[y] = sky_tile_row
        end
        blit_scaled(rows, scaled, 0, 0, tile_px, tile_px)
        local packed = table.concat(rows)
        packed_cache[name] = packed
        return packed
    end

    -- Native .spr is 25x25; web-sim PNGs were exported at 28px (800x480).
    local function sprite_native_w(name)
        if USE_PNG then
            return 28
        end
        local sp = get_sprite(name)
        if sp and sp.w and sp.w > 0 then
            return sp.w
        end
        return 25
    end

    local function apply_img_scale(obj, w, h, spr_name)
        if not obj then
            return
        end
        pcall(function() obj:set_size(w, h) end)
        pcall(function() obj:set_width(w) end)
        pcall(function() obj:set_height(h) end)
        local native = sprite_native_w(spr_name)
        if native > 0 and native ~= w then
            local zoom = math.floor(256 * w / native + 0.5)
            pcall(function() obj:set_zoom(zoom) end)
            pcall(function() obj:set_scale(w / native) end)
            pcall(function()
                obj:set_style({
                    transform_zoom = zoom,
                    img_zoom = zoom,
                    width = w,
                    height = h,
                })
            end)
        end
    end

    local function img_size_ok(obj, w)
        if not obj then
            return false
        end
        local gw = nil
        pcall(function() gw = obj:get_width() end)
        if type(gw) ~= "number" then
            pcall(function() gw = obj.width end)
        end
        if type(gw) == "number" and gw > 0 then
            return gw == w
        end
        return nil
    end

    local function paint_sprite_on(obj, name, w, h)
        if not obj or not name then
            return false
        end
        local packed_ok = pcall(function()
            obj:set_rgb565_data(packed_tile(name), "le")
        end)
        if packed_ok then
            return true
        end
        local sp = get_sprite(name)
        if not sp then
            return false
        end
        local ok = pcall(function()
            local step_x = sp.w / w
            local step_y = sp.h / h
            local trans = sp.transparent
            for py = 0, h - 1 do
                local src_row = math.min(sp.h - 1, math.floor(py * step_y))
                local row_base = src_row * sp.w
                for px = 0, w - 1 do
                    local sx = math.min(sp.w - 1, math.floor(px * step_x))
                    local idx = sp.pix:byte(row_base + sx + 1)
                    if idx ~= trans and sp.colors[idx] then
                        obj:set_px(px, py, sp.colors[idx])
                    end
                end
            end
        end)
        return ok
    end

    local function tile_xy(tx, ty)
        return vis_x + tx * tile_px, vis_y + ty * tile_px
    end

    local game = logic.new()
    local session = { mode = "playing", running = true, rendered_section = -1 }

    local function tile_fill_color(x, y)
        local sx, sy = logic.get_tile_sprite(game, x, y)
        if not sx then
            return "#7a5a32"
        end
        return TILE_PALETTE[((sx + sy * 3) % #TILE_PALETTE) + 1]
    end

    local ctrl_box = {
        x = 0,
        y = height - CONTROL_H,
        w = width,
        h = CONTROL_H,
    }
    print(string.format("jp: ctrl box %d,%d %dx%d",
                        ctrl_box.x, ctrl_box.y, ctrl_box.w, ctrl_box.h))

    input.build({
        lvgl = lvgl,
        parent = scr,
        assets_dir = cfg.assets_dir,
        header = header,
        header_h = HEADER_H,
        width = width,
        height = height,
        control_h = CONTROL_H,
        box = ctrl_box,
        web_sim = WEB_SIM,
        on_left = function(v)
            print("jp: in left " .. (v and "1" or "0"))
            if session.mode == "playing" then
                logic.set_input(game, v, game.input_right, game.input_jump)
            end
        end,
        on_right = function(v)
            print("jp: in right " .. (v and "1" or "0"))
            if session.mode == "playing" then
                logic.set_input(game, game.input_left, v, game.input_jump)
            end
        end,
        on_jump = function(v)
            print("jp: in jump " .. (v and "1" or "0"))
            if session.mode == "playing" then
                logic.set_input(game, game.input_left, game.input_right, v)
            end
        end,
        on_pause = function()
            print("jp: in pause")
            if session.mode == "playing" then
                session.mode = "paused"
                input.set_enabled(false)
                logic.pause(game)
                label_stage:set_text(string.format("Stage %d II", stage_num(game.screen_index)))
            elseif session.mode == "paused" then
                session.mode = "playing"
                input.set_enabled(true)
                logic.resume(game)
                label_stage:set_text(string.format("Stage %d", stage_num(game.screen_index)))
            end
        end,
        on_restart = function()
            print("jp: in restart")
            session.mode = "playing"
            input.set_enabled(true)
            logic.restart(game)
            session.rendered_section = -1
        end,
        on_exit = function()
            print("jp: in exit")
            session.running = false
        end,
    })

    -- ------------------------------------------------------------ rendering
    local bg_rows = {}
    local last_player = { dx = 0, dy = 0, w = 0, h = 0, valid = false }
    local last_draw = { dx = nil, dy = nil, idx = nil, facing = nil, overlap = nil }

    local function new_sky_rows()
        local rows = {}
        for y = 1, field_h do
            rows[y] = sky_row
        end
        return rows
    end

    local function push_rows(rows)
        local packed = table.concat(rows)
        canvas:set_rgb565_data(packed, "le")
        return #packed
    end

    local function rebuild_background_single()
        bg_rows = new_sky_rows()
        for y = 0, logic.MAP_H - 1 do
            for x = 0, logic.MAP_W - 1 do
                if logic.tile_full(game, x, y) then
                    local sx, sy = logic.get_tile_sprite(game, x, y)
                    if sx then
                        local scaled = get_scaled(tile_sprite_name(sx, sy))
                        blit_scaled(bg_rows, scaled, x * tile_px, y * tile_px,
                                    field_w, field_h)
                    end
                end
            end
        end
    end

    local function clone_rows()
        local rows = {}
        for y = 1, field_h do
            rows[y] = bg_rows[y]
        end
        return rows
    end

    local function compose_frame(player_scaled, dx, dy)
        local rows = clone_rows()
        if last_player.valid then
            local x0 = last_player.dx
            local y0 = last_player.dy
            local x1 = x0 + last_player.w
            local y1 = y0 + last_player.h
            if x0 < 0 then x0 = 0 end
            if y0 < 0 then y0 = 0 end
            if x1 > field_w then x1 = field_w end
            if y1 > field_h then y1 = field_h end
            for y = y0, y1 - 1 do
                rows[y + 1] = bg_rows[y + 1]
            end
        end
        blit_scaled(rows, player_scaled, dx, dy, field_w, field_h)
        last_player.dx = dx
        last_player.dy = dy
        last_player.w = player_scaled.w
        last_player.h = player_scaled.h
        last_player.valid = true
        return rows
    end

    local function take_cell(w, h, spr_name)
        w = w or tile_px
        h = h or tile_px
        local key
        if USE_PNG and spr_name then
            key = spr_name
        else
            key = string.format("%dx%d", w, h)
        end
        local bucket = cell_free[key]
        if bucket and #bucket > 0 then
            local obj = bucket[#bucket]
            bucket[#bucket] = nil
            return obj
        end
        -- Tiles live on `scr` at absolute vis_x/vis_y. field_bg is sky only;
        -- WASM often ignores container set_size and would clip children.
        local tile_host = scr
        if USE_PNG and spr_name then
            local native = sprite_native_w(spr_name)
            if native == w then
                local img = try_make_image(tile_host, 0, 0, w, h, sprite_png_src(spr_name))
                if img then
                    apply_img_scale(img, w, h, spr_name)
                    return img
                end
            else
                -- PNG native size != vis_tile: prefer a vis_tile canvas / set_px
                -- so set_size being ignored cannot leave gaps.
                local cv
                if WEB_SIM then
                    cv = try_make_sim_canvas(tile_host, 0, 0, w, h)
                else
                    cv = try_make_canvas(tile_host, 0, 0, w, h)
                end
                if cv and paint_sprite_on(cv, spr_name, w, h) then
                    return cv
                end
                local img = try_make_image(tile_host, 0, 0, w, h, sprite_png_src(spr_name))
                if img then
                    apply_img_scale(img, w, h, spr_name)
                    return img
                end
            end
        end
        -- Device path (and sim fallback): per-tile / row-run RGB565 canvas.
        -- Never a full-playfield buffer. On WEB_SIM try 32-bit first.
        local obj
        if WEB_SIM then
            obj = try_make_sim_canvas(tile_host, 0, 0, w, h)
        else
            obj = try_make_canvas(tile_host, 0, 0, w, h)
        end
        if obj then
            if spr_name then
                paint_sprite_on(obj, spr_name, w, h)
            end
            return obj
        end
        local ok, box = pcall(lvgl.container, tile_host, {
            x = 0, y = 0, w = w, h = h,
            bg_color = "#7a5a32",
            pad = 0,
            border_width = 0,
            radius = 2,
        })
        if not (ok and box) then
            return nil
        end
        pcall(function() box:set_size(w, h) end)
        pcall(function() box:clear_flag("CLICKABLE") end)
        pcall(function() box:set_style({ border_width = 0, pad = 0 }) end)
        return box
    end

    local function hide_cell(obj, w, h, pool_key)
        if not obj then return end
        obj_set_pos(obj, -1000, -1000)
        local key = pool_key or string.format("%dx%d", w or tile_px, h or tile_px)
        local bucket = cell_free[key]
        if not bucket then
            bucket = {}
            cell_free[key] = bucket
        end
        bucket[#bucket + 1] = obj
    end

    local function free_pool_count()
        local n = 0
        for _, bucket in pairs(cell_free) do
            n = n + #bucket
        end
        return n
    end

    local function packed_run(y, x0, run_w)
        local run_px = run_w * tile_px
        local sky_run_row = string.rep(sky_px, run_px)
        local rows = {}
        for py = 1, tile_px do
            rows[py] = sky_run_row
        end
        for i = 0, run_w - 1 do
            local tx = x0 + i
            local sx, sy = logic.get_tile_sprite(game, tx, y)
            if sx then
                local scaled = get_scaled(tile_sprite_name(sx, sy))
                blit_scaled(rows, scaled, i * tile_px, 0, run_px, tile_px)
            end
        end
        return table.concat(rows)
    end

    local function rebuild_background_grid()
        for key, rec in pairs(cell_at) do
            hide_cell(rec.obj, rec.w, rec.h, rec.key)
            cell_at[key] = nil
        end
        local made = 0
        local failed = 0
        local runs = 0
        if USE_PNG then
            for y = 0, logic.MAP_H - 1 do
                for x = 0, logic.MAP_W - 1 do
                    if logic.tile_full(game, x, y) then
                        local sx, sy = logic.get_tile_sprite(game, x, y)
                        if sx then
                            local name = tile_sprite_name(sx, sy)
                            local obj = take_cell(tile_px, tile_px, name)
                            if obj then
                                pcall(function()
                                    obj:set_style({ border_width = 0, pad = 0, bg_opa = 0 })
                                end)
                                local px, py = tile_xy(x, y)
                                obj_set_pos(obj, px, py)
                                pcall(function() obj:clear_flag("CLICKABLE") end)
                                cell_at[y * logic.MAP_W + x] = {
                                    obj = obj, w = tile_px, h = tile_px, key = name,
                                }
                                made = made + 1
                            else
                                failed = failed + 1
                            end
                        end
                    end
                end
                if (not WEB_SIM) and (y + 1) % 3 == 0 then
                    lvgl.process_events(0)
                end
            end
            print(string.format("jp: png tiles placed=%d failed=%d pool=%d",
                                made, failed, made + free_pool_count()))
            return
        end
        for y = 0, logic.MAP_H - 1 do
            local x = 0
            while x < logic.MAP_W do
                if logic.tile_full(game, x, y) then
                    local x0 = x
                    local run_w = 0
                    while x < logic.MAP_W and logic.tile_full(game, x, y) do
                        run_w = run_w + 1
                        x = x + 1
                    end
                    runs = runs + 1
                    local rw = run_w * tile_px
                    local rh = tile_px
                    local obj = take_cell(rw, rh)
                    if obj then
                        pcall(function()
                            obj:set_style({ border_width = 0, pad = 0 })
                        end)
                        local px, py = tile_xy(x0, y)
                        obj_set_pos(obj, px, py)
                        pcall(function() obj:clear_flag("CLICKABLE") end)
                        local painted = pcall(function()
                            obj:set_rgb565_data(packed_run(y, x0, run_w), "le")
                        end)
                        if not painted then
                            pcall(function()
                                obj:set_style({
                                    bg_color = tile_fill_color(x0, y),
                                    border_width = 0,
                                    pad = 0,
                                })
                            end)
                        end
                        cell_at[y * logic.MAP_W + x0] = {
                            obj = obj, w = rw, h = rh,
                            key = string.format("%dx%d", rw, rh),
                        }
                        made = made + 1
                    else
                        failed = failed + 1
                    end
                else
                    x = x + 1
                end
            end
            if (not WEB_SIM) and (y + 1) % 3 == 0 then
                lvgl.process_events(0)
            end
        end
        print(string.format("jp: grid cells placed=%d failed=%d runs=%d pool=%d",
                            made, failed, runs, made + free_pool_count()))
    end

    local function ensure_player_canvas()
        if player_cv then return player_cv end
        if player_alloc_failed then return nil end
        local pw = tile_px
        local ok, obj = pcall(lvgl.container, scr, {
            x = vis_x,
            y = vis_y,
            w = pw,
            h = pw,
            bg_color = COLORS.sky,
            radius = 0,
            pad = 0,
            border_width = 0,
        })
        if not (ok and obj) then
            player_alloc_failed = true
            print("jp: player container alloc failed (no retry) " .. tostring(obj))
            return nil
        end
        player_cv = obj
        pcall(function() player_cv:set_size(pw, pw) end)
        pcall(function() player_cv:clear_flag("CLICKABLE") end)
        pcall(function()
            player_cv:set_scroll({ dir = "none", scrollbar = "off" })
        end)
        player_can_move = obj_set_pos(player_cv, vis_x, vis_y)
        if USE_PNG then
            -- Frames sit on `scr` so a container that ignores set_size cannot
            -- clip them. The mover is still player_cv (transparent, on scr).
            pcall(function()
                player_cv:set_style({
                    border_width = 0,
                    pad = 0,
                    bg_opa = 0,
                })
            end)
            player_frames = {}
            local nimg = 0
            for _, facing in ipairs({"l", "r"}) do
                for i = 0, 6 do
                    local name = string.format("player_%s%d", facing, i)
                    local img = try_make_image(scr, vis_x, vis_y, tile_px, tile_px,
                                               sprite_png_src(name))
                    if img then
                        apply_img_scale(img, tile_px, tile_px, name)
                        obj_set_pos(img, -1000, -1000)
                        player_frames[name] = img
                        nimg = nimg + 1
                    end
                end
            end
            print("jp: player png frames=" .. tostring(nimg)
                .. " move=" .. tostring(player_can_move)
                .. " on=scr tile=" .. tostring(tile_px))
            if nimg == 0 then
                pcall(function()
                    player_cv:set_style({
                        bg_color = "#E23D28",
                        border_width = 0,
                        pad = 0,
                        bg_opa = 255,
                    })
                end)
                print("jp: player fallback box move=" .. tostring(player_can_move))
            end
            return player_cv
        end
        pcall(function()
            player_cv:set_style({
                border_width = 0,
                pad = 0,
                bg_color = COLORS.sky,
            })
        end)
        player_spr = try_make_canvas(player_cv, 0, 0, tile_px, tile_px)
        if player_spr then
            pcall(function()
                player_spr:set_style({ border_width = 0, pad = 0 })
            end)
            pcall(function() player_spr:fill_bg(COLORS.sky) end)
            print("jp: player sprite canvas ok move=" .. tostring(player_can_move))
        else
            pcall(function()
                player_cv:set_style({
                    bg_color = "#E23D28",
                    border_width = 0,
                    pad = 0,
                })
            end)
            print("jp: player fallback box move=" .. tostring(player_can_move))
        end
        return player_cv
    end

    local function fill_player_overlay(psp, dx, dy)
        local rows = {}
        for y = 1, tile_px do
            rows[y] = sky_tile_row
        end
        local x0 = math.floor(dx / tile_px)
        local y0 = math.floor(dy / tile_px)
        local x1 = math.floor((dx + tile_px - 1) / tile_px)
        local y1 = math.floor((dy + tile_px - 1) / tile_px)
        for ty = y0, y1 do
            for tx = x0, x1 do
                if logic.tile_full(game, tx, ty) then
                    local sx, sy = logic.get_tile_sprite(game, tx, ty)
                    if sx then
                        local scaled = get_scaled(tile_sprite_name(sx, sy))
                        blit_scaled(rows, scaled,
                                    tx * tile_px - dx, ty * tile_px - dy,
                                    tile_px, tile_px)
                    end
                end
            end
        end
        blit_scaled(rows, psp, 0, 0, tile_px, tile_px)
        return table.concat(rows)
    end

    local function current_player_scaled()
        local idx = logic.get_player_sprite(game)
        if idx > 6 then idx = 0 end
        if game.is_facing_right then
            return get_scaled(string.format("player_r%d", idx))
        end
        return get_scaled(string.format("player_l%d", idx))
    end

    local function player_draw_origin()
        local fx = logic.player_screen_x(game) * tile_px - math.floor(tile_px / 2)
        local fy = logic.player_screen_y(game) * tile_px
            - math.floor((tile_px * 10) / 16)
        return math.floor(fx), math.floor(fy)
    end

    local png_frames = {}
    local sim_blit_kind = nil
    local sim_first_present = true

    local function load_png_frame(name)
        if not image_mod then
            return nil
        end
        if png_frames[name] ~= nil then
            if png_frames[name] == false then
                return nil
            end
            return png_frames[name]
        end
        local path = sprite_png_file(name)
        local ok, frame = pcall(image_mod.load_file, path)
        if ok and frame then
            png_frames[name] = frame
            return frame
        end
        png_frames[name] = false
        return nil
    end

    local function sim_blit_sprite(name, x, y, w, h)
        x = math.floor(x)
        y = math.floor(y)
        w = math.floor(w or tile_px)
        h = math.floor(h or tile_px)
        if w < 1 then w = 1 end
        if h < 1 then h = 1 end
        -- Prefer PNG image.frame (WEB_SIM only). Device never decodes PNG.
        if USE_PNG and image_mod then
            local frame = load_png_frame(name)
            if frame then
                local ok = pcall(disp.draw_image, x, y, frame, {
                    mode = "stretch", width = w, height = h,
                })
                if ok then
                    sim_blit_kind = sim_blit_kind or "draw_image-png"
                    return true
                end
                ok = pcall(disp.draw_image, x, y, frame, {
                    mode = "fit", width = w, height = h,
                })
                if ok then
                    sim_blit_kind = sim_blit_kind or "draw_image-png-fit"
                    return true
                end
            end
        end
        -- Decoded .spr RGB565 (same pixels the device tiles use).
        local packed = packed_tile(name)
        if packed then
            if type(disp.blit) == "function" then
                local ok = pcall(disp.blit, x, y, packed, {
                    width = w, height = h, format = "rgb565le",
                })
                if ok then
                    sim_blit_kind = sim_blit_kind or "blit-rgb565"
                    return true
                end
            end
            if type(disp.draw_pixels) == "function" then
                local ok = pcall(disp.draw_pixels, x, y, packed, {
                    format = "rgb565le", width = w, height = h, mode = "raw",
                })
                if ok then
                    sim_blit_kind = sim_blit_kind or "draw_pixels-rgb565le"
                    return true
                end
                ok = pcall(disp.draw_pixels, x, y, packed, {
                    format = "rgb565", width = w, height = h,
                })
                if ok then
                    sim_blit_kind = sim_blit_kind or "draw_pixels-rgb565"
                    return true
                end
            end
        end
        return false
    end

    local function sim_draw_chrome()
        pcall(disp.fill_rect, 0, 0, width, HEADER_H, COLORS.panel)
        local st = string.format("Stage %d", stage_num(game.screen_index))
        if session.mode == "paused" then
            st = st .. " II"
        end
        local ly = math.floor((HEADER_H - 22) / 2)
        if ly < 8 then ly = 8 end
        pcall(disp.draw_text_aligned, math.floor((width - 90) / 2), ly, 90, 22, st, {
            color = COLORS.text, font_size = 16, align = "center", valign = "middle",
        })
        local btn_h = math.min(42, math.max(28, HEADER_H - 10))
        local by = math.floor((HEADER_H - btn_h) / 2)
        if by < 2 then by = 2 end
        local pad = math.max(6, math.min(12, math.floor(width * 0.02)))
        local exit_w = math.max(56, math.min(72, math.floor(width * 0.15)))
        local pause_w = math.max(60, math.min(80, math.floor(width * 0.16)))
        local restart_w = math.max(64, math.min(88, math.floor(width * 0.18)))
        local specs = {
            { x = pad, w = exit_w, text = "Exit", bg = "#FEFDF9" },
            { x = pad + exit_w + 8, w = pause_w, text = "Pause", bg = "#FEFDF9" },
            { x = width - pad - restart_w, w = restart_w, text = "Restart", bg = "#DFE7FC" },
        }
        for _, sp in ipairs(specs) do
            pcall(disp.fill_round_rect, sp.x, by, sp.w, btn_h, 8, sp.bg)
            pcall(disp.draw_text_aligned, sp.x, by, sp.w, btn_h, sp.text, {
                color = "#111111", font_size = 14, align = "center", valign = "middle", bg = sp.bg,
            })
        end
        local box_y = height - CONTROL_H
        local gap = 2
        local n = 3
        local zone_w = math.floor((width - gap * (n - 1)) / n)
        local zones = {
            { text = "Left", bg = "#C7F0BD" },
            { text = "Jump", bg = "#F8DFA5" },
            { text = "Right", bg = "#C7F0BD" },
        }
        local charging = game.input_left or game.input_right or game.input_jump
        local aim = 0
        local ch = 0
        if charging then
            aim = game.jump_aim_x or 0
            ch = logic.jump_charge(game)
        end
        local active = 2
        if aim < 0 then active = 1
        elseif aim > 0 then active = 3 end
        for i, z in ipairs(zones) do
            local zx = (i - 1) * (zone_w + gap)
            local zw = zone_w
            if i == n then zw = width - zx end
            local bar_w = math.max(8, zw - 8)
            pcall(disp.fill_rect, zx, box_y, zw, CONTROL_H, "#000000")
            pcall(disp.fill_rect, zx + 4, box_y + 4, bar_w, 8, "#352B69")
            if i == active and ch > 0 then
                local fw = math.max(1, math.floor(ch * bar_w + 0.5))
                pcall(disp.fill_rect, zx + 4, box_y + 4, fw, 8, "#F7C35F")
            end
            local btn_y = box_y + 4 + 8 + 4
            local btn_h2 = CONTROL_H - (4 + 8 + 4) - 4
            if btn_h2 < 28 then btn_h2 = math.max(28, CONTROL_H - 16) end
            pcall(disp.fill_round_rect, zx + 4, btn_y, bar_w, btn_h2, 8, z.bg)
            pcall(disp.draw_text_aligned, zx + 4, btn_y, bar_w, btn_h2, z.text, {
                color = "#111111", font_size = 16, align = "center", valign = "middle", bg = z.bg,
            })
        end
    end

    local function sim_present_frame()
        if not disp_ready then
            return
        end
        local tw = tile_px
        pcall(disp.begin_frame, { clear = true, color = COLORS.sky, preserve = false })
        -- Always walk all 12 map rows so the sim cannot stall on row 0.
        local tiles = 0
        local rows_with = 0
        for y = 0, logic.MAP_H - 1 do
            local row_hit = false
            for x = 0, logic.MAP_W - 1 do
                if logic.tile_full(game, x, y) then
                    row_hit = true
                    local sx, sy = logic.get_tile_sprite(game, x, y)
                    local px = vis_x + x * tw
                    local py = vis_y + y * tw
                    local ok = false
                    if sx then
                        ok = sim_blit_sprite(tile_sprite_name(sx, sy), px, py, tw, tw)
                    end
                    if not ok then
                        pcall(disp.fill_rect, px, py, tw, tw, tile_fill_color(x, y))
                        sim_blit_kind = sim_blit_kind or "fill_rect"
                    end
                    tiles = tiles + 1
                end
            end
            if row_hit then
                rows_with = rows_with + 1
            end
        end
        local idx = logic.get_player_sprite(game)
        if idx > 6 then idx = 0 end
        local dx, dy = player_draw_origin()
        local facing = game.is_facing_right and "r" or "l"
        local pname = string.format("player_%s%d", facing, idx)
        local px = vis_x + dx
        local py = vis_y + dy
        local tx0 = math.floor(dx / tw)
        local ty0 = math.floor(dy / tw)
        local tx1 = math.floor((dx + tw - 1) / tw)
        local ty1 = math.floor((dy + tw - 1) / tw)
        local overlaps = false
        for ty = ty0, ty1 do
            for tx = tx0, tx1 do
                if logic.tile_full(game, tx, ty) then
                    overlaps = true
                end
            end
        end
        local drew = false
        if overlaps then
            local psp = current_player_scaled()
            if psp then
                local packed = fill_player_overlay(psp, dx, dy)
                if packed and type(disp.draw_pixels) == "function" then
                    drew = pcall(disp.draw_pixels, math.floor(px), math.floor(py), packed, {
                        format = "rgb565le", width = tw, height = tw, mode = "raw",
                    })
                    if not drew then
                        drew = pcall(disp.draw_pixels, math.floor(px), math.floor(py), packed, {
                            format = "rgb565", width = tw, height = tw,
                        })
                    end
                    if drew then
                        sim_blit_kind = sim_blit_kind or "draw_pixels-player-overlay"
                    end
                end
            end
        end
        if not drew then
            drew = sim_blit_sprite(pname, px, py, tw, tw)
        end
        if not drew then
            pcall(disp.fill_rect, math.floor(px), math.floor(py), tw, tw, "#E23D28")
        end
        -- Mixing display.present with LVGL chrome often wipes widgets; draw
        -- Exit/Pause/Restart + Left/Jump/Right with display too. Input still
        -- comes from lcd_touch.poll.
        sim_draw_chrome()
        pcall(disp.present)
        pcall(disp.end_frame)
        if sim_first_present then
            sim_first_present = false
            print(string.format(
                "jp: sim present rows=%d/%d tiles=%d blit=%s player@%d,%d vis_tile=%d screen=%d",
                rows_with, logic.MAP_H, tiles, tostring(sim_blit_kind),
                math.floor(px), math.floor(py), tw, game.screen_index))
        end
    end


    local function render_section(force)
        local section = game.screen_index
        if (not force) and section == session.rendered_section then
            return false
        end
        session.rendered_section = section
        last_player.valid = false
        last_draw.idx = nil
        last_draw.overlap = nil
        last_draw.dx = nil
        last_draw.dy = nil
        last_draw.facing = nil
        print(string.format("jp: section %d", section))
        if disp_ready then
            -- WEB_SIM: 16x12 map is presented each frame; no tile widgets.
        elseif render_mode == "single" then
            rebuild_background_single()
        else
            rebuild_background_grid()
            -- Never delete player_cv (realloc after tiles can OOM). Restack it.
            if not player_cv then
                ensure_player_canvas()
            end
            if player_cv then
                pcall(function() player_cv:move_foreground() end)
                pcall(function() player_cv:move_to_index(-1) end)
            end
            if USE_PNG then
                for _, img in pairs(player_frames) do
                    pcall(function() img:move_foreground() end)
                    pcall(function() img:clear_flag("CLICKABLE") end)
                end
            end
        end
        -- Controls must sit above tiles/player so 480x480 bottom-row
        -- tiles cannot cover Left/Jump/Right hit zones.
        if input.raise then
            input.raise()
        end
        label_stage:set_text(string.format("Stage %d", stage_num(section)))
        return true
    end

    local first_blit = true
    local function draw_player_frame()
        if disp_ready then
            sim_present_frame()
            return
        end
        local idx = logic.get_player_sprite(game)
        if idx > 6 then idx = 0 end
        local dx, dy = player_draw_origin()
        local psp = nil
        if (not USE_PNG) and (render_mode == "single" or player_spr) then
            psp = current_player_scaled()
            if not psp then
                return
            end
        end
        if render_mode == "single" then
            local rows = compose_frame(psp, dx, dy)
            local nbytes = push_rows(rows)
            if first_blit then
                first_blit = false
                print(string.format(
                    "jp: first blit %dB player@%d,%d screen=%d pos=%.2f,%.2f",
                    nbytes, dx, dy, game.screen_index,
                    logic.player_screen_x(game), logic.player_screen_y(game)))
            end
            return
        end
        if not player_cv then
            return
        end
        if USE_PNG then
            local facing = game.is_facing_right and "r" or "l"
            local name = string.format("player_%s%d", facing, idx)
            local img = player_frames[name]
            local changed = last_draw.idx ~= idx or last_draw.facing ~= facing
                or last_draw.dx ~= dx or last_draw.dy ~= dy
            if changed then
                if type(last_draw.facing) == "string" and last_draw.idx ~= nil then
                    local prev_name = string.format(
                        "player_%s%d", last_draw.facing, last_draw.idx)
                    if prev_name ~= name then
                        local prev = player_frames[prev_name]
                        if prev then
                            obj_set_pos(prev, -1000, -1000)
                        end
                    end
                end
                if img then
                    obj_set_pos(img, vis_x + dx, vis_y + dy)
                    pcall(function() img:move_foreground() end)
                    pcall(function() img:clear_flag("CLICKABLE") end)
                else
                    obj_set_pos(player_cv, vis_x + dx, vis_y + dy)
                end
                if input.raise then
                    input.raise()
                end
                last_draw.idx = idx
                last_draw.facing = facing
                last_draw.dx, last_draw.dy = dx, dy
            end
            if first_blit then
                first_blit = false
                print(string.format(
                    "jp: first png player@%d,%d vis=%d,%d screen=%d pos=%.2f,%.2f",
                    vis_x + dx, vis_y + dy, vis_x, vis_y, game.screen_index,
                    logic.player_screen_x(game), logic.player_screen_y(game)))
            end
            return
        end
        if player_spr then
            local facing = game.is_facing_right and "r" or "l"
            local tx0 = math.floor(dx / tile_px)
            local ty0 = math.floor(dy / tile_px)
            local tx1 = math.floor((dx + tile_px - 1) / tile_px)
            local ty1 = math.floor((dy + tile_px - 1) / tile_px)
            local overlaps = false
            local overlap_key = ""
            for ty = ty0, ty1 do
                for tx = tx0, tx1 do
                    if logic.tile_full(game, tx, ty) then
                        overlaps = true
                        overlap_key = overlap_key .. string.format("%d,%d;", tx, ty)
                    end
                end
            end
            local same_sprite = last_draw.idx == idx
                and last_draw.facing == facing
                and last_draw.overlap == overlap_key
            if not same_sprite then
                local packed
                if overlaps then
                    packed = fill_player_overlay(psp, dx, dy)
                else
                    packed = packed_tile(string.format("player_%s%d", facing, idx))
                end
                pcall(function() player_spr:set_rgb565_data(packed, "le") end)
                last_draw.idx = idx
                last_draw.facing = facing
                last_draw.overlap = overlap_key
            end
        end
        if last_draw.dx ~= dx or last_draw.dy ~= dy then
            obj_set_pos(player_cv, vis_x + dx, vis_y + dy)
            last_draw.dx, last_draw.dy = dx, dy
        end
        if not player_spr then
            local charging = game.input_left or game.input_right or game.input_jump
            local col = charging and "#F4A261" or "#E23D28"
            pcall(function()
                player_cv:set_style({
                    bg_color = col,
                    border_width = 0,
                    pad = 0,
                })
            end)
        end
        if first_blit then
            first_blit = false
            print(string.format(
                "jp: first grid player@%d,%d vis=%d,%d screen=%d pos=%.2f,%.2f",
                vis_x + dx, vis_y + dy, vis_x, vis_y, game.screen_index,
                logic.player_screen_x(game), logic.player_screen_y(game)))
        end
    end

    logic.start(game)
    session.mode = "playing"

    scr:load()
    render_section(true)
    if not disp_ready then
        ensure_player_canvas()
    end
    draw_player_frame()
    if input.raise then
        input.raise()
    end

    -- Web sim: LVGL pressed/released often never fire (lv_tick_inc is
    -- not called). Poll lcd_touch like snake_game and map x-thirds of
    -- the control band. Device path stays process_events + flush.
    local sim_touch = nil
    local sim_poll_ok = false
    if WEB_SIM then
        if not touch_mod_ok or lcd_touch == nil then
            touch_mod_ok, lcd_touch = pcall(require, "lcd_touch")
            if not touch_mod_ok then lcd_touch = nil end
        end
        pcall(function()
            if board_manager.init_device then
                board_manager.init_device("lcd_touch")
            end
        end)
        sim_touch = touch_handle
        if sim_touch == nil then
            local okh, h = pcall(board_manager.get_lcd_touch_handle, "lcd_touch")
            if okh then sim_touch = h end
        end
        if touch_mod_ok and lcd_touch and sim_touch then
            if type(lcd_touch.init) == "function" then
                pcall(lcd_touch.init, sim_touch)
            end
            if type(lcd_touch.sync) == "function" then
                pcall(lcd_touch.sync, sim_touch)
            end
            sim_poll_ok = true
            print("jp: web sim pointer poll ready")
        else
            print("jp: web sim pointer poll unavailable")
        end
    end

    local sim_poll_warned = false
    local function poll_sim_pointer()
        if not sim_poll_ok then
            return
        end
        local ok, info = pcall(lcd_touch.poll, sim_touch)
        if not ok then
            if not sim_poll_warned then
                sim_poll_warned = true
                print("jp: lcd_touch.poll failed " .. tostring(info))
            end
            return
        end
        if type(info) ~= "table" then
            return
        end
        local pressed = info.pressed == true
        if input.pointer then
            input.pointer(info.x, info.y, pressed)
        end
    end

    local last_charge_aim, last_charge_v = 0, 0
    input.set_charge(0, 0)
    print(string.format(
        "jp: started playing screen=%d pos=%.2f,%.2f mode=%s",
        game.screen_index, game.position.x, game.position.y, render_mode))

    local last_ms = now_ms()
    local last_tick_ms = last_ms
    while session.running do
        lvgl.process_events(0)
        if WEB_SIM then
            poll_sim_pointer()
        end
        if input.flush then
            input.flush()
        end

        local now = now_ms()
        local dt = now - last_ms
        if dt < 0 then
            dt = 16
        elseif dt > 100 then
            dt = 100
        end
        last_ms = now

        if session.mode == "playing" then
            logic.update(game, dt)
            render_section(false)
            draw_player_frame()
            local charging = game.input_left or game.input_right or game.input_jump
            local aim = 0
            local ch = 0
            if charging then
                aim = game.jump_aim_x or 0
                ch = logic.jump_charge(game)
            end
            if aim ~= last_charge_aim or math.abs(ch - last_charge_v) > 0.02 then
                last_charge_aim = aim
                last_charge_v = ch
                input.set_charge(aim, ch)
            end
        elseif disp_ready then
            sim_present_frame()
        end

        if now - last_tick_ms >= 2000 then
            last_tick_ms = now
            print(string.format(
                "jp: tick pos=%.2f,%.2f screen=%d L,R,J=%d,%d,%d cv=%s",
                game.position.x, game.position.y, game.screen_index,
                game.input_left and 1 or 0,
                game.input_right and 1 or 0,
                game.input_jump and 1 or 0,
                tostring(player_cv ~= nil)))
        end

        local used = now_ms() - now
        if used < 0 then used = 0 end
        if used < 16 then
            sleep_ms(16 - used)
        end
    end
end

local function errlog(msg)
    local ok, f = pcall(io.open, "/fatfs/skills/jump_prince_game/error.log", "w")
    if ok and f then
        f:write(tostring(msg))
        f:close()
    end
    print("jp: ERROR " .. tostring(msg))
end

local ok, err = xpcall(main, function(e)
    return tostring(e) .. "\n" .. tostring((debug and debug.traceback and debug.traceback("", 2)) or "")
end)
if not ok then
    errlog("LUA ERROR: " .. err)
end
