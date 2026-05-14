---
{
  "name": "camera_preview",
  "description": "Live camera preview on the on-board LCD. Streams RGB565 frames from the camera sensor to the display.",
  "author": "ESP-Claw contributor",
  "metadata":
    {
      "category": ["media"],
      "tags": ["preview", "video", "demo"],
      "peripherals": ["camera", "display"],
      "cap_groups": ["cap_lua"],
      "manage_mode": "web"
    }
}
---

# Camera Preview

Use this skill when the user asks to preview the camera, show the camera
output, open the camera, run a camera demo, or test that the camera works.

The Lua script grabs frames from the on-board camera and pushes them to the
LCD using the `display` module. RGB565 / RGB565X pixel formats are supported.

## Requirements

- A camera device available on the board.
- A display device declared as `display_lcd` in board hardware info.

If either is missing, the script prints an error and exits.

## Tool Call Inputs

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/camera_preview.lua",
  "args": {}
}
```

The script takes no arguments; pass an empty `args` object.

## Behavior

The display continuously shows the camera image until the script is stopped.
On any startup failure the script prints a single `[camera_preview] ERROR: ...`
line which should be reported directly to the user.
