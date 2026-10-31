-- Add page: pick a device type, then a protocol (or learning only for custom remotes), then create.
local Kit = require("ui.kit")

local AddPage = {}
AddPage.__index = AddPage

local TYPE_HINTS = {
    tv = "Navigation, volume and channels", ac = "Temperature, mode, fan and swing",
    media = "Playback and volume", custom = "Nine keys learned from any remote",
}

function AddPage.new(app)
    local kit, C = app.kit, Kit.C
    local px = function(v) return kit:px(v) end
    local self = setmetatable({app = app, kit = kit, kind = "tv", protocol = nil, types = {}}, AddPage)
    self.view = kit:view(app.root)
    self.header = kit:header(self.view, {title = "Add remote", back = function() app:go("home") end})
    local x, y, w, h = kit:body_rect()
    local gap = px(8)

    local tile_h = px(58)
    local tw = (w - gap * (#Kit.KIND_ORDER - 1)) // #Kit.KIND_ORDER
    for i, kind in ipairs(Kit.KIND_ORDER) do
        local meta = Kit.KINDS[kind]
        local tile = {kind = kind}
        tile.button = kit:button(self.view, x + (i - 1) * (tw + gap), y, tw, tile_h, {radius = px(16)})
        local d, size = px(30), px(18)
        tile.chip = kit:circle(tile.button.obj, (tw - d) // 2, px(6), d, meta.soft)
        kit:icon(tile.chip, meta.icon, (d - size) // 2, (d - size) // 2, size, meta.color)
        tile.label = kit:label(tile.button.obj, meta.label, {font = "caption", align = "top_mid", y = px(38)})
        tile.button:on_click(function() self:_select_kind(kind) end)
        self.types[i] = tile
    end

    local field_y, field_h = y + tile_h + gap, px(46)
    self.field = kit:button(self.view, x, field_y, w, field_h, {radius = px(16)})
    self.field_caption = kit:label(self.field.obj, "PROTOCOL", {font = "caption", color = C.muted, x = px(14), y = px(4)})
    self.field_value = kit:label(self.field.obj, "", {font = "strong", color = C.text, x = px(14), y = px(20), w = w - px(56)})
    self.field_chevron = kit:icon(self.field.obj, "chevron_right", w - px(34), (field_h - px(20)) // 2, px(20), C.muted)
    self.field:on_click(function() self:_pick_protocol() end)

    local cta_h = px(40)
    local cta_y, field_bottom = y + h - cta_h, field_y + field_h
    local detail_y = field_bottom + math.max(0, (cta_y - field_bottom - kit:line_h("caption")) // 2)
    self.detail = kit:label(self.view, "", {font = "caption", color = C.muted, x = x + px(4), y = detail_y, w = w - px(8)})
    self.create = kit:button(self.view, x, cta_y, w, cta_h, {text = "Create remote", font = "strong", fill = C.accent, fg = C.inverse, radius = Kit.FULL})
    self.create:on_click(function() self:_create() end)
    return self
end

function AddPage:enter()
    self:_select_kind("tv")
end

function AddPage:_select_kind(kind)
    self.kind = kind
    self.protocol = kind ~= "custom" and self.app:catalog():select(kind, self.app:option(kind .. "_protocol")) or nil
    self:refresh()
end

function AddPage:_pick_protocol()
    if self.kind == "custom" then return end
    local entries = self.app:catalog():list(self.kind)
    if #entries == 0 then self.app:notify("No protocols for this device type", "warn"); return end
    self.app:overlay("picker"):open({
        title = Kit.KINDS[self.kind].label .. " protocol", entries = entries, selected = self.protocol,
        on_select = function(id) self.protocol = id; self:refresh() end,
    })
end

function AddPage:_create()
    local app = self.app
    if self.kind ~= "custom" and not self.protocol then app:notify("No protocol available", "danger"); return end
    app:create_device(self.kind, self.protocol)
end

function AddPage:refresh()
    local C, catalog = Kit.C, self.app:catalog()
    for _, tile in ipairs(self.types) do
        local meta, selected = Kit.KINDS[tile.kind], tile.kind == self.kind
        Kit.restyle(tile.button.obj, {bg_color = selected and meta.soft or C.surface, border_width = selected and self.kit:px(2) or 0, border_color = meta.color})
        Kit.restyle(tile.label, {text_color = selected and meta.color or C.muted})
    end
    local custom = self.kind == "custom"
    local entry = catalog:entry(self.protocol)
    self.header:set_subtitle(TYPE_HINTS[self.kind])
    Kit.set_text(self.field_caption, custom and "METHOD" or "PROTOCOL")
    self.field_chevron:set_hidden(custom)
    self.field:set_enabled(not custom)
    local value, detail
    if custom then
        value, detail = "Learn from the original remote", "Hold any key on the remote page to learn it"
    elseif entry then
        value, detail = catalog:describe(entry.id), entry.detail
    else
        value, detail = "No protocol available", "Add codesets under ir/protocols in DATA storage"
    end
    Kit.set_text(self.field_value, value)
    Kit.set_text(self.detail, detail)
    local can_create = custom or entry ~= nil
    self.create:set_enabled(can_create)
    self.create:set_colors(can_create and C.accent or C.sunken, can_create and C.inverse or C.faint)
end

return AddPage
