local dir = assert(debug.getinfo(1, "S").source:match("^@(.*/)"))
-- FATFS system assets require paths without parent-directory segments.
local root = assert(dir:match("^(.*)/scripts/$"), "invalid app directory")
local Game, View, Sound = assert(loadfile(dir .. "game.lua"))(), assert(loadfile(dir .. "view.lua"))(), assert(loadfile(dir .. "sound.lua"))()
local display, system, delay = require("display"), require("system"), require("delay")
local a = type(args) == "table" and args or {}
local function number(key, default, low, high)
    local n = a[key]
    return type(n) == "number" and n == n and math.max(low, math.min(high, n)) or default
end
local function warn(message) print("[fruit_slice] " .. tostring(message)) end
local screen, view, sound, storage, json
local function close(object)
    if not object then return end
    local success, result, message = pcall(object.close, object)
    if not success or result == nil and message then warn("close failed: " .. tostring(success and message or result)) end
end
local guard <close> = setmetatable({}, { __close = function()
    close(sound); close(view); close(screen)
end })
local ok, err = xpcall(function()
    screen = display.open()
    local info = screen:info()
    assert(info.width >= 240 and info.height >= 240, "display must be at least 240x240")
    assert(info.touch_available, "a touch display is required")
    local record = {}
    local loaded, data = pcall(function()
        storage, json = require("storage"), require("json")
        local path = storage.join_path(storage.get_root_dir(), "app_data", "fruit_slice.json")
        return storage.exists(path) and json.decode(storage.read_file(path)) or {}
    end)
    if loaded and type(data) == "table" then record = data elseif not loaded then warn("settings unavailable: " .. tostring(data)) end
    for _, key in ipairs({"best_rush", "best_zen"}) do
        local n = record[key]
        record[key] = type(n) == "number" and n == n and math.floor(math.max(0, math.min(999999, n))) or 0
    end
    if a.sound_mode == "music" or a.sound_mode == "effects" or a.sound_mode == "mute" then record.sound_mode = a.sound_mode end
    local volume = math.floor(number("volume", 80, 0, 100))
    if volume == 0 then record.sound_mode = "mute" end
    math.randomseed(system.millis())
    local game = Game.new(math.random, record)
    view = View.new(screen, root, display)
    view:load()
    sound = Sound.new(root, volume, warn)
    collectgarbage("collect")
    local period, run_ms = math.floor(number("frame_ms", 33, 16, 100)), number("run_ms", 0, 0, 86400000)
    local start, previous = system.millis(), system.millis()
    local rendered, last_state, last_sound, last_report, frames, frame_total, frame_max = 0, nil, nil, start, 0, 0, 0
    local audio_max = 0
    local draw_total, present_total, bytes_total = 0, 0, 0
    while not game.exit do
        local now = system.millis()
        if run_ms > 0 and now - start >= run_ms then break end
        game:update((now - previous) / 1000)
        previous = now
        local points, selected = screen:touch().points
        for _, point in ipairs(points) do if not game.press or point.id == game.press.id then selected = point; break end end
        if selected then game:touch({ id = selected.id, x = (selected.x - view.ox) / view.scale, y = (selected.y - view.oy) / view.scale }) else game:touch(nil) end
        if game.save then
            game.save = false
            if storage and json then
                local saved, failure = pcall(function()
                    local root = storage.join_path(storage.get_root_dir(), "app_data")
                    if not storage.exists(root) then assert(storage.mkdir(root)) end
                    assert(storage.write_file(storage.join_path(root, "fruit_slice.json"), json.encode(game.record)))
                end)
                if not saved then warn("save failed: " .. tostring(failure)) end
            end
        end
        local audio_start = system.millis()
        sound:update(game)
        audio_max = math.max(audio_max, system.millis() - audio_start)
        local active = game.state == "playing" or game.state == "ready"
        local redraw = active or game.state ~= last_state or game.sound_mode ~= last_sound or game.state == "home" and now - rendered >= 66
        if redraw then
            view:draw(game)
            rendered, last_state, last_sound = now, game.state, game.sound_mode
            local cost = system.millis() - now
            frames, frame_total, frame_max = frames + 1, frame_total + cost, math.max(frame_max, cost)
            if a.profile then
                local stats = screen:stats()
                draw_total, present_total, bytes_total = draw_total + stats.draw_us, present_total + stats.present_us, bytes_total + stats.submitted_bytes
            end
        end
        if a.profile and now - last_report >= 5000 then
            local count = math.max(1, frames)
            warn(string.format("perf state=%s fps=%.1f avg=%.1fms max=%dms draw=%.1fms present=%.1fms transfer=%.1fKB audio_max=%dms heap=%.0fKB", game.state, frames * 1000 / (now - last_report), frame_total / count, frame_max, draw_total / count / 1000, present_total / count / 1000, bytes_total / count / 1024, audio_max, collectgarbage("count")))
            frames, frame_total, frame_max, last_report = 0, 0, 0, now
            audio_max = 0
            draw_total, present_total, bytes_total = 0, 0, 0
        end
        delay.delay_ms(math.max(1, period - (system.millis() - now)))
    end
end, debug.traceback)
if not ok then warn(err); error(err, 0) end
