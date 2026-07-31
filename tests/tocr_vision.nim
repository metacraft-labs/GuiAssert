## VU9 tests for gui_assert/ocr — OCR quality (upscale + dark-mode inversion +
## per-PSM merge).
##
## Mocking policy: NOTHING is mocked. Every test generates a real PNG with the
## real ffmpeg binary (resolved via FFMPEG / FFMPEG_BIN / PATH) and runs the
## real tesseract binary (via TESSERACT_BIN / PATH), per the workspace "mock as
## little as possible" policy. Each direction is asserted in BOTH its failing
## and passing form so the preprocessing is shown to be load-bearing (a test
## that only asserts the good case would pass even if the option did nothing).
##
## Design note that these tests pin down: `runOcrEx` disables tesseract's own
## built-in polarity heuristic (`tessedit_do_invert`) so that `OcrOptions.invert`
## is the single, deterministic source of truth for polarity. Modern tesseract
## (5.x) will otherwise silently re-invert light-on-dark text even when the
## caller asked for `oiNever`, which would make the dark-mode option untestable
## and, worse, non-authoritative for callers. `runOcr` (the legacy path) keeps
## tesseract's auto-invert ON and is left behaviorally identical.

import std/[unittest, os, osproc, streams, strtabs, strutils, tempfiles]

import ../src/gui_assert/ocr
import ../src/gui_assert/image_math

# ---------------------------------------------------------------------------
# Fixture helpers (real ffmpeg)
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
  ## Render one PNG from a single lavfi `-i` source expression (which may embed
  ## a drawtext/drawbox filter chain).
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

suite "ocr vu9 e2e":

  test "e2e_ocr_dark_mode":
    ## A LIGHT-on-DARK frame that tesseract cannot read without inversion but
    ## reads perfectly with it — asserted in BOTH directions.
    let ffmpeg = resolveFfmpegForFixture()
    check ffmpegSupportsDrawtext(ffmpeg)
    let tmp = createTempDir("tocr_dark_", "")
    defer: removeDir(tmp)
    let frame = tmp / "darkmode.png"
    # Dark background (0x1b1b1b) with light drawtext.
    renderFrame(ffmpeg,
      "color=c=0x1b1b1b:s=560x160," &
      "drawtext=text='DARKMODE TEXT 4242':fontcolor=0xdcdcdc:fontsize=30:" &
      "x=(w-text_w)/2:y=(h-text_h)/2",
      frame)

    # Sanity: the fixture really is a dark frame (so oiAuto will invert it).
    let img = decodeGray(frame)
    var total = 0.0
    for i in 0 ..< img.pixels.len: total += float(img.pixels[i].uint8)
    let mean = total / float(img.pixels.len)
    check mean < autoInvertLumaThreshold

    let noInvert = concat(runOcrEx(frame, initOcrOptions(psm = 11,
                                                         invert = oiNever)))
    let forced  = concat(runOcrEx(frame, initOcrOptions(psm = 11,
                                                        invert = oiAlways)))
    let auto    = concat(runOcrEx(frame, initOcrOptions(psm = 11,
                                                        invert = oiAuto)))
    echo "  dark oiNever : [", noInvert, "]"
    echo "  dark oiAlways: [", forced, "]"
    echo "  dark oiAuto  : [", auto, "]"

    # FAILING direction: without inversion the light-on-dark text is unreadable.
    check not noInvert.toUpperAscii.contains("DARKMODE")
    check not noInvert.contains("4242")
    # PASSING directions: forced inversion AND auto-inversion both read it.
    check forced.toUpperAscii.contains("DARKMODE")
    check forced.contains("4242")
    check auto.toUpperAscii.contains("DARKMODE")
    check auto.contains("4242")

  test "e2e_ocr_upscale_small_text":
    ## A tiny-font frame that 1x OCR reads poorly and 3x upscaled OCR reads
    ## correctly — asserted in BOTH directions.
    let ffmpeg = resolveFfmpegForFixture()
    check ffmpegSupportsDrawtext(ffmpeg)
    let tmp = createTempDir("tocr_upscale_", "")
    defer: removeDir(tmp)
    let frame = tmp / "small.png"
    # Small fontsize 9 dark-on-light text on a modest canvas.
    renderFrame(ffmpeg,
      "color=c=white:s=480x120," &
      "drawtext=text='TINYSCALE 7731':fontcolor=black:fontsize=9:" &
      "x=(w-text_w)/2:y=(h-text_h)/2",
      frame)

    let at1x = concat(runOcrEx(frame, initOcrOptions(psm = 7, upscale = 1.0)))
    let at3x = concat(runOcrEx(frame, initOcrOptions(psm = 7, upscale = 3.0)))
    echo "  small 1x: [", at1x, "]"
    echo "  small 3x: [", at3x, "]"

    # FAILING direction: at native resolution the target is not read cleanly.
    check not at1x.contains("TINYSCALE")
    check not at1x.contains("7731")
    # PASSING direction: 3x Lanczos upscaling recovers the target string.
    check at3x.contains("TINYSCALE")
    check at3x.contains("7731")

  test "test_bbox_rescale":
    ## With upscale > 1 the returned bboxes must be in ORIGINAL image space, not
    ## the upscaled space: every word's box lies within the original bounds.
    let ffmpeg = resolveFfmpegForFixture()
    check ffmpegSupportsDrawtext(ffmpeg)
    let tmp = createTempDir("tocr_bbox_", "")
    defer: removeDir(tmp)
    let frame = tmp / "bboxsrc.png"
    renderFrame(ffmpeg,
      "color=c=white:s=480x120," &
      "drawtext=text='TINYSCALE 7731':fontcolor=black:fontsize=9:" &
      "x=(w-text_w)/2:y=(h-text_h)/2",
      frame)

    let (origW, origH) = probeImageSize(frame)
    check origW == 480
    check origH == 120

    let scale = 3.0
    let words = runOcrEx(frame, initOcrOptions(psm = 7, upscale = scale))
    check words.len > 0
    # A few px of rounding slack; the point is boxes are ~1x, not ~3x.
    const tol = 4
    for w in words:
      check w.bbox[0] >= 0
      check w.bbox[1] >= 0
      check w.bbox[2] > 0
      check w.bbox[3] > 0
      # If coords were left in UPSCALED space, x+w would reach ~3*480=1440.
      check w.bbox[0] + w.bbox[2] <= origW + tol
      check w.bbox[1] + w.bbox[3] <= origH + tol

  test "regression_runOcr_dark_on_light":
    ## The legacy `runOcr` (auto-invert ON, no preprocessing) must still read a
    ## normal high-contrast fixture — VU9's changes must not regress it.
    let ffmpeg = resolveFfmpegForFixture()
    check ffmpegSupportsDrawtext(ffmpeg)
    let tmp = createTempDir("tocr_reg_", "")
    defer: removeDir(tmp)
    let frame = tmp / "reg.png"
    renderFrame(ffmpeg,
      "color=c=black:s=800x200," &
      "drawtext=text='callstack fibonacci function':fontcolor=white:" &
      "fontsize=48:x=40:y=80",
      frame)

    let words = runOcr(frame)
    check words.len > 0
    let text = concat(words).toLowerAscii
    echo "  runOcr: [", concat(words), "]"
    check text.contains("fibonacci")

  test "runOcrMultiPsm_merges_without_duplicates":
    ## Running both a block (psm 6) and sparse (psm 11) pass merges into a single
    ## de-duplicated word set (the VU7 fix), not a doubled one.
    let ffmpeg = resolveFfmpegForFixture()
    check ffmpegSupportsDrawtext(ffmpeg)
    let tmp = createTempDir("tocr_multi_", "")
    defer: removeDir(tmp)
    let frame = tmp / "multi.png"
    renderFrame(ffmpeg,
      "color=c=0x1b1b1b:s=560x160," &
      "drawtext=text='DARKMODE TEXT 4242':fontcolor=0xdcdcdc:fontsize=30:" &
      "x=(w-text_w)/2:y=(h-text_h)/2",
      frame)

    let merged = runOcrMultiPsm(frame, @[6, 11],
                                initOcrOptions(upscale = 2.0, invert = oiAuto))
    let text = concat(merged)
    echo "  multiPsm (", merged.len, " words): [", text, "]"
    check text.toUpperAscii.contains("DARKMODE")
    check text.contains("4242")
    # Three source words; a naive concat of both passes would double them.
    check merged.len <= 5
