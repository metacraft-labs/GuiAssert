# GuiAssert Vision Understanding

Status: **planned** · Owner: campaign extension of "The Flame" home-demo work ·
Related: [[Home-Demo-Screencast.milestones.org]] (codetracer-specs/Marketing),
[[../src/gui_assert/ocr.nim]], [[../src/gui_assert/image_math.nim]],
[[../src/gui_assert/media.nim]], [[../src/gui_assert/window_layout.nim]].

## Problem

GuiAssert can *drive* a GUI session and *capture* it, but it cannot yet turn a
screenshot or a recorded video into a **structured, queryable, assertable**
description. Today an agent (or a test) confronted with `linux-session.mp4` has
no programmatic way to answer:

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

### 2. `gui_assert/windows.nim` — window enumeration (two backends, one API)

```nim
type WindowInfo* = object
  title*: string
  bbox*: array[4, int]           # [x,y,w,h]
  text*: string                  # OCR of the window region (vision backend)
  source*: WindowSource          # wsOsAccessibility | wsVision
proc enumerateWindows*(source: WindowEnumSource): seq[WindowInfo]
```

- **OS backend (ground truth, live sessions):** parse `CGWindowListCopyWindowInfo`
  (macOS, via a tiny bundled helper or `osascript`), `EnumWindows` (Windows,
  via PowerShell), `wmctrl -l -G` (Linux). Parsers are pure + unit-tested; the
  enumeration is integration-tested where a session exists.
- **Vision backend (screenshot/video only — the recorded-substrate case):**
  detect top-level window rectangles from a `GrayImage` via title-bar / border
  edge projection + connected-component grouping, then `runOcr` each region.
  This is what lets `enumerateWindows(wsVision)` answer "how many windows + text"
  from a single mp4 frame with no OS access.

### 3. CLI `gui-assert-vision`

`analyze <video>` → writes `timeline.json`, `digest.md`, `keyframes/*.png`;
`describe <image>` → windows + text of one screenshot;
`windows <image|--live>` → window count + per-window title/text.
The reusable tool: point it at any recording and get a structured description.

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
