-- Infrared Remote App: owns LVGL, the IR link and the saved devices, and routes between pages.
local lvgl = require("lvgl")
local system = require("system")
local script_start_ms = system.millis()
local Kit = require("ui.kit")
local Overlays = require("ui.overlays")
local IrLink = require("ir_link")
local ProtocolCatalog = require("protocol_catalog")
local DeviceManager = require("device_manager")
local RemoteStore = require("remote_store")

local LOG = "[infrared_remote] "
local LOOP_MS = 30
local LEARN_TIMEOUT_MS = 6000
local MIN_W, MIN_H = 240, 200
-- First-run defaults keyed by board_info.yaml "board"; launcher args and saved settings override them.
-- -1 marks a pin that is not connected on that board.
local BOX3_HARDWARE = {tx_gpio = 39, rx_gpio = 38, ctrl_gpio = 44, ctrl_active_level = 0, carrier_hz = 38000}
local BOARD_HARDWARE = {
    esp_box_3 = BOX3_HARDWARE,
    esp_mosaico = {tx_gpio = 47, rx_gpio = -1, ctrl_gpio = -1, ctrl_active_level = 0, carrier_hz = 38000},
}
local CAPTURE_ERRORS = {timeout = "No signal received", frame_too_long = "Signal too long to learn", empty_frame = "Only noise received"}
-- Storage limits enforced by ir_remote:learn(), matched against its error text.
local LEARN_LIMITS = {{match = "learned keys", text = "Too many learned keys"}, {match = "pulses", text = "Learned codes storage full"}}
local LVGL_OPTIONS = {buffer_lines = 40, tick_ms = 5, task_period_ms = 10}

local launch_args = type(args) == "table" and args or {}

-- Returns the board name, or nil when board_manager is not built in or has no board info.
local function board_name()
    local loaded, board_manager = pcall(require, "board_manager")
    if not loaded then
        print(LOG .. "board_manager unavailable: " .. tostring(board_manager))
        return nil
    end
    local info, err = board_manager.get_board_info()
    if not info then
        print(LOG .. "Board info unavailable: " .. tostring(err))
        return nil
    end
    return info.name
end

-- Pages and overlays are built on first use (modules included): building every widget up front
-- dominated the startup time on device.
local function remote_page(panel_module, panel)
    return function(app) return require("pages.remote").new(app, require(panel_module)[panel]) end
end
local PAGE_BUILDERS = {
    home = function(app) return require("pages.home").new(app) end,
    add = function(app) return require("pages.add").new(app) end,
    settings = function(app) return require("pages.settings").new(app) end,
    tv = remote_page("pages.keypad", "tv"), media = remote_page("pages.keypad", "media"),
    custom = remote_page("pages.keypad", "custom"), ac = remote_page("pages.ac_panel", "new"),
}
local OVERLAY_BUILDERS = {
    picker = function(app) return Overlays.picker(app.kit, app.screen) end,
    dialog = function(app) return Overlays.dialog(app.kit, app.screen) end,
    capture_sheet = function(app) return Overlays.capture_sheet(app.kit, app.screen, function() app:cancel_learning() end) end,
}

local App = {}
App.__index = App

function App:option(name, default)
    local value = launch_args[name]
    if value == nil then return default end
    return value
end

function App:now() return system.millis() end

function App:notify(text, tone) self.toast:show(text, tone, self:now()) end

-- Startup profile: records how long the stage that just finished took, for the ready log.
function App:mark(stage)
    local now = self:now()
    self.profile = self.profile or {}
    self.profile[#self.profile + 1] = string.format("%s %d", stage, now - (self.profile_at or now))
    self.profile_at = now
end

function App:ensure_page(name)
    local page = self.pages[name]
    if not page then
        local build = assert(PAGE_BUILDERS[name], "unknown page " .. tostring(name))
        page = build(self)
        self.pages[name] = page
    end
    return page
end

function App:overlay(name)
    local overlay = self.overlays[name]
    if not overlay then
        overlay = assert(OVERLAY_BUILDERS[name], "unknown overlay " .. tostring(name))(self)
        self.overlays[name] = overlay
    end
    return overlay
end

function App:init()
    local screen = lvgl.create_screen()
    self.screen = screen
    self.kit = Kit.new(screen)
    assert(self.kit.w >= MIN_W and self.kit.h >= MIN_H, "Infrared Remote requires at least 240x200 pixels")
    screen:set_style({bg_color = Kit.C.bg, pad = 0, border_width = 0})
    screen:clear_flag("SCROLLABLE")
    self:mark("fonts")

    local ir = require("ir")
    self.store = RemoteStore.open()
    local board = board_name()
    local defaults = {}
    for key, value in pairs(BOARD_HARDWARE[board] or BOX3_HARDWARE) do defaults[key] = self:option(key, value) end
    -- Saved pins belong to the board that saved them (DATA may live on a moved SD card).
    local saved = self.store.data.hardware
    if saved.board ~= board then
        if next(saved) then print(LOG .. "Saved IR hardware is for board " .. tostring(saved.board) .. ", using defaults") end
        saved = nil
    end
    self.hardware = IrLink.normalize(saved, defaults)
    self.hardware.board = board
    self.store.data.hardware = self.hardware
    self.link = IrLink.new(ir)
    self.link:open(self.hardware)
    self:mark("ir")
    self.ir = ir
    self.devices = DeviceManager.new(self.store, require("ir_remote"))
    self:mark("devices")

    -- Pages live in their own layer so overlays, created later on screen, always stay above them.
    self.root = self.kit:box(screen, 0, 0, self.kit.w, self.kit.h, {bg_opa = 0})
    self.pages, self.overlays = {}, {}
    self.toast = Overlays.toast(self.kit, screen)
    self:go("home")
    self:mark("home")

    screen:load()
    self.running = true
    if self.store.load_error then self:notify("Saved data unreadable; changes won't be saved", "danger") end
    self:mark("show")
    print(string.format(LOG .. "ready: %d devices / %s / startup ms: %s", #self.devices:list(), self.link:ready() and "IR online" or "IR unavailable", table.concat(self.profile, ", ")))
end

-- LVGL renders on its own task, so the next page is filled in while still hidden (hidden widgets
-- skip invalidation) and then swapped in; otherwise half-updated frames show up during enter().
function App:go(name, params)
    local page = self:ensure_page(name)
    local old = self.page
    if old and old.leave then old:leave() end
    self.page = page
    page:enter(params)
    Kit.set_hidden(page.view, false)
    if old and old ~= page then Kit.set_hidden(old.view, true) end
end

function App:quit() self.running = false end

-- Listing protocols parses every JSON codeset, so the catalog is only built once a page needs it.
function App:catalog()
    if not self.catalog_cache then self.catalog_cache = ProtocolCatalog.new(self.ir) end
    return self.catalog_cache
end

local function protocol_labels(catalog, protocol)
    local entry = catalog:entry(protocol)
    return {protocol_name = entry and entry.title or string.upper(protocol), protocol_label = catalog:describe(protocol)}
end

-- Protocol names are kept in the device record, so startup never has to list the codesets.
-- Records saved before that get the names filled in once and saved later.
function App:_protocol_names(device)
    local protocol = device.snapshot and device.snapshot.protocol
    if not protocol then return nil end
    if not device.protocol_name then
        for key, value in pairs(protocol_labels(self:catalog(), protocol)) do device[key] = value end
        self.devices:touch(device, self:now())
    end
    return device.protocol_name, device.protocol_label
end

function App:describe(device)
    local _, label = self:_protocol_names(device)
    return label or "Learned remote"
end

-- Short card line: the protocol brand, or the learned-key state for protocol-less remotes.
function App:summary(device)
    local name = self:_protocol_names(device)
    if name then return name end
    return self.devices:learned_count(device) > 0 and "Learned keys" or "No keys yet"
end

function App:send(frame)
    local ok, err = self.link:send(frame)
    if not ok then self:notify(self.link:ready() and "Send failed" or "IR offline · check Settings", "danger") end
    return ok, err
end

function App:open_add()
    if self.devices:is_full() then self:notify("Remote limit reached", "warn"); return end
    self:go("add")
end

function App:create_device(kind, protocol)
    local config, labels = {}, nil
    if kind ~= "custom" then
        local address = math.floor(tonumber(self:option("protocol_address", 0)) or 0)
        config = self:catalog():config(protocol, address, self:option(kind .. "_codes", {}))
        labels = protocol_labels(self:catalog(), protocol)
    end
    local device, err = self.devices:create(kind, config, labels)
    if not device then self:notify(err, "danger"); return end
    self:go(kind, device)
    self:notify(device.name .. " added", "success")
end

function App:delete_device(device)
    if not self.devices:delete(device) then self:notify("Delete failed: storage error", "danger"); return end
    self:go("home")
    self:notify(device.name .. " deleted", "success")
end

-- Returns true when the new hardware settings are live and saved.
function App:apply_hardware(draft)
    local valid, reason = IrLink.validate(draft)
    if not valid then self:notify(reason, "danger"); return false end
    local ok, err = self.link:apply(draft)
    if not ok then
        self:notify("Settings rejected · " .. tostring(err):gsub("^ir%.device: ", ""), "danger")
        return false
    end
    for key, value in pairs(draft) do self.hardware[key] = value end
    local saved = self.store:save()
    self:notify(saved and "Hardware settings applied" or "Applied, but saving failed", saved and "success" or "danger")
    return true
end

function App:start_learning(device, remote, key, label, on_done)
    local ok, err = self.link:start_capture(LEARN_TIMEOUT_MS, self:now())
    if not ok then
        self:notify(self.link:can_receive() and "Receiver busy" or "IR receiver is off · check Settings", "danger")
        print(LOG .. "Learn start failed: " .. tostring(err))
        return
    end
    self.learning = {device = device, remote = remote, key = key, label = label, on_done = on_done}
    self:overlay("capture_sheet"):open(label)
    -- Loads the catalog used to identify the frame while the user is still aiming the remote.
    self:catalog()
end

function App:cancel_learning()
    if not self.learning then return end
    self.learning = nil
    self.link:cancel_capture()
    self:overlay("capture_sheet"):close()
    self:notify("Learning cancelled", "info")
end

function App:_finish_learning(job, frame, reason)
    self.learning = nil
    self:overlay("capture_sheet"):close()
    if not frame then
        self:notify(CAPTURE_ERRORS[reason] or "Learning failed", "danger")
        return
    end
    local ok, err = pcall(job.remote.learn, job.remote, job.key, frame)
    if not ok then
        err = tostring(err)
        print(LOG .. "Learn rejected: " .. err)
        local text = "Learning rejected"
        for _, limit in ipairs(LEARN_LIMITS) do
            if err:find(limit.match, 1, true) then text = limit.text; break end
        end
        self:notify(text, "danger")
        return
    end
    local saved = self.devices:commit(job.device)
    local hint = self:catalog():identify(frame) or string.format("%d pulses", #frame)
    self:notify(saved and string.format("%s learned · %s", job.label, hint) or "Learned, but saving failed", saved and "success" or "danger")
    if job.on_done then job.on_done() end
end

function App:_poll_learning(now)
    local job = self.learning
    if not job then return end
    local frame, reason = self.link:poll_capture(now)
    if frame == nil then
        self:overlay("capture_sheet"):set_progress(self.link:capture_progress(now))
        return
    end
    self:_finish_learning(job, frame or nil, reason)
end

function App:run()
    while self.running do
        lvgl.process_events(LOOP_MS)
        local now = self:now()
        self:_poll_learning(now)
        self.toast:tick(now)
        if self.page.tick then self.page:tick(now) end
        if not self.devices:tick(now) then self:notify("Saving remote state failed", "danger") end
    end
end

-- Releases everything acquired by init(), also after a partial init.
function App:shutdown()
    if self.devices and not self.devices:flush() then print(LOG .. "Final save failed") end
    if self.link then self.link:close() end
end

local app = setmetatable({profile_at = script_start_ms}, App)
local lvgl_owned = false

local function main()
    app:mark("modules")
    lvgl.init(LVGL_OPTIONS)
    lvgl_owned = true
    app:mark("lvgl")
    app:init()
    app:run()
end

local ok, err = xpcall(main, debug.traceback)
local stopped = not ok and tostring(err):find("stop requested", 1, true)
-- Release GPIO and LVGL ownership on every exit path.
local closed, close_err = pcall(app.shutdown, app)
if not closed then print(LOG .. "Shutdown failed: " .. tostring(close_err)) end
if lvgl_owned then
    local released, release_err = pcall(lvgl.deinit)
    if not released then print(LOG .. "LVGL cleanup failed: " .. tostring(release_err)) end
end
if not ok and not stopped then print(LOG .. "ERROR: " .. tostring(err)); error(err) end
