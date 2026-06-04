---
{
  "name": "dino",
  "description": "Run a Chrome offline-style Dino jumping runner on the board LCD. Use when the user asks for Dino, dinosaur game, runner game, jump game, LCD touch game, or GPIO button game.",
  "author": "ESP-Claw contributor",
  "metadata": {
    "category": ["game"],
    "tags": ["dino", "touch", "button", "gpio", "runner"],
    "peripherals": ["display"],
    "cap_groups": ["cap_lua"],
    "manage_mode": "web"
  }
}
---

# Dino

Use this skill when the user asks for Dino, Chrome offline dinosaur game,
a jumping runner game, or a generic LCD touch/button game demo on the board.

The Lua script renders a Chrome offline-style runner on the LCD with a pixel
Dino, clouds, ground, cactus obstacles, score, jump input, and restart on game
over.

## Requirements

- A display device declared as `display_lcd` in board hardware info.
- LCD touch input, or a GPIO button passed through `button_gpio`.

If no input source is available, the script prints an error and exits.

## Tool Call Inputs

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/dino.lua",
  "args": {}
}
```

Pass an empty `args` object for the default grayscale Dino. Common optional
args: `run_ms`, `input_mode`, `button_gpio`, `preset`, `color`, and `scale`.

## Behavior

Press touch or the configured button to jump; after game over, press again to
restart. The script renders continuously until `run_ms` expires or the runtime
stops it. On startup or runtime failure, report the `[dino] ERROR: ...` line
directly to the user and do not retry with changed arguments.
