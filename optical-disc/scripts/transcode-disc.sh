#!/usr/bin/env bash
# transcode-disc.sh — make a viewable H.264 MP4 of every separated video in ONE
# disc folder. Resume-safe and parallel. This is a separate step from ripping:
# rip on the machine with the optical drive, then transcode wherever you have
# the most horsepower (e.g. a box with an NVENC GPU).
#
# Source of truth is videos/ (the separated originals). Output goes to mp4/.
# Auto-detects interlacing per file and deinterlaces (bwdif) only when needed.
#
# Encoder is auto-selected:
#   * h264_nvenc if your ffmpeg has it (fast — use this on the GPU box)
#   * libx264    otherwise (CPU; fine for SD but much slower)
# Force it with ENCODER=nvenc or ENCODER=cpu.
#
# Usage:  ./transcode-disc.sh <disc_folder> [jobs]
#         e.g. ./transcode-disc.sh discs/2026-06-22_143005_disc-label 6
#         e.g. ENCODER=nvenc ./transcode-disc.sh <folder> 8
#
# To batch every disc at once, use transcode-all.sh instead.

set -euo pipefail

DISC="${1:?Usage: $0 <disc_folder> [jobs]}"
JOBS="${2:-3}"
SRC="$DISC/videos"
DST="$DISC/mp4"

[ -d "$SRC" ] || { echo "ERROR: $SRC not found" >&2; exit 1; }
mkdir -p "$DST"

# ---- pick the encoder -------------------------------------------------------
ENC="${ENCODER:-auto}"
if [ "$ENC" = "auto" ]; then
  # NOTE: capture to a var and match with `case` — do NOT pipe into `grep -q`.
  # `grep -q` exits on first match and closes the pipe, ffmpeg then dies of
  # SIGPIPE, and under `set -o pipefail` that makes the check falsely report
  # "no nvenc" → silent CPU fallback even when NVENC is present.
  enc_list="$(ffmpeg -hide_banner -encoders 2>/dev/null || true)"
  case "$enc_list" in
    *h264_nvenc*) ENC="nvenc" ;;
    *)            ENC="cpu" ;;
  esac
fi
export ENC

total=$(find "$SRC" -maxdepth 1 -type f | wc -l)
[ "$total" -eq 0 ] && { echo "No videos in $SRC — nothing to transcode."; exit 0; }
echo "Transcoding $total video(s) from $SRC -> $DST  (encoder=$ENC, $JOBS parallel)"

export DST

encode_one() {
  local f="$1"
  local base; base="$(basename "${f%.*}")"
  local out="$DST/${base}.mp4"
  local tmp="$DST/.${base}.partial.mp4"
  [ -s "$out" ] && return 0          # resume-safe: only a finished file counts
  rm -f "$out" "$tmp"                # clear any stale partial from an interrupted run
  local errlog="$DST/.${base}.err"

  # Detect interlacing: sample ~200 frames with idet, deinterlace only if so.
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

  # Encoder-specific video options.
  local venc
  if [ "$ENC" = "nvenc" ]; then
    venc="-c:v h264_nvenc -preset p7 -tune hq -rc vbr -cq 19 -b:v 0 \
          -profile:v high -spatial-aq 1 -temporal-aq 1 -rc-lookahead 32"
  else
    venc="-c:v libx264 -preset slow -crf 18"
  fi

  local rc=0
  # shellcheck disable=SC2086
  # Encode to a temp file, then atomically rename on success — so an
  # interrupted run never leaves a partial file that looks "done" on resume.
  ffmpeg -nostdin -y -i "$f" \
        -vf "$vf" $venc -pix_fmt yuv420p \
        -c:a aac -b:a 192k -movflags +faststart \
        "$tmp" 2>"$errlog" || rc=$?
  if [ $rc -eq 0 ] && [ -s "$tmp" ]; then
    mv -f "$tmp" "$out"; rm -f "$errlog"; echo "done: $(basename "$out")"
  else
    rm -f "$tmp"; echo "FAILED: $(basename "$f") (exit $rc) — see $errlog" >&2; return 1
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
