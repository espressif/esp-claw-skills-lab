# Game of Life

Tap to seed cells, drag to paint or erase them, and long-press to reset. Shake to scatter cells when an IMU is available.

Launch from the device Launcher. Requires a display; touch input is preferred. Without touch input, use the GPIO0 button. An IMU is optional. Use the device Launcher's back action to exit.

Configure options in `launcher.json.args`; the defaults work without changes. `cell_px` adjusts cell size, `display_ms` and `step_ms` set display and simulation intervals, and `imu_device` selects the board's IMU.

A browser simulator is available. Audio and sensor behavior depend on the physical device; runtime validation of this API migration is still pending.
