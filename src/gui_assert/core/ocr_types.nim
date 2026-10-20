## GuiAssert core: OCR result types and pure post-processing.
##
## Everything an OCR engine produces, and everything a caller does with the
## words afterwards without touching an engine: the `OcrWord` record (text,
## confidence on the 0..100 scale, a pixel bounding box in the recognised
## image's own coordinates), the preprocessing options, the backend
## selectors, and reading-order reconstruction. The engines themselves
## (Tesseract, Apple Vision, RapidOCR) run subprocesses and live outside the
## core (`gui_assert/ocr` today, `gui_assert/backends/ocr/` as they move); the
## engine interface is `OcrEngine` in `gui_assert/core/interfaces`.

import std/[algorithm, strutils, tables]

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

  OcrResult* = object
    ## What one recognition pass returns: the words, the same words as text
    ## in reading order (see `wordsToReadingOrderText`), the engine that read
    ## them, and the languages it was asked for.
    words*: seq[OcrWord]
    text*: string
    backend*: string
    languages*: seq[string]

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

proc concatenatedText*(words: seq[OcrWord]): string =
  ## Join all detected words with spaces. Convenience helper for substring
  ## matching used by `waitForText`.
  var pieces: seq[string] = @[]
  for w in words:
    if w.text.len > 0:
      pieces.add(w.text)
  result = pieces.join(" ")

proc wordsToReadingOrderText*(words: seq[OcrWord]): string =
  ## Reconstruct human reading-order text from unordered OCR words. Words are
  ## grouped by `(blockNum, lineNum)`; the resulting lines are ordered by their
  ## top-y (the minimum `bbox[1]` in the group), and words within a line by
  ## their left-x (`bbox[0]`). Lines are joined with `"\n"`, words with a
  ## single space.
  var groups = initOrderedTable[(int, int), seq[OcrWord]]()
  for w in words:
    let key = (w.blockNum, w.lineNum)
    if key notin groups:
      groups[key] = @[]
    groups[key].add(w)

  type Line = tuple[topY: int, minX: int, text: string]
  var lines: seq[Line] = @[]
  for key, ws in groups:
    var ordered = ws
    ordered.sort(proc(a, b: OcrWord): int = cmp(a.bbox[0], b.bbox[0]))
    var topY = high(int)
    var minX = high(int)
    var pieces: seq[string] = @[]
    for w in ordered:
      if w.bbox[1] < topY: topY = w.bbox[1]
      if w.bbox[0] < minX: minX = w.bbox[0]
      pieces.add(w.text)
    lines.add((topY: topY, minX: minX, text: pieces.join(" ")))

  # Order lines top-to-bottom, tie-break left-to-right.
  lines.sort(proc(a, b: Line): int =
    result = cmp(a.topY, b.topY)
    if result == 0: result = cmp(a.minX, b.minX))

  var outLines: seq[string] = @[]
  for ln in lines:
    outLines.add(ln.text)
  result = outLines.join("\n")

proc initOcrResult*(words: seq[OcrWord], backend: string,
                    languages: seq[string] = @[]): OcrResult =
  ## Build an `OcrResult`, deriving `text` from `words` in reading order.
  OcrResult(words: words, text: wordsToReadingOrderText(words),
            backend: backend, languages: languages)
