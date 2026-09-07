---
{
  "name": "jump_prince_game",
  "description": "Play Jump Prince on the device display: hold LEFT/RIGHT/JUMP to charge, then release to leap.",
  "author": "ESP-Claw contributor",
  "metadata": {
    "category": [
      "game",
      "ui"
    ],
    "tags": [
      "jump",
      "platformer",
      "arcade",
      "touch",
      "charge"
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
    "entry": "scripts/jump_prince_game.lua",
    "icon": "assets/icon.jpg",
    "args": {},
    "order": 11,
    "visible": true
  },
  "simulator": {
    "entry": "scripts/jump_prince_game.lua",
    "files": [
      "scripts/jump_prince_game.lua",
      "scripts/jp_logic.lua",
      "scripts/jp_input.lua",
      "scripts/jp_spr.lua"
    ]
  }
}
---
# Jump Prince

Use this skill when the user wants to play the Jump Prince platformer.

Original Jump Prince by Jakub Tomsu, copyright (c) 2013-2024 (Lua port of
the factory_demo LVGL adaptation in esp32s31-game-center).

Requires a display. Hold LEFT / RIGHT / JUMP to charge, then release to leap.
Longer hold = stronger jump. LEFT/RIGHT do not walk.

## Launch

Tool call:

```json
{"path":"{CUR_SKILL_DIR}/scripts/jump_prince_game.lua","args":{}}
```

Run exactly one bundled Lua script asynchronously:

- Script: `{CUR_SKILL_DIR}/scripts/jump_prince_game.lua`
- Capability: `lua_run_script_async`
- Timeout: `0` (runs until cancelled)
- Name: `jump_prince_game`
- Exclusive: `jump_prince_game`
- Replace: `true`

Optional args:

```json
{"path":"{CUR_SKILL_DIR}/scripts/jump_prince_game.lua","args":{"assets_dir":"{CUR_SKILL_DIR}/assets","tile_px":28}}
```

- `assets_dir`: directory holding `.spr` / `sprites.bin` (default: skill `assets/`).
- `tile_px`: optional on-screen tile size in pixels. Defaults to auto-fit.

## User Interaction

- Game starts on the spawn stage immediately.
- Hold LEFT to charge a leftward jump; release LEFT to leap left.
- Hold RIGHT to charge a rightward jump; release RIGHT to leap right.
- Hold JUMP to charge a vertical jump; release JUMP to leap up.
- Longer hold = stronger jump. LEFT/RIGHT do not walk.
- If JUMP is held together with LEFT or RIGHT, keep charging and lean that way.
- Header shows the current stage and the live charge bar; Pause pauses,
  Restart restarts, Exit returns to the launcher.

## Files

- `scripts/jump_prince_game.lua`
- `scripts/jp_logic.lua`
- `scripts/jp_input.lua`
- `scripts/jp_spr.lua`
- `assets/sprites.bin`
- `assets/icon.jpg`
- `assets/*.png` (web simulator sprites; pal_idx 0x0F is alpha)

## Stopping / Status

- Stop with the async job cancel for name `jump_prince_game`.
- Check progress via `lua_get_async_job` or `lua_tail_async_job`.

If script execution returns an error, report that error directly to the user.

## Customization Notes

Input mapping is isolated in `{CUR_SKILL_DIR}/scripts/jp_input.lua`; replace
that file alone to drive the game from physical buttons or other inputs.
Gameplay physics lives in `scripts/jp_logic.lua` with no LVGL dependencies.

## Mosaico / QSPI

Verified on Mosaico 480x480 QSPI (ESP32-S31). The map is one RGB565 canvas
built from the original .spr tiles, with the player as a small overlay.
Do not prefetch every stage into Lua strings (heap OOM). Keep the entry
script under 64KB. Paths under /nand/ or /fatfs/ are treated as the
real device, not the web simulator.
