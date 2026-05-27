local storage = require("storage")
local event_publisher = require("event_publisher")
local json = require("json")

local STARTUP_RULE_ID = "startup_run_planter"
local START_NOW_RULE_ID = "install_start_planter_sensor"
local LETTER_RULE_ID = "schedule_run_planter_letter"
local LETTER_SCHEDULE_ID = "planter_letter_every_2m"

-- Language used by planter_letter.lua when asking the LLM to write the
-- scheduled letter. The scheduled task has no live user input to detect
-- language from, so we bake a configured value into the schedule payload
-- and pass it into the script via the router rule's args. Override at
-- install time with: args = { language = "English" } / "日本語" / etc.
local DEFAULT_LETTER_LANGUAGE = "Chinese"

local install_args = (type(args) == "table") and args or {}
local LETTER_LANGUAGE = (type(install_args.language) == "string" and install_args.language ~= "")
    and install_args.language
    or DEFAULT_LETTER_LANGUAGE

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
    print("[install_planter] ERROR: " .. msg)
    error(msg)
end

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
        print("[install_planter] " .. label .. " " .. item.id .. " appended")
    else
        print("[install_planter] " .. label .. " " .. item.id .. " updated")
    end
    return out
end

local function install_soul()
    local root = storage.get_root_dir()
    local src = storage.join_path(skill_dir(), "soul_planter.md")
    local dst = storage.join_path(root, "memory", "soul.md")
    local content = read_text_file(src)
    write_text_file(dst, content)
    print("[install_planter] soul.md updated (" .. dst .. ")")
end

local function resident_script_path()
    return storage.join_path(storage.get_root_dir(), "skills", "planter", "scripts", "planter_sensor.lua")
end

local function letter_script_path()
    return storage.join_path(storage.get_root_dir(), "skills", "planter", "scripts", "planter_letter.lua")
end

local function startup_rule()
    return {
        id = STARTUP_RULE_ID,
        description = "Run planter_sensor.lua once the device finishes booting.",
        enabled = true,
        consume_on_match = false,
        ack = "startup planter_sensor.lua executed",
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
                    path = resident_script_path(),
                    async = true,
                    name = "planter_sensor",
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
        description = "Run planter_sensor.lua after install_planter.lua finishes.",
        enabled = true,
        consume_on_match = true,
        ack = "install-triggered planter_sensor.lua executed",
        match = {
            source_cap = "install_planter",
            event_type = "trigger",
            event_key = "planter_sensor_start",
            content_type = "trigger",
        },
        actions = {
            {
                type = "run_script",
                input = {
                    path = resident_script_path(),
                    async = true,
                    name = "planter_sensor",
                    exclusive = "display",
                    replace = true,
                    timeout_ms = 0,
                },
            },
        },
    }
end

local function letter_router_rule()
    return {
        id = LETTER_RULE_ID,
        description = "Run planter_letter.lua when the planter letter schedule fires.",
        enabled = true,
        consume_on_match = true,
        ack = "scheduled planter letter executed",
        match = {
            event_type = "schedule",
            event_key = "planter_letter",
            content_type = "trigger",
        },
        actions = {
            {
                type = "run_script",
                input = {
                    path = letter_script_path(),
                    async = true,
                    args = {
                        language = "{{event.payload.language}}",
                    },
                },
            },
        },
    }
end

local function letter_schedule()
    local payload = {
        source = "planter",
        task = "write_letter",
        language = LETTER_LANGUAGE,
    }
    return {
        id = LETTER_SCHEDULE_ID,
        enabled = true,
        kind = "interval",
        interval_ms = 120000,
        event_type = "schedule",
        event_key = "planter_letter",
        source_channel = "time",
        content_type = "trigger",
        session_policy = "trigger",
        text = "planter letter tick",
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
    rules = upsert_by_id(rules, letter_router_rule(), "router rule")

    write_text_file(rules_path, json.encode(rules))
end

local function install_schedule()
    local root = storage.get_root_dir()
    local schedules_path = storage.join_path(root, "scheduler", "schedules.json")
    local schedules = read_json_array(schedules_path)

    schedules = upsert_by_id(schedules, letter_schedule(), "schedule")

    write_text_file(schedules_path, json.encode(schedules))
end

local function call_capability(name, input, ok_message, warn_message)
    local has_capability, capability = pcall(require, "capability")
    if not has_capability then
        print("[install_planter] WARN: capability module unavailable; reboot to apply " .. warn_message)
        return
    end

    local ok, out, err = capability.call(name, input or {}, {
        source_cap = "install_planter",
    })
    if not ok then
        print("[install_planter] WARN: " .. name .. " failed: " .. tostring(err or out))
        return
    end
    print("[install_planter] " .. ok_message)
    if out ~= nil and tostring(out) ~= "" then
        print("[install_planter] " .. name .. " output: " .. tostring(out))
    end
end

local function start_resident_script_now()
    local ok, err = pcall(function()
        event_publisher.publish_trigger({
            source_cap = "install_planter",
            event_type = "trigger",
            event_key = "planter_sensor_start",
            payload = {
                source = "install_planter",
                task = "start_resident_sensor",
            },
        })
    end)
    if ok then
        print("[install_planter] planter_sensor.lua start event queued")
    else
        print("[install_planter] WARN: failed to queue planter_sensor.lua start event: " .. tostring(err))
    end
end

print("[install_planter] letter language: " .. LETTER_LANGUAGE)
install_soul()
install_router_rules()
install_schedule()
call_capability("reload_router_rules", {}, "reload_router_rules ok", "router rules")
call_capability("scheduler_reload", {}, "scheduler_reload ok", "scheduler")
start_resident_script_now()
print("[install_planter] install complete")
