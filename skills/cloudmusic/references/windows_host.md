# CloudMusic Windows Host Protocol

The Windows companion program remains the original `ditto_video_demo/CloudMusic/win` app.

Default port: `8766`

Endpoints used by the skill:

- `GET /health` -> `200 ok`
- `GET /state` -> JSON now-playing state
- `GET /cover/current` -> JPEG cover
- `GET /cover/prev` -> JPEG cover or `404`
- `GET /cover/next` -> JPEG cover or `404`
- `POST /control` with `{"action":"play_pause"}`, `{"action":"prev"}`, or `{"action":"next"}`

The esp-claw device must have WiFi configured through the normal esp-claw device settings. The CloudMusic skill only stores the Windows host LAN IP and never starts a SoftAP or captive portal.

If requests fail with an allowlist error, add the Windows PC IP address to `search_http_allowlist` in esp-claw settings, or use `*` for local testing.
