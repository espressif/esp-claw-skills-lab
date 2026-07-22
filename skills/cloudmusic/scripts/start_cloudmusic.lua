local board_manager = require("board_manager")
local delay = require("delay")
local json = require("json")
local lcd_touch = require("lcd_touch")
local lvgl = require("lvgl")
local storage = require("storage")
local system = require("system")
local thread = require("thread")

local DEFAULT_PORT = 8766
local CONFIG_DIR = "CloudMusic"
local CONFIG_FILE = "config.json"
local CACHE_DIR = "cache"

local LOOP_MS = 20
local ROT_STEP_MS = 40
local ROT_PERIOD_MS = 24000
local TOUCH_DEBOUNCE_MS = 280
local SIDE_TOUCH_POLL_MS = 120
local SIDE_TOUCH_DEBOUNCE_MS = 220
local CMD_QUEUE_DEPTH = 4
local CMD_QUEUE_ITEM_SIZE = 128
local EVT_QUEUE_DEPTH = 4
local EVT_QUEUE_ITEM_SIZE = 512

local VINYL_BORDER_PX = 5
local VINYL_ARM_POINTS = 6
local VINYL_ARM_ANIM_MS = 900
local VINYL_ARM_PIVOT_X_PCT = 5
local VINYL_ARM_PIVOT_Y_PCT = 85
local VINYL_ARM_HEAD_PLAY_X_PCT = 12
local VINYL_ARM_HEAD_PLAY_Y_PCT = 50
local VINYL_ARM_HEAD_PAUSE_X_PCT = -5

local SIDE_TOUCH_LEFT_MASK = 1 << 0
local SIDE_TOUCH_RIGHT_MASK = (1 << 1) | (1 << 2)

local raw_args = type(args) == "table" and args or {}
local side_prev_mask = tonumber(raw_args.side_prev_mask) or SIDE_TOUCH_LEFT_MASK
local side_next_mask = tonumber(raw_args.side_next_mask) or SIDE_TOUCH_RIGHT_MASK
if raw_args.side_touch_swap == true then
    side_prev_mask, side_next_mask = side_next_mask, side_prev_mask
end

local cfg = nil
local paths = {}
local touch_handle = nil
local side = nil
local worker_job_name = nil
local worker_cmd_queue = nil
local worker_evt_queue = nil
local ui = {}
local cover_slots = {
    current = {},
    prev = {},
    next = {},
}

local last_track_id = ""
local last_cover_id = ""
local last_rot_ms = 0
local last_touch_ms = 0
local last_side_poll_ms = 0

local function now_ms()
    return system.millis()
end

local function valid_ipv4(ip)
    local a, b, c, d = string.match(ip or "", "^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
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

local function ensure_dir(path)
    if not storage.exists(path) then
        storage.mkdir(path)
    end
end

local function init_paths()
    local root = storage.get_root_dir()
    paths.base = storage.join_path(root, CONFIG_DIR)
    paths.cache = storage.join_path(paths.base, CACHE_DIR)
    paths.config = storage.join_path(paths.base, CONFIG_FILE)
    ensure_dir(paths.base)
    ensure_dir(paths.cache)
end

local function current_script_dir()
    if type(debug) ~= "table" or type(debug.getinfo) ~= "function" then
        error("CloudMusic worker_path is required when debug.getinfo is unavailable")
    end
    local source = debug.getinfo(1, "S").source or ""
    local path = string.match(source, "^@(.+)$") or source
    return string.match(path, "^(.*)/[^/]+$") or "."
end

local function init_worker_queues()
    local suffix = tostring(now_ms() % 1000000)
    worker_cmd_queue = "cm_cmd_" .. suffix
    worker_evt_queue = "cm_evt_" .. suffix

    local ok, err = thread.sync.queue_create(worker_cmd_queue, {
        depth = CMD_QUEUE_DEPTH,
        item_size = CMD_QUEUE_ITEM_SIZE,
    })
    if not ok then
        error("CloudMusic command queue create failed: " .. tostring(err))
    end

    ok, err = thread.sync.queue_create(worker_evt_queue, {
        depth = EVT_QUEUE_DEPTH,
        item_size = EVT_QUEUE_ITEM_SIZE,
    })
    if not ok then
        pcall(function()
            thread.sync.queue_delete(worker_cmd_queue)
        end)
        error("CloudMusic event queue create failed: " .. tostring(err))
    end
end

local function queue_command(command)
    if not worker_cmd_queue then
        return false
    end
    local ok, payload = pcall(json.encode, command)
    if not ok then
        return false
    end
    local sent = thread.sync.queue_send(worker_cmd_queue, payload, 20)
    return sent == true
end

local function save_config(next_cfg)
    storage.write_file(paths.config, json.encode(next_cfg))
end

local function load_config()
    local next_cfg = {
        port = DEFAULT_PORT,
    }

    if storage.exists(paths.config) then
        local ok, parsed = pcall(function()
            return json.decode(storage.read_file(paths.config))
        end)
        if ok and type(parsed) == "table" then
            next_cfg.host_ip = parsed.host_ip
            next_cfg.port = tonumber(parsed.port) or DEFAULT_PORT
        end
    end

    if type(raw_args.host_ip) == "string" and raw_args.host_ip ~= "" then
        next_cfg.host_ip = raw_args.host_ip
    end
    if raw_args.port ~= nil then
        next_cfg.port = tonumber(raw_args.port) or next_cfg.port
    end

    if not valid_ipv4(next_cfg.host_ip) then
        error("CloudMusic host IP is not configured. Ask the user for the Windows PC LAN IPv4 address, then run configure_host.lua.")
    end
    if next_cfg.port < 1 or next_cfg.port > 65535 then
        error("CloudMusic port must be in 1..65535")
    end

    next_cfg.port = math.floor(next_cfg.port)
    save_config(next_cfg)
    return next_cfg
end

local function rgb565(r, g, b)
    return ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3)
end

local function pack_rgb565_be(value)
    return string.pack(">I2", value & 0xFFFF)
end

local function pack_argb8888(r, g, b, alpha)
    return string.char(b & 0xFF, g & 0xFF, r & 0xFF, alpha & 0xFF)
end

local function isqrt(n)
    if n <= 0 then
        return 0
    end
    local lo = 0
    local hi = math.min(n, 512)
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if mid * mid <= n then
            lo = mid
        else
            hi = mid - 1
        end
    end
    return lo
end

local function paint_disc_base(size, label_r)
    local cx = math.floor(size / 2)
    local cy = math.floor(size / 2)
    local disc_r = math.floor(size / 2) - 1
    local disc_r2 = disc_r * disc_r
    local label_r2 = label_r * label_r
    local border_inner = disc_r - VINYL_BORDER_PX
    local border_inner2 = border_inner > 0 and border_inner * border_inner or 0
    local black = rgb565(0, 0, 0)
    local vinyl0 = rgb565(10, 10, 10)
    local vinyl1 = rgb565(22, 22, 22)
    local vinyl2 = rgb565(36, 36, 36)
    local rim = rgb565(52, 52, 52)
    local out = {}
    local i = 1

    for y = 0, size - 1 do
        for x = 0, size - 1 do
            local dx = x - cx
            local dy = y - cy
            local d2 = dx * dx + dy * dy
            local c = black

            if d2 <= disc_r2 and d2 <= border_inner2 then
                local hi = border_inner - 2
                if hi > 0 and d2 > hi * hi then
                    c = rim
                elseif d2 <= label_r2 then
                    c = black
                else
                    local phase = (disc_r - isqrt(d2)) % 3
                    c = phase == 0 and vinyl2 or (phase == 1 and vinyl1 or vinyl0)
                end
            end
            out[i] = pack_rgb565_be(c)
            i = i + 1
        end
    end

    return table.concat(out)
end

local function paint_disc_overlay(size, hole_r)
    local cx = math.floor(size / 2)
    local cy = math.floor(size / 2)
    local disc_r = math.floor(size / 2) - 1
    local disc_r2 = disc_r * disc_r
    local hole_r2 = hole_r * hole_r
    local border_inner = disc_r - VINYL_BORDER_PX
    local border_inner2 = border_inner > 0 and border_inner * border_inner or 0
    local transparent = pack_argb8888(0, 0, 0, 0)
    local vinyl0 = pack_argb8888(10, 10, 10, 255)
    local vinyl1 = pack_argb8888(22, 22, 22, 255)
    local vinyl2 = pack_argb8888(36, 36, 36, 255)
    local rim = pack_argb8888(52, 52, 52, 255)
    local out = {}
    local i = 1

    for y = 0, size - 1 do
        for x = 0, size - 1 do
            local dx = x - cx
            local dy = y - cy
            local d2 = dx * dx + dy * dy

            if d2 <= hole_r2 or d2 > disc_r2 or d2 > border_inner2 then
                out[i] = transparent
            elseif d2 > (border_inner - 2) * (border_inner - 2) then
                out[i] = rim
            else
                local phase = (disc_r - isqrt(d2)) % 3
                out[i] = phase == 0 and vinyl2 or (phase == 1 and vinyl1 or vinyl0)
            end
            i = i + 1
        end
    end

    return table.concat(out)
end

local function style_clean(obj)
    obj:set_style({
        bg_opa = 0,
        border_width = 0,
        pad = 0,
    })
end

local function create_box(parent, opts)
    local obj = lvgl.object(parent, opts)
    style_clean(obj)
    if type(opts) == "table" then
        obj:set_style(opts)
    end
    return obj
end

local function arm_angle_to_tip(tip_x, tip_y, tip_lx, tip_ly)
    local tip_dir = math.deg(math.atan(tip_y - ui.arm_pivot_y, tip_x - ui.arm_pivot_x))
    local local_dir = math.deg(math.atan(tip_ly, tip_lx))
    local angle = tip_dir - local_dir
    while angle < 0 do
        angle = angle + 360
    end
    while angle >= 360 do
        angle = angle - 360
    end
    return angle
end

local function build_arm_poses()
    local disc_left = ui.disc_cx - math.floor(ui.disc_size / 2)
    local disc_top = ui.disc_cy - math.floor(ui.disc_size / 2)
    local local_x = { 0, 26, 52, 82, 108, 122 }
    local local_y = { 0, 2, 5, 10, 16, 20 }

    ui.arm_pivot_x = disc_left + math.floor((ui.disc_size * VINYL_ARM_PIVOT_X_PCT) / 100)
    ui.arm_pivot_y = disc_top + math.floor((ui.disc_size * VINYL_ARM_PIVOT_Y_PCT) / 100)

    local head_play_x = disc_left + math.floor((ui.disc_size * VINYL_ARM_HEAD_PLAY_X_PCT) / 100)
    local head_play_y = disc_top + math.floor((ui.disc_size * VINYL_ARM_HEAD_PLAY_Y_PCT) / 100)
    local head_pause_x = disc_left + math.floor((ui.disc_size * VINYL_ARM_HEAD_PAUSE_X_PCT) / 100)
    local dx_play = head_play_x - ui.arm_pivot_x
    local dy_play = head_play_y - ui.arm_pivot_y
    local need_len = isqrt(dx_play * dx_play + dy_play * dy_play)
    local dx_pause = head_pause_x - ui.arm_pivot_x
    local dy_pause_sq = need_len * need_len - dx_pause * dx_pause
    local head_pause_y = ui.arm_pivot_y - isqrt(math.max(dy_pause_sq, 0))
    local tip_lx = local_x[VINYL_ARM_POINTS]
    local tip_ly = local_y[VINYL_ARM_POINTS]
    local local_len = isqrt(tip_lx * tip_lx + tip_ly * tip_ly)

    ui.arm_scaled_x = {}
    ui.arm_scaled_y = {}
    for i = 1, VINYL_ARM_POINTS do
        ui.arm_scaled_x[i] = math.floor((local_x[i] * need_len) / local_len)
        ui.arm_scaled_y[i] = math.floor((local_y[i] * need_len) / local_len)
    end

    ui.arm_angle_play_deg = arm_angle_to_tip(head_play_x, head_play_y, ui.arm_scaled_x[VINYL_ARM_POINTS], ui.arm_scaled_y[VINYL_ARM_POINTS])
    ui.arm_angle_pause_deg = arm_angle_to_tip(head_pause_x, head_pause_y, ui.arm_scaled_x[VINYL_ARM_POINTS], ui.arm_scaled_y[VINYL_ARM_POINTS])
end

local function arm_points_for_pose(t)
    t = math.max(0, math.min(1000, t))
    local a0 = ui.arm_angle_pause_deg
    local a1 = ui.arm_angle_play_deg
    local d = a1 - a0
    if d > 180 then
        d = d - 360
    elseif d < -180 then
        d = d + 360
    end
    local angle = a0 + (d * t) / 1000
    local rad = math.rad(angle)
    local c = math.cos(rad)
    local s = math.sin(rad)
    local pts = {}

    for i = 1, VINYL_ARM_POINTS do
        local lx = ui.arm_scaled_x[i]
        local ly = ui.arm_scaled_y[i]
        pts[i] = {
            x = math.floor(ui.arm_pivot_x + lx * c - ly * s + 0.5),
            y = math.floor(ui.arm_pivot_y + lx * s + ly * c + 0.5),
        }
    end
    return pts
end

local function delete_obj(obj)
    if obj then
        pcall(function()
            obj:delete()
        end)
    end
end

local create_pause_bar
local set_pause_visible

local function draw_arm()
    local pts = arm_points_for_pose(ui.arm_pose)
    if ui.arm_line then
        ui.arm_line:set_points(pts)
    else
        ui.arm_line = lvgl.line(ui.screen, {
            x = 0,
            y = 0,
            w = ui.panel_w,
            h = ui.panel_h,
            points = pts,
            line_width = 3,
            line_color = "#ffffff",
        })
    end

    if not ui.arm_pivot then
        ui.arm_pivot = create_box(ui.screen, {
            x = ui.arm_pivot_x - 7,
            y = ui.arm_pivot_y - 7,
            w = 14,
            h = 14,
            radius = 999,
            bg_color = "#ffffff",
            bg_opa = 255,
        })
        create_box(ui.arm_pivot, {
            align = "center",
            w = 4,
            h = 4,
            radius = 999,
            bg_color = "#555555",
            bg_opa = 255,
        })
    end

    local head = pts[VINYL_ARM_POINTS]
    if ui.arm_head then
        ui.arm_head:set_pos(head.x - 5, head.y - 8)
    else
        ui.arm_head = create_box(ui.screen, {
            x = head.x - 5,
            y = head.y - 8,
            w = 10,
            h = 16,
            radius = 2,
            bg_color = "#ffffff",
            bg_opa = 255,
        })
    end
end

function set_pause_visible(visible)
    local opa = visible and 255 or 0
    ui.pause_visible = visible
    if ui.pause_a then
        ui.pause_a:set_style({ bg_opa = opa })
    end
    if ui.pause_b then
        ui.pause_b:set_style({ bg_opa = opa })
    end
end

function create_pause_bar(x_off)
    return create_box(ui.screen, {
        align = "center",
        x = x_off,
        y = 0,
        w = 10,
        h = 34,
        radius = 2,
        bg_color = "#ffffff",
        bg_opa = 255,
    })
end

local function init_ui()
    board_manager.init_device("display_lcd")
    board_manager.init_device("lcd_touch")

    local panel, io, width, height, panel_if = board_manager.get_display_lcd_params("display_lcd")
    if not panel then
        error("display_lcd not available")
    end

    local initialized, owned_by_current_state = lvgl.is_initialized()
    if initialized and not owned_by_current_state then
        error("lvgl runtime is already owned by another Lua script")
    end
    if not initialized then
        lvgl.init(panel, io, width, height, panel_if, {
            buffer_lines = 20,
            tick_ms = 5,
            task_period_ms = 10,
        })
        ui.lvgl_owned = true
    else
        ui.lvgl_owned = false
    end

    ui.panel_w = width
    ui.panel_h = height
    ui.disc_size = math.min(width, height)
    ui.cover_size = 148
    if ui.cover_size > ui.disc_size - 2 * (VINYL_BORDER_PX + 28) then
        ui.cover_size = ui.disc_size - 2 * (VINYL_BORDER_PX + 28)
        if (ui.cover_size % 2) ~= 0 then
            ui.cover_size = ui.cover_size - 1
        end
    end
    ui.disc_cx = math.floor(width / 2)
    ui.disc_cy = math.floor(height / 2)
    ui.playing = false
    ui.angle_x10 = 0
    ui.arm_pose = 0
    ui.arm_target = 0

    ui.screen = lvgl.create_screen()
    ui.screen:set_style({
        bg_color = "#000000",
        bg_opa = 255,
        pad = 0,
        border_width = 0,
    })

    ui.disc_img = lvgl.image(ui.screen, {
        align = "center",
        w = ui.disc_size,
        h = ui.disc_size,
    })
    ui.disc_img:set_raw_rgb565(ui.disc_size, ui.disc_size,
        paint_disc_base(ui.disc_size, math.floor(ui.cover_size / 2)),
        { swapped = true })

    ui.cover_img = lvgl.image(ui.screen, {
        x = ui.disc_cx - math.floor(ui.cover_size / 2),
        y = ui.disc_cy - math.floor(ui.cover_size / 2),
        w = ui.cover_size,
        h = ui.cover_size,
    })
    ui.cover_img:set_raw_rgb565(ui.cover_size, ui.cover_size,
        string.rep("\0", ui.cover_size * ui.cover_size * 2),
        { swapped = true, circle_mask = true })
    ui.cover_img:set_pivot(math.floor(ui.cover_size / 2), math.floor(ui.cover_size / 2))

    ui.disc_overlay_img = lvgl.image(ui.screen, {
        align = "center",
        w = ui.disc_size,
        h = ui.disc_size,
    })
    ui.disc_overlay_img:set_raw_argb8888(ui.disc_size, ui.disc_size,
        paint_disc_overlay(ui.disc_size, math.floor(ui.cover_size / 2)))

    build_arm_poses()
    draw_arm()

    ui.pause_a = create_pause_bar(-8)
    ui.pause_b = create_pause_bar(8)
    set_pause_visible(true)

    ui.screen:load()
    touch_handle = board_manager.get_lcd_touch_handle("lcd_touch")
    if touch_handle then
        pcall(function()
            lcd_touch.sync(touch_handle)
        end)
    end
end

local function refresh_cover()
    local slot = cover_slots.current
    if not slot.valid or not slot.path or not storage.exists(slot.path) then
        return
    end
    if ui.last_cover_id == slot.cover_id and ui.last_track_id == slot.track_id then
        return
    end

    local ok, err = pcall(function()
        ui.cover_img:set_jpeg_file(slot.path, {
            width = ui.cover_size,
            height = ui.cover_size,
            circle_mask = true,
        })
        ui.cover_img:set_pivot(math.floor(ui.cover_size / 2), math.floor(ui.cover_size / 2))
        ui.cover_img:set_rotation(math.floor(ui.angle_x10))
        ui.last_cover_id = slot.cover_id
        ui.last_track_id = slot.track_id
    end)

    if not ok then
        print("[CloudMusic] refresh cover failed: " .. tostring(err))
    end
end

local function set_playing(playing)
    playing = playing == true
    if ui.playing == playing then
        return
    end
    ui.playing = playing
    ui.arm_target = playing and 1000 or 0
    set_pause_visible(not playing)
end

local function update_arm(dt_ms)
    if ui.arm_pose == ui.arm_target then
        return
    end
    local dir = ui.arm_target > ui.arm_pose and 1 or -1
    local step = math.max(1, math.floor((dt_ms * 1000) / VINYL_ARM_ANIM_MS))
    local next_pose = ui.arm_pose + dir * step

    if dir > 0 then
        next_pose = math.min(next_pose, ui.arm_target)
    else
        next_pose = math.max(next_pose, ui.arm_target)
    end
    if next_pose ~= ui.arm_pose then
        ui.arm_pose = next_pose
        draw_arm()
    end
end

local function update_rotation(dt_ms)
    if not ui.playing or not ui.cover_img then
        return
    end
    ui.angle_x10 = (ui.angle_x10 + (dt_ms * 3600) / ROT_PERIOD_MS) % 3600
    ui.cover_img:set_rotation(math.floor(ui.angle_x10 + 0.5))
end

local function request_fast_poll()
    queue_command({ type = "fast_poll" })
end

local function apply_worker_state(np)
    if type(np) ~= "table" then
        return
    end

    set_playing(np.playing == true)
    if type(np.track_id) == "string" and np.track_id ~= "" and np.track_id ~= last_track_id then
        last_track_id = np.track_id
        last_cover_id = type(np.cover_id) == "string" and np.cover_id or ""
    end
end

local function apply_worker_cover(event)
    if type(event.path) ~= "string" or event.path == "" then
        return
    end
    if not storage.exists(event.path) then
        return
    end

    cover_slots.current = {
        valid = true,
        path = event.path,
        cover_id = event.cover_id or "",
        track_id = event.track_id or "",
    }
    refresh_cover()
end

local function process_worker_event(event)
    if type(event) ~= "table" then
        return
    end

    if event.type == "state" then
        apply_worker_state(event)
    elseif event.type == "cover" then
        apply_worker_cover(event)
    elseif event.type == "status" then
        if event.ready == true then
            print("[CloudMusic] Windows host ready")
        else
            print("[CloudMusic] waiting for Windows host /health")
        end
    elseif event.type == "error" then
        print("[CloudMusic] worker error: " .. tostring(event.message))
    end
end

local function process_worker_events()
    if not worker_evt_queue then
        return
    end

    while true do
        local payload = thread.sync.queue_recv(worker_evt_queue, 0)
        if not payload then
            return
        end
        local ok, event = pcall(function()
            return json.decode(payload)
        end)
        if ok then
            process_worker_event(event)
        end
    end
end

local function start_worker()
    local worker_path = raw_args.worker_path
    if type(worker_path) ~= "string" or worker_path == "" then
        worker_path = storage.join_path(current_script_dir(), "cloudmusic_worker.lua")
    end
    worker_job_name = "cloudmusic_worker"
    local ok, output = thread.start(worker_path, {
        cfg = cfg,
        paths = paths,
        cmd_queue = worker_cmd_queue,
        evt_queue = worker_evt_queue,
    }, {
        timeout_ms = 0,
        name = worker_job_name,
        exclusive = worker_job_name,
        replace = true,
    })

    if not ok then
        error("CloudMusic worker start failed: " .. tostring(output))
    end
end

local function handle_screen_touch()
    if not touch_handle then
        return
    end

    local ok, touch = pcall(function()
        return lcd_touch.poll(touch_handle)
    end)
    if not ok or type(touch) ~= "table" then
        return
    end
    if not touch.just_pressed then
        return
    end

    local now = now_ms()
    if now - last_touch_ms < TOUCH_DEBOUNCE_MS then
        return
    end
    last_touch_ms = now
    print(string.format("[CloudMusic] screen touch (%d,%d) -> play_pause", touch.x or 0, touch.y or 0))
    queue_command({ type = "control", action = "play_pause" })
end

local function init_side_touch()
    local ok, result = pcall(function()
        local i2c = require("i2c")
        local si12t_touch = require("lib_si12t_touch")
        local bus = i2c.new(0, 2, 3, 100000)
        local touch = si12t_touch.new({
            bus = bus,
            addr = 0x78,
            threshold = 3,
            channels = { 1, 2, 3 },
        })
        return {
            bus = bus,
            touch = touch,
            last_mask = 0,
            last_prev_ms = 0,
            last_next_ms = 0,
        }
    end)

    if ok then
        side = result
        print(string.format("[CloudMusic] Si12T side touch ready prev_mask=0x%03X next_mask=0x%03X",
            side_prev_mask, side_next_mask))
    else
        side = nil
        print("[CloudMusic] Si12T side touch unavailable: " .. tostring(result))
    end
end

local function accept_side_edge(last_key)
    local now = now_ms()
    if now - side[last_key] < SIDE_TOUCH_DEBOUNCE_MS then
        return false
    end
    side[last_key] = now
    return true
end

local function handle_side_touch()
    if not side then
        return
    end
    local now = now_ms()
    if now - last_side_poll_ms < SIDE_TOUCH_POLL_MS then
        return
    end
    last_side_poll_ms = now

    local ok, mask = pcall(function()
        return side.touch:read()
    end)
    if not ok then
        return
    end

    local rising = mask & (~side.last_mask) & 0x0FFF
    if mask ~= side.last_mask then
        print(string.format("[CloudMusic] side mask=0x%03X rising=0x%03X", mask, rising))
    end

    if (rising & side_next_mask) ~= 0 and accept_side_edge("last_next_ms") then
        print(string.format("[CloudMusic] side NEXT mask=0x%03X rising=0x%03X", mask, rising))
        request_fast_poll()
        queue_command({ type = "control", action = "next" })
    elseif (rising & side_prev_mask) ~= 0 and accept_side_edge("last_prev_ms") then
        print(string.format("[CloudMusic] side PREV mask=0x%03X rising=0x%03X", mask, rising))
        request_fast_poll()
        queue_command({ type = "control", action = "prev" })
    end
    side.last_mask = mask
end

local function cleanup()
    if worker_cmd_queue then
        pcall(function()
            queue_command({ type = "stop" })
        end)
    end
    if worker_job_name then
        pcall(function()
            thread.stop(worker_job_name, 500)
        end)
    end
    if side then
        pcall(function()
            side.touch:close()
        end)
        pcall(function()
            side.bus:close()
        end)
        side = nil
    end
    if worker_cmd_queue then
        pcall(function()
            thread.sync.queue_delete(worker_cmd_queue)
        end)
        worker_cmd_queue = nil
    end
    if worker_evt_queue then
        pcall(function()
            thread.sync.queue_delete(worker_evt_queue)
        end)
        worker_evt_queue = nil
    end
    if ui.lvgl_owned then
        pcall(function()
            lvgl.deinit()
        end)
        ui.lvgl_owned = false
    end
end

local function run()
    init_paths()
    cfg = load_config()
    print(string.format("[CloudMusic] host=%s:%d", cfg.host_ip, cfg.port))

    init_ui()
    init_side_touch()
    init_worker_queues()
    start_worker()

    print("[CloudMusic] UI ready, worker polling host")
    last_rot_ms = now_ms()

    local last_loop = now_ms()
    while true do
        local now = now_ms()
        local dt = math.max(1, now - last_loop)
        last_loop = now

        handle_screen_touch()
        handle_side_touch()
        process_worker_events()

        if now - last_rot_ms >= ROT_STEP_MS then
            local rot_dt = math.max(1, now - last_rot_ms)
            last_rot_ms = now
            update_rotation(rot_dt)
        end

        update_arm(dt)
        lvgl.process_events(0)
        delay.delay_ms(LOOP_MS)
    end
end

local ok, err = xpcall(run, debug.traceback)
cleanup()
if not ok then
    error(err)
end
