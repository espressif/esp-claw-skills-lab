---
{
  "name": "voice_reminder",
  "description": "Speak Chinese or English text aloud through the board speaker using SiliconFlow cloud TTS. Use this for spoken reminders, notifications, or when the user asks the device to say something.",
  "author": "kankan",
  "metadata":
    {
      "category": ["media", "utility"],
      "tags": ["tts", "speech", "reminder", "voice", "siliconflow"],
      "peripherals": ["speaker"],
      "cap_groups": ["cap_lua", "cap_http_request"],
      "manage_mode": "web"
    }
}
---

# Voice Reminder

Use this skill when the user wants the device to speak text aloud — reminders, notifications, greetings, or any prompt where a spoken response is more appropriate than a text reply.

The skill:
1. Calls SiliconFlow's TTS API to synthesize the text into an MP3
2. Saves the MP3 to `/fatfs/tmp/`
3. Plays it through the board audio output (`audio_dac`, which on the V3.1 breadboard is a USB UAC speaker)
4. Cleans up the temp file and releases the USB UAC when done

## Prerequisites (one-time setup on this device)

- **API key** must be saved to `/fatfs/config/siliconflow_key.txt` (single line, no trailing newline). Upload via `POST /api/files/upload?path=%2Fconfig%2Fsiliconflow_key.txt`.
- **`api.siliconflow.com` must be in `search_http_allowlist`** (web UI → Config → search → http allowlist, comma-separated).

## Args Schema

```json
{
  "type": "object",
  "properties": {
    "text": {
      "type": "string",
      "description": "Text to speak. 1-500 characters recommended for reminders.",
      "minLength": 1
    },
    "voice": {
      "type": "string",
      "description": "Voice id. Defaults to fishaudio/fish-speech-1.5:anna. Other options: :alex, :bella, :benjamin, :charles, :claire, :david, :diana",
      "default": "fishaudio/fish-speech-1.5:anna"
    },
    "model": {
      "type": "string",
      "enum": ["fishaudio/fish-speech-1.5", "FunAudioLLM/CosyVoice2-0.5B"],
      "default": "fishaudio/fish-speech-1.5"
    },
    "volume": {
      "type": "integer",
      "minimum": 0,
      "maximum": 100,
      "default": 70
    },
    "speed": {
      "type": "number",
      "minimum": 0.25,
      "maximum": 4.0,
      "default": 1.0
    },
    "codec_name": {
      "type": "string",
      "default": "audio_dac"
    },
    "api_key": {
      "type": "string",
      "description": "Optional override; if omitted the skill reads /fatfs/config/siliconflow_key.txt"
    }
  },
  "required": ["text"]
}
```

## Tool Call Examples

Speak a reminder:

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/control_speak.lua",
  "args": { "action": "speak", "text": "喝水时间到了" },
  "timeout_ms": 20000
}
```

Speak with a different voice and slower speed:

```json
{
  "path": "{CUR_SKILL_DIR}/scripts/control_speak.lua",
  "args": { "text": "今天下午 3 点有会议", "voice": "fishaudio/fish-speech-1.5:bella", "speed": 0.9, "volume": 80 },
  "timeout_ms": 25000
}
```

## Behavior

- Two-piece design (like network_radio): a short-lived `control_speak.lua` (LLM calls this) sends text via `thread.sync` queue to a long-running `speak_daemon.lua` background job.
- The daemon owns `audio_dac` for its whole lifetime; UAC is initialized once and kept alive. This avoids a V3.1-breadboard issue where `bm.deinit_device(audio_dac)` puts the USB stack into a state where the next init times out.
- First call: daemon spawns (adds ~1s). Subsequent calls: instant (daemon already running, UAC already up).
- Latency per call: 1–4 seconds from control_speak → first sound (TTS API round-trip dominates).
- Daemon job name: `voice_reminder_speaker`, exclusive group `audio_output` (so it and `network_radio_player` cannot run at the same time).
- Temp MP3 files under `/fatfs/tmp/` are deleted after each playback.
- To stop the daemon (rarely needed): `args = { action: "stop" }`.
- If any step fails, error message describes which step failed.

## Recommended Flow

1. When the user asks to be reminded, notified, or wants the device to say something, use this skill directly.
2. For **scheduled** reminders, combine with `cap_scheduler`: add a schedule whose event routes to this skill with the reminder text as `args.text`.
3. Keep `text` short for reminders — one sentence is ideal; longer text works but the user waits longer for playback.
4. Report the returned status text directly. If it starts with `error:`, tell the user which step failed.
