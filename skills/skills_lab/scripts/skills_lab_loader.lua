local delay = require("delay")
local json = require("json")
local skills_lab = require("skills_lab_client")
local storage = require("storage")

local TAG = "[skills_lab_loader]"
local CONTROL_ROOT = "/ramfs"
local CONTROL_DIR = "skills_lab"
local STATUS_FILE = "all_status.json"
local BATCH_SIZE = 6
local CATEGORIES = { "utility", "game", "hardware", "media", "network", "sensor", "ai" }

local function control_dir()
    return storage.join_path(CONTROL_ROOT, CONTROL_DIR)
end

local function status_path()
    return storage.join_path(control_dir(), STATUS_FILE)
end

local function ensure_control_dir()
    local dir = control_dir()
    if storage.exists(dir) then
        return dir
    end
    local ok, err = storage.mkdir(dir)
    if ok == false then
        error("failed to create " .. dir .. ": " .. tostring(err))
    end
    return dir
end

local function write_status(status)
    ensure_control_dir()
    local path = status_path()
    local tmp_path = path .. ".tmp"
    local ok, err = storage.write_file(tmp_path, json.encode(status))
    if ok == false then
        error("failed to write " .. tmp_path .. ": " .. tostring(err))
    end
    pcall(storage.remove, path)
    ok, err = storage.rename(tmp_path, path)
    if ok == false then
        error("failed to publish " .. path .. ": " .. tostring(err))
    end
end

local function publish(status)
    status.updated_at = os.time()
    write_status(status)
end

local function run()
    local status = {
        ok = true,
        loading = true,
        done = false,
        version = 0,
        count = 0,
        error = "",
        items = {},
    }
    local seen = {}
    local batch_added = 0

    publish(status)

    for _, category in ipairs(CATEGORIES) do
        print(TAG .. " loading category=" .. tostring(category))
        local ok, result = pcall(skills_lab.search, { category = category })
        if ok and type(result) == "table" then
            for _, item in ipairs(result.results or {}) do
                if type(item) == "table" and type(item.id) == "string" and not seen[item.id] then
                    seen[item.id] = true
                    status.items[#status.items + 1] = item
                    status.count = #status.items
                    batch_added = batch_added + 1
                    if batch_added >= BATCH_SIZE then
                        status.version = status.version + 1
                        publish(status)
                        batch_added = 0
                        delay.delay_ms(50)
                    end
                end
            end
        else
            print(TAG .. " WARN: category failed category=" .. tostring(category) .. " err=" .. tostring(result))
            status.error = tostring(result)
            status.version = status.version + 1
            publish(status)
        end
        delay.delay_ms(100)
    end

    status.loading = false
    status.done = true
    status.version = status.version + 1
    publish(status)
    print(TAG .. " done count=" .. tostring(status.count))
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
    print(TAG .. " ERROR: " .. tostring(err))
    pcall(write_status, {
        ok = false,
        loading = false,
        done = true,
        version = -1,
        count = 0,
        error = tostring(err),
        items = {},
        updated_at = os.time(),
    })
    error(err)
end
