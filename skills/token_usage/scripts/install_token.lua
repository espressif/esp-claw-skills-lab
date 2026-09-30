local storage = require("storage")
local event_publisher = require("event_publisher")
local json = require("json")
local token_config = require("token_usage_config")
local capability = require("capability")

local STARTUP_RULE_ID = "startup_run_token_usage"
local START_NOW_RULE_ID = "install_start_token_usage"
local SNAPSHOT_RULE_ID = "schedule_run_token_usage_snapshot"
local LETTER_RULE_ID = "schedule_run_token_usage_letter"
local SNAPSHOT_SCHEDULE_ID = "token_usage_snapshot"
local LETTER_SCHEDULE_ID = "token_usage_letter"
local DASHBOARD_JOB_NAME = "token_usage"
local STOP_WAIT_MS = 3000

local install_args = (type(args) == "table") and args or {}

local function script_dir()
    return storage.join_path(token_config.SKILL_DIR, "scripts")
end

local function fail(msg)
    print("[install_token] ERROR: " .. msg)
    error(msg)
end

local function config_int(name, default_value, min_value, max_value)
    local value = token_config[name]
    if value == nil then
        return default_value
    end
    if type(value) ~= "number" then
        fail("token_usage_config." .. name .. " must be a number")
    end
    value = math.floor(value)
    if value < min_value or value > max_value then
        fail(string.format("token_usage_config.%s must be between %d and %d", name, min_value, max_value))
    end
    return value
end

local INSTALL_HOST = token_config.as_string(install_args.host, token_config.as_string(install_args.pc_ip, ""))
if INSTALL_HOST == "" then
    fail("args.host or args.pc_ip is required")
end

local INSTALL_PORT = token_config.as_int(install_args.port, token_config.default_port, 1, 65535)
local LETTER_LANGUAGE = token_config.as_string(install_args.language, token_config.default_letter_language)
local MEMORY_INTERVAL_HOURS = config_int("memory_interval_hours", 1, 1, 24 * 31)
local LETTER_SEND_MINUTE = config_int("letter_send_minute", 0, 0, 59)

local function read_text_file(path)
    if not storage.exists(path) then
        fail("file not found: " .. path)
    end
    local ok, content = pcall(storage.read_file, path)
    if not ok or type(content) ~= "string" or content == "" then
        fail("failed to read " .. path .. ": " .. tostring(content))
    end
    return content
end

local function write_text_file(path, content)
    local ok, err = storage.write_file(path, content)
    if ok == false then
        fail("failed to write " .. path .. ": " .. tostring(err))
    end
end

local function call_required(name, input)
    local ok, out, err = capability.call(name, input or {}, { source_cap = "install_token", max_output_bytes = 65536 })
    if not ok then fail(name .. ": " .. tostring(err or out)) end
    return out
end

-- Update individual entries through their owners, without rewriting shared files.
local function upsert_entries(list_cap, add_cap, update_cap, field, entries)
    local list = json.decode(call_required(list_cap))
    if type(list) ~= "table" then fail(list_cap .. " returned invalid JSON") end
    local existing = {}
    for _, entry in ipairs(list) do existing[entry.id] = true end
    for _, entry in ipairs(entries) do
        call_required(existing[entry.id] and update_cap or add_cap, { [field] = json.encode(entry) })
        if field == "rule_json" then call_required("get_router_rule", { id = entry.id }) end
        print("[install_token] updated " .. entry.id)
    end
end

local function install_soul()
    local root = storage.get_root_dir()
    local src = storage.join_path(token_config.SKILL_DIR, "soul_token.md")
    local dst = storage.join_path(root, "memory", "soul.md")
    local content = read_text_file(src)
    write_text_file(dst, content)
    print("[install_token] soul.md updated (" .. dst .. ")")
end

local function dashboard_script_path()
    return storage.join_path(script_dir(), "token_usage.lua")
end

local function snapshot_script_path()
    return storage.join_path(script_dir(), "token_usage_snapshot.lua")
end

local function letter_script_path()
    return storage.join_path(script_dir(), "token_usage_letter.lua")
end

local function dashboard_args()
    return {
        host = INSTALL_HOST,
        port = INSTALL_PORT,
        boot_delay_ms = 5000,
        cursor_poll_ms = 1000,
        status_poll_ms = 1000,
    }
end

local function startup_rule()
    return {
        id = STARTUP_RULE_ID,
        description = "Start token usage dashboard after boot.",
        enabled = true,
        consume_on_match = false,
        ack = "startup token usage dashboard started",
        match = {
            source_cap = "app_claw",
            event_type = "startup",
            event_key = "boot_completed",
            content_type = "trigger",
        },
        actions = {
            {
                type = "run_script",
                input = {
                    path = dashboard_script_path(),
                    args = dashboard_args(),
                    async = true,
                    name = "token_usage",
                    exclusive = "display",
                    replace = false,
                    timeout_ms = 0,
                },
            },
        },
    }
end

local function start_now_router_rule()
    return {
        id = START_NOW_RULE_ID,
        description = "Run token_usage.lua after install_token.lua finishes.",
        enabled = true,
        consume_on_match = true,
        ack = "install-triggered token_usage.lua executed",
        match = {
            source_cap = "install_token",
            event_type = "trigger",
            event_key = "token_usage_start",
            content_type = "trigger",
        },
        actions = {
            {
                type = "run_script",
                input = {
                    path = dashboard_script_path(),
                    args = dashboard_args(),
                    async = true,
                    name = "token_usage",
                    exclusive = "display",
                    replace = false,
                    timeout_ms = 0,
                },
            },
        },
    }
end

local function snapshot_router_rule()
    return {
        id = SNAPSHOT_RULE_ID,
        description = "Run token_usage_snapshot.lua when the telemetry snapshot schedule fires.",
        enabled = true,
        consume_on_match = true,
        ack = "scheduled token usage snapshot executed",
        match = {
            event_type = "schedule",
            event_key = SNAPSHOT_SCHEDULE_ID,
            content_type = "trigger",
        },
        actions = {
            {
                type = "run_script",
                input = {
                    path = snapshot_script_path(),
                    args = {
                        host = "{{event.payload.user_payload.host}}",
                        port = "{{event.payload.user_payload.port}}",
                    },
                },
            },
        },
    }
end

local function letter_router_rule()
    return {
        id = LETTER_RULE_ID,
        description = "Run token_usage_letter.lua when the hourly greeting schedule fires.",
        enabled = true,
        consume_on_match = true,
        ack = "scheduled token usage letter executed",
        match = {
            event_type = "schedule",
            event_key = LETTER_SCHEDULE_ID,
            content_type = "trigger",
        },
        actions = {
            {
                type = "run_script",
                input = {
                    path = letter_script_path(),
                    args = {
                        language = "{{event.payload.user_payload.language}}",
                        host = "{{event.payload.user_payload.host}}",
                        port = "{{event.payload.user_payload.port}}",
                    },
                },
            },
        },
    }
end

local function snapshot_schedule()
    local payload = {
        source = "token_usage",
        task = "snapshot",
        host = INSTALL_HOST,
        port = INSTALL_PORT,
    }
    return {
        id = SNAPSHOT_SCHEDULE_ID,
        enabled = true,
        kind = "interval",
        interval_ms = MEMORY_INTERVAL_HOURS * 60 * 60 * 1000,
        event_type = "schedule",
        event_key = SNAPSHOT_SCHEDULE_ID,
        source_channel = "time",
        content_type = "trigger",
        session_policy = "trigger",
        text = string.format("token usage telemetry snapshot every %d hour(s)", MEMORY_INTERVAL_HOURS),
        payload_json = json.encode(payload),
        max_runs = 0,
    }
end

local function letter_schedule()
    local payload = {
        source = "token_usage",
        task = "write_letter",
        language = LETTER_LANGUAGE,
        host = INSTALL_HOST,
        port = INSTALL_PORT,
    }
    return {
        id = LETTER_SCHEDULE_ID,
        enabled = true,
        kind = "interval",
        interval_ms = 60 * 1000,
        event_type = "schedule",
        event_key = LETTER_SCHEDULE_ID,
        source_channel = "time",
        content_type = "trigger",
        session_policy = "trigger",
        text = string.format("token usage hourly greeting (check every minute, send at minute %d)", LETTER_SEND_MINUTE),
        payload_json = json.encode(payload),
        max_runs = 0,
    }
end

local function install_router_rules()
    upsert_entries("list_router_rules", "add_router_rule", "update_router_rule", "rule_json", {
        startup_rule(), start_now_router_rule(), snapshot_router_rule(), letter_router_rule(),
    })
end

local function install_schedules()
    upsert_entries("scheduler_list", "scheduler_add", "scheduler_update", "schedule_json", { snapshot_schedule(), letter_schedule() })
end

local function call_capability(name, input)
    local ok, out, err = capability.call(name, input or {}, {
        source_cap = "install_token",
        max_output_bytes = 8192,
    })
    if not ok then
        print("[install_token] WARN: " .. name .. " failed: " .. tostring(err or out))
        return false, out, err or out
    end
    return true, out, nil
end

local function parse_job_field(text, key)
    if type(text) ~= "string" then
        return nil
    end
    local value = text:match(key .. "=([^\n]+)")
    if value == "(none)" or value == "(empty)" then
        return nil
    end
    return value
end

local function parse_job_args(text)
    local args_line = parse_job_field(text, "args")
    if not args_line then
        return nil
    end
    local parse_ok, data = pcall(json.decode, args_line)
    if parse_ok and type(data) == "table" then
        return data
    end
    return nil
end

local function dashboard_job_status()
    local ok, out = call_capability("lua_get_async_job", { name = DASHBOARD_JOB_NAME })
    if not ok then
        return nil, nil
    end
    return parse_job_field(out, "status"), parse_job_args(out)
end

local function dashboard_job_active()
    local status = dashboard_job_status()
    return status == "running" or status == "queued"
end

local function dashboard_host_port_match(job_args)
    if type(job_args) ~= "table" then
        return false
    end
    local host = token_config.as_string(job_args.host, token_config.as_string(job_args.pc_ip, ""))
    local port = token_config.as_int(job_args.port, token_config.default_port, 1, 65535)
    return host == INSTALL_HOST and port == INSTALL_PORT
end

local function install_bool(name)
    local value = install_args[name]
    if value == nil then
        return false
    end
    if type(value) == "boolean" then
        return value
    end
    if type(value) == "string" then
        local lowered = string.lower(value)
        return lowered == "true" or lowered == "1" or lowered == "yes"
    end
    if type(value) == "number" then
        return value ~= 0
    end
    return false
end

local RESTART_DASHBOARD = install_bool("restart_dashboard")
local SKIP_DASHBOARD_START = install_bool("skip_dashboard_start")

local function stop_dashboard(reason)
    print("[install_token] " .. reason)
    call_required("lua_stop_async_job", { name = DASHBOARD_JOB_NAME, wait_ms = STOP_WAIT_MS })
end

local function maybe_stop_dashboard_before_install()
    if SKIP_DASHBOARD_START or not dashboard_job_active() then
        return
    end

    if RESTART_DASHBOARD then
        stop_dashboard("stopping dashboard before requested restart")
    end
end

local function start_dashboard_now()
    local ok, err = pcall(function()
        event_publisher.publish_trigger({
            source_cap = "install_token",
            event_type = "trigger",
            event_key = "token_usage_start",
            payload = {
                source = "install_token",
                task = "start_dashboard",
            },
        })
    end)
    if ok then
        print("[install_token] token_usage.lua start event queued")
    else
        fail("failed to queue token_usage.lua start event: " .. tostring(err))
    end
end

local function maybe_start_dashboard_after_install()
    if SKIP_DASHBOARD_START then
        print("[install_token] skip_dashboard_start=true; dashboard start skipped")
        return
    end

    local status, job_args = dashboard_job_status()
    local active = status == "running" or status == "queued"
    if active and not RESTART_DASHBOARD and dashboard_host_port_match(job_args) then
        print("[install_token] dashboard already running with same host/port; skip start")
        print("[install_token] pass restart_dashboard=true to stop and relaunch, or reboot to apply host/port changes")
        return
    end

    if active then
        print("[install_token] dashboard remains active; pass restart_dashboard=true to apply new host/port now")
        return
    end

    start_dashboard_now()
end

print("[install_token] host=" .. INSTALL_HOST .. " port=" .. tostring(INSTALL_PORT))
print("[install_token] letter language: " .. LETTER_LANGUAGE)
print(string.format("[install_token] snapshot every %d hour(s), letter every min (send at minute %d)",
    MEMORY_INTERVAL_HOURS, LETTER_SEND_MINUTE))
maybe_stop_dashboard_before_install()
install_soul()
install_router_rules()
install_schedules()
call_required("scheduler_trigger_now", { id = SNAPSHOT_SCHEDULE_ID })
maybe_start_dashboard_after_install()
print("[install_token] install complete")
