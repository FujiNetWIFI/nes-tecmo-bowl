#!/usr/bin/env python3
"""rig_verdict.py RIGDIR MODE LEAVE_MODE -- judge a run of test/run_rig.sh."""
import re, sys

rig, mode, leave = sys.argv[1], sys.argv[2], sys.argv[3]

def console(n):
    s = open("%s/c%d.out" % (rig, n)).read()
    finals = re.findall(r"^FINAL t=([\d.]+) tick=(\d+) (.*)$", s, re.M)
    stats = re.findall(r"^STAT t=([\d.]+) tick=(\d+) (.*)$", s, re.M)
    last = finals[-1] if finals else (stats[-1] if stats else None)
    st = {}
    if last:
        st = dict(kv.split("=") for kv in last[2].split())
        st = {k: int(v, 16) for k, v in st.items()}
        st["tick"] = int(last[1])
    st["final"] = bool(finals)
    st["match"] = bool(re.search(r"^MATCH", s, re.M))
    st["poke"] = re.search(r"^POKE .*", s, re.M)
    st["screen"] = "\n".join(re.findall(r"^SCR\s+\d+ (.*)$", s, re.M))
    st["ticks"] = [int(t) for _, t, _ in stats]
    return st

c1, c2 = console(1), console(2)
srv = open(rig + "/server.log").read()
fails = []
def need(cond, msg):
    if not cond:
        fails.append(msg)

matches = re.findall(r"match: host (\S+) vs guest (\S+)", srv)
mism = re.findall(r"CRC MISMATCH tick (\d+)", srv)
oks = [(m.start(), int(m.group(1)), int(m.group(2)))
       for m in re.finditer(r"crc ok through tick (\d+) \((\d+) pairs\)", srv)]
print("rig: server: %d match(es) %s, %d CRC mismatch(es), last ok: %s" % (
    len(matches), matches[:1], len(mism), oks[-1][1:] if oks else None))
for n, c in (1, c1), (2, c2):
    keys = ("ACTIVE", "ROLE", "DROPPED", "WHY", "PSCR", "SLIP", "REJ", "TMO",
            "ERR", "MIS", "RSY", "HLD", "STL", "GATE", "WAITED", "SPMIN")
    print("rig: console %d: match=%s tick=%s %s" % (n, c["match"], c.get("tick"),
          " ".join("%s=%d" % (k, c[k]) for k in keys if k in c)))

need(len(matches) >= 1, "the server never matched the two consoles")
need("RIGONE" in srv, "console 1 never said hello as RIGONE (username appkey)")
need(c1["match"] and c2["match"], "a console never reached the match")
diag = lambda c: sum(c.get(k, 0) for k in ("SLIP", "REJ", "TMO", "ERR"))
# The stack guard: the lowest stack byte written with bank 8 mapped (the
# netcode, and an NMI's frame on top of it), then the NMI's 2 bytes deeper
# with bank 4 mapped, must stay above task $80's stack at $01E4.
SP_FLOOR = 0xE4 + 2
for n, c in (1, c1), (2, c2):
    if "SPMIN" in c:
        need(c["SPMIN"] > SP_FLOOR, "console %d netcode SP reached $%02X (floor $%02X)" % (
            n, c["SPMIN"], SP_FLOOR))

if mode == "rig":
    need(c1["final"] and c2["final"], "a console did not finish its run")
    for n, c in (1, c1), (2, c2):
        need(c.get("ACTIVE") == 1 and c.get("DROPPED") == 0, "console %d not active/connected" % n)
        need(c.get("tick", 0) > 3000, "console %d only reached tick %s" % (n, c.get("tick")))
        need(diag(c) == 0, "console %d diag counters nonzero" % n)
        need(c.get("MIS", 1) == 0, "console %d saw a CRC mismatch" % n)
    need(not mism, "the server logged CRC mismatches")
    need(oks and oks[-1][2] >= 20, "too few CRC pairs verified")
elif mode == "m4":
    need(c2["poke"] is not None, "console 2 never poked")
    for n, c in (1, c1), (2, c2):
        need(c.get("ACTIVE") == 1 and c.get("DROPPED") == 0, "console %d not active/connected" % n)
        need(c.get("RSY", 0) >= 1, "console %d never completed a resync" % n)
        need(c.get("HOLD", 0) == 0, "console %d stuck in a resync hold" % n)
        need(diag(c) == 0, "console %d diag counters nonzero" % n)
    need(mism, "the server saw no mismatch: the poke changed nothing the CRC covers")
    if mism and oks:
        last_bad = max(m.start() for m in re.finditer(r"CRC MISMATCH", srv))
        need(any(pos > last_bad for pos, _, _ in oks), "no 'crc ok' after the last mismatch")
    print("rig: m4: push gate %s (1 = quiet moment, 2 = cap) after %s ticks" % (
        c1.get("GATE"), c1.get("WAITED")))
elif mode == "peerleft":
    need(not c2["final"], "console 2 never left (it ran to the end)")
    want = "OPPONENT LEFT" if leave == "clean" else "CONNECTION LOST"
    need(c1.get("PSCR") == 1, "console 1 never put up the peer-left screen")
    need(c1.get("WHY") == (1 if leave == "clean" else 0), "console 1 has the wrong reason")
    need(want in c1["screen"], "console 1 screen lacks %r:\n%s" % (want, c1["screen"]))
    need("PRESS RESET" in c1["screen"], "console 1 screen lacks PRESS RESET")
    need(diag(c1) == 0, "console 1 diag counters nonzero")
    t = c1["ticks"]
    need(len(t) >= 2 and t[-1] == t[-2], "console 1 sim still moving after the notice")
    print("rig: console 1 screen:\n" + c1["screen"])

if fails:
    for f in fails:
        print("rig: FAIL: " + f)
    sys.exit(1)
print("rig: %s PASS" % mode.upper())
