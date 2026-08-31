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
      "scripts/jp_spr.lua",
      "assets/icon.jpg",
      "assets/player_l0.spr",
      "assets/player_l1.spr",
      "assets/player_l2.spr",
      "assets/player_l3.spr",
      "assets/player_l4.spr",
      "assets/player_l5.spr",
      "assets/player_l6.spr",
      "assets/player_r0.spr",
      "assets/player_r1.spr",
      "assets/player_r2.spr",
      "assets/player_r3.spr",
      "assets/player_r4.spr",
      "assets/player_r5.spr",
      "assets/player_r6.spr",
      "assets/sprites.bin",
      "assets/tile_0_0.spr",
      "assets/tile_0_1.spr",
      "assets/tile_0_2.spr",
      "assets/tile_0_3.spr",
      "assets/tile_0_4.spr",
      "assets/tile_0_5.spr",
      "assets/tile_1_0.spr",
      "assets/tile_1_1.spr",
      "assets/tile_1_2.spr",
      "assets/tile_1_3.spr",
      "assets/tile_1_4.spr",
      "assets/tile_1_5.spr",
      "assets/tile_2_0.spr",
      "assets/tile_2_1.spr",
      "assets/tile_2_2.spr",
      "assets/tile_2_3.spr",
      "assets/tile_2_4.spr",
      "assets/tile_2_5.spr",
      "assets/tile_3_0.spr",
      "assets/tile_3_1.spr",
      "assets/tile_3_2.spr",
      "assets/tile_3_3.spr",
      "assets/tile_3_4.spr",
      "assets/tile_3_5.spr",
      "assets/tile_4_0.spr",
      "assets/tile_4_1.spr",
      "assets/tile_4_2.spr",
      "assets/tile_4_3.spr",
      "assets/tile_4_4.spr",
      "assets/tile_4_5.spr",
      "assets/tile_5_0.spr",
      "assets/tile_5_1.spr",
      "assets/tile_5_2.spr",
      "assets/tile_5_3.spr",
      "assets/tile_5_4.spr",
      "assets/tile_5_5.spr",
      "assets/tile_6_0.spr",
      "assets/tile_6_1.spr",
      "assets/tile_6_2.spr",
      "assets/tile_6_3.spr",
      "assets/tile_6_4.spr",
      "assets/tile_6_5.spr",
      "assets/player_l0.png",
      "assets/player_l1.png",
      "assets/player_l2.png",
      "assets/player_l3.png",
      "assets/player_l4.png",
      "assets/player_l5.png",
      "assets/player_l6.png",
      "assets/player_r0.png",
      "assets/player_r1.png",
      "assets/player_r2.png",
      "assets/player_r3.png",
      "assets/player_r4.png",
      "assets/player_r5.png",
      "assets/player_r6.png",
      "assets/tile_0_0.png",
      "assets/tile_0_1.png",
      "assets/tile_0_2.png",
      "assets/tile_0_3.png",
      "assets/tile_0_4.png",
      "assets/tile_0_5.png",
      "assets/tile_1_0.png",
      "assets/tile_1_1.png",
      "assets/tile_1_2.png",
      "assets/tile_1_3.png",
      "assets/tile_1_4.png",
      "assets/tile_1_5.png",
      "assets/tile_2_0.png",
      "assets/tile_2_1.png",
      "assets/tile_2_2.png",
      "assets/tile_2_3.png",
      "assets/tile_2_4.png",
      "assets/tile_2_5.png",
      "assets/tile_3_0.png",
      "assets/tile_3_1.png",
      "assets/tile_3_2.png",
      "assets/tile_3_3.png",
      "assets/tile_3_4.png",
      "assets/tile_3_5.png",
      "assets/tile_4_0.png",
      "assets/tile_4_1.png",
      "assets/tile_4_2.png",
      "assets/tile_4_3.png",
      "assets/tile_4_4.png",
      "assets/tile_4_5.png",
      "assets/tile_5_0.png",
      "assets/tile_5_1.png",
      "assets/tile_5_2.png",
      "assets/tile_5_3.png",
      "assets/tile_5_4.png",
      "assets/tile_5_5.png",
      "assets/tile_6_0.png",
      "assets/tile_6_1.png",
      "assets/tile_6_2.png",
      "assets/tile_6_3.png",
      "assets/tile_6_4.png",
      "assets/tile_6_5.png"
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
