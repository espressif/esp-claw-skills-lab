-- Track one contact by ID so another finger cannot interrupt a strum.
local system = require("system")
local M = {}

function M.new(screen)
    if not screen:info().touch_available then return nil, "built-in touch unavailable" end
    local adapter = { source = "device" }
    function adapter:drain()
        local point
        for _, candidate in ipairs(screen:touch().points) do
            if not self.previous or candidate.id == self.previous.id then point = candidate; break end
        end
        local events, previous = {}, self.previous
        local kind
        if point and not previous then kind = "down"
        elseif not point and previous then kind = "up"
        elseif point and (point.x ~= previous.x or point.y ~= previous.y) then kind = "move" end
        if kind then
            local position = point or previous
            events[1] = { type = kind, x = position.x, y = position.y, timestamp_us = string.format("%.0f", system.millis() * 1000.0) }
        end
        self.previous = point
        return events, { queued = 0, dropped_moves = 0, dropped_edges = 0, high_watermark = #events }
    end
    function adapter:close() self.previous = nil end
    return adapter
end

return M
