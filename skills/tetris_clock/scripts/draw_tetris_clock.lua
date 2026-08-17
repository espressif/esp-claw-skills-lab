local arg_schema = require("arg_schema")
local board_manager = require("board_manager")
local delay = require("delay")
local display = require("display")
local system = require("system")

local TAG = "[tetris_clock]"

local LOGICAL_W = 32
local GRID_W = 6
local GRID_H = 12
local BAR_H = 4
local DIGIT_OFFSETS_4 = { 1, 8, 18, 25 }
local DIGIT_OFFSETS_3 = { 8, 18, 25 }
local COLON_X = 15
local INITIAL_DELAY = 12

local PIECES = {
  T0 = { {0, -1}, {-1, 0}, {0, 0}, {1, 0} },
  TR = { {0, -1}, {0, 0}, {1, 0}, {0, 1} },
  T2 = { {-1, 0}, {0, 0}, {1, 0}, {0, 1} },
  TL = { {0, -1}, {-1, 0}, {0, 0}, {0, 1} },
  I0 = { {-1, 0}, {0, 0}, {1, 0}, {2, 0} },
  IR = { {1, -1}, {1, 0}, {1, 1}, {1, 2} },
  I2 = { {-1, 1}, {0, 1}, {1, 1}, {2, 1} },
  IL = { {0, -1}, {0, 0}, {0, 1}, {0, 2} },
  O0 = { {0, -1}, {1, -1}, {0, 0}, {1, 0} },
  OR = { {0, -1}, {1, -1}, {0, 0}, {1, 0} },
  O2 = { {0, -1}, {1, -1}, {0, 0}, {1, 0} },
  OL = { {0, -1}, {1, -1}, {0, 0}, {1, 0} },
  L0 = { {1, -1}, {-1, 0}, {0, 0}, {1, 0} },
  LR = { {0, -1}, {0, 0}, {0, 1}, {1, 1} },
  L2 = { {-1, 0}, {0, 0}, {1, 0}, {-1, 1} },
  LL = { {-1, -1}, {0, -1}, {0, 0}, {0, 1} },
  J0 = { {-1, -1}, {-1, 0}, {0, 0}, {1, 0} },
  JR = { {0, -1}, {1, -1}, {0, 0}, {0, 1} },
  J2 = { {-1, 0}, {0, 0}, {1, 0}, {1, 1} },
  JL = { {0, -1}, {0, 0}, {-1, 1}, {0, 1} },
  S0 = { {0, -1}, {1, -1}, {-1, 0}, {0, 0} },
  SR = { {0, -1}, {0, 0}, {1, 0}, {1, 1} },
  S2 = { {0, 0}, {1, 0}, {-1, -1}, {0, -1} },
  SL = { {-1, -1}, {-1, 0}, {0, 0}, {0, 1} },
  Z0 = { {-1, -1}, {0, -1}, {0, 0}, {1, 0} },
  ZR = { {1, -1}, {0, 0}, {1, 0}, {0, 1} },
  Z2 = { {-1, 0}, {0, 0}, {0, -1}, {1, -1} },
  ZL = { {0, -1}, {-1, 0}, {0, 0}, {-1, 1} },
}

local PIECE_COLORS = {
  T0 = 1, TR = 1, T2 = 1, TL = 1,
  I0 = 2, IR = 2, I2 = 2, IL = 2,
  O0 = 3, OR = 3, O2 = 3, OL = 3,
  L0 = 4, LR = 4, L2 = 4, LL = 4,
  J0 = 5, JR = 5, J2 = 5, JL = 5,
  S0 = 6, SR = 6, S2 = 6, SL = 6,
  Z0 = 7, ZR = 7, Z2 = 7, ZL = 7,
}

local ROTATE_CW = {
  T0 = "TR", TR = "T2", T2 = "TL", TL = "T0",
  I0 = "IR", IR = "I2", I2 = "IL", IL = "I0",
  O0 = "OR", OR = "O2", O2 = "OL", OL = "O0",
  L0 = "LR", LR = "L2", L2 = "LL", LL = "L0",
  J0 = "JR", JR = "J2", J2 = "JL", JL = "J0",
  S0 = "SR", SR = "S2", S2 = "SL", SL = "S0",
  Z0 = "ZR", ZR = "Z2", Z2 = "ZL", ZL = "Z0",
}

local DIGIT_SHAPES = {
  [0] = "ZERO",
  [1] = "ONE",
  [2] = "TWO",
  [3] = "THREE",
  [4] = "FOUR",
  [5] = "FIVE",
  [6] = "SIX",
  [7] = "SEVEN",
  [8] = "EIGHT",
  [9] = "NINE",
}

local SUBSHAPES = {
  TWO_BY_FOUR = {
    { {"O0", 0}, {"O0", 0} },
    { {"LR", 0}, {"LL", 1} },
    { {"JL", 1}, {"JR", 0} },
    { {"IL", 0}, {"IR", 0} },
  },
  TWO_BY_SIX = {
    { {"TWO_BY_FOUR", 0}, {"O0", 0} },
    { {"O0", 0}, {"TWO_BY_FOUR", 0} },
    { {"JL", 1}, {"IL", 0}, {"LL", 1} },
    { {"LR", 0}, {"IL", 1}, {"JR", 0} },
  },
  TWO_BY_EIGHT = {
    { {"TWO_BY_SIX", 0}, {"O0", 0} },
    { {"O0", 0}, {"TWO_BY_SIX", 0} },
    { {"TWO_BY_FOUR", 0}, {"TWO_BY_FOUR", 0} },
  },
  FOUR_BY_TWO = {
    { {"O0", -1}, {"O0", 1} },
    { {"L0", 1}, {"L2", 0} },
    { {"J0", 0}, {"J2", 1} },
  },
  SIX_BY_TWO = {
    { {"O0", -2}, {"FOUR_BY_TWO", 1} },
    { {"O0", 2}, {"FOUR_BY_TWO", -1} },
    { {"L0", 2}, {"J0", -1}, {"I0", 0} },
    { {"I0", 0}, {"L2", -1}, {"J2", 2} },
  },
  SQUARE_HOOK_DOWN = {
    { {"JL", 2}, {"J2", 0} },
    { {"O0", 1}, {"I0", 0} },
  },
  SQUARE_HOOK_UP = {
    { {"L0", 0}, {"LL", 2} },
    { {"I0", 0}, {"O0", 1} },
  },
  HORIZONTAL_SLANT = {
    { {"Z0", -1}, {"Z0", 1} },
    { {"I0", 0}, {"I0", -1} },
    { {"T0", 1}, {"T2", -1} },
  },
  VERTICAL_SLANT_RIGHT = {
    { {"ZR", 0}, {"ZR", 0} },
    { {"TR", 0}, {"TL", 1} },
    { {"IR", 0}, {"IL", 0} },
  },
  VERTICAL_SLANT_LEFT = {
    { {"SR", 0}, {"SR", 0} },
    { {"TL", 1}, {"TR", 0} },
    { {"IR", 0}, {"IL", 0} },
  },
  BOWL = {
    { {"O0", 0}, {"SL", -1}, {"ZR", 2} },
    { {"O0", 0}, {"ZR", 2}, {"SL", -1} },
    { {"I0", 0}, {"L0", 2}, {"J0", -1} },
    { {"I0", 0}, {"J0", -1}, {"L0", 2} },
  },
  SIX_MIDDLE = {
    { {"T2", -1}, {"T2", 2}, {"I0", 0}, {"TR", -2} },
    { {"T2", 2}, {"L2", 1}, {"VERTICAL_SLANT_LEFT", -2} },
  },
  ONE = {
    {"TWO_BY_EIGHT", 0},
  },
  TWO = {
    {"SIX_BY_TWO", 0},
    {"O0", -2},
    {"Z0", 0},
    {"T2", 2},
    {"O0", 2},
    {"S0", 1},
    {"S0", -1},
  },
  THREE = {
    {"HORIZONTAL_SLANT", 0},
    {"SQUARE_HOOK_DOWN", 1},
    {"SQUARE_HOOK_UP", 1},
    {"S0", 1},
    {"S0", -1},
  },
  FOUR = {
    {"O0", 1},
    {"I0", -1},
    {"O0", 2},
    {"L0", 0},
    {"VERTICAL_SLANT_RIGHT", -2},
    {"TL", 2},
  },
  FIVE = {
    {"HORIZONTAL_SLANT", 0},
    {"O0", 2},
    {"T0", 2},
    {"S0", 0},
    {"O0", -2},
    {"I0", 0},
    {"L2", -1},
    {"J2", 2},
  },
  SIX = {
    {"BOWL", 0},
    {"SIX_MIDDLE", 0},
    {"I0", 0},
    {"I0", 0},
  },
  SEVEN = {
    {"LR", 0},
    {"JR", 1},
    {"S0", 2},
    {"I0", 0},
    {"L2", -1},
    {"J2", 2},
  },
  EIGHT = {
    {"BOWL", 0},
    {"TR", -1},
    {"T2", 2},
    {"IL", -2},
    {"I0", 1},
    {"O0", 2},
    {"S0", 1},
    {"JR", -1},
  },
  NINE = {
    {"FOUR_BY_TWO", 0},
    {"TL", 3},
    {"I0", 0},
    {"T0", -1},
    {"T0", 2},
    {"J2", 2},
    {"L2", -1},
    {"I0", 0},
  },
  ZERO = {
    {"BOWL", 0},
    {"VERTICAL_SLANT_LEFT", -2},
    {"VERTICAL_SLANT_RIGHT", 2},
    {"FOUR_BY_TWO", 0},
  },
}

local COLOR_SCHEMES = {
  standard_dark = {
    {187, 68, 255}, {68, 255, 255}, {255, 255, 68}, {255, 187, 68},
    {68, 136, 255}, {68, 255, 68}, {255, 68, 68}, {22, 22, 22}, {255, 255, 255},
  },
  standard_light = {
    {187, 68, 255}, {68, 255, 255}, {255, 255, 68}, {255, 187, 68},
    {68, 136, 255}, {68, 255, 68}, {255, 68, 68}, {200, 200, 200}, {68, 68, 68},
  },
  autumn = {
    {241, 235, 163}, {240, 227, 152}, {237, 211, 130}, {241, 198, 118},
    {245, 185, 105}, {249, 172, 92}, {251, 165, 86}, {176, 100, 38}, {252, 143, 54},
  },
  winter = {
    {214, 221, 255}, {192, 201, 245}, {173, 185, 237}, {163, 173, 227},
    {156, 164, 219}, {147, 152, 209}, {139, 142, 201}, {89, 104, 150}, {54, 65, 89},
  },
  spring = {
    {161, 213, 151}, {153, 196, 143}, {150, 190, 140}, {137, 180, 129},
    {124, 169, 118}, {111, 159, 107}, {98, 148, 98}, {201, 242, 199}, {69, 99, 61},
  },
  summer = {
    {255, 218, 185}, {254, 213, 182}, {253, 207, 178}, {251, 196, 171},
    {250, 185, 164}, {249, 179, 161}, {248, 173, 157}, {236, 91, 91}, {165, 63, 63},
  },
  monochrome_dark = {
    {255, 255, 255}, {255, 255, 255}, {255, 255, 255}, {255, 255, 255},
    {255, 255, 255}, {255, 255, 255}, {255, 255, 255}, {0, 0, 0}, {255, 255, 255},
  },
  monochrome_light = {
    {0, 0, 0}, {0, 0, 0}, {0, 0, 0}, {0, 0, 0},
    {0, 0, 0}, {0, 0, 0}, {0, 0, 0}, {255, 255, 255}, {0, 0, 0},
  },
}

local FONT_3X5 = {
  [" "] = { "000", "000", "000", "000", "000" },
  ["0"] = { "111", "101", "101", "101", "111" },
  ["1"] = { "010", "110", "010", "010", "111" },
  ["2"] = { "111", "001", "111", "100", "111" },
  ["3"] = { "111", "001", "111", "001", "111" },
  ["4"] = { "101", "101", "111", "001", "001" },
  ["5"] = { "111", "100", "111", "001", "111" },
  ["6"] = { "111", "100", "111", "101", "111" },
  ["7"] = { "111", "001", "010", "010", "010" },
  ["8"] = { "111", "101", "111", "101", "111" },
  ["9"] = { "111", "101", "111", "001", "111" },
  A = { "010", "101", "111", "101", "101" },
  B = { "110", "101", "110", "101", "110" },
  C = { "111", "100", "100", "100", "111" },
  D = { "110", "101", "101", "101", "110" },
  E = { "111", "100", "110", "100", "111" },
  F = { "111", "100", "110", "100", "100" },
  G = { "111", "100", "101", "101", "111" },
  H = { "101", "101", "111", "101", "101" },
  I = { "111", "010", "010", "010", "111" },
  J = { "001", "001", "001", "101", "111" },
  K = { "101", "101", "110", "101", "101" },
  L = { "100", "100", "100", "100", "111" },
  M = { "101", "111", "111", "101", "101" },
  N = { "101", "111", "111", "111", "101" },
  O = { "111", "101", "101", "101", "111" },
  P = { "111", "101", "111", "100", "100" },
  Q = { "111", "101", "101", "111", "001" },
  R = { "111", "101", "111", "110", "101" },
  S = { "111", "100", "111", "001", "111" },
  T = { "111", "010", "010", "010", "010" },
  U = { "101", "101", "101", "101", "111" },
  V = { "101", "101", "101", "101", "010" },
  W = { "101", "101", "111", "111", "101" },
  X = { "101", "101", "010", "101", "101" },
  Y = { "101", "101", "010", "010", "010" },
  Z = { "111", "001", "010", "100", "111" },
}

local raw_args = type(args) == "table" and args or {}

local ARG_SCHEMA = {
  twenty_four_hour = arg_schema.bool({ default = true }),
  leading_zero = arg_schema.bool({ default = true }),
  show_date = arg_schema.bool({ default = true }),
  show_bar = arg_schema.bool({ default = true }),
  top_bar = arg_schema.bool({ default = false }),
  brightness_percent = arg_schema.int({ default = 100, min = 10, max = 100 }),
  frame_rate = arg_schema.int({ default = 10, min = 4, max = 30 }),
  build_frames = arg_schema.int({ default = 60, min = 16, max = 220 }),
  movement_rate = arg_schema.int({ default = 13, min = 0, max = 100 }),
  duration_ms = arg_schema.int({ default = 0, min = 0 }),
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

ctx.color_scheme = string_arg("color_scheme", "standard_dark")

local function cleanup()
  if display_started then
    pcall(display.end_frame)
    pcall(display.deinit)
    display_started = false
  end
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

local function rand_int(min_value, max_value)
  min_value = math.floor(min_value)
  max_value = math.floor(max_value)
  if max_value <= min_value then
    return min_value
  end
  return math.random(min_value, max_value)
end

local function color_table(rgb, brightness)
  return {
    r = clamp(math.floor(rgb[1] * brightness), 0, 255),
    g = clamp(math.floor(rgb[2] * brightness), 0, 255),
    b = clamp(math.floor(rgb[3] * brightness), 0, 255),
  }
end

local function palette()
  local source = COLOR_SCHEMES[ctx.color_scheme] or COLOR_SCHEMES.standard_dark
  local brightness = ctx.brightness_percent / 100
  local out = {}
  for i, rgb in ipairs(source) do
    out[i] = color_table(rgb, brightness)
  end
  out[8] = { r = 0, g = 0, b = 0 }
  return out
end

local function new_grid()
  local grid = {}
  for y = 1, GRID_H do
    grid[y] = {}
    for x = 1, GRID_W do
      grid[y][x] = false
    end
  end
  return grid
end

local function collides(grid, piece)
  local shape = PIECES[piece.shape]
  for _, cell in ipairs(shape) do
    local cx = cell[1] + piece.x
    local cy = cell[2] + piece.y
    if cx >= 0 and cx < GRID_W and cy >= 0 and cy < GRID_H then
      if grid[cy + 1][cx + 1] then
        return true
      end
    elseif cy >= GRID_H then
      return true
    end
  end
  return false
end

local function place(grid, piece)
  local shape = PIECES[piece.shape]
  for _, cell in ipairs(shape) do
    local cx = cell[1] + piece.x
    local cy = cell[2] + piece.y
    if cx >= 0 and cx < GRID_W and cy >= 0 and cy < GRID_H then
      grid[cy + 1][cx + 1] = true
    end
  end
end

local function unplace(grid, piece)
  local shape = PIECES[piece.shape]
  for _, cell in ipairs(shape) do
    local cx = cell[1] + piece.x
    local cy = cell[2] + piece.y
    if cx >= 0 and cx < GRID_W and cy >= 0 and cy < GRID_H then
      grid[cy + 1][cx + 1] = false
    end
  end
end

local function rotate_ccw(shape)
  return ROTATE_CW[ROTATE_CW[ROTATE_CW[shape]]]
end

local function clone_piece(piece)
  return {
    shape = piece.shape,
    x = piece.x,
    y = piece.y,
    color = piece.color,
  }
end

local function generate_final_pieces(subshape, offset, grid, out)
  for _, item in ipairs(subshape) do
    local name = item[1]
    local x_offset = item[2]
    if PIECES[name] then
      local piece = {
        shape = name,
        x = x_offset + offset,
        y = 0,
        color = PIECE_COLORS[name] or 1,
      }
      for _ = 1, GRID_H + 4 do
        if not collides(grid, piece) then
          piece.y = piece.y + 1
        else
          break
        end
      end
      piece.y = piece.y - 1
      out[#out + 1] = piece
      place(grid, piece)
    else
      local variants = SUBSHAPES[name]
      if not variants then
        error("unknown subshape: " .. tostring(name))
      end
      generate_final_pieces(variants[rand_int(1, #variants)], offset + x_offset, grid, out)
    end
  end
end

local function final_pieces_for_shape(shape_name)
  local out = {}
  generate_final_pieces(SUBSHAPES[shape_name], 2, new_grid(), out)
  return out
end

local function current_clock()
  local hour = tonumber(system.date("%H")) or 0
  local minute = tonumber(system.date("%M")) or 0
  local display_hour = hour
  local suffix = ""

  if ctx.twenty_four_hour then
    suffix = ""
  else
    suffix = hour < 12 and "AM" or "PM"
    display_hour = ((hour - 1) % 12) + 1
  end

  local digits
  local offsets
  if (not ctx.leading_zero) and display_hour < 10 then
    digits = string.format("%d%02d", display_hour, minute)
    offsets = DIGIT_OFFSETS_3
  else
    digits = string.format("%02d%02d", display_hour, minute)
    offsets = DIGIT_OFFSETS_4
  end

  return {
    key = string.format("%02d:%02d", hour, minute),
    digits = digits,
    offsets = offsets,
    suffix = suffix,
    date_label = string.upper(system.date("%b %d")),
  }
end

local function layout()
  local logical_h = GRID_H + (ctx.show_bar and BAR_H or 0)
  local cell = math.floor(math.min(display.width / LOGICAL_W, display.height / logical_h))
  if cell < 1 then
    cell = 1
  end
  local total_w = LOGICAL_W * cell
  local total_h = logical_h * cell
  return {
    cell = cell,
    total_w = total_w,
    total_h = total_h,
    x0 = math.floor((display.width - total_w) / 2),
    y0 = math.floor((display.height - total_h) / 2),
    grid_y = ctx.show_bar and ctx.top_bar and BAR_H or 0,
    bar_y = ctx.top_bar and 0 or GRID_H,
  }
end

local function digit_drop_offset(index, digit_count)
  local pattern = digit_count == 3 and { 1, 0, 2 } or { 3, 1, 0, 2 }
  return math.floor(ctx.build_frames * (pattern[index] or 0) / 20)
end

local function generate_piece_sequence(shape_name, digit_offset, drop_offset)
  local final_pieces = final_pieces_for_shape(shape_name)
  local temp_grid = new_grid()
  local sequence = {}

  for _, piece in ipairs(final_pieces) do
    place(temp_grid, piece)
  end

  for idx = 0, #final_pieces - 1 do
    local final_index = #final_pieces - idx
    local source = final_pieces[final_index]
    local piece = clone_piece(source)
    local movements = {}
    local movement_length = final_index * math.floor(ctx.build_frames / #final_pieces) + drop_offset + INITIAL_DELAY
    local bias = rand_int(1, 2)

    unplace(temp_grid, piece)

    for _ = 1, movement_length do
      if rand_int(0, 99) < ctx.movement_rate then
        local movement
        local movement_type = rand_int(0, 1)
        if movement_type == 0 then
          if rand_int(0, 3) ~= 0 then
            movement = bias
          else
            movement = 3 - bias
          end
        else
          movement = rand_int(3, 4)
        end

        if movement == 1 then
          piece.x = piece.x + 1
        elseif movement == 2 then
          piece.x = piece.x - 1
        elseif movement == 3 then
          piece.shape = ROTATE_CW[piece.shape]
        elseif movement == 4 then
          piece.shape = rotate_ccw(piece.shape)
        end

        if not collides(temp_grid, piece) then
          table.insert(movements, 1, movement)
        else
          if movement == 1 then
            piece.x = piece.x - 1
          elseif movement == 2 then
            piece.x = piece.x + 1
          elseif movement == 3 then
            piece.shape = rotate_ccw(piece.shape)
          elseif movement == 4 then
            piece.shape = ROTATE_CW[piece.shape]
          end
          table.insert(movements, 1, 0)
        end
      else
        table.insert(movements, 1, 0)
      end
      piece.y = piece.y - 1
    end

    piece.digit_offset = digit_offset
    piece.movements = movements
    piece.placed = false
    piece.move_index = 0
    piece.fade = 0
    piece.movement_length = #movements
    table.insert(sequence, 1, piece)
  end

  return sequence
end

local function make_animation_pieces(clock)
  local pieces = {}
  local digit_count = #clock.digits

  for i = 1, digit_count do
    local digit = clock.digits:sub(i, i)
    local digit_offset = clock.offsets[i]
    local digit_num = tonumber(digit)
    local shape_name = digit_num and DIGIT_SHAPES[digit_num]
    if shape_name then
      local sequence = generate_piece_sequence(shape_name, digit_offset, digit_drop_offset(i, digit_count))
      for _, piece in ipairs(sequence) do
        pieces[#pieces + 1] = piece
      end
    end
  end

  return pieces, ctx.frame_rate * 15
end

local function logical_cell(info, gx, gy, color, inset)
  if gx < 0 or gx >= LOGICAL_W or gy < 0 or gy >= GRID_H then
    return
  end
  local pad = inset or 0
  local size = info.cell - pad * 2
  if size < 1 then
    size = 1
    pad = 0
  end
  local x = info.x0 + gx * info.cell + pad
  local y = info.y0 + (info.grid_y + gy) * info.cell + pad
  display.fill_rect(x, y, size, size, color)
end

local function draw_piece(info, colors, piece, frame)
  if piece.move_index >= piece.movement_length then
    if not piece.placed then
      piece.placed = true
    end
    piece.fade = piece.fade + 1
  else
    local movement = piece.movements[piece.move_index + 1] or 0
    piece.move_index = piece.move_index + 1
    piece.y = piece.y + 1
    if movement == 1 then
      piece.x = piece.x - 1
    elseif movement == 2 then
      piece.x = piece.x + 1
    elseif movement == 3 then
      piece.shape = rotate_ccw(piece.shape)
    elseif movement == 4 then
      piece.shape = ROTATE_CW[piece.shape]
    end
  end

  local inset = info.cell >= 4 and 1 or 0
  local px = piece.x + piece.digit_offset
  local py = piece.y
  local color = colors[PIECE_COLORS[piece.shape] or piece.color]

  for _, cell in ipairs(PIECES[piece.shape]) do
    logical_cell(info, px + cell[1], py + cell[2], color, inset)
  end
end

local function draw_colon(info, colors, frame)
  local on = (frame % (ctx.frame_rate * 2)) < ctx.frame_rate
  if not on then
    return
  end
  local color = colors[9]
  local inset = info.cell >= 4 and 1 or 0
  for _, y in ipairs({ 5, 6, 9, 10 }) do
    logical_cell(info, COLON_X, y, color, inset)
    logical_cell(info, COLON_X + 1, y, color, inset)
  end
end

local function pixel_text_width(text, scale)
  local width = 0
  for i = 1, #text do
    local ch = text:sub(i, i)
    local glyph = FONT_3X5[ch] or FONT_3X5[" "]
    width = width + (#glyph[1] * scale)
    if i < #text then
      width = width + scale
    end
  end
  return width
end

local function draw_pixel_text(text, x, y, scale, color)
  for i = 1, #text do
    local ch = text:sub(i, i)
    local glyph = FONT_3X5[ch] or FONT_3X5[" "]
    for row = 1, #glyph do
      local line = glyph[row]
      for col = 1, #line do
        if line:sub(col, col) == "1" then
          display.fill_rect(x + (col - 1) * scale, y + (row - 1) * scale, scale, scale, color)
        end
      end
    end
    x = x + (#glyph[1] + 1) * scale
  end
end

local function draw_bar(info, colors, clock)
  if not ctx.show_bar then
    return
  end
  local bar_x = info.x0
  local bar_y = info.y0 + info.bar_y * info.cell
  local bar_h = BAR_H * info.cell
  display.fill_rect(bar_x, bar_y, info.total_w, bar_h, colors[8])
  if info.cell >= 2 then
    display.draw_line(bar_x, bar_y, bar_x + info.total_w - 1, bar_y, colors[9])
  end

  local scale = math.max(1, math.floor(info.cell / 2))
  local text_h = 5 * scale
  if text_h > bar_h then
    return
  end
  local ty = bar_y + math.floor((bar_h - text_h) / 2)
  local left = clock.suffix
  local right = ctx.show_date and clock.date_label or ""
  draw_pixel_text(left, bar_x + scale, ty, scale, colors[9])
  local right_w = pixel_text_width(right, scale)
  draw_pixel_text(right, bar_x + info.total_w - right_w - scale, ty, scale, colors[9])
end

local function draw_background(info, colors)
  display.begin_frame({ clear = true, color = colors[8], preserve = false })
  if ctx.show_bar then
    draw_bar(info, colors, { suffix = "", date_label = "" })
  end
end

local function draw_scene(info, colors, clock, pieces, frame)
  draw_background(info, colors)
  for _, piece in ipairs(pieces) do
    draw_piece(info, colors, piece, frame)
  end
  draw_colon(info, colors, frame)
  draw_bar(info, colors, clock)
  display.present()
  display.end_frame()
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

local function timed_out(start_ms)
  if ctx.duration_ms <= 0 then
    return false
  end
  return system.millis() - start_ms >= ctx.duration_ms
end

local function run()
  init_display()
  local seed = ctx.seed
  if seed == 0 then
    seed = math.floor(system.time() + system.millis())
  end
  math.randomseed(seed)

  local colors = palette()
  local info = layout()
  local frame_delay_ms = math.max(1, math.floor(1000 / ctx.frame_rate))
  local start_ms = system.millis()
  local cycle = 0

  print(string.format(
    "%s start display=%dx%d cell=%d scheme=%s frame_rate=%d",
    TAG, display.width, display.height, info.cell, ctx.color_scheme, ctx.frame_rate
  ))

  while not timed_out(start_ms) do
    local clock = current_clock()
    local pieces, total_frames = make_animation_pieces(clock)
    cycle = cycle + 1

    print(string.format("%s build %s tetrominoes=%d frames=%d cycle=%d", TAG, clock.key, #pieces, total_frames, cycle))

    for frame = 0, total_frames - 1 do
      draw_scene(info, colors, clock, pieces, frame)
      if timed_out(start_ms) then
        return
      end
      delay.delay_ms(frame_delay_ms)
    end

    local hold_frame = total_frames + 1
    while not timed_out(start_ms) do
      local next_clock = current_clock()
      if next_clock.key ~= clock.key then
        break
      end
      draw_scene(info, colors, next_clock, pieces, hold_frame)
      hold_frame = hold_frame + 1
      delay.delay_ms(250)
    end
  end
end

local ok, err = xpcall(run, debug.traceback)
cleanup()
if not ok then
  print(TAG .. " ERROR: " .. tostring(err))
  error(err)
end

print(TAG .. " done")
