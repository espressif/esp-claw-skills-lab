-- change_ui.lua
--
-- Dual-screen UI: token dashboard + environment sensor layout.
-- Page switch loads a full-screen black screen first, then the target screen,
-- to avoid SPI partial-refresh stripe artifacts on swipe.

local storage = require("storage")

local M = {}

M.PAGE_TOKEN = 1
M.PAGE_ENV = 2

local ENV_UI_W = 284
local ENV_ICON_W = 32
local ENV_ICON_H = 32
local ENV_ICON_BYTES = ENV_ICON_W * ENV_ICON_H * 2
local SWIPE_MIN_PX = 22
local BLACK_FLASH_MS = 20

local COLOR = {
    bg = "#000000",
    card = "#282828",
    label = "#bebebe",
    white = "#ffffff",
}

local ENV_VALUE_CANVAS_H = 16
local ENV_VALUE_SCALE = 2
local ENV_VALUE_GAP = 1

local GLYPHS = {
    ["0"] = {
        "01110",
        "10001",
        "10011",
        "10101",
        "11001",
        "10001",
        "01110",
    },
    ["1"] = {
        "00100",
        "01100",
        "00100",
        "00100",
        "00100",
        "00100",
        "01110",
    },
    ["2"] = {
        "01110",
        "10001",
        "00001",
        "00010",
        "00100",
        "01000",
        "11111",
    },
    ["3"] = {
        "11110",
        "00001",
        "00010",
        "00110",
        "00001",
        "10001",
        "01110",
    },
    ["4"] = {
        "00010",
        "00110",
        "01010",
        "10010",
        "11111",
        "00010",
        "00010",
    },
    ["5"] = {
        "11111",
        "10000",
        "11110",
        "00001",
        "00001",
        "10001",
        "01110",
    },
    ["6"] = {
        "00110",
        "01000",
        "10000",
        "11110",
        "10001",
        "10001",
        "01110",
    },
    ["7"] = {
        "11111",
        "00001",
        "00010",
        "00100",
        "01000",
        "01000",
        "01000",
    },
    ["8"] = {
        "01110",
        "10001",
        "01110",
        "10001",
        "10001",
        "10001",
        "01110",
    },
    ["9"] = {
        "01110",
        "10001",
        "10001",
        "01111",
        "00001",
        "00010",
        "01100",
    },
    ["-"] = {
        "00000",
        "00000",
        "00000",
        "11111",
        "00000",
        "00000",
        "00000",
    },
    ["."] = {
        "00000",
        "00000",
        "00000",
        "00000",
        "00000",
        "00100",
        "00100",
    },
    ["C"] = {
        "01110",
        "10001",
        "10000",
        "10000",
        "10000",
        "10001",
        "01110",
    },
    ["P"] = {
        "11110",
        "10001",
        "10001",
        "11110",
        "10000",
        "10000",
        "10000",
    },
    ["a"] = {
        "00000",
        "00000",
        "01110",
        "00001",
        "01111",
        "10001",
        "01111",
    },
    ["h"] = {
        "10000",
        "10000",
        "10110",
        "11001",
        "10001",
        "10001",
        "10001",
    },
    ["m"] = {
        "00000",
        "00000",
        "11010",
        "10101",
        "10101",
        "10001",
        "10001",
    },
    ["p"] = {
        "00000",
        "00000",
        "11110",
        "10001",
        "10001",
        "11110",
        "10000",
    },
    ["%"] = {
        "10001",
        "00010",
        "00100",
        "01000",
        "10000",
        "10001",
        "00000",
    },
    ["\194\176"] = {
        "00100",
        "01010",
        "01010",
        "00100",
        "00000",
        "00000",
        "00000",
    },
}

local function glyph_width(glyph)
    local width = 0
    for _, line in ipairs(glyph) do
        if #line > width then
            width = #line
        end
    end
    return width
end

local function canvas_plot_scaled(canvas, w, h, px, py, color, scale)
    for dy = 0, scale - 1 do
        for dx = 0, scale - 1 do
            local x = px + dx
            local y = py + dy
            if x >= 0 and x < w and y >= 0 and y < h then
                canvas:set_px(x, y, color, 255)
            end
        end
    end
end

local function canvas_draw_glyph(canvas, w, h, x, y, glyph, color, scale)
    for row = 1, #glyph do
        local line = glyph[row]
        for col = 1, #line do
            if line:sub(col, col) == "1" then
                canvas_plot_scaled(canvas, w, h, x + (col - 1) * scale, y + (row - 1) * scale, color, scale)
            end
        end
    end
end

local function next_glyph(text, i)
    if i > #text then
        return nil, i
    end
    if text:sub(i, i + 1) == "\194\176" then
        return GLYPHS["\194\176"], i + 2
    end
    local ch = text:sub(i, i)
    return GLYPHS[ch], i + 1
end

local function text_pixel_width(text, scale, gap)
    local width = 0
    local i = 1
    while i <= #text do
        local glyph, next_i = next_glyph(text, i)
        if glyph then
            width = width + glyph_width(glyph) * scale + gap * scale
            i = next_i
        else
            i = i + 1
        end
    end
    if width > 0 then
        width = width - gap * scale
    end
    return width
end

local function canvas_draw_text(canvas, w, h, text, color, scale, gap, top_align)
    local y = 0
    if not top_align then
        y = math.floor((h - 7 * scale) / 2)
        if y < 0 then
            y = 0
        end
    end

    local x = 0
    local i = 1
    while i <= #text do
        local glyph, next_i = next_glyph(text, i)
        if glyph then
            canvas_draw_glyph(canvas, w, h, x, y, glyph, color, scale)
            x = x + glyph_width(glyph) * scale + gap * scale
            i = next_i
        else
            i = i + 1
        end
    end
end

local function create_scaled_text_canvas(lvgl, env_page, offset_x, x, y, w, text)
    local canvas = lvgl.canvas(env_page, {
        x = offset_x + x,
        y = y,
        w = w,
        h = ENV_VALUE_CANVAS_H,
        color_format = "rgb565",
    })

    local widget = {
        canvas = canvas,
        canvas_w = w,
        set_text = function(self, new_text)
            local out = type(new_text) == "string" and new_text or tostring(new_text or "")
            self.canvas:fill_bg(COLOR.card, 255)
            canvas_draw_text(self.canvas, self.canvas_w, ENV_VALUE_CANVAS_H, out, COLOR.white, ENV_VALUE_SCALE, ENV_VALUE_GAP, true)
        end,
    }
    widget:set_text(text)
    return widget
end

local function create_value_canvas(lvgl, env_page, offset_x, tile)
    return create_scaled_text_canvas(lvgl, env_page, offset_x, tile.value_x, tile.value_y, tile.value_w or 64, "--")
end

local ENV_TILES = {
    {
        label = "Temperature",
        unit = "\194\176C",
        icon_bin = "icon_temperature_32_rgb565_le.bin",
        icon_color = "#ffd947",
        card_x = 20,
        card_y = 40,
        label_x = 32,
        label_y = 52,
        value_x = 32,
        value_y = 70,
        value_w = 64,
        unit_x = 100,
        desc_x = 32,
        desc_y = 86,
        icon_x = 106,
        icon_y = 92,
    },
    {
        label = "Humidity",
        unit = "%",
        icon_bin = "icon_humidity_32_rgb565_le.bin",
        icon_color = "#5fd9ff",
        card_x = 154,
        card_y = 40,
        label_x = 166,
        label_y = 52,
        value_x = 166,
        value_y = 70,
        value_w = 64,
        unit_x = 234,
        desc_x = 166,
        desc_y = 86,
        icon_x = 240,
        icon_y = 92,
    },
    {
        label = "Pressure",
        unit = "hPa",
        icon_bin = "icon_pressure_32_rgb565_le.bin",
        icon_color = "#ff9762",
        card_x = 20,
        card_y = 140,
        label_x = 32,
        label_y = 152,
        value_x = 32,
        value_y = 170,
        value_w = 64,
        unit_x = 100,
        desc_x = 32,
        desc_y = 186,
        icon_x = 106,
        icon_y = 192,
    },
    {
        label = "CO2",
        unit = "ppm",
        icon_bin = "icon_co2_32_rgb565_le.bin",
        icon_color = "#6fe666",
        card_x = 154,
        card_y = 140,
        label_x = 166,
        label_y = 152,
        value_x = 166,
        value_y = 170,
        value_w = 66,
        unit_x = 236,
        desc_x = 166,
        desc_y = 186,
        icon_x = 240,
        icon_y = 192,
    },
}

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

local function style_screen(screen, display_w, display_h)
    pcall(function()
        screen:set_size(display_w, display_h)
    end)
    screen:set_style({
        bg_color = COLOR.bg,
        bg_opa = 255,
        border_width = 0,
        pad = 0,
        radius = 0,
    })
    disable_scroll(screen)
end

local function rgb565_le_to_hex(lo, hi)
    local v = lo + hi * 256
    local r = math.floor(((v >> 11) & 0x1F) * 255 / 31 + 0.5)
    local g = math.floor(((v >> 5) & 0x3F) * 255 / 63 + 0.5)
    local b = math.floor((v & 0x1F) * 255 / 31 + 0.5)
    return string.format("#%02x%02x%02x", r, g, b)
end

local function blit_rgb565_bin(canvas, data, lvgl)
    local stride = ENV_ICON_W * 2
    for y = 0, ENV_ICON_H - 1 do
        local row_base = y * stride
        for x = 0, ENV_ICON_W - 1 do
            local idx = row_base + x * 2 + 1
            canvas:set_px(x, y, rgb565_le_to_hex(data:byte(idx), data:byte(idx + 1)), 255)
        end
        if lvgl and (y % 8) == 7 then
            pcall(lvgl.process_events, 0)
        end
    end
end

local function build_env_icon(controller, tile)
    local lvgl = controller.lvgl
    local env_page = controller.env_page
    local offset_x = controller.offset_x
    local x = offset_x + tile.icon_x
    local y = tile.icon_y

    local bin_path = storage.join_path(controller.assets_dir, tile.icon_bin)
    local ok, data = pcall(storage.read_file, bin_path)
    if ok and type(data) == "string" and #data >= ENV_ICON_BYTES then
        local canvas = lvgl.canvas(env_page, {
            x = x,
            y = y,
            w = ENV_ICON_W,
            h = ENV_ICON_H,
            color_format = "rgb565",
        })
        canvas:fill_bg(COLOR.bg, 255)
        blit_rgb565_bin(canvas, data, lvgl)
        return
    end

    print("[token_usage] env icon missing, using placeholder: " .. tostring(bin_path))
    lvgl.object(env_page, {
        x = x,
        y = y,
        w = ENV_ICON_W,
        h = ENV_ICON_H,
        bg_color = tile.icon_color,
        bg_opa = 255,
        radius = math.floor(ENV_ICON_W / 2),
        border_width = 0,
        pad = 0,
    })
end

local function build_env_tile(controller, tile, tile_index)
    local lvgl = controller.lvgl
    local env_page = controller.env_page
    local offset_x = controller.offset_x

    lvgl.object(env_page, {
        x = offset_x + tile.card_x,
        y = tile.card_y,
        w = 123,
        h = 89,
        bg_color = COLOR.card,
        bg_opa = 255,
        radius = 20,
        border_width = 0,
        pad = 0,
    })

    lvgl.label(env_page, {
        text = tile.label,
        x = offset_x + tile.label_x,
        y = tile.label_y,
        text_color = COLOR.label,
    })

    local value_label = create_value_canvas(lvgl, env_page, offset_x, tile)

    lvgl.label(env_page, {
        text = tile.unit,
        x = offset_x + tile.unit_x,
        y = tile.value_y,
        text_color = COLOR.white,
    })

    local desc_label = lvgl.label(env_page, {
        text = "--",
        x = offset_x + tile.desc_x,
        y = tile.desc_y,
        text_color = COLOR.label,
    })
    desc_label:set_size(105, 20)

    controller.env_tiles[tile_index] = {
        value = value_label,
        desc = desc_label,
    }

    build_env_icon(controller, tile)
end

local function flush_lvgl(controller, timeout_ms)
    pcall(function()
        controller.lvgl.process_events(timeout_ms or 30)
    end)
end

local function flush_black(controller)
    if controller.blackout_screen then
        controller.blackout_screen:load()
    end
    flush_lvgl(controller, 50)
    if controller.delay_fn then
        controller.delay_fn(BLACK_FLASH_MS)
    end
    flush_lvgl(controller, 30)
end

local function show_page(controller, page)
    flush_black(controller)

    if page == M.PAGE_ENV then
        controller.env_screen:load()
        controller.active_page = M.PAGE_ENV
    else
        controller.token_screen:load()
        controller.active_page = M.PAGE_TOKEN
    end

    flush_lvgl(controller, 30)
end

local function switch_to(controller, page)
    if page == controller.active_page then
        return false
    end
    show_page(controller, page)
    return true
end

local function swipe_matches(dx, dy)
    local adx = math.abs(dx)
    local ady = math.abs(dy)
    if adx < SWIPE_MIN_PX then
        return false
    end
    return adx > ady * 0.6
end

function M.create(opts)
    local lvgl = opts.lvgl
    local display_w = opts.display_w
    local display_h = opts.display_h
    local create_screen = opts.create_screen
    local delay_fn = opts.delay_fn
    local assets_dir = opts.assets_dir or ""

    if not lvgl then
        error("change_ui.create requires lvgl")
    end
    if display_w <= 0 or display_h <= 0 then
        error("change_ui.create requires positive display size")
    end
    if not opts.token_screen and type(create_screen) ~= "function" then
        error("change_ui.create requires create_screen callback when token_screen is not provided")
    end
    if not opts.env_screen and type(create_screen) ~= "function" then
        error("change_ui.create requires create_screen callback when env_screen is not provided")
    end

    local offset_x = math.floor((display_w - ENV_UI_W) / 2)
    if offset_x < 0 then
        offset_x = 0
    end

    local token_screen = opts.token_screen
    local env_screen = opts.env_screen

    if token_screen then
        style_screen(token_screen, display_w, display_h)
    else
        token_screen = create_screen()
        style_screen(token_screen, display_w, display_h)
    end

    if env_screen then
        style_screen(env_screen, display_w, display_h)
    else
        env_screen = create_screen()
        style_screen(env_screen, display_w, display_h)
    end

    local blackout_screen = opts.blackout_screen
    if blackout_screen then
        style_screen(blackout_screen, display_w, display_h)
    elseif type(create_screen) == "function" then
        blackout_screen = create_screen()
        style_screen(blackout_screen, display_w, display_h)
    else
        local ok, scr = pcall(lvgl.create_screen)
        if not ok then
            error("blackout screen failed: " .. tostring(scr))
        end
        blackout_screen = scr
        style_screen(blackout_screen, display_w, display_h)
    end

    local controller = {
        lvgl = lvgl,
        delay_fn = delay_fn,
        offset_x = offset_x,
        display_w = display_w,
        display_h = display_h,
        assets_dir = assets_dir,
        token_screen = token_screen,
        env_screen = env_screen,
        blackout_screen = blackout_screen,
        token_page = token_screen,
        env_page = env_screen,
        active_page = M.PAGE_TOKEN,
        env_built = false,
        env_tile_index = 1,
        env_tiles = {},
    }

    function controller:update_env_tile(index, value_text, desc_text, desc_color)
        local tile = self.env_tiles and self.env_tiles[index]
        if not tile then
            return
        end
        if tile.value then
            tile.value:set_text(value_text)
        end
        if tile.desc then
            tile.desc:set_text(desc_text)
            if desc_color then
                tile.desc:set_style({ text_color = desc_color })
            end
        end
    end

    function controller:get_active_page()
        return self.active_page
    end

    function controller:is_token_page()
        return self.active_page == M.PAGE_TOKEN
    end

    function controller:env_layout_ready()
        return self.env_built
    end

    function controller:begin_env_layout()
        if self.env_built then
            return
        end
        disable_scroll(self.env_page)
    end

    function controller:tick_env_layout()
        if self.env_built then
            return true
        end

        local tile = ENV_TILES[self.env_tile_index]
        if not tile then
            self.env_built = true
            return true
        end

        build_env_tile(self, tile, self.env_tile_index)
        self.env_tile_index = self.env_tile_index + 1
        if self.env_tile_index > #ENV_TILES then
            self.env_built = true
        end
        return self.env_built
    end

    function controller:switch_to(page)
        return switch_to(self, page)
    end

    function controller:handle_swipe(dx, dy)
        if not swipe_matches(dx, dy) then
            return false
        end
        if self.active_page == M.PAGE_TOKEN then
            return self:switch_to(M.PAGE_ENV)
        end
        if self.active_page == M.PAGE_ENV then
            return self:switch_to(M.PAGE_TOKEN)
        end
        return false
    end

    return controller
end

return M
