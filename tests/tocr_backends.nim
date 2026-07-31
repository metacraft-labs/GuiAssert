## VU11 tests for gui_assert/ocr — pluggable OCR backends.
##
## Mocking policy: NOTHING is mocked. Fixtures are real PNGs rendered by the
## real ffmpeg binary (FFMPEG / FFMPEG_BIN / PATH); the Tesseract backend runs
## the real tesseract (TESSERACT_BIN / PATH); the Apple Vision backend, when the
## host supports it, compiles the bundled Swift helper with the REAL swiftc and
## runs the REAL macOS Vision engine (no stub, no faked assertion). This follows
## the workspace "mock as little as possible" policy.
##
## What these tests pin down (VU11 contract):
##   * Tesseract is the reproducible DEFAULT: `runOcrWithBackend(_, obTesseract)`
##     is identical to the direct `runOcrEx` path, and `availableBackends()`
##     always lists it.
##   * Optional backends degrade GRACEFULLY: requesting an unavailable one raises
##     the typed `OcrBackendUnavailable`, and `runOcrBestEffort` falls back to
##     Tesseract and STILL returns the genuine Tesseract reading (asserted equal
##     to the direct Tesseract result — not merely non-empty).
##   * Apple Vision, when swiftc is present (this macOS host), genuinely OCRs via
##     `VNRecognizeTextRequest` with in-range pixel bboxes. Off-platform / no
##     swiftc, the test reports "skipped: ..." via checkpoint+echo and asserts
##     nothing fake.
##   * The OmniParser element backend is a documented unavailable stub; `ebNone`
##     returns empty.

import std/[unittest, os, osproc, streams, strtabs, strutils, tempfiles]

import ../src/gui_assert/ocr
import ../src/gui_assert/image_math

# ---------------------------------------------------------------------------
# Fixture helpers (real ffmpeg) — same approach as tocr_vision.nim
# ---------------------------------------------------------------------------

proc resolveFfmpegForFixture(): string =
  let envBin = getEnv("FFMPEG")
  if envBin.len > 0 and fileExists(envBin):
    return envBin
  let envBin2 = getEnv("FFMPEG_BIN")
  if envBin2.len > 0 and fileExists(envBin2):
    return envBin2
  result = findExe("ffmpeg")
  doAssert result.len > 0, "ffmpeg not found (set FFMPEG or add to PATH)"

proc ffmpegSupportsDrawtext(ffmpeg: string): bool =
  let (output, _) = execCmdEx(ffmpeg & " -hide_banner -filters")
  result = output.contains("drawtext")

proc sanitizedEnvFor(binPath: string): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if (k == "DYLD_LIBRARY_PATH" or k == "DYLD_FALLBACK_LIBRARY_PATH") and
       binPath.startsWith("/nix/"):
      continue
    result[k] = v

proc renderFrame(ffmpeg: string, lavfiInput, outPath: string) =
  let args = @[
    "-y", "-hide_banner", "-loglevel", "error",
    "-f", "lavfi", "-i", lavfiInput,
    "-frames:v", "1", outPath
  ]
  let p = startProcess(
    command = ffmpeg, args = args,
    env = sanitizedEnvFor(ffmpeg), options = {poStdErrToStdOut})
  let output = p.outputStream().readAll()
  let code = p.waitForExit()
  p.close()
  doAssert code == 0, "fixture ffmpeg failed (" & $code & "): " & output
  doAssert fileExists(outPath) and getFileSize(outPath) > 0,
    "fixture produced no file at " & outPath

proc concat(words: seq[OcrWord]): string =
  var pieces: seq[string] = @[]
  for w in words:
    pieces.add(w.text)
  pieces.join(" ")

# ---------------------------------------------------------------------------

suite "ocr vu11 backends":

  test "test_backend_dispatch":
    ## The dispatcher routes obTesseract to the exact runOcrEx path, always lists
    ## it as available, raises OcrBackendUnavailable for an unavailable optional
    ## backend, and falls back to a GENUINE Tesseract reading via best-effort.
    let ffmpeg = resolveFfmpegForFixture()
    check ffmpegSupportsDrawtext(ffmpeg)
    let tmp = createTempDir("tocr_dispatch_", "")
    defer: removeDir(tmp)
    let frame = tmp / "dispatch.png"
    renderFrame(ffmpeg,
      "color=c=white:s=520x140," &
      "drawtext=text='DISPATCH 8842':fontcolor=black:fontsize=34:" &
      "x=(w-text_w)/2:y=(h-text_h)/2",
      frame)

    # Make the RapidOCR backend deterministically UNAVAILABLE for this test.
    delEnv("RAPIDOCR_CMD")

    # 1) obTesseract dispatch == the direct runOcrEx path, byte-for-byte text.
    let viaBackend = concat(runOcrWithBackend(frame, obTesseract))
    let direct     = concat(runOcrEx(frame, initOcrOptions()))
    echo "  tesseract dispatch: [", viaBackend, "]"
    check viaBackend == direct
    check viaBackend.contains("DISPATCH")
    check viaBackend.contains("8842")

    # 2) availableBackends always includes the default.
    let avail = availableBackends()
    echo "  availableBackends : ", avail
    check obTesseract in avail

    # 3) Requesting an unavailable optional backend raises the typed error.
    expect OcrBackendUnavailable:
      discard runOcrWithBackend(frame, obRapidOcr)

    # 4) best-effort over an unavailable backend falls back to Tesseract and
    #    returns the GENUINE Tesseract result (asserted equal, not just present).
    let best = runOcrBestEffort(frame, @[obRapidOcr])
    let bestText = concat(best)
    echo "  best-effort(rapid->tess): [", bestText, "]"
    check bestText == direct
    check bestText.contains("DISPATCH")
    check bestText.contains("8842")

  test "e2e_apple_vision_optional":
    ## macOS + swiftc: genuinely OCR the fixture via Apple Vision and assert it
    ## read the text with in-range pixel bboxes. Otherwise: honest skip.
    when hostOS != "macosx":
      checkpoint "skipped: not macOS (Apple Vision backend is macOS-only)"
      echo "  e2e_apple_vision_optional skipped: not macOS"
    else:
      var helper = ""
      var skipReason = ""
      try:
        helper = resolveAppleVisionHelper()
      except OcrBackendUnavailable as e:
        skipReason = e.msg
      if helper.len == 0:
        checkpoint "skipped: swiftc/helper unavailable: " & skipReason
        echo "  e2e_apple_vision_optional skipped: ", skipReason
      else:
        echo "  apple vision helper: ", helper
        check obAppleVision in availableBackends()
        let ffmpeg = resolveFfmpegForFixture()
        check ffmpegSupportsDrawtext(ffmpeg)
        let tmp = createTempDir("tocr_vision_", "")
        defer: removeDir(tmp)
        let frame = tmp / "vision.png"
        renderFrame(ffmpeg,
          "color=c=white:s=640x180," &
          "drawtext=text='APPLEVISION 5150':fontcolor=black:fontsize=40:" &
          "x=(w-text_w)/2:y=(h-text_h)/2",
          frame)

        let words = runOcrWithBackend(frame, obAppleVision)
        let text = concat(words)
        echo "  apple vision read: [", text, "]"
        # REAL Vision OCR must read the fixture text.
        check text.toUpperAscii.contains("APPLEVISION")
        check text.contains("5150")

        # Pixel bboxes must fall inside the image.
        let img = decodeGray(frame)
        check words.len > 0
        for w in words:
          check w.bbox[0] >= 0
          check w.bbox[1] >= 0
          check w.bbox[0] + w.bbox[2] <= img.width
          check w.bbox[1] + w.bbox[3] <= img.height
          check w.bbox[2] > 0
          check w.bbox[3] > 0

  test "test_omniparser_unavailable":
    ## The OmniParser element backend is a documented unavailable stub; ebNone
    ## returns empty.
    let tmp = createTempDir("tocr_omni_", "")
    defer: removeDir(tmp)
    let dummy = tmp / "x.png"  # detectElements(ebNone) never touches the file
    check detectElements(dummy, ebNone).len == 0

    var raised = false
    try:
      discard detectElements(dummy, ebOmniParser)
    except OcrBackendUnavailable as e:
      raised = true
      echo "  omniparser message: ", e.msg
      check e.msg.contains("ONNX")
      check e.msg.toUpperAscii.contains("OMNIPARSER")
    check raised
