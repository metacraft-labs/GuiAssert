## GuiAssert public API
##
## Re-exports the M2/M3 modules (parser, driver, media, speech_synth) and
## promotes the package root to host the M4 visual-assertion harness:
##
##   * `GuiAssertHarness` — owns the latest-frame source and OCR/SSIM
##     dispatcher.
##   * `waitForText`      — polls OCR until a needle string appears.
##   * `visualCompare`    — SSIM-based golden frame comparison.
##   * `detectLayoutOverflow` — reports OCR words that cross supplied
##     region boundaries.
##
## The harness is deliberately simple: a frame is identified by an on-disk
## image path. Callers (the visual review agent in M4, the timeline editor
## in M5) point the harness at the latest-rendered frame and call into the
## assertion helpers. A future revision is expected to expose live screen
## capture as a frame source.

import std/[os, options, strutils, times]

import ./gui_assert/parser
import ./gui_assert/driver
import ./gui_assert/media
import ./gui_assert/speech_synth
import ./gui_assert/ocr
import ./gui_assert/image_math
import ./gui_assert/storyboard

export parser
export driver
export media
export speech_synth
export ocr
export image_math
export storyboard

type
  GuiAssertHarness* = ref object
    ## Owns the configuration required for the M4 visual assertions. The
    ## `frameSource` is a closure that returns the path of the latest
    ## available frame (typically refreshed by an external capture engine
    ## or by tests writing into a temp directory).
    frameSource*: proc(): string {.closure.}
    pollIntervalMs*: int

proc newGuiAssertHarness*(framePath: string,
                          pollIntervalMs: int = 100): GuiAssertHarness =
  ## Convenience constructor for tests: every poll returns the same fixed
  ## frame path. Use the closure-based form when the frame rotates.
  result = GuiAssertHarness(
    pollIntervalMs: pollIntervalMs,
    frameSource: proc(): string {.closure.} = framePath
  )

proc newGuiAssertHarnessFromSource*(
    source: proc(): string {.closure.},
    pollIntervalMs: int = 100): GuiAssertHarness =
  ## Construct a harness with a dynamic frame source.
  result = GuiAssertHarness(
    frameSource: source,
    pollIntervalMs: pollIntervalMs
  )

# ---------------------------------------------------------------------------
# OCR-driven assertions
# ---------------------------------------------------------------------------

proc waitForText*(harness: GuiAssertHarness, needle: string,
                  timeoutMs: int = 5000): bool =
  ## Repeatedly OCR the latest frame and return `true` as soon as `needle`
  ## appears as a case-sensitive substring of the concatenated word list.
  ## Returns `false` when the timeout elapses without a match.
  ##
  ## The function performs at least one OCR pass even when `timeoutMs == 0`.
  if harness.isNil:
    raise newException(ValueError, "GuiAssertHarness is nil")
  if harness.frameSource.isNil:
    raise newException(ValueError, "GuiAssertHarness has no frameSource")
  let deadline = epochTime() + float(timeoutMs) / 1000.0
  let pollSec = max(float(harness.pollIntervalMs) / 1000.0, 0.001)
  while true:
    let framePath = harness.frameSource()
    if framePath.len > 0 and fileExists(framePath):
      let words = runOcr(framePath)
      let blob = concatenatedText(words)
      if needle in blob:
        return true
    if epochTime() >= deadline:
      return false
    sleep(int(pollSec * 1000.0))

proc regionText*(harness: GuiAssertHarness): seq[OcrWord] =
  ## Run OCR on the current frame and return the word list. Useful for
  ## ad-hoc inspection from tests and reviewer agents.
  if harness.frameSource.isNil:
    raise newException(ValueError, "GuiAssertHarness has no frameSource")
  let p = harness.frameSource()
  if p.len == 0 or not fileExists(p):
    raise newException(OcrError, "No frame available at " & p)
  result = runOcr(p)

# ---------------------------------------------------------------------------
# SSIM-based comparison
# ---------------------------------------------------------------------------

proc visualCompare*(harness: GuiAssertHarness, frame: string,
                    golden: string, tolerance: float = 0.98): bool =
  ## Compare `frame` against `golden` using whole-image SSIM. Returns
  ## `true` when SSIM is greater than or equal to `tolerance`.
  ##
  ## The `harness` argument is currently unused by the comparator itself
  ## but kept in the signature so future revisions can route the call
  ## through the harness's frame-grabbing pipeline.
  discard harness  # reserved for future routing
  let score = ssimFromPaths(frame, golden)
  result = score >= tolerance

proc visualCompareScore*(harness: GuiAssertHarness, frame: string,
                         golden: string): float =
  ## Variant of `visualCompare` that returns the raw SSIM score so callers
  ## can log it or pick custom thresholds.
  discard harness
  result = ssimFromPaths(frame, golden)

# ---------------------------------------------------------------------------
# Layout overflow detection
# ---------------------------------------------------------------------------

proc rectsIntersect(a, b: array[4, int]): bool =
  ## True iff axis-aligned rectangles `a` and `b` overlap. Each rectangle is
  ## `[x, y, w, h]` in pixels.
  let ax2 = a[0] + a[2]
  let ay2 = a[1] + a[3]
  let bx2 = b[0] + b[2]
  let by2 = b[1] + b[3]
  result = not (ax2 <= b[0] or bx2 <= a[0] or ay2 <= b[1] or by2 <= a[1])

proc rectContains(outer, inner: array[4, int]): bool =
  ## True iff `outer` fully contains `inner`.
  let ix2 = inner[0] + inner[2]
  let iy2 = inner[1] + inner[3]
  let ox2 = outer[0] + outer[2]
  let oy2 = outer[1] + outer[3]
  result = inner[0] >= outer[0] and inner[1] >= outer[1] and
           ix2 <= ox2 and iy2 <= oy2

proc detectLayoutOverflow*(harness: GuiAssertHarness, frame: string,
                           regions: seq[array[4, int]]): bool =
  ## Returns `true` if any OCR word's bounding box crosses one of the
  ## supplied region boundaries. A word **crosses** a region when it
  ## intersects the region but is not fully contained in it.
  ##
  ## The intuition: each `region` rect represents a pane whose content is
  ## supposed to stay inside its boundary. If text spills over the edge,
  ## the visual review agent should flag it.
  discard harness
  if not fileExists(frame):
    raise newException(OcrError, "Frame not found: " & frame)
  let words = runOcr(frame)
  for w in words:
    if w.text.len == 0: continue
    for region in regions:
      if rectsIntersect(w.bbox, region) and not rectContains(region, w.bbox):
        return true
  return false
