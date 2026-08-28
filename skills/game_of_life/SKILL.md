---
{
  "name": "game_of_life",
  "description": "Play an immersive full-screen Rainbow Conway's Game of Life on an ESP-Claw display. Tap to seed patterns, drag to paint or erase cells, long-press to reset, and shake an IMU-equipped board to scatter life. Uses Conway B3/S23 with no on-screen controls; LCD touch is preferred and IMU support is optional.",
  "author": "superjames",
  "metadata": {
    "category": ["game", "ui"],
    "tags": ["life", "conway", "rainbow", "arcade", "demo", "button", "touch", "shake", "accelerometer", "immersive"],
    "peripherals": ["display"],
    "cap_groups": ["cap_lua"],
    "manage_mode": "web"
  },
  "execution": {
    "entry": "scripts/mosaico_life.lua",
    "icon": "assets/icon.jpg",
    "args": {},
    "order": 20,
    "visible": true
  },
  "simulator": {
    "entry": "scripts/mosaico_life.lua",
    "files": [
      "scripts/mosaico_life.lua"
    ]
  }
}
---

# Game of Life

Use this skill when the user wants to play Conway's Game of Life, Rainbow Life, a Mosaico life demo, shake-to-scatter cells, paint living tiles on the LCD, or launch an interactive mosaic / cellular automata game.

Requires a display. Chrome-less full-screen ink canvas — no HUD buttons and no generation/status text. Uses LCD touch gestures when available; otherwise falls back to a button. If the board declares an IMU as `imu_sensor` (or the caller passes `args.imu_device`), physical board shaking triggers scatter. Audio is not required. Do not restrict this skill to a specific board model or IMU chip name.

Run exactly one script with `lua_run_script` unless the user explicitly asks to run another application.

If `lua_run_script` returns an error, report that error directly to the user. Do not retry with changed arguments unless the user asks.

## Launch

Tool call:

```json
{"path":"{CUR_SKILL_DIR}/scripts/mosaico_life.lua","args":{}}
```

Optional long-running launch (preferred for interactive play so the agent stays responsive):

```json
{"path":"{CUR_SKILL_DIR}/scripts/mosaico_life.lua","args":{},"exclusive":"display","replace":true,"name":"game_of_life"}
```

Use `lua_run_script_async` for the async form when available.

Optional args:

```json
{"path":"{CUR_SKILL_DIR}/scripts/mosaico_life.lua","args":{"imu_device":"imu_sensor","shake_sensitivity":1.0,"touch_ms":4,"display_ms":36,"step_ms":110,"target_cells":240,"cell_px":16}}
```

- `imu_device`: board_manager device name for the IMU (default `imu_sensor`). Use this only when the board YAML uses a non-default device id — never hard-code a board product name.
- `shake_sensitivity`: number > 0 (default `1.0`). Higher = easier to trigger physical shake.
- `touch_ms`: touch/button poll interval in ms (default `4`, ~250 Hz). Lower = snappier strokes.
- `display_ms`: full-scene refresh interval in ms (default auto ~36–50 from tile count). Raise on slower panels if tearing/CPU bound.
- `step_ms`: Life generation interval while playing (default auto ~110–150 from tile count).
- `target_cells`: soft budget for grid tiles (default `240`). Larger panels grow cell pixels instead of denser grids, so MCU `fill_rect` cost stays bounded.
- `cell_px`: force tile pixel size (overrides `target_cells` sizing). Use only for manual tuning.

## Recommended flow

1. Activate the `board_hardware_info` skill and confirm a display is declared. LCD touch is preferred; a button is enough for pause / reset / shake. If an IMU is declared (commonly `imu_sensor`), physical shake is available automatically.
2. Run `{CUR_SKILL_DIR}/scripts/mosaico_life.lua` with an empty `args` object unless a non-default IMU device name is required.
3. Tell the user the chrome-less controls:
   - Drag: paint living cells (drag over a live cell to erase).
   - Tap: place the next seed pattern.
   - Long-press ≈ 700 ms: reset and reseed.
   - Physically shake the board when IMU is present.
   - Button-only boards: hold ≈ 700 ms to reset and reseed; physical shake requires an IMU.
4. If the display is missing, say so and do not run the script. Missing IMU is not fatal — shake still works via button hold on button-only boards.
5. On script error, report the error text and stop.

## Gameplay notes

- Rule: classic B3/S23 Conway Life with Rainbow hue inheritance.
- Shake moves life in 3×3 blocks (1–3 steps) and plants viable sparks so the board does not die instantly.
- Physical shake detection is relative to resting acceleration (scale-free), so it works across IMU backends without per-chip thresholds.
- A restrained colored background and edge feedback add atmosphere without particle halos or on-screen chrome.
- Tile count is capped (~240) for MCU smoothness.
- Single-device port of the original web demo; multi-tile linking is out of scope for this Lua skill.

## References

- Play and control details: `read_file("{CUR_SKILL_DIR}/references/gameplay.md")`
