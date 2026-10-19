# MOMENT Clock

Choose a warm white ceramic or dark graphite dial with a metallic rim, hand shadows, and an orange second hand. Landscape screens place the dial and time side by side; square screens stack them vertically. The core features remain available on 160×160 displays.

## Controls

- Tap LIGHT / DARK in the top-right corner, or the moon icon on small screens, to switch themes. Tap X to return to the Launcher.
- Press and drag inside the dial for a subtle parallax effect. Release to let it spring back.
- Use CLOCK / FOCUS at the bottom to switch between the clock and focus timer.
- While the focus timer is stopped, rotate around the outer ring to select 5–60 minutes in 5-minute steps.
- START begins the timer, PAUSE pauses it, RESUME continues it, and RESET restores the selected duration. Completion shows DONE and a pulsing progress ring, without an audio alert.
- Switching themes or returning to the clock keeps the countdown running. Exiting the App discards the timer.

## Requirements

Requires a display of at least 160×160. The clock depends on device time synchronization and timezone settings. The countdown uses `system.millis()` and is unaffected by clock adjustments. Devices without touch input can display the clock; cancel the App through the runtime to exit.

Open the browser simulator from this App's detail page. The simulator and device run the same Lua script, with no external font, image, network, or audio dependencies for rendering.

## Installation and launch

Install the complete `clock_dial_demo/` package under `apps/` in the device's DATA root, then publish it with `publish_app`. Resolve the DATA root through the device storage API rather than assuming `/fatfs`. Write scripts and assets first, then `launcher.json`. Tap the App in the device Launcher to start it.

`launcher.json` contains launch settings and an embedded `catalog` object for the site listing. This file provides usage instructions. The App does not need `SKILL.md`.

## Implementation

A single script uses the current `display.open()` screen-object API to draw the dial and vector glyphs with basic shapes. It uses a single buffer by default and redraws the dial by region. Animations update at 50 ms intervals; the stationary focus screen redraws only when its state or displayed seconds change. Actual frame rate depends on hardware and transfer overhead.

Touch-down locks the active control. Buttons activate on release, and dragging does not trigger a click. The display lifetime is managed with `<close>`.
