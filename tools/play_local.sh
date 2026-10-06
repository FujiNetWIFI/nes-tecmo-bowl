#!/bin/sh
# play_local.sh -- two consoles side by side on this machine, playable.
#
#   tools/play_local.sh            (or: make play)
#
# Sets up and starts everything a two-player session needs, then tears it
# all down when either MAME window closes (or on Ctrl-C):
#   - two isolated fujinet-pc-rs232 copies (build/play/fn1, fn2; BoIP on
#     :19861 / :19862, web UI on :18091 / :18092), each with its own
#     username appkey and the Lobby's server-URL appkey pointing at the relay
#   - the relay (tb_relay_server.py) on :PLAY_PORT
#   - two windowed MAMEs running build/tb_net.nes on the FujiNet cart slot
#
# In each window: pick the other player from the lobby (Up/Down, A or
# Start) -- or just wait in one window and challenge from the other. The
# player who waited is 1UP. Each console plays with ITS OWN controller 1
# (MAME's default player-1 keys); keyboard input goes to the focused
# window, so click the one you are playing on.
#
# Environment:
#   P1_NAME / P2_NAME  lobby names, 2-8 of A-Z 0-9 (PLAYONE / PLAYTWO)
#   PLAY_PORT          relay port (9701)
#   DELAY              lockstep input delay in ticks, handed out by the
#                      relay (3)
#   GAME_APPKEY        the Lobby handoff key the ROM reads (41)
#   FNPC_DIST          fujinet-pc build to copy
#                      (~/Workspace/fujinet-pc-rs232/build/dist)
#   MAME               MAME tree (~/Workspace/mame)
set -e
cd "$(dirname "$0")/.."
HERE="$(pwd)"
PLAY="$HERE/build/play"
FNPC_DIST="${FNPC_DIST:-$HOME/Workspace/fujinet-pc-rs232/build/dist}"
MAME="${MAME:-$HOME/Workspace/mame}"
PLAY_PORT="${PLAY_PORT:-9701}"
DELAY="${DELAY:-3}"
GAME_APPKEY="${GAME_APPKEY:-41}"
P1_NAME="${P1_NAME:-PLAYONE}"
P2_NAME="${P2_NAME:-PLAYTWO}"

[ -x "$MAME/mame" ] || { echo "play: no mame binary in $MAME" >&2; exit 1; }
[ -x "$FNPC_DIST/fujinet" ] || { echo "play: no fujinet-pc in $FNPC_DIST" >&2; exit 1; }
for n in "$P1_NAME" "$P2_NAME"; do
    echo "$n" | grep -qE '^[A-Z0-9]{2,8}$' ||
        { echo "play: name '$n' must be 2-8 of A-Z 0-9" >&2; exit 1; }
done

# Ports must be free: a leftover from an earlier session would answer
# instead of the one we are about to start.
python3 - "$PLAY_PORT" <<'PY' || exit 1
import socket, sys
for port in (int(sys.argv[1]), 19861, 19862, 18091, 18092):
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("127.0.0.1", port))
    except OSError:
        sys.exit("play: port %d is busy -- an earlier session still running?" % port)
    s.close()
PY

# The ROM: its baked-in endpoint is only the fallback; the appkey below is
# what it actually connects to.
make --no-print-directory build/tb_net.nes SRV_HOST=127.0.0.1 SRV_PORT="$PLAY_PORT" \
    > "$HERE/build/play_build.log" 2>&1 ||
    { cat "$HERE/build/play_build.log"; exit 1; }

mkdir -p "$PLAY"
for i in 1 2; do
    if [ ! -x "$PLAY/fn$i/fujinet" ]; then
        rm -rf "$PLAY/fn$i"
        mkdir -p "$PLAY/fn$i"
        cp -r "$FNPC_DIST"/. "$PLAY/fn$i/"
        python3 - "$PLAY/fn$i/fnconfig.ini" "1986$i" <<'PY'
import re, sys
path, port = sys.argv[1], sys.argv[2]
s = open(path).read()
s2, n = re.subn(r"(\[BOIP\][^\[]*?port=)[0-9]*", r"\g<1>" + port, s, count=1, flags=re.S)
assert n == 1, "BOIP port not patched"
open(path, "w").write(s2)
PY
    fi
    rm -rf "$PLAY/fn$i/SD"
    mkdir -p "$PLAY/fn$i/SD/FujiNet" "$PLAY/cfg$i" "$PLAY/nvram$i" "$PLAY/snap$i"
    # creator 1 / app 1 / key 0: the Lobby username
    # creator 1 / app 1 / key GAME_APPKEY: the server URL the NES Lobby hands over
    printf 'TCP://127.0.0.1:%s/' "$PLAY_PORT" \
        > "$PLAY/fn$i/SD/FujiNet/000101$(printf %02x "$GAME_APPKEY").key"
done
printf '%s' "$P1_NAME" > "$PLAY/fn1/SD/FujiNet/00010100.key"
printf '%s' "$P2_NAME" > "$PLAY/fn2/SD/FujiNet/00010100.key"

FN1= FN2= SRV= M1= M2=
# SIGKILL: neither MAME nor fujinet-pc acts reliably on SIGTERM
cleanup() {
    trap - EXIT INT TERM
    kill -KILL $M1 $M2 $FN1 $FN2 $SRV 2>/dev/null || true
    echo "play: stopped (logs in build/play/)"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

( cd "$PLAY/fn1" && exec ./fujinet -u http://127.0.0.1:18091 ) > "$PLAY/fn1.log" 2>&1 &
FN1=$!
( cd "$PLAY/fn2" && exec ./fujinet -u http://127.0.0.1:18092 ) > "$PLAY/fn2.log" 2>&1 &
FN2=$!
python3 server/tb_relay_server.py --port "$PLAY_PORT" --delay "$DELAY" \
    > "$PLAY/server.log" 2>&1 &
SRV=$!
sleep 2
for p in $FN1 $FN2 $SRV; do
    kill -0 $p 2>/dev/null || { echo "play: a service failed to start; see build/play/*.log" >&2; exit 1; }
done

ROM="$HERE/build/tb_net.nes"
mame() {    # mame <n> <boip port>
    # export, not VAR=x exec: an assignment in front of a special builtin
    # is not reliably passed on, and MAME would quietly use :9995 instead
    ( cd "$MAME" && export FUJINET_TCP="127.0.0.1:$2" && exec ./mame nes -nes_slot fujinet \
        -cart "$ROM" -window -nomax -skip_gameinfo \
        -cfg_directory "$PLAY/cfg$1" -nvram_directory "$PLAY/nvram$1" \
        -snapshot_directory "$PLAY/snap$1" ) > "$PLAY/mame$1.log" 2>&1 &
}
mame 1 19861
M1=$!
sleep 1
mame 2 19862
M2=$!

cat <<EOF
play: running
  console 1: $P1_NAME   (fujinet-pc web UI http://127.0.0.1:18091)
  console 2: $P2_NAME   (fujinet-pc web UI http://127.0.0.1:18092)
  relay:     127.0.0.1:$PLAY_PORT, input delay $DELAY ticks
Challenge one player from the other's lobby. Close either window or press
Ctrl-C here to stop everything.
EOF

# until either console window closes
while kill -0 $M1 2>/dev/null && kill -0 $M2 2>/dev/null; do
    sleep 1
done
grep -E "match:|CRC MISMATCH|crc ok" "$PLAY/server.log" | tail -3 || true
