# Gravity Maze

Tilt your device to guide a silver ball through 8 handcrafted mazes. Later levels introduce traps and checkpoints. Reach the goal and hold still for 250 ms to finish. Earn stars for completing a level, beating its target time, and avoiding falls. Your best time is saved for each level.

Choose a level and start, then hold the device still in a comfortable position for about 0.8 seconds to calibrate. Green rings mark checkpoints. After falling into a hole, the ball returns to the latest checkpoint or the start. You can pause, resume, or recalibrate. Falling animations count toward your time; pauses and calibration do not.

Requires a display, touch input, and the board's `imu_sensor`. Designed for a 480×480 square screen with slightly rounded corners; screens of at least 240×240 are supported. Audio is muted automatically when unavailable. Play stops if the sensor fails. Use the top-left arrow to exit and the top-right button to cycle through music, effects, and mute.

Launch options: `run_ms=0`, `frame_ms=33`, `volume=80` (0–100), `sound_mode="music"` (also accepts `effects` or `mute`), `lsb_per_g=16384`, `invert_x=true`, `invert_y=false`, and `swap_xy=false`.

Install the complete package under `apps/gravity_maze/` in the DATA root. Write scripts and assets first, then `launcher.json`, and publish the app. Records are saved to `app_data/gravity_maze.json` in DATA, without writing to the SYSTEM package. See [asset credits](assets/ATTRIBUTION.md).
