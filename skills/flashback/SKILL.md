---
{
  "name": "flashback",
  "description": "Show a Ditto digital clock on the board and tap to play fullscreen video on a Windows PC. Requires the Windows Flashback host on the LAN and HTTP allowlist for that host.",
  "author": "ESP-Claw contributor",
  "metadata": {
    "cap_groups": ["cap_lua", "cap_http_request"],
    "manage_mode": "web",
    "category": ["media", "utility"],
    "peripherals": ["display"],
    "tags": ["flashback", "windows-host", "video", "clock"]
  }
}
---

# Flashback

Use this skill when the user wants to run the ESP-Claw Flashback controller for the Windows Flashback host.

This skill preserves the original Windows companion protocol from `ditto_video_demo/flashback/windows`: HTTP on port `8765`, `GET /health`, `GET /`, and `POST /play` with an empty JSON body `{}`.

Do not use SoftAP provisioning. If the Windows host IP is not known, ask the user for the Windows PC LAN IPv4 address during the conversation, then run the configuration script before starting the controller.

The device HTTP allowlist must allow the Windows host IP (or `*`) before HTTP requests can succeed.

## Configure Host

Run this once after asking the user for the Windows PC LAN IP:

```json
{"path":"{CUR_SKILL_DIR}/scripts/configure_host.lua","args":{"host_ip":"192.168.1.100","port":8765},"timeout_ms":15000}
```

`port` is optional and defaults to `8765`. Keep `8765` unless the Windows program was explicitly changed by the user.

## Start Controller

Run the controller asynchronously because it owns the display and polls touch input:

```json
{"path":"{CUR_SKILL_DIR}/scripts/start_flashback.lua","args":{"glyphs_path":"{CUR_SKILL_DIR}/assets/clock_glyphs.lua"},"timeout_ms":0,"name":"flashback","exclusive":"display","replace":true,"log_bytes":4096}
```

If the user gives a new IP while starting, pass it directly and the script will save it:

```json
{"path":"{CUR_SKILL_DIR}/scripts/start_flashback.lua","args":{"host_ip":"192.168.1.100","glyphs_path":"{CUR_SKILL_DIR}/assets/clock_glyphs.lua"},"timeout_ms":0,"name":"flashback","exclusive":"display","replace":true,"log_bytes":4096}
```

## Behavior

- The display shows a black-and-white digital clock using the original Flashback generated glyphs.
- Before the Windows host is reachable, the display shows a black-and-white status screen and retries `/health`.
- A screen tap sends `POST /play` with `{}` to the Windows host.
- The Windows host plays `1.mp4` fullscreen and returns `{"ok": true}` on success.
- Wi-Fi/AP provisioning from the original firmware is intentionally removed; host IP is configured through conversation and persisted under the DATA root.
