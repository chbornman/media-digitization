#!/usr/bin/env bash
# split.sh — detect scenes in a tape master and split into per-scene MKV files.
# Run on bornmanserver (direct), or on margo via sshfs mount — auto-detects path.
# margo is ~2× faster (9950X vs 4790K). Both need scenedetect + av installed:
#   pip install --user --break-system-packages 'scenedetect[opencv]' av
#
# Usage:  ./scripts/split.sh <tape_num>
#         e.g. ./scripts/split.sh 02
#
# Override the data root with env var TAPE_DIG_ROOT if needed.

set -euo pipefail

TAPE="${1:?Usage: $0 <tape_num like 02>}"

if [ -z "${TAPE_DIG_ROOT:-}" ]; then
  for c in \
      "/HomeNAS/Videos/tape-digitization" \
      "$HOME/mnt/bornman/Videos/tape-digitization"; do
    if [ -d "$c" ]; then TAPE_DIG_ROOT="$c"; break; fi
  done
fi
[ -z "${TAPE_DIG_ROOT:-}" ] && { echo "ERROR: data root not found; set TAPE_DIG_ROOT or mount sshfs" >&2; exit 1; }

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
