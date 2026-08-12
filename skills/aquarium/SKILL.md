---
{
  "name": "aquarium",
  "description": "Draw and animate a digital aquarium on the board display by decoding PNG assets from the original Aquarium app into RAM for each scene. Use when the user asks to show, draw, generate, or animate an aquarium, fish tank, fish, or underwater scene.",
  "metadata": {
    "cap_groups": [
      "cap_lua"
    ],
    "manage_mode": "readonly",
    "category": ["utility"]
  }
}
---

# Aquarium

Use this skill when the user asks to show, draw, generate, or animate an aquarium, fish tank, fish, or underwater scene on the screen.

Run the bundled Lua script with `lua_run_script_async` for normal display use:

```json
{"path":"{CUR_SKILL_DIR}/scripts/draw_aquarium.lua","args":{},"name":"aquarium","exclusive":"display","replace":true,"log_bytes":2048}
```

The script decodes only the PNG assets needed for the current scene, converts them to RGB565 row spans in RAM, draws each frame with the `display` module, and releases the cached scene images when the scene ends.

If script execution returns an error, report that error directly to the user.

## Script Args Schema

```json
{
  "type": "object",
  "properties": {
    "water_color": {
      "type": "string",
      "default": "random",
      "description": "Use random, aqua, deep_blue, aquamarine, light_blue, very_dark_blue, dark_turquoise, turquoise, or a display color such as #0099cc."
    },
    "include_diver": {
      "type": "boolean",
      "default": true
    },
    "fish_count": {
      "type": "integer",
      "default": 6,
      "minimum": 3,
      "maximum": 6
    },
    "frame_delay_ms": {
      "type": "integer",
      "default": 50,
      "minimum": 20,
      "maximum": 2000
    },
    "duration_ms": {
      "type": "integer",
      "default": 0,
      "minimum": 0,
      "description": "How long to animate. Use 0 to continue until stopped or replaced."
    },
    "seed": {
      "type": "integer",
      "default": 0,
      "description": "Use 0 to seed from local time."
    }
  }
}
```

## Tool Call Inputs

Start the aquarium animation with defaults:

```json
{"path":"{CUR_SKILL_DIR}/scripts/draw_aquarium.lua","args":{},"name":"aquarium","exclusive":"display","replace":true,"log_bytes":2048}
```

Use a fixed water color:

```json
{"path":"{CUR_SKILL_DIR}/scripts/draw_aquarium.lua","args":{"water_color":"deep_blue"},"name":"aquarium","exclusive":"display","replace":true,"log_bytes":2048}
```

Run for one minute:

```json
{"path":"{CUR_SKILL_DIR}/scripts/draw_aquarium.lua","args":{"duration_ms":60000},"name":"aquarium","exclusive":"display","replace":true,"log_bytes":2048}
```

## Recommended Flow

1. Use `lua_run_script_async` with `name: "aquarium"`, `exclusive: "display"`, and `replace: true`.
2. Use default args unless the user asks for a specific water color, fish count, duration, or seed.
3. Use `duration_ms: 0` for a continuous aquarium that should remain visible until stopped or replaced.
4. Report the async job start result or script error directly to the user.
