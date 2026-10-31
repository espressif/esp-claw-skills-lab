local lvgl = require("lvgl")
local system = require("system")

local a = type(args) == "table" and args or {}
local function option(name, default) return a[name] == nil and default or a[name] end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function integer(v, default) return math.floor(tonumber(v) or default) end
local C = {
    bg = "#f3f5f1", surface = "#ffffff", surface_2 = "#e9eeea", line = "#d3dad4", text = "#202622", muted = "#737c76",
    accent = "#278f7f", accent_dim = "#d6ece7", live = "#278f7f", danger = "#d65f62", warm = "#ad792d", off = "#a1aaa3",
}
local owned, ir_device

local function run()
    lvgl.init({buffer_lines = 40, tick_ms = 5, task_period_ms = 10})
    owned = true
    local screen = lvgl.create_screen()
    local w, h = screen:get_size()
    assert(w >= 240 and h >= 240, "Infrared Remote requires at least 240x240 pixels")
    local scale, side = math.min(w, h) / 480, math.min(w, h)
    local ox, oy = (w - side) // 2, (h - side) // 2
    local function p(v) return math.max(1, math.floor(v * scale + 0.5)) end
    local function pos(v) return math.floor(v * scale + 0.5) end
    local fonts = {
        small = lvgl.font_load({size = clamp(p(11), 9, 16), cache_size = 64}),
        body = lvgl.font_load({size = clamp(p(15), 11, 22), cache_size = 96}),
        title = lvgl.font_load({size = clamp(p(21), 14, 30), cache_size = 96}),
        temp = lvgl.font_load({size = clamp(p(58), 34, 68), cache_size = 48}),
    }
    lvgl.set_default_font(fonts.body)
    screen:set_style({bg_color = C.bg, pad = 0, border_width = 0})
    screen:clear_flag("SCROLLABLE")
    local root = lvgl.object(screen, {x = ox, y = oy, w = side, h = side, bg_color = C.bg, pad = 0, border_width = 0, radius = 0})
    root:clear_flag("SCROLLABLE")

    -- Hardware modules are optional in the browser simulator.
    local ir_ok, ir = pcall(require, "ir")
    local hardware_defaults = {
        tx_gpio = option("tx_gpio", 39), rx_gpio = option("rx_gpio", 38), ctrl_gpio = option("ctrl_gpio", 44),
        ctrl_active_level = option("ctrl_active_level", 0), carrier_hz = option("carrier_hz", 38000),
    }
    local data = {next_id = 1, devices = {}, hardware = {}}
    local store_path, storage, json
    do
        local storage_ok, storage_module = pcall(require, "storage")
        local json_ok, json_module = pcall(require, "json")
        if storage_ok and json_ok then
            storage, json = storage_module, json_module
            local dir = storage.join_path(storage.get_root_dir(), "app_data")
            if not storage.exists(dir) then
                local ok, err = pcall(storage.mkdir, dir)
                if not ok then print("[infrared_remote] Data directory error: " .. tostring(err)) end
            end
            store_path = storage.join_path(dir, "infrared_remote.json")
            local legacy_path = storage.join_path(dir, "airwave_remote.json")
            local load_path = storage.exists(store_path) and store_path or legacy_path
            if storage.exists(load_path) then
                local ok, saved = pcall(function() return json.decode(storage.read_file(load_path)) end)
                if ok and type(saved) == "table" then
                    if type(saved.devices) == "table" then
                        data.devices, data.next_id = saved.devices, tonumber(saved.next_id) or 1
                        if type(saved.hardware) == "table" then data.hardware = saved.hardware end
                    else
                        local legacy = {{"tv", "Television", saved.tv}, {"ac", "Air conditioner", saved.ac}, {"media", "Media player", saved.media}, {"custom", "Custom remote", saved.custom}}
                        for _, item in ipairs(legacy) do
                            if type(item[3]) == "table" and next(item[3]) then
                                data.devices[#data.devices + 1] = {id = data.next_id, kind = item[1], name = item[2], keys = item[3]}
                                data.next_id = data.next_id + 1
                            end
                        end
                    end
                else print("[infrared_remote] Saved data ignored: " .. tostring(saved)) end
            end
        end
    end
    for key, value in pairs(hardware_defaults) do data.hardware[key] = tonumber(data.hardware[key]) or value end
    data.hardware.tx_gpio = clamp(math.floor(data.hardware.tx_gpio), 0, 48)
    data.hardware.rx_gpio = clamp(math.floor(data.hardware.rx_gpio), -1, 48)
    data.hardware.ctrl_gpio = clamp(math.floor(data.hardware.ctrl_gpio), -1, 48)
    data.hardware.ctrl_active_level = clamp(math.floor(data.hardware.ctrl_active_level), 0, 1)
    data.hardware.carrier_hz = clamp(math.floor(data.hardware.carrier_hz), 30000, 60000)
    local function open_ir(config)
        if ir_device then
            local ok, err = pcall(ir_device.close, ir_device)
            if not ok then print("[infrared_remote] IR close failed: " .. tostring(err)) end
            ir_device = nil
        end
        if not ir_ok then return false, "IR module unavailable" end
        local ok, result = pcall(ir.new, config)
        if ok then ir_device = result; return true end
        print("[infrared_remote] IR open failed: " .. tostring(result))
        return false, tostring(result)
    end
    open_ir(data.hardware)
    local function save_data()
        if not store_path then return false end
        local ok, result = pcall(storage.write_file, store_path, json.encode(data))
        if not ok or not result then print("[infrared_remote] Save failed: " .. tostring(result)) end
        return ok and result
    end

    local function plain(obj) obj:clear_flag("SCROLLABLE"); return obj end
    local function button(parent, text, x, y, bw, bh, radius, font)
        local flat_radius = bw == bh and radius or math.min(radius, 14)
        local obj = plain(lvgl.object(parent, {x = pos(x), y = pos(y), w = p(bw), h = p(bh), radius = p(flat_radius), pad = 0,
            border_width = 1, border_color = C.line, bg_color = C.surface_2}))
        obj:add_flag("CLICKABLE")
        local label = plain(lvgl.label(obj, {text = text, align = "center", text_color = C.text, font = font or fonts.body}))
        local control = {}
        function control:on(event, callback) return obj:on(event, callback) end
        function control:set_style(style)
            obj:set_style(style)
            if style.text_color then label:set_style({text_color = style.text_color}) end
            return true
        end
        function control:set_text(value) label:set_text(value); label:align("center", 0, 0); return true end
        function control:set_pos(px, py) return obj:set_pos(px, py) end
        function control:add_flag(flag) return obj:add_flag(flag) end
        function control:clear_flag(flag) return obj:clear_flag(flag) end
        function control:get_object() return obj end
        return control
    end
    local function panel(parent, x, y, pw, ph, radius)
        local flat_radius = pw == ph and radius or math.min(radius, 14)
        return plain(lvgl.object(parent, {x = pos(x), y = pos(y), w = p(pw), h = p(ph), radius = p(flat_radius), pad = 0,
            border_width = 1, border_color = C.line, bg_color = C.surface}))
    end
    local function style_button(obj, selected, enabled)
        obj:set_style({bg_color = selected and C.accent_dim or C.surface_2, border_color = selected and C.accent or C.line,
            border_width = 1, text_color = enabled == false and C.off or selected and C.accent or C.text})
    end

    local running, current, page = true, nil, "home"
    local status_deadline, delete_deadline, learn_mode, show_page
    local back = button(root, "<", 14, 12, 40, 40, 20, fonts.title)
    local title = plain(lvgl.label(root, {text = "My devices", x = pos(66), y = pos(15), text_color = C.text, font = fonts.title}))
    local action = button(root, "+", 422, 12, 44, 40, 20, fonts.title)
    local settings_action = button(root, "PINS", 352, 12, 60, 40, 14, fonts.small)
    local delete_action = button(root, "DEL", 414, 12, 52, 40, 14, fonts.small)
    back:set_style({bg_color = C.bg}); action:set_style({bg_color = C.bg}); settings_action:set_style({bg_color = C.bg}); delete_action:set_style({bg_color = C.bg, text_color = C.danger})
    local badge = panel(root, 326, 17, 78, 30, 15)
    local badge_text = plain(lvgl.label(badge, {text = ir_device and "IR LIVE" or "DEMO", align = "center", text_color = ir_device and C.live or C.muted, font = fonts.small}))
    badge:add_flag("HIDDEN")
    local status = plain(lvgl.label(root, {text = "Add a remote to get started", align = "top_mid", y = pos(62), text_color = C.muted, font = fonts.small}))
    local views = {}
    for _, name in ipairs({"home", "settings", "add", "ac", "tv", "media", "custom"}) do
        views[name] = plain(lvgl.object(root, {x = 0, y = pos(82), w = side, h = p(398), bg_opa = 0, pad = 0, border_width = 0}))
        views[name]:add_flag("HIDDEN")
    end

    local function set_status(text, color, duration)
        status:set_text(text); status:set_style({text_color = color or C.muted}); status:align("top_mid", 0, pos(62))
        status_deadline = duration == 0 and nil or system.millis() + (duration or 1800)
    end
    local function learned_count(device) local n = 0; for _ in pairs(device.keys or {}) do n = n + 1 end; return n end
    local function default_status()
        if page == "home" then
            local n = #data.devices
            return n == 0 and "Add a remote to get started" or string.format("%d remote%s · choose one to control", n, n == 1 and "" or "s")
        elseif page == "settings" then return "Configure infrared hardware pins"
        elseif page == "add" then return "Choose a device type and protocol"
        elseif current then return current.name .. " · tap to send · hold to learn" end
        return "Ready"
    end

    local protocol_cache = {}
    local function get_protocol(name)
        if not ir_device or not ir_ok then return nil end
        if protocol_cache[name] then return protocol_cache[name] end
        local ok, result = pcall(ir.protocol, name)
        if ok then protocol_cache[name] = result; return result end
        print("[infrared_remote] Protocol error: " .. tostring(result)); return nil
    end
    local function send_frame(frame, label)
        if not ir_device then set_status("Demo · " .. label, C.muted); return true end
        local ok, err = pcall(ir_device.send, ir_device, frame)
        if ok then set_status(label .. " sent", C.live, 900)
        else print("[infrared_remote] Send failed: " .. tostring(err)); set_status("Send failed", C.danger) end
        return ok
    end
    local function learn_key(key, label)
        if not current then return end
        if not ir_device then set_status("IR receiver unavailable in demo", C.danger); return end
        set_status("Point remote here · press " .. label, C.warm, 6000); lvgl.process_events(0)
        local ok, frame, reason = pcall(function() local f, why = ir_device:receive(5000); return f, why end)
        if ok and frame then
            current.keys = current.keys or {}; current.keys[key] = frame:to_table(); save_data(); set_status(label .. " learned and saved", C.live)
        else print("[infrared_remote] Learn failed: " .. tostring(ok and reason or frame)); set_status(ok and "Learning timed out" or "Learning failed", C.danger) end
    end
    local function send_key(key, label)
        if not current then return end
        if learn_mode then learn_mode = false; learn_key(key, label); return end
        local saved = current.keys and current.keys[key]
        if saved and ir_ok then
            local ok, frame = pcall(ir.frame, saved)
            if ok then send_frame(frame, label) else print("[infrared_remote] Saved frame invalid: " .. tostring(frame)); set_status("Saved key is invalid", C.danger) end
            return
        end
        local codes = option(current.kind .. "_codes", {})
        local command = type(codes) == "table" and codes[key]
        local protocol = get_protocol(current.protocol or option("consumer_protocol", "nec"))
        if command and protocol then
            local command_data = {command = integer(command, 0), repeat_count = 0}
            if current.protocol ~= "bose.wave" then command_data.address = integer(current.address or option("consumer_address", 0), 0) end
            local ok, frame = pcall(protocol.encode, protocol, command_data)
            if ok then send_frame(frame, label) else print("[infrared_remote] Encode failed: " .. tostring(frame)); set_status("Command code invalid", C.danger) end
        else set_status("Hold " .. label .. " to learn", C.warm) end
    end
    local key_widgets = {ac = {}, tv = {}, media = {}, custom = {}}
    local function bind_key(parent, key, label, x, y, bw, bh, radius, font, display)
        local obj = button(parent, display or label, x, y, bw, bh, radius, font)
        for kind, view in pairs(views) do if view == parent and key_widgets[kind] then key_widgets[kind][key] = obj end end
        obj:on("clicked", function() send_key(key, label); if current and current.keys and current.keys[key] then obj:set_style({bg_color = C.accent_dim}) end end)
        obj:on("long_pressed", function() learn_key(key, label); if current and current.keys and current.keys[key] then obj:set_style({bg_color = C.accent_dim}) end end)
        return obj
    end
    local function bind_arrow(parent, key, label, x, y, direction)
        local tall = direction == "left" or direction == "right"
        local obj = bind_key(parent, key, label, x, y, 60, tall and 56 or 52, 22, fonts.title, "")
        local shapes = {
            up = {x = 18, y = 18, points = {{x = 0, y = 10}, {x = 12, y = 0}, {x = 24, y = 10}}},
            down = {x = 18, y = 18, points = {{x = 0, y = 0}, {x = 12, y = 10}, {x = 24, y = 0}}},
            left = {x = 24, y = 16, points = {{x = 10, y = 0}, {x = 0, y = 12}, {x = 10, y = 24}}},
            right = {x = 24, y = 16, points = {{x = 0, y = 0}, {x = 10, y = 12}, {x = 0, y = 24}}},
        }
        local shape = shapes[direction]
        local points = {}
        for i, point in ipairs(shape.points) do points[i] = {x = pos(point.x), y = pos(point.y)} end
        lvgl.line(obj:get_object(), {x = pos(shape.x), y = pos(shape.y), points = points, line_color = C.text, line_width = p(3)})
        return obj
    end

    local home = views.home
    local empty_panel = panel(home, 24, 42, 432, 220, 28)
    plain(lvgl.label(empty_panel, {text = "NO REMOTES YET", align = "top_mid", y = pos(48), text_color = C.muted, font = fonts.small}))
    plain(lvgl.label(empty_panel, {text = "Build a remote for each device", align = "top_mid", y = pos(88), text_color = C.text, font = fonts.body}))
    local empty_add = button(empty_panel, "ADD FIRST DEVICE", 96, 138, 240, 58, 20, fonts.small)
    local device_cards = {}
    for i = 1, 6 do
        local col, row = (i - 1) % 2, (i - 1) // 2
        local card = button(home, "", 20 + col * 226, 14 + row * 108, 214, 94, 22, fonts.body)
        card:add_flag("HIDDEN")
        card:on("clicked", function() local selected = data.devices[i]; if selected then current = selected; show_page(selected.kind) end end)
        device_cards[i] = card
    end
    local add_card = button(home, "+  ADD DEVICE", 20, 14, 214, 94, 22, fonts.small)

    local add = views.add
    plain(lvgl.label(add, {text = "DEVICE TYPE", x = pos(22), y = pos(8), text_color = C.muted, font = fonts.small}))
    local type_defs = {
        {kind = "tv", label = "TV", detail = "Navigation · volume"}, {kind = "ac", label = "AIR", detail = "Temperature · mode"},
        {kind = "media", label = "MEDIA", detail = "Playback · audio"}, {kind = "custom", label = "CUSTOM", detail = "Learn every key"},
    }
    local draft_kind, draft_protocol = "tv", option("consumer_protocol", "nec")
    local type_buttons = {}
    for i, item in ipairs(type_defs) do
        local col, row = (i - 1) % 2, (i - 1) // 2
        type_buttons[i] = button(add, item.label .. "\n" .. item.detail, 20 + col * 226, 32 + row * 86, 214, 74, 20, fonts.small)
    end
    plain(lvgl.label(add, {text = "CONTROL METHOD", x = pos(22), y = pos(215), text_color = C.muted, font = fonts.small}))
    local protocol_button = button(add, "", 20, 238, 440, 56, 18, fonts.small)
    local create_button = button(add, "CREATE REMOTE", 92, 314, 296, 58, 22, fonts.body)
    create_button:set_style({bg_color = C.accent, border_color = C.accent, text_color = C.bg})
    local ac_protocols = {"gree.capture_v1", "midea.capture_v1", "haier.a6_capture_v1", "lg.akb73315611"}
    local consumer_protocols = {"nec", "nec.extended", "samsung32", "sony12", "sony15", "sony20", "rc5", "jvc", "bose.wave"}
    local function protocol_list() return draft_kind == "ac" and ac_protocols or consumer_protocols end
    local function refresh_add()
        for i, obj in ipairs(type_buttons) do style_button(obj, type_defs[i].kind == draft_kind, true) end
        protocol_button:set_text(draft_kind == "custom" and "LEARN FROM ORIGINAL REMOTE" or "PROTOCOL  ·  " .. string.upper(draft_protocol) .. "  >")
        style_button(protocol_button, false, draft_kind ~= "custom")
    end
    for i, obj in ipairs(type_buttons) do
        obj:on("clicked", function()
            draft_kind = type_defs[i].kind
            draft_protocol = draft_kind == "ac" and option("ac_protocol", "gree.capture_v1") or option("consumer_protocol", "nec")
            refresh_add()
        end)
    end
    protocol_button:on("clicked", function()
        if draft_kind == "custom" then return end
        local list, index = protocol_list(), 1
        for i, name in ipairs(list) do if name == draft_protocol then index = i end end
        draft_protocol = list[index % #list + 1]; refresh_add()
    end)

    local ac = views.ac
    local ac_dial = panel(ac, 165, 10, 150, 150, 75)
    local ac_temp = plain(lvgl.label(ac_dial, {text = "24", align = "center", text_color = C.text, font = fonts.temp}))
    plain(lvgl.object(ac_dial, {x = pos(103), y = pos(46), w = p(9), h = p(9), radius = p(5), bg_opa = 0, border_width = p(2), border_color = C.text, pad = 0}))
    plain(lvgl.label(ac_dial, {text = "C", x = pos(114), y = pos(50), text_color = C.text, font = fonts.body}))
    local ac_minus = button(ac, "-", 58, 48, 64, 64, 32, fonts.title)
    local ac_plus = button(ac, "+", 358, 48, 64, 64, 32, fonts.title)
    local ac_modes, ac_fans = {"AUTO", "COOL", "DRY", "HEAT", "FAN"}, {"AUTO", "LOW", "MID", "HIGH"}
    local ac_mode_buttons, ac_fan_buttons = {}, {}
    panel(ac, 20, 180, 440, 58, 18); panel(ac, 20, 252, 440, 46, 15)
    for i, name in ipairs(ac_modes) do ac_mode_buttons[i] = button(ac, name, 24 + (i - 1) * 86.4, 184, 87, 50, 15, fonts.small) end
    for i, name in ipairs(ac_fans) do ac_fan_buttons[i] = button(ac, name, 24 + (i - 1) * 108, 256, 108, 38, 12, fonts.small) end
    local ac_swing = bind_key(ac, "swing", "SWING", 28, 320, 116, 52, 18, fonts.small)
    local ac_power = button(ac, "POWER", 176, 320, 128, 52, 20, fonts.body)
    local ac_learn = button(ac, "LEARN", 336, 320, 116, 52, 18, fonts.small)
    local function ac_state()
        current.state = current.state or {power = true, temperature = 24, mode = "COOL", fan = "AUTO"}
        current.state.temperature = clamp(integer(current.state.temperature, 24), 16, 30)
        return current.state
    end
    local function update_ac()
        if not current or current.kind ~= "ac" then return end
        local state = ac_state()
        ac_temp:set_text(tostring(state.temperature)); ac_temp:align("center", -pos(10), 0)
        for i, obj in ipairs(ac_mode_buttons) do style_button(obj, state.mode == ac_modes[i], state.power) end
        for i, obj in ipairs(ac_fan_buttons) do style_button(obj, state.fan == ac_fans[i], state.power) end
        style_button(ac_minus, false, state.power); style_button(ac_plus, false, state.power); style_button(ac_swing, current.keys and current.keys.swing ~= nil, true)
        ac_power:set_style({bg_color = state.power and C.accent_dim or C.surface_2, border_color = state.power and C.accent or C.line,
            text_color = state.power and C.accent or C.text})
    end
    local function send_ac()
        local state, protocol = ac_state(), get_protocol(current.protocol or option("ac_protocol", "gree.capture_v1")); save_data()
        if not ir_device or not protocol then set_status("Demo · Air state updated", C.muted); return end
        local fan = state.fan:lower() == "mid" and "medium" or state.fan:lower()
        local ok, frame = pcall(protocol.encode, protocol, {power = state.power, mode = state.mode:lower(), temperature = state.temperature, fan = fan})
        if ok then send_frame(frame, "Air state") else print("[infrared_remote] AC encode failed: " .. tostring(frame)); set_status("Air state unsupported", C.danger) end
    end
    ac_minus:on("clicked", function() local s = ac_state(); if s.power then s.temperature = clamp(s.temperature - 1, 16, 30); update_ac(); send_ac() end end)
    ac_plus:on("clicked", function() local s = ac_state(); if s.power then s.temperature = clamp(s.temperature + 1, 16, 30); update_ac(); send_ac() end end)
    for i, obj in ipairs(ac_mode_buttons) do obj:on("clicked", function() local s = ac_state(); if s.power then s.mode = ac_modes[i]; update_ac(); send_ac() end end) end
    for i, obj in ipairs(ac_fan_buttons) do obj:on("clicked", function() local s = ac_state(); if s.power then s.fan = ac_fans[i]; update_ac(); send_ac() end end) end
    ac_power:on("clicked", function() local s = ac_state(); s.power = not s.power; update_ac(); send_ac() end)
    ac_learn:on("clicked", function() learn_mode = true; set_status("Learn mode · tap SWING", C.warm, 6000) end)

    local tv = views.tv
    panel(tv, 150, 38, 180, 180, 90)
    bind_arrow(tv, "up", "Up", 210, 44, "up"); bind_arrow(tv, "left", "Left", 152, 100, "left")
    local tv_ok = bind_key(tv, "ok", "OK", 216, 104, 48, 48, 24, fonts.body); tv_ok:set_style({bg_color = C.accent_dim, border_color = C.accent, text_color = C.accent})
    bind_arrow(tv, "right", "Right", 268, 100, "right"); bind_arrow(tv, "down", "Down", 210, 160, "down")
    bind_key(tv, "vol_up", "+", 22, 46, 76, 52, 18, fonts.title); bind_key(tv, "vol_down", "-", 22, 158, 76, 52, 18, fonts.title)
    plain(lvgl.label(tv, {text = "VOL", x = pos(45), y = pos(121), text_color = C.muted, font = fonts.small}))
    bind_key(tv, "ch_up", "+", 382, 46, 76, 52, 18, fonts.title); bind_key(tv, "ch_down", "-", 382, 158, 76, 52, 18, fonts.title)
    plain(lvgl.label(tv, {text = "CH", x = pos(410), y = pos(121), text_color = C.muted, font = fonts.small}))
    local tv_bottom = {{"power", "POWER"}, {"source", "INPUT"}, {"mute", "MUTE"}}
    for i, item in ipairs(tv_bottom) do bind_key(tv, item[1], item[2], 22 + (i - 1) * 114, 254, 104, 64, 18, fonts.small) end
    local tv_learn = button(tv, "LEARN", 364, 254, 94, 64, 18, fonts.small)
    tv_learn:on("clicked", function() learn_mode = true; set_status("Learn mode · choose a TV key", C.warm, 6000) end)

    local media = views.media
    local media_keys = {
        {"power", "POWER", 22, 30}, {"source", "INPUT", 138, 30}, {"home", "HOME", 254, 30}, {"back", "BACK", 370, 30},
        {"previous", "PREV", 22, 116}, {"play_pause", "PLAY · PAUSE", 138, 116}, {"next", "NEXT", 300, 116},
        {"vol_down", "VOL -", 22, 202}, {"mute", "MUTE", 138, 202}, {"vol_up", "VOL +", 254, 202},
    }
    for _, item in ipairs(media_keys) do bind_key(media, item[1], item[2], item[3], item[4], item[2] == "PLAY · PAUSE" and 150 or 104, 68, 18, fonts.small) end
    local media_learn = button(media, "LEARN A KEY", 138, 294, 204, 56, 18, fonts.small)
    media_learn:on("clicked", function() learn_mode = true; set_status("Learn mode · choose a media key", C.warm, 6000) end)

    local custom = views.custom
    for i = 1, 9 do
        local col, row = (i - 1) % 3, (i - 1) // 3
        bind_key(custom, "key" .. i, string.format("KEY %02d", i), 34 + col * 142, 24 + row * 92, 128, 76, 20, fonts.body)
    end
    plain(lvgl.label(custom, {text = "Hold any key to learn from the original remote", align = "bottom_mid", y = -pos(24), text_color = C.muted, font = fonts.small}))

    local settings = views.settings
    local hardware_draft, setting_values = {}, {}
    local setting_defs = {
        {key = "tx_gpio", label = "IR SEND GPIO", min = 0, max = 48, step = 1},
        {key = "rx_gpio", label = "IR RECEIVE GPIO", min = -1, max = 48, step = 1},
        {key = "ctrl_gpio", label = "ENABLE GPIO", min = -1, max = 48, step = 1},
        {key = "ctrl_active_level", label = "ENABLE LEVEL", min = 0, max = 1, step = 1},
        {key = "carrier_hz", label = "CARRIER", min = 30000, max = 60000, step = 1000},
    }
    local function setting_text(def)
        local value = hardware_draft[def.key]
        if value < 0 then return "OFF" end
        if def.key == "ctrl_active_level" then return value == 0 and "LOW" or "HIGH" end
        if def.key == "carrier_hz" then return string.format("%d kHz", value // 1000) end
        return "GPIO " .. tostring(value)
    end
    local function refresh_settings()
        for i, def in ipairs(setting_defs) do
            setting_values[i]:set_text(setting_text(def)); setting_values[i]:align("right_mid", -pos(128), 0)
        end
    end
    for i, def in ipairs(setting_defs) do
        local row = panel(settings, 20, 2 + (i - 1) * 59, 440, 50, 14)
        plain(lvgl.label(row, {text = def.label, x = pos(16), align = "left_mid", text_color = C.muted, font = fonts.small}))
        setting_values[i] = plain(lvgl.label(row, {text = "", align = "right_mid", text_color = C.text, font = fonts.body}))
        local minus = button(row, "-", 330, 6, 44, 38, 13, fonts.title)
        local plus = button(row, "+", 386, 6, 44, 38, 13, fonts.title)
        minus:on("clicked", function() hardware_draft[def.key] = clamp(hardware_draft[def.key] - def.step, def.min, def.max); refresh_settings() end)
        plus:on("clicked", function() hardware_draft[def.key] = clamp(hardware_draft[def.key] + def.step, def.min, def.max); refresh_settings() end)
    end
    local apply_hardware = button(settings, "APPLY HARDWARE", 92, 310, 296, 58, 20, fonts.body)
    apply_hardware:set_style({bg_color = C.accent, border_color = C.accent, text_color = C.bg})
    apply_hardware:on("clicked", function()
        local tx, rx, ctrl = hardware_draft.tx_gpio, hardware_draft.rx_gpio, hardware_draft.ctrl_gpio
        if (rx >= 0 and tx == rx) or (ctrl >= 0 and (tx == ctrl or rx == ctrl)) then
            set_status("Send, receive and enable GPIO must differ", C.danger); return
        end
        local previous = {}
        for key in pairs(hardware_defaults) do previous[key], data.hardware[key] = data.hardware[key], hardware_draft[key] end
        if not ir_ok then save_data(); set_status("Settings saved · IR module unavailable", C.muted); return end
        protocol_cache = {}
        local ok, reason = open_ir(data.hardware)
        if not ok then
            for key in pairs(hardware_defaults) do data.hardware[key] = previous[key] end
            local restored, restore_reason = open_ir(data.hardware)
            if not restored then print("[infrared_remote] IR restore failed: " .. tostring(restore_reason)) end
            badge_text:set_text(restored and "IR LIVE" or "DEMO"); badge_text:set_style({text_color = restored and C.live or C.muted}); badge_text:align("center", 0, 0)
            set_status("Settings rejected · " .. tostring(reason), C.danger, 3500); return
        end
        save_data()
        badge_text:set_text("IR LIVE"); badge_text:set_style({text_color = C.live}); badge_text:align("center", 0, 0)
        set_status("Hardware settings applied", C.live)
    end)

    local function reset_delete()
        delete_deadline = nil; delete_action:set_text("DEL"); delete_action:set_style({bg_color = C.bg, border_color = C.line, text_color = C.danger})
    end

    show_page = function(name)
        page, learn_mode = name, false; reset_delete()
        for view_name, view in pairs(views) do if view_name == name then view:clear_flag("HIDDEN") else view:add_flag("HIDDEN") end end
        action:add_flag("HIDDEN"); settings_action:add_flag("HIDDEN"); delete_action:add_flag("HIDDEN"); badge:add_flag("HIDDEN")
        if name == "home" then current = nil; title:set_text("My devices"); action:clear_flag("HIDDEN"); settings_action:clear_flag("HIDDEN")
        elseif name == "settings" then title:set_text("IR settings")
        elseif name == "add" then title:set_text("Add device")
        else title:set_text(current and current.name or "Remote"); badge:clear_flag("HIDDEN"); delete_action:clear_flag("HIDDEN") end
        if current and key_widgets[name] then
            for key, obj in pairs(key_widgets[name]) do obj:set_style({bg_color = current.keys and current.keys[key] and C.accent_dim or C.surface_2, text_color = C.text}) end
            if name == "tv" then tv_ok:set_style({bg_color = C.accent_dim, border_color = C.accent, text_color = C.accent}) end
        end
        title:set_pos(pos(66), pos(15)); set_status(default_status(), C.muted, 0)
        if name == "ac" then update_ac() end
    end
    local function refresh_home()
        local n = #data.devices
        if n == 0 then empty_panel:clear_flag("HIDDEN") else empty_panel:add_flag("HIDDEN") end
        for i, card in ipairs(device_cards) do
            local device = data.devices[i]
            if device then
                card:set_text(device.name .. "\n" .. string.upper(device.kind) .. " · " .. learned_count(device) .. " learned")
                card:clear_flag("HIDDEN")
            else card:add_flag("HIDDEN") end
        end
        if n > 0 and n < 6 then
            local col, row = n % 2, n // 2
            add_card:set_pos(pos(20 + col * 226), pos(14 + row * 108)); add_card:clear_flag("HIDDEN")
        else add_card:add_flag("HIDDEN") end
        if page == "home" then set_status(default_status(), C.muted, 0) end
    end
    local function open_add()
        if #data.devices >= 6 then set_status("Device limit reached", C.warm); return end
        draft_kind, draft_protocol = "tv", option("consumer_protocol", "nec"); refresh_add(); show_page("add")
    end
    local function open_settings()
        for key in pairs(hardware_defaults) do hardware_draft[key] = data.hardware[key] end
        refresh_settings(); show_page("settings")
    end
    local function create_device()
        local names = {tv = "TV", ac = "Air", media = "Media", custom = "Custom"}
        local count = 1
        for _, device in ipairs(data.devices) do if device.kind == draft_kind then count = count + 1 end end
        local device = {id = data.next_id, kind = draft_kind, name = names[draft_kind] .. " " .. count, keys = {}}
        if draft_kind ~= "custom" then device.protocol = draft_protocol end
        if draft_kind ~= "ac" and draft_kind ~= "custom" then device.address = option("consumer_address", 0) end
        data.next_id = data.next_id + 1; data.devices[#data.devices + 1] = device; save_data(); refresh_home(); current = device; show_page(device.kind)
    end
    local function delete_current()
        if not current then return end
        local now = system.millis()
        if not delete_deadline or now >= delete_deadline then
            delete_deadline = now + 4000; delete_action:set_text("OK?"); delete_action:set_style({bg_color = "#f8dddd", border_color = C.danger, text_color = C.danger})
            set_status("Tap OK? again to delete " .. current.name, C.danger, 4000); return
        end
        local deleted = current.name
        for i, device in ipairs(data.devices) do if device.id == current.id then table.remove(data.devices, i); break end end
        save_data(); refresh_home(); show_page("home"); set_status(deleted .. " deleted", C.live)
    end
    empty_add:on("clicked", open_add); add_card:on("clicked", open_add); action:on("clicked", open_add); settings_action:on("clicked", open_settings); delete_action:on("clicked", delete_current); create_button:on("clicked", create_device)
    back:on("clicked", function() if page == "home" then running = false else refresh_home(); show_page("home") end end)
    refresh_add(); refresh_home(); show_page("home")

    screen:load()
    print(string.format("[infrared_remote] ready: %d devices / %s", #data.devices, ir_device and "IR online" or "demo mode"))
    local started = system.millis()
    while running do
        lvgl.process_events(50)
        if status_deadline and system.millis() >= status_deadline then set_status(default_status(), C.muted, 0) end
        if delete_deadline and system.millis() >= delete_deadline then reset_delete() end
        if option("run_ms", 0) > 0 and system.millis() - started >= option("run_ms", 0) then break end
    end
end

local ok, err = xpcall(run, debug.traceback)
local stopped = not ok and tostring(err):find("stop requested", 1, true)
-- Release GPIO and LVGL ownership on every exit path.
if ir_device then
    local closed, close_err = pcall(ir_device.close, ir_device)
    if not closed then print("[infrared_remote] IR close failed: " .. tostring(close_err)) end
end
if owned then
    local closed, close_err = pcall(lvgl.deinit)
    if not closed then print("[infrared_remote] LVGL cleanup failed: " .. tostring(close_err)) end
end
if not ok and not stopped then print("[infrared_remote] ERROR: " .. tostring(err)); error(err) end
