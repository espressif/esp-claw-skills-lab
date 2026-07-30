---
{
  "name": "game_2048",
  "description": "Play a touch-swipe 2048 puzzle game on the LCD with sliding tile animation and pixel-style sound effects.",
  "author": "ESP-Claw contributor",
  "metadata": {
    "category": ["game", "ui"],
    "tags": ["2048", "puzzle", "touch", "slide", "pixel", "sound"],
    "peripherals": ["display"],
    "cap_groups": ["cap_lua"],
    "manage_mode": "web"
  },
  "simulator": {
    "entry": "scripts/game_2048.lua",
    "files": [
      "scripts/game_2048.lua"
    ]
  }
}
---

# Game_ 2048

Use this skill when the user asks to play 2048, a sliding number puzzle, or a touch-swipe LCD game.

The Lua script renders a 480x480-centered 2048 board when enough screen space is available. Swipe up, down, left, or right on the LCD to move tiles. Matching tiles merge, score increases, and the game ends when no moves remain.

## Requirements

- A display device declared as `display_lcd` in board hardware info.
- LCD touch input declared as `lcd_touch`.
- Audio output is optional and used for pixel-style move, merge, new-game, and game-over sound effects.

## Tool Call Inputs

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/game_2048.lua",
  "args": {}
}
```

Optional args:

| Arg | Default | Meaning |
|-----|---------|---------|
| `run_time_ms` | `180000` | Game duration in milliseconds |
| `sample_rate_hz` | board `audio_dac` rate | Output sample rate for sound effects |
| `target_size` | `480` | Square game stage size when screen space allows |

## Behavior

Swipe to move tiles. The script plays a short move tone after any valid slide and a brighter merge tone when a merge happens. On startup failure it prints a single `[game_2048] ERROR: ...` line which should be reported directly to the user.

## Files

- `scripts/game_2048.lua`
