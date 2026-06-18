-- token_usage_dashboard.lua
local board_manager = require("board_manager")
local lvgl = require("lvgl")
local change_ui = require("change_ui")
local storage = require("storage")
local delay = require("delay")
local config = require("token_usage_config")
local remote = require("token_usage_remote")
local env_mod = require("token_usage_env")

local touch_ok, lcd_touch = pcall(require, "lcd_touch")
if not touch_ok then
    lcd_touch = nil
end

local M = {}

function M.run(raw_args)
    raw_args = type(raw_args) == "table" and raw_args or {}
    local ctx = config.build_ctx(raw_args)

    print(string.format("[token_usage] dashboard host=%s port=%d poll_ms=%d", ctx.host, ctx.port, ctx.cursor_poll_ms))

    local ui = {
        remote = remote.new_remote_state(),
        last = {
            date = "",
            weekday = "",
            time = "",
            weather = "",
            city = "",
            weather_desc = "",
            state_index = -1,
            state_panel_key = "",
            usage_pct = -1,
        },
        touch = {
            handle = nil,
            tracking = false,
            swipe_handled = false,
            start_x = 0,
            start_y = 0,
        },
        poll_times = {
            cursor = 0,
            token = 0,
            aux = 0,
            weather = 0,
            aux_account_done = false,
        },
        standing = {
            pill_status = {},
            window_active = false,
            window_hour = -1,
            day_key = "",
            blink_on = true,
            last_blink_ms = 0,
        },
        led = {
            strip = nil,
            chase_active = false,
            chase_idx = 0,
            last_chase_ms = 0,
        },
        objects = {},
        env_objects = {},
        env_state = nil,
        pages = nil,
        display_w = 0,
        display_h = 0,
    }

    for i = 1, config.PILL_TOTAL do
        ui.standing.pill_status[i] = 0
    end

    local stack_offsets = {
        { 0, 0 },
        { 1, 0 },
        { 0, 1 },
        { 1, 1 },
    }

    local function create_label(parent, text, x, y, width, color)
        local label = lvgl.label(parent, {
            text = text,
            x = x,
            y = y,
            text_color = color,
        })
        if width and width > 0 then
            label:set_size(width, 24)
        end
        return label
    end

    local function create_box(parent, x, y, w, h, bg_color, radius, border_color, border_width, bg_opa)
        return lvgl.object(parent, {
            x = x,
            y = y,
            w = w,
            h = h,
            bg_color = bg_color,
            bg_opa = bg_opa or 255,
            radius = radius or 0,
            border_color = border_color or bg_color,
            border_width = border_width or 0,
            pad = 0,
        })
    end

    local function create_stack_label(parent, text, color, width, layer_count)
        local stack = {
            labels = {},
            width = width or 0,
        }
        local count = math.max(1, math.min(layer_count or 1, #stack_offsets))

        for i = 1, count do
            local off = stack_offsets[i]
            local label = lvgl.label(parent, {
                text = text,
                x = off[1],
                y = off[2],
                text_color = color,
            })
            if width and width > 0 then
                label:set_size(width, 24)
            end
            stack.labels[i] = label
        end

        function stack:set_text(value)
            local out = type(value) == "string" and value or tostring(value or "")
            for _, label in ipairs(self.labels) do
                label:set_text(out)
            end
        end

        function stack:set_color(color_value)
            for _, label in ipairs(self.labels) do
                label:set_style({ text_color = color_value })
            end
        end

        function stack:set_thickness(thickness)
            local layers = math.max(1, math.min(thickness or 1, #self.labels))
            for i, label in ipairs(self.labels) do
                label:set_style({ opa = i <= layers and 255 or 0 })
            end
        end

        function stack:set_pos(x, y)
            for i, label in ipairs(self.labels) do
                local off = stack_offsets[i]
                label:set_pos(x + off[1], y + off[2])
            end
        end

        function stack:align(name, x, y)
            for i, label in ipairs(self.labels) do
                local off = stack_offsets[i]
                label:align(name, (x or 0) + off[1], (y or 0) + off[2])
            end
        end

        function stack:set_width(new_width)
            if not new_width or new_width <= 0 then
                return
            end
            self.width = new_width
            for _, label in ipairs(self.labels) do
                label:set_size(new_width, 24)
            end
        end

        stack:set_thickness(count)
        return stack
    end

    local function create_canvas(parent, x, y, w, h, fill_color)
        local canvas = lvgl.canvas(parent, {
            x = x,
            y = y,
            w = w,
            h = h,
            color_format = "rgb565",
        })
        canvas:fill_bg(fill_color or config.COLOR.bg, 255)
        return canvas
    end

    local function canvas_plot(canvas, w, h, x, y, color)
        if x < 0 or y < 0 or x >= w or y >= h then
            return
        end
        canvas:set_px(x, y, color, 255)
    end

    local function canvas_draw_line(canvas, w, h, x1, y1, x2, y2, color)
        local dx = math.abs(x2 - x1)
        local sx = x1 < x2 and 1 or -1
        local dy = -math.abs(y2 - y1)
        local sy = y1 < y2 and 1 or -1
        local err = dx + dy

        while true do
            canvas_plot(canvas, w, h, x1, y1, color)
            if x1 == x2 and y1 == y2 then
                break
            end
            local e2 = err * 2
            if e2 >= dy then
                err = err + dy
                x1 = x1 + sx
            end
            if e2 <= dx then
                err = err + dx
                y1 = y1 + sy
            end
        end
    end

    local function canvas_fill_circle(canvas, w, h, cx, cy, radius, color)
        for y = -radius, radius do
            for x = -radius, radius do
                if x * x + y * y <= radius * radius then
                    canvas_plot(canvas, w, h, cx + x, cy + y, color)
                end
            end
        end
    end

    local function canvas_fill_rect(canvas, w, h, x, y, rw, rh, color)
        for yy = y, y + rh - 1 do
            for xx = x, x + rw - 1 do
                canvas_plot(canvas, w, h, xx, yy, color)
            end
        end
    end

    local function canvas_fill_circle_f(canvas, w, h, cx, cy, radius, color)
        local r2 = radius * radius
        local bound = math.ceil(radius)
        for dy = -bound, bound do
            for dx = -bound, bound do
                if dx * dx + dy * dy <= r2 then
                    canvas_plot(canvas, w, h, math.floor(cx + dx + 0.5), math.floor(cy + dy + 0.5), color)
                end
            end
        end
    end

    local function canvas_draw_thick_point(canvas, w, h, x, y, color, radius)
        radius = radius or 1
        local r2 = radius * radius
        local bound = math.ceil(radius)
        local xi = math.floor(x + 0.5)
        local yi = math.floor(y + 0.5)
        for dy = -bound, bound do
            for dx = -bound, bound do
                local px = xi + dx
                local py = yi + dy
                local dist_x = px - x
                local dist_y = py - y
                if dist_x * dist_x + dist_y * dist_y <= r2 then
                    canvas_plot(canvas, w, h, px, py, color)
                end
            end
        end
    end

    local function canvas_draw_stroke_line(canvas, w, h, x1, y1, x2, y2, color, stroke_w)
        stroke_w = stroke_w or 2
        local radius = stroke_w / 2
        local steps = math.max(math.abs(x2 - x1), math.abs(y2 - y1), 1) * 4
        steps = math.floor(steps)
        for i = 0, steps do
            local t = i / steps
            canvas_draw_thick_point(
                canvas, w, h,
                x1 + (x2 - x1) * t,
                y1 + (y2 - y1) * t,
                color,
                radius)
        end
    end

    local function canvas_draw_bezier(canvas, w, h, x0, y0, x1, y1, x2, y2, x3, y3, color, stroke_w)
        stroke_w = stroke_w or 2
        local steps = math.max(math.abs(x3 - x0), math.abs(y3 - y0), 1) * 4
        steps = math.floor(steps)
        local px, py
        for i = 0, steps do
            local t = i / steps
            local u = 1 - t
            local x = u * u * u * x0 + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t * x3
            local y = u * u * u * y0 + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t * y3
            if px then
                canvas_draw_stroke_line(canvas, w, h, px, py, x, y, color, stroke_w)
            end
            px, py = x, y
        end
    end

    local function draw_stand_icon()
        local canvas = ui.objects.person_canvas
        if not canvas then
            return
        end

        local w = config.LAYOUT.person_w
        local h = config.LAYOUT.person_h
        local color = config.COLOR.white
        local stroke = 2

        canvas:fill_bg(config.COLOR.bg, 255)

        -- Chair (16x24 SVG viewBox)
        canvas_draw_stroke_line(canvas, w, h, 1, 10, 1, 16.5, color, stroke)
        canvas_draw_stroke_line(canvas, w, h, 1, 23, 1, 16.5, color, stroke)
        canvas_draw_stroke_line(canvas, w, h, 1, 16.5, 7, 16.5, color, stroke)
        canvas_draw_stroke_line(canvas, w, h, 7, 16.5, 7, 23, color, stroke)

        -- Person
        canvas_fill_circle_f(canvas, w, h, 10.5, 2.5, 2.5, color)
        canvas_draw_stroke_line(canvas, w, h, 9.5, 7, 11.5, 11, color, stroke)
        canvas_draw_stroke_line(canvas, w, h, 11.5, 11, 15, 14, color, stroke)
        canvas_draw_stroke_line(canvas, w, h, 9.5, 7, 9.5, 14.5, color, stroke)
        canvas_draw_bezier(canvas, w, h, 9.5, 14.5, 10.1667, 15.5, 11.5, 19, 11.5, 23, color, stroke)
    end

    local function ring_canvas_center()
        local center = math.floor(config.LAYOUT.ring_size / 2)
        return center, center
    end

    local function ring_inner_radius()
        return math.floor(config.LAYOUT.ring_size / 2) - config.LAYOUT.ring_width
    end

    local function ring_outer_radius()
        return math.floor(config.LAYOUT.ring_size / 2)
    end

    local function ring_angle_deg(cx, cy, x, y)
        local angle = math.deg(math.atan(y - cy, x - cx))
        if angle < 0 then
            angle = angle + 360
        end
        return angle
    end

    local function ring_sweep_deg(start_deg, end_deg)
        local sweep = end_deg - start_deg
        if sweep <= 0 then
            sweep = sweep + 360
        end
        return sweep
    end

    local function ring_angle_in_segment(angle_deg, start_deg, sweep)
        local dist = angle_deg - start_deg
        while dist < 0 do
            dist = dist + 360
        end
        while dist >= 360 do
            dist = dist - 360
        end
        return dist <= sweep
    end

    local function canvas_fill_ring_segment(canvas, w, h, cx, cy, inner_r, outer_r, start_deg, end_deg, color)
        local sweep = ring_sweep_deg(start_deg, end_deg)
        local inner_r2 = (inner_r - 0.5) * (inner_r - 0.5)
        local outer_r2 = (outer_r + 0.5) * (outer_r + 0.5)
        local min_x = math.max(0, math.floor(cx - outer_r - 1))
        local max_x = math.min(w - 1, math.ceil(cx + outer_r + 1))
        local min_y = math.max(0, math.floor(cy - outer_r - 1))
        local max_y = math.min(h - 1, math.ceil(cy + outer_r + 1))

        for y = min_y, max_y do
            for x = min_x, max_x do
                local dx = x - cx
                local dy = y - cy
                local dist2 = dx * dx + dy * dy
                if dist2 >= inner_r2 and dist2 <= outer_r2 then
                    local angle = ring_angle_deg(cx, cy, x, y)
                    if ring_angle_in_segment(angle, start_deg, sweep) then
                        canvas_plot(canvas, w, h, x, y, color)
                    end
                end
            end
        end
    end

    local function draw_usage_ring(pct)
        local canvas = ui.objects.usage_ring_canvas
        if not canvas then
            return
        end

        local w = config.LAYOUT.ring_size
        local h = config.LAYOUT.ring_size
        local cx, cy = ring_canvas_center()
        local inner_r = ring_inner_radius()
        local outer_r = ring_outer_radius()
        local track_start = config.RING_START_ANGLE
        local track_end = track_start + 360

        canvas:fill_bg(config.COLOR.bg, 255)
        canvas_fill_ring_segment(
            canvas, w, h, cx, cy, inner_r, outer_r, track_start, track_end, config.COLOR.panel_soft)

        if pct <= 0 then
            return
        end

        local color = config.pct_color_hex(pct)
        local span = math.floor((360 * pct) / 100 + 0.5)
        if span < 4 then
            span = 4
        end
        if span > 360 then
            span = 360
        end

        canvas_fill_ring_segment(
            canvas, w, h, cx, cy, inner_r, outer_r, track_start, track_start + span, color)
    end

    local function canvas_draw_cloud(canvas)
        canvas_fill_circle(canvas, 24, 24, 8, 12, 5, config.COLOR.white)
        canvas_fill_circle(canvas, 24, 24, 13, 9, 4, config.COLOR.white)
        canvas_fill_circle(canvas, 24, 24, 17, 12, 5, config.COLOR.white)
        canvas_fill_rect(canvas, 24, 24, 5, 12, 15, 5, config.COLOR.white)
    end

    local function weather_icon_kind(desc)
        if config.contains_ci(desc, "thunder") then
            return "thunder"
        end
        if config.contains_ci(desc, "snow") or config.contains_ci(desc, "sleet") or config.contains_ci(desc, "blizzard") or config.contains_ci(desc, "ice") then
            return "snow"
        end
        if config.contains_ci(desc, "rain") or config.contains_ci(desc, "drizzle") or config.contains_ci(desc, "shower") then
            return "rain"
        end
        if config.contains_ci(desc, "mist") or config.contains_ci(desc, "fog") or config.contains_ci(desc, "haze") then
            return "fog"
        end
        if config.contains_ci(desc, "wind") or config.contains_ci(desc, "breeze") or config.contains_ci(desc, "gust") then
            return "wind"
        end
        if config.contains_ci(desc, "overcast") then
            return "overcast"
        end
        if config.contains_ci(desc, "sunny") or config.contains_ci(desc, "clear") then
            return "sunny"
        end
        if config.contains_ci(desc, "cloud") then
            return "cloudy"
        end
        return "cloudy"
    end

    local function draw_weather_icon(canvas, kind)
        if not canvas then
            return
        end

        canvas:fill_bg(config.COLOR.bg, 255)

        if kind == "sunny" then
            canvas_fill_circle(canvas, 24, 24, 12, 12, 5, config.COLOR.yellow)
            canvas_draw_line(canvas, 24, 24, 12, 1, 12, 5, config.COLOR.yellow)
            canvas_draw_line(canvas, 24, 24, 12, 19, 12, 23, config.COLOR.yellow)
            canvas_draw_line(canvas, 24, 24, 1, 12, 5, 12, config.COLOR.yellow)
            canvas_draw_line(canvas, 24, 24, 19, 12, 23, 12, config.COLOR.yellow)
            canvas_draw_line(canvas, 24, 24, 4, 4, 7, 7, config.COLOR.yellow)
            canvas_draw_line(canvas, 24, 24, 17, 17, 20, 20, config.COLOR.yellow)
            canvas_draw_line(canvas, 24, 24, 4, 20, 7, 17, config.COLOR.yellow)
            canvas_draw_line(canvas, 24, 24, 17, 7, 20, 4, config.COLOR.yellow)
            return
        end

        if kind == "overcast" then
            canvas_draw_cloud(canvas)
            return
        end

        if kind == "rain" then
            canvas_draw_cloud(canvas)
            canvas_draw_line(canvas, 24, 24, 7, 17, 5, 21, config.COLOR.blue)
            canvas_draw_line(canvas, 24, 24, 12, 17, 10, 21, config.COLOR.blue)
            canvas_draw_line(canvas, 24, 24, 17, 17, 15, 21, config.COLOR.blue)
            return
        end

        if kind == "thunder" then
            canvas_draw_cloud(canvas)
            canvas_draw_line(canvas, 24, 24, 9, 15, 13, 15, config.COLOR.yellow)
            canvas_draw_line(canvas, 24, 24, 13, 15, 10, 21, config.COLOR.yellow)
            canvas_draw_line(canvas, 24, 24, 10, 21, 15, 21, config.COLOR.yellow)
            return
        end

        if kind == "snow" or kind == "wind" then
            canvas_draw_line(canvas, 24, 24, 12, 3, 12, 21, config.COLOR.blue)
            canvas_draw_line(canvas, 24, 24, 4, 7, 20, 17, config.COLOR.blue)
            canvas_draw_line(canvas, 24, 24, 4, 17, 20, 7, config.COLOR.blue)
            return
        end

        if kind == "fog" then
            canvas_draw_cloud(canvas)
            canvas_draw_line(canvas, 24, 24, 4, 18, 20, 18, config.COLOR.white)
            canvas_draw_line(canvas, 24, 24, 6, 21, 18, 21, config.COLOR.white)
            return
        end

        canvas_fill_circle(canvas, 24, 24, 10, 6, 4, config.COLOR.yellow)
        canvas_draw_cloud(canvas)
    end

    local function update_state_panel()
        local cursor = ui.remote.cursor
        local state_index = 0
        local is_done = cursor.hook_status == "green"
            and cursor.hook_event ~= ""
            and (cursor.hook_event == "stop"
                or config.contains_ci(cursor.hook_event, "complete")
                or config.contains_ci(cursor.hook_event, "final")
                or config.contains_ci(cursor.hook_message, "final answer"))

        if not cursor.cursor_running then
            state_index = 0
        elseif cursor.mode == "error"
                or cursor.mode == "blocked"
                or cursor.mode == "confirm"
                or cursor.hook_status == "red" then
            state_index = 2
        elseif cursor.agent_active then
            state_index = 1
        elseif is_done then
            state_index = 3
        else
            state_index = 0
        end

        local panel_key = tostring(state_index) .. ":" .. tostring(cursor.hook_status or "")
        if panel_key == ui.last.state_panel_key then
            return
        end

        ui.last.state_panel_key = panel_key
        ui.last.state_index = state_index

        local active_color = config.state_color_hex(state_index, cursor.hook_status)
        for i = 1, 4 do
            if i - 1 == state_index then
                ui.objects.state_dots[i]:set_style({
                    bg_color = active_color,
                    bg_opa = 255,
                    border_width = 0,
                    radius = math.floor(config.LAYOUT.radio_size / 2),
                })
                ui.objects.state_labels[i]:set_color(active_color)
                ui.objects.state_labels[i]:set_thickness(3)
            else
                ui.objects.state_dots[i]:set_style({
                    bg_opa = 0,
                    border_color = config.COLOR.pill_gray,
                    border_width = 3,
                    radius = math.floor(config.LAYOUT.radio_size / 2),
                })
                ui.objects.state_labels[i]:set_color(config.COLOR.text_dim)
                ui.objects.state_labels[i]:set_thickness(1)
            end
        end
    end

    local function usage_pct_from_remote()
        local current_balance = tonumber(ui.remote.token.balance_str) or 0
        local account_balance = tonumber(ui.remote.token.account_balance) or 0
        local pct = 0

        if account_balance > 0 and current_balance >= 0 and current_balance <= account_balance then
            pct = math.floor(((account_balance - current_balance) * 100) / account_balance + 0.5)
        elseif account_balance > 0 and current_balance > account_balance then
            pct = 0
        end

        if pct < 0 then
            pct = 0
        end
        if pct > 100 then
            pct = 100
        end

        return pct
    end

    local function update_usage_display()
        local pct = usage_pct_from_remote()
        if pct == ui.last.usage_pct then
            return
        end

        ui.last.usage_pct = pct
        local color = config.pct_color_hex(pct)
        ui.objects.usage_pct:set_text(string.format("%d%%", pct))
        ui.objects.usage_pct:align("top_mid", 0, config.LAYOUT.usage_pct_y)
        ui.objects.usage_pct:set_color(color)
        draw_usage_ring(pct)
    end

    local ENV_TOP_BAR_Y_OFFSET = -15

    local function build_top_bar(parent, refs, y_offset)
        y_offset = y_offset or 0
        local top_y = config.LAYOUT.top_y + y_offset
        local weather_icon_y = config.LAYOUT.weather_icon_y + y_offset

        refs.date = create_label(parent, "--/--", config.LAYOUT.date_x, top_y, 50, config.COLOR.white)
        refs.weekday = create_label(parent, "---", config.LAYOUT.weekday_x, top_y, 36, config.COLOR.white)
        refs.time = create_label(parent, "--:--", config.LAYOUT.time_x, top_y, 40, config.COLOR.white)
        refs.weather = create_label(parent, "--", config.LAYOUT.weather_x, top_y, 44, config.COLOR.white)
        refs.weather_dot = create_box(parent, config.LAYOUT.weather_dot_x, top_y, 4, 4, config.COLOR.white, 2, config.COLOR.white, 0, 255)
        refs.weather_icon = create_canvas(parent, config.LAYOUT.weather_icon_x, weather_icon_y, 24, 24, config.COLOR.bg)
        refs.city = create_label(parent, "--", config.LAYOUT.city_x, top_y, 80, config.COLOR.white)
    end

    local function apply_top_bar_time(refs, time_info)
        if not refs or not refs.date then
            return
        end

        if time_info then
            refs.date:set_text(time_info.date_text)
            refs.weekday:set_text(time_info.weekday_text)
            refs.time:set_text(time_info.time_text)
            if time_info.weekday_num == 0 or time_info.weekday_num == 6 then
                refs.weekday:set_style({ text_color = config.COLOR.green })
            else
                refs.weekday:set_style({ text_color = config.COLOR.white })
            end
        else
            refs.date:set_text("--/--")
            refs.weekday:set_text("---")
            refs.time:set_text("--:--")
            refs.weekday:set_style({ text_color = config.COLOR.white })
        end
    end

    local function update_top_bar()
        local time_info = config.current_time_info()
        local weather = ui.remote.weather
        local weather_text = "--"

        if time_info then
            if time_info.date_text ~= ui.last.date
                    or time_info.weekday_text ~= ui.last.weekday
                    or time_info.time_text ~= ui.last.time then
                ui.last.date = time_info.date_text
                ui.last.weekday = time_info.weekday_text
                ui.last.time = time_info.time_text
                apply_top_bar_time(ui.objects, time_info)
                apply_top_bar_time(ui.env_objects, time_info)
            end
        elseif ui.last.date ~= "--/--" then
            ui.last.date = "--/--"
            ui.last.weekday = "---"
            ui.last.time = "--:--"
            apply_top_bar_time(ui.objects, nil)
            apply_top_bar_time(ui.env_objects, nil)
        end

        if weather.query_ok then
            local temp = weather.temperature
            if type(temp) == "string" then
                temp = temp:gsub("\194\176C", "")
                temp = temp:gsub("\194\176", "")
            else
                temp = "--"
            end
            weather_text = temp ~= "--" and (temp .. " C") or "--"
        end

        if weather_text ~= ui.last.weather then
            ui.last.weather = weather_text
            if ui.objects.weather then
                ui.objects.weather:set_text(weather_text)
            end
            if ui.env_objects.weather then
                ui.env_objects.weather:set_text(weather_text)
            end
        end

        local city = weather.location ~= "" and weather.location or "--"
        if city ~= ui.last.city then
            ui.last.city = city
            if ui.objects.city then
                ui.objects.city:set_text(city)
            end
            if ui.env_objects.city then
                ui.env_objects.city:set_text(city)
            end
        end

        if weather.description ~= ui.last.weather_desc then
            ui.last.weather_desc = weather.description
            local kind = weather_icon_kind(weather.description)
            draw_weather_icon(ui.objects.weather_icon, kind)
            draw_weather_icon(ui.env_objects.weather_icon, kind)
        end

        return time_info
    end

    local function set_pill_color(index, color)
        local pill = ui.objects.pills[index]
        if pill then
            pill:set_style({
                bg_color = color,
                bg_opa = 255,
                border_width = 0,
                radius = config.LAYOUT.pill_radius,
            })
        end
    end

    local function led_cleanup()
        if ui.led.strip then
            pcall(function()
                ui.led.strip:clear()
                ui.led.strip:refresh()
                ui.led.strip:close()
            end)
            ui.led.strip = nil
        end
        ui.led.chase_active = false
    end

    local function init_led_strip()
        local ok, led_strip = pcall(require, "led_strip")
        if not ok then
            print("[token_usage] led_strip module unavailable")
            return
        end

        local strip, err = led_strip.new(ctx.led_gpio, ctx.led_count)
        if not strip then
            print("[token_usage] led_strip init failed: " .. tostring(err))
            return
        end

        ui.led.strip = strip
        print(string.format("[token_usage] led strip init gpio=%d count=%d",
            ctx.led_gpio, ctx.led_count))
    end

    local function led_boot_chase()
        if not ui.led.strip then
            return
        end

        for index = 0, ctx.led_count - 1 do
            ui.led.strip:clear()
            ui.led.strip:set_pixel(index, 0, 8, 0)
            ui.led.strip:refresh()
            delay.delay_ms(config.LED_CHASE_STEP_MS)
        end
        delay.delay_ms(300)
        ui.led.strip:clear()
        ui.led.strip:refresh()
    end

    local function led_chase_start()
        if not ui.led.strip then
            return
        end
        ui.led.chase_active = true
        ui.led.chase_idx = 0
        ui.led.last_chase_ms = config.now_ms()
    end

    local function led_chase_stop()
        if not ui.led.strip then
            return
        end
        ui.led.chase_active = false
        ui.led.strip:clear()
        ui.led.strip:refresh()
    end

    local function led_chase_tick()
        if not ui.led.strip or not ui.led.chase_active then
            return
        end

        local tick_ms = config.now_ms()
        if tick_ms - ui.led.last_chase_ms < config.LED_CHASE_INTERVAL_MS then
            return
        end
        ui.led.last_chase_ms = tick_ms

        ui.led.strip:clear()
        ui.led.strip:set_pixel(ui.led.chase_idx, 0, 8, 0)
        ui.led.strip:refresh()
        ui.led.chase_idx = (ui.led.chase_idx + 1) % ctx.led_count
    end

    local function write_standing_state()
        if not ui.skill_dir then
            return
        end
        local count = 0
        for i = 1, config.PILL_TOTAL do
            if ui.standing.pill_status[i] == 1 then
                count = count + 1
            end
        end
        local payload = {
            count = count,
            day_key = ui.standing.day_key or "",
            updated_at = system.date("%Y-%m-%d %H:%M:%S"),
        }
        local path = storage.join_path(ui.skill_dir, "standing_state.json")
        local enc_ok, encoded = pcall(json.encode, payload)
        if not enc_ok then
            return
        end
        pcall(storage.write_file, path, encoded)
    end

    local function reset_standing_day(day_key)
        ui.standing.day_key = day_key
        ui.standing.window_active = false
        ui.standing.window_hour = -1
        ui.standing.blink_on = true
        ui.standing.last_blink_ms = 0
        led_chase_stop()
        for i = 1, config.PILL_TOTAL do
            ui.standing.pill_status[i] = 0
            set_pill_color(i, config.COLOR.pill_gray)
        end
        write_standing_state()
    end

    local function confirm_standing_if_needed()
        if not ui.standing.window_active then
            return
        end

        local index = ui.standing.window_hour + 1
        if index < 1 or index > config.PILL_TOTAL then
            return
        end

        ui.standing.pill_status[index] = 1
        ui.standing.window_active = false
        led_chase_stop()
        set_pill_color(index, config.COLOR.blue)
        write_standing_state()
        print(string.format("[token_usage] standing confirmed pill=%d hour=%d",
            index, ui.standing.window_hour + 10))
    end

    local function update_standing(time_info)
        if not time_info then
            return
        end

        if ui.standing.day_key ~= time_info.day_key then
            reset_standing_day(time_info.day_key)
        end

        local in_window = time_info.minute >= 50 and time_info.minute < 60 and time_info.hour >= 10
        local window_hour = time_info.hour - 10
        local tick_ms = config.now_ms()

        if in_window and window_hour >= 0 and window_hour < config.PILL_TOTAL then
            if (not ui.standing.window_active) or ui.standing.window_hour ~= window_hour then
                if ui.standing.window_active then
                    local prev_index = ui.standing.window_hour + 1
                    if prev_index >= 1 and prev_index <= config.PILL_TOTAL and ui.standing.pill_status[prev_index] == 0 then
                        ui.standing.pill_status[prev_index] = 2
                    end
                end

                if ui.standing.pill_status[window_hour + 1] == 0 then
                    ui.standing.window_active = true
                    ui.standing.window_hour = window_hour
                    ui.standing.blink_on = true
                    ui.standing.last_blink_ms = tick_ms
                    led_chase_start()
                    print(string.format("[token_usage] standing reminder active hour=%d pill=%d",
                        time_info.hour, window_hour + 1))
                else
                    ui.standing.window_active = false
                    ui.standing.window_hour = window_hour
                    led_chase_stop()
                end
            end

            if ui.standing.window_active and tick_ms - ui.standing.last_blink_ms >= 1500 then
                ui.standing.blink_on = not ui.standing.blink_on
                ui.standing.last_blink_ms = tick_ms
            end

            if ui.standing.window_active then
                led_chase_tick()
            end
        else
            if ui.standing.window_active then
                local prev_index = ui.standing.window_hour + 1
                if prev_index >= 1 and prev_index <= config.PILL_TOTAL and ui.standing.pill_status[prev_index] == 0 then
                    ui.standing.pill_status[prev_index] = 2
                end
            end
            if ui.standing.window_active then
                led_chase_stop()
            end
            ui.standing.window_active = false
        end

        for i = 1, config.PILL_TOTAL do
            if ui.standing.window_active and i == ui.standing.window_hour + 1 then
                set_pill_color(i, ui.standing.blink_on and config.COLOR.blue or config.COLOR.pill_gray)
            elseif ui.standing.pill_status[i] == 1 then
                set_pill_color(i, config.COLOR.blue)
            else
                set_pill_color(i, config.COLOR.pill_gray)
            end
        end
    end

    local function handle_touch()
        if not ui.touch.handle or not lcd_touch then
            return
        end

        local ok, info = pcall(lcd_touch.poll, ui.touch.handle)
        if not ok or type(info) ~= "table" then
            return
        end

        if info.just_pressed then
            ui.touch.tracking = true
            ui.touch.swipe_handled = false
            ui.touch.start_x = info.x or 0
            ui.touch.start_y = info.y or 0
            return
        end

        if ui.touch.tracking and not ui.touch.swipe_handled and ui.pages then
            local cur_x = info.x or ui.touch.start_x
            local cur_y = info.y or ui.touch.start_y
            local dx = cur_x - ui.touch.start_x
            local dy = cur_y - ui.touch.start_y
            if ui.pages:handle_swipe(dx, dy) then
                ui.touch.swipe_handled = true
                ui.touch.tracking = false
                return
            end
        end

        if info.just_released then
            local end_x = info.x or ui.touch.start_x
            local end_y = info.y or ui.touch.start_y
            local dx = end_x - ui.touch.start_x
            local dy = end_y - ui.touch.start_y

            if ui.touch.tracking and not ui.touch.swipe_handled and ui.pages then
                if ui.pages:handle_swipe(dx, dy) then
                    ui.touch.swipe_handled = true
                end
            end

            if ui.touch.tracking and not ui.touch.swipe_handled
                    and ui.pages and ui.pages:is_token_page()
                    and math.abs(dx) < 12 and math.abs(dy) < 12 then
                confirm_standing_if_needed()
            end

            ui.touch.tracking = false
            ui.touch.swipe_handled = false
            return
        end

        if info.pressed then
            ui.touch.tracking = true
        end
    end

    local function disable_scroll(obj)
        if not obj then
            return
        end
        pcall(function()
            obj:set_scroll({
                dir = "none",
                scrollbar = "off",
                snap_x = "none",
                snap_y = "none",
            })
        end)
    end

    local function build_token_page(parent)
        ui.objects.token_page = create_box(
            parent, 0, 0, ui.display_w, ui.display_h, config.COLOR.bg, 0, config.COLOR.bg, 0, 255)
        disable_scroll(ui.objects.token_page)

        build_top_bar(ui.objects.token_page, ui.objects)

        create_box(
            ui.objects.token_page,
            config.LAYOUT.panel_x,
            config.LAYOUT.panel_y,
            config.LAYOUT.panel_w,
            config.LAYOUT.panel_h,
            config.COLOR.panel,
            config.LAYOUT.panel_radius,
            config.COLOR.panel,
            0,
            255)

        ui.objects.state_dots = {}
        ui.objects.state_labels = {}
        local state_names = { "IDLE", "RUNNING", "ALERT", "DONE" }
        for i = 1, 4 do
            local y = config.LAYOUT.radio_y0 + (i - 1) * config.LAYOUT.radio_step
            ui.objects.state_dots[i] = create_box(
                ui.objects.token_page,
                config.LAYOUT.radio_x,
                y,
                config.LAYOUT.radio_size,
                config.LAYOUT.radio_size,
                config.COLOR.blue,
                math.floor(config.LAYOUT.radio_size / 2),
                config.COLOR.pill_gray,
                3,
                0)
            ui.objects.state_labels[i] = create_stack_label(
                ui.objects.token_page,
                state_names[i],
                config.COLOR.text_dim,
                76,
                3)
            ui.objects.state_labels[i]:set_pos(config.LAYOUT.label_x, y - 1)
            ui.objects.state_labels[i]:set_thickness(1)
        end

        ui.objects.usage_box = create_box(
            ui.objects.token_page,
            config.LAYOUT.usage_box_x,
            config.LAYOUT.usage_box_y,
            config.LAYOUT.usage_box_w,
            config.LAYOUT.usage_box_h,
            config.COLOR.bg,
            0,
            config.COLOR.bg,
            0,
            255)

        ui.objects.usage_ring_canvas = create_canvas(
            ui.objects.usage_box,
            config.LAYOUT.ring_x,
            config.LAYOUT.ring_y,
            config.LAYOUT.ring_size,
            config.LAYOUT.ring_size,
            config.COLOR.bg)

        ui.objects.usage_title = create_stack_label(ui.objects.usage_box, "Usage", config.COLOR.text_muted, 0, 3)
        ui.objects.usage_title:align("top_mid", 0, config.LAYOUT.usage_title_y)

        ui.objects.usage_pct = create_stack_label(ui.objects.usage_box, "0%", config.COLOR.blue, 0, 4)
        ui.objects.usage_pct:align("top_mid", 0, config.LAYOUT.usage_pct_y)

        ui.objects.model_line1 = create_stack_label(ui.objects.usage_box, "Deepseek", config.COLOR.white, 0, 4)
        ui.objects.model_line1:align("top_mid", 0, config.LAYOUT.model_line1_y)

        ui.objects.model_line2 = create_stack_label(ui.objects.usage_box, "v4-pro", config.COLOR.white, 0, 4)
        ui.objects.model_line2:align("top_mid", 0, config.LAYOUT.model_line2_y)

        ui.objects.pills = {}
        for i = 1, config.PILL_TOTAL do
            ui.objects.pills[i] = create_box(
                ui.objects.token_page,
                config.LAYOUT.pill_x0 + (i - 1) * config.LAYOUT.pill_step,
                config.LAYOUT.pill_y,
                config.LAYOUT.pill_w,
                config.LAYOUT.pill_h,
                config.COLOR.pill_gray,
                config.LAYOUT.pill_radius,
                config.COLOR.pill_gray,
                0,
                255)
        end

        ui.objects.person_canvas = create_canvas(
            ui.objects.token_page,
            config.LAYOUT.person_x,
            config.LAYOUT.person_y,
            config.LAYOUT.person_w,
            config.LAYOUT.person_h,
            config.COLOR.bg)
        draw_stand_icon()
    end

    local function yield_to_lvgl(step_ms, rounds)
        step_ms = step_ms or 30
        rounds = rounds or 1
        for _ = 1, rounds do
            -- process_events(timeout) yields to the lvgl task while draining callbacks.
            pcall(lvgl.process_events, step_ms)
        end
    end

    local SCREEN_CREATE_MAX_ATTEMPTS = 40
    local LVGL_SETTLE_TICKS = 8

    local function try_create_screen(label, attempt)
        yield_to_lvgl(50, 1)
        local ok, scr = pcall(lvgl.create_screen)
        if ok then
            if attempt and attempt > 1 then
                print(string.format("[token_usage] %s screen ok on attempt %d", label, attempt))
            else
                print(string.format("[token_usage] %s screen ok", label))
            end
            return scr
        end
        print(string.format("[token_usage] %s screen retry %d: %s",
            label, attempt or 1, tostring(scr)))
        return nil, scr
    end

    local function tick_ui_init()
        local init = ui.init
        if not init or init.phase == "done" then
            return true
        end

        if init.phase == "lvgl_settle" then
            yield_to_lvgl(50, 1)
            init.settle_ticks = (init.settle_ticks or 0) + 1
            if init.settle_ticks >= LVGL_SETTLE_TICKS then
                init.phase = "create_token_screen"
                init.screen_attempts = 0
                print("[token_usage] creating screens...")
            end
            return false
        end

        if init.phase == "create_token_screen" then
            init.screen_attempts = (init.screen_attempts or 0) + 1
            local scr = try_create_screen("token", init.screen_attempts)
            if not scr then
                if init.screen_attempts >= SCREEN_CREATE_MAX_ATTEMPTS then
                    error("token screen failed after " .. tostring(SCREEN_CREATE_MAX_ATTEMPTS) .. " attempts")
                end
                return false
            end
            init.token_screen = scr
            init.phase = "create_env_screen"
            init.screen_attempts = 0
            return false
        end

        if init.phase == "create_env_screen" then
            init.screen_attempts = (init.screen_attempts or 0) + 1
            local scr = try_create_screen("env", init.screen_attempts)
            if not scr then
                if init.screen_attempts >= SCREEN_CREATE_MAX_ATTEMPTS then
                    error("env screen failed after " .. tostring(SCREEN_CREATE_MAX_ATTEMPTS) .. " attempts")
                end
                return false
            end
            init.env_screen = scr
            init.phase = "create_blackout_screen"
            init.screen_attempts = 0
            return false
        end

        if init.phase == "create_blackout_screen" then
            init.screen_attempts = (init.screen_attempts or 0) + 1
            local scr = try_create_screen("blackout", init.screen_attempts)
            if not scr then
                if init.screen_attempts >= SCREEN_CREATE_MAX_ATTEMPTS then
                    error("blackout screen failed after " .. tostring(SCREEN_CREATE_MAX_ATTEMPTS) .. " attempts")
                end
                return false
            end
            init.blackout_screen = scr
            init.phase = "assemble_pages"
            return false
        end

        if init.phase == "assemble_pages" then
            ui.pages = change_ui.create({
                lvgl = lvgl,
                display_w = ui.display_w,
                display_h = ui.display_h,
                assets_dir = init.assets_dir,
                token_screen = init.token_screen,
                env_screen = init.env_screen,
                blackout_screen = init.blackout_screen,
                delay_fn = function(ms)
                    delay.delay_ms(ms)
                end,
            })
            ui.objects.screen = ui.pages.token_screen
            ui.pages:begin_env_layout()
            init.phase = "env_layout"
            print("[token_usage] building UI...")
            return false
        end

        if init.phase == "env_layout" then
            if ui.pages:tick_env_layout() then
                init.phase = "build_token"
                print("[token_usage] building token page...")
            end
            return false
        end

        if init.phase == "build_token" then
            build_token_page(ui.pages.token_page)
            build_top_bar(ui.pages.env_screen, ui.env_objects, ENV_TOP_BAR_Y_OFFSET)
            draw_weather_icon(ui.objects.weather_icon, "cloudy")
            draw_weather_icon(ui.env_objects.weather_icon, "cloudy")
            update_state_panel()
            update_usage_display()
            ui.pages.token_screen:load()

            local touch_handle, touch_err = board_manager.get_lcd_touch_handle("lcd_touch")
            if touch_handle and lcd_touch then
                ui.touch.handle = touch_handle
                pcall(lcd_touch.sync, touch_handle)
            elseif touch_err then
                print("[token_usage] lcd touch unavailable: " .. tostring(touch_err))
            end

            ui.env_state = env_mod.init()
            pcall(env_mod.update_widgets, ui.pages, ui.env_state)

            init.phase = "done"
            remote.reset_poll_schedule(ui.poll_times)
            print("[token_usage] UI init complete")
            return true
        end

        return false
    end

    local function init_runtime()
        -- Clear any stale LVGL singleton left by a prior failed/replaced job.
        pcall(lvgl.deinit)
        yield_to_lvgl(50, 6)

        -- display_lcd / lcd_touch are already initialized at boot (emote uses the panel).
        -- Re-initing here races emote and can hang or crash; just resolve handles.
        local panel_handle, io_handle, width, height, panel_if =
            board_manager.get_display_lcd_params("display_lcd")
        if not panel_handle then
            error("display_lcd unavailable: " .. tostring(io_handle))
        end

        init_led_strip()

        -- Let emote finish its current frame before lvgl.init acquires display ownership.
        local emote_settle_ms = config.as_int(raw_args.emote_settle_ms, 5000, 500, 15000)
        if emote_settle_ms > 0 then
            delay.delay_ms(emote_settle_ms)
        end

        ui.display_w = math.floor(tonumber(width) or 0)
        ui.display_h = math.floor(tonumber(height) or 0)
        if ui.display_w <= 0 or ui.display_h <= 0 then
            error("display_lcd returned invalid size: " .. tostring(width) .. "x" .. tostring(height))
        end

        lvgl.init(panel_handle, io_handle, ui.display_w, ui.display_h, panel_if, {
            buffer_lines = 10,
            tick_ms = 5,
            -- Slower lvgl task during boot reduces lock contention with screen creation.
            task_period_ms = 20,
        })

        local script_path = config.as_string(raw_args.script_path, config.DEFAULT_SCRIPT_PATH)
        local skill_dir = script_path:match("^(.+)/scripts/") or "/fatfs/skills/token_usage"
        ui.skill_dir = skill_dir
        local assets_dir = storage.join_path(skill_dir, "assets")

        ui.init = {
            phase = "lvgl_settle",
            assets_dir = assets_dir,
            settle_ticks = 0,
            screen_attempts = 0,
        }
        print("[token_usage] lvgl ready, UI build deferred to main loop...")
    end

    local function cleanup()
        led_cleanup()
        if ui.env_state then
            env_mod.close(ui.env_state)
            ui.env_state = nil
        end
        pcall(lvgl.deinit)
    end

    local function run()
        local boot_delay_ms = tonumber(raw_args.boot_delay_ms) or 3000
        if boot_delay_ms > 0 then
            delay.delay_ms(boot_delay_ms)
        end

        local ui_ok, ui_err = xpcall(init_runtime, debug.traceback)
        if not ui_ok then
            print("[token_usage] UI init failed, poll-only mode: " .. tostring(ui_err))
            while true do
                remote.poll_remote_updates(ctx, ui.remote, ui.poll_times)
                delay.delay_ms(100)
            end
        end

        while true do
            local ui_ready = ui.init and ui.init.phase == "done"
            local ui_failed = ui.init and ui.init.phase == "failed"
            local ui_booting = ui.init and not ui_ready and not ui_failed

            if ui_booting then
                pcall(lvgl.process_events, 30)
            else
                lvgl.process_events(20)
            end

            if ui.init and not ui_ready and not ui_failed then
                local ok, err = xpcall(tick_ui_init, debug.traceback)
                if not ok then
                    print("[token_usage] UI build failed, poll-only mode: " .. tostring(err))
                    ui.init.phase = "failed"
                    pcall(lvgl.deinit)
                end
            end

            -- Cursor status first, then refresh UI before any slow HTTP/graphics work.
            if ui_ready then
                remote.poll_cursor_status(ctx, ui.remote, ui.poll_times)

                handle_touch()

                if not ui.touch.tracking then
                    local time_info = update_top_bar()
                    if ui.pages and ui.pages:is_token_page() then
                        update_state_panel()
                        update_usage_display()
                        update_standing(time_info)
                    end
                end

                if ui.env_state and ui.pages and ui.pages:env_layout_ready() then
                    if env_mod.poll_if_due(ui.env_state, config.now_ms(), 3000) then
                        pcall(env_mod.update_widgets, ui.pages, ui.env_state)
                    end
                end

                remote.poll_background_updates(ctx, ui.remote, ui.poll_times)
            elseif ui_failed then
                remote.poll_remote_updates(ctx, ui.remote, ui.poll_times)
            end
        end
    end

    local ok, err = xpcall(run, debug.traceback)
    cleanup()
    if not ok then
        print("[token_usage] ERROR: " .. tostring(err))
        error(err)
    end
end

return M
