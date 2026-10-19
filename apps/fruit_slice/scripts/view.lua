local M = {}
local C = { bg = 0xff111c25, panel = 0xff20323c, text = 0xfffffaed, muted = 0xff91a5af, lime = 0xffd8f46a, red = 0xffff6869, line = 0xff30454f }
local function round(x) return math.floor(x + 0.5) end

function M.new(screen, directory, display)
    local info = screen:info()
    local scale = math.min(info.width, info.height) / 480
    local ox, oy = round((info.width - 480 * scale) / 2), round((info.height - 480 * scale) / 2)
    local v = { screen = screen, fonts = {}, sprites = {}, scale = scale, ox = ox, oy = oy, draws = 0, damage = {}, damage_count = 0 }
    local function sz(x) return round(x * scale) end
    local function px(x) return ox + sz(x) end
    local function py(y) return oy + sz(y) end
    local function remember(x, y, w, h)
        if not v.tracking then return end
        local right, bottom = math.min(px(480), x + w), math.min(py(444), y + h)
        x, y = math.max(px(0), x), math.max(py(80), y)
        if x >= right or y >= bottom then return end
        v.damage_area = v.damage_area + (right - x) * (bottom - y)
        if v.damage_area >= sz(480) * sz(364) / 2 then
            v.full_damage, v.tracking = true, false
            return
        end
        v.damage_count = v.damage_count + 1
        local rect = v.damage[v.damage_count]
        if not rect then rect = {}; v.damage[v.damage_count] = rect end
        rect.x, rect.y, rect.w, rect.h = x, y, right - x, bottom - y
    end
    function v:close()
        for _, font in pairs(self.fonts) do
            local ok, err = pcall(font.close, font)
            if not ok then print("[fruit_slice] font close failed: " .. tostring(err)) end
        end
    end
    function v:text(x, y, text, size, color, align)
        local font = self.fonts[size]
        local opts = { font = font, color = color or C.text }
        local w, h = screen:measure_text(text, opts)
        local left = px(x) - (align == "left" and 0 or align == "right" and w or w // 2)
        screen:text(left, py(y), text, opts)
        if self.tracking then remember(left - 2, py(y) - 2, w + 4, h + 4) end
    end
    function v:rect(x, y, w, h, color, radius)
        screen:fill_round_rect(px(x), py(y), sz(w), sz(h), sz(radius or 0), color)
        if self.tracking then remember(px(x), py(y), sz(w), sz(h)) end
    end
    function v:circle(x, y, r, color)
        local radius = math.max(1, sz(r))
        screen:fill_circle(px(x), py(y), radius, color)
        if self.tracking then remember(px(x) - radius, py(y) - radius, radius * 2 + 1, radius * 2 + 1) end
    end
    function v:line(x1, y1, x2, y2, color, width)
        width = width or 1
        local dx, dy = x2 - x1, y2 - y1
        local length = math.sqrt(dx * dx + dy * dy)
        if length < 0.5 then return end
        local nx, ny = -dy / length * width / 2, dx / length * width / 2
        screen:fill_triangle(px(x1 + nx), py(y1 + ny), px(x1 - nx), py(y1 - ny), px(x2 + nx), py(y2 + ny), color)
        screen:fill_triangle(px(x1 - nx), py(y1 - ny), px(x2 - nx), py(y2 - ny), px(x2 + nx), py(y2 + ny), color)
        if self.tracking then
            local left, top = px(math.min(x1, x2) - math.abs(nx)), py(math.min(y1, y2) - math.abs(ny))
            remember(left, top, px(math.max(x1, x2) + math.abs(nx)) - left + 1, py(math.max(y1, y2) + math.abs(ny)) - top + 1)
        end
    end
    function v:sprite(name, x, y)
        local sprite = assert(self.sprites[name], name)
        local left, top = px(x) - sprite.width // 2, py(y) - sprite.height // 2
        for _, r in ipairs(sprite) do screen:blit(left + r.x, top + r.y, r.data, r.options) end
        if self.tracking then remember(left, top, sprite.width, sprite.height) end
    end
    local function load_sprite(name)
        local file <close> = assert(io.open(directory .. "/assets/" .. name .. ".spr", "rb"))
        local data = assert(file:read("a"))
        local magic, width, height, count, offset = string.unpack("<c4I2I2I2", data)
        assert(magic == "FSP1" and width <= 160 and height <= 160 and count <= 320, "invalid sprite: " .. name)
        local sprite = { width = sz(width), height = sz(height) }
        for _ = 1, count do
            local x, y, w, h
            x, y, w, h, offset = string.unpack("<I2I2I2I2", data, offset)
            assert(w > 0 and h > 0 and x + w <= width and y + h <= height and offset + w * h * 2 - 1 <= #data, "truncated sprite: " .. name)
            local bytes = data:sub(offset, offset + w * h * 2 - 1)
            offset = offset + #bytes
            local sw, sh = sz(x + w) - sz(x), sz(y + h) - sz(y)
            if sw > 0 and sh > 0 then
                if scale ~= 1 then
                    -- Resize once during loading; the frame loop only blits cached strips.
                    local pixels = {}
                    for row = 0, sh - 1 do
                        for col = 0, sw - 1 do
                            local i = (math.min(h - 1, math.floor(row * h / sh)) * w + math.min(w - 1, math.floor(col * w / sw))) * 2 + 1
                            pixels[#pixels + 1] = bytes:sub(i, i + 1)
                        end
                    end
                    bytes = table.concat(pixels)
                end
                sprite[#sprite + 1] = { x = sz(x), y = sz(y), data = bytes, options = { width = sw, height = sh, format = "rgb565" } }
            end
        end
        assert(offset == #data + 1, "extra sprite data: " .. name)
        v.sprites[name] = sprite
    end
    function v:load()
        for _, target in ipairs({12, 18, 24, 36, 48, 60, 84}) do
            local actual = 12
            for _, size in ipairs({12, 18, 24, 36, 48, 60}) do if size <= target * scale then actual = size end end
            if target == 84 and scale >= 1 then actual = 84 end
            self.fonts[target] = display.load_font(directory .. "/assets/ui-" .. actual .. ".dfn")
        end
        for kind = 1, 5 do
            for _, frame in ipairs({"0", "1", "2", "r-18", "r18"}) do load_sprite("fruit-" .. kind .. "-" .. frame) end
        end
        for _, name in ipairs({"hero-1-1", "hero-1-2", "hero-2-1", "hero-3-2", "bomb"}) do load_sprite(name) end
    end
    function v:speaker(mode)
        self:rect(431, 27, 5, 12, C.text, 1)
        screen:fill_triangle(px(434), py(27), px(443), py(20), px(443), py(46), C.text)
        if mode == "mute" then self:line(427, 20, 454, 47, C.red, 3)
        else
            screen:arc(px(441), py(33), sz(10), -55, 55, C.text)
            if mode == "music" then screen:arc(px(441), py(33), sz(16), -55, 55, C.text) end
        end
    end
    function v:back()
        self:line(39, 21, 28, 33, C.text, 3)
        self:line(28, 33, 39, 45, C.text, 3)
    end
    function v:button(y, label, held)
        self:rect(24, y, 432, 54, held and 0xffb7d451 or C.lime, 25)
        self:text(240, y + 15, label, 24, C.bg)
    end
    function v:home(g)
        self:back(); self:speaker(g.sound_mode)
        self:text(240, 57, "FRUIT", 60)
        self:text(240, 111, "SLICE", 60)
        local bob = math.sin(g.time * 1.6) * 3
        self:sprite("hero-2-1", 102, 243 - bob)
        self:sprite("hero-3-2", 380, 277 + bob)
        self:sprite("hero-1-1", 211, 232 + bob)
        self:sprite("hero-1-2", 282, 281 - bob)
        self:line(136, 319, 333, 196, 0xff51636a, 7)
        self:line(141, 315, 330, 198, C.text, 3)
        self:circle(140, 218, 3, C.red); self:circle(349, 227, 4, 0xffffaf4c); self:circle(329, 310, 3, C.lime)
        self:rect(100, 347, 134, 34, g.mode == "rush" and C.lime or C.panel, 17)
        self:rect(246, 347, 134, 34, g.mode == "zen" and C.lime or C.panel, 17)
        self:text(167, 354, "RUSH", 24, g.mode == "rush" and C.bg or C.muted)
        self:text(313, 354, "ZEN", 24, g.mode == "zen" and C.bg or C.muted)
        local swipe = g.press and g.press.action == "start" and math.max(0, math.min(1, (g.press.x - g.press.sx) / 110)) or 0
        self:button(395, "SWIPE TO START", swipe > 0)
        self:line(400 + swipe * 5, 413, 411 + swipe * 5, 422, C.bg, 2)
        self:line(411 + swipe * 5, 422, 400 + swipe * 5, 431, C.bg, 2)
        self:text(240, 456, "BEST " .. tostring(g.record["best_" .. g.mode] or 0), 18, C.muted)
    end
    function v:play(g)
        local seconds = math.max(0, math.ceil(60 - g.clock))
        if self.last_score ~= g.score or self.last_seconds ~= seconds then
            screen:save(); screen:clip(px(0), py(0), sz(480), sz(80))
            self:rect(0, 0, 480, 80, C.bg)
            self:text(24, 16, tostring(g.score), g.score < 10000 and 48 or 36, C.text, "left")
            self:text(26, 60, "SCORE", 18, C.muted, "left")
            self:text(261, 25, g.mode == "zen" and "ZEN" or string.format("%02d:%02d", seconds // 60, seconds % 60), 36, seconds <= 10 and g.mode == "rush" and C.red or C.text)
            self:rect(429, 24, 6, 25, C.text, 2); self:rect(443, 24, 6, 25, C.text, 2)
            screen:restore()
            self.last_score, self.last_seconds = g.score, seconds
        end
        -- Restore the previous objects before drawing the new frame.
        local pieces = 0
        for _, p in ipairs(g.pieces) do if p.active then pieces = pieces + 1 end end
        local full_damage = g.flash > 0 or pieces >= 6
        if self.full_damage or full_damage then
            screen:fill_rect(px(0), py(80), sz(480), sz(364), C.bg)
        else
            for i = 1, self.damage_count do
                local r = self.damage[i]
                screen:fill_rect(r.x, r.y, r.w, r.h, C.bg)
            end
        end
        self.damage_count, self.damage_area, self.full_damage, self.tracking = 0, 0, full_damage, not full_damage
        screen:save(); screen:clip(px(0), py(82), sz(480), sz(362))
        for _, f in ipairs(g.fruits) do
            if f.active then
                local frame = math.floor(f.age * 3) % 4
                local name = f.kind == 0 and "bomb" or "fruit-" .. f.kind .. "-" .. (frame == 1 and "r18" or frame == 3 and "r-18" or "0")
                self:sprite(name, f.x, f.y)
            end
        end
        for _, p in ipairs(g.pieces) do if p.active then self:sprite("fruit-" .. p.kind .. "-" .. p.part, p.x, p.y) end end
        for _, p in ipairs(g.particles) do
            if p.active then self:circle(p.x, p.y, p.radius * math.min(1, p.life * 6), p.color) end
        end
        for _, t in ipairs(g.trail) do
            if t.active then
                local fade = math.max(0, math.min(1, t.life / 0.15))
                self:line(t.x1, t.y1, t.x2, t.y2, 0xff51616a, 7 * fade)
                self:line(t.x1, t.y1, t.x2, t.y2, C.text, math.max(1, 3 * fade))
            end
        end
        screen:restore()
        if g.toast > 0 then
            local title = g.toast_kind == "bomb" and "OUCH! -20" or g.toast_kind == "fever" and "FEVER  x2" or tostring(g.toast_combo) .. " FRUIT COMBO"
            self:text(24, 90, title, 24, g.toast_kind == "bomb" and C.red or C.lime, "left")
            if g.toast_kind == "combo" then self:text(25, 119, "+" .. g.bonus .. " BONUS", 18, C.text, "left") end
        end
        self.tracking = false
        local bar = g.mode == "zen" and g.cuts or round(365 * (g.fever > 0 and g.fever / 5 or g.energy / 20))
        if self.last_bar ~= bar then
            self:rect(0, 444, 480, 36, C.bg)
            self:text(24, 451, g.mode == "zen" and "SLICED" or "FEVER", 18, C.muted, "left")
            if g.mode == "zen" then self:text(455, 450, tostring(g.cuts), 18, C.lime, "right")
            else
                self:rect(91, 455, 365, 9, C.panel, 4)
                self:rect(91, 455, bar, 9, g.fever > 0 and 0xffffc76a or C.lime, 4)
            end
            self.last_bar = bar
        end
        self.tracking = not self.full_damage
        if g.fever > 0 then self:rect(0, 80, 3, 362, C.lime); self:rect(477, 80, 3, 362, C.lime) end
        if g.flash > 0 then
            local alpha = round(90 * g.flash / 0.22)
            self:rect(0, 80, 480, 364, (alpha << 24) | 0xe65a50)
        end
        self.tracking = false
    end
    function v:result(g)
        self:back(); self:speaker(g.sound_mode)
        self:text(240, 67, g.mode == "zen" and "NICE FLOW" or g.finished_early and "ROUND OVER" or "TIME'S UP", 24, C.muted)
        self:sprite("hero-2-1", 85, 172)
        self:sprite("hero-3-2", 394, 187)
        self:text(240, 119, tostring(g.score), g.score <= 9999 and 84 or 60)
        self:text(240, 203, g.new_best and "NEW BEST" or "WELL SLICED", 24, C.lime)
        self:rect(40, 261, 400, 1, C.line)
        self:text(135, 281, "FRUIT", 18, C.muted)
        self:text(344, 281, "BEST COMBO", 18, C.muted)
        self:text(135, 306, tostring(g.cuts), 36)
        self:text(344, 306, tostring(g.best_combo), 36)
        self:rect(240, 283, 1, 55, C.line)
        self:button(367, "PLAY AGAIN", g.press and g.press.action == "again")
        self:text(240, 444, "HOME", 18, C.muted)
    end
    function v:draw(g)
        local partial = g.state == "playing" and self.render_state == "playing"
        if partial then screen:begin() else screen:begin({ clear = C.bg }) end
        if not partial then self.last_score, self.last_seconds, self.last_bar, self.damage_count, self.full_damage = nil, nil, nil, 0, false end
        if g.state == "home" then self:home(g)
        elseif g.state == "result" then self:result(g)
        elseif g.state == "paused" then
            self:speaker(g.sound_mode)
            self:text(240, 134, "TAKE A BREATH", 36)
            self:text(240, 191, "Your round is paused.", 18, C.muted)
            self:rect(70, 260, 340, 58, C.lime, 27)
            self:text(240, 277, "RESUME", 24, C.bg)
            self:text(240, 350, "FINISH ROUND", 18, C.muted)
        elseif g.state == "ready" then
            self:text(240, 156, g.ready > 0.55 and "READY?" or "SLICE!", 60, g.ready > 0.55 and C.text or C.lime)
            self:text(240, 244, g.mode == "rush" and "60 seconds. Make them juicy." or "No bombs. Just good slices.", 18, C.muted)
            self:text(240, 302, "SWIPE THROUGH THE FRUIT", 12, C.muted)
        else self:play(g) end
        screen:present()
        self.render_state = g.state
        self.draws = self.draws + 1
    end
    return v
end
return M
