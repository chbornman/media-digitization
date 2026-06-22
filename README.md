# media-digitization

My personal toolkit for converting old/legacy media into preserved digital
archives. It's organized **by source media type**, so as I run into new formats
(VHS, film, floppies, whatever turns up) each one just gets its own top-level
folder.

> [!IMPORTANT]
> **This is "here's what I did," not a turnkey tool.** Everything here is the
> actual set of scripts I used for *my* situation — my drive, my server, my
> storage layout. Paths, hostnames, and assumptions are hard-coded to my setup
> and will not match yours. I'm publishing it because the **approach** and the
> **gotchas I hit** might save you time, not because it's a polished product.
> Read it as a worked example and a starting point, then adapt freely.

## The philosophy (this is the part that transfers)

Every workflow here follows the same four principles, and these are what I'd
actually recommend to anyone digitizing old media:

1. **Capture a pristine master first.** A bit-exact image (raw DV stream, full
   disc ISO) that you never touch again. Everything else is derived from it, so
   you only read the fragile original once.
2. **Derive the convenient copies separately.** Per-clip files, H.264 MP4s for
   watching — generated from the master, regenerable if you change your mind.
3. **Capture all the metadata you can, while you can.** Embedded timestamps,
   disc volume dates, file modification times, codec details — old footage is
   usually undated, and these are often the only clues to *when* something
   happened. Once the disc/tape is gone, they're gone.
4. **Verify before you trust it.** Spot-check that the derived files actually
   play and that nothing silently dropped.

## What's in here

| Folder | Source media | What it does |
|---|---|---|
| [`optical-disc/`](optical-disc) | CDs / DVDs (Video-CD, SVCD, DVD-Video, plain data discs) | Rip (one command): bit-exact ISO master + every original file + each video separated + full disc & per-file metadata. Auto-detects the disc type. Transcode to H.264 MP4 is a separate batch step (CPU or NVENC) you run later on the fastest box. |
| [`dv-tape/`](dv-tape) | MiniDV / DV camcorder tapes | Capture a raw DV master, scene-split it back into the individual clips, transcode each to H.264. |
| [`scene-audit/`](scene-audit) | *(a tool, not a media type)* | An mpv overlay to visually check the scene-split cuts against the master. Used by `dv-tape`; works on any video. |

Each folder has its own README with the specifics.

## Using it

The scripts default to working in the **current directory** and put output
there, so the basic flow is just "cd somewhere with room, run the script":

- **Output location** is overridable per workflow with an env var
  (`CD_DIG_ROOT` for optical-disc, `TAPE_DIG_ROOT` for dv-tape) if you'd rather
  archive to a NAS or external drive than the current folder.
- **Check the tools.** Each README lists what it needs (`ddrescue`, `xorriso`,
  `ffmpeg`, `scenedetect`, `mpv`, …). Nothing exotic; all from your distro's
  package manager.
- **The optical-disc one is the most reusable** — it's a single script you can
  point at any disc, and it figures out the rest. That's the one I'd start from.

These were written and tested on Linux (the optical-disc workflow assumes a
Linux optical drive at `/dev/sr0`, overridable with `--dev`). The choices
inside reflect the situation I built them for, so read them as a worked example
rather than gospel and adjust to taste.

## This repo is code only

The actual media — the masters, the ripped files, the MP4s — is **not** in here
(it's many hundreds of GB and lives on separate storage). `.gitignore`
defensively excludes media files so nothing bulky or personal ever gets
committed by accident. There is no footage, no personal files, and no
credentials in this repository — only scripts and documentation.
