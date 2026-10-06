-- det.lua -- run a TRACE build until its sim tick reaches DET_TICKS, then
-- print the per-tick checksum ring (TRACE_BUF, 1024 x lo/hi) and exit.
-- Output lines: "TICK n" then "TR <tick> <crc>" for the last 1000 ticks.
local target = tonumber(os.getenv("DET_TICKS") or "3000")
local trace = tonumber(os.getenv("TRACE_BUF") or "0x7700")
local prog = manager.machine.devices[":maincpu"].spaces["program"]
local done = false
local frames = 0
_G.__det = emu.add_machine_frame_notifier(function()
  if done then return end
  frames = frames + 1
  local tick = prog:readv_u8(0x6305) + 256 * prog:readv_u8(0x6306)
  if tick >= target then
    done = true
    print(string.format("TICK %d FRAMES %d LAGNMI %d", tick, frames,
      prog:readv_u8(0x6322) + 256 * prog:readv_u8(0x6323)))
    for t = tick - 1000, tick - 1 do
      local i = (t % 1024) * 2
      print(string.format("TR %d %02X%02X", t, prog:readv_u8(trace + i + 1), prog:readv_u8(trace + i)))
    end
    manager.machine.screens[":screen"]:snapshot()
    manager.machine:exit()
  elseif frames > target * 12 then
    done = true
    print(string.format("STUCK tick %d after %d frames", tick, frames))
    manager.machine:exit()
  end
end)
