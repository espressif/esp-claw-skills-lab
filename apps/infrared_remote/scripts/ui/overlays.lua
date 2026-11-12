-- Layers above the pages: toast, confirm dialog, learning sheet and protocol picker.
local lvgl = require("lvgl")
local Kit = require("ui.kit")

local Overlays = {}

local TOAST_MS = {info = 1600, success = 2000, warn = 2600, danger = 3200}
local SCRIM_OPA = 150
local CARD_MAX_W = 272

local function scrim(kit, parent)
    local layer = kit:box(parent, 0, 0, kit.w, kit.h, {bg_color = Kit.C.scrim, bg_opa = SCRIM_OPA})
    -- Clickable so the scrim swallows touches meant for the page behind it.
    layer:add_flag("CLICKABLE")
    layer:add_flag("HIDDEN")
    return layer
end

local function card_width(kit) return math.min(kit.w - kit:px(40), kit:px(CARD_MAX_W)) end

local function show_layer(layer)
    layer:clear_flag("HIDDEN")
    layer:move_foreground()
end

local Toast = {}
Toast.__index = Toast

function Overlays.toast(kit, parent)
    local px = function(v) return kit:px(v) end
    local w, h = kit.w - px(32), px(32)
    local self = setmetatable({deadline = nil}, Toast)
    self.box = kit:box(parent, px(16), kit.h - h - px(56), w, h, {radius = Kit.FULL, bg_color = Kit.C.toast})
    self.dot = kit:circle(self.box, px(13), (h - px(8)) // 2, px(8), Kit.TONES.info)
    self.label = kit:label(self.box, "", {color = Kit.C.inverse, align = "left_mid", x = px(30), w = w - px(42)})
    self.box:add_flag("HIDDEN")
    return self
end

-- tone: info | success | warn | danger.
function Toast:show(text, tone, now)
    tone = tone or "info"
    self.label:set_text(text)
    self.dot:set_style({bg_color = Kit.TONES[tone] or Kit.TONES.info})
    show_layer(self.box)
    self.deadline = now + (TOAST_MS[tone] or TOAST_MS.info)
end

function Toast:tick(now)
    if self.deadline and now >= self.deadline then
        self.deadline = nil
        self.box:add_flag("HIDDEN")
    end
end

local Dialog = {}
Dialog.__index = Dialog

function Overlays.dialog(kit, parent)
    local C, px = Kit.C, function(v) return kit:px(v) end
    local self = setmetatable({}, Dialog)
    local w, h = card_width(kit), px(140)
    local bw, bh = (w - px(40)) // 2, px(36)
    self.layer = scrim(kit, parent)
    local card = kit:box(self.layer, 0, 0, w, h, {align = "center", radius = px(20)})
    self.title = kit:label(card, "", {font = "strong", color = C.text, x = px(16), y = px(14), w = w - px(32)})
    self.text = kit:label(card, "", {color = C.muted, x = px(16), y = px(42), w = w - px(32), lines = 2})
    self.cancel = kit:button(card, px(16), h - bh - px(14), bw, bh, {text = "Cancel", fill = C.sunken, radius = px(12)})
    self.confirm = kit:button(card, w - bw - px(16), h - bh - px(14), bw, bh, {text = "Confirm", fill = C.accent, fg = C.inverse, radius = px(12)})
    self.cancel:on_click(function() self:close() end)
    self.confirm:on_click(function()
        local on_confirm = self.on_confirm
        self:close()
        if on_confirm then on_confirm() end
    end)
    return self
end

-- spec: title, text, confirm, tone ("danger" | nil), on_confirm.
function Dialog:open(spec)
    local C = Kit.C
    self.on_confirm = spec.on_confirm
    self.title:set_text(spec.title)
    self.text:set_text(spec.text or "")
    self.confirm:set_text(spec.confirm or "Confirm")
    self.confirm:set_colors(spec.tone == "danger" and C.danger or C.accent, C.inverse)
    show_layer(self.layer)
end

function Dialog:close()
    self.on_confirm = nil
    self.layer:add_flag("HIDDEN")
end

local CaptureSheet = {}
CaptureSheet.__index = CaptureSheet

function Overlays.capture_sheet(kit, parent, on_cancel)
    local C, px = Kit.C, function(v) return kit:px(v) end
    local self = setmetatable({seconds = nil}, CaptureSheet)
    local w, h = card_width(kit), px(176)
    local chip = px(40)
    self.layer = scrim(kit, parent)
    local card = kit:box(self.layer, 0, 0, w, h, {align = "center", radius = px(20)})
    kit:circle(card, px(16), px(16), chip, C.warn_soft)
    kit:icon(card, "learn", px(16) + (chip - px(22)) // 2, px(16) + (chip - px(22)) // 2, px(22), C.warn)
    self.title = kit:label(card, "", {font = "strong", color = C.text, x = px(68), y = px(16), w = w - px(84)})
    self.countdown = kit:label(card, "", {font = "caption", color = C.warn, x = px(68), y = px(38)})
    self.text = kit:label(card, "", {color = C.muted, x = px(16), y = px(66), w = w - px(32), lines = 2})
    self.bar = kit:progress(card, px(16), px(112), w - px(32), px(6), C.warn)
    local cancel = kit:button(card, px(16), h - px(36) - px(14), w - px(32), px(36), {text = "Cancel", fill = C.sunken, radius = px(12)})
    cancel:on_click(on_cancel)
    return self
end

function CaptureSheet:open(label)
    self.title:set_text("Learning " .. label)
    self.text:set_text("Aim the original remote here and press " .. label .. ".")
    self.seconds = nil
    self:set_progress(0, nil)
    show_layer(self.layer)
end

function CaptureSheet:set_progress(fraction, remaining_ms)
    self.bar:set_value(1 - fraction)
    local seconds = remaining_ms and math.max(0, math.ceil(remaining_ms / 1000)) or nil
    if seconds ~= self.seconds then
        self.seconds = seconds
        self.countdown:set_text(seconds and string.format("Listening · %ds", seconds) or "Listening")
    end
end

function CaptureSheet:close() self.layer:add_flag("HIDDEN") end

local Picker = {}
Picker.__index = Picker

local ROW_H, ROW_GAP = 50, 8

function Overlays.picker(kit, parent)
    local px = function(v) return kit:px(v) end
    local self = setmetatable({kit = kit}, Picker)
    self.view = kit:view(parent)
    self.header = kit:header(self.view, {title = "Choose protocol", back = function() self:close() end})
    local x, y = kit:body_rect()
    self.list = lvgl.object(self.view, {x = 0, y = y - px(4), w = kit.w, h = kit.h - y + px(4), pad = 0, bg_opa = 0, border_width = 0, radius = 0})
    self.list:set_scroll({dir = "ver", scrollbar = "off"})
    self.margin = x
    return self
end

function Picker:_row(index, entry, selected)
    local kit, C = self.kit, Kit.C
    local px = function(v) return kit:px(v) end
    local w, h = kit.w - 2 * self.margin, px(ROW_H)
    local y = px(4) + (index - 1) * (h + px(ROW_GAP))
    local row = kit:button(self.list, self.margin, y, w, h, {fill = selected and C.accent_soft or C.surface, radius = px(14)})
    local text_w = w - px(72)
    kit:label(row.obj, entry.title, {font = "strong", color = C.text, x = px(14), y = px(6), w = text_w})
    kit:label(row.obj, entry.subtitle or "", {font = "caption", color = C.muted, x = px(14), y = px(28), w = text_w})
    if selected then
        kit:icon(row.obj, "check", w - px(34), (h - px(20)) // 2, px(20), C.accent)
    elseif entry.experimental then
        local tag = kit:box(row.obj, w - px(50), (h - px(20)) // 2, px(38), px(20), {radius = Kit.FULL, bg_color = C.warn_soft})
        kit:label(tag, "BETA", {font = "caption", color = C.warn, align = "center"})
    end
    row:on_click(function()
        local on_select = self.on_select
        self:close()
        if on_select then on_select(entry.id) end
    end)
end

-- spec: title, entries ({id, title, subtitle, experimental}), selected id, on_select(id).
function Picker:open(spec)
    -- Rows of the previous session are freed here rather than in close(), which may run inside a row callback.
    self.list:clean()
    self.on_select = spec.on_select
    self.header:set_title(spec.title or "Choose protocol")
    self.header:set_subtitle(string.format("%d available", #spec.entries))
    for i, entry in ipairs(spec.entries) do self:_row(i, entry, entry.id == spec.selected) end
    -- Bottom spacer so the last row's shadow is not clipped.
    self.kit:box(self.list, 0, self.kit:px(4) + #spec.entries * self.kit:px(ROW_H + ROW_GAP), 1, self.kit:px(ROW_GAP), {bg_opa = 0})
    show_layer(self.view)
end

function Picker:close()
    self.on_select = nil
    self.view:add_flag("HIDDEN")
end

return Overlays
