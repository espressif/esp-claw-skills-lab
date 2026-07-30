local arg_schema = require("arg_schema")
local board_manager = require("board_manager")
local camera = require("camera")
local delay = require("delay")
local display = require("display")
local image = require("image")
local motion_detect = require("motion_detect")
local system = require("system")

local DEFAULT_FRAME_INTERVAL_MS = 3
local DEFAULT_CAPTURE_TIMEOUT_MS = 500
local DEFAULT_DISPLAY_EVERY_N = 1
local DEFAULT_DISPLAY_CROP_SIZE = 240
local DEFAULT_PERF_LOG_EVERY_N = 30
local DEFAULT_PIXEL_DIFF_THRESHOLD = 24
local DEFAULT_ACTIVE_PIXEL_PERCENT = 5
local DEFAULT_CONFIRM_FRAMES = 2
local DEFAULT_HOLD_FRAMES = 3
local DEFAULT_BLOCK_SIZE = 4
local DEFAULT_BLOCK_HIT_PIXELS = 10
local DEFAULT_BOX_PADDING = 2
local DEFAULT_BOX_DEADBAND = 2
local DEFAULT_BOX_SNAP_THRESHOLD = 24
local DISPLAY_BG_COLOR = "black"

local display_started = false
local camera_started = false
local detector

local ARG_SCHEMA = {
    run_seconds = arg_schema.int({ default = 0, min = 0 }),
    frame_interval_ms = arg_schema.int({ default = DEFAULT_FRAME_INTERVAL_MS, min = 0 }),
    capture_timeout_ms = arg_schema.int({ default = DEFAULT_CAPTURE_TIMEOUT_MS, min = 1 }),
    display_every_n = arg_schema.int({ default = DEFAULT_DISPLAY_EVERY_N, min = 1 }),
    display_crop_size = arg_schema.int({ default = DEFAULT_DISPLAY_CROP_SIZE, min = 1 }),
    perf_log_every_n = arg_schema.int({ default = DEFAULT_PERF_LOG_EVERY_N, min = 0 }),
    pixel_diff_threshold = arg_schema.int({ default = DEFAULT_PIXEL_DIFF_THRESHOLD, min = 0, max = 255 }),
    active_pixel_percent = arg_schema.int({ default = DEFAULT_ACTIVE_PIXEL_PERCENT, min = 1, max = 100 }),
    confirm_frames = arg_schema.int({ default = DEFAULT_CONFIRM_FRAMES, min = 1 }),
    hold_frames = arg_schema.int({ default = DEFAULT_HOLD_FRAMES, min = 0 }),
    block_size = arg_schema.int({ default = DEFAULT_BLOCK_SIZE, min = 1, max = 255 }),
    block_hit_pixels = arg_schema.int({ default = DEFAULT_BLOCK_HIT_PIXELS, min = 1, max = 255 }),
    box_padding = arg_schema.int({ default = DEFAULT_BOX_PADDING, min = 0 }),
    box_deadband = arg_schema.int({ default = DEFAULT_BOX_DEADBAND, min = 0 }),
    box_snap_threshold = arg_schema.int({ default = DEFAULT_BOX_SNAP_THRESHOLD, min = 0 }),
}

local ctx = arg_schema.parse(args, ARG_SCHEMA)

local function clamp(value, min_value, max_value)
    if value < min_value then
        return min_value
    end
    if value > max_value then
        return max_value
    end
    return value
end

local function cleanup()
    if detector then
        pcall(detector.close, detector)
        detector = nil
    end
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

local function compute_center_square_source_rect(src_w, src_h)
    local crop = math.min(ctx.display_crop_size, src_w, src_h)
    local src_x = math.floor((src_w - crop) / 2)
    local src_y = math.floor((src_h - crop) / 2)
    return src_x, src_y, crop, crop
end

local function build_motion_overlay(result, output_w, output_h, src_x, src_y, src_w, src_h)
    if not result or output_w <= 0 or output_h <= 0 or src_w <= 0 or src_h <= 0 then
        return nil
    end
    if result.motion ~= true then
        return nil
    end

    local box = result.box
    if not box then
        return nil
    end

    local left = clamp(box.left, src_x, src_x + src_w - 1)
    local right = clamp(box.right, src_x, src_x + src_w - 1)
    local top = clamp(box.top, src_y, src_y + src_h - 1)
    local bottom = clamp(box.bottom, src_y, src_y + src_h - 1)
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
        color = "yellow",
    }
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
        "[gimbal_motion_detect] display framebuffers=%d double_buffered=%s",
        animation_info.framebuffer_count,
        tostring(animation_info.double_buffered)
    ))
    if not animation_info.double_buffered then
        print("[gimbal_motion_detect] WARN: display framebuffer allocation fell back to single buffering")
    end
end

local function init_camera()
    local camera_paths, path_err = board_manager.get_camera_paths()
    if not camera_paths then
        error("get_camera_paths failed: " .. tostring(path_err))
    end

    -- Use the board default camera stream first. Some board sensors only expose
    -- one fixed mode, and forcing a reconfiguration can hide the real init error.
    print("[gimbal_motion_detect] camera dev_path=" .. tostring(camera_paths.dev_path) ..
          " meta_path=" .. tostring(camera_paths.meta_path))

    local tried = {}
    local function try_open(path)
        if not path or tried[path] then
            return false, nil
        end
        tried[path] = true
        local opened, open_err = pcall(camera.open, path)
        if opened then
            print("[gimbal_motion_detect] camera opened path=" .. tostring(path))
            return true, nil
        end
        return false, tostring(open_err)
    end

    local open_errors = {}
    local opened, open_err = try_open(camera_paths.dev_path)
    if not opened and open_err then
        open_errors[#open_errors + 1] = tostring(camera_paths.dev_path) .. ": " .. open_err
    end
    if not opened then
        for index = 0, 7 do
            local candidate = "/dev/video" .. tostring(index)
            local candidate_opened, candidate_err = try_open(candidate)
            if candidate_opened then
                opened = true
                break
            end
            if candidate_err then
                open_errors[#open_errors + 1] = candidate .. ": " .. candidate_err
            end
        end
    end
    if not opened then
        error("camera.open failed; tried " .. table.concat(open_errors, " | "))
    end
    camera_started = true

    local info_ok, info_or_err = pcall(camera.info)
    if not info_ok then
        error("camera.info failed after open: " .. tostring(info_or_err))
    end
    print(string.format("[gimbal_motion_detect] camera stream=%dx%d format=%s",
        info_or_err.width, info_or_err.height, tostring(info_or_err.pixel_format)))

    local flushed, flush_err = pcall(camera.flush)
    if not flushed then
        print("[gimbal_motion_detect] WARN: camera.flush failed: " .. tostring(flush_err))
    end
end

local function build_detector(src_x, src_y, src_w, src_h)
    detector = motion_detect.new({
        roi = {
            x = src_x,
            y = src_y,
            width = src_w,
            height = src_h,
        },
        pixel_diff_threshold = ctx.pixel_diff_threshold,
        active_pixel_percent = ctx.active_pixel_percent,
        confirm_frames = ctx.confirm_frames,
        hold_frames = ctx.hold_frames,
        block_size = ctx.block_size,
        block_hit_pixels = ctx.block_hit_pixels,
        box_padding = ctx.box_padding,
        box_deadband = ctx.box_deadband,
        box_snap_threshold = ctx.box_snap_threshold,
    })
end

local function run()
    init_camera()
    init_display()

    local stream = camera.info()
    local src_x, src_y, src_w, src_h = compute_center_square_source_rect(stream.width, stream.height)
    local dst_x = math.floor((display.width - src_w) / 2)
    local dst_y = math.floor((display.height - src_h) / 2)
    build_detector(src_x, src_y, src_w, src_h)

    local frame_index = 0
    local perf_start_ms = system.millis()
    local perf_frames = 0
    local perf_get_ms = 0
    local perf_convert_ms = 0
    local perf_detect_ms = 0
    local perf_display_ms = 0
    local perf_loop_ms = 0
    local start_s = os.time()
    local deadline_s = ctx.run_seconds > 0 and (start_s + ctx.run_seconds) or nil

    print(string.format(
        "[gimbal_motion_detect] start stream=%dx%d format=%s roi=(%d,%d %dx%d)",
        stream.width, stream.height, tostring(stream.pixel_format), src_x, src_y, src_w, src_h
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

        t0 = system.millis()
        local converted, rgb565_or_err = pcall(image.convert, frame, image.RGB565)
        local convert_ms = system.millis() - t0
        if not converted then
            error("image.convert RGB565 failed: " .. tostring(rgb565_or_err))
        end
        local rgb565 <close> = rgb565_or_err

        t0 = system.millis()
        local detect_ok, motion_result_or_err = pcall(function()
            return detector:detect(rgb565)
        end)
        local detect_ms = system.millis() - t0
        if not detect_ok then
            error("motion_detect failed: " .. tostring(motion_result_or_err))
        end
        local motion_result = motion_result_or_err

        frame_index = frame_index + 1

        local display_ms = 0
        if (frame_index % ctx.display_every_n) == 0 then
            t0 = system.millis()
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
            local overlay_rect = build_motion_overlay(motion_result, output_w, output_h,
                                                      src_x, src_y, src_w, src_h)
            if overlay_rect then
                display.draw_rect(
                    dst_x + overlay_rect.x,
                    dst_y + overlay_rect.y,
                    overlay_rect.width,
                    overlay_rect.height,
                    overlay_rect.color
                )
            end
            display.present_full()
            display.end_frame({ wait = false })
            display_ms = system.millis() - t0
        end

        local loop_ms = system.millis() - loop_t0
        perf_frames = perf_frames + 1
        perf_get_ms = perf_get_ms + get_ms
        perf_convert_ms = perf_convert_ms + convert_ms
        perf_detect_ms = perf_detect_ms + detect_ms
        perf_display_ms = perf_display_ms + display_ms
        perf_loop_ms = perf_loop_ms + loop_ms
        if ctx.perf_log_every_n > 0 and perf_frames >= ctx.perf_log_every_n then
            local elapsed_ms = math.max(1, system.millis() - perf_start_ms)
            local fps = perf_frames * 1000 / elapsed_ms
            print(string.format(
                "[gimbal_motion_detect] perf fps=%.1f avg_ms get=%.1f convert=%.1f detect=%.1f display=%.1f loop=%.1f ready=%s motion=%s event=%s score=%.3f has_box=%s",
                fps,
                perf_get_ms / perf_frames,
                perf_convert_ms / perf_frames,
                perf_detect_ms / perf_frames,
                perf_display_ms / perf_frames,
                perf_loop_ms / perf_frames,
                tostring(motion_result.ready),
                tostring(motion_result.motion),
                tostring(motion_result.event),
                motion_result.score or 0,
                tostring(motion_result.box ~= nil)
            ))
            perf_start_ms = system.millis()
            perf_frames = 0
            perf_get_ms = 0
            perf_convert_ms = 0
            perf_detect_ms = 0
            perf_display_ms = 0
            perf_loop_ms = 0
        end

        if ctx.frame_interval_ms > 0 then
            delay.delay_ms(ctx.frame_interval_ms)
        end
    end
end

local ok, err = xpcall(run, debug.traceback)
cleanup()
if not ok then
    print("[gimbal_motion_detect] ERROR: " .. tostring(err))
    error(err)
end
