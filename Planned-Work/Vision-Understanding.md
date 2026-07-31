# GuiAssert Vision Understanding

Status: **planned** · Owner: campaign extension of "The Flame" home-demo work ·
Related: [[Home-Demo-Screencast.milestones.org]] (codetracer-specs/Marketing),
[[../src/gui_assert/ocr.nim]], [[../src/gui_assert/image_math.nim]],
[[../src/gui_assert/media.nim]], [[../src/gui_assert/window_layout.nim]].

## Two distinct capability sets (this initiative is the second)

GuiAssert's GUI-understanding work splits into two independent capability sets;
**this initiative is strictly the second one.**

1. **OS-driven automation (appium-like).** Enumerate top-level windows,
   read their titles/bounds, focus/activate/resize, click and type — using the
   host's OS/accessibility APIs (macOS Accessibility/`CGWindowList`, Windows
   UIAutomation/`EnumWindows`, Linux EWMH/`wmctrl`, Appium/WebDriver). This set
   already *partially exists* (`window_layout.nim`, `appium.nim`, `input.nim`)
   and is what drives the substrate recordings. It is **out of scope here.**

2. **Pure computer-vision analysis (this initiative).** Answer the same kinds of
   questions **from pixels alone** — a screenshot or a recorded video — with **no
   OS API available**. This is the only option when analysing a recorded mp4, a
   screen streamed from a remote/VM/kiosk session, a single-surface app that
   draws its own widgets (games, canvas/WebGL, custom GPU UIs), or footage from a
   machine we cannot introspect. Everything below uses only decoded frame pixels
   + OCR; it never calls an OS window API.

## Problem

For the pure-CV case, GuiAssert cannot yet turn a screenshot or a recorded
video into a **structured, queryable, assertable** description. Today an agent
(or a test) confronted with `linux-session.mp4` — a *recording*, where no live
OS query is possible — has no programmatic way to answer:

- "How many top-level windows are visible, and what is each one's text?"
- "At what timestamps did the on-screen content change?"
- "Did a window titled *CodeTracer Browser Replay* ever appear?"
- "Was the URL `127.0.0.1:8080/docs` shown at any point?"

The low-level primitives already exist and are tested:

| Primitive | Module | What it gives |
|---|---|---|
| Word-level OCR w/ pixel bboxes | `ocr.runOcr` → `seq[OcrWord]` | text + `[x,y,w,h]` + confidence + line/block |
| Grayscale decode (ffmpeg) | `image_math.decodeGray` → `GrayImage` | raw 8-bit buffer of known size |
| Global SSIM | `image_math.computeSsim(a,b)` | frame-to-frame similarity in [-1,1] |
| ffmpeg/tesseract resolution | `media.resolveFfmpegBinary`, `ocr.resolveTesseractBinary` | pinned-binary discovery |

**Missing:** the *video-level* layer that segments a recording by visual change,
OCRs representative frames, and assembles a timeline; the *window-enumeration*
layer that answers "how many windows + their text"; a *query/assertion* API over
both; a *CLI* the agent can run on any video; and *reproducible* tool pinning
(GuiAssert has no flake — it borrows ffmpeg/tesseract from the consuming repo).

## Design

Two new modules plus a CLI, composing the existing primitives. No new heavy
dependencies — only `ffmpeg` (already used) and `tesseract` (already used).

### 1. `gui_assert/video_analysis.nim`

Segments a video by visual change (reusing `computeSsim`), extracts one
representative keyframe per distinct state, OCRs it, and assembles a timeline.

```nim
type
  Keyframe* = object
    index*: int
    tStart*, tEnd*: float
    changeScore*: float          # 1 - SSIM vs previous kept state
    imagePath*: string           # extracted full-res PNG
    words*: seq[OcrWord]
    text*: string                # reconstructed reading-order text
    urls*: seq[string]           # extracted URLs / host:port paths
  VideoInfo* = object
    path*: string
    durationS*: float
    width*, height*: int
  VideoAnalysis* = object
    info*: VideoInfo
    frames*: seq[Keyframe]       # one per detected distinct state
```

Pure, unit-tested: `buildProbeArgv`, `parseProbeJson`, `buildSampleFramesArgv`,
`buildExtractFrameArgv`, `extractUrls`, `wordsToReadingOrderText`,
`segmentBoundaries(ssims, threshold)`.
Effectful, integration-tested against real ffmpeg+tesseract: `probeVideo`,
`segmentByChange` (sample at low fps + downscaled, SSIM consecutive frames,
boundary when `1-SSIM > threshold`), `analyzeVideo`.

### 2. `gui_assert/vision_windows.nim` — window detection from pixels only

Answers "how many top-level windows are visible, and what is each one's text?"
from a single decoded frame, **with no OS API** — the only option for a
recording, a remote/VM screen, or a self-drawn surface.

```nim
type DetectedWindow* = object
  bbox*: array[4, int]           # [x,y,w,h] in frame pixels
  titleText*: string             # OCR of the detected title-bar band (if any)
  text*: string                  # OCR of the whole window region
  confidence*: float             # detector confidence for the rectangle
proc detectWindowRects*(img: GrayImage): seq[array[4, int]]
proc detectWindows*(framePath: string): seq[DetectedWindow]   # rects + per-region OCR
```

Pure CV: `detectWindowRects` finds top-level window rectangles from a
`GrayImage` (`decodeGray`) via title-bar / border edge projection (row/column
gradient profiles) + connected-component grouping of the resulting box edges,
filtered by minimum area and aspect. `detectWindows` then crops each rectangle
and `runOcr`s it, returning per-window text — so window count + per-window text
come purely from pixels. No `CGWindowList`/`EnumWindows`/`wmctrl` here; that
ground-truth path belongs to the separate OS-driven capability set.

### 3. CLI `gui-assert-vision`

`analyze <video>` → writes `timeline.json`, `digest.md`, `keyframes/*.png`;
`describe <image>` → detected windows + text of one screenshot (pure CV);
`windows <image>` → window count + per-window title/text (pure CV).
The reusable tool: point it at any recording/screenshot and get a structured
description, without touching the host's OS window APIs.

### 4. Query / assertion API (pure)

`containsText`, `locateText` (→ frame + `OcrWord`), `seenUrl`,
`distinctStateCount`, `textInRegion`, `windowCount`, `windowWithTitle`.

## Reproducibility

Add a GuiAssert `flake.nix` pinning `nim`, `ffmpeg`, and `tesseract` so
`nix develop -c nimble test` is hermetic. Until then the modules resolve
binaries via `$FFMPEG`/`$TESSERACT_BIN`/`$PATH` (as today), and the consuming
repo's devShell supplies them.

## Testing policy

Per workspace policy: mock as little as possible. Parser/geometry procs are
pure and tested against inline fixtures. Pipeline procs are tested against
**real** ffmpeg + tesseract using fixtures *generated at test time* (ffmpeg
`drawtext` frames + a 2-state fixture video), so OCR/SSIM run against genuine
binaries with no committed media blobs and no stubbed subprocesses.
