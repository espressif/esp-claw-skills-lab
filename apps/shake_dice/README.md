# Shake Dice

Choose 1–3 dice, shake your device, then hold still to watch them settle and reveal the total. Large lavender dice, a clear total, and a single-row history keep the screen easy to read. The last 5 results remain visible during the current session. You can also tap the dice area to roll. The bottom selector changes the number of dice between rolls.

A roll starts after sustained shaking is detected. Hold still for about 450 ms to begin the settling animation. Each result is generated once per roll; the animation does not determine the outcome. This app uses Lua pseudorandom numbers for casual entertainment.

Designed for a 480×480 square screen with slightly rounded corners; screens of at least 240×240 are supported. Touch rolling remains available if the board's `imu_sensor` is unavailable. Audio is muted automatically when unavailable. Use the top-left arrow to exit and the top-right button to cycle through music, effects, and mute. Dice sounds play in both music and effects modes.

Launch options: `run_ms=0` for continuous operation, `frame_ms=33`, `volume=80` (0–100), and `sound_mode="music"` (also accepts `effects` or `mute`). `lsb_per_g=16384` matches the Mosaico ±2g range. Adjust `invert_x=true`, `invert_y=false`, and `swap_xy=false` for different sensor orientations.

Install the complete package under `apps/shake_dice/` in the DATA root. Write scripts and assets first, then `launcher.json`, and publish the app. Sound preferences are saved to `app_data/shake_dice.json` in DATA. See [asset credits](assets/ATTRIBUTION.md).
