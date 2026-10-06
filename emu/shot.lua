-- shot.lua -- run SHOT_AT seconds, save a snapshot, exit.
local at = tonumber(os.getenv("SHOT_AT") or "5")
local done = false
_G.__sub = emu.add_machine_frame_notifier(function()
  if done then return end
  if manager.machine.time:as_double() >= at then
    done = true
    manager.machine.screens[":screen"]:snapshot()
    manager.machine:exit()
  end
end)
