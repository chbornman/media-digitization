# media-digitization

Home for converting old/legacy media to preserved digital archives. One repo,
organized **by source media type**, so new formats (VHS, film, floppies,
whatever turns up) just get a new top-level folder.

Every workflow follows the same philosophy:
**capture a pristine master → derive usable files → capture all metadata → verify.**

The code lives here; the bulky data lives on the NAS under `/HomeNAS/Videos/...`
and is auto-detected by each tool (never committed).

## Media types

| Folder | Source | What it does |
|---|---|---|
| [`dv-tape/`](dv-tape) | MiniDV / DV camcorder tapes | Capture raw DV master → scene-split → NVENC H.264. |
| [`optical-disc/`](optical-disc) | CDs / DVDs (VCD, SVCD, DVD-Video, data discs) | One-command: bit-exact ISO master + all files + separated videos + full metadata + MP4. |
| [`scene-audit/`](scene-audit) | (tool) | mpv overlay to visually verify PySceneDetect cuts against a master. Used by `dv-tape`; works on any video. |

## Quick start

**Optical disc** (the current project — wife's family CDs):
```
cd optical-disc
./scripts/rip-disc.sh        # pop in a disc, type notes, walk away; it ejects when done
```
See [`optical-disc/README.md`](optical-disc/README.md) for the one-time tool
install and the full output layout.

**DV tape:**
```
cd dv-tape
./scripts/split.sh 02 && ./scripts/transcode.sh 02
```
See [`dv-tape/README.md`](dv-tape/README.md).

## Data lives on the NAS, not in git

| Workflow | Data root |
|---|---|
| dv-tape | `/HomeNAS/Videos/tape-digitization/{masters,scenes,final}` |
| optical-disc | `/HomeNAS/Videos/cd-digitization/discs/<timestamp>_<label>/` |

`.gitignore` defensively excludes media files and these data dirs in case any
ever land inside the repo.
