-- Keypad panels for TV, media and custom remotes. Every key is bound to the remote page by name, so
-- mapped codes, learned frames and launcher-configured codes all go through the same dispatch.
local Kit = require("ui.kit")

local Keypad = {}

local CUSTOM_KEY_COUNT = 9

local function key(page, parent, x, y, w, h, spec)
    spec.badge = spec.badge or "corner"
    local button = page.kit:button(parent, x, y, w, h, spec)
    page:bind(button, spec.key, spec.label)
    return button
end

-- Evenly splits a span into n cells separated by gap; returns the cell size.
local function cell(span, n, gap) return (span - gap * (n - 1)) // n end

-- Vertical pill with flat +/- keys and a caption between them, e.g. volume or channel.
local function rocker(page, parent, x, y, w, h, caption, up, down)
    local kit = page.kit
    local pill = kit:raised(parent, x, y, w, h, Kit.FULL)
    for i, k in ipairs({up, down}) do
        key(page, pill, 0, i == 1 and 0 or h - w, w, w, {key = k[1], label = k[2], icon = k[3], flat = true, radius = Kit.FULL, icon_size = kit:px(20), badge = "top"})
    end
    kit:label(pill, caption, {font = "caption", color = Kit.C.muted, align = "center"})
end

function Keypad.tv(page, parent, x, y, w, h)
    local kit, C = page.kit, Kit.C
    local px = function(v) return kit:px(v) end
    local gap, row_h = px(8), px(46)
    local top_h = h - row_h - gap
    local d = math.min(top_h, w // 2)
    local cx = x + w // 2
    local rocker_w = math.min(px(58), (w - d) // 2 - gap)

    rocker(page, parent, x, y, rocker_w, top_h, "VOL", {"vol_up", "Volume up", "plus"}, {"vol_down", "Volume down", "minus"})
    rocker(page, parent, x + w - rocker_w, y, rocker_w, top_h, "CH", {"ch_up", "Channel up", "chevron_up"}, {"ch_down", "Channel down", "chevron_down"})

    local pad = kit:raised(parent, cx - d // 2, y + (top_h - d) // 2, d, d, Kit.FULL)
    local k, ok_d, inset = d * 30 // 100, d * 36 // 100, px(4)
    local arrows = {
        {"up", "Up", "chevron_up", (d - k) // 2, inset},
        {"down", "Down", "chevron_down", (d - k) // 2, d - k - inset},
        {"left", "Left", "chevron_left", inset, (d - k) // 2},
        {"right", "Right", "chevron_right", d - k - inset, (d - k) // 2},
    }
    for _, a in ipairs(arrows) do
        key(page, pad, a[4], a[5], k, k, {key = a[1], label = a[2], icon = a[3], flat = true, radius = Kit.FULL, icon_size = px(22), badge = "top"})
    end
    key(page, pad, (d - ok_d) // 2, (d - ok_d) // 2, ok_d, ok_d, {key = "ok", label = "OK", text = "OK", font = "strong", fill = C.accent, fg = C.inverse, radius = Kit.FULL, badge = "top"})

    local bw = cell(w, 3, gap)
    local bottom = {{"power", "Power", "power", C.danger}, {"source", "Input", "input"}, {"mute", "Mute", "mute"}}
    for i, b in ipairs(bottom) do
        key(page, parent, x + (i - 1) * (bw + gap), y + h - row_h, bw, row_h, {key = b[1], label = b[2], icon = b[3], text = b[2], fg = b[4], icon_size = px(16)})
    end
    return {}
end

function Keypad.media(page, parent, x, y, w, h)
    local kit, C = page.kit, Kit.C
    local px = function(v) return kit:px(v) end
    local gap, row_h = px(8), px(44)

    local top = {{"power", "Power", "power", C.danger}, {"source", "Input", "input"}, {"home", "Home", "home"}, {"back", "Back", "ret"}}
    local tw = cell(w, #top, gap)
    for i, b in ipairs(top) do
        key(page, parent, x + (i - 1) * (tw + gap), y, tw, row_h, {key = b[1], label = b[2], icon = b[3], text = b[2], fg = b[4], icon_size = px(16)})
    end

    local card_y, card_h = y + row_h + gap, h - 2 * (row_h + gap)
    local card = kit:raised(parent, x, card_y, w, card_h, px(20))
    local play_d = math.min(card_h - px(16), px(64))
    local side_d = play_d * 3 // 4
    local spread = play_d // 2 + side_d // 2 + px(18)
    local cx, cy = w // 2, card_h // 2
    key(page, card, cx - spread - side_d // 2, cy - side_d // 2, side_d, side_d, {key = "previous", label = "Previous", icon = "previous", flat = true, fill = C.sunken, radius = Kit.FULL, badge = "top"})
    key(page, card, cx + spread - side_d // 2, cy - side_d // 2, side_d, side_d, {key = "next", label = "Next", icon = "next", flat = true, fill = C.sunken, radius = Kit.FULL, badge = "top"})
    key(page, card, cx - play_d // 2, cy - play_d // 2, play_d, play_d, {key = "play_pause", label = "Play/Pause", icon = "play_pause", fill = C.accent, fg = C.inverse, radius = Kit.FULL, icon_size = px(26), badge = "top"})

    local bar = kit:raised(parent, x, y + h - row_h, w, row_h, Kit.FULL)
    local vw = cell(w, 3, 0)
    local volume = {{"vol_down", "Volume down", "vol_down"}, {"mute", "Mute", "mute"}, {"vol_up", "Volume up", "vol_up"}}
    for i, b in ipairs(volume) do
        key(page, bar, (i - 1) * vw, 0, vw, row_h, {key = b[1], label = b[2], icon = b[3], flat = true, radius = Kit.FULL, icon_size = px(20)})
    end
    return {}
end

function Keypad.custom(page, parent, x, y, w, h)
    local kit, px = page.kit, function(v) return page.kit:px(v) end
    local gap, cols = px(8), 3
    local rows = math.ceil(CUSTOM_KEY_COUNT / cols)
    local kw, kh = cell(w, cols, gap), cell(h, rows, gap)
    for i = 1, CUSTOM_KEY_COUNT do
        local col, row = (i - 1) % cols, (i - 1) // cols
        local name = "Key " .. i
        key(page, parent, x + col * (kw + gap), y + row * (kh + gap), kw, kh, {key = "key" .. i, label = name, text = name, font = "strong", radius = kit:px(16)})
    end
    return {}
end

return Keypad
