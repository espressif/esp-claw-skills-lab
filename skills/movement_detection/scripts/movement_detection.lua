local arg_schema = require("arg_schema")
local board_manager = require("board_manager")
local camera = require("camera")
local capability = require("capability")
local delay = require("delay")
local image = require("image")
local motion = require("motion_detect")
local storage = require("storage")
local system = require("system")

local TAG = "[movement_detection]"

local DEFAULT_DURATION_MS = 300000
local DEFAULT_FRAME_INTERVAL_MS = 200
local DEFAULT_COOLDOWN_MS = 10000
local DEFAULT_MAX_NOTIFICATIONS = 1
local DEFAULT_TIMEOUT_MS = 3000
local DEFAULT_WARMUP_FRAMES = 3
local DEFAULT_STRIDE = 8
local DEFAULT_PIXEL_THRESHOLD = 0.2
local DEFAULT_MOVING_THRESHOLD = 0.02
local DEFAULT_DIR = "movement_detection"
local DEFAULT_CAPTION = "Moving object detected"

local CHANNELS = {
    wechat = {
        context_channel = "wechat",
        image = "wechat_send_image",
    },
    feishu = {
        context_channel = "feishu",
        image = "feishu_send_image",
    },
    qq = {
        context_channel = "qq",
        image = "qq_send_image",
    },
    telegram = {
        context_channel = "telegram",
        image = "tg_send_image",
    },
    tg = {
        context_channel = "telegram",
        image = "tg_send_image",
    },
    web = {
        context_channel = "web",
        text = "local_send_message",
    },
    ["local"] = {
        context_channel = "web",
        text = "local_send_message",
    },
}

local ARG_SCHEMA = {
    duration_ms = arg_schema.int({ default = DEFAULT_DURATION_MS, min = 0 }),
    frame_interval_ms = arg_schema.int({ default = DEFAULT_FRAME_INTERVAL_MS, min = 0 }),
    cooldown_ms = arg_schema.int({ default = DEFAULT_COOLDOWN_MS, min = 0 }),
    max_notifications = arg_schema.int({ default = DEFAULT_MAX_NOTIFICATIONS, min = 0 }),
    timeout_ms = arg_schema.int({ default = DEFAULT_TIMEOUT_MS, min = 0 }),
    warmup_frames = arg_schema.int({ default = DEFAULT_WARMUP_FRAMES, min = 0 }),
    stride = arg_schema.int({ default = DEFAULT_STRIDE, min = 1 }),
}

local raw_args = type(args) == "table" and args or {}
local ctx = arg_schema.parse(raw_args, ARG_SCHEMA)

local camera_opened = false

local function raw_arg(name, default)
    local value = raw_args[name]
    if value ~= nil then
        return value
    end
    return default
end

local function string_arg(name, default)
    local value = raw_args[name]
    if type(value) == "string" and value ~= "" then
        return value
    end
    return default
end

local function number_arg(name, default, min, max)
    local value = raw_arg(name, default)
    if type(value) ~= "number" then
        error("args." .. name .. " must be a number")
    end
    if min and value < min then
        error("args." .. name .. " must be >= " .. tostring(min))
    end
    if max and value > max then
        error("args." .. name .. " must be <= " .. tostring(max))
    end
    return value
end

ctx.pixel_threshold = number_arg("pixel_threshold", DEFAULT_PIXEL_THRESHOLD, 0, 1)
ctx.moving_threshold = number_arg("moving_threshold", DEFAULT_MOVING_THRESHOLD, 0, 1)
ctx.caption = string_arg("caption", DEFAULT_CAPTION)
ctx.dir = string_arg("dir", DEFAULT_DIR)
ctx.session_id = string_arg("session_id", nil)

local function cleanup()
    if camera_opened then
        local ok, err = pcall(camera.close)
        if not ok then
            print(TAG .. " WARN: camera.close failed: " .. tostring(err))
        end
        camera_opened = false
    end
end

local function reject_path_part(name, value)
    if type(value) ~= "string" then
        error(name .. " must be a string")
    end
    if string.find(value, "%.%.", 1, false) then
        error(name .. " must not contain '..'")
    end
    if string.find(value, "/", 1, true) or string.find(value, "\\", 1, true) then
        error(name .. " must not contain path separators")
    end
end

local function ensure_capture_dir()
    reject_path_part("dir", ctx.dir)

    local root = storage.get_root_dir()
    local dir_path = storage.join_path(root, ctx.dir)
    if not storage.exists(dir_path) then
        storage.mkdir(dir_path)
    end
    return dir_path
end

local function parse_target_from_session(session_id)
    if type(session_id) ~= "string" or session_id == "" then
        return nil, nil
    end

    local channel, chat_id = string.match(session_id, "^([^:]+):([^:]+):")
    return channel, chat_id
end

local function normalize_channel(channel)
    if not channel or channel == "" then
        return "wechat"
    end
    return string.lower(channel)
end

local function resolve_target()
    local session_channel, session_chat_id = parse_target_from_session(ctx.session_id)
    local channel = normalize_channel(string_arg("channel", session_channel))
    local chat_id = string_arg("chat_id", session_chat_id)
    local config = CHANNELS[channel]

    if not config then
        error("unsupported channel: " .. tostring(channel))
    end

    return channel, chat_id, config
end

local function build_cap_opts(config, chat_id)
    local opts = {
        channel = config.context_channel,
        source_cap = "movement_detection",
        max_output_bytes = 8192,
    }

    if ctx.session_id then
        opts.session_id = ctx.session_id
    end
    if chat_id then
        opts.chat_id = chat_id
    end

    return opts
end

local function call_required(cap_name, payload, opts, label)
    local ok, out, err = capability.call(cap_name, payload, opts)
    print(string.format(
        "%s capability label=%s cap=%s ok=%s out=%s err=%s",
        TAG,
        tostring(label),
        tostring(cap_name),
        tostring(ok),
        tostring(out),
        tostring(err)
    ))

    if not ok then
        error(string.format("%s failed: err=%s out=%s", cap_name, tostring(err), tostring(out)))
    end
end

local function send_detection(channel, chat_id, config, path, caption)
    local opts = build_cap_opts(config, chat_id)

    if config.image then
        if not chat_id then
            error("args.chat_id is required for " .. channel .. " image send")
        end

        call_required(config.image, {
            chat_id = chat_id,
            path = path,
            caption = caption,
        }, opts, "image")
        return
    end

    local payload = {
        channel = config.context_channel,
        message = caption .. "\nImage: " .. path,
        link_url = path,
        link_label = "View image",
    }

    if chat_id then
        payload.chat_id = chat_id
    end

    call_required(config.text, payload, opts, "local_message")
end

local function save_frame(frame, dir_path, index)
    local filename = string.format("motion_%s_%03d.jpg", system.date("%Y%m%d_%H%M%S"), index)
    local path = storage.join_path(dir_path, filename)

    image.save_file(path, frame)

    local stat, stat_err = storage.stat(path)
    if not stat then
        error("storage.stat failed after save: " .. tostring(stat_err))
    end

    return path, stat.size
end

local function open_camera()
    local camera_paths, path_err = board_manager.get_camera_paths()
    if not camera_paths then
        error("get_camera_paths failed: " .. tostring(path_err))
    end

    local ok, err = pcall(camera.open, camera_paths.dev_path, {
        format = { "JPEG", "RGBP", "YUYV", "UYVY", "YU12" },
        width = 320,
        height = 240,
        nearest = true,
    })
    if not ok then
        error("camera.open failed: " .. tostring(err))
    end
    camera_opened = true

    local info = camera.info()
    print(string.format(
        "%s camera stream: %dx%d format=%s",
        TAG,
        info.width,
        info.height,
        tostring(info.pixel_format)
    ))

    camera.flush()
    for i = 1, ctx.warmup_frames do
        local warmup_frame <close> = camera.get_frame(ctx.timeout_ms)
        local frame_info = warmup_frame:info()
        print(string.format(
            "%s skipped warm-up frame %d/%d: %dx%d format=%s",
            TAG,
            i,
            ctx.warmup_frames,
            frame_info.width,
            frame_info.height,
            tostring(frame_info.pixel_format)
        ))
    end
end

local function run()
    local channel, chat_id, config = resolve_target()
    local dir_path = ensure_capture_dir()
    local start_ms = system.millis()
    local deadline_ms = ctx.duration_ms > 0 and (start_ms + ctx.duration_ms) or nil
    local last_notify_ms = 0 - ctx.cooldown_ms
    local frames = 0
    local notifications = 0
    local motion_opts = {
        stride = ctx.stride,
        pixel_threshold = ctx.pixel_threshold,
        moving_threshold = ctx.moving_threshold,
    }

    print(string.format(
        "%s start channel=%s chat_id=%s duration_ms=%d cooldown_ms=%d max_notifications=%d",
        TAG,
        channel,
        tostring(chat_id),
        ctx.duration_ms,
        ctx.cooldown_ms,
        ctx.max_notifications
    ))

    open_camera()
    motion.reset()

    while not deadline_ms or system.millis() < deadline_ms do
        local now_ms = system.millis()
        local notify_path = nil
        local notify_caption = nil
        local should_stop = false

        do
            local frame <close> = camera.get_frame(ctx.timeout_ms)
            local gray <close> = image.convert(frame, image.GRAY8)
            local result = motion.detect(gray, motion_opts)

            frames = frames + 1

            if result.has_previous and result.moved then
                local cooled_down = (now_ms - last_notify_ms) >= ctx.cooldown_ms
                local under_limit = ctx.max_notifications == 0 or notifications < ctx.max_notifications

                print(string.format(
                    "%s motion frame=%d moving_ratio=%.4f moving_points=%s sample_points=%s cooled_down=%s under_limit=%s",
                    TAG,
                    frames,
                    result.moving_ratio or 0,
                    tostring(result.moving_points),
                    tostring(result.sample_points),
                    tostring(cooled_down),
                    tostring(under_limit)
                ))

                if cooled_down and under_limit then
                    notifications = notifications + 1
                    last_notify_ms = now_ms

                    local path, size = save_frame(frame, dir_path, notifications)
                    notify_path = path
                    notify_caption = string.format(
                        "%s，moving_ratio=%.4f，image=%s",
                        ctx.caption,
                        result.moving_ratio or 0,
                        path
                    )

                    print(string.format("%s saved trigger image path=%s bytes=%d", TAG, path, size))

                    if ctx.max_notifications > 0 and notifications >= ctx.max_notifications then
                        print(string.format("%s reached max_notifications=%d", TAG, ctx.max_notifications))
                        should_stop = true
                    end
                end
            elseif frames == 1 or frames % 30 == 0 then
                print(string.format(
                    "%s frame=%d seeded=%s moving_ratio=%.4f moved=%s",
                    TAG,
                    frames,
                    tostring(not result.has_previous),
                    result.moving_ratio or 0,
                    tostring(result.moved)
                ))
            end
        end

        if notify_path then
            send_detection(channel, chat_id, config, notify_path, notify_caption)
        end

        if should_stop then
            break
        end

        if ctx.frame_interval_ms > 0 then
            delay.delay_ms(ctx.frame_interval_ms)
        end
    end

    print(string.format(
        "%s stopped frames=%d notifications=%d elapsed_ms=%d",
        TAG,
        frames,
        notifications,
        system.millis() - start_ms
    ))
end

local ok, err = xpcall(run, debug.traceback)
cleanup()
if not ok then
    print(TAG .. " ERROR: " .. tostring(err))
    error(err)
end
