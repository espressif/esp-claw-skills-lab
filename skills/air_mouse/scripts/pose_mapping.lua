-- Quaternion pose mapping ported from airmouse_pose_mapping_quaternion.cpp.

local imu_quat = require("imu_quat")

local M = {}

local DEFAULT_SCREEN_DIST = 50
local DEFAULT_GAIN = 20.0
local DEFAULT_DEAD_X = 0.05
local DEFAULT_DEAD_Y = 0.05
local DEFAULT_MAX_DX = 20
local DEFAULT_MAX_DY = 20
local DEFAULT_SPHERICAL_DEADZONE = 0.0008
local DEFAULT_GYRO_LIMIT_DPS = 250.0

local function normalize3(v)
    return imu_quat.vec_normalize3(v)
end

local function reset_stable_forward(handle)
    local f_init = imu_quat.rotate_body_to_world(handle.quat, handle.f_ref)
    if not normalize3(f_init) then
        local fallback = imu_quat.axis_to_vec3(handle.forward_axis)
        handle.f_stable[1] = fallback[1]
        handle.f_stable[2] = fallback[2]
        handle.f_stable[3] = fallback[3]
        return
    end
    handle.f_stable[1] = f_init[1]
    handle.f_stable[2] = f_init[2]
    handle.f_stable[3] = f_init[3]
end

local function project_fcur_to_uv(handle, f_cur)
    local forward = imu_quat.axis_to_vec3(handle.forward_axis)
    local sx = imu_quat.axis_to_vec3(handle.screen_x_axis)
    local sy = imu_quat.axis_to_vec3(handle.screen_y_axis)
    if not forward or not sx or not sy then
        return nil
    end

    local eps = 1e-4
    local depth = imu_quat.vec_dot3(f_cur, forward)
    if depth <= eps then
        return nil
    end

    local dist = handle.screen_dist
    local u = dist * imu_quat.vec_dot3(f_cur, sx) / depth
    local v = dist * imu_quat.vec_dot3(f_cur, sy) / depth
    return u, v
end

local function uv_to_dxdy(handle, u, v)
    if not handle.has_last_uv then
        handle.last_u = u
        handle.last_v = v
        handle.has_last_uv = true
        return 0, 0
    end

    local du = u - handle.last_u
    local dv = v - handle.last_v
    handle.last_u = u
    handle.last_v = v

    if math.abs(du) < handle.dead_x then
        du = 0
    end
    if math.abs(dv) < handle.dead_y then
        dv = 0
    end

    local fx = du * handle.sensitivity_gain + handle.rem_x
    local fy = dv * handle.sensitivity_gain + handle.rem_y

    if fx > handle.max_dx then
        fx = handle.max_dx
    elseif fx < -handle.max_dx then
        fx = -handle.max_dx
    end
    if fy > handle.max_dy then
        fy = handle.max_dy
    elseif fy < -handle.max_dy then
        fy = -handle.max_dy
    end

    -- C (int) truncates toward zero
    local dx = fx >= 0 and math.floor(fx) or math.ceil(fx)
    local dy = fy >= 0 and math.floor(fy) or math.ceil(fy)

    handle.rem_x = fx - dx
    handle.rem_y = fy - dy
    return dx, dy
end

local function in_spherical_deadzone(handle, f_cur)
    local dx = f_cur[1] - handle.f_stable[1]
    local dy = f_cur[2] - handle.f_stable[2]
    local dz = f_cur[3] - handle.f_stable[3]
    local dist2 = dx * dx + dy * dy + dz * dz
    local thr = handle.spherical_deadzone
    return dist2 < thr * thr
end

--- Create pose mapping handle.
--- opts: gain, dead_x, dead_y, max_dx, max_dy, screen_dist, spherical_deadzone, gyro_limit_dps
function M.create(opts)
    opts = opts or {}

    local forward_axis = imu_quat.AXIS_NEG_X
    local up_axis = imu_quat.AXIS_POS_Z
    local screen_x_axis = imu_quat.AXIS_POS_Y
    local screen_y_axis = imu_quat.AXIS_NEG_Z

    local f_ref = imu_quat.axis_to_vec3(forward_axis)

    local quat_config = {
        init_strategy = imu_quat.INIT_ACCEL_HEADING_ALIGNMENT,
        accel_target_axis = up_axis,
        heading_ref_body = { f_ref[1], f_ref[2], f_ref[3] },
        heading_target_axis = forward_axis,
        gyro_bias_enabled = true,
        gyro_guard_enabled = true,
        gyro_guard_limit_dps = opts.gyro_limit_dps or DEFAULT_GYRO_LIMIT_DPS,
    }

    local handle = {
        quat = imu_quat.create(quat_config),
        forward_axis = forward_axis,
        up_axis = up_axis,
        screen_x_axis = screen_x_axis,
        screen_y_axis = screen_y_axis,
        f_ref = f_ref,
        f_stable = { f_ref[1], f_ref[2], f_ref[3] },
        screen_dist = opts.screen_dist or DEFAULT_SCREEN_DIST,
        sensitivity_gain = opts.gain or DEFAULT_GAIN,
        dead_x = opts.dead_x or DEFAULT_DEAD_X,
        dead_y = opts.dead_y or DEFAULT_DEAD_Y,
        max_dx = opts.max_dx or DEFAULT_MAX_DX,
        max_dy = opts.max_dy or DEFAULT_MAX_DY,
        spherical_deadzone = opts.spherical_deadzone or DEFAULT_SPHERICAL_DEADZONE,
        last_u = 0,
        last_v = 0,
        has_last_uv = false,
        rem_x = 0,
        rem_y = 0,
        last_sample_us = 0,
    }
    return handle
end

--- Update relative cursor from accel (g) + gyro (dps).
--- @return dx, dy  (integers; 0,0 when no motion)
function M.update_cursor(handle, accel, gyro, now_us)
    if handle.last_sample_us ~= 0 and (now_us - handle.last_sample_us) > 100000 then
        handle.has_last_uv = false
    end
    handle.last_sample_us = now_us

    local quat_out, err = imu_quat.update(handle.quat, accel, gyro, now_us)
    if not quat_out then
        return 0, 0, err
    end

    if not quat_out.updated then
        if quat_out.reinitialized then
            handle.has_last_uv = false
        end
        reset_stable_forward(handle)
        return 0, 0
    end

    local f_cur = imu_quat.rotate_body_to_world(handle.quat, handle.f_ref)
    if not normalize3(f_cur) then
        return 0, 0
    end

    if in_spherical_deadzone(handle, f_cur) then
        return 0, 0
    end

    handle.f_stable[1] = f_cur[1]
    handle.f_stable[2] = f_cur[2]
    handle.f_stable[3] = f_cur[3]

    local u, v = project_fcur_to_uv(handle, f_cur)
    if not u then
        return 0, 0
    end

    return uv_to_dxdy(handle, u, v)
end

return M
