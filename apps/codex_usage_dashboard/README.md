# Codex Usage Dashboard

Track remaining five-hour and weekly usage allowances with updates every minute. Tap REFRESH to update manually, or the top-right X to return to the Launcher.

## Requirements

Requires a display of at least 160×240, the `display`, `delay`, `capability`, `json`, and `system` modules, and the `http_request` capability with access to your data source. Buttons require touch input; otherwise, cancel the App through the runtime.

## Controls and status

Tap REFRESH at the bottom to update manually, or the top-right X to return to the Launcher. The dashboard shows remaining five-hour and weekly allowances in two columns on landscape screens or stacked on narrow screens. Failed updates retain the last successful data and show STALE / RETRY. Before any successful update, a failure shows FAILED / RETRY. Without a configured data source, the screen shows SET URL IN ARGS.

The simulator uses bundled sample data labeled DEMO. Device HTTP requests can take up to 5 seconds, during which touch handling is deferred.

## Installation and launch

Install the complete `codex_usage_dashboard/` package under `apps/` in the device's DATA root, then publish it with `publish_app`. Resolve the DATA root through the device storage API rather than assuming `/fatfs`. Write scripts and assets first, then `launcher.json`. Tap the App in the device Launcher to start it.

`launcher.json` contains launch settings and an embedded `catalog` object for the site listing. This file provides usage instructions. The App does not need `SKILL.md`.

## Implementation

Uses `display.open()` and basic shapes to draw responsive cards, reading dimensions from the screen object. Invalid HTTP status codes, JSON, or percentage fields produce an update error and a log message while preserving the last valid data.

## Data source configuration

Set the actual address of your PC data service in `launcher.json.args`, for example:

```json
{ "url": "http://192.168.1.10:8000/data.json" }
```

Without a URL, the App only shows `SET URL IN ARGS` and does not request the example address. Run the data service on your PC and allow its host in the device's `search_http_allowlist`. The endpoint follows the dashboard's existing data contract and does not call the Codex or OpenAI API directly.

Return HTTP 2xx with the following JSON. Wrapping these fields in a `usage` object is also supported:

```json
{
  "five_h_pct": 72,
  "five_h_reset": "2h 30m",
  "weekly_pct": 85,
  "weekly_reset": "3d 4h"
}
```

Percentage fields represent the remaining allowance and must be numbers from 0 to 100. Missing or invalid values are not treated as 0%. Weekly reset times also support the legacy `HH:MM on DD Month` format, interpreted in the device's local time.
