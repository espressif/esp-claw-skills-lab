---
{
  "name": "game_of_life",
  "description": "Play an immersive full-screen Rainbow Conway's Game of Life on ESP-Claw / Mosaico displays. Adapted for QSPI AMOLED using paced full-frame present. Tap to seed, drag to paint or erase, long-press to reset. Shake-to-scatter needs the Lua imu module; on current Mosaico firmware imu is unavailable so shake is temporarily disabled. Conway B3/S23, chrome-less full-screen; LCD touch preferred.",
  "author": "superjames",
  "metadata": {
    "category": [
      "game",
      "ui"
    ],
    "tags": [
      "life",
      "conway",
      "rainbow",
      "arcade",
      "demo",
      "button",
      "touch",
      "shake",
      "accelerometer",
      "immersive"
    ],
    "peripherals": [
      "display"
    ],
    "cap_groups": [
      "cap_lua"
    ],
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

Use this skill when the user wants to play Conway's Game of Life, Rainbow Life, a Mosaico life demo, paint living tiles on the LCD, or launch an interactive mosaic / cellular automata game.

Requires a display. Tuned for Mosaico QSPI AMOLED (command-mode GRAM): each frame uses begin_frame, draw, present, end_frame; avoid present_full and clear=false partial paths on current firmware. Chrome-less full-screen ink canvas — no HUD buttons and no generation/status text. Uses LCD touch gestures when available; otherwise falls back to a button. IMU shake is optional and soft-required via pcall(require, "imu"). On current Mosaico firmware the Lua imu module is not registered, so shake-to-scatter is temporarily unavailable even though the board has a hardware IMU. When imu is present and the board declares imu_sensor (or args.imu_device is set), shaking still scatters life. Audio is not required.

Run exactly one script with `lua_run_script` unless the user explicitly asks to run another application.

If `lua_run_script` returns an error, report that error directly to the user. Do not retry with changed arguments unless the user asks.

## Launch

Tool call:

```json
{"path":"{CUR_SKILL_DIR}/scripts/mosaico_life.lua","args":{}}
```


## Mosaico / QSPI notes

- Target panel: 480x480 QSPI AMOLED (CO5300-class GRAM). A full RGB565 frame is about 450 KB, so refresh uses paced full-frame present rather than RGB-style continuous scanout.
- Safe Lua display path on current Mosaico image: begin_frame({ clear = true }) then draw then present() then end_frame().
- Shake/IMU: code keeps optional IMU support, but without the Lua imu module shake does nothing until firmware enables it.

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
- `display_ms`: visual refresh interval in ms (default `25` on RGB framebuffer panels, `80` on SPI/QSPI panels).
- `step_ms`: Life generation interval (default `90` on RGB framebuffer panels, `150` on SPI/QSPI panels).
- `target_cells`: soft budget for grid tiles (default `900` on RGB framebuffer panels, `240` on SPI/QSPI panels). Larger panels grow cell pixels instead of denser grids.
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
- Tile density is panel-aware: about 900 cells on RGB framebuffer panels and about 240 on SPI/QSPI panels.
- SPI/QSPI panels automatically use horizontal dirty-band presents, final-state transitions, and a lower default cadence; RGB framebuffer panels retain the richer high-frame-rate path.
- Single-device port of the original web demo; multi-tile linking is out of scope for this Lua skill.

## References

- Play and control details: `read_file("{CUR_SKILL_DIR}/references/gameplay.md")`
