local board_manager = require("board_manager")
local lvgl = require("lvgl")
local capability = require("capability")
local json = require("json")
local system = require("system")

local DEFAULT_URL = "http://192.168.1.10:8000/data.json"

local function trim(s)
    return tostring(s or ""):match("^%s*(.-)%s*$")
end

local function resolve_url()
    local a = rawget(_G, "args")
    if type(a) == "table" then
        local u = trim(a.url or a.endpoint or a.URL)
        if u ~= "" then
            if not u:match("^https?://") then
                error("args.url must start with http:// or https://")
            end
            return u
        end
    end
    return DEFAULT_URL
end

local URL = resolve_url()
print("code_usage_dashboard url:", URL)

local C = {
    bg = "#100604",
    panel = "#1b0a04",
    panel2 = "#0a0302",
    border = "#8a320d",
    glow = "#5c1b06",
    text = "#ffb35c",
    dim = "#b85a20",
    bright = "#ffd18a",
    ok = "#ff7a1a",
    warn = "#ff9f1a",
    bad = "#ff2b1f",
}

local function clamp(v, lo, hi)
    v = tonumber(v) or 0
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function round(v) return math.floor((tonumber(v) or 0) + 0.5) end
local function fmt_pct(v) return string.format("%d%%", round(v)) end

local function now_hm()
    local ok, s = pcall(system.date, "%H:%M")
    if ok and s and #s > 0 then return s end
    return "--:--"
end

local function num_date(fmt)
    local ok, s = pcall(system.date, fmt)
    if ok and s then return tonumber(s) end
    return nil
end

local function extract_json(text)
    if not text then return nil end
    local p = string.find(text, "{", 1, true)
    if not p then return nil end
    return string.sub(text, p)
end

local function fetch_data()
    local ok, out, err = capability.call("http_request", {
        url = URL, method = "GET", timeout_ms = 5000, max_body_bytes = 4096,
    }, { source_cap = "lua_script" })
    if not ok then return nil, err or "request failed" end
    local body = extract_json(out)
    if not body then return nil, "no json body" end
    local dec_ok, data = pcall(json.decode, body)
    if not dec_ok then return nil, "json parse failed" end
    return data, nil
end

local function five_h_reset_in(reset_text)
    local s = tostring(reset_text or "")
    if s == "" then return "--:--" end
    return s
end

local month_no = {Jan=1,January=1,Feb=2,February=2,Mar=3,March=3,Apr=4,April=4,May=5,Jun=6,June=6,Jul=7,July=7,Aug=8,August=8,Sep=9,Sept=9,September=9,Oct=10,October=10,Nov=11,November=11,Dec=12,December=12}
local function days_from_civil(y,m,d)
    y = y - ((m <= 2) and 1 or 0)
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = m + ((m > 2) and -3 or 9)
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end
local function abs_min(y,m,d,hh,mm) return days_from_civil(y,m,d) * 1440 + hh * 60 + mm end
local function now_abs_min()
    local y,m,d = num_date("%Y"), num_date("%m"), num_date("%d")
    local h,mi = num_date("%H"), num_date("%M")
    if not y or not m or not d or not h or not mi then return nil end
    return abs_min(y,m,d,h,mi), y
end
local function fmt_left(total)
    total = math.max(0, math.floor(total or 0))
    local dd = math.floor(total / 1440)
    local rem = total % 1440
    local hh = math.floor(rem / 60)
    local mi = rem % 60
    if dd > 0 then return string.format("%dd %dh", dd, hh) end
    if hh > 0 then return string.format("%dh %dm", hh, mi) end
    return string.format("%dm", mi)
end
local function weekly_reset_in(reset_text)
    local s = tostring(reset_text or "")
    if s:match("^%d+d%s+%d+h$") or s:match("^%d+h%s+%d+m$") or s:match("^%d+m$") then return s end
    local hh, mi, day, mon = s:match("(%d%d?):(%d%d)%s+on%s+(%d%d?)%s+(%a+)")
    local now, year = now_abs_min()
    mon = month_no[mon]
    if not now or not mon then return "--" end
    local target = abs_min(year, mon, tonumber(day), tonumber(hh), tonumber(mi))
    if target < now then target = abs_min(year + 1, mon, tonumber(day), tonumber(hh), tonumber(mi)) end
    return fmt_left(target - now)
end

local function quota_color(remain)
    if remain < 30 then return C.bad end
    if remain < 60 then return C.warn end
    return C.ok
end

local FONT5 = {
 A={"01110","10001","10001","11111","10001","10001","10001"},
 C={"01111","10000","10000","10000","10000","10000","01111"},
 D={"11110","10001","10001","10001","10001","10001","11110"},
 E={"11111","10000","10000","11110","10000","10000","11111"},
 G={"01111","10000","10000","10111","10001","10001","01111"},
 O={"01110","10001","10001","10001","10001","10001","01110"},
 S={"01111","10000","10000","01110","00001","00001","11110"},
 U={"10001","10001","10001","10001","10001","10001","01110"},
 X={"10001","01010","00100","00100","00100","01010","10001"},
}
local FONT3 = {
 ["0"]={"111","101","101","101","111"}, ["1"]={"010","110","010","010","111"},
 ["2"]={"111","001","111","100","111"}, ["3"]={"111","001","111","001","111"},
 ["4"]={"101","101","111","001","001"}, ["5"]={"111","100","111","001","111"},
 ["6"]={"111","100","111","101","111"}, ["7"]={"111","001","010","010","010"},
 ["8"]={"111","101","111","101","111"}, ["9"]={"111","101","111","001","111"},
 [":"]={"000","010","000","010","000"}, ["-"]={"000","000","111","000","000"}, ["%"]={"11001","11010","00100","01011","10011"},
}

local function draw_pixels(parent, font, text, x, y, scale, color, spacing)
    local cx = x
    for i = 1, #text do
        local ch = string.sub(text, i, i)
        if ch == " " then
            cx = cx + scale * 4
        else
            local pat = font[ch]
            if pat then
                for row = 1, #pat do
                    local line = pat[row]
                    for col = 1, #line do
                        if string.sub(line, col, col) == "1" then
                            lvgl.container(parent, {
                                x = cx + (col - 1) * scale,
                                y = y + (row - 1) * scale,
                                w = scale,
                                h = scale,
                                bg_color = color,
                                bg_opa = 255,
                                border_width = 0,
                                radius = 0,
                                pad = 0,
                            })
                        end
                    end
                end
                cx = cx + #pat[1] * scale + spacing
            end
        end
    end
end

local function pixel_width(font, text, scale, spacing)
    local w = 0
    text = tostring(text or "")
    for i = 1, #text do
        local ch = string.sub(text, i, i)
        if ch == " " then
            w = w + scale
        else
            local pat = font[ch]
            if pat then w = w + #pat[1] * scale + spacing end
        end
    end
    return w
end

local function draw_pixels_right(parent, font, text, right_x, y, scale, color, spacing)
    local w = pixel_width(font, text, scale, spacing)
    draw_pixels(parent, font, text, right_x - w, y, scale, color, spacing)
end

-- 固定像素格更新时间：不 clean、不重建对象，避免右上角闪烁。
local function make_time_pixels(parent, x, y, scale, spacing, on_color, off_color)
    local cells = {}
    local char_w = 3
    for pos = 1, 5 do
        cells[pos] = {}
        local ox = x + (pos - 1) * (char_w * scale + spacing)
        for row = 1, 5 do
            cells[pos][row] = {}
            for col = 1, char_w do
                cells[pos][row][col] = lvgl.container(parent, {
                    x = ox + (col - 1) * scale,
                    y = y + (row - 1) * scale,
                    w = scale,
                    h = scale,
                    bg_color = off_color,
                    bg_opa = 120,
                    border_width = 0,
                    radius = 0,
                    pad = 0,
                })
            end
        end
    end

    return function(text)
        text = tostring(text or "--:--")
        for pos = 1, 5 do
            local ch = string.sub(text, pos, pos)
            local pat = FONT3[ch] or FONT3["-"]
            for row = 1, 5 do
                local line = pat[row]
                for col = 1, char_w do
                    local on = string.sub(line, col, col) == "1"
                    cells[pos][row][col]:set_style({
                        bg_color = on and on_color or off_color,
                        bg_opa = on and 255 or 65,
                    })
                end
            end
        end
    end
end

local panel_handle, io_handle, width, height, panel_if =
    board_manager.get_display_lcd_params("display_lcd")

lvgl.init(panel_handle, io_handle, width, height, panel_if, {
    buffer_lines = 10, tick_ms = 5, task_period_ms = 10,
})

local function no_scroll(obj)
    pcall(function() obj:set_scroll({ dir = "none", scrollbar = "off" }) end)
end

local ok, err = pcall(function()
    local scr = lvgl.create_screen()
    scr:set_style({ bg_color = C.bg })
    no_scroll(scr)

    local margin = 8
    local usable_w = width - margin * 2
    local header_h = 41
    local gap = 8
    local footer_h = 0
    local footer_gap = 0
    local cards_y = header_h + margin
    local card_h = math.floor((height - cards_y - margin - gap - footer_h - footer_gap) / 2)
    if card_h < 80 then card_h = 80 end

    for i = 0, 7 do
        lvgl.container(scr, {
            x = i * 32, y = height - 24,
            w = 18, h = 2,
            bg_color = C.glow, bg_opa = 160,
            border_width = 0, radius = 0, pad = 0,
        })
    end

    -- 标题下移，与右侧时间的像素数字顶线对齐。
    draw_pixels(scr, FONT5, "CODEX USAGE", margin, 13, 2, C.text, 2)

    local time_box_w = 74
    local time_box = lvgl.container(scr, {
        x = width - margin - time_box_w,
        y = 7,
        w = time_box_w,
        h = 26,
        bg_color = C.panel2,
        bg_opa = 255,
        border_color = C.border,
        border_width = 1,
        radius = 0,
        pad = 0,
    })
    no_scroll(time_box)
    local update_time = make_time_pixels(time_box, 10, 5, 3, 2, C.bright, C.panel2)
    update_time(now_hm())

    local function make_card(y, title)
        local card = lvgl.container(scr, {
            x = margin, y = y, w = usable_w, h = card_h,
            bg_color = C.panel, bg_opa = 255,
            border_color = C.border, border_width = 2,
            radius = 0, pad = 0,
        })
        no_scroll(card)
        lvgl.container(card, { x = 4, y = 4, w = usable_w - 8, h = 2, bg_color = C.glow, bg_opa = 180, border_width = 0, radius = 0, pad = 0 })

        local title_y = 10
        lvgl.label(card, { text = title, x = 12, y = title_y, text_color = C.text })

        local pct = lvgl.container(card, {
            x = usable_w - 12 - 62, y = title_y,
            w = 62, h = 20,
            bg_opa = 0,
            border_width = 0,
            radius = 0,
            pad = 0,
        })
        no_scroll(pct)
        draw_pixels_right(pct, FONT3, "--%", 62, 1, 3, C.bright, 2)

        local bar_h = 16
        local bar_y = title_y + 24
        local reset_y = bar_y + bar_h + 8
        if reset_y > card_h - 18 then
            reset_y = card_h - 18
            bar_y = reset_y - 12 - bar_h
        end
        local track_w = usable_w - 24
        local track = lvgl.container(card, {
            x = 12, y = bar_y, w = track_w, h = bar_h,
            bg_color = "#070302", bg_opa = 255,
            border_color = C.dim, border_width = 2,
            radius = 0, pad = 0,
        })
        no_scroll(track)
        local fill = lvgl.container(track, {
            x = 0, y = 0, w = 1, h = bar_h,
            bg_color = C.ok, bg_opa = 255,
            border_width = 0, radius = 0, pad = 0,
        })
        for i = 1, 9 do
            lvgl.container(track, {
                x = math.floor(track_w * i / 10), y = 3, w = 1, h = bar_h - 6,
                bg_color = "#3a1407", bg_opa = 200,
                border_width = 0, radius = 0, pad = 0,
            })
        end

        local reset = lvgl.label(card, {
            text = "Reset at --", x = 12, y = reset_y, text_color = C.bright,
        })
        return { pct = pct, track_w = track_w, fill = fill, reset = reset, bar_h = bar_h }
    end

    local five = make_card(cards_y, "5H QUOTA")
    local weekly = make_card(cards_y + card_h + gap, "WEEKLY QUOTA")

    local function set_card(card, remain_pct, reset_in_text)
        local remain = clamp(remain_pct, 0, 100)
        local color = quota_color(remain)
        local fill_w = math.floor(card.track_w * remain / 100)
        if remain > 0 and fill_w < 3 then fill_w = 3 end
        card.fill:set_size(fill_w, card.bar_h)
        card.fill:set_style({ bg_color = color, radius = 0 })
        card.pct:clean()
        draw_pixels_right(card.pct, FONT3, fmt_pct(remain), 62, 1, 3, color, 2)
        card.reset:set_text(tostring(reset_in_text or "--"))
    end

    local last_data = nil
    local function refresh()
        local data, ferr = fetch_data()
        if not data then
            print("fetch failed:", ferr)
            return
        end
        last_data = data
        local u = data.usage or data
        set_card(five, u.five_h_pct, "Reset in " .. five_h_reset_in(u.five_h_reset))
        set_card(weekly, u.weekly_pct, "Reset in " .. weekly_reset_in(u.weekly_reset))
    end

    scr:load()
    refresh()

    local last_fetch = system.millis()
    local last_clock = 0
    while true do
        lvgl.process_events(100)
        local ms = system.millis()
        if ms - last_clock >= 1000 then
            update_time(now_hm())
            last_clock = ms
        end
        if ms - last_fetch >= 60000 then
            refresh()
            last_fetch = ms
        end
    end
end)

local deinit_ok, deinit_err = pcall(lvgl.deinit)
if not deinit_ok then print("lvgl deinit skipped:", deinit_err) end
if not ok then error(err) end
