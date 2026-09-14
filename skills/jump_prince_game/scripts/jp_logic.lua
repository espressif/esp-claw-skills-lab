-- logic.lua: pure gameplay/physics state machine for Jump Prince.
-- Faithful Lua port of factory_demo ui/jump_prince_game.c (esp32s31-game-center).
-- Original Jump Prince by Jakub Tomsu, copyright (c) 2013-2024.
-- No LVGL or hardware dependencies; rendering lives in the entry script.

local M = {}

M.MAP_W = 16
M.MAP_H = 12

M.STATE_STOPPED = 0
M.STATE_RUNNING = 1
M.STATE_PAUSED = 2

-- Tuning constants (identical values to the C port).
local SCREEN_COUNT = 6
local PLAYER_HALF_W = 0.3
local PLAYER_HALF_H = 0.4
local GRAVITY = 30.0
local SPEED = 200.0
local JUMP_STRENGTH = 15.0
-- Side-jump horizontal impulse (independent of up). Charged right jump
-- must clear the first-stage ~4-tile gap that normalize() used to miss.
local JUMP_SIDE = 7.0
local JUMP_UP_SIDE = 1.12
local BOUNCE_FACTOR_X = 0.45
local SCREEN_EDGE_EPSILON = 0.001
local MAX_FRAME_DELTA = 0.1
local MAX_PHYSICS_STEP = 0.008

-- Tilemaps: '#' solid, ' ' empty; one string per row.
local TILEMAPS = {
    [0] = {
        "",
    },
    [1] = {
        "################",
        "#              #",
        "# #### #### #  #",
        "# #    #    #  #",
        "# # ## # ## #  #",
        "# #  # #  #    #",
        "# #### #### #  #",
        "#              #",
        "#              #",
        "#              #",
        "#              #",
        "#########      #",
    },
    [2] = {
        "#########      #",
        "#########    ###",
        "########      ##",
        "########      ##",
        "##########     #",
        "##########     #",
        "########      ##",
        "########      ##",
        "##########    ##",
        "######        ##",
        "###           ##",
        "###         ####",
    },
    [3] = {
        "###         ####",
        "###    ###  ####",
        "###         ####",
        "###          ###",
        "#####        ###",
        "###          ###",
        "#            ###",
        "##        ######",
        "##         #####",
        "##         #####",
        "######     #####",
        "#####      #####",
    },
    [4] = {
        "#####      #####",
        "###      #######",
        "##        ######",
        "##          ####",
        "######      ####",
        "######       ###",
        "######   #   ###",
        "#####    ##  ###",
        "#####        ###",
        "##           ###",
        "##        ######",
        "##    ##########",
    },
    [5] = {
        "##    ##########",
        "##            ##",
        "####          ##",
        "########       #",
        "#####          #",
        "##             #",
        "##       #######",
        "#        #######",
        "#         ######",
        "#####     ######",
        "#####     ######",
        "################",
    },
}

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function vec2_len(v)
    return math.sqrt(v.x * v.x + v.y * v.y)
end

local function vec2_normalize(v)
    local len = vec2_len(v)
    if len <= 0.0001 then
        return { x = 0.0, y = 0.0 }
    end
    return { x = v.x / len, y = v.y / len }
end

local function floor_to_int(v)
    -- Matches C float->int truncation toward negative infinity.
    return math.floor(v)
end

local function get_screen_height_index(y)
    return floor_to_int(-y / M.MAP_H)
end

local function get_screen_info(y)
    local height_index = get_screen_height_index(y)
    local screen_index = SCREEN_COUNT - height_index - 2
    if screen_index < 0 or screen_index >= SCREEN_COUNT then
        screen_index = 0
    end
    return {
        screen_index = screen_index,
        screen_offset_y = -(height_index + 1) * M.MAP_H,
    }
end

local function get_motion_screen_info(game)
    local y = game.position.y
    if game.is_on_ground or game.velocity.y > 0.0 then
        y = y + PLAYER_HALF_H + SCREEN_EDGE_EPSILON
    elseif game.velocity.y < 0.0 then
        y = y - PLAYER_HALF_H - SCREEN_EDGE_EPSILON
    end
    return get_screen_info(y)
end

local function apply_screen_info(game, info)
    game.screen_index = info.screen_index
    game.screen_offset_y = info.screen_offset_y
end

local function update_screen(game)
    apply_screen_info(game, get_motion_screen_info(game))
end


function M.get_tile_from_map(map_index, x, y, full_outside)
    if full_outside then
        if x < 0 or x >= M.MAP_W or y < 0 or y >= M.MAP_H then
            return '#'
        end
    else
        if x < 0 or x >= M.MAP_W then
            return '#'
        end
        if y < 0 or y >= M.MAP_H then
            return ' '
        end
    end

    if map_index < 0 or map_index >= SCREEN_COUNT then
        return ' '
    end
    local row = TILEMAPS[map_index][y + 1]
    if not row or #row == 0 then
        return ' '
    end
    local c = row:sub(x + 1, x + 1)
    if c == "" then
        return ' '
    end
    return c
end

local function tile_full_in_screen(screen_index, x, y)
    return M.get_tile_from_map(screen_index, x, y, false) == '#'
end

local function tile_full_at(game, x, y)
    return tile_full_in_screen(game.screen_index, x, y)
end

local function box_colliding_with_tilemap(game, center, size)
    center = { x = center.x, y = center.y - game.screen_offset_y }

    local start_x = floor_to_int(center.x - size.x)
    local start_y = floor_to_int(center.y - size.y)
    local end_x = floor_to_int(center.x + size.x)
    local end_y = floor_to_int(center.y + size.y)

    for x = start_x, end_x do
        for y = start_y, end_y do
            if tile_full_at(game, x, y) then
                local box_pos_x = 0.5 + x
                local box_pos_y = 0.5 + y
                local sum_x = size.x + 0.5
                local sum_y = size.y + 0.5
                local dist_x = math.abs(center.x - box_pos_x) - sum_x
                local dist_y = math.abs(center.y - box_pos_y) - sum_y
                if dist_x <= 0.0 and dist_y <= 0.0 then
                    return true
                end
            end
        end
    end
    return false
end

local function box_colliding_with_screen(screen_index, tilemap_height, center, size)
    center = { x = center.x, y = center.y - tilemap_height }

    local start_x = floor_to_int(center.x - size.x)
    local start_y = floor_to_int(center.y - size.y)
    local end_x = floor_to_int(center.x + size.x)
    local end_y = floor_to_int(center.y + size.y)

    for x = start_x, end_x do
        for y = start_y, end_y do
            if tile_full_in_screen(screen_index, x, y) then
                local box_pos_x = 0.5 + x
                local box_pos_y = 0.5 + y
                local sum_x = size.x + 0.5
                local sum_y = size.y + 0.5
                local dist_x = math.abs(center.x - box_pos_x) - sum_x
                local dist_y = math.abs(center.y - box_pos_y) - sum_y
                if dist_x <= 0.0 and dist_y <= 0.0 then
                    return true
                end
            end
        end
    end
    return false
end

local function resolve_box_collision_on_screen(screen_index, tilemap_height,
                                               center, velocity, size)
    center.y = center.y - tilemap_height

    local start_x = floor_to_int(center.x - size.x)
    local start_y = floor_to_int(center.y - size.y)
    local end_x = floor_to_int(center.x + size.x)
    local end_y = floor_to_int(center.y + size.y)

    for x = start_x, end_x do
        for y = start_y, end_y do
            if tile_full_in_screen(screen_index, x, y) then
                local box_pos_x = 0.5 + x
                local box_pos_y = 0.5 + y
                local sum_x = size.x + 0.5
                local sum_y = size.y + 0.5
                local dist_x = math.abs(center.x - box_pos_x) - sum_x
                local dist_y = math.abs(center.y - box_pos_y) - sum_y

                if dist_x <= 0.0 and dist_y <= 0.0 then
                    local side = (center.x > box_pos_x) and 1 or -1
                    local is_x_empty = not tile_full_in_screen(screen_index, x + side, y)
                    local side_y = (center.y > box_pos_y) and 1 or -1
                    local is_y_empty = not tile_full_in_screen(screen_index, x, y + side_y)
                    if is_x_empty or is_y_empty then
                        local clip_x = is_x_empty
                        if is_x_empty and is_y_empty then
                            clip_x = dist_x > dist_y
                        end

                        if clip_x then
                            if center.x > box_pos_x then
                                center.x = box_pos_x + sum_x
                                if velocity.x < 0.0 then
                                    velocity.x = -velocity.x * BOUNCE_FACTOR_X
                                end
                            else
                                center.x = box_pos_x - sum_x
                                if velocity.x > 0.0 then
                                    velocity.x = -velocity.x * BOUNCE_FACTOR_X
                                end
                            end
                        else
                            if center.y > box_pos_y then
                                center.y = box_pos_y + sum_y
                                if velocity.y < 0.0 then
                                    velocity.y = 0.0
                                end
                            else
                                center.y = box_pos_y - sum_y
                                if velocity.y > 0.0 then
                                    velocity.y = 0.0
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    center.y = center.y + tilemap_height
end

local function refresh_ground_state(game)
    game.is_on_ground = box_colliding_with_screen(
        game.screen_index,
        game.screen_offset_y,
        { x = game.position.x, y = game.position.y + PLAYER_HALF_H },
        { x = 0.1, y = 0.05 })
end

local function resolve_motion_collision(game, before_screen)
    local after_screen = get_motion_screen_info(game)
    resolve_box_collision_on_screen(
        after_screen.screen_index,
        after_screen.screen_offset_y,
        game.position,
        game.velocity,
        { x = PLAYER_HALF_W, y = PLAYER_HALF_H })
    apply_screen_info(game, after_screen)
    refresh_ground_state(game)

    if after_screen.screen_index ~= before_screen.screen_index then
        -- Boundary tiles are duplicated on adjacent screens; resolving the
        -- old screen again can push the player through the target's fix-up.
        update_screen(game)
        refresh_ground_state(game)
        return
    end

    update_screen(game)
    refresh_ground_state(game)
end

local function update_player(game, delta)
    -- LEFT / RIGHT / JUMP all charge. Leap when the last of them is released.
    -- Direction is remembered in jump_aim_x because the release frame has
    -- all inputs already false. Never walk (no SPEED on ground).
    local charging = game.input_jump or game.input_left or game.input_right
    local jump_released = game.prev_charging and not charging

    game.velocity.y = game.velocity.y + GRAVITY * delta
    game.is_on_ground = box_colliding_with_tilemap(
        game,
        { x = game.position.x, y = game.position.y + PLAYER_HALF_H },
        { x = 0.1, y = 0.05 })

    if game.is_on_ground then
        game.velocity.x = 0.0

        if jump_released then
            local jump_strength = clamp(game.jump_hold_time * 2.6, 1.1, 2.0) / 2.0
            local aim = game.jump_aim_x or 0
            -- Height and span are independent. Normalizing used to steal
            -- height on side jumps and cap range at ~3.5 tiles.
            local up = jump_strength * JUMP_STRENGTH
            if aim ~= 0 then
                up = up * JUMP_UP_SIDE
                game.is_facing_right = aim > 0
            end
            game.velocity.y = -up
            game.velocity.x = aim * jump_strength * JUMP_SIDE
        end

        if charging then
            game.jump_hold_time = game.jump_hold_time + delta
            if game.input_right and not game.input_left then
                game.jump_aim_x = 1
                game.is_facing_right = true
            elseif game.input_left and not game.input_right then
                game.jump_aim_x = -1
                game.is_facing_right = false
            elseif game.input_jump and not game.input_left and not game.input_right then
                game.jump_aim_x = 0
            end
        else
            game.jump_hold_time = 0.0
        end
    else
        game.jump_hold_time = 0.0
    end

    local speed = vec2_len(game.velocity)
    if speed > 25.0 then
        local n = vec2_normalize(game.velocity)
        game.velocity.x = n.x * 25.0
        game.velocity.y = n.y * 25.0
    end

    game.prev_charging = charging
    game.prev_input_jump = game.input_jump
    game.anim_time = game.anim_time + delta
end


function M.new()
    return {
        position = { x = 8.0, y = 6.0 },
        velocity = { x = 0.0, y = 0.0 },
        jump_hold_time = 0.0,
        anim_time = 0.0,
        is_on_ground = false,
        is_facing_right = true,
        input_left = false,
        input_right = false,
        input_jump = false,
        prev_input_jump = false,
        prev_charging = false,
        jump_aim_x = 0,
        screen_index = 0,
        screen_offset_y = 0.0,
        state = M.STATE_STOPPED,
    }
end

function M.start(game)
    game.position = { x = 8.0, y = 6.0 }
    game.velocity = { x = 0.0, y = 0.0 }
    game.jump_hold_time = 0.0
    game.anim_time = 0.0
    game.is_on_ground = false
    game.is_facing_right = true
    game.input_left = false
    game.input_right = false
    game.input_jump = false
    game.prev_input_jump = false
    game.prev_charging = false
    game.jump_aim_x = 0
    game.state = M.STATE_RUNNING
    update_screen(game)
end

function M.restart(game)
    M.start(game)
end

function M.pause(game)
    if game.state == M.STATE_RUNNING then
        game.state = M.STATE_PAUSED
    end
end

function M.resume(game)
    if game.state == M.STATE_PAUSED then
        game.state = M.STATE_RUNNING
    end
end

function M.end_game(game)
    game.state = M.STATE_STOPPED
end

function M.set_input(game, left, right, jump)
    game.input_left = left
    game.input_right = right
    game.input_jump = jump
end

function M.update(game, elapsed_ms)
    if game.state ~= M.STATE_RUNNING then
        return
    end

    local delta = clamp(elapsed_ms / 1000.0, 0.0001, MAX_FRAME_DELTA)
    update_screen(game)
    update_player(game, delta)

    local remaining = delta
    while remaining > 0.0 do
        local step = remaining > MAX_PHYSICS_STEP and MAX_PHYSICS_STEP or remaining

        update_screen(game)
        local before_screen = {
            screen_index = game.screen_index,
            screen_offset_y = game.screen_offset_y,
        }
        game.position.x = game.position.x + game.velocity.x * step
        game.position.y = game.position.y + game.velocity.y * step
        resolve_motion_collision(game, before_screen)

        remaining = remaining - step
    end
end

function M.tile_full(game, x, y)
    if x < 0 or x >= M.MAP_W or y < 0 or y >= M.MAP_H then
        return false
    end
    return M.get_tile_from_map(game.screen_index, x, y, false) == '#'
end

function M.tile_full_outside(game, x, y)
    return M.get_tile_from_map(game.screen_index, x, y, true) == '#'
end

function M.get_tile_sprite(game, x, y)
    -- Returns sx, sy (tile atlas coords) or nil when the cell is empty.
    if not M.tile_full(game, x, y) then
        return nil
    end

    local top = M.tile_full_outside(game, x, y - 1)
    local bottom = M.tile_full_outside(game, x, y + 1)
    local right = M.tile_full_outside(game, x + 1, y)
    local left = M.tile_full_outside(game, x - 1, y)
    local top_right = M.tile_full_outside(game, x + 1, y - 1)
    local bottom_right = M.tile_full_outside(game, x + 1, y + 1)
    local top_left = M.tile_full_outside(game, x - 1, y - 1)
    local bottom_left = M.tile_full_outside(game, x - 1, y + 1)

    local sx = 1
    local sy = 1
    if top then sy = sy + 1 end
    if bottom then sy = sy - 1 end
    if right then sx = sx - 1 end
    if left then sx = sx + 1 end

    if (not top) and (not bottom) and (not right) and (not left) then
        sx = 3
        sy = 3
    end
    if (not left) and (not right) and sx == 1 then
        sx = 3
    end
    if (not top) and (not bottom) and sy == 1 then
        sy = 3
    end

    if sx == 1 and sy == 1 then
        if (not top_right) and bottom_right and top_left and bottom_left then
            sx = 4; sy = 2
        end
        if top_right and (not bottom_right) and top_left and bottom_left then
            sx = 4; sy = 0
        end
        if top_right and bottom_right and (not top_left) and bottom_left then
            sx = 6; sy = 2
        end
        if top_right and bottom_right and top_left and (not bottom_left) then
            sx = 6; sy = 0
        end
    end

    return sx, sy
end

function M.get_player_sprite(game)
    if game.is_on_ground then
        if game.jump_hold_time > 0.001 then
            return 4
        end
        if math.abs(game.velocity.x) > 0.01 then
            return 1 + (math.floor(game.anim_time * 6.0) % 2)
        end
        return 0
    end

    if game.velocity.y > 0.0 then
        return 5
    end
    return 6
end

function M.player_screen_x(game)
    return game.position.x
end

function M.player_screen_y(game)
    return game.position.y - game.screen_offset_y
end

function M.jump_charge(game)
    return clamp(game.jump_hold_time * 2.6, 0.0, 2.0) / 2.0
end

function M.get_state(game)
    return game.state
end

return M
