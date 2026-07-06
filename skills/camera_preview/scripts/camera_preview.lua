local board_manager = require("board_manager")
local camera = require("camera")
local display = require("display")
local delay = require("delay")

local FRAME_TIMEOUT_MS = 1000
local FRAME_INTERVAL_MS = 30
local PREVIEW_MODE = "fit"
local CAMERA_FORMATS = { "RGBP", "RGBR", "JPEG", "MJPG", "YUYV", "UYVY" }

local function close_camera()
    local ok, err = pcall(camera.close)
    if not ok then
        print("[camera_preview_demo] WARN: close failed: " .. tostring(err))
    end
end

local function cleanup_display()
    pcall(display.end_frame)
    pcall(display.deinit)
end

local camera_paths, path_err = board_manager.get_camera_paths()
if not camera_paths then
    print("[camera_preview_demo] ERROR: get_camera_paths failed: " .. tostring(path_err))
    return
end

local panel_handle, io_handle, lcd_w, lcd_h, panel_if = board_manager.get_display_lcd_params("display_lcd")
if not panel_handle then
    print("[camera_preview_demo] ERROR: get_display_lcd_params failed: " .. tostring(io_handle))
    return
end

local panel_if_name = "io"
if panel_if == board_manager.PANEL_IF_MIPI_DSI then
    panel_if_name = "mipi_dsi"
elseif panel_if == board_manager.PANEL_IF_RGB then
    panel_if_name = "rgb"
end

local ok, err = pcall(display.init, panel_handle, io_handle, lcd_w, lcd_h, panel_if)
if not ok then
    print("[camera_preview_demo] ERROR: display.init failed: " .. tostring(err))
    return
end

local width = display.width
local height = display.height
if width <= 0 or height <= 0 then
    print("[camera_preview_demo] ERROR: invalid display size after init")
    cleanup_display()
    return
end

-- Match the requested camera stream size to the actual LCD drawing size.
local camera_open_opts = {
    format = CAMERA_FORMATS,
    width = width,
    height = height,
    nearest = true,
}

local opened, open_err = pcall(camera.open, camera_paths.dev_path, camera_open_opts)
if not opened then
    print("[camera_preview_demo] ERROR: " .. tostring(open_err))
    cleanup_display()
    return
end

local info_ok, info_or_err = pcall(camera.info)
if not info_ok then
    print("[camera_preview_demo] ERROR: " .. tostring(info_or_err))
    close_camera()
    cleanup_display()
    return
end

local pixel_format = tostring(info_or_err.pixel_format)

local x = 0
local y = 0

local function draw_frame(frame)
    display.draw_image(x, y, frame, { mode = PREVIEW_MODE, width = width, height = height })
    display.present()
end

print(string.format(
    "[camera_preview_demo] preview start camera=%dx%d format=%s lcd=%dx%d panel_if=%s mode=%s",
    info_or_err.width, info_or_err.height, pixel_format, width, height, panel_if_name, PREVIEW_MODE
))

display.begin_frame({ clear = true })

while true do
    local frame_ok, frame_or_err = pcall(camera.get_frame, FRAME_TIMEOUT_MS)
    if not frame_ok then
        print("[camera_preview_demo] ERROR: " .. tostring(frame_or_err))
        break
    end

    local draw_ok, draw_err = pcall(draw_frame, frame_or_err)

    pcall(frame_or_err.release, frame_or_err)

    if not draw_ok then
        print("[camera_preview_demo] ERROR: draw failed: " .. tostring(draw_err))
        break
    end

    delay.delay_ms(FRAME_INTERVAL_MS)
end

close_camera()
cleanup_display()
