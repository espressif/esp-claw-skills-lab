---
{
  "name": "maze",
  "description": "Generate, draw, and solve animated mazes on the board display using local Lua computation. Use when the user asks to show, draw, generate, solve, or animate a maze.",
  "metadata": {
    "cap_groups": [
      "cap_lua"
    ],
    "manage_mode": "readonly",
    "category": ["utility"]
  }
}
---

# Maze

Use this skill when the user asks to show, draw, generate, solve, or animate a maze on the screen.

Run the bundled Lua script with `lua_run_script_async` for normal display use:

```json
{"path":"{CUR_SKILL_DIR}/scripts/draw_maze.lua","args":{},"name":"maze","exclusive":"display","replace":true,"log_bytes":2048}
```

The script computes each maze locally in Lua, plays the maze-generation animation, plays a solving animation from the fixed top-left entrance to the fixed bottom-right exit, holds for 5 seconds, then starts a new maze. It repeats until stopped or replaced by another display job.

If script execution returns an error, report that error directly to the user.

## Script Args Schema

```json
{
  "type": "object",
  "properties": {
    "columns": {
      "type": "integer",
      "default": 0,
      "minimum": 0,
      "maximum": 80
    },
    "rows": {
      "type": "integer",
      "default": 0,
      "minimum": 0,
      "maximum": 60
    },
    "step_size": {
      "type": "integer",
      "default": 3,
      "minimum": 1,
      "maximum": 128
    },
    "solve_step_size": {
      "type": "integer",
      "default": 1,
      "minimum": 1,
      "maximum": 128
    },
    "frame_delay_ms": {
      "type": "integer",
      "default": 35,
      "minimum": 0,
      "maximum": 2000
    },
    "solve_delay_ms": {
      "type": "integer",
      "default": 35,
      "minimum": 0,
      "maximum": 2000
    },
    "final_hold_ms": {
      "type": "integer",
      "default": 5000,
      "minimum": 0,
      "description": "How long to hold the completed maze before starting the next one. Use 0 with repeat_count 1 to hold a one-shot maze indefinitely."
    },
    "repeat_count": {
      "type": "integer",
      "default": 0,
      "minimum": 0,
      "description": "Number of mazes to generate. Use 0 for unlimited."
    },
    "seed": {
      "type": "integer",
      "default": 0,
      "description": "Use 0 to seed from local time."
    },
    "wall_color": {
      "type": "string",
      "default": "#ffffff"
    },
    "background": {
      "type": "string",
      "default": "#000000"
    },
    "solve_color": {
      "type": "string",
      "default": "#00ff00"
    }
  }
}
```

## Tool Call Inputs

Continuously generate mazes, solve each one, hold for 5 seconds, then start the next:

```json
{"path":"{CUR_SKILL_DIR}/scripts/draw_maze.lua","args":{},"name":"maze","exclusive":"display","replace":true,"log_bytes":2048}
```

Generate a larger maze with faster generation and solving:

```json
{"path":"{CUR_SKILL_DIR}/scripts/draw_maze.lua","args":{"columns":40,"rows":20,"step_size":8,"solve_step_size":3,"frame_delay_ms":20,"solve_delay_ms":20},"name":"maze","exclusive":"display","replace":true,"log_bytes":2048}
```

Generate one maze, animate generation and solving, then hold it on screen:

```json
{"path":"{CUR_SKILL_DIR}/scripts/draw_maze.lua","args":{"repeat_count":1,"final_hold_ms":0},"name":"maze","exclusive":"display","replace":true,"log_bytes":2048}
```

## Recommended Flow

1. Use `lua_run_script_async` with `name: "maze"`, `exclusive: "display"`, and `replace: true`.
2. Use default args unless the user asks for a specific size, speed, colors, seed, or continuous generation.
3. Leave `columns` and `rows` as `0` to size the maze from the current display. The default auto-size intentionally uses fewer cells so the walls and passages are easier to see. The script fixes the entrance at the left side of the top-left cell and the exit at the right side of the bottom-right cell.
4. Keep the default `repeat_count: 0` and `final_hold_ms: 5000` for continuous display. Use `repeat_count: 1` and `final_hold_ms: 0` only when the user asks for a one-shot maze that should remain visible until stopped or replaced.
5. Report the async job start result or script error directly to the user.
