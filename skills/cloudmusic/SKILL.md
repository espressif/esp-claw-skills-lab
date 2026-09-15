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

Use this skill to control NetEase Cloud Music on a Windows PC from ESP-Claw. The PC plays audio and exposes playback data and controls on HTTP port `8766`; ESP-Claw displays the vinyl UI and sends commands.


## Requirements

- A Windows 10/11 PC and ESP-Claw on the same LAN.
- Python 3.10+ available as `python` on `PATH`.
- NetEase Cloud Music for Windows.
- InfinityLink, BetterNCM, or another bridge that exposes NetEase through Windows SMTC.
- The PC LAN IPv4 address added to the ESP-Claw `search_http_allowlist`.

## Install the Windows Host

1. Download [CloudMusic.zip](https://dl.espressif.com/AE/esp-claw/skills/CloudMusic.zip).
2. Extract it to a local folder.
3. Open `CloudMusic\win` and run `install.bat`. Approve the UAC and firewall prompts.
4. Open NetEase Cloud Music and play a song.

Only the `win` folder is required.  Building or flashing the standalone firmware included in the download is not required.
The installer starts the host in the background; its log is `CloudMusic\win\cloudmusic-host.log`. Run `install.bat` again if the host is not running after a reboot.

## Verify the Windows Host

On the PC, run:

```bat
curl http://127.0.0.1:8766/health
curl http://127.0.0.1:8766/state
```

Continue only when `/health` returns `ok` and `/state` reports `"smtc_ready": true`. Get the PC LAN IPv4 address from `ipconfig` or the `lan_ip` field; do not use `127.0.0.1` for ESP-Claw.

## Configure the ESP-Claw Device

Confirm that both devices are on the same LAN and add the PC LAN IPv4 address to `search_http_allowlist`. Ask the user for the address if needed, then run:

```json
{"path":"{CUR_SKILL_DIR}/scripts/configure_host.lua","args":{"host_ip":"192.168.1.100","port":8766},"timeout_ms":15000}
```

`port` defaults to `8766`. Run this configuration again if the PC IP changes. Do not start the controller if it reports `/health not ready`.

## Start the Controller

Run the controller asynchronously because it owns the display:

```json
{"path":"{CUR_SKILL_DIR}/scripts/start_cloudmusic.lua","args":{"worker_path":"{CUR_SKILL_DIR}/scripts/cloudmusic_worker.lua"},"timeout_ms":0,"name":"cloudmusic","exclusive":"display","replace":true,"log_bytes":4096}
```

To configure a new IP while starting, pass it directly:

```json
{"path":"{CUR_SKILL_DIR}/scripts/start_cloudmusic.lua","args":{"host_ip":"192.168.1.100","worker_path":"{CUR_SKILL_DIR}/scripts/cloudmusic_worker.lua"},"timeout_ms":0,"name":"cloudmusic","exclusive":"display","replace":true,"log_bytes":4096}
```

If previous and next are reversed, pass `"side_touch_swap": true`.

## Controls and Behavior

- Tap the screen to play or pause.
- Touch Si12T TS1 for the previous track.
- Touch Si12T TS2 or TS3 for the next track.

The protocol is unauthenticated HTTP intended only for a trusted LAN. Do not expose port `8766` to the public internet.

## Stop or Uninstall

Stop the device's asynchronous Lua job named `cloudmusic`. To remove the Windows Host, run `CloudMusic\win\uninstall.bat`.
