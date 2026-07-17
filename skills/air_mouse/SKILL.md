---
{
  "name": "air_mouse",
  "description": "Turn the board into a BLE air mouse: tilt/point to move the cursor, tap the LCD for left/right click and scroll. Requires BMI270 IMU, BLE HID, and display touch.",
  "author": "ESP-Claw contributor",
  "metadata": {
    "cap_groups": ["cap_lua"],
    "manage_mode": "web",
    "category": ["hardware", "utility"],
    "peripherals": ["display"],
    "tags": ["ble", "hid", "imu", "mouse", "airmouse"]
  }
}
---

# Airmouse

Use this skill when the user asks to start an air mouse, IMU mouse, or pointer
control from device motion. The script reads BMI270 samples through `imu`,
runs quaternion pose mapping, and sends relative mouse reports through `ble_hid`.

On the LCD, the screen is split horizontally:
- **Top half** press/hold → mouse **right** button down until release
- **Bottom half** press/hold → mouse **left** button down until release
- **Mid strip** (divider) → scroll wheel: swipe **left** = wheel up, swipe **right** = wheel down

Quick double-taps on left/right zones are timed for host double-click (HID down/up
before UI redraw).

A trackball-style icon (from the provided SVG) is drawn near the center; LEFT/RIGHT
labels sit on the left side of the screen (rotated 90° CCW).

## Start Airmouse (async, long-running)

Prefer async so the loop keeps running until cancelled:

```json
{"path":"{CUR_SKILL_DIR}/scripts/start_air_mouse.lua","args":{"name":"esp-claw-airmouse"},"timeout_ms":0,"name":"air_mouse"}
```

Use `lua_run_script_async` (or router `run_script` with `"async": true`).
`timeout_ms: 0` means run until cancelled.

## Script Args Schema

```json
{
  "type": "object",
  "properties": {
    "name": {
      "type": "string",
      "default": "esp-claw-airmouse",
      "description": "BLE HID advertised name (max 29 bytes)"
    },
    "interval_ms": {
      "type": "integer",
      "default": 10,
      "minimum": 1,
      "description": "IMU poll period in milliseconds"
    },
    "gain": {
      "type": "number",
      "default": 20,
      "description": "Cursor sensitivity gain applied to UV deltas"
    },
    "dead_x": {
      "type": "number",
      "default": 0.05,
      "description": "UV deadzone on X"
    },
    "dead_y": {
      "type": "number",
      "default": 0.05,
      "description": "UV deadzone on Y"
    },
    "max_dx": {
      "type": "integer",
      "default": 20,
      "minimum": 1,
      "maximum": 127
    },
    "max_dy": {
      "type": "integer",
      "default": 20,
      "minimum": 1,
      "maximum": 127
    }
  }
}
```

## Recommended Flow

1. Start the script async with the schema above.
2. Pair the host with the advertised BLE HID name.
3. After `connected`, tilt/point the device to move the cursor.
4. Short-tap LCD top/bottom for right/left click (double-tap supported); hold/drag
   for press-and-hold. Swipe on the mid divider: left = scroll up, right = scroll down.
5. Stop with `lua_stop_job` using job name `air_mouse` when finished.
