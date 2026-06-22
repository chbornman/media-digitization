#!/usr/bin/env bash
# transcode.sh — NVENC-encode all per-scene MKVs of a tape to H.264 MP4,
# in parallel. Run on margo (5080) via sshfs mount, or anywhere with
# h264_nvenc available.
#
# Usage:  ./scripts/transcode.sh <tape_num> [jobs]
#         e.g. ./scripts/transcode.sh 02         (default 4 parallel jobs)
#         e.g. ./scripts/transcode.sh 02 8       (8 parallel jobs)
#
# Auto-detects data root: /HomeNAS/Videos/tape-digitization (direct on
# bornmanserver) or $HOME/mnt/bornman/Videos/tape-digitization (margo via
# sshfs). Override with TAPE_DIG_ROOT env var.
#
# bwdif (CPU) is the per-process bottleneck — each ffmpeg saturates ~1 thread.
# NVENC ASIC on Blackwell handles many simultaneous sessions, so parallel
# ffmpeg processes scale roughly linearly until CPU threads run out.

set -euo pipefail

TAPE="${1:?Usage: $0 <tape_num like 02> [jobs]}"
JOBS="${2:-4}"

if [ -z "${TAPE_DIG_ROOT:-}" ]; then
  for c in \
      "/HomeNAS/Videos/tape-digitization" \
      "$HOME/mnt/bornman/Videos/tape-digitization"; do
    if [ -d "$c" ]; then TAPE_DIG_ROOT="$c"; break; fi
  done
fi
[ -z "${TAPE_DIG_ROOT:-}" ] && { echo "ERROR: data root not found; set TAPE_DIG_ROOT or mount sshfs" >&2; exit 1; }

SCENE_DIR="$TAPE_DIG_ROOT/scenes/tape$TAPE"
FINAL_DIR="$TAPE_DIG_ROOT/final/tape$TAPE"

[ -d "$SCENE_DIR" ] || { echo "ERROR: $SCENE_DIR not found" >&2; exit 1; }
mkdir -p "$FINAL_DIR"

total=$(ls "$SCENE_DIR"/tape$TAPE-scene-*.mkv 2>/dev/null | wc -l)
echo "Transcoding:  $SCENE_DIR/tape$TAPE-scene-*.mkv  ($total scenes)"
echo "Output:       $FINAL_DIR/tape$TAPE-scene-*.mp4"
echo "Parallelism:  $JOBS concurrent ffmpeg processes (NVENC)"
echo

export FINAL_DIR

encode_one() {
  local f="$1"
  local out="$FINAL_DIR/$(basename "${f%.mkv}").mp4"
  # resume-safe only when the existing file is non-empty (zero-byte means a
  # previous failed run left a stub from ffmpeg's -y; treat as missing)
  if [ -s "$out" ]; then return 0; fi
  rm -f "$out"
  local errlog="$FINAL_DIR/.$(basename "$out").err"
  local rc=0
  ffmpeg -y -i "$f" \
        -vf "bwdif=mode=1:parity=1,format=yuv420p,setparams=color_primaries=smpte170m:color_trc=smpte170m:colorspace=smpte170m,format=yuv420p" \
        -c:v h264_nvenc -preset p7 -tune hq -rc vbr -cq 19 -b:v 0 \
        -profile:v high -spatial-aq 1 -temporal-aq 1 -rc-lookahead 32 \
        -color_primaries smpte170m -color_trc smpte170m -colorspace smpte170m \
        -c:a aac -b:a 192k -movflags +faststart \
        "$out" 2>"$errlog" || rc=$?
  if [ $rc -eq 0 ] && [ -s "$out" ]; then
    rm -f "$errlog"
    echo "done: $(basename "$out")"
  else
    rm -f "$out"
    echo "FAILED: $(basename "$f") (ffmpeg exit $rc) — see $errlog" >&2
    return 1
  fi
}
export -f encode_one

# Don't let xargs's non-zero exit kill the script via set -e — we want to
# always reach the summary below so the user sees the failure count.
ls "$SCENE_DIR"/tape$TAPE-scene-*.mkv | \
  xargs -P "$JOBS" -I {} bash -c 'encode_one "$@"' _ {} || true

n=$(ls "$FINAL_DIR"/*.mp4 2>/dev/null | wc -l)
echo
if [ "$n" -lt "$total" ]; then
  echo "DONE WITH FAILURES — $n of $total transcoded ($((total - n)) failed)"
  echo "Re-run the same command to retry just the failed ones (resume-safe)."
  echo "Inspect failure details: ls -la $FINAL_DIR/.*.err"
  exit 1
else
  echo "DONE — $n of $total transcoded"
fi
