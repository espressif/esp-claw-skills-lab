-- input.lua: full-height hold zones + first-press lock (charge-safe).
-- Device (Korvo): visible Left/Jump/Right receive pressed/released; optional
-- transparent overlays sit on top for a larger hit area. Web sim: skip
-- opa=0 overlays (WASM hit-test often ignores them) and also poll the
-- pointer from jump_prince_game.lua because lv_tick_inc is not called.
local M = {}
local zone_buttons = {}
local charge_fills = {}
local zone_cbs = {}
local raise_list = {}
local header_hits = {}
local charge_max_w = 1
local bar_h = 8
local held = 0
local release_armed = 0
local ptr_down = false
local header_pending = 0
local ctrl_x = 0
local ctrl_y = 0
local ctrl_w = 1
local ctrl_h = 76
local ctrl_extra = 12
local header_h = 56

local function lock_hit(obj)
    if obj == nil then return obj end
    pcall(function() obj:add_flag("CLICKABLE") end)
    pcall(function() obj:add_flag("PRESS_LOCK") end)
    pcall(function() obj:clear_flag("SCROLLABLE") end)
    pcall(function()
        obj:set_scroll({ dir = "none", scrollbar = "off" })
    end)
    return obj
end

local function no_click(obj)
    if obj == nil then return obj end
    pcall(function() obj:clear_flag("CLICKABLE") end)
    pcall(function() obj:clear_flag("SCROLLABLE") end)
    return obj
end

local function no_border(obj)
    if obj == nil then return obj end
    pcall(function() obj:set_style({ border_width = 0, pad = 0 }) end)
    return obj
end

local function track_raise(obj)
    if obj == nil then return obj end
    raise_list[#raise_list + 1] = obj
    return obj
end

local function on_pressed(i)
    -- Sliding onto a neighbor in the same event batch cancels a just-armed
    -- release so the charge does not drop. First-press lock keeps aim.
    if release_armed ~= 0 then
        release_armed = 0
    end
    if held == 0 then
        held = i
        local cb = zone_cbs[i]
        if cb then cb(true) end
    end
end

local function on_released(i)
    if held == 0 then
        return
    end
    if held == i then
        release_armed = i
    else
        -- Finger lifted on a neighbor while first-press locked.
        release_armed = held
    end
end

function M.build(ctx)
    local lvgl = ctx.lvgl
    zone_buttons = {}
    charge_fills = {}
    zone_cbs = {}
    raise_list = {}
    header_hits = {}
    held = 0
    release_armed = 0
    ptr_down = false
    header_pending = 0

    local web_sim = ctx.web_sim == true
    local hw = tonumber(ctx.width) or 0
    local hh = tonumber(ctx.header_h) or 56
    header_h = hh
    local hdr = ctx.header or ctx.parent
    if hdr and hw > 0 then
        local btn_h = math.min(42, math.max(28, hh - 10))
        local by = math.floor((hh - btn_h) / 2)
        if by < 2 then by = 2 end
        local pad = math.max(6, math.min(12, math.floor(hw * 0.02)))
        local exit_w = math.max(56, math.min(72, math.floor(hw * 0.15)))
        local pause_w = math.max(60, math.min(80, math.floor(hw * 0.16)))
        local restart_w = math.max(64, math.min(88, math.floor(hw * 0.18)))
        local specs = {
            { x = pad, w = exit_w, text = "Exit", bg = "#FEFDF9", cb = ctx.on_exit },
            { x = pad + exit_w + 8, w = pause_w, text = "Pause", bg = "#FEFDF9", cb = ctx.on_pause },
            { x = hw - pad - restart_w, w = restart_w, text = "Restart", bg = "#DFE7FC", cb = ctx.on_restart },
        }
        for _, s in ipairs(specs) do
            local btn = lvgl.button(hdr, {
                x = s.x, y = by, w = s.w, h = btn_h,
                text = s.text, radius = 8,
                bg_color = s.bg, text_color = "#111111",
                border_width = 0, pad = 0,
            })
            no_border(btn)
            if s.cb then
                -- clicked is more likely to work than press on WASM.
                btn:on("clicked", s.cb)
            end
            header_hits[#header_hits + 1] = {
                x = s.x, y = by, w = s.w, h = btn_h, cb = s.cb,
            }
            track_raise(btn)
        end
    end

    -- Full-width bottom bar from the layout (actual screen W/H + CONTROL_H).
    local scr_w = tonumber(ctx.width) or 0
    local scr_h = tonumber(ctx.height) or 0
    local ch = tonumber(ctx.control_h) or 0
    local box = ctx.box
    if type(box) ~= "table" then
        box = {}
    end
    if not box.w or box.w < 1 then
        box.w = scr_w
    end
    if not box.h or box.h < 1 then
        box.h = (ch > 0) and ch or 76
    end
    if box.x == nil then
        box.x = 0
    end
    if box.y == nil then
        box.y = scr_h - box.h
    end
    local EXTRA = math.max(12, math.min(24, math.floor(box.h * 0.28)))
    ctrl_x = box.x
    ctrl_y = box.y
    ctrl_w = box.w
    ctrl_h = box.h
    ctrl_extra = EXTRA
    local gap = 2
    local n = 3
    local zone_w = math.floor((box.w - gap * (n - 1)) / n)
    if zone_w < 8 then zone_w = 8 end

    local zones = {
        { text = "Left",  bg = "#C7F0BD", cb = ctx.on_left },
        { text = "Jump",  bg = "#F8DFA5", cb = ctx.on_jump },
        { text = "Right", bg = "#C7F0BD", cb = ctx.on_right },
    }

    -- Pass 1: visual zones (charge bar is a child, not a sibling above the
    -- button). Visible Left/Jump/Right MUST receive pressed/released.
    local layout = {}
    for i, s in ipairs(zones) do
        local zx = box.x + (i - 1) * (zone_w + gap)
        local zw = zone_w
        if i == n then
            zw = (box.x + box.w) - zx
        end
        zone_cbs[i] = s.cb

        -- bg_opa=1 (not 0): WASM hit-test often skips fully transparent
        -- parents and would never reach the child buttons.
        local visual = lvgl.container(ctx.parent, {
            x = zx, y = box.y, w = zw, h = box.h,
            pad = 0, border_width = 0,
            bg_color = "#000000", bg_opa = 1,
        })
        pcall(function() visual:set_size(zw, box.h) end)
        pcall(function() visual:set_pos(zx, box.y) end)
        no_border(visual)
        pcall(function()
            visual:set_style({ border_width = 0, pad = 0, bg_opa = 1, bg_color = "#000000" })
        end)
        no_click(visual)
        track_raise(visual)

        local bar_w = math.max(8, zw - 8)
        if i == 1 then
            charge_max_w = bar_w
        end
        local bar = lvgl.container(visual, {
            x = 4, y = 4, w = bar_w, h = bar_h,
            bg_color = "#352B69", radius = 4, pad = 0,
            border_width = 0,
        })
        pcall(function() bar:set_size(bar_w, bar_h) end)
        pcall(function() bar:set_pos(4, 4) end)
        no_border(bar)
        no_click(bar)

        local fill = lvgl.container(bar, {
            x = 0, y = 0, w = 1, h = bar_h,
            bg_color = "#F7C35F", radius = 4, pad = 0,
            border_width = 0,
        })
        pcall(function() fill:set_size(1, bar_h) end)
        no_border(fill)
        no_click(fill)
        charge_fills[#charge_fills + 1] = fill

        local btn_y = 4 + bar_h + 4
        local btn_h = box.h - btn_y - 4
        if btn_h < 32 then
            btn_h = math.max(28, box.h - bar_h - 8)
        end
        local btn = lvgl.button(visual, {
            x = 4, y = btn_y, w = bar_w, h = btn_h,
            text = s.text, radius = 8,
            bg_color = s.bg, text_color = "#111111",
            border_width = 0, pad = 0,
        })
        pcall(function() btn:set_size(bar_w, btn_h) end)
        no_border(btn)
        lock_hit(btn)
        local idx = i
        btn:on("pressed", function() on_pressed(idx) end)
        btn:on("released", function() on_released(idx) end)
        zone_buttons[#zone_buttons + 1] = btn
        track_raise(btn)

        layout[i] = { zx = zx, zw = zw }
    end

    -- Pass 2: device-only hit widgets LAST so they sit on top of bars +
    -- buttons and cover the full control height plus ~20px into the
    -- playfield. Skip on WEB_SIM: WASM hit-test often ignores opa=0.
    if not web_sim then
        for i, rec in ipairs(layout) do
            local hx = rec.zx
            local hw = rec.zw
            local hy = box.y - EXTRA
            local hh2 = box.h + EXTRA
            local hit = lvgl.container(ctx.parent, {
                x = hx, y = hy, w = hw, h = hh2,
                pad = 0, radius = 0, border_width = 0, bg_opa = 0,
            })
            pcall(function() hit:set_size(hw, hh2) end)
            pcall(function() hit:set_pos(hx, hy) end)
            no_border(hit)
            pcall(function()
                hit:set_style({ bg_opa = 0, border_width = 0, pad = 0 })
            end)
            lock_hit(hit)
            local idx = i
            hit:on("pressed", function() on_pressed(idx) end)
            hit:on("released", function() on_released(idx) end)
            pcall(function() hit:move_foreground() end)
            pcall(function() hit:move_to_index(-1) end)
            track_raise(hit)
        end
    end

    return { jump_btn = zone_buttons[2] }
end

function M.raise()
    for _, obj in ipairs(raise_list) do
        pcall(function() obj:move_foreground() end)
        pcall(function() obj:move_to_index(-1) end)
    end
end

function M.pointer(x, y, pressed)
    x = tonumber(x) or 0
    y = tonumber(y) or 0
    if pressed then
        if not ptr_down then
            ptr_down = true
            header_pending = 0
            if y >= (ctrl_y - ctrl_extra) then
                local third = 1
                if ctrl_w > 0 then
                    third = math.floor((x - ctrl_x) * 3 / ctrl_w) + 1
                end
                if third < 1 then third = 1 end
                if third > 3 then third = 3 end
                on_pressed(third)
            elseif y < header_h then
                for i, rec in ipairs(header_hits) do
                    if x >= rec.x and x < (rec.x + rec.w) then
                        header_pending = i
                        break
                    end
                end
            end
        end
    else
        if ptr_down then
            ptr_down = false
            if held ~= 0 then
                on_released(held)
            elseif header_pending ~= 0 then
                local rec = header_hits[header_pending]
                if rec and rec.cb then
                    rec.cb()
                end
            end
            header_pending = 0
        end
    end
end

function M.flush()
    if release_armed == 0 then
        return
    end
    local i = held
    release_armed = 0
    held = 0
    local cb = zone_cbs[i]
    if cb then cb(false) end
end

function M.set_enabled(enabled)
    local colors = {
        { on = "#C7F0BD", off = "#6A8A64" },
        { on = "#F8DFA5", off = "#8A7A58" },
        { on = "#C7F0BD", off = "#6A8A64" },
    }
    for i, b in ipairs(zone_buttons) do
        local c = colors[i]
        if c then
            pcall(function()
                b:set_style({
                    bg_color = enabled and c.on or c.off,
                    border_width = 0,
                    pad = 0,
                })
            end)
        end
    end
end

function M.set_charge(aim, charge)
    charge = tonumber(charge) or 0
    if charge < 0 then charge = 0 end
    if charge > 1 then charge = 1 end
    local active = 2
    aim = tonumber(aim) or 0
    if aim < 0 then active = 1
    elseif aim > 0 then active = 3 end
    for i = 1, 3 do
        local w = 1
        if i == active and charge > 0 then
            w = math.max(1, math.floor(charge * charge_max_w + 0.5))
        end
        local obj = charge_fills[i]
        if obj then
            pcall(function() obj:set_size(w, bar_h) end)
        end
    end
end

return M
