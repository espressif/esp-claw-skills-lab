# Fruit Slice

Swipe through colorful fruit, split it into juicy halves, and chase a new best score. A dark ink canvas, bright lime controls, clean blade trails, and original fruit artwork keep the action readable on a small square display. All interface text is English.

Choose **RUSH** or **ZEN**, then swipe the start bar from left to right. Rush lasts 60 seconds. Every fruit earns 10 points; slicing three fruit in one quick stroke adds 15 bonus points, with another 10 for each additional fruit in that chain. A pause of more than 220 ms between cuts starts a new chain. The best combo records the largest chain.

In Rush, every 20 fruit fills the Fever meter. Fever lasts 5 seconds, doubles fruit points and combo bonuses, and removes bombs until it ends. Cutting a bomb subtracts 20 points without taking the score below zero, clears Fever and its meter, and breaks the chain. Missing fruit does not subtract points. Bombs appear only after the opening seven seconds of Rush.

Zen has no bombs or time limit. Use the top-right pause control to resume or finish a round. Pausing freezes motion and the round clock. Results show points, fruit cut, and best combo; Rush and Zen keep separate best scores. PLAY AGAIN starts a fresh round; HOME returns to mode selection.

Requires a touch display of at least 240×240; designed for a 480×480 square screen with small rounded corners. Touch input uses one stable finger ID and tests the entire segment between samples, including relative fruit movement. Audio is optional. The speaker control cycles through music, effects, and mute. Music plays on the home screen; gameplay prioritizes short slicing and reward sounds. Records and preferences are saved to `app_data/fruit_slice.json` under the device DATA root.

Launch options: `run_ms=0` for continuous operation, `frame_ms=33`, `volume=80` (0–100), and `sound_mode="music"` (also `effects` or `mute`). `profile=true` logs frame costs, peak audio submission time, and Lua heap usage every five seconds. The round uses the monotonic device clock rather than frame counting. Slow frames cannot extend Rush.

Sound effects are preloaded PCM for the device's 16 kHz, mono, 16-bit mixer. Each frame submits at most 60 ms of audio; gameplay never opens a sound file or starts an AAC decoder. Unsupported audio formats disable sound with a diagnostic while the game remains playable.

The independent package uses `display`, preloaded bitmap fonts and RGB565 sprite strips. A sprite's transparent gaps are omitted from its strips; each opaque strip is submitted with `screen:blit()`. Art is resized once at startup for smaller displays. Runtime pools are limited to seven airborne objects, twelve fruit pieces, twenty-four juice particles, and ten blade segments. No shared App library is required. Browser play is not enabled in this repository's bundled simulator.

Install the entire package under `apps/fruit_slice/` in the DATA root. Write scripts and assets first, then `launcher.json`, and publish the App. See [asset credits](assets/ATTRIBUTION.md). Host gameplay checks can be run from the repository root with `lua tests/fruit_slice.lua` using Lua 5.4 or later.
