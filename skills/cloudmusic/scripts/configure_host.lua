local capability = require("capability")
local json = require("json")
local storage = require("storage")

local DEFAULT_PORT = 8766
local CONFIG_DIR = "CloudMusic"
local CONFIG_FILE = "config.json"

local raw_args = type(args) == "table" and args or {}

local function require_string(key)
    local value = raw_args[key]
    if type(value) ~= "string" or value == "" then
        error("args." .. key .. " is required")
    end
    return value
end

local function valid_ipv4(ip)
    local a, b, c, d = string.match(ip, "^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then
        return false
    end
    for _, part in ipairs({ a, b, c, d }) do
        local n = tonumber(part)
        if not n or n < 0 or n > 255 then
            return false
        end
    end
    return true
end

local function config_path()
    local root = storage.get_root_dir()
    local dir = storage.join_path(root, CONFIG_DIR)
    storage.mkdir(dir)
    return storage.join_path(dir, CONFIG_FILE)
end

local function http_status(output)
    return tonumber(string.match(tostring(output or ""), "^HTTP%s+(%d+)"))
end

local function health_check(host_ip, port)
    local ok, out, err = capability.call("http_request", {
        url = string.format("http://%s:%d/health", host_ip, port),
        method = "GET",
        timeout_ms = 4000,
        max_body_bytes = 64,
    }, {
        source_cap = "CloudMusic",
        max_output_bytes = 512,
    })

    if not ok then
        return false, tostring(err or out)
    end
    if http_status(out) ~= 200 then
        return false, tostring(out)
    end
    return true, out
end

local function run()
    local host_ip = require_string("host_ip")
    local port = tonumber(raw_args.port) or DEFAULT_PORT

    if not valid_ipv4(host_ip) then
        error("args.host_ip must be an IPv4 address, for example 192.168.1.100")
    end
    if port < 1 or port > 65535 then
        error("args.port must be in 1..65535")
    end

    local cfg = {
        host_ip = host_ip,
        port = math.floor(port),
    }
    storage.write_file(config_path(), json.encode(cfg))
    print(string.format("[CloudMusic] saved host %s:%d", cfg.host_ip, cfg.port))

    local healthy, detail = health_check(cfg.host_ip, cfg.port)
    if healthy then
        print("[CloudMusic] /health OK")
    else
        print("[CloudMusic] /health not ready: " .. tostring(detail))
        print("[CloudMusic] ensure the Windows app is running and http_allowlist includes this IP")
    end
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
    error(err)
end
