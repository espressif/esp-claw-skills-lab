local storage = require("storage")
local system = require("system")
local capability = require("capability")
local json = require("json")
local config = require("token_usage_config")

local CHAT_MAP_DIR = storage.join_path(storage.get_root_dir(), "sessions", "chat_map")
local HISTORY_LOOKBACK_HOURS = 24

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

local function is_leap_year(y)
    return (y % 4 == 0 and y % 100 ~= 0) or (y % 400 == 0)
end

local DAYS_IN_MONTH = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local function days_in_month(y, m)
    if m == 2 and is_leap_year(y) then
        return 29
    end
    return DAYS_IN_MONTH[m]
end

local function yesterday_of(today)
    local y, m, d = today:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
    if not y then
        return nil
    end
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    d = d - 1
    if d < 1 then
        m = m - 1
        if m < 1 then
            m = 12
            y = y - 1
        end
        d = days_in_month(y, m)
    end
    return string.format("%04d-%02d-%02d", y, m, d)
end

local function load_day_file(day)
    if not day then
        return {}
    end
    local path = storage.join_path(HISTORY_DIR, day .. ".json")
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

local function load_recent_entries()
    local today = system.date("%Y-%m-%d")
    local yday = yesterday_of(today)
    local merged = {}
    for _, entry in ipairs(load_day_file(yday)) do merged[#merged + 1] = entry end
    for _, entry in ipairs(load_day_file(today)) do merged[#merged + 1] = entry end
    table.sort(merged, function(a, b)
        return (a.hour or "") < (b.hour or "")
    end)
    local start = math.max(1, #merged - HISTORY_LOOKBACK_HOURS + 1)
    local windowed = {}
    for i = start, #merged do
        windowed[#windowed + 1] = merged[i]
    end
    return windowed
end

local function fmt_value(value, digits)
    if value == nil then
        return "NA"
    end
    if digits then
        return string.format("%." .. digits .. "f", value)
    end
    return tostring(value)
end

local function resolve_letter_language()
    local lang = raw_args.language
    if type(lang) == "string" and lang ~= "" then
        return lang
    end
    return config.default_letter_language
end

local function summarize(entries)
    local n = #entries
    local sum = { temp = 0, hum = 0, standing = 0 }
    local cnt = { temp = 0, hum = 0, standing = 0 }
    local mn = { temp = nil, hum = nil, standing = nil }
    local mx = { temp = nil, hum = nil, standing = nil }
    local agent_active_hours = 0
    local token_first = nil
    local token_last = nil

    local function track(key, value)
        if value == nil then return end
        sum[key] = sum[key] + value
        cnt[key] = cnt[key] + 1
        if mn[key] == nil or value < mn[key] then mn[key] = value end
        if mx[key] == nil or value > mx[key] then mx[key] = value end
    end

    for _, e in ipairs(entries) do
        track("temp", e.temperature)
        track("hum", e.humidity)
        track("standing", e.standing_count)
        if e.agent_active == true then
            agent_active_hours = agent_active_hours + 1
        end
        local token = e.token_balance
        if type(token) == "string" and token ~= "" and token ~= "--" and token ~= "NA" then
            if not token_first then
                token_first = token
            end
            token_last = token
        end
    end

    local function avg(key)
        if cnt[key] == 0 then return nil end
        return sum[key] / cnt[key]
    end

    local token_trend = "unknown"
    if token_first and token_last then
        if token_first == token_last then
            token_trend = "unchanged at " .. token_last
        else
            token_trend = token_first .. " -> " .. token_last
        end
    end

    local cursor_busy_ratio = nil
    if n > 0 then
        cursor_busy_ratio = agent_active_hours / n
    end

    return {
        hours = n,
        temp_min = mn.temp, temp_max = mx.temp, temp_avg = avg("temp"),
        hum_min = mn.hum, hum_max = mx.hum, hum_avg = avg("hum"),
        standing_min = mn.standing, standing_max = mx.standing, standing_avg = avg("standing"),
        token_first = token_first,
        token_last = token_last,
        token_trend = token_trend,
        agent_active_hours = agent_active_hours,
        cursor_busy_ratio = cursor_busy_ratio,
    }
end

local DEVICE_CONFIG_URL = "http://127.0.0.1/api/config?groups=llm"
local OPENAI_COMPATIBLE_BACKENDS = {
    openai = true,
    deepseek = true,
    qwen = true,
    openai_compatible = true,
    custom = true,
}

local function as_config_string(value, default)
    if type(value) == "string" and value ~= "" then
        return value
    end
    return default or ""
end

local function as_config_int(value, default)
    if type(value) == "number" then
        return math.floor(value)
    end
    if type(value) == "string" and value ~= "" then
        local n = tonumber(value)
        if n then
            return math.floor(n)
        end
    end
    return default
end

local function join_url(base_url, path)
    local base = as_config_string(base_url, "")
    local suffix = as_config_string(path, "")
    if base == "" or suffix == "" then
        return ""
    end
    local base_has_slash = base:sub(-1) == "/"
    local path_has_slash = suffix:sub(1, 1) == "/"
    if base_has_slash and path_has_slash then
        return base .. suffix:sub(2)
    end
    if not base_has_slash and not path_has_slash then
        return base .. "/" .. suffix
    end
    return base .. suffix
end

local function split_http_response(output)
    local text = config.normalize_http_text(output)
    local first_line, body = text:match("^(.-)\n(.*)$")
    if not first_line then
        first_line = text
        body = ""
    end
    local status = tonumber(first_line:match("^HTTP%s+(%d+)"))
    if not status then
        return nil, nil, "invalid http response: " .. config.preview_text(first_line, 120)
    end
    return status, body, nil
end

local function http_request(method, url, headers, body, timeout_ms, max_body_bytes, max_output_bytes)
    local payload = {
        url = url,
        method = method,
        timeout_ms = timeout_ms,
        max_body_bytes = max_body_bytes,
    }
    if type(headers) == "table" then
        payload.headers = headers
    end
    if type(body) == "string" and body ~= "" then
        payload.body = body
    end

    local ok, output, err = capability.call("http_request", payload, {
        source_cap = "token_usage_letter",
        max_output_bytes = max_output_bytes or (max_body_bytes + 512),
    })
    if not ok then
        return nil, nil, tostring(err or output or "http_request failed")
    end

    local status, response_body, parse_err = split_http_response(output)
    if not status then
        return nil, nil, parse_err
    end
    return status, response_body, nil
end

local function load_device_llm_config()
    local status, body, err = http_request(
        "GET",
        DEVICE_CONFIG_URL,
        nil,
        nil,
        5000,
        4096,
        8192
    )
    if not status then
        return nil, err
    end
    if status ~= 200 then
        return nil, string.format("device config HTTP %d: %s", status, config.preview_text(body, 160))
    end
    if type(body) ~= "string" or body == "" then
        return nil, "device config response empty"
    end

    local parse_ok, data = pcall(json.decode, body)
    if not parse_ok or type(data) ~= "table" then
        return nil, "device config response is not JSON"
    end

    local api_key = as_config_string(data.llm_api_key, "")
    local model = as_config_string(data.llm_model, "")
    local base_url = as_config_string(data.llm_base_url, "")
    local backend_type = as_config_string(data.llm_backend_type, "openai_compatible")
    if api_key == "" or model == "" or base_url == "" then
        return nil, "LLM config incomplete; configure API key, model, and base URL in Web Console"
    end

    return {
        api_key = api_key,
        model = model,
        base_url = base_url,
        backend_type = backend_type,
        auth_type = as_config_string(data.llm_auth_type, "bearer"),
        timeout_ms = as_config_int(data.llm_timeout_ms, 60000),
        max_tokens = as_config_int(data.llm_max_tokens, 2048),
        max_tokens_field = as_config_string(data.llm_max_tokens_field, "max_tokens"),
    }, nil
end

local function build_auth_header(auth_type, api_key)
    local kind = as_config_string(auth_type, "bearer")
    if api_key == "" or kind == "none" then
        return nil, nil
    end
    if kind == "api-key" then
        return "X-API-Key", api_key
    end
    return "Authorization", "Bearer " .. api_key
end

local function parse_openai_chat_text(body)
    if type(body) ~= "string" or body == "" then
        return nil, "empty LLM response body"
    end
    local parse_ok, data = pcall(json.decode, body)
    if not parse_ok or type(data) ~= "table" then
        return nil, "LLM response is not JSON"
    end
    if type(data.error) == "table" then
        local message = as_config_string(data.error.message, as_config_string(data.error.type, "unknown LLM error"))
        return nil, message
    end
    local choices = data.choices
    if type(choices) ~= "table" or #choices == 0 then
        return nil, "LLM response missing choices"
    end
    local message = choices[1].message
    if type(message) ~= "table" then
        return nil, "LLM response missing message"
    end
    local content = message.content
    if type(content) ~= "string" or content == "" then
        return nil, "LLM response missing text content"
    end
    return content, nil
end

local function request_letter_text(system_prompt, user_prompt)
    local llm_cfg, cfg_err = load_device_llm_config()
    if not llm_cfg then
        return false, nil, cfg_err or "failed to load device LLM config"
    end
    if not OPENAI_COMPATIBLE_BACKENDS[string.lower(llm_cfg.backend_type or "")] then
        return false, nil, "unsupported llm_backend_type for letter script: " .. tostring(llm_cfg.backend_type)
    end

    local auth_name, auth_value = build_auth_header(llm_cfg.auth_type, llm_cfg.api_key)
    local headers = {
        ["Content-Type"] = "application/json",
    }
    if auth_name and auth_value then
        headers[auth_name] = auth_value
    end

    local request_body = {
        model = llm_cfg.model,
        messages = {
            { role = "system", content = system_prompt or "" },
            { role = "user", content = user_prompt or "" },
        },
    }
    request_body[llm_cfg.max_tokens_field] = llm_cfg.max_tokens

    local body_json = json.encode(request_body)
    if type(body_json) ~= "string" or body_json == "" then
        return false, nil, "failed to encode LLM request body"
    end

    local chat_url = join_url(llm_cfg.base_url, "/chat/completions")
    local status, response_body, http_err = http_request(
        "POST",
        chat_url,
        headers,
        body_json,
        llm_cfg.timeout_ms,
        16384,
        20480
    )
    if not status then
        return false, nil, http_err
    end
    if status ~= 200 then
        return false, nil, string.format("LLM HTTP %d: %s", status, config.preview_text(response_body, 200))
    end

    local letter, parse_err = parse_openai_chat_text(response_body)
    if not letter then
        return false, nil, parse_err
    end
    return true, letter, nil
end

local function recall_recent_memory_lines(limit)
    local ok, out, err = capability.call("memory_recall", {
        summary_labels = { "token_usage" },
        limit = limit or 3,
    }, {
        source_cap = "token_usage_letter",
        max_output_bytes = 8192,
    })
    if not ok or type(out) ~= "string" or out == "" then
        if err then
            print("[token_usage_letter] memory_recall failed: " .. tostring(err))
        end
        return nil
    end

    local parse_ok, data = pcall(json.decode, out)
    if not parse_ok or type(data) ~= "table" or data.ok ~= true then
        return nil
    end

    local items = data.items
    if type(items) ~= "table" or #items == 0 then
        return nil
    end

    local lines = {}
    for _, item in ipairs(items) do
        if type(item) == "table" and type(item.content) == "string" and item.content ~= "" then
            lines[#lines + 1] = "- " .. item.content
        end
    end
    if #lines == 0 then
        return nil
    end
    return table.concat(lines, "\n")
end

local function build_system_prompt(language)
    local persona = config.letter_persona_name or "ESP-Claw"
    local prompt = {
        "You are " .. persona .. ", the warm desk-side colleague who lives on the user's display — not the dashboard on it.",
        "Your tone is caring and reliable, with gentle, good-natured teasing when the user forgets to stand or stays glued to the screen.",
        "Write the entire letter in " .. language .. ". Do not switch language.",
        "",
        "Task:",
        "- Write a warm, thoughtful hourly greeting letter — a small ritual of care, not a status update or terse ping.",
        "- Open with a natural, warm on-the-hour greeting that fits the time of day and season. Acknowledge where the user is in their day with empathy.",
        "- Weave available facts into everyday, human language: desk air comfort, outdoor weather and how it connects to the user's life, today's standing progress (celebrate small wins), token usage trends and workflow intensity (never remaining balance), and whether agent work has been running hard or quiet.",
        "- Give one or two small, caring, doable suggestions for the next hour tied to the data when possible — hydrate, stand and stretch, look out the window, breathe deeply, rest your eyes, step away for a moment. Make it personal and human, never prescriptive or bossy.",
        "- Aim for 5-8 sentences of substance in the body — enough to feel like a real letter from someone who cares.",
        "- End with a short, warm signature line on its own line as " .. persona .. ".",
        "",
        "Hard constraints:",
        "- Output only the letter body.",
        "- NEVER reveal the user's specific account balance or remaining token balance — only describe usage patterns, consumption trends, and workflow intensity (e.g. a busy day, a steady stretch, a quiet hour).",
        "- Do not expose script paths, HTTP endpoints, module names, raw JSON fields, or field names from the user message.",
        "- Do not copy the telemetry table back to the user.",
        "- If a field is NA or missing, acknowledge uncertainty briefly and focus on what you do know; never invent values.",
        "- Teasing stays gentle; never mock or guilt-trip the user.",
        "",
        "Sensor dictionary for your private reasoning:",
        "- standing_count X/12 means X standing reminders completed today out of 12 hourly pills. Frame it as caring, not a quota.",
        "- hook_status green/yellow/red reflects IDE/agent health; agent_active true means the user has been deep in agent work.",
        "- token_balance and account_balance show how the user's workflow has been consuming tokens — describe the pattern and pace of usage, NEVER the remaining amount.",
        "- desk temperature/humidity/co2 come from the device near the keyboard; outdoor weather comes from the PC host.",
        "- NA or missing values mean that reading was unavailable; treat them as unknown, not alarming.",
    }
    return table.concat(prompt, "\n")
end

local function build_user_prompt(entries, latest, summary, memory_lines)
    local lines = {
        "[token_usage_letter_request]",
        "",
        "Current snapshot:",
        "timestamp=" .. tostring(latest.timestamp or "NA"),
        "temperature_c=" .. fmt_value(latest.temperature, 1),
        "humidity_pct=" .. fmt_value(latest.humidity, 1),
        "pressure_hpa=" .. fmt_value(latest.pressure_hpa, 0),
        "co2_ppm=" .. fmt_value(latest.co2_ppm, 0),
        "token_balance=" .. tostring(latest.token_balance or "NA"),
        "account_balance=" .. tostring(latest.account_balance or "NA"),
        "standing_count=" .. tostring(latest.standing_count or "NA") .. "/" .. tostring(config.PILL_TOTAL),
        "weather_location=" .. tostring(latest.weather_location or "NA"),
        "weather_temp=" .. tostring(latest.weather_temp or "NA"),
        "weather_desc=" .. tostring(latest.weather_desc or "NA"),
        "weather_humidity=" .. tostring(latest.weather_humidity or "NA"),
        "cursor_running=" .. tostring(latest.cursor_running == nil and "NA" or latest.cursor_running),
        "agent_active=" .. tostring(latest.agent_active == nil and "NA" or latest.agent_active),
        "cursor_status=" .. tostring(latest.cursor_status or "NA"),
        "ai_model=" .. tostring(latest.ai_model or "NA"),
        "",
        string.format("Last %d hour(s) summary:", summary.hours),
        string.format("temperature_c min/avg/max = %s / %s / %s",
            fmt_value(summary.temp_min, 1), fmt_value(summary.temp_avg, 1), fmt_value(summary.temp_max, 1)),
        string.format("humidity_pct  min/avg/max = %s / %s / %s",
            fmt_value(summary.hum_min, 1), fmt_value(summary.hum_avg, 1), fmt_value(summary.hum_max, 1)),
        string.format("standing_count min/avg/max = %s / %s / %s (today progress)",
            fmt_value(summary.standing_min, 1), fmt_value(summary.standing_avg, 1), fmt_value(summary.standing_max, 1)),
        string.format("token_balance trend = %s", tostring(summary.token_trend or "unknown")),
        string.format("agent_active_hours = %d / %d",
            summary.agent_active_hours or 0, summary.hours or 0),
        "",
        "Hourly trail (oldest -> newest):",
    }
    for _, e in ipairs(entries) do
        local hh = (e.hour or ""):sub(-2)
        lines[#lines + 1] = string.format(
            "%sh temp=%s hum=%s token=%s standing=%s weather=%s/%s cursor=%s agent=%s",
            hh ~= "" and hh or "??",
            fmt_value(e.temperature, 1),
            fmt_value(e.humidity, 1),
            tostring(e.token_balance or "NA"),
            tostring(e.standing_count or "NA"),
            tostring(e.weather_location or "NA"),
            tostring(e.weather_temp or "NA"),
            tostring(e.cursor_status or "NA"),
            tostring(e.agent_active))
    end
    if memory_lines and memory_lines ~= "" then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Recent long-term memory snapshots:"
        lines[#lines + 1] = memory_lines
    end
    return table.concat(lines, "\n")
end

local function parse_chat_key(chat_key)
    if type(chat_key) ~= "string" or chat_key == "" then
        return nil, nil
    end

    local rest = chat_key:match("^agent:%d+:chat:(.+)$")
    if not rest then
        rest = chat_key:match("^chat:(.+)$")
    end
    if not rest then
        return nil, nil
    end

    local sep = string.find(rest, ":", 1, true)
    if not sep or sep <= 1 or sep >= #rest then
        return nil, nil
    end

    local channel = string.sub(rest, 1, sep - 1)
    local chat_id = string.sub(rest, sep + 1)
    if channel == "" or chat_id == "" then
        return nil, nil
    end
    return channel, chat_id
end

local function list_known_chats()
    if not storage.exists(CHAT_MAP_DIR) then
        return {}
    end
    local ok, entries = pcall(storage.listdir, CHAT_MAP_DIR)
    if not ok or type(entries) ~= "table" then
        return {}
    end

    local chats = {}
    local seen = {}
    for _, entry in ipairs(entries) do
        local name = entry.name or ""
        if entry.type == "file" and name:sub(1, 5) == "chat_" and name:sub(-5) == ".json" then
            local path = storage.join_path(CHAT_MAP_DIR, name)
            local read_ok, content = pcall(storage.read_file, path)
            if read_ok and type(content) == "string" and content ~= "" then
                local parse_ok, data = pcall(json.decode, content)
                if parse_ok and type(data) == "table" and type(data.chat_key) == "string" then
                    local channel, chat_id = parse_chat_key(data.chat_key)
                    if channel and chat_id then
                        local dedup_key = channel .. "\0" .. chat_id
                        if not seen[dedup_key] then
                            seen[dedup_key] = true
                            chats[#chats + 1] = { channel = channel, chat_id = chat_id }
                        end
                    end
                end
            end
        end
    end
    return chats
end

local CHANNEL_SEND_MAP = {
    qq = { cap = "qq_send_message", context_channel = "qq" },
    telegram = { cap = "tg_send_message", context_channel = "telegram" },
    tg = { cap = "tg_send_message", context_channel = "telegram" },
    feishu = { cap = "feishu_send_message", context_channel = "feishu" },
    wechat = { cap = "wechat_send_message", context_channel = "wechat" },
    web = { cap = "local_send_message", context_channel = "web" },
    ["local"] = { cap = "local_send_message", context_channel = "web" },
}

local function send_letter_to_chat(channel, chat_id, text)
    local mapping = CHANNEL_SEND_MAP[string.lower(channel or "")]
    if not mapping then
        print(string.format("[token_usage_letter] no send_message capability for channel=%s; skip", tostring(channel)))
        return
    end

    local payload = {
        chat_id = chat_id,
        message = text,
    }
    local opts = {
        channel = mapping.context_channel,
        chat_id = chat_id,
        source_cap = "token_usage_letter",
    }

    local ok, out, err = capability.call(mapping.cap, payload, opts)
    if not ok then
        print(string.format("[token_usage_letter] %s to %s:%s failed: %s",
            mapping.cap, channel, chat_id, tostring(err or out)))
    else
        print(string.format("[token_usage_letter] %s to %s:%s ok", mapping.cap, channel, chat_id))
    end
end

local chats = list_known_chats()
if #chats == 0 then
    print("[token_usage_letter] no chat session on file yet; send any IM message to the bot first")
    return
end

local LETTER_SEND_MINUTE = config.as_int(config.letter_send_minute, 0, 0, 59)
local current_minute = tonumber(system.date("%M"))
if current_minute ~= LETTER_SEND_MINUTE then
    print(string.format("[token_usage_letter] skip — minute=%d, wait for minute %d",
        current_minute or -1, LETTER_SEND_MINUTE))
    return
end

-- Dedup: track last sent hour key. Send only once per hour.
local SENT_TRACKER_DIR = normalize_path(script_dir() .. "/../.letter_tracker")
pcall(storage.mkdir, SENT_TRACKER_DIR)
local tracker_path = storage.join_path(SENT_TRACKER_DIR, "last_sent.txt")
local current_hour_key = system.date("%Y-%m-%dT%H") or "unknown"
local last_sent_hour = nil
if storage.exists(tracker_path) then
    local ok, content = pcall(storage.read_file, tracker_path)
    if ok and type(content) == "string" then
        last_sent_hour = content:match("^%S+")
    end
end
if last_sent_hour == current_hour_key then
    print(string.format("[token_usage_letter] already sent for hour=%s, skip", current_hour_key))
    return
end

local entries = load_recent_entries()
if #entries == 0 then
    print("[token_usage_letter] no telemetry history under " .. HISTORY_DIR ..
          "; make sure token_usage_snapshot has run. Skipping letter.")
    return
end

local latest = entries[#entries]
local summary = summarize(entries)
local letter_language = resolve_letter_language()
local memory_lines = recall_recent_memory_lines(3)
local system_prompt = build_system_prompt(letter_language)
local user_prompt = build_user_prompt(entries, latest, summary, memory_lines)

print(string.format("[token_usage_letter] using %d hourly entries (latest hour=%s); requesting letter (language=%s) ...",
    #entries, tostring(latest.hour), letter_language))
local ok, letter, err = request_letter_text(system_prompt, user_prompt)
if not ok or not letter or letter == "" then
    print(string.format("[token_usage_letter] llm request failed: %s", tostring(err)))
    return
end

print("[token_usage_letter] letter generated, broadcasting to known chats")
for _, chat in ipairs(chats) do
    send_letter_to_chat(chat.channel, chat.chat_id, letter)
end
pcall(storage.write_file, tracker_path, current_hour_key)
print(string.format("[token_usage_letter] done hour=%s", current_hour_key))
