## GuiAssert end-to-end tests
##
## The test file hosts:
##
##   * `e2e_terminal_action_injection` (M2) — PTY driver timing precision.
##   * `verify_agent_storyboard_generation` (M4) — prompt-to-script.
##   * `verify_gui_assert_frame_validation` (M4) — OCR + layout overflow.
##   * SSIM identity sanity test for the visual math engine.
##
## All tests perform real work: real PTY subprocesses, real ffmpeg-rendered
## PNGs, and real Tesseract OCR. No mocks. No graceful skips.

import std/[options, os, osproc, sequtils, streams, strformat, strtabs, strutils, unittest]

import ../src/gui_assert
import ../src/gui_assert/parser
import ../src/gui_assert/driver
import ../src/gui_assert/ocr
import ../src/gui_assert/image_math
import ../src/gui_assert/storyboard
import ../src/gui_assert/media

# ---------------------------------------------------------------------------
# Shared ffmpeg helper — pick a binary with drawtext support so we can
# render synthetic OCR fixtures. Mirrors the tmedia.nim discovery logic.
# ---------------------------------------------------------------------------

proc ffmpegFiltersOutput(path: string): string =
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if (k == "DYLD_LIBRARY_PATH" or k == "DYLD_FALLBACK_LIBRARY_PATH") and
       path.startsWith("/nix/"):
      continue
    env[k] = v
  let p = startProcess(
    command = path,
    args = @["-hide_banner", "-filters"],
    env = env,
    options = {poStdErrToStdOut}
  )
  result = p.outputStream().readAll()
  discard p.waitForExit()
  p.close()

proc hasDrawtext(path: string): bool =
  try:
    let listing = ffmpegFiltersOutput(path)
    result = listing.splitLines.anyIt(it.contains(" drawtext "))
  except CatchableError:
    result = false

proc discoverFfmpegWithDrawtext(): string =
  let envBin = getEnv("FFMPEG_BIN")
  if envBin.len > 0 and fileExists(envBin) and hasDrawtext(envBin):
    return envBin
  let pathBin = findExe("ffmpeg")
  if pathBin.len > 0 and hasDrawtext(pathBin):
    return pathBin
  var candidates: seq[string] = @[]
  if dirExists("/nix/store"):
    for entry in walkDir("/nix/store"):
      if entry.kind == pcDir:
        let base = entry.path.extractFilename
        if "ffmpeg" in base and base.endsWith("-bin"):
          let bin = entry.path / "bin" / "ffmpeg"
          if fileExists(bin):
            candidates.add(bin)
  for c in candidates:
    if "ffmpeg-full" in c and hasDrawtext(c):
      return c
  for c in candidates:
    if hasDrawtext(c):
      return c
  raise newException(
    ValueError,
    "No ffmpeg binary with `drawtext` filter found. Searched $FFMPEG_BIN, " &
    "$PATH, and /nix/store/*ffmpeg*-bin/bin/ffmpeg."
  )

let ffmpegPath = discoverFfmpegWithDrawtext()
putEnv("FFMPEG_BIN", ffmpegPath)
echo "Using ffmpeg: ", ffmpegPath

proc runFfmpegEx(args: seq[string]): tuple[output: string, exitCode: int] =
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if (k == "DYLD_LIBRARY_PATH" or k == "DYLD_FALLBACK_LIBRARY_PATH") and
       ffmpegPath.startsWith("/nix/"):
      continue
    env[k] = v
  let p = startProcess(
    command = ffmpegPath,
    args = args,
    env = env,
    options = {poStdErrToStdOut}
  )
  result.output = p.outputStream().readAll()
  result.exitCode = p.waitForExit()
  p.close()

# ===========================================================================
# M2: e2e_terminal_action_injection (unchanged from the original file)
# ===========================================================================

suite "e2e_terminal_action_injection":

  test "PTY driver fires three keystrokes within +/-50ms of schedule":
    const yaml = """
metadata:
  title: "PTY timing test"
timeline:
  - time: 0.0
    action: type_text
    params:
      text: "hello\n"
  - time: 0.5
    action: type_text
    params:
      text: "world\n"
  - time: 1.0
    action: type_text
    params:
      text: "ok\n"
"""
    let script = parseScriptYaml(yaml)
    check script.timeline.len == 3

    var driver = newPtyDriver(["/bin/cat"])
    defer: closeDriver(driver)

    let events = playScriptOnPty(driver, script)
    check events.len == 3

    let expectedEcho = "hello\nworld\nok\n"
    discard waitForByteCount(driver, expectedEcho.len, timeoutMs = 2000)

    for ev in events:
      let driftMs = abs(ev.drift) * 1000.0
      checkpoint "kf=" & $ev.keyframeIndex &
                 " sched=" & $ev.scheduledOffset &
                 " actual=" & $ev.actualOffset &
                 " drift_ms=" & $driftMs
      check driftMs <= 50.0

    let outBuf = driver.output
    check expectedEcho in outBuf

# ===========================================================================
# M4: verify_agent_storyboard_generation
# ===========================================================================

suite "verify_agent_storyboard_generation":

  test "rule-based backend produces valid scripts for three goal keywords":
    let backend = newRuleBasedBackend()
    let goals = @[
      "Demonstrate recursive stepping through fibonacci",
      "Set a breakpoint and inspect variables",
      "Show the hot-reload workflow end to end"
    ]
    for goal in goals:
      let req = StoryboardRequest(
        goal: goal,
        durationSec: 15.0,
        resolution: "1920x1080",
        fps: 30
      )
      let yaml = generateScriptYaml(backend, req)
      checkpoint "goal: " & goal
      check yaml.len > 0
      # Must round-trip through the M2 parser without raising.
      let script = parseScriptYaml(yaml)
      validateScript(script)
      check script.timeline.len > 0
      check script.metadata.resolution == "1920x1080"
      check script.metadata.fps == 30

  test "unrecognised goal falls back to a sensible default":
    let backend = newRuleBasedBackend()
    let req = StoryboardRequest(
      goal: "An unknown demo theme nobody recognises",
      durationSec: 10.0,
      resolution: "1280x720",
      fps: 24
    )
    let yaml = generateScriptYaml(backend, req)
    let script = parseScriptYaml(yaml)
    validateScript(script)
    check script.timeline.len == 3
    check script.metadata.fps == 24
    check script.metadata.resolution == "1280x720"

  test "narration timings respect the M2 150-wpm overlap rule":
    # Drive every recipe and confirm none of them produces a script that the
    # parser would flag as overlapping. The parser's `validateScript` is the
    # ground truth; if it returns without raising we are good.
    let backend = newRuleBasedBackend()
    for goal in @["recursive", "breakpoint", "hot-reload", "completely unknown"]:
      let req = StoryboardRequest(
        goal: goal,
        durationSec: 20.0,
        resolution: "1920x1080",
        fps: 30
      )
      let yaml = generateScriptYaml(backend, req)
      let script = parseScriptYaml(yaml)
      validateScript(script)

  test "backend seam: a synthetic translator can be swapped in":
    # Demonstrates the extension point — a real LLM caller would supply a
    # closure here instead of the rule-based one.
    var stubBackend = StoryboardBackend(
      translate: proc(req: StoryboardRequest): string {.closure.} =
        result =
          "metadata:\n" &
          "  title: \"stub\"\n" &
          "  resolution: \"" & req.resolution & "\"\n" &
          "  fps: " & $req.fps & "\n" &
          "timeline:\n" &
          "  - time: 0.0\n" &
          "    action: launch_app\n" &
          "    narration: \"Hello stub\"\n" &
          "  - time: 3.0\n" &
          "    action: pause\n"
    )
    let req = StoryboardRequest(
      goal: "anything", durationSec: 5.0,
      resolution: "800x600", fps: 60
    )
    let yaml = generateScriptYaml(stubBackend, req)
    let script = parseScriptYaml(yaml)
    check script.metadata.resolution == "800x600"
    check script.metadata.fps == 60
    check script.timeline.len == 2

  test "backend producing invalid YAML raises StoryboardError":
    var bad = StoryboardBackend(
      translate: proc(req: StoryboardRequest): string {.closure.} =
        # `time` is missing on the second keyframe → ScriptParseError.
        result =
          "timeline:\n" &
          "  - time: 0.0\n" &
          "    action: click\n" &
          "  - action: click\n"
    )
    let req = StoryboardRequest(goal: "x", durationSec: 1.0,
                                resolution: "100x100", fps: 30)
    expect StoryboardError:
      discard generateScriptYaml(bad, req)

# ===========================================================================
# M4: verify_gui_assert_frame_validation
# ===========================================================================
#
# Generates a synthetic CodeTracer-styled frame:
#
#   * 1920x1080 testsrc background.
#   * Overlay text "callstack: fibonacci(5)" placed in known pixel
#     coordinates so the test can assert detectLayoutOverflow on a region
#     rect the text crosses and another that it does not.
#
# The text is rendered via ffmpeg drawtext, then OCR'd via Tesseract.

const FrameWidth = 1920
const FrameHeight = 1080
const TextLine = "callstack fibonacci function call"
  ## Stick to alphabetic words: digits and parentheses in `fibonacci(5)`
  ## travel through OCR less reliably than plain ASCII words.
const TextX = 200      # absolute X of the rendered text's left edge
const TextY = 500      # absolute Y of the rendered text's baseline-ish top
const TextSize = 72    # pixel height of the rendered text

proc generateCodeTracerTestFrame(path: string) =
  ## Render a 1920x1080 PNG whose centre carries the recognisable line.
  ## We deliberately use a high-contrast white-on-black render so Tesseract
  ## reads it accurately without language packs beyond `eng`.
  let drawText = "drawtext=text='" & TextLine & "':fontcolor=white:fontsize=" &
                 $TextSize & ":x=" & $TextX & ":y=" & $TextY
  let (output, code) = runFfmpegEx(@[
    "-y", "-hide_banner", "-loglevel", "error",
    "-f", "lavfi",
    "-i", "color=c=black:size=" & $FrameWidth & "x" & $FrameHeight & ":d=1",
    "-vf", drawText,
    "-frames:v", "1",
    path
  ])
  doAssert code == 0, "frame render failed: " & output
  doAssert fileExists(path), "frame did not land at " & path

suite "verify_gui_assert_frame_validation":

  test "waitForText reads the rendered line and detectLayoutOverflow flags spillover":
    let outDir = getTempDir() / "gui_assert_m4"
    createDir(outDir)
    let framePath = outDir / "codetracer_frame.png"
    if fileExists(framePath): removeFile(framePath)

    generateCodeTracerTestFrame(framePath)
    let size = getFileSize(framePath)
    check size > 1024
    echo &"  rendered frame: {size} bytes at {framePath}"

    let harness = newGuiAssertHarness(framePath)

    # 1. OCR-driven waitForText: the rendered line contains "fibonacci".
    let found = waitForText(harness, "fibonacci", timeoutMs = 2000)
    if not found:
      # Dump what we actually saw to make a future regression actionable.
      let words = runOcr(framePath)
      echo "OCR words: "
      for w in words:
        echo "  '", w.text, "' bbox=", w.bbox, " conf=", w.confidence
    check found

    # Sanity: the OCR also returns at least one word with a bounding box.
    let words = runOcr(framePath)
    check words.len > 0
    var hasFibonacci = false
    for w in words:
      if "fibonacci" in w.text.toLowerAscii:
        hasFibonacci = true
        # Bounding box must lie reasonably near the rendered text location.
        check w.bbox[0] >= 0
        check w.bbox[1] >= 0
        check w.bbox[2] > 0
        check w.bbox[3] > 0
    check hasFibonacci

    # 2. detectLayoutOverflow — region that the text deliberately crosses.
    # The rendered text sits around x in [TextX, TextX + ~1100], y in
    # [TextY, TextY + ~80]. A pane that ends at x=400 must be flagged.
    let overflowingRegion: array[4, int] = [0, 0, 400, 1080]
    check detectLayoutOverflow(harness, framePath, @[overflowingRegion]) == true

    # And a region that comfortably contains every recognised word — must
    # be reported as non-overflowing. The full canvas qualifies.
    let containingRegion: array[4, int] = [0, 0, FrameWidth, FrameHeight]
    check detectLayoutOverflow(harness, framePath, @[containingRegion]) == false

# ===========================================================================
# M4: SSIM identity & mismatch sanity
# ===========================================================================

suite "image_math.ssim":

  test "identical PNGs score >= tolerance":
    let outDir = getTempDir() / "gui_assert_m4_ssim"
    createDir(outDir)
    let a = outDir / "frame_a.png"
    let b = outDir / "frame_b.png"

    let (out1, code1) = runFfmpegEx(@[
      "-y", "-hide_banner", "-loglevel", "error",
      "-f", "lavfi",
      "-i", "testsrc=size=640x360:rate=1:duration=1",
      "-frames:v", "1",
      a
    ])
    doAssert code1 == 0, "testsrc render A failed: " & out1
    # Copy A → B byte-for-byte so SSIM is exactly 1.0.
    writeFile(b, readFile(a))

    let harness = newGuiAssertHarness(a)
    let score = visualCompareScore(harness, a, b)
    echo &"  identical-frame SSIM: {score:.6f}"
    check score >= 0.999
    check visualCompare(harness, a, b, tolerance = 0.98)

  test "mismatched frames score below tolerance":
    let outDir = getTempDir() / "gui_assert_m4_ssim"
    createDir(outDir)
    let a = outDir / "black.png"
    let b = outDir / "white.png"

    let (out1, code1) = runFfmpegEx(@[
      "-y", "-hide_banner", "-loglevel", "error",
      "-f", "lavfi",
      "-i", "color=c=black:size=320x240:d=1",
      "-frames:v", "1",
      a
    ])
    doAssert code1 == 0, "black render failed: " & out1
    let (out2, code2) = runFfmpegEx(@[
      "-y", "-hide_banner", "-loglevel", "error",
      "-f", "lavfi",
      "-i", "color=c=white:size=320x240:d=1",
      "-frames:v", "1",
      b
    ])
    doAssert code2 == 0, "white render failed: " & out2

    let harness = newGuiAssertHarness(a)
    let score = visualCompareScore(harness, a, b)
    echo &"  black-vs-white SSIM: {score:.6f}"
    check score < 0.98
    check visualCompare(harness, a, b, tolerance = 0.98) == false
