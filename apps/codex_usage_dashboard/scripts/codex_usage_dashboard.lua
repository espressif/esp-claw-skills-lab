local display = require("display")
local delay = require("delay")
local capability = require("capability")
local json = require("json")
local system = require("system")

local a = type(args) == "table" and args or {}
local URL = type(a.url) == "string" and a.url:match("^%s*(.-)%s*$") or ""
local C = { bg = "#132623", panel = "#213D36", text = "#9CB5A6", bright = "#F1F2DC", ok = "#88DBAF", warn = "#EAC377", bad = "#F08B79", track = "#365249" }

local function num_date(fmt)
    return tonumber(system.date(fmt))
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

local function fetch_data()
    local ok, out, err = capability.call("http_request", {
        url = URL, method = "GET", timeout_ms = 5000, max_body_bytes = 4096,
    }, { source_cap = "codex_usage_dashboard", max_output_bytes = 8192 })
    if not ok then return nil, err or "request failed" end
    if type(out) ~= "string" then return nil, "invalid HTTP response" end
    -- http_request returns a status line followed by the response body.
    local status, suffix, body = out:match("^HTTP (%d+)([^\n]*)\n(.*)$")
    status = tonumber(status)
    if not status or status < 200 or status >= 300 then return nil, "HTTP " .. tostring(status or "invalid response") end
    if suffix ~= "" then return nil, "truncated HTTP response" end
    local decoded, data = pcall(json.decode, body)
    if not decoded or type(data) ~= "table" then return nil, "invalid JSON object" end
    local usage = data.usage or data
    if type(usage) ~= "table" then return nil, "invalid usage object" end
    for _, field in ipairs({ "five_h_pct", "weekly_pct" }) do
        local value = usage[field]
        if type(value) ~= "number" or value ~= value or value < 0 or value > 100 then
            return nil, "invalid " .. field
        end
    end
    return usage
end

local function main()
    local screen <close> = display.open()
    local info = screen:info()
    local w, h = info.width, info.height
    assert(w >= 160 and h >= 240, "dashboard requires at least 160x240 pixels")
    local wide = w >= 480 and w > h
    local gap, margin = 10, w >= 480 and 24 or 8
    local card_w = wide and (w - margin * 2 - gap) // 2 or w - margin * 2
    local card_h = wide and h - 140 or (h - 112) // 2
    local cards = { { x = margin, y = 48, title = "5H", value = nil }, { x = wide and margin + card_w + gap or margin, y = wide and 48 or 48 + card_h + gap, title = "WEEKLY", value = nil } }
    local status, dirty, refresh_requested = "READY", true, true
    local last_fetch, last_clock = -60000, ""
    local touch_id, target, press_x, press_y, moved
    local function text(x, y, value, size, color, max_w)
        value = value:gsub("[%c]", " ")
        local opts = { color = color, font_size = size }
        local tw = screen:measure_text(value, opts)
        while max_w and tw > max_w and opts.font_size > 12 do
            opts.font_size = opts.font_size - 1
            tw = screen:measure_text(value, opts)
        end
        if max_w and tw > max_w then
            repeat value = value:sub(1, (utf8.offset(value, -1) or 1) - 1); tw = screen:measure_text(value .. "...", opts) until tw <= max_w or #value == 0
            value = value .. "..."
        end
        screen:text(x, y, value, opts)
    end
    local function render()
        screen:begin({ clear = C.bg })
        text(margin, 12, w < 240 and "USAGE" or "CODEX USAGE", wide and 24 or 18, C.bright, w - margin - 50)
        screen:fill_round_rect(w - 40, 4, 32, 32, 9, C.panel)
        screen:line(w - 29, 15, w - 19, 25, C.bright)
        screen:line(w - 19, 15, w - 29, 25, C.bright)
        for _, card in ipairs(cards) do
            local x, y = card.x, card.y
            local color = not card.value and C.text or (card.value < 30 and C.bad or (card.value < 60 and C.warn or C.ok))
            screen:fill_round_rect(x, y + 3, card_w, card_h, 10, "#0C1D1A")
            screen:fill_round_rect(x, y, card_w, card_h, 10, C.panel)
            local value = card.value and string.format("%d%%", math.floor(card.value + 0.5)) or "--"
            if card_h >= 120 then
                text(x + 14, y + 14, card.title .. " REMAINING", wide and 24 or 18, C.text, card_w - 28)
                text(x + 14, y + card_h // 3, value, math.min(64, card_h // 3), color, card_w - 28)
            else
                text(x + 10, y + 8, card.title, 12, C.text, card_w // 2 - 12)
                text(x + card_w // 2, y + 4, value, 22, color, card_w // 2 - 10)
            end
            local bar_y = y + card_h - 32
            screen:fill_round_rect(x + 10, bar_y, card_w - 20, 8, 4, C.track)
            if card.value and card.value > 0 then screen:fill_rect(x + 10, bar_y, math.floor((card_w - 20) * card.value / 100), 8, color) end
            text(x + 10, y + card_h - 18, "RESET " .. (card.reset or "--"), wide and 18 or 12, C.text, card_w - 20)
        end
        text(margin, h - 52, status, wide and 18 or 12, C.text, w - margin * 2)
        local bw = math.min(w - margin * 2, 180)
        screen:fill_round_rect(margin, h - 32, bw, 28, 8, C.ok)
        local tw, th = screen:measure_text("REFRESH", { font_size = 14 })
        screen:text(margin + (bw - tw) // 2, h - 32 + (28 - th) // 2, "REFRESH", { color = C.bg, font_size = 14 })
        if wide then text(w - margin - 60, h - 26, system.date("%H:%M"), 16, C.text) end
        screen:present()
        dirty = false
    end
    print("[codex_usage_dashboard] ready")
    while true do
        if info.touch_available then
            local point
            for _, p in ipairs(screen:touch().points) do if not touch_id or p.id == touch_id then point = p; break end end
            if point then
                if not touch_id then
                    touch_id, press_x, press_y, moved = point.id, point.x, point.y, false
                    target = point.x >= w - 40 and point.x < w - 8 and point.y >= 4 and point.y < 36 and "exit" or (point.x >= margin and point.x < margin + math.min(w - margin * 2, 180) and point.y >= h - 32 and point.y < h - 4 and "refresh") or nil
                end
                moved = moved or math.abs(point.x - press_x) > 8 or math.abs(point.y - press_y) > 8
            elseif touch_id then
                if not moved and target == "exit" then break end
                if not moved and target == "refresh" then refresh_requested = true end
                touch_id, target = nil, nil
            end
        end
        local now = system.millis()
        if refresh_requested or now - last_fetch >= 60000 then
            refresh_requested = false
            if URL == "" then status = "SET URL IN ARGS"
            elseif not URL:match("^https?://[^%s/]+") then
                status = "INVALID URL"
                print("[codex_usage_dashboard] ERROR: args.url must be an HTTP(S) endpoint")
            else
                status = "UPDATING..."
                render()
                local data, err = fetch_data()
                if data then
                    cards[1].value, cards[1].reset = data.five_h_pct, tostring(data.five_h_reset or "--")
                    cards[2].value, cards[2].reset = data.weekly_pct, weekly_reset_in(data.weekly_reset)
                    status = (a.demo == true and "DEMO " or "UPDATED ") .. system.date("%H:%M")
                else
                    status = cards[1].value and "STALE / RETRY" or "FAILED / RETRY"
                    print("[codex_usage_dashboard] ERROR: " .. tostring(err))
                end
            end
            last_fetch, dirty = system.millis(), true
        end
        local clock = system.date("%H:%M")
        if clock ~= last_clock then last_clock, dirty = clock, true end
        if dirty then render() end
        delay.delay_ms(50)
    end
end

local ok, err = xpcall(main, debug.traceback)
if not ok then
    print("[codex_usage_dashboard] ERROR: " .. tostring(err))
    error(err, 0)
end
