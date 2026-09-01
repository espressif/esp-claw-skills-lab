-- Game of Life — immersive Rainbow Conway B3/S23 for ESP-Claw displays.
-- Full-screen ink canvas (no HUD / buttons / status text).
-- Gestures: drag paint, long-press reset; shake (IMU) when Lua imu module exists.
-- Mosaico QSPI AMOLED (CO5300 480x480): full-frame begin_frame/present/end_frame only.
-- On current Mosaico firmware, require("imu") is unavailable so shake is disabled.

local bm = require("board_manager")
local display = require("display")
local delay = require("delay")

local lcd_touch_ok, lcd_touch = pcall(require, "lcd_touch")
local button_ok, button = pcall(require, "button")
local imu_ok, imu = pcall(require, "imu")

local args_tbl = type(args) == "table" and args or {}

-- math.atan2 was removed in Lua 5.3+; math.atan accepts (y, x) there.
local atan2 = math.atan2 or function(y, x)
  return math.atan(y, x)
end

local function clamp(v, lo, hi)
  if v < lo then
    return lo
  end
  if v > hi then
    return hi
  end
  return v
end

local FRAME_MS = 5          -- 200 Hz input is responsive without starving the S3 render task
local DISPLAY_MS = 40       -- 25 fps present probe
local IMU_POLL_MS = 40
local STEP_MS = 40          -- faster gens; present stays DISPLAY_MS
local RUN_TIME_MS = 0        -- 0 = until launcher stops the skill
local LONG_PRESS_MS = 550   -- hold still to reset
local DRAG_THRESH_PX = 16   -- jitter below this is still a long-press, not a drag
local SHAKE_COOLDOWN_MS = 900
local IMU_WARMUP_SAMPLES = 12
-- Relative spike vs resting accel magnitude; scale-free so raw LSB / mg / g all work.
local IMU_SHAKE_RATIO = 0.38
-- Balanced composition (~S3-BOX 320x240 → cell≈9 → ~910 tiles).
local TARGET_CELLS = 900
local MIN_CELL_PX = 9
local MAX_CELL_PX = 24
local SHAKE_FX_MS = 400
local BIRTH_PULSE_FRAMES = 3
local DEATH_FADE_FRAMES = 2
local TRANSITION_LIMIT = 240
local display_ms_overridden = false
local step_ms_overridden = false
local cell_px_override = nil

if type(args_tbl.touch_ms) == "number" and args_tbl.touch_ms >= 1 then
  FRAME_MS = math.floor(args_tbl.touch_ms)
end
if type(args_tbl.display_ms) == "number" and args_tbl.display_ms >= 12 then
  DISPLAY_MS = math.floor(args_tbl.display_ms)
  display_ms_overridden = true
end
if type(args_tbl.step_ms) == "number" and args_tbl.step_ms >= 20 then
  STEP_MS = math.floor(args_tbl.step_ms)
  step_ms_overridden = true
end
if type(args_tbl.target_cells) == "number" and args_tbl.target_cells >= 80 then
  TARGET_CELLS = math.floor(args_tbl.target_cells)
end
if type(args_tbl.cell_px) == "number" and args_tbl.cell_px >= 4 then
  cell_px_override = math.floor(args_tbl.cell_px)
end
if type(args_tbl.run_time_ms) == "number" and args_tbl.run_time_ms >= 0 then
  RUN_TIME_MS = math.floor(args_tbl.run_time_ms)
end
if type(args_tbl.transition_limit) == "number" and args_tbl.transition_limit >= 0 then
  TRANSITION_LIMIT = math.floor(args_tbl.transition_limit)
end

if type(args_tbl.shake_sensitivity) == "number" and args_tbl.shake_sensitivity > 0 then
  IMU_SHAKE_RATIO = clamp(IMU_SHAKE_RATIO / args_tbl.shake_sensitivity, 0.25, 1.2)
end

-- Prefer denser grids; only bump cell size if far over soft budget.
local function pick_cell_size(screen_w, play_h)
  if cell_px_override then
    return clamp(cell_px_override, 4, MAX_CELL_PX)
  end
  local area = math.max(1, screen_w * play_h)
  local cell = math.floor(math.sqrt(area / TARGET_CELLS) + 0.5)
  cell = clamp(cell, MIN_CELL_PX, MAX_CELL_PX)
  while (screen_w // cell) * (play_h // cell) > math.floor(TARGET_CELLS * 1.25) and cell < MAX_CELL_PX do
    cell = cell + 1
  end
  return cell
end

local function auto_tune_timing(n)
  if not display_ms_overridden then
    DISPLAY_MS = 40
  end
  if not step_ms_overridden then
    STEP_MS = 40
  end
end

local INK = { r = 4, g = 8, b = 10 }
local DEEP_TEAL = { r = 10, g = 28, b = 32 }
local TEAL = { r = 30, g = 205, b = 186 }
local CYAN = { r = 126, g = 247, b = 236 }
local CORAL = { r = 255, g = 92, b = 63 }
local WHITE = { r = 255, g = 255, b = 255 }

local input_mode = "none"
local touch_handle = nil
local button_handle = nil
local button_active_level = 0
local button_last_level = 1
local button_down_ms = 0
local button_fired_hold = false
local paint_hue = 28
local last_step_ms = 0
local last_display_ms = 0
local last_imu_ms = 0
local shake_fx_ms = 0
local shake_cooldown_ms = 0
local shake_dir_x, shake_dir_y = 1, 0
local event_feedback_ms = 0
local event_feedback_color = TEAL
local event_feedback_draw_level = -1
local low_population_steps = 0
local tap_seed_index = 1
local stroke_cell_count = 0
local revive_world = nil
local screen_created = false
local world_dirty = true
local need_full_redraw = true
local last_paint_x, last_paint_y = -1, -1
local painting = false
local erase_mode = false
-- Touch gesture tracking (chrome-less).
local touch_down = false
local touch_down_ms = 0
local touch_start_x, touch_start_y = 0, 0
local touch_moved = false
local touch_long_fired = false

local imu_sensor = nil
local imu_enabled = false
local imu_have_prev = false
local imu_prev_x, imu_prev_y, imu_prev_z = 0, 0, 0
local imu_mag_ema = 0
local imu_warmup = 0
local imu_device_name = "imu_sensor"

-- Forward-declared; filled after grid size is known / used by inherit_hue_n.
local parent_hues = { 0, 0, 0, 0, 0, 0, 0, 0 }

if type(args_tbl.imu_device) == "string" and args_tbl.imu_device ~= "" then
  imu_device_name = args_tbl.imu_device
end

local function rgb(r, g, b)
  return { r = r, g = g, b = b }
end

local function wrap_hue(h)
  h = h % 360
  if h < 0 then
    h = h + 360
  end
  return h
end

local function hue_to_rgb(h, sat, light)
  sat = sat or 0.78
  light = light or 0.56
  h = wrap_hue(h) / 360
  local function hue2rgb(p, q, t)
    if t < 0 then
      t = t + 1
    end
    if t > 1 then
      t = t - 1
    end
    if t < 1 / 6 then
      return p + (q - p) * 6 * t
    end
    if t < 1 / 2 then
      return q
    end
    if t < 2 / 3 then
      return p + (q - p) * (2 / 3 - t) * 6
    end
    return p
  end
  local q
  if light < 0.5 then
    q = light * (1 + sat)
  else
    q = light + sat - light * sat
  end
  local p = 2 * light - q
  return rgb(
    math.floor(hue2rgb(p, q, h + 1 / 3) * 255 + 0.5),
    math.floor(hue2rgb(p, q, h) * 255 + 0.5),
    math.floor(hue2rgb(p, q, h - 1 / 3) * 255 + 0.5)
  )
end

local function mix_rgb(a, b, t)
  t = clamp(t, 0, 1)
  return rgb(
    math.floor(a.r + (b.r - a.r) * t + 0.5),
    math.floor(a.g + (b.g - a.g) * t + 0.5),
    math.floor(a.b + (b.b - a.b) * t + 0.5)
  )
end

local function mix_rgb_into(out, a, b, t)
  t = clamp(t, 0, 1)
  out.r = math.floor(a.r + (b.r - a.r) * t + 0.5)
  out.g = math.floor(a.g + (b.g - a.g) * t + 0.5)
  out.b = math.floor(a.b + (b.b - a.b) * t + 0.5)
  return out
end

local function hue_delta(a, b)
  local d = math.abs(a - b) % 360
  if d > 180 then
    d = 360 - d
  end
  return d
end

local function mean_hue(hues)
  if #hues == 0 then
    return 170
  end
  local x, y = 0, 0
  for i = 1, #hues do
    local r = hues[i] * math.pi / 180
    x = x + math.cos(r)
    y = y + math.sin(r)
  end
  return wrap_hue(atan2(y, x) * 180 / math.pi)
end

local function circular_span(hues)
  local maxd = 0
  for i = 1, #hues do
    for j = i + 1, #hues do
      local d = hue_delta(hues[i], hues[j])
      if d > maxd then
        maxd = d
      end
    end
  end
  return maxd
end

local function inherit_hue(hues)
  if #hues == 0 then
    return math.random() * 360
  end
  local hue
  local span = circular_span(hues)
  if span > 100 or math.random() < 0.4 then
    hue = hues[math.random(1, #hues)]
  else
    hue = mean_hue(hues)
  end
  hue = hue + (math.random() - 0.5) * 56
  return wrap_hue(hue)
end

-- Same as inherit_hue but reads the reusable parent_hues[1..n] buffer (no alloc).
local function inherit_hue_n(n)
  if n <= 0 then
    return math.random() * 360
  end
  local maxd = 0
  for i = 1, n do
    for j = i + 1, n do
      local d = hue_delta(parent_hues[i], parent_hues[j])
      if d > maxd then
        maxd = d
      end
    end
  end
  local hue
  if maxd > 100 or math.random() < 0.4 then
    hue = parent_hues[math.random(1, n)]
  else
    local x, y = 0, 0
    for i = 1, n do
      local r = parent_hues[i] * math.pi / 180
      x = x + math.cos(r)
      y = y + math.sin(r)
    end
    hue = wrap_hue(atan2(y, x) * 180 / math.pi)
  end
  return wrap_hue(hue + (math.random() - 0.5) * 110)
end

-- Display init ---------------------------------------------------------------

-- board_manager may either return nil+err or raise, depending on the board YAML.
local params_ok, panel_handle, io_handle, width, height, panel_if =
  pcall(bm.get_display_lcd_params, "display_lcd")
if not params_ok then
  print("[mosaico] ERROR: get_display_lcd_params(display_lcd) raised: " .. tostring(panel_handle))
  return
end
if not panel_handle then
  print("[mosaico] ERROR: get_display_lcd_params(display_lcd) failed: " .. tostring(io_handle))
  return
end

local ok, err = pcall(display.init, panel_handle, io_handle, width, height, panel_if)
if not ok then
  print("[mosaico] ERROR: init failed: " .. tostring(err))
  return
end
screen_created = true

local function cleanup()
  if imu_sensor then
    pcall(function()
      imu_sensor:close()
    end)
    imu_sensor = nil
    imu_enabled = false
  end
  if button_handle then
    pcall(button.off, button_handle)
    pcall(button.close, button_handle)
    button_handle = nil
  end
  if screen_created then
    pcall(display.end_frame)
    pcall(display.deinit)
    screen_created = false
  end
end

width = display.width
height = display.height
if width <= 0 or height <= 0 then
  print("[mosaico] ERROR: invalid display size after init")
  cleanup()
  return
end

local play_h = height
local cell = pick_cell_size(width, play_h)
local grid_w = width // cell
local grid_h = play_h // cell
local grid_px_w = grid_w * cell
local grid_px_h = grid_h * cell
local grid_ox = (width - grid_px_w) // 2
local grid_oy = (play_h - grid_px_h) // 2
local n_cells = grid_w * grid_h
auto_tune_timing(n_cells)
local LIVE_BUDGET = {
  soft = math.floor(n_cells * 0.30),
  hard = math.floor(n_cells * 0.42),
}

-- Static low-cost culture-medium background. Broad bands cross tile boundaries
-- and make the field feel spatial without consuming per-frame animation budget.
local BG_BANDS = grid_h
local bg_colors = {}
for b = 1, BG_BANDS do
  local t = (b - 0.5) / BG_BANDS
  local center = 1 - math.abs(t * 2 - 1)
  local drift = math.sin(t * math.pi * 2)
  -- RGB565 panels crush very dark values. Keep the substrate visibly blue
  -- while preserving enough contrast for saturated organisms.
  bg_colors[b] = rgb(
    math.floor(6 + center * 5 + math.max(0, drift) * 6),
    math.floor(12 + center * 24 + math.max(0, -drift) * 6),
    math.floor(26 + center * 24 + math.abs(drift) * 6)
  )
end

local cells = {}
local next_cells = {}
local hues = {}
local next_hues = {}
local birth = {}
local pulse = {} -- birth flash frames remaining
local fade_age = {} -- death afterglow frames remaining
local fade_r = {}
local fade_g = {}
local fade_b = {}
local color_r = {}
local color_g = {}
local color_b = {}
local age = {}
local next_age = {}
local dirty = {}
local dirty_mark = {}
local eval_list = {}
local eval_mark = {}
local neighbor_counts = {}
local live_list = {}
local live_list_dirty = false
local live_count = 0
local carry_fx_buf = {}
local keep_fx_buf = {}
local generation = 0
local rendered_frames = 0
local tick_count = 0

for i = 1, n_cells do
  cells[i] = 0
  next_cells[i] = 0
  hues[i] = 0
  next_hues[i] = 0
  birth[i] = 0
  pulse[i] = 0
  fade_age[i] = 0
  fade_r[i] = 0
  fade_g[i] = 0
  fade_b[i] = 0
  color_r[i] = 0
  color_g[i] = 0
  color_b[i] = 0
  age[i] = 0
  next_age[i] = 0
  dirty_mark[i] = false
  eval_mark[i] = false
  neighbor_counts[i] = 0
end

local scratch_color = { r = 0, g = 0, b = 0 }
local scratch_core = { r = 0, g = 0, b = 0 }
local scratch_base = { r = 0, g = 0, b = 0 }
local scratch_edge_outer = { r = 0, g = 0, b = 0 }
local scratch_edge_inner = { r = 0, g = 0, b = 0 }

local function idx(x, y)
  return y * grid_w + x + 1
end

local function in_bounds(x, y)
  return x >= 0 and y >= 0 and x < grid_w and y < grid_h
end

local function get_cell(x, y)
  if not in_bounds(x, y) then
    return 0
  end
  return cells[idx(x, y)]
end

local function clear_dirty()
  for d = 1, #dirty do
    dirty_mark[dirty[d]] = false
  end
  dirty = {}
end

local function mark_dirty(i)
  if not dirty_mark[i] then
    dirty_mark[i] = true
    dirty[#dirty + 1] = i
  end
end

local function clear_eval()
  for e = 1, #eval_list do
    eval_mark[eval_list[e]] = false
  end
  eval_list = {}
end

local function mark_eval(i)
  if not eval_mark[i] then
    eval_mark[i] = true
    eval_list[#eval_list + 1] = i
  end
end

local function cache_cell_color(i)
  -- Full-spectrum emitter color. Lower lightness avoids pastel/washed-out RGB
  -- while maximum saturation keeps red, green, blue, and magenta equally vivid.
  local years = age[i] or 0
  local light = birth[i] == 1 and 0.60 or (years >= 24 and 0.43 or (years >= 6 and 0.48 or 0.52))
  local sat = 1.0
  local c = hue_to_rgb(hues[i], sat, light)
  color_r[i] = c.r
  color_g[i] = c.g
  color_b[i] = c.b
end

local function rebuild_live_list()
  live_list = {}
  for i = 1, n_cells do
    if cells[i] == 1 then
      live_list[#live_list + 1] = i
    end
  end
  live_count = #live_list
  live_list_dirty = false
end

local function start_afterglow(i)
  fade_age[i] = DEATH_FADE_FRAMES
  fade_r[i] = math.floor(color_r[i] * 0.35 + DEEP_TEAL.r * 0.25)
  fade_g[i] = math.floor(color_g[i] * 0.35 + DEEP_TEAL.g * 0.25)
  fade_b[i] = math.floor(color_b[i] * 0.35 + DEEP_TEAL.b * 0.25)
end

local function set_cell(x, y, alive, hue)
  if not in_bounds(x, y) then
    return
  end
  local i = idx(x, y)
  local prev = cells[i]
  if alive == 1 then
    cells[i] = 1
    hues[i] = wrap_hue(hue or 170)
    birth[i] = 1
    pulse[i] = BIRTH_PULSE_FRAMES
    age[i] = 0
    fade_age[i] = 0
    cache_cell_color(i)
  else
    if prev == 1 then
      start_afterglow(i)
    end
    cells[i] = 0
    hues[i] = 0
    birth[i] = 0
    pulse[i] = 0
    age[i] = 0
  end
  if prev ~= cells[i] or alive == 1 then
    mark_dirty(i)
  end
  if prev ~= cells[i] then
    live_count = live_count + (cells[i] == 1 and 1 or -1)
    live_list_dirty = true
  end
end

-- Count neighbors; if want_parents, also fill parent_hues[1..n] (for births only).
local function neighbor_count_parents(x, y, want_parents)
  local n = 0
  local pn = 0
  for dy = -1, 1 do
    local ny = y + dy
    if ny >= 0 and ny < grid_h then
      local row = ny * grid_w
      for dx = -1, 1 do
        if not (dx == 0 and dy == 0) then
          local nx = x + dx
          if nx >= 0 and nx < grid_w then
            local ni = row + nx + 1
            if cells[ni] == 1 then
              n = n + 1
              if want_parents then
                pn = pn + 1
                parent_hues[pn] = hues[ni]
              end
            end
          end
        end
      end
    end
  end
  return n, pn
end

local function clear_world()
  for i = 1, n_cells do
    cells[i] = 0
    hues[i] = 0
    birth[i] = 0
    pulse[i] = 0
    fade_age[i] = 0
    age[i] = 0
    next_age[i] = 0
  end
  live_list = {}
  live_count = 0
  live_list_dirty = false
  clear_dirty()
  clear_eval()
  generation = 0
  need_full_redraw = true
end

local function paint(x, y, alive, hue)
  set_cell(x, y, alive, hue)
end

local function spice_hues()
  if #live_list < 10 then
    return
  end
  local living_hues = {}
  for i = 1, #live_list do
    living_hues[i] = hues[live_list[i]]
  end
  local mean = mean_hue(living_hues)
  local var_sum = 0
  for i = 1, #living_hues do
    var_sum = var_sum + hue_delta(living_hues[i], mean)
  end
  if var_sum / #living_hues > 55 then
    return
  end
  local count = math.max(3, math.floor(#live_list * 0.08))
  for _ = 1, count do
    local i = live_list[math.random(1, #live_list)]
    hues[i] = wrap_hue(mean + 110 + math.random() * 140)
    birth[i] = 1
    pulse[i] = BIRTH_PULSE_FRAMES
    cache_cell_color(i)
    mark_dirty(i)
  end
end

local function step_world()
  -- Touch painting mutates cells between generations. Synchronize the sparse
  -- active set before evaluation so freshly painted/erased cells obey B3/S23
  -- immediately and cannot leave stale LCD pixels outside the dirty set.
  if live_list_dirty then
    rebuild_live_list()
  end
  for i = 1, #carry_fx_buf do carry_fx_buf[i] = nil end
  for d = 1, #dirty do
    local i = dirty[d]
    if pulse[i] > 0 or fade_age[i] > 0 then carry_fx_buf[#carry_fx_buf + 1] = i end
  end
  -- Zero next board. 2k writes is cheap vs scanning every cell's 8 neighbors in Lua.
  for i = 1, n_cells do
    next_cells[i] = 0
    next_age[i] = 0
    birth[i] = 0
  end

  -- One pass over live cells builds all Moore-neighbor counts. This avoids
  -- rescanning eight neighbors for every candidate and removes the 90 ms CPU spike.
  clear_eval()
  for li = 1, #live_list do
    local i = live_list[li]
    local x = (i - 1) % grid_w
    local y = (i - 1) // grid_w
    mark_eval(i) -- isolated live cells must still be evaluated with count 0
    for dy = -1, 1 do
      local ny = y + dy
      if ny >= 0 and ny < grid_h then
        for dx = -1, 1 do
          local nx = x + dx
          if not (dx == 0 and dy == 0) and nx >= 0 and nx < grid_w then
            local ni = ny * grid_w + nx + 1
            mark_eval(ni)
            neighbor_counts[ni] = neighbor_counts[ni] + 1
          end
        end
      end
    end
  end

  clear_dirty()
  for e = 1, #eval_list do
    local i = eval_list[e]
    local x = (i - 1) % grid_w
    local y = (i - 1) // grid_w
    local alive = cells[i]
    local n = neighbor_counts[i]
    if alive == 1 then
      if n == 2 or n == 3 then
        next_cells[i] = 1
        next_age[i] = math.min(255, age[i] + 1)
        -- Hue drift is data-only: do NOT mark_dirty, or every survivor redraws each gen.
        next_hues[i] = wrap_hue(hues[i] + (math.random() - 0.5) * 8)
      else
        start_afterglow(i)
        mark_dirty(i)
      end
    else
      if n == 3 then
        local _, pn = neighbor_count_parents(x, y, true)
        next_cells[i] = 1
        next_age[i] = 0
        next_hues[i] = inherit_hue_n(pn)
        birth[i] = 1
        pulse[i] = BIRTH_PULSE_FRAMES
        fade_age[i] = 0
        mark_dirty(i)
      end
    end
    neighbor_counts[i] = 0
  end

  cells, next_cells = next_cells, cells
  hues, next_hues = next_hues, hues
  age, next_age = next_age, age

  for k = 1, #carry_fx_buf do
    local i = carry_fx_buf[k]
    if (cells[i] == 1 and pulse[i] > 0) or (cells[i] == 0 and fade_age[i] > 0) then
      mark_dirty(i)
    end
  end

  for d = 1, #dirty do
    local i = dirty[d]
    if cells[i] == 1 then
      cache_cell_color(i)
    end
  end

  rebuild_live_list()
  -- Age color changes are sparse milestones, not per-frame full-board work.
  for li = 1, #live_list do
    local i = live_list[li]
    if age[i] == 6 or age[i] == 24 then
      cache_cell_color(i)
      mark_dirty(i)
    end
  end

  -- Dense explosions skip temporal staging but still render the correct final state.
  local effective_transition_limit = TRANSITION_LIMIT
  if live_count > LIVE_BUDGET.hard then
    effective_transition_limit = 0
  elseif live_count > LIVE_BUDGET.soft then
    effective_transition_limit = math.min(100, TRANSITION_LIMIT)
  end
  if #dirty > effective_transition_limit then
    for d = 1, #dirty do
      local i = dirty[d]
      pulse[i] = 0
      fade_age[i] = 0
    end
  end

  generation = generation + 1
  if generation % 18 == 0 then
    spice_hues()
  end
  if #live_list < 3 then
    low_population_steps = low_population_steps + 1
  else
    low_population_steps = 0
  end
  if low_population_steps >= 6 and revive_world then
    revive_world()
  end
  world_dirty = (#dirty > 0)
end

local function sow_sparks(clusters)
  local shapes = {
    { { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } },
    { { 0, 0 }, { 1, 0 }, { 2, 0 }, { 0, 1 }, { 1, 2 } },
    { { 0, 0 }, { 1, 0 }, { 2, 0 } },
  }
  local centers = {}
  local max_ox = math.max(0, grid_w - 6)
  local max_oy = math.max(0, grid_h - 6)
  for _ = 1, clusters do
    local shape = shapes[math.random(1, #shapes)]
    local ox = 2 + math.random(0, max_ox)
    local oy = 2 + math.random(0, max_oy)
    local hue = math.random() * 360
    for s = 1, #shape do
      local x = ox + shape[s][1]
      local y = oy + shape[s][2]
      set_cell(x, y, 1, hue)
    end
    centers[#centers + 1] = { x = ox, y = oy }
  end
  return centers
end

local function shake_random()
  local dirs = {
    { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 },
    { 1, 1 }, { -1, -1 }, { 1, -1 }, { -1, 1 },
  }
  local block = 3
  local bw = math.ceil(grid_w / block)
  local bh = math.ceil(grid_h / block)
  local moves = {}
  for b = 0, bw * bh - 1 do
    local d = dirs[math.random(1, #dirs)]
    local dist = 1 + math.random(0, 2)
    moves[b] = { d[1] * dist, d[2] * dist }
  end

  for i = 1, n_cells do
    next_cells[i] = 0
    next_hues[i] = 0
    next_age[i] = 0
    birth[i] = 0
  end

  for y = 0, grid_h - 1 do
    for x = 0, grid_w - 1 do
      local i = idx(x, y)
      if cells[i] == 1 then
        local b = (y // block) * bw + (x // block)
        local m = moves[b]
        local nx, ny = x + m[1], y + m[2]
        if in_bounds(nx, ny) then
          local ni = idx(nx, ny)
          next_cells[ni] = 1
          next_hues[ni] = hues[i]
          next_age[ni] = age[i]
          birth[ni] = 1
        end
      end
    end
  end

  cells, next_cells = next_cells, cells
  hues, next_hues = next_hues, hues
  age, next_age = next_age, age
  local centers = sow_sparks(math.min(6, math.max(3, math.floor(n_cells / 240))))
  rebuild_live_list()
  for i = 1, #live_list do
    cache_cell_color(live_list[i])
  end
  need_full_redraw = true
  return centers
end

local function seed_demo()
  clear_world()
  local mid_x = grid_w // 2
  local mid_y = grid_h // 2
  -- glider near top-left (clamped)
  local gx0 = math.min(2, math.max(0, grid_w - 5))
  local gy0 = math.min(2, math.max(0, grid_h - 5))
  local g = { { 1, 0 }, { 2, 1 }, { 0, 2 }, { 1, 2 }, { 2, 2 } }
  for i = 1, #g do
    set_cell(gx0 + g[i][1], gy0 + g[i][2], 1, 200)
  end
  -- blinker
  local bx = clamp(mid_x - 1, 0, math.max(0, grid_w - 3))
  local by = clamp(mid_y, 0, grid_h - 1)
  for x = 0, 2 do
    set_cell(bx + x, by, 1, 40)
  end
  -- block
  local kx = clamp(mid_x + 4, 0, math.max(0, grid_w - 2))
  local ky = clamp(mid_y - 2, 0, math.max(0, grid_h - 2))
  for dy = 0, 1 do
    for dx = 0, 1 do
      set_cell(kx + dx, ky + dy, 1, 120)
    end
  end
  -- Bound initial population so a denser grid does not multiply active work.
  for _ = 1, math.min(30, math.max(12, math.floor(n_cells * 0.025))) do
    local x = math.random(0, grid_w - 1)
    local y = math.random(0, grid_h - 1)
    set_cell(x, y, 1, math.random() * 360)
  end
  sow_sparks(3)
  rebuild_live_list()
  for i = 1, #live_list do
    cache_cell_color(live_list[i])
  end
  need_full_redraw = true
end

-- Gestures / mapping helpers -------------------------------------------------

local function screen_to_cell(px, py)
  local x = (px - grid_ox) // cell
  local y = (py - grid_oy) // cell
  if in_bounds(x, y) then
    return x, y
  end
  return nil, nil
end

local function touch_dist2(ax, ay, bx, by)
  local dx, dy = ax - bx, ay - by
  return dx * dx + dy * dy
end

-- Render ---------------------------------------------------------------------

local scratch_fade = { r = 0, g = 0, b = 0 }

local function cell_px(x, y)
  return grid_ox + x * cell, grid_oy + y * cell
end

local function fill_cell_index(i, color)
  local x = (i - 1) % grid_w
  local y = (i - 1) // grid_w
  local px, py = cell_px(x, y)
  display.fill_rect(px, py, cell, cell, color)
end

local function background_color_for_y(y)
  local band = clamp((y - grid_oy) // cell + 1, 1, BG_BANDS)
  return bg_colors[band]
end

local function clear_cell_index(i)
  local y = (i - 1) // grid_w
  fill_cell_index(i, background_color_for_y(grid_oy + y * cell + cell // 2))
end

local function draw_background()
  local bands = 6
  local y = 0
  for b = 1, bands do
    local y1 = height * b // bands
    local idx = 1 + (b - 1) * (BG_BANDS - 1) // (bands - 1)
    if idx < 1 then idx = 1 end
    if idx > BG_BANDS then idx = BG_BANDS end
    display.fill_rect(0, y, width, y1 - y, bg_colors[idx])
    y = y1
  end
end

-- Bioluminescent glass tile: dark pedestal + bright inset core (+ birth spark).
local function draw_live_index(i, offset_x, offset_y)
  local x = (i - 1) % grid_w
  local y = (i - 1) // grid_w
  local px, py = cell_px(x, y)
  px = px + (offset_x or 0)
  py = py + (offset_y or 0)
  scratch_color.r = color_r[i]
  scratch_color.g = color_g[i]
  scratch_color.b = color_b[i]
  local core = scratch_color
  if pulse[i] > 0 then
    local t = pulse[i] / BIRTH_PULSE_FRAMES
    core = mix_rgb_into(scratch_core, scratch_color, WHITE, 0.10 + t * 0.12)
    local size = pulse[i] == 3 and math.max(2, cell // 4)
      or (pulse[i] == 2 and math.max(3, cell // 2) or cell)
    display.fill_rect(px + (cell - size) // 2, py + (cell - size) // 2, size, size, core)
    return
  end
  display.fill_rect(px, py, cell, cell, core)
end

local function draw_fade_index(i, offset_x, offset_y)
  scratch_fade.r = fade_r[i]
  scratch_fade.g = fade_g[i]
  scratch_fade.b = fade_b[i]
  local size = fade_age[i] >= 2 and math.max(3, cell * 3 // 4) or math.max(2, cell // 3)
  local x = (i - 1) % grid_w
  local y = (i - 1) // grid_w
  local px, py = cell_px(x, y)
  px = px + (offset_x or 0)
  py = py + (offset_y or 0)
  display.fill_rect(px + (cell - size) // 2, py + (cell - size) // 2, size, size, scratch_fade)
end

local tap_patterns = {
  { { 1, 0 }, { 2, 1 }, { 0, 2 }, { 1, 2 }, { 2, 2 } }, -- glider
  { { -1, 0 }, { 0, 0 }, { 1, 0 } },                    -- blinker
  { { 0, -1 }, { 1, -1 }, { -1, 0 }, { 0, 0 }, { 0, 1 } }, -- R-pentomino
}

local function stamp_tap_seed(cx, cy)
  local pattern = tap_patterns[tap_seed_index]
  local hue = paint_hue
  for p = 1, #pattern do
    set_cell(cx + pattern[p][1], cy + pattern[p][2], 1, wrap_hue(hue + p * 9))
  end
  tap_seed_index = tap_seed_index % #tap_patterns + 1
  paint_hue = wrap_hue(paint_hue + 83)
  rebuild_live_list()
  event_feedback_color = hue_to_rgb(hue, 1.0, 0.5)
  event_feedback_ms = 180
  event_feedback_draw_level = -1
  world_dirty = true
end

revive_world = function()
  sow_sparks(3)
  rebuild_live_list()
  for li = 1, #live_list do cache_cell_color(live_list[li]) end
  low_population_steps = 0
  event_feedback_color = CORAL
  event_feedback_ms = 180
  event_feedback_draw_level = -1
  world_dirty = true
end

local function draw_scene(offset_x, offset_y)
  draw_background()
  for li = 1, #live_list do
    local i = live_list[li]
    draw_live_index(i, offset_x, offset_y)
    if pulse[i] > 0 then
      pulse[i] = pulse[i] - 1
    end
  end
  for i = 1, n_cells do
    if cells[i] == 0 and fade_age[i] > 0 then
      draw_fade_index(i, offset_x, offset_y)
      fade_age[i] = fade_age[i] - 1
    end
  end
end

local function draw_dirty_cells()
  for i = 1, #keep_fx_buf do keep_fx_buf[i] = nil end
  for d = 1, #dirty do
    local i = dirty[d]
    if cells[i] == 1 then
      fade_age[i] = 0
      draw_live_index(i)
      if pulse[i] > 0 then
        pulse[i] = pulse[i] - 1
        if pulse[i] > 0 then keep_fx_buf[#keep_fx_buf + 1] = i end
      end
    elseif fade_age[i] > 0 then
      draw_fade_index(i)
      fade_age[i] = fade_age[i] - 1
      if fade_age[i] > 0 then keep_fx_buf[#keep_fx_buf + 1] = i else clear_cell_index(i) end
    else
      clear_cell_index(i)
    end
  end
  for d = 1, #dirty do
    dirty_mark[dirty[d]] = false
  end
  dirty = {}
  for k = 1, #keep_fx_buf do
    mark_dirty(keep_fx_buf[k])
  end
  if #keep_fx_buf > 0 then
    world_dirty = true
  end
end

local function paint_one_fast(x, y, alive, hue)
  if not in_bounds(x, y) then return false end
  if alive == 1 and get_cell(x, y) == 0 and live_count >= LIVE_BUDGET.hard then
    return false
  end
  paint(x, y, alive, hue)
  world_dirty = true
  -- Drawing is intentionally deferred to the 25 ms visual scheduler. Touch
  -- used to paint here and then redraw the same dirty cell again, doubling work.
  return true
end

local function paint_cell_fast(x, y, alive, hue)
  event_feedback_ms = math.max(event_feedback_ms, 120)
  world_dirty = true
  if x == last_paint_x and y == last_paint_y then return false end
  if last_paint_x < 0 then
    last_paint_x, last_paint_y = x, y
    return paint_one_fast(x, y, alive, hue)
  end

  local x0, y0 = last_paint_x, last_paint_y
  local dx = math.abs(x - x0)
  local sx = x0 < x and 1 or -1
  local dy = -math.abs(y - y0)
  local sy = y0 < y and 1 or -1
  local err = dx + dy
  local steps = 0
  while steps < 16 do
    if not (x0 == last_paint_x and y0 == last_paint_y) then
      stroke_cell_count = stroke_cell_count + 1
      local sparse_dense_brush = alive == 1 and live_count >= LIVE_BUDGET.soft
      if not sparse_dense_brush or stroke_cell_count % 2 == 0 then
        paint_one_fast(x0, y0, alive, hue)
      end
      -- Sparse deterministic side spores make a viable organic ribbon without
      -- changing the rules applied after injection.
      if alive == 1 and live_count < LIVE_BUDGET.soft and stroke_cell_count % 5 == 0 then
        local side_x, side_y = -sy, sx
        paint_one_fast(x0 + side_x, y0 + side_y, 1, wrap_hue(hue + 37))
      end
    end
    if x0 == x and y0 == y then break end
    local e2 = 2 * err
    if e2 >= dy then err = err + dy; x0 = x0 + sx end
    if e2 <= dx then err = err + dx; y0 = y0 + sy end
    steps = steps + 1
  end
  last_paint_x, last_paint_y = x, y
  return true
end

local function begin_paint_at(px, py)
  local cx, cy = screen_to_cell(px, py)
  if cx == nil then
    return false
  end
  painting = true
  erase_mode = get_cell(cx, cy) == 1
  event_feedback_color = erase_mode and CORAL or hue_to_rgb(paint_hue, 1.0, 0.52)
  event_feedback_ms = 180
  event_feedback_draw_level = -1
  last_paint_x, last_paint_y = -1, -1
  stroke_cell_count = 0
  paint_cell_fast(cx, cy, erase_mode and 0 or 1, paint_hue)
  paint_hue = wrap_hue(paint_hue + 11)
  return true
end

local function draw_shaken_scene()
  local t = 1 - shake_fx_ms / SHAKE_FX_MS
  t = clamp(t, 0, 1)
  local units
  if t < 0.18 then
    units = 1.1 * (t / 0.18)
  elseif t < 0.55 then
    units = 1.1 - 1.5 * ((t - 0.18) / 0.37)
  else
    units = -0.4 * (1 - (t - 0.55) / 0.45)
  end
  local amplitude = cell * units
  local ox = math.floor(shake_dir_x * amplitude)
  local oy = math.floor(shake_dir_y * amplitude)

  draw_background()

  -- Two dim motion echoes make displacement direction legible without turning
  -- the effect into a decorative shockwave.
  if t <= 0.60 then
    local trail = mix_rgb(INK, CYAN, 0.12 * (1 - t / 0.60))
    for li = 1, #live_list do
      local i = live_list[li]
      local x = (i - 1) % grid_w
      local y = (i - 1) // grid_w
      local px, py = cell_px(x, y)
      local s = math.max(2, cell - 4)
      display.fill_rect(px - ox // 2 + 2, py - oy // 2 + 2, s, s, trail)
    end
  end

  for li = 1, #live_list do
    draw_live_index(live_list[li], ox, oy)
  end

  -- A brief exposed-edge glint reinforces that the whole scene moved as one.
  local edge = mix_rgb(INK, CYAN, t <= 0.50 and 0.20 * (1 - t / 0.50) or 0)
  if ox > 1 then
    display.fill_rect(0, 0, math.min(3, ox), height, edge)
  elseif ox < -1 then
    display.fill_rect(width - math.min(3, -ox), 0, math.min(3, -ox), height, edge)
  end
  if oy > 1 then
    display.fill_rect(0, 0, width, math.min(3, oy), edge)
  elseif oy < -1 then
    display.fill_rect(0, height - math.min(3, -oy), width, math.min(3, -oy), edge)
  end
end

local function draw_event_feedback()
  if event_feedback_ms <= 0 then
    return
  end
  local energy = clamp(event_feedback_ms / 180, 0, 1)
  local outer = mix_rgb_into(scratch_edge_outer, INK, event_feedback_color, 0.20 + 0.52 * energy)
  local inner = mix_rgb_into(scratch_edge_inner, INK, event_feedback_color, 0.08 + 0.30 * energy)
  local thick = 10
  local inner_thick = 4
  display.fill_rect(0, 0, width, thick, outer)
  display.fill_rect(0, height - thick, width, thick, outer)
  display.fill_rect(0, 0, thick, height, outer)
  display.fill_rect(width - thick, 0, thick, height, outer)
  display.fill_rect(thick, thick, width - thick * 2, inner_thick, inner)
  display.fill_rect(thick, height - thick - inner_thick, width - thick * 2, inner_thick, inner)
  display.fill_rect(thick, thick, inner_thick, height - thick * 2, inner)
  display.fill_rect(width - thick - inner_thick, thick, inner_thick, height - thick * 2, inner)
end

local function draw_world(with_glow)
  if shake_fx_ms > 0 then
    draw_shaken_scene()
    world_dirty = true
  elseif need_full_redraw then
    draw_scene(0, 0)
    need_full_redraw = false
    clear_dirty()
    world_dirty = false
  elseif #dirty > 0 then
    -- Fast path: redraw only births/deaths between halo recompositions.
    draw_dirty_cells()
    world_dirty = (#dirty > 0)
  else
    world_dirty = false
  end
end

local function render(force_glow)
  display.begin_frame({ clear = true, color = INK })
  if shake_fx_ms > 0 then
    draw_shaken_scene()
  else
    draw_scene(0, 0)
  end
  draw_event_feedback()
  display.present()
  display.end_frame()
  need_full_redraw = false
  clear_dirty()
  world_dirty = false
  rendered_frames = rendered_frames + 1
  last_display_ms = 0
end

local function mark_scene_dirty()
  world_dirty = true
  need_full_redraw = true
end

local function do_shake()
  if shake_cooldown_ms > 0 then
    return false
  end
  shake_random()
  shake_fx_ms = SHAKE_FX_MS
  shake_cooldown_ms = SHAKE_COOLDOWN_MS
  local angle = math.random() * math.pi * 2
  shake_dir_x = math.cos(angle)
  shake_dir_y = math.sin(angle) * 0.72
  paint_hue = wrap_hue(paint_hue + 37)
  event_feedback_color = CYAN
  event_feedback_ms = 120
  event_feedback_draw_level = -1
  -- Later frames redraw the entire field at a damped offset, making the shake
  -- read as physical scene motion rather than an unrelated overlay.
  mark_scene_dirty()
  return true
end

local function do_reset()
  seed_demo()
  last_step_ms = 0
  for i = 1, #live_list do
    cache_cell_color(live_list[i])
  end
  mark_scene_dirty()
  event_feedback_color = TEAL
  event_feedback_ms = 180
  event_feedback_draw_level = -1
end

-- Input ----------------------------------------------------------------------

local function init_imu()
  if not imu_ok then
    print("[mosaico] INFO: require(imu) unavailable; physical shake disabled")
    return false
  end

  -- Other Mosaico skills open IMU with imu.new() and no name. Named
  -- imu_sensor is only a fallback for boards that require it.
  local opened, sensor_or_err = pcall(imu.new)
  if not opened or not sensor_or_err then
    opened, sensor_or_err = pcall(imu.new, imu_device_name)
  end
  if not opened or not sensor_or_err then
    print("[mosaico] INFO: imu.new failed: " .. tostring(sensor_or_err))
    return false
  end

  imu_sensor = sensor_or_err
  local name_ok, resolved = pcall(function()
    return imu_sensor:name()
  end)
  imu_enabled = true
  imu_have_prev = false
  imu_mag_ema = 0
  imu_warmup = 0
  print("[mosaico] IMU ready device=" .. tostring(name_ok and resolved or imu_device_name))
  return true
end

local function poll_imu_shake()
  if not imu_enabled or not imu_sensor then
    return true
  end
  if shake_cooldown_ms > 0 or shake_fx_ms > 0 then
    return true
  end

  local ok_read, sample = pcall(function()
    return imu_sensor:read()
  end)
  if not ok_read or type(sample) ~= "table" or type(sample.accel) ~= "table" then
    print("[mosaico] WARN: imu read failed: " .. tostring(sample))
    return true
  end

  local ax = tonumber(sample.accel.x) or 0
  local ay = tonumber(sample.accel.y) or 0
  local az = tonumber(sample.accel.z) or 0
  local mag = math.sqrt(ax * ax + ay * ay + az * az)

  if not imu_have_prev then
    imu_prev_x, imu_prev_y, imu_prev_z = ax, ay, az
    imu_mag_ema = mag
    imu_have_prev = true
    imu_warmup = 1
    return true
  end

  local dx = ax - imu_prev_x
  local dy = ay - imu_prev_y
  local dz = az - imu_prev_z
  local delta = math.sqrt(dx * dx + dy * dy + dz * dz)
  imu_prev_x, imu_prev_y, imu_prev_z = ax, ay, az

  -- Warm up resting magnitude EMA before arming detection.
  if imu_warmup < IMU_WARMUP_SAMPLES then
    imu_mag_ema = imu_mag_ema + (mag - imu_mag_ema) * 0.35
    imu_warmup = imu_warmup + 1
    return true
  end

  imu_mag_ema = imu_mag_ema + (mag - imu_mag_ema) * 0.08
  local baseline = math.max(imu_mag_ema, 1e-3)
  local score = delta / baseline
  if score >= IMU_SHAKE_RATIO then
    print(string.format("[mosaico] IMU shake score=%.2f", score))
    do_shake()
  end
  return true
end

local function init_input()
  if lcd_touch_ok then
    -- Boards without a touch device may raise here; fall through to button.
    local got, handle, touch_err = pcall(bm.get_lcd_touch_handle, "lcd_touch")
    if not got then
      touch_handle, touch_err = nil, handle
    else
      touch_handle = handle
    end
    if touch_handle then
      local synced, sync_err = pcall(lcd_touch.sync, touch_handle)
      if synced then
        input_mode = "lcd_touch"
        return true
      end
      print("[mosaico] WARN: lcd_touch.sync failed: " .. tostring(sync_err))
    else
      print("[mosaico] WARN: get_lcd_touch_handle(lcd_touch) failed: " .. tostring(touch_err))
    end
  end

  if not button_ok then
    print("[mosaico] ERROR: no lcd_touch and require(button) failed")
    return false
  end

  local made, handle, button_err = pcall(button.new, 0, 0)
  if not made then
    print("[mosaico] ERROR: button.new raised: " .. tostring(handle))
    return false
  end
  button_handle = handle
  if not button_handle then
    print("[mosaico] ERROR: button.new failed: " .. tostring(button_err))
    return false
  end
  local read, level, level_err = pcall(button.get_key_level, button_handle)
  if not read then
    print("[mosaico] ERROR: button.get_key_level raised: " .. tostring(level))
    return false
  end
  if level == nil then
    print("[mosaico] ERROR: button.get_key_level failed: " .. tostring(level_err))
    return false
  end
  button_last_level = level
  input_mode = "button"
  return true
end

local function poll_touch()
  local polled, info = pcall(lcd_touch.poll, touch_handle)
  if not polled then
    print("[mosaico] ERROR: lcd_touch.poll failed: " .. tostring(info))
    return false
  end

  if info.just_pressed then
    touch_down = true
    touch_down_ms = 0
    touch_start_x, touch_start_y = info.x, info.y
    touch_moved = false
    touch_long_fired = false
    painting = false
    last_paint_x, last_paint_y = -1, -1
  end

  if touch_down and info.pressed then
    touch_down_ms = touch_down_ms + FRAME_MS
    local d2 = touch_dist2(info.x, info.y, touch_start_x, touch_start_y)
    if d2 >= (DRAG_THRESH_PX * DRAG_THRESH_PX) then
      if not touch_moved then
        touch_moved = true
        begin_paint_at(touch_start_x, touch_start_y)
      end
    end

    if painting then
      local cx, cy = screen_to_cell(info.x, info.y)
      if cx ~= nil then
        paint_cell_fast(cx, cy, erase_mode and 0 or 1, paint_hue)
      end
    elseif not touch_long_fired and not touch_moved and touch_down_ms >= LONG_PRESS_MS then
      do_reset()
      touch_long_fired = true
    end
  end

  if info.just_released then
    if painting then
      rebuild_live_list()
      event_feedback_ms = 180
      event_feedback_draw_level = -1
    elseif not touch_moved and not touch_long_fired then
      local cx, cy = screen_to_cell(info.x, info.y)
      if cx ~= nil then stamp_tap_seed(cx, cy) end
    end
    touch_down = false
    painting = false
    last_paint_x, last_paint_y = -1, -1
    touch_moved = false
    touch_long_fired = false
  end
  return true
end

local function poll_button()
  local level, level_err = button.get_key_level(button_handle)
  if level == nil then
    print("[mosaico] ERROR: button.get_key_level failed: " .. tostring(level_err))
    return false
  end

  if level == button_active_level then
    if button_last_level ~= button_active_level then
      button_down_ms = 0
      button_fired_hold = false
    else
      button_down_ms = button_down_ms + FRAME_MS
      if not button_fired_hold and button_down_ms >= LONG_PRESS_MS then
        do_reset()
        button_fired_hold = true
      end
    end
  else
    button_down_ms = 0
    button_fired_hold = false
  end
  button_last_level = level
  return true
end

-- Main -----------------------------------------------------------------------

math.randomseed(os.time() + width * 17 + height * 31)

if not init_input() then
  cleanup()
  return
end

init_imu()

seed_demo()
mark_scene_dirty()
render(true)

print(string.format(
  "[mosaico] ready screen=%dx%d grid=%dx%d cell=%d tiles=%d touch=%dms display=%dms step=%dms",
  width, height, grid_w, grid_h, cell, n_cells, FRAME_MS, DISPLAY_MS, STEP_MS
))
if input_mode == "lcd_touch" then
  print("[mosaico] gestures: tap=seed  drag=eco-brush  long-press=reset  shake=IMU")
else
  print("[mosaico] button: hold=reset")
end
if imu_enabled then
  print("[mosaico] physical shake armed (imu_sensor)")
else
  print("[mosaico] physical shake unavailable")
end

local function main_loop()
  local ticks = 0
  if RUN_TIME_MS > 0 then
    ticks = math.max(1, RUN_TIME_MS // FRAME_MS)
  end
  local n = 0
  while true do
    if ticks > 0 then
      n = n + 1
      if n > ticks then
        break
      end
    end
    local ok_input = true
    if input_mode == "lcd_touch" then
      ok_input = poll_touch()
    else
      ok_input = poll_button()
    end
    if not ok_input then
      break
    end

    last_imu_ms = last_imu_ms + FRAME_MS
    if last_imu_ms >= IMU_POLL_MS then
      last_imu_ms = 0
      poll_imu_shake()
    end

    if shake_fx_ms > 0 then
      shake_fx_ms = math.max(0, shake_fx_ms - FRAME_MS)
      world_dirty = true
      if shake_fx_ms == 0 then
        -- Clear the final displaced frame and motion echoes with one rebuild.
        need_full_redraw = true
      end
    end
    if shake_cooldown_ms > 0 then
      shake_cooldown_ms = math.max(0, shake_cooldown_ms - FRAME_MS)
    end
    if event_feedback_ms > 0 then
      local before = event_feedback_ms
      local before_level = math.max(1, math.ceil(before / 60))
      event_feedback_ms = math.max(0, event_feedback_ms - FRAME_MS)
      local after_level = event_feedback_ms > 0 and math.max(1, math.ceil(event_feedback_ms / 60)) or 0
      if after_level ~= before_level then world_dirty = true end
      if before > 0 and event_feedback_ms == 0 then
        event_feedback_draw_level = -1
        need_full_redraw = true
      end
    end

    last_step_ms = last_step_ms + FRAME_MS
    if shake_fx_ms <= 0 and last_step_ms >= STEP_MS then
      last_step_ms = 0
      step_world()
    end

    last_display_ms = last_display_ms + FRAME_MS
    if last_display_ms >= DISPLAY_MS and
      (world_dirty or #dirty > 0 or shake_fx_ms > 0) then
      render(false)
    end

    tick_count = tick_count + 1
    if tick_count % 1000 == 0 then
      print(string.format("[mosaico] FPS_STATS ticks=%d frames=%d gens=%d", tick_count, rendered_frames, generation))
    end
    delay.delay_ms(FRAME_MS)
  end
end

local run_ok, run_err = xpcall(main_loop, debug.traceback)
cleanup()
if not run_ok then
  print("[mosaico] ERROR: " .. tostring(run_err))
  error(run_err)
end
print("[mosaico] done")
