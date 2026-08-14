local arg_schema = require("arg_schema")
local board_manager = require("board_manager")
local delay = require("delay")
local display = require("display")

local TAG = "[snake]"

local START_LENGTH = 6
local BOARD_CELLS = 16
local DEFAULT_FRAME_DELAY_MS = 140
local DEFAULT_DURATION_MS = 0
local DEFAULT_BACKGROUND = "#000000"
local DEFAULT_SNAKE_COLOR = "#ffffff"
local DEFAULT_HEAD_COLOR = "#ff8f00"
local DEFAULT_FOOD_COLOR = "#00ff00"

local raw_args = type(args) == "table" and args or {}

local ARG_SCHEMA = {
  frame_delay_ms = arg_schema.int({ default = DEFAULT_FRAME_DELAY_MS, min = 40, max = 2000 }),
  duration_ms = arg_schema.int({ default = DEFAULT_DURATION_MS, min = 0 }),
  cell_size = arg_schema.int({ default = 0, min = 0 }),
  wrap_edges = arg_schema.bool({ default = true }),
  seed = arg_schema.int({ default = 0, min = 0 }),
}

local ctx = arg_schema.parse(raw_args, ARG_SCHEMA)
local display_started = false

local DIRECTIONS = {
  { name = "right", dx = 1, dy = 0 },
  { name = "down", dx = 0, dy = 1 },
  { name = "left", dx = -1, dy = 0 },
  { name = "up", dx = 0, dy = -1 },
}

local function string_arg(name, default)
  local value = raw_args[name]
  if type(value) == "string" and value ~= "" then
    return value
  end
  return default
end

ctx.background = string_arg("background", DEFAULT_BACKGROUND)
ctx.snake_color = string_arg("snake_color", DEFAULT_SNAKE_COLOR)
ctx.head_color = string_arg("head_color", DEFAULT_HEAD_COLOR)
ctx.food_color = string_arg("food_color", DEFAULT_FOOD_COLOR)

local function cleanup()
  if display_started then
    pcall(display.end_frame)
    pcall(display.deinit)
    display_started = false
  end
end

local function rand_int(min_value, max_value)
  min_value = math.floor(min_value)
  max_value = math.floor(max_value)
  if max_value <= min_value then
    return min_value
  end
  return math.random(min_value, max_value)
end

local function abs(value)
  if value < 0 then
    return -value
  end
  return value
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

local function wrap(value, max_value)
  if value < 1 then
    return max_value
  end
  if value > max_value then
    return 1
  end
  return value
end

local function same_cell(a, b)
  return a.x == b.x and a.y == b.y
end

local function cell_key(cell)
  return tostring(cell.x) .. "," .. tostring(cell.y)
end

local function collision_index(snake, cell, start_index)
  for i = start_index or 1, #snake do
    if same_cell(snake[i], cell) then
      return i
    end
  end
  return nil
end

local function init_display()
  local panel_handle, io_handle, width, height, panel_if, pixel_format =
      board_manager.get_display_lcd_params("display_lcd")
  if not panel_handle then
    error("get_display_lcd_params failed: " .. tostring(io_handle))
  end

  display.init(panel_handle, io_handle, width, height, panel_if, pixel_format)
  display_started = true
  pcall(display.backlight, true)
end

local function choose_cell_size(width, height)
  local max_cell = math.max(1, math.min(width // BOARD_CELLS, height // BOARD_CELLS))

  if ctx.cell_size > 0 then
    return clamp(ctx.cell_size, 1, max_cell)
  end

  local size = math.min(width, height) // BOARD_CELLS
  if size < 1 then
    size = 1
  end
  return size
end

local function make_board()
  local cell = choose_cell_size(display.width, display.height)
  local cols = BOARD_CELLS
  local rows = BOARD_CELLS
  local draw_w = cols * cell
  local draw_h = rows * cell

  if cols < START_LENGTH or rows < 1 then
    error("display is too small for snake: " .. tostring(display.width) .. "x" .. tostring(display.height))
  end

  return {
    cell = cell,
    cols = cols,
    rows = rows,
    offset_x = math.floor((display.width - draw_w) / 2),
    offset_y = math.floor((display.height - draw_h) / 2),
  }
end

local function make_snake(board)
  local snake = {}
  local head_x = math.max(START_LENGTH + 1, board.cols // 2)
  local head_y = math.max(1, board.rows // 2)

  for i = 1, START_LENGTH do
    snake[i] = {
      x = wrap(head_x - i + 1, board.cols),
      y = head_y,
    }
  end

  return snake
end

local function make_food(board, snake)
  local occupied = {}
  for _, segment in ipairs(snake) do
    occupied[cell_key(segment)] = true
  end

  local free_count = board.cols * board.rows - #snake
  if free_count <= 0 then
    return {
      x = rand_int(1, board.cols),
      y = rand_int(1, board.rows),
    }
  end

  for _ = 1, 80 do
    local food = {
      x = rand_int(1, board.cols),
      y = rand_int(1, board.rows),
    }
    if not occupied[cell_key(food)] then
      return food
    end
  end

  for y = 1, board.rows do
    for x = 1, board.cols do
      local food = { x = x, y = y }
      if not occupied[cell_key(food)] then
        return food
      end
    end
  end

  return { x = 1, y = 1 }
end

local function next_cell(board, head, direction)
  local x = head.x + direction.dx
  local y = head.y + direction.dy

  if ctx.wrap_edges then
    if x < 1 then
      x = board.cols
    elseif x > board.cols then
      x = 1
    end

    if y < 1 then
      y = board.rows
    elseif y > board.rows then
      y = 1
    end
  end

  return { x = x, y = y }
end

local function in_bounds(board, cell)
  return cell.x >= 1 and cell.x <= board.cols and cell.y >= 1 and cell.y <= board.rows
end

local function is_edge_cell(board, cell)
  return cell.x == 1 or cell.x == board.cols or cell.y == 1 or cell.y == board.rows
end

local function crosses_edge(board, head, direction)
  local x = head.x + direction.dx
  local y = head.y + direction.dy
  return x < 1 or x > board.cols or y < 1 or y > board.rows
end

local function distance_to_food(board, cell, food)
  local dx = abs(cell.x - food.x)
  local dy = abs(cell.y - food.y)
  if not in_bounds(board, cell) then
    return 1000000
  end
  return dx + dy
end

local function is_reverse(a, b)
  return a.dx + b.dx == 0 and a.dy + b.dy == 0
end

local function cells_are_connected(board, a, b)
  local dx = abs(a.x - b.x)
  local dy = abs(a.y - b.y)

  if ctx.wrap_edges then
    dx = math.min(dx, board.cols - dx)
    dy = math.min(dy, board.rows - dy)
  end

  return dx + dy == 1
end

local function validate_snake(board, snake)
  if #snake < 1 then
    error("snake has no head")
  end

  local occupied = {}
  for i, segment in ipairs(snake) do
    if not in_bounds(board, segment) then
      error(string.format("snake segment %d is out of bounds at (%d,%d)", i, segment.x, segment.y))
    end

    local key = cell_key(segment)
    if occupied[key] then
      error(string.format("snake overlaps itself at (%d,%d)", segment.x, segment.y))
    end
    occupied[key] = true

    if i > 1 and not cells_are_connected(board, snake[i - 1], segment) then
      error(string.format(
        "snake is disconnected between (%d,%d) and (%d,%d)",
        snake[i - 1].x,
        snake[i - 1].y,
        segment.x,
        segment.y
      ))
    end
  end
end

local function choose_direction(board, snake, current_direction, food, leave_edge_after_event)
  local options = {}
  local head = snake[1]

  local function add_options(allow_reverse)
    for _, direction in ipairs(DIRECTIONS) do
      if allow_reverse or #snake <= 1 or not is_reverse(direction, current_direction) then
        local candidate = next_cell(board, head, direction)
        if in_bounds(board, candidate) then
          local bite_at = collision_index(snake, candidate, 2)
          local wrapped = crosses_edge(board, head, direction)
          local event_on_wrap = wrapped and (same_cell(candidate, food) or bite_at ~= nil)

          if not event_on_wrap and not (leave_edge_after_event and wrapped) then
            local score = distance_to_food(board, candidate, food)

            if bite_at then
              score = score + 5000 + math.max(0, #snake - bite_at + 1) * 100
            end
            if leave_edge_after_event and is_edge_cell(board, candidate) then
              score = score + 2000
            end
            options[#options + 1] = {
              direction = direction,
              score = score,
              tie = rand_int(0, 999),
            }
          end
        end
      end
    end
  end

  add_options(false)
  if #options == 0 then
    add_options(true)
  end

  table.sort(options, function(a, b)
    if a.score == b.score then
      return a.tie < b.tie
    end
    return a.score < b.score
  end)

  if #options == 0 then
    error("no valid snake direction")
  end

  return options[1].direction
end

local function move_snake(board, snake, direction, food)
  local old_head = snake[1]
  local new_head = next_cell(board, old_head, direction)
  local wrapped = crosses_edge(board, old_head, direction)
  local ate_food = same_cell(new_head, food)
  local bite_at = collision_index(snake, new_head, 2)
  local keep_until = #snake

  if bite_at then
    keep_until = bite_at - 1
  elseif not ate_food then
    keep_until = #snake - 1
  end

  local moved = {
    { x = new_head.x, y = new_head.y },
  }
  for i = 1, keep_until do
    moved[#moved + 1] = {
      x = snake[i].x,
      y = snake[i].y,
    }
  end

  if not cells_are_connected(board, old_head, moved[1]) then
    error(string.format(
      "invalid head move from (%d,%d) to (%d,%d)",
      old_head.x,
      old_head.y,
      moved[1].x,
      moved[1].y
    ))
  end
  validate_snake(board, moved)

  return moved, ate_food, bite_at, wrapped
end

local function draw_cell(board, cell, color, inset)
  local pixel = board.cell
  local x = board.offset_x + (cell.x - 1) * pixel
  local y = board.offset_y + (cell.y - 1) * pixel
  local pad = inset or 0
  local size = pixel - pad * 2

  if size < 1 then
    size = 1
    pad = 0
  end

  x = x + pad
  y = y + pad

  if pixel >= 8 and size >= 4 then
    display.fill_round_rect(x, y, size, size, math.max(1, size // 4), color)
  else
    display.fill_rect(x, y, size, size, color)
  end
end

local function draw_food(board, food)
  local pixel = board.cell
  if pixel >= 6 then
    local radius = math.max(2, (pixel - 4) // 2)
    local cx = board.offset_x + (food.x - 1) * pixel + pixel // 2
    local cy = board.offset_y + (food.y - 1) * pixel + pixel // 2
    display.fill_circle(cx, cy, radius, ctx.food_color)
  else
    draw_cell(board, food, ctx.food_color, 0)
  end
end

local function draw_frame(board, snake, food, score)
  display.begin_frame({ clear = true, color = ctx.background, preserve = false })
  if food then
    draw_food(board, food)
  end

  for i = #snake, 1, -1 do
    local color = i == 1 and ctx.head_color or ctx.snake_color
    local inset = board.cell >= 6 and 1 or 0
    draw_cell(board, snake[i], color, inset)
  end

  if board.cell >= 10 then
    display.draw_text(4, 4, "SNAKE " .. tostring(score), {
      color = "#808080",
      font_size = 12,
    })
  end

  display.present()
  display.end_frame()
end

local function run()
  if ctx.seed > 0 then
    math.randomseed(ctx.seed)
  else
    math.randomseed(os.time())
  end

  init_display()

  local board = make_board()
  local snake = make_snake(board)
  local direction = DIRECTIONS[1]
  local food = make_food(board, snake)
  local elapsed_ms = 0
  local score = 0
  local bites = 0
  local leave_edge_after_event = false

  print(string.format(
    "%s start display=%dx%d cell=%d grid=%dx%d length=%d",
    TAG,
    display.width,
    display.height,
    board.cell,
    board.cols,
    board.rows,
    #snake
  ))

  while ctx.duration_ms == 0 or elapsed_ms < ctx.duration_ms do
    direction = choose_direction(board, snake, direction, food, leave_edge_after_event)
    local previous_head = { x = snake[1].x, y = snake[1].y }
    local previous_length = #snake
    local ate_food = false
    local bite_at = nil
    local wrapped = false
    snake, ate_food, bite_at, wrapped = move_snake(board, snake, direction, food)
    if ate_food then
      score = score + 1
    end
    if bite_at then
      bites = bites + 1
    end

    if wrapped then
      print(string.format(
        "%s wrap=(%d,%d)->(%d,%d) direction=%s ate=%s bite=%s",
        TAG,
        previous_head.x,
        previous_head.y,
        snake[1].x,
        snake[1].y,
        direction.name,
        tostring(ate_food),
        tostring(bite_at ~= nil)
      ))
    end
    if bite_at then
      print(string.format(
        "%s bite=(%d,%d) index=%d removed=%d length=%d",
        TAG,
        snake[1].x,
        snake[1].y,
        bite_at,
        previous_length - bite_at + 1,
        #snake
      ))
    end

    if leave_edge_after_event and not is_edge_cell(board, snake[1]) then
      leave_edge_after_event = false
    end
    if ate_food or bite_at then
      leave_edge_after_event = is_edge_cell(board, snake[1])
    end

    -- Keep the eaten cell visible as the head for one complete frame. Spawning
    -- the next food afterward prevents two distant event changes in one frame.
    local frame_food = food
    if ate_food then
      frame_food = nil
    end
    draw_frame(board, snake, frame_food, score)
    delay.delay_ms(ctx.frame_delay_ms)
    elapsed_ms = elapsed_ms + ctx.frame_delay_ms

    if ate_food then
      local eaten_x = food.x
      local eaten_y = food.y
      food = make_food(board, snake)
      print(string.format(
        "%s ate=(%d,%d) head=(%d,%d) next_food=(%d,%d) length=%d",
        TAG,
        eaten_x,
        eaten_y,
        snake[1].x,
        snake[1].y,
        food.x,
        food.y,
        #snake
      ))
    end
  end

  print(string.format("%s done score=%d length=%d bites=%d", TAG, score, #snake, bites))
end

local ok, err = xpcall(run, debug.traceback)
cleanup()
if not ok then
  print(TAG .. " ERROR: " .. tostring(err))
  error(err)
end
