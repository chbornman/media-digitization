#!/usr/bin/env bash
# rip-disc.sh — one-command optical-disc archiver for the wife's-family CDs.
#
# Pop in a CD/DVD, run this, walk away. You get a timestamped folder holding:
#   * master.iso        — bit-exact image of the disc (the preserved master)
#   * master.map        — ddrescue map: exactly which sectors read cleanly
#   * files/            — every original file, names + timestamps preserved
#   * videos/           — each individual video, separated (VCD seqs, DVD
#                         titles, or copied straight from files/)
#   * mp4/              — H.264 MP4 of each video for easy viewing (Jellyfin)
#   * metadata/         — EVERYTHING: ISO volume dates, per-file ffprobe +
#                         exiftool, disc/track layout, sha256 of the master
#   * disc-info.json    — the consolidated machine-readable summary
#   * notes.md          — your typed notes (CD-case label, etc.)
#
# Auto-detects DVD-Video / Video-CD(SVCD) / plain data discs. Ejects at the
# end so you can immediately drop in the next one.
#
# Usage:
#   ./rip-disc.sh                       interactive: opens $EDITOR for notes
#   ./rip-disc.sh --note "Box 1, 1998 birthday + beach"   notes from CLI
#   ./rip-disc.sh --no-transcode        skip the MP4 step (do it later)
#   ./rip-disc.sh --no-eject            leave the disc in
#   ./rip-disc.sh --dev /dev/sr1        use a different drive
#
# Env overrides:  DISC_DEV=/dev/sr0   CD_DIG_ROOT=/HomeNAS/Videos/cd-digitization

set -euo pipefail

# ---- config / flags ---------------------------------------------------------
DEV="${DISC_DEV:-/dev/sr0}"
ROOT="${CD_DIG_ROOT:-/HomeNAS/Videos/cd-digitization}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTE=""
NOTE_SET=0
DO_TRANSCODE=1
DO_EJECT=1

while [ $# -gt 0 ]; do
  case "$1" in
    --note) NOTE="${2:-}"; NOTE_SET=1; shift 2;;
    --no-transcode) DO_TRANSCODE=0; shift;;
    --no-eject) DO_EJECT=0; shift;;
    --dev) DEV="$2"; shift 2;;
    -h|--help) sed -n '2,30p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[err]\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---- preflight --------------------------------------------------------------
[ -r "$DEV" ] || die "$DEV not readable. In the 'cdrom' group? Is the device right?"

# Wait for a disc to be present and spun up.
log "Waiting for disc in $DEV ..."
for i in $(seq 1 60); do
  if blkid -p "$DEV" >/dev/null 2>&1 || [ "$(blockdev --getsize64 "$DEV" 2>/dev/null || echo 0)" -gt 0 ]; then
    break
  fi
  sleep 1
  [ "$i" = 60 ] && die "No readable medium in $DEV after 60s."
done
sleep 2  # let the drive settle / report final geometry

# ---- identify ---------------------------------------------------------------
LABEL_RAW="$(blkid -p -s LABEL -o value "$DEV" 2>/dev/null || true)"
FSTYPE="$(blkid -p -s TYPE -o value "$DEV" 2>/dev/null || true)"
# slugify the label for the folder name; fall back to 'disc'
SLUG="$(printf '%s' "${LABEL_RAW:-disc}" | tr '[:upper:]' '[:lower:]' \
        | tr -c 'a-z0-9' '-' | sed -E 's/-+/-/g; s/^-|-$//g')"
[ -z "$SLUG" ] && SLUG="disc"
STAMP="$(date +%Y-%m-%d_%H%M%S)"
OUT="$ROOT/discs/${STAMP}_${SLUG}"
mkdir -p "$OUT"/{files,videos,mp4,metadata}
log "Output folder: $OUT"
log "Disc label: ${LABEL_RAW:-(none)}   fs: ${FSTYPE:-unknown}"

# ---- 1. image the disc (the master) ----------------------------------------
ISO="$OUT/master.iso"
MAP="$OUT/master.map"
log "Imaging disc -> master.iso (this is the preserved master)"
if have ddrescue; then
  # Pass 1: fast copy of all good sectors. Pass 2: scrape the rest harder.
  # The mapfile makes it resumable and records read fidelity per sector.
  ddrescue -b 2048 -n "$DEV" "$ISO" "$MAP" || warn "ddrescue pass 1 had errors"
  ddrescue -b 2048 -d -r2 "$DEV" "$ISO" "$MAP" || warn "ddrescue scrape had errors"
else
  warn "ddrescue not installed — falling back to dd (no bad-sector recovery)."
  warn "For aging discs, install it:  sudo apt install gddrescue"
  dd if="$DEV" of="$ISO" bs=2048 conv=noerror,sync status=progress || \
    warn "dd reported read errors; master may have gaps"
fi
[ -s "$ISO" ] || die "Imaging produced an empty file; disc unreadable."
ISO_SHA="$(sha256sum "$ISO" | awk '{print $1}')"
ISO_BYTES="$(stat -c %s "$ISO")"
log "Master written: $(numfmt --to=iec "$ISO_BYTES" 2>/dev/null || echo "$ISO_BYTES bytes")  sha256=${ISO_SHA:0:16}..."

# ---- 2. deep metadata from the image ---------------------------------------
log "Extracting volume metadata (dates, publisher, etc.)"
ISO_META="$(python3 "$SCRIPT_DIR/parse_iso_meta.py" "$ISO" 2>/dev/null || echo '{}')"
echo "$ISO_META" > "$OUT/metadata/iso-volume.json"

# full raw probes of the disc/drive for provenance
udevadm info --query=property --name="$DEV" > "$OUT/metadata/udev.properties" 2>/dev/null || true
blkid -p "$DEV" > "$OUT/metadata/blkid.txt" 2>/dev/null || true
have cd-info && cd-info "$DEV" > "$OUT/metadata/cd-info.txt" 2>/dev/null || true
have isoinfo && isoinfo -d -i "$ISO" > "$OUT/metadata/isoinfo.txt" 2>/dev/null || true

# ---- 3. list contents & classify -------------------------------------------
# List the ISO filesystem without mounting (xorriso osirrox).
FILELIST="$OUT/metadata/filelist.txt"
if have xorriso; then
  xorriso -indev "$ISO" -find / -exec lsdl 2>/dev/null > "$FILELIST" || \
    xorriso -indev "$ISO" -find / 2>/dev/null > "$FILELIST" || true
fi

DISC_TYPE="data"
if xorriso -indev "$ISO" -find /VIDEO_TS >/dev/null 2>&1 && \
   xorriso -indev "$ISO" -ls /VIDEO_TS 2>/dev/null | grep -qi 'VTS_.*VOB\|VIDEO_TS.VOB'; then
  DISC_TYPE="dvd-video"
elif xorriso -indev "$ISO" -ls /MPEGAV 2>/dev/null | grep -qi 'AVSEQ\|.DAT' ; then
  DISC_TYPE="vcd"
elif xorriso -indev "$ISO" -ls /SVCD /MPEG2 2>/dev/null | grep -qi 'AVSEQ\|.DAT' ; then
  DISC_TYPE="svcd"
fi
log "Detected disc type: $DISC_TYPE"

# ---- 4. extract original files (preserve names + timestamps) ----------------
if have xorriso; then
  log "Extracting all original files -> files/"
  # -osirrox on; restore whole tree, keeping ISO timestamps on the copies.
  xorriso -osirrox on:auto_chmod_on \
          -indev "$ISO" \
          -extract / "$OUT/files" 2>"$OUT/metadata/xorriso-extract.log" || \
    warn "xorriso extraction reported issues (see metadata/xorriso-extract.log)"
else
  warn "xorriso not installed — cannot extract files. Install:  sudo apt install xorriso"
fi

# ---- 5. separate each individual video -------------------------------------
log "Separating individual videos -> videos/"
shopt -s nullglob nocaseglob
case "$DISC_TYPE" in
  dvd-video)
    # One output per DVD title: concat that title's VOB parts in order.
    VTS_DIR="$OUT/files/VIDEO_TS"
    if [ -d "$VTS_DIR" ]; then
      for ts in $(ls "$VTS_DIR"/VTS_*_1.VOB 2>/dev/null | sed -E 's/.*VTS_([0-9]+)_1\.VOB/\1/' | sort -u); do
        parts=$(ls "$VTS_DIR"/VTS_${ts}_[1-9].VOB 2>/dev/null | sort -V)
        [ -z "$parts" ] && continue
        out="$OUT/videos/title_${ts}.vob"
        cat $parts > "$out"
        log "  title $ts -> $(basename "$out")"
      done
    fi
    ;;
  vcd|svcd)
    if have vcdxrip; then
      ( cd "$OUT/videos" && vcdxrip --bin-file - --no-ext-psd >/dev/null 2>&1 || true )
      # vcdxrip works off the device/image; if it produced nothing, fall through
    fi
    # Fallback / primary: the .DAT files extracted into files/ are MPEG-PS.
    # Remux each separately so they play and keep timing.
    for dat in "$OUT/files"/MPEGAV/*.DAT "$OUT/files"/SVCD/*.DAT "$OUT/files"/MPEG2/*.DAT; do
      [ -e "$dat" ] || continue
      base="$(basename "${dat%.*}")"
      out="$OUT/videos/${base}.mpg"
      [ -e "$out" ] && continue
      ffmpeg -nostdin -loglevel error -i "$dat" -c copy "$out" 2>/dev/null \
        || cp "$dat" "$out"
      log "  $(basename "$dat") -> $(basename "$out")"
    done
    ;;
  *)
    # Data disc: copy each recognized video file out, keeping it separate.
    while IFS= read -r -d '' vid; do
      rel="${vid#"$OUT/files/"}"
      flat="$(printf '%s' "$rel" | tr '/' '_')"
      cp -p "$vid" "$OUT/videos/$flat"
      log "  $rel"
    done < <(find "$OUT/files" -type f \
              -iregex '.*\.\(mp4\|mov\|avi\|mpg\|mpeg\|m2ts\|mts\|vob\|wmv\|mkv\|m4v\|3gp\|dv\|flv\|divx\)$' \
              -print0 2>/dev/null)
    ;;
esac
shopt -u nullglob nocaseglob

VID_COUNT=$(find "$OUT/videos" -type f | wc -l)
log "Separated $VID_COUNT video file(s)."

# ---- 6. per-video technical metadata (every bit we can get) -----------------
log "Probing each video (ffprobe + exiftool)"
mkdir -p "$OUT/metadata/videos"
for v in "$OUT/videos"/*; do
  [ -f "$v" ] || continue
  b="$(basename "$v")"
  ffprobe -v quiet -print_format json -show_format -show_streams -show_chapters \
          "$v" > "$OUT/metadata/videos/${b}.ffprobe.json" 2>/dev/null || true
  have exiftool && exiftool -j -G "$v" > "$OUT/metadata/videos/${b}.exiftool.json" 2>/dev/null || true
done

# ---- 7. consolidated disc-info.json ----------------------------------------
log "Writing disc-info.json"
python3 - "$OUT" "$DEV" "$DISC_TYPE" "$ISO_SHA" "$ISO_BYTES" "$LABEL_RAW" "$FSTYPE" "$STAMP" <<'PY'
import json, os, sys, glob
out, dev, dtype, sha, ibytes, label, fstype, stamp = sys.argv[1:9]
meta_dir = os.path.join(out, "metadata")
def load(p, default):
    try:
        with open(p) as f: return json.load(f)
    except Exception: return default
iso_vol = load(os.path.join(meta_dir, "iso-volume.json"), {})
videos = []
for fp in sorted(glob.glob(os.path.join(out, "videos", "*"))):
    if not os.path.isfile(fp): continue
    b = os.path.basename(fp)
    pf = load(os.path.join(meta_dir, "videos", b + ".ffprobe.json"), {})
    fmt = pf.get("format", {}) if isinstance(pf, dict) else {}
    vstream = next((s for s in pf.get("streams", []) if s.get("codec_type")=="video"), {}) if isinstance(pf, dict) else {}
    videos.append({
        "file": b,
        "size_bytes": os.path.getsize(fp),
        "duration_s": fmt.get("duration"),
        "format": fmt.get("format_long_name"),
        "video_codec": vstream.get("codec_name"),
        "width": vstream.get("width"),
        "height": vstream.get("height"),
        "fps": vstream.get("avg_frame_rate"),
        "embedded_creation_time": (fmt.get("tags", {}) or {}).get("creation_time"),
    })
# pull the most useful date out of the volume metadata
prim = iso_vol.get("primary") or {}
joli = iso_vol.get("joliet") or {}
burn_date = prim.get("volume_creation") or joli.get("volume_creation")
summary = {
    "captured_at": stamp,
    "device": dev,
    "disc_type": dtype,
    "fs_label": label or None,
    "fs_type": fstype or None,
    "burn_date_guess": burn_date,
    "master_iso": {"sha256": sha, "size_bytes": int(ibytes)},
    "iso_volume_metadata": iso_vol,
    "video_count": len(videos),
    "videos": videos,
}
with open(os.path.join(out, "disc-info.json"), "w") as f:
    json.dump(summary, f, indent=2, ensure_ascii=False)
# human-readable headline
print(f"  burn-date guess: {burn_date or 'unknown'}")
print(f"  videos: {len(videos)}")
PY

# ---- 8. notes ---------------------------------------------------------------
NOTES_FILE="$OUT/notes.md"
BURN_DATE="$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d.get("burn_date_guess") or "")' "$OUT/disc-info.json" 2>/dev/null || true)"
{
  echo "# Disc notes"
  echo
  echo "- Captured: $STAMP"
  echo "- Disc label (from filesystem): ${LABEL_RAW:-（none）}"
  echo "- Burn-date guess (ISO volume creation): ${BURN_DATE:-unknown}"
  echo "- Disc type: $DISC_TYPE"
  echo "- Videos found: $VID_COUNT"
  echo
  echo "## Notes from the CD case / label (type below)"
  echo
  echo "${NOTE}"
} > "$NOTES_FILE"

if [ "$NOTE_SET" = 0 ]; then
  if [ -t 0 ] && [ -t 1 ]; then
    EDITOR_BIN="${EDITOR:-${VISUAL:-nano}}"
    log "Opening $EDITOR_BIN for you to type the CD-case notes (save & close when done)..."
    "$EDITOR_BIN" "$NOTES_FILE" </dev/tty >/dev/tty 2>&1 || warn "editor exited non-zero"
  else
    warn "No TTY for notes. Add them later by editing: $NOTES_FILE  (or use --note)"
  fi
fi

# ---- 9. transcode to MP4 ----------------------------------------------------
if [ "$DO_TRANSCODE" = 1 ]; then
  log "Transcoding videos -> mp4/ (H.264, for easy viewing)"
  "$SCRIPT_DIR/transcode-disc.sh" "$OUT" || warn "transcode step had failures (re-run transcode-disc.sh $OUT)"
else
  log "Skipping transcode (--no-transcode). Run later:  scripts/transcode-disc.sh \"$OUT\""
fi

# ---- 10. done ---------------------------------------------------------------
if [ "$DO_EJECT" = 1 ]; then
  eject "$DEV" 2>/dev/null && log "Ejected. Pop in the next disc and run again." || warn "eject failed"
fi

ALL_FILES=$(find "$OUT/files" -type f 2>/dev/null | wc -l)
NONVID=$(( ALL_FILES - VID_COUNT ))
[ "$NONVID" -lt 0 ] && NONVID=0
echo
log "FINISHED: $OUT"
echo "    master.iso  ($(numfmt --to=iec "$ISO_BYTES" 2>/dev/null || echo "$ISO_BYTES")) — complete bit-exact disc image"
echo "    files/      ($ALL_FILES total files of ALL types preserved)"
echo "    videos/     ($VID_COUNT separated videos)"
echo "    mp4/        ($(ls "$OUT/mp4"/*.mp4 2>/dev/null | wc -l) transcoded)"
echo "    disc-info.json, metadata/, notes.md"
if [ "$NONVID" -gt 0 ]; then
  log "Note: $NONVID non-video file(s) were also found and kept in files/:"
  find "$OUT/files" -type f \
    ! -iregex '.*\.\(mp4\|mov\|avi\|mpg\|mpeg\|m2ts\|mts\|vob\|wmv\|mkv\|m4v\|3gp\|dv\|flv\|divx\|dat\)$' \
    2>/dev/null | sed "s#^$OUT/files/#      #" | head -40
fi
