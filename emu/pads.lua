-- pads.lua -- drive the two NES pads from Lua.
-- Bits are in the game's own order (what $C314 shifts in):
--   A=$80 B=$40 Select=$20 Start=$10 Up=$08 Down=$04 Left=$02 Right=$01
local M = {}
local NAMES = { [0x80]="A", [0x40]="B", [0x20]="Select", [0x10]="Start",
                [0x08]="Up", [0x04]="Down", [0x02]="Left", [0x01]="Right" }
local fields = { {}, {} }

local function bind()
  for p = 1, 2 do
    local port = manager.machine.ioport.ports[":ctrl" .. p .. ":joypad:JOYPAD"]
    for bit, n in pairs(NAMES) do
      fields[p][bit] = port.fields["P" .. p .. " " .. n]
    end
  end
end

-- set pad p (1|2) to the byte v
function M.set(p, v)
  if not fields[1][0x80] then bind() end
  for bit, f in pairs(fields[p]) do
    f:set_value((v & bit) ~= 0 and 1 or 0)
  end
end

-- a deterministic xorshift for fuzz, seeded per run
function M.rng(seed)
  local s = seed & 0xFFFF
  if s == 0 then s = 0xACE1 end
  return function()
    s = s ~ ((s << 7) & 0xFFFF)
    s = s ~ (s >> 9)
    s = s ~ ((s << 8) & 0xFFFF)
    return s & 0xFF
  end
end

return M
