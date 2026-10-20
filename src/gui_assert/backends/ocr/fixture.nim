## The fixture OCR engine (spec §9.2): it reads the words the fixture drew.
##
## Every frame the fixture capture backend writes is registered by the
## SHA-256 of its PNG together with the words drawn on it. Recognizing an
## image looks that registry up, so `screenshot` followed by `ocr --image`
## round-trips exactly. An image the fixture did not write cannot be read
## (`backend-error` / `ocr-failed`): the fixture has no recognizer, and
## returning no words would claim the image holds no text.
##
## Tesseract's preprocessing knobs (`--psm`, `--upscale`, `--invert`) have no
## equivalent here and are refused (`unsupported-option`); a language the
## scenario does not list is refused the same way.

import std/[options, os, strutils]

import ../../core/[desktop_types, ocr_types, interfaces, sha256]
import ../../state_store
import ../fixture_desktop

proc newFixtureOcr*(cfg: FixtureConfig): OcrEngine =
  ## The fixture OCR engine. Raises `backend-unavailable` when
  ## GUIASSERT_FIXTURE_UNAVAILABLE names `ocr`.
  cfg.checkModuleAvailable(fmOcr)
  result.name = fixtureBackendName
  result.recognize = proc (req: OcrRequest): OcrResult =
    if req.psm.isSome: raise unsupported("the fixture OCR has no --psm")
    if req.upscale.isSome: raise unsupported("the fixture OCR has no --upscale")
    if req.invert.isSome: raise unsupported("the fixture OCR has no --invert")
    let scen = loadScenario(cfg.scenarioPath)
    var langs = req.languages
    if langs.len == 0: langs = scen.languages
    for l in langs:
      if l notin scen.languages:
        raise unsupported("the fixture OCR reads only " & scen.languages.join(", ") &
          ", not '" & l & "'")
    if not fileExists(req.imagePath):
      raise notFound("file", "no image at " & req.imagePath)
    var bytes: string
    try: bytes = readFileCapped(req.imagePath, maxImageFileBytes)
    except IOError as e: raise failed("ocr-failed", "cannot read " & req.imagePath & ": " & e.msg)
    var frame: typeof(cfg.lookupFrame(""))
    cfg.withFixtureLock:
      frame = cfg.lookupFrame(sha256Hex(bytes))
    if frame.isNone:
      raise failed("ocr-failed", "the fixture OCR reads only frames the fixture " &
        "captured, and " & req.imagePath & " is not one of them")
    var words: seq[OcrWord]
    for w in frame.get.words:
      if req.minConfidence.isSome and w.confidence < req.minConfidence.get: continue
      words.add w
    initOcrResult(words, fixtureBackendName, langs)
  result.features = proc (probe: bool): seq[Feature] =
    @[Feature(feature: "ocr", backend: fixtureBackendName, state: fsSupported,
              reason: some("reads fixture-captured frames only"),
              remedy: none(string))]
