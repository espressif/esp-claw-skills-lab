local M = {}

local PNG_SIG = "\137PNG\r\n\026\n"

local LENGTH_BASE = {
  3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
  35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
}

local LENGTH_EXTRA = {
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
  3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
}

local DIST_BASE = {
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129,
  193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
  8193, 12289, 16385, 24577,
}

local DIST_EXTRA = {
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6,
  6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
}

local CL_ORDER = {
  16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
}

local function u32be(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  return ((a * 256 + b) * 256 + c) * 256 + d
end

local function u16le(s, i)
  local a, b = s:byte(i, i + 1)
  return a + b * 256
end

local function reverse_bits(code, len)
  local out = 0
  for _ = 1, len do
    out = (out << 1) | (code & 1)
    code = code >> 1
  end
  return out
end

local function build_huffman(lengths)
  local max_len = 0
  local counts = {}
  for _, len in ipairs(lengths) do
    if len > 0 then
      counts[len] = (counts[len] or 0) + 1
      if len > max_len then
        max_len = len
      end
    end
  end

  local next_code = {}
  local code = 0
  for bits = 1, max_len do
    code = (code + (counts[bits - 1] or 0)) << 1
    next_code[bits] = code
  end

  local tree = { max_len = max_len, by_len = {} }
  for symbol = 0, #lengths - 1 do
    local len = lengths[symbol + 1]
    if len and len > 0 then
      local rev = reverse_bits(next_code[len], len)
      next_code[len] = next_code[len] + 1
      tree.by_len[len] = tree.by_len[len] or {}
      tree.by_len[len][rev] = symbol
    end
  end
  return tree
end

local function bit_reader(data, start_i, end_i)
  return {
    data = data,
    i = start_i,
    end_i = end_i,
    bitbuf = 0,
    bitcount = 0,
  }
end

local function read_bits(br, n)
  while br.bitcount < n do
    if br.i > br.end_i then
      error("truncated deflate stream")
    end
    br.bitbuf = br.bitbuf | ((br.data:byte(br.i) or 0) << br.bitcount)
    br.bitcount = br.bitcount + 8
    br.i = br.i + 1
  end
  local value = br.bitbuf & ((1 << n) - 1)
  br.bitbuf = br.bitbuf >> n
  br.bitcount = br.bitcount - n
  return value
end

local function align_byte(br)
  br.bitbuf = 0
  br.bitcount = 0
end

local function decode_symbol(br, tree)
  local code = 0
  for len = 1, tree.max_len do
    code = code | (read_bits(br, 1) << (len - 1))
    local row = tree.by_len[len]
    local symbol = row and row[code]
    if symbol then
      return symbol
    end
  end
  error("invalid deflate huffman code")
end

local fixed_lit_tree
local fixed_dist_tree

local function fixed_trees()
  if fixed_lit_tree then
    return fixed_lit_tree, fixed_dist_tree
  end

  local lit_lengths = {}
  for i = 0, 287 do
    if i <= 143 then
      lit_lengths[i + 1] = 8
    elseif i <= 255 then
      lit_lengths[i + 1] = 9
    elseif i <= 279 then
      lit_lengths[i + 1] = 7
    else
      lit_lengths[i + 1] = 8
    end
  end

  local dist_lengths = {}
  for i = 1, 32 do
    dist_lengths[i] = 5
  end

  fixed_lit_tree = build_huffman(lit_lengths)
  fixed_dist_tree = build_huffman(dist_lengths)
  return fixed_lit_tree, fixed_dist_tree
end

local function dynamic_trees(br)
  local hlit = read_bits(br, 5) + 257
  local hdist = read_bits(br, 5) + 1
  local hclen = read_bits(br, 4) + 4
  local cl_lengths = {}
  for i = 1, 19 do
    cl_lengths[i] = 0
  end
  for i = 1, hclen do
    cl_lengths[CL_ORDER[i] + 1] = read_bits(br, 3)
  end

  local cl_tree = build_huffman(cl_lengths)
  local lengths = {}
  while #lengths < hlit + hdist do
    local symbol = decode_symbol(br, cl_tree)
    if symbol <= 15 then
      lengths[#lengths + 1] = symbol
    elseif symbol == 16 then
      local repeat_count = read_bits(br, 2) + 3
      local previous = lengths[#lengths] or 0
      for _ = 1, repeat_count do
        lengths[#lengths + 1] = previous
      end
    elseif symbol == 17 then
      for _ = 1, read_bits(br, 3) + 3 do
        lengths[#lengths + 1] = 0
      end
    elseif symbol == 18 then
      for _ = 1, read_bits(br, 7) + 11 do
        lengths[#lengths + 1] = 0
      end
    else
      error("invalid deflate code-length symbol")
    end
  end

  local lit_lengths = {}
  local dist_lengths = {}
  for i = 1, hlit do
    lit_lengths[i] = lengths[i] or 0
  end
  for i = 1, hdist do
    dist_lengths[i] = lengths[hlit + i] or 0
  end
  return build_huffman(lit_lengths), build_huffman(dist_lengths)
end

local function decode_compressed(br, lit_tree, dist_tree, out)
  while true do
    local symbol = decode_symbol(br, lit_tree)
    if symbol < 256 then
      out[#out + 1] = symbol
    elseif symbol == 256 then
      return
    else
      local li = symbol - 257 + 1
      local length = LENGTH_BASE[li]
      if not length then
        error("invalid deflate length symbol")
      end
      local extra = LENGTH_EXTRA[li]
      if extra > 0 then
        length = length + read_bits(br, extra)
      end

      local dist_symbol = decode_symbol(br, dist_tree)
      local distance = DIST_BASE[dist_symbol + 1]
      if not distance then
        error("invalid deflate distance symbol")
      end
      extra = DIST_EXTRA[dist_symbol + 1]
      if extra > 0 then
        distance = distance + read_bits(br, extra)
      end

      local start = #out - distance + 1
      if start < 1 then
        error("invalid deflate back-reference")
      end
      for i = 0, length - 1 do
        out[#out + 1] = out[start + i]
      end
    end
  end
end

local function inflate_zlib(data)
  if #data < 6 then
    error("invalid zlib stream")
  end

  local cmf, flg = data:byte(1, 2)
  if (cmf & 0x0f) ~= 8 or (((cmf * 256) + flg) % 31) ~= 0 or (flg & 0x20) ~= 0 then
    error("unsupported zlib stream")
  end

  local br = bit_reader(data, 3, #data - 4)
  local out = {}
  local final = 0
  while final == 0 do
    final = read_bits(br, 1)
    local block_type = read_bits(br, 2)
    if block_type == 0 then
      align_byte(br)
      local len = u16le(data, br.i)
      br.i = br.i + 4
      for i = br.i, br.i + len - 1 do
        out[#out + 1] = data:byte(i)
      end
      br.i = br.i + len
    elseif block_type == 1 then
      local lit_tree, dist_tree = fixed_trees()
      decode_compressed(br, lit_tree, dist_tree, out)
    elseif block_type == 2 then
      local lit_tree, dist_tree = dynamic_trees(br)
      decode_compressed(br, lit_tree, dist_tree, out)
    else
      error("reserved deflate block type")
    end
  end
  return out
end

local function paeth(a, b, c)
  local p = a + b - c
  local pa = math.abs(p - a)
  local pb = math.abs(p - b)
  local pc = math.abs(p - c)
  if pa <= pb and pa <= pc then
    return a
  elseif pb <= pc then
    return b
  end
  return c
end

local function unfilter(raw, width, height, channels)
  local stride = width * channels
  local out = {}
  local in_i = 1
  local out_i = 1
  for _ = 1, height do
    local filter = raw[in_i]
    in_i = in_i + 1
    local row_start = out_i
    for x = 0, stride - 1 do
      local value = raw[in_i]
      in_i = in_i + 1
      local left = x >= channels and out[out_i - channels] or 0
      local up = row_start > 1 and out[out_i - stride] or 0
      local up_left = (row_start > 1 and x >= channels) and out[out_i - stride - channels] or 0
      if filter == 1 then
        value = (value + left) & 0xff
      elseif filter == 2 then
        value = (value + up) & 0xff
      elseif filter == 3 then
        value = (value + ((left + up) >> 1)) & 0xff
      elseif filter == 4 then
        value = (value + paeth(left, up, up_left)) & 0xff
      elseif filter ~= 0 then
        error("unsupported PNG filter type")
      end
      out[out_i] = value
      out_i = out_i + 1
    end
  end
  return out
end

function M.load(path)
  local f = assert(io.open(path, "rb"))
  local data = f:read("*a")
  f:close()
  if data:sub(1, 8) ~= PNG_SIG then
    error("not a PNG file: " .. tostring(path))
  end

  local width, height, bit_depth, color_type, interlace
  local idat = {}
  local pos = 9
  while pos <= #data do
    local len = u32be(data, pos)
    local chunk_type = data:sub(pos + 4, pos + 7)
    local chunk_data = data:sub(pos + 8, pos + 7 + len)
    pos = pos + len + 12
    if chunk_type == "IHDR" then
      width = u32be(chunk_data, 1)
      height = u32be(chunk_data, 5)
      bit_depth = chunk_data:byte(9)
      color_type = chunk_data:byte(10)
      interlace = chunk_data:byte(13)
    elseif chunk_type == "IDAT" then
      idat[#idat + 1] = chunk_data
    elseif chunk_type == "IEND" then
      break
    end
  end

  if bit_depth ~= 8 or interlace ~= 0 or (color_type ~= 6 and color_type ~= 2) then
    error("unsupported PNG format: " .. tostring(path))
  end

  local channels = color_type == 6 and 4 or 3
  local pixels = unfilter(inflate_zlib(table.concat(idat)), width, height, channels)
  return {
    width = width,
    height = height,
    channels = channels,
    pixels = pixels,
  }
end

return M
