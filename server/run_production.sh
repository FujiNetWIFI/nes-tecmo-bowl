#!/bin/sh
# Production launch on the shared host: relay on the game's port, registered
# as a room on the FujiNet Lobby for platform "nes".
#
# Port 9701 and appkey 41 are this port's PROPOSED assignments, next to
# Double Dribble's proposed 9700 and 40 (9100-9115 are the Intellivision
# games, 9600-9604 the 2600 ones; appkeys 10-27 are taken) -- confirm both
# before the first production start. The appkey must match the ROM's
# GAME_APPKEY (make GAME_APPKEY=n): the NES Lobby hands the booted ROM this
# room's serverurl through that key.
#
# Override via the environment: PORT, LOBBY_URL, LOBBY_APPKEY,
# LOBBY_SERVERURL, LOBBY_CLIENT_URL. Never run this against a test rig; rigs
# stay unregistered (make rig uses 127.0.0.1 and no --lobby-enabled).
set -e
cd "$(dirname "$0")/.."

exec python3 server/tb_relay_server.py \
    --port "${PORT:-9701}" \
    --lobby-enabled \
    ${LOBBY_URL:+--lobby-url "$LOBBY_URL"} \
    ${LOBBY_APPKEY:+--lobby-appkey "$LOBBY_APPKEY"} \
    ${LOBBY_SERVERURL:+--lobby-serverurl "$LOBBY_SERVERURL"} \
    ${LOBBY_CLIENT_URL:+--lobby-client-url "$LOBBY_CLIENT_URL"} \
    "$@"
