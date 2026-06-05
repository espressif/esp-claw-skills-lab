---
{
  "name": "balance_ball",
  "description": "Play an IMU tilt-controlled balance ball game on the board LCD. Tilt the board to roll the ball into the target circle and hold to score. Requires display and IMU (BMI270).",
  "author": "ESP-Claw contributor",
  "metadata": {
    "cap_groups": ["cap_lua"],
    "manage_mode": "web",
    "category": ["game"],
    "peripherals": ["display"],
    "tags": ["imu", "ball", "tilt", "balance"]
  }
}
---

# Balance Ball

Use this skill when the user asks to play a balance ball game, tilt game, IMU
game, ball-rolling game, or balance board game on the board.

The Lua script renders a physics-based ball game on the LCD with a ball, target
circle, trail, score bar, and hold progress indicator. Tilt the board to roll
the ball into the target and hold to score. Each score shrinks the next target.

## Requirements

- A display device declared as `display_lcd` in board hardware info.
- An IMU device available to the Lua `imu` module.

If the display or IMU fails to initialize, the script prints an error and exits.

## Tool Call Inputs

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/balance_ball.lua",
  "args": {}
}
```

Pass an empty `args` object for default physics and 55-second duration. Common
optional args: `run_ms`, `ball_r`, `target_r`, `accel_k`, `friction`,
`hold_frames`, `invert_x`, `invert_y`, and `swap_xy`.

## Behavior

Tilt the board to accelerate the ball toward the target. When the ball stays
inside the target, a hold bar fills up; once full, you score a point and a new
smaller target appears. The script runs until `run_ms` expires or the runtime
stops it. On startup or runtime failure, report the `[ball] ...` error line
directly to the user and do not retry with changed arguments.
