local arg_schema = require("arg_schema")
local board_manager = require("board_manager")
local capability = require("capability")
local delay = require("delay")
local display = require("display")
local json = require("json")

local TAG = "[stock_quotes_display]"

local DEFAULT_SECIDS = "1.000001,0.399001,0.399006"
local DEFAULT_REFRESH_MS = 15000
local DEFAULT_RUN_TIME_MS = 0
local DEFAULT_DETAIL_INDEX = 1
local MIN_REFRESH_MS = 1000
local MAX_REFRESH_MS = 600000
local HTTP_TIMEOUT_MS = 10000
local HTTP_MAX_BODY_BYTES = 32768
local LOOP_SLICE_MS = 100
local EASTMONEY_URL = "https://push2.eastmoney.com/api/qt/ulist.np/get"
local EASTMONEY_UT = "b2884a393a59ad64002292a3e90d46a5"
local EASTMONEY_FIELDS = table.concat({
    "f2", "f3", "f4", "f6", "f12", "f14", "f15", "f16", "f17",
}, ",")

local ARG_SCHEMA = {
    refresh_ms = arg_schema.int({ default = DEFAULT_REFRESH_MS, min = MIN_REFRESH_MS, max = MAX_REFRESH_MS }),
    run_time_ms = arg_schema.int({ default = DEFAULT_RUN_TIME_MS, min = 0 }),
    rotate = arg_schema.bool({ default = true }),
    detail_index = arg_schema.int({ default = DEFAULT_DETAIL_INDEX, min = 1 }),
}

local raw_args = type(args) == "table" and args or {}
local ctx = arg_schema.parse(raw_args, ARG_SCHEMA)

local COLORS = {
    bg = { r = 4, g = 8, b = 16 },
    panel = { r = 12, g = 22, b = 36 },
    panel_alt = { r = 18, g = 30, b = 48 },
    border = { r = 48, g = 70, b = 96 },
    text = { r = 232, g = 238, b = 246 },
    muted = { r = 132, g = 148, b = 166 },
    green = { r = 54, g = 210, b = 124 },
    red = { r = 245, g = 84, b = 92 },
    yellow = { r = 240, g = 190, b = 72 },
    blue = { r = 86, g = 156, b = 255 },
    error = { r = 255, g = 126, b = 126 },
}

local DISPLAY_NAMES = {
    ["000001"] = "Shanghai",
    ["399001"] = "Shenzhen",
    ["399006"] = "ChiNext",
}

local function raw_string(key, default)
    local value = raw_args[key]
    if type(value) == "string" and value ~= "" then
        return value
    end
    return default
end

local function sanitize_secids(value)
    value = tostring(value or "")
    value = string.gsub(value, "%s+", "")
    if value == "" then
        return DEFAULT_SECIDS
    end
    if not string.match(value, "^[0-9%.,]+$") then
        error("args.secids must be a comma-separated Eastmoney secid list such as 1.600519,0.000001")
    end
    return value
end

local function is_ascii_text(value)
    value = tostring(value or "")
    for i = 1, #value do
        local byte = string.byte(value, i)
        if byte < 32 or byte > 126 then
            return false
        end
    end
    return value ~= ""
end

local function safe_text(value, fallback)
    local text = tostring(value or "")
    if is_ascii_text(text) then
        return text
    end
    return fallback or "--"
end

local function clipped_text(value, max_len, fallback)
    local text = safe_text(value, fallback)
    if #text > max_len then
        return string.sub(text, 1, max_len - 3) .. "..."
    end
    return text
end

local function num(value)
    if type(value) == "number" then
        return value
    end
    if type(value) == "string" then
        return tonumber(value)
    end
    return nil
end

local function fmt_num(value, decimals)
    local n = num(value)
    if not n then
        return "--"
    end
    return string.format("%." .. tostring(decimals or 2) .. "f", n)
end

local function fmt_pct(value)
    local n = num(value)
    if not n then
        return "--"
    end
    return string.format("%+.2f%%", n)
end

local function fmt_compact(value)
    local n = num(value)
    local sign = ""
    local abs_n

    if not n then
        return "--"
    end
    if n < 0 then
        sign = "-"
        n = -n
    end
    abs_n = n
    if abs_n >= 1000000000000 then
        return string.format("%s%.2fT", sign, abs_n / 1000000000000)
    end
    if abs_n >= 1000000000 then
        return string.format("%s%.2fB", sign, abs_n / 1000000000)
    end
    if abs_n >= 1000000 then
        return string.format("%s%.2fM", sign, abs_n / 1000000)
    end
    if abs_n >= 1000 then
        return string.format("%s%.2fK", sign, abs_n / 1000)
    end
    return string.format("%s%.0f", sign, abs_n)
end

local function quote_color(item)
    local pct = num(item and item.f3)
    if not pct then
        return COLORS.text
    end
    if pct > 0 then
        return COLORS.red
    end
    if pct < 0 then
        return COLORS.green
    end
    return COLORS.text
end

local function display_name(item, max_len)
    local code = safe_text(item and item.f12, "----")
    local name = DISPLAY_NAMES[code] or safe_text(item and item.f14, code)

    return clipped_text(name, max_len or 12, code)
end

local function fmt_change(item)
    local pct = fmt_pct(item and item.f3)
    local change = fmt_num(item and item.f4, 2)

    if pct == "--" and change == "--" then
        return "--"
    end
    return pct .. "  " .. change
end

local function build_url(secids)
    return EASTMONEY_URL
        .. "?ut=" .. EASTMONEY_UT
        .. "&fltt=2&invt=2"
        .. "&fields=" .. EASTMONEY_FIELDS
        .. "&secids=" .. secids
end

local function strip_http_response(output)
    local status_text, body = string.match(tostring(output or ""), "^HTTP%s+(%d+)[^\n]*\n(.*)$")
    local status = tonumber(status_text)

    if not status then
        return nil, nil, "unexpected http_request output: " .. tostring(output)
    end
    if status < 200 or status >= 300 then
        return status, nil, "HTTP status " .. tostring(status)
    end
    return status, body or "", nil
end

local function fetch_quotes(secids)
    local ok, output, err = capability.call("http_request", {
        url = build_url(secids),
        method = "GET",
        headers = {
            ["Accept"] = "application/json",
            ["User-Agent"] = "ESP-Claw/stock-quotes-display",
        },
        timeout_ms = HTTP_TIMEOUT_MS,
        max_body_bytes = HTTP_MAX_BODY_BYTES,
    }, {
        source_cap = "stock_quotes_display",
        max_output_bytes = HTTP_MAX_BODY_BYTES + 128,
    })
    local body
    local decoded

    if not ok then
        error("http_request failed: err=" .. tostring(err) .. " out=" .. tostring(output))
    end

    _, body, err = strip_http_response(output)
    if err then
        error(err)
    end

    decoded = json.decode(body)
    if type(decoded) ~= "table" or type(decoded.data) ~= "table" or type(decoded.data.diff) ~= "table" then
        error("Eastmoney response missing data.diff")
    end

    return decoded.data.diff
end

local function draw_label_value(x, y, w, label, value, value_color)
    local label_w = 62

    display.draw_text(x, y, label, {
        color = COLORS.muted,
        font_size = 12,
        bg = COLORS.panel,
    })
    display.draw_text_aligned(x + label_w, y, w - label_w, 14, value, {
        color = value_color or COLORS.text,
        font_size = 12,
        bg = COLORS.panel,
        align = "right",
        valign = "top",
    })
end

local function draw_metric_row(x, y, w, row_h, label, value, value_color, label_font, value_font)
    local label_w = (w >= 360) and 128 or 74

    display.draw_text_aligned(x, y, label_w, row_h, label, {
        color = COLORS.muted,
        font_size = label_font,
        bg = COLORS.panel,
        align = "left",
        valign = "middle",
    })
    display.draw_text_aligned(x + label_w, y, w - label_w, row_h, value, {
        color = value_color or COLORS.text,
        font_size = value_font,
        bg = COLORS.panel,
        align = "right",
        valign = "middle",
    })
end

local function draw_error(width, height, message)
    display.begin_frame({ clear = true, color = COLORS.bg })
    display.fill_round_rect(8, 8, width - 16, height - 16, 12, COLORS.panel)
    display.draw_round_rect(8, 8, width - 16, height - 16, 12, COLORS.border)
    display.draw_text_aligned(16, 24, width - 32, 24, "Stock Quotes", {
        color = COLORS.yellow,
        font_size = 20,
        bg = COLORS.panel,
        align = "center",
        valign = "middle",
    })
    display.draw_text_aligned(16, 64, width - 32, height - 80, safe_text(message, "Error"), {
        color = COLORS.error,
        font_size = 12,
        bg = COLORS.panel,
        align = "center",
        valign = "middle",
    })
    display.present()
    display.end_frame()
end

local function draw_loading(width, height)
    display.begin_frame({ clear = true, color = COLORS.bg })
    display.fill_round_rect(8, 8, width - 16, height - 16, 12, COLORS.panel)
    display.draw_round_rect(8, 8, width - 16, height - 16, 12, COLORS.border)
    display.draw_text_aligned(16, 52, width - 32, 32, "Stock Quotes", {
        color = COLORS.yellow,
        font_size = 22,
        bg = COLORS.panel,
        align = "center",
        valign = "middle",
    })
    display.draw_text_aligned(16, 92, width - 32, 22, "Loading Eastmoney data...", {
        color = COLORS.muted,
        font_size = 14,
        bg = COLORS.panel,
        align = "center",
        valign = "middle",
    })
    display.present()
    display.end_frame()
end

local function draw_quotes(width, height, quotes, detail_index, status)
    local item = quotes[detail_index] or quotes[1] or {}
    local code = safe_text(item.f12, "----")
    local name = display_name(item, 12)
    local color = quote_color(item)
    local large_screen = width >= 360 and height >= 360
    local bottom_margin = large_screen and 16 or 12
    local row_h = large_screen and 30 or 24
    local max_rows = math.min(2, #quotes)
    local list_start = detail_index
    local list_y = height - bottom_margin - row_h * max_rows
    local top_h = list_y - (large_screen and 14 or 8)
    local card_x = large_screen and 14 or 6
    local card_y = large_screen and 14 or 6
    local card_w = width - card_x * 2
    local card_h = top_h - card_y
    local content_x = card_x + (large_screen and 20 or 12)
    local content_w = card_w - (large_screen and 40 or 24)
    local detail_y = card_y + (large_screen and 20 or 14)
    local detail_step = large_screen and 44 or 22
    local label_font = large_screen and 20 or 12
    local value_font = large_screen and 20 or 12
    local price_font = large_screen and 36 or 22
    local price_row_h = large_screen and 54 or 30
    local detail_fields = {
        { "Code", name .. " " .. code, COLORS.text, label_font, value_font, detail_step },
        { "Price", fmt_num(item.f2, 2), color, label_font, price_font, price_row_h },
        { "Change", fmt_change(item), color, label_font, value_font, detail_step },
        { "Open", fmt_num(item.f17, 2), nil, label_font, value_font, detail_step },
        { "High", fmt_num(item.f15, 2), COLORS.red, label_font, value_font, detail_step },
        { "Low", fmt_num(item.f16, 2), COLORS.green, label_font, value_font, detail_step },
        { "Amount", fmt_compact(item.f6), nil, label_font, value_font, detail_step },
    }
    local detail_bottom = card_y + card_h - (large_screen and 38 or 24)

    display.begin_frame({ clear = true, color = COLORS.bg })
    display.fill_round_rect(card_x, card_y, card_w, card_h, 12, COLORS.panel)
    display.draw_round_rect(card_x, card_y, card_w, card_h, 12, COLORS.border)

    for _, field in ipairs(detail_fields) do
        if detail_y > detail_bottom then
            break
        end
        draw_metric_row(content_x, detail_y, content_w, field[6], field[1], field[2], field[3], field[4], field[5])
        detail_y = detail_y + field[6]
    end

    display.draw_text_aligned(card_x + 8, card_y + card_h - 24, card_w - 16, 14, clipped_text(status, large_screen and 36 or 28, "status"), {
        color = COLORS.muted,
        font_size = large_screen and 12 or 10,
        bg = COLORS.panel,
        align = "right",
        valign = "middle",
    })

    if list_start > #quotes - max_rows + 1 then
        list_start = math.max(1, #quotes - max_rows + 1)
    end

    for i = 1, max_rows do
        local quote_index = list_start + i - 1
        local row = quotes[quote_index]
        local y = list_y + (i - 1) * row_h
        local row_color = quote_color(row)
        local bg = (quote_index == detail_index) and COLORS.panel_alt or COLORS.bg

        display.fill_round_rect(card_x, y, width - card_x * 2, row_h - 4, 5, bg)
        display.draw_text(card_x + 8, y + 5, display_name(row, large_screen and 12 or 9), {
            color = (quote_index == detail_index) and COLORS.yellow or COLORS.text,
            font_size = large_screen and 14 or 12,
            bg = bg,
        })
        display.draw_text_aligned(math.floor(width * 0.38), y + 5, math.floor(width * 0.26), 14, fmt_num(row.f2, 2), {
            color = row_color,
            font_size = large_screen and 14 or 12,
            bg = bg,
            align = "right",
        })
        if width > 210 then
            display.draw_text_aligned(math.floor(width * 0.68), y + 5, width - math.floor(width * 0.68) - card_x - 8, 14, fmt_pct(row.f3), {
                color = row_color,
                font_size = large_screen and 14 or 12,
                bg = bg,
                align = "right",
            })
        end
    end

    display.present()
    display.end_frame()
end

local function should_stop(start_s)
    if ctx.run_time_ms <= 0 then
        return false
    end
    return (os.time() - start_s) * 1000 >= ctx.run_time_ms
end

local function run()
    local secids = sanitize_secids(raw_string("secids", DEFAULT_SECIDS))
    local panel_handle, io_handle, lcd_w, lcd_h, panel_if = board_manager.get_display_lcd_params("display_lcd")
    local width
    local height
    local quotes = nil
    local detail_index = ctx.detail_index
    local next_fetch_ms = 0
    local elapsed_ms = 0
    local start_s = os.time()
    local status = "init"

    if not panel_handle then
        error("get_display_lcd_params(display_lcd) failed: " .. tostring(io_handle))
    end

    local ok, err = pcall(display.init, panel_handle, io_handle, lcd_w, lcd_h, panel_if)
    if not ok then
        error("display.init failed: " .. tostring(err))
    end

    width = display.width
    height = display.height
    if width <= 0 or height <= 0 then
        error("invalid display size")
    end

    draw_loading(width, height)

    while not should_stop(start_s) do
        if elapsed_ms >= next_fetch_ms then
            local fetch_ok, fetched = pcall(fetch_quotes, secids)
            if fetch_ok and type(fetched) == "table" and #fetched > 0 then
                quotes = fetched
                if detail_index > #quotes then
                    detail_index = 1
                end
                status = string.format("items=%d refresh=%ds", #quotes, math.floor(ctx.refresh_ms / 1000))
                draw_quotes(width, height, quotes, detail_index, status)
                if ctx.rotate and #quotes > 1 then
                    detail_index = detail_index + 1
                    if detail_index > #quotes then
                        detail_index = 1
                    end
                end
            else
                status = tostring(fetched)
                print(TAG .. " WARN: " .. status)
                if quotes then
                    draw_quotes(width, height, quotes, detail_index, "net timeout, keep last")
                else
                    draw_error(width, height, status)
                end
            end
            next_fetch_ms = elapsed_ms + ctx.refresh_ms
        end

        local touch_ok, touch = pcall(display.read_touch, 0)
        if touch_ok and touch and quotes and #quotes > 0 and touch.type == "release" then
            detail_index = detail_index + 1
            if detail_index > #quotes then
                detail_index = 1
            end
            draw_quotes(width, height, quotes, detail_index, status)
        end

        delay.delay_ms(LOOP_SLICE_MS)
        elapsed_ms = elapsed_ms + LOOP_SLICE_MS
    end
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
    print(TAG .. " ERROR: " .. tostring(err))
    pcall(display.end_frame)
    pcall(display.deinit)
    error(err)
end

pcall(display.end_frame)
pcall(display.deinit)
