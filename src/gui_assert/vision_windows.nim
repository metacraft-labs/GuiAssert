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
## The *pure* detector (`otsuThreshold`, `detectWindowRects` and the
## helpers below it) lives in the pure core, `gui_assert/core/vision_windows`,
## and is re-exported here. This module keeps the *effectful* composition,
## `detectWindows`, which decodes the frame, runs the pure detector, then crops
## each rectangle with ffmpeg and OCRs it (`buildCropArgv` is its pure argv
## builder). Binary discovery honours
## `FFMPEG` / `FFMPEG_BIN` / `$PATH` (and `TESSERACT_BIN` via `ocr`) like the
## rest of the library.

import std/[os, osproc, streams, strtabs, strutils, tempfiles]

import ./ffmpeg_tools
import ./image_math
import ./ocr
import ./core/vision_windows as core_vision_windows

# The pure detector (`otsuThreshold`, `detectWindowRects`, the morphology,
# line and profile helpers, `buildRegionTree`) and the `DetectedWindow` /
# `VisionWindowError` types live in `gui_assert/core/vision_windows`; they are
# re-exported so `import gui_assert/vision_windows` keeps offering them.
export core_vision_windows

# ---------------------------------------------------------------------------
# Effectful: crop each rect + OCR
# ---------------------------------------------------------------------------

proc buildCropArgv*(framePath: string, x, y, w, h: int,
                    outPng: string): seq[string] =
  ## Pure builder for the ffmpeg argv (no leading binary token) that crops the
  ## rectangle `(x, y, w, h)` out of `framePath` to a single PNG at `outPng`.
  ## The input is `ffmpeg_tools.ffmpegInputUrl(framePath)`, so a name starting with
  ## `-` or naming a protocol is read as a file.
  @[
    "-hide_banner",
    "-loglevel", "error",
    "-y",
    "-i", ffmpegInputUrl(framePath),
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
  ## `ffmpeg_tools.resolveFfmpegBinary` (which honors `FFMPEG_BIN`, then `$PATH`).
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
