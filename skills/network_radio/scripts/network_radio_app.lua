local board_manager = require("board_manager")
local lvgl = require("lvgl")
local common = require("radio_common")
local thread = require("thread")

local TAG = "[network_radio_app]"
local WAIT_MS = 20000
local EVENT_POLL_MS = 100
local STATUS_REFRESH_MS = 1000
local WAVE_REFRESH_MS = 140
local CLOCK_REFRESH_MS = 1000
local RADIO_FONT_PATH = "fonts/fusion-pixel-12px.ttf"
local DEFAULT_VOLUME = common.DEFAULT_VOLUME
local APP_BG = "#07111F"
local CARD_BG = "#0F1E33"
local CARD_ALT_BG = "#152A45"
local ACCENT = "#38BDF8"
local TEXT = "#F8FAFC"
local MUTED = "#B6C7DA"
local TRACK = "#1E3A5F"
local LABEL_H = 20

local STATION_META = {
    ["崂山921"] = { display = "Laoshan 921", freq = "92.1 MHz", track = "Morning Coast" },
    ["长沙101.7城市之声"] = { display = "Changsha City FM", freq = "101.7 MHz", track = "City Voice" },
    ["上海经典947"] = { display = "Classic Shanghai", freq = "94.7 MHz", track = "Golden Melody" },
    ["湖北经典音乐广播"] = { display = "Hubei Classic", freq = "96.6 MHz", track = "Classic Flow" },
    ["成都年代音乐怀旧好声音"] = { display = "Chengdu Classics", freq = "88.7 MHz", track = "Retro Night" },
    ["山东经典音乐广播"] = { display = "Shandong Classic", freq = "97.5 MHz", track = "Old Time Radio" },
    ["杭州90.7"] = { display = "Hangzhou Radio", freq = "90.7 MHz", track = "Smooth Jazz Night" },
    ["天津TIKI 100.5"] = { display = "Tianjin TIKI", freq = "100.5 MHz", track = "Sax Flow" },
}

local state = {
    volume = DEFAULT_VOLUME,
    title = "",
    url = "",
    status = "idle",
    volume_dirty = false,
    selected_index = 1,
    play_started_ms = nil,
}

local ui = {
    label_text = {},
    wave_bars = {},
    screen = nil,
    station_overlay = nil,
    radio_font = nil,
    radio_list_font = nil,
}

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$") or ""
end

local function set_cached_text(key, obj, text)
    text = tostring(text or "")
    if obj and ui.label_text[key] ~= text then
        obj:set_text(text)
        ui.label_text[key] = text
    end
end

local function clock_text()
    local ok, value = pcall(os.date, "%H:%M")
    if ok and type(value) == "string" and value ~= "" then
        return value
    end
    return "--:--"
end

local function load_radio_fonts()
    local ok, font_or_err = pcall(lvgl.font_load, RADIO_FONT_PATH, {
        size = 22,
        cache_size = 96,
    })
    if ok then
        ui.radio_font = font_or_err
    else
        print(TAG .. " WARN: failed to load radio font: " .. tostring(font_or_err))
    end

    ok, font_or_err = pcall(lvgl.font_load, RADIO_FONT_PATH, {
        size = 18,
        cache_size = 128,
    })
    if ok then
        ui.radio_list_font = font_or_err
    else
        print(TAG .. " WARN: failed to load radio list font: " .. tostring(font_or_err))
    end
end

local function current_script_dir()
    local info = debug.getinfo(1, "S")
    local source = info and info.source or ""
    if source:sub(1, 1) == "@" then
        source = source:sub(2)
    end
    return source:match("^(.*)/[^/]+$")
end

local function daemon_path()
    local dir = current_script_dir()
    if not dir then
        error("failed to resolve network radio script dir")
    end
    return dir .. "/radio_player_daemon.lua"
end

local function daemon_job_exists()
    local ok, output = thread.get(common.DAEMON_JOB_NAME)
    if ok then
        return output:find("status=running", 1, true) ~= nil or output:find("status=queued", 1, true) ~= nil
    end
    return false
end

local function start_daemon_if_needed()
    if daemon_job_exists() then
        return
    end

    local ok, err = thread.start(daemon_path(), {
        codec_name = common.DEFAULT_CODEC_NAME,
    }, {
        name = common.DAEMON_JOB_NAME,
        exclusive = common.DAEMON_EXCLUSIVE,
        replace = false,
        timeout_ms = 0,
    })
    if not ok then
        local text = tostring(err)
        local existing_daemon_conflict = text:find("ESP_ERR_INVALID_STATE", 1, true)
            or text:find("Conflict with", 1, true)
            or text:find("exclusive", 1, true)
        if existing_daemon_conflict and daemon_job_exists() then
            return
        end
        if text:find("already", 1, true) or text:find("running", 1, true) then
            return
        end
        error("failed to start network radio daemon: " .. text)
    end
end

local function station_display(title)
    title = trim(title)
    if title == "" then
        return "--"
    end
    return title
end

local function station_meta(title)
    title = trim(title)
    local meta = STATION_META[title]
    if meta then
        return {
            display = title,
            freq = meta.freq,
            track = meta.track,
        }
    end
    return {
        display = station_display(title),
        freq = "-- MHz",
        track = "直播电台",
    }
end

local function station_index(title, url)
    title = trim(title)
    url = trim(url)
    for index, station in ipairs(common.STATIONS) do
        if (title ~= "" and station.title == title) or (url ~= "" and station.url == url) then
            return index
        end
    end
    return state.selected_index or 1
end

local function status_text(status)
    if not status then
        return "Status: not running"
    end
    local text = tostring(status.state or "unknown")
    local command_status = tostring(status.command_status or "")
    if command_status ~= "" then
        text = text .. " / " .. command_status
    end
    if status.error and status.error ~= "" then
        text = text .. " / " .. tostring(status.error)
    end
    return "Status: " .. text
end

local function same_station(title, url)
    title = trim(title)
    url = trim(url)
    return (title ~= "" and title == trim(state.title))
        or (url ~= "" and url == trim(state.url))
end

local function set_message(text)
    set_cached_text("message", ui.message, text)
    print(TAG .. " " .. tostring(text or ""))
end

local function update_now_playing(now_ms)
    local meta = station_meta(state.title)
    local display_title = meta.display
    local frequency = meta.freq
    local playing = state.status == "playing"

    if not playing and trim(state.title) == "" then
        local station = common.STATIONS[state.selected_index or 1]
        if station then
            meta = station_meta(station.title)
            display_title = meta.display
            frequency = meta.freq
        end
    end

    set_cached_text("station", ui.station, display_title)
    set_cached_text("frequency", ui.frequency, frequency)
    set_cached_text("play_button", ui.play_button, playing and "STOP" or "PLAY")
end

local function apply_status(status)
    if type(status) ~= "table" then
        return
    end

    local prev_status = state.status
    local prev_title = state.title
    local prev_url = state.url
    local now_ms = common.now_ms()

    state.status = tostring(status.state or state.status or "idle")
    state.title = tostring(status.title or state.title or "")
    state.url = tostring(status.url or state.url or "")
    state.volume = common.clamp_volume(status.volume) or state.volume or DEFAULT_VOLUME
    state.selected_index = station_index(state.title, state.url)

    if state.status == "playing" then
        if prev_status ~= "playing" or prev_title ~= state.title or prev_url ~= state.url then
            state.play_started_ms = tonumber(status.updated_at_ms) or now_ms
        end
    else
        state.play_started_ms = nil
    end

    update_now_playing(now_ms)
    set_cached_text("status", ui.status, status_text(status))
    if ui.volume_label then
        set_cached_text("volume", ui.volume_label, tostring(state.volume) .. "%")
    end
    if ui.slider and not state.volume_dirty and ui.slider:get_value() ~= state.volume then
        ui.slider:set_value(state.volume)
    end
end

local function read_status()
    local status = common.read_json(common.status_path())
    if status and (status.state == "playing" or status.state == "idle" or status.state == "ended") and not daemon_job_exists() then
        status.state = "stopped"
        status.command_status = "stale_status_repaired"
        status.updated_at_ms = common.now_ms()
        common.write_json(common.status_path(), status)
    end
    return status
end

local function wait_status(command_id)
    local deadline = common.now_ms() + WAIT_MS
    while common.now_ms() < deadline do
        local remaining = deadline - common.now_ms()
        local wait_ms = remaining > common.QUEUE_RECV_MS and common.QUEUE_RECV_MS or remaining
        local status = common.recv_reply(wait_ms)
        if status and status.command_id == command_id then
            return status
        end
    end
    error("network radio command timed out")
end

local function send_control(action, opts)
    opts = opts or {}
    common.ensure_control_dir()
    common.ensure_queues()

    if action ~= "status" then
        start_daemon_if_needed()
    end

    common.lock_control(WAIT_MS)
    local ok, result = xpcall(function()
        local command_id = common.new_command_id()
        local command = {
            command_id = command_id,
            action = action,
            station = opts.station or "",
            url = opts.url or "",
            title = opts.title or "",
            codec_name = common.DEFAULT_CODEC_NAME,
            created_at_ms = common.now_ms(),
        }
        if opts.volume ~= nil then
            command.volume = common.clamp_volume(opts.volume)
        end

        local sent, send_err = common.send_command(command, common.QUEUE_SEND_MS)
        if not sent then
            error("failed to send network radio command: " .. tostring(send_err))
        end

        local status = wait_status(command_id)
        if status.command_status == "error" then
            error(tostring(status.error or "network radio command failed"))
        end
        return status
    end, debug.traceback)
    common.unlock_control()

    if not ok then
        error(result)
    end
    return result
end

local function run_command(action, opts, pending_text)
    if pending_text then
        set_message(pending_text)
    end

    local ok, result = pcall(send_control, action, opts)
    if ok then
        apply_status(result)
        set_message("Ready")
    else
        local message = tostring(result)
        set_message("Error: " .. message)
        print(TAG .. " ERROR: " .. message)
    end
end

local function make_label(parent, key, text, color, width, height, bg_color, font)
    local label = lvgl.label(parent, {
        text = text,
        w = width,
        h = height or LABEL_H,
        text_color = color or TEXT,
        bg_color = bg_color or APP_BG,
        bg_opa = 255,
        font = font,
    })
    ui.label_text[key] = text
    return label
end

local function make_center_label(parent, key, text, color, width, height, bg_color, font)
    local box = lvgl.container(parent, {
        w = width,
        h = height or LABEL_H,
        bg_color = bg_color or APP_BG,
        bg_opa = 255,
        border_width = 0,
        pad = 0,
    })
    box:set_flex({ flow = "row", main = "center", cross = "center" })

    local label = lvgl.label(box, {
        text = text,
        h = height or LABEL_H,
        text_color = color or TEXT,
        bg_color = bg_color or APP_BG,
        bg_opa = 255,
        font = font,
    })
    ui.label_text[key] = text
    return label
end

local function switch_to_station(index)
    local station_count = #common.STATIONS
    if station_count <= 0 then
        set_message("No station configured")
        return
    end

    if index < 1 then
        index = station_count
    elseif index > station_count then
        index = 1
    end
    state.selected_index = index

    local station = common.STATIONS[index]
    local volume = ui.slider and ui.slider:get_value() or state.volume or DEFAULT_VOLUME
    local resolved_title, resolved_url = common.resolve_station(station.title, "", "")

    if state.status == "playing" and same_station(resolved_title, resolved_url) then
        if volume ~= state.volume then
            run_command("volume", {
                volume = volume,
            }, "Setting volume...")
        else
            set_message("Ready")
            update_now_playing(common.now_ms())
        end
        return
    end

    run_command("switch", {
        station = station.title,
        volume = volume,
    }, "Switching to " .. station_display(station.title) .. "...")
end

local function toggle_playback()
    if state.status == "playing" then
        run_command("stop", {}, "Stopping...")
        return
    end
    switch_to_station(state.selected_index or 1)
end

local function make_round_button(parent, text, size, bg_color)
    return lvgl.button(parent, {
        text = text,
        w = size,
        h = size,
        radius = math.floor(size / 2),
        bg_color = bg_color or CARD_ALT_BG,
        text_color = "#ffffff",
    })
end

local function make_menu_button(parent, size)
    local btn = lvgl.button(parent, {
        w = size,
        h = size,
        radius = math.floor(size / 2),
        bg_color = CARD_ALT_BG,
        text_color = "#ffffff",
        pad = 0,
        pad_row = 0,
    })

    local line_w = math.floor(size * 0.44)
    local line_h = math.max(2, math.floor(size * 0.06))
    local line_gap = math.max(4, math.floor(size * 0.16))
    for _, y in ipairs({ -line_gap, 0, line_gap }) do
        lvgl.container(btn, {
            align = "center",
            x = 0,
            y = y,
            w = line_w,
            h = line_h,
            bg_color = "#ffffff",
            bg_opa = 255,
            border_width = 0,
            radius = line_h,
            pad = 0,
        })
    end

    return btn
end

local function make_wave_panel(parent, width, height, compact)
    local panel = lvgl.container(parent, {
        w = width,
        h = height,
        bg_color = CARD_BG,
        bg_opa = 170,
        border_color = "#1E5A89",
        border_width = 1,
        radius = 18,
        pad = compact and 8 or 14,
        pad_column = compact and 4 or 8,
    })
    panel:set_flex({ flow = "row", main = "center", cross = "center" })

    ui.wave_bars = {}
    local bar_count = compact and 16 or 22
    local bar_w = compact and 5 or 8
    local max_h = height - (compact and 20 or 34)

    for index = 1, bar_count do
        local bar = lvgl.container(panel, {
            w = bar_w,
            h = compact and 16 or 28,
            bg_color = ACCENT,
            bg_opa = 235,
            border_width = 0,
            radius = math.floor(bar_w / 2),
            pad = 0,
        })
        ui.wave_bars[index] = {
            obj = bar,
            w = bar_w,
            max_h = max_h,
        }
    end

    return panel
end

local function update_wave(now_ms)
    if not ui.wave_bars then
        return
    end

    local playing = state.status == "playing"
    local phase = math.floor((now_ms or common.now_ms()) / WAVE_REFRESH_MS)

    for index, item in ipairs(ui.wave_bars) do
        local value
        if playing then
            value = 18 + ((phase * 11 + index * 17 + (index % 5) * 13) % 76)
        else
            value = 10 + (index % 4) * 4
        end

        local h = math.max(6, math.floor(item.max_h * value / 100))
        item.obj:set_size(item.w, h)
    end
end

local function close_station_list()
    if ui.station_overlay then
        ui.station_overlay:delete()
        ui.station_overlay = nil
    end
end

local function open_station_list(width, height, compact)
    if ui.station_overlay or not ui.screen then
        return
    end

    ui.station_overlay = lvgl.container(ui.screen, {
        w = width,
        h = height,
        bg_color = "#000000",
        bg_opa = 150,
        border_width = 0,
        pad = 0,
    })

    local drawer_h = math.floor(height * (compact and 0.72 or 0.68))
    local drawer_w = width - (compact and 20 or 36)
    local row_h = compact and 42 or 52
    local drawer = lvgl.container(ui.station_overlay, {
        align = "bottom_mid",
        w = drawer_w,
        h = drawer_h,
        bg_color = CARD_BG,
        bg_opa = 245,
        border_color = "#1E5A89",
        border_width = 1,
        radius = 18,
        pad = compact and 10 or 14,
        pad_row = compact and 6 or 8,
    })
    drawer:set_flex({ flow = "column", main = "start", cross = "center" })
    drawer:set_scroll({ dir = "none", scrollbar = "off" })

    local header = lvgl.container(drawer, {
        w = drawer_w - (compact and 22 or 30),
        h = compact and 34 or 40,
        bg_color = CARD_BG,
        bg_opa = 255,
        border_width = 0,
        pad = 0,
    })
    header:set_flex({ flow = "row", main = "space_between", cross = "center" })
    make_label(header, "radio_list_title", "Radio List", TEXT, drawer_w - 92, compact and 28 or 32, CARD_BG)
    local close_btn = lvgl.button(header, {
        text = "X",
        w = compact and 34 or 40,
        h = compact and 30 or 34,
        radius = 16,
        bg_color = CARD_ALT_BG,
        text_color = "#ffffff",
    })
    close_btn:on("clicked", close_station_list)

    local list_body = lvgl.container(drawer, {
        w = drawer_w - (compact and 22 or 30),
        h = drawer_h - (compact and 58 or 70),
        bg_color = CARD_BG,
        bg_opa = 255,
        border_width = 0,
        pad = 0,
        pad_row = compact and 6 or 8,
    })
    list_body:set_flex({ flow = "column", main = "start", cross = "center" })
    list_body:set_scroll({ dir = "ver", scrollbar = "auto" })

    for index, station in ipairs(common.STATIONS) do
        local selected = index == (state.selected_index or 1)
        local row = lvgl.button(list_body, {
            text = (selected and "*  " or "   ") .. station_display(station.title),
            w = drawer_w - (compact and 22 or 30),
            h = row_h,
            radius = 12,
            bg_color = selected and "#123A5A" or CARD_ALT_BG,
            text_color = selected and ACCENT or TEXT,
            font = ui.radio_list_font,
        })
        row:on("clicked", function()
            close_station_list()
            switch_to_station(index)
        end)
    end
end

local function build_ui(width, height)
    local scr = lvgl.create_screen()
    ui.screen = scr
    scr:set_style({ bg_color = APP_BG })

    local compact = height < 360
    local status_h = compact and 18 or 24
    local body_h = height - status_h - 24
    local content_w = width - 24
    local main_w = content_w
    local button_size = compact and 32 or 44
    local controls_w = math.min(main_w - 32, compact and 220 or 280)
    local volume_w = math.max(controls_w - button_size - 18, 140)
    local wave_h = math.max(compact and 82 or 150, body_h - (compact and 152 or 236))

    local root = lvgl.container(scr, {
        w = width,
        h = height,
        bg_color = APP_BG,
        bg_opa = 255,
        border_width = 0,
        pad = 8,
        pad_row = compact and 2 or 6,
    })
    root:set_flex({ flow = "column", main = "start", cross = "center" })
    root:set_scroll({ dir = "none", scrollbar = "off" })

    local status_bar = lvgl.container(root, {
        w = content_w,
        h = status_h,
        bg_opa = 0,
        border_width = 0,
        pad = 0,
    })
    status_bar:set_flex({ flow = "row", main = "space_between", cross = "center" })
    ui.clock = make_label(status_bar, "clock", clock_text(), MUTED, 72, compact and 14 or 18)
    make_label(status_bar, "wifi", "WiFi", MUTED, 72, compact and 14 or 18)

    local main = lvgl.container(root, {
        w = content_w,
        h = body_h,
        bg_opa = 0,
        border_width = 0,
        pad = 0,
        pad_row = compact and 3 or 8,
    })
    main:set_flex({ flow = "column", main = "center", cross = "center" })

    ui.station = make_center_label(main, "station", "杭州90.7", TEXT, main_w, compact and 24 or 32, APP_BG, ui.radio_font)
    ui.frequency = make_center_label(main, "frequency", "90.7 MHz", ACCENT, main_w, compact and 16 or 22)

    make_wave_panel(main, main_w, wave_h, compact)

    ui.message = make_center_label(main, "message", "Ready", "#BAE6FD", main_w, compact and 18 or 24, APP_BG, ui.radio_font)

    local controls = lvgl.container(main, {
        w = controls_w,
        h = button_size + (compact and 6 or 10),
        bg_opa = 0,
        border_width = 0,
        pad = 0,
        pad_column = compact and 10 or 16,
    })
    controls:set_flex({ flow = "row", main = "center", cross = "center" })
    local prev_btn = make_round_button(controls, "<<", button_size, CARD_ALT_BG)
    ui.play_button = make_round_button(controls, "PLAY", button_size + 10, ACCENT)
    local next_btn = make_round_button(controls, ">>", button_size, CARD_ALT_BG)
    local list_btn = make_menu_button(controls, button_size)

    prev_btn:on("clicked", function()
        switch_to_station((state.selected_index or 1) - 1)
    end)
    ui.play_button:on("clicked", toggle_playback)
    next_btn:on("clicked", function()
        switch_to_station((state.selected_index or 1) + 1)
    end)
    list_btn:on("clicked", function()
        open_station_list(width, height, compact)
    end)

    local volume_panel = lvgl.container(main, {
        w = controls_w,
        h = compact and 42 or 54,
        bg_color = APP_BG,
        bg_opa = 255,
        border_width = 0,
        pad = 0,
        pad_row = compact and 2 or 4,
    })
    volume_panel:set_flex({ flow = "column", main = "center", cross = "center" })
    ui.slider = lvgl.slider(volume_panel, {
        w = volume_w,
        h = compact and 6 or 8,
        min = common.MIN_VOLUME,
        max = common.MAX_VOLUME,
        value = state.volume,
        bg_color = ACCENT,
        line_color = ACCENT,
    })
    ui.volume_label = make_center_label(volume_panel, "volume", tostring(state.volume) .. "%", TEXT, 64, compact and 14 or 18, APP_BG)
    ui.slider:on("value_changed", function()
        local volume = ui.slider:get_value()
        state.volume = volume
        state.volume_dirty = true
        set_cached_text("volume", ui.volume_label, tostring(volume) .. "%")
    end)
    ui.slider:on("released", function()
        state.volume_dirty = false
        run_command("volume", {
            volume = ui.slider:get_value(),
        }, "Setting volume...")
    end)

    update_wave(common.now_ms())
    scr:load()
end

local function run()
    common.ensure_control_dir()
    common.ensure_queues()

    local panel_handle, io_handle, width, height, panel_if =
        board_manager.get_display_lcd_params("display_lcd")
    if not panel_handle then
        error("get_display_lcd_params(display_lcd) failed: " .. tostring(io_handle))
    end

    lvgl.init(panel_handle, io_handle, width, height, panel_if, {
        buffer_lines = 10,
        tick_ms = 5,
        task_period_ms = 10,
    })
    load_radio_fonts()

    local touch_handle, touch_err = board_manager.get_lcd_touch_handle("lcd_touch")
    if touch_handle then
        local ok, err = pcall(lvgl.indev_register, "touch", touch_handle)
        if not ok then
            print(TAG .. " WARN: touch register failed: " .. tostring(err))
        end
    else
        print(TAG .. " WARN: no touch handle: " .. tostring(touch_err))
    end

    build_ui(width, height)
    apply_status(read_status() or {
        state = "stopped",
        title = "",
        volume = DEFAULT_VOLUME,
        command_status = "ready",
    })

    local next_status_ms = common.now_ms() + STATUS_REFRESH_MS
    local next_wave_ms = common.now_ms() + WAVE_REFRESH_MS
    local next_clock_ms = common.now_ms() + CLOCK_REFRESH_MS
    while true do
        lvgl.process_events(EVENT_POLL_MS)
        local now = common.now_ms()
        if now >= next_clock_ms then
            set_cached_text("clock", ui.clock, clock_text())
            next_clock_ms = now + CLOCK_REFRESH_MS
        end
        if now >= next_wave_ms then
            update_wave(now)
            next_wave_ms = now + WAVE_REFRESH_MS
        end
        if now >= next_status_ms then
            local status = read_status()
            if status then
                apply_status(status)
            end
            next_status_ms = now + STATUS_REFRESH_MS
        end
    end
end

local ok, err = xpcall(run, debug.traceback)
pcall(lvgl.indev_unregister, "touch")
pcall(lvgl.deinit)
if not ok then
    print(TAG .. " ERROR: " .. tostring(err))
    error(err)
end
