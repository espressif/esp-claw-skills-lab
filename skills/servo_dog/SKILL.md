---
{
  "name": "servo_dog",
  "description": "Control a four-servo robotic dog named Servo Dog through Lua PWM actions, command calls, and a Lua HTTP Server web control panel.",
  "metadata": {
    "cap_groups": [
      "cap_lua"
    ],
    "manage_mode": "readonly",
    "category": ["game"],
    "tags": ["servo", "ai"]
  }
}
---

# Servo Dog

Use this skill when the user asks to control a four-servo robotic dog, start the Servo Dog web control panel, calibrate dog leg servo offsets, or run dog actions such as forward, backward, turn, bow, shake hand, jump, or retract legs.

This skill controls four servos directly from Lua with `mcpwm`. Default GPIOs are:

- `fl_gpio`: `1`
- `fr_gpio`: `2`
- `bl_gpio`: `41`
- `br_gpio`: `42`

Default neutral angles are compatible with the original servo dog controller:

- `fl_neutral`: `70`
- `fr_neutral`: `110`
- `bl_neutral`: `110`
- `br_neutral`: `70`

## Start Web Control

Run the server script asynchronously. It starts the PWM worker, mounts the bundled web UI, and registers HTTP APIs.

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/servo_dog_server.lua",
  "timeout_ms": 0,
  "name": "servo_dog_server",
  "exclusive": "servo_dog",
  "replace": true,
  "args": {
    "app_id": "servo_dog",
    "queue_name": "servo_dog_cmd",
    "web_root": "{CUR_SKILL_DIR}/assets",
    "worker_path": "{CUR_SKILL_DIR}/scripts/servo_dog_worker.lua",
    "worker_args": {
      "fl_gpio": 1,
      "fr_gpio": 2,
      "bl_gpio": 41,
      "br_gpio": 42
    }
  }
}
```

After it starts, open:

```text
/lua/servo_dog/
```

The page uses:

- `GET /api/lua/servo_dog/state`
- `POST /api/lua/servo_dog/control`
- `GET /api/lua/servo_dog/start_calibration`
- `GET /api/lua/servo_dog/exit_calibration`
- `POST /api/lua/servo_dog/adjust`

## Command Control

For command or agent control, keep the server running and call:

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/servo_dog_command.lua",
  "args": {
    "queue_name": "servo_dog_cmd",
    "action": "forward"
  }
}
```

If the command script reports that the controller is not running, start the web control script first.

## Actions

Supported action names:

- `installation`
- `idle`
- `forward`
- `backward`
- `turn_left`
- `turn_right`
- `lay_down`
- `bow`
- `lean_back`
- `bow_lean`
- `sway_back_forth`
- `sway`
- `shake_hand`
- `poke`
- `shake_back_legs`
- `jump_forward`
- `jump_backward`
- `retract_legs`

Movement aliases:

```json
{"move":"F"}
{"move":"B"}
{"move":"L"}
{"move":"R"}
```

Original web action id aliases:

```json
{"action":"1"}
{"action":"2"}
{"action":"3"}
{"action":"4"}
{"action":"5"}
{"action":"6"}
{"action":"7"}
{"action":"8"}
{"action":"9"}
{"action":"10"}
{"action":"11"}
{"action":"12"}
```

These map to `lay_down`, `bow`, `lean_back`, `bow_lean`, `sway_back_forth`, `sway`, `shake_hand`, `poke`, `shake_back_legs`, `jump_forward`, `jump_backward`, and `retract_legs`.

## Optional Action Args

Some actions accept overrides:

```json
{
  "action": "forward",
  "args": {
    "repeat_count": 3,
    "speed": 90
  }
}
```

Supported fields are:

- `repeat_count`: positive integer for repeated gait/action cycles.
- `speed`: higher values shorten interpolation delay.
- `hold_time_ms`: hold duration for actions such as `bow`, `lean_back`, and `shake_hand`.
- `angle_offset`: offset used by `idle` and `sway`.

## Calibration

Start calibration from the web UI or send:

```json
{"action":"installation"}
```

Adjust one servo offset:

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/servo_dog_command.lua",
  "args": {
    "queue_name": "servo_dog_cmd",
    "type": "adjust",
    "servo": "fl",
    "value": 3
  }
}
```

Valid servo ids are `fl`, `fr`, `bl`, and `br`. Values are clamped to `-25..25` and saved under the DATA root in `servo_dog/config.json`.

## Extension

To add a new dog action, edit `{CUR_SKILL_DIR}/scripts/servo_dog_worker.lua`:

1. Add a Lua function that calls `set_angle()` or `set_angles()` and uses `action_delay(ms)` inside long loops.
2. Register it in the `actions` table.
3. Optionally add an alias in `action_aliases`.
4. Add a button entry in the server `ACTIONS` list if the web UI should expose it.

Use `action_delay()` instead of `delay.delay_ms()` inside actions so a new command can interrupt the current action.
