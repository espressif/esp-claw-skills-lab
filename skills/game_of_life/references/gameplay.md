# Game of Life — gameplay

On-device Rainbow Conway Life for ESP-Claw boards with a display.
Immersive full-screen ink canvas — no HUD buttons, no generation / status text.

## Rules

- Birth: empty cell with exactly 3 live neighbors becomes alive.
- Survival: live cell with 2 or 3 neighbors stays alive.
- Otherwise the cell dies or stays empty.
- Newborn hue comes from parent neighbors (Rainbow inheritance with mutation).
- Every 18 generations, a few cells get a hue spice jump so colors do not collapse.

## Controls

### LCD touch boards

| Gesture | Action |
|---|---|
| Tap | Cycle glider, blinker, and R-pentomino seeds |
| Drag | Continuous paint/erase brush with sparse side spores; Life keeps evolving |
| Long-press ≈ 700 ms | Clear and reseed |
| Physically shake device | Block-scatter + sparks when an IMU is available |

### Button-only boards

| Input | Action |
|---|---|
| Short press | No action |
| Hold ≈ 700 ms | Reset + reseed |
| Physically shake device | Same as shake when an IMU is available |

## IMU shake (board-agnostic)

Physical shake uses the generic ESP-Claw `imu` Lua module:

```lua
local imu = require("imu")
local sensor = imu.new("imu_sensor")  -- default board device name
local sample = sensor:read()          -- sample.accel.x/y/z
```

Rules:

- Open the board-declared IMU device (default name `imu_sensor`). Do **not** hard-code a board product name or a specific chip brand in gameplay logic.
- Detection is relative: compare sample-to-sample accel delta against a resting magnitude EMA. This stays usable whether the backend reports raw LSB, mg, or g.
- Shake motion settles in ~200 ms; a cooldown prevents repeated triggers.
- If `require("imu")` or `imu.new(...)` fails, the demo continues; only physical shake is unavailable.

## Visuals

- Full-bleed deep-ink canvas; no grid lines, no chrome, no footer text.
- Static culture-medium background shifts subtly from deep navy to active teal-blue and back, using full-width row bands that restore cleanly after deaths.
- Bioluminescent tiles: dark teal pedestal + bright inset core (glass-organism look).
- Birth: center point → half tile → full tile at the visual cadence.
- Death: shrinking dim core over two visual frames, then clear.
- Particle age subtly darkens mature and old organisms without reducing saturation.
- Particle glow is disabled; saturated tile bodies remain crisp against the ink background.
- Shake moves the complete particle field with damped oscillation, motion echoes, and edge exposure so it reads as scene movement.
- Tap and paint strokes trigger a high-energy edge response extending 14 px inward (10 px outer + 4 px inner); erase strokes use coral and paint strokes use their lineage hue.

## Hardware

- Required: `display_lcd` via `board_manager.get_display_lcd_params`.
- Preferred: `lcd_touch`.
- Fallback: GPIO button through the `button` module.
- Optional: any board IMU exposed as `imu_sensor` (or another name passed via `args.imu_device`).

## Performance (embedded)

The renderer selects its defaults from the display interface reported by Board Manager:

- RGB framebuffer panels: ~900 tiles, 25 ms visual cadence, 90 ms simulation cadence, staged birth/death animation.
- SPI/QSPI panels such as ESP-Mosaico: ~240 tiles, 80 ms visual cadence, 150 ms simulation cadence, final-state transitions.
- QSPI/Mosaico draws into one frame and calls `present()` once. Per-band `present()` and per-row background fills are disabled because they paint the panel layer by layer.
- Unknown panel interfaces default to the serial path so a QSPI screen is never given the RGB renderer. Override with `args.serial_panel`.
- Consecutive dead cells on the same row are coalesced into one `fill_rect`. Live tiles use a single fill (no inset / birth spark).
- The four-edge interaction flash and multi-frame shake displacement stay disabled on serial panels.

Grid size targets **~910 tiles** on 320×240 (35×26, cell ≈ 9px), with 90 ms simulation and 25 ms visual cadences:

- Each Life step only `fill_rect`s cells that changed (typically 5–15% of the board).
- Tiles at 10 px or below use one `fill_rect` instead of pedestal + inset; initial and shake populations are capped independently of grid size.
- Live cells are tracked in a list; full-grid redraws happen only on reset / shake.
- Neighbor counts are accumulated in one pass over live cells; only actual births rescan parents for hue inheritance.
- Transition carry/keep lists and edge-color scratch objects are reused across frames to avoid garbage-collection stutter.
- Cells use dirty-rectangle updates each generation; the renderer issues no circular glow primitives.
- Cell RGB is cached; `hue_to_rgb` runs on birth / hue changes only.
- More than 240 changed cells skip staged transitions and draw their final state directly.
- Touch strokes are committed by the visual scheduler rather than drawing synchronously inside the 5 ms input loop.
- At 30%/42% live density, brush detail and new-cell injection are progressively bounded so dense scenes remain responsive.
- Interaction edge color is quantized into three fade redraws; its 14 px footprint remains unchanged while continuous drag avoids repeated large LCD transfers.
- Submit sparse dirty particles in four-row horizontal bands (about seven bands on S3-BOX-3). Above 120 changes or high live density, use single-row bands and final-state drawing so empty bounding-box pixels and repeat animation traffic stay bounded.

| Loop | Typical | Role |
|---|---|---|
| Touch / button poll | 5 ms (~200 Hz) | High-rate input sampling |
| Visual frame | 25 ms (~40 FPS ceiling) | Sparse lifecycle animation + event feedback |
| IMU poll | 40 ms | Shake detection |
| Life step | 90 ms (~11 gen/s) | Conway simulation cadence |

Painting and Life stepping run concurrently. Drag threshold is 4 px; painted cells are synchronized into the sparse live list before the next generation.
All runtime presents are owned by the visual scheduler; touch and IMU handlers never submit competing frames.

Optional args: `touch_ms`, `display_ms`, `step_ms`, `target_cells`, `cell_px`, `transition_limit`.

## Limits

- Runs for about 180 seconds per launch, then exits cleanly.
- Single-screen port. Web Duo tile linking is not implemented in Lua.
- No on-screen labels; controls are gesture / button / IMU only.
