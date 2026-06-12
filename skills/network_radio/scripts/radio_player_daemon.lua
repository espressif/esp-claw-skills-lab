-- --------------------------------------------------------------
-- Long-running network radio player daemon.
-- --------------------------------------------------------------

local audio = require("audio")
local bm = require("board_manager")
local common = require("radio_common")

local raw_args = type(args) == "table" and args or {}
local codec_name = type(raw_args.codec_name) == "string" and raw_args.codec_name ~= "" and raw_args.codec_name or common.DEFAULT_CODEC_NAME

local output = nil
local player = nil
local last_command_id = nil
local state = {
  state = "idle",
  title = "",
  url = "",
  volume = common.DEFAULT_VOLUME,
  codec_name = codec_name,
  updated_at_ms = common.now_ms(),
}

local function publish_status(extra)
  state.updated_at_ms = common.now_ms()
  if type(extra) == "table" then
    for key, value in pairs(extra) do
      state[key] = value
    end
  end
  common.write_json(common.status_path(), state)
end

local function cleanup()
  if player then
    pcall(function()
      player:stop()
    end)
    pcall(function()
      player:close()
    end)
    player = nil
  end
  if output then
    pcall(function()
      output:close()
    end)
    output = nil
  end
end

local function ensure_output(volume)
  if output then
    return
  end

  local codec, rate, channels, bits = bm.get_audio_codec_output_params(codec_name)
  if not codec then
    local message = "get_audio_codec_output_params(" .. tostring(codec_name) .. ") failed: " .. tostring(rate)
    print("[network_radio] ERROR: " .. message)
    error(message)
  end

  local new_output, output_err = audio.new_output({ codec, rate, channels, bits, volume = volume })
  if not new_output then
    local message = "audio.new_output failed: " .. tostring(output_err)
    print("[network_radio] ERROR: " .. message)
    error(message)
  end

  output = new_output
  local info = output:info()
  print(string.format("[network_radio] output=%dHz/%dch/%dbit volume=%d", info.sample_rate, info.channels, info.bits, volume))
end

local function ensure_player()
  if player then
    return
  end
  local new_player, player_err = audio.player({ output = output })
  if not new_player then
    local message = "audio.player failed: " .. tostring(player_err)
    print("[network_radio] ERROR: " .. message)
    error(message)
  end
  player = new_player
end

local function stop_playback()
  if player then
    pcall(function()
      player:stop()
    end)
    pcall(function()
      player:close()
    end)
    player = nil
  end
  if output then
    pcall(function()
      output:close()
    end)
    output = nil
  end
end

local function play_station(command)
  local title, url = common.resolve_station(command.station, command.url, command.title)
  local volume = common.clamp_volume(command.volume) or state.volume or common.DEFAULT_VOLUME

  stop_playback()
  ensure_output(volume)
  ensure_player()

  local ok, play_err = player:play(url)
  if not ok then
    local message = "player:play failed: " .. tostring(play_err)
    print("[network_radio] ERROR: " .. message)
    error(message)
  end

  state.state = "playing"
  state.title = title
  state.url = url
  state.volume = volume
  state.error = nil
  print(string.format("[network_radio] playing title=%s volume=%d url=%s", title, volume, url))
end

local function set_volume(command)
  local volume = common.clamp_volume(command.volume)
  if not volume then
    error("args.volume is required for volume action")
  end
  state.volume = volume
  if output then
    local ok, err = output:set_volume(volume)
    if not ok then
      error("output:set_volume failed: " .. tostring(err))
    end
  end
  print("[network_radio] volume=" .. tostring(volume))
end

local function handle_command(command)
  if type(command) ~= "table" or type(command.command_id) ~= "string" or command.command_id == "" then
    return false
  end
  if command.command_id == last_command_id then
    return false
  end

  last_command_id = command.command_id
  local action = command.action
  state.last_command_id = command.command_id

  if action == "play" or action == "switch" then
    play_station(command)
    publish_status({ state = "playing", command_id = command.command_id, command_status = "done" })
  elseif action == "volume" then
    set_volume(command)
    publish_status({ command_id = command.command_id, command_status = "done" })
  elseif action == "status" then
    publish_status({ command_id = command.command_id, command_status = "done" })
  elseif action == "stop" then
    stop_playback()
    publish_status({ state = "stopped", title = "", url = "", command_id = command.command_id, command_status = "done" })
    return true
  else
    error("unknown action: " .. tostring(action))
  end

  return false
end

local function run()
  common.ensure_control_dir()
  common.ensure_queues()
  publish_status({ state = "idle", command_status = "ready" })

  while true do
    local command, recv_err = common.recv_command(common.QUEUE_RECV_MS)
    if command then
      local ok, should_exit_or_err = xpcall(function()
        return handle_command(command)
      end, debug.traceback)

      if not ok then
        local message = tostring(should_exit_or_err)
        print("[network_radio] ERROR: command failed: " .. message)
        state.error = message
        state.state = state.state ~= "playing" and "error" or state.state
        publish_status({ command_id = command.command_id, command_status = "error" })
      end

      local reply_ok, reply_err = common.send_reply(state, common.QUEUE_SEND_MS)
      if not reply_ok then
        print("[network_radio] ERROR: failed to publish command reply: " .. tostring(reply_err))
      end

      if ok and should_exit_or_err then
        return
      end
    elseif recv_err == "stopped" then
      print("[network_radio] daemon stop requested while waiting for command")
      return
    elseif recv_err and recv_err ~= "timeout" then
      print("[network_radio] WARN: command receive failed: " .. tostring(recv_err))
    end
  end
end

math.randomseed(os.time())
local ok, err = xpcall(run, debug.traceback)
cleanup()
if not ok then
  print("[network_radio] ERROR: daemon failed: " .. tostring(err))
  state.error = tostring(err)
  state.state = "error"
  pcall(function()
    publish_status()
  end)
  error(err)
end
