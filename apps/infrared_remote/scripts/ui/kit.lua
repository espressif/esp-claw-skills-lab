-- Design tokens and LVGL building blocks shared by every Infrared Remote page.
local lvgl = require("lvgl")
local Icons = require("ui.icons")

local Kit = {}
Kit.__index = Kit

-- Layout units are designed for a 240 px short side and scaled to the actual screen.
local REFERENCE_SIDE = 240
local MAX_SCALE = 1.5
local HEADER_H = 48
local MARGIN = 12
local BOTTOM_MARGIN = 10
-- Line height of the bundled NotoSansSC font in ems ((ascent + descent) / units per em).
local LINE_RATIO = 1.448
local MIN_FONT_PX = 9
-- Icon glyphs span about one em and are centered 0.375 em above the baseline, which sits one
-- ascent (1.16 em) below the top of the line. Icons fill 75% of their box like the old strokes did.
local ICON_EM_RATIO = 0.75
local ICON_CENTER_EM = 1.16 - 0.375
local ICON_FONT_CACHE = 16
local RING_STEP_DEG = 10
local FONTS = {
    caption = {size = 11, cache = 96},
    body = {size = 13, cache = 128},
    strong = {size = 15, cache = 96},
    title = {size = 18, cache = 64},
    hero = {size = 46, cache = 16},
}

Kit.FULL = 0x7FFF -- LV_RADIUS_CIRCLE
Kit.C = {
    bg = "#eef1f6", surface = "#ffffff", sunken = "#e6eaf0", pressed = "#d9dfe8", shadow = "#d3d9e2", line = "#dde2ea",
    text = "#18202b", muted = "#6f7a89", faint = "#b0b8c4", inverse = "#ffffff",
    accent = "#3d6af2", accent_soft = "#e4ebff", success = "#16a36f", success_soft = "#dcf4ea",
    warn = "#e58a1f", warn_soft = "#fdf0de", danger = "#e5484d", danger_soft = "#fde6e6",
    scrim = "#0d1420", toast = "#1d2633",
}
-- Toast dots sit on the dark toast surface, so they use lighter tones.
Kit.TONES = {info = "#8fb3ff", success = "#3dd68c", warn = "#ffb547", danger = "#ff6b6b"}
Kit.KINDS = {
    tv = {label = "TV", icon = "tv", color = "#3d6af2", soft = "#e4ebff"},
    ac = {label = "Air", icon = "snow", color = "#0e9fc2", soft = "#dcf3f9"},
    media = {label = "Media", icon = "play", color = "#8b5cf6", soft = "#efe8ff"},
    custom = {label = "Custom", icon = "grid", color = "#ef8a23", soft = "#fff0df"},
}
Kit.KIND_ORDER = {"tv", "ac", "media", "custom"}

local function rgb(color)
    return tonumber(color:sub(2, 3), 16), tonumber(color:sub(4, 5), 16), tonumber(color:sub(6, 7), 16)
end

-- Linear blend of two "#rrggbb" colors; t = 0 gives a, t = 1 gives b.
function Kit.mix(a, b, t)
    local ar, ag, ab = rgb(a)
    local br, bg, bb = rgb(b)
    local function channel(x, y) return math.floor(x + (y - x) * t + 0.5) end
    return string.format("#%02x%02x%02x", channel(ar, br), channel(ag, bg), channel(ab, bb))
end

-- Last values pushed to each widget. Every LVGL call takes the display lock and invalidates the
-- widget, so repaints only forward what actually changed. A widget must be updated either through
-- these helpers or directly, never both.
local applied = setmetatable({}, {__mode = "k"})

local function applied_state(obj)
    local state = applied[obj]
    if not state then
        state = {}
        applied[obj] = state
    end
    return state
end

function Kit.restyle(obj, style)
    local state, diff = applied_state(obj), nil
    for key, value in pairs(style) do
        if state[key] ~= value then
            state[key] = value
            diff = diff or {}
            diff[key] = value
        end
    end
    if diff then obj:set_style(diff) end
end

function Kit.set_text(obj, text)
    local state = applied_state(obj)
    if state._text ~= text then
        state._text = text
        obj:set_text(text)
    end
end

function Kit.move(obj, x, y)
    local state = applied_state(obj)
    if state._x ~= x or state._y ~= y then
        state._x, state._y = x, y
        obj:set_pos(x, y)
    end
end

function Kit.resize(obj, w, h)
    local state = applied_state(obj)
    if state._w ~= w or state._h ~= h then
        state._w, state._h = w, h
        obj:set_size(w, h)
    end
end

local function set_hidden(obj, hidden)
    local state = applied_state(obj)
    hidden = hidden and true or false
    if state._hidden == hidden then return end
    state._hidden = hidden
    if hidden then obj:add_flag("HIDDEN") else obj:clear_flag("HIDDEN") end
end
Kit.set_hidden = set_hidden

function Kit.new(screen)
    local w, h = screen:get_size()
    local self = setmetatable({w = w, h = h, u = math.min(MAX_SCALE, math.min(w, h) / REFERENCE_SIDE), fonts = {}, font_px = {}, icon_fonts = {}}, Kit)
    for name, font in pairs(FONTS) do
        self.font_px[name] = math.max(MIN_FONT_PX, self:px(font.size))
        self.fonts[name] = lvgl.font_load({size = self.font_px[name], cache_size = font.cache})
    end
    lvgl.set_default_font(self.fonts.body)
    return self
end

function Kit:px(v) return math.floor(v * self.u + 0.5) end

-- Height of one text line; single-line labels use it so a wrapped second line stays clipped.
function Kit:line_h(font) return math.floor(self.font_px[font or "body"] * LINE_RATIO) end

-- Content area below the page header.
function Kit:body_rect()
    local margin, top = self:px(MARGIN), self:px(HEADER_H)
    return margin, top, self.w - 2 * margin, self.h - top - self:px(BOTTOM_MARGIN)
end

-- Non-interactive surface; touches pass through to the widgets below it.
function Kit:box(parent, x, y, w, h, style)
    style = style or {}
    local obj = lvgl.object(parent, {
        x = x, y = y, w = w, h = h, align = style.align, pad = 0, radius = style.radius or 0,
        bg_color = style.bg_color or Kit.C.surface, bg_opa = style.bg_opa or 255,
        border_width = style.border_width or 0, border_color = style.border_color or Kit.C.line,
    })
    obj:clear_flag("SCROLLABLE")
    obj:clear_flag("CLICKABLE")
    return obj
end

function Kit:circle(parent, x, y, d, color)
    return self:box(parent, x, y, d, d, {radius = Kit.FULL, bg_color = color})
end

function Kit:view(parent)
    local view = self:box(parent, 0, 0, self.w, self.h, {bg_color = Kit.C.bg})
    set_hidden(view, true)
    return view
end

-- Labels without color inherit text_color from their parent, which lets buttons recolor them.
-- opts.w makes a clipped single-line label (or opts.lines lines) instead of a content-sized one.
function Kit:label(parent, text, opts)
    opts = opts or {}
    local font = opts.font or "body"
    return lvgl.label(parent, {
        text = text, font = self.fonts[font], text_color = opts.color, x = opts.x or 0, y = opts.y or 0, align = opts.align,
        w = opts.w, h = opts.w and self:line_h(font) * (opts.lines or 1) or nil, text_align = opts.text_align,
    })
end

local function glyph(name)
    return Icons[name] or error("unknown icon '" .. tostring(name) .. "'")
end

-- One glyph label; show() swaps the glyph in place.
local Icon = {}
Icon.__index = Icon

function Icon:set_color(color) Kit.restyle(self.label, {text_color = color}) end

function Icon:set_hidden(hidden) set_hidden(self.label, hidden) end

function Icon:show(name) Kit.set_text(self.label, glyph(name)) end

-- Icon fonts are shared per pixel size; they reuse the loaded font data and only add a glyph cache.
function Kit:_icon_font(size)
    local px = math.max(MIN_FONT_PX, math.floor(size * ICON_EM_RATIO + 0.5))
    local font = self.icon_fonts[px]
    if not font then
        font = lvgl.font_load({size = px, cache_size = ICON_FONT_CACHE})
        self.icon_fonts[px] = font
    end
    return font, px
end

-- Centers the glyph in the size x size box at (x, y). The label is twice as wide as the box so wide
-- glyphs such as play/pause are never wrapped or clipped. lvgl.label() ignores w unless h is also
-- given, and a content-sized label would leave the glyph shifted left by the extra half width.
function Kit:icon(parent, name, x, y, size, color)
    local font, px = self:_icon_font(size)
    local label = lvgl.label(parent, {
        text = "", font = font, x = x - size // 2, y = y + size // 2 - math.floor(px * ICON_CENTER_EM + 0.5),
        w = size * 2, h = math.floor(px * LINE_RATIO), text_align = "center",
    })
    local icon = setmetatable({label = label}, Icon)
    if name then icon:show(name) end
    icon:set_color(color)
    return icon
end

-- Same as icon(); kept for slots whose glyph changes, where initial may be nil.
function Kit:icon_set(parent, x, y, size, color, initial)
    return self:icon(parent, initial, x, y, size, color)
end

-- Button marks: "idle", "learned" (badge dot), "missing" (no code yet) and "target" (learn/remove mode).
local Button = {}
Button.__index = Button

function Button:_paint()
    local C = Kit.C
    local target, missing = self.mark == "target", self.mark == "missing"
    local fill = target and C.warn_soft or self.fill
    local fg = target and C.warn or (missing and C.faint or self.fg)
    self.current_fill = fill
    Kit.restyle(self.obj, {bg_color = fill, text_color = fg, border_width = target and math.max(1, self.kit:px(1)) or 0, border_color = C.warn})
    if self.icon then self.icon:set_color(fg) end
    if self.dot then set_hidden(self.dot, self.mark ~= "learned") end
end

function Button:set_mark(mark)
    if mark == self.mark then return end
    self.mark = mark
    self:_paint()
end

function Button:set_colors(fill, fg)
    self.fill, self.fg = fill, fg or self.fg
    self:_paint()
end

function Button:set_text(text) Kit.set_text(self.label, text) end

function Button:set_enabled(enabled)
    enabled = enabled and true or false
    if enabled == self.enabled then return end
    self.enabled = enabled
    if enabled then self.obj:add_flag("CLICKABLE") else self.obj:clear_flag("CLICKABLE") end
end

function Button:set_hidden(hidden) set_hidden(self.obj, hidden) end

function Button:place(x, y, w, h)
    Kit.move(self.obj, x, y)
    Kit.resize(self.obj, w, h)
end

-- LVGL sends "clicked" after "long_pressed" as well; a hold suppresses that click.
function Button:on_click(fn)
    self.obj:on("clicked", function() if not self.held then fn() end end)
end

function Button:on_hold(fn)
    self.obj:on("long_pressed", function() self.held = true; fn() end)
end

function Kit:_button_content(button, w, h, spec)
    local obj, fg = button.obj, button.fg
    local icon_size = spec.icon_size or self:px(20)
    if spec.icon and spec.text then
        local font = spec.font or "caption"
        local line, gap = self:line_h(font), self:px(1)
        local top = (h - icon_size - gap - line) // 2
        button.icon = self:icon(obj, spec.icon, (w - icon_size) // 2, top, icon_size, fg)
        button.label = self:label(obj, spec.text, {font = font, align = "top_mid", y = top + icon_size + gap})
    elseif spec.icon then
        button.icon = self:icon(obj, spec.icon, (w - icon_size) // 2, (h - icon_size) // 2, icon_size, fg)
    elseif spec.text then
        button.label = self:label(obj, spec.text, {font = spec.font or "body", align = "center"})
    end
    if spec.badge then
        local d = self:px(6)
        local x = spec.badge == "top" and (w - d) // 2 or w - d - self:px(7)
        button.dot = self:circle(obj, x, self:px(spec.badge == "top" and 5 or 7), d, Kit.C.accent)
    end
end

-- Elevated buttons use the theme shadow, press darkening and grow animation; flat ones sit inside a
-- surface and only swap their fill while pressed.
-- spec: fill, fg, radius, icon, icon_size, text, font, badge ("corner" | "top"), flat, pressed_fill.
function Kit:button(parent, x, y, w, h, spec)
    spec = spec or {}
    local C = Kit.C
    local fill, fg = spec.fill or C.surface, spec.fg or C.text
    local opts = {x = x, y = y, w = w, h = h, pad = 0, border_width = 0, radius = spec.radius or self:px(14), bg_color = fill, text_color = fg}
    local obj = spec.flat and lvgl.object(parent, opts) or lvgl.button(parent, opts)
    obj:clear_flag("SCROLLABLE")
    local button = setmetatable({kit = self, obj = obj, fill = fill, fg = fg, mark = "idle", held = false, enabled = true}, Button)
    self:_button_content(button, w, h, spec)
    local pressed_fill = spec.pressed_fill or C.pressed
    obj:on("pressed", function()
        button.held = false
        if spec.flat then Kit.restyle(obj, {bg_color = pressed_fill}) end
    end)
    if spec.flat then
        obj:add_flag("CLICKABLE")
        obj:add_flag("PRESS_LOCK")
        obj:on("released", function() Kit.restyle(obj, {bg_color = button.current_fill}) end)
    end
    button:_paint()
    return button
end

-- Fake elevation for plain surfaces: a slightly darker copy offset below the surface.
function Kit:raised(parent, x, y, w, h, radius, color)
    self:box(parent, x, y + self:px(2), w, h, {radius = radius, bg_color = Kit.C.shadow})
    return self:box(parent, x, y, w, h, {radius = radius, bg_color = color or Kit.C.surface})
end

local Header = {}
Header.__index = Header

function Header:set_title(text) Kit.set_text(self.title, text) end

-- dot_color shows a status dot before the subtitle; nil hides it.
function Header:set_subtitle(text, color, dot_color)
    Kit.set_text(self.subtitle, text)
    Kit.restyle(self.subtitle, {text_color = color or Kit.C.muted})
    set_hidden(self.dot, dot_color == nil)
    if dot_color then Kit.restyle(self.dot, {bg_color = dot_color}) end
    Kit.move(self.subtitle, dot_color and self.text_x + self.dot_gap or self.text_x, self.subtitle_y)
end

-- spec: title, subtitle, back = fn, actions = {{icon, fill, fg, on_click, on_hold}}, listed right to left.
function Kit:header(parent, spec)
    local px = function(v) return self:px(v) end
    local size, top = px(32), px(8)
    local header = setmetatable({actions = {}, text_x = px(14), subtitle_y = px(27), dot_gap = px(10)}, Header)
    if spec.back then
        header.back = self:button(parent, px(10), top, size, size, {radius = Kit.FULL, icon = "back", icon_size = px(18)})
        header.back:on_click(spec.back)
        header.text_x = px(10) + size + px(10)
    end
    header.title = self:label(parent, spec.title or "", {font = "title", x = header.text_x, y = px(4)})
    header.dot = self:circle(parent, header.text_x, header.subtitle_y + px(5), px(6), Kit.C.success)
    header.subtitle = self:label(parent, "", {font = "caption", x = header.text_x, y = header.subtitle_y})
    header:set_subtitle(spec.subtitle or "")
    local x = self.w - px(10)
    for i, action in ipairs(spec.actions or {}) do
        x = x - size
        local button = self:button(parent, x, top, size, size, {radius = Kit.FULL, icon = action.icon, icon_size = px(18), fill = action.fill, fg = action.fg})
        if action.on_click then button:on_click(action.on_click) end
        if action.on_hold then button:on_hold(action.on_hold) end
        header.actions[i] = button
        x = x - px(8)
    end
    return header
end

-- Circular dot dial: thick polylines show seams at every joint, while dots render cleanly.
local Ring = {}
Ring.__index = Ring

local function ring_point(s, deg)
    local a = math.rad(deg)
    return math.floor(s.cx + s.r * math.cos(a) + 0.5), math.floor(s.cy + s.r * math.sin(a) + 0.5)
end

function Ring:_paint_dots(from, to)
    for i = from, to do Kit.restyle(self.dots[i], {bg_color = i <= self.lit and self.colors.fill or self.colors.track}) end
end

function Ring:set_colors(track, fill, knob)
    self.colors = {track = track, fill = fill}
    Kit.restyle(self.knob, {bg_color = knob or fill})
    self:_paint_dots(1, #self.dots)
end

function Ring:set_value(fraction)
    local s = self.spec
    fraction = math.max(0, math.min(1, fraction or 0))
    local lit = math.floor(fraction * (#self.dots - 1) + 0.5) + 1
    local old = self.lit
    self.lit = lit
    if old ~= lit then self:_paint_dots(math.min(old, lit), math.max(old, lit)) end
    local x, y = ring_point(s, s.from + s.sweep * fraction)
    local half = s.knob // 2
    Kit.move(self.knob, x - half, y - half)
end

-- spec: cx, cy, r, dot (diameter), from (deg), sweep (deg), knob (diameter).
function Kit:ring(parent, spec)
    local ring = setmetatable({spec = spec, dots = {}, lit = 1, colors = {track = Kit.C.line, fill = Kit.C.accent}}, Ring)
    local count = math.max(2, math.floor(spec.sweep / RING_STEP_DEG) + 1)
    local half = spec.dot // 2
    for i = 1, count do
        local x, y = ring_point(spec, spec.from + spec.sweep * (i - 1) / (count - 1))
        ring.dots[i] = self:circle(parent, x - half, y - half, spec.dot, ring.colors.track)
    end
    ring.knob = self:circle(parent, 0, 0, spec.knob, Kit.C.accent)
    ring:set_colors(ring.colors.track, ring.colors.fill)
    ring:set_value(0)
    return ring
end

-- Horizontal progress bar built from two pills.
local Progress = {}
Progress.__index = Progress

function Progress:set_value(fraction)
    fraction = math.max(0, math.min(1, fraction or 0))
    Kit.resize(self.fill, math.max(self.h, math.floor(self.w * fraction + 0.5)), self.h)
end

function Kit:progress(parent, x, y, w, h, color)
    local bar = setmetatable({w = w, h = h}, Progress)
    bar.track = self:box(parent, x, y, w, h, {radius = Kit.FULL, bg_color = Kit.C.sunken})
    bar.fill = self:box(parent, x, y, h, h, {radius = Kit.FULL, bg_color = color})
    return bar
end

return Kit
