local http = require("http_server")
local json = require("json")
local thread = require("thread")

local raw_args = type(args) == "table" and args or {}
local app_id = type(raw_args.app_id) == "string" and raw_args.app_id ~= "" and raw_args.app_id or "weather_clock"
local queue_name = type(raw_args.queue_name) == "string" and raw_args.queue_name ~= "" and raw_args.queue_name or nil

if not queue_name then
    error("queue_name is required")
end

local function decode_body(body)
    if type(body) ~= "string" or body == "" then
        return nil, "empty request body"
    end
    local ok, data = pcall(function()
        return json.decode(body)
    end)
    if not ok or type(data) ~= "table" then
        return nil, "invalid JSON body"
    end
    return data, nil
end

local function enqueue(data)
    local payload = json.encode(data)
    local ok_send, send_err = thread.sync.queue_send(queue_name, payload, 100)
    if not ok_send then
        return nil, tostring(send_err or "queue send failed")
    end
    return true, nil
end

local function run()
    local app = http.app(app_id)

    app:get("/state", function(_req)
        return {
            json = {
                ok = true,
                app = app_id,
                control = "/api/lua/" .. app_id .. "/control",
                icon = "/api/lua/" .. app_id .. "/icon",
            },
        }
    end)

    app:post("/control", function(req)
        local data, err = decode_body(req.body)
        if not data then
            return {
                status = 400,
                json = {
                    ok = false,
                    error = err,
                },
            }
        end
        data.type = "control"
        local ok_send, send_err = enqueue(data)
        if not ok_send then
            return {
                status = 503,
                json = {
                    ok = false,
                    error = tostring(send_err or "queue send failed"),
                },
            }
        end
        return {
            json = {
                ok = true,
            },
        }
    end)

    app:post("/icon", function(req)
        local data, err = decode_body(req.body)
        if not data then
            return {
                status = 400,
                json = {
                    ok = false,
                    error = err,
                },
            }
        end
        data.type = "icon"
        local ok_send, send_err = enqueue(data)
        if not ok_send then
            return {
                status = 503,
                json = {
                    ok = false,
                    error = send_err,
                },
            }
        end
        return {
            json = {
                ok = true,
            },
        }
    end)

    print("[weather_clock_control] serving /api/lua/" .. app_id .. "/control and /icon")
    app:serve_forever()
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
    print("[weather_clock_control] ERROR: " .. tostring(err))
    error(err)
end
