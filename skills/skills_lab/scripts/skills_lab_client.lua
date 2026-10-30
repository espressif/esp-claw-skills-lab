local capability = require("capability")
local json = require("json")
local storage = require("storage")

local M = {}

local HUB_HOST = "skills-lab.esp-claw.com"
local HUB_API_BASE = "https://" .. HUB_HOST .. "/api"
local HUB_RAW_BASE = "https://" .. HUB_HOST .. "/raw"
local CATALOG_HTTP_TIMEOUT_MS = 6000
local INSTALL_HTTP_TIMEOUT_MS = 20000
local HTTP_MAX_BODY_BYTES = 65535
local HTTP_MAX_FILE_BYTES = 10 * 1024 * 1024

local DEFAULT_CATEGORIES = { "ai", "game", "hardware", "media", "network", "sensor", "utility" }
local PROTECTED_SKILLS = {
    camera_preview = true,
    network_radio = true,
    flappybird = true,
    stock_quotes_display = true,
    china_a_share_quote = true,
    skills_lab = true,
}
local INSTALLED_ALIASES = {
    china_a_share_quote = "stock_quotes_display",
}

local function validate_skill_id(skill_id)
    if type(skill_id) ~= "string" or skill_id == "" then
        error("skill_id is required")
    end
    if not skill_id:match("^[A-Za-z0-9_-]+$") then
        error("skill_id must match ^[A-Za-z0-9_-]+$")
    end
end

local function url_encode(value)
    return tostring(value or ""):gsub("([^%w%-_%.~])", function(ch)
        return string.format("%%%02X", string.byte(ch))
    end)
end

local function parse_http_output(out)
    local first_line, body = tostring(out or ""):match("^(.-)\n(.*)$")
    if not first_line then
        first_line = tostring(out or "")
        body = ""
    end
    local status = tonumber(first_line:match("^HTTP%s+(%d+)"))
    if not status then
        error("unexpected http_request output: " .. tostring(out))
    end
    return status, body, first_line
end

local function with_allowlist_hint(message)
    message = tostring(message or "")
    if message:find("HTTP allowlist is empty", 1, true) or message:find("is not in allowlist", 1, true) then
        return message .. ". Add skills-lab.esp-claw.com or *.esp-claw.com to the HTTP allowlist."
    end
    return message
end

local function http_get(url, timeout_ms)
    local ok, out, err = capability.call("http_request", {
        url = url,
        method = "GET",
        timeout_ms = timeout_ms or CATALOG_HTTP_TIMEOUT_MS,
        max_body_bytes = HTTP_MAX_BODY_BYTES,
    }, {
        source_cap = "skills_lab",
        max_output_bytes = HTTP_MAX_BODY_BYTES + 128,
    })
    if not ok then
        error(with_allowlist_hint(err or out or "http_request failed"))
    end
    local status, body = parse_http_output(out)
    if status ~= 200 then
        error(string.format("request failed with HTTP %d: %s", status, body))
    end
    return body
end

local function http_save(url, path)
    local ok, out, err = capability.call("http_request", {
        url = url,
        method = "GET",
        timeout_ms = INSTALL_HTTP_TIMEOUT_MS,
        save_path = path,
        max_file_bytes = HTTP_MAX_FILE_BYTES,
    }, {
        source_cap = "skills_lab",
    })
    if not ok then
        error(with_allowlist_hint(err or out or "http_request failed"))
    end
    local status, _, first_line = parse_http_output(out)
    if status ~= 200 then
        pcall(storage.remove, path)
        error(string.format("failed to download %s (HTTP %d)", url, status))
    end
    if first_line:find("file truncated", 1, true) then
        pcall(storage.remove, path)
        error(string.format("failed to download %s: file exceeds %d bytes", url, HTTP_MAX_FILE_BYTES))
    end
end

local function decode_json(text, what)
    local ok, data = pcall(json.decode, text)
    if not ok or type(data) ~= "table" then
        error("invalid " .. what .. " JSON")
    end
    return data
end

local function ensure_dir(path)
    if storage.exists(path) then
        return
    end
    local current = path:sub(1, 1) == "/" and "/" or ""
    for part in path:gmatch("[^/]+") do
        current = storage.join_path(current, part)
        if not storage.exists(current) then
            storage.mkdir(current)
        end
    end
end

local function validate_extra_file_name(name, group_name)
    if type(name) ~= "string" or name == "" then
        error("invalid file name in extra_files." .. tostring(group_name))
    end
    if name:find("/", 1, true) or name:find("\\", 1, true) then
        error("extra_files." .. tostring(group_name) .. " entries must be file names only: " .. name)
    end
end

local function skill_dir(skill_id)
    return storage.join_path(storage.get_root_dir(), "skills", skill_id)
end

function M.list_installed()
    local ok, out, err = capability.call("list_skill", {}, {
        source_cap = "skills_lab",
        max_output_bytes = 262144,
    })
    if not ok then
        error(tostring(err or out or "list_skill failed"))
    end

    local data = decode_json(out or "{}", "skill catalog")
    local installed = {}
    local items = {}
    for _, item in ipairs(data.skills or {}) do
        if type(item) == "table" and type(item.id) == "string" then
            local protected = PROTECTED_SKILLS[item.id] == true
            item.installed = true
            item.installed_id = item.id
            item.protected = protected
            item.removable = not protected and item.manage_mode == "web"
            item.local_only = true
            installed[item.id] = item
            items[#items + 1] = item
        end
    end
    table.sort(items, function(lhs, rhs)
        return tostring(lhs.title or lhs.id) < tostring(rhs.title or rhs.id)
    end)
    return installed, items
end

local function installed_status(skill_id, installed)
    local installed_id = INSTALLED_ALIASES[skill_id] or skill_id
    local installed_item = installed[installed_id]
    local protected = PROTECTED_SKILLS[skill_id] == true or PROTECTED_SKILLS[installed_id] == true
    return {
        installed = installed_item ~= nil,
        installed_id = installed_item and installed_id or "",
        protected = protected,
        removable = installed_item ~= nil and not protected and installed_item.manage_mode == "web",
    }
end

local function annotate_skill(item, installed)
    if type(item) ~= "table" or type(item.id) ~= "string" then
        return item
    end
    local status = installed_status(item.id, installed)
    item.installed = status.installed
    item.installed_id = status.installed_id
    item.protected = status.protected
    item.removable = status.removable
    item.local_only = false
    return item
end

function M.fetch_tags()
    local ok, data_or_err = pcall(function()
        return decode_json(http_get(HUB_RAW_BASE .. "/tags.json", CATALOG_HTTP_TIMEOUT_MS), "tags")
    end)
    if ok and type(data_or_err.category) == "table" and #data_or_err.category > 0 then
        return data_or_err
    end
    return {
        category = DEFAULT_CATEGORIES,
        tag = {},
        peripheral = {},
    }
end

function M.search(opts)
    opts = type(opts) == "table" and opts or {}
    local installed = M.list_installed()
    local query = type(opts.query) == "string" and opts.query or ""
    local category = type(opts.category) == "string" and opts.category or ""
    local search_query = query
    local by_id = {}
    local results = {}

    if search_query == "" and category ~= "" then
        search_query = 'c:"' .. category .. '"'
    end

    local data = decode_json(http_get(HUB_API_BASE .. "/search?q=" .. url_encode(search_query), CATALOG_HTTP_TIMEOUT_MS), "catalog")
    for _, item in ipairs(data.results or {}) do
        if type(item) == "table" and type(item.id) == "string" and not by_id[item.id] then
            by_id[item.id] = annotate_skill(item, installed)
            results[#results + 1] = by_id[item.id]
        end
    end

    table.sort(results, function(lhs, rhs)
        if (lhs.featured == true) ~= (rhs.featured == true) then
            return lhs.featured == true
        end
        return tostring(lhs.title or lhs.id) < tostring(rhs.title or rhs.id)
    end)

    return {
        ok = true,
        results = results,
        category = category,
        query = search_query,
    }
end

local function fetch_metadata(skill_id)
    validate_skill_id(skill_id)
    local data = decode_json(http_get(HUB_RAW_BASE .. "/" .. skill_id .. "/_metadata.json"), "metadata")
    if type(data.name) == "string" and data.name ~= skill_id then
        error("metadata name mismatch: " .. data.name)
    end
    return data
end

function M.install_skill(skill_id)
    validate_skill_id(skill_id)
    local metadata = fetch_metadata(skill_id)
    local base_dir = skill_dir(skill_id)
    ensure_dir(base_dir)

    http_save(HUB_RAW_BASE .. "/" .. skill_id .. "/SKILL.md", storage.join_path(base_dir, "SKILL.md"))

    local extra_files = type(metadata.extra_files) == "table" and metadata.extra_files or {}
    for group_name, files in pairs(extra_files) do
        if type(files) ~= "table" then
            error("extra_files." .. tostring(group_name) .. " must be an array")
        end
        if #files > 0 then
            local group_dir = storage.join_path(base_dir, tostring(group_name))
            ensure_dir(group_dir)
            for _, file_name in ipairs(files) do
                validate_extra_file_name(file_name, group_name)
                http_save(
                    HUB_RAW_BASE .. "/" .. skill_id .. "/" .. tostring(group_name) .. "/" .. file_name,
                    storage.join_path(group_dir, file_name)
                )
            end
        end
    end

    local ok, out, err = capability.call("register_skill", {
        skill_id = skill_id,
        file = skill_id .. "/SKILL.md",
    }, {
        source_cap = "skills_lab",
        max_output_bytes = 262144,
    })
    if not ok then
        error(tostring(err or out or "register_skill failed"))
    end

    return {
        ok = true,
        skill_id = skill_id,
        path = base_dir,
        register_result = decode_json(out or "{}", "register result"),
    }
end

function M.uninstall_skill(skill_id)
    validate_skill_id(skill_id)
    if PROTECTED_SKILLS[skill_id] then
        error("skill is protected builtin")
    end

    local ok, out, err = capability.call("unregister_skill", {
        skill_id = skill_id,
    }, {
        source_cap = "skills_lab",
        max_output_bytes = 262144,
    })
    if not ok then
        error(tostring(err or out or "unregister_skill failed"))
    end

    return {
        ok = true,
        skill_id = skill_id,
        unregister_result = decode_json(out or "{}", "unregister result"),
    }
end

return M
