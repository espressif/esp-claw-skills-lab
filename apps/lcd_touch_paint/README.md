# Screen Paint

Choose a color and brush, then drag to paint. CLEAR resets the canvas; X returns to the Launcher.

## Requirements

Requires a display and touch input.

## Controls

Choose a color and brush, then drag across the canvas. CLEAR resets the canvas, and the top-right X returns to the Launcher. Clear and exit activate on release; dragging away from the button cancels the action. Small screens place the palette and brushes on separate rows to avoid overlap. Requires a touch display of at least 160×160.

## Installation and launch

Install the complete `lcd_touch_paint/` package under `apps/` in the device's DATA root, then publish it with `publish_app`. Resolve the DATA root through the device storage API rather than assuming `/fatfs`. Write scripts and assets first, then `launcher.json`. Tap the App in the device Launcher to start it.

`launcher.json` contains launch settings and an embedded `catalog` object for the site listing. This file provides usage instructions. The App does not need `SKILL.md`.

## Implementation

Adapted from upstream `system/apps/lcd_touch_paint`, retaining its launcher configuration and icon. The initial draw is protected by error handling so the display is released even if the first frame fails.
