# dv-tape

Digitizing MiniDV / DV camcorder tapes. A tape is one long continuous stream,
so the pipeline captures a raw master, **scene-splits** it back into the
individual clips, then transcodes each to H.264.

```
  FireWire capture (dvgrab/etc.)  →  masters/tapeNN/tapeNN.dv   (raw DV master)
        │
        ▼
  split.sh NN      PySceneDetect content-detect  →  scenes/tapeNN/*.mkv  (bit-exact per-scene copies)
        │
        ▼
  transcode.sh NN  NVENC H.264 (bwdif deinterlace) →  final/tapeNN/*.mp4
        │
        ▼
  ../scene-audit/  visually verify the cuts against the master
```

## Data location

Code lives here; the (large) tape data lives wherever you point the scripts.
They expect this layout under a **data root**:

```
<data-root>/
├── masters/tapeNN/tapeNN.dv   ← your captured raw DV masters
├── scenes/tapeNN/*.mkv        ← created by split.sh
└── final/tapeNN/*.mp4         ← created by transcode.sh
```

The data root defaults to the current directory, so `cd` into it before running
(or set `TAPE_DIG_ROOT=/path/to/data`). Keeping the masters on big storage (a
NAS, an external drive) and running the scripts against them works fine.

## Steps

**1. Split a captured master into scenes** (needs `scenedetect[opencv]` + `av`):

```
./scripts/split.sh 02
```

**2. Transcode the scenes to MP4** (needs `ffmpeg` with `h264_nvenc`; no NVENC
GPU? swap it for `libx264` in the ffmpeg call). bwdif deinterlacing on CPU is
the per-process bottleneck, so NVENC lets the parallel jobs scale:

```
./scripts/transcode.sh 02        # 4 parallel jobs (default)
./scripts/transcode.sh 02 8      # 8 parallel jobs
```

Both scripts are resume-safe — re-run to retry only what's missing/failed.

**3. Audit the cuts** — see [`../scene-audit`](../scene-audit), which overlays
the PySceneDetect output on the master in mpv for visual QA.
