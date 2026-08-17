-- --------------------------------------------------------------
-- Push a notification message onto the OLED status daemon's queue.
--
-- Args:
--   text:        string, required — message body (auto-wraps to
--                4 lines of 25 chars ASCII)
--   duration_ms: integer, optional (default 8000, min 500,
--                max 60000)
--
-- Fire-and-forget: this script does not wait for the daemon to
-- render. If the daemon is not running, the queue must still exist
-- (created lazily below) and the message will be picked up when
-- the daemon starts.
-- --------------------------------------------------------------

local json = require("json")
local thread = require("thread")

local NOTIFY_QUEUE = "oled_status_notify"
local NOTIFY_QUEUE_DEPTH = 4
local NOTIFY_QUEUE_ITEM = 1024

local raw = type(args) == "table" and args or {}
local text = type(raw.text) == "string" and raw.text or ""
if text == "" then
  error("oled_notify: 'text' is required")
end

local duration_ms = tonumber(raw.duration_ms) or 8000
if duration_ms < 500 then duration_ms = 500 end
if duration_ms > 60000 then duration_ms = 60000 end

local ok, err = thread.sync.queue_create(NOTIFY_QUEUE, {
  depth = NOTIFY_QUEUE_DEPTH,
  item_size = NOTIFY_QUEUE_ITEM,
})
if not ok and err ~= "exists" then
  error("oled_notify: queue_create failed: " .. tostring(err))
end

local payload = json.encode({
  text = text,
  duration_ms = duration_ms,
})

-- If the queue is full (daemon overwhelmed), drop the oldest entry
-- so the new message wins. Notifications are ephemeral; latest > oldest.
local sent, send_err = thread.sync.queue_send(NOTIFY_QUEUE, payload, 200)
if not sent then
  -- Try to make room by draining one, then retry once.
  thread.sync.queue_recv(NOTIFY_QUEUE, 0)
  sent, send_err = thread.sync.queue_send(NOTIFY_QUEUE, payload, 200)
end

if not sent then
  error("oled_notify: queue_send failed: " .. tostring(send_err))
end

print(string.format("[oled_notify] pushed %d chars for %dms", #text, duration_ms))
