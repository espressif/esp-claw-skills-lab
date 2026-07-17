# Flashback Windows Host Protocol

This skill keeps the protocol used by `ditto_video_demo/flashback/windows/app.py`.

## Host Defaults

- Port: `8765`
- Video file: `1.mp4`, next to `app.py`
- Service shape: background Flask process, no GUI except the fullscreen playback window
- Firewall rule: inbound TCP `8765`

## Endpoints

### `GET /health`

Health check used by the ESP side before entering the clock UI.

Success:

```text
HTTP 200
ok
```

### `POST /play`

Triggers fullscreen playback. The original ESP firmware sends an empty JSON body:

```json
{}
```

Success:

```json
{"ok": true}
```

If a video is already playing, the host returns HTTP 200 with:

```json
{"ok": false, "reason": "already playing"}
```

If `1.mp4` is missing, the host returns HTTP 404 with a JSON `reason`.

### `GET /`

Human-readable status page showing host state and whether `1.mp4` exists. The ESP skill does not depend on this endpoint.

## ESP-Claw Runtime Notes

- Configure the host IP with `{CUR_SKILL_DIR}/scripts/configure_host.lua`.
- Ensure `cap_http_request` allows requests to the Windows host IP.
- Start the controller with `{CUR_SKILL_DIR}/scripts/start_flashback.lua` as an async display job.
