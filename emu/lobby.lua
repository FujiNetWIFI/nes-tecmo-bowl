-- lobby.lua -- look at the session screens: snapshot + text dump at a few
-- moments, optionally press buttons on controller 1.
--   LOBBY_SHOTS  comma list of seconds to snapshot at (default 6,10)
--   LOBBY_KEYS   "sec:mask,sec:mask" presses (held 6 frames), game bit order
local P = dofile(os.getenv("TB_EMU") .. "/pads.lua")
local ppu = manager.machine.devices[":ppu"].spaces["videoram"]
local prog = manager.machine.devices[":maincpu"].spaces["program"]
local FONT = dofile(os.getenv("TB_EMU") .. "/fontmap.lua")
local shots, keys = {}, {}
for s in (os.getenv("LOBBY_SHOTS") or "6,10"):gmatch("[^,]+") do shots[#shots + 1] = tonumber(s) end
for s, m in (os.getenv("LOBBY_KEYS") or ""):gmatch("([%d.]+):(%w+)") do keys[#keys + 1] = { tonumber(s), tonumber(m) } end
local frame, last = 0, shots[#shots]
local function screen(tag)
  print("---- " .. tag .. string.format(" (session state %d, mode %d)", prog:readv_u8(0x631A), prog:readv_u8(0x6319)))
  for r = 0, 29 do
    local row = {}
    for c = 0, 31 do
      local v = ppu:readv_u8(0x2000 + r * 32 + c)
      row[#row + 1] = FONT[v] or " "
    end
    local s = table.concat(row):gsub("%s+$", "")
    if #s > 0 then print(string.format("%2d %s", r, s)) end
  end
end
_G.__l = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  local t = frame / 60
  local held = 0
  for _, k in ipairs(keys) do
    if t >= k[1] and t < k[1] + 0.1 then held = held | k[2] end
  end
  P.set(1, held)
  for _, s in ipairs(shots) do
    if frame == math.floor(s * 60) then
      manager.machine.screens[":screen"]:snapshot(string.format("lobby%04.1f.png", s))
      screen(string.format("t=%.1f", s))
    end
  end
  if t > last + 0.1 then manager.machine:exit() end
end)
