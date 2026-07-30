---
{
  "name": "gimbal_color_detect",
  "description": "Use the camera and ESP-DL-backed color_detect Lua module to identify a target object's color, track that color, show the camera preview on the LCD, draw a bounding box, and drive X/Y gimbal servos toward the target center.",
  "metadata": {
    "cap_groups": [
      "cap_lua"
    ],
    "manage_mode": "readonly",
    "category": [
      "utility"
    ],
    "peripherals": [],
    "tags": [
      "camera",
      "vision",
      "color-detect",
      "gimbal",
      "servo",
      "lcd"
    ]
  }
}
---

# Gimbal Color Detect

Use this skill when the user wants `esp-claw` to use the camera as a visual
servo target tracker.

## Visible Object Rule

If the user asks to track "this object", "the object in front", "the thing in
front", "这个物体", "前面这个东西", or any other visible object without naming a
specific color, you MUST NOT start color tracking directly and MUST NOT fall
back to the default green preset. First use the `take_picture` skill to capture
the object, inspect the saved photo with AI vision, identify the intended
foreground object's dominant visible color, tell the user the recognized color,
and only then start this color tracking script with the recognized color.

If the recognized color is one of the built-in presets, pass only
`target_color_name`. If it is not a preset, ask AI vision to return an HSV range
and pass `target_h_min`, `target_h_max`, `target_s_min`, `target_s_max`,
`target_v_min`, and `target_v_max`.

The built-in `green` preset is used only when the user gives no color and also
does not refer to a specific visible object. HSV thresholds match ESP-DL:
hue uses `0..180`, saturation uses `0..255`, and value uses `0..255`.
If `target_h_min > target_h_max`, the
script treats the hue range as wrapping through 0, which is useful for red
targets.

Preview display follows the `esp-hello-new/examples/gimbal_base` camera path by
default: crop a centered `240x240` square from the board-default camera stream,
and draw it centered on the `284x240` LCD. Detection runs on that same centered
crop so off-screen colors do not affect the tracked box. Each display frame
uses `display.begin_frame({ clear = false, preserve = false })`, draws the image
first, draws the detection rectangle as a separate display primitive, then calls
`display.present_full()` and `display.end_frame({ wait = false })` so
double-buffered panels can refresh asynchronously.

## Default Hardware

- Camera device: from `board_manager.get_camera_paths()`
- Camera stream: board default mode from `camera.open(dev_path)`
- LCD panel: from `board_manager.get_display_lcd_params("display_lcd")`
- X servo GPIO: `4`
- Y servo GPIO: `5`
- PWM driver: `ledc`, `50 Hz`, `500 us .. 2500 us`
- X angle range: `0 .. 180`, initial `90`
- Y angle range: `10 .. 70`, initial `50`
- Runtime shape: a single async Lua job owns camera, LCD, color detection, and X/Y LEDC servos.

## Start Script Args Schema

```json
{
  "type": "object",
  "properties": {
    "run_seconds": {
      "type": "integer",
      "default": 0,
      "description": "0 means run until the async Lua job is stopped."
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
      "default": 10,
      "description": "Print average get/convert/detect/display/loop timing every N frames. Set 0 to disable."
    },
    "display_crop_size": {
      "type": "integer",
      "default": 240,
      "description": "Centered square crop size before drawing to the LCD."
    },
    "detect_stride": {
      "type": "integer",
      "default": 4,
      "description": "Kept for compatibility. ESP-DL color detection evaluates the HSV mask for the selected source crop."
    },
    "detect_min_pixels": {
      "type": "integer",
      "default": 250,
      "description": "Minimum connected-component size, matching the ESP-DL gimbal_base detector scale."
    },
    "detect_max_blob_percent": {
      "type": "integer",
      "default": 35,
      "description": "Reject connected components larger than this percentage of the display crop."
    },
    "target_color_name": {
      "type": "string",
      "default": "green",
      "description": "Registered target color name. Built-in presets: red, orange, yellow, green, cyan, blue, purple."
    },
    "target_h_min": {
      "type": "integer",
      "description": "Custom registered target hue lower bound, 0..180. Required only when target_color_name is not a built-in preset."
    },
    "target_h_max": {
      "type": "integer",
      "description": "Custom registered target hue upper bound, 0..180. Values lower than target_h_min wrap through 0."
    },
    "target_s_min": {
      "type": "integer",
      "description": "Custom registered target saturation lower bound, 0..255."
    },
    "target_s_max": {
      "type": "integer",
      "description": "Custom registered target saturation upper bound, 0..255."
    },
    "target_v_min": {
      "type": "integer",
      "description": "Custom registered target value lower bound, 0..255."
    },
    "target_v_max": {
      "type": "integer",
      "description": "Custom registered target value upper bound, 0..255."
    },
    "deadzone_px": {
      "type": "integer",
      "default": 12
    },
    "x_gain": {
      "type": "number",
      "default": 0.035
    },
    "y_gain": {
      "type": "number",
      "default": 0.035
    },
    "max_track_step_degrees": {
      "type": "number",
      "default": 2
    },
    "x_gpio": {
      "type": "integer",
      "default": 4
    },
    "y_gpio": {
      "type": "integer",
      "default": 5
    },
    "servo_max_step_degrees": {
      "type": "number",
      "default": 2
    }
  }
}
```

## Tool Call Inputs

Start color tracking:

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/start_gimbal_color_detect.lua",
  "args": {},
  "timeout_ms": 0,
  "name": "gimbal_color_detect",
  "exclusive": "gimbal_color_detect",
  "replace": true
}
```

Start tracking a built-in blue preset:

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/start_gimbal_color_detect.lua",
  "args": {
    "target_color_name": "blue"
  },
  "timeout_ms": 0,
  "name": "gimbal_color_detect",
  "exclusive": "gimbal_color_detect",
  "replace": true
}
```

Start tracking a custom AI-returned color:

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/start_gimbal_color_detect.lua",
  "args": {
    "target_color_name": "custom teal",
    "target_h_min": 78,
    "target_h_max": 92,
    "target_s_min": 64,
    "target_s_max": 255,
    "target_v_min": 46,
    "target_v_max": 255
  },
  "timeout_ms": 0,
  "name": "gimbal_color_detect",
  "exclusive": "gimbal_color_detect",
  "replace": true
}
```

Required first call when the user says "track this object" / "追踪这个物体":
activate the `take_picture` skill and run its script with that skill's own
`{CUR_SKILL_DIR}`.

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/take_picture.lua",
  "args": {
    "filename": "gimbal_target.jpg",
    "skip_frames": 3
  },
  "timeout_ms": 10000
}
```

After this call returns the saved JPEG path, inspect that image with AI vision.
Then start `start_gimbal_color_detect.lua` using the recognized preset color or
custom HSV range. Do not skip the photo and do not start with empty `args` for a
visible-object request.

Stop color tracking:

```json
{
  "name": "gimbal_color_detect",
  "wait_ms": 2000
}
```

## Recommended Flow

1. Activate `board_hardware_info` first when the user wants pin validation.
2. If the user refers to a visible object instead of naming a color, run the `take_picture` skill first. Use a simple filename such as `gimbal_target.jpg`.
3. Inspect the saved photo with AI vision and identify the intended foreground object's dominant visible color.
4. Tell the user the recognized color before starting tracking.
5. If the recognized color is one of `red`, `orange`, `yellow`, `green`, `cyan`, `blue`, or `purple`, register it by passing only `target_color_name`.
6. If the recognized color is not one of those presets, ask AI vision for a practical HSV range and register it with `target_color_name` plus `target_h_min`, `target_h_max`, `target_s_min`, `target_s_max`, `target_v_min`, and `target_v_max`.
7. If the user gives no color and does not refer to a specific visible object, run the tracker with no color args; it defaults to the built-in `green` preset.
8. Run the tracking script with `lua_run_script_async`.
9. Use `timeout_ms: 0`, `name: "gimbal_color_detect"`, `exclusive: "gimbal_color_detect"`, and `replace: true`.
10. Tune `x_gain` / `y_gain` signs if servo direction is reversed on a specific mount.

## Color Registration Hints

The script has built-in presets for these colors. When AI identifies one of
these names, pass only `target_color_name`; do not pass HSV values unless you
need to override the preset for local lighting. For red, the preset uses a hue
range that wraps through 0. Chinese names `红色`, `橙色`, `黄色`, `绿色`,
`青色`, `蓝色`, and `紫色` are accepted as aliases.

| Color | `target_h_min` | `target_h_max` | Notes |
|---|---:|---:|---|
| red | 170 | 10 | Wraps through 0 |
| orange | 8 | 24 | Often needs higher `target_s_min` |
| yellow | 22 | 40 | Sensitive to warm lighting |
| green | 50 | 88 | Default when no color is specified |
| cyan | 82 | 100 | Narrow if blue objects also appear |
| blue | 95 | 130 | Use lower `target_v_min` for dark blue |
| purple | 128 | 158 | Includes violet/magenta edge |
