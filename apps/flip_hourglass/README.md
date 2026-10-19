# Flip Hourglass

Choose a 1-, 3-, 5-, or 10-minute timer with a single tap. A quiet cream canvas, curved glass hourglass, amber sand, and large countdown keep the remaining time easy to read. Start, pause, resume, and reset from the bottom controls. The countdown uses the device's monotonic clock, so slower animation never extends the timer.

Face the screen toward you and hold the device upright until its orientation is stable. Turn it upside down by about 180° and briefly hold the new orientation to restart the full duration. A slanted grip is supported; you do not need to hold the screen perfectly vertical. Each flip triggers once, including while paused or after the timer ends. Rotating a device lying flat or shaking it vigorously does not count as a flip. The entire interface turns with the device: the hourglass, title, countdown, duration options, back arrow, sound icon, and buttons. Touch targets follow the rotated controls. Opening the app upside down adjusts the interface without starting the timer; a touch held across a flip is cancelled to prevent accidental actions.

This is a foreground timer: exiting the app ends the countdown. A display and touch input are required; flipping also requires the board's `imu_sensor`. Manual timing remains available if the sensor fails. A visual alert marks the end when audio is unavailable. Use the top-left arrow to exit and the top-right speaker icon to cycle through music, effects, and mute. Duration options can be changed before starting or after the countdown finishes.

Designed for a 480×480 square screen with slightly rounded corners; screens of at least 240×240 are supported. Launch options: `run_ms=0`, `frame_ms=33`, `volume=80` (0–100), `sound_mode="music"` (also accepts `effects` or `mute`), `lsb_per_g=16384`, `invert_x=true`, `invert_y=false`, and `swap_xy=false`.

Install the complete package under `apps/flip_hourglass/` in the DATA root. Write scripts and assets first, then `launcher.json`, and publish the app. Sound preferences are saved to `app_data/flip_hourglass.json` in DATA. See [asset credits](assets/ATTRIBUTION.md).
