local M = {}
local abs, min, max, sqrt = math.abs, math.min, math.max, math.sqrt
M.limits = { fruit = 7, pieces = 12, particles = 24, trail = 10 }
M.colors = { 0xffff5f62, 0xffffac31, 0xffaee44e, 0xffff6b58, 0xffefd45a }

local function pool(n)
    local result = {}
    for i = 1, n do result[i] = { active = false } end
    return result
end
local function free(items)
    for _, item in ipairs(items) do if not item.active then return item end end
end
local function clear(items) for _, item in ipairs(items) do item.active = false end end
local function inside(x, y, left, top, width, height)
    return x >= left and x <= left + width and y >= top and y <= top + height
end
local function hit(ax, ay, bx, by, cx, cy, radius)
    local dx, dy = bx - ax, by - ay
    local length = dx * dx + dy * dy
    local t = length > 0 and max(0, min(1, ((cx - ax) * dx + (cy - ay) * dy) / length)) or 0
    return (ax + t * dx - cx)^2 + (ay + t * dy - cy)^2 <= radius^2, t
end
M.hit = hit

function M.new(random, record)
    local g = { random = random or math.random, record = record or {}, state = "home", mode = "rush", time = 0, clock = 0, score = 0, cuts = 0, best_combo = 0, energy = 0, fever = 0, flash = 0, combo = 0, combo_age = 1, toast = 0, toast_kind = "", bonus = 0, wave = 0, round = 0, ready = 0, sound = nil, save = false, exit = false }
    g.mode = g.record.mode == "zen" and "zen" or "rush"
    g.sound_mode = g.record.sound_mode or "music"
    if g.sound_mode ~= "music" and g.sound_mode ~= "effects" and g.sound_mode ~= "mute" then g.sound_mode = "music" end
    g.fruits, g.pieces, g.particles, g.trail = pool(M.limits.fruit), pool(M.limits.pieces), pool(M.limits.particles), pool(M.limits.trail)
    g.trail_index, g.particle_index, g.piece_index = 1, 1, 1

    function g:emit(name, priority)
        if not self.sound or priority >= self.sound.priority then self.sound = { name = name, priority = priority } end
    end
    function g:reset_stroke()
        self.blade, self.combo = nil, 0
        clear(self.trail)
    end
    function g:start()
        self.state, self.ready, self.clock, self.score, self.cuts, self.best_combo = "ready", 1.4, 0, 0, 0, 0
        self.energy, self.fever, self.flash, self.wave, self.toast = 0, 0, 0, 0.2, 0
        self.round, self.new_best, self.bombs = self.round + 1, false, 0
        clear(self.fruits); clear(self.pieces); clear(self.particles)
        self:reset_stroke()
        self:emit("tick", 2)
    end
    function g:finish()
        if self.state ~= "playing" and self.state ~= "paused" then return end
        self.state, self.toast, self.fever = "result", 0, 0
        self.finished_early = self.mode == "rush" and self.clock < 60
        local key = "best_" .. self.mode
        self.new_best = self.score > (tonumber(self.record[key]) or 0)
        if self.new_best then self.record[key] = self.score end
        self.record.mode, self.save = self.mode, true
        self:reset_stroke()
        self:emit("result", 4)
    end
    function g:pause()
        if self.state == "playing" then self.state = "paused"; self:reset_stroke() end
    end
    function g:resume()
        if self.state == "paused" then self.state = "playing"; self:reset_stroke() end
    end
    function g:burst(x, y, kind, count)
        for i = 1, count do
            local p = self.particles[self.particle_index]
            self.particle_index = self.particle_index % #self.particles + 1
            local angle, speed = self.random() * math.pi * 2, 75 + self.random() * 130
            p.active, p.x, p.y, p.vx, p.vy = true, x, y, math.cos(angle) * speed, math.sin(angle) * speed - 50
            p.life, p.radius, p.color = 0.32 + self.random() * 0.22, 2 + self.random() * 3, M.colors[kind] or 0xffffaf4c
        end
    end
    function g:spawn()
        local count = self.mode == "zen" and 3 or min(5, 3 + math.floor(self.clock / 25))
        local center, velocity = 185 + self.random() * 110, -725 - self.random() * 65
        for i = 1, count do
            local f = free(self.fruits)
            if not f then break end
            f.active, f.kind, f.x, f.y = true, self.random(1, 5), center + (i - (count + 1) / 2) * 66, 525 + self.random() * 14
            f.vx, f.vy = (240 - f.x) * 0.22 + (self.random() - 0.5) * 40, velocity + (self.random() - 0.5) * 25
            f.px, f.py, f.radius, f.age = f.x, f.y, 35, self.random()
        end
        if self.mode == "rush" and self.clock > 7 and self.fever <= 0 and self.random() < 0.45 then
            local f = free(self.fruits)
            if f then
                f.active, f.kind, f.x, f.y = true, 0, center > 240 and 58 or 422, 535
                f.vx, f.vy, f.radius, f.age = f.x < 240 and 28 or -28, -735, 28, 0
                f.px, f.py = f.x, f.y
            end
        end
    end
    function g:cut(f)
        f.active = false
        if f.kind == 0 then
            self.score, self.energy, self.fever, self.combo = max(0, self.score - 20), 0, 0, 0
            self.bombs, self.flash, self.toast, self.toast_kind = self.bombs + 1, 0.22, 0.65, "bomb"
            self:burst(f.x, f.y, 0, 12); self:emit("bomb", 5)
            return false
        end
        local multiplier = self.fever > 0 and 2 or 1
        self.cuts, self.score = self.cuts + 1, self.score + 10 * multiplier
        self.combo = self.combo_age <= 0.22 and self.combo + 1 or 1
        self.combo_age, self.best_combo = 0, max(self.best_combo, self.combo)
        if self.combo >= 3 then
            local bonus = (self.combo == 3 and 15 or 10) * multiplier
            self.score, self.bonus = self.score + bonus, self.combo == 3 and bonus or self.bonus + bonus
            self.toast, self.toast_kind, self.toast_combo = 0.7, "combo", self.combo
            self:emit("combo", 3)
        else self:emit("slice-" .. self.random(1, 3), 1) end
        self:burst(f.x, f.y, f.kind, 5)
        for side = 1, 2 do
            local p = self.pieces[self.piece_index]
            self.piece_index = self.piece_index % #self.pieces + 1
            p.active, p.kind, p.part, p.life = true, f.kind, side, 0.65
            p.x, p.y, p.vx, p.vy = f.x + (side == 1 and -12 or 12), f.y, f.vx + (side == 1 and -95 or 95), f.vy * 0.25 - 65
        end
        if self.fever <= 0 and self.mode == "rush" then
            self.energy = self.energy + 1
            if self.energy >= 20 then
                self.energy, self.fever, self.toast, self.toast_kind = 0, 5, 1, "fever"
                for _, other in ipairs(self.fruits) do if other.kind == 0 then other.active = false end end
                self:emit("fever", 4)
            end
        end
        return true
    end
    function g:slice(x, y, id)
        if self.state ~= "playing" or y < 82 or y > 444 or x < 0 or x > 480 then self.blade = nil; return end
        local previous = self.blade
        self.blade = { x = x, y = y, id = id }
        if not previous or previous.id ~= id then return end
        if (previous.x - x)^2 + (previous.y - y)^2 < 9 then return end
        local t = self.trail[self.trail_index]
        self.trail_index = self.trail_index % #self.trail + 1
        t.active, t.x1, t.y1, t.x2, t.y2, t.life = true, previous.x, previous.y, x, y, 0.15
        -- Relative motion catches fast swipes and fruit moving between samples.
        local hits = {}
        for _, f in ipairs(self.fruits) do
            if f.active and f.y > 100 and f.y < 446 then
                local crossed, along = hit(previous.x - f.px, previous.y - f.py, x - f.x, y - f.y, 0, 0, f.radius)
                if crossed then hits[#hits + 1] = { fruit = f, along = along } end
            end
        end
        table.sort(hits, function(a, b) return a.along < b.along end)
        for _, item in ipairs(hits) do
            if item.fruit.active and not self:cut(item.fruit) then break end
        end
    end
    function g:update(dt)
        dt = max(0, dt)
        self.time = self.time + dt
        if self.state == "ready" then
            self.ready = self.ready - dt
            if self.ready <= 0 then self.state, self.clock, self.wave = "playing", 0, 0.2 end
            return
        end
        if self.state ~= "playing" then return end
        self.clock = self.clock + dt
        if self.mode == "rush" and self.clock >= 60 then self.clock = 60; self:finish(); return end
        self.combo_age, self.toast, self.flash = self.combo_age + dt, max(0, self.toast - dt), max(0, self.flash - dt)
        self.fever = max(0, self.fever - dt)
        if dt > 0.1 then self:reset_stroke(); self.press = nil end
        -- Limit physics catch-up without slowing the wall-clock round timer.
        local step = min(dt, 0.08)
        self.wave = self.wave - dt
        if self.wave <= 0 then self:spawn(); self.wave = self.mode == "zen" and 1.25 or max(0.82, 1.3 - self.clock * 0.007) end
        for _, f in ipairs(self.fruits) do
            if f.active then
                f.px, f.py = f.x, f.y
                f.x, f.y, f.vy, f.age = f.x + f.vx * step, f.y + f.vy * step + 450 * step^2, f.vy + 900 * step, f.age + step
                if f.y > 580 and f.vy > 0 then f.active = false end
            end
        end
        for _, p in ipairs(self.pieces) do
            if p.active then
                p.x, p.y, p.vy, p.life = p.x + p.vx * step, p.y + p.vy * step, p.vy + 850 * step, p.life - dt
                if p.life <= 0 or p.y > 560 then p.active = false end
            end
        end
        for _, p in ipairs(self.particles) do
            if p.active then
                p.x, p.y, p.vy, p.life = p.x + p.vx * step, p.y + p.vy * step, p.vy + 440 * step, p.life - dt
                if p.life <= 0 then p.active = false end
            end
        end
        for _, t in ipairs(self.trail) do if t.active then t.life = t.life - dt; t.active = t.life > 0 end end
    end
    function g:touch(point)
        if not point then
            local p = self.press
            self.press, self.blade, self.combo = nil, nil, 0
            if not p or p.state ~= self.state then return end
            if p.action == "start" then
                if p.x - p.sx >= 110 and abs(p.y - p.sy) < 50 then self:start() end
                return
            end
            if p.distance > 18 then return end
            if p.action == "exit" then self.exit = true
            elseif p.action == "sound" then
                self.sound_mode = self.sound_mode == "music" and "effects" or self.sound_mode == "effects" and "mute" or "music"
                self.record.sound_mode, self.save = self.sound_mode, true
            elseif p.action == "mode" then
                self.mode = p.x < 240 and "rush" or "zen"
                self.record.mode, self.save = self.mode, true
            elseif p.action == "pause" then self:pause()
            elseif p.action == "resume" then self:resume()
            elseif p.action == "finish" then self:finish()
            elseif p.action == "again" then self:start()
            elseif p.action == "home" then self.state = "home"; self:reset_stroke() end
            return
        end
        local p = self.press
        if p and p.id ~= point.id then self:reset_stroke(); self.press = nil; return end
        if not p then
            p = { id = point.id, sx = point.x, sy = point.y, x = point.x, y = point.y, distance = 0, state = self.state }
            self.press = p
            local x, y = point.x, point.y
            if self.state == "playing" then p.action = inside(x, y, 410, 10, 58, 58) and "pause" or "slice"
            elseif self.state == "home" then
                if inside(x, y, 24, 392, 432, 54) then p.action = "start"
                elseif inside(x, y, 100, 342, 280, 42) then p.action = "mode"
                elseif inside(x, y, 8, 8, 54, 54) then p.action = "exit"
                elseif inside(x, y, 414, 8, 58, 54) then p.action = "sound" end
            elseif self.state == "result" then
                if inside(x, y, 24, 365, 432, 58) then p.action = "again"
                elseif inside(x, y, 150, 432, 180, 40) or inside(x, y, 8, 8, 54, 54) then p.action = "home"
                elseif inside(x, y, 414, 8, 58, 54) then p.action = "sound" end
            elseif self.state == "paused" then
                if inside(x, y, 70, 260, 340, 58) then p.action = "resume"
                elseif inside(x, y, 120, 335, 240, 48) then p.action = "finish"
                elseif inside(x, y, 414, 8, 58, 54) then p.action = "sound" end
            end
        end
        p.x, p.y = point.x, point.y
        p.distance = max(p.distance, sqrt((p.x - p.sx)^2 + (p.y - p.sy)^2))
        if p.action == "slice" then self:slice(point.x, point.y, point.id) end
    end
    return g
end
return M
