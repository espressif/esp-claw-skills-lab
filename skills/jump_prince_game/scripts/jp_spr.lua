-- spr.lua: decoder for ".spr" RLE palette sprite files produced by
-- tools/extract_sprites.py (jump_prince_game/assets/*.spr).
--
-- .spr v1 layout (little-endian):
--   "SPR" | ver u8 = 1 | w u8 | h u8 | pal_count u8 (<=15)
--   pal: pal_count x u16 RGB565
--   runs to end: [run_len u8 1..255][pal_idx u8]
--   pal_idx == 0x0F -> fully transparent pixel
--
-- decode() returns a sprite table:
--   sp.w, sp.h           dimensions
--   sp.pix               string, one byte per pixel (row-major), value =
--                        palette index or 0x0F for transparent
--   sp.colors[i]         pre-formatted "#rrggbb" string for palette index i

local M = {}

local TRANSPARENT_IDX = 0x0F


local function color_string(rgb565)
    local r = ((rgb565 >> 11) & 0x1F) << 3
    local g = ((rgb565 >> 5) & 0x3F) << 2
    local b = (rgb565 & 0x1F) << 3
    return string.format("#%02x%02x%02x", r, g, b)
end


function M.decode(data)
    if #data < 7 then
        error("sprite data too short")
    end
    if data:byte(1, 3) ~= nil and data:sub(1, 3) ~= "SPR" then
        error("bad sprite magic")
    end
    local version = data:byte(4)
    if version ~= 1 then
        error("unsupported sprite version " .. tostring(version))
    end
    local w = data:byte(5)
    local h = data:byte(6)
    local pal_count = data:byte(7)

    local colors = {}
    local offset = 8
    -- Sprite pixels store 0-based palette indices (plus 0x0F = transparent).
    -- Index the Lua colors table the same way so blit colors[idx] is never nil.
    for i = 0, pal_count - 1 do
        local lo = data:byte(offset)
        local hi = data:byte(offset + 1)
        colors[i] = color_string(lo | (hi << 8))
        offset = offset + 2
    end

    -- Expand runs into a per-pixel index string.
    local npx = w * h
    local parts = {}
    local total = 0
    while offset < #data and total < npx do
        local run_len = data:byte(offset)
        local idx = data:byte(offset + 1)
        offset = offset + 2
        if total + run_len > npx then
            run_len = npx - total
        end
        parts[#parts + 1] = string.rep(string.char(idx), run_len)
        total = total + run_len
    end
    if total < npx then
        error("sprite runs truncated (" .. tostring(total) .. "/" .. tostring(npx) .. ")")
    end

    return {
        w = w,
        h = h,
        pix = table.concat(parts),
        colors = colors,
        transparent = TRANSPARENT_IDX,
    }
end


--- Load a packed sprite atlas ("sprites.bin") produced by extract_sprites.py.
--- Returns a bank table; decode individual sprites lazily with decode_named().
--- Layout: "SPB1" | count u16 | records of
---   [name_len u8][name][spr_len u32][raw .spr bytes]
function M.load_bank(data)
    if data:sub(1, 4) ~= "SPB1" then
        error("bad sprite bank magic")
    end
    local count = data:byte(5) | (data:byte(6) << 8)
    local bank = { raw = {}, decoded = {} }
    local offset = 7
    for _ = 1, count do
        local nl = data:byte(offset)
        offset = offset + 1
        local name = data:sub(offset, offset + nl - 1)
        offset = offset + nl
        local ml = data:byte(offset) | (data:byte(offset + 1) << 8)
                  | (data:byte(offset + 2) << 16) | (data:byte(offset + 3) << 24)
        offset = offset + 4
        bank.raw[name] = data:sub(offset, offset + ml - 1)
        offset = offset + ml
    end
    return bank
end


--- Return (and cache) the decoded sprite for `name` from a loaded bank.
function M.decode_named(bank, name)
    if bank.decoded[name] then
        return bank.decoded[name]
    end
    local raw = bank.raw[name]
    if not raw then
        error("sprite not in bank: " .. tostring(name))
    end
    local sp = M.decode(raw)
    bank.decoded[name] = sp
    return sp
end


--- Blit `sp` onto canvas `cv` with its top-left at (dx, dy).
--- Transparent pixels are skipped. Also returns the number of pixels drawn.
function M.blit(cv, sp, dx, dy)
    local pix = sp.pix
    local colors = sp.colors
    local trans = TRANSPARENT_IDX
    local count = 0
    for y = 0, sp.h - 1 do
        local row_base = y * sp.w
        local py = dy + y
        for x = 0, sp.w - 1 do
            local idx = pix:byte(row_base + x + 1)
            if idx ~= trans then
                cv:set_px(dx + x, py, colors[idx])
                count = count + 1
            end
        end
    end
    return count
end


return M
