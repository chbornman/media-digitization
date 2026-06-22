# optical-disc

One-command archival of CDs/DVDs — built to digitize a stack of old family
home-video discs. Sister workflow to [`../dv-tape`](../dv-tape), same
philosophy: **keep a pristine master, derive usable files, capture all the
metadata, verify.**

Output lands in a `discs/` folder under the current directory by default; set
`CD_DIG_ROOT` to send archives somewhere with more room (a NAS, external drive).

The tape project captured DV over FireWire, scene-split, and NVENC-transcoded.
Optical discs are different — the disc *is* already a digital master and the
videos are already separate files — so the pipeline is simpler:

```
  insert disc
      │
      ▼
  rip-disc.sh ──┐
      │         ├─ 0. PROMPT YOU FOR CASE NOTES        → notes.md   (before the rip)
      │         │      (editor opens; type, save & close to start ripping)
      │         ├─ 1. image the whole disc            → master.iso  (+ .map)
      │         ├─ 2. read ISO9660/Joliet volume meta → metadata/iso-volume.json
      │         ├─ 3. detect type (DVD-Video / VCD / SVCD / data)
      │         ├─ 4. extract every original file      → files/   (timestamps kept)
      │         ├─ 5. separate each video              → videos/
      │         ├─ 6. probe each video (ffprobe+exif)  → metadata/videos/
      │         ├─ 7. consolidate                      → disc-info.json
      │         └─ 8. append auto-detected facts        → notes.md
      ▼
  eject  →  "pop in the next disc"
```

> Notes come **first**, on purpose: the editor opens before the slow rip, so you
> can read the disc/case and type the right details, then save & close and walk
> away while it rips unattended. Auto-detected facts (burn date, disc type,
> video count) are appended to your notes afterward.

## Two steps, on purpose

Ripping and transcoding are **separate steps** so you can rip a whole stack of
discs quickly on the machine with the optical drive, then transcode them all in
one batch on whatever box is fastest (ideally one with an NVENC GPU).

**Step 1 — rip (on the machine with the drive).** Fast: image + extract +
metadata + notes. No transcoding by default.

```
cd optical-disc
./scripts/rip-disc.sh
```

Insert a disc and run that. The editor opens **first** — type the notes off the
CD case, then save & close to kick off the rip and walk away. It ejects when
finished. Repeat for the next disc.

**Step 2 — transcode (later, on the fast/GPU box).** Point it at the same
storage and batch-convert every ripped disc to MP4. See
[Transcoding](#transcoding) below.

```
CD_DIG_ROOT=/path/to/discs-storage ./scripts/transcode-all.sh 8
```

Each rip creates a self-contained, timestamped folder under `discs/` (in the
current directory, or under `$CD_DIG_ROOT`) — no naming required:

```
discs/2026-06-22_143005_disc-label/
├── master.iso            ← bit-exact preserved master (the whole disc)
├── master.map            ← ddrescue map: which sectors read cleanly
├── files/                ← every original file, names + dates preserved
├── videos/               ← each individual video, separated out
├── mp4/                  ← H.264 MP4 of each video (Jellyfin-friendly)
├── metadata/             ← EVERYTHING (see below)
├── disc-info.json        ← consolidated machine-readable summary
└── notes.md              ← your typed notes + the auto-detected facts
```

### Options

```
./scripts/rip-disc.sh --note "disc 1 of 30 — text copied off the case"   # notes from CLI
./scripts/rip-disc.sh --transcode         # also make MP4s now (off by default)
./scripts/rip-disc.sh --no-eject          # leave the disc in
./scripts/rip-disc.sh --dev /dev/sr1      # different drive
```

## What gets preserved as the master

`master.iso` is a bit-for-bit image of the entire disc, made with **ddrescue**
— which, unlike a plain copy, retries and scrapes weak sectors and writes a
`master.map` recording exactly what it could and couldn't read. That matters:
these discs are 20+ years old and dye-degraded. The map is your provenance —
if a sector is bad you'll know which video it touched. Everything else
(`files/`, `videos/`, `mp4/`) is *derived from the ISO*, so the physical disc
is read only once.

`disc-info.json` records the master's SHA-256 so you can verify integrity later.

### Nothing is discarded — all file types kept

`files/` is a full extraction of the **entire disc**, not just videos — photos,
slideshows, documents, audio, readme/index files, autorun players, whatever
happens to be on there is copied out with its original path and timestamp. On
top of that, `master.iso` is a complete image, so even files the extractor
can't handle still live inside the master. `videos/` and `mp4/` are *additional*
conveniences derived from that complete set. The end-of-run summary prints a
list of any non-video files it found so you can see them at a glance.

## Metadata — "every bit we can get"

| Source | What it captures | Where |
|---|---|---|
| ISO9660 + Joliet volume descriptors | volume label, **burn date** (creation/modification/expiration/effective), publisher, data-preparer, application ID | `metadata/iso-volume.json` |
| `ffprobe` per video | codec, duration, resolution, fps, bitrate, chapters, embedded `creation_time` | `metadata/videos/*.ffprobe.json` |
| `exiftool` per video | any camcorder / QuickTime / maker tags | `metadata/videos/*.exiftool.json` |
| filesystem | every file's name, path, size, and original timestamp | `files/` + `metadata/filelist.txt` |
| `udevadm` / `blkid` / `cd-info` | drive + disc/track layout | `metadata/*.txt` |
| ddrescue map | per-sector read fidelity | `master.map` |

**The burn date is the gold.** Undated home video rarely has dates *in* the
video, but the disc's ISO volume-creation timestamp is usually when it was
burned — which, for a camcorder-to-CD transfer, is close to when it was shot.
`disc-info.json` surfaces it as `burn_date_guess`, and `notes.md` shows it so
you can confirm/adjust against the case label.

## How each disc type is separated into individual videos

- **Data CD** (`.avi/.mov/.mpg/.mp4/...`): each video file copied out verbatim,
  one per file, keeping its original timestamp.
- **DVD-Video** (`VIDEO_TS`): one output per *title* — that title's `VTS_NN_*.VOB`
  parts concatenated in order; separate titles stay separate.
- **Video CD / SVCD** (`MPEGAV/AVSEQ*.DAT`): each MPEG sequence remuxed to its
  own `.mpg`.

## Transcoding

This is the deferred batch step — run it after you've ripped your discs, on
whatever machine is fastest. It makes an H.264 MP4 of each separated video into
each disc's `mp4/`, auto-detects interlacing per file (`idet`) and only
deinterlaces (bwdif) when needed. Resume-safe and parallel — re-run to retry
only what's missing or failed.

**The encoder is auto-selected:** `h264_nvenc` if your `ffmpeg` has it (fast —
use a machine with an NVENC GPU), otherwise CPU `libx264 -crf 18` (fine for SD,
just much slower). Force it with `ENCODER=nvenc` or `ENCODER=cpu`.

**All discs at once** (the normal case):

```
# on the fast/GPU box, pointed at where the rips live:
CD_DIG_ROOT=/path/to/discs-storage ./scripts/transcode-all.sh 8
```

`8` is the number of parallel encodes — raise it on a GPU box with lots of CPU
cores (NVENC handles many sessions; bwdif deinterlace is the CPU bottleneck).

**A single disc:**

```
./scripts/transcode-disc.sh discs/2026-06-22_143005_disc-label/ 6
```

### Running it on a different machine

The transcode step just needs read/write access to the disc folders. Either run
the rips straight onto shared storage (a NAS, an external drive) and point the
GPU box at the same path via `CD_DIG_ROOT`, or mount it over the network
(sshfs/NFS). Nothing else has to move — `videos/` is the input, `mp4/` is the
output, both inside each disc folder.

## Setup (one time)

Install the imaging/extraction tools (Debian/Ubuntu shown; use your distro's
package manager otherwise):

```
sudo apt install gddrescue xorriso vcdimager genisoimage
```

- `gddrescue` → `ddrescue` (robust imaging — **the important one**)
- `xorriso`   → mount-free file extraction (runs as your user, no root per disc)
- `vcdimager` → cleaner Video-CD extraction (optional; there's an ffmpeg fallback)
- `genisoimage` → `isoinfo` for an extra human-readable metadata dump (optional)

`ffmpeg`, `ffprobe`, `exiftool`, and `python3` are also required (most systems
already have them). Add your user to the `cdrom` group (`sudo usermod -aG cdrom
$USER`, then re-login) so reading the drive and imaging need no root.

## Verifying a disc

After a rip, sanity-check before moving on:

```
cat discs/<folder>/disc-info.json | python3 -m json.tool   # or: less
ls -la discs/<folder>/videos discs/<folder>/mp4
```

Confirm `video_count` matches what you expect from the case, `burn_date_guess`
looks plausible, and the `mp4/` files play. If a video is missing or short,
check `master.map` for bad sectors over that region and consider a re-read
(ddrescue is resumable: re-running appends to the same map).
