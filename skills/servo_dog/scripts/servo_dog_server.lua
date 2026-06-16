local http = require("http_server")
local json = require("json")
local storage = require("storage")
local thread = require("thread")

local sync = thread.sync

local DEFAULT_APP_ID = "servo_dog"
local DEFAULT_QUEUE = "servo_dog_cmd"
local DEFAULT_CONFIG_DIR = "servo_dog"
local DEFAULT_CONFIG_FILE = "config.json"
local DEFAULT_SKILL_DIR = "servo_dog"

local function default_skill_path(...)
    return storage.join_path(storage.get_root_dir(), "skills", DEFAULT_SKILL_DIR, ...)
end

local raw_args = type(args) == "table" and args or {}
local app_id = type(raw_args.app_id) == "string" and raw_args.app_id ~= "" and raw_args.app_id or DEFAULT_APP_ID
local queue_name = type(raw_args.queue_name) == "string" and raw_args.queue_name ~= "" and raw_args.queue_name or DEFAULT_QUEUE
local web_root = type(raw_args.web_root) == "string" and raw_args.web_root ~= "" and raw_args.web_root or default_skill_path("assets")
local worker_path = type(raw_args.worker_path) == "string" and raw_args.worker_path ~= "" and raw_args.worker_path or default_skill_path("scripts", "servo_dog_worker.lua")
local worker_args = type(raw_args.worker_args) == "table" and raw_args.worker_args or {}
worker_args.queue_name = queue_name

local calibration_mode = false

local ACTIONS = {
    { id = "1", name = "lay_down", label = "趴下" },
    { id = "2", name = "bow", label = "鞠躬" },
    { id = "3", name = "lean_back", label = "后仰" },
    { id = "4", name = "bow_lean", label = "前后" },
    { id = "5", name = "sway_back_forth", label = "摇摆" },
    { id = "6", name = "sway", label = "左右" },
    { id = "7", name = "shake_hand", label = "握手" },
    { id = "8", name = "poke", label = "戳戳" },
    { id = "9", name = "shake_back_legs", label = "抖腿" },
    { id = "10", name = "jump_forward", label = "前跳" },
    { id = "11", name = "jump_backward", label = "后跳" },
    { id = "12", name = "retract_legs", label = "收腿" },
}

local function config_path()
    local root = storage.get_root_dir()
    local dir = storage.join_path(root, DEFAULT_CONFIG_DIR)
    pcall(storage.mkdir, dir)
    return storage.join_path(dir, DEFAULT_CONFIG_FILE)
end

local function load_offsets()
    local offset = { fl = 0, fr = 0, bl = 0, br = 0 }
    local path = config_path()
    if not storage.exists(path) then
        return offset
    end
    local ok, data = pcall(json.decode, storage.read_file(path))
    if ok and type(data) == "table" and type(data.offset) == "table" then
        for _, leg in ipairs({ "fl", "fr", "bl", "br" }) do
            offset[leg] = tonumber(data.offset[leg]) or 0
        end
    end
    return offset
end

local function safe_app_id(value)
    return type(value) == "string" and value:match("^[%w_-]+$") ~= nil
end

local function safe_abs_path(value)
    return type(value) == "string" and value:sub(1, 1) == "/" and not value:find("%.%.", 1, true)
end

local function parse_body(body)
    if type(body) ~= "string" or body == "" then
        return {}
    end
    local ok, data = pcall(json.decode, body)
    if not ok or type(data) ~= "table" then
        return nil, "invalid JSON body"
    end
    return data
end

local function send_command(command)
    local ok, err = sync.queue_send(queue_name, json.encode(command), 100)
    if not ok then
        return nil, err or "queue send failed"
    end
    return true
end

local function json_error(message, status)
    return {
        status = status or 400,
        json = {
            ok = false,
            error = message,
        },
    }
end

local function start_worker()
    pcall(thread.stop, "servo_dog_worker", 1000)
    pcall(sync.queue_delete, queue_name)
    assert(sync.queue_create(queue_name, { depth = 8, item_size = 2048 }))

    local ok, output = thread.start(worker_path, worker_args, {
        name = "servo_dog_worker",
        exclusive = "servo_dog_worker",
        replace = true,
        timeout_ms = 0,
    })
    assert(ok, output)
end

local function register_routes(app)
    app:get("/state", function(_req)
        return {
            json = {
                ok = true,
                calibration = calibration_mode,
                offsets = load_offsets(),
                actions = ACTIONS,
                moves = {
                    { id = "F", label = "前进" },
                    { id = "B", label = "后退" },
                    { id = "L", label = "左转" },
                    { id = "R", label = "右转" },
                },
            },
        }
    end)

    app:post("/control", function(req)
        if calibration_mode then
            return json_error("Control disabled in calibration mode", 400)
        end
        local body, err = parse_body(req.body)
        if not body then
            return json_error(err, 400)
        end
        local ok, send_err = send_command(body)
        if not ok then
            return json_error(send_err, 503)
        end
        return { json = { ok = true } }
    end)

    app:get("/start_calibration", function(_req)
        calibration_mode = true
        send_command({ action = "installation" })
        return {
            json = {
                ok = true,
                calibration = true,
                offsets = load_offsets(),
            },
        }
    end)

    app:get("/exit_calibration", function(_req)
        calibration_mode = false
        send_command({ action = "idle" })
        return { json = { ok = true, calibration = false } }
    end)

    app:post("/adjust", function(req)
        local body, err = parse_body(req.body)
        if not body then
            return json_error(err, 400)
        end
        local servo = body.servo or body.leg
        local value = tonumber(body.value)
        if type(servo) ~= "string" or value == nil then
            return json_error("servo and value are required", 400)
        end
        local ok, send_err = send_command({
            type = "adjust",
            servo = servo,
            value = math.floor(value),
        })
        if not ok then
            return json_error(send_err, 503)
        end
        return { json = { ok = true } }
    end)
end

local function run()
    if not safe_app_id(app_id) then
        error("invalid app_id: " .. tostring(app_id))
    end
    if not safe_abs_path(web_root) then
        error("invalid web_root: " .. tostring(web_root))
    end
    if not safe_abs_path(worker_path) then
        error("invalid worker_path: " .. tostring(worker_path))
    end

    start_worker()

    local app = http.app(app_id)
    app:mount_static(web_root)
    register_routes(app)

    print("[servo_dog] serving " .. app:url() .. " from " .. web_root)
    app:serve_forever()
    pcall(thread.stop, "servo_dog_worker", 1000)
    pcall(sync.queue_delete, queue_name)
    print("[servo_dog] server stopped")
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
    print("[servo_dog] ERROR: " .. tostring(err))
    error(err)
end
