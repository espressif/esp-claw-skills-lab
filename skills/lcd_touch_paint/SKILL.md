---
{
  "name": "lcd_touch_paint",
  "description": "A finger-drawing paint application on the on-board LCD touch panel. Use as a touch test, drawing demo, or LCD touch sanity check.",
  "author": "ESP-Claw contributor",
  "metadata":
    {
      "category": ["utility"],
      "tags": ["paint", "drawing", "touch", "demo"],
      "peripherals": ["display"],
      "cap_groups": ["cap_lua"],
      "manage_mode": "web"
    }
}
---

# LCD Touch Paint

Use this skill when the user asks for a drawing app, paint app, touch test,
LCD touch demo, or finger drawing on the board's display.

The Lua script uses the on-device `board_manager`, `display`, and `lcd_touch`
modules to initialize the panel and render strokes that follow the user's
finger. It clears and redraws each frame, so no persistent buffer is needed.

## Requirements

- A display device declared as `display_lcd` in board hardware info.
- An LCD touch device available on the board.

If either is missing the script prints an error and exits without retrying.

## Tool Call Inputs

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/lcd_touch_paint.lua",
  "args": {}
}
```

The script takes no arguments; pass an empty `args` object.

## Behavior

After launch the screen shows a blank canvas. Touching and dragging a finger
draws strokes in the configured ink color; releasing lifts the pen. The script
runs until it is stopped by the runtime. On startup or runtime failure it
prints a single `[lcd_touch_paint] ERROR: ...` line which should be reported
directly to the user.
