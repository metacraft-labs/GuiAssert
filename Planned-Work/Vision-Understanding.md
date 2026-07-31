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

### 3. Token-efficient agent index (THE primary deliverable)

SOTA long-video agent systems (DrVideo, VideoAgent) never feed many frames to
the model: they turn the video into a **textual document + retrieval loop** and
pull individual frames **only on demand**. GuiAssert adopts this directly. The
`analyze` output is a single hierarchical JSON index with three levels:

1. **Summary** (~hundreds of tokens, zero images): duration, dimensions, frame
   count, N states, the distinct window titles seen, the URLs seen. Answers
   "what is this recording?" with no frames.
2. **Segment timeline**: one row per stable UI state —
   `{id, start, end, thumbnail, activeWindow, regionTree, text (reading order),
   urls, textDiffVsPrev}`. The **text-diff vs the previous state** ("+ dialog
   'Delete file?'", "− toolbar", "addr A→B") is the highest-signal / lowest-token
   description of *what changed*.
3. **Searchable text/element index**: every OCR'd string + detected region as
   `{text, confidence, bbox, segmentId, timestamp}` so an agent can **grep the
   video** — locate the exact timestamps where a string/URL/window appears, then
   extract only those 1–3 frames to actually look at.

### 4. CLI `gui-assert-vision` — two modes: explore & grep

- `analyze <video>` → writes `index.json` (the 3-level index above) + `digest.md`
  (human/agent-readable timeline with per-state text-diffs) + `keyframes/*.png`.
- `find <text|url|regex> <video-or-index>` → the "grep the video" command:
  returns matching `{timestamp, segmentId, bbox, confidence}` rows.
- `extract-frame --at <ts> | --segment <id>` → emits ONLY the requested frame(s)
  for the agent to view; `contact-sheet <video>` → one tiled keyframe grid for a
  single-image "gestalt" of the whole recording.
- `describe <image>` / `windows <image>` → detected windows + text of one
  screenshot (pure CV), no OS window APIs.

The workflow: **read the index/digest to explore casually; grep → extract 1–3
frames to write or verify a precise assertion** — minimizing both tokens and
images.

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

## State of the art & our choices (2026 survey)

A SOTA survey (OmniParser v2; DrVideo/VideoAgent long-video agents; PySceneDetect
detectors; Tesseract vs PaddleOCR/RapidOCR/Apple Vision; Set-of-Mark) informed
these decisions. Full sources in the initiative notes.

- **Agent token-efficiency (highest leverage).** The winning pattern is
  *video→document + retrieval*: emit a compact textual index and pull frames
  only on demand (DrVideo). We adopt the 3-level index + `find`/`extract-frame`/
  `contact-sheet` above. This — not ML — is our top priority (VU5).
- **Change detection.** Global SSIM is dominated by large unchanged regions and
  misses small-but-important UI changes (a new dialog, an address-bar edit). Go
  **tiled/local SSIM** (trigger on the max local drop), add **pHash (DCT) dedup**
  of keyframes before OCR, an **edge-change-ratio** secondary signal (fires on
  text scroll / window open-close, quiet on colour-only change), and
  **freezedetect** to skip idle stretches + snap keyframes to the settled state
  (VU8). ThresholdDetector/fade metrics are useless for screens.
- **OCR.** Biggest levers for screen text: **2–4× Lanczos upscaling**,
  **per-region PSM** (11/12 full-frame, 7 single-line, 6 block — pairs with our
  window detection), **dark-mode detection + inversion** (Tesseract expects
  dark-on-light; un-inverted dark UIs silently fail), light contrast only. Keep
  **Tesseract** as the reproducible default; expose **Apple Vision** (macOS) and
  **RapidOCR (pinned PP-OCR ONNX)** as optional high-accuracy backends behind
  flags (VU9 / VU11). Emit word-level bbox + confidence into the index.
- **Layout/window detection.** Beyond Otsu+CC (VU4), add pure-CV **morphological
  close/open → Hough/LSD line detection** (title bars/toolbars/borders) **→ MSER**
  text regions **→ projection profiles → contour-hierarchy region tree** (VU10).
  This recovers most of OmniParser's *structural* value without ML; semantic
  element labels ("Save button") remain ML-only and are an optional backend
  (VU11) — OCR text near a region is a cheap proxy.
