# Balance Challenge

Tilt your device to chase golden target rings with an aqua water drop. Challenge mode runs for 45 seconds across three stages: Find uses generous fixed targets, Focus uses smaller targets, and Flow adds gently drifting targets. Move into each ring and slow down until its hold arc fills. A new target appears after each catch.

Every catch earns 10 points at x1, 20 at x2, or 30 at x3. The third consecutive catch unlocks x2 and the sixth unlocks x3. Miss a target's time window and the streak resets; your points remain. Target windows are 6.5, 6, and 5.5 seconds across the three stages. Distinct chimes rise with your multiplier, with a separate cue when a new stage starts.

You have three lives. Staying at the movement area's edge for 0.4 seconds causes a spill, costs one life, breaks the streak, and returns the drop to the center. The round ends after 45 seconds or three spills. Results show points, targets caught, best streak, missed targets, and spills. Your best points score is saved separately from the previous version's percentage record. Play again starts a fresh round; Modes returns to mode selection.

Challenge is selected by default. Tap Challenge to switch to Practice for the original calm center-hold activity, which tracks your steady streak and longest hold without a time limit or lives. Its outer progress ring fills over a 5-second steady hold.

Tap Start, then hold the device still in a comfortable position for about 0.8 seconds to calibrate. Both modes support pause, resume, and recalibration. Calibration and pause freeze the round clock and target movement. Losing the motion sensor also stops movement and scoring. A long sampling gap cannot complete a target hold.

Requires a display, touch input, and the board's `imu_sensor`. Designed for a 480×480 square screen with slightly rounded corners; screens of at least 240×240 are supported. Audio is muted automatically when unavailable. If the IMU is unavailable, a message appears and movement and scoring stop. Use the top-left arrow to exit and the top-right button to cycle through music, effects, and mute. Your sound preference is saved.

Launch options: `run_ms=0` for continuous operation, `frame_ms=33`, `volume=80` (0–100), and `sound_mode="music"` (also accepts `effects` or `mute`). `lsb_per_g=16384` matches the Mosaico ±2g range. Adjust `invert_x=true`, `invert_y=false`, and `swap_xy=false` for different sensor orientations.

Install the complete package under `apps/balance_drop/` in the DATA root. Write scripts and assets first, then `launcher.json`, and publish the app. Records are saved to `app_data/balance_drop.json` under the root returned by `storage.get_root_dir()`, without writing to the SYSTEM package. See [asset credits](assets/ATTRIBUTION.md).
