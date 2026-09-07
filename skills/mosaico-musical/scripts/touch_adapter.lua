-- touch_adapter.lua: deliver an ordered stream of touch events to the entry.
--
-- The device backend owns exactly one `lcd_touch.new_stream` and forwards its
-- queued events. The hosted backend drains the simulator's `touch.poll()`
-- source into the same shape. Both expose:
--   events, stats = adapter:drain(limit)   -- ordered {type,x,y,timestamp_us}
--   adapter:close()
-- The adapter never collapses events into a pressed/x/y snapshot; every
-- down/move/up is preserved in order so a swipe's crossings survive.

local M = {}

local MAX_DRAIN_EVENTS = 64
local STREAM_INTERVAL_MS = 5
local STREAM_QUEUE_DEPTH = 64
-- Synthetic clock step for hosted events that carry no timestamp of their own,
-- so hosted timestamps are strictly monotonic across drains.
local HOSTED_TS_STEP_US = 1000

local Adapter = {}
Adapter.__index = Adapter

local function to_number(value, fallback)
    return tonumber(value) or fallback
end

-- Hosted events arrive as {type|event = "down"/"move"/"up", x|px, y|py}. Some
-- builds only report a pressed flag, so derive the kind from it.
local function event_kind(event, pressed_now)
    local raw = event.type or event.event
    if raw == "down" or raw == "press" or raw == "pressed" then
        return "down"
    end
    if raw == "up" or raw == "release" or raw == "released" then
        return "up"
    end
    if raw == "move" or raw == "motion" or raw == "drag" then
        return "move"
    end
    if event.pressed == true then
        return pressed_now and "move" or "down"
    end
    if event.pressed == false then
        return "up"
    end
    return nil
end

local function try_device(board_manager)
    if type(board_manager) ~= "table"
        or type(board_manager.get_lcd_touch_handle) ~= "function" then
        return nil, nil
    end
    local mod_ok, lcd_touch = pcall(require, "lcd_touch")
    if not mod_ok or type(lcd_touch) ~= "table"
        or type(lcd_touch.new_stream) ~= "function" then
        return nil, nil
    end
    local ok, handle = pcall(board_manager.get_lcd_touch_handle, "lcd_touch")
    if not ok or handle == nil then
        return nil, nil
    end
    local sok, stream = pcall(lcd_touch.new_stream, handle, {
        interval_ms = STREAM_INTERVAL_MS,
        queue_depth = STREAM_QUEUE_DEPTH,
    })
    if not sok then
        return nil, "touch stream init failed: " .. tostring(stream)
    end
    if stream == nil then
        return nil, "touch stream init returned nil"
    end
    return { lcd_touch = lcd_touch, stream = stream }
end

local function try_hosted()
    local ok, touch = pcall(require, "touch")
    if ok and type(touch) == "table" and type(touch.poll) == "function" then
        return touch
    end
    return nil
end

function M.new(board_manager)
    local self = setmetatable({
        source = "none",
        stream = nil,
        lcd_touch = nil,
        touch = nil,
        pressed = false,
        last_x = 0,
        last_y = 0,
        clock_us = 0,
        stats = {
            queued = 0,
            dropped_moves = 0,
            dropped_edges = 0,
            high_watermark = 0,
        },
    }, Adapter)

    local device, device_err = try_device(board_manager)
    if device ~= nil then
        self.stream = device.stream
        self.lcd_touch = device.lcd_touch
        self.source = "device"
        return self
    end

    -- `device_err` is non-nil only after a real `lcd_touch` handle was
    -- obtained and `new_stream` then failed (raised or returned nil). That is
    -- a real-device stream error, not an absent backend: abort with it and
    -- never silently degrade to hosted polling, which would leave a physical
    -- panel dark while the instrument quietly ran off a simulator source.
    -- Hosted fallback is legal only when no device handle was ever obtained
    -- (device_err == nil).
    if device_err ~= nil then
        return nil, device_err
    end

    local hosted = try_hosted()
    if hosted ~= nil then
        self.touch = hosted
        self.source = "hosted"
        return self
    end

    return nil, "touch unavailable: no usable device or hosted backend"
end

local function clamp_limit(limit)
    limit = math.floor(to_number(limit, MAX_DRAIN_EVENTS))
    if limit < 1 then
        return 1
    end
    return limit
end

local function normalize_event(event)
    -- `timestamp_us` is carried opaquely: the native `lcd_touch` stream exposes
    -- it as a decimal string that encodes a full 64-bit microsecond value, which
    -- a 32-bit Lua `tonumber` would silently truncate. Coordinates are small and
    -- may be normalized, but the timestamp must pass through untouched so the
    -- native mixer can parse it back to an exact int64.
    return {
        type = event.type,
        x = to_number(event.x, 0),
        y = to_number(event.y, 0),
        timestamp_us = event.timestamp_us,
    }
end

function Adapter:drain_device(limit)
    local ok, events, stats = pcall(function()
        return self.stream:drain(limit)
    end)
    if not ok then
        error("touch drain failed: " .. tostring(events), 0)
    end
    local out = {}
    if type(events) == "table" then
        for i = 1, #events do
            out[i] = normalize_event(events[i])
        end
    end
    return out, (type(stats) == "table") and stats or self.stats
end

function Adapter:drain_hosted(limit)
    local out = {}
    for _ = 1, limit do
        local ok, event = pcall(self.touch.poll)
        if not ok then
            error("touch poll failed: " .. tostring(event), 0)
        end
        if type(event) ~= "table" then
            break
        end
        local kind = event_kind(event, self.pressed)
        if kind ~= nil then
            local x = to_number(event.x, to_number(event.px, self.last_x))
            local y = to_number(event.y, to_number(event.py, self.last_y))
            self.last_x, self.last_y = x, y
            self.clock_us = self.clock_us + HOSTED_TS_STEP_US
            local ts = tonumber(event.timestamp_us) or self.clock_us
            out[#out + 1] = { type = kind, x = x, y = y, timestamp_us = ts }
            if kind == "down" then
                self.pressed = true
            elseif kind == "up" then
                self.pressed = false
            end
        end
    end
    self.stats.queued = 0
    self.stats.high_watermark = math.max(self.stats.high_watermark, #out)
    return out, self.stats
end

function Adapter:drain(limit)
    limit = clamp_limit(limit)
    if self.source == "device" then
        return self:drain_device(limit)
    elseif self.source == "hosted" then
        return self:drain_hosted(limit)
    end
    error("touch adapter has no usable backend", 0)
end

function Adapter:close()
    if self.source == "device" and self.stream ~= nil then
        pcall(function() self.stream:close() end)
        self.stream = nil
    end
    self.source = "closed"
end

return M
