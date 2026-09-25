-- --------------------------------------------------------------
-- OLED status daemon: renders a 4-line status board on the SSD1306
-- (128x32) at ~1 Hz. When another script pushes a notification into
-- the oled_status_notify queue, the daemon flips to a full-screen
-- notification view for its duration_ms, then falls back to the
-- status board.
--
-- Push a notification with oled_status_notify.lua (control script)
-- or directly:
--   thread.sync.queue_send("oled_status_notify",
--     json.encode({text="hello", duration_ms=8000}), 100)
-- --------------------------------------------------------------

local i2c = require("i2c")
local ssd1306 = require("ssd1306")
local system = require("system")
local storage = require("storage")
local json = require("json")
local thread = require("thread")

-- Hardware
local I2C_PORT = 0
local SDA_GPIO = 41
local SCL_GPIO = 42
local I2C_FREQ_HZ = 400000
local OLED_ADDR = 0x3C
local WIDTH = 128
local HEIGHT = 32
local FONT_H = 8
local CHARS_PER_LINE = 25
local MAX_LINES = 4

-- Poll interval; also drives status refresh cadence.
local TICK_MS = 1000

-- Data sources
local RADIO_STATUS_PATH = "/ramfs/network_radio/status.json"
local MASTER_VOLUME_PATH = "/fatfs/board_button_volume_master.json"

-- Notification protocol
local NOTIFY_QUEUE = "oled_status_notify"
local NOTIFY_QUEUE_DEPTH = 4
local NOTIFY_QUEUE_ITEM = 1024
local DEFAULT_NOTIFY_MS = 8000

local function read_json_file(path)
  if not storage.exists(path) then return nil end
  local text = storage.read_file(path)
  if not text or text == "" then return nil end
  local ok, val = pcall(json.decode, text)
  if not ok then return nil end
  return val
end

local function ensure_queue()
  local ok, err = thread.sync.queue_create(NOTIFY_QUEUE, {
    depth = NOTIFY_QUEUE_DEPTH,
    item_size = NOTIFY_QUEUE_ITEM,
  })
  if not ok and err ~= "exists" then
    print("[oled_status] queue_create failed: " .. tostring(err))
  end
end

local function fmt_uptime(sec)
  sec = math.floor(tonumber(sec) or 0)
  local h = math.floor(sec / 3600)
  local m = math.floor((sec % 3600) / 60)
  if h > 0 then
    return string.format("%dh%02dm", h, m)
  end
  return string.format("%dm%02ds", m, sec % 60)
end

-- Radio state -> short label. State values from network_radio:
--   playing / idle / ended / stopped
local function radio_label(state)
  local map = { playing = "play", idle = "idle", ended = "end", stopped = "off" }
  return map[tostring(state)] or (state and tostring(state):sub(1, 4) or "off")
end

local function status_lines()
  local lines = {}

  -- Line 1: WiFi + IP (or state)
  local info = system.info() or {}
  local ip = system.ip()
  if ip and ip ~= "" then
    lines[1] = "WiFi:" .. tostring(ip)
  elseif info.wifi_ssid then
    lines[1] = "WiFi:conn"
  else
    lines[1] = "WiFi:--"
  end

  -- Line 2: Volume (mute-aware)
  local master = read_json_file(MASTER_VOLUME_PATH) or {}
  local vol = tonumber(master.volume) or 70
  if vol == 0 then
    if master.saved_volume then
      lines[2] = string.format("Vol:MUTE (was %d)", math.floor(master.saved_volume))
    else
      lines[2] = "Vol:MUTE"
    end
  else
    lines[2] = "Vol:" .. tostring(math.floor(vol))
  end

  -- Line 3: Radio
  local radio = read_json_file(RADIO_STATUS_PATH)
  if not radio then
    lines[3] = "Radio:off"
  else
    lines[3] = "Radio:" .. radio_label(radio.state)
  end

  -- Line 4: Time HH:MM:SS + uptime
  local ok_date, date_str = pcall(system.date, "%H:%M:%S")
  local time_part = ok_date and date_str or "--:--:--"
  local up_str = fmt_uptime(system.uptime())
  lines[4] = string.format("%s UP:%s", time_part, up_str)

  return lines
end

local function wrap_notification(text)
  local lines = {}
  local remaining = text or ""
  -- Split on explicit newlines first, then hard-wrap each chunk.
  for chunk in (remaining .. "\n"):gmatch("(.-)\n") do
    local rem = chunk
    while rem ~= "" and #lines < MAX_LINES do
      lines[#lines + 1] = string.sub(rem, 1, CHARS_PER_LINE)
      rem = string.sub(rem, CHARS_PER_LINE + 1)
    end
    if #lines >= MAX_LINES then break end
  end
  return lines
end

local function receive_notification(timeout_ms)
  local msg = thread.sync.queue_recv(NOTIFY_QUEUE, timeout_ms)
  if not msg then return nil end
  local ok, val = pcall(json.decode, msg)
  if not ok or type(val) ~= "table" then return nil end
  local text = type(val.text) == "string" and val.text or ""
  if text == "" then return nil end
  local dur = tonumber(val.duration_ms) or DEFAULT_NOTIFY_MS
  if dur < 500 then dur = 500 end
  if dur > 60000 then dur = 60000 end
  return { text = text, expires_ms = system.millis() + dur }
end

local function open_display()
  local bus = i2c.new(I2C_PORT, SDA_GPIO, SCL_GPIO, I2C_FREQ_HZ)
  local oled = ssd1306.new(bus:device(OLED_ADDR), {
    width = WIDTH, height = HEIGHT, addr = OLED_ADDR,
  })
  oled:init()
  return bus, oled
end

local function render(oled, lines)
  oled:clear(false)
  for i = 1, MAX_LINES do
    local line = lines[i]
    if line and line ~= "" then
      oled:draw_text(0, (i - 1) * FONT_H,
                     string.sub(line, 1, CHARS_PER_LINE), true)
    end
  end
  oled:show()
end

-- ---------------- main loop ----------------

ensure_queue()

local bus, oled = open_display()
print("[oled_status] daemon started")

-- Show a startup splash for a tick so users know we're alive.
render(oled, { "ESP-Claw ready", "", "OLED status daemon", "up" })

local notification = nil

while true do
  -- Wait for a notification up to TICK_MS. Doubles as our poll cadence.
  local remaining_ms = TICK_MS
  if notification then
    local left = notification.expires_ms - system.millis()
    if left < remaining_ms then remaining_ms = left end
    if remaining_ms < 0 then remaining_ms = 0 end
  end
  local new_notif = receive_notification(remaining_ms)
  if new_notif then
    notification = new_notif
  end

  if notification and system.millis() >= notification.expires_ms then
    notification = nil
  end

  local lines
  if notification then
    lines = wrap_notification(notification.text)
  else
    lines = status_lines()
  end
  render(oled, lines)
end
