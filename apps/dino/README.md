# Dino

Tap the screen or use a configured GPIO button to jump. After the game ends, tap or press again to retry.

## Requirements

Requires a display of at least 160×160 and either touch input or a GPIO button.

## Controls

- Tap or press a button to start, jump during play, and retry after the game ends.
- Tap the top-right X to return to the Launcher. The adjacent pause button pauses or resumes play; tapping the pause panel also resumes it.
- Control buttons activate on release; dragging away cancels the action. Exit and pause controls do not trigger gameplay actions.
- Runs continuously by default. Set `args.run_ms` above 0 to limit runtime in milliseconds. On devices without touch input, cancel the App through the runtime.

## Installation and launch

Install the complete `dino/` package under `apps/` in the device's DATA root, then publish it with `publish_app`. Resolve the DATA root through the device storage API rather than assuming `/fatfs`. Write scripts and assets first, then `launcher.json`. Tap the App in the device Launcher to start it.

`launcher.json` contains launch settings and an embedded `catalog` object for the site listing. This file provides usage instructions. The App does not need `SKILL.md`.

## Implementation

Based on the upstream Dino drawing and collision logic, with a start screen, pause/resume controls, and a top-right exit button. The scene, character, and text scale to the display size.

## Launch options

Touch input is preferred by default. For a GPIO button, set `input_mode: "button"` and `button_gpio` in `launcher.json.args`. See the parameter definitions at the top of the bundled script for other options.
