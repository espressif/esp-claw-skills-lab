# Pocket Aquarium

Carry a little ocean in your hands. Seven fish explore a screen-filling rectangular tank, avoid one another, and chase food. Tilt your device to sway the water and move the fish with the current, while plants wave. The sun, moon, and stars stay fixed in the sky. Bubbles appear at random positions, drift upward at different speeds and sizes, and pop softly at the surface.

Tap the water or the feeding button at the bottom to add food: up to three pieces per feeding, eight pieces in the tank, and at least 650 ms between feedings. Food is eaten or fades away. The bottom-left button switches between day and night. Your theme and sound preferences are saved. The top-right button cycles through music, effects, and mute; effects mode plays a feeding sound.

Designed for a 480×480 square screen with slightly rounded corners; screens of at least 240×240 are supported. A display is required; feeding and settings use touch input. Fish continue swimming and touch feeding remains available if the board's `imu_sensor` is unavailable. The water's tilt is limited, and fish stay inside both the water and the tank. Audio is muted automatically when unavailable. Use the top-left arrow to exit.

Launch options: `run_ms=0`, `frame_ms=33`, `volume=80` (0–100), `sound_mode="music"` (also accepts `effects` or `mute`), `lsb_per_g=16384`, `invert_x=true`, `invert_y=false`, and `swap_xy=false`.

Install the complete package under `apps/pocket_aquarium/` in the DATA root. Write scripts and assets first, then `launcher.json`, and publish the app. Preferences are saved to `app_data/pocket_aquarium.json` in DATA. See [asset credits](assets/ATTRIBUTION.md).
