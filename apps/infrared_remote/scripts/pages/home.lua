-- Home page: saved remotes as cards, with entry points to Add and Settings.
local Kit = require("ui.kit")

local HomePage = {}
HomePage.__index = HomePage

local COLUMNS = 2
local CARD_MAX_H = 64
local BADGE_D = 18

local Card = {}
Card.__index = Card

local function new_card(kit, parent, x, y, w, h)
    local C, px = Kit.C, function(v) return kit:px(v) end
    local card = setmetatable({}, Card)
    card.button = kit:button(parent, x, y, w, h, {radius = px(18)})
    local d, chip_x = px(34), px(9)
    local chip_y = (h - d) // 2
    card.chip = kit:box(card.button.obj, chip_x, chip_y, d, d, {radius = Kit.FULL})
    local size = px(18)
    card.icon = kit:icon_set(card.chip, (d - size) // 2, (d - size) // 2, size, C.text)
    local text_x = chip_x + d + px(8)
    local text_w = w - text_x - px(6)
    card.name = kit:label(card.button.obj, "", {font = "strong", color = C.text, align = "left_mid", x = text_x, y = -px(9), w = text_w})
    card.detail = kit:label(card.button.obj, "", {font = "caption", color = C.muted, align = "left_mid", x = text_x, y = px(10), w = text_w})
    -- Learned-key count on the chip corner; the accent matches the learned dots on the keypads.
    local badge = px(BADGE_D)
    card.badge = kit:box(card.button.obj, chip_x + d - badge + px(4), chip_y - px(4), badge, badge, {radius = Kit.FULL, bg_color = C.accent, border_width = px(2), border_color = C.surface})
    card.badge_count = kit:label(card.badge, "", {font = "caption", color = C.inverse, align = "center"})
    return card
end

function Card:show(device, detail, failed, learned)
    local kind = Kit.KINDS[device.kind] or Kit.KINDS.custom
    Kit.restyle(self.chip, {bg_color = failed and Kit.C.danger_soft or kind.soft})
    self.icon:show(kind.icon)
    self.icon:set_color(failed and Kit.C.danger or kind.color)
    Kit.set_text(self.name, device.name)
    Kit.set_text(self.detail, detail)
    Kit.restyle(self.detail, {text_color = failed and Kit.C.danger or Kit.C.muted})
    Kit.set_hidden(self.badge, failed or learned == 0)
    Kit.set_text(self.badge_count, tostring(learned))
    self.button:set_hidden(false)
end

function HomePage.new(app)
    local kit, C = app.kit, Kit.C
    local px = function(v) return kit:px(v) end
    local self = setmetatable({app = app, kit = kit, cards = {}}, HomePage)
    self.view = kit:view(app.root)
    self.header = kit:header(self.view, {
        title = "Remotes", back = function() app:quit() end,
        actions = {
            {icon = "plus", fill = C.accent, fg = C.inverse, on_click = function() app:open_add() end},
            {icon = "settings", on_click = function() app:go("settings") end},
        },
    })
    local x, y, w, h = kit:body_rect()
    local rows, gap = math.ceil(app.devices.MAX_DEVICES / COLUMNS), px(8)
    local cw = (w - gap * (COLUMNS - 1)) // COLUMNS
    local ch = math.min(px(CARD_MAX_H), (h - gap * (rows - 1)) // rows)
    for i = 1, app.devices.MAX_DEVICES do
        local col, row = (i - 1) % COLUMNS, (i - 1) // COLUMNS
        local card = new_card(kit, self.view, x + col * (cw + gap), y + row * (ch + gap), cw, ch)
        card.button:on_click(function()
            local device = app.devices:list()[i]
            if device then app:go(device.kind, device) end
        end)
        self.cards[i] = card
    end
    self:_build_empty(x, y, w, h)
    return self
end

function HomePage:_build_empty(x, y, w, h)
    local kit, C = self.kit, Kit.C
    local px = function(v) return kit:px(v) end
    self.empty = kit:box(self.view, x, y, w, h, {bg_opa = 0})
    local d, top = px(64), math.max(0, (h - px(176)) // 2)
    local chip = kit:circle(self.empty, (w - d) // 2, top, d, C.accent_soft)
    kit:icon(chip, "remote", (d - px(32)) // 2, (d - px(32)) // 2, px(32), C.accent)
    kit:label(self.empty, "No remotes yet", {font = "title", color = C.text, align = "top_mid", y = top + d + px(10)})
    kit:label(self.empty, "Add a TV, air conditioner or any IR device", {font = "caption", color = C.muted, align = "top_mid", y = top + d + px(38)})
    local bw = px(168)
    local add = kit:button(self.empty, (w - bw) // 2, top + d + px(66), bw, px(40), {text = "Add remote", font = "strong", fill = C.accent, fg = C.inverse, radius = Kit.FULL})
    add:on_click(function() self.app:open_add() end)
end

function HomePage:enter() self:refresh() end

function HomePage:refresh()
    local app, C = self.app, Kit.C
    local devices = app.devices:list()
    for i, card in ipairs(self.cards) do
        local device = devices[i]
        if device then
            local _, err = app.devices:remote(device)
            card:show(device, err and "Restore failed" or app:summary(device), err ~= nil, app.devices:learned_count(device))
        else
            card.button:set_hidden(true)
        end
    end
    Kit.set_hidden(self.empty, #devices > 0)
    local ready = app.link:ready()
    local status = ready and "IR ready" or "IR offline"
    local text = #devices == 0 and status or string.format("%d of %d · %s", #devices, app.devices.MAX_DEVICES, status)
    self.header:set_subtitle(text, nil, ready and C.success or C.danger)
end

return HomePage
