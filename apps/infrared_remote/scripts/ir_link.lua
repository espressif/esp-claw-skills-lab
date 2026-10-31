-- IR transceiver owned by the App: hardware config, device lifecycle, sending and non-blocking capture.
local IrLink = {}
IrLink.__index = IrLink

local LOG = "[infrared_remote] "

IrLink.FIELDS = {
    {key = "tx_gpio", label = "Transmit GPIO", min = 0, max = 48, step = 1},
    {key = "rx_gpio", label = "Receive GPIO", min = -1, max = 48, step = 1},
    {key = "ctrl_gpio", label = "Enable GPIO", min = -1, max = 48, step = 1},
    {key = "ctrl_active_level", label = "Enable level", min = 0, max = 1, step = 1},
    {key = "carrier_hz", label = "Carrier", min = 30000, max = 60000, step = 1000},
}

-- Clamped integer config from saved values, falling back to defaults per field.
function IrLink.normalize(saved, defaults)
    local hw = {}
    for _, field in ipairs(IrLink.FIELDS) do
        local value = tonumber(saved and saved[field.key]) or tonumber(defaults[field.key]) or field.min
        hw[field.key] = math.max(field.min, math.min(field.max, math.floor(value)))
    end
    return hw
end

function IrLink.validate(hw)
    local tx, rx, ctrl = hw.tx_gpio, hw.rx_gpio, hw.ctrl_gpio
    if (rx >= 0 and rx == tx) or (ctrl >= 0 and (ctrl == tx or ctrl == rx)) then
        return false, "Transmit, receive and enable GPIOs must differ"
    end
    return true
end

function IrLink.format(field, value)
    if value < 0 then return "NC" end
    if field.key == "ctrl_active_level" then return value == 0 and "Low" or "High" end
    if field.key == "carrier_hz" then return string.format("%d kHz", value // 1000) end
    return "GPIO " .. value
end

function IrLink.new(ir)
    return setmetatable({ir = ir, device = nil, config = nil, capture = nil, error = nil}, IrLink)
end

function IrLink:ready() return self.device ~= nil end

function IrLink:can_receive() return self.device ~= nil and self.config.rx_gpio >= 0 end

function IrLink:busy() return self.capture ~= nil end

function IrLink:close()
    self:cancel_capture()
    if not self.device then return end
    local ok, err = pcall(self.device.close, self.device)
    if not ok then print(LOG .. "IR close failed: " .. tostring(err)) end
    self.device = nil
end

function IrLink:open(hw)
    self:close()
    local config = {}
    for _, field in ipairs(IrLink.FIELDS) do config[field.key] = hw[field.key] end
    local ok, result = pcall(self.ir.device, config)
    if not ok then
        self.error = tostring(result)
        print(LOG .. "IR open failed: " .. self.error)
        return false, self.error
    end
    self.device, self.config, self.error = result, config, nil
    return true
end

-- Opens hw; on failure the previously working configuration is reopened and the failure returned.
function IrLink:apply(hw)
    local previous = self.config
    local ok, err = self:open(hw)
    if ok or not previous then return ok, err end
    if not self:open(previous) then print(LOG .. "IR restore failed: " .. tostring(self.error)) end
    return false, err
end

function IrLink:send(frame)
    if not self.device then return false, "IR hardware unavailable" end
    -- A pending capture would record our own transmission.
    if self.capture then return false, "IR receiver is busy" end
    local ok, err = pcall(self.device.send, self.device, frame)
    if not ok then
        print(LOG .. "Send failed: " .. tostring(err))
        return false, tostring(err)
    end
    return true
end

function IrLink:start_capture(timeout_ms, now)
    if not self:can_receive() then return false, "IR receiver unavailable" end
    if self.capture then return false, "IR receiver is busy" end
    local ok, err = pcall(self.device.start_receive, self.device)
    if not ok then
        print(LOG .. "Capture start failed: " .. tostring(err))
        return false, tostring(err)
    end
    self.capture = {started = now, deadline = now + timeout_ms}
    return true
end

-- Returns nil while still listening, a frame on success, or false and a reason.
function IrLink:poll_capture(now)
    local capture = self.capture
    if not capture then return false, "not_started" end
    local ok, frame, reason = pcall(self.device.read, self.device, {timeout_ms = 0})
    if not ok then
        self:cancel_capture()
        print(LOG .. "Capture failed: " .. tostring(frame))
        return false, tostring(frame)
    end
    if frame then
        self.capture = nil
        return frame
    end
    -- "timeout" keeps the capture armed; "empty_frame" (glitches only) ends it, so re-arm.
    if now < capture.deadline then
        if reason == "timeout" then return nil end
        if reason == "empty_frame" then
            local rearmed, err = pcall(self.device.start_receive, self.device)
            if rearmed then return nil end
            reason = tostring(err)
        end
    end
    self:cancel_capture()
    return false, reason
end

function IrLink:capture_progress(now)
    local capture = self.capture
    if not capture then return 1, 0 end
    local total = capture.deadline - capture.started
    return math.min(1, (now - capture.started) / total), math.max(0, capture.deadline - now)
end

function IrLink:cancel_capture()
    if not self.capture then return end
    self.capture = nil
    local ok, err = pcall(self.device.stop_receive, self.device)
    if not ok then print(LOG .. "Capture stop failed: " .. tostring(err)) end
end

return IrLink
