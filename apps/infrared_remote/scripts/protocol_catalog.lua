-- Protocol discovery: groups ir.protocol.list() by device kind, labels entries, builds ir_remote configs
-- and identifies learned frames with the decodable builtin protocols.
local ProtocolCatalog = {}
ProtocolCatalog.__index = ProtocolCatalog

-- App device kind per codeset category; key protocols (a command field, no category) serve TV and MEDIA.
local CATEGORY_KINDS = {air_conditioner = "ac", tv = "tv", audio = "media"}
local KEY_PROTOCOL_KINDS = {"tv", "media"}
local KEY_PROTOCOL_TITLES = {
    nec = "NEC", ["nec.extended"] = "NEC Extended", samsung32 = "Samsung", sony12 = "Sony 12-bit", sony15 = "Sony 15-bit",
    sony20 = "Sony 20-bit", rc5 = "Philips RC5", jvc = "JVC",
}
local LOG = "[infrared_remote] "

local function has(values, expected)
    for _, value in ipairs(values or {}) do if value == expected then return true end end
    return false
end

local function make_entry(info)
    local tags = {string.format("%d kHz", math.floor(info.carrier_hz / 1000 + 0.5))}
    if info.checked then tags[#tags + 1] = "checksum" end
    if info.maturity == "experimental" then tags[#tags + 1] = "experimental" end
    local subtitle = info.model or (info.brand and "Built-in protocol")
        or (has(info.fields, "address") and "Address + command" or "Command only")
    return {
        id = info.id, title = info.brand or KEY_PROTOCOL_TITLES[info.id] or string.upper(info.id), subtitle = subtitle,
        detail = table.concat(tags, " · "), experimental = info.maturity == "experimental", model = info.model, info = info,
    }
end

-- Codesets by brand, builtin tables (no model) before generated ones.
local function by_brand(a, b)
    if a.title ~= b.title then return a.title < b.title end
    if (a.model == nil) ~= (b.model == nil) then return a.model == nil end
    return (a.model or a.id) < (b.model or b.id)
end

function ProtocolCatalog.new(ir)
    local self = setmetatable({ir = ir, entries = {}, lists = {ac = {}, tv = {}, media = {}}, decodable = {}}, ProtocolCatalog)
    local ok, infos = pcall(ir.protocol.list)
    if not ok then
        print(LOG .. "Protocol list failed: " .. tostring(infos))
        infos = {}
    end
    for _, info in ipairs(infos) do
        local kind = CATEGORY_KINDS[info.category]
        local kinds = kind and {kind} or (not info.category and has(info.fields, "command") and KEY_PROTOCOL_KINDS) or {}
        if #kinds > 0 then
            local entry = make_entry(info)
            self.entries[info.id] = entry
            for _, k in ipairs(kinds) do self.lists[k][#self.lists[k] + 1] = entry end
        end
        if info.decode then self.decodable[#self.decodable + 1] = info end
    end
    table.sort(self.lists.ac, by_brand)
    return self
end

-- Decoders are only needed once a frame is learned, so protocol objects are fetched on first use.
function ProtocolCatalog:_decoders()
    if self.decoders then return self.decoders end
    self.decoders = {}
    for _, info in ipairs(self.decodable) do
        local ok, protocol = pcall(self.ir.protocol.get, info.id)
        if ok then
            local entry = self.entries[info.id]
            self.decoders[#self.decoders + 1] = {protocol = protocol, checked = info.checked, title = entry and entry.title or string.upper(info.id)}
        else
            print(LOG .. "Decoder unavailable: " .. info.id)
        end
    end
    -- Checked protocols first: an unchecked decode is only weak evidence.
    table.sort(self.decoders, function(a, b) return a.checked and not b.checked end)
    return self.decoders
end

function ProtocolCatalog:list(kind) return self.lists[kind] or {} end

function ProtocolCatalog:entry(id) return id and self.entries[id] end

function ProtocolCatalog:select(kind, preferred)
    local first
    for _, entry in ipairs(self:list(kind)) do
        if entry.id == preferred then return preferred end
        first = first or entry.id
    end
    return first
end

-- One-line description for headers, e.g. "Gree · IRext 10727".
function ProtocolCatalog:describe(id)
    local entry = self:entry(id)
    if not entry then return id end
    return entry.model and (entry.title .. " · " .. entry.model) or entry.title
end

-- Builds an ir_remote config: a codeset id, or a key protocol with an address and {key = command} codes.
function ProtocolCatalog:config(id, address, codes)
    local entry = self:entry(id)
    if not entry then return {} end
    local fields = entry.info.fields
    if not has(fields, "command") then return {protocol = id} end
    local keys = {}
    for name, command in pairs(codes or {}) do keys[name] = {command = command} end
    return {protocol = id, fixed = has(fields, "address") and {address = address or 0} or nil, keys = keys}
end

local function values_text(values)
    if values.command then
        return values.address and string.format("%02X:%02X", values.address, values.command) or string.format("%02X", values.command)
    end
    local parts = {}
    if values.power == false then parts[1] = "off" end
    if values.mode then parts[#parts + 1] = values.mode end
    if values.temperature then parts[#parts + 1] = tostring(values.temperature) end
    return table.concat(parts, " ")
end

-- Short label such as "NEC 10:20" for a received frame, or nil when no builtin protocol matches.
function ProtocolCatalog:identify(frame)
    for _, decoder in ipairs(self:_decoders()) do
        local ok, values = pcall(decoder.protocol.decode, decoder.protocol, frame)
        if ok and values then
            local text = values_text(values)
            local label = text ~= "" and (decoder.title .. " " .. text) or decoder.title
            return decoder.checked and label or (label .. "?")
        end
    end
    return nil
end

return ProtocolCatalog
