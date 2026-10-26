-- Timed score playback and a separate chord practice study.
local qingtian = require("qingtian_score")
local pingfan = require("pingfan_score")
local M = {}
M.songs = {
    { title = "一直很安静", artist = "阿桑", description = "简化伴奏", bpm = 72, chords = { "F", "G", "C", "C" } },
    { title = "晴天", artist = "周杰伦", description = "指弹独奏", bpm = qingtian.bpm, score = qingtian },
    { title = "平凡之路", artist = "朴树", description = "指弹独奏", bpm = pingfan.bpm, score = pingfan },
}
local pattern = { 0, 3, 4, 5, 6, 5, 4, 3 }

function M.new()
    return { index = nil, step = -1, started_ms = 0, cursor = 1, skipped = 0 }
end

function M.stop(player)
    player.index = nil
end

function M.start(player, index, now)
    if not M.songs[index] then return false end
    player.index, player.step, player.started_ms = index, -1, now
    player.cursor, player.skipped, player.bar, player.note = 1, 0, 1, 1
    return true
end

-- Absolute time prevents drift; skip missed notes instead of bursting them.
function M.poll(player, now, state, logic)
    local song = M.songs[player.index]
    if not song then return {} end
    if song.score then
        local score, batch = song.score, {}
        local tick_ms = 60000 / (song.bpm * score.ticks_per_beat)
        local elapsed = now - player.started_ms
        if elapsed >= score.total_ticks * tick_ms + 100 then M.stop(player); return batch end
        -- Queue one short lookahead window; native audio owns within-window timing.
        while player.bar <= #score.order do
            local notes = score.patterns[score.order[player.bar]]
            local event = notes[player.note]
            if not event then
                player.bar, player.note = player.bar + 1, 1
            else
                local due = ((player.bar - 1) * score.ticks_per_beat * 4 + event[1]) * tick_ms
                if due > elapsed + 100 or #batch >= 24 then break end
                player.cursor, player.note = player.cursor + 1, player.note + 1
                if due >= elapsed - 100 then
                    batch[#batch + 1] = { type = "pluck", midi = event[2], velocity = event[3],
                        duration_ms = math.max(1, math.floor(event[4] * tick_ms + 0.5)),
                        delay_ms = math.max(0, math.floor(due - elapsed + 0.5)), geometry = event[5] }
                else
                    player.skipped = player.skipped + 1
                end
            end
        end
        return batch
    end
    local step = math.floor(math.max(0, now - player.started_ms) * song.bpm / 30000)
    if step >= #song.chords * 8 * 4 then M.stop(player); return {} end
    if step <= player.step then return {} end
    player.step = step
    logic.select_chord(state, song.chords[math.floor(step / 8) % #song.chords + 1])
    local geometry = pattern[step % #pattern + 1]
    if geometry == 0 then
        for i = 1, 6 do
            if logic.midi(state, i) then geometry = i; break end
        end
    end
    local midi = logic.midi(state, geometry)
    if not midi then return {} end
    return {{ type = "pluck", geometry = geometry, midi = midi, velocity = step % 8 == 0 and 0.75 or 0.55 }}
end

return M
