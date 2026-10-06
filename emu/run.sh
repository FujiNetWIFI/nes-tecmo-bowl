#!/usr/bin/env bash
# run.sh ROM [script] -- MAME with the FujiNet cart slot. Headless when a Lua
# script is named (emu/<script>.lua), windowed otherwise. FUJINET_TCP picks
# the fujinet-pc BoIP endpoint (default 127.0.0.1:9995); the cart device
# reads it from the environment. SNAPDIR overrides
# the snapshot directory. MAME must run from its own tree or
# -autoboot_script is silently ignored, so every path is absolute.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
MAME="${MAME:-$HOME/Workspace/mame}"
ROM="$(realpath "$1")"
SCRIPT="${2:-}"
export TB_EMU="$HERE/emu"
SNAPDIR="$(realpath -m "${SNAPDIR:-$HERE/build/snap}")"
args=(nes -nes_slot fujinet -cart "$ROM" -snapshot_directory "$SNAPDIR")
if [ -n "$SCRIPT" ]; then
    args+=(-autoboot_script "$HERE/emu/$SCRIPT.lua" -video none -sound none
           -seconds_to_run "${SECS:-600}")
    # THROTTLE=1: real time (the two-console rigs: lockstep timeouts are in
    # frames, and two unthrottled MAMEs make a frame a few wall-clock ms)
    [ "${THROTTLE:-0}" = 1 ] || args+=(-nothrottle)
else
    args+=(-window -nomax)
fi
cd "$MAME"
exec ./mame "${args[@]}"
