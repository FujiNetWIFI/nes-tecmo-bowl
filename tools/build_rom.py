#!/usr/bin/env python3
"""build_rom.py -- splice the netcode into Tecmo Bowl.

  build_rom.py ORIG.nes NET.bin NET.lbl OUT.nes
  build_rom.py --org ORIG.nes OUT.nes     split + rejoin, untouched (verify-org)

MMC1 8 x 16K PRG becomes 16 x 16K (at exactly 256K MMC1 needs no SUROM
bit): banks 0-6 as they were, 7 a spare copy of the old fixed bank (the game
never maps it; kept so a stray select still lands on real code, and its
$BFF8 still reads 7), 8 the netcode, 9-14 empty, 15 the fixed bank with
tools/patches.py applied. Every bank ends in the game's $BFE0 tail -- the
reset stub, the bank's own number at $BFF8, the vectors -- because the NMI
reads $BFF8 to put the interrupted bank back. CHR-ROM is carried through.
The NES 2.0 header asks for 8K of PRG-RAM, which the FujiNet cart serves
at $6000.

NET.bin is ld65's output (src/tb.cfg): bank 8 up to $BFDF, then the FIX
blobs the patch table splices into the fixed bank.
"""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from patches import PATCHES, FIX

BANK = 16384
B8_SIZE = 0x3FE0
TAIL = 0x3FE0                   # $BFE0: stub, ID at +$18, vectors
ID_AT = 0x18

def labels(path):
    out = {}
    for line in open(path):
        p = line.split()
        if len(p) == 3 and p[0] == 'al':
            out[p[2].lstrip('.')] = int(p[1], 16)
    return out

def expand(seq, syms):
    b = []
    for x in seq:
        if isinstance(x, str):
            v = syms[x]
            b += [v & 0xFF, v >> 8]
        else:
            b.append(x)
    return b

def split(path):
    d = open(path, 'rb').read()
    hdr, prg = d[:16], d[16:16 + d[4] * BANK]
    assert d[:4] == b'NES\x1a' and d[4] == 8 and (d[6] >> 4) == 1 and d[5] == 16, \
        "not the MMC1 Tecmo Bowl (8 x 16K PRG, 16 x 8K CHR)"
    return hdr, [bytearray(prg[i * BANK:(i + 1) * BANK]) for i in range(8)], d[16 + len(prg):]

def tail_for(banks, n):
    t = bytearray(banks[0][TAIL:])
    for b in banks[1:7]:        # every switchable bank has the same tail
        u = bytearray(b[TAIL:])
        u[ID_AT] = t[ID_AT]
        assert u == t, "bank tails differ beyond the ID byte"
    t[ID_AT] = n
    return t

def main():
    a = sys.argv[1:]
    if a[0] == '--org':
        hdr, banks, tail = split(a[1])
        open(a[2], 'wb').write(hdr + b''.join(banks) + tail)
        return
    orig, binpath, lblpath, out = a
    hdr, banks, chr_ = split(orig)
    syms = labels(lblpath)
    blob = open(binpath, 'rb').read()
    blobs, off = {}, B8_SIZE
    for name in ('FIXA', 'FIXB'):
        size = FIX[name][1]
        blobs[name] = list(blob[off:off + size])
        off += size
    assert len(blob) == off, "ld65 output is {} bytes, expected {}".format(len(blob), off)
    b8 = bytearray(blob[:B8_SIZE]) + tail_for(banks, 8)
    fixed = bytearray(banks[7])
    for addr, old, new, why in PATCHES:
        new = blobs[new] if isinstance(new, str) else expand(new, syms)
        o = addr - 0xC000
        have = list(fixed[o:o + len(old)])
        if have != old:
            sys.exit("patch ${:04X}: expected {} found {} ({})".format(
                addr, bytes(old).hex(), bytes(have).hex(), why))
        assert len(new) == len(old), "patch ${:04X} changes length".format(addr)
        fixed[o:o + len(new)] = bytes(new)
    out_banks = banks[:7] + [banks[7], b8]
    for n in range(9, 15):
        e = bytearray(b'\xff' * TAIL) + tail_for(banks, n)
        out_banks.append(e)
    out_banks.append(fixed)
    h = bytearray(hdr)
    h[4] = 16                   # 16 x 16K PRG
    h[7] = (h[7] & 0xF0) | 0x08 # NES 2.0
    h[9] = 0
    h[10] = 0x07                # 8K PRG-RAM (64 << 7), volatile
    open(out, 'wb').write(bytes(h) + b''.join(out_banks) + chr_)

if __name__ == '__main__':
    main()
