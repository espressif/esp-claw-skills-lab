-- guitar_logic.lua: pure chord/tuning/layout model (no hardware).
-- Tuning, chord voicings, roles, hit testing, and 480x480 geometry.
--
-- Every Y coordinate is authored for a 480-high panel. A wider panel is
-- supported by centring a 480-wide content box; `layout.origin_x` and
-- `layout.content_width` describe that box for the renderer.

local M = {}

local OPEN_HZ = { 82.4069, 110.0000, 146.8324, 195.9977, 246.9417, 329.6276 }
local CHORDS = {
    C  = { -1, 3, 2, 0, 1, 0 },
    G  = {  3, 2, 0, 0, 0, 3 },
    Am = { -1, 0, 2, 2, 1, 0 },
    F  = {  1, 3, 3, 2, 1, 1 },
    Em = {  0, 2, 2, 0, 0, 0 },
    D  = { -1,-1, 0, 2, 3, 2 },
}
local CHORD_ORDER = { "C", "G", "Am", "F", "Em", "D" }
local VALID_ROLES = { solo = true, strings = true, chords = true }
-- The instrument has six strings. `index` (1..6) is the geometric column,
-- left-to-right as drawn; the physical guitar string number runs the other
-- way (low-E is the 6th string, high-e is the 1st). Tuning and chord tables
-- are keyed by the geometric column, so that index stays the internal key;
-- only the identity handed to the native mixer is the physical number.
local STRING_COUNT = 6

-- Geometric column index (1 = leftmost = low-E) -> physical guitar string
-- number (low-E=6, A=5, D=4, G=3, B=2, high-e=1).
local function physical_string_number(index)
    return STRING_COUNT + 1 - index
end
-- Nothing is reserved along the bottom edge: the instrument gives up the
-- shell's exit swipe (see init_display) and exits only on the function button,
-- so the controls may use the full height.
local EXIT_EDGE_PX = 0
local DESIGN_WIDTH = 480
-- Controls keep enough air to survive panel masking and simulator chrome.
-- STRING_INSET_PX accommodates half of the 72 px centred label lane plus the
-- renderer's 4 px safety margin.
local CONTROL_TOP_PX = 12
local CONTROL_BOTTOM_GAP_PX = 12
local STRING_BOTTOM_GAP_PX = 14
local CHORD_INSET_PX = 8
local STRING_INSET_PX = 40

-- MIDI 440 Hz reference (A4 = 69). Frequencies are mapped to the nearest
-- semitone so a chord voicing selects the matching sampled note.
local A4_HZ = 440.0
local A4_MIDI = 69

local function freq_to_midi(frequency)
    return math.floor(0.5 + A4_MIDI + 12 * math.log(frequency / A4_HZ) / math.log(2))
end

-- Velocity is derived from horizontal motion and must stay finite, strictly
-- positive, and no greater than 1: those are the mixer:pluck contract bounds.
-- The floor is what a tap and a slow strum get, and it is high because it sets
-- the instrument's usable loudness: the samples themselves peak well below full
-- scale, so a low floor cannot be made up further down the chain. The slope
-- still reaches 1.0 within one fast swipe, which keeps strum dynamics.
local VELOCITY_FLOOR = 0.6

local function pluck_velocity(delta_x)
    return math.max(
        VELOCITY_FLOOR,
        math.min(1.0, VELOCITY_FLOOR + math.abs(delta_x) / 180))
end

local function point_in_rect(x, y, rect)
    return x >= rect.x and x < (rect.x + rect.w)
        and y >= rect.y and y < (rect.y + rect.h)
end

local function chord_at(layout, x, y)
    for _, button in ipairs(layout.chord_buttons) do
        if point_in_rect(x, y, button) then
            return button.name
        end
    end
    return nil
end

local function nearest_string(layout, x, y)
    local strings = layout.strings
    if #strings == 0 then
        return nil
    end
    local best = strings[1]
    local best_dist = math.abs(x - best.x)
    for i = 2, #strings do
        local s = strings[i]
        local dist = math.abs(x - s.x)
        if dist < best_dist then
            best = s
            best_dist = dist
        end
    end
    -- Half the string pitch: each string owns the lane up to the midpoint
    -- between it and its neighbour, and the outer two get the same lane width
    -- instead of an unbounded half-plane. On a panel wider than the content
    -- box that margin is empty space, not playable surface.
    if #strings > 1 then
        local pitch = math.abs(strings[2].x - strings[1].x)
        if best_dist > pitch / 2 then
            return nil
        end
    end
    if y >= best.y0 and y <= best.y1 then
        return best.index
    end
    return nil
end

local function classify_zone(layout, x, y)
    if y >= layout.content_bottom then
        return "edge"
    end
    if chord_at(layout, x, y) then
        return "chord"
    end
    if #layout.strings > 0
        and y >= layout.strings[1].y0
        and y <= layout.strings[1].y1 then
        return "string"
    end
    return "none"
end

-- One pluck command for the native sample mixer. `string_index` is the
-- geometric column (1 = leftmost = low-E) used to key the tuning and chord
-- tables. The command's `string` is the *physical* guitar string number
-- (low-E=6..high-e=1), which is the identity the native mixer contract
-- expects; `geometry` preserves the column index for the entry's per-string
-- visual flash. `midi` is the mapped note (nil only when the selected chord
-- mutes the string), and `timestamp_us` is the originating touch event's
-- stamp, preserved end to end. MIDI mapping and muting are keyed by geometry
-- and are unchanged by the physical renumbering.
local function make_pluck_event(state, string_index, delta_x, timestamp_us)
    local freq = M.frequency(state, string_index)
    return {
        type = "pluck",
        string = physical_string_number(string_index),
        geometry = string_index,
        chord = state.selected_chord,
        frequency = freq,
        midi = freq ~= nil and freq_to_midi(freq) or nil,
        muted = freq == nil,
        velocity = pluck_velocity(delta_x),
        timestamp_us = timestamp_us,
    }
end

-- Returns { {index = n, fraction = 0..1}, ... } in crossing order, where the
-- fraction is how far along this move's travel the string sits.
local function crossed_strings(layout, prev_x, cur_x, triggered)
    if prev_x == cur_x then
        return {}
    end
    local span = cur_x - prev_x
    local hits = {}
    for _, s in ipairs(layout.strings) do
        if not triggered[s.index] then
            local sx = s.x
            local crossed = (prev_x < sx and cur_x >= sx)
                or (prev_x > sx and cur_x <= sx)
                or (prev_x == sx and cur_x ~= sx)
            if crossed then
                local fraction = (sx - prev_x) / span
                if fraction < 0 then fraction = 0 end
                if fraction > 1 then fraction = 1 end
                table.insert(hits, { index = s.index, fraction = fraction })
            end
        end
    end
    -- Travel order is crossing order, which for evenly spaced strings is the
    -- same ascending/descending index order as before.
    table.sort(hits, function(a, b)
        if a.fraction ~= b.fraction then
            return a.fraction < b.fraction
        end
        if span > 0 then
            return a.index < b.index
        end
        return a.index > b.index
    end)
    return hits
end

-- A crossed string stays latched until the finger has clearly left it: x jitter
-- on a string line must not machine-gun one note, while a real back-and-forth
-- strum must retrigger. Half the string spacing is far wider than controller
-- noise and far narrower than a deliberate return stroke. It is measured from
-- the layout, so it scales with the panel instead of assuming a pixel pitch.
local RETRIGGER_RELEASE_FRACTION = 0.5

local function retrigger_release_px(layout)
    local strings = layout.strings
    if #strings < 2 then
        return nil
    end
    return math.abs(strings[2].x - strings[1].x) * RETRIGGER_RELEASE_FRACTION
end

-- Unlatch every string the finger now sits far enough from. Call this only
-- after the crossings of the current move have been emitted: the same move that
-- carries the finger off a string would otherwise be free to sound it twice.
local function release_left_strings(layout, triggered, x)
    local release = retrigger_release_px(layout)
    if release == nil then
        return
    end
    for _, s in ipairs(layout.strings) do
        if triggered[s.index] and math.abs(x - s.x) > release then
            triggered[s.index] = nil
        end
    end
end

local function clear_gesture(state)
    state.gesture = nil
end

local function normalize_role(role)
    if VALID_ROLES[role] then
        return role
    end
    return "solo"
end

local function build_layout(width, height, role)
    role = normalize_role(role)
    local content_bottom = height - EXIT_EDGE_PX
    -- Horizontal geometry is authored for DESIGN_WIDTH and centred on wider
    -- panels, so the instrument keeps its proportions instead of stretching.
    local content_width = math.min(width, DESIGN_WIDTH)
    local origin_x = math.floor((width - content_width) / 2)
    local layout = {
        width = width,
        height = height,
        role = role,
        origin_x = origin_x,
        content_width = content_width,
        content_bottom = content_bottom,
        chord_buttons = {},
        strings = {},
    }

    if role ~= "strings" then
        local x0 = origin_x + CHORD_INSET_PX
        local x1 = origin_x + content_width - CHORD_INSET_PX
        local y0, y1
        if role == "chords" then
            y0, y1 = CONTROL_TOP_PX, content_bottom - CONTROL_BOTTOM_GAP_PX
        else
            y0, y1 = CONTROL_TOP_PX, 150
        end
        local cols = 3
        local rows = 2
        local cell_w = (x1 - x0) / cols
        local cell_h = (y1 - y0) / rows
        for i, name in ipairs(CHORD_ORDER) do
            local row = math.floor((i - 1) / cols)
            local col = (i - 1) % cols
            table.insert(layout.chord_buttons, {
                name = name,
                x = x0 + col * cell_w,
                y = y0 + row * cell_h,
                w = cell_w,
                h = cell_h,
            })
        end
    end

    if role ~= "chords" then
        -- `label_y0..label_y1` is the nut band at the head of the fretboard,
        -- not a separate strip above it: the numbers stay large and legible
        -- while costing only the wood they sit on. The strings begin where it
        -- ends, so nothing is drawn over a label.
        local label_y0, label_y1, y0, y1
        if role == "strings" then
            label_y0, label_y1 = CONTROL_TOP_PX, 46
            y0, y1 = 46, content_bottom - STRING_BOTTOM_GAP_PX
        else
            label_y0, label_y1 = 158, 192
            y0, y1 = 192, content_bottom - STRING_BOTTOM_GAP_PX
        end
        layout.label_y0 = label_y0
        layout.label_y1 = label_y1
        local x0 = origin_x + STRING_INSET_PX
        local x1 = origin_x + content_width - STRING_INSET_PX
        local notes = { "E", "A", "D", "G", "B", "e" }
        for i = 1, 6 do
            local cx = x0 + (i - 1) * (x1 - x0) / 5
            local string_number = physical_string_number(i)
            table.insert(layout.strings, {
                index = i,
                string_number = string_number,
                note = notes[i],
                label = tostring(string_number) .. " " .. notes[i],
                x = cx,
                y0 = y0,
                y1 = y1,
            })
        end
    end

    return layout
end

function M.new(width, height, role)
    width = math.floor(tonumber(width) or 480)
    height = math.floor(tonumber(height) or 480)
    role = normalize_role(role)
    return {
        width = width,
        height = height,
        role = role,
        selected_chord = "C",
        layout = build_layout(width, height, role),
    }
end

function M.set_role(state, role)
    role = normalize_role(role)
    state.role = role
    state.layout = build_layout(state.width, state.height, role)
    return role
end

function M.select_chord(state, chord_name)
    if not CHORDS[chord_name] then
        return false
    end
    state.selected_chord = chord_name
    return true
end

function M.frequency(state, string_index)
    string_index = math.floor(tonumber(string_index) or 0)
    if string_index < 1 or string_index > 6 then
        return nil
    end
    local voicing = CHORDS[state.selected_chord]
    if not voicing then
        return nil
    end
    local fret = voicing[string_index]
    if fret < 0 then
        return nil
    end
    return OPEN_HZ[string_index] * (2 ^ (fret / 12))
end

-- Nearest MIDI note for a string under the selected chord, or nil when the
-- chord mutes it. The mixer keys its loaded samples by this note.
function M.midi(state, string_index)
    local freq = M.frequency(state, string_index)
    if freq == nil then
        return nil
    end
    return freq_to_midi(freq)
end

-- Process one ordered touch event `{type, x, y, timestamp_us}` and return the
-- ordered logic events it produces (plucks and chord selections).
--
-- The touch adapter delivers a stream of discrete down/move/up events; this
-- consumes them one at a time so the entry can drain a whole batch and submit
-- every resulting command before it draws.
--
-- Rules:
--   * A chord-pad `down` latches the chord immediately. `up` never restores a
--     previous chord.
--   * A string-area `down` plucks the nearest string immediately.
--   * Each `move` plucks every string newly crossed since the previous
--     coordinate, in swipe (geometric) order. A string that just sounded is
--     latched until the finger moves half a string spacing away from it, so a
--     back-and-forth strum keeps sounding the strings it sweeps while jitter on
--     a string line cannot repeat one note. `up` clears the gesture entirely.
function M.handle_event(state, event)
    local layout = state.layout
    local etype = event.type
    local x = tonumber(event.x) or 0
    local y = tonumber(event.y) or 0
    local timestamp_us = event.timestamp_us
    local events = {}

    if etype == "down" then
        local zone = classify_zone(layout, x, y)
        if zone == "chord" then
            local chord_name = chord_at(layout, x, y)
            if chord_name then
                M.select_chord(state, chord_name)
                table.insert(events, {
                    type = "select_chord",
                    chord = chord_name,
                })
            end
            state.gesture = { zone = "chord" }
        elseif zone == "string" then
            state.gesture = {
                zone = "string",
                prev_x = x,
                triggered_strings = {},
            }
            local string_index = nearest_string(layout, x, y)
            if string_index then
                state.gesture.triggered_strings[string_index] = true
                table.insert(
                    events,
                    make_pluck_event(state, string_index, 0, timestamp_us)
                )
            end
        else
            state.gesture = { zone = "none" }
        end
        return events
    end

    if etype == "move" then
        local gesture = state.gesture
        if gesture ~= nil and gesture.zone == "string" then
            local prev_x = gesture.prev_x
            local delta_x = x - prev_x
            local crossed = crossed_strings(
                layout, prev_x, x, gesture.triggered_strings
            )
            for _, hit in ipairs(crossed) do
                gesture.triggered_strings[hit.index] = true
                table.insert(
                    events,
                    make_pluck_event(state, hit.index, delta_x, timestamp_us)
                )
            end
            release_left_strings(layout, gesture.triggered_strings, x)
            gesture.prev_x = x
        end
        return events
    end

    if etype == "up" then
        clear_gesture(state)
    end

    return events
end

-- No `presentation` accessor: string-flash pulses are owned by the entry
-- script, which already knows the pluck events it just consumed.

return M
