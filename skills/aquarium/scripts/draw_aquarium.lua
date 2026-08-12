package.path = package.path .. ";/fatfs/skills/aquarium/scripts/?.lua"

local arg_schema = require("arg_schema")
local delay = require("delay")
local display = require("display")
local catalog = require("aquarium_catalog")
local png = require("aquarium_png")

local TAG = "[aquarium]"
local IMAGE_DIR = "/fatfs/skills/aquarium/scripts/images"

local DEFAULT_WATER_COLOR = "random"
local DEFAULT_INCLUDE_DIVER = true
local DEFAULT_FISH_COUNT = 6
local DEFAULT_FRAME_DELAY_MS = 10
local DEFAULT_DURATION_MS = 0
local MIN_FISH_COUNT = 3
local MAX_FISH_COUNT = 6
local MIN_DECOR_COUNT = 3
local MAX_DECOR_COUNT = 5
local MIN_FISH_SPEED = 3
local MAX_FISH_SPEED = 7
local DISPLAY_RGB565_BYTE_SWAP_COMPENSATION = true
local SAND_COLOR = "#c2b280"

local WATER_COLORS = {
  aqua = "#33b5cc",
  deep_blue = "#0099cc",
  aquamarine = "#40d6a5",
  light_blue = "#add8e6",
  very_dark_blue = "#04034d",
  dark_turquoise = "#00ced1",
  turquoise = "#30c2b3",
}

local WATER_CHOICES = {
  WATER_COLORS.aqua,
  WATER_COLORS.deep_blue,
  WATER_COLORS.aquamarine,
  WATER_COLORS.light_blue,
  WATER_COLORS.very_dark_blue,
  WATER_COLORS.dark_turquoise,
  WATER_COLORS.turquoise,
}

local SEALIFE = catalog.sealife
local DIVER = catalog.diver
local OCEAN_FLOOR = catalog.decor

local raw_args = type(args) == "table" and args or {}

local ARG_SCHEMA = {
  include_diver = arg_schema.bool({ default = DEFAULT_INCLUDE_DIVER }),
  fish_count = arg_schema.int({ default = DEFAULT_FISH_COUNT, min = MIN_FISH_COUNT, max = MAX_FISH_COUNT }),
  frame_delay_ms = arg_schema.int({ default = DEFAULT_FRAME_DELAY_MS, min = 5, max = 2000 }),
  duration_ms = arg_schema.int({ default = DEFAULT_DURATION_MS, min = 0 }),
  seed = arg_schema.int({ default = 0, min = 0 }),
}

local ctx = arg_schema.parse(raw_args, ARG_SCHEMA)
local display_started = false
local active_scene = nil

local function string_arg(name, default)
  local value = raw_args[name]
  if type(value) == "string" and value ~= "" then
    return value
  end
  return default
end

local function rand_int(min_value, max_value)
  min_value = math.floor(min_value)
  max_value = math.floor(max_value)
  if max_value <= min_value then
    return min_value
  end
  return math.random(min_value, max_value)
end

local function display_rgb565_value(value)
  if DISPLAY_RGB565_BYTE_SWAP_COMPENSATION then
    return ((value % 256) * 256) + math.floor(value / 256)
  end
  return value
end

local function color_to_rgb565(color)
  local r = tonumber(color:sub(2, 3), 16) or 0
  local g = tonumber(color:sub(4, 5), 16) or 0
  local b = tonumber(color:sub(6, 7), 16) or 0
  return ((r - (r % 8)) * 256) + ((g - (g % 4)) * 8) + math.floor(b / 8)
end

local function rgb_to_rgb565(r, g, b)
  return ((r - (r % 8)) * 256) + ((g - (g % 4)) * 8) + math.floor(b / 8)
end

local function pack_rgb565(value)
  value = display_rgb565_value(value)
  return string.char(value % 256, math.floor(value / 256) % 256)
end

local function rgb565_to_display_hex(value, alpha)
  value = display_rgb565_value(value)

  local r5 = math.floor(value / 2048) % 32
  local g6 = math.floor(value / 32) % 64
  local b5 = value % 32
  local r = math.floor(r5 * 255 / 31)
  local g = math.floor(g6 * 255 / 63)
  local b = math.floor(b5 * 255 / 31)

  if not alpha or alpha >= 255 then
    return string.format("#%02x%02x%02x", r, g, b)
  end
  return string.format("#%02x%02x%02x%02x", r, g, b, alpha)
end

local function panel_color(color)
  if type(color) ~= "string" or color:sub(1, 1) ~= "#" or (#color ~= 7 and #color ~= 9) then
    return color
  end
  local alpha = #color == 9 and tonumber(color:sub(8, 9), 16) or 255
  return rgb565_to_display_hex(color_to_rgb565(color), alpha)
end

local function normalize_color(value)
  if not value or value == "" or value == "random" or value == "Random" then
    return "random"
  end

  local key = value:gsub("%s+", "_"):lower()
  return WATER_COLORS[key] or value
end

local function pick_water_color(value)
  value = normalize_color(value)
  if value == "random" then
    return panel_color(WATER_CHOICES[rand_int(1, #WATER_CHOICES)])
  end
  return panel_color(value)
end

local function copy_list(items)
  local out = {}
  for i, item in ipairs(items) do
    out[i] = item
  end
  return out
end

local function shuffle(items)
  for i = #items, 2, -1 do
    local j = rand_int(1, i)
    items[i], items[j] = items[j], items[i]
  end
end

local function image_path(key)
  return IMAGE_DIR .. "/" .. key .. ".png"
end

local function png_to_spans(decoded)
  local channels = decoded.channels
  local pixels = decoded.pixels
  local spans = {}
  local pos = 1

  for y = 0, decoded.height - 1 do
    local run_x = nil
    local run = {}

    for x = 0, decoded.width - 1 do
      local r = pixels[pos] or 0
      local g = pixels[pos + 1] or 0
      local b = pixels[pos + 2] or 0
      local a = channels == 4 and (pixels[pos + 3] or 255) or 255
      pos = pos + channels

      if a >= 32 then
        if not run_x then
          run_x = x
          run = {}
        end
        run[#run + 1] = pack_rgb565(rgb_to_rgb565(r, g, b))
      elseif run_x then
        spans[#spans + 1] = {
          x = run_x,
          y = y,
          width = #run,
          data = table.concat(run),
        }
        run_x = nil
      end
    end

    if run_x then
      spans[#spans + 1] = {
        x = run_x,
        y = y,
        width = #run,
        data = table.concat(run),
      }
    end
  end

  decoded.pixels = nil
  return {
    width = decoded.width,
    height = decoded.height,
    spans = spans,
  }
end

local function load_sprite_image(key)
  local decoded = png.load(image_path(key))
  return png_to_spans(decoded)
end

local function sprite_asset(spec)
  local image = load_sprite_image(spec.key)

  return {
    key = spec.key,
    name = spec.name,
    direction = spec.direction,
    image = image,
    width = image.width,
    height = image.height,
  }
end

local function draw_sprite(sprite, x, y, screen_width, screen_height)
  x = math.floor(x)
  y = math.floor(y)

  for _, span in ipairs(sprite.spans) do
    local draw_x = x + span.x
    local draw_y = y + span.y

    if draw_x < screen_width and draw_x + span.width > 0 and draw_y < screen_height and draw_y + 1 > 0 then
      display.draw_pixels(draw_x, draw_y, span.data, {
        format = "rgb565",
        width = span.width,
        height = 1,
      })
    end
  end
end

local function make_sealife(unit, width, height, floor_items)
  local pool = copy_list(SEALIFE)
  if ctx.include_diver then
    pool[#pool + 1] = DIVER
  end

  shuffle(pool)

  local selected = {}
  local max_count = math.min(ctx.fish_count, #pool)
  local min_count = math.min(MIN_FISH_COUNT, max_count)
  local count = rand_int(min_count, max_count)
  local floor_height = 0

  for _, item in ipairs(floor_items) do
    if item.height > floor_height then
      floor_height = item.height
    end
  end

  local swim_bottom = math.max(1, height - floor_height - unit)
  local lane_height = math.max(1, swim_bottom // (count + 1))

  for i = 1, count do
    local item = sprite_asset(pool[i])
    local center_y = lane_height * i
    local jitter = rand_int(-lane_height // 3, lane_height // 3)
    item.y = math.max(0, math.min(swim_bottom - item.height, center_y + jitter - item.height // 2))
    item.speed = rand_int(MIN_FISH_SPEED, MAX_FISH_SPEED)
    item.start_offset = rand_int(0, math.max(width // 2, item.width * 2))
    item.start_delay = rand_int(0, math.max(0, width // (4 * unit)))
    selected[i] = item
  end
  return selected
end

local function rects_overlap(a, b, padding)
  return a.x < b.x + b.width + padding and
    b.x < a.x + a.width + padding and
    a.y < b.y + b.height + padding and
    b.y < a.y + a.height + padding
end

local function can_place_floor(layout, candidate, padding)
  for _, placed in ipairs(layout) do
    if rects_overlap(candidate, placed, padding) then
      return false
    end
  end
  return true
end

local function make_floor_layout(unit, width, height)
  local pool = copy_list(OCEAN_FLOOR)
  local layout = {}
  local max_items = math.min(MAX_DECOR_COUNT, #pool)
  if max_items > MIN_DECOR_COUNT then
    max_items = rand_int(MIN_DECOR_COUNT, max_items)
  end
  local padding = math.max(2, 4 * unit)

  shuffle(pool)

  for _, spec in ipairs(pool) do
    if #layout >= max_items then
      break
    end

    local item = sprite_asset(spec)
    local max_x = math.max(0, width - item.width)
    local y = math.max(0, height - item.height)
    local placed = false

    for _ = 1, 16 do
      local candidate = {
        item = item,
        x = rand_int(0, max_x),
        y = y,
        width = item.width,
        height = item.height,
      }

      if can_place_floor(layout, candidate, padding) then
        layout[#layout + 1] = candidate
        placed = true
        break
      end
    end

    if not placed then
      for slot = 0, max_items - 1 do
        local slot_w = width // max_items
        local slot_x = slot * slot_w + math.max(0, slot_w - item.width) // 2
        local candidate = {
          item = item,
          x = math.min(max_x, slot_x),
          y = y,
          width = item.width,
          height = item.height,
        }

        if can_place_floor(layout, candidate, padding) then
          layout[#layout + 1] = candidate
          break
        end
      end
    end
  end

  if #layout == 0 and #pool > 0 then
    local item = sprite_asset(pool[1])
    layout[1] = {
      item = item,
      x = math.max(0, width - item.width) // 2,
      y = math.max(0, height - item.height),
      width = item.width,
      height = item.height,
    }
  end

  return layout
end

local function setup_display()
  local info, err = display.init()
  if not info then
    error(TAG .. " display.init failed: " .. tostring(err))
  end

  display_started = true
  pcall(display.backlight, true)
  return display.width, display.height
end

local function draw_fish(item, frame, width, height, unit)
  if frame < item.start_delay then
    return
  end

  local travel = (frame - item.start_delay) * item.speed * unit
  local x

  if item.direction == "right" then
    x = -item.width - item.start_offset + travel
  else
    x = width + item.start_offset - travel
  end

  draw_sprite(item.image, x, item.y, width, height)
end

local function draw_frame(frame, width, height, unit, water_color, sealife, floor_layout)
  local sand_color = panel_color(SAND_COLOR)
  display.begin_frame({ clear = true, color = water_color, preserve = false })
  display.fill_rect(0, 0, width, height, water_color)
  display.fill_rect(0, height - 2 * unit, width, unit, sand_color)

  if floor_layout[2] then
    draw_sprite(floor_layout[2].item.image, floor_layout[2].x, floor_layout[2].y, width, height)
  end

  for i, item in ipairs(sealife) do
    draw_fish(item, frame, width, height, unit)
  end

  for i, placed in ipairs(floor_layout) do
    if i ~= 2 then
      draw_sprite(placed.item.image, placed.x, placed.y, width, height)
    end
  end
  display.fill_rect(0, height - unit, width, unit, sand_color)
  display.present()
  display.end_frame()
end

local function make_scene(width, height, unit, water_color_arg)
  local floor_layout = make_floor_layout(unit, width, height)
  local floor_items = {}
  for i, placed in ipairs(floor_layout) do
    floor_items[i] = placed.item
  end

  local sealife = make_sealife(unit, width, height, floor_items)
  local water_color = pick_water_color(water_color_arg)
  local frame_count = 1

  for _, item in ipairs(sealife) do
    local crossing = width + item.width * 2 + item.start_offset
    local frames = crossing // math.max(1, item.speed * unit)
    frames = frames + item.start_delay
    if frames > frame_count then
      frame_count = frames
    end
  end

  return {
    water_color = water_color,
    sealife = sealife,
    floor_layout = floor_layout,
    frame_count = math.max(1, frame_count),
  }
end

local function release_sprite(item)
  if item and item.image then
    item.image.spans = nil
    item.image = nil
  end
end

local function release_scene(scene)
  if not scene then
    return
  end

  for _, item in ipairs(scene.sealife or {}) do
    release_sprite(item)
  end
  for _, placed in ipairs(scene.floor_layout or {}) do
    release_sprite(placed.item)
  end

  scene.sealife = nil
  scene.floor_layout = nil
  collectgarbage("collect")
end

local function main()
  local seed = ctx.seed
  if seed == 0 then
    seed = os.time()
  end
  math.randomseed(seed)

  local width, height = setup_display()
  local unit = 1
  local water_color_arg = string_arg("water_color", DEFAULT_WATER_COLOR)
  local scene = make_scene(width, height, unit, water_color_arg)
  active_scene = scene
  local elapsed_ms = 0
  local frame = 0

  while ctx.duration_ms == 0 or elapsed_ms < ctx.duration_ms do
    if frame >= scene.frame_count then
      release_scene(scene)
      scene = make_scene(width, height, unit, water_color_arg)
      active_scene = scene
      frame = 0
    end

    draw_frame(frame, width, height, unit, scene.water_color, scene.sealife, scene.floor_layout)
    frame = frame + 1
    elapsed_ms = elapsed_ms + ctx.frame_delay_ms
    delay.delay_ms(ctx.frame_delay_ms)
  end

  release_scene(scene)
  active_scene = nil
end

local ok, err = pcall(main)
release_scene(active_scene)
if display_started then
  pcall(display.end_frame)
  pcall(display.deinit)
end

if not ok then
  error(err)
end
