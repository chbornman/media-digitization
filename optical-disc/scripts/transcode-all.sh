#!/usr/bin/env bash
# transcode-all.sh — batch-transcode EVERY ripped disc under the data root,
# running multiple DISCS concurrently.
#
# This is the "do it later on the fast machine" step. Rip discs on the box with
# the optical drive (rip-disc.sh, which no longer transcodes by default), then
# run this wherever you have the most horsepower — e.g. a desktop with an NVENC
# GPU, pointed at the same storage (locally or over an sshfs/NFS mount).
#
# It walks $CD_DIG_ROOT/discs/*/ and transcodes each disc's videos/ -> mp4/.
# Resume-safe: finished discs are skipped, partial ones pick up where they left
# off (output is written atomically, so an interrupted run never leaves a
# partial that looks "done").
#
# WHY disc-level parallelism: each disc is usually one big main title plus a few
# tiny stub clips, so parallelizing *within* a disc barely helps — at any moment
# it's ~1 real stream. NVENC finishes SD instantly and sits idle. To actually
# use the machine you run several DISCS at once. The per-disc decode + bwdif
# deinterlace are CPU-bound and single-threaded-ish, so throughput scales with
# how many discs you run in parallel, until you run out of CPU cores.
#
# Usage:  ./transcode-all.sh [discs_in_parallel] [jobs_within_each_disc]
#         e.g. ./transcode-all.sh 12              (12 discs at once — main knob)
#         e.g. ./transcode-all.sh 16 2            (16 discs, 2 encodes each)
#         e.g. CD_DIG_ROOT=/mnt/nas/cd-digitization ./transcode-all.sh 12
#         e.g. ENCODER=nvenc ./transcode-all.sh 12
#
# Rule of thumb: set discs_in_parallel near your CPU thread count (the limiter
# is bwdif, not the GPU). On a 16-core/32-thread box, 12-16 is a good start.
#
# Data root defaults to the current directory; override with CD_DIG_ROOT.

set -euo pipefail

DISC_PAR="${1:-6}"      # how many discs to transcode at once (main throughput knob)
PER_DISC="${2:-2}"      # parallel encodes within a single disc
ROOT="${CD_DIG_ROOT:-$PWD}"
DISCS="$ROOT/discs"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -d "$DISCS" ] || { echo "ERROR: no 'discs/' under $ROOT — cd to your data root or set CD_DIG_ROOT" >&2; exit 1; }

shopt -s nullglob
# only folders that actually contain a videos/ dir (skips _duplicates, etc.)
folders=()
for d in "$DISCS"/*/; do [ -d "$d/videos" ] && folders+=("$d"); done
[ "${#folders[@]}" -eq 0 ] && { echo "No disc folders with videos/ in $DISCS — nothing to do."; exit 0; }

echo "Batch transcoding ${#folders[@]} disc(s) under $DISCS"
echo "  $DISC_PAR discs in parallel x up to $PER_DISC encode(s) each"
echo

# Run discs concurrently. Each transcode-disc.sh is resume-safe and reports its
# own failures; don't let one failure abort the whole sweep.
printf '%s\0' "${folders[@]}" | \
  xargs -0 -P "$DISC_PAR" -I {} "$SCRIPT_DIR/transcode-disc.sh" {} "$PER_DISC" || true

# Summary: a disc is "done" when every file in videos/ has a matching mp4.
done_cnt=0; pending=0
for d in "${folders[@]}"; do
  nvid=$(find "$d/videos" -maxdepth 1 -type f | wc -l)
  nmp4=$(find "$d/mp4" -maxdepth 1 -name '*.mp4' 2>/dev/null | wc -l)
  if [ "$nmp4" -ge "$nvid" ] && [ "$nvid" -gt 0 ]; then done_cnt=$((done_cnt+1)); else pending=$((pending+1)); fi
done
echo
if [ "$pending" -gt 0 ]; then
  echo "BATCH DONE WITH $pending disc(s) INCOMPLETE — re-run to retry (resume-safe). $done_cnt complete."
  exit 1
fi
echo "BATCH DONE — all $done_cnt discs transcoded."
