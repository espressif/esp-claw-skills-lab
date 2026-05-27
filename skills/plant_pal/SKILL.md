---
{
  "name": "plant_pal",
  "description": "Turn the device into a mimosa smart planter that senses soil/light/temp/humidity, reacts to touch with animated expressions, auto-waters, and writes short letters from the plant to the user. Hardware pins and behavior thresholds are configurable.",
  "author": "ESP-Claw contributor",
  "metadata":
    {
      "cap_groups": ["cap_lua"],
      "manage_mode": "web",
      "category": ["game"],
      "peripherals": ["display", "gpio", "motor"],
      "tags": ["planter", "mimosa", "plant", "touch", "environmental_sensor", "智能花盆", "含羞草"]
    }
}
---

# Planter

Installs a mimosa smart planter on ESP-Claw. The installer Lua script switches
the agent persona to the plant, registers an always-on background script that
owns sensor sampling, touch reactions, and animated expressions, and registers
a recurring scheduler entry that lets the plant write short letters to the
user.

## When to use

- The user asks to install, set up, or adopt the smart planter or mimosa, in
  any language.
- The user wants the device to start sensing soil and light and to react to
  touch with plant-style expressions.

Match the user's language when you reply; do not switch language on your own.

## How to use

1. Run the installer with `lua_run_script` and the inputs shown below.
2. Wait for the log line `[install_planter] install complete` before telling
   the user that the planter is ready.
3. If the script prints `[install_planter] ERROR: ...`, report that line to
   the user and stop.

## Tool Call Inputs

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/install_planter.lua",
  "args": {},
  "timeout_ms": 30000
}
```

The installer takes no arguments; pass an empty `args` object.

## Example

User asks to turn the device into a smart planter (in their own language).
-> `lua_run_script` with the inputs above
-> wait for `[install_planter] install complete`
-> Reply in the user's language, briefly confirming that the planter is set
   up, that it reacts to touch, and that it will send short letters from time
   to time.

## Configuration

All tunables live in **`{CUR_SKILL_DIR}/scripts/planter_config.lua`** —
hardware wiring (GPIO pins, touch device) plus behavior thresholds (pump
trigger / pulse / cooldown, soil and light level tables, temperature and
humidity ranges). Each field has an inline comment in that file.