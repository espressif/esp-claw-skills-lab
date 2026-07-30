-- --------------------------------------------------------------
-- Shared helpers for the network radio skill.
-- --------------------------------------------------------------

local json = require("json")
local storage = require("storage")
local system = require("system")
local thread = require("thread")

local M = {}

M.DEFAULT_CODEC_NAME = "audio_dac"
M.DEFAULT_VOLUME = 70
M.MIN_VOLUME = 0
M.MAX_VOLUME = 100
M.DAEMON_JOB_NAME = "network_radio_player"
M.DAEMON_EXCLUSIVE = "audio_output"
M.CONTROL_ROOT = "/ramfs"
M.CONTROL_DIR_NAME = "network_radio"
M.STATUS_FILE_NAME = "status.json"
M.COMMAND_QUEUE_NAME = "network_radio_cmd"
M.REPLY_QUEUE_NAME = "network_radio_reply"
M.CONTROL_LOCK_NAME = "network_radio_control_lock"
M.QUEUE_DEPTH = 2
M.QUEUE_ITEM_SIZE = 2048
M.QUEUE_RECV_MS = 500
M.QUEUE_SEND_MS = 1000

M.STATIONS = {
  { title = "崂山921", url = "http://lhttp.qingting.fm/live/20212426/64k.mp3" },
  { title = "长沙101.7城市之声", url = "http://lhttp.qingting.fm/live/4237/64k.mp3" },
  { title = "上海经典947", url = "http://lhttp.qingting.fm/live/267/64k.mp3" },
  { title = "湖北经典音乐广播", url = "http://lhttp.qingting.fm/live/1296/64k.mp3" },
  { title = "成都年代音乐怀旧好声音", url = "http://lhttp.qingting.fm/live/20211686/64k.mp3" },
  { title = "山东经典音乐广播", url = "http://lhttp.qingting.fm/live/20240/64k.mp3" },
  { title = "杭州90.7", url = "http://lhttp.qingting.fm/live/15318146/64k.mp3" },
  { title = "天津TIKI 100.5", url = "http://lhttp.qingting.fm/live/20003/64k.mp3" },
}

function M.control_dir()
  return storage.join_path(M.CONTROL_ROOT, M.CONTROL_DIR_NAME)
end

function M.status_path()
  return storage.join_path(M.control_dir(), M.STATUS_FILE_NAME)
end

function M.ensure_control_dir()
  local dir = M.control_dir()
  if storage.exists(dir) then
    return dir
  end
  local ok, err = storage.mkdir(dir)
  if ok == false then
    print("[network_radio] ERROR: failed to create control dir: " .. tostring(err))
    error("failed to create network_radio control dir: " .. tostring(err))
  end
  return dir
end

function M.read_json(path)
  if not storage.exists(path) then
    return nil
  end
  local text, read_err = storage.read_file(path)
  if not text or text == "" then
    return nil, read_err
  end
  local ok, value = pcall(json.decode, text)
  if not ok then
    print("[network_radio] ERROR: invalid json file=" .. tostring(path) .. " err=" .. tostring(value))
    return nil, value
  end
  return value
end

function M.write_json(path, value)
  M.ensure_control_dir()
  local text = json.encode(value)
  local tmp_path = path .. ".tmp"
  local ok, err = storage.write_file(tmp_path, text)
  if ok == false then
    print("[network_radio] ERROR: failed to write temp json: " .. tostring(err))
    error("failed to write " .. tmp_path .. ": " .. tostring(err))
  end
  pcall(storage.remove, path)
  ok, err = storage.rename(tmp_path, path)
  if ok == false then
    print("[network_radio] ERROR: failed to publish json: " .. tostring(err))
    error("failed to rename " .. tmp_path .. " to " .. path .. ": " .. tostring(err))
  end
end

function M.ensure_queue(name)
  local ok, err = thread.sync.queue_create(name, { depth = M.QUEUE_DEPTH, item_size = M.QUEUE_ITEM_SIZE })
  if ok or err == "exists" then
    return true
  end
  print("[network_radio] ERROR: failed to create queue " .. tostring(name) .. ": " .. tostring(err))
  error("failed to create network radio queue " .. tostring(name) .. ": " .. tostring(err))
end

function M.ensure_queues()
  M.ensure_queue(M.COMMAND_QUEUE_NAME)
  M.ensure_queue(M.REPLY_QUEUE_NAME)
end

function M.ensure_control_lock()
  local ok, err = thread.sync.lock_create(M.CONTROL_LOCK_NAME)
  if ok or err == "exists" then
    return true
  end
  print("[network_radio] ERROR: failed to create control lock: " .. tostring(err))
  error("failed to create network radio control lock: " .. tostring(err))
end

function M.lock_control(timeout_ms)
  M.ensure_control_lock()
  local ok, err = thread.sync.lock(M.CONTROL_LOCK_NAME, timeout_ms or M.QUEUE_SEND_MS)
  if not ok then
    print("[network_radio] ERROR: failed to lock control channel: " .. tostring(err))
    error("failed to lock network radio control channel: " .. tostring(err))
  end
end

function M.unlock_control()
  local ok, err = thread.sync.unlock(M.CONTROL_LOCK_NAME)
  if not ok and err ~= "not_found" and err ~= "not_owner" then
    print("[network_radio] WARN: failed to unlock control channel: " .. tostring(err))
  end
end

local function decode_queue_json(text, queue_name)
  local ok, value = pcall(json.decode, text)
  if not ok then
    print("[network_radio] ERROR: invalid queue json queue=" .. tostring(queue_name) .. " err=" .. tostring(value))
    return nil, value
  end
  return value
end

function M.queue_send_json(name, value, timeout_ms)
  local text = json.encode(value)
  local ok, err = thread.sync.queue_send(name, text, timeout_ms or M.QUEUE_SEND_MS)
  if not ok then
    print("[network_radio] ERROR: failed to send queue message queue=" .. tostring(name) .. " err=" .. tostring(err))
    return nil, err
  end
  return true
end

function M.queue_recv_json(name, timeout_ms)
  local text, err = thread.sync.queue_recv(name, timeout_ms or 0)
  if not text then
    return nil, err
  end
  return decode_queue_json(text, name)
end

function M.send_command(command, timeout_ms)
  return M.queue_send_json(M.COMMAND_QUEUE_NAME, command, timeout_ms)
end

function M.recv_command(timeout_ms)
  return M.queue_recv_json(M.COMMAND_QUEUE_NAME, timeout_ms or M.QUEUE_RECV_MS)
end

function M.send_reply(status, timeout_ms)
  return M.queue_send_json(M.REPLY_QUEUE_NAME, status, timeout_ms)
end

function M.recv_reply(timeout_ms)
  return M.queue_recv_json(M.REPLY_QUEUE_NAME, timeout_ms or M.QUEUE_RECV_MS)
end

function M.drain_queue(name, limit)
  for _ = 1, limit or M.QUEUE_DEPTH do
    local msg = thread.sync.queue_recv(name, 0)
    if not msg then
      return
    end
  end
end

function M.now_ms()
  return system.millis()
end

function M.new_command_id()
  return tostring(M.now_ms()) .. "_" .. tostring(math.random(100000, 999999))
end

function M.clamp_volume(volume)
  local n = tonumber(volume)
  if not n then
    return nil
  end
  n = math.floor(n)
  if n < M.MIN_VOLUME then
    n = M.MIN_VOLUME
  elseif n > M.MAX_VOLUME then
    n = M.MAX_VOLUME
  end
  return n
end

function M.is_http_stream(url)
  return type(url) == "string" and url:match("^https?://") ~= nil
end

local function station_matches(title, query)
  if type(query) ~= "string" or query == "" then
    return false
  end
  local title_lower = string.lower(title)
  local query_lower = string.lower(query)
  return title == query or title_lower == query_lower or string.find(title_lower, query_lower, 1, true) ~= nil
end

function M.resolve_station(station_name, url, title)
  if type(url) == "string" and url ~= "" then
    if not M.is_http_stream(url) then
      error("args.url must start with http:// or https://")
    end
    return title and title ~= "" and title or "自定义电台", url
  end

  for _, station in ipairs(M.STATIONS) do
    if station_matches(station.title, station_name) then
      return station.title, station.url
    end
  end

  error("unknown station: " .. tostring(station_name))
end

function M.station_titles()
  local titles = {}
  for i, station in ipairs(M.STATIONS) do
    titles[i] = station.title
  end
  return titles
end

return M
