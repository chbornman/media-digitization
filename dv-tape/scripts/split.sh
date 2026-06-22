#!/usr/bin/env bash
# split.sh — detect scenes in a tape master and split into per-scene MKV files.
# Needs scenedetect + av installed:
#   pip install --user --break-system-packages 'scenedetect[opencv]' av
#
# Usage:  ./scripts/split.sh <tape_num>
#         e.g. ./scripts/split.sh 02
#
# Data layout (under the data root): masters/tapeNN/*.dv  ->  scenes/tapeNN/
# Data root defaults to the current directory; override with TAPE_DIG_ROOT.

set -euo pipefail

TAPE="${1:?Usage: $0 <tape_num like 02>}"

TAPE_DIG_ROOT="${TAPE_DIG_ROOT:-$PWD}"
[ -d "$TAPE_DIG_ROOT/masters" ] || { echo "ERROR: no 'masters/' under $TAPE_DIG_ROOT — cd to your data root or set TAPE_DIG_ROOT" >&2; exit 1; }

MASTER_DIR="$TAPE_DIG_ROOT/masters/tape$TAPE"
SCENE_DIR="$TAPE_DIG_ROOT/scenes/tape$TAPE"

MASTER=$(ls "$MASTER_DIR"/*.dv 2>/dev/null | head -1)
[ -z "$MASTER" ] && { echo "ERROR: no .dv file in $MASTER_DIR" >&2; exit 1; }

mkdir -p "$SCENE_DIR"

echo "Splitting:  $MASTER"
echo "Output:     $SCENE_DIR/tape$TAPE-scene-*.mkv"
echo "Expect ~14 min detection + ~5 min split for a 2-hour tape."
echo

scenedetect -i "$MASTER" \
    -b pyav \
    -o "$SCENE_DIR" \
    detect-content \
    list-scenes \
    split-video --copy --filename "tape$TAPE-scene-\$SCENE_NUMBER.mkv"

n=$(ls "$SCENE_DIR"/tape$TAPE-scene-*.mkv 2>/dev/null | wc -l)
echo
echo "DONE — $n scenes in $SCENE_DIR"
