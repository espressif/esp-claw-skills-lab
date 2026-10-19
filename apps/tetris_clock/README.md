# Tetris Clock

Watch falling Tetris blocks assemble the current time.

Launch from the device Launcher. Requires a display and a correctly set device clock. Use the device Launcher's back action to exit.

Configure options in `launcher.json.args`; the defaults work without changes. `twenty_four_hour`, `leading_zero`, and `show_date` control the time and date format. `color_scheme` selects the theme, and `frame_rate` controls the frame rate. Set `duration_ms = 0` for continuous display.

A browser simulator is available. Audio and sensor behavior depend on the physical device; runtime validation of this API migration is still pending.
