---
{
  "name": "number_puzzle",
  "description": "Play a touch-controlled 15-puzzle number sliding game on the LCD with lightweight rendering, swipe controls, and pixel-style sound effects.",
  "author": "ESP-Claw contributor",
  "metadata": {
    "category": ["game", "ui"],
    "tags": ["15-puzzle", "number puzzle", "sliding puzzle", "touch", "animation", "sound"],
    "peripherals": ["display"],
    "cap_groups": ["cap_lua"],
    "manage_mode": "web"
  },
  "simulator": {
    "entry": "scripts/number_puzzle.lua",
    "files": [
      "scripts/number_puzzle.lua"
    ]
  }
}
---

# Number Puzzle

Use this skill when the user asks to play 数字华容道, number puzzle, 15-puzzle, sliding puzzle, or a tile ordering game.

The Lua script renders a 4x4 board with tiles 1-15 and one empty space. Tap a numbered tile next to the empty space, or swipe up/down/left/right to slide the matching adjacent tile into the empty space. The goal is to restore the board to 1-15 with the empty space at bottom right. Normal moves use partial refresh for the changed cells and header info.

## Requirements

- A display device declared as `display_lcd` in board hardware info.
- LCD touch input declared as `lcd_touch`.
- Audio output is optional and used for pixel-style move, blocked, shuffle, and win sound effects.

## Tool Call Inputs

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/number_puzzle.lua",
  "args": {}
}
```

Optional args:

| Arg | Default | Meaning |
|-----|---------|---------|
| `run_time_ms` | `600000` | Game duration in milliseconds |
| `sample_rate_hz` | board `audio_dac` rate | Output sample rate for sound effects |
| `target_size` | `480` | Square game stage size when screen space allows |
| `shuffle_steps` | `140` | Number of legal random moves used to create a solvable puzzle |
| `perf_log` | `1` | Set to `0` to disable timing logs for startup, touch handling, rendering, and actions |

## Behavior

Tap an adjacent tile to slide it into the empty space, or swipe in the direction the tile should move. For example, left swipe moves the tile on the right side of the empty space left into the empty space. The board is shuffled only through legal moves, so every puzzle is solvable. When solved, the script shows a completion panel with move count and elapsed time.

## Files

- `scripts/number_puzzle.lua`
