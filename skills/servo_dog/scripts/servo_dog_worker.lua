local delay = require("delay")
local json = require("json")
local mcpwm = require("mcpwm")
local storage = require("storage")
local thread = require("thread")

local sync = thread.sync

local DEFAULT_QUEUE = "servo_dog_cmd"
local DEFAULT_GPIOS = { fl = 1, fr = 2, bl = 41, br = 42 }
local DEFAULT_NEUTRAL = { fl = 70, fr = 110, bl = 110, br = 70 }
local DEFAULT_MIN_PULSE_US = 500
local DEFAULT_MAX_PULSE_US = 2500
local DEFAULT_FREQUENCY_HZ = 50
local DEFAULT_CONFIG_DIR = "servo_dog"
local DEFAULT_CONFIG_FILE = "config.json"

local BOW_OFFSET = 50
local STEP_OFFSET = 5

local raw_args = type(args) == "table" and args or {}
local queue_name = type(raw_args.queue_name) == "string" and raw_args.queue_name ~= "" and raw_args.queue_name or DEFAULT_QUEUE

local cfg = {
    gpios = {
        fl = tonumber(raw_args.fl_gpio) or DEFAULT_GPIOS.fl,
        fr = tonumber(raw_args.fr_gpio) or DEFAULT_GPIOS.fr,
        bl = tonumber(raw_args.bl_gpio) or DEFAULT_GPIOS.bl,
        br = tonumber(raw_args.br_gpio) or DEFAULT_GPIOS.br,
    },
    neutral = {
        fl = tonumber(raw_args.fl_neutral) or DEFAULT_NEUTRAL.fl,
        fr = tonumber(raw_args.fr_neutral) or DEFAULT_NEUTRAL.fr,
        bl = tonumber(raw_args.bl_neutral) or DEFAULT_NEUTRAL.bl,
        br = tonumber(raw_args.br_neutral) or DEFAULT_NEUTRAL.br,
    },
    offset = { fl = 0, fr = 0, bl = 0, br = 0 },
    min_pulse_us = tonumber(raw_args.min_pulse_us) or DEFAULT_MIN_PULSE_US,
    max_pulse_us = tonumber(raw_args.max_pulse_us) or DEFAULT_MAX_PULSE_US,
    frequency_hz = tonumber(raw_args.frequency_hz) or DEFAULT_FREQUENCY_HZ,
}

local pwm_front
local pwm_back
local pending_cmd

local function config_path()
    local root = storage.get_root_dir()
    local dir = storage.join_path(root, DEFAULT_CONFIG_DIR)
    pcall(storage.mkdir, dir)
    return storage.join_path(dir, DEFAULT_CONFIG_FILE)
end

local function load_config()
    local path = config_path()
    if not storage.exists(path) then
        return
    end

    local text = storage.read_file(path)
    local ok, data = pcall(json.decode, text)
    if not ok or type(data) ~= "table" then
        return
    end

    if type(data.offset) == "table" then
        for _, leg in ipairs({ "fl", "fr", "bl", "br" }) do
            cfg.offset[leg] = tonumber(data.offset[leg]) or cfg.offset[leg]
        end
    end
end

local function save_config()
    storage.write_file(config_path(), json.encode({ offset = cfg.offset }))
end

local function clamp(value, min_value, max_value)
    if value < min_value then
        return min_value
    end
    if value > max_value then
        return max_value
    end
    return value
end

local function neutral(leg)
    return cfg.neutral[leg] + cfg.offset[leg]
end

local function angle_to_duty_percent(angle)
    local clamped = clamp(angle, 0, 180)
    local pulse_width_us = cfg.min_pulse_us + (cfg.max_pulse_us - cfg.min_pulse_us) * clamped / 180
    return pulse_width_us * cfg.frequency_hz / 10000
end

local function set_angle(leg, angle)
    local duty = angle_to_duty_percent(angle)
    if leg == "fl" then
        pwm_front:set_duty(1, duty)
    elseif leg == "fr" then
        pwm_front:set_duty(2, duty)
    elseif leg == "bl" then
        pwm_back:set_duty(1, duty)
    elseif leg == "br" then
        pwm_back:set_duty(2, duty)
    end
end

local function set_angles(angles)
    if angles.fl then set_angle("fl", angles.fl) end
    if angles.fr then set_angle("fr", angles.fr) end
    if angles.bl then set_angle("bl", angles.bl) end
    if angles.br then set_angle("br", angles.br) end
end

local function poll_command(timeout_ms)
    local msg, err = sync.queue_recv(queue_name, timeout_ms)
    if not msg then
        return nil, err
    end

    local ok, data = pcall(json.decode, msg)
    if ok and type(data) == "table" then
        return data
    end
    return nil, "invalid"
end

local function action_delay(ms)
    local cmd, err = poll_command(math.max(0, math.floor(ms or 0)))
    if err == "stopped" then
        error("stopped")
    end
    if cmd then
        pending_cmd = cmd
        return false
    end
    return true
end

local function neutral_pose(action_args)
    local angle_offset = tonumber(action_args and action_args.angle_offset) or 0
    set_angles({
        fl = neutral("fl") + angle_offset,
        fr = neutral("fr") - angle_offset,
        bl = neutral("bl") - angle_offset,
        br = neutral("br") + angle_offset,
    })
    return action_delay(20)
end

local function installation()
    set_angles({
        fl = neutral("fl") - 70,
        fr = neutral("fr") + 70,
        bl = neutral("bl") + 70,
        br = neutral("br") - 70,
    })
    return action_delay(200)
end

local function step_delay(action_args)
    local speed = tonumber(action_args.speed) or 80
    if speed <= 0 then
        speed = 80
    end
    return math.max(1, math.floor(500 / speed))
end

local function forward(action_args)
    local repeat_count = tonumber(action_args.repeat_count) or 2
    local d = step_delay(action_args)
    local fl, fr, bl, br = neutral("fl"), neutral("fr"), neutral("bl"), neutral("br")

    for _ = 1, repeat_count do
        for i = 0, 39 do
            set_angles({ fl = fl + 20 - i, br = br - 20 + i, bl = bl - 20 + i - STEP_OFFSET, fr = fr + 20 - i - STEP_OFFSET })
            if not action_delay(d) then return end
        end
        if not action_delay(50) then return end
        for i = 0, 39 do
            set_angles({ fl = fl - 20 + i, br = br + 20 - i, bl = bl + 20 - i + STEP_OFFSET, fr = fr - 20 + i + STEP_OFFSET })
            if not action_delay(d) then return end
        end
        if not action_delay(50) then return end
    end

    for i = 0, 19 do
        set_angles({ fl = fl + 20 - i, br = br - 20 + i, bl = bl - 20 + i, fr = fr + 20 - i })
        if not action_delay(d) then return end
    end
end

local function backward(action_args)
    local repeat_count = tonumber(action_args.repeat_count) or 2
    local d = step_delay(action_args)
    local fl, fr, bl, br = neutral("fl"), neutral("fr"), neutral("bl"), neutral("br")

    for _ = 1, repeat_count do
        for i = 0, 39 do
            set_angles({ bl = bl + 20 - i, fr = fr - 20 + i, fl = fl - 20 + i - STEP_OFFSET, br = br + 20 - i - STEP_OFFSET })
            if not action_delay(d) then return end
        end
        if not action_delay(50) then return end
        for i = 0, 39 do
            set_angles({ bl = bl - 20 + i, fr = fr + 20 - i, fl = fl + 20 - i + STEP_OFFSET, br = br - 20 + i + STEP_OFFSET })
            if not action_delay(d) then return end
        end
        if not action_delay(50) then return end
    end

    for i = 0, 19 do
        set_angles({ bl = bl + 20 - i, fr = fr - 20 + i, fl = fl - 20 + i, br = br + 20 - i })
        if not action_delay(d) then return end
    end
end

local function turn_left(action_args)
    local repeat_count = tonumber(action_args.repeat_count) or 2
    local d = step_delay(action_args)
    local fl, fr, bl, br = neutral("fl"), neutral("fr"), neutral("bl"), neutral("br")

    for _ = 1, repeat_count do
        for i = 0, 39 do
            set_angles({ fl = fl + 20 - i + STEP_OFFSET, br = br + 20 - i + STEP_OFFSET, bl = bl - 20 + i, fr = fr - 20 + i })
            if not action_delay(d) then return end
        end
        for i = 0, 39 do
            set_angles({ fl = fl - 20 + i - STEP_OFFSET, br = br - 20 + i - STEP_OFFSET, bl = bl + 20 - i, fr = fr + 20 - i })
            if not action_delay(d) then return end
        end
    end

    for i = 0, 19 do
        set_angles({ fl = fl + 20 - i, br = br + 20 - i, bl = bl - 20 + i, fr = fr - 20 + i })
        if not action_delay(d) then return end
    end
end

local function turn_right(action_args)
    local repeat_count = tonumber(action_args.repeat_count) or 2
    local d = step_delay(action_args)
    local fl, fr, bl, br = neutral("fl"), neutral("fr"), neutral("bl"), neutral("br")

    for _ = 1, repeat_count do
        for i = 0, 39 do
            set_angles({ fl = fl - 20 + i, br = br - 20 + i, bl = bl + 20 - i + STEP_OFFSET, fr = fr + 20 - i + STEP_OFFSET })
            if not action_delay(d) then return end
        end
        for i = 0, 39 do
            set_angles({ fl = fl + 20 - i - STEP_OFFSET, br = br + 20 - i - STEP_OFFSET, bl = bl - 20 + i, fr = fr - 20 + i })
            if not action_delay(d) then return end
        end
    end

    for i = 0, 19 do
        set_angles({ fl = fl - 20 + i, br = br - 20 + i, bl = bl + 20 - i, fr = fr + 20 - i })
        if not action_delay(d) then return end
    end
end

local function bow(action_args)
    local d = step_delay(action_args)
    local hold = tonumber(action_args.hold_time_ms) or 500
    local fl, fr, bl, br = neutral("fl"), neutral("fr"), neutral("bl"), neutral("br")

    for i = 0, BOW_OFFSET - 1 do
        set_angles({ fl = fl - i, fr = fr + i, bl = bl - i, br = br + i })
        if not action_delay(d) then return end
    end
    if not action_delay(hold) then return end
    for i = 0, BOW_OFFSET - 1 do
        set_angles({ fl = fl - BOW_OFFSET + i, fr = fr + BOW_OFFSET - i, bl = bl - BOW_OFFSET + i, br = br + BOW_OFFSET - i })
        if not action_delay(d) then return end
    end
end

local function lean_back(action_args)
    local d = step_delay(action_args)
    local hold = tonumber(action_args.hold_time_ms) or 500
    local fl, fr, bl, br = neutral("fl"), neutral("fr"), neutral("bl"), neutral("br")

    for i = 0, BOW_OFFSET - 1 do
        set_angles({ fl = fl + i, fr = fr - i, bl = bl + i, br = br - i })
        if not action_delay(d) then return end
    end
    if not action_delay(hold) then return end
    for i = 0, BOW_OFFSET - 1 do
        set_angles({ fl = fl + BOW_OFFSET - i, fr = fr - BOW_OFFSET + i, bl = bl + BOW_OFFSET - i, br = br - BOW_OFFSET + i })
        if not action_delay(d) then return end
    end
end

local function bow_and_lean_back(action_args)
    local d = step_delay(action_args)
    local repeat_count = tonumber(action_args.repeat_count) or 2
    local fl, fr, bl, br = neutral("fl"), neutral("fr"), neutral("bl"), neutral("br")

    for i = 0, BOW_OFFSET - 1 do
        set_angles({ fl = fl - i, fr = fr + i, bl = bl - i, br = br + i })
        if not action_delay(d) then return end
    end
    for _ = 1, repeat_count do
        for i = 0, BOW_OFFSET * 2 - 1 do
            set_angles({ fl = fl - BOW_OFFSET + i, fr = fr + BOW_OFFSET - i, bl = bl - BOW_OFFSET + i, br = br + BOW_OFFSET - i })
            if not action_delay(d) then return end
        end
        for i = 0, BOW_OFFSET * 2 - 1 do
            set_angles({ fl = fl + BOW_OFFSET - i, fr = fr - BOW_OFFSET + i, bl = bl + BOW_OFFSET - i, br = br - BOW_OFFSET + i })
            if not action_delay(d) then return end
        end
    end
    for i = 0, BOW_OFFSET - 1 do
        set_angles({ fl = fl - BOW_OFFSET + i, fr = fr + BOW_OFFSET - i, bl = bl - BOW_OFFSET + i, br = br + BOW_OFFSET - i })
        if not action_delay(d) then return end
    end
end

local function sway_back_and_forth()
    local fl, fr, bl, br = neutral("fl"), neutral("fr"), neutral("bl"), neutral("br")
    local sway_offset = 18
    for i = 0, sway_offset - 1 do
        set_angles({ fl = fl - i, fr = fr + i, bl = bl - i, br = br + i })
        if not action_delay(5) then return end
    end
    while sway_offset > 0 and sway_offset <= 18 do
        for i = 0, sway_offset * 2 - 1 do
            set_angles({ fl = fl - sway_offset + i, fr = fr + sway_offset - i, bl = bl - sway_offset + i, br = br + sway_offset - i })
            if not action_delay(5) then return end
        end
        for i = 0, sway_offset * 2 - 1 do
            set_angles({ fl = fl + sway_offset - i, fr = fr - sway_offset + i, bl = bl + sway_offset - i, br = br - sway_offset + i })
            if not action_delay(5) then return end
        end
        sway_offset = sway_offset - 3
    end
end

local function lay_down()
    local fl, fr, bl, br = neutral("fl"), neutral("fr"), neutral("bl"), neutral("br")
    for i = 0, 59 do
        set_angles({ fl = fl - i, fr = fr + i, bl = bl + i, br = br - i })
        if not action_delay(10) then return end
    end
end

local function sway_left_right(action_args)
    local d = step_delay(action_args)
    local repeat_count = tonumber(action_args.repeat_count) or 2
    local angle_offset = tonumber(action_args.angle_offset) or 20
    local fl, fr, bl, br = neutral("fl"), neutral("fr"), neutral("bl"), neutral("br")

    neutral_pose({ angle_offset = 20 })
    for _ = 1, repeat_count do
        for i = 0, angle_offset - 1 do
            set_angles({ fl = fl + 20 - i, fr = fr - 20 - i, bl = bl - 20 - i, br = br + 20 - i })
            if not action_delay(d) then return end
        end
        for i = 0, angle_offset * 2 - 1 do
            set_angles({ fl = fl + 20 - angle_offset + i, fr = fr - 20 - angle_offset + i, bl = bl - 20 - angle_offset + i, br = br + 20 - angle_offset + i })
            if not action_delay(d) then return end
        end
        for i = 0, angle_offset - 1 do
            set_angles({ fl = fl + 20 + angle_offset - i, fr = fr - 20 + angle_offset - i, bl = bl - 20 + angle_offset - i, br = br + 20 + angle_offset - i })
            if not action_delay(d) then return end
        end
    end
end

local function shake_hand(action_args)
    local repeat_count = tonumber(action_args.repeat_count) or 10
    local hold = tonumber(action_args.hold_time_ms) or 3000
    local fr, bl, br = neutral("fr"), neutral("bl"), neutral("br")

    for i = 0, 59 do
        set_angles({ bl = bl - i, br = br + i })
        if not action_delay(8) then return end
    end
    local start_angle = fr + 72
    local end_angle = fr + 57
    set_angle("fr", start_angle)
    for _ = 1, repeat_count do
        for angle = start_angle, end_angle, -1 do
            set_angle("fr", angle)
            if not action_delay(15) then return end
        end
        for angle = end_angle, start_angle do
            set_angle("fr", angle)
            if not action_delay(15) then return end
        end
    end
    if not action_delay(hold) then return end
    for angle = start_angle, fr, -1 do
        set_angle("fr", angle)
        if not action_delay(5) then return end
    end
    for i = 0, 59 do
        set_angles({ bl = bl - 60 + i, br = br + 60 - i })
        if not action_delay(8) then return end
    end
end

local function jump_forward(action_args)
    local fl, fr, bl, br = neutral("fl"), neutral("fr"), neutral("bl"), neutral("br")
    neutral_pose(action_args)
    if not action_delay(300) then return end
    set_angles({ fl = fl - 30, fr = fr + 30, bl = bl - 60, br = br + 60 })
    if not action_delay(300) then return end
    set_angles({ fl = fl + 70, fr = fr - 70 })
    if not action_delay(40) then return end
    set_angles({ fl = fl - 70, fr = fr + 70 })
    if not action_delay(20) then return end
    set_angles({ bl = bl + 20, br = br - 20 })
    if not action_delay(150) then return end
    set_angles({ fl = fl, fr = fr })
    action_delay(200)
end

local function jump_backward(action_args)
    local fl, fr, bl, br = neutral("fl"), neutral("fr"), neutral("bl"), neutral("br")
    set_angles({ fl = fl + 40, fr = fr - 40, bl = bl + 20, br = br - 20 })
    if not action_delay(100) then return end
    set_angles({ fl = fl + 20, fr = fr - 20, bl = bl - 20, br = br + 20 })
    if not action_delay(100) then return end
    set_angles({ fl = fl, fr = fr, bl = bl + 20, br = br - 20 })
    if not action_delay(150) then return end
    neutral_pose(action_args)
end

local function poke(action_args)
    local fr, bl, br = neutral("fr"), neutral("bl"), neutral("br")
    set_angle("fl", 0)
    if not action_delay(20) then return end
    for i = 0, 4 do
        set_angles({ fr = fr + i, bl = bl - 10 * i, br = br + 10 * i })
        if not action_delay(10) then return end
    end
    for _ = 1, 2 do
        for i = 0, 19 do
            set_angles({ fr = fr + 5 + i, bl = bl - 50 - i, br = br + 50 + i })
            if not action_delay(20) then return end
        end
        for i = 0, 19 do
            set_angles({ fr = fr + 25 - i, bl = bl - 70 + i, br = br + 70 - i })
            if not action_delay(20) then return end
        end
    end
    neutral_pose(action_args)
end

local function shake_back_legs()
    local fl, fr, bl, br = neutral("fl"), neutral("fr"), neutral("bl"), neutral("br")
    for i = 0, 17 do
        set_angles({ fl = fl + 2 * i, fr = fr - 2 * i, bl = bl + 3 * i, br = br - 3 * i })
        if not action_delay(15) then return end
    end
    for _ = 1, 12 do
        for i = 0, 5 do
            set_angles({ bl = bl + 54 + i, br = br - 54 + i })
            if not action_delay(7) then return end
        end
        for i = 0, 11 do
            set_angles({ bl = bl + 54 - i, br = br - 54 - i })
            if not action_delay(7) then return end
        end
        for i = 0, 5 do
            set_angles({ bl = bl + 54 + i, br = br - 54 + i })
            if not action_delay(7) then return end
        end
    end
    for i = 0, 17 do
        set_angles({ fl = fl + 36 - 2 * i, fr = fr - 36 + 2 * i, bl = bl + 54 - 3 * i, br = br - 54 + 3 * i })
        if not action_delay(15) then return end
    end
end

local function retract_legs()
    local fl, fr, bl, br = neutral("fl"), neutral("fr"), neutral("bl"), neutral("br")
    for i = 0, 109 do
        set_angles({ fl = fl + i, fr = fr - i })
        if not action_delay(4) then return end
    end
    for i = 0, 102 do
        set_angles({ bl = bl - i, br = br + i })
        if not action_delay(4) then return end
    end
end

local actions = {
    installation = { fn = installation },
    idle = { fn = neutral_pose, args = { angle_offset = 0 } },
    forward = { fn = forward, args = { repeat_count = 2, speed = 80 } },
    backward = { fn = backward, args = { repeat_count = 2, speed = 80 } },
    turn_right = { fn = turn_right, args = { repeat_count = 2, speed = 80 } },
    turn_left = { fn = turn_left, args = { repeat_count = 2, speed = 80 } },
    lay_down = { fn = lay_down },
    bow = { fn = bow, args = { speed = 80, hold_time_ms = 500 } },
    lean_back = { fn = lean_back, args = { speed = 80, hold_time_ms = 500 } },
    bow_lean = { fn = bow_and_lean_back, args = { repeat_count = 2, speed = 80 } },
    sway_back_forth = { fn = sway_back_and_forth },
    sway = { fn = sway_left_right, args = { repeat_count = 2, speed = 40, angle_offset = 20 } },
    shake_hand = { fn = shake_hand, args = { repeat_count = 10, hold_time_ms = 3000 } },
    poke = { fn = poke },
    shake_back_legs = { fn = shake_back_legs },
    jump_forward = { fn = jump_forward },
    jump_backward = { fn = jump_backward },
    retract_legs = { fn = retract_legs },
}

local action_aliases = {
    F = "forward",
    B = "backward",
    L = "turn_left",
    R = "turn_right",
    ["1"] = "lay_down",
    ["2"] = "bow",
    ["3"] = "lean_back",
    ["4"] = "bow_lean",
    ["5"] = "sway_back_forth",
    ["6"] = "sway",
    ["7"] = "shake_hand",
    ["8"] = "poke",
    ["9"] = "shake_back_legs",
    ["10"] = "jump_forward",
    ["11"] = "jump_backward",
    ["12"] = "retract_legs",
}

local function merge_args(base, override)
    local out = {}
    if type(base) == "table" then
        for k, v in pairs(base) do out[k] = v end
    end
    if type(override) == "table" then
        for k, v in pairs(override) do out[k] = v end
    end
    return out
end

local function resolve_action(cmd)
    local name = cmd.action or cmd.move or cmd.name
    if type(name) == "number" then
        name = tostring(math.floor(name))
    end
    if type(name) ~= "string" then
        return nil
    end
    return action_aliases[name] or name
end

local function run_action(name, action_args)
    local entry = actions[name]
    if not entry then
        print("[servo_dog] unknown action: " .. tostring(name))
        return
    end
    print("[servo_dog] action: " .. name)
    entry.fn(merge_args(entry.args, action_args))
end

local function adjust(cmd)
    local leg = cmd.servo or cmd.leg
    local value = tonumber(cmd.value)
    if not cfg.offset[leg] or value == nil then
        print("[servo_dog] invalid adjust command")
        return
    end
    cfg.offset[leg] = clamp(math.floor(value), -25, 25)
    save_config()
    installation()
end

local function direct_angles(cmd)
    if type(cmd.angles) ~= "table" then
        return
    end
    set_angles({
        fl = tonumber(cmd.angles.fl),
        fr = tonumber(cmd.angles.fr),
        bl = tonumber(cmd.angles.bl),
        br = tonumber(cmd.angles.br),
    })
end

local function handle_command(cmd)
    if cmd.type == "adjust" then
        adjust(cmd)
        return
    end
    if cmd.type == "angles" then
        direct_angles(cmd)
        return
    end
    if cmd.type == "save_offsets" and type(cmd.offset) == "table" then
        for _, leg in ipairs({ "fl", "fr", "bl", "br" }) do
            cfg.offset[leg] = clamp(math.floor(tonumber(cmd.offset[leg]) or cfg.offset[leg]), -25, 25)
        end
        save_config()
        installation()
        return
    end
    if cmd.type == "stop" then
        neutral_pose({ angle_offset = 0 })
        return
    end

    local name = resolve_action(cmd)
    if name then
        run_action(name, cmd.args)
    end
end

local function cleanup()
    if pwm_front then
        pcall(pwm_front.stop, pwm_front)
        pcall(pwm_front.close, pwm_front)
        pwm_front = nil
    end
    if pwm_back then
        pcall(pwm_back.stop, pwm_back)
        pcall(pwm_back.close, pwm_back)
        pwm_back = nil
    end
end

local function run()
    load_config()
    pwm_front = mcpwm.new({
        gpio = cfg.gpios.fl,
        gpio_b = cfg.gpios.fr,
        frequency_hz = cfg.frequency_hz,
        duty_percent = angle_to_duty_percent(neutral("fl")),
        duty_percent_b = angle_to_duty_percent(neutral("fr")),
    })
    pwm_back = mcpwm.new({
        gpio = cfg.gpios.bl,
        gpio_b = cfg.gpios.br,
        frequency_hz = cfg.frequency_hz,
        duty_percent = angle_to_duty_percent(neutral("bl")),
        duty_percent_b = angle_to_duty_percent(neutral("br")),
    })
    pwm_front:start()
    pwm_back:start()
    neutral_pose({ angle_offset = 0 })
    print(string.format("[servo_dog] worker ready queue=%s gpios=%d,%d,%d,%d",
        queue_name, cfg.gpios.fl, cfg.gpios.fr, cfg.gpios.bl, cfg.gpios.br))

    while true do
        local cmd = pending_cmd
        pending_cmd = nil
        if not cmd then
            local err
            cmd, err = poll_command(1000)
            if err == "stopped" then
                return
            end
        end
        if cmd then
            handle_command(cmd)
        end
    end
end

local ok, err = xpcall(run, debug.traceback)
cleanup()
if not ok then
    if tostring(err):find("stopped", 1, true) then
        print("[servo_dog] worker stopped")
        return
    end
    print("[servo_dog] ERROR: " .. tostring(err))
    error(err)
end
