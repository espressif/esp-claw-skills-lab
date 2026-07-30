-- --------------------------------------------------------------
-- voice_reminder daemon: owns UAC audio_dac for its whole lifetime,
-- receives {text,voice,model,volume,speed} commands via thread.sync
-- queue, calls SiliconFlow TTS, then plays the returned MP3.
-- Never calls bm.deinit_device (see speak.lua bug notes) — on V3.1
-- breadboard, deinit puts the USB stack into a state where the next
-- init times out.
-- --------------------------------------------------------------

local audio = require("audio")
local bm = require("board_manager")
local capability = require("capability")
local common = require("speak_common")
local delay = require("delay")
local json = require("json")
local storage = require("storage")
local thread = require("thread")

local codec_name = common.DEFAULT_CODEC_NAME
local uac_initialized = false
local api_key_cached = nil

-- ---------- helpers ----------
local function ensure_queue(name)
  local ok, err = thread.sync.queue_create(name, {
    depth = common.QUEUE_DEPTH,
    item_size = common.QUEUE_ITEM_SIZE,
  })
  if ok or err == "exists" then return true end
  error("voice_daemon: failed to create queue " .. tostring(name) .. ": " .. tostring(err))
end

local function send_reply(payload)
  local text = json.encode(payload)
  thread.sync.queue_send(common.REPLY_QUEUE_NAME, text, common.QUEUE_SEND_MS)
end

local function recv_command()
  local text, err = thread.sync.queue_recv(common.COMMAND_QUEUE_NAME, common.QUEUE_RECV_MS)
  if not text then return nil end
  local ok, value = pcall(json.decode, text)
  if not ok then
    print("[voice_daemon] bad cmd JSON: " .. tostring(value))
    return nil
  end
  return value
end

local function load_api_key()
  if api_key_cached then return api_key_cached end
  local content = storage.read_file(common.KEY_PATH)
  if not content or content == "" then
    error("voice_daemon: api key file " .. common.KEY_PATH .. " missing/empty")
  end
  api_key_cached = content:gsub("[\r\n%s]+$", "")
  return api_key_cached
end

-- ---------- audio lifecycle ----------
-- UAC driver init is done ONCE (never deinit'd for the daemon's life).
-- output+player are created per-speak and closed after, so the
-- audio_device lock is released between speaks and network_radio can
-- reclaim the speaker.
local function ensure_uac()
  if uac_initialized then return end
  local ok, init_err = bm.init_device(codec_name)
  if not ok then
    error("voice_daemon: init_device(" .. codec_name .. ") failed: " .. tostring(init_err))
  end
  uac_initialized = true
  print("[voice_daemon] UAC initialized")
end

local function play_chime_start(out_obj)
  if common.CHIME_START_TONE_MS > 0 and out_obj.play_tone then
    pcall(function() out_obj:play_tone(common.CHIME_START_FREQ_1_HZ, common.CHIME_START_TONE_MS) end)
    if common.CHIME_START_GAP_MS > 0 then
      delay.delay_ms(common.CHIME_START_GAP_MS)
    end
    pcall(function() out_obj:play_tone(common.CHIME_START_FREQ_2_HZ, common.CHIME_START_TONE_MS) end)
  end
end

local function play_chime_end(out_obj)
  if common.CHIME_END_TONE_MS > 0 and out_obj.play_tone then
    pcall(function() out_obj:play_tone(common.CHIME_END_FREQ_HZ, common.CHIME_END_TONE_MS) end)
  end
end

local function make_output_and_player(volume)
  local codec, rate, channels, bits = bm.get_audio_codec_output_params(codec_name)
  if not codec then
    error("voice_daemon: get_audio_codec_output_params failed: " .. tostring(rate))
  end
  local out_obj, out_err = audio.new_output({
    codec, rate, channels, bits, volume = volume,
  })
  if not out_obj then error("voice_daemon: audio.new_output failed: " .. tostring(out_err)) end
  local pl, pl_err = audio.player({ output = out_obj })
  if not pl then
    pcall(function() out_obj:close() end)
    error("voice_daemon: audio.player failed: " .. tostring(pl_err))
  end
  return out_obj, pl, rate, channels, bits
end

-- ---------- one speak cycle ----------
local function do_speak(cmd)
  local text = type(cmd.text) == "string" and cmd.text or ""
  if text == "" then
    return { ok = false, error = "text is empty" }
  end

  local voice = (type(cmd.voice) == "string" and cmd.voice ~= "") and cmd.voice or common.DEFAULT_VOICE
  local model = (type(cmd.model) == "string" and cmd.model ~= "") and cmd.model or common.DEFAULT_MODEL
  local speed = tonumber(cmd.speed) or 1.0
  local volume = tonumber(cmd.volume) or common.DEFAULT_VOLUME
  if volume < 0 then volume = 0 elseif volume > 100 then volume = 100 end

  -- ensure UAC driver is installed (idempotent)
  ensure_uac()

  -- 1) TTS request
  pcall(storage.mkdir, common.TMP_DIR)
  local mp3_path = string.format("%s/tts_%d.mp3", common.TMP_DIR, cmd._id or 0)
  local body = json.encode({
    model = model, input = text, voice = voice,
    response_format = "mp3", stream = false, speed = speed,
  })
  print(string.format("[voice_daemon] TTS: model=%s voice=%s chars=%d", model, voice, #text))

  local ok, resp, err = capability.call("http_request", {
    url = common.TTS_URL,
    method = "POST",
    headers = {
      ["Authorization"] = "Bearer " .. load_api_key(),
      ["Content-Type"] = "application/json",
    },
    body = body,
    save_path = mp3_path,
    timeout_ms = common.TTS_TIMEOUT_MS,
    max_file_bytes = common.TTS_MAX_BYTES,
  })
  if not ok then
    return { ok = false, error = "TTS http_request failed: " .. tostring(err or resp) }
  end
  local status = tonumber(resp and resp:match("^HTTP%s+(%d+)"))
  if status ~= 200 then
    pcall(storage.remove, mp3_path)
    return { ok = false, error = "TTS HTTP " .. tostring(status) .. ": " .. tostring(resp) }
  end
  print("[voice_daemon] " .. tostring(resp))

  -- 2) create fresh output+player, chime + play + chime, then release
  local out_obj, pl = nil, nil
  local play_ok, play_err = pcall(function()
    out_obj, pl = make_output_and_player(volume)
    -- pre-chime: gives user "reminder incoming" signal before the ~2-3s
    -- TTS-audio-buffer-fill silence that follows.
    play_chime_start(out_obj)
    pl:play(mp3_path, { wait = true })
    -- post-chime: marks the end of the reminder before radio resumes.
    play_chime_end(out_obj)
    -- wait=true only guarantees the GMF pipeline finished. The tail of
    -- the audio (post-chime tone included) is still buffered downstream
    -- in the audio codec, UAC host URBs, USB FIFO, and the physical
    -- USB speaker's internal buffer. Closing the player immediately
    -- truncates that tail. Sleep long enough for the downstream chain
    -- to drain before we release output.
    delay.delay_ms(common.PLAY_TAIL_DRAIN_MS)
  end)
  -- Always release audio_device lock so network_radio can reclaim it
  if pl then pcall(function() pl:close() end) end
  if out_obj then pcall(function() out_obj:close() end) end
  pcall(storage.remove, mp3_path)
  if not play_ok then
    return { ok = false, error = "play failed: " .. tostring(play_err) }
  end

  return { ok = true, spoken = text, voice = voice }
end

-- ---------- main loop ----------
ensure_queue(common.COMMAND_QUEUE_NAME)
ensure_queue(common.REPLY_QUEUE_NAME)

print("[voice_daemon] started, waiting for commands on " .. common.COMMAND_QUEUE_NAME)

while true do
  local cmd = recv_command()
  if cmd then
    if cmd.action == "stop" then
      print("[voice_daemon] stop requested, exiting")
      send_reply({ ok = true, stopped = true, cmd_id = cmd._id })
      break
    elseif cmd.action == "speak" or cmd.action == nil then
      local result = do_speak(cmd)
      result.cmd_id = cmd._id
      send_reply(result)
    else
      send_reply({ ok = false, error = "unknown action: " .. tostring(cmd.action), cmd_id = cmd._id })
    end
  end
end

-- cleanup on stop (rare — daemon usually runs forever).
-- output/player are already per-speak scoped, nothing global to close.
-- Intentionally NOT calling bm.deinit_device — keeps UAC alive for the
-- next daemon incarnation.
