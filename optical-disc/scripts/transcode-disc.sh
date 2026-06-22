#!/usr/bin/env bash
# transcode-disc.sh — make a viewable H.264 MP4 of every separated video in a
# disc folder. Resume-safe and parallel, mirroring the tape pipeline.
#
# Source of truth is videos/ (the separated originals). Output goes to mp4/.
# Auto-detects interlacing per file and deinterlaces only when needed (home
# camcorder SD is usually interlaced; VCD MPEG-1 is usually progressive).
#
# Usage:  ./transcode-disc.sh <disc_folder> [jobs]
#         e.g. ./transcode-disc.sh discs/2026-06-22_143005_disc-label 3
#
# Uses CPU x264 — SD home-video content transcodes fast on CPU, and it has no
# GPU dependency, so it runs anywhere. If you have an NVENC GPU and want to
# offload, the per-file ffmpeg call below is the only thing you'd swap.

set -euo pipefail

DISC="${1:?Usage: $0 <disc_folder> [jobs]}"
JOBS="${2:-3}"
SRC="$DISC/videos"
DST="$DISC/mp4"

[ -d "$SRC" ] || { echo "ERROR: $SRC not found" >&2; exit 1; }
mkdir -p "$DST"

total=$(find "$SRC" -maxdepth 1 -type f | wc -l)
[ "$total" -eq 0 ] && { echo "No videos in $SRC — nothing to transcode."; exit 0; }
echo "Transcoding $total video(s) from $SRC -> $DST  ($JOBS parallel)"

export DST

encode_one() {
  local f="$1"
  local base; base="$(basename "${f%.*}")"
  local out="$DST/${base}.mp4"
  [ -s "$out" ] && return 0          # resume-safe
  rm -f "$out"
  local errlog="$DST/.${base}.err"

  # Detect interlacing: sample ~200 frames with idet.
  local idet; idet="$(ffmpeg -nostdin -hide_banner -filter:v idet -frames:v 200 \
                       -an -f null - -i "$f" 2>&1 || true)"
  local tff bff prog
  tff=$(printf '%s' "$idet" | grep -oiE 'TFF: *[0-9]+' | grep -oE '[0-9]+' | paste -sd+ | bc 2>/dev/null || echo 0)
  bff=$(printf '%s' "$idet" | grep -oiE 'BFF: *[0-9]+' | grep -oE '[0-9]+' | paste -sd+ | bc 2>/dev/null || echo 0)
  prog=$(printf '%s' "$idet" | grep -oiE 'Progressive: *[0-9]+' | grep -oE '[0-9]+' | paste -sd+ | bc 2>/dev/null || echo 0)
  local vf="format=yuv420p"
  if [ "$(( ${tff:-0} + ${bff:-0} ))" -gt "${prog:-0}" ]; then
    vf="bwdif=mode=1,format=yuv420p"   # interlaced -> deinterlace
  fi

  local rc=0
  ffmpeg -nostdin -y -i "$f" \
        -vf "$vf" \
        -c:v libx264 -preset slow -crf 18 -pix_fmt yuv420p \
        -c:a aac -b:a 192k -movflags +faststart \
        "$out" 2>"$errlog" || rc=$?
  if [ $rc -eq 0 ] && [ -s "$out" ]; then
    rm -f "$errlog"; echo "done: $(basename "$out")"
  else
    rm -f "$out"; echo "FAILED: $(basename "$f") (exit $rc) — see $errlog" >&2; return 1
  fi
}
export -f encode_one

find "$SRC" -maxdepth 1 -type f -print0 | \
  xargs -0 -P "$JOBS" -I {} bash -c 'encode_one "$@"' _ {} || true

n=$(ls "$DST"/*.mp4 2>/dev/null | wc -l)
echo
if [ "$n" -lt "$total" ]; then
  echo "DONE WITH FAILURES — $n of $total ($((total-n)) failed). Re-run to retry."
  exit 1
else
  echo "DONE — $n of $total transcoded"
fi
