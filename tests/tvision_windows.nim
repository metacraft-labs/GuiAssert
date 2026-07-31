## VU4 tests for gui_assert/vision_windows — pure-CV window detection.
##
## Mocking policy (per the workspace "mock as little as possible" policy):
##   * `test_detect_window_rects_synthetic` is FULLY pure — it constructs a
##     `GrayImage` in memory (writing the `pixels` string directly) and exercises
##     the connected-components + Otsu detector with NO ffmpeg and NO tesseract.
##   * `e2e_windows_two_window_frame` mocks NOTHING: it renders a self-contained
##     synthetic "desktop" PNG with the real ffmpeg binary (dark background + two
##     filled light window rectangles + distinct drawtext body labels) and then
##     runs the real `detectWindows` pipeline (real ffmpeg crops + real tesseract
##     OCR) against it. No media is committed — the fixture is generated at test
##     time.
##   * The optional `GUIASSERT_SUBSTRATE_MP4` block runs only when that env var
##     points at a real recording; when unset it does nothing (it is genuinely
##     conditional on an external asset, not a skip of the required tests).

import std/[unittest, os, osproc, streams, strtabs, strutils, tempfiles]

import ../src/gui_assert/vision_windows
import ../src/gui_assert/image_math

# ---------------------------------------------------------------------------
# In-memory GrayImage helpers (pure test)
# ---------------------------------------------------------------------------

proc mkImage(w, h, bg: int): GrayImage =
  ## Build a `w x h` grayscale image filled with the background value `bg`.
  result.width = w
  result.height = h
  result.pixels = newString(w * h)
  for i in 0 ..< w * h:
    result.pixels[i] = chr(bg)

proc fillRect(img: var GrayImage, x, y, w, h, val: int) =
  ## Paint a solid filled rectangle of value `val` into `img`.
  for yy in y ..< y + h:
    let rowBase = yy * img.width
    for xx in x ..< x + w:
      img.pixels[rowBase + xx] = chr(val)

proc approx(actual, expected, tol: int): bool =
  abs(actual - expected) <= tol

# ---------------------------------------------------------------------------
# ffmpeg fixture helpers (e2e)
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

proc runFfmpeg(ffmpeg: string, args: seq[string]) =
  let p = startProcess(
    command = ffmpeg,
    args = args,
    env = sanitizedEnvFor(ffmpeg),
    options = {poStdErrToStdOut}
  )
  let output = p.outputStream().readAll()
  let code = p.waitForExit()
  p.close()
  doAssert code == 0, "ffmpeg failed (" & $code & "): " & output

proc generateTwoWindowFrame(ffmpeg, outPng: string) =
  ## Render a 1000x700 synthetic desktop PNG: a dark background with two solid
  ## light window rectangles at known positions, each carrying distinct dark
  ## drawtext body text (dark-on-light so OCR can read it). The text is centred
  ## within each box via drawtext `text_w`/`text_h` expressions so it never
  ## overflows onto the dark background.
  const bg = "0x101418"        # gray ~19
  const box = "0xd0d4dc"       # gray ~212
  const ink = "0x101418"       # dark text on the light box
  # Window 1: (60,40,300,200); Window 2: (500,300,360,240).
  let vf =
    "drawbox=x=60:y=40:w=300:h=200:color=" & box & ":t=fill," &
    "drawbox=x=500:y=300:w=360:h=240:color=" & box & ":t=fill," &
    "drawtext=text=TERMINAL ALPHA LOG:" &
      "x=60+(300-text_w)/2:y=40+(200-text_h)/2:fontsize=28:fontcolor=" & ink & "," &
    "drawtext=text=FILE MANAGER BETA:" &
      "x=500+(360-text_w)/2:y=300+(240-text_h)/2:fontsize=28:fontcolor=" & ink
  runFfmpeg(ffmpeg, @[
    "-hide_banner", "-loglevel", "error", "-y",
    "-f", "lavfi", "-i", "color=c=" & bg & ":s=1000x700:d=1:r=1",
    "-vf", vf,
    "-frames:v", "1",
    outPng
  ])
  doAssert fileExists(outPng) and getFileSize(outPng) > 0,
    "fixture produced no PNG"

# ---------------------------------------------------------------------------
# Pure detector
# ---------------------------------------------------------------------------

suite "vision_windows pure":
  test "test_detect_window_rects_synthetic":
    # Dark background with two well-separated bright filled rectangles.
    var img = mkImage(1000, 700, 20)
    fillRect(img, 60, 40, 300, 200, 230)
    fillRect(img, 500, 300, 360, 240, 230)

    let rects = detectWindowRects(img)
    check rects.len == 2

    # Sorted top-left to bottom-right: rect at y=40 first, y=300 second.
    check approx(rects[0][0], 60, 6)
    check approx(rects[0][1], 40, 6)
    check approx(rects[0][2], 300, 6)
    check approx(rects[0][3], 200, 6)

    check approx(rects[1][0], 500, 6)
    check approx(rects[1][1], 300, 6)
    check approx(rects[1][2], 360, 6)
    check approx(rects[1][3], 240, 6)

    # A blank (all-dark) frame has no windows.
    let blank = mkImage(1000, 700, 20)
    check detectWindowRects(blank).len == 0

    # A pure-black frame likewise yields nothing.
    let black = mkImage(640, 480, 0)
    check detectWindowRects(black).len == 0

# ---------------------------------------------------------------------------
# End-to-end: real ffmpeg-rendered frame + real tesseract OCR
# ---------------------------------------------------------------------------

suite "vision_windows e2e":
  test "e2e_windows_two_window_frame":
    let ffmpeg = resolveFfmpegForFixture()
    check ffmpegSupportsDrawtext(ffmpeg)   # body-text OCR needs real drawtext
    let tmp = createTempDir("tvision_e2e_", "")
    defer: removeDir(tmp)
    let frame = tmp / "desktop.png"
    generateTwoWindowFrame(ffmpeg, frame)

    let windows = detectWindows(frame)
    # Exactly two windows detected from pixels alone.
    check windows.len == 2

    # Positions match the drawn boxes (allow a few px for encode/decode).
    check approx(windows[0].bbox[0], 60, 12)
    check approx(windows[0].bbox[1], 40, 12)
    check approx(windows[0].bbox[2], 300, 12)
    check approx(windows[0].bbox[3], 200, 12)

    check approx(windows[1].bbox[0], 500, 12)
    check approx(windows[1].bbox[1], 300, 12)
    check approx(windows[1].bbox[2], 360, 12)
    check approx(windows[1].bbox[3], 240, 12)

    # Solid filled windows -> high fill ratio confidence.
    check windows[0].confidence > 0.5
    check windows[1].confidence > 0.5

    # Per-window OCR text includes each window's distinct label, and NOT the
    # other window's label — proving the crops are per-window (case-insensitive,
    # OCR noise tolerated via substring match).
    let t0 = windows[0].text.toUpperAscii
    let t1 = windows[1].text.toUpperAscii
    check t0.contains("ALPHA")
    check not t0.contains("BETA")
    check t1.contains("BETA")
    check not t1.contains("ALPHA")

# ---------------------------------------------------------------------------
# Optional: real substrate recording, only when GUIASSERT_SUBSTRATE_MP4 is set
# ---------------------------------------------------------------------------

suite "vision_windows substrate (optional)":
  test "optional_substrate_frame":
    let mp4 = getEnv("GUIASSERT_SUBSTRATE_MP4")
    if mp4.len == 0 or not fileExists(mp4):
      # Genuinely conditional on an external asset; nothing to do otherwise.
      check true
    else:
      let ffmpeg = resolveFfmpegForFixture()
      let tmp = createTempDir("tvision_substrate_", "")
      defer: removeDir(tmp)
      let frame = tmp / "frame_6s.png"
      runFfmpeg(ffmpeg, @[
        "-hide_banner", "-loglevel", "error", "-y",
        "-ss", "6", "-i", mp4,
        "-frames:v", "1", frame
      ])
      doAssert fileExists(frame) and getFileSize(frame) > 0
      let windows = detectWindows(frame)
      check windows.len >= 2
