-- --------------------------------------------------------------
-- Apply a volume delta / mute toggle from board volume buttons.
--
-- Behavior:
--   1. Always maintains a persistent "master volume" at
--      /fatfs/board_button_volume_master.json — this is the source
--      of truth for other skills (e.g. voice_reminder) that want to
--      honor button-adjusted volume as their default.
--   2. If network_radio is playing / idle, also pushes the new
--      volume live via its control script so the change is audible
--      immediately.
--   3. Mute toggle: when unmuting, restores the volume that was
--      active before the mute (falls back to 70 if none saved).
--
-- Args (from router rule):
--   event_type: "vol_up" | "vol_down" | "mute"
--   event_key:  "click"  | "hold"     | "toggle"  (informational)
--   delta:      number, percent points to add/subtract (default 10)
--   delta_str:  string alternative for delta (router templates
--               render values as strings)
-- --------------------------------------------------------------

local json = require("json")
local storage = require("storage")
local capability = require("capability")

local a = type(args) == "table" and args or {}
local event_type = tostring(a.event_type or "")
local delta = tonumber(a.delta) or tonumber(a.delta_str) or 10
if delta < 1 then delta = 1 end
if delta > 100 then delta = 100 end

local STATUS_PATH = "/ramfs/network_radio/status.json"
local CONTROL_SCRIPT = "/fatfs/skills/network_radio/scripts/control_network_radio.lua"
local MASTER_VOLUME_PATH = storage.join_path(storage.get_root_dir(),
                                             "board_button_volume_master.json")

local function read_json_file(path)
  if not storage.exists(path) then
    return nil
  end
  local text, err = storage.read_file(path)
  if not text or text == "" then
    return nil, err
  end
  local ok, val = pcall(json.decode, text)
  if not ok then
    return nil, val
  end
  return val
end

local function write_json_file(path, value)
  local text = json.encode(value)
  local ok, err = storage.write_file(path, text)
  if ok == false then
    print("[button_volume] WARN: failed to write " .. path .. ": " .. tostring(err))
  end
end

local function clamp(v)
  v = math.floor(tonumber(v) or 0)
  if v < 0 then v = 0 end
  if v > 100 then v = 100 end
  return v
end

local function read_master()
  local val = read_json_file(MASTER_VOLUME_PATH)
  if type(val) ~= "table" then
    return { volume = 70 }
  end
  val.volume = clamp(val.volume or 70)
  if val.saved_volume ~= nil then
    val.saved_volume = clamp(val.saved_volume)
  end
  return val
end

local master = read_master()

local radio_status = read_json_file(STATUS_PATH)
local radio_active = radio_status and
                     (radio_status.state == "playing" or radio_status.state == "idle")

-- Current volume: prefer live radio value when it's running, else master.
local current = master.volume
if radio_active and tonumber(radio_status.volume) then
  current = clamp(radio_status.volume)
end

local new_vol
if event_type == "vol_up" then
  new_vol = clamp(current + delta)
elseif event_type == "vol_down" then
  new_vol = clamp(current - delta)
elseif event_type == "mute" then
  if current > 0 then
    master.saved_volume = current
    new_vol = 0
  else
    new_vol = clamp(master.saved_volume or 70)
    master.saved_volume = nil
  end
else
  print("[button_volume] unknown event_type=" .. event_type)
  return
end

-- Always persist so voice_reminder and future consumers can read it.
if new_vol ~= master.volume or event_type == "mute" then
  master.volume = new_vol
  write_master(master)
end

if new_vol == current then
  print(string.format("[button_volume] %s: volume unchanged at %d", event_type, current))
  return
end

print(string.format("[button_volume] %s: %d -> %d (radio_active=%s)",
                    event_type, current, new_vol, tostring(radio_active or false)))

if not radio_active then
  return
end

local ok, out, err = capability.call("lua_run_script", {
  path = CONTROL_SCRIPT,
  args = {
    action = "volume",
    volume = new_vol,
  },
})

if not ok then
  print("[button_volume] control call failed: " .. tostring(err))
end
