---
{
  "name": "snake_game",
  "description": "Play a touch-swipe Snake game with a responsive blue-white cyber interface, data-link boot animation, evolving color trail, and sound effects.",
  "author": "ESP-Claw contributor",
  "metadata": {
    "category": ["game", "ui"],
    "tags": ["snake", "arcade", "touch", "swipe", "cyber", "sound"],
    "peripherals": ["display"],
    "cap_groups": ["cap_lua"],
    "manage_mode": "web"
  },
  "simulator": {
    "entry": "scripts/snake_game.lua",
    "files": [
      "scripts/snake_game.lua"
    ]
  }
}
---

# Snake Game

Use this skill when the user asks to play Snake, 贪吃蛇, a touch-swipe arcade game, or a classic growing snake game.

The Lua script renders a responsive 15x15 blue-white cyber board on the LCD. A short system-link animation leads to the ready screen; the first swipe launches a falling data-cursor sequence before the grid deploys. Swipe to steer, tap the HUD pause button to pause or resume, and eat food to unlock additional trail colors. The game ends when the snake hits a wall or itself.

## Requirements

- A display device declared as `display_lcd` in board hardware info.
- LCD touch input declared as `lcd_touch`.
- Audio output is optional and used for pixel-style start, food, turn, and crash sound effects.

## Tool Call Inputs

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/snake_game.lua",
  "args": {}
}
```

Optional args:

| Arg | Default | Meaning |
|-----|---------|---------|
| `run_time_ms` | `180000` | Game duration in milliseconds |
| `sample_rate_hz` | board `audio_dac` rate | Output sample rate for sound effects |
| `target_size` | `480` | Square game stage size when screen space allows |
| `grid_size` | `15` | Snake grid width and height |

## Behavior

The snake waits for the first swipe before deploying the board and moving. Swipe to change direction while playing. Tap PAUSE or RESUME in the HUD to control the game state. The snake grows after eating food and speeds up every few points. After game over, one swipe restarts the game in the selected direction.

## Files

- `scripts/snake_game.lua`
