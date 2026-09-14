local board_manager = require("board_manager")
local delay = require("delay")
local json = require("json")
local lvgl = require("lvgl")
local skills_lab = require("skills_lab_client")
local storage = require("storage")
local thread = require("thread")

local TAG = "[skills_lab_app]"
local EVENT_POLL_MS = 100
local CLOCK_REFRESH_MS = 1000
local LOADER_POLL_MS = 500
local FONT_PATH = "fonts/fusion-pixel-12px.ttf"
local LOADER_JOB_NAME = "skills_lab_loader"
local LOADER_EXCLUSIVE = "skills_lab_loader"
local CONTROL_ROOT = "/ramfs"
local CONTROL_DIR = "skills_lab"
local STATUS_FILE = "all_status.json"

local COLORS = {
    bg = "#090A0F",
    bg_soft = "#101116",
    panel = "#14151C",
    panel_alt = "#1C1D25",
    panel_installed = "#17181F",
    accent = "#EF4444",
    accent_dark = "#2A1114",
    button_bg = "#170D10",
    button_text = "#FCA5A5",
    installed_bg = "#1A1B22",
    installed_border = "#3F3F46",
    installed_text = "#A1A1AA",
    green = "#EF4444",
    red = "#EF4444",
    yellow = "#FCA5A5",
    text = "#F4F4F5",
    muted = "#A1A1AA",
    faint = "#71717A",
    overlay = "#000000",
}

local I18N = {
    en = {
        installed = "Installed",
        all = "All",
        game = "Game",
        utility = "Utility",
        hardware = "Hardware",
        media = "Media",
        network = "Network",
        sensor = "Sensor",
        ai = "AI",
        title = "Equip your ESP-Claw with These Skills!",
        install = "Install",
        uninstall = "Uninstall",
        installing = "Installing",
        protected = "Built-in",
        loading_installed = "Refreshing installed...",
        installed_count = "Installed: %d",
        loading_all = "Loading all...",
        all_count = "All: %d",
        loader_start_failed = "All loader failed",
        installed_load_failed = "Installed load failed",
        all_load_failed = "All load failed",
        loading_category = "Loading %s...",
        category_count = "%s: %d",
        load_failed = "Load failed",
        downloading = "Installing %s...",
        installed_done = "Installed %s",
        install_failed = "Install failed",
        removing = "Uninstalling %s...",
        removed = "Uninstalled %s",
        remove_failed = "Uninstall failed",
        no_installed = "No installed skills",
        select_category = "Select a category",
        author = "by %s",
        detail_author = "Author: %s",
        detail_id = "ID: %s",
        detail_mode = "Manage mode: %s",
        status_not_installed = "Status: Not installed",
        status_protected = "Status: Built-in, cannot uninstall",
        status_removable = "Status: Installed, can uninstall here",
        status_installed = "Status: Installed",
        lang = "English",
    },
    zh = {
        installed = "已安装",
        all = "全部",
        game = "游戏",
        utility = "工具",
        hardware = "硬件",
        media = "媒体",
        network = "网络",
        sensor = "传感器",
        ai = "AI",
        title = "为你的 ESP-Claw 装备技能",
        install = "下载",
        uninstall = "删除",
        installing = "安装中",
        protected = "出厂内置",
        loading_installed = "刷新已安装...",
        installed_count = "已安装: %d",
        loading_all = "正在加载全部...",
        all_count = "全部: %d",
        loader_start_failed = "全部加载器启动失败",
        installed_load_failed = "已安装列表加载失败",
        all_load_failed = "全部加载失败",
        loading_category = "正在加载%s...",
        category_count = "%s: %d",
        load_failed = "加载失败",
        downloading = "正在下载 %s...",
        installed_done = "已安装 %s",
        install_failed = "下载失败",
        removing = "正在删除 %s...",
        removed = "已删除 %s",
        remove_failed = "删除失败",
        no_installed = "暂无已安装技能",
        select_category = "请选择分类",
        author = "by %s",
        detail_author = "作者: %s",
        detail_id = "ID: %s",
        detail_mode = "管理模式: %s",
        status_not_installed = "状态: 未安装",
        status_protected = "状态: 出厂内置, 不可删除",
        status_removable = "状态: 已安装, 可在此删除",
        status_installed = "状态: 已安装",
        lang = "中文",
    },
}

local NAV_ITEMS = {
    { id = "installed", label_key = "installed", kind = "installed" },
    { id = "all", label_key = "all", kind = "all" },
    { id = "game", label_key = "game", kind = "category", category = "game" },
    { id = "utility", label_key = "utility", kind = "category", category = "utility" },
    { id = "hardware", label_key = "hardware", kind = "category", category = "hardware" },
    { id = "media", label_key = "media", kind = "category", category = "media" },
    { id = "network", label_key = "network", kind = "category", category = "network" },
    { id = "sensor", label_key = "sensor", kind = "category", category = "sensor" },
    { id = "ai", label_key = "ai", kind = "category", category = "ai" },
}

local state = {
    width = 0,
    height = 0,
    compact = false,
    wide = false,
    lang = "en",
    active_nav = "installed",
    installed_items = {},
    remote_items = {},
    all_items = {},
    all_done = false,
    all_loading = false,
    all_loader_started = false,
    all_status_version = nil,
    status = "",
    busy_skill_id = "",
}

local ui = {
    screen = nil,
    root = nil,
    header = nil,
    hero_title = nil,
    lang_button = nil,
    content = nil,
    nav_panel = nil,
    list_panel = nil,
    detail_overlay = nil,
    status = nil,
    clock = nil,
    font_title = nil,
    font_body = nil,
    font_small = nil,
    label_text = {},
}

local render_nav
local render_list
local refresh_installed
local update_header_text
local clear_detail
local nav_item_by_id
local current_nav_status_text

local function t(key, ...)
    local dict = I18N[state.lang] or I18N.en
    local text = dict[key] or I18N.en[key] or key
    if select("#", ...) > 0 then
        return string.format(text, ...)
    end
    return text
end

local function nav_label(nav)
    return t(nav.label_key or nav.id)
end

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$") or ""
end

local function clipped(value, max_len)
    local text = trim(value)
    if text == "" then
        return "--"
    end
    if #text > max_len then
        return text:sub(1, max_len - 3) .. "..."
    end
    return text
end

local function clock_text()
    local ok, value = pcall(os.date, "%H:%M")
    if ok and type(value) == "string" and value ~= "" then
        return value
    end
    return "--:--"
end

local function skill_title(item, max_len)
    return clipped(item and (item.title or item.name or item.id), max_len or 18)
end

local function skill_desc(item, max_len)
    return clipped(item and (item.description or item.summary or ""), max_len or (state.compact and 30 or 42))
end

local function skill_author(item)
    return clipped(item and (item.author or "ESP-Claw contributor"), state.compact and 24 or 34)
end

local function skill_mode(item)
    local metadata = type(item and item.metadata) == "table" and item.metadata or {}
    return tostring(item and (item.manage_mode or metadata.manage_mode) or "")
end

local function set_cached_text(key, obj, text)
    text = tostring(text or "")
    if obj and ui.label_text[key] ~= text then
        obj:set_text(text)
        ui.label_text[key] = text
    end
end

local function set_status(text)
    state.status = tostring(text or "")
    set_cached_text("status", ui.status, state.status)
    print(TAG .. " " .. state.status)
end

local function switch_language()
    state.lang = state.lang == "en" and "zh" or "en"
    if update_header_text then
        update_header_text()
    end
    render_nav()
    render_list()
    if ui.detail_overlay then
        clear_detail()
    end
    set_status(current_nav_status_text())
end

local function load_font(size, cache_size)
    local ok, font_or_err = pcall(lvgl.font_load, FONT_PATH, {
        size = size,
        cache_size = cache_size,
    })
    if ok then
        return font_or_err
    end
    print(TAG .. " WARN: failed to load font size " .. tostring(size) .. ": " .. tostring(font_or_err))
    return nil
end

local function load_fonts()
    ui.font_title = load_font(state.compact and 22 or 26, 80)
    ui.font_body = load_font(state.compact and 17 or 19, 128)
    ui.font_small = load_font(state.compact and 15 or 16, 128)
end

local function lv_dim(value, fallback)
    local num = tonumber(value)
    if not num then
        num = fallback or 0
    end
    if num < 0 then
        num = 0
    end
    return math.floor(num)
end

local function make_label(parent, key, text, color, width, height, bg_color, font)
    local label = lvgl.label(parent, {
        text = text,
        w = lv_dim(width, 0),
        h = lv_dim(height, 20),
        text_color = color or COLORS.text,
        bg_color = bg_color or COLORS.bg,
        bg_opa = 255,
        font = font,
    })
    ui.label_text[key] = text
    return label
end

local function make_button(parent, text, width, height, opts)
    opts = opts or {}
    return lvgl.button(parent, {
        text = text,
        w = lv_dim(width, 0),
        h = lv_dim(height, 0),
        radius = opts.radius or 8,
        bg_color = opts.bg_color or COLORS.panel_alt,
        bg_opa = opts.bg_opa or 255,
        border_color = opts.border_color or opts.bg_color or COLORS.panel_alt,
        border_width = opts.border_width or 0,
        text_color = opts.text_color or COLORS.text,
        font = opts.font or ui.font_small,
        pad = opts.pad or 0,
        pad_column = opts.pad_column or 0,
    })
end

local function add_download_icon(parent)
    local icon = lvgl.container(parent, {
        w = 14,
        h = 16,
        bg_opa = 0,
        border_width = 0,
        pad = 0,
    })
    lvgl.line(icon, {
        points = { { x = 7, y = 1 }, { x = 7, y = 8 } },
        line_color = COLORS.button_text,
        line_width = 2,
    })
    lvgl.line(icon, {
        points = { { x = 4, y = 6 }, { x = 7, y = 10 }, { x = 10, y = 6 } },
        line_color = COLORS.button_text,
        line_width = 2,
    })
    lvgl.line(icon, {
        points = { { x = 3, y = 13 }, { x = 11, y = 13 } },
        line_color = COLORS.button_text,
        line_width = 2,
    })
    return icon
end

local function approximate_text_width(text)
    local len = #tostring(text or "")
    if state.lang == "en" then
        return len * (state.compact and 7 or 8)
    end
    return len * (state.compact and 4 or 5)
end

local function make_download_button(parent, width, height)
    local btn_w = lv_dim(width, 0)
    local btn = lvgl.button(parent, {
        w = btn_w,
        h = lv_dim(height, 0),
        radius = 8,
        bg_color = COLORS.button_bg,
        bg_opa = 255,
        border_color = COLORS.accent,
        border_width = 1,
        text_color = COLORS.button_text,
        font = ui.font_small,
        pad = 0,
    })
    local content_h = lv_dim(state.compact and 18 or 20, 20)
    local text_w = lv_dim(approximate_text_width(t("install")) + 4, 18)
    local content_w = lv_dim(14 + 4 + text_w, 0)
    local content = lvgl.container(btn, {
        align = "center",
        w = content_w,
        h = content_h,
        bg_opa = 0,
        border_width = 0,
        pad = 0,
        pad_column = 4,
    })
    content:set_flex({ flow = "row", main = "center", cross = "center" })
    add_download_icon(content)
    make_label(content, "download_text_" .. tostring(btn), t("install"), COLORS.button_text, text_w, content_h, COLORS.button_bg, ui.font_small)
    return btn
end

local function card_action_button_width(item, card_w)
    local text = t("install")
    local extra = state.compact and 38 or 42
    local min_w = state.lang == "en" and (state.compact and 90 or 96) or (state.compact and 72 or 82)

    if state.busy_skill_id == item.id then
        text = t("installing")
        extra = state.compact and 18 or 22
        min_w = state.lang == "en" and (state.compact and 104 or 116) or (state.compact and 86 or 98)
    elseif item.installed then
        text = t("installed")
        extra = state.compact and 18 or 22
        min_w = state.lang == "en" and (state.compact and 92 or 100) or (state.compact and 78 or 92)
    end

    local ideal_w = math.max(min_w, approximate_text_width(text) + extra)
    local max_w = math.max(min_w, card_w - (state.compact and 92 or 118))
    return lv_dim(math.min(ideal_w, max_w), min_w)
end

local function make_action_button(parent, item, width, height)
    if state.busy_skill_id == item.id then
        return make_button(parent, t("installing"), width, height, {
            bg_color = COLORS.installed_bg,
            border_color = COLORS.installed_border,
            border_width = 1,
            text_color = COLORS.installed_text,
            font = ui.font_small,
        })
    end

    if item.installed then
        return make_button(parent, t("installed"), width, height, {
            bg_color = COLORS.installed_bg,
            border_color = COLORS.installed_border,
            border_width = 1,
            text_color = COLORS.installed_text,
            font = ui.font_small,
        })
    end

    local btn = make_download_button(parent, width, height)
    btn:on("clicked", function()
        state.busy_skill_id = item.id
        set_status(t("downloading", tostring(item.id)))
        render_list()
        lvgl.process_events(20)

        local ok, err = pcall(skills_lab.install_skill, item.id)
        state.busy_skill_id = ""
        if ok then
            item.installed = true
            item.installed_id = item.id
            item.protected = false
            item.removable = true
            refresh_installed()
            set_status(t("installed_done", tostring(item.id)))
        else
            set_status(t("install_failed"))
            print(TAG .. " ERROR: " .. tostring(err))
        end
        render_list()
    end)
    return btn
end

nav_item_by_id = function(id)
    for _, item in ipairs(NAV_ITEMS) do
        if item.id == id then
            return item
        end
    end
    return NAV_ITEMS[1]
end

current_nav_status_text = function()
    local nav = nav_item_by_id(state.active_nav)
    if nav.kind == "installed" then
        return t("installed_count", #state.installed_items)
    end
    if nav.kind == "all" then
        return t("all_count", #state.all_items)
    end
    return t("category_count", nav_label(nav), #state.remote_items)
end

clear_detail = function()
    if ui.detail_overlay then
        ui.detail_overlay:delete()
        ui.detail_overlay = nil
    end
end

local function current_script_dir()
    local info = debug.getinfo(1, "S")
    local source = info and info.source or ""
    if source:sub(1, 1) == "@" then
        source = source:sub(2)
    end
    return source:match("^(.*)/[^/]+$")
end

local function loader_path()
    local dir = current_script_dir()
    if not dir then
        error("failed to resolve skills lab script dir")
    end
    return dir .. "/skills_lab_loader.lua"
end

local function control_dir()
    return storage.join_path(CONTROL_ROOT, CONTROL_DIR)
end

local function status_path()
    return storage.join_path(control_dir(), STATUS_FILE)
end

local function read_loader_status()
    local path = status_path()
    if not storage.exists(path) then
        return nil
    end
    local text = storage.read_file(path)
    if type(text) ~= "string" or text == "" then
        return nil
    end
    local ok, data = pcall(json.decode, text)
    if not ok or type(data) ~= "table" then
        print(TAG .. " WARN: invalid loader status: " .. tostring(data))
        return nil
    end
    return data
end

local function loader_job_exists()
    local ok, output = thread.get(LOADER_JOB_NAME)
    if ok then
        return output:find("status=running", 1, true) ~= nil or output:find("status=queued", 1, true) ~= nil
    end
    return false
end

local function start_loader_if_needed()
    if state.all_loader_started and loader_job_exists() then
        return true
    end
    if loader_job_exists() then
        state.all_loader_started = true
        return true
    end

    local ok, err = thread.start(loader_path(), {}, {
        name = LOADER_JOB_NAME,
        exclusive = LOADER_EXCLUSIVE,
        replace = false,
        timeout_ms = 0,
    })
    if not ok then
        local text = tostring(err)
        if text:find("already", 1, true) or text:find("running", 1, true) or text:find("exclusive", 1, true) then
            state.all_loader_started = true
            return true
        end
        print(TAG .. " ERROR: failed to start loader: " .. text)
        set_status(t("loader_start_failed"))
        return false
    end

    state.all_loader_started = true
    return true
end

refresh_installed = function()
    local ok, installed_or_err, items = pcall(function()
        local _, installed_items = skills_lab.list_installed()
        return nil, installed_items
    end)
    if not ok then
        set_status(t("installed_load_failed"))
        print(TAG .. " ERROR: " .. tostring(installed_or_err))
        return false
    end
    state.installed_items = items or {}
    return true
end

local function apply_loader_status(status, force_render)
    if type(status) ~= "table" then
        return false
    end
    if not force_render and state.all_status_version == status.version then
        return false
    end

    state.all_status_version = status.version
    state.all_items = type(status.items) == "table" and status.items or {}
    state.all_loading = status.loading == true
    state.all_done = status.done == true

    if state.active_nav ~= "all" then
        return true
    end

    if status.ok == false then
        set_status(t("all_load_failed"))
    else
        set_status(current_nav_status_text())
    end

    render_list()
    return true
end

local function poll_loader_status()
    if not state.all_loader_started and state.active_nav ~= "all" then
        return
    end
    local status = read_loader_status()
    if status then
        apply_loader_status(status, false)
    elseif state.active_nav == "all" and state.all_loading then
        set_status(current_nav_status_text())
    end
end

local function show_all()
    state.active_nav = "all"
    render_nav()

    local status = read_loader_status()
    if status then
        apply_loader_status(status, true)
    else
        state.all_items = {}
        state.all_done = false
        state.all_loading = true
        state.all_status_version = nil
        set_status(current_nav_status_text())
        render_list()
    end

    if not state.all_done then
        start_loader_if_needed()
    end
end

local function load_remote_nav(nav)
    state.active_nav = nav.id
    state.remote_items = {}
    render_nav()
    render_list()
    set_status(current_nav_status_text())
    lvgl.process_events(20)

    local opts = {}
    if nav.kind == "category" then
        opts.category = nav.category
    else
        opts.query = nav.query or ""
    end

    local ok, result = pcall(skills_lab.search, opts)
    if ok and type(result) == "table" then
        state.remote_items = result.results or {}
        set_status(current_nav_status_text())
    else
        state.remote_items = {}
        set_status(t("load_failed"))
        print(TAG .. " ERROR: " .. tostring(result))
    end
    render_list()
end

local function select_nav(nav)
    if nav.kind == "installed" then
        state.active_nav = nav.id
        set_status(current_nav_status_text())
        lvgl.process_events(20)
        refresh_installed()
        set_status(current_nav_status_text())
        render_nav()
        render_list()
        return
    end
    if nav.kind == "all" then
        show_all()
        return
    end
    load_remote_nav(nav)
end

local function remove_item(item)
    if type(item) ~= "table" then
        return
    end
    local skill_id = item.installed_id ~= "" and item.installed_id or item.id
    clear_detail()
    set_status(t("removing", tostring(skill_id)))
    lvgl.process_events(20)

    local ok, err = pcall(skills_lab.uninstall_skill, skill_id)
    if ok then
        item.installed = false
        item.installed_id = ""
        item.removable = false
        refresh_installed()
        set_status(t("removed", tostring(skill_id)))
    else
        set_status(t("remove_failed"))
        print(TAG .. " ERROR: " .. tostring(err))
    end
    render_list()
end

local function open_detail(item)
    clear_detail()
    if not ui.screen or type(item) ~= "table" then
        return
    end

    local width = state.width
    local height = state.height
    local compact = state.compact
    ui.detail_overlay = lvgl.container(ui.screen, {
        w = lv_dim(width, 0),
        h = lv_dim(height, 0),
        bg_color = COLORS.overlay,
        bg_opa = 160,
        border_width = 0,
        pad = 0,
    })

    local drawer_w = width - (compact and 18 or 34)
    local drawer_h = math.floor(height * (compact and 0.82 or 0.74))
    local drawer = lvgl.container(ui.detail_overlay, {
        align = "bottom_mid",
        w = lv_dim(drawer_w, 0),
        h = lv_dim(drawer_h, 0),
        bg_color = COLORS.panel,
        bg_opa = 255,
        border_color = COLORS.accent,
        border_width = 1,
        radius = 18,
        pad = compact and 10 or 14,
        pad_row = compact and 6 or 8,
    })
    drawer:set_flex({ flow = "column", main = "start", cross = "center" })
    drawer:set_scroll({ dir = "none", scrollbar = "off" })

    local header_h = compact and 36 or 44
    local footer_h = compact and 46 or 54
    local body_h = math.max(78, drawer_h - header_h - footer_h - (compact and 34 or 44))

    local header = lvgl.container(drawer, {
        w = lv_dim(drawer_w - 24, 0),
        h = lv_dim(header_h, 0),
        bg_color = COLORS.panel,
        bg_opa = 255,
        border_width = 0,
        pad = 0,
    })
    header:set_flex({ flow = "row", main = "space_between", cross = "center" })
    make_label(header, "detail_title", skill_title(item, compact and 18 or 30), COLORS.text, drawer_w - 78, compact and 30 or 36, COLORS.panel, ui.font_body)
    local close_btn = make_button(header, "X", compact and 34 or 40, compact and 30 or 34, {
        bg_color = COLORS.panel_alt,
        text_color = COLORS.text,
        font = ui.font_small,
    })
    close_btn:on("clicked", clear_detail)

    local body = lvgl.container(drawer, {
        w = lv_dim(drawer_w - 28, 0),
        h = lv_dim(body_h, 0),
        bg_color = COLORS.panel,
        bg_opa = 255,
        border_width = 0,
        pad = 0,
        pad_row = compact and 5 or 7,
    })
    body:set_flex({ flow = "column", main = "start", cross = "center" })
    body:set_scroll({ dir = "ver", scrollbar = "auto" })

    make_label(body, "detail_author", t("detail_author", skill_author(item)), COLORS.faint, drawer_w - 32, compact and 20 or 24, COLORS.panel, ui.font_small)
    make_label(body, "detail_desc", skill_desc(item, compact and 46 or 72), COLORS.muted, drawer_w - 32, compact and 40 or 54, COLORS.panel, ui.font_small)
    make_label(body, "detail_id", t("detail_id", tostring(item.id or "--")), COLORS.faint, drawer_w - 32, compact and 18 or 22, COLORS.panel, ui.font_small)
    make_label(body, "detail_mode", t("detail_mode", (skill_mode(item) ~= "" and skill_mode(item) or "--")), COLORS.faint, drawer_w - 32, compact and 18 or 22, COLORS.panel, ui.font_small)

    local status_text = t("status_not_installed")
    if item.protected then
        status_text = t("status_protected")
    elseif item.installed and item.removable then
        status_text = t("status_removable")
    elseif item.installed then
        status_text = t("status_installed")
    end
    make_label(body, "detail_status", status_text, COLORS.yellow, drawer_w - 32, compact and 22 or 26, COLORS.panel, ui.font_small)

    local actions = lvgl.container(drawer, {
        w = lv_dim(drawer_w - 28, 0),
        h = lv_dim(footer_h, 0),
        bg_opa = 0,
        border_width = 0,
        pad = 0,
        pad_column = compact and 8 or 12,
    })
    actions:set_flex({ flow = "row", main = "center", cross = "center" })

    if item.installed then
        if item.removable then
            local remove_btn = make_button(actions, t("uninstall"), compact and 128 or 150, compact and 36 or 42, {
                bg_color = "#351D2A",
                border_color = COLORS.red,
                border_width = 1,
                text_color = "#FFD7DC",
                font = ui.font_small,
            })
            remove_btn:on("clicked", function()
                remove_item(item)
            end)
        else
            make_button(actions, item.protected and t("protected") or t("installed"), compact and 112 or 132, compact and 36 or 42, {
                bg_color = COLORS.installed_bg,
                border_color = COLORS.installed_border,
                border_width = 1,
                text_color = COLORS.installed_text,
                font = ui.font_small,
            })
        end
    else
        local install_btn = make_download_button(actions, compact and 104 or 124, compact and 36 or 42)
        install_btn:on("clicked", function()
            clear_detail()
            state.busy_skill_id = item.id
            set_status(t("downloading", tostring(item.id)))
            render_list()
            lvgl.process_events(20)
            local ok, err = pcall(skills_lab.install_skill, item.id)
            state.busy_skill_id = ""
            if ok then
                item.installed = true
                item.installed_id = item.id
                item.protected = false
                item.removable = true
                refresh_installed()
                set_status(t("installed_done", tostring(item.id)))
            else
                set_status(t("install_failed"))
                print(TAG .. " ERROR: " .. tostring(err))
            end
            render_list()
        end)
    end
end

render_nav = function()
    if ui.nav_panel then
        ui.nav_panel:delete()
        ui.nav_panel = nil
    end
    if not ui.content then
        return
    end

    local compact = state.compact
    local nav_w = state.wide and 108 or (state.width - 20)
    local nav_h = state.wide and (state.height - (compact and 94 or 116)) or (compact and 42 or 48)
    ui.nav_panel = lvgl.container(ui.content, {
        w = lv_dim(nav_w, 0),
        h = lv_dim(nav_h, 0),
        bg_color = COLORS.bg_soft,
        bg_opa = 255,
        border_color = "#1D324B",
        border_width = state.wide and 1 or 0,
        radius = state.wide and 12 or 0,
        pad = compact and 4 or 6,
        pad_row = compact and 5 or 7,
        pad_column = compact and 6 or 8,
    })
    ui.nav_panel:set_flex({
        flow = state.wide and "column" or "row",
        main = "start",
        cross = "center",
    })
    ui.nav_panel:set_scroll({ dir = state.wide and "ver" or "hor", scrollbar = "off" })

    for _, nav in ipairs(NAV_ITEMS) do
        local active = state.active_nav == nav.id
        local btn = make_button(ui.nav_panel, nav_label(nav), state.wide and (nav_w - 14) or (compact and 72 or 82), compact and 32 or 36, {
            radius = 8,
            bg_color = active and COLORS.accent_dark or COLORS.bg_soft,
            border_color = active and COLORS.accent or COLORS.bg_soft,
            border_width = active and 1 or 0,
            text_color = active and COLORS.button_text or COLORS.muted,
            font = ui.font_small,
        })
        btn:on("clicked", function()
            select_nav(nav)
        end)
    end
end

local function make_skill_card(parent, item, card_w, card_h, index)
    local installed = item.installed == true
    local card_bg = installed and COLORS.panel_installed or COLORS.panel
    local card = lvgl.button(parent, {
        text = "",
        w = lv_dim(card_w, 0),
        h = lv_dim(card_h, 0),
        radius = 12,
        bg_color = card_bg,
        bg_opa = 255,
        border_color = installed and COLORS.accent or "#272936",
        border_width = 1,
        text_color = COLORS.text,
        pad = state.compact and 8 or 10,
        pad_row = state.compact and 4 or 5,
    })
    card:set_flex({ flow = "column", main = "start", cross = "start" })
    card:on("clicked", function()
        open_detail(item)
    end)

    local title_row = lvgl.container(card, {
        w = lv_dim(card_w - (state.compact and 18 or 22), 0),
        h = lv_dim(state.compact and 28 or 32, 0),
        bg_color = card_bg,
        bg_opa = 255,
        border_width = 0,
        pad = 0,
        pad_column = 6,
    })
    title_row:set_flex({ flow = "row", main = "space_between", cross = "center" })

    local btn_w = card_action_button_width(item, card_w)
    local btn_h = state.compact and 26 or 30
    local title_w = card_w - btn_w - (state.compact and 36 or 44)
    make_label(title_row, "card_title_" .. tostring(index), skill_title(item, state.compact and 14 or 18), installed and COLORS.accent or COLORS.text, title_w, state.compact and 22 or 24, card_bg, ui.font_body)
    make_action_button(title_row, item, btn_w, btn_h)

    make_label(card, "card_author_" .. tostring(index), t("author", skill_author(item)), COLORS.faint, card_w - 22, state.compact and 18 or 20, card_bg, ui.font_small)
    make_label(card, "card_desc_" .. tostring(index), skill_desc(item, state.compact and 28 or 40), COLORS.muted, card_w - 22, state.compact and 20 or 22, card_bg, ui.font_small)
end

render_list = function()
    if ui.list_panel then
        ui.list_panel:delete()
        ui.list_panel = nil
    end
    if not ui.content then
        return
    end

    local compact = state.compact
    local nav_w = state.wide and 108 or 0
    local list_w = state.wide and (state.width - nav_w - 30) or (state.width - 20)
    local list_h = state.wide and (state.height - (compact and 94 or 116)) or (state.height - (compact and 134 or 158))
    local items = state.remote_items
    if state.active_nav == "installed" then
        items = state.installed_items
    elseif state.active_nav == "all" then
        items = state.all_items
    end

    ui.list_panel = lvgl.container(ui.content, {
        w = lv_dim(list_w, 0),
        h = lv_dim(list_h, 0),
        bg_color = COLORS.bg,
        bg_opa = 255,
        border_width = 0,
        pad = 0,
        pad_row = compact and 7 or 9,
        pad_column = compact and 7 or 9,
    })
    ui.list_panel:set_scroll({ dir = "ver", scrollbar = "auto" })

    local use_grid = state.wide and list_w >= 430
    ui.list_panel:set_flex({
        flow = use_grid and "row_wrap" or "column",
        main = "start",
        cross = "start",
    })

    if #items == 0 then
        local nav = nav_item_by_id(state.active_nav)
        local text = nav.kind == "installed" and t("no_installed") or t("select_category")
        if state.active_nav == "all" then
            text = t("loading_all")
        end
        make_label(ui.list_panel, "empty", text, COLORS.faint, list_w - 12, compact and 42 or 50, COLORS.bg, ui.font_body)
        return
    end

    local card_w
    if use_grid then
        card_w = math.floor((list_w - (compact and 8 or 10)) / 2)
    else
        card_w = list_w - 4
    end
    local card_h = compact and 112 or 128
    for index, item in ipairs(items) do
        make_skill_card(ui.list_panel, item, card_w, card_h, index)
    end
end

local function build_header()
    local compact = state.compact
    local header_h = compact and 76 or 98
    local header = lvgl.container(ui.root, {
        w = lv_dim(state.width, 0),
        h = lv_dim(header_h, 0),
        bg_color = COLORS.bg,
        bg_opa = 255,
        border_width = 0,
        pad = compact and 6 or 8,
        pad_row = compact and 4 or 6,
    })
    ui.header = header
    header:set_flex({ flow = "column", main = "center", cross = "center" })

    local top = lvgl.container(header, {
        w = lv_dim(state.width - 20, 0),
        h = lv_dim(compact and 30 or 38, 0),
        bg_color = COLORS.bg,
        bg_opa = 255,
        border_width = 0,
        pad = 0,
    })
    top:set_flex({ flow = "row", main = "space_between", cross = "center" })
    ui.hero_title = make_label(top, "hero_title", t("title"), COLORS.text, state.width - (compact and 150 or 176), compact and 26 or 34, COLORS.bg, ui.font_title)
    local header_actions = lvgl.container(top, {
        w = lv_dim(compact and 128 or 154, 0),
        h = lv_dim(compact and 28 or 32, 0),
        bg_color = COLORS.bg,
        bg_opa = 255,
        border_width = 0,
        pad = 0,
        pad_column = 6,
    })
    header_actions:set_flex({ flow = "row", main = "end", cross = "center" })
    ui.lang_button = make_button(header_actions, t("lang"), compact and 66 or 82, compact and 24 or 28, {
        bg_color = COLORS.panel_alt,
        border_color = COLORS.installed_border,
        border_width = 1,
        text_color = COLORS.muted,
        font = ui.font_small,
    })
    ui.lang_button:on("clicked", switch_language)
    ui.clock = make_label(header_actions, "clock", clock_text(), COLORS.faint, 46, compact and 20 or 24, COLORS.bg, ui.font_small)

    local status_w = math.min(state.width - 44, state.wide and 360 or state.width - 44)
    local status_bar = lvgl.container(header, {
        w = lv_dim(status_w, 0),
        h = lv_dim(compact and 30 or 36, 0),
        bg_color = COLORS.bg_soft,
        bg_opa = 255,
        border_color = "#1D324B",
        border_width = 1,
        radius = 10,
        pad = 0,
    })
    status_bar:set_flex({ flow = "row", main = "center", cross = "center" })
    ui.status = make_label(status_bar, "status", current_nav_status_text(), COLORS.faint, status_w - 20, compact and 22 or 26, COLORS.bg_soft, ui.font_small)
end

update_header_text = function()
    set_cached_text("hero_title", ui.hero_title, t("title"))
    set_cached_text("lang_button", ui.lang_button, t("lang"))
    if ui.status then
        set_cached_text("status", ui.status, current_nav_status_text())
    end
end

local function build_ui(width, height)
    state.width = width
    state.height = height
    state.compact = height < 360
    state.wide = width >= 420

    local scr = lvgl.create_screen()
    ui.screen = scr
    scr:set_style({ bg_color = COLORS.bg })

    load_fonts()

    ui.root = lvgl.container(scr, {
        w = lv_dim(width, 0),
        h = lv_dim(height, 0),
        bg_color = COLORS.bg,
        bg_opa = 255,
        border_width = 0,
        pad = 0,
        pad_row = 0,
    })
    ui.root:set_flex({ flow = "column", main = "start", cross = "center" })
    ui.root:set_scroll({ dir = "none", scrollbar = "off" })

    build_header()

    ui.content = lvgl.container(ui.root, {
        w = lv_dim(width, 0),
        h = lv_dim(height - (state.compact and 76 or 98), 0),
        bg_color = COLORS.bg,
        bg_opa = 255,
        border_width = 0,
        pad = 8,
        pad_column = state.compact and 6 or 8,
        pad_row = state.compact and 6 or 8,
    })
    ui.content:set_flex({
        flow = state.wide and "row" or "column",
        main = "start",
        cross = "start",
    })
    ui.content:set_scroll({ dir = "none", scrollbar = "off" })

    render_nav()
    render_list()
    scr:load()
end

local function run()
    local panel_handle, io_handle, width, height, panel_if =
        board_manager.get_display_lcd_params("display_lcd")
    if not panel_handle then
        error("get_display_lcd_params(display_lcd) failed: " .. tostring(io_handle))
    end

    lvgl.init(panel_handle, io_handle, width, height, panel_if, {
        buffer_lines = 10,
        tick_ms = 5,
        task_period_ms = 10,
    })

    local touch_handle, touch_err = board_manager.get_lcd_touch_handle("lcd_touch")
    if touch_handle then
        local ok, err = pcall(lvgl.indev_register, "touch", touch_handle)
        if not ok then
            print(TAG .. " WARN: touch register failed: " .. tostring(err))
        end
    else
        print(TAG .. " WARN: no touch handle: " .. tostring(touch_err))
    end

    build_ui(width, height)
    select_nav(nav_item_by_id("installed"))

    local next_clock_ms = os.time() * 1000 + CLOCK_REFRESH_MS
    local next_loader_poll_ms = os.time() * 1000 + LOADER_POLL_MS
    while true do
        lvgl.process_events(EVENT_POLL_MS)
        local now_ms = os.time() * 1000
        if now_ms >= next_clock_ms then
            set_cached_text("clock", ui.clock, clock_text())
            next_clock_ms = now_ms + CLOCK_REFRESH_MS
        end
        if now_ms >= next_loader_poll_ms then
            poll_loader_status()
            next_loader_poll_ms = now_ms + LOADER_POLL_MS
        end
        delay.delay_ms(10)
    end
end

local ok, err = xpcall(run, debug.traceback)
pcall(lvgl.indev_unregister, "touch")
pcall(lvgl.deinit)
if not ok then
    print(TAG .. " ERROR: " .. tostring(err))
    error(err)
end
