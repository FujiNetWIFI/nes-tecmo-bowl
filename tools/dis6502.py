#!/usr/bin/env python3
"""dis6502.py -- tiny 6502 disassembler for the Double Dribble PRG.

  dis6502.py ROM BANK START [END|+N]     disassemble console addresses in a bank
  dis6502.py ROM --xref ADDR             every abs/zp reference to ADDR, all banks

BANK 7 (or 'F') is the fixed bank at $C000; banks 0-6 sit at $8000.
"""
import sys

OPS = {}
def _d(m, mode, *codes):
    for c in codes: OPS[c] = (m, mode)
# mode: imp imm zp zpx zpy abs abx aby ind izx izy rel acc
for m, row in {
 'ADC': dict(imm=0x69, zp=0x65, zpx=0x75, abs=0x6D, abx=0x7D, aby=0x79, izx=0x61, izy=0x71),
 'AND': dict(imm=0x29, zp=0x25, zpx=0x35, abs=0x2D, abx=0x3D, aby=0x39, izx=0x21, izy=0x31),
 'ASL': dict(acc=0x0A, zp=0x06, zpx=0x16, abs=0x0E, abx=0x1E),
 'BIT': dict(zp=0x24, abs=0x2C),
 'CMP': dict(imm=0xC9, zp=0xC5, zpx=0xD5, abs=0xCD, abx=0xDD, aby=0xD9, izx=0xC1, izy=0xD1),
 'CPX': dict(imm=0xE0, zp=0xE4, abs=0xEC), 'CPY': dict(imm=0xC0, zp=0xC4, abs=0xCC),
 'DEC': dict(zp=0xC6, zpx=0xD6, abs=0xCE, abx=0xDE),
 'EOR': dict(imm=0x49, zp=0x45, zpx=0x55, abs=0x4D, abx=0x5D, aby=0x59, izx=0x41, izy=0x51),
 'INC': dict(zp=0xE6, zpx=0xF6, abs=0xEE, abx=0xFE),
 'JMP': dict(abs=0x4C, ind=0x6C), 'JSR': dict(abs=0x20),
 'LDA': dict(imm=0xA9, zp=0xA5, zpx=0xB5, abs=0xAD, abx=0xBD, aby=0xB9, izx=0xA1, izy=0xB1),
 'LDX': dict(imm=0xA2, zp=0xA6, zpy=0xB6, abs=0xAE, aby=0xBE),
 'LDY': dict(imm=0xA0, zp=0xA4, zpx=0xB4, abs=0xAC, abx=0xBC),
 'LSR': dict(acc=0x4A, zp=0x46, zpx=0x56, abs=0x4E, abx=0x5E),
 'ORA': dict(imm=0x09, zp=0x05, zpx=0x15, abs=0x0D, abx=0x1D, aby=0x19, izx=0x01, izy=0x11),
 'ROL': dict(acc=0x2A, zp=0x26, zpx=0x36, abs=0x2E, abx=0x3E),
 'ROR': dict(acc=0x6A, zp=0x66, zpx=0x76, abs=0x6E, abx=0x7E),
 'SBC': dict(imm=0xE9, zp=0xE5, zpx=0xF5, abs=0xED, abx=0xFD, aby=0xF9, izx=0xE1, izy=0xF1),
 'STA': dict(zp=0x85, zpx=0x95, abs=0x8D, abx=0x9D, aby=0x99, izx=0x81, izy=0x91),
 'STX': dict(zp=0x86, zpy=0x96, abs=0x8E), 'STY': dict(zp=0x84, zpx=0x94, abs=0x8C),
}.items():
    for mode, c in row.items(): _d(m, mode, c)
for m, c in dict(BPL=0x10, BMI=0x30, BVC=0x50, BVS=0x70, BCC=0x90, BCS=0xB0, BNE=0xD0, BEQ=0xF0).items():
    _d(m, 'rel', c)
for m, c in dict(BRK=0, PHP=8, CLC=0x18, PLP=0x28, SEC=0x38, RTI=0x40, PHA=0x48, CLI=0x58, RTS=0x60,
                 PLA=0x68, SEI=0x78, DEY=0x88, TXA=0x8A, TYA=0x98, TXS=0x9A, TAY=0xA8, TAX=0xAA,
                 CLV=0xB8, TSX=0xBA, INY=0xC8, DEX=0xCA, CLD=0xD8, INX=0xE8, NOP=0xEA, SED=0xF8).items():
    _d(m, 'imp', c)
SIZE = dict(imp=1, acc=1, imm=2, zp=2, zpx=2, zpy=2, izx=2, izy=2, rel=2, abs=3, abx=3, aby=3, ind=3)
FMT = dict(imp='', acc='A', imm='#${:02X}', zp='${:02X}', zpx='${:02X},X', zpy='${:02X},Y',
           izx='(${:02X},X)', izy='(${:02X}),Y', abs='${:04X}', abx='${:04X},X', aby='${:04X},Y',
           ind='(${:04X})', rel='${:04X}')

def load(path):
    d = open(path, 'rb').read()
    prg = d[16:16 + d[4] * 16384]
    return [prg[i*16384:(i+1)*16384] for i in range(len(prg)//16384)]

def base(bank, nbanks):
    return 0xC000 if bank == nbanks - 1 else 0x8000

def decode(mem, org, pc):
    op = mem[pc - org]
    if op not in OPS:
        return None, 1, '.byte ${:02X}'.format(op)
    m, mode = OPS[op]
    n = SIZE[mode]
    if pc - org + n > len(mem):
        return None, 1, '.byte ${:02X}'.format(op)
    if n == 1:
        arg = None
        txt = m + (' A' if mode == 'acc' else '')
    elif n == 2:
        arg = mem[pc - org + 1]
        if mode == 'rel':
            arg = (pc + 2 + (arg - 256 if arg > 127 else arg)) & 0xFFFF
        txt = m + ' ' + FMT[mode].format(arg)
    else:
        arg = mem[pc - org + 1] | mem[pc - org + 2] << 8
        txt = m + ' ' + FMT[mode].format(arg)
    return (m, mode, arg), n, txt

def main():
    a = sys.argv[1:]
    banks = load(a[0])
    if a[1] == '--xref':
        tgt = int(a[2], 16)
        for b, mem in enumerate(banks):
            org = base(b, len(banks))
            for pc in range(org, org + len(mem) - 2):
                ins, n, txt = decode(mem, org, pc)
                if ins and ins[2] == tgt and ins[1] not in ('imm', 'rel'):
                    print('bank {} ${:04X}: {}'.format(b, pc, txt))
        return
    b = len(banks) - 1 if a[1] in ('F', 'f') else int(a[1])
    mem = banks[b]; org = base(b, len(banks))
    pc = int(a[2], 16)
    end = pc + 0x40
    if len(a) > 3:
        end = pc + int(a[3][1:], 16) if a[3].startswith('+') else int(a[3], 16)
    while pc < end:
        ins, n, txt = decode(mem, org, pc)
        raw = ' '.join('{:02X}'.format(x) for x in mem[pc-org:pc-org+n])
        print('{:04X}  {:9s} {}'.format(pc, raw, txt))
        pc += n

if __name__ == '__main__':
    main()
