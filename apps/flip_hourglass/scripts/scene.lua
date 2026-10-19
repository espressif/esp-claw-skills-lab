local durations = {60, 180, 300, 600}
return function(ui)
    local s = { phase = "ready", selection = 2, remaining = 180, duration = 180, orientation = 1, candidate = 0, samples = 0, turns = 0, flow_time = 0 }
    -- Use the nearest RGB565 cream to avoid a pink cast after quantization.
    local ink, paper, glass, edge, sand, muted = 0xff293b3b, 0xfff0f4e8, 0xffeaede5, 0xffbcc8c1, 0xffd4a667, 0xff687975
    s.background = paper
    ui.theme = {accent=ink, button=0xffe9eae3, text=ink, muted=muted, ink=paper, shadow=paper}
    ui.minimal_toolbar, ui.rotation = true, 0
    local widths, areas = {}, {[0]=0}
    for y = 0, 84 do
        widths[y] = 4 + 50 * math.sin(y / 84 * math.pi / 2) ^ 1.35
        if y > 0 then areas[y] = areas[y - 1] + math.max(0, widths[y] - 4) * 2 end
    end
    local capacity = areas[62]
    local bands = {}
    for y = -84, 78, 6 do bands[#bands + 1] = {y, y + 6, widths[math.abs(y)], widths[math.abs(y + 6)]} end
    local function start()
        s.duration = durations[s.selection]
        s.remaining, s.deadline, s.phase, s.finished, s.flow_time = s.duration, ui.now + s.duration, "running", false, 0
        ui:music("sand_ambient"); ui:sound("flip", 2)
    end
    function s:update(dt)
        local m = ui.motion
        local direction = 0
        if m.available and m.norm >= 0.75 and m.norm <= 1.25 then
            -- Raw gravity avoids filter lag; hysteresis tolerates a slightly tilted grip.
            local vertical = (m.ay or m.gy) / m.norm
            if vertical >= 0.5 then direction = 1 elseif vertical <= -0.5 then direction = -1
            elseif self.candidate * vertical >= 0.35 then direction = self.candidate end
        end
        if direction == 0 then
            self.candidate, self.since, self.samples = 0, nil, 0
        else
            -- Confirm with actual timestamps and fresh samples, independent of animation dt.
            if direction ~= self.candidate or not self.sample_at or ui.now - self.sample_at > 0.5 then
                self.candidate, self.since, self.samples = direction, ui.now, 1
            else self.samples = self.samples + 1 end
            if self.samples >= 2 and ui.now - self.since >= 0.14 then
                if not self.armed then self.orientation, self.armed = direction, true
                elseif direction ~= self.orientation then self.orientation, self.turns = direction, self.turns + 1; start() end
            end
        end
        self.sample_at = m.available and ui.now or nil
        ui.rotation = self.orientation == -1 and 180 or 0
        if self.phase == "running" then
            self.flow_time = self.flow_time + dt
            self.remaining = math.max(0, self.deadline - ui.now)
            if self.remaining == 0 then self.phase, self.finished = "finished", true; ui:music(nil); ui:sound("bell", 5) end
        end
    end
    local function action(x, width, label, primary)
        ui:rect(x - width / 2, 424, width, 46, primary and ink or 0xffe9eae3, 10)
        ui:text(x, 433, label, 24, primary and paper or ink)
        return ui:hit(x, 447, width, 46)
    end
    local function fill_band(y1, y2, a, b, tint)
        ui:tri(240 - a, 174 + y1, 240 + a, 174 + y1, 240 - b, 174 + y2, tint)
        ui:tri(240 + a, 174 + y1, 240 - b, 174 + y2, 240 + b, 174 + y2, tint)
    end
    local function fill_sand(first, last)
        for y = first, last - 1, 6 do
            local next_y = math.min(last, y + 6)
            fill_band(y, next_y, widths[math.abs(y)] - 4, widths[math.abs(next_y)] - 4, sand)
        end
    end
    function s:draw()
        ui:header("Flip Hourglass")
        local fraction = self.remaining / self.duration
        local top, bottom = 0, 82
        -- Match sand area in both curved chambers, rather than animating a linear height.
        for y = 1, 62 do if areas[y] <= capacity * fraction then top = y end end
        for y = 81, 0, -1 do if areas[82] - areas[y] <= capacity * (1 - fraction) then bottom = y end end
        -- Coarse curve bands reduce Lua draw calls without an extra framebuffer.
        for _, band in ipairs(bands) do fill_band(band[1], band[2], band[3], band[4], glass) end
        if top > 0 then fill_sand(-top, 0) end
        if fraction < 1 and bottom < 82 then fill_sand(bottom + 1, 83) end
        for _, band in ipairs(bands) do
            local y1, y2, a, b = band[1], band[2], band[3], band[4]
            for _, sign in ipairs({-1, 1}) do
                ui:line(240 + sign * a, 174 + y1, 240 + sign * b, 174 + y2, edge)
                ui:line(240 + sign * (a + 1), 174 + y1, 240 + sign * (b + 1), 174 + y2, edge)
            end
        end
        if top > 0 then ui:line(244 - widths[top], 174 - top, 236 + widths[top], 174 - top, 0xffdfbd86) end
        if bottom < 82 then ui:line(244 - widths[bottom], 174 + bottom, 236 + widths[bottom], 174 + bottom, 0xffdfbd86) end
        if self.phase ~= "ready" and self.remaining > 0 then
            for i = 1, 9 do
                local t = (i / 9 + self.flow_time * 0.9) % 1
                ui:circle(240 + math.sin(i * 4) * 0.7, 174 + t * math.max(2, bottom - 2), i % 3 == 0 and 1.2 or 0.7, sand)
            end
        end
        ui:rect(182, 78, 116, 12, ink, 3)
        ui:rect(182, 258, 116, 12, ink, 3)
        local seconds = math.ceil(self.remaining)
        ui:text(240, 282, string.format("%02d:%02d", seconds // 60, seconds % 60), 60, ink)
        local status = ({ready="Ready when you are", running="Flip to restart", paused="Paused. Take your time.", finished="Time's up. Take a breath."})[self.phase]
        if not ui.motion.available and self.phase ~= "finished" then status = "Touch controls available" end
        ui:text(240, 344, status, 18, muted)
        local selectable = self.phase == "ready" or self.phase == "finished"
        for i, duration in ipairs(durations) do
            local x = 78 + (i - 1) * 108
            if i == self.selection then ui:rect(x - 43, 378, 86, 36, 0xfff0dfbf, 10) end
            ui:text(x, 383, duration // 60 .. "m", 24, (selectable or i == self.selection) and ink or muted)
            if selectable and ui:hit(x, 396, 94, 40) then
                self.selection, self.duration, self.remaining, self.phase, self.finished = i, duration, duration, "ready", false
            end
        end
        if self.phase == "ready" or self.phase == "finished" then
            ui:rect(18, 424, 444, 46, ink, 10)
            ui:tri(165, 438, 165, 454, 177, 446, paper)
            ui:text(258, 433, self.phase == "finished" and "Start again" or "Start timer", 24, paper)
            if ui:hit(240, 447, 444, 46) then start() end
        else
            if action(128, 208, self.phase == "paused" and "Resume" or "Pause", true) then
                if self.phase == "running" then self.phase = "paused"; ui:music(nil)
                else self.phase, self.deadline = "running", ui.now + self.remaining; ui:music("sand_ambient") end
            end
            if action(352, 208, "Reset", false) then self.phase, self.remaining = "ready", self.duration; ui:music(nil) end
        end
    end
    return s
end
