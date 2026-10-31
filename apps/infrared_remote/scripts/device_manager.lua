-- Saved devices and their live ir_remote objects; persists snapshots through RemoteStore.
local DeviceManager = {}
DeviceManager.__index = DeviceManager

DeviceManager.MAX_DEVICES = 6
-- Frequent AC state changes are coalesced into one flash write.
local SAVE_DELAY_MS = 1500
local KIND_NAMES = {tv = "TV", ac = "Air", media = "Media", custom = "Custom"}
local LOG = "[infrared_remote] "

function DeviceManager.new(store, ir_remote)
    local self = setmetatable({store = store, ir_remote = ir_remote, remotes = {}, errors = {}, pending = {}, save_due = nil}, DeviceManager)
    for _, device in ipairs(store.data.devices) do
        local ok, result = pcall(ir_remote.new, device.snapshot)
        if ok then
            self.remotes[device.id] = result
        else
            self.errors[device.id] = tostring(result)
            print(LOG .. "Restore failed for " .. tostring(device.name) .. ": " .. tostring(result))
        end
    end
    return self
end

function DeviceManager:list() return self.store.data.devices end

function DeviceManager:is_full() return #self.store.data.devices >= DeviceManager.MAX_DEVICES end

-- Returns the live remote, or nil and the restore error. Failed records are kept untouched on disk.
function DeviceManager:remote(device) return self.remotes[device.id], self.errors[device.id] end

function DeviceManager:learned_count(device)
    local remote, n = self.remotes[device.id], 0
    if remote then
        for _, source in pairs(remote:keys()) do if source == "learned" then n = n + 1 end end
    else
        for _ in pairs(device.snapshot and device.snapshot.learned or {}) do n = n + 1 end
    end
    return n
end

local function next_name(devices, kind)
    local count = 1
    for _, device in ipairs(devices) do if device.kind == kind then count = count + 1 end end
    return KIND_NAMES[kind] .. " " .. count
end

-- Creates and persists a device; labels are extra display fields stored in the record.
-- Returns the device, or nil and a user-facing reason.
function DeviceManager:create(kind, config, labels)
    if self:is_full() then return nil, "Remote limit reached" end
    local ok, remote = pcall(self.ir_remote.new, config)
    if not ok then
        print(LOG .. "Create failed: " .. tostring(remote))
        return nil, "Check protocol address and codes"
    end
    local exported, snapshot = pcall(remote.to_table, remote)
    if not exported then
        print(LOG .. "Snapshot failed: " .. tostring(snapshot))
        return nil, "Snapshot failed"
    end
    local data = self.store.data
    local device = {id = data.next_id, kind = kind, name = next_name(data.devices, kind), snapshot = snapshot}
    for key, value in pairs(labels or {}) do device[key] = value end
    data.devices[#data.devices + 1] = device
    data.next_id = device.id + 1
    if not self.store:save() then
        table.remove(data.devices)
        data.next_id = device.id
        return nil, "Storage error"
    end
    self.remotes[device.id] = remote
    return device
end

function DeviceManager:delete(device)
    local devices, index = self.store.data.devices, nil
    for i, item in ipairs(devices) do if item.id == device.id then index = i; break end end
    if not index then return false end
    table.remove(devices, index)
    if not self.store:save() then
        table.insert(devices, index, device)
        return false
    end
    self.remotes[device.id], self.errors[device.id], self.pending[device.id] = nil, nil, nil
    return true
end

function DeviceManager:_snapshot(device)
    local remote = self.remotes[device.id]
    if not remote then return end
    local ok, snapshot = pcall(remote.to_table, remote)
    if ok then device.snapshot = snapshot else print(LOG .. "Snapshot failed: " .. tostring(snapshot)) end
end

-- Schedules a deferred save of the device's remote state.
function DeviceManager:touch(device, now)
    self.pending[device.id] = device
    self.save_due = now + SAVE_DELAY_MS
end

-- Snapshots and saves immediately, together with any pending changes.
function DeviceManager:commit(device)
    self.pending[device.id] = device
    return self:flush(true)
end

function DeviceManager:flush(force)
    if not force and not next(self.pending) then return true end
    for _, device in pairs(self.pending) do self:_snapshot(device) end
    self.pending, self.save_due = {}, nil
    return self.store:save()
end

-- Returns false when a deferred save failed.
function DeviceManager:tick(now)
    if self.save_due and now >= self.save_due then return self:flush() end
    return true
end

return DeviceManager
