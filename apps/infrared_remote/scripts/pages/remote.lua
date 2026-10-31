-- Remote page shared by every device kind: header, learn/remove modes and key dispatch.
-- The kind-specific panel builds the controls and binds them through this page.
local Kit = require("ui.kit")

local RemotePage = {}
RemotePage.__index = RemotePage

local LOG = "[infrared_remote] "
local SENT_FLASH_MS = 900
local MODE_HINTS = {
    learn = {text = "Tap a key to learn it", color = Kit.C.warn},
    erase = {text = "Tap a learned key to remove it", color = Kit.C.danger},
}

-- build_panel(page, parent, x, y, w, h) returns the panel; panel:refresh() is optional.
function RemotePage.new(app, build_panel)
    local kit, C = app.kit, Kit.C
    local self = setmetatable({app = app, kit = kit, keys = {}, mode = nil, flash_until = nil}, RemotePage)
    self.view = kit:view(app.root)
    self.header = kit:header(self.view, {
        back = function() app:go("home") end,
        actions = {
            {icon = "learn", on_click = function() self:toggle_mode("learn") end, on_hold = function() self:toggle_mode("erase") end},
            {icon = "trash", fg = C.danger, on_click = function() self:confirm_delete() end},
        },
    })
    self.learn_action = self.header.actions[1]
    self.panel = build_panel(self, self.view, kit:body_rect())
    return self
end

function RemotePage:enter(device)
    self.device, self.mode, self.flash_until = device, nil, nil
    local err
    self.remote, err = self.app.devices:remote(device)
    self.header:set_title(device.name)
    if err then self.app:notify("Saved remote could not be restored", "danger") end
    self:refresh()
end

function RemotePage:leave()
    self.mode = nil
    if not self.app.devices:flush() then self.app:notify("Saving remote state failed", "danger") end
end

function RemotePage:tick(now)
    if self.flash_until and now >= self.flash_until then
        self.flash_until = nil
        self:_refresh_header()
    end
end

function RemotePage:source(key) return self.remote and self.remote:keys()[key] end

function RemotePage:mark(key)
    local source = self:source(key)
    if self.mode == "learn" then return "target" end
    if self.mode == "erase" then return source == "learned" and "target" or "missing" end
    if source == "learned" then return "learned" end
    return source and "idle" or "missing"
end

function RemotePage:_refresh_header()
    local C, hint = Kit.C, MODE_HINTS[self.mode]
    if hint then
        self.header:set_subtitle(hint.text, hint.color)
    elseif self.flash_until then
        self.header:set_subtitle(self.flash_text, C.accent, C.accent)
    elseif not self.remote then
        self.header:set_subtitle("Restore failed · record kept", C.danger, C.danger)
    else
        self.header:set_subtitle(self.app:describe(self.device))
    end
    local active = self.mode ~= nil
    self.learn_action:set_colors(active and (self.mode == "erase" and C.danger or C.warn) or C.surface, active and C.inverse or C.text)
end

function RemotePage:refresh()
    for key, button in pairs(self.keys) do button:set_mark(self:mark(key)) end
    self:_refresh_header()
    if self.panel.refresh then self.panel:refresh() end
end

-- Binds a keypad button: tap sends (or learns/removes in a mode), hold learns directly.
function RemotePage:bind(button, key, label)
    self.keys[key] = button
    button:on_click(function() self:activate(key, label) end)
    button:on_hold(function() self:capture(key, label) end)
end

function RemotePage:flash(label)
    self.flash_text = label .. " sent"
    self.flash_until = self.app:now() + SENT_FLASH_MS
    self:_refresh_header()
end

function RemotePage:send(frame, label)
    if self.app:send(frame) then self:flash(label) end
end

function RemotePage:activate(key, label)
    local app, remote = self.app, self.remote
    if not remote then app:notify("Remote unavailable; record kept", "danger"); return end
    if self.mode == "erase" then return self:forget(key, label) end
    if self.mode == "learn" then return self:capture(key, label) end
    if not self:source(key) then app:notify("Hold " .. label .. " to learn it", "warn"); return end
    local ok, frame = pcall(remote.press, remote, key)
    if not ok then
        print(LOG .. "Press failed: " .. tostring(frame))
        app:notify(label .. " is unavailable in this mode", "danger")
        return
    end
    self:send(frame, label)
end

-- Applies an AC state change through remote:set() and sends the resulting full-state frame.
function RemotePage:apply_state(changes, label)
    local app, remote = self.app, self.remote
    if not remote then app:notify("Remote unavailable; record kept", "danger"); return end
    local ok, frame = pcall(remote.set, remote, changes)
    if not ok then
        print(LOG .. "Set failed: " .. tostring(frame))
        app:notify("Not supported by this protocol", "danger")
        return
    end
    self:send(frame, label)
    app.devices:touch(self.device, app:now())
    self:refresh()
end

function RemotePage:capture(key, label)
    if not self.remote then self.app:notify("Remote unavailable; record kept", "danger"); return end
    self.mode = nil
    self:refresh()
    self.app:start_learning(self.device, self.remote, key, label, function() self:refresh() end)
end

function RemotePage:forget(key, label)
    local app = self.app
    self.mode = nil
    if self.remote:forget(key) then
        local saved = app.devices:commit(self.device)
        app:notify(saved and ("Learned " .. label .. " removed") or "Removed, but saving failed", saved and "success" or "danger")
    else
        app:notify(label .. " has no learned signal", "warn")
    end
    self:refresh()
end

function RemotePage:toggle_mode(mode)
    local app = self.app
    if not self.remote then app:notify("Remote unavailable; record kept", "danger"); return end
    if self.mode == mode then
        self.mode = nil
    elseif mode == "learn" and not app.link:can_receive() then
        app:notify("IR receiver is off · check Settings", "danger")
        return
    else
        self.mode = mode
    end
    self:refresh()
end

function RemotePage:confirm_delete()
    local app, device = self.app, self.device
    app:overlay("dialog"):open({
        title = "Delete " .. device.name .. "?",
        text = "Its protocol settings and learned keys will be removed.",
        confirm = "Delete", tone = "danger",
        on_confirm = function() app:delete_device(device) end,
    })
end

return RemotePage
