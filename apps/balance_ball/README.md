# Balance Ball

Tilt the device to guide the ball into the target ring and hold it there to score. Tap the top-right X to return to the Launcher.

## Requirements

Requires a display and the board's `imu_sensor`. On devices without touch input, cancel the App through the runtime.

## Controls

Tilt the device to move the ball into the target ring. The bottom progress bar shows how long you have held it there. The top-right X returns to the Launcher; the adjacent button pauses or resumes play. Pausing preserves the ball's position, velocity, and score. Controls activate on release; dragging away cancels the action. On devices without touch input, cancel the App through the runtime.

The default axis settings are `invert_x=true`, `invert_y=false`, and `swap_xy=false`. The default acceleration factor is `accel_k=5.0`, and the velocity retained per frame is `friction=0.85`, providing responsive tilt control and reducing drift when the device is level. Adjust the axis settings for a different mounting orientation. Lower `friction` values slow the ball more quickly. Explicit launch options override these defaults.

## Installation and launch

Install the complete `balance_ball/` package under `apps/` in the device's DATA root, then publish it with `publish_app`. Resolve the DATA root through the device storage API rather than assuming `/fatfs`. Write scripts and assets first, then `launcher.json`. Tap the App in the device Launcher to start it.

`launcher.json` contains launch settings and an embedded `catalog` object for the site listing. This file provides usage instructions. The App does not need `SKILL.md`.

## Implementation

Uses `display.open()`, `screen:begin()/present()`, and `imu.new({ device = "imu_sensor" })/read()/close()`. Runs continuously by default and releases the display and IMU on exit or error.

## Launch options

Set options in `launcher.json.args`: `run_ms` (default 0, continuous operation), `frame_ms`, `lsb_per_g` (default 16384 for the Mosaico BMI270's ±2g range; use the actual range for other boards), `invert_x`, `invert_y`, `swap_xy`, `ball_r`, `target_r`, `accel_k`, `friction`, `bounce`, `max_speed`, and `hold_frames`. Numeric values must stay within the ranges declared in the script.
