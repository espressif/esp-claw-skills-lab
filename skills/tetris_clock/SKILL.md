---
{
  "name": "tetris_clock",
  "description": "Show an animated Tetris-style clock on the board display using local time. Use when the user asks for Tetris Clock, falling block clock, or blocky animated time.",
  "metadata": {
    "cap_groups": [
      "cap_lua"
    ],
    "manage_mode": "readonly",
    "category": ["utility"]
  }
}
---

# Tetris Clock

Use this skill when the user asks to show a Tetris Clock, falling block clock, block clock, or animated time display on the screen.

Run the bundled Lua script with `lua_run_script_async` for normal display use:

```json
{"path":"{CUR_SKILL_DIR}/scripts/draw_tetris_clock.lua","args":{},"name":"tetris_clock","exclusive":"display","replace":true,"log_bytes":2048}
```

The script reads the local device time with the `system` Lua module, generates tetromino piece sequences using the original Tetris Clock timing model, applies the same per-digit drop offsets, 15-second frame count, movement probability, and movement-list randomness, draws the centered colon on the original 32-column clock grid, renders the date and AM/PM label with a tiny pixel font, and scales the logical pixel grid to the current screen size.

If script execution returns an error, report that error directly to the user.

## Script Args Schema

```json
{
  "type": "object",
  "properties": {
    "twenty_four_hour": {
      "type": "boolean",
      "default": true
    },
    "leading_zero": {
      "type": "boolean",
      "default": true
    },
    "show_date": {
      "type": "boolean",
      "default": true
    },
    "show_bar": {
      "type": "boolean",
      "default": true
    },
    "top_bar": {
      "type": "boolean",
      "default": false
    },
    "color_scheme": {
      "type": "string",
      "default": "standard_dark",
      "description": "Use standard_dark, standard_light, spring, summer, autumn, winter, monochrome_dark, or monochrome_light."
    },
    "brightness_percent": {
      "type": "integer",
      "default": 100,
      "minimum": 10,
      "maximum": 100
    },
    "frame_rate": {
      "type": "integer",
      "default": 10,
      "minimum": 4,
      "maximum": 30
    },
    "build_frames": {
      "type": "integer",
      "default": 60,
      "minimum": 16,
      "maximum": 220,
      "description": "Matches the original app digitlength value. It controls the movement-list length used to build each digit."
    },
    "movement_rate": {
      "type": "integer",
      "default": 13,
      "minimum": 0,
      "maximum": 100,
      "description": "Matches the original app movementrate value. Each generated movement step has this percent chance to try a horizontal move or rotation."
    },
    "duration_ms": {
      "type": "integer",
      "default": 0,
      "minimum": 0,
      "description": "How long to keep the clock running. Use 0 to continue until stopped or replaced."
    },
    "seed": {
      "type": "integer",
      "default": 0,
      "minimum": 0,
      "description": "Use 0 to seed from local time and uptime."
    }
  }
}
```

## Tool Call Inputs

Start the Tetris Clock with defaults:

```json
{"path":"{CUR_SKILL_DIR}/scripts/draw_tetris_clock.lua","args":{},"name":"tetris_clock","exclusive":"display","replace":true,"log_bytes":2048}
```

Use 12-hour time without a leading zero:

```json
{"path":"{CUR_SKILL_DIR}/scripts/draw_tetris_clock.lua","args":{"twenty_four_hour":false,"leading_zero":false},"name":"tetris_clock","exclusive":"display","replace":true,"log_bytes":2048}
```

Use a brighter seasonal palette:

```json
{"path":"{CUR_SKILL_DIR}/scripts/draw_tetris_clock.lua","args":{"color_scheme":"winter","brightness_percent":100},"name":"tetris_clock","exclusive":"display","replace":true,"log_bytes":2048}
```

## Recommended Flow

1. Use `lua_run_script_async` with `name: "tetris_clock"`, `exclusive: "display"`, and `replace: true`.
2. Use default args unless the user asks for 12-hour time, no leading zero, date display, a theme, brightness, animation speed, build speed, or movement rate.
3. Leave `duration_ms: 0` for a clock that should remain visible and rebuild every minute.
4. Report the async job start result or script error directly to the user.
