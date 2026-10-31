local RemoteStore = {}
RemoteStore.__index = RemoteStore

local function empty_data()
    return {next_id = 1, devices = {}, hardware = {}}
end

function RemoteStore.open()
    local self = setmetatable({data = empty_data()}, RemoteStore)
    local storage = require("storage")
    local json = require("json")

    local dir = storage.join_path(storage.get_root_dir(), "app_data")
    if not storage.exists(dir) then
        local ok, result = pcall(storage.mkdir, dir)
        if not ok or not result then print("[infrared_remote] Data directory error: " .. tostring(result)) end
    end
    self.storage, self.json = storage, json
    self.path = storage.join_path(dir, "infrared_remote.json")
    local backup = self.path .. ".bak"
    if not storage.exists(self.path) and storage.exists(backup) then
        local recovered, reason = pcall(storage.rename, backup, self.path)
        if not recovered then self.load_error = tostring(reason); return self end
    end
    if not storage.exists(self.path) then return self end

    local ok, saved = pcall(function() return json.decode(storage.read_file(self.path)) end)
    if not ok or type(saved) ~= "table" then
        self.load_error = "invalid saved JSON"
        print("[infrared_remote] Saved data retained: " .. tostring(saved))
        return self
    end
    if type(saved.devices) ~= "table" then
        self.load_error = "missing devices array"
        print("[infrared_remote] Saved data retained: missing devices array")
        return self
    end
    self.data.devices = saved.devices
    self.data.next_id = tonumber(saved.next_id) or 1
    if type(saved.hardware) == "table" then self.data.hardware = saved.hardware end
    return self
end

function RemoteStore:save()
    if not self.path or self.load_error then return false end
    local temporary, backup = self.path .. ".tmp", self.path .. ".bak"
    local ok, result = pcall(function()
        assert(self.storage.write_file(temporary, self.json.encode(self.data)), "temporary write failed")
        -- FATFS rename may reject an existing destination; retain the old file until replacement succeeds.
        local had_file = self.storage.exists(self.path)
        if had_file then
            if self.storage.exists(backup) then assert(self.storage.remove(backup)) end
            assert(self.storage.rename(self.path, backup))
        end
        local replaced, reason = pcall(self.storage.rename, temporary, self.path)
        if not replaced or not reason then
            if had_file then
                local restored, restore_reason = pcall(self.storage.rename, backup, self.path)
                if not restored or not restore_reason then print("[infrared_remote] Backup retained: " .. tostring(restore_reason)) end
            end
            error("replacement failed: " .. tostring(reason))
        end
        if had_file then pcall(self.storage.remove, backup) end
        return true
    end)
    if not ok or not result then print("[infrared_remote] Save failed: " .. tostring(result)) end
    return ok and result
end

return RemoteStore
