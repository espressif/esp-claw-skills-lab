-- mosaico_musical.lua: raw `display` guitar page for the 480x480 Mosaico face.
-- Owns display lifecycle only; chord/gesture state lives in guitar_logic and
-- input normalization lives in touch_adapter. Never mixes lvgl with display.
--
-- Audio mixes the sample bank in Lua using the board output format.

local display = require("display")
local canvas
-- Keep alignment local; the display API draws text at an explicit origin.
local function aligned_text(x, y, w, h, text, opts)
    opts = opts or {}
    opts.font_size = math.max(8, math.min(64, math.floor(opts.font_size or 24)))
    if opts.bg then canvas:fill_rect(math.floor(x), math.floor(y), math.floor(w), math.floor(h), opts.bg) end
    local tw, th = canvas:measure_text(text, opts)
    if opts.align == "center" then x = x + (w - tw) // 2 elseif opts.align == "right" then x = x + w - tw end
    if opts.valign == "middle" then y = y + (h - th) // 2 elseif opts.valign == "bottom" then y = y + h - th end
    canvas:text(math.floor(x), math.floor(y), text, opts)
end

local delay = require("delay")

local logic = require("guitar_logic")
local touch_adapter = require("touch_adapter")
local sample_loader = require("sample_loader")
local sample_engine = require("sample_engine")
local pairing_adapter = require("pairing_adapter")

local system_ok, system = pcall(require, "system")
if not system_ok then system = nil end

local COLORS = {
    background = "#17110D",
    wood = "#6E3F22",
    pad = "#2B211B",
    selected = "#F2A93B",
    string = "#E8DFCF",
    muted = "#756C62",
    text = "#FFF4DE",
    accent = "#58D5C4",
}

-- The layout is authored for exactly this viewport; see init_display.
local DESIGN_WIDTH = 480
local DESIGN_HEIGHT = 480
local FRAME_MS = 33
-- Floor for the frame delay. delay_ms checks the stop flag even for a zero
-- delay, so this is not about stop delivery: it keeps an over-budget frame
-- from turning the render loop into a busy loop that starves other tasks.
local MIN_SLEEP_MS = 4
-- Touch and audio are serviced far more often than the panel is repainted. A
-- redraw costs ~46 primitives including 13 TTF text runs, so tying input
-- latency to the repaint rate made input feel late.
local LOOP_MS = 8
local ROLE_POLL_MS = 1000
local PULSE_MS = 200
local PAD_INSET = 6
local PAD_RADIUS = 14
-- Diagnostics are overlaid on a corner of the instrument instead of getting a
-- reserved row, so they cost no vertical space in the normal case.
local BADGE_W = 74
local BADGE_H = 22
local BADGE_MARGIN = 4
-- The fretboard is inset less than the chord grid's pads: it is one slab, so
-- its rounded corners are the only thing the margin has to clear.
local BOARD_INSET = 8
local PANEL_MARGIN = 4
local STRING_LABEL_WIDTH = 72
local FRET_COUNT = 5
local FRET_WIDTH = 3
-- Restore the device-wide volume when this session ends.
local AUDIO_VOLUME = 100
-- Resample the 16 kHz mono bank to the output format; use six voices.
local MIXER_MAX_VOICES = 6
-- Keep audio warnings visible briefly.
local AUDIO_WARN_MS = 1000
local FUNCTION_GPIO = 7
local FUNCTION_ACTIVE = 0

-- Audio is optional: hosted simulators often ship neither `audio` nor a codec.
-- Missing audio leaves the instrument usable as a silent touch surface.
-- `audio_out` holds { output, engine, rate, channels, dead } once the
-- chain is up, and stays nil whenever any link is missing.
local audio_out = nil

-- Owned at file scope so the protected cleanup below can close them in order
-- (touch stream, then mixer, then output) whether the run exits cleanly or a
-- partial startup raised.
local touch = nil

-- Set only while the first frame is on screen and the sample bank has not been
-- loaded yet, so the badge can distinguish "not ready" from "not available".
local audio_loading = false

-- Every numeric the display bindings take is checked with lua_isinteger, which
-- rejects the float subtype even when the value is whole: `6 / 2` is 3.0 and is
-- refused. Layout math divides freely, so these wrappers are the choke point
-- where coordinates, extents, radii and font sizes become integers.

local function fill_rect(x, y, w, h, color)
    w, h = math.floor(w), math.floor(h)
    if w < 1 or h < 1 then
        return
    end
    x, y = math.floor(x), math.floor(y)
    canvas:fill_rect(x, y, w, h, color)
end

local function hline(x, y, w, color)
    canvas:line(math.floor(x), math.floor(y), math.floor(x + w - 1), math.floor(y), color)
end

local function fill_round_rect(x, y, w, h, radius, color)
    canvas:fill_round_rect(math.floor(x), math.floor(y),
        math.floor(w), math.floor(h), math.floor(radius), color)
end

local function stroke_round_rect(x, y, w, h, radius, color)
    canvas:stroke_round_rect(math.floor(x), math.floor(y),
        math.floor(w), math.floor(h), math.floor(radius), color)
end

local function text_in(x, y, w, h, value, color, size, align)
    aligned_text(math.floor(x), math.floor(y),
        math.floor(w), math.floor(h), value, {
            color = color,
            font_size = size and math.floor(size) or nil,
            align = align or "center",
            valign = "middle",
        })
end

-- Hosted builds can freeze system.millis at a positive value. Detect stalls
-- and advance by LOOP_MS so 200 ms pulses expire deterministically.
local clock = {
    last_raw = nil,
    stalls = 0,
    frame_clock = 0,
}

local function read_millis()
    if system ~= nil and type(system.millis) == "function" then
        local ok, value = pcall(system.millis)
        if ok then
            return math.floor(tonumber(value) or 0)
        end
    end
    return 0
end

local function now_ms()
    local raw = read_millis()
    if raw > 0 and (clock.last_raw == nil or raw > clock.last_raw) then
        clock.last_raw = raw
        clock.stalls = 0
        return raw
    end
    if raw > 0 then
        clock.stalls = clock.stalls + 1
        return clock.last_raw + clock.stalls * LOOP_MS
    end
    local now = clock.frame_clock
    clock.frame_clock = now + LOOP_MS
    return now
end

-- String-flash state is owned here: `add_pulse` is called for every pluck
-- event the loop consumes, muted ones included. The native mixer places each
-- note in time itself, so the flash simply starts now.
local pulses = {}

local function add_pulse(string_index, muted, now)
    string_index = math.floor(tonumber(string_index) or 0)
    if string_index < 1 or string_index > 6 then
        return
    end
    pulses[string_index] = {
        until_ms = now + PULSE_MS,
        muted = muted == true,
    }
end

local function pulse_active(string_index, now)
    local pulse = pulses[string_index]
    if pulse == nil then
        return nil
    end
    if now >= pulse.until_ms then
        pulses[string_index] = nil
        return nil
    end
    return pulse
end

-- The base rendering thickness of a string, keyed by its geometric column so
-- the outer strings read thicker like a real guitar. A pulse and its restore
-- reuse this exact thickness -- a flash is only a colour change, never a wider
-- line or a halo -- so one fill_rect at the base geometry overwrites the prior
-- colour pixel-for-pixel.
local function string_thickness(index)
    return math.max(2, 8 - index)
end

-- The colour a string lane should currently show: its pulse colour while a
-- flash is live (accent, or the selected colour for a muted pluck), otherwise
-- its base colour (muted grey when the chord silences it, ivory when it
-- sounds). The geometric column is the key throughout; the physical string
-- number only ever leaves the model on the mixer command, never here.
local function desired_string_color(state, geometry, now)
    local pulse = pulse_active(geometry, now)
    if pulse ~= nil then
        return pulse.muted and COLORS.selected or COLORS.accent
    end
    if logic.frequency(state, geometry) == nil then
        return COLORS.muted
    end
    return COLORS.string
end

-- Collapses the badge row to one comparable value for change detection.
local function badge_state()
    if audio_loading then
        return "loading"
    end
    if audio_out == nil or audio_out.dead then
        return "muted"
    end
    if audio_out.warn_until_ms ~= nil then
        return "warn"
    end
    return "on"
end

-- Whether the left diagnostic badge (LOADING/MUTED/BUSY) and the right role
-- badge are currently on screen. Used only so a partial repaint of an outer
-- string lane -- the only lanes whose bottom reaches under a badge -- can re-lay
-- that badge on top and never flash over it.
local function left_badge_visible(now)
    if audio_loading then
        return true
    end
    if audio_out == nil or audio_out.dead then
        return true
    end
    return audio_out.warn_until_ms ~= nil and now < audio_out.warn_until_ms
end

local function right_badge_visible(state)
    return state.role ~= "solo"
end

-- Paints one chord pad exactly as a full frame would: the same rectangle,
-- radius, fill, stroke and label. A partial chord redraw calls this for the
-- pad losing selection and the pad gaining it, so the two paints together
-- overwrite precisely the pixels that changed.
local function draw_chord_button(state, button)
    local selected = button.name == state.selected_chord
    local x = button.x + PAD_INSET
    local y = button.y + PAD_INSET
    local w = button.w - 2 * PAD_INSET
    local h = button.h - 2 * PAD_INSET
    local fill = selected and COLORS.selected or COLORS.pad
    local label = selected and COLORS.background or COLORS.text
    fill_round_rect(x, y, w, h, PAD_RADIUS, fill)
    stroke_round_rect(x, y, w, h, PAD_RADIUS,
        selected and COLORS.text or COLORS.wood)
    text_in(x, y, w, h, button.name, label, 24)
end

local function draw_chord_pads(state)
    for _, button in ipairs(state.layout.chord_buttons) do
        draw_chord_button(state, button)
    end
end

local function draw_one_chord_pad(state, name)
    for _, button in ipairs(state.layout.chord_buttons) do
        if button.name == name then
            draw_chord_button(state, button)
            return
        end
    end
end

-- A badge says something only when it says something unusual, so it is drawn
-- over a corner of the instrument rather than in a band reserved for it.
local function draw_badge(x, y, value, color)
    fill_round_rect(x, y, BADGE_W, BADGE_H, 8, COLORS.pad)
    stroke_round_rect(x, y, BADGE_W, BADGE_H, 8, color)
    text_in(x, y, BADGE_W, BADGE_H, value, color, 16)
end

local function draw_badges(state, now)
    local layout = state.layout
    local ox = layout.origin_x
    local cw = layout.content_width
    -- Bottom corners, not top: the nut band's outer labels reach the top
    -- corners in the `strings` role, and the lower frets carry no text in any
    -- role.
    local y = layout.content_bottom - BADGE_MARGIN - BADGE_H
    -- The frame drawn before the sample bank is loaded must not claim MUTED:
    -- audio is pending, not unavailable, and the two demand different actions
    -- from whoever is holding the board.
    if audio_loading then
        draw_badge(ox + BADGE_MARGIN, y, "LOADING", COLORS.accent)
    elseif audio_out == nil or audio_out.dead then
        draw_badge(ox + BADGE_MARGIN, y, "MUTED", COLORS.selected)
    elseif audio_out.warn_until_ms ~= nil
        and now < audio_out.warn_until_ms then
        draw_badge(ox + BADGE_MARGIN, y, "BUSY", COLORS.accent)
    end
    if state.role ~= "solo" then
        draw_badge(ox + cw - BADGE_MARGIN - BADGE_W, y,
            string.upper(state.role), COLORS.accent)
    end
end

local function draw_fretboard(state)
    local layout = state.layout
    local strings = layout.strings
    if #strings == 0 then
        return
    end
    local first = strings[1]
    -- The board starts at the nut band, which carries the string labels: one
    -- slab of wood instead of a label strip plus a separate fretboard.
    local board_top = layout.label_y0 or (first.y0 - 6)
    local board_bottom = math.min(layout.content_bottom - 4, first.y1 + 6)
    local board_h = board_bottom - board_top
    local ox = layout.origin_x
    local cw = layout.content_width
    local board_w = cw - 2 * BOARD_INSET
    fill_round_rect(ox + BOARD_INSET, board_top, board_w, board_h, 20,
        COLORS.wood)
    stroke_round_rect(ox + BOARD_INSET, board_top, board_w, board_h, 20,
        COLORS.pad)

    local fret_x = ox + BOARD_INSET + 6
    local fret_w = board_w - 12
    fill_rect(fret_x, first.y0 - 2, fret_w, FRET_WIDTH + 2, COLORS.text)
    for i = 1, FRET_COUNT do
        local y = first.y0 + i * (first.y1 - first.y0) / FRET_COUNT
        fill_rect(fret_x, y - FRET_WIDTH, fret_w, FRET_WIDTH, COLORS.pad)
    end
    hline(fret_x, first.y1 + 2, fret_w, COLORS.pad)
end

-- One string line, at its base geometry, in the given colour. The full frame
-- and every partial repaint go through this single primitive, so a colour
-- change is a byte-for-byte overwrite of the same pixels -- no halo, no width
-- change to leave residue behind.
local function draw_string_line(line, color)
    local thickness = string_thickness(line.index)
    fill_rect(line.x - thickness / 2, line.y0,
        thickness, line.y1 - line.y0 + 1, color)
end

local function draw_strings(state, now)
    local layout = state.layout
    local strings = layout.strings
    if #strings == 0 or layout.label_y0 == nil or layout.label_y1 == nil then
        return
    end
    -- The nut band is a darker inlay on the board the strings already sit on.
    local label_y = layout.label_y0 + 4
    local label_h = layout.label_y1 - layout.label_y0 - 6
    fill_round_rect(layout.origin_x + BOARD_INSET + 4, label_y,
        layout.content_width - 2 * BOARD_INSET - 8, label_h, 10, COLORS.pad)

    for _, line in ipairs(strings) do
        draw_string_line(line, desired_string_color(state, line.index, now))
        text_in(line.x - STRING_LABEL_WIDTH / 2, label_y,
            STRING_LABEL_WIDTH, label_h,
            line.label, COLORS.text, 24)
    end
end

-- Repaint exactly one string lane (by geometric column) in the given colour,
-- and nothing else. This is the entire cost of a pulse start, a pulse expiry,
-- or a chord remuting one lane: a single fill_rect over the frame on screen.
local function redraw_string_color(state, geometry, color)
    for _, line in ipairs(state.layout.strings) do
        if line.index == geometry then
            draw_string_line(line, color)
            return
        end
    end
end

local function draw_frame(state, now)
    canvas:begin({ clear = COLORS.background })
    draw_fretboard(state)
    draw_strings(state, now)
    draw_chord_pads(state)
    draw_badges(state, now)
    canvas:present()

end

-- A partial repaint over the frame already on screen. clear=false keeps those
-- pixels; we overwrite only the two pads whose selection changed and each lane
-- in `changed` (one fill_rect apiece, already coalesced by the caller so a lane
-- repaints at most once per batch). The outer lanes reach under a badge's
-- bottom edge, so when such a lane repaints while its badge is shown we re-lay
-- that badge on top; interior lanes never touch a badge, so the common case
-- adds nothing.
-- Real-display note: this relies on begin_frame({clear=false}) preserving the
-- prior frame. Task 7 verifies that on device; if it does not, the fallback is
-- to keep this state-driven scheduling but call draw_frame here instead -- the
-- audio dispatch in the loop still precedes any display call either way.
local function draw_partial(state, now, chord_changed, prev_chord, changed)
    canvas:begin()
    if chord_changed then
        draw_one_chord_pad(state, prev_chord)
        draw_one_chord_pad(state, state.selected_chord)
    end
    local relay_badges = false
    for _, ch in ipairs(changed) do
        redraw_string_color(state, ch.index, ch.color)
        if (ch.index == 1 and left_badge_visible(now))
            or (ch.index == 6 and right_badge_visible(state)) then
            relay_badges = true
        end
    end
    if relay_badges then
        draw_badges(state, now)
    end
    canvas:present()

end

local function init_display()
    canvas = display.open()
    local info = canvas:info()
    if info.height ~= DESIGN_HEIGHT or info.width < DESIGN_WIDTH then
        error("mosaico-musical requires a display at least 480 wide and exactly 480 high")
    end
    return info.width, info.height
end

local function muted(reason)
    print("mosaico-musical: audio unavailable, MUTED: " .. reason)
    return nil
end

-- Raises the shared output volume to AUDIO_VOLUME and returns the level that
-- was in effect, or nil when the firmware exposes no volume control. Neither
-- step is fatal: a refused volume only costs loudness.
local function claim_output_volume(output)
    local previous = nil
    if type(output.get_volume) == "function" then
        local ok, value = pcall(output.get_volume, output)
        if ok then
            previous = tonumber(value)
        end
    end
    if type(output.set_volume) ~= "function" then
        print("mosaico-musical: output has no set_volume; using system volume")
        return nil
    end
    local ok, err = pcall(output.set_volume, output, AUDIO_VOLUME)
    if not ok then
        print("mosaico-musical: set_volume failed: " .. tostring(err))
        return nil
    end
    print(string.format("mosaico-musical: output volume %s -> %d",
        previous ~= nil and tostring(previous) or "?", AUDIO_VOLUME))
    return previous
end

-- The steel PCM lives beside this script under ../assets/steel. `args` may
-- override it for tests or a relocated install.
local function resolve_steel_dir()
    if type(args) == "table" then
        if type(args.steel_dir) == "string" and args.steel_dir ~= "" then
            return args.steel_dir
        end
        if type(args.assets_dir) == "string" and args.assets_dir ~= "" then
            return (args.assets_dir:gsub("[\\/]+$", "")) .. "/steel"
        end
    end
    local info = debug and debug.getinfo and debug.getinfo(1, "S")
    local src = (info and info.source) or ""
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    src = src:gsub("\\", "/")
    local scripts_dir = src:match("^(.*)/[^/]+$")
    if scripts_dir then
        local skill_dir = scripts_dir:match("^(.*)/scripts$")
        if skill_dir then
            return skill_dir .. "/assets/steel"
        end
    end
    return nil
end

-- Yield while loading the sample bank so cancellation stays responsive.
local function setup_lua_engine(output, format, previous_volume)
    local samples, load_err = sample_loader.load(
        resolve_steel_dir(),
        function()
            delay.delay_ms(1)
        end)
    if samples == nil then
        if previous_volume then pcall(output.set_volume, output, previous_volume) end
        pcall(function() output:close() end)
        return muted(load_err)
    end
    local engine = sample_engine.new({
        samples = samples,
        sample_rate = format.rate,
        source_rate = sample_loader.map_rate(),
        channels = format.channels,
        max_voices = MIXER_MAX_VOICES,
    })
    print(string.format(
        "mosaico-musical: lua engine up rate=%d channels=%d notes=%d",
        format.rate, format.channels, sample_engine.sample_count(engine)))
    return {
        output = output,
        engine = engine,
        previous_volume = previous_volume,
        rate = format.rate,
        channels = format.channels,
        loaded = sample_engine.sample_count(engine),
        dead = false,
        active_voices = 0,
        dropped = 0,
        warn_until_ms = nil,
        last_stats_ms = nil,
        last_pump_ms = nil,
        lua_draining = false,
    }
end

-- Generate PCM in the board output format; the sample engine resamples the bank.
local function setup_audio()
    local available, audio = pcall(require, "audio")
    if not available then return muted(tostring(audio)) end
    local opened, output = pcall(audio.open_output)
    if not opened then return muted(tostring(output)) end
    local info = output:info()
    if info.bits ~= 16 or (info.channels ~= 1 and info.channels ~= 2) then
        output:close()
        return muted("sample engine requires 16-bit mono or stereo PCM")
    end
    return setup_lua_engine(output, { rate = info.sample_rate, channels = info.channels }, claim_output_volume(output))
end

-- Restore the shared volume before releasing the output.
local function close_audio()
    local active = audio_out
    audio_out = nil
    if active == nil then
        return
    end
    active.engine = nil
    if active.output ~= nil then
        -- Before muting: the level belongs to the shared mixer, so leaving it
        -- raised would make every other app on the device louder.
        if active.previous_volume ~= nil
            and type(active.output.set_volume) == "function" then
            pcall(active.output.set_volume, active.output,
                active.previous_volume)
        end
        if type(active.output.set_mute) == "function" then
            pcall(active.output.set_mute, active.output, true)
        end
        pcall(function() active.output:close() end)
        active.output = nil
    end
end

-- Rate-limited so a full queue cannot flood the log; the note is dropped by the
-- mixer, not retried here.
local function warn_audio(now, message)
    audio_out.dropped = (audio_out.dropped or 0) + 1
    audio_out.warn_until_ms = now + AUDIO_WARN_MS
    if audio_out.last_warn_ms == nil or now - audio_out.last_warn_ms >= 500 then
        audio_out.last_warn_ms = now
        print("mosaico-musical: " .. message .. " (dropped="
            .. tostring(audio_out.dropped) .. ")")
    end
end

-- Enqueues one pluck command. Non-blocking: the mixer either accepts it or
-- returns nil on a full queue, which is a warning, not a fault. A raised error
-- puts the chain in the dead state so the badge flips to MUTED.
local function submit_pluck(event, now)
    if audio_out == nil or audio_out.dead or event.midi == nil then
        return
    end
    if audio_out.engine == nil or event.frequency == nil then
        return
    end
    local ok, res, perr = pcall(
        sample_engine.pluck, audio_out.engine,
        event.frequency, event.velocity, now, 0)
    if not ok then
        audio_out.dead = true
        print("mosaico-musical: engine:pluck raised, MUTED: " .. tostring(res))
        return
    end
    if res == false then
        warn_audio(now, "lua pluck refused: " .. tostring(perr))
    else
        audio_out.lua_draining = true
    end
end

-- Lua path only: render the wall-clock gap since the last pump and write it.
-- Idle with no voices writes nothing, so the amp is not held on digital zero.
local function pump_lua_audio(now)
    if audio_out == nil or audio_out.dead or audio_out.engine == nil then
        return
    end
    local last = audio_out.last_pump_ms
    audio_out.last_pump_ms = now
    if last == nil then
        return
    end
    local elapsed_ms = now - last
    if elapsed_ms < 1 then
        elapsed_ms = LOOP_MS
    elseif elapsed_ms > 80 then
        elapsed_ms = 80
    end
    local voices = sample_engine.active_voice_count(audio_out.engine)
    if voices < 1 and not audio_out.lua_draining then
        return
    end
    local frames = math.floor(audio_out.rate * elapsed_ms / 1000)
    if frames < 1 then
        frames = 1
    end
    local ok, pcm = pcall(sample_engine.render, audio_out.engine, frames)
    if not ok then
        audio_out.dead = true
        print("mosaico-musical: lua render raised, MUTED: " .. tostring(pcm))
        return
    end
    if type(pcm) == "string" and #pcm > 0 then
        local wok, written, werr = pcall(audio_out.output.write, audio_out.output, pcm)
        if not wok or written ~= #pcm then
            audio_out.dead = true
            print("mosaico-musical: output:write raised, MUTED: "
                .. tostring(wok and werr or written))
            return
        end
    end
    audio_out.active_voices = sample_engine.active_voice_count(audio_out.engine)
    audio_out.lua_draining = audio_out.active_voices > 0
end

local function init_function_button()
    local ok_module, button = pcall(require, "button")
    if not ok_module then
        print("mosaico-musical: no button module; exit with the shell swipe "
            .. "or the simulator stop control")
        return nil, nil, nil
    end
    local made, handle = pcall(button.new, FUNCTION_GPIO, FUNCTION_ACTIVE)
    local err = made and nil or handle
    if not made then handle = nil end
    if handle == nil then
        print("mosaico-musical: Function Button unavailable: "
            .. tostring(err))
        return nil, nil, nil
    end
    local level, level_err = button.get_key_level(handle)
    if level == nil then
        print("mosaico-musical: Function Button unavailable: "
            .. tostring(level_err))
        return nil, nil, nil
    end
    return button, handle, level
end

local function poll_function_button(button, handle, last_level)
    local level, level_err = button.get_key_level(handle)
    if level == nil then
        error("[mosaico-musical] ERROR: Function Button (GPIO7) unavailable: "
            .. tostring(level_err), 0)
    end
    local pressed = level == FUNCTION_ACTIVE and last_level ~= FUNCTION_ACTIVE
    return level, pressed
end

local function run()
    local width, height = init_display()
    local state = logic.new(width, height, "solo")

    local adapter, terr = touch_adapter.new(canvas)
    if adapter == nil then
        error(terr or "touch unavailable: no usable device or hosted backend", 0)
    end
    touch = adapter

    -- The instrument is on screen before the sample bank is loaded, so the
    -- panel is never left blank during startup; a LOADING badge marks that
    -- window. read_millis, not now_ms: now_ms advances its stall synthesis on
    -- every call, and no pulse exists yet, so the exact value cannot matter.
    audio_loading = true
    draw_frame(state, read_millis())
    -- Trackers describe the frame now on screen. The badge is captured while
    -- audio is still loading, so the first loop pass -- once setup_audio has
    -- flipped it to muted/on -- detects the badge change and repaints.
    local last_chord = state.selected_chord
    local last_role = state.role
    local last_badge = badge_state()
    local last_draw_ms = nil
    -- The colour last painted for each string lane, so the loop repaints only
    -- the lanes whose colour actually changed. Seeded from the frame just
    -- drawn (no pulses yet, so every lane is at its base colour).
    local string_colors = {}
    for i = 1, 6 do
        string_colors[i] = desired_string_color(state, i, 0)
    end

    local button_mod, button_handle, button_last_level
    if adapter.source == "device" then
        button_mod, button_handle, button_last_level = init_function_button()
    end

    audio_out = setup_audio()
    audio_loading = false

    print(string.format(
        "mosaico-musical: %dx%d role=%s chord=%s touch=%s audio=%s",
        width, height, state.role, state.selected_chord, adapter.source,
        audio_out ~= nil and "on" or "muted"))

    -- No discovery provider is wired in, so this always resolves to `solo`.
    -- It exists so a future backend can change the role without touching the
    -- render loop; it is not magnetic pairing and detects no physical link.
    local pairing = pairing_adapter.new(nil)
    local next_role_poll_ms = nil

    -- The LOADING frame already went out above; count it so the periodic
    -- frame log stays meaningful.
    local frames = 1
    while true do
        -- Raw clock, deliberately not now_ms(): the frozen-clock synthesis
        -- advances on every read, which would make work look like a frame.
        local work_started = read_millis()
        local now = now_ms()

        if button_handle ~= nil then
            local pressed
            button_last_level, pressed = poll_function_button(
                button_mod, button_handle, button_last_level)
            if pressed then
                error("stop requested", 0)
            end
        end

        if next_role_poll_ms == nil or now >= next_role_poll_ms then
            next_role_poll_ms = now + ROLE_POLL_MS
            local role, changed = pairing:poll()
            if changed and role ~= state.role then
                -- set_role rebuilds only the layout: the selected chord and
                -- every sounding voice live outside it and keep playing.
                logic.set_role(state, role)
                -- A strum in flight was measured against the old geometry.
                state.gesture = nil
                print(string.format(
                    "mosaico-musical: role change -> %s chord=%s voices=%d",
                    role, state.selected_chord,
                    audio_out ~= nil and audio_out.active_voices or 0))
            end
        end

        -- Drain the whole batch of touch events, translate them to logic
        -- commands, and submit every mixer:pluck BEFORE the panel is drawn:
        -- audio-before-display keeps a strum tight. state (and state.gesture)
        -- persists across iterations on purpose.
        local batch = adapter:drain(64)
        for _, touch_event in ipairs(batch) do
            local events = logic.handle_event(state, touch_event)
            for _, event in ipairs(events) do
                if event.type == "pluck" then
                    -- The flash is drawn per geometric column, so it keys on
                    -- `geometry`; `event.string` is the physical guitar string
                    -- number used by submit_pluck.
                    add_pulse(event.geometry, event.muted, now)
                    submit_pluck(event, now)
                end
            end
        end

        pump_lua_audio(now)

        -- Repaint only what the eye would notice, and never faster than
        -- FRAME_MS. A role change rebuilt the layout and a badge appearing or
        -- clearing must be laid down/lifted cleanly off the body, so both take
        -- the full frame; everything else is a partial paint. The exact string
        -- lanes whose colour must change -- pulse starts, pulse expiries, and
        -- lanes the new chord remutes -- are coalesced here into one list, so a
        -- batch that plucked several strings still repaints each lane at most
        -- once, and it happens after every mixer:pluck for the batch went out.
        local badge = badge_state()
        local role_changed = state.role ~= last_role
        local badge_changed = badge ~= last_badge
        local chord_changed = state.selected_chord ~= last_chord
        local changed = {}
        for i = 1, 6 do
            local want = desired_string_color(state, i, now)
            if want ~= string_colors[i] then
                changed[#changed + 1] = { index = i, color = want }
            end
        end
        local dirty = role_changed or badge_changed or chord_changed
            or #changed > 0
        if dirty and (last_draw_ms == nil or now - last_draw_ms >= FRAME_MS) then
            if role_changed or badge_changed then
                draw_frame(state, now)
                for i = 1, 6 do
                    string_colors[i] = desired_string_color(state, i, now)
                end
            else
                draw_partial(state, now, chord_changed, last_chord, changed)
                for _, ch in ipairs(changed) do
                    string_colors[ch.index] = ch.color
                end
            end
            last_draw_ms = now
            last_chord = state.selected_chord
            last_role = state.role
            last_badge = badge
            frames = frames + 1
            if frames % 90 == 0 then
                print(string.format("mosaico-musical: f=%d chord=%s",
                    frames, state.selected_chord))
            end
        end

        -- The service period stays near LOOP_MS: subtract this iteration's own
        -- work from the delay so input latency does not drift with the work.
        local sleep_ms = LOOP_MS
        if work_started > 0 then
            local elapsed = read_millis() - work_started
            if elapsed > 0 then
                sleep_ms = LOOP_MS - elapsed
            end
        end
        if sleep_ms < MIN_SLEEP_MS then
            sleep_ms = MIN_SLEEP_MS
        end
        delay.delay_ms(sleep_ms)
    end
end

local ok, err = xpcall(run, function(message)
    local trace = ""
    if debug ~= nil and type(debug.traceback) == "function" then
        trace = tostring(debug.traceback("", 2))
    end
    return tostring(message) .. "\n" .. trace
end)

-- Unwind in creation order's reverse: release the touch stream, then the mixer,
-- then the output, then the display. Each step is protected so a partial
-- startup (touch up but no audio, or a mixer that never started) cleans only
-- what it created.
pcall(function()
    if touch ~= nil then
        touch:close()
        touch = nil
    end
end)
pcall(close_audio)
pcall(function() if canvas then canvas:close(); canvas = nil end end)

-- A cooperative stop arrives as a raised error, and the wording differs by
-- host: firmware's delay module raises "stop requested" while the hosted web
-- simulator raises "script stopped". Both are normal shutdowns, not crashes,
-- so neither may print ERROR. The patterns stay anchored to the
-- "<chunk>:<line>: " prefix so a genuine failure whose text merely ends the
-- same way is still reported.
local STOP_SIGNALS = {
    "^.-:%d+: stop requested$",
    "^.-:%d+: script stopped$",
}

local function is_stop_signal(message)
    for _, pattern in ipairs(STOP_SIGNALS) do
        if message:match(pattern) ~= nil then
            return true
        end
    end
    return false
end

if not ok then
    local msg = tostring(err)
    local first = msg:match("^[^\n]+") or msg
    if not is_stop_signal(first) then
        print("[mosaico-musical] ERROR: " .. first)
    end
end
