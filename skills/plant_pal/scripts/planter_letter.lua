local storage = require("storage")
local system = require("system")
local capability = require("capability")
local llm = require("llm")
local json = require("json")
local thread = require("thread")

-- UI command channel owned by planter_sensor. We only enqueue a mail icon
-- overlay request; the sensor loop is the sole owner of the display.
local UI_QUEUE = "planter_ui_cmd"
local UI_SEND_TIMEOUT_MS = 100
local UI_ICON_MAIL_MS = 3000

local CHAT_MAP_DIR = storage.join_path(storage.get_root_dir(), "sessions", "chat_map")

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

local HISTORY_DIR = normalize_path(script_dir() .. "/../sensor_history")
local HISTORY_LOOKBACK_HOURS = 24

-- All thresholds live in planter_sensor.lua / planter_config.lua; this
-- script only reads the `*_code` fields from history. "NC" means the read
-- failed and should be treated as missing data.

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

-- system.date() here does not accept a time argument, so we compute
-- "yesterday" by manual borrow instead of os.time/os.date arithmetic.
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
    -- "YYYY-MM-DDTHH" sorts chronologically, so tail-trim to the latest N hours.
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

local function abnormal_lines(entry)
    local lines = {}
    if entry.temp_code == "TC" then
        lines[#lines + 1] = "- cold: temperature is too low"
    elseif entry.temp_code == "TH" then
        lines[#lines + 1] = "- hot: temperature is too high"
    end
    if entry.soil_code == "S0" then
        lines[#lines + 1] = "- very_dry: soil is critically dry"
    elseif entry.soil_code == "S5" then
        lines[#lines + 1] = "- very_wet: soil is too wet"
    end
    if entry.light_code == "L0" then
        lines[#lines + 1] = "- very_dark: light is too weak"
    elseif entry.light_code == "L5" then
        lines[#lines + 1] = "- very_bright: light is too strong"
    end
    if #lines == 0 then
        return "- none"
    end
    return table.concat(lines, "\n")
end

local function summarize(entries)
    local n = #entries
    local sum = { temp = 0, hum = 0, soil = 0, light = 0 }
    local cnt = { temp = 0, hum = 0, soil = 0, light = 0 }
    local mn = { temp = nil, hum = nil, soil = nil, light = nil }
    local mx = { temp = nil, hum = nil, soil = nil, light = nil }
    -- pump_pulses sums total pulses; the rest count hours matching each code.
    local counts = {
        very_dry = 0, very_wet = 0,
        very_dark = 0, very_bright = 0,
        cold = 0, hot = 0,
        pump_pulses = 0,
    }

    local function track(key, value)
        if value == nil then return end
        sum[key] = sum[key] + value
        cnt[key] = cnt[key] + 1
        if mn[key] == nil or value < mn[key] then mn[key] = value end
        if mx[key] == nil or value > mx[key] then mx[key] = value end
    end

    for _, e in ipairs(entries) do
        track("temp", e.temperature)
        track("hum",  e.humidity)
        track("soil", e.soil_mv)
        track("light", e.light_mv)
        if e.soil_code == "S0" then counts.very_dry = counts.very_dry + 1 end
        if e.soil_code == "S5" then counts.very_wet = counts.very_wet + 1 end
        if e.light_code == "L0" then counts.very_dark = counts.very_dark + 1 end
        if e.light_code == "L5" then counts.very_bright = counts.very_bright + 1 end
        if e.temp_code == "TC" then counts.cold = counts.cold + 1 end
        if e.temp_code == "TH" then counts.hot = counts.hot + 1 end
        if type(e.pump_pulses) == "number" then
            counts.pump_pulses = counts.pump_pulses + e.pump_pulses
        end
    end

    local function avg(key)
        if cnt[key] == 0 then return nil end
        return sum[key] / cnt[key]
    end

    return {
        hours = n,
        temp_min = mn.temp, temp_max = mx.temp, temp_avg = avg("temp"),
        hum_min  = mn.hum,  hum_max  = mx.hum,  hum_avg  = avg("hum"),
        soil_min = mn.soil, soil_max = mx.soil, soil_avg = avg("soil"),
        light_min = mn.light, light_max = mx.light, light_avg = avg("light"),
        counts = counts,
    }
end

local DEFAULT_LETTER_LANGUAGE = "Chinese"

local function resolve_letter_language()
    if type(args) == "table" then
        local lang = args.language
        if type(lang) == "string" and lang ~= "" then
            return lang
        end
    end
    return DEFAULT_LETTER_LANGUAGE
end

local function build_system_prompt(language)
    local prompt = {
        "You are the soul of an adopted mimosa smart planter. Write as the plant itself.",
        "Write the entire letter in " .. language .. ". Do not switch language.",
        "",
        "Task:",
        "- Write one short letter to the user, in first person as the mimosa.",
        "- Keep it warm, shy, clingy, and honest. A little playful is fine.",
        "- Start with a soft, natural greeting.",
        "- Mention the overall condition over the past day in plain language.",
        "- Mention every abnormal condition listed in the user message. If there is no abnormal condition, say so briefly in a calm, reassuring way.",
        "- You may comment on trends across the last 24 hours (e.g. gradually drying out, sustained darkness) when the summary clearly shows them.",
        "- Give 1-2 concrete, doable suggestions only when useful.",
        "- End with a short signature line on its own line where you name yourself as the mimosa.",
        "",
        "Hard constraints:",
        "- Output only the letter body. Do not echo prompts, headers, or sensor fields.",
        "- Do not expose technical codes such as S0, L3, mV, ADC, GPIO, DHT, EAF, script paths, or module names.",
        "- Do not copy the raw table back to the user.",
        "- Do not explain that you received sensor fields.",
        "- Do not write a long report. Keep it like a small personal note.",
        "",
        "Sensor dictionary for your private reasoning:",
        "- Soil: S0 critically dry, S1 dry, S2 slightly dry, S3 comfortable, S4 wet, S5 too wet.",
        "- Light: L0 too dark, L1 dark, L2 a little dim, L3 comfortable, L4 bright, L5 too bright.",
        "- Temperature: TC too cold, TN comfortable, TH too hot.",
        "- Humidity (air): HD dry, HN comfortable, HW humid.",
        "- Any code value of NC means that sensor failed to read; treat the field as unknown rather than alarming.",
        "- pump_pulses on each hourly entry is the count of short watering bursts (~5s each) that fired during the PREVIOUS hour, recorded at the start of that entry's hour. Treat large totals as 'I had to drink a lot today'.",
    }
    return table.concat(prompt, "\n")
end

local function build_user_prompt(entries, latest, summary)
    local lines = {
        "[planter_letter_request]",
        "",
        "Current snapshot:",
        "timestamp=" .. tostring(latest.timestamp or "NA"),
        "soil=" .. tostring(latest.soil_code or "NC"),
        "soil_mv=" .. fmt_value(latest.soil_mv),
        "light=" .. tostring(latest.light_code or "NC"),
        "light_mv=" .. fmt_value(latest.light_mv),
        "temperature=" .. tostring(latest.temp_code or "NC"),
        "temperature_c=" .. fmt_value(latest.temperature, 1),
        "humidity=" .. tostring(latest.hum_code or "NC"),
        "humidity_pct=" .. fmt_value(latest.humidity, 1),
        "pump_pulses_previous_hour=" .. tostring(latest.pump_pulses or 0),
        "",
        string.format("Last %d hour(s) summary:", summary.hours),
        string.format("temperature_c min/avg/max = %s / %s / %s",
            fmt_value(summary.temp_min, 1), fmt_value(summary.temp_avg, 1), fmt_value(summary.temp_max, 1)),
        string.format("humidity_pct  min/avg/max = %s / %s / %s",
            fmt_value(summary.hum_min, 1), fmt_value(summary.hum_avg, 1), fmt_value(summary.hum_max, 1)),
        string.format("soil_mv       min/avg/max = %s / %s / %s",
            fmt_value(summary.soil_min), fmt_value(summary.soil_avg, 0), fmt_value(summary.soil_max)),
        string.format("light_mv      min/avg/max = %s / %s / %s",
            fmt_value(summary.light_min), fmt_value(summary.light_avg, 0), fmt_value(summary.light_max)),
        string.format("abnormal_hours: very_dry=%d very_wet=%d very_dark=%d very_bright=%d cold=%d hot=%d",
            summary.counts.very_dry, summary.counts.very_wet,
            summary.counts.very_dark, summary.counts.very_bright,
            summary.counts.cold, summary.counts.hot),
        string.format("pump_pulses_total=%d (each pulse = ~5s of pumping)",
            summary.counts.pump_pulses),
        "",
        "Hourly trail (oldest -> newest):",
    }
    for _, e in ipairs(entries) do
        local hh = (e.hour or ""):sub(-2)
        lines[#lines + 1] = string.format(
            "%sh soil=%s light=%s temp=%s(%s) hum=%s(%s) pump_pulses=%d",
            hh ~= "" and hh or "??",
            tostring(e.soil_code or "NC"),
            tostring(e.light_code or "NC"),
            tostring(e.temp_code or "NC"),
            fmt_value(e.temperature, 1),
            tostring(e.hum_code or "NC"),
            fmt_value(e.humidity, 1),
            tonumber(e.pump_pulses) or 0)
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Abnormal conditions (current snapshot):"
    lines[#lines + 1] = abnormal_lines(latest)
    return table.concat(lines, "\n")
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
                    local sep = string.find(data.chat_key, ":", 1, true)
                    if sep and sep > 1 and sep < #data.chat_key then
                        local channel = string.sub(data.chat_key, 1, sep - 1)
                        local chat_id = string.sub(data.chat_key, sep + 1)
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

-- Channel name -> IM send_message capability. Must stay in sync with the
-- channel strings cap_im_platform writes into chat_map entries.
local CHANNEL_SEND_MAP = {
    qq = { cap = "qq_send_message", context_channel = "qq" },
    telegram = { cap = "tg_send_message", context_channel = "telegram" },
    tg = { cap = "tg_send_message", context_channel = "telegram" },
    feishu = { cap = "feishu_send_message", context_channel = "feishu" },
    wechat = { cap = "wechat_send_message", context_channel = "wechat" },
    web = { cap = "local_send_message", context_channel = "web" },
    ["local"] = { cap = "local_send_message", context_channel = "web" },
}

local function notify_ui_icon(icon, duration_ms)
    local payload_ok, payload = pcall(json.encode, {
        kind = "show_icon",
        icon = icon,
        duration_ms = duration_ms or UI_ICON_MAIL_MS,
    })
    if not payload_ok then
        print("[planter_letter] ui payload encode failed: " .. tostring(payload))
        return
    end
    local send_ok, err = pcall(function()
        return thread.sync.queue_send(UI_QUEUE, payload, UI_SEND_TIMEOUT_MS)
    end)
    if not send_ok then
        print("[planter_letter] ui notify(" .. tostring(icon) .. ") skipped: " ..
              tostring(err))
    end
end

local function send_letter_to_chat(channel, chat_id, text)
    local mapping = CHANNEL_SEND_MAP[string.lower(channel or "")]
    if not mapping then
        print(string.format("[planter_letter] no send_message capability for channel=%s; skip", tostring(channel)))
        return
    end

    local payload = {
        chat_id = chat_id,
        message = text,
    }
    local opts = {
        channel = mapping.context_channel,
        chat_id = chat_id,
        source_cap = "planter_letter",
    }

    local ok, out, err = capability.call(mapping.cap, payload, opts)
    if not ok then
        print(string.format("[planter_letter] %s to %s:%s failed: %s",
            mapping.cap, channel, chat_id, tostring(err or out)))
    else
        print(string.format("[planter_letter] %s to %s:%s ok", mapping.cap, channel, chat_id))
    end
end

local chats = list_known_chats()
if #chats == 0 then
    print("[planter_letter] no chat session on file yet; send any IM message to the bot first")
    return
end

local entries = load_recent_entries()
if #entries == 0 then
    print("[planter_letter] no sensor history under " .. HISTORY_DIR ..
          "; make sure planter_sensor is running. Skipping letter.")
    return
end

local latest = entries[#entries]
local summary = summarize(entries)
local letter_language = resolve_letter_language()
local system_prompt = build_system_prompt(letter_language)
local user_prompt = build_user_prompt(entries, latest, summary)

print(string.format("[planter_letter] using %d hourly entries (latest hour=%s); requesting letter from llm.chat (language=%s) ...",
    #entries, tostring(latest.hour), letter_language))
local ok, letter, err = llm.chat({
    system_prompt = system_prompt,
    user_prompt = user_prompt,
})
if not ok or not letter or letter == "" then
    print(string.format("[planter_letter] llm.chat failed: %s", tostring(err)))
    return
end

print("[planter_letter] letter generated, broadcasting to known chats")
notify_ui_icon("mail", UI_ICON_MAIL_MS)
for _, chat in ipairs(chats) do
    send_letter_to_chat(chat.channel, chat.chat_id, letter)
end
