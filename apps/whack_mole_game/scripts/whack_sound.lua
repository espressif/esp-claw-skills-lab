local M = {}
local cues = {
    start = { notes = { 523.25, 659.25, 783.99 }, step = 0.09 },
    hit1 = { notes = { 523.25 }, step = 0.12, bend = 340 },
    hit2 = { notes = { 659.25 }, step = 0.12, bend = 340 },
    hit3 = { notes = { 783.99 }, step = 0.12, bend = 340 },
    combo = { notes = { 783.99, 987.77, 1174.66, 1567.98 }, step = 0.065 },
    bomb = { notes = { 150 }, step = 0.32, bend = -110, noise = true },
    tick = { notes = { 1046.50 }, step = 0.055 },
    finish = { notes = { 659.25, 783.99, 1046.50, 783.99, 1046.50 }, step = 0.12 },
}

-- Cache original, enveloped PCM cues in the output's native format.
local function synth(cue, rate, channels)
    local parts, phase, noise = {}, 0, 17
    local count = math.floor(cue.step * rate)
    for _, frequency in ipairs(cue.notes) do
        for i = 0, count - 1 do
            local t = i / rate
            local progress = i / count
            phase = (phase + (frequency + (cue.bend or 0) * progress) / rate) % 1
            local envelope = math.min(1, t / 0.004) * (1 - progress) ^ 2
            local value = math.sin(2 * math.pi * phase) + 0.22 * math.sin(4 * math.pi * phase)
            if cue.noise then
                noise = (noise * 16807) % 2147483647
                value = value * 0.65 + (noise / 2147483647 * 2 - 1) * 0.55
            end
            local sample = string.pack("<i2", math.floor(value * envelope * 12000))
            parts[#parts + 1] = channels == 2 and sample .. sample or sample
        end
    end
    return table.concat(parts)
end

function M.new()
    local s = { clips = {}, queued_until = 0 }
    function s:close()
        if self.output then
            local ok, result, err = pcall(self.output.close, self.output)
            if not ok or result == nil and err then print("whack: audio close failed: " .. tostring(ok and err or result)) end
            self.output = nil
        end
        self.clips, self.pcm = {}, nil
    end
    local ok, err = pcall(function()
        s.output = assert(require("audio").open_output())
        local format = s.output:info()
        assert(format.bits == 16 and (format.channels == 1 or format.channels == 2), "audio requires 16-bit mono or stereo PCM")
        assert(format.sample_rate >= 8000 and format.sample_rate <= 48000, "unsupported audio sample rate")
        s.frame_bytes = format.channels * 2
        s.bytes_per_ms = format.sample_rate * s.frame_bytes / 1000
        for name, cue in pairs(cues) do s.clips[name] = synth(cue, format.sample_rate, format.channels) end
    end)
    if not ok then print("whack: audio unavailable: " .. tostring(err)); s:close() end

    function s:update(game, now)
        local event = game.sound
        game.sound = nil
        if not self.output then return end
        local success, failure = pcall(function()
            -- Countdown ticks must not interrupt hit or reward feedback.
            if event and (event ~= "tick" or not self.pcm and now >= self.queued_until) then
                self.pcm, self.offset = assert(self.clips[event], "unknown sound cue"), 1
            end
            if not self.pcm then return end
            local available = math.floor((now + 40 - math.max(now, self.queued_until)) * self.bytes_per_ms / self.frame_bytes) * self.frame_bytes
            local count = math.min(#self.pcm - self.offset + 1, available)
            if count <= 0 then return end
            -- Keep at most 40 ms queued so new hits remain responsive.
            local chunk = self.pcm:sub(self.offset, self.offset + count - 1)
            assert(self.output:write(chunk) == #chunk, "incomplete PCM write")
            self.offset = self.offset + count
            self.queued_until = math.max(now, self.queued_until) + count / self.bytes_per_ms
            if self.offset > #self.pcm then self.pcm = nil end
        end)
        if not success then print("whack: audio disabled: " .. tostring(failure)); self:close() end
    end
    return s
end

return M
