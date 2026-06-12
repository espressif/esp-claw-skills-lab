-- --------------------------------------------------------------
-- Synchronous control entrypoint for the network radio daemon.
-- --------------------------------------------------------------

local arg_schema = require("arg_schema")
local common = require("radio_common")
local thread = require("thread")

local raw_args = type(args) == "table" and args or {}
local ARG_SCHEMA = {
  volume = arg_schema.int({ default = -1, min = -1, max = common.MAX_VOLUME }),
  wait_ms = arg_schema.int({ default = 8000, min = 1000 }),
}

local parsed = arg_schema.parse(raw_args, ARG_SCHEMA)
local action = type(raw_args.action) == "string" and raw_args.action or "status"
local station = type(raw_args.station) == "string" and raw_args.station or ""
local url = type(raw_args.url) == "string" and raw_args.url or ""
local title = type(raw_args.title) == "string" and raw_args.title or ""
local codec_name = type(raw_args.codec_name) == "string" and raw_args.codec_name ~= "" and raw_args.codec_name or common.DEFAULT_CODEC_NAME

local VALID_ACTIONS = {
  play = true,
  switch = true,
  volume = true,
  stop = true,
  status = true,
}

local function current_script_dir()
  local info = debug.getinfo(1, "S")
  local source = info and info.source or ""
  if source:sub(1, 1) == "@" then
    source = source:sub(2)
  end
  return source:match("^(.*)/[^/]+$")
end

local function daemon_path()
  if type(raw_args.daemon_path) == "string" and raw_args.daemon_path ~= "" then
    return raw_args.daemon_path
  end
  local dir = current_script_dir()
  if not dir then
    error("args.daemon_path is required")
  end
  return dir .. "/radio_player_daemon.lua"
end

local function daemon_job_exists()
  local ok, output = thread.get(common.DAEMON_JOB_NAME)
  if ok then
    return output:find("status=running", 1, true) ~= nil or output:find("status=queued", 1, true) ~= nil
  end
  return false
end

local function start_daemon_if_needed()
  if action == "status" then
    return
  end

  if daemon_job_exists() then
    return
  end

  local ok, err = thread.start(daemon_path(), {
    codec_name = codec_name,
  }, {
    name = common.DAEMON_JOB_NAME,
    exclusive = common.DAEMON_EXCLUSIVE,
    replace = false,
    timeout_ms = 0,
  })
  if not ok then
    local text = tostring(err)
    if (text:find("ESP_ERR_INVALID_STATE", 1, true) or text:find("Conflict with", 1, true) or text:find("exclusive", 1, true)) and daemon_job_exists() then
      return
    end
    if text:find("already", 1, true) or text:find("running", 1, true) then
      return
    end
    print("[network_radio] ERROR: failed to start daemon: " .. text)
    error("failed to start network radio daemon: " .. text)
  end
end

local function wait_status(command_id)
  local deadline = common.now_ms() + parsed.wait_ms
  while common.now_ms() < deadline do
    local remaining = deadline - common.now_ms()
    local wait_ms = remaining > common.QUEUE_RECV_MS and common.QUEUE_RECV_MS or remaining
    local status = common.recv_reply(wait_ms)
    if status and status.command_id == command_id then
      return status
    end
  end
  local status = common.read_json(common.status_path())
  local status_text = " current_status=nil"
  if status then
    status_text = string.format(
      " current_command_id=%s state=%s command_status=%s error=%s",
      tostring(status.command_id or ""),
      tostring(status.state or ""),
      tostring(status.command_status or ""),
      tostring(status.error or ""))
  end
  print("[network_radio] ERROR: command timed out command_id=" .. tostring(command_id) .. status_text)
  error("network radio command timed out:" .. status_text)
end

local function print_status(status)
  if not status then
    print("[network_radio] status=not_running")
    return
  end
  print(string.format(
    "[network_radio] status=%s title=%s volume=%s command_status=%s error=%s",
    tostring(status.state),
    tostring(status.title or ""),
    tostring(status.volume or ""),
    tostring(status.command_status or ""),
    tostring(status.error or "")))
end

local function read_current_status()
  local status = common.read_json(common.status_path())
  if status and (status.state == "playing" or status.state == "idle" or status.state == "ended") and not daemon_job_exists() then
    status.state = "stopped"
    status.command_status = "stale_status_repaired"
    status.updated_at_ms = common.now_ms()
    common.write_json(common.status_path(), status)
  end
  return status
end

local function validate()
  if not VALID_ACTIONS[action] then
    error("args.action must be play, switch, volume, stop, or status")
  end
  if (action == "play" or action == "switch") and station == "" and url == "" then
    error("args.station or args.url is required for " .. action)
  end
  if action == "volume" and parsed.volume < 0 then
    error("args.volume is required for volume action")
  end
end

local function run()
  validate()
  common.ensure_control_dir()
  common.ensure_queues()

  local command_id = common.new_command_id()
  local command = {
    command_id = command_id,
    action = action,
    station = station,
    url = url,
    title = title,
    codec_name = codec_name,
    created_at_ms = common.now_ms(),
  }

  if parsed.volume >= 0 then
    command.volume = parsed.volume
  end

  local daemon_running = daemon_job_exists()
  if action == "status" and not daemon_running then
    print_status(read_current_status())
    return
  end

  if action == "stop" and not daemon_running then
    local status = {
      state = "stopped",
      title = "",
      url = "",
      volume = parsed.volume >= 0 and parsed.volume or common.DEFAULT_VOLUME,
      codec_name = codec_name,
      command_id = command_id,
      command_status = "done",
      updated_at_ms = common.now_ms(),
    }
    common.write_json(common.status_path(), status)
    print_status(status)
    return
  end

  common.lock_control(parsed.wait_ms)
  local ok, err = xpcall(function()
    local active = daemon_job_exists()
    if action == "status" and not active then
      print_status(read_current_status())
      return
    end
    if action == "stop" and not active then
      local status = {
        state = "stopped",
        title = "",
        url = "",
        volume = parsed.volume >= 0 and parsed.volume or common.DEFAULT_VOLUME,
        codec_name = codec_name,
        command_id = command_id,
        command_status = "done",
        updated_at_ms = common.now_ms(),
      }
      common.write_json(common.status_path(), status)
      print_status(status)
      return
    end
    if not active then
      common.drain_queue(common.COMMAND_QUEUE_NAME)
      common.drain_queue(common.REPLY_QUEUE_NAME)
      start_daemon_if_needed()
    end

    local sent, send_err = common.send_command(command, common.QUEUE_SEND_MS)
    if not sent then
      error("failed to send network radio command: " .. tostring(send_err))
    end

    local status = wait_status(command_id)
    if status.command_status == "error" then
      error(tostring(status.error or "network radio command failed"))
    end
    print_status(status)
  end, debug.traceback)
  common.unlock_control()
  if not ok then
    error(err)
  end
end

math.randomseed(os.time())
local ok, err = xpcall(run, debug.traceback)
if not ok then
  print("[network_radio] ERROR: " .. tostring(err))
  error(err)
end
