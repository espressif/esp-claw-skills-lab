-- Air conditioner panel: a thermostat card tinted by the mode, plus power, mode, fan and swing tiles.
-- Everything shown comes from remote:capabilities(), so codesets with fewer fields simply show less.
local Kit = require("ui.kit")

local AcPanel = {}
AcPanel.__index = AcPanel

local RING_FROM_DEG, RING_SWEEP_DEG = 135, 270
local HERO_SHARE = 0.56
local TILE_MAX_H = 64
local HERO_DIGIT_ADVANCE = 0.56 -- approximate digit width of the hero font, in ems
local DEFAULT_TEMPERATURE = {min = 16, max = 30, step = 1}
-- Field vocabulary used when a protocol does not restrict an enum.
local FIELD_VALUES = {
    mode = {"auto", "cool", "dry", "heat", "fan"},
    fan = {"auto", "low", "medium", "high"},
    swing_v = {"off", "auto"},
}
local MODES = {
    auto = {color = "#7c5cf6", icon = "auto"}, cool = {color = "#2f7cf6", icon = "snow"}, dry = {color = "#0d9e98", icon = "drop"},
    heat = {color = "#f26b2c", icon = "sun"}, fan = {color = "#4f63e8", icon = "fan"},
}
local OFF_COLOR = "#8792a2"
local VALUE_NAMES = {medium = "Mid", min = "Min", max = "Max", off = "Off", auto = "Auto"}
-- Only keys that exist on every remote can be learned; state fields are encoded from the protocol.
local LEARNABLE = {power = "Power", swing_v = "Swing"}

local function value_name(value)
    if value == nil then return "--" end
    local position = tostring(value):match("^position_(%d+)$")
    if position then return "Pos " .. position end
    return VALUE_NAMES[value] or (tostring(value):gsub("^%l", string.upper))
end

local function next_value(values, current)
    for i, value in ipairs(values) do if value == current then return values[i % #values + 1] end end
    return values[1]
end

local function format_temperature(t)
    if t == nil then return "--" end
    return t % 1 == 0 and string.format("%d", math.floor(t)) or string.format("%.1f", t)
end

local Tile = {}
Tile.__index = Tile

local function new_tile(kit, parent, icon, caption)
    local px = function(v) return kit:px(v) end
    local tile = setmetatable({kit = kit, caption_text = caption}, Tile)
    tile.button = kit:button(parent, 0, 0, px(100), px(40), {radius = px(16)})
    local chip_d = px(28)
    tile.chip = kit:box(tile.button.obj, px(9), 0, chip_d, chip_d, {align = "left_mid", radius = Kit.FULL})
    local size = px(16)
    tile.icon = kit:icon_set(tile.chip, (chip_d - size) // 2, (chip_d - size) // 2, size, Kit.C.text, icon)
    tile.caption = kit:label(tile.button.obj, caption, {font = "caption", align = "left_mid", x = px(45), y = -px(8)})
    tile.value = kit:label(tile.button.obj, "--", {font = "strong", align = "left_mid", x = px(45), y = px(8)})
    return tile
end

-- look: {accent, soft, active, mark ("idle" | "target" | "missing"), caption, value, icon}
function Tile:paint(look)
    local C = Kit.C
    local target, dim = look.mark == "target", look.mark == "missing"
    local fill = look.active and look.accent or (target and C.warn_soft or C.surface)
    Kit.restyle(self.button.obj, {bg_color = fill, border_width = target and math.max(1, self.kit:px(1)) or 0, border_color = C.warn})
    Kit.restyle(self.caption, {text_color = look.active and C.inverse or (dim and C.faint or C.muted)})
    Kit.restyle(self.value, {text_color = look.active and C.inverse or (dim and C.faint or C.text)})
    Kit.restyle(self.chip, {bg_color = look.active and C.inverse or (target and C.surface or look.soft)})
    self.icon:set_color(dim and C.faint or (target and C.warn or look.accent))
    if look.icon then self.icon:show(look.icon) end
    Kit.set_text(self.caption, look.caption or self.caption_text)
    Kit.set_text(self.value, look.value)
end

function AcPanel.new(page, parent, x, y, w, h)
    local kit = page.kit
    local self = setmetatable({page = page, kit = kit, x = x, y = y, w = w, h = h, gap = kit:px(8)}, AcPanel)
    local hero_w = math.floor(w * HERO_SHARE)
    self.tiles_x, self.tiles_w = x + hero_w + self.gap, w - hero_w - self.gap
    self:_build_hero(parent, x, y, hero_w, h)

    self.power = new_tile(kit, parent, "power", "Power")
    self.mode = new_tile(kit, parent, MODES.cool.icon, "Mode")
    self.fan = new_tile(kit, parent, "fan", "Fan")
    self.swing = new_tile(kit, parent, "swing", "Swing")
    self.power.button:on_click(function() self:_toggle_power() end)
    self.power.button:on_hold(function() page:capture("power", LEARNABLE.power) end)
    self.swing.button:on_click(function() self:_cycle_swing() end)
    self.swing.button:on_hold(function() page:capture("swing_v", LEARNABLE.swing_v) end)
    self.mode.button:on_click(function() self:_cycle("mode", "Mode") end)
    self.fan.button:on_click(function() self:_cycle("fan", "Fan") end)
    -- Tiles are created at the origin; give them a real layout before the page is ever shown.
    self:_layout({self.power, self.mode, self.fan, self.swing})
    return self
end

function AcPanel:_build_hero(parent, x, y, w, h)
    local kit, C = self.kit, Kit.C
    local px = function(v) return kit:px(v) end
    self.hero = kit:box(parent, x, y, w, h, {radius = px(22), bg_color = MODES.cool.color})
    self.hero_icon = kit:icon_set(self.hero, px(12), px(10), px(16), C.inverse, MODES.cool.icon)
    self.hero_mode = kit:label(self.hero, "", {font = "body", color = C.inverse, x = px(33), y = px(8)})

    local cx, cy = w // 2, math.floor(h * 0.47)
    local r = math.floor(math.min(w * 0.33, h * 0.3))
    self.ring = kit:ring(self.hero, {cx = cx, cy = cy, r = r, dot = px(5), from = RING_FROM_DEG, sweep = RING_SWEEP_DEG, knob = px(13)})
    self.temp = kit:label(self.hero, "--", {font = "hero", color = C.inverse, align = "center", y = cy - h // 2 - px(4)})
    self.status = kit:label(self.hero, "", {font = "caption", color = C.inverse, align = "center", y = cy - h // 2 + px(26)})
    self.unit_x0, self.unit_y = cx, cy - px(22)
    self.degree = kit:box(self.hero, 0, self.unit_y, px(6), px(6), {radius = Kit.FULL, bg_opa = 0, border_width = px(2), border_color = C.inverse})
    self.unit = kit:label(self.hero, "C", {font = "body", color = C.inverse, x = 0, y = self.unit_y - px(3)})

    local d = px(34)
    local by = h - d - px(10)
    self.minus = kit:button(self.hero, cx - d - px(6), by, d, d, {radius = Kit.FULL, icon = "minus", icon_size = px(18)})
    self.plus = kit:button(self.hero, cx + px(6), by, d, d, {radius = Kit.FULL, icon = "plus", icon_size = px(18)})
    self.minus:on_click(function() self:_step_temperature(-1) end)
    self.plus:on_click(function() self:_step_temperature(1) end)
end

local function field_values(cap, field)
    return cap and (cap.values or FIELD_VALUES[field])
end

-- Snapshot of what the protocol allows right now. Codesets without a mode are key-only.
function AcPanel:_model()
    local remote = self.page.remote
    local state = remote and remote:state() or {}
    local adjustable = state.mode ~= nil
    local caps = adjustable and remote:capabilities({mode = state.mode}).state or {}
    local all = adjustable and remote:capabilities().state or {}
    return {
        state = state, adjustable = adjustable, caps = caps, on = state.power ~= false,
        modes = field_values(all.mode, "mode"),
        temperature = caps.temperature and (caps.temperature.min and caps.temperature or DEFAULT_TEMPERATURE),
    }
end

-- State controls are blocked in learn/remove mode and while the AC is off.
function AcPanel:_blocked(m)
    local app = self.page.app
    if self.page.mode then
        app:notify("Only Power and Swing can be learned", "warn")
        return true
    end
    if not m.on then
        app:notify("Turn the air conditioner on first", "warn")
        return true
    end
    return false
end

function AcPanel:_toggle_power()
    local page, m = self.page, self:_model()
    if page.mode or page:source("power") == "learned" or not m.adjustable then
        page:activate("power", LEARNABLE.power)
        return
    end
    page:apply_state({power = not m.on}, m.on and "Power off" or "Power on")
end

function AcPanel:_cycle_swing()
    local page, m = self.page, self:_model()
    local values = field_values(m.caps.swing_v, "swing_v")
    if page.mode or page:source("swing_v") == "learned" or not values then
        page:activate("swing_v", LEARNABLE.swing_v)
        return
    end
    local value = next_value(values, m.state.swing_v)
    page:apply_state({swing_v = value}, "Swing " .. value_name(value))
end

function AcPanel:_cycle(field, label)
    local m = self:_model()
    if self:_blocked(m) then return end
    local values = field == "mode" and m.modes or field_values(m.caps[field], field)
    if not values then return end
    local value = next_value(values, m.state[field])
    self.page:apply_state({[field] = value}, label .. " " .. value_name(value))
end

function AcPanel:_step_temperature(direction)
    local m = self:_model()
    if self:_blocked(m) then return end
    local limit, current = m.temperature, m.state.temperature
    if not limit or not current then return end
    local target = math.max(limit.min, math.min(limit.max, current + direction * limit.step))
    if target ~= current then self.page:apply_state({temperature = target}, "Temp " .. format_temperature(target)) end
end

function AcPanel:_tile_mark(key)
    local page = self.page
    if key and page.mode then return page:mark(key) end
    if page.mode then return "missing" end
    return "idle"
end

function AcPanel:_layout(tiles)
    local n, gap = #tiles, self.gap
    local th = math.min(self.kit:px(TILE_MAX_H), (self.h - gap * (n - 1)) // n)
    for i, tile in ipairs(tiles) do tile.button:place(self.tiles_x, self.y + (i - 1) * (th + gap), self.tiles_w, th) end
end

function AcPanel:_paint_hero(m, accent)
    local C, kit = Kit.C, self.kit
    local style = MODES[m.state.mode]
    Kit.restyle(self.hero, {bg_color = accent})
    self.hero_icon:show(style and style.icon or "snow")
    Kit.set_text(self.hero_mode, m.adjustable and value_name(m.state.mode) or "Air conditioner")
    local limit, t = m.temperature, m.state.temperature
    local text = format_temperature(limit and t)
    Kit.set_text(self.temp, text)
    Kit.set_text(self.status, not m.adjustable and "Key control" or (m.on and "Target" or "Powered off"))
    -- The unit follows the digits; the font has no degree glyph, so a ring stands in for it.
    local ux = self.unit_x0 + math.floor(#text * HERO_DIGIT_ADVANCE * kit.font_px.hero / 2) + kit:px(3)
    Kit.move(self.degree, ux, self.unit_y)
    Kit.move(self.unit, ux + kit:px(8), self.unit_y - kit:px(3))
    local track = Kit.mix(accent, C.inverse, 0.35)
    self.ring:set_colors(track, C.inverse, C.inverse)
    self.ring:set_value(limit and t and (t - limit.min) / math.max(1, limit.max - limit.min) or 0)
    local can_step = m.on and limit ~= nil and t ~= nil
    self.minus:set_enabled(can_step and t > limit.min)
    self.plus:set_enabled(can_step and t < limit.max)
    self.minus:set_colors(C.inverse, can_step and t > limit.min and accent or C.faint)
    self.plus:set_colors(C.inverse, can_step and t < limit.max and accent or C.faint)
end

function AcPanel:refresh()
    local page, m = self.page, self:_model()
    local style = MODES[m.state.mode]
    local accent = m.on and (style and style.color or Kit.KINDS.ac.color) or OFF_COLOR
    local soft = Kit.mix(accent, Kit.C.inverse, 0.85)
    self:_paint_hero(m, accent)

    local stateful_power = m.adjustable and page:source("power") ~= "learned"
    local power_learned = page:source("power") == "learned"
    self.power:paint({
        accent = accent, soft = soft, active = stateful_power and m.on and not page.mode, mark = self:_tile_mark("power"),
        caption = power_learned and "Power · learned" or "Power", value = stateful_power and (m.on and "On" or "Off") or "Toggle",
    })

    local tiles = {self.power}
    local controls_mark = (page.mode or not m.on) and "missing" or "idle"
    Kit.set_hidden(self.mode.button.obj, not m.modes)
    if m.modes then
        tiles[#tiles + 1] = self.mode
        self.mode:paint({accent = accent, soft = soft, mark = controls_mark, value = value_name(m.state.mode), icon = style and style.icon})
    end
    local fan_values = field_values(m.caps.fan, "fan")
    Kit.set_hidden(self.fan.button.obj, not fan_values)
    if fan_values then
        tiles[#tiles + 1] = self.fan
        self.fan:paint({accent = accent, soft = soft, mark = controls_mark, value = value_name(m.state.fan)})
    end

    local swing_source = page:source("swing_v")
    local swing_state = m.caps.swing_v and swing_source ~= "learned"
    local swing_value = swing_state and value_name(m.state.swing_v) or (swing_source and "Toggle" or "Hold to learn")
    local swing_mark = self:_tile_mark("swing_v")
    if swing_mark == "idle" and not swing_state and not swing_source then swing_mark = "missing" end
    tiles[#tiles + 1] = self.swing
    self.swing:paint({accent = accent, soft = soft, mark = swing_mark, caption = swing_source == "learned" and "Swing · learned" or "Swing", value = swing_value})
    self:_layout(tiles)
end

return AcPanel
