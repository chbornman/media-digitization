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

Code lives here; the (large) data lives on the NAS and is auto-detected:
`/HomeNAS/Videos/tape-digitization/{masters,scenes,final}` (or
`~/mnt/bornman/Videos/tape-digitization` over sshfs from margo). Override with
`TAPE_DIG_ROOT`.

> The `final/` folder is bind-mounted read-only into the Immich container, so
> don't relocate it without updating `containers/docker-compose.yml`.

## Steps

**1. Split a captured master into scenes** (run on bornmanserver, or margo via
sshfs — needs `scenedetect[opencv]` + `av`):

```
./scripts/split.sh 02
```

**2. Transcode the scenes to MP4** (run where `h264_nvenc` exists — i.e. margo's
5080; bwdif on CPU is the per-process bottleneck, NVENC scales in parallel):

```
./scripts/transcode.sh 02        # 4 parallel jobs (default)
./scripts/transcode.sh 02 8      # 8 parallel jobs
```

Both scripts are resume-safe — re-run to retry only what's missing/failed.

**3. Audit the cuts** — see [`../scene-audit`](../scene-audit), which overlays
the PySceneDetect output on the master in mpv for visual QA.
