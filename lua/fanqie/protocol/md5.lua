-- RFC 1321 MD5, used by the request signature. No OpenSSL dependency.
local bit = require("bit")
local M = {}
local shifts = {
  7,12,17,22, 7,12,17,22, 7,12,17,22, 7,12,17,22,
  5,9,14,20, 5,9,14,20, 5,9,14,20, 5,9,14,20,
  4,11,16,23, 4,11,16,23, 4,11,16,23, 4,11,16,23,
  6,10,15,21, 6,10,15,21, 6,10,15,21, 6,10,15,21,
}
local constants = {}
for i = 1, 64 do constants[i] = math.floor(math.abs(math.sin(i)) * 4294967296) end
local function le(n)
  return string.char(bit.band(n,255), bit.band(bit.rshift(n,8),255),
    bit.band(bit.rshift(n,16),255), bit.band(bit.rshift(n,24),255))
end
function M.sum(input)
  local bytes = #input
  local s = input .. "\128" .. string.rep("\0", (55 - bytes) % 64)
    .. le(bytes * 8) .. le(math.floor(bytes / 536870912))
  local a0, b0, c0, d0 = 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476
  for start = 1, #s, 64 do
    local words = {}
    for j = 0, 15 do
      local a,b,c,d = s:byte(start+j*4, start+j*4+3)
      words[j] = a+b*256+c*65536+d*16777216
    end
    local a,b,c,d = a0,b0,c0,d0
    for i = 0, 63 do
      local f,g
      if i < 16 then f,g = bit.bor(bit.band(b,c),bit.band(bit.bnot(b),d)), i
      elseif i < 32 then f,g = bit.bor(bit.band(d,b),bit.band(bit.bnot(d),c)), (5*i+1)%16
      elseif i < 48 then f,g = bit.bxor(b,c,d), (3*i+5)%16
      else f,g = bit.bxor(c,bit.bor(b,bit.bnot(d))), (7*i)%16 end
      local next_b = bit.tobit(b + bit.rol(bit.tobit(a+f+constants[i+1]+words[g]),shifts[i+1]))
      a,b,c,d = d,next_b,b,c
    end
    a0,b0,c0,d0 = bit.tobit(a0+a),bit.tobit(b0+b),bit.tobit(c0+c),bit.tobit(d0+d)
  end
  return ((le(a0)..le(b0)..le(c0)..le(d0)):gsub(".",function(c) return ("%02x"):format(c:byte()) end))
end
return M
