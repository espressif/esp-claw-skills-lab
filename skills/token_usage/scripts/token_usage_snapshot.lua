local storage = require("storage")
local system = require("system")
local capability = require("capability")
local json = require("json")
local config = require("token_usage_config")
local env_mod = require("token_usage_env")
local remote = require("token_usage_remote")

local TEMP_OFFSET = 5.0
local BME69X_GASM_VALID_MSK = 0x20
local HISTORY_MAX_ENTRIES_PER_DAY = 24

local raw_args = type(args) == "table" and args or {}

local function script_dir()
    local src = debug.getinfo(1, "S").source or ""
    if src:sub(1, 1) == "@" then
        src = src:sub(2)
    end
    return (src:match("(.+)/[^/]+$")) or "."
end

local function normalize_path(path)
    local parts = {}
    for seg in string.gmatch(path, "[^/]+") do
        if seg == ".." then
            if #parts > 0 then
                table.remove(parts)
            end
        elseif seg ~= "." and seg ~= "" then
            parts[#parts + 1] = seg
        end
    end
    local prefix = (string.sub(path, 1, 1) == "/") and "/" or ""
    return prefix .. table.concat(parts, "/")
end

local HISTORY_DIR = normalize_path(script_dir() .. "/../telemetry_history")

local function resolve_host_port()
    local host = config.as_string(raw_args.host, config.as_string(raw_args.pc_ip, ""))
    local port_raw = raw_args.port
    local port = config.default_port
    if type(port_raw) == "number" then
        port = config.as_int(port_raw, config.default_port, 1, 65535)
    elseif type(port_raw) == "string" and port_raw ~= "" then
        port = config.as_int(tonumber(port_raw), config.default_port, 1, 65535)
    end
    return host, port
end

local function hour_key_now()
    return system.date("%Y-%m-%dT%H")
end

local function history_path_for(day)
    return storage.join_path(HISTORY_DIR, day .. ".json")
end

local function load_day(path)
    if not storage.exists(path) then
        return {}
    end
    local ok, content = pcall(storage.read_file, path)
    if not ok or type(content) ~= "string" or content == "" then
        return {}
    end
    local parse_ok, data = pcall(json.decode, content)
    if not parse_ok or type(data) ~= "table" then
        return {}
    end
    return data
end

local function save_day(path, list)
    local enc_ok, payload = pcall(json.encode, list)
    if not enc_ok then
        return false, payload
    end
    return pcall(storage.write_file, path, payload)
end

local function upsert_hour(list, record)
    for i, entry in ipairs(list) do
        if entry.hour == record.hour then
            list[i] = record
            return list
        end
    end
    list[#list + 1] = record
    while #list > HISTORY_MAX_ENTRIES_PER_DAY do
        table.remove(list, 1)
    end
    return list
end

local function gas_valid(sample)
    if type(sample.gas_valid) == "boolean" then
        return sample.gas_valid
    end
    if type(sample.gas_index) == "number" then
        return (sample.gas_index & BME69X_GASM_VALID_MSK) ~= 0
    end
    return type(sample.gas_resistance) == "number"
end

local function estimate_co2_ppm(gas_resistance)
    if type(gas_resistance) ~= "number" or gas_resistance <= 0 then
        return nil
    end
    return math.floor(400 + (50000 / gas_resistance) * 800 + 0.5)
end

local function read_environment()
    local env_state = env_mod.init()
    env_mod.poll_if_due(env_state, config.now_ms(), 0)
    local sample = env_state.last_sample
    env_mod.close(env_state)

    if type(sample) ~= "table" then
        return {
            temperature = nil,
            humidity = nil,
            pressure_hpa = nil,
            co2_ppm = nil,
        }
    end

    local temperature = sample.temperature
    if type(temperature) == "number" then
        temperature = temperature - TEMP_OFFSET
    end

    local pressure_hpa = nil
    if type(sample.pressure) == "number" then
        pressure_hpa = sample.pressure / 100.0
    end

    local co2_ppm = nil
    if gas_valid(sample) then
        co2_ppm = estimate_co2_ppm(sample.gas_resistance)
    end

    return {
        temperature = temperature,
        humidity = sample.humidity,
        pressure_hpa = pressure_hpa,
        co2_ppm = co2_ppm,
    }
end

local function cursor_status_summary(cursor)
    if type(cursor) ~= "table" then
        return nil
    end
    if not cursor.cursor_running then
        return "idle"
    end
    local status = cursor.hook_status
    if type(status) ~= "string" or status == "" then
        status = "unknown"
    end
    if cursor.agent_active then
        return status .. ", agent active"
    end
    return status
end

local function empty_remote_data()
    return {
        token_balance = nil,
        token_query_ok = false,
        weather_location = nil,
        weather_temp = nil,
        weather_desc = nil,
        weather_humidity = nil,
        weather_query_ok = false,
        cursor_running = nil,
        agent_active = nil,
        cursor_status = nil,
        ai_model = nil,
        account_balance = nil,
        account_query_ok = false,
    }
end

local function read_remote(host, port)
    if host == "" then
        return empty_remote_data()
    end

    local ctx = config.build_ctx({ host = host, port = port })
    local worker_state = remote.new_remote_state()

    local balance_data = remote.worker_http_get_json(ctx, worker_state, "deepseek-balance", 4096)
    if balance_data then
        remote.worker_apply_balance(worker_state, balance_data)
    end

    local account_data = remote.worker_http_get_json(ctx, worker_state, "deepseek-account-balance", 2048)
    local account_query_ok = false
    if account_data and remote.worker_apply_account(worker_state, account_data) then
        account_query_ok = true
    end

    local weather_data = remote.worker_http_get_json(ctx, worker_state, "weather", 4096)
    if weather_data then
        remote.worker_apply_weather(worker_state, weather_data)
    end

    local cursor_data = remote.worker_http_get_json(ctx, worker_state, "cursor-status", 4096)
    if cursor_data then
        remote.apply_cursor_payload(worker_state, cursor_data)
    end

    local weather = worker_state.weather
    local cursor = worker_state.cursor
    return {
        token_balance = worker_state.token.balance_str,
        token_query_ok = worker_state.token.query_ok,
        weather_location = weather.location ~= "--" and weather.location or nil,
        weather_temp = weather.temperature ~= "--" and weather.temperature or nil,
        weather_desc = weather.description ~= "--" and weather.description or nil,
        weather_humidity = weather.humidity ~= "--" and weather.humidity or nil,
        weather_query_ok = weather.query_ok,
        cursor_running = cursor.cursor_running,
        agent_active = cursor.agent_active,
        cursor_status = cursor_status_summary(cursor),
        ai_model = cursor.ai_model ~= "" and cursor.ai_model or nil,
        account_balance = account_query_ok and worker_state.token.account_balance or nil,
        account_query_ok = account_query_ok,
    }
end

local function fmt_num(value, digits)
    if value == nil then
        return "NA"
    end
    if digits then
        return string.format("%." .. digits .. "f", value)
    end
    return tostring(value)
end

local function read_standing_state(skill_dir)
    local path = storage.join_path(skill_dir, "standing_state.json")
    if not storage.exists(path) then
        return 0, false
    end
    local ok, content = pcall(storage.read_file, path)
    if not ok or type(content) ~= "string" or content == "" then
        return 0, false
    end
    local parse_ok, data = pcall(json.decode, content)
    if not parse_ok or type(data) ~= "table" or type(data.count) ~= "number" then
        return 0, false
    end
    return math.max(0, math.min(config.PILL_TOTAL, math.floor(data.count))), true
end

local function build_memory_content(record)
    local parts = {
        string.format(
            "At %s, desk was %sC / %s%% humidity, pressure %shPa, co2 %sppm",
            record.timestamp or "unknown time",
            fmt_num(record.temperature, 1),
            fmt_num(record.humidity, 1),
            fmt_num(record.pressure_hpa, 0),
            fmt_num(record.co2_ppm, 0)),
    }

    if record.weather_query_ok then
        parts[#parts + 1] = string.format(
            "outdoor %s %sC %s (humidity %s)",
            tostring(record.weather_location or "unknown"),
            tostring(record.weather_temp or "NA"),
            tostring(record.weather_desc or ""),
            tostring(record.weather_humidity or "NA"))
    end

    parts[#parts + 1] = string.format("DeepSeek balance %s", tostring(record.token_balance or "NA"))
    if record.account_query_ok and record.account_balance then
        parts[#parts + 1] = string.format("account balance %s", tostring(record.account_balance))
    end
    parts[#parts + 1] = string.format(
        "standing reminders completed %s/%d",
        tostring(record.standing_count or "NA"),
        config.PILL_TOTAL)

    if record.cursor_running ~= nil then
        local cursor_note = tostring(record.cursor_status or "unknown")
        if record.ai_model then
            cursor_note = cursor_note .. ", model " .. record.ai_model
        end
        parts[#parts + 1] = "Cursor " .. cursor_note
    end

    return table.concat(parts, "; ") .. "."
end

local function store_memory(record)
    local content = build_memory_content(record)
    local ok, out, err = capability.call("memory_store", {
        content = content,
        tags = "token_usage,environment,standing,weather,cursor",
        keywords = string.format("%s,telemetry,snapshot", record.hour or "hourly"),
        source = "token_usage_snapshot",
    }, {
        source_cap = "token_usage_snapshot",
        max_output_bytes = 4096,
    })

    if not ok then
        print("[token_usage_snapshot] memory_store failed: " .. tostring(err or out))
        return false
    end
    print("[token_usage_snapshot] memory_store ok: " .. tostring(out))
    return true
end

local host, port = resolve_host_port()
print(string.format("[token_usage_snapshot] collecting telemetry host=%s port=%d", host, port))

pcall(storage.mkdir, HISTORY_DIR)

local env = read_environment()
local remote_data = read_remote(host, port)
local hk = hour_key_now()
local day = system.date("%Y-%m-%d")

local record = {
    hour = hk,
    timestamp = system.date("%Y-%m-%d %H:%M:%S"),
    temperature = env.temperature,
    humidity = env.humidity,
    pressure_hpa = env.pressure_hpa,
    co2_ppm = env.co2_ppm,
    token_balance = remote_data.token_balance,
    standing_count = read_standing_state(normalize_path(script_dir() .. "/..")),
    token_query_ok = remote_data.token_query_ok,
    standing_query_ok = true,
    weather_location = remote_data.weather_location,
    weather_temp = remote_data.weather_temp,
    weather_desc = remote_data.weather_desc,
    weather_humidity = remote_data.weather_humidity,
    weather_query_ok = remote_data.weather_query_ok,
    cursor_running = remote_data.cursor_running,
    agent_active = remote_data.agent_active,
    cursor_status = remote_data.cursor_status,
    ai_model = remote_data.ai_model,
    account_balance = remote_data.account_balance,
    account_query_ok = remote_data.account_query_ok,
}

local path = history_path_for(day)
local list = load_day(path)
list = upsert_hour(list, record)
local save_ok, save_err = save_day(path, list)
if not save_ok then
    print("[token_usage_snapshot] history write failed: " .. tostring(save_err))
else
    print("[token_usage_snapshot] history updated " .. path .. " hour=" .. hk)
end

store_memory(record)
print("[token_usage_snapshot] snapshot complete")
