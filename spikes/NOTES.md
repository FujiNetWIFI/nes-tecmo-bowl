# Notes: how Tecmo Bowl was made deterministic

Everything here was measured, not assumed. The tools:
- `emu/profile.lua`: a MAME Lua map of RAM access by bank:PC, NMI classes and mapper writes, over 150 s of title, menus and fuzzed 2P play (`make profile`);
- `emu/modes.lua`: state bytes and snapshots over time;
- `emu/look.lua`: snapshots plus PPU dumps;
- `tools/dis6502.py`: the disassembler.

The design follows nes-double-dribble ("DD"), and its lessons carried over (bottom of this file). Where Tecmo Bowl forced something different, the reason is here.

## The ROM

- **Format:** NES 2.0, mapper 1 (MMC1).
  - 8 × 16K PRG and 16 × 8K CHR-ROM; no PRG-RAM in the header.
  - PRG CRC32 `4F0C69BE`, CHR CRC32 `2FA4B7BE`.
- **MMC1 control:** only `$1E` and `$1F` are ever written:
  - 4K CHR mode, PRG mode 3 (`$8000` switchable, `$C000` fixed to the last bank);
  - `$1E` gives vertical mirroring, `$1F` horizontal.
  - Every control write goes through `$C87E` (9 call sites), plus the reset stubs.
- **PRG writes (`$E000`):** banks 0-6 only. Bit 4 (WRAM disable on MMC1B) is never set, so the cart's WRAM stays enabled.
- **Bank tail:** every bank ends in the same 32 bytes at `$xFE0`:
  - the reset stub (`LDA #$10 / STA $2000 / LDA #$80 / STA $8000 / LDA #$1E / LDX #5 / STA $8000 / LSR / DEX / BNE / JMP $C000`);
  - the bank's own number at `$xFF8`;
  - the vectors: NMI = IRQ = `$C060`, RESET = `$FFE0`.

  The game reads `$BFF8` to learn which bank is mapped. The NMI saves it in `$0C` and restores it on the way out, so every bank the build adds carries the tail with its own number.
- **The claim:** the FujiNet claim belongs at `$FFF0`, which is the middle of the reset stub's loop. The build copies the stub into the hook space (`W_RESET`) and points the reset vector there. Nothing jumps to `$FFE0` (xref).
- **Free space in the fixed bank:**

  | Range | Size | State | Used for |
  |---|---|---|---|
  | `$C290-$C39F` | 272 bytes | zero, never read | FIXA |
  | `$CD96-$CEFE` | 361 bytes | zero, never read (`$CEFF` is read) | FIXB |
  | `$CBF5-$CCFD` | — | zero, but a table: read by `$CB6D`, `$CBC3`, `$CBC9` | not used |
  | `$FE00-$FFDF` | — | data read by bank 1 | not used |
  | `$D800-$DFFF` | 2K | never read in the profile, but not blank | left alone |

## Where the game runs

The logic runs on the main thread, in eight cooperative tasks:
- The task slots are 16 bytes at `$80`, `$90`, ... `$F0`. Each holds status, wait count, saved SP, bank and locals.
- The scheduler at `$C556` resets SP to `$FF`, scans for the lowest ready slot (status `$12` or above) and dispatches it.
- Tasks yield through `wait` (`$C64F`, A = frames; 405 call sites).
- With nothing ready, the scheduler loops in `$C559-$C56E`.

The NMI (`$C060`) runs in this order:
1. `$0A` bit 7 clear: it is a stub (`$C064`) and the whole frame is dropped. The game clears the bit around every MMC1 serial write and every task switch.
2. The crash guard: an interrupted PC below `$8000` jumps to the "PROGRAM ERROR" screen at `$C3A0`. So no netcode can run from WRAM, unlike DD's trampolines.
3. `$0C` ← `$BFF8`, then OAM DMA.
4. CHR0 from `$CC`, if its bit 7 is set (then the bit is cleared).
5. Rendering off; the field column (`$13`) or one VRAM request (`$1A`); rendering on.
6. `$2000` (nametable bits from `$BF`/`$DF`), the scroll, and CHR1 ← `$2C`.
7. The pad read (`$C1FF`, inline). It is DPCM-safe: it reads until two reads agree, up to 4 tries.
8. The edges (`$C257`, into `$0D-$10`), the RNG (`$C26F`: `$1F/$20/$21 += $83/$0D/$11`) and `INC $03`.
9. The sprite-0 flag wait (`$C284`).
10. The wakeups (`$C500`): each waiting task's count goes down by one, and at zero the task becomes ready. Then preemption, if `$0B` bit 7 is set.

The status bar is split by task `$D0` (bank 2, `$8094`):
- It does nothing when `$DD` bit 7 is set.
- Otherwise it busy-waits for the sprite-0 hit, with a timeout of 4 × 256 loops.
- It then writes `$2000` (bit 0 from `$BB`), `$2005` ← `$BA`/`$BE`, and CHR1 ← `$2D`. If `$DD` bit 6 is clear, CHR1 is instead `$10` + (`$03` >> 5 & 3), the animated field.
- After the split it far-calls the sound engine (bank 0, `$8000`).

### The NMI classes, stock (`profile.lua`, 9,000 frames)

| Class | Count |
|---|---|
| Full, with the scheduler idle | 8,853 |
| Full, mid-task (a lag frame) | 99, every one a preemption |
| Stub | 4 |
| Scheduler restarts from the NMI | 8,194 |

Stock Tecmo Bowl lags on about 1% of frames, so net mode's lag-as-slowdown (below) costs almost nothing.

## The tick

**A tick is everything between two scheduler-idle points.**

| Stock, the NMI does this... | ...and net mode moves it |
|---|---|
| Pad read, edges, RNG, `$03`, wakeups | Into `LS_TICK` on the main thread. The scheduler is idle there, so preemption reduces to a rescan and is dropped |
| Display pass with sim-visible writes (`$CC` bit 7, `$1A`/`$1B`, `$13`, `$11`, `$12`) | Into the one "tick NMI" per tick: the first full NMI after `NET_IDLE` set `IDLE` |
| Display pass on every other NMI | `W_LAGDISP`: the same PPU and CHR1 results computed in A, and no RAM writes |

As a result, nothing sim-visible happens at a time that depends on where a frame boundary falls inside task code. The stall, the pump and the resync all run on the main thread between ticks, and the NMI never touches the mailbox. A tick that overruns a frame becomes slowdown, not a mid-task wakeup.

This is DD's design turned inside out. DD stalled inside its NMI, because its whole sim ran there; here the sim runs between NMIs.

- **RNG:** stepped only in `LS_TICK`, so it is tick-locked without being replaced. START's seed goes into `$1F/$20`.
- **Sound:** runs inside task `$D0`, once per tick by construction, which removes DD's trap 2. It does read `$4015` (bank 0 `$84E8`, DMC status: real time), so sound RAM can drift. Nothing outside the engine reads it: game logic only writes the request slots `$0700-$0703`. It is outside the CRC, like DD's.

## Determinism traps, in the order they bit

1. **`$CC` bit 7 is read by game logic.**
   - The object engine (task `$E0`, `$CF00`) sets `$CC` bit 7 to request a CHR0 change, then reads the bit back at `$CFAB` in the same run.
   - Stock, a lag NMI between the two clears it, so the read depends on timing.
   - `W_LAGDISP` writes no RAM, and the tick NMI is the only one that applies `$CC`.
2. **The fuzz script never ran, and `det` passed on the title screen.**
   - `LS_LOCAL` read the target tick from `ZP_PTR2` before `LS_TICK` computed it.
   - DD has the same order, but its value survived between ticks. Here `NET_IDLE` puts the game's `$F4-$F8` back after every tick, so it read 0.
   - Lesson: look at where a det run ends up (`emu/ticks.lua`), not just at the verdict.
3. **Lag frames drew the field with the status bar's CHR bank.**
   - The status-bar split runs in task `$D0`, so it is missing on a frame the tick overran.
   - TRACE builds (a full checksum every tick, about 1.9 frames) made that most frames.
   - `W_LAGDISP` now does `$D0`'s split itself: wait for the flag to clear, then for the hit, then the field's scroll and CHR1. Stock does the same through preemption, at the same CPU cost.
4. **The CRC cost a visible hitch.**
   - A full checksum is about 1,660 bytes and 1.3 frames, every 64 ticks.
   - It is now folded in idle time, a quarter of the state on each of ticks `$3D`, `$3E`, `$3F` and `$00` (mod 64), before `IDLE` is set. Every NMI meanwhile is then a lag NMI that writes no RAM.
   - A resync mid-fold voids that CRC (`CK_NEXT`).

## Free RAM

- **Zero page never touched** (profile): `$25`, `$7E`, `$86`, `$87`, `$8C`, `$CF`, `$F4-$F8`, `$FF`.
  - Most are task locals that an unprofiled phase could use.
  - `$F4-$F8` are borrowed: `NET_IDLE` saves them on the way in and restores them on the way out.
  - The resync image takes them from the save area, and the CRC leaves them out.
- **Stack page:** carved into eight 28-byte task stacks, plus the scheduler's `$01E5-$01FF`. The netcode runs on the scheduler's stack (SP = `$FF` at `NET_IDLE`).
  - Stock, an NMI from idle goes down to `$01F8`.
  - The rigs' stack guard records the lowest push while bank 8 is mapped: `$01F0` (host), `$01EE` (guest applying a resync).
  - The floor is `$01E6`: two more bytes for the NMI's `JSR $8003` with bank 4 mapped, above task `$80`'s `$01E4`.
- **Everything else** is in the cart's WRAM (header byte 10 = `$07`).
  - WRAM is zeroed at boot, except `CTRL_SH`, which the game set at `$C035`.
  - A Lobby boot hands over whatever the Lobby left there.

## The checksum

The checksum covers:
- zero page, minus `$0A` (the idle scan's SEC/ROR runs a timing-dependent number of times), `$0C`, sound (`$70-$7F`) and `$F4-$F8`;
- `$0200-$06FF`;
- the play data at `$07D8-$07FF`.

The stack page is out: the dead bytes below each task's SP differ with the sound engine's path.

## The resync image (4,130 bytes)

| Part | Notes |
|---|---|
| Zero page | Borrowed bytes from the save area |
| `$0100-$01FF` | Applied up to `$01E4`: the task stacks hold live context |
| `$0200-$07FF` | |
| The two physical nametables | `$2000`, then `$2400` (vertical) or `$2800` (horizontal), by `CTRL_SH` |
| Palette | |
| `CTRL_SH`, `CHR0_SH` | Shadows kept by `W_CTRL`/`W_CHR0` and the tick NMI's `$CC` path. CHR1 needs none: every NMI sets it |

- **When:** the host snapshots, and the guest applies, at the same point of a tick: inside `LS_TICK`, after the tick NMI.
- **An END between ticks waits (`RS_ENDP`):** applied before the tick NMI, the host's already-processed VRAM request would be replayed.
- **`RS_QUIET`:** task slot `$E0` (the object engine) is free on the play-select screen, between plays and in the menus (`modes.lua`). In `make m4` the push went out at such a moment 136-188 ticks after the mismatch.

## The text screens

CHR is ROM, at MMC1's 128K limit, so our screens borrow the game's font:
- 4K CHR bank 11, which the team-select screen uses.
- It is ASCII for A-Z and 0-9, with `!` at `$21`, `:` at `$3A`, a dash at `$3B`, and chevrons at `$14`/`$15`.
- There is no `.`, `/`, `(` or `=`, so the strings avoid them.
- `tools/mkfontmap.py` checks every glyph against the ROM and writes the map for `text.s` and its reverse for the rigs' screen dumps.

## Measured results

| Test | Result |
|---|---|
| SOLO + FUZZ, no TRACE | 4,000 ticks in 4,183 frames, 154 lag NMIs |
| `det` | Identical at 4,000, 7,000 and 12,000 ticks. B saw 9,798 / 17,335 / 29,943 lag NMIs to A's 6,737 / 12,012 / 20,713 |
| `rig` | 96 CRC pairs, 0 mismatches, every counter 0, about 60 ticks/s; the six tick-aligned snapshot pairs are pixel-identical |
| `m4` | Poke → mismatch → quiet push → rebase; snapshots identical before and after |
| `peerleft` | Clean leave and timeout both pass |
| `lobby` | Every screen checked as text and snapshot |

## Rig lessons (on top of DD's)

- **A MAME read tap over `$8000-$BFFF` costs a Lua call per instruction fetch.** The first stack guard made both consoles run at a fraction of real time, and the match took seven minutes. The guard is now a write tap on `$01E0-$01F7` that counts only pushes, i.e. writes at SP.
- **`RS_APPLY` writes the stack page itself,** so a guard that counted every write there failed `m4`.
