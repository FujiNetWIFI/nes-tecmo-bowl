-- look.lua -- M0 helper: snapshots at LOOK_SHOTS seconds, LOOK_KEYS presses
-- ("sec:mask:pad,..."; pad defaults to 1, held 6 frames), and at each shot
-- a hex dump of nametable 0 plus the PPU's current pattern memory to
-- build/look/<t>.ppu (8K CHR window + 4K nametables) for tools/mkfontmap.py.
local P = dofile(os.getenv("TB_EMU") .. "/pads.lua")
local ppu = manager.machine.devices[":ppu"].spaces["videoram"]
local shots, keys = {}, {}
for s in (os.getenv("LOOK_SHOTS") or "5,10"):gmatch("[^,]+") do shots[#shots + 1] = tonumber(s) end
for s, m, p in (os.getenv("LOOK_KEYS") or ""):gmatch("([%d.]+):(%w+):?(%d?)") do
  keys[#keys + 1] = { tonumber(s), tonumber(m), tonumber(p) or 1 }
end
local dir = os.getenv("LOOK_DIR") or "/tmp"
local frame, last = 0, shots[#shots]
local function dump(t)
  local f = io.open(string.format("%s/%05.1f.ppu", dir, t), "wb")
  for a = 0, 0x2FFF do f:write(string.char(ppu:readv_u8(a))) end
  f:close()
end
_G.__l = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  local t = frame / 60
  local held = { 0, 0 }
  for _, k in ipairs(keys) do
    if t >= k[1] and t < k[1] + 0.1 then held[k[3]] = held[k[3]] | k[2] end
  end
  P.set(1, held[1]); P.set(2, held[2])
  for _, s in ipairs(shots) do
    if frame == math.floor(s * 60) then
      manager.machine.screens[":screen"]:snapshot(string.format("look%05.1f.png", s))
      dump(s)
    end
  end
  if t > last + 0.1 then manager.machine:exit() end
end)
