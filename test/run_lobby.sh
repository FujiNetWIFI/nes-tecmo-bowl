#!/bin/sh
# Look at the session screens: one console (build/tb_net.nes) against a relay
# with idle players parked in it (two of them matched to each other, so the
# list shows IN GAME rows). Prints each screen as text and snapshots it to
# build/lobbyshots. Then moves the cursor down twice and challenges the third
# entry: the matched screen, the game starting, and -- the idler never sends
# a single input -- the CONNECTION LOST notice ten seconds later.
# Uses the rig's fujinet-pc copy (make rig creates it) with a username appkey
# and the Lobby's server-URL appkey pointing at the relay.
set -e
BUILD="$(pwd)/build"
RIG="$BUILD/rig"
PORT=9799
[ -x "$RIG/fn1/fujinet" ] || { echo "lobby: run 'make rig' once first (it sets up build/rig/fn1)"; exit 1; }
rm -rf "$RIG/fn1/SD" "$BUILD/lobbyshots"
mkdir -p "$RIG/fn1/SD/FujiNet"
printf 'thom' > "$RIG/fn1/SD/FujiNet/00010100.key"
printf 'TCP://127.0.0.1:%s/' "$PORT" > "$RIG/fn1/SD/FujiNet/000101$(printf %02x "${GAME_APPKEY:-41}").key"
( cd "$RIG/fn1" && exec ./fujinet -u http://127.0.0.1:18081 ) > "$RIG/fn1.log" 2>&1 &
FN=$!
python3 server/tb_relay_server.py --port $PORT > "$BUILD/lobby_srv.log" 2>&1 &
SRV=$!
ID=
trap 'kill -KILL $FN $SRV $ID 2>/dev/null || true' EXIT
sleep 1.5
python3 test/lobby_idlers.py --port $PORT --pair ALPHA BRAVO CHARLIE DELTA > "$BUILD/idlers.log" 2>&1 &
ID=$!
sleep 1
FUJINET_TCP=127.0.0.1:19851 THROTTLE=1 SNAPDIR="$BUILD/lobbyshots" \
    LOBBY_SHOTS="4,9,13,33" LOBBY_KEYS="8:4,11:4,12:128" SECS=60 \
    emu/run.sh "$BUILD/tb_net.nes" lobby 2>&1 | grep -v "^fujinet\|^Average"
grep -E "hello|match" "$BUILD/lobby_srv.log" | cut -c25-
