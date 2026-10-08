-- sample_loader.lua: load steel guitar PCM blobs from skill assets.
-- Returns a table keyed by MIDI note with packed s16 mono PCM strings.

local sample_map = require("sample_map")

local M = {}

local function join_path(a, b)
    local ok_storage, storage = pcall(require, "storage")
    if ok_storage and storage and type(storage.join_path) == "function" then
        local ok, joined = pcall(storage.join_path, a, b)
        if ok and type(joined) == "string" then
            return joined
        end
    end
    a = tostring(a or ""):gsub("\\", "/"):gsub("/+$", "")
    return a .. "/" .. tostring(b)
end

local function read_bytes(path)
    local ok_storage, storage = pcall(require, "storage")
    if ok_storage and storage and type(storage.read_file) == "function" then
        local ok, data = pcall(storage.read_file, path)
        if ok and type(data) == "string" and #data > 0 then
            return data
        end
    end
    if io and io.open then
        local ok, handle = pcall(io.open, path, "rb")
        if ok and handle then
            local data = handle:read("*a")
            handle:close()
            if type(data) == "string" and #data > 0 then
                return data
            end
        end
    end
    return nil
end

local function resolve_steel_dir()
    if type(args) == "table" then
        if type(args.steel_dir) == "string" and args.steel_dir ~= "" then
            return args.steel_dir
        end
        if type(args.assets_dir) == "string" and args.assets_dir ~= "" then
            return join_path(args.assets_dir, "steel")
        end
    end
    local info = debug and debug.getinfo and debug.getinfo(1, "S")
    local src = (info and info.source) or ""
    if src:sub(1, 1) == "@" then
        src = src:sub(2)
    end
    src = src:gsub("\\", "/")
    local scripts_dir = src:match("^(.*)/[^/]+$")
    if scripts_dir then
        local skill_dir = scripts_dir:match("^(.*)/scripts$")
        if skill_dir then
            return join_path(skill_dir, "assets/steel")
        end
    end
    return nil
end

-- `on_progress(loaded, total, name)` is called after each file. The entry uses
-- it to draw and to hand the scheduler a yield point, so loading a megabyte of
-- PCM neither blanks the screen nor swallows a stop request.
function M.load(steel_dir, on_progress)
    steel_dir = steel_dir or resolve_steel_dir()
    if steel_dir == nil or steel_dir == "" then
        return nil, "steel assets directory unavailable"
    end

    local order = {}
    for midi in pairs(sample_map.notes) do
        order[#order + 1] = midi
    end
    table.sort(order)

    local samples = {}
    local loaded = 0
    for _, midi in ipairs(order) do
        local entry = sample_map.notes[midi]
        local path = join_path(steel_dir, entry.file)
        local pcm = read_bytes(path)
        if pcm == nil then
            return nil, "missing sample " .. tostring(entry.file)
        end
        local expected_bytes = entry.frames * 2
        if #pcm < expected_bytes then
            return nil, string.format(
                "short sample %s (%d bytes, expected %d)",
                entry.file, #pcm, expected_bytes)
        end
        samples[midi] = pcm:sub(1, expected_bytes)
        loaded = loaded + 1
        if on_progress ~= nil then
            on_progress(loaded, #order, entry.name or entry.file)
        end
    end
    if loaded < 1 then
        return nil, "sample table empty"
    end
    return samples, nil
end

function M.map_rate()
    return sample_map.rate
end

return M
