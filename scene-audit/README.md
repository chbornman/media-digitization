# dv-scenedetect-audit

A small mpv user script for **visually auditing PySceneDetect output** against
a source master video. Built for DV-tape digitization pipelines but works on
any video format mpv can decode.

You feed it the master file plus the `*-Scenes.csv` that PySceneDetect emits,
and it plays the master with an overlay showing every cut, the current scene,
and surrounding context. Optional per-scene MKV and MP4 slice directories
enable a side-by-side compare mode for auditing transcode fidelity.

The tool is **read-only**: it never modifies any input file, and mpv is
launched with watch-later state and config writes disabled, so running it
has zero on-disk side effects.

## Requirements

- `mpv` (with Lua support — standard in upstream builds)
- `bash` (for the launcher; the Lua script itself is the only logic)

No Python, no pip, no virtualenv.

## Install

Clone the repo anywhere and make the launcher executable:

```
git clone https://github.com/<you>/dv-scenedetect-audit.git
cd dv-scenedetect-audit
chmod +x audit
```

Optionally symlink `audit` onto your `PATH`.

## Usage

```
./audit MASTER --scenes CSV [--mkv-dir DIR] [--mp4-dir DIR]
```

- `MASTER` — the source video (DV, MP4, MKV — anything mpv handles).
- `--scenes CSV` — a PySceneDetect `*-Scenes.csv` for that master.
- `--mkv-dir DIR` — optional. Directory of per-scene bit-exact slices,
  named so that `sort -V` puts them in scene order. Required for compare mode.
- `--mp4-dir DIR` — optional. Directory of transcoded per-scene slices,
  same ordering. Required for compare mode.

Example:

```
./audit path/to/master.dv \
  --scenes  path/to/master-Scenes.csv \
  --mkv-dir path/to/scenes \
  --mp4-dir path/to/final
```

When both slice directories are supplied, files are paired with scenes by
sorted index. The tool warns (but continues) if the counts don't match.

## On-screen layout

```
┌────────────────────────────────────────────────────────────────────┐
│                                                                    │
│                         mpv video surface                          │
│                                                                    │
│  0:23:14 / 2:04:56                          ▶ scene 47/280  …      │
│  scene 47/280  0:23:14 – 0:23:58  (44.0s)     scene 48 …           │
│                                                                    │
│                                                                    │
│ Space play/pause  ←/→ ±1s  ↑/↓ ±5s  Ctrl+←/→ prev/next cut  …      │
│ c compare   Esc exit compare   z toggle zoom   h hide   q quit     │
│ ┃         ▌         ▌  ▌  ▌      █  ▌    ▌    ▌            0:25:00 │
│ ┗━━━━━━━━━┻━━━━━━━━━┻━━┻━━┻━━━━━━━┻━━┻━━━━┻━━━━┻━━━━━━━━━━━━━━━━━━━┛
│ 0:21:30                                                            │
└────────────────────────────────────────────────────────────────────┘
```

- **Top-left:** current timecode + master duration, plus current scene info.
- **Top-right:** seven-scene context window centered on the current scene.
- **Above the timeline:** keyboard legend, always visible. Hide with `h`.
- **Timeline strip:** zoomed to a window around the playhead.
  - Top half ticks = **scene starts** (incoming cut).
  - Bottom half ticks = **scene stops** (outgoing cut).
  - Bright green / red-orange = the current scene's cut-in / cut-out.
  - Muted green / red = every other start / stop.
  - White vertical line = playhead.
  - Darker green band on the track = current scene's span.

## Keys

| Key                | Action                              |
| ------------------ | ----------------------------------- |
| `Space`            | Play / pause                        |
| `←` / `→`          | Seek ±1 s                           |
| `↑` / `↓`          | Seek ±5 s                           |
| `Ctrl+←` / `Ctrl+→`| Previous / next cut                 |
| `[` / `]`          | Same as `←` / `→` (legacy alias)    |
| `PgUp` / `PgDn`    | Same as `Ctrl+←` / `Ctrl+→` (alias) |
| `,` / `.`          | Frame back / forward                |
| click on timeline  | Seek to that position               |
| `c`                | Enter compare mode for current scene|
| `Esc`              | Exit compare mode                   |
| `z`                | Toggle zoomed / full timeline view  |
| `h`                | Hide / show the overlay             |
| `q`                | Quit mpv                            |

Playback always runs continuously on the master file. Nothing auto-seeks;
scenes only change when you press a navigation key or click the timeline.

## Compare mode

When you press `c` on a scene and both `--mkv-dir` and `--mp4-dir` were
supplied, mpv reloads the corresponding MKV slice as the primary input,
adds the MP4 slice as an external file, and applies an `hstack` filter
to show both side-by-side at video resolution. Audio comes from the MKV
(the bit-exact source).

The two panes start synchronized at scene t=0 and stay in sync via
identical wall-clock durations — mpv aligns by PTS, not frame index, so
this works even when the transcode has a different frame rate
(e.g. bwdif-deinterlaced 60p MP4 vs 30i MKV).

`Esc` tears down compare mode and restores the master at the position
you left it.

## Display scaling

The overlay renders into a virtual 1080-row canvas that mpv scales to
your display. On a 4K display every UI pixel is roughly 2× a 1080p
pixel, so text reads at a comfortable size without any configuration.

## Wayland / X11

mpv is Wayland-native. The script makes no assumptions about the
windowing system — it works equally well on Wayland compositors and
under X11.

## Read-only guarantees

- The script reads the CSV and slice directories with `io.open(..., "r")`
  and `utils.readdir`. It never writes.
- The launcher passes `--save-position-on-quit=no` and
  `--write-filename-in-watch-later-config=no` to mpv, so the watch-later
  state is not recorded.
- No file in any of the input paths is modified.

