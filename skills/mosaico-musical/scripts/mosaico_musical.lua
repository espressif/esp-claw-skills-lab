-- mosaico_musical.lua: raw `display` guitar page for the 480x480 Mosaico face.
-- Owns display lifecycle only; chord/gesture state lives in guitar_logic and
-- input normalization lives in touch_adapter. Never mixes lvgl with display.
--
-- Audio prefers a native `audio.sample_mixer` when the firmware has one.
-- Official ESP-Claw builds do not: they still get sound from `sample_engine`
-- mixed in Lua and written with `output:write`. That path can miss a fast
-- strum because the write may block touch sampling.

local board_manager = require("board_manager")
local display = require("display")
local delay = require("delay")

-- The device launcher runs this file by absolute path and does not put the
-- skill's own scripts/ directory on package.path, so the sibling modules below
-- are unresolvable until we add it. In the bundled single-file build the same
-- modules are pre-registered in package.preload, where this is a no-op.
do
    local info = debug and debug.getinfo and debug.getinfo(1, "S")
    local src = (info and info.source) or ""
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    src = src:gsub("\\", "/")
    local scripts_dir = src:match("^(.*)/[^/]+$")
    if scripts_dir and package and package.path then
        package.path = scripts_dir .. "/?.lua;" .. package.path
    end
end

local logic = require("guitar_logic")
local touch_adapter = require("touch_adapter")
local sample_map = require("sample_map")
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
-- The `volume` field of the open descriptor is only recorded by the firmware,
-- never pushed to the mixer, so the level has to be set explicitly after the
-- open. This is the shared mixer's output volume, i.e. the whole device's, so
-- the previous value is captured and restored on the way out.
local AUDIO_VOLUME = 100
local AUDIO_BITS = 16
local DEFAULT_CHANNELS = 1
local MIN_SAMPLE_RATE = 8000
local MAX_SAMPLE_RATE = 192000
-- The bank ships at 16 kHz mono; the mixer's default source rate matches, so
-- opening the codec at that format keeps the codec and the samples aligned.
local PREFERRED_RATE = 16000
-- The mixer is guitar-specific: exactly six voices, one per string.
local MIXER_MAX_VOICES = 6
local MIXER_QUEUE_DEPTH = 32
-- Stats are polled far less often than plucks are submitted: once a note is on
-- its way the queue depth and failure flag change slowly.
local STATS_POLL_MS = 500
-- How long a queue-full warning badge stays up after the last drop.
local AUDIO_WARN_MS = 1000
local FUNCTION_GPIO = 7
local FUNCTION_ACTIVE = 0

-- Audio is optional: hosted simulators often ship neither `audio` nor a codec.
-- Missing codec stays MUTED. Missing `sample_mixer` still sounds via Lua.
-- `audio_out` holds { output, mixer|engine, rate, channels, dead } once the
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
local has_fill_rect = type(display.fill_rect) == "function"
local has_draw_line = type(display.draw_line) == "function"
local has_draw_round_rect = type(display.draw_round_rect) == "function"

local function fill_rect(x, y, w, h, color)
    w, h = math.floor(w), math.floor(h)
    if w < 1 or h < 1 then
        return
    end
    x, y = math.floor(x), math.floor(y)
    if has_fill_rect then
        display.fill_rect(x, y, w, h, color)
    else
        display.fill_round_rect(x, y, w, h, 0, color)
    end
end

local function hline(x, y, w, color)
    if has_draw_line then
        display.draw_line(math.floor(x), math.floor(y),
            math.floor(x + w - 1), math.floor(y), color)
    else
        fill_rect(x, y, w, 1, color)
    end
end

local function fill_round_rect(x, y, w, h, radius, color)
    display.fill_round_rect(math.floor(x), math.floor(y),
        math.floor(w), math.floor(h), math.floor(radius), color)
end

local function stroke_round_rect(x, y, w, h, radius, color)
    if not has_draw_round_rect then
        return
    end
    display.draw_round_rect(math.floor(x), math.floor(y),
        math.floor(w), math.floor(h), math.floor(radius), color)
end

local function text_in(x, y, w, h, value, color, size, align)
    display.draw_text_aligned(math.floor(x), math.floor(y),
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
    display.begin_frame({ clear = true, color = COLORS.background })
    draw_fretboard(state)
    draw_strings(state, now)
    draw_chord_pads(state)
    draw_badges(state, now)
    display.present()
    display.end_frame()
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
    display.begin_frame({ clear = false })
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
    display.present()
    display.end_frame()
end

local function init_display()
    local panel_handle, io_handle, width, height, panel_if =
        board_manager.get_display_lcd_params("display_lcd")

    width = math.floor(tonumber(width) or 0)
    height = math.floor(tonumber(height) or 0)
    -- Hosted backends often report nothing; assume the design viewport.
    if width < 64 then width = DESIGN_WIDTH end
    if height < 64 then height = DESIGN_HEIGHT end

    -- Height is load-bearing: every band edge (chord grid, nut band,
    -- fretboard, exit reserve) is a 480-based literal, so on a shorter panel
    -- the fretboard lands inside the reserved exit band and the instrument
    -- silently stops responding. Extra width is harmless -- guitar_logic
    -- centres a 480-wide content box -- and the hosted simulator's canvas
    -- defaults to 800x480, so wider panels must keep working.
    if height ~= DESIGN_HEIGHT or width < DESIGN_WIDTH then
        error(string.format(
            "unsupported panel %dx%d: mosaico-musical needs height %d "
            .. "and width >= %d",
            width, height, DESIGN_HEIGHT, DESIGN_WIDTH), 0)
    end

    -- The string lanes and the badges reach into the bottom band the shell's
    -- exit swipe watches, so that gesture both swallowed strums and quit the
    -- instrument mid-song. Giving it up makes the function button the only exit
    -- and hands the bottom-edge touches back to the strings. Firmware without
    -- the option ignores the table and keeps the swipe; see SKILL.md.
    local ok = pcall(function()
        display.init(panel_handle, io_handle, width, height, panel_if, nil,
            { exit_gesture = false })
    end)
    if not ok then
        ok = pcall(function()
            display.init(panel_handle, io_handle, width, height, panel_if)
        end)
    end
    if not ok then
        display.init(panel_handle, io_handle, width, height)
    end
    if type(display.backlight) == "function" then
        pcall(display.backlight, true)
    end
    return width, height
end

-- Returns nil whenever any part of the audio chain is unavailable so the
-- instrument stays playable as a silent visual surface. A silent instrument in
-- the field is indistinguishable from a broken one unless the log says which
-- link of the chain gave way.
local function muted(reason)
    print("mosaico-musical: audio unavailable, MUTED: " .. reason)
    return nil
end

-- Firmware builds disagree on this name. Observed: the esp-claw sources in
-- hand register new_output/new_input, while a Mosaico device reported
-- open_output/open_input. Which way the rename went is unverified, so neither
-- spelling is treated as canonical.
local OUTPUT_OPENERS = { "open_output", "new_output" }

local function resolve_opener(audio)
    for _, name in ipairs(OUTPUT_OPENERS) do
        if type(audio[name]) == "function" then
            return name, audio[name]
        end
    end
    return nil, nil
end

-- Parses whatever `get_audio_codec_output_params` returned into codec + rate +
-- channels, or nil plus the reason it could not.
local function parse_codec_params(first, second, third)
    local codec, rate, channels
    if type(first) == "table" and (first.rate or first.sample_rate) then
        codec = first.codec or first.handle or first
        rate = tonumber(first.rate or first.sample_rate)
        channels = tonumber(first.channels)
    elseif type(first) == "table" or type(first) == "userdata"
        or type(first) == "string" then
        codec = first
        rate = tonumber(second)
        channels = tonumber(third)
    else
        return nil, "unrecognised codec params shape: " .. type(first)
    end

    if rate == nil then
        return nil, "codec params carry no sample rate"
    end
    rate = math.floor(rate)
    if rate < MIN_SAMPLE_RATE or rate > MAX_SAMPLE_RATE then
        return nil, string.format(
            "codec sample rate %d outside %d..%d",
            rate, MIN_SAMPLE_RATE, MAX_SAMPLE_RATE)
    end
    channels = math.floor(channels or DEFAULT_CHANNELS)
    if channels ~= 2 then channels = DEFAULT_CHANNELS end
    return { codec = codec, rate = rate, channels = channels }
end

-- Opens one output codec device, or nil plus the reason it was refused.
local function try_open_format(open_output, opener_name, codec, format)
    local ok_output, output, open_err = pcall(open_output, {
        codec = codec,
        sample_rate = format.rate,
        channels = format.channels,
        bits = AUDIO_BITS,
        volume = AUDIO_VOLUME,
    })
    if not ok_output then
        return nil, "audio." .. opener_name .. " failed: " .. tostring(output)
    end
    if output == nil then
        return nil, "audio." .. opener_name
            .. " rejected the descriptor: "
            .. tostring(open_err or "no reason given")
    end
    return output, nil
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

-- Opens the codec at the bank's own 16 kHz mono when possible, falling back to
-- whatever format the board reported if the codec refuses the first. Returns
-- the output object plus the format it was actually opened at.
local function open_output_device(open_output, opener_name, codec, board)
    local preferred = { rate = PREFERRED_RATE, channels = DEFAULT_CHANNELS }
    local fallback = { rate = board.rate, channels = board.channels }

    local output, reason = try_open_format(
        open_output, opener_name, codec, preferred)
    if output ~= nil then
        return output, preferred
    end

    -- Only worth a second attempt when the fallback differs; otherwise the
    -- same descriptor would be refused for the same reason.
    if fallback.rate ~= preferred.rate
        or fallback.channels ~= preferred.channels then
        print(string.format(
            "mosaico-musical: codec refused %d Hz x%d (%s); "
            .. "retrying at %d Hz x%d",
            preferred.rate, preferred.channels, tostring(reason),
            fallback.rate, fallback.channels))
        local retry, retry_reason = try_open_format(
            open_output, opener_name, codec, fallback)
        if retry ~= nil then
            return retry, fallback
        end
        reason = retry_reason
    end
    return nil, reason
end

-- Loads every note in sample_map into the mixer by absolute path. The PCM is
-- read by the native mixer, never into Lua. Returns the count, or nil + reason.
local function load_all_notes(mixer, steel_dir)
    if steel_dir == nil or steel_dir == "" then
        return nil, "steel assets directory unavailable"
    end
    local order = {}
    for midi in pairs(sample_map.notes) do
        order[#order + 1] = midi
    end
    table.sort(order)

    local loaded = 0
    for _, midi in ipairs(order) do
        local entry = sample_map.notes[midi]
        local path = steel_dir .. "/" .. entry.file
        local ok, res, err = pcall(mixer.load_note, mixer, midi, path)
        if not ok then
            return nil, string.format(
                "load_note(%d) raised: %s", midi, tostring(res))
        end
        if res == nil then
            return nil, string.format(
                "load_note(%d, %s) failed: %s",
                midi, entry.file, tostring(err))
        end
        loaded = loaded + 1
    end
    if loaded < 1 then
        return nil, "sample map is empty"
    end
    return loaded
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

-- Official firmware has no sample_mixer. Mix in Lua and push PCM through the
-- same output. Yields once per file so a 1.3 MB load cannot swallow stop.
local function setup_lua_engine(output, format, previous_volume)
    local samples, load_err = sample_loader.load(
        resolve_steel_dir(),
        function()
            pcall(delay.delay_ms, 1)
        end)
    if samples == nil then
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
        mixer = nil,
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

-- Brings the whole audio chain up: require the module, open one output, then
-- either the native mixer or the Lua engine. Any failed step tears down only
-- what this call created and returns nil, leaving the instrument a silent
-- visual surface. Returns the audio_out session on success.
local function setup_audio()
    local ok_module, audio = pcall(require, "audio")
    if not ok_module then
        return muted("require('audio') failed: " .. tostring(audio))
    end
    if type(audio) ~= "table" then
        return muted("audio module is a " .. type(audio) .. ", not a table")
    end

    local open_name, open_output = resolve_opener(audio)
    if open_output == nil then
        local names = {}
        for key in pairs(audio) do
            names[#names + 1] = tostring(key)
        end
        table.sort(names)
        return muted("audio module exports none of "
            .. table.concat(OUTPUT_OPENERS, "/") .. "; it has: "
            .. (#names > 0 and table.concat(names, ",") or "nothing"))
    end
    if type(board_manager.get_audio_codec_output_params) ~= "function" then
        return muted("board_manager has no get_audio_codec_output_params")
    end

    local ok_params, first, second, third = pcall(
        board_manager.get_audio_codec_output_params, "audio_dac")
    if not ok_params then
        return muted("codec params call failed: " .. tostring(first))
    end
    local board, params_err = parse_codec_params(first, second, third)
    if board == nil then
        return muted(params_err)
    end

    local output, format = open_output_device(
        open_output, open_name, board.codec, board)
    if output == nil then
        return muted(tostring(format))
    end
    local previous_volume = claim_output_volume(output)

    if type(audio.sample_mixer) == "function" then
        local ok_mixer, mixer, mixer_err = pcall(audio.sample_mixer, {
            output = output,
            max_voices = MIXER_MAX_VOICES,
            queue_depth = MIXER_QUEUE_DEPTH,
        })
        if ok_mixer and mixer ~= nil then
            local loaded, load_err = load_all_notes(mixer, resolve_steel_dir())
            if loaded ~= nil then
                local ok_start, started, start_err = pcall(function()
                    return mixer:start()
                end)
                if ok_start and started ~= nil then
                    print(string.format(
                        "mosaico-musical: mixer up rate=%d channels=%d notes=%d",
                        format.rate, format.channels, loaded))
                    return {
                        output = output,
                        mixer = mixer,
                        previous_volume = previous_volume,
                        rate = format.rate,
                        channels = format.channels,
                        loaded = loaded,
                        dead = false,
                        active_voices = 0,
                        dropped = 0,
                        warn_until_ms = nil,
                        last_stats_ms = nil,
                    }
                end
                print("mosaico-musical: mixer:start failed: "
                    .. tostring((not ok_start) and started or start_err))
            else
                print("mosaico-musical: mixer load failed: " .. tostring(load_err))
            end
            pcall(function() mixer:close() end)
        else
            print("mosaico-musical: native mixer unavailable: "
                .. tostring(mixer_err or mixer))
        end
    end

    return setup_lua_engine(output, format, previous_volume)
end

-- The mixer must be closed before the output: `output:close` returns busy
-- until the mixer releases it. Idempotent via the nil-out of audio_out.
local function close_audio()
    local active = audio_out
    audio_out = nil
    if active == nil then
        return
    end
    if active.mixer ~= nil then
        pcall(function() active.mixer:close() end)
        active.mixer = nil
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
    if audio_out.mixer ~= nil then
        local ok, res, perr = pcall(audio_out.mixer.pluck, audio_out.mixer, {
            string = event.string,
            midi = event.midi,
            velocity = event.velocity,
            timestamp_us = event.timestamp_us,
        })
        if not ok then
            audio_out.dead = true
            print("mosaico-musical: mixer:pluck raised, MUTED: " .. tostring(res))
            return
        end
        if res == nil then
            warn_audio(now, "mixer queue full: " .. tostring(perr))
        end
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
        local wok, werr = pcall(audio_out.output.write, audio_out.output, pcm)
        if not wok then
            audio_out.dead = true
            print("mosaico-musical: output:write raised, MUTED: "
                .. tostring(werr))
            return
        end
    end
    audio_out.active_voices = sample_engine.active_voice_count(audio_out.engine)
    audio_out.lua_draining = audio_out.active_voices > 0
end

-- Samples the mixer's health at STATS_POLL_MS, not per pluck: a codec write
-- failure flips `failed`, which turns the badge to MUTED without taking the UI
-- loop down.
local function poll_audio_stats(now)
    if audio_out == nil or audio_out.dead or audio_out.mixer == nil then
        return
    end
    if audio_out.last_stats_ms ~= nil
        and now - audio_out.last_stats_ms < STATS_POLL_MS then
        return
    end
    audio_out.last_stats_ms = now
    local ok, stats = pcall(function()
        return audio_out.mixer:poll()
    end)
    if not ok or type(stats) ~= "table" then
        return
    end
    audio_out.active_voices = tonumber(stats.active_voices) or 0
    if stats.failed == true then
        audio_out.dead = true
        print("mosaico-musical: mixer failed, MUTED: "
            .. tostring(stats.error or "codec write error"))
    end
    if audio_out.warn_until_ms ~= nil and now >= audio_out.warn_until_ms then
        audio_out.warn_until_ms = nil
    end
end

local function init_function_button()
    local ok_module, button = pcall(require, "button")
    if not ok_module then
        print("mosaico-musical: no button module; exit with the shell swipe "
            .. "or the simulator stop control")
        return nil, nil, nil
    end
    local handle, err = button.new(FUNCTION_GPIO, FUNCTION_ACTIVE)
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

    local adapter, terr = touch_adapter.new(board_manager)
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
                    -- number handed to the native mixer by submit_pluck.
                    add_pulse(event.geometry, event.muted, now)
                    submit_pluck(event, now)
                end
            end
        end

        poll_audio_stats(now)
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
-- The display module documents end_frame before deinit: a draw call that
-- raised mid-frame would otherwise deinitialize an open frame.
pcall(function() display.end_frame() end)
pcall(function() display.deinit() end)

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
