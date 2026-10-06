#!/bin/sh
# Determinism A/B: the same fuzz inputs (generated per tick, inside the
# console) through build A (no stalls) and build B (a 9-frame stall every 64
# ticks, and every tick's tasks held back by a different part of a frame, so
# they run at a different place in the frame and some overrun into lag
# NMIs), each recording every tick's sim checksum. The two traces must be
# identical tick for tick: if they are, how long a tick takes -- stalls, lag
# frames, the mailbox -- cannot reach the sim.
set -e
BUILD=build
TICKS="${DET_TICKS:-4000}"
TB=$(awk '/\.TRACE_BUF$/ {print "0x" substr($2,3)}' $BUILD/tb_detA.lbl)
for v in A B; do
    rm -rf "$BUILD/det$v"
    SNAPDIR="$BUILD/det$v" DET_TICKS=$TICKS TRACE_BUF=$TB SECS=900 \
        emu/run.sh $BUILD/tb_det$v.nes det > $BUILD/det$v.out 2>&1 &
done
wait
python3 - "$BUILD/detA.out" "$BUILD/detB.out" <<'PY'
import sys, re
def load(p):
    s = open(p).read()
    m = re.search(r"^TICK (\d+) FRAMES (\d+) LAGNMI (\d+)", s, re.M)
    if not m:
        sys.exit("det: no trace in %s:\n%s" % (p, s[-800:]))
    return int(m.group(1)), int(m.group(2)), int(m.group(3)), dict((int(a), b) for a, b in re.findall(r"^TR (\d+) (\w+)", s, re.M))
ta, fa, la, a = load(sys.argv[1]); tb, fb, lb, b = load(sys.argv[2])
common = sorted(set(a) & set(b))
bad = [t for t in common if a[t] != b[t]]
print("det: A reached tick %d in %d frames, B tick %d in %d frames" % (ta, fa, tb, fb))
print("det: lag NMIs (mid-task, display only): A %d, B %d" % (la, lb))
print("det: %d ticks compared (%d..%d), %d differ" % (len(common), common[0], common[-1], len(bad)))
if bad:
    print("det: first divergence at tick %d: A %s B %s" % (bad[0], a[bad[0]], b[bad[0]]))
    sys.exit("det: FAIL")
if fb <= fa:
    sys.exit("det: FAIL -- B was not slower; the stall injection did not happen")
print("det: PASS")
PY
