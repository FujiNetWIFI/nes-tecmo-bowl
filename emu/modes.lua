-- modes.lua -- M0: what state bytes say about the game's phase. Drives the
-- title into a 2P game like profile.lua, then fuzzes both pads. Every
-- MODES_EVERY seconds: a snapshot and one line of candidate bytes -- the
-- mode byte $02, the eight task slots' status and current bank, and any
-- extra bytes named in MODES_ADDRS ("0x4B,0x13"). With MODES_TRACE=addr,
-- logs every change of that byte instead, with how long the value lasted.
local P = dofile(os.getenv("TB_EMU") .. "/pads.lua")
local prog = manager.machine.devices[":maincpu"].spaces["program"]
local secs = tonumber(os.getenv("PLAY_SECS") or "120")
local every = tonumber(os.getenv("MODES_EVERY") or "2")
local trace = tonumber(os.getenv("MODES_TRACE") or "-1")
local extra = {}
for s in (os.getenv("MODES_ADDRS") or ""):gmatch("[^,]+") do extra[#extra + 1] = tonumber(s) end
local frame, last, since = 0, nil, 0
local r1, r2 = P.rng(0x1234), P.rng(0x5678)
local script = { { 3, 0x10, 1 }, { 6, 0x20, 1 }, { 7, 0x10, 1 }, { 9, 0x80, 1 }, { 10, 0x80, 2 } }
_G.__m = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  local t = frame / 60
  if t < 20 then
    local held = { 0, 0 }
    for _, k in ipairs(script) do
      if t >= k[1] and t < k[1] + 0.1 then held[k[3]] = held[k[3]] | k[2] end
    end
    P.set(1, held[1]); P.set(2, held[2])
  elseif frame % 8 == 0 then
    P.set(1, r1() & 0xCF); P.set(2, r2() & 0xCF)
  end
  if trace >= 0 then
    local v = prog:readv_u8(trace)
    if v ~= last then
      if last then print(string.format("f=%6d $%02X=%02X lasted %d", frame, trace, last, frame - since)) end
      last, since = v, frame
    end
  elseif frame % (every * 60) == 0 then
    local s = { string.format("t=%5.1f m=%02X", t, prog:readv_u8(0x02)) }
    for slot = 0x80, 0xF0, 0x10 do
      s[#s + 1] = string.format("%02X:%02X/%X", slot, prog:readv_u8(slot), prog:readv_u8(slot + 3))
    end
    for _, a in ipairs(extra) do s[#s + 1] = string.format("$%02X=%02X", a, prog:readv_u8(a)) end
    print(table.concat(s, " "))
    manager.machine.screens[":screen"]:snapshot(string.format("m%05.1f.png", t))
  end
  if frame >= secs * 60 then manager.machine:exit() end
end)
