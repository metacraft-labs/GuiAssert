## The `apple-vision` OCR engine: macOS Vision's `VNRecognizeTextRequest`
## (spec §4.1), the default OCR backend on macOS.
##
## **How it runs.** Vision is a Swift / Objective-C API, so recognition runs in
## GuiAssert's small Swift helper (`helpers/vision_ocr.swift`, `--json` mode),
## compiled on first use with the system `swiftc` (`gui_assert/swift_helper`)
## from a copy of its source embedded in this module at build time, so an
## installed `guiassert` does not depend on a source checkout. Recognizing an
## image file needs no TCC permission: Vision reads the file, not the screen.
##
## **What it reports** (the frozen `OcrWord` of spec §7.5):
##
## * one `OcrWord` per whitespace-separated word of each recognized line, with
##   the box Vision gives that word's character range, in pixels of the
##   recognized image with a top-left origin. A line for which Vision gives no
##   word boxes is reported as one word holding the whole line, with the
##   line's box, rather than as words carrying a box that is not theirs.
## * `confidence` is the line's Vision confidence (0..1) scaled to 0..100;
##   Vision scores whole lines, so every word of a line carries its line's.
## * `line` numbers rows of text top to bottom: Vision may return the words of
##   one row as several observations (two words far apart on one row), and
##   observations whose vertical extents overlap by at least half the shorter
##   one's height are one row (`groupRows`). `block` is 0: Vision reports no
##   blocks. `text` is therefore reading order: rows top to bottom, words left
##   to right (`core/ocr_types.wordsToReadingOrderText`).
## * `languages` are the languages Vision ran with: the `--lang` codes, else
##   Vision's default, in Vision's own spelling (`en-US`, `zh-Hans`, …). A code
##   accurate recognition does not support is refused (exit 4 /
##   `unsupported-option`), never dropped.
##
## Recognition is at the accurate level with language correction off, so text
## on screen (identifiers, numbers, nonces) is read as drawn. The contract has
## no recognition-level flag (spec §7.5), so the level is not selectable.
## Tesseract's preprocessing knobs (`--psm`, `--upscale`, `--invert`) have no
## Vision equivalent and are refused (`unsupported-option`) before anything
## runs.
##
## **Captured content** (C15): the helper writes its result to a file in a
## private temporary directory, removed afterwards; its diagnostics name paths
## and codes only, and recognized text appears only in the returned
## `OcrResult` (`backends/ocr/engine_process`).
##
## Off macOS the constructor returns an engine whose every operation is
## `backend-unavailable` / `wrong-platform` (spec §3.3).

import std/[algorithm, json, options, os, strutils]

import ../../core/[desktop_types, ocr_types, interfaces]
import ../../[cancel, state_store, swift_helper]
import ./engine_process

const
  appleVisionName* = "apple-vision"
    ## The engine's contract name.
  defaultVisionTimeoutMs* = 120_000
    ## Bound on one recognition by the helper.
  maxVisionResultBytes = 64 * 1024 * 1024
  visionHelperSource = staticRead("../../helpers/vision_ocr.swift")
    ## The helper's source as of this build (module doc).
  helperCacheName = "gui_assert_apple_vision"
  missingToolRemedy = "install the Xcode command line tools (xcode-select " &
    "--install) so swiftc can build the Vision helper, or set " &
    "GUIASSERT_VISION_HELPER to a prebuilt helper"

type
  AppleVisionConfig* = object
    ## What the engine runs with.
    token*: CancelToken      ## cancellation and the deadline; may be nil
    timeoutMs*: int          ## 0: `defaultVisionTimeoutMs`

  VisionWord* = object
    text*: string
    box*: array[4, int]

  VisionLine* = object
    ## One `VNRecognizedTextObservation` as the helper reports it.
    confidence*: float       ## 0..1
    box*: array[4, int]
    words*: seq[VisionWord]

  VisionResult* = object
    ## The helper's `--json` result file.
    width*, height*: int
    languages*: seq[string]
    lines*: seq[VisionLine]

# ---------------------------------------------------------------------------
# Pure: the helper's result and its words
# ---------------------------------------------------------------------------

proc normalizeVisionLanguage*(code: string): string =
  ## Vision's language code in its BCP 47 spelling: Vision lists supported
  ## languages as `en-US` but reports a request's default as `en_US`.
  code.replace('_', '-')

proc readBox(n: JsonNode, what: string): array[4, int] =
  if n.kind != JArray or n.len != 4:
    raise newException(ValueError, what & " is not [x, y, w, h]")
  for i in 0 .. 3:
    if n[i].kind != JInt: raise newException(ValueError, what & " has a non-integer")
    result[i] = n[i].getInt
  if result[2] < 0 or result[3] < 0:
    raise newException(ValueError, what & " has a negative size")

proc parseVisionResult*(text: string): VisionResult =
  ## Parse the helper's `--json` result. Raises `ValueError` for anything that
  ## is not exactly its documented shape (`helpers/vision_ocr.swift`).
  var n: JsonNode
  try: n = parseJson(text)
  except JsonParsingError as e: raise newException(ValueError, "not JSON: " & e.msg)
  if n.kind != JObject: raise newException(ValueError, "not an object")
  for k in ["width", "height"]:
    if not n.hasKey(k) or n[k].kind != JInt or n[k].getInt <= 0:
      raise newException(ValueError, k & " is not a positive integer")
  result.width = n["width"].getInt
  result.height = n["height"].getInt
  if not n.hasKey("languages") or n["languages"].kind != JArray:
    raise newException(ValueError, "languages is not an array")
  for l in n["languages"]:
    if l.kind != JString or l.getStr.len == 0:
      raise newException(ValueError, "a language is not a non-empty string")
    result.languages.add normalizeVisionLanguage(l.getStr)
  if not n.hasKey("lines") or n["lines"].kind != JArray:
    raise newException(ValueError, "lines is not an array")
  for ln in n["lines"]:
    if ln.kind != JObject: raise newException(ValueError, "a line is not an object")
    var line: VisionLine
    if not ln.hasKey("confidence") or ln["confidence"].kind notin {JFloat, JInt}:
      raise newException(ValueError, "a line has no numeric confidence")
    line.confidence = ln["confidence"].getFloat
    if line.confidence < 0.0 or line.confidence > 1.0:
      raise newException(ValueError, "a line confidence is outside 0..1")
    if not ln.hasKey("box"): raise newException(ValueError, "a line has no box")
    line.box = readBox(ln["box"], "a line box")
    if not ln.hasKey("words") or ln["words"].kind != JArray or ln["words"].len == 0:
      raise newException(ValueError, "a line has no words")
    for w in ln["words"]:
      if w.kind != JObject or not w.hasKey("text") or w["text"].kind != JString or
         w["text"].getStr.len == 0 or not w.hasKey("box"):
        raise newException(ValueError, "a word is not {text, box}")
      line.words.add VisionWord(text: w["text"].getStr, box: readBox(w["box"], "a word box"))
    result.lines.add line

proc groupRows*(boxes: seq[array[4, int]]): seq[int] =
  ## The row of each box (by index into `boxes`), rows numbered from 0 top to
  ## bottom. Boxes are taken in order of their top edge; a box joins the row
  ## it overlaps vertically by at least half the shorter height (of the box
  ## and of the row's span so far), else starts a new row below.
  result = newSeq[int](boxes.len)
  var order = newSeq[int](boxes.len)
  for i in 0 ..< boxes.len: order[i] = i
  order.sort(proc (a, b: int): int =
    result = cmp(boxes[a][1], boxes[b][1])
    if result == 0: result = cmp(boxes[a][0], boxes[b][0]))
  var rows: seq[tuple[top, bottom: int]]
  for i in order:
    let top = boxes[i][1]
    let bottom = boxes[i][1] + boxes[i][3]
    var joined = -1
    for r in countdown(rows.high, 0):
      let overlap = min(bottom, rows[r].bottom) - max(top, rows[r].top)
      let shorter = min(bottom - top, rows[r].bottom - rows[r].top)
      if shorter > 0 and overlap * 2 >= shorter:
        joined = r
        break
    if joined < 0:
      rows.add (top, bottom)
      joined = rows.high
    else:
      rows[joined].top = min(rows[joined].top, top)
      rows[joined].bottom = max(rows[joined].bottom, bottom)
    result[i] = joined

proc visionWords*(r: VisionResult, minConfidence = none(float)): seq[OcrWord] =
  ## The `OcrWord`s of a helper result (module doc): line confidence scaled to
  ## 0..100, rows numbered by `groupRows`, words of a line in Vision's order.
  ## With `minConfidence`, words below it are left out.
  var lineBoxes: seq[array[4, int]]
  for ln in r.lines: lineBoxes.add ln.box
  let rows = groupRows(lineBoxes)
  for i, ln in r.lines:
    let conf = ln.confidence * 100.0
    if minConfidence.isSome and conf < minConfidence.get: continue
    for w in ln.words:
      result.add OcrWord(text: w.text, confidence: conf, bbox: w.box,
                         lineNum: rows[i], blockNum: 0)

# ---------------------------------------------------------------------------
# The helper binary
# ---------------------------------------------------------------------------

proc missingTool(msg: string): ref BackendUnavailableError =
  result = unavailable(appleVisionName, "missing-tool", msg)
  result.remedy = missingToolRemedy

proc visionHelperProbablyAvailable*(): bool =
  ## Cheap check, compiling nothing: macOS, and a prebuilt helper
  ## (`GUIASSERT_VISION_HELPER`) or a `swiftc` to build one.
  when not defined(macosx):
    false
  else:
    let prebuilt = getEnv("GUIASSERT_VISION_HELPER")
    if prebuilt.len > 0: fileExists(prebuilt)
    else: resolveSwiftc().len > 0

proc visionHelperBinary*(): string =
  ## The compiled Vision helper: `GUIASSERT_VISION_HELPER` when set (a prebuilt
  ## binary); else built from `GUIASSERT_VISION_HELPER_SRC` when set; else
  ## built from this build's embedded source, written to the helper cache
  ## directory (rewritten only when it differs, so the compile is cached).
  ## Raises `BackendUnavailableError`: `wrong-platform` off macOS,
  ## `missing-tool` when there is no helper and no `swiftc` to build one.
  when not defined(macosx):
    raise unavailable(appleVisionName, "wrong-platform",
      "the apple-vision OCR backend runs on macOS only")
  else:
    let prebuilt = getEnv("GUIASSERT_VISION_HELPER")
    if prebuilt.len > 0:
      if fileExists(prebuilt): return prebuilt
      raise missingTool("GUIASSERT_VISION_HELPER points at " & prebuilt &
        " but no file exists there")
    var src = getEnv("GUIASSERT_VISION_HELPER_SRC")
    if src.len == 0:
      let dir = swiftHelperCacheDir(helperCacheName)
      src = dir / "vision_ocr.swift"
      try:
        ensurePrivateCacheDir(dir)
      except SwiftHelperError as e:
        raise missingTool(e.msg)
      try:
        let current = (if fileExists(src): readFile(src) else: "")
        if current != visionHelperSource:
          # Write beside and rename, so a concurrent compile never reads a
          # half-written source.
          let tmp = src & "." & $getCurrentProcessId() & ".tmp"
          writeFile(tmp, visionHelperSource)
          let why = replaceFile(tmp, src)
          if why.len > 0:
            discard tryRemoveFile(tmp)
            raise newException(IOError, why)
      except OSError, IOError:
        raise missingTool("cannot write the Vision helper source to " & dir &
          ": " & getCurrentExceptionMsg())
    try:
      compileSwiftHelper(helperCacheName, "vision_ocr", src)
    except SwiftHelperError as e:
      raise missingTool(e.msg)

# ---------------------------------------------------------------------------
# The engine
# ---------------------------------------------------------------------------

proc unsupported(msg: string): ref BackendUnavailableError =
  unavailable(appleVisionName, "unsupported-option", msg)

proc failed(msg: string): ref BackendError =
  newBackendError(BackendError, appleVisionName, "ocr-failed", msg)

proc refuseTesseractKnobs*(req: OcrRequest) =
  ## Raise `unsupported-option` for the Tesseract preprocessing knobs, which
  ## Vision has no equivalent of (spec §7.5).
  if req.psm.isSome:
    raise unsupported("apple-vision has no page-segmentation mode (--psm is a tesseract option)")
  if req.upscale.isSome:
    raise unsupported("apple-vision does its own scaling (--upscale is a tesseract option)")
  if req.invert.isSome:
    raise unsupported("apple-vision handles text polarity itself (--invert is a tesseract option)")

proc validateVisionRequest*(req: OcrRequest) =
  ## Refuse what Vision cannot honour, running nothing (`OcrEngine.validate`):
  ## the Tesseract knobs and an empty language code. Whether Vision supports
  ## a language is asked of Vision itself when the request runs.
  refuseTesseractKnobs(req)
  for l in req.languages:
    if l.len == 0: raise unsupported("an empty language code")

proc recognizeWithVision(cfg: AppleVisionConfig, req: OcrRequest): OcrResult =
  validateVisionRequest(req)
  if not fileExists(req.imagePath):
    raise newBackendError(BackendNotFoundError, appleVisionName, "file",
      "no image at " & req.imagePath)
  let helper = visionHelperBinary()
  let work = privateTempDir(appleVisionName, "guiassert_vision_")
  try:
    let outPath = work / "result.json"
    var args = @["--json", "--out", outPath]
    for l in req.languages: args.add ["--lang", l]
    args.add canonicalPath(req.imagePath)
    let timeout = if cfg.timeoutMs > 0: cfg.timeoutMs else: defaultVisionTimeoutMs
    let run = runEngine(appleVisionName, helper, args, cfg.token, timeout)
    case run.code
    of 0: discard
    of 5:
      raise unsupported("Vision's accurate recognition does not support " &
        "the requested language (" & run.diagnostics & "); supported: " &
        "see `guiassert capabilities --probe` or Vision's " &
        "supportedRecognitionLanguages")
    of 3:
      raise failed("Vision could not load the image " & req.imagePath)
    else:
      raise failed("the Vision helper exited with " & $run.code & ": " & run.diagnostics)
    var text: string
    try: text = readFileCapped(outPath, maxVisionResultBytes)
    except IOError as e: raise failed("cannot read the Vision result: " & e.msg)
    var parsed: VisionResult
    try: parsed = parseVisionResult(text)
    except ValueError as e: raise failed("the Vision helper wrote a malformed result: " & e.msg)
    initOcrResult(visionWords(parsed, req.minConfidence), appleVisionName,
                  parsed.languages)
  finally:
    try: removeDir(work)
    except OSError: discard

proc visionLanguages(cfg: AppleVisionConfig): seq[string] =
  ## The languages accurate recognition supports (`--languages`).
  let helper = visionHelperBinary()
  let work = privateTempDir(appleVisionName, "guiassert_vision_")
  try:
    let outPath = work / "languages.json"
    let run = runEngine(appleVisionName, helper, @["--languages", "--out", outPath],
                        cfg.token, defaultVisionTimeoutMs)
    if run.code != 0:
      raise failed("the Vision helper exited with " & $run.code & ": " & run.diagnostics)
    try:
      let n = parseJson(readFileCapped(outPath, maxVisionResultBytes))
      if n.kind != JArray: raise newException(ValueError, "not an array")
      for l in n:
        if l.kind != JString: raise newException(ValueError, "not a string")
        result.add normalizeVisionLanguage(l.getStr)
    except JsonParsingError, ValueError, IOError:
      raise failed("the Vision helper listed no languages: " & getCurrentExceptionMsg())
  finally:
    try: removeDir(work)
    except OSError: discard

proc appleVisionFeatures*(cfg: AppleVisionConfig, probe: bool): seq[Feature] =
  ## The engine's one feature, `ocr`. Without `probe`: `available` when a
  ## helper is present or `swiftc` can build one. With `probe`: the helper is
  ## built and asked for its languages, and `supported` only when it lists
  ## some.
  proc f(state: FeatureState, reason = "", remedy = ""): Feature =
    Feature(feature: "ocr", backend: appleVisionName, state: state,
            reason: (if reason.len > 0: some(reason) else: none(string)),
            remedy: (if remedy.len > 0: some(remedy) else: none(string)))
  when not defined(macosx):
    return @[f(fsUnavailable, "wrong-platform", "select the tesseract OCR backend")]
  else:
    if not probe:
      return @[if visionHelperProbablyAvailable(): f(fsAvailable)
               else: f(fsUnavailable, "missing-tool", missingToolRemedy)]
    try:
      if visionLanguages(cfg).len > 0: return @[f(fsSupported)]
      return @[f(fsUnavailable, "missing-tool", missingToolRemedy)]
    except BackendUnavailableError as e:
      return @[f(fsUnavailable, e.reason, e.remedy)]
    except BackendError:
      return @[f(fsUnavailable, "missing-tool", missingToolRemedy)]

proc newAppleVisionOcr*(cfg = AppleVisionConfig()): OcrEngine =
  ## The `apple-vision` engine (module doc). Constructing it runs nothing; the
  ## helper is built on the first recognition or probe.
  result.name = appleVisionName
  result.recognize = proc (req: OcrRequest): OcrResult =
    when defined(macosx):
      recognizeWithVision(cfg, req)
    else:
      raise unavailable(appleVisionName, "wrong-platform",
        "the apple-vision OCR backend runs on macOS only")
  result.validate = proc (req: OcrRequest) =
    when defined(macosx):
      validateVisionRequest(req)
    else:
      raise unavailable(appleVisionName, "wrong-platform",
        "the apple-vision OCR backend runs on macOS only")
  result.features = proc (probe: bool): seq[Feature] =
    appleVisionFeatures(cfg, probe)
