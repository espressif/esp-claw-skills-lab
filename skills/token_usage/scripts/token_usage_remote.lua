-- token_usage_remote.lua
local json = require("json")
local capability = require("capability")
local config = require("token_usage_config")

local M = {}

function M.new_remote_state()
    return {
        cursor = {
            cursor_running = false,
            mode = "idle",
            agent_active = false,
            hook_status = "green",
            hook_event = "ready",
            hook_message = "Waiting for host",
            source = "Cursor",
            ai_model = "",
            last_cursor_update_ms = 0,
        },
        token = {
            balance_str = "--",
            account_balance = "0",
            is_available = false,
            query_ok = false,
            last_token_update_ms = 0,
        },
        weather = {
            temperature = "--",
            description = "--",
            humidity = "--",
            location = "--",
            query_ok = false,
            last_update_ms = 0,
        },
        last_host_error = "",
        last_http_status = "",
    }
end

function M.worker_is_host_unreachable(text)
    local value = string.lower(tostring(text or ""))
    return value:find("timed out", 1, true)
        or value:find("timeout", 1, true)
        or value:find("refused", 1, true)
        or value:find("unreachable", 1, true)
        or value:find("failed to connect", 1, true)
        or value:find("could not connect", 1, true)
        or value:find("network is down", 1, true)
        or value:find("no route", 1, true)
        or value:find("name or service not known", 1, true)
        or value:find("not known", 1, true)
        or value:find("host", 1, true) and value:find("resolve", 1, true)
end

function M.worker_log_endpoint_error(endpoint, err_text)
    print(string.format("[token_usage.worker] %s -> %s", endpoint, config.trim_text(err_text, 200)))
end

function M.worker_set_cursor_host_error(worker_state, err_text)
    worker_state.cursor.cursor_running = false
    worker_state.cursor.agent_active = false
    worker_state.cursor.mode = "error"
    worker_state.cursor.hook_status = "red"
    worker_state.cursor.hook_event = "host_error"
    worker_state.cursor.hook_message = config.trim_text(err_text, 96)
    worker_state.cursor.last_cursor_update_ms = config.now_ms()
end

function M.worker_http_get_json(ctx, worker_state, endpoint, max_body_bytes)
    local body_limit = max_body_bytes or 4096
    local url = string.format("http://%s:%d/%s", ctx.host, ctx.port, endpoint)
    local ok, output, err = capability.call("http_request", {
        url = url,
        method = "GET",
        timeout_ms = ctx.http_timeout_ms,
        max_body_bytes = body_limit,
    }, {
        source_cap = "token_usage",
        max_output_bytes = body_limit + 512,
    })

    if not ok then
        local detail = tostring(err or output or "http_request failed")
        if M.worker_is_host_unreachable(detail) then
            return nil, "host unreachable: " .. config.trim_text(detail, 120), "host_unreachable"
        end
        return nil, "request failed: " .. config.trim_text(detail, 120), "request_failed"
    end

    local text = config.normalize_http_text(output)
    local first_line, body = text:match("^(.-)\n(.*)$")
    if not first_line then
        first_line = text
        body = ""
    end

    local status = tonumber(first_line:match("^HTTP%s+(%d+)"))
    if not status then
        return nil, "invalid http response: " .. config.preview_text(first_line, 120), "bad_response"
    end

    worker_state.last_http_status = "HTTP " .. tostring(status)

    if status ~= 200 then
        local snippet = config.preview_text(body, 160)
        if snippet ~= "" then
            return nil, string.format("non-200 status HTTP %d: %s", status, snippet), "non_200"
        end
        return nil, string.format("non-200 status HTTP %d", status), "non_200"
    end

    if body == "" then
        return nil, "empty body", "empty_body"
    end

    local decode_ok, decoded = pcall(json.decode, body)
    if not decode_ok or type(decoded) ~= "table" then
        local decode_err = decode_ok and "root is not an object" or tostring(decoded)
        return nil,
            "json decode failed: " .. config.preview_text(decode_err, 96) .. " body=" .. config.preview_text(body, 160),
            "json_decode"
    end

    return decoded
end

function M.status_priority(status)
    if status == "red" then
        return 3
    end
    if status == "yellow" then
        return 2
    end
    return 1
end

function M.normalize_cursor_payload(data)
    if type(data) ~= "table" then
        return nil
    end
    if type(data.hook_status) == "string" then
        if type(data.cursor_running) ~= "boolean" and type(data.running) == "boolean" then
            data.cursor_running = data.running
        end
        return data
    end

    local cursor = type(data.cursor_status) == "table" and data.cursor_status or {}
    local codex = type(data.codex_status) == "table" and data.codex_status or {}
    local cursor_prio = M.status_priority(cursor.hook_status or "green")
    local codex_prio = M.status_priority(codex.hook_status or "green")
    local picked = cursor
    local source = "Cursor"

    if codex_prio > cursor_prio
            or (codex_prio == cursor_prio and codex.agent_active and not cursor.agent_active) then
        picked = codex
        source = "Codex"
    end

    return {
        cursor_running = data.cursor_running == true or data.running == true,
        mode = picked.mode or "idle",
        agent_active = cursor.agent_active == true or codex.agent_active == true,
        hook_status = picked.hook_status or "green",
        hook_event = picked.hook_event or "",
        hook_message = picked.hook_message or "",
        source = source,
        ai_model = picked.ai_model or source,
    }
end

function M.apply_cursor_payload(remote, data)
    local normalized = M.normalize_cursor_payload(data)
    if not normalized then
        remote.last_host_error = "cursor-status payload invalid"
        M.worker_log_endpoint_error("/cursor-status", remote.last_host_error)
        return false
    end
    M.worker_apply_cursor_status(remote, normalized)
    return true
end

function M.poll_cursor_status(ctx, remote, poll_times)
    if ctx.host == "" then
        return
    end

    local tick_ms = config.now_ms()
    if tick_ms - poll_times.cursor < ctx.cursor_poll_ms then
        return
    end

    local data, err = M.worker_http_get_json(ctx, remote, "cursor-status", 4096)
    if data then
        M.apply_cursor_payload(remote, data)
    else
        remote.last_host_error = tostring(err)
        M.worker_set_cursor_host_error(remote, remote.last_host_error)
        M.worker_log_endpoint_error("/cursor-status", remote.last_host_error)
    end
    poll_times.cursor = tick_ms
end

function M.poll_background_updates(ctx, remote, poll_times)
    if ctx.host == "" then
        return
    end

    local tick_ms = config.now_ms()

    if tick_ms - poll_times.token >= ctx.token_poll_ms then
        local data, err = M.worker_http_get_json(ctx, remote, "deepseek-balance", 4096)
        if data then
            if not M.worker_apply_balance(remote, data) then
                remote.last_host_error = "deepseek-balance returned no balance"
                M.worker_log_endpoint_error("/deepseek-balance", remote.last_host_error)
            end
        else
            remote.last_host_error = tostring(err)
            remote.token.query_ok = false
            M.worker_log_endpoint_error("/deepseek-balance", remote.last_host_error)
        end
        poll_times.token = tick_ms
        return
    end

    if tick_ms - poll_times.aux >= ctx.aux_poll_ms then
        if not poll_times.aux_account_done then
            local account_data, account_err = M.worker_http_get_json(ctx, remote, "deepseek-account-balance", 2048)
            if type(account_data) == "table" then
                if not M.worker_apply_account(remote, account_data) then
                    M.worker_log_endpoint_error("/deepseek-account-balance", "missing account_balance field")
                end
            elseif account_err then
                M.worker_log_endpoint_error("/deepseek-account-balance", tostring(account_err))
            end
            poll_times.aux_account_done = true
            return
        end

        poll_times.aux = tick_ms
        poll_times.aux_account_done = false
        return
    end

    local weather_interval = remote.weather.query_ok and ctx.weather_poll_ms or ctx.weather_retry_ms
    if tick_ms - poll_times.weather >= weather_interval then
        local data, err = M.worker_http_get_json(ctx, remote, "weather", 4096)
        if data then
            if not M.worker_apply_weather(remote, data) then
                remote.last_host_error = "weather returned incomplete payload"
                M.worker_log_endpoint_error("/weather", remote.last_host_error)
            end
        else
            remote.last_host_error = tostring(err)
            remote.weather.query_ok = false
            M.worker_log_endpoint_error("/weather", remote.last_host_error)
        end
        poll_times.weather = tick_ms
    end
end

function M.reset_poll_schedule(poll_times)
    local tick_ms = config.now_ms()
    poll_times.cursor = tick_ms
    poll_times.token = tick_ms
    poll_times.aux = tick_ms
    poll_times.weather = tick_ms
    poll_times.aux_account_done = false
end

function M.poll_remote_updates(ctx, remote, poll_times)
    M.poll_cursor_status(ctx, remote, poll_times)
    M.poll_background_updates(ctx, remote, poll_times)
end

function M.worker_apply_cursor_status(worker_state, data)
    worker_state.last_host_error = ""

    if type(data.cursor_running) == "boolean" then
        worker_state.cursor.cursor_running = data.cursor_running
    elseif type(data.running) == "boolean" then
        worker_state.cursor.cursor_running = data.running
    end
    if type(data.mode) == "string" and data.mode ~= "" then
        worker_state.cursor.mode = config.trim_text(data.mode, 16)
    end
    if type(data.agent_active) == "boolean" then
        worker_state.cursor.agent_active = data.agent_active
    end
    if type(data.hook_status) == "string" and data.hook_status ~= "" then
        worker_state.cursor.hook_status = config.trim_text(data.hook_status, 16)
    end
    if type(data.hook_event) == "string" then
        worker_state.cursor.hook_event = config.trim_text(data.hook_event, 32)
    end
    if type(data.hook_message) == "string" then
        worker_state.cursor.hook_message = config.trim_text(data.hook_message, 96)
    end
    if type(data.source) == "string" and data.source ~= "" then
        worker_state.cursor.source = config.trim_text(data.source, 16)
    end
    if type(data.ai_model) == "string" then
        worker_state.cursor.ai_model = config.trim_text(data.ai_model, 48)
    end
    worker_state.cursor.last_cursor_update_ms = config.now_ms()

    local balance_str = config.coerce_text(data.deepseek_balance, 16)
    if balance_str then
        worker_state.token.balance_str = balance_str
    end
    if type(data.deepseek_available) == "boolean" then
        worker_state.token.is_available = data.deepseek_available
    end
    if type(data.deepseek_query_ok) == "boolean" then
        worker_state.token.query_ok = data.deepseek_query_ok
    end
    local account_balance = config.coerce_text(data.account_balance, 16)
    if account_balance then
        worker_state.token.account_balance = account_balance
    end
    if worker_state.token.query_ok then
        worker_state.token.last_token_update_ms = config.now_ms()
    end

    local temperature = config.coerce_text(data.temperature, 16)
    if temperature then
        worker_state.weather.temperature = temperature
    end
    if type(data.description) == "string" then
        worker_state.weather.description = config.trim_text(data.description, 32)
    end
    local humidity = config.coerce_text(data.humidity, 16)
    if humidity then
        worker_state.weather.humidity = humidity
    end
    if type(data.weather_location) == "string" and data.weather_location ~= "" then
        worker_state.weather.location = config.trim_text(data.weather_location, 24)
    end
    if type(data.weather_query_ok) == "boolean" then
        worker_state.weather.query_ok = data.weather_query_ok
    end
    if worker_state.weather.query_ok then
        worker_state.weather.last_update_ms = config.now_ms()
    end
end

function M.worker_apply_balance(worker_state, data)
    if type(data.is_available) == "boolean" then
        worker_state.token.is_available = data.is_available
    end

    local list = data.balance_infos
    if type(list) == "table" and type(list[1]) == "table" then
        local total_balance = config.coerce_text(list[1].total_balance, 16)
        if total_balance and total_balance ~= "" then
            worker_state.token.balance_str = total_balance
            worker_state.token.query_ok = true
            worker_state.token.last_token_update_ms = config.now_ms()
            worker_state.last_host_error = ""
            return true
        end
    end

    worker_state.token.query_ok = false
    return false
end

function M.worker_apply_account(worker_state, data)
    local account_balance = config.coerce_text(data.account_balance, 16)
    if account_balance and account_balance ~= "" then
        worker_state.token.account_balance = account_balance
        return true
    end
    return false
end

function M.worker_apply_weather(worker_state, data)
    if type(data) ~= "table" then
        return false
    end

    local payload = data
    if type(data.weather) == "table" then
        local nested = data.weather
        payload = {
            location = nested.location or data.location,
            weather_location = nested.location or data.weather_location,
            temperature = nested.temperature or data.temperature,
            description = nested.description or data.description,
            humidity = nested.humidity or data.humidity,
            query_ok = nested.query_ok ~= nil and nested.query_ok or data.query_ok,
            weather_query_ok = nested.query_ok ~= nil and nested.query_ok or data.weather_query_ok,
        }
    end

    local updated = false

    if type(payload.location) == "string" and payload.location ~= "" then
        worker_state.weather.location = config.trim_text(payload.location, 24)
        updated = true
    elseif type(payload.weather_location) == "string" and payload.weather_location ~= "" then
        worker_state.weather.location = config.trim_text(payload.weather_location, 24)
        updated = true
    end

    local query_ok = payload.query_ok == true or payload.weather_query_ok == true
    local temperature = config.coerce_text(payload.temperature, 16)
    local description = type(payload.description) == "string" and config.trim_text(payload.description, 32) or nil
    local humidity = config.coerce_text(payload.humidity, 16)

    if query_ok and temperature and description and humidity
            and temperature ~= "--" and description ~= "--" and humidity ~= "--" then
        worker_state.weather.temperature = temperature
        worker_state.weather.description = description
        worker_state.weather.humidity = humidity
        worker_state.weather.query_ok = true
        worker_state.weather.last_update_ms = config.now_ms()
        worker_state.last_host_error = ""
        return true
    end

    worker_state.weather.query_ok = false
    return updated
end

return M
