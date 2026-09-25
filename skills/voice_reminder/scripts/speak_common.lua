-- Shared constants for voice_reminder daemon and control scripts.
local M = {}

M.DEFAULT_CODEC_NAME = "audio_dac"
M.DEFAULT_VOLUME = 70
M.DEFAULT_MODEL = "fishaudio/fish-speech-1.5"
M.DEFAULT_VOICE = "fishaudio/fish-speech-1.5:anna"

M.DAEMON_JOB_NAME = "voice_reminder_speaker"
-- Intentionally NOT in "audio_output" exclusive group so we can coexist
-- with network_radio_player daemon. control_speak.lua coordinates who
-- actually plays via stop-radio → speak → resume-radio.
M.DAEMON_EXCLUSIVE = nil

M.COMMAND_QUEUE_NAME = "voice_reminder_cmd"
M.REPLY_QUEUE_NAME = "voice_reminder_reply"

M.QUEUE_DEPTH = 4
M.QUEUE_ITEM_SIZE = 2048     -- covers our TTS text + JSON overhead
M.QUEUE_SEND_MS = 2000
M.QUEUE_RECV_MS = 500

-- After player:play(...,{wait=true}) returns, this many ms of buffered
-- audio may still be in flight through: audio codec → UAC host URBs →
-- USB FIFO → USB speaker internal buffer. Sleep this long before we
-- close output so the tail actually reaches the speaker.
-- Empirically 800ms covers cheap USB speakers; raise if last words
-- still get clipped.
M.PLAY_TAIL_DRAIN_MS = 800

-- Notification chimes played before/after the TTS clip. Alexa-style
-- two-tone start ("ding-dong"), single-tone end ("ding"). Set any
-- duration_ms to 0 to disable that chime.
M.CHIME_START_FREQ_1_HZ = 880    -- A5, higher first note
M.CHIME_START_FREQ_2_HZ = 660    -- E5, lower second note
M.CHIME_START_TONE_MS = 100
M.CHIME_START_GAP_MS = 60
M.CHIME_END_FREQ_HZ = 660
M.CHIME_END_TONE_MS = 80

M.KEY_PATH = "/fatfs/config/siliconflow_key.txt"
M.TMP_DIR = "/fatfs/tmp"
M.TTS_URL = "https://api.siliconflow.com/v1/audio/speech"
M.TTS_TIMEOUT_MS = 30000
M.TTS_MAX_BYTES = 2 * 1024 * 1024

return M
