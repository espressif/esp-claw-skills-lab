---
{
  "name": "snake",
  "description": "Show a continuous automatic Snake game animation on the board display. Use when the user asks to play, show, draw, or animate Snake on screen.",
  "metadata": {
    "cap_groups": [
      "cap_lua"
    ],
    "manage_mode": "readonly"
  }
}
---

# Snake

Use this skill when the user asks to play, show, draw, or animate Snake on the screen.

Run the bundled Lua script with `lua_run_script_async` for normal display use:

```json
{"path":"{CUR_SKILL_DIR}/scripts/draw_snake.lua","args":{},"name":"snake","exclusive":"display","replace":true,"log_bytes":2048}
```

The script recreates the original Snake app as a local Lua display animation with these rules:

- The snake starts at a fixed length of 6.
- Each food eaten grows the snake by exactly 1 segment.
- If the head bites the tail, the bitten segment and all tail segments after it are removed.
- After eating, the consumed cell remains visible as the head for a complete frame before the next food appears.
- The game runs continuously until stopped, replaced, or an explicit `duration_ms` is provided.
- The logical snake board is fixed at 16 x 16 cells. It is scaled to the screen, so a 480 x 480 screen shows each segment as 30 x 30 pixels.
- Edge wrapping is enabled, and it only happens when the head steps past the logical board boundary.
- Eating or biting never happens on the same movement as an edge wrap. After an event on an edge cell, the snake leaves that edge before wrapping is allowed again.

If script execution returns an error, report that error directly to the user.

## Script Args Schema

```json
{
  "type": "object",
  "properties": {
    "frame_delay_ms": {
      "type": "integer",
      "default": 140,
      "minimum": 40,
      "maximum": 2000
    },
    "duration_ms": {
      "type": "integer",
      "default": 0,
      "minimum": 0,
      "description": "How long to run. Use 0 to continue until stopped or replaced."
    },
    "cell_size": {
      "type": "integer",
      "default": 0,
      "minimum": 0,
      "description": "Display pixel size for one snake segment. Use 0 to scale the fixed 16 x 16 board to the screen."
    },
    "wrap_edges": {
      "type": "boolean",
      "default": true,
      "description": "Whether the snake appears on the opposite side after crossing the board edge."
    },
    "seed": {
      "type": "integer",
      "default": 0,
      "minimum": 0,
      "description": "Use 0 to seed from local time."
    },
    "background": {
      "type": "string",
      "default": "#000000"
    },
    "snake_color": {
      "type": "string",
      "default": "#ffffff"
    },
    "head_color": {
      "type": "string",
      "default": "#ff8f00"
    },
    "food_color": {
      "type": "string",
      "default": "#00ff00"
    }
  }
}
```

## Tool Call Inputs

Start Snake with defaults:

```json
{"path":"{CUR_SKILL_DIR}/scripts/draw_snake.lua","args":{},"name":"snake","exclusive":"display","replace":true,"log_bytes":2048}
```

Run Snake for one minute:

```json
{"path":"{CUR_SKILL_DIR}/scripts/draw_snake.lua","args":{"duration_ms":60000},"name":"snake","exclusive":"display","replace":true,"log_bytes":2048}
```

Override the cell size:

```json
{"path":"{CUR_SKILL_DIR}/scripts/draw_snake.lua","args":{"cell_size":30},"name":"snake","exclusive":"display","replace":true,"log_bytes":2048}
```

## Recommended Flow

1. Use `lua_run_script_async` with `name: "snake"`, `exclusive: "display"`, and `replace: true`.
2. Use default args unless the user asks for a speed, duration, seed, color, or explicit cell size.
3. Leave `duration_ms` as `0` for a Snake animation that keeps running until stopped or replaced.
4. Report the async job start result or script error directly to the user.
