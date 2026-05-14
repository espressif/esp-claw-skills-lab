---
{
  "name": "flappybird",
  "description": "A Flappy Bird mini-game running on the on-board display. Controls fall back from LCD touch to a button if no touch is available.",
  "author": "ESP-Claw contributor",
  "metadata":
    {
      "category": ["game"],
      "tags": ["flappybird", "arcade", "demo"],
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
  physical button.
- Audio output is optional and used only for sound effects.

## Tool Call Inputs

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/flappybird.lua",
  "args": {}
}
```

The script takes no arguments; pass an empty `args` object.

## Behavior

Each tap or button press makes the bird flap upward. Hitting a pipe or the
ground ends the round. The game loop runs until the script is stopped. On
startup failure the script prints a single `[flappybird] ERROR: ...` line
which should be reported directly to the user.
