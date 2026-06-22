#!/usr/bin/env bash
# transcode-all.sh — batch-transcode EVERY ripped disc under the data root.
#
# This is the "do it later on the fast machine" step. Rip discs on the box with
# the optical drive (rip-disc.sh, which no longer transcodes by default), then
# run this wherever you have the most horsepower — e.g. a desktop with an NVENC
# GPU, pointed at the same storage (locally or over an sshfs/NFS mount).
#
# It walks $CD_DIG_ROOT/discs/*/, and for each one with a videos/ folder runs
# transcode-disc.sh. Resume-safe: discs already fully transcoded are skipped,
# and partially-done ones pick up where they left off.
#
# Usage:  ./transcode-all.sh [jobs]
#         e.g. ./transcode-all.sh 8                 (8 parallel encodes)
#         e.g. CD_DIG_ROOT=/mnt/nas/cd-digitization ./transcode-all.sh 8
#         e.g. ENCODER=nvenc ./transcode-all.sh 8   (force NVENC)
#
# Data root defaults to the current directory; override with CD_DIG_ROOT.

set -euo pipefail

JOBS="${1:-3}"
ROOT="${CD_DIG_ROOT:-$PWD}"
DISCS="$ROOT/discs"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -d "$DISCS" ] || { echo "ERROR: no 'discs/' under $ROOT — cd to your data root or set CD_DIG_ROOT" >&2; exit 1; }

shopt -s nullglob
folders=("$DISCS"/*/)
[ "${#folders[@]}" -eq 0 ] && { echo "No disc folders in $DISCS — nothing to do."; exit 0; }

echo "Batch transcoding ${#folders[@]} disc folder(s) under $DISCS  ($JOBS parallel each)"
echo

fail=0
for d in "${folders[@]}"; do
  [ -d "$d/videos" ] || { echo "skip (no videos/): $(basename "$d")"; continue; }
  echo "=== $(basename "$d") ==="
  "$SCRIPT_DIR/transcode-disc.sh" "$d" "$JOBS" || fail=1
  echo
done

if [ "$fail" -ne 0 ]; then
  echo "BATCH DONE WITH FAILURES — re-run to retry the ones that failed (resume-safe)."
  exit 1
fi
echo "BATCH DONE — all discs transcoded."
