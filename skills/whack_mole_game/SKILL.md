---
{
  "name": "whack_mole_game",
  "description": "Play Whack-a-Mole on the device display: tap raised moles, avoid bombs, beat the 30s clock.",
  "author": "superjames",
  "metadata": {
    "category": ["game", "ui"],
    "tags": ["mole", "arcade", "touch", "bomb", "combo"],
    "peripherals": ["display"],
    "cap_groups": ["cap_lua"],
    "manage_mode": "web"
  },
  "execution": {
    "entry": "scripts/whack_mole_game.lua",
    "icon": "assets/icon.jpg",
    "args": {},
    "order": 13,
    "visible": true
  },
  "simulator": {
    "entry": "scripts/whack_mole_game.lua",
    "files": [
      "scripts/whack_mole_game.lua",
      "scripts/whack_logic.lua",
      "assets/mole_sm.rgb565",
      "assets/bomb_sm.rgb565",
      "assets/hole_sm.rgb565",
      "assets/rst_sm.rgb565",
      "assets/exit_sm.rgb565"
    ]
  }
}
---

# Whack-a-Mole

Use this skill when the user wants to play Whack-a-Mole on the device screen.

Requires a display. Tap moles, avoid bombs, beat the 30s clock. RST restarts. EXIT returns to the launcher.

## Launch

Tool call:

```json
{"path":"{CUR_SKILL_DIR}/scripts/whack_mole_game.lua","args":{}}
```

Run exactly one bundled Lua script asynchronously:

- Script: `{CUR_SKILL_DIR}/scripts/whack_mole_game.lua`
- Capability: `lua_run_script_async`
- Timeout: `0` (runs until cancelled)
- Name: `whack_mole_game`
- Exclusive: `whack_mole_game`
- Replace: `true`

## User Interaction

- 3x3 holes. A mole or bomb pops for 0.5-1.0s.
- Tap a mole: +100 and combo up. Tap a bomb: -200 and combo resets.
- Timeout (escaped target) is a miss (combo resets). Empty-hole taps do nothing.
- 30 second round. Header shows SCORE, COMBO, remaining TIME. RST restarts. EXIT returns to the launcher.
- After time is up, tap RST or any hole to play again.
