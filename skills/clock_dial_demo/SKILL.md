---
{
  "name": "clock_dial_demo",
  "description": "An animated analog clock dial rendered on the on-board LCD, with hour/minute/second hands and a dark themed face.",
  "author": "ESP-Claw contributor",
  "metadata":
    {
      "category": ["utility"],
      "tags": ["clock", "watchface", "dial", "demo"],
      "peripherals": ["display"],
      "cap_groups": ["cap_lua"],
      "manage_mode": "web"
    }
}
---

# Clock Dial Demo

Use this skill when the user asks for a clock, watch face, dial, time
display, or a generic display demo on the board.

The Lua script reads the system time and draws an animated analog clock face
on the LCD. The hour, minute, and second hands sweep in real time on a dark
themed dial with major/minor ticks and a digital sub-text.

## Requirements

- A display device declared as `display_lcd` in board hardware info.

If the display is missing, the script prints an error and exits.

## Tool Call Inputs

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/clock_dial_demo.lua",
  "args": {}
}
```

The script takes no arguments; pass an empty `args` object.

## Behavior

The dial renders at roughly 10 frames per second and keeps running for the
script's configured run time. On startup failure the script prints a single
`[clock_dial_demo] ERROR: ...` line which should be reported directly to the
user.
