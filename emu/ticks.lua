-- ticks.lua -- a SOLO/FUZZ build on its own: a snapshot every SNAP_TICKS
-- sim ticks (named by tick) up to DET_TICKS, then exit. For looking at
-- where a fuzzed run actually goes.
local every = tonumber(os.getenv("SNAP_TICKS") or "300")
local target = tonumber(os.getenv("DET_TICKS") or "3000")
local prog = manager.machine.devices[":maincpu"].spaces["program"]
local last, frames = -1, 0
_G.__t = emu.add_machine_frame_notifier(function()
  frames = frames + 1
  local tick = prog:readv_u8(0x6305) + 256 * prog:readv_u8(0x6306)
  local b = tick // every
  if b > last then
    last = b
    manager.machine.screens[":screen"]:snapshot(string.format("t%05d.png", b * every))
  end
  if tick >= target then
    print(string.format("TICK %d FRAMES %d LAGNMI %d", tick, frames,
      prog:readv_u8(0x6322) + 256 * prog:readv_u8(0x6323)))
    manager.machine:exit()
  end
end)
