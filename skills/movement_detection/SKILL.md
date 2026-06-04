---
{
  "name": "movement_detection",
  "description": "Detect moving objects with the board camera and send a captured photo to the current WeChat chat or online dialog.",
  "metadata": {
    "cap_groups": ["cap_lua", "cap_im_wechat", "cap_im_local"],
    "manage_mode": "readonly"
  }
}
---

# Movement Detection

Use this skill when the user asks to monitor the camera for movement, motion, moving objects, intrusion, or activity, and notify them with a photo when motion is detected.

The Lua script opens the board camera, detects motion from consecutive frames, saves the trigger frame as a JPEG, and sends it through IM capabilities.

## Requirements

- A camera device declared in board hardware info.
- IM capability for the target channel.

If the camera or send capability is missing, the script prints an error and exits.

## Tool Call Inputs

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/movement_detection.lua",
  "args": {
    "channel": "wechat",
    "chat_id": "<current_chat_id>"
  },
  "timeout_ms": 360000
}
```

Common optional args: `duration_ms` defaults to `300000`, `max_notifications` defaults to `1`, and `caption` defaults to `Moving object detected`.

## Behavior

For `wechat`, the script sends the saved JPEG through `wechat_send_image`. For `web` or `local`, it sends a local message with the saved image path. If startup or sending fails, report the `[movement_detection] ERROR: ...` line directly to the user.
