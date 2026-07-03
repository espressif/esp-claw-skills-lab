---
{
  "name": "flappybird",
  "description": "Run a Flappy Bird mini-game on the board LCD. Prefer LCD touch; otherwise use a GPIO button. Optional audio on audio_dac.",
  "author": "ESP-Claw contributor",
  "metadata": {
    "category": ["game", "ui"],
    "tags": ["flappybird", "arcade", "demo", "button", "touch"],
    "peripherals": ["display"],
    "cap_groups": ["cap_lua"],
    "manage_mode": "web"
  }
}
---

# Flappy Bird

Use this skill when the user asks to play a game, run Flappy Bird, start a
bird game, or launch an interactive game demo on the board.

The Lua script renders the bird, pipes, and score on the LCD and reads input
events to make the bird flap.

## Requirements

- A display device declared as `display_lcd` in board hardware info.
- LCD touch is preferred; if it is not available the script falls back to a
  physical button on `pin` / `button_gpio`.
- Audio output is optional and used only for sound effects.

## Tool Call Inputs

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/flappybird.lua",
  "args": {}
}
```

Pass an empty `args` object for defaults (touch if available, otherwise
`button_gpio=0`, board audio sample rate, `run_time_ms=180000`).

Common optional args:

| Arg | Default | Meaning |
|-----|---------|---------|
| `pin` / `button_gpio` | `0` | GPIO for flap button when touch is unavailable |
| `active_level` | `0` | Active level for the button (0 = active low) |
| `sample_rate_hz` | board `audio_dac` rate | Output sample rate; use `8000` for USB UAC breadboard speakers |
| `run_time_ms` | `180000` | Game duration in milliseconds |

### esp32_S3_DevKitC_1 breadboard example

External tact button on GPIO48, USB UAC speaker at 8 kHz:

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/flappybird.lua",
  "args": {
    "pin": 48,
    "active_level": 0,
    "sample_rate_hz": 8000,
    "run_time_ms": 180000
  }
}
```

Run asynchronously with `timeout_ms` greater than `run_time_ms`, for example
`200000`.

## Behavior

Each tap or button press makes the bird flap upward. Hitting a pipe or the
ground ends the round. The game loop runs until `run_time_ms` expires or the
runtime stops it. On startup or runtime failure, report the `[lappybird] ...`
error line directly to the user and do not retry with changed arguments unless
the user asks.

## Files

- `scripts/flappybird.lua`
