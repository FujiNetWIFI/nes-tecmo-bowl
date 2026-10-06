-- profile.lua -- M0: what the stock game touches, and from where. Drives the
-- title into a 2P game (both teams picked), then fuzzes both pads.
-- Output (stdout):
--   NMI ...            every NMI classified: stub ($0A bit 7 clear), full
--                      from the scheduler's idle scan, full mid-task (lag);
--                      preemptions and NMI scheduler restarts
--   LAGPC b:pc n       where the lag NMIs landed (top 40)
--   W/R addr who...    RAM writers/readers, who = [N]bank:pc*count, N = in
--                      the NMI; bank F is the fixed bank
--   MAP reg b:pc n     MMC1 serial writes by register ($8000/A000/C000/E000)
--   IO addr b:pc n     $4015-$4017 reads
--   FREE addr b:pc n   reads of the fixed-bank space the build wants
--   SP ...             lowest stack byte written by an NMI from idle, by
--                      anything at all, and where
local P = dofile(os.getenv("TB_EMU") .. "/pads.lua")
local secs = tonumber(os.getenv("PROF_SECS") or "150")
local cpu = manager.machine.devices[":maincpu"]
local prog = cpu.spaces["program"]
local W, R, MAP, IO, FREE, LAGPC = {}, {}, {}, {}, {}, {}
local n_stub, n_idle, n_lag, n_pre, n_restart = 0, 0, 0, 0, 0
local in_nmi, nmi_idle = false, false
local sp_idle, sp_idle_who, sp_any, sp_any_who = 0x1FF, 0, 0x1FF, 0
local frame = 0
local r1, r2 = P.rng(0x1234), P.rng(0x5678)

local function pc() return cpu.state["PC"].value end
local function bankof(p)
  if p >= 0xC000 then return 0xF end
  if p >= 0x8000 then return prog:readv_u8(0xBFF8) & 0xF end
  return 0xE                       -- below $8000: should never happen
end
local function who()
  local p = pc()
  local k = bankof(p) * 0x10000 + p
  if in_nmi then k = k | 0x100000 end
  return k
end
local function bump(t, a, k)
  local e = t[a]
  if not e then e = {}; t[a] = e end
  e[k] = (e[k] or 0) + 1
end
local function fmt(k)
  return string.format("%s%X:%04X", (k & 0x100000) ~= 0 and "N" or "", (k >> 16) & 0xF, k & 0xFFFF)
end

-- NMI entry: classify by $0A bit 7 and the interrupted PC on the stack
_G.__n0 = prog:install_read_tap(0xC060, 0xC060, "nmi", function(off)
  if pc() ~= 0xC060 then return end
  if (prog:readv_u8(0x0A) & 0x80) == 0 then n_stub = n_stub + 1; return end
  local sp = cpu.state["SP"].value & 0xFF
  local ipc = prog:readv_u8(0x100 + ((sp + 2) & 0xFF)) | (prog:readv_u8(0x100 + ((sp + 3) & 0xFF)) << 8)
  if ipc >= 0xC559 and ipc <= 0xC56E then
    n_idle = n_idle + 1; nmi_idle = true
  else
    n_lag = n_lag + 1; nmi_idle = false
    bump(LAGPC, 0, bankof(ipc) * 0x10000 + ipc)
  end
end)
_G.__n1 = prog:install_read_tap(0xC06A, 0xC06A, "nmi1", function(off)
  if pc() == 0xC06A then in_nmi = true end
end)
local function leave(addr, f)
  return prog:install_read_tap(addr, addr, "lv" .. addr, function(off)
    if pc() == addr then
      if f and in_nmi then f() end
      in_nmi = false
    end
  end)
end
_G.__l1 = leave(0xC555)
_G.__l2 = leave(0xC556, function() n_restart = n_restart + 1 end)
_G.__l3 = leave(0xC5DE, function() n_pre = n_pre + 1 end)

_G.__wt = prog:install_write_tap(0x0000, 0x07FF, "pw", function(off)
  local k = who()
  bump(W, off, k)
  if off >= 0x100 and off <= 0x1FF then
    if in_nmi and nmi_idle and off < sp_idle then sp_idle, sp_idle_who = off, k end
    if off < sp_any then sp_any, sp_any_who = off, k end
  end
end)
_G.__rt = prog:install_read_tap(0x0000, 0x07FF, "pr", function(off) bump(R, off, who()) end)
_G.__mt = prog:install_write_tap(0x8000, 0xFFFF, "pm", function(off) bump(MAP, (off >> 13) & 3, who()) end)
_G.__io = prog:install_read_tap(0x4015, 0x4017, "pio", function(off) bump(IO, off, who()) end)
local free = { { 0xC290, 0xC39F }, { 0xCBF5, 0xCCFD }, { 0xCD96, 0xCEFF }, { 0xD800, 0xDFFF }, { 0xFE00, 0xFFDF } }
_G.__fr = {}
for i, r in ipairs(free) do
  _G.__fr[i] = prog:install_read_tap(r[1], r[2], "pf" .. i, function(off)
    if prog:readv_u8(0xBFF8) >= 0 then bump(FREE, off, who()) end
  end)
end

local function dump(tag, t, lo, hi, top)
  for a = lo, hi do
    local e = t[a]
    if e then
      local ks = {}
      for k, c in pairs(e) do ks[#ks + 1] = { k, c } end
      table.sort(ks, function(x, y) return x[2] > y[2] end)
      local s = {}
      for i, kc in ipairs(ks) do
        if top and i > top then break end
        s[#s + 1] = fmt(kc[1]) .. "*" .. kc[2]
      end
      print(string.format("%s %04X %s", tag, a, table.concat(s, " ")))
    end
  end
end

-- title: Start, Select (2PLAYERS), Start; team select: A on both pads
local script = { { 3, 0x10, 1 }, { 6, 0x20, 1 }, { 7, 0x10, 1 }, { 9, 0x80, 1 }, { 10, 0x80, 2 } }
_G.__f = emu.add_machine_frame_notifier(function()
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
  if frame >= secs * 60 then
    print(string.format("NMI stub %d idle %d lag %d preempt %d restart %d frames %d",
      n_stub, n_idle, n_lag, n_pre, n_restart, frame))
    dump("LAGPC", LAGPC, 0, 0, 40)
    print(string.format("SP idle-NMI lowest $%03X by %s; anything lowest $%03X by %s",
      sp_idle, fmt(sp_idle_who), sp_any, fmt(sp_any_who)))
    dump("MAP", MAP, 0, 3)
    dump("IO", IO, 0x4015, 0x4017)
    dump("FREE", FREE, 0xC000, 0xFFFF, 4)
    dump("W", W, 0, 0x7FF, 12)
    dump("R", R, 0, 0x7FF, 12)
    manager.machine:exit()
  end
end)
