---
{
  "name": "skills_lab",
  "description": "Open the on-device Skills Lab app store to browse, install, and remove ESP-Claw Skills from skills-lab.esp-claw.com.",
  "author": "ESP-Claw contributor",
  "metadata": {
    "category": ["utility"],
    "tags": ["skills", "app store", "install"],
    "cap_groups": ["cap_lua", "cap_http_request", "cap_skill"],
    "manage_mode": "web"
  }
}
---

# Skills Lab

Use this skill when the user wants to open the on-device Skills Lab app store,
browse ESP-Claw Skills, install Skills from Skills Lab, or remove downloaded
Skills.

The bundled Lua app renders a native LVGL app store UI on the device display.

## Requirements

- Network access from the device.
- HTTP request capability enabled.
- HTTP allowlist includes `skills-lab.esp-claw.com` or `*.esp-claw.com`.
- Skill manager capability enabled for registration and unregister.

## Tool Call Inputs

Run the bundled device app script asynchronously:

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/skills_lab_app.lua",
  "args": {},
  "timeout_ms": 0
}
```

## Recommended Flow

- Capability: `lua_run_script_async`
- Script: `{CUR_SKILL_DIR}/scripts/skills_lab_app.lua`
- Timeout: `0`
- Name: `skills_lab`
- Exclusive: `display`
- Replace: `true`

## Behavior

The app provides:

- Native LVGL list and detail pages on the device display.
- Local installed Skills are shown immediately at startup.
- Remote catalog entries are fetched lazily by category.
- Detail pages show installed, protected, removable, and `web` management status.
- Install downloads the Skill files and registers the Skill.
- Remove calls `unregister_skill` for downloaded `web` Skills and reloads the registry.

Factory-installed Skills are shown as installed and protected from deletion:

- `camera_preview`
- `network_radio`
- `flappybird`
- `stock_quotes_display`

Skills Lab item `china_a_share_quote` is treated as installed when
`stock_quotes_display` is present on the device.
