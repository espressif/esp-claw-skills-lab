# Flappy Bird

Tap the screen or use a configured GPIO button to control the bird. Sound effects are optional.

## Requirements

Requires a display of at least 160×160 and either touch input or a GPIO button. Audio output is optional.

## Controls

- Tap or press a button to start, flap during play, and retry after the game ends.
- Tap the top-right X to return to the Launcher. The adjacent pause button pauses or resumes play; tapping the pause panel also resumes it.
- Control buttons activate on release; dragging away cancels the action. Exit and pause controls do not trigger gameplay actions.
- Runs continuously by default. Set `args.run_ms` above 0 to limit runtime; `run_time_ms` is also supported. On devices without touch input, cancel the App through the runtime.

## Installation and launch

Install the complete `flappybird/` package under `apps/` in the device's DATA root, then publish it with `publish_app`. Resolve the DATA root through the device storage API rather than assuming `/fatfs`. Write scripts and assets first, then `launcher.json`. Tap the App in the device Launcher to start it.

`launcher.json` contains launch settings and an embedded `catalog` object for the site listing. This file provides usage instructions. The App does not need `SKILL.md`.

## Implementation

Based on upstream Flappy Bird, with pause/resume controls, a top-right exit button, and small-screen support. The original bird drawing and icon are retained. The script uses the current audio API: `output:info()` supplies the actual sample rate, channel count, and bit depth; `output:set_volume()` sets the volume. It generates matching 16-bit or 32-bit PCM and skips optional effects for other bit depths. `sample_rate_hz` is no longer used to configure the output format.

## Launch options

Touch input is preferred by default. For a GPIO button, set `input_mode: "button"` and `button_gpio` in `launcher.json.args`. See the parameter definitions at the top of the bundled script for other options.
