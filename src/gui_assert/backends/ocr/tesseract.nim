## The `tesseract` OCR engine (spec §4), shared by every platform: the default
## on Linux, an alternative on macOS and Windows.
##
## **How it runs.** The `tesseract` program (`TESSERACT_BIN`, else `PATH`; the
## flake pins it) reads the image and writes its word table as TSV to a file
## in a private temporary directory (`backends/ocr/engine_process`), so the
## recognized text never passes through a stream GuiAssert reads as
## diagnostics, and tesseract's own diagnostics are never passed through to
## GuiAssert's stderr (C15). A missing program is exit 4 / `missing-tool`.
##
## **Options**, each honoured exactly or refused (spec §2):
##
## * `--lang <code>…`: tesseract's own language codes (`eng`, `deu`,
##   `chi_sim`, …), joined with `+`. Without `--lang` the engine reads `eng`,
##   and says so in `languages`. A code whose traineddata the installed
##   tesseract does not have (`tesseract --list-langs`) is exit 4 /
##   `unsupported-option`, never dropped.
## * `--psm N`: tesseract's page-segmentation mode, passed through. Without it
##   tesseract's own default (3, automatic) applies.
## * `--invert auto|never|always`: the polarity decision is GuiAssert's, made
##   on the decoded image (`auto` inverts when the mean luma is below
##   `core/ocr_types.autoInvertLumaThreshold`), and tesseract's own
##   auto-inversion (`tessedit_do_invert`) is switched off so the decision is
##   the only one. Without `--invert` tesseract's default applies.
## * `--upscale F`: the image is scaled by `F` (nearest neighbour, pure core)
##   before recognition, and every box is mapped back to the original image's
##   pixels, so boxes are always in the coordinates of the image the caller
##   gave.
## * `--min-confidence C`: words below `C` (0..100) are left out.
##
## Preprocessing (`--invert`, `--upscale`) decodes and re-encodes PNG with the
## pure core, so this engine needs no media backend.
##
## **What it reports.** Word rows (level 5) of tesseract's TSV, with its 0..100
## confidence and pixel box. `block` is tesseract's block number, and `line`
## numbers the distinct (block, paragraph, line) triples in order of first
## appearance, so two paragraphs' first lines are never one line; `text` is in
## reading order (`core/ocr_types.wordsToReadingOrderText`).

import std/[math, options, os, strtabs, strutils, tables]

import ../../core/[desktop_types, ocr_types, interfaces, image, png]
import ../../[cancel, state_store]
import ./engine_process

const
  tesseractName* = "tesseract"
    ## The engine's contract name.
  defaultTesseractTimeoutMs* = 120_000
    ## Bound on one recognition.
  defaultTesseractLanguage* = "eng"
    ## The language read without `--lang`.
  maxTsvBytes = 64 * 1024 * 1024
  missingToolRemedy = "install tesseract (the GuiAssert flake pins it; or a " &
    "distribution or Homebrew package) or set TESSERACT_BIN"

type
  TesseractConfig* = object
    ## What the engine runs with.
    token*: CancelToken      ## cancellation and the deadline; may be nil
    timeoutMs*: int          ## 0: `defaultTesseractTimeoutMs`

# ---------------------------------------------------------------------------
# Pure: tesseract's TSV and language list
# ---------------------------------------------------------------------------

proc parseTesseractTsv*(tsv: string): seq[OcrWord] =
  ## The words of tesseract's TSV output (columns `level page_num block_num
  ## par_num line_num word_num left top width height conf text`, see
  ## https://github.com/tesseract-ocr/tesseract/blob/main/src/api/renderer.cpp).
  ## Keeps level-5 (word) rows with non-blank text; numbers lines as the
  ## module doc says. Raises `ValueError` when the header is missing or a word
  ## row is malformed: a table that cannot be read is never taken for one
  ## that holds no words.
  var sawHeader = false
  var lines = initTable[(int, int, int), int]()
  for raw in tsv.splitLines:
    let line = raw.strip(leading = false, trailing = true, chars = {'\r', '\n'})
    if line.len == 0: continue
    let cols = line.split('\t')
    if not sawHeader:
      if cols.len < 12 or cols[0] != "level" or cols[11] != "text":
        raise newException(ValueError, "the TSV has no header row")
      sawHeader = true
      continue
    if cols.len < 11:
      raise newException(ValueError, "a TSV row has " & $cols.len & " columns")
    if cols[0] != "5": continue
    let text = (if cols.len >= 12: cols[11 .. ^1].join("\t") else: "").strip
    if text.len == 0: continue
    var w: OcrWord
    try:
      let blk = parseInt(cols[2])
      let key = (blk, parseInt(cols[3]), parseInt(cols[4]))
      if key notin lines: lines[key] = lines.len
      w = OcrWord(text: text, blockNum: blk, lineNum: lines[key],
                  bbox: [parseInt(cols[6]), parseInt(cols[7]),
                         parseInt(cols[8]), parseInt(cols[9])],
                  confidence: parseFloat(cols[10]))
    except ValueError:
      raise newException(ValueError, "a TSV word row has a non-numeric field")
    if w.bbox[2] < 0 or w.bbox[3] < 0:
      raise newException(ValueError, "a TSV word row has a negative size")
    w.confidence = clamp(w.confidence, 0.0, 100.0)
    result.add w
  if not sawHeader:
    raise newException(ValueError, "the TSV is empty")

proc parseTesseractLanguages*(listing: string): seq[string] =
  ## The language codes of `tesseract --list-langs` output: every line after
  ## the `List of available languages …:` header.
  var started = false
  for raw in listing.splitLines:
    let l = raw.strip
    if l.len == 0: continue
    if not started:
      if l.startsWith("List of available languages"): started = true
      continue
    result.add l

proc chooseInvert*(gray: GrayImage, mode: OcrInvert): bool =
  ## Whether `--invert mode` inverts `gray` (module doc).
  case mode
  of oiAlways: true
  of oiNever: false
  of oiAuto:
    if gray.pixels.len == 0: false
    else:
      var total = 0
      for c in gray.pixels: total += ord(c)
      total / gray.pixels.len < autoInvertLumaThreshold

proc preprocess*(png: string, upscale: float, invert: Option[OcrInvert]): string =
  ## The PNG tesseract reads for `--upscale` / `--invert`: `png` decoded to
  ## grayscale, scaled by `upscale` (nearest neighbour), inverted when
  ## `chooseInvert` says so, re-encoded. Raises `PngError` for an image the
  ## core cannot decode.
  var gray = decodePngGray(png)
  if upscale != 1.0:
    let w = max(1, int(round(float(gray.width) * upscale)))
    let h = max(1, int(round(float(gray.height) * upscale)))
    if not fitsPixelCap(w, h):
      raise newException(PngError, "--upscale " & $upscale & " makes the image " &
        $w & "x" & $h & ", over the pixel cap")
    gray = scaleNearest(gray, w, h)
  if invert.isSome and chooseInvert(gray, invert.get):
    for i in 0 ..< gray.pixels.len: gray.pixels[i] = char(255 - ord(gray.pixels[i]))
  encodePng(gray)

proc unscale*(words: var seq[OcrWord], upscale: float) =
  ## Map boxes read on an image scaled by `upscale` back to the original's
  ## pixels (edges rounded, sizes from the rounded edges).
  if upscale == 1.0: return
  for w in words.mitems:
    let x0 = int(round(float(w.bbox[0]) / upscale))
    let y0 = int(round(float(w.bbox[1]) / upscale))
    let x1 = int(round(float(w.bbox[0] + w.bbox[2]) / upscale))
    let y1 = int(round(float(w.bbox[1] + w.bbox[3]) / upscale))
    w.bbox = [x0, y0, x1 - x0, y1 - y0]

# ---------------------------------------------------------------------------
# The program
# ---------------------------------------------------------------------------

proc missingTool(msg: string): ref BackendUnavailableError =
  result = unavailable(tesseractName, "missing-tool", msg)
  result.remedy = missingToolRemedy

proc failed(msg: string): ref BackendError =
  newBackendError(BackendError, tesseractName, "ocr-failed", msg)

proc unsupported(msg: string): ref BackendUnavailableError =
  unavailable(tesseractName, "unsupported-option", msg)

proc tesseractBinary*(): string =
  ## `TESSERACT_BIN`, else `tesseract` on `PATH`. Raises
  ## `BackendUnavailableError` / `missing-tool` when neither exists.
  let env = getEnv("TESSERACT_BIN")
  if env.len > 0:
    if fileExists(env): return env
    raise missingTool("TESSERACT_BIN points at " & env & " but no file exists there")
  result = findExe("tesseract")
  if result.len == 0: raise missingTool("tesseract is not on PATH")

proc engineEnv(exe: string): StringTableRef =
  ## The environment for a nix-provided tesseract: without the
  ## `DYLD_*LIBRARY_PATH` of the caller, which would make it load foreign
  ## dylibs.
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if exe.startsWith("/nix/") and k in ["DYLD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH"]:
      continue
    result[k] = v

proc timeoutOf(cfg: TesseractConfig): int =
  if cfg.timeoutMs > 0: cfg.timeoutMs else: defaultTesseractTimeoutMs

proc installedLanguages*(cfg: TesseractConfig): seq[string] =
  ## The languages the installed tesseract has traineddata for.
  let exe = tesseractBinary()
  # `--list-langs` prints to stdout, merged into the diagnostics pipe; it
  # carries no captured content. The listing is short (one code per line,
  # 130 codes with every language pack), so the diagnostics cap is raised.
  let run = runEngine(tesseractName, exe, @["--list-langs"], cfg.token,
                      cfg.timeoutOf, engineEnv(exe), diagnosticCap = 65_536)
  if run.code != 0:
    raise failed("tesseract --list-langs exited with " & $run.code & ": " & run.diagnostics)
  result = parseTesseractLanguages(run.diagnostics)

proc validateTesseractRequest*(req: OcrRequest) =
  ## Refuse what tesseract cannot honour, running nothing
  ## (`OcrEngine.validate`): a page-segmentation mode outside 0..13, an upscale
  ## factor that is not positive, and a language code that is empty or joins
  ## several (`eng+deu`: pass `--lang` once per language). Whether the
  ## installed tesseract has a language is asked of it when the request runs.
  if req.psm.isSome and req.psm.get notin 0 .. 13:
    raise unsupported("tesseract's page-segmentation modes are 0..13")
  if req.upscale.isSome and not (req.upscale.get > 0.0):
    raise unsupported("--upscale must be positive")
  for l in req.languages:
    if l.len == 0 or '+' in l:
      raise unsupported("'" & l & "' is not one tesseract language code " &
        "(pass --lang once per language)")

proc recognizeWithTesseract(cfg: TesseractConfig, req: OcrRequest): OcrResult =
  validateTesseractRequest(req)
  let langs = if req.languages.len > 0: req.languages else: @[defaultTesseractLanguage]
  if not fileExists(req.imagePath):
    raise newBackendError(BackendNotFoundError, tesseractName, "file",
      "no image at " & req.imagePath)
  let exe = tesseractBinary()
  let installed = installedLanguages(cfg)
  for l in langs:
    if l notin installed:
      raise unsupported("the installed tesseract has no '" & l & "' traineddata (" &
        $installed.len & " languages installed; see tesseract --list-langs)")
  let upscale = req.upscale.get(1.0)
  let work = privateTempDir(tesseractName, "guiassert_tesseract_")
  try:
    var input = canonicalPath(req.imagePath)
    if upscale != 1.0 or req.invert.isSome:
      var bytes: string
      try: bytes = readFileCapped(req.imagePath, maxImageFileBytes)
      except IOError as e: raise failed("cannot read " & req.imagePath & ": " & e.msg)
      try:
        input = work / "input.png"
        writeFile(input, preprocess(bytes, upscale, req.invert))
      except PngError as e:
        raise unsupported("--upscale / --invert need a PNG the core can decode: " & e.msg)
      except IOError as e:
        raise failed("cannot write the preprocessed image: " & e.msg)
    let outBase = work / "result"
    var args = @[input, outBase, "-l", langs.join("+")]
    if req.psm.isSome: args.add ["--psm", $req.psm.get]
    if req.invert.isSome: args.add ["-c", "tessedit_do_invert=0"]
    args.add "tsv"
    let run = runEngine(tesseractName, exe, args, cfg.token, cfg.timeoutOf, engineEnv(exe))
    if run.code != 0:
      raise failed("tesseract exited with " & $run.code & ": " & run.diagnostics)
    var tsv: string
    try: tsv = readFileCapped(outBase & ".tsv", maxTsvBytes)
    except IOError as e: raise failed("tesseract wrote no word table: " & e.msg)
    var words: seq[OcrWord]
    try: words = parseTesseractTsv(tsv)
    except ValueError as e: raise failed("tesseract wrote a malformed word table: " & e.msg)
    words.unscale(upscale)
    var kept: seq[OcrWord]
    for w in words:
      if req.minConfidence.isSome and w.confidence < req.minConfidence.get: continue
      kept.add w
    initOcrResult(kept, tesseractName, langs)
  finally:
    try: removeDir(work)
    except OSError: discard

proc tesseractFeatures*(cfg: TesseractConfig, probe: bool): seq[Feature] =
  ## The engine's one feature, `ocr`. Without `probe`: `available` when the
  ## program is found. With `probe`: `supported` only when it runs and lists
  ## the default language.
  proc f(state: FeatureState, reason = "", remedy = ""): Feature =
    Feature(feature: "ocr", backend: tesseractName, state: state,
            reason: (if reason.len > 0: some(reason) else: none(string)),
            remedy: (if remedy.len > 0: some(remedy) else: none(string)))
  try:
    discard tesseractBinary()
    if not probe: return @[f(fsAvailable)]
    if defaultTesseractLanguage in installedLanguages(cfg): return @[f(fsSupported)]
    return @[f(fsUnavailable, "missing-tool",
               "install tesseract's '" & defaultTesseractLanguage & "' traineddata")]
  except BackendUnavailableError as e:
    return @[f(fsUnavailable, e.reason, e.remedy)]
  except BackendError as e:
    return @[f(fsUnavailable, "missing-tool", missingToolRemedy & " (" & e.msg & ")")]

proc newTesseractOcr*(cfg = TesseractConfig()): OcrEngine =
  ## The `tesseract` engine (module doc). Constructing it runs nothing.
  result.name = tesseractName
  result.recognize = proc (req: OcrRequest): OcrResult = recognizeWithTesseract(cfg, req)
  result.validate = proc (req: OcrRequest) = validateTesseractRequest(req)
  result.features = proc (probe: bool): seq[Feature] = tesseractFeatures(cfg, probe)
