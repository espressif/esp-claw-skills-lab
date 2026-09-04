---
{
  "name": "mosaico-musical",
  "description": "Play a six-string Mosaico guitar: choose simple chords, tap strings, or swipe to strum.",
  "author": "xujiamu",
  "metadata": {
    "category": ["media", "ui"],
    "tags": ["guitar", "instrument", "chords", "strum", "touch"],
    "peripherals": ["display", "speaker"],
    "cap_groups": ["cap_lua"],
    "manage_mode": "web"
  },
  "execution": {
    "entry": "scripts/mosaico_musical.lua",
    "args": {},
    "order": 20,
    "visible": true
  },
  "simulator": {
    "entry": "scripts/mosaico_musical.lua",
    "files": [
      "scripts/mosaico_musical.lua",
      "scripts/guitar_logic.lua",
      "scripts/touch_adapter.lua",
      "scripts/sample_map.lua",
      "scripts/sample_loader.lua",
      "scripts/sample_engine.lua",
      "scripts/pairing_adapter.lua",
      "assets/ATTRIBUTION.md"
    ]
  }
}
---

# Mosaico Musical

Use this skill when the user wants to play guitar on the device screen: pick a chord,
tap a string, or swipe across the strings to strum.

Requires a display. The native design viewport is 480x480; a wider panel is fine and
the instrument is centred on it, but the panel must be exactly 480 pixels high.

Audio prefers a native `audio.sample_mixer` when the firmware exports one: the entry
opens one output, loads the 18 CC0 steel-string notes by path, and only enqueues
`mixer:pluck` from then on. Official ESP-Claw firmware does not ship that mixer. In
that case the same samples are mixed in Lua (`sample_engine`) and written with
`output:write`. Taps still sound. A fast strum can drop crossed strings because a
blocking codec write delays the next touch sample. The hosted simulator uses the Lua
engine (via the bundled `mosaico_musical_sim.lua`).

If there is no `audio` module or the codec will not open, the page stays a playable
visual instrument with a `MUTED` badge. The log names the failed step.

The instrument draws its first frame before the sample bank is loaded, so the panel is
never left blank during startup; a `LOADING` badge marks that window.

The samples ship at 16 kHz mono and the codec is opened at that format, falling back to
the board-reported format if it refuses. Rate conversion happens in the firmware mixer
or, on the Lua path, inside `sample_engine`.

Touch: if `lcd_touch.new_stream` exists, a C task samples every 5 ms. Otherwise the
skill falls back to hosted or polled touch, which is enough for taps and slow strums.

Exit: on ESP-Mosaico, press the Function Button (GPIO7) when that GPIO is present.
Firmware that accepts `display.init(..., { exit_gesture = false })` then uses that
button only. Official firmware ignores the option and keeps the shell swipe; boards
without GPIO7 also exit that way. The hosted simulator uses its script-stop control.

This Skill is the ESP-Claw Skills Lab / community build. Multi-device magnetic
instruments live in a separate native app, not in this package.

## Launch

Tool call:

```json
{"path":"{CUR_SKILL_DIR}/scripts/mosaico_musical.lua","args":{}}
```

Optional long-running launch:

```json
{"path":"{CUR_SKILL_DIR}/scripts/mosaico_musical.lua","args":{},"exclusive":"display","replace":true,"name":"mosaico_musical"}
```

Use `lua_run_script_async` for the async form when available.

The hosted local-script upload at https://simulator.esp-claw.com/ accepts one
Lua file and does not load sibling `require` modules. For that path, upload
`mosaico_musical_sim.lua` (regenerate with `python tools/bundle_mosaico_musical.py`).
Device launch and `simulator.files` stay the individual scripts under `scripts/`.

To share the Skill with other ESP-Claw devices, package this directory as
`Skills/mosaico-musical/` and open a PR against
https://github.com/espressif/esp-claw-skills-lab (MIT). Players install it from
https://skills-lab.esp-claw.com via the on-device Skills Lab downloader. Do not
include `.asset-originals/` or test-only tools.

The simulator canvas defaults to 800x480, which works as-is: the instrument is drawn
centred in a 480-wide box. Any canvas 480 or more wide is accepted as long as its
height is exactly 480. A different height is refused at launch with a log line saying
so, because every vertical band is authored against a 480-high panel.

## User Interaction

- Six chord pads fill the top of the screen: C, G, Am, F, Em, D. Tapping a pad latches
  that chord on touch-down; C is selected at launch and the selection persists after
  release until another pad is tapped.
- Six vertical strings are tuned E2, A2, D3, G3, B3, E4 and get progressively thinner
  from low E on the left to high e on the right. Labels read `6 E` through `1 e`.
- Tap a string to pluck it, on touch-down. Swipe horizontally across the strings to
  strum; every crossed string fires in crossing order. A string that just sounded is
  latched until the finger moves half a string spacing (40 px on a 480-wide layout)
  away from it, so a back-and-forth strum keeps sounding the strings it sweeps -- a
  single gesture is not limited to six plucks -- while jitter on a string line cannot
  repeat one note. A vertical drag does not strum.
- Plucking a string that is still ringing replaces that string's own voice; different
  strings ring together, up to six at once.
- Each pluck carries its original touch timestamp to the native mixer, which owns note
  timing. This is verified offline only, like the rest of the audio path.
- Strings muted by the selected chord are drawn dimmed and flash without a pitch.
- There is no status row. The chord buttons and the fretboard fill the panel edge to
  edge, and the selected chord is shown by the highlighted pad rather than repeated
  as text.
- Diagnostics are corner badges drawn only when they say something: `LOADING` while
  the sample bank is being read, `MUTED` when no audio codec is available, and the
  role name only in a paired role. None of them reserves any space.
- On ESP-Mosaico, press the Function Button (GPIO7) to exit when that pin is wired.
  Official firmware keeps the shell swipe; boards without the button use that swipe too.

## Device roles

The page always plays `solo`: every chord pad and every string is on one screen.

`scripts/pairing_adapter.lua` is a seam, not a feature. It is **not** magnetic
pairing and it detects no physical link: no discovery provider is wired in, so the
shipped Skill can only ever resolve to `solo`. The module exists so a future
backend can supply

```
provider.poll() -> {connected=boolean, local_id=string, peer_id=string}|nil
```

and split two devices deterministically without negotiating: the lower `local_id`
takes `chords`, the higher takes `strings`. Anything else — a provider error, a
missing report, a disconnected peer, or equal/empty IDs — stays `solo`. The entry
polls the adapter once per second and, on a change, rebuilds only the layout, so
the selected chord and any sounding notes carry across.

`docs/preview/render-05-role-strings.png` and `render-06-role-chords.png` are
rendered offline through a stubbed provider purely to show those two layouts.

## Audio behavior

Steel-string pluck samples (CC0 Martin HD28 from the Discord SFZ GM Bank) play through
the native six-voice `audio.sample_mixer`. All 18 notes are loaded into mixer-owned
memory by path before `start`; the raw PCM never enters Lua. Each of the six voice
slots is keyed by physical string number (low-E=6 .. high-e=1): plucking an idle string
starts its note, plucking an active string replaces that string's voice with a short
de-click ramp, and different strings overlap. `mixer:pluck` is non-blocking; a full
command queue returns nil, is rate-limited into a transient `BUSY` badge, and never
blocks the loop.

When any link of the audio chain is missing or refuses the descriptor, the `MUTED`
badge appears and the log carries a one-line reason
(`mosaico-musical: audio unavailable, MUTED: ...`) naming the step that failed. A codec
write failure reported by `mixer:poll` also flips the badge to `MUTED` without taking
the UI down.

## Firmware requirements

The device build must provide two additive firmware APIs. Both are source-compatible
extensions; existing `lcd_touch.read/poll/sync` and existing `audio` callers are
unchanged.

- `lcd_touch.new_stream(handle, {interval_ms=5, queue_depth=64})` -- an asynchronous
  single-contact touch event stream. A C task samples every 5 ms and queues ordered
  `{type="down"|"move"|"up", x, y, timestamp_us}` events; `stream:drain(64)` returns
  them in timestamp order plus stats (`queued`, `dropped_moves`, `high_watermark`).
  `timestamp_us` is a **decimal string** (always, for a stable type): the capture clock
  is a full 64-bit microsecond value that overflows a 32-bit Lua integer after ~35 min
  of uptime, so it is carried opaquely as a string and never passed through `tonumber`.
  While a stream owns the handle, `poll`/`sync` return `nil, "lcd_touch: stream active"`.
- `audio.sample_mixer({output, max_voices=6, queue_depth=32})` -- a six-voice native PCM
  mixer with `load_note(midi, path)`, `start`, `pluck{string,midi,velocity,timestamp_us}`,
  `poll`, and `close`. `pluck` accepts `timestamp_us` either as that exact decimal string
  or as a plain number (simulator/test values) and parses it back to an exact int64 for
  the capture-to-render latency metric. It owns one audio task and renders 128-frame
  (8 ms) blocks at 16 kHz with no allocation in its render loop, pacing each block to an
  absolute deadline with a high-resolution timer wait (never a busy-spin) that is
  independent of the codec write duration.

### Loudness

Three gains sit between a touch and the speaker, and only the middle one is where it
looks:

- The `volume` field of `audio.open_output`'s descriptor is recorded by the firmware and
  never pushed to the mixer, so it changes nothing on its own. The instrument therefore
  calls `output:set_volume(100)` after opening. That level belongs to the *shared*
  mixer, i.e. the whole device, so the level in effect beforehand is read with
  `output:get_volume()` and written back when the output closes. Firmware without either
  method just keeps the system volume.
- Pluck velocity starts at a 0.6 floor (`guitar_logic.pluck_velocity`) rather than
  something quiet, because a tap carries no horizontal travel and the sample bank cannot
  be made louder further down the chain. One fast swipe still reaches 1.0, so strum
  dynamics survive.
- The sample bank is peak-normalised to 95% of full scale by
  `tools/normalize_steel_samples.py`, which keeps the pristine originals in
  `.asset-originals/` (outside the skill, so they are never uploaded) and always reads
  from there, so the target can be revised without compounding gain. As recorded the
  bank spanned 30-89% FS with a constant ~17 dB crest factor, i.e. the high notes were
  simply ~10 dB quieter rather than different in character, so normalising evened the
  strings out as well as raising them.

Normalising costs polyphony headroom, and the bank had none to give. The mixer sums its
six voices and then saturates once, with no limiter, and a fast swipe crosses all six
strings inside a single touch event, so the six notes carry one timestamp and start in
the same render block. That worst case already clipped before normalisation (the Em
voicing peaked at 227% of full scale, 393 clamped frames at velocity 1.0) and now peaks
at 340%, or 1104 clamped frames -- audible as a harder, grittier attack on a full strum,
while any single note stays clean. Run
`python tools/normalize_steel_samples.py --dry-run --target <pct>` to measure a
different target: the report covers all six voicings. Removing the distortion rather
than trading it for level needs a master gain plus a soft limiter in
`audio_sample_mixer_core.c`, which is firmware work.

### Acceptance thresholds

On device, ten consecutive full-width swipes must each trigger all six strings in order
with `dropped_moves=0`, `dropped_commands=0`, and `max_capture_to_render_us<=20000`
(20 ms internal capture-to-render, leaving margin for codec/DMA latency). Measured
touch-to-audible onset must be at most 30 ms. Six strings must ring together, same-string
taps must replace rather than stack, the chord must stay latched after release, the UI
must stay responsive while six strings ring, no idle hiss may remain after the mute hold,
and GPIO7 must exit cleanly. A slow upward swipe starting at the bottom edge must play the
strings it crosses and must **not** exit.

### Rollback and display fallback

Both firmware APIs are additive extensions, but this shipped Skill is **native only**:
the scripts drive `lcd_touch.new_stream` and `audio.sample_mixer` directly and there is
**no automatic `lcd_touch.poll` fallback** built into them. On firmware that lacks
`lcd_touch.new_stream`, touch input does not silently degrade to polling -- `touch_adapter`
resolves to the hosted simulator source only when no real touch handle exists, and
otherwise the instrument has no usable touch backend. Rolling back to the previous
`lcd_touch.poll` + Lua-sample instrument therefore requires **restoring the previous
scripts**; it is not something the current firmware can do on its own.

The `exit_gesture = false` display option degrades harmlessly: firmware that does not
know it ignores the options table, so the instrument still runs but keeps the shell's
bottom-edge exit swipe, and a low strum can quit it.

The audio path is different and does degrade in place: when `audio.sample_mixer` is
missing or any link of the audio chain refuses the descriptor, the entry catches it and
runs as a fully playable **silent** instrument with a `MUTED` badge (see *Audio
behavior*). A codec write failure reported by `mixer:poll` flips the same badge to
`MUTED` without taking the UI down. That MUTED audio degradation is automatic; the touch
rollback above is not.

Runtime repaints are minimal partial frames (`begin_frame({clear=false})`); if a device
cannot preserve the prior frame for partial drawing, the fallback is a rate-limited full
redraw after audio dispatch -- visual feedback may be slower, but captured touch events
and audio commands are never delayed.
