local M = {}
local cues = { "slice-1", "slice-2", "slice-3", "tick", "combo", "bomb", "fever", "result" }
local bytes_per_ms, ahead_ms = 32, 60
function M.new(directory, volume, warn)
    local system = require("system")
    local s = { last = -1000, priority = 0, queued_until = 0, clips = {} }
    local ok, err = pcall(function()
        local audio = require("audio")
        s.output = assert(audio.open_output())
        assert(s.output:set_volume(volume))
        local format = s.output:info()
        assert(format.sample_rate == 16000 and format.channels == 1 and format.bits == 16, "sound effects require 16 kHz mono PCM output")
        for _, name in ipairs(cues) do
            local file <close> = assert(io.open(directory .. "/assets/audio/" .. name .. ".pcm", "rb"))
            local pcm = assert(file:read("a"))
            assert(#pcm > 0 and #pcm % 2 == 0 and #pcm <= 32000, "invalid sound effect: " .. name)
            s.clips[name] = pcm
        end
        s.player = assert(audio.player({ output = s.output }))
    end)
    function s:close()
        if self.player then
            -- Drain audio callbacks before the firmware marks the player closed.
            local stopped, failure = pcall(function() assert(self.player:stop()) end)
            if not stopped then warn("audio stop failed: " .. tostring(failure)) end
        end
        for _, key in ipairs({"player", "output"}) do
            if self[key] then
                local success, result, message = pcall(self[key].close, self[key])
                if not success or result == nil and message then warn("audio close failed: " .. tostring(success and message or result)) end
                self[key] = nil
            end
        end
    end
    if not ok then warn("audio unavailable: " .. tostring(err)); s:close() end
    function s:update(g)
        local event = g.sound
        g.sound = nil
        if not self.output then return end
        local success, message = pcall(function()
            local now = system.millis()
            local music = g.state == "home" and g.sound_mode == "music"
            -- The output remains busy until menu playback is stopped.
            if self.menu and (not music or g.state == "paused") then assert(self.player:stop()); self.menu = nil end
            if g.sound_mode == "mute" or g.state == "paused" then
                self.playing, self.pcm, self.priority = nil, nil, 0
                return
            end
            if music then
                local status = assert(self.player:poll())
                if status.state == "error" then error("menu player error") end
                if not status.running then assert(self.player:play(directory .. "/assets/audio/menu.aac")) end
                self.menu = true
                self.playing, self.pcm, self.priority = nil, nil, 0
                return
            end
            if self.playing and now >= self.finished_at then self.playing, self.pcm, self.priority = nil, nil, 0 end
            if event and (event.priority > self.priority or not self.playing or event.priority == 1 and self.priority == 1 and now - self.last >= 110) then
                self.pcm = assert(self.clips[event.name], "unknown sound effect: " .. event.name)
                self.playing, self.priority, self.last, self.offset = event.name, event.priority, now, 1
                self.finished_at = math.max(now, self.queued_until) + #self.pcm / bytes_per_ms
            end
            if self.pcm and self.offset <= #self.pcm then
                -- Feed a small PCM window; the firmware mixer plays it while the UI draws.
                local available = math.floor((now + ahead_ms - math.max(now, self.queued_until)) * bytes_per_ms / 2) * 2
                local count = math.min(#self.pcm - self.offset + 1, available)
                if count > 0 then
                    local chunk = self.pcm:sub(self.offset, self.offset + count - 1)
                    assert(self.output:write(chunk) == #chunk, "incomplete PCM write")
                    self.offset = self.offset + count
                    self.queued_until = math.max(now, self.queued_until) + count / bytes_per_ms
                end
            end
        end)
        if not success then warn("audio stopped: " .. tostring(message)); self:close() end
    end
    return s
end
return M
