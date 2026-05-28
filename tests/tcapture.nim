## tcapture — pure tests for the GuiAssert capture module.
##
## Default invocation (no live capture):
##
##   nim c -r --hints:off tests/tcapture.nim
##
## Live macOS background capture (mirrors agent-harbor's
## `verify_macos_background_capture`):
##
##   nim c -d:captureLive -r --hints:off tests/tcapture.nim
##
## The live test is compile-time gated. The default build does NOT include
## it, so CI / day-to-day `nim c -r` runs do not block on a 5-second screen
## recording. The compile gate is deliberate: a runtime skip would silently
## degrade coverage on macOS dev boxes.

import std/[options, strutils, unittest]

import ../src/gui_assert/capture

when defined(macosx) and defined(captureLive):
  import std/[json, os, osproc, streams, strtabs]
  import ../src/gui_assert/media

# ---------------------------------------------------------------------------
# Sample stderr output from `ffmpeg -f avfoundation -list_devices true -i ""`.
# Copied from agent-harbor's capture.rs test fixture so the two
# implementations stay byte-identical.
# ---------------------------------------------------------------------------

const FFMPEG_AVFOUNDATION_SAMPLE = """
[AVFoundation indev @ 0x7f8] AVFoundation video devices:
[AVFoundation indev @ 0x7f8] [0] MacBook Pro Camera
[AVFoundation indev @ 0x7f8] [1] OBS Virtual Camera
[AVFoundation indev @ 0x7f8] [2] iPhone Camera
[AVFoundation indev @ 0x7f8] [3] MacBook Pro Desk View Camera
[AVFoundation indev @ 0x7f8] [4] iPhone Desk View Camera
[AVFoundation indev @ 0x7f8] [5] Capture screen 0
[AVFoundation indev @ 0x7f8] AVFoundation audio devices:
[AVFoundation indev @ 0x7f8] [0] iPhone Microphone
[AVFoundation indev @ 0x7f8] [1] MacBook Pro Microphone
"""

# ---------------------------------------------------------------------------
# Helpers for argv assertions
# ---------------------------------------------------------------------------

proc indexOf(argv: seq[string], tok: string): int =
  for i, a in argv:
    if a == tok: return i
  return -1

proc hasFlag(argv: seq[string], tok: string): bool =
  indexOf(argv, tok) >= 0

proc valueAfter(argv: seq[string], tok: string): string =
  let i = indexOf(argv, tok)
  doAssert i >= 0, "expected flag '" & tok & "' missing from argv: " & $argv
  doAssert i + 1 < argv.len,
    "flag '" & tok & "' has no following value in argv: " & $argv
  return argv[i + 1]

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

suite "capture: backend resolution":

  test "resolveBackend(cbAuto) maps to the current OS default":
    let r = resolveBackend(cbAuto)
    when defined(macosx):
      check r == rbAvfoundation
    elif defined(windows):
      check r == rbDdagrab
    elif defined(linux):
      # On Linux the result depends on env. Any of the linux backends is
      # acceptable; if neither WAYLAND_DISPLAY nor DISPLAY is set the
      # resolver raises and we'd not reach here.
      check (r == rbWfRecorder or r == rbX11Grab)

  test "resolveBackend rejects an OS-incompatible explicit choice":
    when defined(linux):
      expect CaptureError:
        discard resolveBackend(cbAvfoundation)
    elif defined(macosx):
      expect CaptureError:
        discard resolveBackend(cbDdagrab)
    elif defined(windows):
      expect CaptureError:
        discard resolveBackend(cbWfRecorder)
    else:
      skip()

suite "capture: argv builders":

  test "buildArgv(rbAvfoundation, region) emits crop filter":
    var opts = defaultCaptureOptions()
    opts.output = "/tmp/out.mp4"
    opts.durationSec = some(5.0)
    opts.region = some(CaptureRegion(x: 10, y: 20, width: 640, height: 480))
    let argv = buildArgv(rbAvfoundation, opts)
    check valueAfter(argv, "-vf") == "crop=640:480:10:20"
    check hasFlag(argv, "avfoundation")
    check valueAfter(argv, "-t") == "5.000"
    check argv[^1] == "/tmp/out.mp4"

  test "buildArgv(rbAvfoundation, no region) emits no -vf":
    var opts = defaultCaptureOptions()
    opts.output = "/tmp/out.mp4"
    opts.durationSec = some(3.0)
    let argv = buildArgv(rbAvfoundation, opts)
    check not hasFlag(argv, "-vf")
    # And no crop= filter anywhere in the argv.
    for a in argv:
      check not a.startsWith("crop=")
    check valueAfter(argv, "-i") == "0:none"

  test "buildArgv(rbDdagrab, region) emits offset_x/offset_y/video_size":
    var opts = defaultCaptureOptions()
    opts.output = "C:/tmp/out.mp4"
    opts.durationSec = some(5.0)
    opts.region = some(CaptureRegion(x: 100, y: 50, width: 800, height: 600))
    let argv = buildArgv(rbDdagrab, opts)
    check valueAfter(argv, "-offset_x") == "100"
    check valueAfter(argv, "-offset_y") == "50"
    check valueAfter(argv, "-video_size") == "800x600"
    check valueAfter(argv, "-f") == "ddagrab"
    check valueAfter(argv, "-i") == "desktop"

  test "buildArgv(rbGdiGrab) selects gdigrab muxer":
    var opts = defaultCaptureOptions()
    opts.output = "C:/tmp/out.mp4"
    opts.durationSec = some(5.0)
    let argv = buildArgv(rbGdiGrab, opts)
    check valueAfter(argv, "-f") == "gdigrab"
    # No region → no offset_x.
    check not hasFlag(argv, "-offset_x")

  test "buildArgv(rbX11Grab, region) emits +x,y input and video_size":
    var opts = defaultCaptureOptions()
    opts.output = "/tmp/out.mp4"
    opts.region = some(CaptureRegion(x: 100, y: 50, width: 800, height: 600))
    # buildArgv consults $DISPLAY for X11; use the wrapper that takes it
    # explicitly so the test is environment-independent.
    let argv = buildX11GrabArgv(opts, ":0")
    check valueAfter(argv, "-video_size") == "800x600"
    check valueAfter(argv, "-i") == ":0+100,50"

  test "buildArgv(rbX11Grab, no region) leaves the input untouched":
    var opts = defaultCaptureOptions()
    opts.output = "/tmp/out.mp4"
    opts.durationSec = some(5.0)
    let argv = buildX11GrabArgv(opts, ":0")
    check valueAfter(argv, "-i") == ":0"
    check not hasFlag(argv, "-video_size")

  test "buildArgv(rbWfRecorder, region) emits -g x,y WxH":
    var opts = defaultCaptureOptions()
    opts.output = "/tmp/out.mp4"
    opts.region = some(CaptureRegion(x: 10, y: 20, width: 800, height: 600))
    let argv = buildArgv(rbWfRecorder, opts)
    check valueAfter(argv, "-g") == "10,20 800x600"
    check valueAfter(argv, "-f") == "/tmp/out.mp4"
    check valueAfter(argv, "-c") == "libx264"

  test "buildWfRecorderArgv(no region) emits a minimal argv":
    var opts = defaultCaptureOptions()
    opts.output = "/tmp/out.mp4"
    let argv = buildWfRecorderArgv(opts, "libx264")
    check argv == @["-f", "/tmp/out.mp4", "-c", "libx264"]

suite "capture: macOS device index parser":

  test "parseMacosScreenDeviceIndex picks the 'Capture screen 0' line":
    check parseMacosScreenDeviceIndex(FFMPEG_AVFOUNDATION_SAMPLE) == 5

  test "parseMacosScreenDeviceIndex raises when no screen device is listed":
    let stub = """
[AVFoundation indev @ 0x7f8] AVFoundation video devices:
[AVFoundation indev @ 0x7f8] [0] MacBook Pro Camera
"""
    expect CaptureError:
      discard parseMacosScreenDeviceIndex(stub)

  test "parseMacosScreenDeviceIndex tolerates extra whitespace":
    let stub = """
[AVFoundation indev @ 0xff] [12]   Capture screen 2
"""
    check parseMacosScreenDeviceIndex(stub) == 12

# ---------------------------------------------------------------------------
# Live capture (macOS). Compile-time gated; opt in with -d:captureLive.
# ---------------------------------------------------------------------------

when defined(macosx) and defined(captureLive):

  proc ffprobeJson(path: string): JsonNode =
    let ffmpegPath = resolveFfmpegBinary()
    let ffprobeBin =
      if ffmpegPath.endsWith("/ffmpeg"):
        ffmpegPath[0 ..< ^len("ffmpeg")] & "ffprobe"
      else:
        findExe("ffprobe")
    doAssert ffprobeBin.len > 0 and fileExists(ffprobeBin),
      "ffprobe not found alongside ffmpeg at " & ffmpegPath
    var env = newStringTable(modeCaseSensitive)
    for k, v in envPairs():
      if (k == "DYLD_LIBRARY_PATH" or k == "DYLD_FALLBACK_LIBRARY_PATH") and
         ffprobeBin.startsWith("/nix/"):
        continue
      env[k] = v
    let p = startProcess(
      command = ffprobeBin,
      args = @[
        "-hide_banner",
        "-v", "error",
        "-print_format", "json",
        "-show_streams",
        "-show_format",
        path
      ],
      env = env,
      options = {poStdErrToStdOut}
    )
    let output = p.outputStream().readAll()
    let code = p.waitForExit()
    p.close()
    doAssert code == 0, "ffprobe failed (" & $code & "): " & output
    result = parseJson(output)

  suite "capture: verifyMacosBackgroundCapture":

    test "recordScreen produces a valid ~5s mp4 via avfoundation":
      let outPath = getTempDir() / "guiassert_verify_macos_background_capture.mp4"
      if fileExists(outPath):
        removeFile(outPath)
      var opts = defaultCaptureOptions()
      opts.output = outPath
      opts.durationSec = some(5.0)
      opts.backend = cbAvfoundation
      discard recordScreen(opts)
      check fileExists(outPath)
      check getFileSize(outPath) > 0
      let probe = ffprobeJson(outPath)
      let fmt = probe{"format", "format_name"}.getStr()
      check ("mp4" in fmt or "mov" in fmt)
      let dur = parseFloat(probe{"format", "duration"}.getStr())
      check dur >= 4.0
      check dur <= 6.0
      var hasVideo = false
      for s in probe{"streams"}.items:
        if s{"codec_type"}.getStr() == "video":
          hasVideo = true
      check hasVideo
