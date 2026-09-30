---
{
  "name": "movement_detection",
  "description": "Detect moving objects with the board camera and send a captured photo to the current WeChat chat or online dialog.",
  "author": "ESP-Claw contributor",
  "metadata": {
    "cap_groups": ["cap_lua", "cap_im_wechat", "cap_im_local", "cap_im_feishu", "cap_im_qq", "cap_im_tg"],
    "category": ["media"],
    "peripherals": ["camera"],
    "tags": ["motion", "intrusion", "monitoring"]
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

使用 `lua_run_script_async` 启动监控，通过 `lua_get_async_job` / `lua_tail_async_job` 查看状态，通过 `lua_stop_async_job` 停止。只有用户明确要求替换占用摄像头的任务时才设置 `replace: true`。

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/movement_detection.lua",
  "args": {
    "channel": "wechat",
    "chat_id": "<current_chat_id>"
  },
  "name": "movement_detection",
  "exclusive": "camera",
  "replace": false,
  "timeout_ms": 360000
}
```

Common optional args: `duration_ms` defaults to `300000`, `max_notifications` defaults to `1`, and `caption` defaults to `Moving object detected`.

## Behavior

For `wechat`, the script sends the saved JPEG through `wechat_send_image`. For `web` or `local`, it sends a local message with the saved image path. If startup or sending fails, report the `[movement_detection] ERROR: ...` line directly to the user.

## 当前检测接口

脚本通过 `camera.list_devices()` 选择摄像头，可用 `device_path` 显式指定；使用 `motion_detect.new(...)` 创建独立检测器，并调用 `detector:detect(frame)`。首次结果 `ready=false`，之后按 `motion` 和 `score` 判断运动，不再使用全局 `detect/reset`。

`pixel_threshold` 范围 0–1，默认 0.2，转换为 0–255 像素差；`moving_threshold` 范围 0.01–1，默认 0.02，向上取整为 1–100 的面积百分比。`confirm_frames` 默认 2，`hold_frames` 默认 3。旧参数 `stride` 已移除，检测器按完整图像处理。

明确传入当前会话的 `channel` 和 `chat_id`，不要猜测发送目标。照片存储在 DATA 根目录的 `movement_detection/` 下，不写入 Skill 包。
