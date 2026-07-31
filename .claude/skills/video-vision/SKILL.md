---
name: video-vision
description: >-
  Understand, query, and write assertions against desktop SCREEN RECORDINGS and
  marketing videos from pixels alone (no OS APIs) using GuiAssert's vision
  tooling. Use when you need to know what happens in an .mp4/screenshot, find
  where text/a URL/a window appears, extract only the frames worth looking at
  (token-efficient), OCR a timeline, or assert a recording actually shows
  expected content. Pure computer vision — works on recordings, remote/VM
  screens, and self-drawn surfaces where accessibility/appium APIs are absent.
---

# video-vision — analyze desktop recordings from pixels

GuiAssert turns a screen recording into a **compact textual index** so you can
explore it and write assertions **without dumping many frames into context**.
The workflow mirrors DrVideo/VideoAgent: read the text index → *grep the video*
→ extract only the 1–3 frames you actually need to look at.

## Golden rule (token efficiency)

Do **not** extract-and-view many frames. Instead:

1. `analyze` the video once → `index.json` + `digest.md`.
2. **Read `digest.md`** (or the index `summary`) — a few hundred tokens tells you
   the states, window titles, URLs, and per-state *what-changed* diffs. Often
   this alone answers "what happens in this recording?" with **zero images**.
3. `find "<text|url>"` to get the exact timestamps where something appears.
4. `extract-frame --at <ts>` to pull **only that one frame**, then `Read` the PNG.
5. For a one-image gestalt of the whole video, `contact-sheet`.

## Setup (reproducible)

From the GuiAssert checkout, everything is pinned by the flake:

```sh
cd /path/to/GuiAssert
nix develop            # provides nim, ffmpeg (drawtext), tesseract (eng) + env
```

The flake's shellHook exports `FFMPEG`/`FFPROBE`/`FFMPEG_BIN`/`TESSERACT_BIN`,
fonts, and canonicalizes `TMPDIR` (leptonica can't open symlinked `/tmp` on
macOS). Without the flake, set those env vars yourself and ensure `FFPROBE`
points at the **real ffprobe** (not ffmpeg).

Build the CLI:

```sh
nim c -d:release --hints:off -o:bin/gui-assert-vision src/gui_assert_vision.nim
```

## CLI commands

```sh
# 1) Analyze → writes OUT/index.json, OUT/digest.md, OUT/keyframes/*.png
bin/gui-assert-vision analyze recording.mp4 --out vision-out

# 2) Grep the video (substring, or --regex) → matching {timestamp, segmentId, bbox, confidence, text}
bin/gui-assert-vision find "Browser Replay" vision-out/index.json
bin/gui-assert-vision find "127\.0\.0\.1:\d+" recording.mp4 --regex

# 3) Extract ONLY the frame(s) you need to look at
bin/gui-assert-vision extract-frame recording.mp4 --at 30.5 --out /tmp/f.png
bin/gui-assert-vision extract-frame recording.mp4 --segment 7 --out /tmp/f.png

# 4) One tiled keyframe grid for the whole recording (single image gestalt)
bin/gui-assert-vision contact-sheet recording.mp4 --out /tmp/sheet.png --cols 3

# 5) Single screenshot: detected windows (count + bbox + text) / description
bin/gui-assert-vision windows screenshot.png
bin/gui-assert-vision describe screenshot.png
```

`just analyze VIDEO` is a convenience recipe.

## index.json structure (what to read)

```jsonc
{
  "summary":  { "video","durationS","width","height","stateCount",
                "windowTitles": [...], "urls": [...] },      // read this first
  "segments": [ { "id","start","end","changeScore","thumbnail",
                  "text",                                    // reading-order OCR
                  "urls",
                  "textDiffVsPrev" } ],                      // "+ added / − removed"
  "textIndex": [ { "text","confidence","bbox":[x,y,w,h],
                   "segmentId","timestamp" } ]               // grep target
}
```

`textDiffVsPrev` is the highest-signal, lowest-token "what changed" per state.

## Writing assertions (Nim, in tests)

Import `gui_assert/video_analysis` (and `gui_assert/vision_windows`):

```nim
let a = analyzeVideo("recording.mp4")            # real ffmpeg + tesseract
check distinctStateCount(a) >= 2
check containsText(a, "CodeTracer")              # case-insensitive
check seenUrl(a, "127.0.0.1:8080/docs")
let hits = locateText(a, "Worker error")         # → seq[(frame, OcrWord)]
check textInRegion(a, frame=7, x=520,y=60,w=1040,h=780, "Browser Replay")

let idx = buildIndex(a)                           # JsonNode (3-level)
let m = findInIndex(idx, "flame")                 # grep the index

# pixel-only window enumeration from ONE frame (no OS APIs):
let wins = detectWindows("frame.png")             # seq[DetectedWindow] (bbox+text)
```

**Beat-verifier pattern** (see codetracer-marketing `runner/vm-record/
verify_recording.nim`, VU7): assert a recording shows required "beats" (≥N
states, specific text/URL present) and **fail loudly** on an empty/black capture
— use this as a post-record gate, not just eyeballing the mp4.

## What the tooling does (so you trust the output)

- **Segmentation** (`segmentByChange`): tiled/local SSIM (catches small UI
  changes global SSIM misses) + pHash dedup of near-duplicate states + optional
  edge-change-ratio. One keyframe per distinct state.
- **OCR** (`runOcrMultiPsm`): 2× Lanczos upscale + auto dark-mode inversion
  (Tesseract wants dark-on-light) + both `--psm 6` (blocks) and `--psm 11`
  (sparse) merged — so small headings amid busy text aren't dropped. Word-level
  bboxes + confidence.
- **Windows** (`detectWindowRects`/`detectWindows`): Otsu threshold + connected
  components → per-window crop + OCR. Pure pixels; works because desktop windows
  are light regions on a darker background.

## Gotchas

- `FFPROBE` must be the real ffprobe binary, not ffmpeg.
- OCR is imperfect on busy/anti-aliased text — prefer any-of alternative
  substrings and case-insensitive matches in assertions; verify a specific claim
  by `extract-frame` + `Read`.
- `analyzeVideo` is thorough, not real-time (multi-PSM × upscale × N states):
  ~seconds per state. Fine for analysis; not a live loop.
- Window detection assumes light-on-dark chrome; a full-bleed single window may
  be treated as background (documented).

## Where things live

- Code: `GuiAssert/src/gui_assert/{video_analysis,vision_windows,ocr,image_math}.nim`,
  CLI `src/gui_assert_vision.nim`.
- Spec + milestones: `GuiAssert/Planned-Work/Vision-Understanding.md` and
  `.milestones.org` (VU1–VU11; SOTA survey + rationale inside).
- To make this skill global, copy/symlink this dir into `~/.claude/skills/`.
