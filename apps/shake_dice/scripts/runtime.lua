-- Device I/O and drawing helpers maintained within Shake Dice.
local display, system, delay = require("display"), require("system"), require("delay")
local M = {}
local function round(n) return math.floor(n + 0.5) end
function M.clamp(n, a, b) return math.max(a, math.min(b, n)) end
function M.distance(x, y) return math.sqrt(x * x + y * y) end

function M.run(id, directory, create)
    local a = type(args) == "table" and args or {}
    local function number(key, default, lo, hi)
        local n = a[key]
        if type(n) ~= "number" or n ~= n then return default end
        return M.clamp(n, lo, hi)
    end
    local ui = { now = system.millis() / 1000, fonts = {}, inverted_fonts = {}, motion = {}, record = {}, sound_mode = number("volume", 80, 0, 100) == 0 and "mute" or "music" }
    local screen, sensor, player, output, storage, json
    local function warn(message) print("[" .. id .. "] WARN: " .. tostring(message)) end
    local function close(object)
        if object then
            local ok, result, err = pcall(object.close, object)
            if not ok or result == nil and err then warn(ok and err or result) end
        end
    end
    local guard <close> = setmetatable({}, { __close = function()
        close(player); close(output); close(sensor)
        for _, font in pairs(ui.fonts) do close(font) end
        for _, font in pairs(ui.inverted_fonts) do close(font) end
        close(screen)
    end })
    local ok, err = xpcall(function()
        screen = display.open()
        local info = screen:info()
        assert(math.min(info.width, info.height) >= 240, "display must be at least 240x240")
        local scale = math.min(info.width, info.height) / 480
        local ox, oy = (info.width - 480 * scale) / 2, (info.height - 480 * scale) / 2
        local function x(n) local p = round(ox + n * scale); return ui.rotation == 180 and info.width - 1 - p or p end
        local function y(n) local p = round(oy + n * scale); return ui.rotation == 180 and info.height - 1 - p or p end
        local function size(n) return round(n * scale) end
        local function font_for(n, inverted)
            local cache = inverted and ui.inverted_fonts or ui.fonts
            if cache[n] then return cache[n] end
            local chosen = 9
            local sizes = n == 60 and {9, 12, 18, 24, 30, 36, 48, 60} or {9, 12, 18, 24, 36, 48}
            for _, available in ipairs(sizes) do if available <= n * scale then chosen = available end end
            cache[n] = display.load_font(directory .. "/assets/ui-" .. chosen .. (inverted and "-180" or "") .. ".dfn")
            return cache[n]
        end
        for _, n in ipairs({18, 24, 36, 48}) do font_for(n, false) end
        function ui:circle(cx, cy, r, c) screen:fill_circle(x(cx), y(cy), size(r), c) end
        function ui:ring(cx, cy, r, c) screen:stroke_circle(x(cx), y(cy), size(r), c) end
        function ui:line(x1, y1, x2, y2, c) screen:line(x(x1), y(y1), x(x2), y(y2), c) end
        function ui:rect(px, py, w, h, c, r)
            local left, top, width, height = x(px), y(py), size(w), size(h)
            if self.rotation == 180 then left, top = left - width + 1, top - height + 1 end
            screen:fill_round_rect(left, top, width, height, size(r or 0), c)
        end
        function ui:tri(x1, y1, x2, y2, x3, y3, c) screen:fill_triangle(x(x1), y(y1), x(x2), y(y2), x(x3), y(y3), c) end
        function ui:arc(cx, cy, r, first, last, c, width)
            if last <= first then return end
            if self.rotation == 180 then first, last = first + 180, last + 180 end
            for i = 0, (width or 1) - 1 do screen:arc(x(cx), y(cy), size(r - i), first, last, c) end
        end
        function ui:text(px, py, text, font_size, color)
            text = tostring(text)
            local font = font_for(font_size or 18, self.rotation == 180)
            local opts = { font = font, color = color or (self.theme and self.theme.text) or 0xffe6edf2 }
            local w, h = screen:measure_text(text, opts)
            local left, top = round(ox + px * scale) - w // 2, round(oy + py * scale)
            if self.rotation == 180 then
                -- Inverted glyphs and reversed UTF-8 order rotate the whole line.
                local chars = {}
                for ch in text:gmatch(utf8.charpattern) do chars[#chars + 1] = ch end
                for i = 1, #chars // 2 do chars[i], chars[#chars - i + 1] = chars[#chars - i + 1], chars[i] end
                text = table.concat(chars)
                left, top = info.width - left - w, info.height - top - h
            end
            screen:text(left, top, text, opts)
        end
        function ui:hit(cx, cy, w, h)
            return self.tap and math.abs(self.tap.x - cx) <= w / 2 and math.abs(self.tap.y - cy) <= h / 2
        end
        function ui:button(cx, cy, w, label, active)
            local t = self.theme or {}
            self:rect(cx - w / 2, cy - 20, w, 44, t.shadow or 0xff09151d, 12)
            self:rect(cx - w / 2, cy - 22, w, 42, active and (t.accent or 0xffc6e5dc) or (t.button or 0xff243b46), 12)
            self:text(cx, cy - 13, label, 18, active and (t.ink or 0xff152a31) or t.text)
            return self:hit(cx, cy, w, 44)
        end
        function ui:header(title, subtitle)
            self.heading = { title, subtitle }
        end
        function ui:calibrate()
            self.calibration = { elapsed = 0, x = 0, y = 0, count = 0 }
        end
        function ui:music(name, effect) self.track, self.loop_effect = name, effect end
        function ui:sound(name, priority)
            if not self.pending or (priority or 1) > self.pending.priority then self.pending = { name = name, priority = priority or 1 } end
        end
        function ui:save()
            if not storage or not json then return end
            local saved, message = pcall(function()
                local root = storage.join_path(storage.get_root_dir(), "app_data")
                if not storage.exists(root) then assert(storage.mkdir(root)) end
                local path = storage.join_path(root, id .. ".json")
                assert(storage.write_file(path, json.encode(self.record)))
            end)
            if not saved then warn("save failed: " .. tostring(message)) end
        end
        local loaded, data = pcall(function()
            storage, json = require("storage"), require("json")
            local path = storage.join_path(storage.get_root_dir(), "app_data", id .. ".json")
            return storage.exists(path) and json.decode(storage.read_file(path)) or {}
        end)
        if loaded and type(data) == "table" then ui.record = data end
        if not loaded and storage and json then warn("settings ignored: " .. tostring(data)) end
        local mode = a.sound_mode or ui.record.sound_mode
        if number("volume", 80, 0, 100) ~= 0 and (mode == "music" or mode == "effects" or mode == "mute") then ui.sound_mode = mode end
        local sensor_ok, sensor_result = pcall(function() return require("imu").new({ device = "imu_sensor" }) end)
        if sensor_ok then sensor = sensor_result else warn(sensor_result) end
        local volume = round(number("volume", 80, 0, 100))
        if volume == 0 then volume = 80 end
        local audio_ok, audio_err = pcall(function()
            local audio = require("audio")
            output = assert(audio.open_output())
            assert(output:set_volume(volume))
            player = assert(audio.player({ output = output }))
        end)
        if not audio_ok then warn("sound unavailable: " .. tostring(audio_err)); close(player); close(output); player, output = nil, nil end
        local function audio_tick()
            if not player then ui.pending = nil; return end
            local success, problem = pcall(function()
                if ui.sound_mode == "mute" then
                    if ui.playing then assert(player:stop()) end
                    ui.pending, ui.playing, ui.priority = nil, nil, nil
                    return
                end
                local status = assert(player:poll())
                if status.state == "error" then error("playback error: " .. tostring(ui.playing)) end
                local pending = ui.pending
                local track = (ui.sound_mode == "music" or ui.loop_effect) and ui.track or nil
                if track and pending and pending.priority < 3 then pending = nil end
                if status.running and ((pending and pending.priority > (ui.priority or 0)) or (ui.priority == 0 and ui.playing ~= track)) then
                    assert(player:stop()); status.running = false
                end
                if not status.running then
                    local name = pending and pending.name or track
                    ui.priority, ui.playing = pending and pending.priority or 0, name
                    if name then assert(player:play(directory .. "/assets/audio/" .. name .. ".aac")) end
                end
                ui.pending = nil
            end)
            if not success then warn(problem); close(player); close(output); player, output = nil, nil end
        end
        local scene = create(ui, a)
        local start, previous = ui.now, ui.now
        local period = round(number("frame_ms", 33, 16, 100))
        local run_ms = number("run_ms", 0, 0, 86400000)
        local lsb = number("lsb_per_g", 16384, 1, 65536)
        local press, last, moved, gx, gy, gz
        while not ui.exit do
            ui.now = system.millis() / 1000
            if run_ms > 0 and (ui.now - start) * 1000 >= run_ms then break end
            ui.wall_dt = math.max(0, ui.now - previous)
            local dt = math.min(ui.wall_dt, 0.08)
            previous = ui.now
            ui.tap = nil
            if info.touch_available then
                local points, point = screen:touch().points
                for _, p in ipairs(points) do if not press or p.id == press.id then point = p; break end end
                if point then
                    local p = { id = point.id, x = (point.x - ox) / scale, y = (point.y - oy) / scale }
                    if not press then press, moved = p, false end
                    if M.distance(p.x - press.x, p.y - press.y) > 14 then moved = true end
                    last = p
                elseif press then
                    if not moved and last then ui.tap = last end
                    press, last = nil, nil
                end
            end
            local m = ui.motion
            m.available = sensor ~= nil
            if sensor then
                local read_ok, sample = pcall(sensor.read, sensor)
                if not read_ok then warn(sample); close(sensor); sensor = nil; m.available = false
                else
                    local ax, ay, az = sample.accel.x / lsb, sample.accel.y / lsb, sample.accel.z / lsb
                    if a.swap_xy then ax, ay = ay, ax end
                    if a.invert_x ~= false then ax = -ax end
                    if a.invert_y then ay = -ay end
                    m.ax, m.ay, m.az = ax, ay, az
                    local k = 1 - math.exp(-dt / 0.12)
                    gx, gy, gz = gx or ax, gy or ay, gz or az
                    m.energy = M.distance(ax - gx, ay - gy)
                    m.energy = math.sqrt(m.energy * m.energy + (az - gz) ^ 2)
                    gx, gy, gz = gx + k * (ax - gx), gy + k * (ay - gy), gz + k * (az - gz)
                    m.gx, m.gy, m.gz, m.norm = gx, gy, gz, math.sqrt(ax * ax + ay * ay + az * az)
                    local c = ui.calibration
                    if c then
                        if m.energy > 0.08 or math.abs(m.norm - 1) > 0.18 then c.elapsed, c.x, c.y, c.count = 0, 0, 0, 0
                        else c.elapsed, c.x, c.y, c.count = c.elapsed + dt, c.x + ax, c.y + ay, c.count + 1 end
                        if c.elapsed >= 0.8 then ui.zero_x, ui.zero_y, ui.calibration = c.x / c.count, c.y / c.count, nil end
                    end
                    m.x, m.y = gx - (ui.zero_x or 0), gy - (ui.zero_y or 0)
                end
            end
            local rotation = ui.rotation
            scene:update(dt)
            if rotation ~= ui.rotation then
                ui.tap, moved = nil, true
            elseif ui.tap and ui.rotation == 180 then
                ui.tap.x = (info.width - 1 - 2 * ox) / scale - ui.tap.x
                ui.tap.y = (info.height - 1 - 2 * oy) / scale - ui.tap.y
            end
            screen:begin({ clear = scene.background or 0xff0b1822 })
            scene:draw()
            local theme = ui.theme or {}
            if ui.heading then
                ui:text(240, ui.minimal_toolbar and 18 or 12, ui.heading[1], 24)
                local subtitle = not ui.minimal_toolbar and (not m.available and "传感器不可用" or ui.calibration and "保持静止 · 校准中" or ui.heading[2])
                if subtitle then ui:text(240, 44, subtitle, 18, theme.muted or 0xffa8bbc0) end
            end
            if ui:hit(32, 32, 40, 40) then ui.exit = true end
            if not ui.minimal_toolbar then ui:rect(12, 12, 40, 40, theme.button or 0xcc152933, 12) end
            ui:line(36, 24, 28, 32, theme.text or 0xffd5e4e9); ui:line(28, 32, 36, 40, theme.text or 0xffd5e4e9)
            if ui.minimal_toolbar then ui:line(37, 24, 29, 32, theme.text); ui:line(29, 32, 37, 40, theme.text) end
            if ui:hit(448, 32, 40, 40) then
                ui.sound_mode = ({music="effects", effects="mute", mute="music"})[ui.sound_mode]
                ui.record.sound_mode = ui.sound_mode; ui:save()
            end
            if ui.minimal_toolbar then
                local ink = theme.text or 0xff293b3b
                local points = {{436,28},{441,28},{447,23},{447,41},{441,36},{436,36},{436,28}}
                for i = 1, #points - 1 do
                    local a, b = points[i], points[i + 1]
                    local dx, dy = 0, 1
                    if math.abs(b[2] - a[2]) > math.abs(b[1] - a[1]) then dx, dy = 1, 0 end
                    ui:line(a[1], a[2], b[1], b[2], ink); ui:line(a[1] + dx, a[2] + dy, b[1] + dx, b[2] + dy, ink)
                end
                if ui.sound_mode == "mute" then ui:line(451, 27, 460, 37, ink); ui:line(451, 37, 460, 27, ink)
                else
                    ui:arc(446, 32, 9, -52, 52, ink, 2)
                    if ui.sound_mode == "music" then ui:arc(446, 32, 15, -52, 52, ink, 2) end
                end
            else
                ui:rect(428, 12, 40, 40, theme.button or 0xcc152933, 12)
                ui:text(448, 19, ({music="乐", effects="效", mute="静"})[ui.sound_mode], 18)
            end
            screen:present()
            audio_tick()
            local remaining = period - round((system.millis() / 1000 - ui.now) * 1000)
            delay.delay_ms(math.max(1, remaining))
        end
    end, debug.traceback)
    if not ok then print("[" .. id .. "] ERROR: " .. tostring(err)); error(err, 0) end
end

return M
