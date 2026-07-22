local capability = require("capability")
local delay = require("delay")
local json = require("json")
local storage = require("storage")
local system = require("system")
local thread = require("thread")

local DEFAULT_PORT = 8766
local POLL_MS = 500
local POLL_FAST_MS = 150
local POLL_FAST_DURATION_MS = 3000
local HEALTH_RETRY_MS = 1000
local LOOP_MS = 20
local COVER_MAX_BYTES = 64 * 1024
local MAX_EVENT_ERROR_LEN = 220

local raw_args = type(args) == "table" and args or {}
local cfg = raw_args.cfg or {}
local paths = raw_args.paths or {}
local cmd_queue = raw_args.cmd_queue
local evt_queue = raw_args.evt_queue

local last_cover_id = ""
local last_track_id = ""
local fast_poll_until = 0

local function now_ms()
    return system.millis()
end

local function build_url(path)
    return string.format("http://%s:%d%s", cfg.host_ip, tonumber(cfg.port) or DEFAULT_PORT, path)
end

local function parse_http_output(output)
    output = tostring(output or "")
    local status = tonumber(string.match(output, "^HTTP%s+(%d+)"))
    local body = string.match(output, "^HTTP%s+%d+[^\n]*\n(.*)$") or ""
    return status, body
end

local function http_request(payload, label)
    local ok, out, err = capability.call("http_request", payload, {
        source_cap = "CloudMusic",
        max_output_bytes = 8192,
    })

    if not ok then
        print(string.format("[CloudMusic worker] %s failed: err=%s out=%s", label, tostring(err), tostring(out)))
        return nil, nil, tostring(err or out)
    end

    local status, body = parse_http_output(out)
    if not status then
        print(string.format("[CloudMusic worker] %s returned unexpected output: %s", label, tostring(out)))
        return nil, nil, tostring(out)
    end
    return status, body, nil
end

local function send_event(event)
    if not evt_queue then
        return
    end
    if type(event.message) == "string" and #event.message > MAX_EVENT_ERROR_LEN then
        event.message = string.sub(event.message, 1, MAX_EVENT_ERROR_LEN)
    end
    local ok, payload = pcall(json.encode, event)
    if ok then
        thread.sync.queue_send(evt_queue, payload, 20)
    end
end

local function send_state_event(np)
    send_event({
        type = "state",
        playing = np.playing == true,
        track_id = type(np.track_id) == "string" and np.track_id or "",
        cover_id = type(np.cover_id) == "string" and np.cover_id or "",
    })
end

local function health_check()
    local status = http_request({
        url = build_url("/health"),
        method = "GET",
        timeout_ms = 2500,
        max_body_bytes = 64,
    }, "GET /health")
    return status == 200
end

local function fetch_state()
    local status, body = http_request({
        url = build_url("/state"),
        method = "GET",
        timeout_ms = 2500,
        max_body_bytes = 2048,
    }, "GET /state")

    if status ~= 200 then
        return nil
    end

    local ok, decoded = pcall(function()
        return json.decode(body)
    end)
    if not ok or type(decoded) ~= "table" then
        print("[CloudMusic worker] invalid /state JSON")
        return nil
    end
    return decoded
end

local function safe_file_id(value, fallback)
    value = tostring(value or "")
    local id = string.match(value, "^[A-Za-z0-9_-]+$") and value or ""
    if id == "" then
        id = fallback
    end
    return id
end

local function cover_path(cover_id, track_id)
    local id = safe_file_id(cover_id, safe_file_id(track_id, "current"))
    return storage.join_path(paths.cache, "current_" .. id .. ".jpg")
end

local function fetch_current_cover(np)
    local cover_id = type(np.cover_id) == "string" and np.cover_id or ""
    local track_id = type(np.track_id) == "string" and np.track_id or ""

    if cover_id == "" or (cover_id == last_cover_id and track_id == last_track_id) then
        return
    end

    local path = cover_path(cover_id, track_id)
    local status = http_request({
        url = build_url("/cover/current"),
        method = "GET",
        timeout_ms = 3500,
        save_path = path,
        max_file_bytes = COVER_MAX_BYTES,
    }, "GET /cover/current")

    if status == 200 and storage.exists(path) then
        last_cover_id = cover_id
        last_track_id = track_id
        send_event({
            type = "cover",
            slot = "current",
            path = path,
            cover_id = cover_id,
            track_id = track_id,
        })
        print(string.format("[CloudMusic worker] cached current cover=%s track=%s", cover_id, track_id))
    end
end

local function send_control(action)
    local status = http_request({
        url = build_url("/control"),
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
        },
        body = json.encode({ action = action }),
        timeout_ms = 2000,
        max_body_bytes = 512,
    }, "POST /control " .. action)

    if status and status >= 200 and status < 300 then
        print("[CloudMusic worker] control " .. action .. " OK")
        fast_poll_until = now_ms() + POLL_FAST_DURATION_MS
        return true
    end
    return false
end

local function handle_command(payload)
    local ok, cmd = pcall(function()
        return json.decode(payload)
    end)
    if not ok or type(cmd) ~= "table" then
        return true
    end

    if cmd.type == "stop" then
        return false
    end
    if cmd.type == "control" and type(cmd.action) == "string" then
        send_control(cmd.action)
    elseif cmd.type == "fast_poll" then
        fast_poll_until = now_ms() + POLL_FAST_DURATION_MS
    end
    return true
end

local function drain_commands()
    while true do
        local payload, err = thread.sync.queue_recv(cmd_queue, 0)
        if payload then
            if not handle_command(payload) then
                return false
            end
        elseif err == "stopped" then
            return false
        else
            return true
        end
    end
end

local function poll_interval_ms()
    if fast_poll_until ~= 0 and now_ms() < fast_poll_until then
        return POLL_FAST_MS
    end
    return POLL_MS
end

local function run()
    if type(cfg.host_ip) ~= "string" or cfg.host_ip == "" or not cmd_queue or not evt_queue then
        error("CloudMusic worker missing configuration")
    end

    local host_ready = false
    local last_health_ms = 0
    local last_poll_ms = 0

    while true do
        local now = now_ms()
        if not drain_commands() then
            break
        end

        if not host_ready then
            if now - last_health_ms >= HEALTH_RETRY_MS then
                last_health_ms = now
                host_ready = health_check()
                send_event({ type = "status", ready = host_ready })
                if host_ready then
                    print("[CloudMusic worker] ready, polling host")
                    last_poll_ms = 0
                else
                    print("[CloudMusic worker] waiting for Windows host /health")
                end
            end
        elseif now - last_poll_ms >= poll_interval_ms() then
            last_poll_ms = now
            local np = fetch_state()
            if np then
                send_state_event(np)
                fetch_current_cover(np)
            else
                host_ready = false
                send_event({ type = "status", ready = false })
            end
        end

        local payload, err = thread.sync.queue_recv(cmd_queue, LOOP_MS)
        if payload then
            if not handle_command(payload) then
                break
            end
        elseif err == "stopped" then
            break
        end
        delay.delay_ms(1)
    end
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
    send_event({ type = "error", message = tostring(err) })
    error(err)
end
