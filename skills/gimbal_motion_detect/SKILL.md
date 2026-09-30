---
{
  "name": "gimbal_motion_detect",
  "description": "Use the camera and motion_detect Lua module to show a live LCD preview and draw a bounding box around detected motion.",
  "metadata": {
    "cap_groups": [
      "cap_lua"
    ],
    "category": [
      "utility"
    ],
    "peripherals": ["camera", "display"],
    "tags": ["vision", "motion-detect", "gimbal", "lcd"]
  }
}
---

# Gimbal Motion Detect

Use this skill when the user wants `esp-claw` to show the camera preview on the
LCD and draw a bounding box around moving regions. The script opens the board
camera, converts frames to RGB565, displays the same centered preview style used
by `gimbal_color_detect`, and runs the standalone `motion_detect` Lua module.

Preview display crops a centered `240x240` square from the board-default camera
stream and draws it centered on the `284x240` LCD without additional flipping.

## Default Hardware

- Discover the camera with `camera.list_devices()` and open its first device.
- Open the built-in display with `display.open()`.
- A single async Lua job owns camera, preview, and motion detection.
- Each preview uses `screen:begin()`, `screen:image()`, and `screen:present({ full = true })`.
- If camera discovery or opening fails, report the actual error.

## Start Script Args Schema

```json
{
  "type": "object",
  "properties": {
    "run_seconds": {
      "type": "integer",
      "default": 0,
      "description": "0 means run until the async Lua job receives a cooperative stop request."
    },
    "capture_timeout_ms": {
      "type": "integer",
      "default": 500,
      "description": "Camera frame wait timeout. Keep this short enough that stop requests can reach cleanup quickly."
    },
    "frame_interval_ms": {
      "type": "integer",
      "default": 0,
      "description": "Extra delay after each frame. Keep 0 for maximum camera/display throughput."
    },
    "display_every_n": {
      "type": "integer",
      "default": 1
    },
    "perf_log_every_n": {
      "type": "integer",
      "default": 30,
      "description": "Print average get/convert/detect/display/loop timing every N frames. Set 0 to disable."
    },
    "display_crop_size": {
      "type": "integer",
      "default": 240,
      "description": "Centered square crop size before drawing to the LCD."
    },
    "pixel_diff_threshold": {
      "type": "integer",
      "default": 24,
      "description": "Per-pixel luma difference threshold."
    },
    "active_pixel_percent": {
      "type": "integer",
      "default": 5,
      "description": "Minimum active-pixel percentage inside the ROI required for raw motion."
    },
    "confirm_frames": {
      "type": "integer",
      "default": 2
    },
    "hold_frames": {
      "type": "integer",
      "default": 3
    },
    "block_size": {
      "type": "integer",
      "default": 4
    },
    "block_hit_pixels": {
      "type": "integer",
      "default": 15
    },
    "box_padding": {
      "type": "integer",
      "default": 2
    },
    "box_deadband": {
      "type": "integer",
      "default": 2
    },
    "box_snap_threshold": {
      "type": "integer",
      "default": 24
    }
  }
}
```

## Tool Call Inputs

Start motion tracking:

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/start_gimbal_motion_detect.lua",
  "args": {},
  "timeout_ms": 0,
  "name": "gimbal_motion_detect",
  "exclusive": "gimbal_motion_detect",
  "replace": false
}
```

Stop motion tracking:

```json
{
  "name": "gimbal_motion_detect",
  "wait_ms": 2000
}
```

Stop requests are handled by the Lua job executor. The script keeps the camera
capture timeout short so stop can interrupt promptly, then runs camera,
display, and detector cleanup from the script exit path.

## Recommended Flow

1. Activate `gimbal_motion_detect`.
2. Run `{CUR_SKILL_DIR}/scripts/start_gimbal_motion_detect.lua` with `lua_run_script_async`.
3. Use `timeout_ms: 0`, `name: "gimbal_motion_detect"`, `exclusive: "gimbal_motion_detect"`, and `replace: true`.
4. Tune `pixel_diff_threshold`, `active_pixel_percent`, and `block_hit_pixels` for sensitivity.
