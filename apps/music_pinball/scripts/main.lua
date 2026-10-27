local display, system, delay = require("display"), require("system"), require("delay")
local physics, sound = require("physics"), require("sound")
local source = assert(debug.getinfo(1, "S").source:match("^@(.*/)"), "missing script path")
local root = assert(source:match("^(.*)/scripts/$"))
local screen, speaker, audio_loaded
local fonts = {}
local C = { bg = "#090D20", panel = "#1C2341", rail = "#465478", cyan = "#55F4DC", gold = "#FFD478",
    pink = "#BC9CFF", white = "#F4F7FF", dim = "#B3C2DF", dark = "#253250", glow = "#173F49", hot = "#39264E" }
local palette = { C.cyan, C.pink, C.gold }
local scale, ox, oy = 1, 0, 0
local function n(x) return math.floor(x * scale + 0.5) end
local function circle(x, y, r, color, fill)
    if fill then screen:fill_circle(ox + n(x), oy + n(y), n(r), color)
    else screen:stroke_circle(ox + n(x), oy + n(y), n(r), color) end
end
local function line(ax, ay, bx, by, color)
    screen:line(ox + n(ax), oy + n(ay), ox + n(bx), oy + n(by), color)
end
local function box(x, y, w, h, r, color)
    screen:fill_round_rect(ox + n(x), oy + n(y), n(w), n(h), n(r), color)
end
local function label(x, y, text, size, color)
    local options = { font = size >= 28 and fonts.large or fonts.small, color = color }
    local width = screen:measure_text(text, options)
    screen:text(ox + n(x) - width // 2, oy + n(y), text, options)
end

local header, controls, painted
local function render(s, paused, trail)
    local fever = physics.fever(s)
    local sequence = physics.sequence(s)
    local goal = not fever and sequence[s.progress + 1]
    local accent = fever and C.gold or C.cyan
    screen:begin(not painted and { clear = C.bg } or nil)
    if not painted then
        for dy = -1, 1 do
            line(168, 345 + dy, 192, 345 + dy, C.white)
            line(168, 345 + dy, 175, 338 + dy, C.white)
            line(168, 345 + dy, 175, 352 + dy, C.white)
        end
    end
    -- Keep static UI out of the redraw region to reduce display traffic.
    local key = s.score .. ":" .. s.lives .. ":" .. tostring(paused)
    if key ~= header then
        screen:fill_rect(ox + n(70), oy + n(16), n(220), n(36), C.bg)
        label(153, 18, tostring(s.score), 28, C.white)
        for i = 1, 3 do circle(215 + i * 12, 25, 3, i <= s.lives and C.gold or C.dark, true) end
        if paused then
            for i = 0, 8 do line(246 + i, 34 + i / 2, 246 + i, 42 - i / 2, C.white) end
        else
            box(243, 34, 4, 12, 1, C.white); box(253, 34, 4, 12, 1, C.white)
        end
        header = key
    end
    screen:save()
    screen:clip(ox + n(27), oy + n(52), n(306), n(258))
    screen:fill_rect(ox + n(27), oy + n(52), n(306), n(258), C.bg)
    -- Sparse field details keep the ball and active target visually dominant.
    for x = 60, 300, 240 do
        for y = 130, 210, 40 do circle(x, y, 1, C.dark, true) end
    end
    line(95, 53, 265, 53, C.dark)
    line(90, 49, 30, 125, C.rail); line(270, 49, 330, 125, C.rail)
    line(30, 125, 30, 225, C.rail); line(330, 125, 330, 225, C.rail)
    line(30, 225, 94, 274, accent); line(330, 225, 266, 274, fever and C.gold or C.pink)
    line(33, 222, 97, 271, C.dark); line(327, 222, 263, 271, C.dark)
    for i, item in ipairs(s.targets) do
        local lit = s.time - (s.flash[i + 3] or -10) < 0.18
        circle(item.x, item.y, item.r + 3, C.dark, true)
        circle(item.x, item.y, item.r, lit and C.white or C.gold, true)
        circle(item.x - 2, item.y - 3, 2, C.white, true)
    end
    for i, b in ipairs(s.bumpers) do
        local age = s.time - (s.flash[i] or -10)
        local color = fever and C.gold or palette[i]
        local selected = goal == i or fever
        if age < 0.3 then circle(b.x, b.y, b.r + 6 + age * 30, color) end
        circle(b.x, b.y, b.r + 6, selected and (fever and C.hot or C.glow) or C.panel, true)
        circle(b.x, b.y, b.r + 4, selected and color or C.dark)
        if selected then circle(b.x, b.y, b.r + 7 + math.sin(s.time * 5) * 2, color) end
        circle(b.x, b.y, b.r, age < 0.12 and C.white or selected and color or C.panel, true)
        label(b.x, b.y - 11, ({ "C", "E", "G" })[i], 20, selected and C.bg or color)
    end
    -- Sequence dots preview the order; completed notes become small white cores.
    for i, target in ipairs(sequence) do
        local x = 180 + (i - (#sequence + 1) / 2) * 18
        circle(x, 97, 5, fever and C.gold or palette[target], i <= s.progress or fever)
        if i == s.progress + 1 and not fever then circle(x, 97, 7, C.white) end
        if i <= s.progress then circle(x, 97, 2, C.white, true) end
    end
    local status = s.phase == "lost" and "再来一球" or fever and ("狂欢 x2 · " .. math.ceil(s.fever_until - s.time) .. "s")
        or s.time - (s.flash.bonus or -10) < 1 and "+1000"
        or s.combo > 1 and ("连击 x" .. math.min(5, 1 + s.combo // 4))
        or s.phase == "playing" and s.time < s.save_until and "护球中" or "击中光环"
    label(180, 225, status, 20, fever and C.gold or C.dim)
    box(123, 250, 114, 5, 2, C.dark)
    if fever then
        box(123, 250, math.max(2, 114 * (s.fever_until - s.time) / 15), 5, 2, C.gold)
    else
        for i = 1, 3 do box(123 + (i - 1) * 39, 250, 36, 5, 2, i <= s.energy and C.cyan or C.dark) end
    end
    for _, side in ipairs({ "left", "right" }) do
        local ax, ay, bx, by = physics.flipper(s, side)
        local color = side == "left" and C.cyan or C.pink
        for offset = -4, 4 do line(ax, ay + offset, bx, by + offset, color) end
        circle(ax, ay, 5, C.white, true); circle(bx, by, 4, color, true)
    end
    for i, p in ipairs(trail) do circle(p.x, p.y, 1 + i / 3, i > 3 and C.rail or C.dark, true) end
    if s.phase ~= "lost" and s.phase ~= "over" then
        circle(s.x, s.y, 8, C.dark, true)
        circle(s.x, s.y, 6, C.white, true)
        circle(s.x - 2, s.y - 2, 2, C.cyan, true)
    end
    if paused or s.phase == "ready" or s.phase == "over" then
        box(58, 216, 244, 72, 18, C.dark)
        box(59, 217, 242, 70, 17, C.panel)
        box(157, 217, 46, 3, 1, accent)
        local title = paused and "已暂停" or s.phase == "over" and "本局结束" or "轻点开球"
        label(180, 224, title, 28, C.white)
        local subtitle = paused and "轻点继续" or s.phase == "over" and "轻点再玩" or "追光连奏 · 三段狂欢"
        label(180, 258, subtitle, 20, C.cyan)
    end
    if audio_loaded and not speaker then label(180, 289, "静音", 20, C.dim) end
    screen:restore()
    key = tostring(s.left > 0.5) .. ":" .. tostring(s.right > 0.5)
    if key ~= controls then
        box(90, 310, 80, 28, 14, s.left > 0.5 and C.cyan or C.panel)
        box(190, 310, 80, 28, 14, s.right > 0.5 and C.pink or C.panel)
        label(130, 312, "左挡板", 20, s.left > 0.5 and C.bg or C.cyan)
        label(230, 312, "右挡板", 20, s.right > 0.5 and C.bg or C.pink)
        controls = key
    end
    painted = true
    screen:present()
end

local function run()
    screen = display.open()
    local info = screen:info()
    assert(info.width >= 240 and info.height >= 240, "display must be at least 240x240")
    assert(info.touch_available, "touch input required")
    scale = math.min(info.width, info.height) / 360
    ox, oy = (info.width - n(360)) // 2, (info.height - n(360)) // 2
    local small, large = scale < 0.9 and 14 or scale > 1.2 and 28 or 20, scale < 0.9 and 20 or scale > 1.2 and 38 or 28
    fonts.small = display.load_font(root .. "/assets/ui-" .. small .. ".dfn")
    fonts.large = display.load_font(root .. "/assets/ui-" .. large .. ".dfn")
    local s, trail = physics.new(), {}
    render(s, false, trail)
    speaker = sound.open(root)
    audio_loaded = true
    print(string.format("[music_pinball] ready %dx%d audio=%s", info.width, info.height, speaker and "on" or "off"))
    local previous, report = system.millis(), system.millis()
    local paused, contacts, done = false, {}, false
    while not done do
        local now = system.millis()
        local dt = math.max(0, now - previous) / 1000
        previous = now
        local left, right, current = false, false, {}
        -- Contact IDs make held touches distinct from launch and pause taps.
        for _, point in ipairs(screen:touch().points) do
            local x, y = (point.x - ox) / scale, (point.y - oy) / scale
            current[point.id] = true
            if not contacts[point.id] then
                if y >= 336 and math.abs(x - 180) < 40 then done = true
                elseif y < 60 and x >= 230 and x <= 280 then paused = not paused
                elseif paused and y >= 213 and y <= 280 then paused = false
                elseif y >= 60 and not paused then
                    if s.phase == "over" then s = physics.new(s.best); trail = {} end
                    if physics.launch(s) then sound.play(speaker, "launch") end
                end
            end
            if y >= 60 and y < 336 then
                if x < 180 then left = true else right = true end
            end
        end
        contacts = current
        if not paused then
            for _, event in ipairs(physics.update(s, dt, left, right)) do sound.play(speaker, event.kind, event.note) end
            if s.phase == "playing" then
                trail[#trail + 1] = { x = s.x, y = s.y }
                if #trail > 6 then table.remove(trail, 1) end
            else trail = {} end
        end
        render(s, paused, trail)
        if speaker and now - report >= 10000 then
            report = now
            local status = speaker.player:status()
            if status.error ~= "ESP_OK" then
                print("[music_pinball] audio worker failed: " .. status.error)
                sound.close(speaker); speaker = nil
            end
        end
        delay.delay_ms(math.max(1, 33 - (system.millis() - now)))
    end
end

local ok, err = xpcall(run, debug.traceback)
local closed, close_err = pcall(sound.close, speaker)
if screen then screen:close() end
for _, font in pairs(fonts) do font:close() end
if not closed then print("[music_pinball] audio cleanup failed: " .. tostring(close_err)) end
if not ok then
    local message = tostring(err)
    if not message:find("stop requested", 1, true) and not message:find("stopped by user", 1, true) then print("[music_pinball] ERROR: " .. message) end
end
