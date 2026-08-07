local arg_schema = require("arg_schema")
local delay = require("delay")
local display = require("display")

local TAG = "[maze]"

local DEFAULT_COLUMNS = 0
local DEFAULT_ROWS = 0
local DEFAULT_STEP_SIZE = 3
local DEFAULT_SOLVE_STEP_SIZE = 1
local DEFAULT_FRAME_DELAY_MS = 35
local DEFAULT_SOLVE_DELAY_MS = 35
local DEFAULT_FINAL_HOLD_MS = 5000
local DEFAULT_REPEAT_COUNT = 0
local DEFAULT_WALL_COLOR = "#ffffff"
local DEFAULT_BACKGROUND = "#000000"
local DEFAULT_SOLVE_COLOR = "#00ff00"
local DEFAULT_START_COLOR = "#00ffff"
local DEFAULT_END_COLOR = "#ff4040"

local raw_args = type(args) == "table" and args or {}

local ARG_SCHEMA = {
  columns = arg_schema.int({ default = DEFAULT_COLUMNS, min = 0, max = 80 }),
  rows = arg_schema.int({ default = DEFAULT_ROWS, min = 0, max = 60 }),
  step_size = arg_schema.int({ default = DEFAULT_STEP_SIZE, min = 1, max = 128 }),
  solve_step_size = arg_schema.int({ default = DEFAULT_SOLVE_STEP_SIZE, min = 1, max = 128 }),
  frame_delay_ms = arg_schema.int({ default = DEFAULT_FRAME_DELAY_MS, min = 0, max = 2000 }),
  solve_delay_ms = arg_schema.int({ default = DEFAULT_SOLVE_DELAY_MS, min = 0, max = 2000 }),
  final_hold_ms = arg_schema.int({ default = DEFAULT_FINAL_HOLD_MS, min = 0 }),
  repeat_count = arg_schema.int({ default = DEFAULT_REPEAT_COUNT, min = 0 }),
  seed = arg_schema.int({ default = 0, min = 0 }),
}

local ctx = arg_schema.parse(raw_args, ARG_SCHEMA)
local display_started = false

local function string_arg(name, default)
  local value = raw_args[name]
  if type(value) == "string" and value ~= "" then
    return value
  end
  return default
end

ctx.wall_color = string_arg("wall_color", string_arg("foreground", DEFAULT_WALL_COLOR))
ctx.background = string_arg("background", DEFAULT_BACKGROUND)
ctx.solve_color = string_arg("solve_color", DEFAULT_SOLVE_COLOR)
ctx.start_color = string_arg("start_color", DEFAULT_START_COLOR)
ctx.end_color = string_arg("end_color", DEFAULT_END_COLOR)

local function rand_int(min_value, max_value)
  if max_value <= min_value then
    return min_value
  end
  return math.random(min_value, max_value)
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

local function cell_key(cell)
  return tostring(cell.x) .. "," .. tostring(cell.y)
end

local function cleanup()
  if display_started then
    pcall(display.end_frame)
    pcall(display.deinit)
    display_started = false
  end
end

local function init_display()
  local info, err = display.init()
  if not info then
    error("display.init failed: " .. tostring(err))
  end

  display_started = true
  pcall(display.backlight, true)
end

local function choose_dimensions()
  local max_columns = math.max(1, math.floor((display.width - 1) / 2))
  local max_rows = math.max(1, math.floor((display.height - 1) / 2))
  local auto_scale = 10

  if display.width >= 480 and display.height >= 480 then
    auto_scale = 16
  elseif display.width <= 96 or display.height <= 48 then
    auto_scale = 4
  end

  local auto_columns = clamp(math.floor((display.width / auto_scale - 1) / 2), 4, 80)
  local auto_rows = clamp(math.floor((display.height / auto_scale - 1) / 2), 4, 60)
  local columns = ctx.columns > 0 and ctx.columns or auto_columns
  local rows = ctx.rows > 0 and ctx.rows or auto_rows

  ctx.columns = clamp(columns, math.min(4, max_columns), math.min(80, max_columns))
  ctx.rows = clamp(rows, math.min(4, max_rows), math.min(60, max_rows))
end

local function layout()
  local logical_w = ctx.columns * 2 + 1
  local logical_h = ctx.rows * 2 + 1
  local scale_x = math.floor(display.width / logical_w)
  local scale_y = math.floor(display.height / logical_h)
  local scale = math.max(1, math.min(scale_x, scale_y))
  local draw_w = logical_w * scale
  local draw_h = logical_h * scale

  return {
    logical_w = logical_w,
    logical_h = logical_h,
    scale = scale,
    x = math.floor((display.width - draw_w) / 2),
    y = math.floor((display.height - draw_h) / 2),
    width = draw_w,
    height = draw_h,
  }
end

local function logical_rect(info, logical_x, logical_y, color)
  display.fill_rect(
    info.x + logical_x * info.scale,
    info.y + logical_y * info.scale,
    info.scale,
    info.scale,
    color
  )
end

local function cell_logical_x(cell)
  return cell.x * 2 + 1
end

local function cell_logical_y(cell)
  return cell.y * 2 + 1
end

local function carve_cell(info, cell, color)
  logical_rect(info, cell_logical_x(cell), cell_logical_y(cell), color)
end

local function carve_between(info, a, b, color)
  local ax = cell_logical_x(a)
  local ay = cell_logical_y(a)
  local bx = cell_logical_x(b)
  local by = cell_logical_y(b)

  logical_rect(info, math.floor((ax + bx) / 2), math.floor((ay + by) / 2), color)
end

local function draw_entrance_exit(info, background_color)
  logical_rect(info, 0, 1, background_color)
  logical_rect(info, ctx.columns * 2, ctx.rows * 2 - 1, background_color)
end

local function draw_markers(info, grid)
  carve_cell(info, grid[1][1], ctx.start_color)
  carve_cell(info, grid[ctx.rows][ctx.columns], ctx.end_color)
end

local function new_grid()
  local grid = {}
  for y = 0, ctx.rows - 1 do
    local row = {}
    grid[y + 1] = row
    for x = 0, ctx.columns - 1 do
      row[x + 1] = {
        x = x,
        y = y,
        links = {},
        generated = false,
      }
    end
  end
  return grid
end

local function neighbours(grid, cell)
  local out = {}
  local candidates = {
    { cell.x, cell.y - 1 },
    { cell.x, cell.y + 1 },
    { cell.x + 1, cell.y },
    { cell.x - 1, cell.y },
  }

  for _, candidate in ipairs(candidates) do
    local x = candidate[1]
    local y = candidate[2]
    if x >= 0 and x < ctx.columns and y >= 0 and y < ctx.rows then
      out[#out + 1] = grid[y + 1][x + 1]
    end
  end

  return out
end

local function link_cells(a, b)
  a.links[#a.links + 1] = b
  b.links[#b.links + 1] = a
end

local function generate_maze(grid)
  local sequence = {}
  local active = { grid[1][1] }
  grid[1][1].generated = true

  while #active > 0 do
    local active_index = rand_int(1, #active)
    local cell = active[active_index]
    local available = {}

    for _, next_cell in ipairs(neighbours(grid, cell)) do
      if not next_cell.generated then
        available[#available + 1] = next_cell
      end
    end

    if #available > 0 then
      local next_cell = available[rand_int(1, #available)]
      next_cell.generated = true
      link_cells(cell, next_cell)
      active[#active + 1] = next_cell
      sequence[#sequence + 1] = { cell, next_cell }
    else
      active[active_index] = active[#active]
      active[#active] = nil
    end
  end

  return sequence
end

local function draw_closed_grid(info)
  display.fill_rect(0, 0, display.width, display.height, ctx.background)
  display.fill_rect(info.x, info.y, info.width, info.height, ctx.wall_color)
  draw_entrance_exit(info, ctx.background)
end

local function carve_edge(info, edge, color)
  carve_cell(info, edge[1], color)
  carve_between(info, edge[1], edge[2], color)
  carve_cell(info, edge[2], color)
end

local function draw_generation_frame(info, grid, sequence, count)
  display.begin_frame({ clear = true, color = ctx.background, preserve = false })
  draw_closed_grid(info)
  carve_cell(info, grid[1][1], ctx.background)
  for i = 1, count do
    carve_edge(info, sequence[i], ctx.background)
  end
  draw_entrance_exit(info, ctx.background)
  draw_markers(info, grid)
  display.present()
  display.end_frame()
end

local function animate_generation(info, grid, sequence)
  draw_generation_frame(info, grid, sequence, 0)
  for i = 1, #sequence, ctx.step_size do
    local last = math.min(#sequence, i + ctx.step_size - 1)
    draw_generation_frame(info, grid, sequence, last)
    if ctx.frame_delay_ms > 0 then
      delay.delay_ms(ctx.frame_delay_ms)
    end
  end
end

local function draw_full_maze(info, grid)
  draw_closed_grid(info)
  for y = 1, ctx.rows do
    for x = 1, ctx.columns do
      local cell = grid[y][x]
      carve_cell(info, cell, ctx.background)
      for _, linked in ipairs(cell.links) do
        if linked.x > cell.x or linked.y > cell.y then
          carve_between(info, cell, linked, ctx.background)
        end
      end
    end
  end
  draw_entrance_exit(info, ctx.background)
end

local function draw_path(info, path, count, color)
  local previous = nil
  for i = 1, count do
    local cell = path[i]
    if previous then
      carve_between(info, previous, cell, color)
    end
    carve_cell(info, cell, color)
    previous = cell
  end
end

local function draw_solve_frame(info, grid, path, count)
  display.begin_frame({ clear = true, color = ctx.background, preserve = false })
  draw_full_maze(info, grid)
  draw_path(info, path, count, ctx.solve_color)
  draw_markers(info, grid)
  display.present()
  display.end_frame()
end

local function animate_solution(info, grid)
  local start = grid[1][1]
  local goal = grid[ctx.rows][ctx.columns]
  local stack = {
    {
      cell = start,
      next_link = 1,
    },
  }
  local path = { start }
  local in_path = {
    [cell_key(start)] = true,
  }
  local step_counter = 0

  draw_solve_frame(info, grid, path, #path)

  while #stack > 0 do
    local top = stack[#stack]

    if top.cell == goal then
      draw_solve_frame(info, grid, path, #path)
      return true, #path
    end

    if top.next_link <= #top.cell.links then
      local next_cell = top.cell.links[top.next_link]
      top.next_link = top.next_link + 1

      if not in_path[cell_key(next_cell)] then
        stack[#stack + 1] = {
          cell = next_cell,
          next_link = 1,
        }
        path[#path + 1] = next_cell
        in_path[cell_key(next_cell)] = true
        step_counter = step_counter + 1

        if step_counter % ctx.solve_step_size == 0 then
          draw_solve_frame(info, grid, path, #path)
          if ctx.solve_delay_ms > 0 then
            delay.delay_ms(ctx.solve_delay_ms)
          end
        end
      end
    else
      in_path[cell_key(top.cell)] = nil
      stack[#stack] = nil
      path[#path] = nil
      step_counter = step_counter + 1

      if #path > 0 and step_counter % ctx.solve_step_size == 0 then
        draw_solve_frame(info, grid, path, #path)
        if ctx.solve_delay_ms > 0 then
          delay.delay_ms(ctx.solve_delay_ms)
        end
      end
    end
  end

  return false, 0
end

local function draw_maze_once(run_index)
  choose_dimensions()
  local info = layout()
  local grid = new_grid()
  local sequence = generate_maze(grid)

  print(string.format(
    "%s generating cells=%dx%d scale=%d entrance=(%d,%d) exit=(%d,%d) run=%d",
    TAG,
    ctx.columns,
    ctx.rows,
    info.scale,
    info.x,
    info.y + info.scale,
    info.x + ctx.columns * 2 * info.scale,
    info.y + (ctx.rows * 2 - 1) * info.scale,
    run_index
  ))

  animate_generation(info, grid, sequence)

  print(string.format("%s solving edges=%d", TAG, #sequence))
  local solved, path_len = animate_solution(info, grid)
  if not solved then
    error(TAG .. " generated maze was not solvable")
  end

  print(string.format("%s done path=%d edges=%d", TAG, path_len, #sequence))
end

local function hold_final(run_index)
  if ctx.final_hold_ms > 0 then
    delay.delay_ms(ctx.final_hold_ms)
  elseif ctx.repeat_count == 1 and run_index == 1 then
    while true do
      delay.delay_ms(1000)
    end
  end
end

local function run()
  if ctx.seed > 0 then
    math.randomseed(ctx.seed)
  else
    math.randomseed(os.time())
  end

  init_display()
  local run_index = 0

  while ctx.repeat_count == 0 or run_index < ctx.repeat_count do
    run_index = run_index + 1
    draw_maze_once(run_index)
    hold_final(run_index)
  end
end

local ok, err = xpcall(run, debug.traceback)
cleanup()
if not ok then
  print(TAG .. " ERROR: " .. tostring(err))
  error(err)
end
