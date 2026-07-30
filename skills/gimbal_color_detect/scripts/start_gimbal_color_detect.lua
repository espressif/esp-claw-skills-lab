local arg_schema = require("arg_schema")
local board_manager = require("board_manager")
local camera = require("camera")
local color_detect = require("color_detect")
local delay = require("delay")
local display = require("display")
local image = require("image")
local ledc = require("ledc")
local system = require("system")

local DEFAULT_FRAME_INTERVAL_MS = 3
local DEFAULT_CAPTURE_TIMEOUT_MS = 3000
local DEFAULT_DISPLAY_EVERY_N = 1
local DEFAULT_DISPLAY_CROP_SIZE = 240
local DEFAULT_PERF_LOG_EVERY_N = 10
local DEFAULT_DETECT_STRIDE = 4
local DEFAULT_DETECT_MIN_PIXELS = 250
local DEFAULT_DETECT_MAX_BLOB_PERCENT = 35
local DEFAULT_DEADZONE_PX = 12
local DEFAULT_X_GAIN = 0.035
local DEFAULT_Y_GAIN = 0.035
local DEFAULT_MAX_TRACK_STEP_DEGREES = 2
local DEFAULT_LOST_CENTER_ENABLE = false
local DEFAULT_LOST_CENTER_FRAMES = 60
local DEFAULT_SERVO_MAX_STEP_DEGREES = 2
local DEFAULT_X_GPIO = 4
local DEFAULT_Y_GPIO = 5
local DEFAULT_FREQUENCY_HZ = 50
local DEFAULT_MIN_PULSE_US = 500
local DEFAULT_MAX_PULSE_US = 2500
local DEFAULT_X_INIT_ANGLE = 90
local DEFAULT_Y_INIT_ANGLE = 50
local DEFAULT_X_MIN_ANGLE = 0
local DEFAULT_X_MAX_ANGLE = 180
local DEFAULT_Y_MIN_ANGLE = 10
local DEFAULT_Y_MAX_ANGLE = 70
local MIN_SERVO_DELTA_DEGREES = 0.05
local DISPLAY_BG_COLOR = "black"

local COLOR_PRESETS = {
    red = { h_min = 170, h_max = 10, s_min = 130, s_max = 255, v_min = 130, v_max = 255 },
    orange = { h_min = 8, h_max = 24, s_min = 89, s_max = 255, v_min = 51, v_max = 255 },
    yellow = { h_min = 22, h_max = 40, s_min = 71, s_max = 255, v_min = 64, v_max = 255 },
    green = { h_min = 50, h_max = 88, s_min = 79, s_max = 255, v_min = 51, v_max = 255 },
    cyan = { h_min = 82, h_max = 100, s_min = 64, s_max = 255, v_min = 46, v_max = 255 },
    blue = { h_min = 95, h_max = 130, s_min = 71, s_max = 255, v_min = 46, v_max = 255 },
    purple = { h_min = 128, h_max = 158, s_min = 64, s_max = 255, v_min = 46, v_max = 255 },
}

local COLOR_ALIASES = {
    ["红色"] = "red",
    ["橙色"] = "orange",
    ["黄色"] = "yellow",
    ["绿色"] = "green",
    ["青色"] = "cyan",
    ["蓝色"] = "blue",
    ["紫色"] = "purple",
}

local display_started = false
local camera_started = false
local x_pwm
local y_pwm

local ARG_SCHEMA = {
    run_seconds = arg_schema.int({ default = 0, min = 0 }),
    frame_interval_ms = arg_schema.int({ default = DEFAULT_FRAME_INTERVAL_MS, min = 0 }),
    capture_timeout_ms = arg_schema.int({ default = DEFAULT_CAPTURE_TIMEOUT_MS, min = 1 }),
    display_every_n = arg_schema.int({ default = DEFAULT_DISPLAY_EVERY_N, min = 1 }),
    display_crop_size = arg_schema.int({ default = DEFAULT_DISPLAY_CROP_SIZE, min = 1 }),
    perf_log_every_n = arg_schema.int({ default = DEFAULT_PERF_LOG_EVERY_N, min = 0 }),
    detect_stride = arg_schema.int({ default = DEFAULT_DETECT_STRIDE, min = 1 }),
    detect_min_pixels = arg_schema.int({ default = DEFAULT_DETECT_MIN_PIXELS, min = 1 }),
    detect_max_blob_percent = arg_schema.int({ default = DEFAULT_DETECT_MAX_BLOB_PERCENT, min = 1, max = 100 }),
    deadzone_px = arg_schema.int({ default = DEFAULT_DEADZONE_PX, min = 0 }),
    x_gain = arg_schema.int({ default = DEFAULT_X_GAIN, floor = false }),
    y_gain = arg_schema.int({ default = DEFAULT_Y_GAIN, floor = false }),
    max_track_step_degrees = arg_schema.int({ default = DEFAULT_MAX_TRACK_STEP_DEGREES, min = 0, max = 30, floor = false }),
    lost_center_enable = arg_schema.bool({ default = DEFAULT_LOST_CENTER_ENABLE }),
    lost_center_frames = arg_schema.int({ default = DEFAULT_LOST_CENTER_FRAMES, min = 1 }),
    servo_max_step_degrees = arg_schema.int({ default = DEFAULT_SERVO_MAX_STEP_DEGREES, min = 1, max = 30, floor = false }),
    x_gpio = arg_schema.int({ default = DEFAULT_X_GPIO, min = 0 }),
    y_gpio = arg_schema.int({ default = DEFAULT_Y_GPIO, min = 0 }),
    frequency_hz = arg_schema.int({ default = DEFAULT_FREQUENCY_HZ, min = 1 }),
    min_pulse_us = arg_schema.int({ default = DEFAULT_MIN_PULSE_US, min = 1 }),
    max_pulse_us = arg_schema.int({ default = DEFAULT_MAX_PULSE_US, min = 1 }),
    x_init_angle = arg_schema.int({ default = DEFAULT_X_INIT_ANGLE, min = 0, max = 180, floor = false }),
    y_init_angle = arg_schema.int({ default = DEFAULT_Y_INIT_ANGLE, min = 0, max = 180, floor = false }),
    x_min_angle = arg_schema.int({ default = DEFAULT_X_MIN_ANGLE, min = 0, max = 180 }),
    x_max_angle = arg_schema.int({ default = DEFAULT_X_MAX_ANGLE, min = 0, max = 180 }),
    y_min_angle = arg_schema.int({ default = DEFAULT_Y_MIN_ANGLE, min = 0, max = 180 }),
    y_max_angle = arg_schema.int({ default = DEFAULT_Y_MAX_ANGLE, min = 0, max = 180 }),
}

local ctx = arg_schema.parse(args, ARG_SCHEMA)
local x_current = ctx.x_init_angle
local y_current = ctx.y_init_angle
local x_target = ctx.x_init_angle
local y_target = ctx.y_init_angle

local function clamp(value, min_value, max_value)
    if value < min_value then
        return min_value
    end
    if value > max_value then
        return max_value
    end
    return value
end

local function raw_arg(name)
    if type(args) == "table" then
        return args[name]
    end
    return nil
end

local function raw_number(name)
    local value = raw_arg(name)
    if type(value) == "number" then
        return value
    end
    return nil
end

local function raw_string(name, default)
    local value = raw_arg(name)
    if type(value) == "string" and value ~= "" then
        return value
    end
    return default
end

local function normalize_color_name(name)
    local normalized = string.lower(tostring(name or "")):gsub("^%s+", ""):gsub("%s+$", "")
    return COLOR_ALIASES[normalized] or normalized
end

local function has_custom_hsv()
    return raw_number("target_h_min") ~= nil or raw_number("target_h_max") ~= nil or
        raw_number("target_s_min") ~= nil or raw_number("target_s_max") ~= nil or
        raw_number("target_v_min") ~= nil or raw_number("target_v_max") ~= nil
end

local function resolve_target_color()
    local color_name = raw_string("target_color_name", raw_string("color_name", ""))
    if color_name == "" and not has_custom_hsv() then
        color_name = "green"
    end
    local preset = COLOR_PRESETS[normalize_color_name(color_name)]
    local custom = has_custom_hsv()

    if preset and not custom then
        ctx.target_color_name = color_name
        ctx.target_h_min = preset.h_min
        ctx.target_h_max = preset.h_max
        ctx.target_s_min = preset.s_min
        ctx.target_s_max = preset.s_max
        ctx.target_v_min = preset.v_min
        ctx.target_v_max = preset.v_max
        ctx.target_color_source = "preset"
        return
    end

    ctx.target_color_name = color_name ~= "" and color_name or "custom"
    ctx.target_h_min = raw_number("target_h_min") or (preset and preset.h_min)
    ctx.target_h_max = raw_number("target_h_max") or (preset and preset.h_max)
    ctx.target_s_min = raw_number("target_s_min") or (preset and preset.s_min) or 64
    ctx.target_s_max = raw_number("target_s_max") or (preset and preset.s_max) or 255
    ctx.target_v_min = raw_number("target_v_min") or (preset and preset.v_min) or 46
    ctx.target_v_max = raw_number("target_v_max") or (preset and preset.v_max) or 255
    ctx.target_color_source = preset and "preset+custom" or "custom"

    if ctx.target_h_min == nil or ctx.target_h_max == nil then
        error("custom target color requires target_h_min and target_h_max")
    end
end

resolve_target_color()
ctx.target_h_min = math.floor(ctx.target_h_min)
ctx.target_h_max = math.floor(ctx.target_h_max)
ctx.target_s_min = math.floor(ctx.target_s_min)
ctx.target_s_max = math.floor(ctx.target_s_max)
ctx.target_v_min = math.floor(ctx.target_v_min)
ctx.target_v_max = math.floor(ctx.target_v_max)

local function clamp_step(value, max_abs)
    if max_abs <= 0 then
        return value
    end
    return clamp(value, -max_abs, max_abs)
end

local function approach(current, target, max_step)
    if target > current + max_step then
        return current + max_step
    end
    if target < current - max_step then
        return current - max_step
    end
    return target
end

local function validate_config()
    if ctx.max_pulse_us <= ctx.min_pulse_us then
        error("max_pulse_us must be greater than min_pulse_us")
    end
    if ctx.x_min_angle > ctx.x_max_angle then
        error("x_min_angle must be <= x_max_angle")
    end
    if ctx.y_min_angle > ctx.y_max_angle then
        error("y_min_angle must be <= y_max_angle")
    end
    if ctx.target_h_min < 0 or ctx.target_h_min > 180 or ctx.target_h_max < 0 or ctx.target_h_max > 180 then
        error("target_h_min/target_h_max must be in 0..180")
    end
    if ctx.target_s_min < 0 or ctx.target_s_min > 255 or ctx.target_s_max < 0 or ctx.target_s_max > 255 then
        error("target_s_min/target_s_max must be in 0..255")
    end
    if ctx.target_v_min < 0 or ctx.target_v_min > 255 or ctx.target_v_max < 0 or ctx.target_v_max > 255 then
        error("target_v_min/target_v_max must be in 0..255")
    end
    if ctx.target_s_min > ctx.target_s_max then
        error("target_s_min must be <= target_s_max")
    end
    if ctx.target_v_min > ctx.target_v_max then
        error("target_v_min must be <= target_v_max")
    end
end

local function angle_to_duty_percent(angle)
    local pulse_width_us = ctx.min_pulse_us +
        (ctx.max_pulse_us - ctx.min_pulse_us) * clamp(angle, 0, 180) / 180
    return pulse_width_us * ctx.frequency_hz / 10000
end

local function set_pwm_angle(pwm, angle)
    pwm:set_duty(angle_to_duty_percent(angle))
end

local function init_servos()
    x_current = clamp(ctx.x_init_angle, ctx.x_min_angle, ctx.x_max_angle)
    y_current = clamp(ctx.y_init_angle, ctx.y_min_angle, ctx.y_max_angle)
    x_target = x_current
    y_target = y_current

    x_pwm = ledc.new({
        gpio = ctx.x_gpio,
        frequency_hz = ctx.frequency_hz,
        duty_percent = angle_to_duty_percent(x_current),
    })
    y_pwm = ledc.new({
        gpio = ctx.y_gpio,
        frequency_hz = ctx.frequency_hz,
        duty_percent = angle_to_duty_percent(y_current),
    })
    x_pwm:start()
    y_pwm:start()

    print(string.format(
        "[gimbal_color_detect] servos started x_gpio=%d y_gpio=%d max_step=%s",
        ctx.x_gpio, ctx.y_gpio, tostring(ctx.servo_max_step_degrees)
    ))
end

local function stop_servos()
    if x_pwm then
        pcall(x_pwm.stop, x_pwm)
        pcall(x_pwm.close, x_pwm)
        x_pwm = nil
    end
    if y_pwm then
        pcall(y_pwm.stop, y_pwm)
        pcall(y_pwm.close, y_pwm)
        y_pwm = nil
    end
end

local function apply_axis(pwm, current, target)
    local next_angle = approach(current, target, ctx.servo_max_step_degrees)
    if math.abs(next_angle - current) >= MIN_SERVO_DELTA_DEGREES then
        set_pwm_angle(pwm, next_angle)
        return next_angle
    end
    return current
end

local function apply_servo_targets()
    if not x_pwm or not y_pwm then
        return
    end
    x_current = apply_axis(x_pwm, x_current, x_target)
    y_current = apply_axis(y_pwm, y_current, y_target)
end

local function cleanup()
    pcall(color_detect.release)
    stop_servos()
    if display_started then
        pcall(display.end_frame)
        pcall(display.deinit)
        display_started = false
    end
    if camera_started then
        pcall(camera.close)
        camera_started = false
    end
end

local function update_servo_target_from_detection(result)
    if not result or result.detected ~= true then
        return
    end

    local source_cx = (result.source_x or 0) + ((result.source_width or result.width or 0) / 2)
    local source_cy = (result.source_y or 0) + ((result.source_height or result.height or 0) / 2)
    local err_x = result.cx - source_cx
    local err_y = result.cy - source_cy
    if math.abs(err_x) < ctx.deadzone_px then
        err_x = 0
    end
    if math.abs(err_y) < ctx.deadzone_px then
        err_y = 0
    end
    if err_x == 0 and err_y == 0 then
        return
    end

    local delta_x = clamp_step(err_x * ctx.x_gain, ctx.max_track_step_degrees)
    local delta_y = clamp_step(err_y * ctx.y_gain, ctx.max_track_step_degrees)
    x_target = clamp(x_target + delta_x, ctx.x_min_angle, ctx.x_max_angle)
    y_target = clamp(y_target + delta_y, ctx.y_min_angle, ctx.y_max_angle)
end

local function center_servos()
    x_target = clamp(ctx.x_init_angle, ctx.x_min_angle, ctx.x_max_angle)
    y_target = clamp(ctx.y_init_angle, ctx.y_min_angle, ctx.y_max_angle)
end

local function compute_center_square_source_rect(src_w, src_h)
    local crop = math.min(ctx.display_crop_size, src_w, src_h)
    local src_x = math.floor((src_w - crop) / 2)
    local src_y = math.floor((src_h - crop) / 2)
    return src_x, src_y, crop, crop
end

local function make_detection_rect(result, output_w, output_h, src_x, src_y, src_w, src_h)
    if not result or result.detected ~= true or output_w <= 0 or output_h <= 0 or src_w <= 0 or src_h <= 0 then
        return nil
    end

    local left = clamp(result.left, src_x, src_x + src_w - 1)
    local right = clamp(result.right, src_x, src_x + src_w - 1)
    local top = clamp(result.top, src_y, src_y + src_h - 1)
    local bottom = clamp(result.bottom, src_y, src_y + src_h - 1)
    if right <= left or bottom <= top then
        return nil
    end

    local scale_x = output_w / src_w
    local scale_y = output_h / src_h
    local x = math.floor((left - src_x) * scale_x)
    local y = math.floor((top - src_y) * scale_y)
    local w = math.max(1, math.floor((right - left + 1) * scale_x))
    local h = math.max(1, math.floor((bottom - top + 1) * scale_y))

    return {
        x = x,
        y = y,
        width = w,
        height = h,
        color = "green",
    }
end

local function detect_color_range(rgb565, src_x, src_y, src_w, src_h, max_blob_pixels, h_min, h_max)
    return color_detect.detect(rgb565, {
        min_pixels = ctx.detect_min_pixels,
        max_blob_pixels = max_blob_pixels,
        source = {
            x = src_x,
            y = src_y,
            width = src_w,
            height = src_h,
        },
        h_min = h_min,
        h_max = h_max,
        s_min = ctx.target_s_min,
        s_max = ctx.target_s_max,
        v_min = ctx.target_v_min,
        v_max = ctx.target_v_max,
    })
end

local function detect_registered_color(rgb565, src_x, src_y, src_w, src_h, max_blob_pixels)
    return detect_color_range(rgb565, src_x, src_y, src_w, src_h, max_blob_pixels,
                              ctx.target_h_min, ctx.target_h_max)
end

local function init_display()
    local panel_handle, io_handle, lcd_width, lcd_height, panel_if =
        board_manager.get_display_lcd_params("display_lcd")
    if not panel_handle then
        error("get_display_lcd_params failed: " .. tostring(io_handle))
    end
    display.init(panel_handle, io_handle, lcd_width, lcd_height, panel_if)
    display_started = true
    pcall(display.backlight, true)
    display.begin_frame({ clear = false, color = DISPLAY_BG_COLOR, preserve = false })
    display.clear(DISPLAY_BG_COLOR)
    display.present_full()
    display.end_frame()

    local animation_info = display.animation_info()
    print(string.format(
        "[gimbal_color_detect] display framebuffers=%d double_buffered=%s",
        animation_info.framebuffer_count,
        tostring(animation_info.double_buffered)
    ))
    if not animation_info.double_buffered then
        print("[gimbal_color_detect] WARN: display framebuffer allocation fell back to single buffering")
    end
end

local function init_camera()
    local camera_paths, path_err = board_manager.get_camera_paths()
    if not camera_paths then
        error("get_camera_paths failed: " .. tostring(path_err))
    end

    -- Use the board default camera stream first. Some board sensors only expose
    -- one fixed mode, and forcing a reconfiguration can hide the real init error.
    print("[gimbal_color_detect] camera dev_path=" .. tostring(camera_paths.dev_path))
    local opened, open_err = pcall(camera.open, camera_paths.dev_path)
    if not opened then
        error("camera.open failed: " .. tostring(open_err))
    end
    camera_started = true
    pcall(camera.flush)
end

local function run()
    validate_config()
    init_camera()
    init_display()
    init_servos()

    local stream = camera.info()
    local frame_index = 0
    local lost_frames = 0
    local perf_start_ms = system.millis()
    local perf_frames = 0
    local perf_get_ms = 0
    local perf_convert_ms = 0
    local perf_detect_ms = 0
    local perf_display_ms = 0
    local perf_delay_ms = 0
    local perf_loop_ms = 0
    local perf_frame_ts_delta_ms = 0
    local perf_frame_ts_count = 0
    local prev_frame_timestamp_us = nil
    local start_s = os.time()
    local deadline_s = ctx.run_seconds > 0 and (start_s + ctx.run_seconds) or nil
    print(string.format(
        "[gimbal_color_detect] start stream=%dx%d format=%s target_color=%s source=%s hsv=(%s..%s, %d..%d, %d..%d)",
        stream.width,
        stream.height,
        tostring(stream.pixel_format),
        tostring(ctx.target_color_name),
        tostring(ctx.target_color_source),
        tostring(ctx.target_h_min),
        tostring(ctx.target_h_max),
        ctx.target_s_min,
        ctx.target_s_max,
        ctx.target_v_min,
        ctx.target_v_max
    ))

    while not deadline_s or os.time() < deadline_s do
        local loop_t0 = system.millis()
        local t0 = loop_t0
        local got_frame, frame_or_err = pcall(camera.get_frame, ctx.capture_timeout_ms)
        local get_ms = system.millis() - t0
        if not got_frame then
            error("camera.get_frame failed: " .. tostring(frame_or_err))
        end
        local frame <close> = frame_or_err
        local frame_info = frame:info()
        if prev_frame_timestamp_us ~= nil and frame_info.timestamp_us ~= nil then
            perf_frame_ts_delta_ms = perf_frame_ts_delta_ms +
                ((frame_info.timestamp_us - prev_frame_timestamp_us) / 1000)
            perf_frame_ts_count = perf_frame_ts_count + 1
        end
        prev_frame_timestamp_us = frame_info.timestamp_us

        t0 = system.millis()
        local converted, rgb565_or_err = pcall(image.convert, frame, image.RGB565)
        local convert_ms = system.millis() - t0
        if not converted then
            error("image.convert RGB565 failed: " .. tostring(rgb565_or_err))
        end
        local rgb565 <close> = rgb565_or_err

        local image_w = frame_info.width or stream.width
        local image_h = frame_info.height or stream.height
        local src_x, src_y, src_w, src_h = compute_center_square_source_rect(image_w, image_h)
        local max_blob_pixels = math.floor(src_w * src_h * ctx.detect_max_blob_percent / 100)

        t0 = system.millis()
        local detected, detect_result_or_err = pcall(detect_registered_color, rgb565,
                                                     src_x, src_y, src_w, src_h, max_blob_pixels)
        local detect_ms = system.millis() - t0
        if not detected then
            error("color_detect.detect failed: " .. tostring(detect_result_or_err))
        end
        local detect_result = detect_result_or_err

        frame_index = frame_index + 1
        if detect_result.detected == true then
            lost_frames = 0
            update_servo_target_from_detection(detect_result)
        else
            lost_frames = lost_frames + 1
            if ctx.lost_center_enable and lost_frames >= ctx.lost_center_frames then
                center_servos()
                lost_frames = 0
            end
        end
        apply_servo_targets()

        local display_ms = 0
        if (frame_index % ctx.display_every_n) == 0 then
            t0 = system.millis()
            local dst_x = math.floor((display.width - src_w) / 2)
            local dst_y = 0
            display.begin_frame({ clear = false, color = DISPLAY_BG_COLOR, preserve = false })
            local output_w, output_h = display.draw_image(dst_x, dst_y, rgb565, {
                mode = "crop",
                source = {
                    x = src_x,
                    y = src_y,
                    width = src_w,
                    height = src_h,
                },
                width = src_w,
                height = src_h,
            })
            local detection_rect = make_detection_rect(detect_result, output_w, output_h,
                                                       src_x, src_y, src_w, src_h)
            if detection_rect then
                display.draw_rect(
                    dst_x + detection_rect.x,
                    dst_y + detection_rect.y,
                    detection_rect.width,
                    detection_rect.height,
                    detection_rect.color
                )
            end
            display.present_full()
            display.end_frame({ wait = false })
            display_ms = system.millis() - t0
        end

        local delay_ms = 0
        if ctx.frame_interval_ms > 0 then
            t0 = system.millis()
            delay.delay_ms(ctx.frame_interval_ms)
            delay_ms = system.millis() - t0
        end

        local loop_ms = system.millis() - loop_t0
        perf_frames = perf_frames + 1
        perf_get_ms = perf_get_ms + get_ms
        perf_convert_ms = perf_convert_ms + convert_ms
        perf_detect_ms = perf_detect_ms + detect_ms
        perf_display_ms = perf_display_ms + display_ms
        perf_delay_ms = perf_delay_ms + delay_ms
        perf_loop_ms = perf_loop_ms + loop_ms
        if ctx.perf_log_every_n > 0 and perf_frames >= ctx.perf_log_every_n then
            local elapsed_ms = math.max(1, system.millis() - perf_start_ms)
            local fps = perf_frames * 1000 / elapsed_ms
            local frame_ts_ms = perf_frame_ts_count > 0 and (perf_frame_ts_delta_ms / perf_frame_ts_count) or -1
            print(string.format(
                "[gimbal_color_detect] perf fps=%.1f avg_ms get=%.1f convert=%.1f detect=%.1f display=%.1f delay=%.1f loop=%.1f frame_ts=%.1f",
                fps,
                perf_get_ms / perf_frames,
                perf_convert_ms / perf_frames,
                perf_detect_ms / perf_frames,
                perf_display_ms / perf_frames,
                perf_delay_ms / perf_frames,
                perf_loop_ms / perf_frames,
                frame_ts_ms
            ))
            perf_start_ms = system.millis()
            perf_frames = 0
            perf_get_ms = 0
            perf_convert_ms = 0
            perf_detect_ms = 0
            perf_display_ms = 0
            perf_delay_ms = 0
            perf_loop_ms = 0
            perf_frame_ts_delta_ms = 0
            perf_frame_ts_count = 0
        end

        if frame_index == 1 or frame_index % 60 == 0 then
            print(string.format("[gimbal_color_detect] frame=%d detected=%s target=(%.1f,%.1f) current=(%.1f,%.1f)",
                frame_index, tostring(detect_result.detected), x_target, y_target, x_current, y_current))
        end
    end
end

local ok, err = xpcall(run, debug.traceback)
cleanup()
if not ok then
    print("[gimbal_color_detect] ERROR: " .. tostring(err))
    error(err)
end
