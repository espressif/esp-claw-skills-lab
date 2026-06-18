local storage = require("storage")
local event_publisher = require("event_publisher")
local json = require("json")
local token_config = require("token_usage_config")

local STARTUP_RULE_ID = "startup_run_token_usage"
local START_NOW_RULE_ID = "install_start_token_usage"
local SNAPSHOT_RULE_ID = "schedule_run_token_usage_snapshot"
local LETTER_RULE_ID = "schedule_run_token_usage_letter"
local SNAPSHOT_SCHEDULE_ID = "token_usage_snapshot"
local LETTER_SCHEDULE_ID = "token_usage_letter"
local DASHBOARD_JOB_NAME = "token_usage"
local DISPLAY_EXCLUSIVE = "display"
local STOP_WAIT_MS = 3000

local install_args = (type(args) == "table") and args or {}

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

local function skill_dir()
    return normalize_path(script_dir() .. "/..")
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

local function read_json_array(path)
    local raw = read_text_file(path)
    local parse_ok, value = pcall(json.decode, raw)
    if not parse_ok or type(value) ~= "table" then
        fail(path .. " is not a JSON array: " .. tostring(value))
    end
    return value
end

local function upsert_by_id(list, item, label)
    local found = false
    local out = {}
    for _, entry in ipairs(list) do
        if type(entry) == "table" and entry.id == item.id then
            out[#out + 1] = item
            found = true
        else
            out[#out + 1] = entry
        end
    end
    if not found then
        out[#out + 1] = item
        print("[install_token] " .. label .. " " .. item.id .. " appended")
    else
        print("[install_token] " .. label .. " " .. item.id .. " updated")
    end
    return out
end

local function install_soul()
    local root = storage.get_root_dir()
    local src = storage.join_path(skill_dir(), "soul_token.md")
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
        emote_settle_ms = 3000,
        cursor_poll_ms = 1000,
        status_poll_ms = 1000,
    }
end

local function startup_rule()
    return {
        id = STARTUP_RULE_ID,
        description = "Start token usage dashboard after boot tasks complete.",
        enabled = true,
        consume_on_match = true,
        ack = "startup token usage dashboard started",
        match = {
            source_cap = "app_claw",
            event_type = "startup",
            event_key = "startup_tasks_completed",
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
                    replace = true,
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
                    replace = true,
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
                        host = "{{event.payload.host}}",
                        port = "{{event.payload.port}}",
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
                        language = "{{event.payload.language}}",
                        host = "{{event.payload.host}}",
                        port = "{{event.payload.port}}",
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
    local root = storage.get_root_dir()
    local rules_path = storage.join_path(root, "router_rules", "router_rules.json")
    local rules = read_json_array(rules_path)

    rules = upsert_by_id(rules, startup_rule(), "router rule")
    rules = upsert_by_id(rules, start_now_router_rule(), "router rule")
    rules = upsert_by_id(rules, snapshot_router_rule(), "router rule")
    rules = upsert_by_id(rules, letter_router_rule(), "router rule")

    write_text_file(rules_path, json.encode(rules))
end

local function install_schedules()
    local root = storage.get_root_dir()
    local schedules_path = storage.join_path(root, "scheduler", "schedules.json")
    local schedules = read_json_array(schedules_path)
    local snapshot = snapshot_schedule()
    local letter = letter_schedule()

    schedules = upsert_by_id(schedules, snapshot, "schedule")
    schedules = upsert_by_id(schedules, letter, "schedule")

    write_text_file(schedules_path, json.encode(schedules))
    return snapshot, letter
end

local function call_capability(name, input, ok_message, warn_message)
    local has_capability, capability = pcall(require, "capability")
    if not has_capability then
        print("[install_token] WARN: capability module unavailable; reboot to apply " .. warn_message)
        return false, nil, "capability module unavailable"
    end

    local ok, out, err = capability.call(name, input or {}, {
        source_cap = "install_token",
        max_output_bytes = 8192,
    })
    if not ok then
        print("[install_token] WARN: " .. name .. " failed: " .. tostring(err or out))
        return false, out, err or out
    end
    if ok_message then
        print("[install_token] " .. ok_message)
    end
    if out ~= nil and tostring(out) ~= "" and ok_message then
        print("[install_token] " .. name .. " output: " .. tostring(out))
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

local function stop_display_jobs(reason)
    print("[install_token] " .. reason)
    call_capability("lua_stop_all_async_jobs", {
        exclusive = DISPLAY_EXCLUSIVE,
        wait_ms = STOP_WAIT_MS,
    }, "display jobs stopped", "display jobs")
end

local function maybe_stop_dashboard_before_install()
    if not dashboard_job_active() then
        return
    end

    local _, job_args = dashboard_job_status()
    local host_port_changed = not dashboard_host_port_match(job_args)
    if RESTART_DASHBOARD or host_port_changed then
        stop_display_jobs("stopping display jobs before reinstall to free Lua task memory")
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
        print("[install_token] WARN: failed to queue token_usage.lua start event: " .. tostring(err))
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
        stop_display_jobs("stopping display jobs before dashboard relaunch")
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
local installed_snapshot_schedule, installed_letter_schedule = install_schedules()
call_capability("reload_router_rules", {}, "reload_router_rules ok", "router rules")
call_capability("scheduler_reload", {}, "scheduler_reload ok", "scheduler")
call_capability("scheduler_update", {
    schedule_json = json.encode(installed_snapshot_schedule),
}, "scheduler_update ok", "snapshot schedule")
call_capability("scheduler_update", {
    schedule_json = json.encode(installed_letter_schedule),
}, "scheduler_update ok", "letter schedule")
call_capability("scheduler_trigger_now", {
    id = SNAPSHOT_SCHEDULE_ID,
}, "snapshot bootstrap triggered", "initial snapshot")
maybe_start_dashboard_after_install()
print("[install_token] install complete")
