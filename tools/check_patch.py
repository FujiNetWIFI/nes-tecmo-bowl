#!/usr/bin/env python3
"""check_patch.py -- audit a built ROM against the original.

Fails unless: banks 0-6 and the spare bank 7 are byte-identical to the
original, the new fixed bank (15) differs from the original fixed bank ONLY
at the bytes tools/patches.py declares, and CHR-ROM is untouched.
"""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from patches import PATCHES
BANK = 16384

orig = open(sys.argv[1], 'rb').read()
new = open(sys.argv[2], 'rb').read()
op = orig[16:16 + 8 * BANK]
np_ = new[16:16 + new[4] * BANK]
assert new[4] == 16, "expected 16 PRG banks"
bad = 0
for b in range(8):
    if np_[b * BANK:(b + 1) * BANK] != op[b * BANK:(b + 1) * BANK]:
        print("bank {} differs from the original".format(b)); bad += 1
declared = set()
for addr, old, newb, why in PATCHES:
    declared.update(range(addr - 0xC000, addr - 0xC000 + len(old)))
fo, fn = op[7 * BANK:], np_[15 * BANK:]
diffs = [i for i in range(BANK) if fo[i] != fn[i]]
for i in diffs:
    if i not in declared:
        print("undeclared change at ${:04X}: {:02X} -> {:02X}".format(0xC000 + i, fo[i], fn[i])); bad += 1
if new[16 + 16 * BANK:] != orig[16 + 8 * BANK:]:
    print("CHR-ROM differs from the original"); bad += 1
if bad:
    sys.exit("check_patch: FAIL ({} problems)".format(bad))
print("check_patch: OK -- {} declared patch sites, {} bytes changed in the fixed bank".format(
    len(PATCHES), len(diffs)))
