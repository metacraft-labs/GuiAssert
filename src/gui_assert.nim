## GuiAssert public API
##
## Re-exports GuiAssert's modules (OCR, image math, capture, input, window
## layout) and hosts the visual-assertion harness. The video-production
## modules (the editor, composition, narration, the presenter overlay, the
## keyframe-script parser and driver) live in DemoVideoStudio now
## (https://github.com/metacraft-labs/DemoVideoStudio).
##
##
##   * `GuiAssertHarness` — owns the latest-frame source and OCR/SSIM
##     dispatcher.
##   * `waitForText`      — polls OCR until a needle string appears.
##   * `visualCompare`    — SSIM-based golden frame comparison.
##   * `detectLayoutOverflow` — reports OCR words that cross supplied
##     region boundaries.
##
## A frame is identified by an on-disk image path, and a harness owns a
## `frameSource` closure that produces one. Callers (the visual review agent
## in M4, the timeline editor in M5) point the harness at the latest-rendered
## frame and call into the assertion helpers.
##
## **Live screen capture is now one of those frame sources** (macOS). The
## promise this header used to carry — "a future revision is expected to expose
## live screen capture as a frame source" — is kept by
## `newLiveDisplayHarness` and `newLiveWindowHarness`, which build a harness
## whose `frameSource` captures a fresh still on every call through
## `gui_assert/screen_capture`. Because `waitForText` already re-invokes
## `frameSource` on every poll, pointing a harness at a live source turns it
## into a genuine wait-for-the-UI loop with no change to the assertion code.
##
## The path-based API is unchanged and remains the default. Every assertion
## keeps its `frame: string` overload, so existing consumers
## (`codetracer-marketing`) are unaffected; the new overloads simply omit the
## frame and take it from the harness instead.
##
## `visualCompare` / `detectLayoutOverflow` previously ignored their `harness`
## argument entirely ("reserved for future routing"). The frame-less overloads
## are that routing.

import std/[os, options, strutils, times]

import ./gui_assert/ffmpeg_tools
import ./gui_assert/ocr
import ./gui_assert/image_math
import ./gui_assert/capture
import ./gui_assert/screen_capture
import ./gui_assert/window_layout
import ./gui_assert/input
import ./gui_assert/pacing

export ffmpeg_tools
export ocr
export image_math
export capture
export screen_capture
export window_layout
export input
export pacing

type
  GuiAssertHarness* = ref object
    ## Owns the configuration required for the M4 visual assertions. The
    ## `frameSource` is a closure that returns the path of the latest
    ## available frame (typically refreshed by an external capture engine
    ## or by tests writing into a temp directory).
    frameSource*: proc(): string {.closure.}
    pollIntervalMs*: int
    frameSourceLabel*: string
      ## Human-readable description of where frames come from, e.g.
      ## `path:/tmp/frame.png`, `live-display:0`, `live-window:iTerm`. Carried
      ## so a failure report can say WHAT was captured instead of only that an
      ## assertion failed. Purely descriptive; nothing dispatches on it.

proc newGuiAssertHarness*(framePath: string,
                          pollIntervalMs: int = 100): GuiAssertHarness =
  ## Convenience constructor for tests: every poll returns the same fixed
  ## frame path. Use the closure-based form when the frame rotates.
  result = GuiAssertHarness(
    pollIntervalMs: pollIntervalMs,
    frameSource: proc(): string {.closure.} = framePath,
    frameSourceLabel: "path:" & framePath
  )

proc newGuiAssertHarnessFromSource*(
    source: proc(): string {.closure.},
    pollIntervalMs: int = 100,
    label: string = "closure"): GuiAssertHarness =
  ## Construct a harness with a dynamic frame source.
  result = GuiAssertHarness(
    frameSource: source,
    pollIntervalMs: pollIntervalMs,
    frameSourceLabel: label
  )

# ---------------------------------------------------------------------------
# Live capture frame sources (macOS)
# ---------------------------------------------------------------------------

proc newLiveDisplayHarness*(displayIndex: int = 0,
                            pollIntervalMs: int = 250,
                            frameDir: string = "",
                            captureTimeoutMs: int = 30_000):
                            GuiAssertHarness =
  ## A harness whose frames are **live full-display stills**, captured through
  ## `gui_assert/screen_capture` (ScreenCaptureKit, inside the signed
  ## `GuiAssertCapture.app` TCC subject).
  ##
  ## The default poll interval is 250 ms rather than the path-based 100 ms: a
  ## real capture costs a process launch through `open`, and polling faster
  ## than the capture takes only queues work.
  ##
  ## Raises `StillCaptureUnavailable` on a host that cannot capture at all, and
  ## `StillCaptureDenied` (carrying `grantInstructions`) on the first capture
  ## if the one-time macOS Screen Recording grant has not been given to the
  ## bundle. It never degrades to a stale or blank frame.
  result = newGuiAssertHarnessFromSource(
    newDisplayFrameSource(frameDir, displayIndex, captureTimeoutMs),
    pollIntervalMs,
    "live-display:" & $displayIndex)

proc newLiveWindowHarness*(query: WindowQuery,
                           pollIntervalMs: int = 250,
                           frameDir: string = "",
                           captureTimeoutMs: int = 30_000):
                           GuiAssertHarness =
  ## A harness whose frames are **live stills of one window's own pixels**.
  ##
  ## Prefer this over `newLiveDisplayHarness` whenever the assertion is about a
  ## specific application: a display still cropped to the window's bounds
  ## captures whatever is stacked on top of it, so an overlapping window turns
  ## a real regression into a passing assertion, or the reverse. See
  ## `screen_capture`'s module header.
  var label = "live-window:"
  if query.windowId != 0: label &= "#" & $query.windowId
  if query.owner.len > 0: label &= query.owner
  if query.title.len > 0: label &= "/" & query.title
  if query.titleContains.len > 0: label &= "/~" & query.titleContains
  result = newGuiAssertHarnessFromSource(
    newWindowFrameSource(query, frameDir, captureTimeoutMs),
    pollIntervalMs,
    label)

proc currentFrame*(harness: GuiAssertHarness): string =
  ## Pull one frame from the harness's source and return its path, raising when
  ## the source yields nothing usable.
  ##
  ## For a live harness this performs a capture; for a path-based one it just
  ## returns the configured path. Either way the file is asserted to exist, so
  ## a caller never silently asserts against a frame that was never written.
  if harness.isNil:
    raise newException(ValueError, "GuiAssertHarness is nil")
  if harness.frameSource.isNil:
    raise newException(ValueError, "GuiAssertHarness has no frameSource")
  result = harness.frameSource()
  if result.len == 0:
    raise newException(OcrError,
      "frame source (" & harness.frameSourceLabel & ") returned no path")
  if not fileExists(result):
    raise newException(OcrError,
      "frame source (" & harness.frameSourceLabel & ") returned " & result &
      " but no file exists there")

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

proc visualCompare*(harness: GuiAssertHarness, golden: string,
                    tolerance: float = 0.98): bool =
  ## Frame-less overload: take the frame from the harness's own source (a live
  ## capture for a live harness) and compare it against `golden`.
  ##
  ## This is the "future routing" the three-argument form's doc comment
  ## reserved the `harness` parameter for. The three-argument form is
  ## unchanged.
  result = visualCompare(harness, harness.currentFrame(), golden, tolerance)

proc visualCompareScore*(harness: GuiAssertHarness, golden: string): float =
  ## Frame-less `visualCompareScore`: scores the harness's current frame.
  result = ssimFromPaths(harness.currentFrame(), golden)

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

proc detectLayoutOverflow*(harness: GuiAssertHarness,
                           regions: seq[array[4, int]]): bool =
  ## Frame-less overload: run the overflow check against the harness's own
  ## current frame (a live capture for a live harness).
  result = detectLayoutOverflow(harness, harness.currentFrame(), regions)
