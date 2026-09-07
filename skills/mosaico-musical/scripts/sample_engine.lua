-- sample_engine.lua: bounded PCM sample voices rendered to s16 PCM.
-- Same caller-facing API as the retired pluck_synth module.
--
-- Rate conversion happens per voice while rendering, not to the sample bank at
-- load time. An earlier version resampled every shipped note inside `new()`;
-- with a 48 kHz codec that expanded 1.28 MB of 16 kHz samples into millions of
-- Lua table slots in one unyielding loop, so the entry drew no first frame and
-- could not observe a stop request. Playback now advances a fractional read
-- position by `step = source_rate / output_rate` and interpolates, which is
-- O(1) per output sample and makes `new()` free.

local M = {}

local DEFAULT_SAMPLE_RATE = 16000
local DEFAULT_CHANNELS = 1
local DEFAULT_MAX_VOICES = 10
local MAX_AGE_S = 2.5
local ATTACK_S = 0.004
local RELEASE_S = 0.015
local MAX_ONSET_S = 0.25
local LIMIT_THRESHOLD = 0.70
local PACK_BATCH = 64
local BATCH_FORMAT = string.rep("<i2", PACK_BATCH)
local MIN_SAMPLE_RATE = 8000
local MAX_SAMPLE_RATE = 192000
-- Below this the fractional read path is indistinguishable from integer
-- stepping, so the cheaper branch is taken.
local STEP_EPSILON = 1e-9

local function clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

-- Soft knee limiter: linear below the threshold, asymptotic to 1.0 above it,
-- so a full six-string strum compresses instead of hard-clipping.
local function soft_limit(value)
    local magnitude = math.abs(value)
    if magnitude <= LIMIT_THRESHOLD then
        return value
    end
    local over = (magnitude - LIMIT_THRESHOLD) / (1.0 - LIMIT_THRESHOLD)
    local shaped = LIMIT_THRESHOLD
        + (1.0 - LIMIT_THRESHOLD) * (over / (1.0 + over))
    if value < 0 then
        return -shaped
    end
    return shaped
end

local function freq_to_midi(frequency)
    return math.floor(0.5 + 69 + 12 * math.log(frequency / 440) / math.log(2))
end

-- Adds one voice's contribution to `acc[1..count]` and advances its cursors.
--
-- Deliberately block-at-a-time rather than sample-at-a-time: this runs at the
-- output rate on a 240 MHz interpreter, so a per-sample function call for the
-- voice, its envelope, and the limiter costs more than the arithmetic. Here
-- every voice field is hoisted into a local once per block and the inner loop
-- is one unpack plus an add.
--
-- Attack and release are counted in output frames, so the envelope keeps the
-- same wall-clock shape whatever rate the codec runs at.
local function mix_voice(voice, acc, count, step)
    local age = voice.age
    local out_length = voice.out_length
    -- Frames still available before this voice falls silent.
    local usable = out_length - age
    if usable > count then
        usable = count
    end
    if usable < 1 then
        voice.age = age + count
        return
    end

    local pcm = voice.pcm
    local pos = voice.pos
    local attack = voice.attack_frames
    local attack_inv = voice.attack_inv
    local release = voice.release_frames
    local release_inv = voice.release_inv
    -- Folds the 16-bit normalisation into the per-voice level so the inner
    -- loop needs one multiply instead of two.
    local scale = voice.scale
    local unpack_i16 = string.unpack

    if step == nil then
        -- Output rate equals the bank's rate: read straight through.
        for i = 1, usable do
            local gain
            if age < attack then
                gain = (age + 1) * attack_inv
            else
                local remaining = out_length - age
                if remaining < release then
                    gain = remaining * release_inv
                else
                    gain = 1.0
                end
            end
            acc[i] = acc[i]
                + unpack_i16("<i2", pcm, (pos - 1) * 2 + 1) * gain * scale
            pos = pos + 1
            age = age + 1
        end
    else
        local frames = voice.frames
        for i = 1, usable do
            local index = pos // 1
            local frac = pos - index
            local byte_at = (index - 1) * 2 + 1
            local a = unpack_i16("<i2", pcm, byte_at)
            local b = a
            if index < frames then
                b = unpack_i16("<i2", pcm, byte_at + 2)
            end
            local gain
            if age < attack then
                gain = (age + 1) * attack_inv
            else
                local remaining = out_length - age
                if remaining < release then
                    gain = remaining * release_inv
                else
                    gain = 1.0
                end
            end
            acc[i] = acc[i] + (a + (b - a) * frac) * gain * scale
            pos = pos + step
            age = age + 1
        end
    end

    voice.pos = pos
    -- A voice that ran dry mid-block still ages for the whole block, so
    -- retirement stays driven by elapsed frames rather than by reads.
    voice.age = age + (count - usable)
end

-- Samples are stored as handed over: no decoding, no rate conversion, no copy
-- of the payload. This is what keeps `new()` cheap enough to call on the
-- render task before the first frame.
local function index_samples(samples)
    local out = {}
    for midi, pcm in pairs(samples) do
        if type(pcm) == "string" and #pcm >= 4 then
            out[midi] = { pcm = pcm, frames = #pcm // 2 }
        end
    end
    return out
end

-- Whole output samples to withhold before a voice sounds. Anything absent,
-- negative, NaN, or absurd degrades to an immediate onset or the bounded
-- maximum.
local function onset_frames(state, onset_ms)
    onset_ms = tonumber(onset_ms)
    if onset_ms == nil or onset_ms ~= onset_ms or onset_ms <= 0 then
        return 0
    end
    local frames = math.floor(onset_ms * state.sample_rate / 1000)
    local limit = math.floor(state.sample_rate * MAX_ONSET_S)
    if frames > limit then
        return limit
    end
    return frames
end

function M.new(config)
    config = config or {}
    local sample_rate = math.floor(
        tonumber(config.sample_rate) or DEFAULT_SAMPLE_RATE)
    if sample_rate < MIN_SAMPLE_RATE or sample_rate > MAX_SAMPLE_RATE then
        sample_rate = DEFAULT_SAMPLE_RATE
    end
    local source_rate = math.floor(
        tonumber(config.source_rate) or DEFAULT_SAMPLE_RATE)
    if source_rate < MIN_SAMPLE_RATE or source_rate > MAX_SAMPLE_RATE then
        source_rate = DEFAULT_SAMPLE_RATE
    end
    local channels = math.floor(tonumber(config.channels) or DEFAULT_CHANNELS)
    if channels ~= 2 then
        channels = 1
    end
    local max_voices = math.floor(
        tonumber(config.max_voices) or DEFAULT_MAX_VOICES)
    if max_voices < 1 then
        max_voices = DEFAULT_MAX_VOICES
    end

    local step = source_rate / sample_rate
    return {
        sample_rate = sample_rate,
        source_rate = source_rate,
        channels = channels,
        max_voices = max_voices,
        -- nil marks the integer fast path; any other value is the fractional
        -- source advance per output frame.
        step = math.abs(step - 1.0) < STEP_EPSILON and nil or step,
        samples = index_samples(config.samples or {}),
        voices = {},
        pluck_count = 0,
        -- Reused scratch buffer for grouped string.pack calls.
        batch = {},
        -- Reused float accumulator: voices are summed into this per block.
        acc = {},
    }
end

function M.sample_count(state)
    local count = 0
    for _ in pairs(state.samples) do
        count = count + 1
    end
    return count
end

function M.pluck(state, frequency, velocity, now_ms, onset_ms)
    frequency = tonumber(frequency)
    if frequency == nil then
        return false, "frequency is required"
    end
    if frequency <= 0 then
        return false, "frequency must be positive"
    end
    if frequency >= state.sample_rate / 2 then
        return false, "frequency is above the Nyquist limit"
    end
    if frequency < 1.0 then
        return false, "frequency is below the lowest playable pitch"
    end

    local midi = freq_to_midi(frequency)
    local sample = state.samples[midi]
    if sample == nil then
        print(string.format(
            "mosaico-musical: no sample for midi %d (%.2f Hz)",
            midi, frequency))
        return false, "no sample for requested pitch"
    end

    velocity = clamp(tonumber(velocity) or 1.0, 0.0, 1.0)

    -- How many output frames this sample yields at the current step, capped by
    -- the voice lifetime so one note can never pin a slot.
    local step = state.step
    local out_length = sample.frames
    if step ~= nil then
        out_length = math.floor((sample.frames - 1) / step) + 1
    end
    out_length = math.min(out_length,
        math.floor(state.sample_rate * MAX_AGE_S))
    if out_length < 1 then
        return false, "sample is too short to sound"
    end

    state.pluck_count = state.pluck_count + 1
    local attack_frames = math.max(1,
        math.floor(state.sample_rate * ATTACK_S))
    local release_frames = math.max(1,
        math.floor(state.sample_rate * RELEASE_S))
    local voice = {
        pcm = sample.pcm,
        frames = sample.frames,
        pos = 1,
        age = 0,
        out_length = out_length,
        attack_frames = attack_frames,
        release_frames = release_frames,
        -- Reciprocals and the folded level are precomputed because the mixer
        -- would otherwise redo both once per output sample per voice.
        attack_inv = 1.0 / attack_frames,
        release_inv = 1.0 / release_frames,
        scale = velocity / 32768.0,
        started_ms = math.floor(tonumber(now_ms) or 0),
        -- Output frames still to withhold, counted down by render.
        pending = onset_frames(state, onset_ms),
        velocity = velocity,
    }

    -- Hard cap: the oldest voice yields to the newest pluck.
    while #state.voices >= state.max_voices do
        table.remove(state.voices, 1)
    end
    table.insert(state.voices, voice)
    return true, nil
end

-- Counts pending voices as well as sounding ones. Callers use this to decide
-- whether the engine still needs rendering; excluding a scheduled voice would
-- let the caller stop rendering and park that note forever.
function M.active_voice_count(state)
    return #state.voices
end

function M.render(state, frame_count)
    frame_count = math.floor(tonumber(frame_count) or 0)
    if frame_count < 1 then
        return ""
    end

    local voices = state.voices
    local step = state.step
    local stereo = state.channels == 2
    local chunks = {}
    local batch = state.batch
    local batch_len = 0
    local acc = state.acc

    -- The block is split at each pending voice's start sample so the mixer
    -- never tests whether a voice has begun: within one segment the set of
    -- sounding voices is fixed.
    local frame = 0
    while frame < frame_count do
        local segment_end = frame_count
        local sounding_len = 0
        for i = 1, #voices do
            local pending = voices[i].pending
            if pending <= frame then
                sounding_len = sounding_len + 1
            elseif pending < segment_end then
                segment_end = pending
            end
        end
        -- Loop invariant: segment_end > frame, so every pass consumes at least
        -- one frame. An inverted comparison above would otherwise spin this
        -- loop forever, which on device is a locked Lua task.
        if segment_end <= frame then
            segment_end = frame + 1
        end
        local count = segment_end - frame

        for i = 1, count do
            acc[i] = 0.0
        end
        if sounding_len > 0 then
            for i = 1, #voices do
                local voice = voices[i]
                if voice.pending <= frame then
                    mix_voice(voice, acc, count, step)
                end
            end
        end

        for i = 1, count do
            local mix = acc[i]
            -- The limiter is a call only when it would actually shape the
            -- sample; a lone string never reaches the knee.
            if mix > LIMIT_THRESHOLD or mix < -LIMIT_THRESHOLD then
                mix = soft_limit(mix)
            end
            local sample = math.floor(mix * 32767.0)
            if sample > 32767 then
                sample = 32767
            elseif sample < -32768 then
                sample = -32768
            end
            batch_len = batch_len + 1
            batch[batch_len] = sample
            if stereo then
                batch_len = batch_len + 1
                batch[batch_len] = sample
            end
            -- Pack in groups so the render loop does not hand the GC one short
            -- string per sample.
            if batch_len >= PACK_BATCH then
                chunks[#chunks + 1] = string.pack(
                    BATCH_FORMAT, table.unpack(batch, 1, PACK_BATCH))
                batch_len = 0
            end
        end
        frame = segment_end
    end

    for i = 1, #voices do
        local pending = voices[i].pending
        if pending > 0 then
            pending = pending - frame_count
            voices[i].pending = pending > 0 and pending or 0
        end
    end
    if batch_len > 0 then
        chunks[#chunks + 1] = string.pack(
            string.rep("<i2", batch_len), table.unpack(batch, 1, batch_len))
    end

    for i = #voices, 1, -1 do
        local voice = voices[i]
        -- A voice that has not sounded yet is silent by design and must not be
        -- retired for having produced nothing.
        if voice.pending == 0 and voice.age >= voice.out_length then
            table.remove(voices, i)
        end
    end

    return table.concat(chunks)
end

return M
