local M = {}
local BANK = { "pluck", "kick", "chime" }

function M.close(s)
    if not s then return end
    -- Release playback ownership before restoring and closing the output.
    if s.player then s.player:close(); s.player = nil end
    if s.output then
        if s.volume then s.output:set_volume(s.volume) end
        s.output:close()
        s.output = nil
    end
end

function M.open(root)
    local s = { dropped = 0 }
    local ok, err = pcall(function()
        local audio = require("audio")
        assert(type(audio.sample_player) == "function", "firmware requires audio.sample_player")
        s.output = assert(audio.open_output())
        s.volume = s.output:get_volume()
        assert(s.output:set_volume(70))
        s.player = assert(audio.sample_player({ output = s.output, source_rate = 16000, max_voices = 6,
            sample_budget_bytes = 32768, attack_ms = 2, release_ms = 12, limit_threshold = 0.8 }))
        for id, name in ipairs(BANK) do
            local file <close> = assert(io.open(root .. "/assets/" .. name .. ".pcm", "rb"))
            assert(s.player:load(id, file:read("a")))
        end
        assert(s.player:start())
    end)
    if ok then return s end
    M.close(s)
    print("[music_pinball] audio unavailable: " .. tostring(err))
end

function M.play(s, kind, note)
    if not s then return end
    local function trigger(id, gain, offset, rate)
        local voice, err = s.player:trigger(id, gain, offset or 0, 0, rate or 1)
        if not voice then
            s.dropped = s.dropped + 1
            if s.dropped == 1 then print("[music_pinball] sound dropped: " .. tostring(err)) end
        end
    end
    if kind == "note" then trigger(1, 0.65, 0, 2 ^ (note / 12))
    elseif kind == "melody" or kind == "fever_note" then
        trigger(1, 0.55, 0, 2 ^ (note / 12)); trigger(1, 0.22, 35, 2 ^ ((note + 12) / 12))
    elseif kind == "fever" then
        trigger(3, 0.5); trigger(1, 0.4, 90, 1.5); trigger(1, 0.4, 180, 2)
    elseif kind == "flip" then trigger(2, 0.28)
    elseif kind == "lost" then trigger(1, 0.45, 0, 0.5); trigger(1, 0.3, 140, 0.375)
    elseif kind == "bonus" or kind == "launch" or kind == "save" then
        trigger(3, 0.4); trigger(1, 0.35, 70, 1.25); trigger(1, 0.35, 140, 1.5)
    end
end

return M
