local lvgl = require("lvgl")
local storage = require("storage")
local delay = require("delay")
local system = require("system")

local scripts = assert(debug.getinfo(1, "S").source:match("^@(.*)/[^/]+$"), "cannot resolve Jump Prince path")
package.path = scripts .. "/?.lua;" .. package.path
local logic = require("jp_logic")
local spr = require("jp_spr")
local cfg = type(args) == "table" and args or {}
local SKY = "#cfe3f5"
local FRAME_MS = 16
local owned = false

local function hex_to_rgb565le(hex)
    local r = tonumber(hex:sub(2, 3), 16) or 0
    local g = tonumber(hex:sub(4, 5), 16) or 0
    local b = tonumber(hex:sub(6, 7), 16) or 0
    local v = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
    return string.char(v & 0xFF, (v >> 8) & 0xFF)
end

local function scale_sprite(sp, dest_w, dest_h, alpha)
    local pal = {}
    for idx, hex in pairs(sp.colors) do
        pal[idx] = alpha and string.char(tonumber(hex:sub(6, 7), 16), tonumber(hex:sub(4, 5), 16), tonumber(hex:sub(2, 3), 16), 255) or hex_to_rgb565le(hex)
    end
    local trans = sp.transparent
    local step_x = sp.w / dest_w
    local step_y = sp.h / dest_h
    local rows, masks = {}, {}
    local zero = string.rep("\0", alpha and 4 or 2)
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

local function decorate(obj)
    obj:clear_flag("CLICKABLE")
    obj:clear_flag("SCROLLABLE")
    return obj
end

local function run()
    local assets = cfg.assets_dir or storage.join_path(assert(scripts:match("^(.*)/scripts$"), "invalid App path"), "assets")
    local bank = spr.load_bank(storage.read_file(storage.join_path(assets, "sprites.bin")))
    lvgl.init({ buffer_lines = 20, tick_ms = 5, task_period_ms = 10 })
    owned = true
    local screen = lvgl.create_screen()
    local w, h = screen:get_size()
    screen:set_style({ bg_color = SKY, pad = 0, border_width = 0 })
    screen:clear_flag("SCROLLABLE")
    local header, footer = 64, math.max(56, math.min(80, math.floor(h * 0.16)))
    local max_tile = math.min(w // logic.MAP_W, (h - header - footer) // logic.MAP_H)
    local tile = tonumber(cfg.tile_px) or max_tile
    assert(tile % 1 == 0 and tile >= 4 and tile <= max_tile, "tile_px must fit the display")
    local fw, fh = tile * logic.MAP_W, tile * logic.MAP_H
    local fx, fy = (w - fw) // 2, header + (h - header - footer - fh) // 2
    local field = decorate(lvgl.object(screen, { x = fx, y = fy, w = fw, h = fh, pad = 0, border_width = 0, radius = 0, bg_color = SKY }))
    local background = decorate(lvgl.canvas(field, { x = 0, y = 0, w = fw, h = fh, color_format = "rgb565" }))
    local game = logic.new()
    logic.start(game)
    local running, paused, held = true, false, nil
    local release_pending = false
    local section, current_frame, last_x, last_y
    local frames, tiles, fills, hits, controls = {}, {}, {}, {}, {}
    local colors = { "#C7F0BD", "#F8DFA5", "#C7F0BD" }
    local disabled_colors = { "#6A8A64", "#8A7A58", "#6A8A64" }

    -- Cache all player frames once; animation only changes visibility and position.
    for _, facing in ipairs({ "l", "r" }) do
        for i = 0, 6 do
            local name = string.format("player_%s%d", facing, i)
            local pixels = scale_sprite(spr.decode_named(bank, name), tile, tile, true)
            local obj = decorate(lvgl.image(field, { w = tile, h = tile }))
            obj:add_flag("HIDDEN")
            obj:set_raw_argb8888(tile, tile, table.concat(pixels.rows))
            frames[name] = obj
        end
    end

    local bar = decorate(lvgl.object(screen, { x = 0, y = 0, w = w, h = header, bg_color = "#182235", pad = 0, border_width = 0, radius = 0 }))
    local stage = decorate(lvgl.label(bar, { align = "top_mid", y = 4, text = "Stage 1", text_color = "#f5f7fa" }))
    local function update_stage()
        stage:set_text(string.format("Stage %d%s", math.max(1, math.min(5, 6 - game.screen_index)), paused and " II" or ""))
    end
    local function cancel_charge()
        held, release_pending = nil, false
        logic.set_input(game, false, false, false)
        game.jump_hold_time, game.prev_charging, game.prev_input_jump = 0, false, false
    end
    local function enable_controls(enabled)
        for i, hit in ipairs(hits) do
            if enabled then hit:add_flag("CLICKABLE") else hit:clear_flag("CLICKABLE") end
            controls[i]:set_style({ bg_color = enabled and colors[i] or disabled_colors[i] })
        end
    end
    local pause_button
    local actions = {
        { "Exit", function() running = false end },
        { "Pause", function()
            cancel_charge()
            paused = not paused
            if paused then logic.pause(game) else logic.resume(game) end
            pause_button:set_text(paused and "Resume" or "Pause")
            enable_controls(not paused)
            update_stage()
        end },
        { "Restart", function()
            cancel_charge()
            logic.restart(game)
            paused, section = false, nil
            pause_button:set_text("Pause")
            enable_controls(true)
        end },
    }
    for i, action in ipairs(actions) do
        local left, right = (i - 1) * w // 3, i * w // 3
        local button = lvgl.button(bar, { x = left + 5, y = 28, w = right - left - 10, h = 30, text = action[1], radius = 6, pad = 0, border_width = 0 })
        button:clear_flag("SCROLLABLE")
        button:on("clicked", action[2])
        if i == 2 then pause_button = button end
    end

    for i, label in ipairs({ "Left", "Jump", "Right" }) do
        local left, right = (i - 1) * w // 3, i * w // 3
        local width = right - left - 2
        local visual = decorate(lvgl.object(screen, { x = left, y = h - footer, w = width, h = footer, bg_color = colors[i], pad = 0, border_width = 0, radius = 0 }))
        local track = decorate(lvgl.object(visual, { x = 4, y = 4, w = width - 8, h = 8, bg_color = "#384454", pad = 0, border_width = 0, radius = 2 }))
        fills[i] = decorate(lvgl.object(track, { x = 0, y = 0, w = 1, h = 8, bg_color = "#ffd166", pad = 0, border_width = 0, radius = 2 }))
        decorate(lvgl.label(visual, { align = "center", y = 6, text = label, text_color = "#111111" }))
        local extra = math.max(12, math.min(24, math.floor(footer * 0.28)))
        local hit = lvgl.object(screen, { x = left, y = h - footer - extra, w = right - left, h = footer + extra, opa = 0, pad = 0, border_width = 0, radius = 0 })
        hit:clear_flag("SCROLLABLE")
        hit:add_flag("CLICKABLE")
        hit:add_flag("PRESS_LOCK")
        hit:move_foreground()
        hit:on("pressed", function()
            release_pending = false
            if not paused and not held then
                held = i
                logic.set_input(game, i == 1, i == 3, i == 2)
            end
        end)
        hit:on("released", function()
            if held == i then release_pending = true end
        end)
        hits[i], controls[i] = hit, visual
    end

    local charge_widths = {}
    local function render()
        if section ~= game.screen_index then
            section = game.screen_index
            local rows, sky = {}, string.rep(hex_to_rgb565le(SKY), fw)
            for y = 1, fh do rows[y] = sky end
            for y = 0, logic.MAP_H - 1 do
                for x = 0, logic.MAP_W - 1 do
                    local sx, sy = logic.get_tile_sprite(game, x, y)
                    if sx then
                        local name = string.format("tile_%d_%d", sx, sy)
                        if not tiles[name] then tiles[name] = scale_sprite(spr.decode_named(bank, name), tile, tile) end
                        blit_scaled(rows, tiles[name], x * tile, y * tile, fw, fh)
                    end
                end
            end
            background:set_rgb565_data(table.concat(rows), "le")
            update_stage()
        end
        local name = string.format("player_%s%d", game.is_facing_right and "r" or "l", logic.get_player_sprite(game))
        local player = frames[name]
        local x = math.floor(logic.player_screen_x(game) * tile - tile / 2)
        local y = math.floor(logic.player_screen_y(game) * tile - tile * 10 / 16)
        if current_frame ~= player or x ~= last_x or y ~= last_y then
            player:set_pos(x, y)
            last_x, last_y = x, y
        end
        if current_frame ~= player then
            if current_frame then current_frame:add_flag("HIDDEN") end
            player:clear_flag("HIDDEN")
            current_frame = player
        end
        for i, fill in ipairs(fills) do
            local width = math.max(1, math.floor((i * w // 3 - (i - 1) * w // 3 - 10) * (held == i and logic.jump_charge(game) or 0)))
            if charge_widths[i] ~= width then fill:set_size(width, 8); charge_widths[i] = width end
        end
    end

    render()
    screen:load()
    local last = system.millis()
    while running do
        local now = system.millis()
        lvgl.process_events(0)
        if not running then break end
        logic.update(game, math.max(0, math.min(100, now - last)))
        last = now
        -- Preserve a short press even when press/release arrive in one event batch.
        if release_pending then
            held, release_pending = nil, false
            logic.set_input(game, false, false, false)
        end
        render()
        delay.delay_ms(math.max(1, FRAME_MS - (system.millis() - now)))
    end
end

local ok, err = xpcall(run, debug.traceback)
if owned then
    local closed, close_err = pcall(lvgl.deinit)
    if not closed then print("[JumpPrince] display cleanup failed: " .. tostring(close_err)) end
end
if not ok then
    print("[JumpPrince] " .. tostring(err))
    error(err)
end
