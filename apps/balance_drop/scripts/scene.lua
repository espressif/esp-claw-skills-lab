local clamp = function(v, a, b) return math.max(a, math.min(b, v)) end
local targets = {{100,-60}, {-100,50}, {95,65}, {-85,-65}, {0,80}, {0,-85}, {130,0}, {-130,0}}
local stages = {{name="Find", radius=30, hold=0.65, speed=32}, {name="Focus", radius=23, hold=0.8, speed=28}, {name="Flow", radius=26, hold=0.7, speed=38}}
return function(ui)
    local s = {x=0, y=0, vx=0, vy=0, mode="挑战", phase="ready", stable=0, longest=0, inside=0, spills=0, edge=0, elapsed=0, ripples={}, stage=1, score=0, hits=0, combo=0, max_combo=0, misses=0, lives=3, target_x=100, target_y=-60, target_index=0, charge=0}
    local paper, ink, muted, accent, gold = 0xfff0f4e8, 0xff244b46, 0xff769189, 0xff368f83, 0xffbc8238
    s.background = paper
    ui.theme = {accent=ink, button=0xffdce5df, text=ink, muted=muted, ink=paper, shadow=paper}
    ui.minimal_toolbar = true
    local function feedback(label) s.feedback, s.feedback_until = label, s.elapsed + 1.0 end
    local function target_position()
        s.target_x, s.target_y = s.base_x, s.base_y
        if s.stage == 3 then s.target_x, s.target_y = s.base_x + math.sin(s.elapsed * 1.2) * 14, s.base_y + math.cos(s.elapsed * 0.9) * 10 end
    end
    local function next_target()
        -- Pick a different reachable destination; stage three adds a gentle drift.
        s.target_index = (s.target_index + math.random(#targets - 1) - 1) % #targets + 1
        s.base_x, s.base_y = table.unpack(targets[s.target_index])
        s.target_until, s.charge, s.centered = s.elapsed + 7 - s.stage * 0.5, 0, false
        target_position()
    end
    local function start()
        s.x, s.y, s.vx, s.vy, s.stable, s.longest, s.inside, s.spills, s.edge, s.elapsed = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        s.stage, s.score, s.hits, s.combo, s.max_combo, s.misses, s.lives, s.charge = 1, 0, 0, 0, 0, 0, 3, 0
        s.base_x, s.base_y, s.target_x, s.target_y, s.target_until, s.target_index = 0, 0, 0, 0, 6.5, 0
        s.phase, s.ripples, s.centered, s.splash, s.burst, s.feedback, s.new_best = "calibrating", {}, false, nil, nil, nil, false
        ui:calibrate(); ui:music("balance_ambient")
    end
    local function finish()
        s.phase = "result"
        -- Keep the old percentage record separate from the new points-based challenge.
        local best = tonumber(ui.record.route_best) or 0
        s.new_best, ui.record.route_best = s.score > best, math.max(best, s.score)
        ui:save(); ui:music(nil); ui:sound("result", 5)
    end
    function s:update(dt)
        if self.phase == "calibrating" and not ui.calibration and ui.motion.available then self.phase = "playing" end
        if self.phase ~= "playing" or not ui.motion.available or ui.calibration then return end
        local challenge, elapsed = self.mode == "挑战", math.max(0, ui.wall_dt or dt)
        if challenge then elapsed = math.min(elapsed, 45 - self.elapsed) end
        self.elapsed = self.elapsed + elapsed
        if challenge and self.elapsed >= 45 then finish(); return end
        if challenge then
            local stage = math.min(3, 1 + math.floor(self.elapsed / 15))
            if stage ~= self.stage then
                self.stage, self.charge = stage, 0
                self.target_until = math.max(self.target_until, self.elapsed + 3)
                feedback("Stage " .. stage .. " / " .. stages[stage].name); ui:sound("stage", 4)
            end
            target_position()
        end
        self.vx = (self.vx + ui.motion.x * 680 * dt) * math.exp(-5 * dt)
        self.vy = (self.vy + ui.motion.y * 680 * dt) * math.exp(-5 * dt)
        self.vx, self.vy = clamp(self.vx, -160, 160), clamp(self.vy, -160, 160)
        self.x, self.y = self.x + self.vx * dt, self.y + self.vy * dt
        local speed = math.sqrt(self.vx^2 + self.vy^2)
        self.edge = (math.abs(self.x) > 186 or math.abs(self.y) > 128) and self.edge + dt or 0
        self.x, self.y = clamp(self.x, -192, 192), clamp(self.y, -134, 134)
        if self.edge >= 0.4 then
            self.spills, self.x, self.y, self.vx, self.vy, self.edge, self.stable = self.spills + 1, 0, 0, 0, 0, 0, 0
            self.splash, self.centered = self.elapsed, false
            ui:sound("spill", 4)
            if challenge then
                self.lives, self.combo = self.lives - 1, 0
                if self.lives == 0 then finish(); return end
                feedback("Spill! " .. self.lives .. (self.lives == 1 and " life left" or " lives left")); next_target()
            end
            return
        end
        if challenge then
            if self.elapsed >= self.target_until then
                self.misses, self.combo = self.misses + 1, 0
                feedback("Missed. Find the next ring."); ui:sound("unstable", 3); next_target()
                return
            end
            local rule = stages[self.stage]
            self.centered = (self.x - self.target_x)^2 + (self.y - self.target_y)^2 < rule.radius^2 and speed < rule.speed
            -- A stalled frame must not complete a hold using unobserved motion.
            self.charge = self.centered and elapsed <= 0.25 and self.charge + elapsed or 0
            if self.charge >= rule.hold then
                self.hits, self.combo = self.hits + 1, self.combo + 1
                self.max_combo = math.max(self.max_combo, self.combo)
                local multiplier = math.min(3, 1 + self.combo // 3)
                local points = 10 * multiplier
                self.score = self.score + points
                self.burst = {x=self.target_x, y=self.target_y, at=self.elapsed}
                feedback("+" .. points .. " / " .. self.combo .. " in a row")
                ui:sound("collect_" .. multiplier, 3); next_target()
            end
        else
            local was_centered = self.centered
            self.centered = self.x^2 + self.y^2 < 24^2 and speed < 12
            if self.centered ~= was_centered and ui.now - (self.last_cue or -1) > 0.3 then
                self.last_cue = ui.now; ui:sound(self.centered and "in_ring" or "unstable", 1)
            end
            if self.centered then
                local before = self.stable
                self.stable, self.inside = self.stable + elapsed, self.inside + elapsed
                self.longest = math.max(self.longest, self.stable)
                if math.floor(self.stable) > math.floor(before) then self.ripples[#self.ripples + 1] = self.elapsed end
            else self.stable = 0 end
            for i = #self.ripples, 1, -1 do if self.elapsed - self.ripples[i] > 1.2 then table.remove(self.ripples, i) end end
        end
    end
    local function button(x, width, label, primary, disabled)
        ui:rect(x - width / 2, 424, width, 46, primary and ink or 0xffdce5df, 10)
        ui:text(x, 433, label, 24, disabled and muted or primary and paper or ink)
        return not disabled and ui:hit(x, 447, width, 46)
    end
    local function drop()
        -- Map the physics area into the space between metrics and controls.
        local px, py = 240 + s.x * 0.7, 240 + s.y * 0.7
        local speed = math.sqrt(s.vx^2 + s.vy^2)
        ui:circle(px + 2, py + 4, 22, 0xffc4d7ca)
        if speed > 5 then ui:circle(px - s.vx * 0.04, py - s.vy * 0.04, 15, 0xff8cc6b9) end
        ui:circle(px, py, 22, accent); ui:circle(px - 3, py - 4, 17, 0xff48a99d)
        ui:arc(px - 2, py - 2, 15, 190, 280, 0xff76c6b9, 5); ui:circle(px - 8, py - 9, 4, 0xffeffaf0)
        if s.splash and s.elapsed - s.splash < 0.7 then
            for i = 1, 8 do
                local a, age = i * math.pi / 4, s.elapsed - s.splash
                ui:circle(240 + math.cos(a) * (28 + 80 * age), 240 + math.sin(a) * (28 + 80 * age), 3 - age * 2, accent)
            end
        end
    end
    function s:draw()
        ui:header("Balance Challenge")
        local challenge, result, ready = self.mode == "挑战", self.phase == "result", self.phase == "ready"
        if challenge then
            ui:text(76, 62, result and "Targets" or ready and "Round" or "Score", 18, muted)
            ui:text(76, 84, result and self.hits or ready and "45s" or self.score, 36, ink)
            ui:text(404, 62, (ready or result) and "Best" or "Time left", 18, muted)
            ui:text(404, 84, (ready or result) and (ui.record.route_best or 0) or math.ceil(45 - self.elapsed) .. "s", 36, ink)
            ui:text(240, 66, ready and "3 stages" or result and "Finished" or self.stage .. "/3 " .. stages[self.stage].name, 18, muted)
            ui:text(240, 96, self.lives .. (self.lives == 1 and " life" or " lives"), 18, self.lives == 1 and 0xffbc6653 or accent)
        else
            ui:text(88, 62, "Centered", 18, muted); ui:text(88, 84, string.format("%.1fs", self.stable), 36, ink)
            ui:text(392, 62, "Best hold", 18, muted); ui:text(392, 84, string.format("%.1fs", self.longest), 36, ink)
        end
        if result then
            local title = self.new_best and "New personal best" or self.lives == 0 and "Out of lives" or "Route complete"
            ui:arc(240, 236, 108, -90, 270, 0xffd7e1d9, 2)
            ui:text(240, 158, title, 18, muted)
            ui:text(240, 198, self.score, 60, ink); ui:text(240, 264, "points", 18, muted)
            ui:text(240, 304, "Best streak " .. self.max_combo, 18, accent)
            ui:text(240, 362, self.misses .. " missed / " .. self.spills .. " spills", 18, muted)
        else
            if challenge then
                -- Boundary marks show the spill limits without adding a heavy tray.
                local warning = self.edge > 0 and 0xffbc6653 or 0xffc3d4c8
                for _, dx in ipairs({-1, 1}) do for _, dy in ipairs({-1, 1}) do
                    local x, y = 240 + dx * 153, 240 + dy * 114
                    ui:line(x, y, x - dx * 16, y, warning); ui:line(x, y, x, y - dy * 16, warning)
                end end
                local tx, ty, rule = 240 + self.target_x * 0.7, 240 + self.target_y * 0.7, stages[self.stage]
                local radius = rule.radius * 0.7 + 22
                for i = 1, 6 do
                    local k = i / 7
                    local x, y = self.x + (self.target_x - self.x) * k, self.y + (self.target_y - self.y) * k
                    if (x-self.x)^2 + (y-self.y)^2 > 36^2 and (x-self.target_x)^2 + (y-self.target_y)^2 > 66^2 then ui:circle(240+x*0.7, 240+y*0.7, 1, 0xffcfbd94) end
                end
                ui:circle(tx, ty, radius, 0xfff1e7cc); ui:arc(tx, ty, radius, -90, 270, gold, 2)
                local progress = self.phase == "calibrating" and (ui.calibration and ui.calibration.elapsed or 0) / 0.8 or self.charge / rule.hold
                ui:arc(tx, ty, radius + 5, -90, -90 + math.min(1, progress) * 360, accent, 4)
                ui:circle(tx, ty, 3, gold)
                if self.burst and self.elapsed - self.burst.at < 0.7 then
                    local age, bx, by = self.elapsed - self.burst.at, 240 + self.burst.x * 0.7, 240 + self.burst.y * 0.7
                    for i = 1, 8 do
                        local a = i * math.pi / 4
                        local x, y = bx + math.cos(a) * (32 + age * 38), by + math.sin(a) * (32 + age * 38)
                        if y >= 130 and y <= 350 then ui:circle(x, y, 3 - age * 2, gold) end
                    end
                end
                drop()
                ui:text(240, 361, ready and "Chase / Hold / Chain" or self.combo .. " in a row / x" .. math.min(3, 1 + self.combo // 3), 18, accent)
                if not ready then
                    ui:rect(24, 410, 432, 3, 0xffd7e1d9, 1)
                    ui:rect(24, 410, 432 * (1 - self.elapsed / 45), 3, self.elapsed >= 40 and gold or accent, 1)
                end
            else
                ui:arc(240, 240, 116, -90, 270, muted, 2); ui:arc(240, 240, 82, -90, 270, 0xffd7e1d9, 2)
                for _, sign in ipairs({-1, 1}) do
                    ui:line(240 + sign * 123, 240, 240 + sign * 131, 240, muted)
                    ui:line(240, 240 + sign * 123, 240, 240 + sign * 131, muted)
                end
                local progress = self.phase == "calibrating" and clamp((ui.calibration and ui.calibration.elapsed or 0) / 0.8, 0, 1) or math.min(1, self.stable / 5)
                if not ready then ui:arc(240, 240, 116, -90, -90 + progress * 360, self.phase == "paused" and muted or accent, 3) end
                ui:circle(240, 240, 40, self.centered and 0xffc8e3d9 or 0xffdeebe3)
                for _, t in ipairs(self.ripples) do if self.elapsed - t < 1.2 then ui:ring(240, 240, 40 + (self.elapsed - t) * 58, 0xffbfdbcd) end end
                drop()
            end
        end
        local status = "Gently return to the center."
        if ready then status = challenge and "Guide the drop into the gold ring." or "Tilt gently. Find your center."
        elseif result then status = self.hits >= 12 and "Masterful. Keep the flow." or self.hits >= 6 and "Nice run. Beat it next time." or "Tilt gently, then hold steady."
        elseif self.phase == "calibrating" then status = "Hold still. Finding level..."
        elseif self.phase == "paused" then status = "Paused. Take a breath."
        elseif challenge then
            if self.feedback and self.elapsed < self.feedback_until then status = self.feedback
            elseif self.centered then status = "Hold... " .. string.format("%.1fs", math.max(0, stages[self.stage].hold - self.charge))
            else status = "Catch the ring / " .. math.ceil(self.target_until - self.elapsed) .. "s" end
        elseif self.centered then status = "Right there. Hold steady." end
        if not ui.motion.available then status = "Motion sensor unavailable" end
        ui:text(240, 386, status, 18, self.centered and accent or muted)
        if ready then
            if button(128, 208, challenge and "Challenge" or "Practice") then self.mode = challenge and "练习" or "挑战" end
            if button(352, 208, "Start", true, not ui.motion.available) then start() end
        elseif result then
            if button(128, 208, "Modes") then self.phase, self.burst = "ready", nil; self.x, self.y, self.stage, self.lives, self.target_x, self.target_y, self.charge = 0, 0, 1, 3, 100, -60, 0 end
            if button(352, 208, "Play again", true, not ui.motion.available) then start() end
        else
            if button(128, 208, self.phase == "paused" and "Resume" or "Pause", true, self.phase == "calibrating" or not ui.motion.available) then
                if self.phase == "playing" then self.phase = "paused"; ui:music(nil)
                elseif self.phase == "paused" then self.phase = "playing"; ui:music("balance_ambient") end
            end
            if button(352, 208, "Calibrate", false, not ui.motion.available) then ui:calibrate(); self.phase, self.vx, self.vy, self.charge = "calibrating", 0, 0, 0 end
        end
    end
    return s
end
