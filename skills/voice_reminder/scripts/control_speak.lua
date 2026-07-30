-- --------------------------------------------------------------
-- voice_reminder control script: short-lived, LLM/scheduler/console
-- calls this each time. Ensures the daemon is alive, sends a "speak"
-- command via queue, waits for the reply, and returns.
--
-- Also coordinates with network_radio: if the radio is playing when
-- speak arrives, we capture its state, stop it, speak, then restart
-- it with the same station+volume. Emulates the "duck for reminder"
-- behavior of consumer smart speakers using stop+resume (V3.1 audio
-- pipeline can't real-mix two streams).
-- --------------------------------------------------------------

local capability = require("capability")
local common = require("speak_common")
local json = require("json")
local storage = require("storage")
local system = require("system")
local thread = require("thread")

local raw = type(args) == "table" and args or {}
local text = type(raw.text) == "string" and raw.text or ""
if text == "" and raw.action ~= "stop" and raw.action ~= "status" then
  error("voice_reminder: 'text' is required")
end

-- ---------- network_radio coordination ----------
local RADIO_JOB_NAME = "network_radio_player"
local RADIO_CMD_QUEUE = "network_radio_cmd"
local RADIO_REPLY_QUEUE = "network_radio_reply"
local RADIO_DAEMON_PATH = "/fatfs/skills/network_radio/scripts/radio_player_daemon.lua"
local RADIO_STATUS_PATH = "/ramfs/network_radio/status.json"

local function job_alive(name)
  local ok, info = thread.get(name)
  if not ok or not info then return false end
  local s = tostring(info)
  return s:find("status=running", 1, true) ~= nil
      or s:find("status=queued", 1, true) ~= nil
end

local function wait_job_gone(name, timeout_ms)
  local deadline = system.millis() + (timeout_ms or 5000)
  while system.millis() < deadline do
    if not job_alive(name) then return true end
  end
  return false
end

-- Read radio state from its status file. Returns table or nil.
local function read_radio_state()
  local content = storage.read_file(RADIO_STATUS_PATH)
  if not content or content == "" then return nil end
  local ok, value = pcall(json.decode, content)
  if not ok or type(value) ~= "table" then return nil end
  return value
end

-- Send stop to radio and wait for it to exit. Returns saved state
-- (title/url/volume) if radio was actually playing, else nil.
local function pause_radio_if_playing()
  if not job_alive(RADIO_JOB_NAME) then return nil end

  local state = read_radio_state()
  local was_playing = state and state.state == "playing"
  local saved = was_playing and {
    title = state.title or "",
    url = state.url or "",
    volume = tonumber(state.volume) or common.DEFAULT_VOLUME,
  } or nil

  -- Drain any stale radio replies before sending stop
  for _ = 1, 4 do thread.sync.queue_recv(RADIO_REPLY_QUEUE, 0) end

  local stop_msg = json.encode({
    action = "stop",
    command_id = "voice_pause_" .. tostring(system.millis()),
  })
  local sent = thread.sync.queue_send(RADIO_CMD_QUEUE, stop_msg, common.QUEUE_SEND_MS)
  if not sent then
    print("[voice_reminder] could not send stop to radio; leaving it as-is")
    return nil
  end

  if not wait_job_gone(RADIO_JOB_NAME, 4000) then
    print("[voice_reminder] radio still alive after 4s stop; giving up on pause")
    return nil
  end

  print("[voice_reminder] radio paused; saved state title=" ..
        tostring(saved and saved.title) .. " volume=" .. tostring(saved and saved.volume))
  return saved
end

local function resume_radio(saved)
  if not saved or (saved.title == "" and saved.url == "") then return end
  if job_alive(RADIO_JOB_NAME) then
    print("[voice_reminder] radio already back up; skipping resume")
    return
  end

  local spawn_payload = json.encode({
    path = RADIO_DAEMON_PATH,
    args = {},
    name = RADIO_JOB_NAME,
    exclusive = "audio_output",
    replace = false,
  })
  local ok, out, err = capability.call("lua_run_script_async", spawn_payload)
  if not ok then
    print("[voice_reminder] failed to respawn radio daemon: " .. tostring(err or out))
    return
  end

  -- Wait for radio daemon to reach recv loop
  local deadline = system.millis() + 3000
  while system.millis() < deadline do
    if job_alive(RADIO_JOB_NAME) then break end
  end

  -- Drain any stale replies then send play
  for _ = 1, 4 do thread.sync.queue_recv(RADIO_REPLY_QUEUE, 0) end
  local play_msg = json.encode({
    action = "play",
    title = saved.title,
    url = saved.url,
    volume = saved.volume,
    command_id = "voice_resume_" .. tostring(system.millis()),
  })
  local sent = thread.sync.queue_send(RADIO_CMD_QUEUE, play_msg, common.QUEUE_SEND_MS)
  if not sent then
    print("[voice_reminder] resume queue_send failed")
    return
  end
  print("[voice_reminder] radio resumed with title=" .. tostring(saved.title))
end

-- ---------- voice_reminder daemon plumbing ----------
local function ensure_queue(name)
  local ok, err = thread.sync.queue_create(name, {
    depth = common.QUEUE_DEPTH,
    item_size = common.QUEUE_ITEM_SIZE,
  })
  if not ok and err ~= "exists" then
    error("voice_reminder: queue_create(" .. name .. ") failed: " .. tostring(err))
  end
end
ensure_queue(common.COMMAND_QUEUE_NAME)
ensure_queue(common.REPLY_QUEUE_NAME)

local function voice_daemon_alive()
  return job_alive(common.DAEMON_JOB_NAME)
end

-- ---------- main flow ----------
-- Pause radio first (if playing). Do this BEFORE spawning voice daemon
-- so audio_output exclusive group is free.
local saved_radio = pause_radio_if_playing()

if not voice_daemon_alive() then
  print("[voice_reminder] daemon not running, spawning it")
  -- Drain any stale voice replies from previous daemon incarnation
  for _ = 1, common.QUEUE_DEPTH do
    thread.sync.queue_recv(common.REPLY_QUEUE_NAME, 0)
  end

  -- Explicitly do NOT set exclusive here: voice daemon must coexist with
  -- network_radio_player daemon (which owns "audio_output"). The two share
  -- the physical UAC codec; control_speak.lua serializes access by
  -- pausing radio before speak and resuming after.
  local payload_tbl = {
    path = "/fatfs/skills/voice_reminder/scripts/speak_daemon.lua",
    args = {},
    name = common.DAEMON_JOB_NAME,
    replace = false,
  }
  if common.DAEMON_EXCLUSIVE then payload_tbl.exclusive = common.DAEMON_EXCLUSIVE end
  local payload = json.encode(payload_tbl)
  local ok, out, err = capability.call("lua_run_script_async", payload)
  if not ok then
    -- If we paused radio, restore it before erroring out
    resume_radio(saved_radio)
    error("voice_reminder: failed to spawn daemon: " .. tostring(err or out))
  end
  print("[voice_reminder] daemon spawn ok: " .. tostring(out))

  local deadline = system.millis() + 3000
  while system.millis() < deadline do
    if voice_daemon_alive() then break end
  end
end

-- Send command + wait reply
local cmd_id = system.millis()
local cmd = {
  action = raw.action or "speak",
  text = text,
  voice = raw.voice,
  model = raw.model,
  volume = raw.volume,
  speed = raw.speed,
  _id = cmd_id,
}

for _ = 1, common.QUEUE_DEPTH do
  thread.sync.queue_recv(common.REPLY_QUEUE_NAME, 0)
end

local send_ok, send_err = thread.sync.queue_send(
  common.COMMAND_QUEUE_NAME, json.encode(cmd), common.QUEUE_SEND_MS)
if not send_ok then
  resume_radio(saved_radio)
  error("voice_reminder: queue_send failed: " .. tostring(send_err))
end

local final_result = nil
local final_error = nil
local deadline = system.millis() + 45000
while system.millis() < deadline do
  local text_reply = thread.sync.queue_recv(common.REPLY_QUEUE_NAME, 500)
  if text_reply then
    local ok, reply = pcall(json.decode, text_reply)
    if ok and type(reply) == "table" and reply.cmd_id == cmd_id then
      if reply.ok then
        final_result = string.format("spoken: %s", tostring(reply.spoken or ""))
      else
        final_error = "voice_reminder: daemon returned error: " .. tostring(reply.error)
      end
      break
    end
  end
end

-- Always resume radio if we paused it, whether speak succeeded or not.
resume_radio(saved_radio)

if final_error then error(final_error) end
if final_result then return final_result end
error("voice_reminder: timeout waiting for daemon reply")
