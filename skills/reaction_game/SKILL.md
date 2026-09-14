---
{
  "name": "reaction_game",
  "description": "Play the reaction-time test: wait for green, tap as fast as you can, 5 rounds.",
  "author": "superjames",
  "metadata": {
    "category": ["game", "ui"],
    "tags": ["reaction", "tap", "arcade", "touch"],
    "peripherals": ["display"],
    "cap_groups": ["cap_lua"],
    "manage_mode": "web"
  },
  "execution": {
    "entry": "scripts/reaction_game.lua",
    "icon": "assets/icon.jpg",
    "args": {},
    "order": 14,
    "visible": true
  },
  "simulator": {
    "entry": "scripts/reaction_game.lua",
    "files": [
      "scripts/reaction_game.lua",
      "scripts/reaction_logic.lua",
      "assets/Exit.rgb565",
      "assets/Restart.rgb565",
      "assets/icon.jpg"
    ]
  }
}
---

# Reaction Time

Use this skill when the user wants to play the reaction-time test on the device screen.

Requires a display. Wait for green, tap as fast as you can, 5 rounds. RST restarts. EXIT returns to the launcher.

## Launch

Tool call:

```json
{"path":"{CUR_SKILL_DIR}/scripts/reaction_game.lua","args":{}}
```

Run exactly one bundled Lua script asynchronously:

- Script: `{CUR_SKILL_DIR}/scripts/reaction_game.lua`
- Capability: `lua_run_script_async`
- Timeout: `0` (runs until cancelled)
- Name: `reaction_game`
- Exclusive: `reaction_game`
- Replace: `true`

## User Interaction

- 5 rounds. Play area starts yellow: Wait, tap when it turns green.
- Tap too early: false start (round still counts). Tap on green: reaction time is scored.
- Ratings: Lightning Fast (<100ms), Great Reaction (<300ms), Nice Try (<600ms), Wake Up otherwise.
- Header shows ROUND n/5, BEST (-- or {ms}ms), FALSE count. RST restarts. EXIT returns to the launcher.
- After 5 rounds, tap RST to play again.
