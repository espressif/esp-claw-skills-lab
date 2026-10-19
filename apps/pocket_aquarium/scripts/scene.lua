local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function color(r, g, b) return 0xff000000 | (math.floor(r) << 16) | (math.floor(g) << 8) | math.floor(b) end
return function(ui)
    local s = { fish = {}, food = {}, bubbles = {}, night = ui.record.night == true, angle = 0, angular_v = 0, wave = 1, fed_at = -1, ripples = {} }
    local cx, cy, half_w, half_h = 240, 246, 228, 160
    local palette = {0xffffbe66, 0xfff3816a, 0xffc9efe5, 0xffffdc7e, 0xff7fdae6, 0xffee9bbb, 0xffb5dcb3}
    for i = 1, 7 do s.fish[i] = { x = (i - 4) * 46, y = 15 + math.sin(i * 2) * 42, vx = i % 2 == 0 and 25 or -25, vy = 0, size = 15 + i % 3 * 3, target = i, color = palette[i] } end
    local function reset_bubble(b, initial)
        b.x, b.y = math.random(-204, 204), initial and math.random(-30, 144) or math.random(136, 150)
        b.size, b.speed = 2.5 + math.random() * 4.5, 16 + math.random() * 22
        b.phase, b.sway = math.random() * math.pi * 2, 3 + math.random() * 6
        b.delay, b.pop = initial and 0 or 0.2 + math.random() * 1.8, nil
    end
    -- Reuse a bounded pool so bubbles never accumulate during long sessions.
    for i = 1, 24 do s.bubbles[i] = {}; reset_bubble(s.bubbles[i], true) end
    function s:surface(u) return -66 + math.sin(u * 0.032 + ui.now * 2.1) * self.wave + math.sin(u * 0.051 - ui.now * 1.3) * self.wave * 0.35 end
    function s:local_point(x, y)
        local c, sn = math.cos(self.angle), math.sin(self.angle)
        return x * c + y * sn, -x * sn + y * c
    end
    function s:world_point(u, v)
        local c, sn = math.cos(self.angle), math.sin(self.angle)
        return u * c - v * sn, u * sn + v * c
    end
    function s:contain(f)
        -- Project into the rectangular tank, then below the rotated waterline.
        local pad = f.size * 1.8 + 3
        local x, y = clamp(f.x, -half_w + pad, half_w - pad), clamp(f.y, -half_h + pad, half_h - pad)
        if x ~= f.x or y ~= f.y then f.target = f.target + 1 end
        f.x, f.y = x, y
        local u, v = self:local_point(x, y)
        if v < self:surface(u) + pad then
            local lo, hi = y, half_h - pad
            for _ = 1, 10 do
                local mid = (lo + hi) / 2
                local a, b = self:local_point(x, mid)
                if b < self:surface(a) + pad then lo = mid else hi = mid end
            end
            f.y, f.vy = hi, math.abs(f.vy)
        end
    end
    local function feed(x, y)
        if ui.now - s.fed_at <= 0.65 then return end
        local u, v = s:local_point(x, y)
        if math.abs(x) >= half_w - 12 or y <= -half_h or y >= half_h or v <= s:surface(u) + 5 then return end
        s.fed_at = ui.now
        ui:sound("feed", 1)
        for i = 1, math.min(3, 8 - #s.food) do s.food[#s.food + 1] = {x=x + (i - 2) * 6, y=y, life=8} end
        s.ripples[#s.ripples + 1] = {x=x, y=y, time=ui.now}
        if #s.ripples > 3 then table.remove(s.ripples, 1) end
    end
    local function music() ui:music(s.night and "aquarium_night" or "aquarium_day") end
    music()
    function s:update(dt)
        local m = ui.motion
        local target = m.available and clamp(-m.gx * 0.9, -0.55, 0.55) or 0
        self.angular_v = (self.angular_v + (target - self.angle) * 16 * dt) * math.exp(-4 * dt)
        self.angle = clamp(self.angle + self.angular_v * dt, -0.62, 0.62)
        self.wave = self.wave + (2 + math.min(7, math.abs(self.angular_v) * 18) - self.wave) * (1 - math.exp(-2 * dt))
        if ui.tap and ui.tap.y > 84 and ui.tap.y < 406 then feed(ui.tap.x - cx, ui.tap.y - cy) end
        for i = #self.food, 1, -1 do
            local f = self.food[i]
            f.x, f.y, f.life = f.x - math.sin(self.angle) * dt * 6, f.y + math.cos(self.angle) * dt * 6, f.life - dt
            local u, v = self:local_point(f.x, f.y)
            if f.life <= 0 or math.abs(f.x) > half_w - 8 or f.y > half_h or v < self:surface(u) then table.remove(self.food, i) end
        end
        for i, f in ipairs(self.fish) do
            local tx, ty = math.sin(ui.now * 0.17 + f.target * 2) * 164, 30 + math.cos(ui.now * 0.11 + i * 3) * 70
            local nearest, distance
            for j, food in ipairs(self.food) do
                local d = (food.x - f.x) ^ 2 + (food.y - f.y) ^ 2
                if not distance or d < distance then nearest, distance = j, d end
            end
            if nearest then tx, ty = self.food[nearest].x, self.food[nearest].y; if distance < 120 then table.remove(self.food, nearest) end end
            local dx, dy = tx - f.x, ty - f.y
            for j, other in ipairs(self.fish) do
                local sx, sy = f.x - other.x, f.y - other.y
                local d = sx * sx + sy * sy
                if i ~= j and d > 0 and d < 900 then dx, dy = dx + sx * 900 / (d + 60), dy + sy * 900 / (d + 60) end
            end
            local length = math.max(1, math.sqrt(dx * dx + dy * dy))
            local speed = nearest and 58 or 22 + i * 1.7
            local k = 1 - math.exp(-2.2 * dt)
            f.vx, f.vy = f.vx + (dx / length * speed - f.vx) * k, f.vy + (dy / length * speed - f.vy) * k
            f.x, f.y = f.x + (f.vx - self.angular_v * 55) * dt, f.y + f.vy * dt
            self:contain(f)
        end
        for _, b in ipairs(self.bubbles) do
            if b.delay > 0 then
                b.delay = math.max(0, b.delay - dt)
            elseif b.pop then
                b.pop = b.pop + dt
                if b.pop >= 0.25 then reset_bubble(b, false) end
            else
                b.x = b.x + (math.sin(ui.now * 1.8 + b.phase) * b.sway + math.sin(self.angle) * b.speed * 0.6) * dt
                b.y = b.y - math.cos(self.angle) * b.speed * dt
                local u, v = self:local_point(b.x, b.y)
                if math.abs(b.x) + b.size > half_w or math.abs(b.y) + b.size > half_h then
                    reset_bubble(b, false)
                elseif v - b.size <= self:surface(u) then
                    b.pop, b.pop_u = 0, u
                end
            end
        end
    end
    function s:draw()
        ui.theme = self.night and {accent=0xff86c9d2, button=0xff244556, text=0xffe1f1ef, muted=0xff97babe, ink=0xff173347, shadow=0xff122c40}
            or {accent=0xfff8df9c, button=0xffa5d5cf, text=0xff234f5b, muted=0xff487c82, ink=0xff4c462d, shadow=0xff275c68}
        for y = 0, 479, 2 do
            local t = y / 480
            local col = self.night and color(13, 61 - t * 25, 83 - t * 25) or color(48 - t * 32, 155 - t * 82, 168 - t * 70)
            ui:rect(0, y, 480, 2, col)
        end
        for i = 1, 3 do
            local x = 40 + i * 120 + math.sin(ui.now * 0.3 + i) * 14
            ui:tri(x, 40, x - 100, 480, x + 30, 480, self.night and 0x0578e9ff or 0x0cdafff4)
        end
        for u = -480, 470, 10 do
            local a, b = self:surface(u), self:surface(u + 10)
            local x1, y1 = self:world_point(u, a); local x2, y2 = self:world_point(u + 10, b)
            local x3, y3 = self:world_point(u, -700); local x4, y4 = self:world_point(u + 10, -700)
            local sky = self.night and 0xff152b40 or 0xffc3e5dd
            ui:tri(cx + x1, cy + y1, cx + x2, cy + y2, cx + x3, cy + y3, sky)
            ui:tri(cx + x2, cy + y2, cx + x3, cy + y3, cx + x4, cy + y4, sky)
            ui:line(cx + x1, cy + y1, cx + x2, cy + y2, self.night and 0xff76bfcd or 0xffe3fff2)
        end
        -- Anchor the sky to the screen, clear of the water at maximum tilt.
        ui:circle(cx, 104, 18, self.night and 0xffd6e6ce or 0xfff6dfa2)
        if self.night then ui:circle(cx + 8, 98, 17, 0xff152b40) end
        for i = 1, 7 do
            local x, y = 44 + i * 49, i == 4 and 76 or 82 + i % 3 * 16
            local u, v = self:local_point(x - cx, y - cy)
            if v < self:surface(u) - 2 then ui:circle(x, y, 1, self.night and 0xffc2d7d7 or 0xfff0fff0) end
        end
        ui:tri(0, 416, 0, 480, 420, 480, self.night and 0xff163f49 or 0xff3c7a79)
        ui:tri(480, 402, 480, 480, 30, 480, self.night and 0xff1b4850 or 0xff59918b)
        for i = 1, 17 do
            local x, bottom = 12 + i * 26, 442 + math.sin(i * 2) * 14
            local sway = math.sin(ui.now * 1.5 + i) * 8 + self.angle * 16
            local height = 30 + i * 13 % 62
            for k = 0, 5 do
                local yy, bend = bottom - k * height / 6, sway * k / 6
                ui:line(x + bend, yy, x + sway * (k + 1) / 6, yy - height / 6, self.night and 0xff347c7a or 0xff6ab8a0)
                if k % 2 == 0 then ui:tri(x + bend, yy, x - 9 + bend, yy - 17, x + bend, yy - 8, self.night and 0xff2c6369 or 0xff5da28a) end
            end
        end
        for _, x in ipairs({28, 446}) do
            for i = 1, 4 do
                ui:rect(x + (i - 2) * 9, 407 - i % 3 * 12, 7, 37 + i % 3 * 12, self.night and 0xff58647d or 0xffd59a95, 3)
            end
        end
        for i, f in ipairs(self.fish) do
            local angle, body = math.atan(f.vy, f.vx), f.size
            local c, sn = math.cos(angle), math.sin(angle)
            local function p(x, y) return cx + f.x + x * c - y * sn, cy + f.y + x * sn + y * c end
            local function tri(x1, y1, x2, y2, x3, y3, col) local ax, ay = p(x1, y1); local bx, by = p(x2, y2); local dx, dy = p(x3, y3); ui:tri(ax, ay, bx, by, dx, dy, col) end
            local tail = math.sin(ui.now * 9 + i * 3) * 4
            tri(-body * 0.5, 0, -body * 1.5, -body * 0.65 + tail, -body * 1.5, body * 0.65 + tail, f.color)
            for j = 0, 15 do
                local a, b = j * math.pi / 8, (j + 1) * math.pi / 8
                tri(0, 0, math.cos(a) * body, math.sin(a) * body * 0.55, math.cos(b) * body, math.sin(b) * body * 0.55, f.color)
            end
            tri(-body * 0.2, 0, body * 0.15, -body * 0.75, body * 0.6, -body * 0.4, 0x99fff5da)
            tri(-body * 0.5, -body * 0.33, body * 0.5, -body * 0.33, -body * 0.1, -body * 0.45, 0x99fff5da)
            local ex, ey = p(body * 0.65, -body * 0.12); ui:circle(ex, ey, 3, 0xfffff5de); ui:circle(ex, ey, 1.5, 0xff183849)
        end
        for _, f in ipairs(self.food) do ui:circle(cx + f.x, cy + f.y, 2, 0xffefd6a1) end
        for _, b in ipairs(self.bubbles) do
            if b.delay == 0 then
                if b.pop then
                    local x, y = self:world_point(b.pop_u, self:surface(b.pop_u))
                    local alpha = math.floor((1 - b.pop / 0.25) * 160)
                    if math.abs(x) < half_w - 10 and math.abs(y) < half_h - 10 then ui:ring(cx + x, cy + y, b.size + b.pop * 22, (alpha << 24) | 0xbfe9e6) end
                else
                    local x, y = cx + b.x, cy + b.y
                    ui:circle(x, y, b.size, self.night and 0x206fbacb or 0x2474d7e2)
                    ui:ring(x, y, b.size, self.night and 0xb08ed5df or 0xb0c9f3ed)
                    ui:circle(x - b.size * 0.3, y - b.size * 0.35, math.max(0.8, b.size * 0.18), 0xcceffff8)
                end
            end
        end
        for _, r in ipairs(self.ripples) do local age = ui.now - r.time; if age < 0.7 then ui:ring(cx + r.x, cy + r.y, 5 + age * 25, 0xffafdad0) end end
        ui:header("Pocket Aquarium", self.night and "A little ocean under moonlight" or "A little ocean in your hands")
        if ui:button(92, 448, 136, self.night and "切换白昼" or "切换夜间") then self.night = not self.night; ui.record.night = self.night; ui:save(); music() end
        if ui:button(316, 448, 280, "投喂鱼群", true) then feed(0, 50) end
    end
    return s
end
