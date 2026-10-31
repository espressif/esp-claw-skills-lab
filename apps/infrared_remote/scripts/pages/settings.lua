-- Hardware settings page: edit IR pins and carrier as a draft, then apply them in one step.
local Kit = require("ui.kit")
local IrLink = require("ir_link")

local SettingsPage = {}
SettingsPage.__index = SettingsPage

local ERROR_TEXT_MAX = 32

function SettingsPage.new(app)
    local kit, C = app.kit, Kit.C
    local px = function(v) return kit:px(v) end
    local self = setmetatable({app = app, kit = kit, draft = {}, values = {}}, SettingsPage)
    self.view = kit:view(app.root)
    self.header = kit:header(self.view, {
        title = "IR hardware", back = function() app:go("home") end,
        actions = {{icon = "check", fill = C.accent, fg = C.inverse, on_click = function() self:_apply() end}},
    })
    local x, y, w, h = kit:body_rect()
    local n, gap = #IrLink.FIELDS, px(6)
    local row_h = (h - gap * (n - 1)) // n
    local bw, bh = px(40), row_h - px(8)
    for i, field in ipairs(IrLink.FIELDS) do
        local row = kit:raised(self.view, x, y + (i - 1) * (row_h + gap), w, row_h, px(14))
        kit:label(row, field.label, {color = C.muted, align = "left_mid", x = px(14)})
        self.values[i] = kit:label(row, "", {font = "strong", color = C.text, align = "right_mid", x = -(px(14) + 2 * bw + px(14))})
        local minus = kit:button(row, w - 2 * bw - px(10), (row_h - bh) // 2, bw, bh, {icon = "minus", icon_size = px(16), fill = C.sunken, radius = px(10)})
        local plus = kit:button(row, w - bw - px(4), (row_h - bh) // 2, bw, bh, {icon = "plus", icon_size = px(16), fill = C.sunken, radius = px(10)})
        minus:on_click(function() self:_step(field, -1) end)
        plus:on_click(function() self:_step(field, 1) end)
    end
    return self
end

function SettingsPage:enter()
    for _, field in ipairs(IrLink.FIELDS) do self.draft[field.key] = self.app.hardware[field.key] end
    self:refresh()
end

function SettingsPage:_step(field, direction)
    self.draft[field.key] = math.max(field.min, math.min(field.max, self.draft[field.key] + direction * field.step))
    self:refresh()
end

function SettingsPage:_apply()
    if self.app:apply_hardware(self.draft) then self:refresh() end
end

function SettingsPage:refresh()
    local C, app = Kit.C, self.app
    for i, field in ipairs(IrLink.FIELDS) do
        local value = self.draft[field.key]
        Kit.set_text(self.values[i], IrLink.format(field, value))
        Kit.restyle(self.values[i], {text_color = value ~= app.hardware[field.key] and C.accent or C.text})
    end
    if app.link:ready() then
        self.header:set_subtitle(app.link:can_receive() and "Ready to send and learn" or "Ready to send · receiver off", nil, C.success)
    else
        local reason = tostring(app.link.error or "not configured"):gsub("^ir%.device: ", "")
        self.header:set_subtitle("Offline · " .. reason:sub(1, ERROR_TEXT_MAX), C.danger, C.danger)
    end
end

return SettingsPage
