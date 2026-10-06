"""patches.py -- every byte the build changes in Tecmo Bowl's fixed bank.

Each entry: console address, the ORIGINAL bytes (checked before patching, so
a wrong ROM or a moved routine fails the build), the replacement (a list of
ints and symbol names -- a symbol expands to its 16-bit little-endian value
from the label file -- or the name of a FIX blob from the linker output),
and why. check_patch.py fails the build on any difference between the
original and patched fixed bank not listed here.
"""

# The fixed bank's free space the hooks are linked into (src/tb.cfg): both
# read as zero in the original and nothing reads them (emu/profile.lua).
FIX = {'FIXA': (0xC290, 0x110), 'FIXB': (0xCD96, 0x169)}

PATCHES = [
    (0xFFFC, [0xE0, 0xFF], ['W_RESET'],
     "RESET vector: the game's stub at $FFE0, moved into FIXA"),
    (0xFFF0, [0x80, 0x4A, 0xCA, 0xD0], list(b"FUJI"),
     "the FujiNet claim, over the moved stub's loop: keeps the cart mailbox alive"),
    (0xC044, [0x20, 0xEE, 0xC5], [0x20, 'W_BOOT'],
     "init: JSR $C5EE (spawn task $80) -> JSR W_BOOT (netcode boot, then the spawn)"),
    (0xC064, [0x48, 0xAD, 0x02, 0x20, 0x68, 0x40], [0x4C, 'W_STUB', 0xEA, 0xEA, 0xEA],
     "NMI busy exit ($0A bit 7 clear) -> W_STUB: the same, and a frame count"),
    (0xC087, [0xA5, 0xCC, 0x10, 0x17], [0x4C, 'W_DISP', 0xEA],
     "NMI after OAM DMA: LDA $CC / BPL -> W_DISP (net: tick NMI or RAM-free lag NMI)"),
    (0xC1FF, [0xA0, 0x04, 0xA5, 0x0D], [0x4C, 'W_SIM', 0xEA],
     "NMI pad read: LDY #4 / LDA $0D -> W_SIM (net: pads, RNG, $03 in LS_TICK)"),
    (0xC28D, [0x4C, 0x00, 0xC5], [0x4C, 'W_WAKE'],
     "NMI: JMP $C500 (wakeups, preemption) -> W_WAKE (net: LS_TICK wakes)"),
    (0xC569, [0xE0, 0x00, 0xD0, 0xF1, 0xF0, 0xEA], [0xD0, 0xF3, 0x4C, 'W_IDLE', 0xEA],
     "idle scan: CPX #0 (redundant after TAX) / BNE / BEQ $C559 -> BNE / JMP W_IDLE"),
    (0xC87E, [0x46, 0x0A, 0x8D], [0x4C, 'W_CTRL'],
     "MMC1 control write: shadow the mirroring for the resync image"),
    (0xC897, [0x46, 0x0A, 0x8D], [0x4C, 'W_CHR0'],
     "MMC1 CHR0 write: shadow the bank for the resync image"),
    (0xC290, [0x00] * 0x110, 'FIXA', "hook code (src/fix.s)"),
    (0xCD96, [0x00] * 0x169, 'FIXB', "hook code (src/fix.s), spare"),
]
