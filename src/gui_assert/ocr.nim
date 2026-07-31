## GuiAssert OCR Dispatcher
##
## The library spec calls for native macOS Vision / Windows.Media.Ocr /
## Linux Tesseract backends behind a unified API. The M4 milestone agreed to
## keep the FFI surface small and ship a Tesseract-based dispatcher first,
## documenting native bindings as a follow-up. This module therefore:
##
##   1. Locates a `tesseract` binary (`TESSERACT_BIN`, then `$PATH`).
##   2. Runs it on an image, requesting TSV-formatted word boxes
##      (`-c tessedit_create_tsv=1` via the `tsv` output config).
##   3. Parses the TSV into `OcrWord` records that carry bounding-box
##      coordinates in pixels.
##
## We **fail loudly** when `tesseract` is not on PATH — there are no graceful
## skips. The repository's setup notes instruct developers to install it via
## `brew install tesseract` (macOS), `nix-env -iA nixpkgs.tesseract` (Nix
## hosts), or distro packages on Linux.

import std/[os, osproc, strtabs, strutils, streams, math, tempfiles]

import ./media
import ./image_math

type
  OcrError* = object of CatchableError
    ## Raised when Tesseract is missing, exits non-zero, or its TSV output
    ## cannot be parsed.

  OcrWord* = object
    ## A single recognised word.
    text*: string
    confidence*: float
    bbox*: array[4, int]  ## [x, y, w, h] in pixels
    lineNum*: int
    blockNum*: int

  OcrInvert* = enum
    ## Dark-mode inversion policy for `runOcrEx`. Tesseract expects
    ## dark-on-light text; light-on-dark UI frames must be inverted first.
    oiAuto     ## decide from region mean luma (invert dark backgrounds)
    oiNever    ## never invert
    oiAlways   ## always invert (`ffmpeg negate`)

  OcrOptions* = object
    ## Preprocessing knobs for `runOcrEx` / `runOcrMultiPsm` (VU9).
    psm*: int         ## tesseract page-segmentation mode (default 6)
    upscale*: float   ## Lanczos upscale factor before OCR (default 1.0)
    invert*: OcrInvert  ## dark-mode inversion policy (default oiAuto)
    contrast*: bool   ## apply a light contrast stretch (default false)

const
  ## Auto-invert luma threshold: a decoded grayscale whose MEAN pixel value is
  ## below this (0-255 scale) is treated as a dark background and inverted
  ## before OCR. 110 sits below a neutral mid-gray (128) so ordinary
  ## light/white document backgrounds (mean ~200+) are never touched, while
  ## typical dark editor/terminal chrome (mean ~20-70) is caught.
  autoInvertLumaThreshold* = 110.0

proc initOcrOptions*(psm = 6, upscale = 1.0, invert = oiAuto,
                     contrast = false): OcrOptions =
  ## Construct `OcrOptions` with the VU9 defaults (psm 6, no upscale, auto
  ## inversion, no contrast stretch). Prefer this over a raw object
  ## constructor so omitted fields get the intended defaults rather than
  ## Nim's zero values (`psm=0` is tesseract's orientation-only mode).
  OcrOptions(psm: psm, upscale: upscale, invert: invert, contrast: contrast)

proc resolveTesseractBinary*(): string =
  ## Locate the Tesseract binary. Honors `TESSERACT_BIN`, then `$PATH`.
  ## Raises `OcrError` with installation guidance when missing.
  let envBin = getEnv("TESSERACT_BIN")
  if envBin.len > 0:
    if not fileExists(envBin):
      raise newException(OcrError,
        "TESSERACT_BIN points at " & envBin & " but no file exists there.")
    return envBin
  let p = findExe("tesseract")
  if p.len == 0:
    raise newException(OcrError,
      "tesseract not found on PATH. Install via `brew install tesseract` " &
      "(macOS), `nix-env -iA nixpkgs.tesseract` (Nix), or the appropriate " &
      "distribution package on Linux.")
  return p

proc sanitizedEnv(path: string): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if (k == "DYLD_LIBRARY_PATH" or k == "DYLD_FALLBACK_LIBRARY_PATH") and
       path.startsWith("/nix/"):
      continue
    result[k] = v

proc parseTsv(output: string): seq[OcrWord] =
  ## Parse Tesseract's `--psm 6 tsv` output. The TSV columns are:
  ##
  ##   level page_num block_num par_num line_num word_num
  ##     left top width height conf text
  ##
  ## The header row is `level\tpage_num\t...`; data rows have `level=5` for
  ## individual words (per Tesseract's TSV docs). We keep only those.
  result = @[]
  var sawHeader = false
  for rawLine in output.splitLines:
    let line = rawLine.strip(leading = false, trailing = true)
    if line.len == 0: continue
    let cols = line.split('\t')
    if not sawHeader:
      # First non-empty line is the header.
      sawHeader = true
      if cols.len >= 1 and cols[0] == "level":
        continue
      # Some Tesseract builds skip header; fall through and try to parse.
    if cols.len < 12: continue
    var level: int
    try:
      level = parseInt(cols[0])
    except ValueError:
      continue
    if level != 5: continue   # 5 = word-level row
    let text = cols[11]
    if text.len == 0: continue
    var w: OcrWord
    w.text = text
    try:
      w.blockNum = parseInt(cols[2])
      w.lineNum = parseInt(cols[4])
      w.bbox[0] = parseInt(cols[6])
      w.bbox[1] = parseInt(cols[7])
      w.bbox[2] = parseInt(cols[8])
      w.bbox[3] = parseInt(cols[9])
      w.confidence = parseFloat(cols[10])
    except ValueError:
      continue
    result.add w

proc runTesseractTsv(imagePath: string, psm: int,
                     disableAutoInvert = false): seq[OcrWord] =
  ## Shell out to tesseract for `imagePath` at page-segmentation mode `psm`,
  ## requesting TSV word boxes, and parse the result. Shared by `runOcr` and
  ## `runOcrEx`. Bounding boxes are in `imagePath`'s own pixel space.
  ##
  ## When `disableAutoInvert` is true, tesseract's built-in polarity heuristic
  ## (`tessedit_do_invert`, on by default) is turned OFF. `runOcrEx` sets this
  ## so that its own `OcrOptions.invert` decision is authoritative and
  ## deterministic — otherwise tesseract silently re-inverts light-on-dark text
  ## even when the caller asked for `oiNever`, defeating the option. `runOcr`
  ## leaves it at tesseract's default (auto-invert ON) to preserve its exact
  ## legacy behavior.
  let tesseractBin = resolveTesseractBinary()
  let env = sanitizedEnv(tesseractBin)
  # `stdout` as output base + `tsv` config => Tesseract writes TSV to stdout.
  var args = @[imagePath, "stdout", "--psm", $psm]
  if disableAutoInvert:
    args.add("-c")
    args.add("tessedit_do_invert=0")
  args.add("-c")
  args.add("tessedit_create_tsv=1")
  args.add("tsv")
  let p = startProcess(
    command = tesseractBin,
    args = args,
    env = env,
    options = {poStdErrToStdOut}
  )
  let output = p.outputStream().readAll()
  let code = p.waitForExit()
  p.close()
  if code != 0:
    raise newException(OcrError,
      "tesseract exited with code " & $code & ":\n" & output)
  result = parseTsv(output)

proc runOcr*(imagePath: string): seq[OcrWord] =
  ## Run Tesseract on `imagePath` and return word-level OCR records.
  ## Bounding boxes are pixels in the image's coordinate system.
  ##
  ## This is the original, preprocessing-free path (`--psm 6`, no upscale, no
  ## inversion) and is intentionally left behaviorally identical for callers
  ## and tests that depend on it. For the VU9 improvements use `runOcrEx` /
  ## `runOcrMultiPsm`.
  ##
  ## Raises `OcrError` on subprocess failure.
  if not fileExists(imagePath):
    raise newException(OcrError, "OCR image not found: " & imagePath)
  result = runTesseractTsv(imagePath, 6)

# ---------------------------------------------------------------------------
# VU9: preprocessing-aware OCR (upscale + dark-mode inversion + per-PSM)
# ---------------------------------------------------------------------------

proc resolveFfmpeg(): string =
  ## Locate ffmpeg for preprocessing. Honors `FFMPEG`, then delegates to
  ## `media.resolveFfmpegBinary` (which honors `FFMPEG_BIN`, then `$PATH`).
  let envBin = getEnv("FFMPEG")
  if envBin.len > 0:
    if not fileExists(envBin):
      raise newException(OcrError,
        "FFMPEG points at " & envBin & " but no file exists there.")
    return envBin
  try:
    return resolveFfmpegBinary()
  except MediaCompositionError as e:
    raise newException(OcrError, e.msg)

proc meanLuma(imagePath: string): float =
  ## Mean grayscale pixel value (0-255) of `imagePath`, via `image_math`'s
  ## ffmpeg-backed `decodeGray`. Used by `oiAuto` to detect dark backgrounds.
  let img = decodeGray(imagePath)
  if img.pixels.len == 0:
    return 255.0
  var total = 0.0
  for i in 0 ..< img.pixels.len:
    total += float(img.pixels[i].uint8)
  result = total / float(img.pixels.len)

proc buildPreprocessFilter(opts: OcrOptions, doInvert: bool): string =
  ## Build the ffmpeg `-vf` chain for the requested preprocessing, or the empty
  ## string when nothing is requested.
  var parts: seq[string] = @[]
  if opts.upscale > 1.0:
    let u = formatFloat(opts.upscale, ffDecimal, precision = 6)
    parts.add("scale=iw*" & u & ":ih*" & u & ":flags=lanczos")
  if opts.contrast:
    # Light contrast stretch only (keeps thin glyph strokes intact).
    parts.add("eq=contrast=1.3")
  if doInvert:
    parts.add("negate")
  result = parts.join(",")

proc preprocessToPng(imagePath: string, opts: OcrOptions,
                     doInvert: bool): string =
  ## Run ffmpeg to apply `opts` (+ the resolved invert decision) to `imagePath`,
  ## writing a temp PNG whose path is returned. The caller owns / removes it.
  let ffmpegBin = resolveFfmpeg()
  let (tmpFile, tmpPath) = createTempFile("gui_assert_ocr_", ".png")
  tmpFile.close()
  let filter = buildPreprocessFilter(opts, doInvert)
  let env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if (k == "DYLD_LIBRARY_PATH" or k == "DYLD_FALLBACK_LIBRARY_PATH") and
       ffmpegBin.startsWith("/nix/"):
      continue
    env[k] = v
  let p = startProcess(
    command = ffmpegBin,
    args = @[
      "-hide_banner", "-loglevel", "error", "-y",
      "-i", imagePath,
      "-vf", filter,
      "-frames:v", "1",
      tmpPath
    ],
    env = env,
    options = {poStdErrToStdOut}
  )
  let output = p.outputStream().readAll()
  let code = p.waitForExit()
  p.close()
  if code != 0:
    try: removeFile(tmpPath)
    except OSError: discard
    raise newException(OcrError,
      "ffmpeg OCR preprocessing failed (" & $code & ") on " & imagePath &
      " with -vf '" & filter & "': " & output)
  result = tmpPath

proc runOcrEx*(imagePath: string, opts: OcrOptions): seq[OcrWord] =
  ## Preprocess `imagePath` per `opts` (Lanczos upscale, dark-mode inversion,
  ## optional light contrast) with ffmpeg, then run tesseract at `opts.psm`.
  ##
  ## Returned bounding boxes are ALWAYS in the ORIGINAL image's coordinate
  ## space: when `opts.upscale > 1.0`, coordinates are divided back down by the
  ## upscale factor so callers/tests never see upscaled pixels.
  ##
  ## `oiAuto` decodes a grayscale of the original image and inverts when the
  ## mean luma is below `autoInvertLumaThreshold` (dark background). `oiAlways`/
  ## `oiNever` force the decision. Raises `OcrError` on subprocess failure.
  ##
  ## Unlike `runOcr`, this path disables tesseract's own built-in polarity
  ## heuristic (`tessedit_do_invert`) so the `invert` option is the single,
  ## deterministic source of truth for polarity — otherwise tesseract silently
  ## re-inverts light-on-dark text even under `oiNever`. Consequently `oiNever`
  ## genuinely leaves light-on-dark UI text unreadable, which is exactly the
  ## dark-mode failure `oiAuto`/`oiAlways` fix.
  if not fileExists(imagePath):
    raise newException(OcrError, "OCR image not found: " & imagePath)

  # Normalize fields so an under-specified object constructor is still safe.
  var o = opts
  if o.psm <= 0: o.psm = 6
  if o.upscale <= 0.0: o.upscale = 1.0

  let doInvert =
    case o.invert
    of oiAlways: true
    of oiNever: false
    of oiAuto: meanLuma(imagePath) < autoInvertLumaThreshold

  let needsPreprocess = o.upscale > 1.0 or o.contrast or doInvert
  if not needsPreprocess:
    return runTesseractTsv(imagePath, o.psm, disableAutoInvert = true)

  let prepped = preprocessToPng(imagePath, o, doInvert)
  try:
    result = runTesseractTsv(prepped, o.psm, disableAutoInvert = true)
  finally:
    try: removeFile(prepped)
    except OSError: discard

  # Rescale bboxes from upscaled space back to the original image space.
  if o.upscale > 1.0:
    for w in result.mitems:
      for k in 0 ..< 4:
        w.bbox[k] = int(round(float(w.bbox[k]) / o.upscale))

proc bboxesRoughlyEqual(a, b: array[4, int], tol: int): bool =
  for k in 0 ..< 4:
    if abs(a[k] - b[k]) > tol:
      return false
  true

proc runOcrMultiPsm*(imagePath: string, psms: seq[int],
                     opts: OcrOptions): seq[OcrWord] =
  ## Run `runOcrEx` once per PSM in `psms` (sharing `opts`, whose own `psm`
  ## field is ignored) and MERGE the results, de-duplicating words by
  ## (text, approximately-equal bbox). This gives busy frames both block
  ## (`--psm 6`) and sparse (`--psm 11`) coverage — the direct fix for the VU7
  ## gap where a smaller window heading is swamped by a wall of block text.
  ##
  ## The first PSM's reading (typically block mode) is kept as the base; each
  ## later PSM only contributes words not already present. Bounding boxes are in
  ## original image space (see `runOcrEx`).
  result = @[]
  # bbox tolerance scales a little with upscale rounding; a few px is plenty.
  const tol = 6
  for psm in psms:
    var o = opts
    o.psm = psm
    let words = runOcrEx(imagePath, o)
    for w in words:
      var dup = false
      for existing in result:
        if existing.text == w.text and
           bboxesRoughlyEqual(existing.bbox, w.bbox, tol):
          dup = true
          break
      if not dup:
        result.add(w)

proc concatenatedText*(words: seq[OcrWord]): string =
  ## Join all detected words with spaces. Convenience helper for substring
  ## matching used by `waitForText`.
  var pieces: seq[string] = @[]
  for w in words:
    if w.text.len > 0:
      pieces.add(w.text)
  result = pieces.join(" ")
