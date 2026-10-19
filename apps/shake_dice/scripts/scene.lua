return function(ui)
    local s = { phase = "ready", count = 2, dice = {}, history = {}, peaks = 0, quiet = 0, phase_time = 0, last_hit = -1, energy = 0 }
    local paper, ink, muted, accent = 0xfff0f4e8, 0xff332d43, 0xff81768e, 0xff7664c4
    s.background = paper
    ui.theme = {accent=accent, button=0xffeae4f4, text=ink, muted=muted, ink=paper, shadow=paper}
    ui.minimal_toolbar = true
    local dots = { {{0, 0}}, {{-1, -1}, {1, 1}}, {{-1, -1}, {0, 0}, {1, 1}}, {{-1, -1}, {1, -1}, {-1, 1}, {1, 1}}, {{-1, -1}, {1, -1}, {0, 0}, {-1, 1}, {1, 1}}, {{-1, -1}, {-1, 0}, {-1, 1}, {1, -1}, {1, 0}, {1, 1}} }
    local function roll(touch)
        s.phase, s.phase_time, s.quiet, s.peaks = "shaking", ui.now, 0, 0
        s.touch_roll, s.results = touch, nil
        ui:music("dice_roll", true)
        for i = 1, s.count do s.dice[i] = { face = math.random(6), angle = math.random() * 6.28 } end
    end
    local function settle()
        s.phase, s.phase_time, s.results = "settling", ui.now, {}
        -- Results are sampled once, independently of the animation and orientation.
        for i = 1, s.count do s.results[i] = math.random(6) end
        ui:music(nil)
    end
    function s:update(dt)
        local energy = ui.motion.available and ui.motion.energy or 0
        self.energy = energy
        if energy > 0.28 then
            self.quiet = 0
            if ui.now - self.last_hit > 0.14 then self.peaks, self.last_hit = self.peaks + 1, ui.now end
        else self.quiet = self.quiet + dt end
        if self.phase == "ready" or self.phase == "result" then
            if self.quiet > 0.35 then self.peaks = 0 end
            if self.peaks >= 2 then roll(false) end
        elseif self.phase == "shaking" then
            if ui.now - self.phase_time > 0.6 and ((self.touch_roll and ui.now - self.phase_time > 1) or (not self.touch_roll and self.quiet > 0.45)) then settle() end
        elseif self.phase == "settling" then
            if energy > 0.4 and self.peaks >= 2 then roll(false); return end
            local elapsed = ui.now - self.phase_time
            for i = 1, self.count do
                if elapsed >= 0.6 + (i - 1) * 0.12 and not self.dice[i].landed then
                    self.dice[i].landed = true; ui:sound("land_" .. math.random(3), 3)
                end
            end
            if elapsed >= 0.6 + (self.count - 1) * 0.12 then
                self.phase, self.total, self.peaks, self.quiet = "result", 0, 0, 0
                for _, n in ipairs(self.results) do self.total = self.total + n end
                table.insert(self.history, 1, self.total)
                if #self.history > 5 then table.remove(self.history) end
            end
        end
    end
    local function draw_die(cx, cy, side, angle, value, lift)
        local c, sn = math.cos(angle), math.sin(angle)
        local function p(x, y) return cx + x * c - y * sn, cy + x * sn + y * c - lift end
        local h, r = side / 2, side * 0.17
        local outline = {{-h+r,-h},{h-r,-h},{h,-h+r},{h,h-r},{h-r,h},{-h+r,h},{-h,h-r},{-h,-h+r}}
        local function face(offset, col)
            for i, a in ipairs(outline) do
                local b = outline[i % #outline + 1]
                local ax, ay = p(a[1], a[2]); local bx, by = p(b[1], b[2])
                ui:tri(cx, cy - lift + offset, ax, ay + offset, bx, by + offset, col)
            end
            for _, x in ipairs({-h+r, h-r}) do for _, y in ipairs({-h+r, h-r}) do local px, py = p(x, y); ui:circle(px, py + offset, r, col) end end
        end
        -- Two flat layers keep the rolling animation light on the device.
        face(6, 0xffc8bce9); face(0, 0xffeee8fa)
        for _, dot in ipairs(dots[value]) do
            local px, py = p(dot[1] * side * 0.25, dot[2] * side * 0.25)
            ui:circle(px, py, side * 0.085, ink)
        end
    end
    function s:draw()
        ui:header("Shake Dice")
        ui:text(240, 74, ui.motion.available and "Shake. Settle. Reveal." or "Tap to roll anytime.", 18, muted)
        local age = ui.now - self.phase_time
        for i = 1, self.count do
            local dx = (i - (self.count + 1) / 2) * (self.count == 3 and 118 or 150)
            local dy = self.count == 3 and (i == 2 and -8 or 8) or 0
            local rest_angle = (i - (self.count + 1) / 2) * 0.28
            local amp = self.phase == "shaking" and math.min(19, 10 + self.energy * 12) or self.phase == "settling" and math.max(0, 18 * (1 - age / (0.6 + (i - 1) * 0.12))) or 0
            local angle = rest_angle + math.sin(ui.now * 15 + i * 2) * amp * 0.02
            local face = self.results and self.results[i] or ({5, 3, 6})[i]
            if amp > 2 then face = (math.floor(ui.now * 15) + i * 3) % 6 + 1 end
            local side = self.count == 1 and 136 or self.count == 2 and 122 or 92
            draw_die(240 + dx + math.sin(ui.now * 20 + i) * amp * 0.6, 203 + dy + math.cos(ui.now * 17 + i) * amp * 0.4, side, angle, face, math.abs(math.sin(ui.now * 18 + i)) * amp * 0.5)
        end
        if self.phase == "result" then
            ui:text(240, 278, "Total", 18, muted)
            ui:text(240, 297, self.total, 60, ink)
            ui:text(240, 360, ui.motion.available and "Shake or tap to roll" or "Tap to roll again", 18, muted)
        else
            ui:text(240, 302, self.phase == "shaking" and (self.touch_roll and "Rolling..." or "Keep shaking") or self.phase == "settling" and "Settling..." or "Shake or tap to roll", 24, ink)
            ui:text(240, 338, self.phase == "settling" and "A little suspense" or "Hold still to reveal", 18, muted)
        end
        ui:text(60, 385, "Recent", 18, muted)
        for i = 1, 5 do
            local x = 145 + (i - 1) * 66
            if self.history[i] then ui:text(x, 383, self.history[i], 24, i == 1 and accent or muted)
            else ui:line(x - 6, 396, x + 6, 396, muted) end
        end
        local idle = self.phase == "ready" or self.phase == "result"
        ui:rect(18, 424, 444, 46, 0xffeae4f4, 12)
        for i = 1, 3 do
            local x, selected = 92 + (i - 1) * 148, self.count == i
            if selected then ui:rect(x - 74, 424, 148, 46, accent, 12) end
            ui:text(x, 433, i == 1 and "1 die" or i .. " dice", 24, selected and paper or idle and ink or muted)
            if idle and ui:hit(x, 447, 144, 46) then self.count, self.phase, self.results = i, "ready", nil end
        end
        if idle and ui:hit(240, 230, 424, 280) then roll(true) end
    end
    return s
end
