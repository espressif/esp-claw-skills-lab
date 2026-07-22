-- Quaternion complementary filter ported from imu_quaternion (C).

local M = {}

local DEG2RAD = 0.01745329252
local RAD2DEG = 57.2957795131

local FEEDBACK_GAIN = 0.5
local WARMUP_GAIN = 10.0
local WARMUP_PERIOD_SEC = 3.0
local REST_FILTER_TAU_SEC = 0.5
local REST_MIN_TIME_SEC = 1.2
local REST_GYRO_THRESHOLD_DPS = 5.0
local REST_ACC_THRESHOLD_G = 0.12
local BIAS_FILTER_TAU_SEC = 0.5
local BIAS_REST_GAIN = 0.1
local BIAS_CLIP_DPS = 2.0
local GYRO_RECOVER_DPS = 30.0
local GYRO_REINIT_WINDOW_MS = 200
local GYRO_RECOVER_WINDOW_MS = 400

M.AXIS_POS_X = 0
M.AXIS_NEG_X = 1
M.AXIS_POS_Y = 2
M.AXIS_NEG_Y = 3
M.AXIS_POS_Z = 4
M.AXIS_NEG_Z = 5

M.INIT_CURRENT_POSE = 0
M.INIT_ACCEL_HEADING_ALIGNMENT = 1

local function vec_dot3(a, b)
    return a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
end

local function vec_norm3(v)
    return math.sqrt(vec_dot3(v, v))
end

local function vec_normalize3(v)
    local n = vec_norm3(v)
    if n <= 1e-6 then
        return false
    end
    v[1] = v[1] / n
    v[2] = v[2] / n
    v[3] = v[3] / n
    return true
end

local function vec_cross3(a, b, out)
    out[1] = a[2] * b[3] - a[3] * b[2]
    out[2] = a[3] * b[1] - a[1] * b[3]
    out[3] = a[1] * b[2] - a[2] * b[1]
end

local function quat_normalize(q)
    local n = math.sqrt(q.w * q.w + q.x * q.x + q.y * q.y + q.z * q.z)
    q.w = q.w / n
    q.x = q.x / n
    q.y = q.y / n
    q.z = q.z / n
end

local function quat_multiply(aw, ax, ay, az, bw, bx, by, bz)
    return aw * bw - ax * bx - ay * by - az * bz,
        aw * bx + ax * bw + ay * bz - az * by,
        aw * by - ax * bz + ay * bw + az * bx,
        aw * bz + ax * by - ay * bx + az * bw
end

local function rotate_vec(qw, qx, qy, qz, v, out)
    local r00 = 1.0 - 2.0 * (qy * qy + qz * qz)
    local r01 = 2.0 * (qx * qy - qw * qz)
    local r02 = 2.0 * (qx * qz + qw * qy)
    local r10 = 2.0 * (qx * qy + qw * qz)
    local r11 = 1.0 - 2.0 * (qx * qx + qz * qz)
    local r12 = 2.0 * (qy * qz - qw * qx)
    local r20 = 2.0 * (qx * qz - qw * qy)
    local r21 = 2.0 * (qy * qz + qw * qx)
    local r22 = 1.0 - 2.0 * (qx * qx + qy * qy)
    out[1] = r00 * v[1] + r01 * v[2] + r02 * v[3]
    out[2] = r10 * v[1] + r11 * v[2] + r12 * v[3]
    out[3] = r20 * v[1] + r21 * v[2] + r22 * v[3]
end

local function rotate_vec_transpose(qw, qx, qy, qz, v, out)
    local r00 = 1.0 - 2.0 * (qy * qy + qz * qz)
    local r01 = 2.0 * (qx * qy - qw * qz)
    local r02 = 2.0 * (qx * qz + qw * qy)
    local r10 = 2.0 * (qx * qy + qw * qz)
    local r11 = 1.0 - 2.0 * (qx * qx + qz * qz)
    local r12 = 2.0 * (qy * qz - qw * qx)
    local r20 = 2.0 * (qx * qz - qw * qy)
    local r21 = 2.0 * (qy * qz + qw * qx)
    local r22 = 1.0 - 2.0 * (qx * qx + qy * qy)
    out[1] = r00 * v[1] + r10 * v[2] + r20 * v[3]
    out[2] = r01 * v[1] + r11 * v[2] + r21 * v[3]
    out[3] = r02 * v[1] + r12 * v[2] + r22 * v[3]
end

local function from_rotation_matrix(rot, q)
    local trace = rot[1][1] + rot[2][2] + rot[3][3]
    if trace > 0.0 then
        local s = 2.0 * math.sqrt(trace + 1.0)
        if s <= 1e-12 then
            return false
        end
        q.w = 0.25 * s
        q.x = (rot[3][2] - rot[2][3]) / s
        q.y = (rot[1][3] - rot[3][1]) / s
        q.z = (rot[2][1] - rot[1][2]) / s
    elseif rot[1][1] > rot[2][2] and rot[1][1] > rot[3][3] then
        local s = 2.0 * math.sqrt(1.0 + rot[1][1] - rot[2][2] - rot[3][3])
        if s <= 1e-12 then
            return false
        end
        q.w = (rot[3][2] - rot[2][3]) / s
        q.x = 0.25 * s
        q.y = (rot[1][2] + rot[2][1]) / s
        q.z = (rot[1][3] + rot[3][1]) / s
    elseif rot[2][2] > rot[3][3] then
        local s = 2.0 * math.sqrt(1.0 + rot[2][2] - rot[1][1] - rot[3][3])
        if s <= 1e-12 then
            return false
        end
        q.w = (rot[1][3] - rot[3][1]) / s
        q.x = (rot[1][2] + rot[2][1]) / s
        q.y = 0.25 * s
        q.z = (rot[2][3] + rot[3][2]) / s
    else
        local s = 2.0 * math.sqrt(1.0 + rot[3][3] - rot[1][1] - rot[2][2])
        if s <= 1e-12 then
            return false
        end
        q.w = (rot[2][1] - rot[1][2]) / s
        q.x = (rot[1][3] + rot[3][1]) / s
        q.y = (rot[2][3] + rot[3][2]) / s
        q.z = 0.25 * s
    end
    quat_normalize(q)
    return true
end

function M.axis_to_vec3(axis, out)
    out = out or { 0, 0, 0 }
    if axis == M.AXIS_POS_X then
        out[1], out[2], out[3] = 1, 0, 0
    elseif axis == M.AXIS_NEG_X then
        out[1], out[2], out[3] = -1, 0, 0
    elseif axis == M.AXIS_POS_Y then
        out[1], out[2], out[3] = 0, 1, 0
    elseif axis == M.AXIS_NEG_Y then
        out[1], out[2], out[3] = 0, -1, 0
    elseif axis == M.AXIS_POS_Z then
        out[1], out[2], out[3] = 0, 0, 1
    elseif axis == M.AXIS_NEG_Z then
        out[1], out[2], out[3] = 0, 0, -1
    else
        return nil
    end
    return out
end

local function reset_solver_runtime(h)
    local feedback_gain = FEEDBACK_GAIN
    local warmup_gain = WARMUP_GAIN
    local warmup_period_sec = WARMUP_PERIOD_SEC
    h.runtime_gain.steady_gain = feedback_gain
    if warmup_period_sec > 0.0 and warmup_gain > feedback_gain then
        h.runtime_gain.warming_up = true
        h.runtime_gain.live_gain = warmup_gain
        h.runtime_gain.gain_drop_per_sec = (warmup_gain - feedback_gain) / warmup_period_sec
    else
        h.runtime_gain.warming_up = false
        h.runtime_gain.live_gain = feedback_gain
        h.runtime_gain.gain_drop_per_sec = 0.0
    end
end

local function set_current_pose_reference(h, accel)
    h.up_ref[1] = accel[1]
    h.up_ref[2] = accel[2]
    h.up_ref[3] = accel[3]
    if not vec_normalize3(h.up_ref) then
        h.up_ref[1], h.up_ref[2], h.up_ref[3] = 0, 0, 1
    end
    h.q.w, h.q.x, h.q.y, h.q.z = 1, 0, 0, 0
end

local function set_accel_heading_alignment_reference(h, accel)
    local p_body = { accel[1], accel[2], accel[3] }
    if not vec_normalize3(p_body) then
        return false
    end

    local r_body = {
        h.config.heading_ref_body[1],
        h.config.heading_ref_body[2],
        h.config.heading_ref_body[3],
    }
    if not vec_normalize3(r_body) then
        return false
    end

    local r_dot_p = vec_dot3(r_body, p_body)
    local s_body = {
        r_body[1] - r_dot_p * p_body[1],
        r_body[2] - r_dot_p * p_body[2],
        r_body[3] - r_dot_p * p_body[3],
    }
    if not vec_normalize3(s_body) then
        return false
    end

    local t_body = { 0, 0, 0 }
    vec_cross3(p_body, s_body, t_body)
    if not vec_normalize3(t_body) then
        return false
    end

    vec_cross3(t_body, p_body, s_body)
    if not vec_normalize3(s_body) then
        return false
    end

    local p_world = M.axis_to_vec3(h.config.accel_target_axis)
    local s_world = M.axis_to_vec3(h.config.heading_target_axis)
    if not p_world or not s_world then
        return false
    end
    if math.abs(vec_dot3(p_world, s_world)) > 1e-6 then
        return false
    end

    local t_world = { 0, 0, 0 }
    vec_cross3(p_world, s_world, t_world)
    if not vec_normalize3(t_world) then
        return false
    end

    local rot = {
        { 0, 0, 0 },
        { 0, 0, 0 },
        { 0, 0, 0 },
    }
    for i = 1, 3 do
        for j = 1, 3 do
            rot[i][j] = s_world[i] * s_body[j] + t_world[i] * t_body[j] + p_world[i] * p_body[j]
        end
    end

    if not from_rotation_matrix(rot, h.q) then
        return false
    end

    h.up_ref[1] = p_world[1]
    h.up_ref[2] = p_world[2]
    h.up_ref[3] = p_world[3]
    return true
end

local function reinitialize_from_sample(h, accel, gyro, now_us)
    if h.config.init_strategy == M.INIT_ACCEL_HEADING_ALIGNMENT then
        if not set_accel_heading_alignment_reference(h, accel) then
            return false
        end
    else
        set_current_pose_reference(h, accel)
    end

    h.last_timestamp_us = now_us
    h.bias.rest_detected = false
    h.bias.bias_lp_valid = false
    h.bias.rest_time_sec = 0.0
    h.gyro_guard.gyro_over_limit_time_sec = 0.0
    h.gyro_guard.gyro_recover_time_sec = 0.0
    h.gyro_guard.gyro_reinit_armed = false

    h.bias.rest_gyro_lp[1] = gyro[1]
    h.bias.rest_gyro_lp[2] = gyro[2]
    h.bias.rest_gyro_lp[3] = gyro[3]
    h.bias.rest_acc_lp[1] = accel[1]
    h.bias.rest_acc_lp[2] = accel[2]
    h.bias.rest_acc_lp[3] = accel[3]

    reset_solver_runtime(h)
    return true
end

local function update_rest_bias(h, accel, gyro, dt_sec)
    if not h.config.gyro_bias_enabled then
        return
    end

    local prev_rest = h.bias.rest_detected
    local gx = gyro[1] - h.bias.gyro_bias[1] * RAD2DEG
    local gy = gyro[2] - h.bias.gyro_bias[2] * RAD2DEG
    local gz = gyro[3] - h.bias.gyro_bias[3] * RAD2DEG
    local allow = true
    if h.config.gyro_guard_enabled then
        local lim = h.config.gyro_guard_limit_dps
        allow = math.abs(gx) <= lim and math.abs(gy) <= lim and math.abs(gz) <= lim
    end

    if allow then
        local alpha = dt_sec / (REST_FILTER_TAU_SEC + dt_sec)
        if alpha < 0 then
            alpha = 0
        elseif alpha > 1 then
            alpha = 1
        end
        for i = 1, 3 do
            h.bias.rest_gyro_lp[i] = h.bias.rest_gyro_lp[i]
                + alpha * (gyro[i] - h.bias.rest_gyro_lp[i])
            h.bias.rest_acc_lp[i] = h.bias.rest_acc_lp[i]
                + alpha * (accel[i] - h.bias.rest_acc_lp[i])
        end

        local gdx = gyro[1] - h.bias.rest_gyro_lp[1]
        local gdy = gyro[2] - h.bias.rest_gyro_lp[2]
        local gdz = gyro[3] - h.bias.rest_gyro_lp[3]
        local gyro_dev = math.sqrt(gdx * gdx + gdy * gdy + gdz * gdz)

        local adx = accel[1] - h.bias.rest_acc_lp[1]
        local ady = accel[2] - h.bias.rest_acc_lp[2]
        local adz = accel[3] - h.bias.rest_acc_lp[3]
        local acc_dev = math.sqrt(adx * adx + ady * ady + adz * adz)

        if gyro_dev < REST_GYRO_THRESHOLD_DPS and acc_dev < REST_ACC_THRESHOLD_G then
            h.bias.rest_time_sec = h.bias.rest_time_sec + dt_sec
            if h.bias.rest_time_sec >= REST_MIN_TIME_SEC then
                h.bias.rest_detected = true
            end
        else
            h.bias.rest_time_sec = 0.0
            h.bias.rest_detected = false
        end
    end

    if not prev_rest and h.bias.rest_detected then
        h.bias.bias_gyro_lp[1] = gyro[1]
        h.bias.bias_gyro_lp[2] = gyro[2]
        h.bias.bias_gyro_lp[3] = gyro[3]
        h.bias.bias_lp_valid = true
    elseif not h.bias.rest_detected then
        h.bias.bias_lp_valid = false
    end

    if h.bias.rest_detected and h.bias.bias_lp_valid then
        local beta = dt_sec / (BIAS_FILTER_TAU_SEC + dt_sec)
        if beta < 0 then
            beta = 0
        elseif beta > 1 then
            beta = 1
        end
        for i = 1, 3 do
            h.bias.bias_gyro_lp[i] = h.bias.bias_gyro_lp[i]
                + beta * (gyro[i] - h.bias.bias_gyro_lp[i])
        end

        local bias_clip = BIAS_CLIP_DPS * DEG2RAD
        for i = 1, 3 do
            local gyro_lp_rad = h.bias.bias_gyro_lp[i] * DEG2RAD
            local bias_err = gyro_lp_rad - h.bias.gyro_bias[i]
            h.bias.gyro_bias[i] = h.bias.gyro_bias[i] + BIAS_REST_GAIN * bias_err * dt_sec
            if h.bias.gyro_bias[i] > bias_clip then
                h.bias.gyro_bias[i] = bias_clip
            elseif h.bias.gyro_bias[i] < -bias_clip then
                h.bias.gyro_bias[i] = -bias_clip
            end
        end
    end
end

local function handle_gyro_guard(h, accel, gyro, now_us, dt_sec)
    if not h.config.gyro_guard_enabled then
        return false
    end

    local gx = gyro[1] - h.bias.gyro_bias[1] * RAD2DEG
    local gy = gyro[2] - h.bias.gyro_bias[2] * RAD2DEG
    local gz = gyro[3] - h.bias.gyro_bias[3] * RAD2DEG
    local lim = h.config.gyro_guard_limit_dps
    local over = math.abs(gx) > lim or math.abs(gy) > lim or math.abs(gz) > lim
    local recovered = math.abs(gx) < GYRO_RECOVER_DPS
        and math.abs(gy) < GYRO_RECOVER_DPS
        and math.abs(gz) < GYRO_RECOVER_DPS

    local reinit_window_sec = GYRO_REINIT_WINDOW_MS / 1000.0
    local recover_window_sec = GYRO_RECOVER_WINDOW_MS / 1000.0

    if over then
        h.gyro_guard.gyro_over_limit_time_sec = h.gyro_guard.gyro_over_limit_time_sec + dt_sec
        h.gyro_guard.gyro_recover_time_sec = 0.0
        if not h.gyro_guard.gyro_reinit_armed
            and h.gyro_guard.gyro_over_limit_time_sec >= reinit_window_sec then
            h.gyro_guard.gyro_reinit_armed = true
        end
    end

    if h.gyro_guard.gyro_reinit_armed then
        if recovered then
            h.gyro_guard.gyro_recover_time_sec = h.gyro_guard.gyro_recover_time_sec + dt_sec
            if h.gyro_guard.gyro_recover_time_sec >= recover_window_sec then
                if not reinitialize_from_sample(h, accel, gyro, now_us) then
                    return false
                end
                return true
            end
        else
            h.gyro_guard.gyro_recover_time_sec = 0.0
        end
    end

    if not over and not h.gyro_guard.gyro_reinit_armed then
        h.gyro_guard.gyro_over_limit_time_sec = 0.0
        h.gyro_guard.gyro_recover_time_sec = 0.0
    end

    return false
end

local function complementary_update(h, accel, gyro, dt_sec)
    local qw, qx, qy, qz = h.q.w, h.q.x, h.q.y, h.q.z
    local gx = gyro[1] * DEG2RAD - h.bias.gyro_bias[1]
    local gy = gyro[2] * DEG2RAD - h.bias.gyro_bias[2]
    local gz = gyro[3] * DEG2RAD - h.bias.gyro_bias[3]

    local dq_w, dq_x, dq_y, dq_z = quat_multiply(qw, qx, qy, qz, 0, gx, gy, gz)
    qw = qw + 0.5 * dq_w * dt_sec
    qx = qx + 0.5 * dq_x * dt_sec
    qy = qy + 0.5 * dq_y * dt_sec
    qz = qz + 0.5 * dq_z * dt_sec
    local qtmp = { w = qw, x = qx, y = qy, z = qz }
    quat_normalize(qtmp)
    qw, qx, qy, qz = qtmp.w, qtmp.x, qtmp.y, qtmp.z

    local measured_up = { accel[1], accel[2], accel[3] }
    local acc_norm = vec_norm3(measured_up)
    if acc_norm <= 0.85 or acc_norm >= 1.15 then
        h.q.w, h.q.x, h.q.y, h.q.z = qw, qx, qy, qz
        return
    end

    vec_normalize3(measured_up)

    local predicted_up = { 0, 0, 0 }
    rotate_vec_transpose(qw, qx, qy, qz, h.up_ref, predicted_up)
    vec_normalize3(predicted_up)

    local error = { 0, 0, 0 }
    vec_cross3(measured_up, predicted_up, error)

    if h.runtime_gain.warming_up then
        h.runtime_gain.live_gain = h.runtime_gain.live_gain
            - h.runtime_gain.gain_drop_per_sec * dt_sec
        if h.runtime_gain.live_gain <= h.runtime_gain.steady_gain
            or h.runtime_gain.steady_gain <= 0.0 then
            h.runtime_gain.live_gain = h.runtime_gain.steady_gain
            h.runtime_gain.warming_up = false
        end
    end

    local gain = h.runtime_gain.live_gain
    local gx_corr = gx + gain * error[1]
    local gy_corr = gy + gain * error[2]
    local gz_corr = gz + gain * error[3]

    qw, qx, qy, qz = h.q.w, h.q.x, h.q.y, h.q.z
    dq_w, dq_x, dq_y, dq_z = quat_multiply(qw, qx, qy, qz, 0, gx_corr, gy_corr, gz_corr)
    qw = qw + 0.5 * dq_w * dt_sec
    qx = qx + 0.5 * dq_x * dt_sec
    qy = qy + 0.5 * dq_y * dt_sec
    qz = qz + 0.5 * dq_z * dt_sec
    qtmp = { w = qw, x = qx, y = qy, z = qz }
    quat_normalize(qtmp)
    h.q.w, h.q.x, h.q.y, h.q.z = qtmp.w, qtmp.x, qtmp.y, qtmp.z
end

function M.default_config()
    return {
        init_strategy = M.INIT_CURRENT_POSE,
        accel_target_axis = M.AXIS_POS_Z,
        heading_ref_body = { -1.0, 0.0, 0.0 },
        heading_target_axis = M.AXIS_NEG_X,
        gyro_bias_enabled = true,
        gyro_guard_enabled = true,
        gyro_guard_limit_dps = 150.0,
    }
end

function M.create(config)
    local cfg = M.default_config()
    if config then
        for k, v in pairs(config) do
            cfg[k] = v
        end
    end

    local h = {
        config = cfg,
        q = { w = 1, x = 0, y = 0, z = 0 },
        up_ref = { 0, 0, 1 },
        last_timestamp_us = 0,
        runtime_gain = {
            warming_up = false,
            steady_gain = FEEDBACK_GAIN,
            live_gain = FEEDBACK_GAIN,
            gain_drop_per_sec = 0,
        },
        bias = {
            rest_detected = false,
            bias_lp_valid = false,
            rest_time_sec = 0,
            gyro_bias = { 0, 0, 0 },
            rest_gyro_lp = { 0, 0, 0 },
            rest_acc_lp = { 0, 0, 0 },
            bias_gyro_lp = { 0, 0, 0 },
        },
        gyro_guard = {
            gyro_over_limit_time_sec = 0,
            gyro_recover_time_sec = 0,
            gyro_reinit_armed = false,
        },
    }
    reset_solver_runtime(h)
    return h
end

function M.reset_state(h)
    h.q.w, h.q.x, h.q.y, h.q.z = 1, 0, 0, 0
    h.up_ref[1], h.up_ref[2], h.up_ref[3] = 0, 0, 1
    h.last_timestamp_us = 0
    h.bias.gyro_bias[1], h.bias.gyro_bias[2], h.bias.gyro_bias[3] = 0, 0, 0
    h.bias.rest_detected = false
    h.bias.bias_lp_valid = false
    h.bias.rest_time_sec = 0
    h.gyro_guard.gyro_over_limit_time_sec = 0
    h.gyro_guard.gyro_recover_time_sec = 0
    h.gyro_guard.gyro_reinit_armed = false
    for i = 1, 3 do
        h.bias.rest_gyro_lp[i] = 0
        h.bias.rest_acc_lp[i] = 0
        h.bias.bias_gyro_lp[i] = 0
    end
    reset_solver_runtime(h)
end

function M.set_config(h, config)
    for k, v in pairs(config) do
        h.config[k] = v
    end
end

--- Update quaternion from one IMU sample.
--- @param accel table {ax, ay, az} in g
--- @param gyro table {gx, gy, gz} in deg/s
--- @param timestamp_us number
--- @return table { updated, reinitialized, rest_detected, q_w, q_x, q_y, q_z } or nil, err
function M.update(h, accel, gyro, timestamp_us)
    local out = {
        updated = false,
        reinitialized = false,
        rest_detected = false,
        q_w = h.q.w,
        q_x = h.q.x,
        q_y = h.q.y,
        q_z = h.q.z,
    }

    if h.last_timestamp_us == 0 then
        if not reinitialize_from_sample(h, accel, gyro, timestamp_us) then
            return nil, "reinit failed"
        end
        out.q_w, out.q_x, out.q_y, out.q_z = h.q.w, h.q.x, h.q.y, h.q.z
        out.rest_detected = h.bias.rest_detected
        return out
    end

    local dt_us = timestamp_us - h.last_timestamp_us
    h.last_timestamp_us = timestamp_us
    if dt_us <= 0 then
        return nil, "invalid dt"
    end
    if dt_us > 100000 then
        dt_us = 100000
    end
    local dt_sec = dt_us * 1e-6

    local reinitialized = handle_gyro_guard(h, accel, gyro, timestamp_us, dt_sec)
    if reinitialized then
        out.reinitialized = true
        out.q_w, out.q_x, out.q_y, out.q_z = h.q.w, h.q.x, h.q.y, h.q.z
        out.rest_detected = h.bias.rest_detected
        return out
    end

    update_rest_bias(h, accel, gyro, dt_sec)
    complementary_update(h, accel, gyro, dt_sec)

    out.updated = true
    out.q_w, out.q_x, out.q_y, out.q_z = h.q.w, h.q.x, h.q.y, h.q.z
    out.rest_detected = h.bias.rest_detected
    return out
end

function M.rotate_body_to_world(h, v_body, v_world)
    v_world = v_world or { 0, 0, 0 }
    rotate_vec(h.q.w, h.q.x, h.q.y, h.q.z, v_body, v_world)
    return v_world
end

M.vec_normalize3 = vec_normalize3
M.vec_dot3 = vec_dot3
M.vec_norm3 = vec_norm3

return M
