local source = debug.getinfo(1, "S").source:match("^@(.*/)")
local levels = assert(loadfile(source .. "levels.lua"))()
return function(ui)
    local s = { level = 1, phase = "ready", walls = {}, pits = {}, trails = {}, x = 0, y = 0, vx = 0, vy = 0, elapsed = 0, falls = 0, hold = 0, last_bump = -1 }
    local cw, ch, left, top, radius = 44, 36, 42, 82, 9
    s.background = 0xff101d2b
    ui.theme = {accent=0xfff1bd63, button=0xff263b50, text=0xffedf4f5, muted=0xff99b0c2, ink=0xff382a18}
    local function load_level()
        s.walls, s.pits, s.trails, s.checkpoint = {}, {}, {}, nil
        s.elapsed, s.falls, s.hold, s.vx, s.vy = 0, 0, 0, 0, 0
        for row, line in ipairs(levels[s.level]) do
            for col = 1, #line do
                local tile, x, y = line:sub(col, col), left + (col - 0.5) * cw, top + (row - 0.5) * ch
                if tile == "#" then s.walls[#s.walls + 1] = { x = x - cw / 2, y = y - ch / 2 }
                elseif tile == "S" then s.x, s.y, s.spawn_x, s.spawn_y = x, y, x, y
                elseif tile == "G" then s.goal = { x = x, y = y }
                elseif tile == "C" then s.checkpoint = { x = x, y = y }
                elseif tile == "O" then s.pits[#s.pits + 1] = { x = x, y = y } end
            end
        end
        ui:music("maze_menu")
    end
    local function collision(x, y)
        for _, w in ipairs(s.walls) do
            local nx, ny = math.max(w.x, math.min(w.x + cw, x)), math.max(w.y, math.min(w.y + ch, y))
            if (x - nx) ^ 2 + (y - ny) ^ 2 < radius ^ 2 then return true end
        end
        return false
    end
    local function start() s.phase = "calibrating"; ui:calibrate(); ui:music(nil) end
    load_level()
    function s:update(dt)
        if self.phase == "calibrating" and not ui.calibration and ui.motion.available then self.phase = "playing" end
        if self.phase == "falling" then
            self.elapsed = self.elapsed + (ui.wall_dt or dt)
            if ui.now - self.fall_time >= 0.6 then self.x, self.y, self.vx, self.vy, self.phase = self.spawn_x, self.spawn_y, 0, 0, "playing" end
            return
        end
        if self.phase ~= "playing" or not ui.motion.available or ui.calibration then return end
        self.elapsed = self.elapsed + (ui.wall_dt or dt)
        local steps = math.max(1, math.ceil(dt / 0.008))
        local step = dt / steps
        for _ = 1, steps do
            self.vx = math.max(-130, math.min(130, (self.vx + ui.motion.x * 720 * step) * math.exp(-3.2 * step)))
            self.vy = math.max(-130, math.min(130, (self.vy + ui.motion.y * 720 * step) * math.exp(-3.2 * step)))
            local nx, ny = self.x + self.vx * step, self.y + self.vy * step
            local hit = false
            if collision(nx, self.y) then self.vx, hit = -self.vx * 0.2, true else self.x = nx end
            if collision(self.x, ny) then self.vy, hit = -self.vy * 0.2, true else self.y = ny end
            if hit and ui.now - self.last_bump > 0.18 then self.last_bump = ui.now; ui:sound("bump_" .. math.random(3), 1) end
        end
        if #self.trails >= 8 then table.remove(self.trails, 1) end
        self.trails[#self.trails + 1] = { self.x, self.y }
        local c = self.checkpoint
        if c and not c.active and (self.x - c.x) ^ 2 + (self.y - c.y) ^ 2 < 100 then
            c.active, self.spawn_x, self.spawn_y = true, c.x, c.y; ui:sound("checkpoint", 3)
        end
        for _, pit in ipairs(self.pits) do
            if (self.x - pit.x) ^ 2 + (self.y - pit.y) ^ 2 < 64 then
                self.phase, self.fall_time, self.falls, self.hold = "falling", ui.now, self.falls + 1, 0; ui:sound("fall", 4); return
            end
        end
        local g = self.goal
        local in_goal = (self.x - g.x) ^ 2 + (self.y - g.y) ^ 2 < 90 and self.vx ^ 2 + self.vy ^ 2 < 400
        self.hold = in_goal and self.hold + dt or 0
        if self.hold >= 0.25 then
            self.phase = "won"
            self.stars = 1 + (self.elapsed < 40 + self.level * 8 and 1 or 0) + (self.falls == 0 and 1 or 0)
            local key = "level_" .. self.level
            local old = tonumber(ui.record[key])
            ui.record[key] = old and math.min(old, self.elapsed) or self.elapsed
            ui:save(); ui:sound("win", 5)
        end
    end
    function s:draw()
        ui:header("Gravity Maze", string.format("Level %02d / 08    ·    %.1f s", self.level, self.elapsed))
        ui:rect(24, 72, 432, 344, 0xff09131e, 14)
        ui:rect(24, 70, 432, 344, 0xff426079, 14)
        ui:rect(28, 74, 424, 336, 0xff24394c, 11)
        ui:rect(left, top, cw * 9, ch * 9, 0xff102333, 6)
        for row = 0, 8 do for col = 0, 8 do ui:circle(left + (col + 0.5) * cw, top + (row + 0.5) * ch, 1, 0xff365064) end end
        for _, wall in ipairs(self.walls) do
            ui:rect(wall.x + 1, wall.y + 4, cw - 2, ch - 4, 0xff08131f, 4)
            ui:rect(wall.x + 1, wall.y + 1, cw - 2, ch - 5, 0xff45647b, 4)
            ui:line(wall.x + 5, wall.y + 2, wall.x + cw - 6, wall.y + 2, 0xff6b8ca1)
        end
        for _, x in ipairs({34, 446}) do for _, y in ipairs({80, 404}) do ui:circle(x, y, 3, 0xff98afbc); ui:line(x - 2, y, x + 2, y, 0xff263b50) end end
        local g = self.goal
        ui:circle(g.x, g.y, 14 + math.sin(ui.now * 3), 0xff614d2c); ui:ring(g.x, g.y, 11, 0xffe9c37a); ui:circle(g.x, g.y, 6, 0xffffdc92)
        for _, pit in ipairs(self.pits) do ui:circle(pit.x, pit.y + 1, 11, 0xff455460); ui:circle(pit.x, pit.y, 10, 0xff030c15); ui:ring(pit.x, pit.y, 7, 0xff12232f) end
        local c = self.checkpoint
        if c then ui:ring(c.x, c.y, 10, c.active and 0xff92dfb6 or 0xff638389); ui:circle(c.x, c.y, 3, c.active and 0xffb9ffce or 0xff638389) end
        for i, p in ipairs(self.trails) do ui:circle(p[1], p[2], 2, 0xff284052 + i * 0x020202) end
        local r = self.phase == "falling" and radius * math.max(0, 1 - (ui.now - self.fall_time) / 0.6) or radius
        ui:circle(self.x + 2, self.y + 3, r + 1, 0x99000000); ui:circle(self.x, self.y, r, 0xffbfcdd0)
        ui:circle(self.x - 2, self.y - 2, math.max(0, r * 0.5), 0xfff4f6e9)
        if self.phase == "won" then
            ui:rect(96, 166, 288, 160, 0xff102333, 14)
            ui:rect(120, 166, 240, 3, 0xffedc77d)
            ui:text(240, 184, "抵达终点", 24, 0xffffdc92)
            ui:text(240, 220, string.rep("★", self.stars), 36, 0xffedc77d)
            ui:text(240, 278, string.format("%.1f 秒 · 掉落 %d", self.elapsed, self.falls), 18)
            if ui:button(240, 448, 432, self.level == 8 and "再玩一轮" or "下一关", true) then self.level = self.level % #levels + 1; load_level(); self.phase = "ready" end
        elseif self.phase == "ready" then
            if ui:button(128, 448, 208, "选关 " .. self.level) then self.level = self.level % #levels + 1; load_level() end
            if ui:button(352, 448, 208, "开始挑战", true) then start() end
        else
            if ui:button(128, 448, 208, self.phase == "paused" and "继续" or "暂停") then
                if self.phase == "playing" then self.phase = "paused" elseif self.phase == "paused" then self.phase = "playing" end
            end
            if ui:button(352, 448, 208, "校准") then start(); self.vx, self.vy = 0, 0 end
        end
    end
    return s
end
