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

import std/[os, osproc, strtabs, strutils, streams, math, tempfiles, times]

import ./media
import ./image_math

type
  OcrError* = object of CatchableError
    ## Raised when Tesseract is missing, exits non-zero, or its TSV output
    ## cannot be parsed.

  OcrBackendUnavailable* = object of CatchableError
    ## Raised when an OPTIONAL OCR/element backend cannot be used on this host
    ## (wrong platform, missing toolchain, or unconfigured). Distinct from
    ## `OcrError` so callers can catch it and fall back to the reproducible
    ## Tesseract default (see `runOcrBestEffort`) instead of treating it as a
    ## hard failure. The default (`obTesseract`) backend NEVER raises this.

  OcrBackend* = enum
    ## Selects which OCR engine `runOcrWithBackend` dispatches to.
    obTesseract    ## Tesseract via `runOcrEx` — the reproducible DEFAULT.
    obAppleVision  ## macOS Vision (`VNRecognizeTextRequest`) via bundled helper.
    obRapidOcr     ## RapidOCR / PP-OCR ONNX runner (external, opt-in).

  ElementBackend* = enum
    ## Selects a semantic UI-element detector for `detectElements`. Only the
    ## no-op `ebNone` ships by default; `ebOmniParser` is a documented,
    ## intentionally-unimplemented stub (see `detectElements`).
    ebNone        ## No element detection; returns an empty seq.
    ebOmniParser  ## OmniParser-class ONNX detector (requires pinned weights).

  DetectedElement* = object
    ## A semantic UI element produced by an element backend (OmniParser-class).
    ## Populated only by ML backends; the shipped code returns none of these.
    label*: string          ## semantic label, e.g. "Save button"
    kind*: string           ## coarse element kind, e.g. "button" / "text"
    confidence*: float      ## detector confidence (0..100)
    bbox*: array[4, int]    ## [x, y, w, h] in pixels

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

# ---------------------------------------------------------------------------
# VU11: pluggable OCR backends (Tesseract DEFAULT; Apple Vision / RapidOCR
# optional & graceful-degrading) + a documented OmniParser-class element stub.
#
# Design: `obTesseract` is the reproducible default and reuses the existing
# `runOcrEx` path verbatim — it adds ZERO new runtime dependencies to the
# default pipeline. The optional backends shell out to external tools and raise
# the typed `OcrBackendUnavailable` (NOT `OcrError`) when the host lacks them, so
# `runOcrBestEffort` can fall back to Tesseract without ever throwing for a
# merely-unavailable backend. Apple Vision (macOS) and RapidOCR both emit the
# same simple pixel TSV — `TEXT\tconf\tx\ty\tw\th` — parsed by `parsePixelTsv`.
# ---------------------------------------------------------------------------

proc parsePixelTsv(output: string): seq[OcrWord] =
  ## Parse the shared optional-backend format emitted by the Apple Vision helper
  ## and the RapidOCR runner: one recognized string per line as
  ## `TEXT\tconf\tx\ty\tw\th`, where `conf` is 0..1 and x/y/w/h are pixels in the
  ## image's own top-left-origin coordinate space. `conf` is scaled to
  ## Tesseract's 0..100 convention so `OcrWord.confidence` is comparable across
  ## backends. Each recognized string becomes one `OcrWord` (Vision/RapidOCR
  ## group at line granularity); `lineNum` counts records, `blockNum` is 0.
  result = @[]
  var idx = 0
  for rawLine in output.splitLines:
    let line = rawLine.strip(leading = false, trailing = true)
    if line.len == 0: continue
    let cols = line.split('\t')
    if cols.len < 6: continue
    var w: OcrWord
    w.text = cols[0]
    if w.text.len == 0: continue
    try:
      w.confidence = parseFloat(cols[1]) * 100.0
      w.bbox[0] = parseInt(cols[2])
      w.bbox[1] = parseInt(cols[3])
      w.bbox[2] = parseInt(cols[4])
      w.bbox[3] = parseInt(cols[5])
    except ValueError:
      continue
    w.lineNum = idx
    w.blockNum = 0
    result.add w
    inc idx

# --- Apple Vision (macOS) --------------------------------------------------

proc resolveSwiftc(): string =
  ## Locate `swiftc`. Honors `SWIFTC`, then `$PATH`, then the standard Xcode
  ## command-line-tools location. Returns "" when unavailable.
  let envBin = getEnv("SWIFTC")
  if envBin.len > 0:
    return (if fileExists(envBin): envBin else: "")
  result = findExe("swiftc")
  if result.len == 0 and fileExists("/usr/bin/swiftc"):
    result = "/usr/bin/swiftc"

proc appleVisionHelperSource(): string =
  ## Path to the bundled Swift helper source. Honors
  ## `GUIASSERT_VISION_HELPER_SRC`; otherwise resolves relative to this module.
  let envSrc = getEnv("GUIASSERT_VISION_HELPER_SRC")
  if envSrc.len > 0:
    return envSrc
  result = currentSourcePath().parentDir / "helpers" / "vision_ocr.swift"

proc appleVisionProbablyAvailable(): bool =
  ## Cheap probe (no compilation): macOS + a resolvable swiftc + the helper
  ## source (or a prebuilt binary via `GUIASSERT_VISION_HELPER`).
  when hostOS != "macosx":
    return false
  else:
    let prebuilt = getEnv("GUIASSERT_VISION_HELPER")
    if prebuilt.len > 0 and fileExists(prebuilt):
      return true
    return resolveSwiftc().len > 0 and fileExists(appleVisionHelperSource())

proc resolveAppleVisionHelper*(): string =
  ## macOS-only. Return the path to a compiled Apple Vision OCR helper binary,
  ## compiling the bundled Swift source on demand with `swiftc` into a cache dir
  ## (recompiled only when missing or older than the source). Honors
  ## `GUIASSERT_VISION_HELPER` (prebuilt binary), `GUIASSERT_VISION_HELPER_SRC`
  ## (source override) and `SWIFTC`. Raises `OcrBackendUnavailable` when the
  ## platform, toolchain, or source is missing — never `OcrError`.
  when hostOS != "macosx":
    raise newException(OcrBackendUnavailable,
      "Apple Vision backend is macOS-only")
  else:
    let prebuilt = getEnv("GUIASSERT_VISION_HELPER")
    if prebuilt.len > 0:
      if fileExists(prebuilt): return prebuilt
      raise newException(OcrBackendUnavailable,
        "GUIASSERT_VISION_HELPER points at " & prebuilt &
        " but no file exists there.")
    let src = appleVisionHelperSource()
    if not fileExists(src):
      raise newException(OcrBackendUnavailable,
        "Apple Vision helper source not found: " & src &
        " (set GUIASSERT_VISION_HELPER_SRC or GUIASSERT_VISION_HELPER).")
    let swiftc = resolveSwiftc()
    if swiftc.len == 0:
      raise newException(OcrBackendUnavailable,
        "swiftc not found (set SWIFTC or install the Xcode command line tools).")
    let cacheDir = getTempDir() / "gui_assert_vision_helper"
    try:
      createDir(cacheDir)
    except OSError as e:
      raise newException(OcrBackendUnavailable,
        "cannot create Apple Vision helper cache dir " & cacheDir & ": " & e.msg)
    let bin = cacheDir / "vision_ocr"
    var needCompile = true
    if fileExists(bin):
      try:
        if getLastModificationTime(bin) >= getLastModificationTime(src):
          needCompile = false
      except OSError:
        discard
    if needCompile:
      # Sanitize the environment for swiftc: a nix profile often exports
      # SDKROOT / DEVELOPER_DIR pointing at a nix-provided Apple SDK whose Swift
      # version does not match the system /usr/bin/swiftc, which makes the
      # compile fail ("no such module 'SwiftShims'"). Dropping them lets the
      # system compiler find its own matching bundled SDK. (No-op when unset.)
      let cenv = newStringTable(modeCaseSensitive)
      for k, v in envPairs():
        if swiftc.startsWith("/usr/") and (k == "SDKROOT" or k == "DEVELOPER_DIR"):
          continue
        cenv[k] = v
      let p = startProcess(command = swiftc, args = @["-O", src, "-o", bin],
                           env = cenv, options = {poStdErrToStdOut})
      let output = p.outputStream().readAll()
      let code = p.waitForExit()
      p.close()
      if code != 0:
        raise newException(OcrBackendUnavailable,
          "swiftc failed to compile the Apple Vision helper (" & $code &
          "):\n" & output)
    return bin

proc runAppleVision(imagePath: string, opts: OcrOptions): seq[OcrWord] =
  ## Run the macOS Apple Vision helper on `imagePath`. `opts` is accepted for API
  ## symmetry but Vision performs its own preprocessing/upscaling, so the
  ## Tesseract-specific knobs (psm/upscale/invert/contrast) do not apply.
  ## Raises `OcrBackendUnavailable` when the backend is unusable, `OcrError` on a
  ## genuine runtime failure of an available helper.
  if not fileExists(imagePath):
    raise newException(OcrError, "OCR image not found: " & imagePath)
  let helper = resolveAppleVisionHelper()
  let p = startProcess(command = helper, args = @[imagePath],
                       options = {poStdErrToStdOut})
  let output = p.outputStream().readAll()
  let code = p.waitForExit()
  p.close()
  if code != 0:
    raise newException(OcrError,
      "Apple Vision helper exited with code " & $code & ":\n" & output)
  result = parsePixelTsv(output)

# --- RapidOCR (optional external ONNX runner) ------------------------------

proc resolveRapidOcrCmd(): seq[string] =
  ## Return the argv prefix for the RapidOCR runner, or `@[]` when unconfigured.
  ## Honors `RAPIDOCR_CMD` (a full command line, parsed shell-style), else looks
  ## for a `rapidocr` executable on `$PATH`. The configured runner must accept
  ## the image path as its LAST argument and print the shared pixel TSV
  ## (`TEXT\tconf\tx\ty\tw\th`) on stdout. GuiAssert bundles no ONNX weights.
  let envCmd = getEnv("RAPIDOCR_CMD")
  if envCmd.len > 0:
    return parseCmdLine(envCmd)
  let p = findExe("rapidocr")
  if p.len > 0:
    return @[p]
  return @[]

proc runRapidOcr(imagePath: string, opts: OcrOptions): seq[OcrWord] =
  ## Shell out to the configured RapidOCR runner (see `resolveRapidOcrCmd`).
  ## Raises `OcrBackendUnavailable` when unconfigured, `OcrError` on runtime
  ## failure. `opts` is accepted for API symmetry (RapidOCR does its own
  ## preprocessing).
  if not fileExists(imagePath):
    raise newException(OcrError, "OCR image not found: " & imagePath)
  let cmd = resolveRapidOcrCmd()
  if cmd.len == 0:
    raise newException(OcrBackendUnavailable,
      "RapidOCR backend not configured. Set RAPIDOCR_CMD to a runner that " &
      "prints 'TEXT\\tconf\\tx\\ty\\tw\\th' pixel rows for its image-path " &
      "argument, or put a 'rapidocr' executable on PATH. GuiAssert ships no " &
      "ONNX weights; see Planned-Work/Vision-Understanding.md (VU11).")
  var args = cmd[1 .. ^1]
  args.add imagePath
  let p = startProcess(command = cmd[0], args = args,
                       options = {poStdErrToStdOut})
  let output = p.outputStream().readAll()
  let code = p.waitForExit()
  p.close()
  if code != 0:
    raise newException(OcrError,
      "RapidOCR runner exited with code " & $code & ":\n" & output)
  result = parsePixelTsv(output)

# --- Dispatch --------------------------------------------------------------

proc runOcrWithBackend*(imagePath: string, backend: OcrBackend,
                        opts: OcrOptions = initOcrOptions()): seq[OcrWord] =
  ## Run OCR through the selected `backend`. `obTesseract` (the DEFAULT
  ## everywhere) uses the reproducible `runOcrEx` path; the optional backends
  ## raise `OcrBackendUnavailable` when the host cannot provide them. Use
  ## `runOcrBestEffort` if you want automatic fallback instead of an exception.
  case backend
  of obTesseract:  runOcrEx(imagePath, opts)
  of obAppleVision: runAppleVision(imagePath, opts)
  of obRapidOcr:   runRapidOcr(imagePath, opts)

proc availableBackends*(): seq[OcrBackend] =
  ## Probe which OCR backends are usable on this host. `obTesseract` is always
  ## listed (default); `obAppleVision` is listed on macOS when swiftc + the
  ## helper source (or a prebuilt binary) are present; `obRapidOcr` is listed
  ## when configured via `RAPIDOCR_CMD` or a `rapidocr` on PATH. The Apple Vision
  ## probe is cheap and does NOT compile the helper.
  result = @[obTesseract]
  if appleVisionProbablyAvailable():
    result.add obAppleVision
  if resolveRapidOcrCmd().len > 0:
    result.add obRapidOcr

proc runOcrBestEffort*(imagePath: string, preferred: seq[OcrBackend],
                       opts: OcrOptions = initOcrOptions()): seq[OcrWord] =
  ## Try `preferred` backends in order, returning the first that succeeds, and
  ## fall back to `obTesseract` if every preferred backend is unavailable. Only
  ## `OcrBackendUnavailable` is swallowed — a genuine `OcrError` from an
  ## available backend propagates. This NEVER throws merely because an optional
  ## backend is missing, so callers get the reproducible Tesseract result.
  for b in preferred:
    try:
      return runOcrWithBackend(imagePath, b, opts)
    except OcrBackendUnavailable:
      discard
  result = runOcrWithBackend(imagePath, obTesseract, opts)

# --- OmniParser-class element backend (documented stub) --------------------

proc detectElements*(imagePath: string,
                     backend: ElementBackend): seq[DetectedElement] =
  ## Detect semantic UI elements (OmniParser-class: buttons, icons, fields with
  ## labels). `ebNone` returns an empty seq. `ebOmniParser` is an intentionally
  ## unimplemented, DOCUMENTED stub: it raises `OcrBackendUnavailable` because a
  ## real implementation requires pinned OmniParser ONNX weights (~hundreds of
  ## MB: an icon-detection model plus a captioning model) and an ONNX runtime,
  ## which would break the reproducible, ML-free default. GuiAssert's pure-CV
  ## layout tree (VU10) plus OCR-text-near-a-region already recovers most of the
  ## STRUCTURAL value; only semantic labels are ML-only. To enable a real
  ## backend, wire a runner analogous to RapidOCR (see VU11 in
  ## Planned-Work/Vision-Understanding.md) — deliberately out of scope here.
  case backend
  of ebNone:
    result = @[]
  of ebOmniParser:
    raise newException(OcrBackendUnavailable,
      "OmniParser element backend requires pinned ONNX weights and an ONNX " &
      "runtime; not bundled for reproducibility. See docs " &
      "(Planned-Work/Vision-Understanding.md, VU11) to enable it.")
