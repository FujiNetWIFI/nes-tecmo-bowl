# Tecmo Bowl (NES) — FujiNet Netplay

Two-player Tecmo Bowl (1989) head to head over the network. Each player sits at their own NES with the FujiNet cartridge, and a small relay server matches them by username. Behaviour follows `~/Workspace/nes-double-dribble` and the FujiNet netplay ports before it:

- your name comes from the Lobby username appkey;
- you pick an opponent from a lobby list, and the waiting player becomes host;
- input is exchanged in delay-based lockstep;
- a CRC check every 64 ticks detects desyncs, and the host repairs one by pushing its state;
- when the opponent goes, an "OPPONENT LEFT" or "CONNECTION LOST" screen shows the field-diagnostic counters.

**Architecture.** Both consoles run the full, lightly patched original game. Tecmo Bowl runs its logic in eight cooperative tasks on the main thread, so a sim tick is everything between two points where the scheduler has nothing to run. At that point a hook hands the main thread to the netcode. The first NMI after that does the game's display pass, then the netcode does what the stock NMI would have done next:
- exchange and feed the pads;
- step the RNG;
- count the frame;
- wake the waiting tasks.

Every other NMI only re-asserts the PPU registers (including the status-bar split) and writes no RAM. A tick that overruns a frame therefore becomes slowdown, never a timing-dependent wakeup.

Tick-stamped pad bytes travel over a persistent `N:TCP://` connection through the relay. Both sims apply both players' inputs at the same tick, with local input delayed by `d` ticks (3 by default, set by the server).

When the network is late, the stall spins on the main thread with the scheduler idle, and the display stays alive.

The netcode lives in a new PRG bank: the ROM grows to 256K PRG, which MMC1 maps directly. Its state lives in the cart's 8K WRAM. The NMI's crash guard forbids running code from WRAM, so the hooks sit in the fixed bank's free space. Ten declared patch sites in the fixed bank hook them in: eight redirect code there, one points the reset vector at the moved reset stub, and one writes the "FUJI" claim. Details and the measurements behind each decision are in `spikes/NOTES.md`.

## Layout

| Path | Contents |
|---|---|
| `rom/` | The original `tecmo_bowl.nes` (MMC1, 128K PRG, 128K CHR-ROM); see `rom/README.md` |
| `src/bank8.s` | The netcode bank: boot, module includes |
| `src/fix.s` | The fixed-bank hooks: reset, NMI tick/lag split, idle hook, MMC1 shadows |
| `src/netcode/mailbox.s` | FujiNet cart mailbox, N: device and appkey calls |
| `src/netcode/session.s` | Name, server, lobby, START, stream pump and frame parser |
| `src/netcode/lockstep.s` | `NET_IDLE`, the tick, gate and stall, feed, CRC, peer-left screen |
| `src/netcode/resync.s` | CRC records, desync detection, state push and apply |
| `src/ui/text.s` | Text screens in the game's own font (CHR bank 11) |
| `tools/mkfontmap.py` | Checks the font glyphs in the ROM; writes `src/ui/fontmap.inc` and `emu/fontmap.lua` |
| `tools/patches.py` | Every changed fixed-bank byte, with its original bytes |
| `tools/build_rom.py` | Splices bank 8 and the hooks in, applies the patches, writes the NES 2.0 header |
| `tools/check_patch.py` | Fails on any undeclared change |
| `tools/checkrom.py` | Bans RMW instructions aimed at the mailbox |
| `tools/dis6502.py` | Small disassembler and xref tool for the ROM |
| `server/tb_relay_server.py` | Matchmaking and relay, the Baseball protocol unchanged |
| `emu/` | MAME Lua: `profile` (RAM access map, NMI classes), `modes`, `look`, `ticks`, `play`, `det`, `rig`, `lobby`; `run.sh` launches MAME |
| `test/` | `run_det.sh`, `run_rig.sh`, `rig_verdict.py`, `run_lobby.sh`, `lobby_idlers.py` |

## Build and verify (headless)

Requirements: cc65 (`ca65`, `ld65`), Python 3 with Pillow (for looking at snapshots), the patched MAME in `~/Workspace/mame` (fn-nes `pico/nes/emu/apply.sh`), and `~/Workspace/fujinet-pc-rs232/build/dist` for the rigs.

```sh
make verify-org   # split + rejoin of the original ROM is byte-identical
make hook         # HOOK build (all hooks in, nothing armed) + patch audit
make det          # determinism A/B: in-console fuzz into a 2P game; B adds a
                  # 9-frame stall every 64 ticks and a per-tick jitter that
                  # forces lag NMIs; per-tick sim checksums must match (PASS)
make rig          # 2x fujinet-pc + relay + 2x MAME, auto-matched, fuzz,
                  # CRC cross-check, zero diag counters, stack guard (RIG PASS)
make m4           # desync injection -> detect -> push -> recover (M4 PASS)
make peerleft     # opponent leaves: clean (OPPONENT LEFT) and timeout
                  # (CONNECTION LOST); both must PASS
make lobby        # the session screens as text + snapshots, against idle
                  # players parked in the relay (after one `make rig`)
python3 tools/test_lobby_pub.py   # Lobby registration contract
make profile      # M0: the stock game's RAM map into build/profile.txt
```

## Play

Two consoles side by side on one machine, everything set up for you:

```sh
make play          # or tools/play_local.sh; P1_NAME=.. P2_NAME=.. DELAY=..
```

This starts:
- two isolated fujinet-pc copies (`build/play/`), each with its own username appkey and the Lobby server-URL appkey;
- the relay on :9701;
- two MAME windows.

Challenge one player from the other's lobby. Each console uses its own controller 1, and keys go to the focused window. Closing either window or pressing Ctrl-C stops everything.

Against a real server:

```sh
make SRV_HOST=<server> SRV_PORT=9701   # build/tb_net.nes
python3 server/tb_relay_server.py --port 9701
emu/run.sh build/tb_net.nes            # MAME window, FujiNet cart slot
```

The netplay screens work like this:

- **Name:** taken from the FujiNet Lobby username appkey (creator 1 / app 1 / key 0), upper-cased, falling back to `GUESTnn`.
- **Server:** taken from the Lobby's handoff appkey (key `GAME_APPKEY`, 41) when the game was booted from the NES Lobby, otherwise the endpoint baked in at build time.
- **Lobby:** Up and Down move the cursor, A or Start challenges, and Select plays locally instead.
- **Roles:** the waiting player becomes host, which makes them 1UP. Both players use controller 1 on their own console.
- **Menus:** the title runs in lockstep exactly as on a couch, so 1UP picks 2PLAYERS. On the team-select screen each player picks their own team, and on the play-select screen each picks their own plays.

With no FujiNet or no server, the stock game runs locally.

## Status

Verified in emulation (MAME with the FujiNet cart device, two fujinet-pc instances). The cartridge hardware does not exist yet.

- `det` PASS at 4,000, 7,000 and 12,000 ticks through the title, the menus, kickoffs and fuzzed play. B saw about 30,000 lag NMIs by tick 12,000, and every tick's checksum still matched A's.
- A SOLO fuzz build without TRACE runs 4,000 ticks in 4,183 frames, close to stock speed.
- `rig` PASS:
  - 96 CRC pairs with no mismatches, and every diagnostic counter at zero;
  - the two consoles render pixel-identical frames at the same ticks;
  - console 1 connects only through the Lobby's server-URL appkey (its baked-in endpoint is a dead port), and its name comes from the username appkey;
  - the netcode's deepest stack push, plus an NMI's on top, stays above task `$80`'s stack.
- `m4` PASS: a poked byte is detected at the next CRC. The host pushes the 4,130-byte image at a dead-ball moment (task slot `$E0` free), and both sims rebase and agree from then on, with pixel-identical frames.
- `peerleft` PASS for both a clean leave and a timeout.
- `lobby`: the name, list, IN GAME rows, cursor, challenge, matched screen and handover into the game all checked on screen.

Open items:

- `d` needs tuning on real hardware (the default is 3, i.e. 50 ms), as does the mailbox's real latency.
- There is no PAL guard yet.
- Port 9701 and appkey 41 are proposals, next to Double Dribble's 9700 and 40, and must be confirmed before a production `server/run_production.sh`.
- A tick that overruns a frame slows the game rather than catching up mid-task. Stock lags on about 1% of frames, so this rarely shows.
