# Neon Strike

A touch-controlled spaceship shooter with enemy waves, power-ups, and battle sound effects.

- Drag on the screen to steer. The ship fires automatically and moves on its own when you are not touching the screen.
- Tap the screen after game over to restart.
- Requires a display of at least 240×240. Runs silently when audio is unavailable.
- Entry point: `scripts/main.lua`.
- `args.frame_ms`: frame interval in milliseconds, default 33.
- `args.run_ms`: runtime in milliseconds, default 0 for continuous play.
- `args.sound_volume`: volume from 0 to 100, default 72. Set to 0 to disable sound effects.
