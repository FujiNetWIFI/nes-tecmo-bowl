#!/bin/sh
# Two-player rig, headless and in real time:
#   2 x fujinet-pc-rs232 (isolated copies, BoIP :19851 / :19852)
#   1 x tb_relay_server (:RIG_PORT)
#   2 x MAME with the FujiNet cart: console 1 waits in the lobby, console 2
#       auto-joins it; both play fuzz inputs generated per tick in-console
# Console 1's fujinet-pc carries a username appkey (RIGONE) and the Lobby's
# server-URL appkey; its ROM's own endpoint is a dead port, so it can only
# get in through the handoff. Console 2 has neither: GUESTnn, build endpoint.
#
# RIG_MODE=rig       (default) pass: both matched and ticking, zero CRC
#                    mismatches on the server, diag counters all zero
# RIG_MODE=m4        console 2 pokes a sim byte mid-game: the mismatch must be
#                    detected, the host must push, and CRCs agree afterwards
# RIG_MODE=peerleft  console 2 leaves at LEAVE_SECS; LEAVE_MODE=clean kills
#                    its fujinet-pc too (the server sees the socket close:
#                    "OPPONENT LEFT"), LEAVE_MODE=timeout kills only MAME (the
#                    socket stays up: console 1 must time out, "CONNECTION
#                    LOST"). Console 1 must show the notice and stay frozen.
set -e
BUILD="$(pwd)/build"
RIG="$BUILD/rig"
FNPC_DIST="${FNPC_DIST:-$HOME/Workspace/fujinet-pc-rs232/build/dist}"
RIG_PORT="${RIG_PORT:-9799}"
RIG_MODE="${RIG_MODE:-rig}"
RIG_SECS="${RIG_SECS:-120}"
LEAVE_SECS="${LEAVE_SECS:-60}"
LEAVE_MODE="${LEAVE_MODE:-clean}"
GAME_APPKEY="${GAME_APPKEY:-41}"
# A stale rig (a killed run's survivors) would answer in place of this one.
python3 - "$RIG_PORT" <<'PY' || exit 1
import socket, sys
for port in (int(sys.argv[1]), 19851, 19852, 18081, 18082):
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("127.0.0.1", port))
    except OSError:
        sys.exit("rig: port %d is busy -- a previous rig still running?" % port)
    s.close()
PY
mkdir -p "$RIG"
rm -rf "$RIG"/*.log "$RIG"/*.out "$RIG"/snap1 "$RIG"/snap2

for i in 1 2; do
    if [ ! -x "$RIG/fn$i/fujinet" ]; then
        rm -rf "$RIG/fn$i"
        mkdir -p "$RIG/fn$i"
        cp -r "$FNPC_DIST"/. "$RIG/fn$i/"
        python3 - "$RIG/fn$i/fnconfig.ini" "1985$i" <<'PY'
import re, sys
path, port = sys.argv[1], sys.argv[2]
s = open(path).read()
s2, n = re.subn(r"(\[BOIP\][^\[]*?port=)[0-9]*", r"\g<1>" + port, s, count=1, flags=re.S)
assert n == 1, "BOIP port not patched"
open(path, "w").write(s2)
PY
    fi
    rm -rf "$RIG/fn$i/SD"
    mkdir -p "$RIG/fn$i/SD/FujiNet"
done
printf 'RIGONE' > "$RIG/fn1/SD/FujiNet/00010100.key"
printf 'TCP://127.0.0.1:%s/' "$RIG_PORT" > "$RIG/fn1/SD/FujiNet/000101$(printf %02x "$GAME_APPKEY").key"

( cd "$RIG/fn1" && exec ./fujinet -u http://127.0.0.1:18081 ) > "$RIG/fn1.log" 2>&1 &
FN1=$!
( cd "$RIG/fn2" && exec ./fujinet -u http://127.0.0.1:18082 ) > "$RIG/fn2.log" 2>&1 &
FN2=$!
python3 server/tb_relay_server.py --port "$RIG_PORT" > "$RIG/server.log" 2>&1 &
SRV=$!
C1=; C2=
# SIGKILL all round: neither headless MAME nor fujinet-pc acts on SIGTERM,
# and a survivor holding a port would quietly stand in for the next run
cleanup() { kill -KILL $C1 $C2 $FN1 $FN2 $SRV 2>/dev/null || true; }
trap cleanup EXIT
sleep 2

secs2=$RIG_SECS
[ "$RIG_MODE" = peerleft ] && secs2=$((RIG_SECS + 60))
M4ENV=
[ "$RIG_MODE" = m4 ] && M4ENV="M4_AT=${M4_AT:-40}"

env -u M4_AT THROTTLE=1 FUJINET_TCP=127.0.0.1:19851 RIG_SECS=$RIG_SECS SCREEN_TEXT=1 \
    SNAPDIR="$RIG/snap1" SNAP_EVERY=0 SNAP_TICKS=1024 SECS=$((RIG_SECS + 30)) \
    emu/run.sh "$BUILD/tb_rig1.nes" rig > "$RIG/c1.out" 2>&1 &
C1=$!
sleep 3
env $M4ENV THROTTLE=1 FUJINET_TCP=127.0.0.1:19852 RIG_SECS=$secs2 \
    SNAPDIR="$RIG/snap2" SNAP_EVERY=0 SNAP_TICKS=1024 SECS=$((secs2 + 30)) \
    emu/run.sh "$BUILD/tb_rig2.nes" rig > "$RIG/c2.out" 2>&1 &
C2=$!

if [ "$RIG_MODE" = peerleft ]; then
    # wait for the match, then LEAVE_SECS more, then pull console 2
    for _ in $(seq 1 120); do grep -q "^MATCH" "$RIG/c1.out" 2>/dev/null && break; sleep 1; done
    sleep "$LEAVE_SECS"
    echo "rig: console 2 leaves ($LEAVE_MODE)"
    # SIGKILL: headless MAME does not act on SIGTERM
    kill -KILL $C2 2>/dev/null || true
    [ "$LEAVE_MODE" = clean ] && kill -KILL $FN2 2>/dev/null || true
fi
wait $C1 || true
wait $C2 2>/dev/null || true    # (already gone in peerleft mode)

python3 test/rig_verdict.py "$RIG" "$RIG_MODE" "$LEAVE_MODE"
