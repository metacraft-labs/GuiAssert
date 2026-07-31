## GuiAssert Vision Windows — window detection from pixels only (VU4)
##
## Answers "how many top-level windows are visible, and what is each one's
## text?" from a single decoded frame, **with no OS window API**. This is the
## only option when analysing a recorded mp4, a screen streamed from a
## remote/VM/kiosk session, a single-surface app that draws its own widgets, or
## footage from a machine we cannot introspect. Everything here uses only
## decoded frame pixels (`image_math.GrayImage`) plus OCR (`ocr.runOcr`); it
## never calls `CGWindowList` / `EnumWindows` / `wmctrl`. That OS-driven /
## appium ground-truth path is a SEPARATE capability set (`window_layout.nim`,
## `appium.nim`) and is explicitly not part of this module.
##
## Algorithm (pure CV): desktop windows are light regions on a darker
## background, so the detector
##
##   1. builds a foreground mask by thresholding brightness — the threshold is
##      chosen data-drivenly with **Otsu's method** over the frame histogram
##      (overridable via the `threshold` param),
##   2. connected-component labels the mask with an **iterative** stack-based
##      flood fill (never one recursion per pixel — frames are large),
##   3. keeps components whose connected-pixel area *and* bounding-box area
##      exceed a minimum fraction of the frame and whose aspect ratio is
##      window-plausible (thin slivers rejected), while rejecting a component
##      whose bbox spans essentially the whole frame (that is the background,
##      not a window — this is also what makes a blank/all-dark frame yield
##      zero windows even though Otsu degenerates on a unimodal histogram),
##   4. merges/deduplicates boxes that coincide or nest (keeps the outer box),
##   5. returns the surviving rectangles sorted top-left to bottom-right.
##
## As elsewhere in GuiAssert the *pure* core (`otsuThreshold`,
## `detectWindowRects`, `buildCropArgv`) is separated from the *effectful*
## `detectWindows`, which decodes the frame, runs the pure detector, then crops
## each rectangle with ffmpeg and OCRs it. Binary discovery honours
## `FFMPEG` / `FFMPEG_BIN` / `$PATH` (and `TESSERACT_BIN` via `ocr`) like the
## rest of the library.

import std/[os, osproc, streams, strtabs, strutils, algorithm, tempfiles]

import ./media
import ./image_math
import ./ocr

type
  VisionWindowError* = object of CatchableError
    ## Raised on ffmpeg crop failures or when a frame cannot be processed.

  DetectedWindow* = object
    ## A single window region detected purely from pixels.
    bbox*: array[4, int]      ## [x, y, w, h] in frame pixels
    titleText*: string        ## OCR of the top title-bar band of the region
    text*: string             ## OCR of the whole window region
    confidence*: float        ## detector confidence in [0, 1]

# ---------------------------------------------------------------------------
# Pure CV core
# ---------------------------------------------------------------------------

proc otsuThreshold*(img: GrayImage): int =
  ## Compute a global grayscale threshold with Otsu's method: the level that
  ## maximises the between-class variance of the two brightness classes in the
  ## frame's histogram. Returns a value in `0 .. 255`; pixels with a gray value
  ## strictly greater than the threshold are treated as foreground.
  ##
  ## On a *unimodal* image (e.g. an all-dark frame) no split increases the
  ## between-class variance, so the returned threshold stays `0`. Callers must
  ## therefore not treat "> threshold" alone as proof of a real bimodal split —
  ## `detectWindowRects` additionally rejects a full-frame foreground blob.
  var hist: array[256, int]
  let n = img.width * img.height
  if n <= 0 or img.pixels.len < n:
    return 0
  for i in 0 ..< n:
    inc hist[ord(img.pixels[i])]

  let total = n
  var sumAll = 0.0
  for t in 0 ..< 256:
    sumAll += float(t) * float(hist[t])

  var sumB = 0.0
  var wB = 0
  var maxVar = 0.0
  var threshold = 0
  for t in 0 ..< 256:
    wB += hist[t]
    if wB == 0: continue
    let wF = total - wB
    if wF == 0: break
    sumB += float(t) * float(hist[t])
    let mB = sumB / float(wB)
    let mF = (sumAll - sumB) / float(wF)
    let diff = mB - mF
    let between = float(wB) * float(wF) * diff * diff
    if between > maxVar:
      maxVar = between
      threshold = t
  result = threshold

type
  Component = object
    ## Bounding box + connected-pixel area of one labelled foreground blob.
    minx, miny, maxx, maxy, area: int

proc labelComponents(img: GrayImage, threshold: int,
                     connectivity8: bool): seq[Component] =
  ## Connected-component labelling of the foreground mask
  ## (`gray value > threshold`) via an iterative stack-based flood fill. Uses an
  ## explicit `seq[int]` stack of pixel indices — never per-pixel recursion — so
  ## it is safe on large frames. Returns one `Component` per blob.
  let w = img.width
  let h = img.height
  let n = w * h
  result = @[]
  if n <= 0 or img.pixels.len < n:
    return
  var labels = newSeq[int](n)   # 0 = unvisited
  var stack: seq[int] = @[]
  var comp = 0
  for start in 0 ..< n:
    if labels[start] != 0: continue
    if ord(img.pixels[start]) <= threshold: continue   # background
    inc comp
    labels[start] = comp
    stack.setLen(0)
    stack.add(start)
    var minx = w
    var miny = h
    var maxx = -1
    var maxy = -1
    var area = 0
    while stack.len > 0:
      let idx = stack.pop()
      let px = idx mod w
      let py = idx div w
      inc area
      if px < minx: minx = px
      if px > maxx: maxx = px
      if py < miny: miny = py
      if py > maxy: maxy = py
      for dy in -1 .. 1:
        let ny = py + dy
        if ny < 0 or ny >= h: continue
        for dx in -1 .. 1:
          if dx == 0 and dy == 0: continue
          if not connectivity8 and dx != 0 and dy != 0: continue
          let nx = px + dx
          if nx < 0 or nx >= w: continue
          let nidx = ny * w + nx
          if labels[nidx] != 0: continue
          if ord(img.pixels[nidx]) <= threshold: continue
          labels[nidx] = comp
          stack.add(nidx)
    result.add(Component(minx: minx, miny: miny, maxx: maxx, maxy: maxy,
                         area: area))

proc intersectionArea(a, b: array[4, int]): int =
  ## Area of the axis-aligned overlap of two `[x, y, w, h]` rectangles.
  let ax2 = a[0] + a[2]
  let ay2 = a[1] + a[3]
  let bx2 = b[0] + b[2]
  let by2 = b[1] + b[3]
  let ix = max(0, min(ax2, bx2) - max(a[0], b[0]))
  let iy = max(0, min(ay2, by2) - max(a[1], b[1]))
  result = ix * iy

proc mergeBoxes(boxes: seq[array[4, int]]): seq[array[4, int]] =
  ## Deduplicate coincident / nested rectangles, keeping the outer (larger) box.
  ## Boxes are considered redundant when >90% of their own area is contained in
  ## an already-kept, larger box. Processing largest-first guarantees the outer
  ## box wins.
  var order = boxes
  order.sort(proc(a, b: array[4, int]): int =
    cmp(b[2] * b[3], a[2] * a[3]))   # area descending
  result = @[]
  for box in order:
    let boxArea = box[2] * box[3]
    var redundant = false
    for kept in result:
      let inter = intersectionArea(box, kept)
      if boxArea > 0 and float(inter) / float(boxArea) > 0.9:
        redundant = true
        break
    if not redundant:
      result.add(box)

proc detectWindowRects*(img: GrayImage,
                        threshold: int = -1,
                        minAreaFrac: float = 0.015,
                        maxAreaFrac: float = 0.98,
                        maxAspect: float = 12.0,
                        connectivity8: bool = true): seq[array[4, int]] =
  ## Detect top-level window rectangles from a decoded `GrayImage` using only
  ## pixels (no OS API). Returns `[x, y, w, h]` rectangles sorted top-left to
  ## bottom-right.
  ##
  ## Parameters (all with sane, data-driven defaults):
  ## * `threshold` — brightness cutoff for the foreground mask. `-1` (default)
  ##   computes it with Otsu's method (`otsuThreshold`); pass `0 .. 255` to
  ##   override.
  ## * `minAreaFrac` — a component's connected-pixel area *and* its bbox area
  ##   must each exceed this fraction of the frame. Default `0.015` (1.5%): far
  ##   below any real window yet well above icon/cursor/text specks.
  ## * `maxAreaFrac` — reject a component whose bbox covers more than this
  ##   fraction of the frame; that blob is the background (or a unimodal frame's
  ##   whole-image mask), not a window. Default `0.98`. (A truly 100%-maximised
  ##   full-bleed window is therefore treated as background — an accepted
  ##   trade-off for making blank frames yield zero windows.)
  ## * `maxAspect` — reject slivers whose longer side is more than this multiple
  ##   of the shorter side. Default `12.0`.
  ## * `connectivity8` — 8-connectivity when true (default), else 4.
  let w = img.width
  let h = img.height
  if w <= 0 or h <= 0 or img.pixels.len < w * h:
    return @[]
  let thr = if threshold >= 0: threshold else: otsuThreshold(img)
  let comps = labelComponents(img, thr, connectivity8)
  let frameArea = float(w * h)

  var boxes: seq[array[4, int]] = @[]
  for c in comps:
    let bw = c.maxx - c.minx + 1
    let bh = c.maxy - c.miny + 1
    if bw <= 0 or bh <= 0: continue
    let bboxArea = float(bw * bh)
    # Minimum size: both the filled area and the bbox area must be substantial.
    if float(c.area) < minAreaFrac * frameArea: continue
    if bboxArea < minAreaFrac * frameArea: continue
    # Reject the background / whole-frame blob.
    if bboxArea > maxAreaFrac * frameArea: continue
    # Reject thin slivers (task bars, separators, scrollbars, ...).
    let longSide = float(max(bw, bh))
    let shortSide = float(min(bw, bh))
    if shortSide <= 0.0: continue
    if longSide / shortSide > maxAspect: continue
    boxes.add([c.minx, c.miny, bw, bh])

  result = mergeBoxes(boxes)
  # Deterministic reading order: top-to-bottom, then left-to-right.
  result.sort(proc(a, b: array[4, int]): int =
    result = cmp(a[1], b[1])
    if result == 0: result = cmp(a[0], b[0]))

# ---------------------------------------------------------------------------
# Effectful: crop each rect + OCR
# ---------------------------------------------------------------------------

proc buildCropArgv*(framePath: string, x, y, w, h: int,
                    outPng: string): seq[string] =
  ## Pure builder for the ffmpeg argv (no leading binary token) that crops the
  ## rectangle `(x, y, w, h)` out of `framePath` to a single PNG at `outPng`.
  @[
    "-hide_banner",
    "-loglevel", "error",
    "-y",
    "-i", framePath,
    "-vf", "crop=" & $w & ":" & $h & ":" & $x & ":" & $y,
    "-frames:v", "1",
    outPng
  ]

proc sanitizedEnv(binPath: string): StringTableRef =
  ## Mirror image_math/media/video_analysis: on nix-store binaries drop DYLD_*
  ## so the dynamic linker does not splice in incompatible Homebrew libs.
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if (k == "DYLD_LIBRARY_PATH" or k == "DYLD_FALLBACK_LIBRARY_PATH") and
       binPath.startsWith("/nix/"):
      continue
    result[k] = v

proc resolveFfmpeg(): string =
  ## Locate ffmpeg. Honors `FFMPEG`, then delegates to
  ## `media.resolveFfmpegBinary` (which honors `FFMPEG_BIN`, then `$PATH`).
  let envBin = getEnv("FFMPEG")
  if envBin.len > 0:
    if not fileExists(envBin):
      raise newException(VisionWindowError,
        "FFMPEG points at " & envBin & " but no file exists there.")
    return envBin
  try:
    return resolveFfmpegBinary()
  except MediaCompositionError as e:
    raise newException(VisionWindowError, e.msg)

proc runCrop(ffmpegBin, framePath: string, x, y, w, h: int, outPng: string) =
  ## Crop `(x, y, w, h)` from `framePath` into `outPng` with ffmpeg.
  let argv = buildCropArgv(framePath, x, y, w, h, outPng)
  let env = sanitizedEnv(ffmpegBin)
  let p = startProcess(
    command = ffmpegBin,
    args = argv,
    env = env,
    options = {poStdErrToStdOut}
  )
  let output = p.outputStream().readAll()
  let code = p.waitForExit()
  p.close()
  if code != 0:
    raise newException(VisionWindowError,
      "ffmpeg crop failed (" & $code & ") on " & framePath & ": " & output)
  if not (fileExists(outPng) and getFileSize(outPng) > 0):
    raise newException(VisionWindowError,
      "ffmpeg produced no crop at " & outPng)

proc detectWindows*(framePath: string): seq[DetectedWindow] =
  ## Decode `framePath`, detect window rectangles purely from pixels
  ## (`detectWindowRects`), then for each rectangle crop the ORIGINAL frame with
  ## ffmpeg and `runOcr` it to obtain the region's `text`; a top band
  ## (`min(32px, 8% of height)`) is cropped and OCR'd separately for
  ## `titleText`. `confidence` is the fraction of the bbox that is foreground
  ## (fill ratio) — a solid window fills its bbox, a sliver/noise does not.
  ##
  ## All crop temp files are written to a fresh temp dir that is removed before
  ## returning. Honors FFMPEG / FFMPEG_BIN / PATH and TESSERACT_BIN like the
  ## rest of the library.
  if not fileExists(framePath):
    raise newException(VisionWindowError, "Frame not found: " & framePath)

  let img = decodeGray(framePath)
  let rects = detectWindowRects(img)
  let thr = otsuThreshold(img)
  let ffmpegBin = resolveFfmpeg()

  result = @[]
  if rects.len == 0:
    return

  let tmpDir = createTempDir("gui_assert_win_", "")
  try:
    for i, rect in rects:
      # Clamp the rectangle to the frame (defensive; components are in-bounds).
      var rx = max(0, rect[0])
      var ry = max(0, rect[1])
      var rw = rect[2]
      var rh = rect[3]
      if rx + rw > img.width: rw = img.width - rx
      if ry + rh > img.height: rh = img.height - ry
      if rw <= 0 or rh <= 0: continue

      # Confidence = fill ratio of foreground within the bbox.
      var fg = 0
      for yy in ry ..< ry + rh:
        let rowBase = yy * img.width
        for xx in rx ..< rx + rw:
          if ord(img.pixels[rowBase + xx]) > thr: inc fg
      let conf = clamp(float(fg) / float(rw * rh), 0.0, 1.0)

      # Whole-region OCR.
      let regionPng = tmpDir / ("region_" & align($i, 5, '0') & ".png")
      runCrop(ffmpegBin, framePath, rx, ry, rw, rh, regionPng)
      let regionWords = runOcr(regionPng)
      let regionText = concatenatedText(regionWords)

      # Title-bar band OCR (top ~8% of the region, capped at 32px).
      var bandH = min(32, max(8, rh * 8 div 100))
      if bandH > rh: bandH = rh
      var titleText = ""
      if bandH > 0:
        let titlePng = tmpDir / ("title_" & align($i, 5, '0') & ".png")
        runCrop(ffmpegBin, framePath, rx, ry, rw, bandH, titlePng)
        titleText = concatenatedText(runOcr(titlePng))

      result.add(DetectedWindow(
        bbox: [rx, ry, rw, rh],
        titleText: titleText,
        text: regionText,
        confidence: conf
      ))
  finally:
    try:
      removeDir(tmpDir)
    except OSError:
      discard
