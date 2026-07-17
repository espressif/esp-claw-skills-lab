---
{
  "name": "cloudmusic",
  "description": "Control NetEase Cloud Music on a Windows PC from the board display: play/pause, prev/next, and vinyl cover UI. Requires the Windows host app on the LAN and HTTP allowlist for that host.",
  "author": "ESP-Claw contributor",
  "metadata": {
    "cap_groups": ["cap_lua", "cap_http_request"],
    "manage_mode": "web",
    "category": ["media", "utility"],
    "peripherals": ["display"],
    "tags": ["cloudmusic", "netease", "windows-host", "vinyl"]
  }
}
---

# CloudMusic

Use this skill when the user wants to run the ESP-Claw CloudMusic controller for NetEase Cloud Music on a Windows PC.

This skill preserves the original Windows companion protocol from `ditto_video_demo/CloudMusic/win`: HTTP on port `8766`, `GET /health`, `GET /state`, `GET /cover/current`, `GET /cover/prev`, `GET /cover/next`, and `POST /control` with `play_pause`, `prev`, or `next`.

Do not use SoftAP provisioning. If the Windows host IP is not known, ask the user for the Windows PC LAN IPv4 address during the conversation, then run the configuration script before starting the controller.

The device HTTP allowlist must allow the Windows host IP (or `*`) before HTTP requests can succeed.

## Configure Host

Run this once after asking the user for the Windows PC LAN IP:

```json
{"path":"{CUR_SKILL_DIR}/scripts/configure_host.lua","args":{"host_ip":"192.168.1.100","port":8766},"timeout_ms":15000}
```

`port` is optional and defaults to `8766`. Keep `8766` unless the Windows program was explicitly changed by the user.

## Start Controller

Run the controller asynchronously because it owns the display and polls the Windows host:

```json
{"path":"{CUR_SKILL_DIR}/scripts/start_cloudmusic.lua","args":{"worker_path":"{CUR_SKILL_DIR}/scripts/cloudmusic_worker.lua"},"timeout_ms":0,"name":"cloudmusic","exclusive":"display","replace":true,"log_bytes":4096}
```

If the user gives a new IP while starting, pass it directly and the script will save it:

```json
{"path":"{CUR_SKILL_DIR}/scripts/start_cloudmusic.lua","args":{"host_ip":"192.168.1.100","worker_path":"{CUR_SKILL_DIR}/scripts/cloudmusic_worker.lua"},"timeout_ms":0,"name":"cloudmusic","exclusive":"display","replace":true,"log_bytes":4096}
```

If side touch channels are reversed on the actual board, pass `side_touch_swap: true`. For deeper hardware diagnosis, `side_prev_mask` and `side_next_mask` can override the Si12T bit masks directly; defaults are `side_prev_mask: 1` for TS1 and `side_next_mask: 6` for TS2|TS3.

## Behavior

- A screen tap sends `POST /control` with `{"action":"play_pause"}`.
- Si12T side touch TS1 sends `prev`; TS2 or TS3 sends `next`.
- State polling runs in a background Lua worker at the original 500 ms interval, switching to 150 ms for 3 seconds after prev/next.
- The worker only downloads the current cover from `/cover/current` during normal playback, avoiding synchronous prev/next cover prefetch stalls.
- The UI is intentionally the original vinyl UI: black background, procedural groove disc, round cover, tonearm, and pause overlay.
