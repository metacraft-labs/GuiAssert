## VU1 tests for gui_assert/video_analysis.
##
## Mocking policy: the pure procs (argv builders, JSON parse, segmentation
## core) are tested against inline fixtures with no subprocess. The e2e test
## deliberately mocks NOTHING — it generates a real 2-state mp4 with the real
## ffmpeg binary (resolved via FFMPEG / PATH) and runs the real
## `segmentByChange` pipeline (real ffmpeg frame sampling + real SSIM) against
## it, per the workspace "mock as little as possible" policy.

import std/[unittest, os, osproc, streams, strtabs, strutils, tempfiles]

import ../src/gui_assert/video_analysis

# ---------------------------------------------------------------------------
# Helpers for the e2e fixture
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
  ## Probe the build for the drawtext filter (needs libfreetype). If absent we
  ## fall back to plain solid colours.
  let (output, _) = execCmdEx(ffmpeg & " -hide_banner -filters")
  result = output.contains("drawtext")

proc sanitizedEnvFor(binPath: string): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if (k == "DYLD_LIBRARY_PATH" or k == "DYLD_FALLBACK_LIBRARY_PATH") and
       binPath.startsWith("/nix/"):
      continue
    result[k] = v

proc generateTwoStateVideo(ffmpeg, outPath: string, useDrawtext: bool) =
  ## Build a ~3s mp4: ~1.5s of red (labelled ALPHA) then ~1.5s of blue
  ## (labelled BETA), concatenated via the lavfi concat filter. 8 fps.
  let redSrc = "color=c=red:s=320x240:d=1.5:r=8"
  let blueSrc = "color=c=blue:s=320x240:d=1.5:r=8"
  var filter: string
  if useDrawtext:
    filter =
      "[0:v]drawtext=text='ALPHA':fontcolor=white:fontsize=48:" &
      "x=(w-text_w)/2:y=(h-text_h)/2[a];" &
      "[1:v]drawtext=text='BETA':fontcolor=white:fontsize=48:" &
      "x=(w-text_w)/2:y=(h-text_h)/2[b];" &
      "[a][b]concat=n=2:v=1:a=0[v]"
  else:
    filter = "[0:v][1:v]concat=n=2:v=1:a=0[v]"
  let args = @[
    "-hide_banner", "-loglevel", "error", "-y",
    "-f", "lavfi", "-i", redSrc,
    "-f", "lavfi", "-i", blueSrc,
    "-filter_complex", filter,
    "-map", "[v]",
    "-c:v", "libx264", "-pix_fmt", "yuv420p",
    outPath
  ]
  let p = startProcess(
    command = ffmpeg,
    args = args,
    env = sanitizedEnvFor(ffmpeg),
    options = {poStdErrToStdOut}
  )
  let output = p.outputStream().readAll()
  let code = p.waitForExit()
  p.close()
  doAssert code == 0, "fixture ffmpeg failed (" & $code & "): " & output
  doAssert fileExists(outPath) and getFileSize(outPath) > 0,
    "fixture produced no file"

# ---------------------------------------------------------------------------
# Pure procs
# ---------------------------------------------------------------------------

suite "video_analysis pure":
  test "test_parse_probe_json":
    let sample = """
      {
        "streams": [ { "width": 1600, "height": 900 } ],
        "format": { "duration": "49.72" }
      }
    """
    let info = parseProbeJson(sample)
    check info.width == 1600
    check info.height == 900
    check abs(info.durationS - 49.72) < 0.001

    # duration may also arrive as a JSON number.
    let numeric = """{"streams":[{"width":640,"height":480}],
      "format":{"duration":12.5}}"""
    let info2 = parseProbeJson(numeric)
    check info2.width == 640
    check info2.height == 480
    check abs(info2.durationS - 12.5) < 0.001

  test "test_segment_boundaries":
    # ssims[i] = SSIM(frame i, frame i+1); boundary at i+1 when 1-ssim>thr.
    let ssims = @[0.99, 0.98, 0.30, 0.99, 0.40]
    check segmentBoundaries(ssims, 0.12) == @[0, 3, 5]

    # An all-similar series collapses to a single segment.
    check segmentBoundaries(@[0.99, 0.98, 0.99], 0.12) == @[0]

    # A high threshold swallows even the big drops -> one segment.
    check segmentBoundaries(ssims, 0.9) == @[0]

    # A very low threshold makes every transition a boundary.
    check segmentBoundaries(ssims, 0.001) == @[0, 1, 2, 3, 4, 5]

    # An empty series (one frame) is still one segment.
    check segmentBoundaries(@[], 0.12) == @[0]

  test "test_build_argv_shapes":
    let probe = buildProbeArgv("/tmp/in.mp4")
    check "/tmp/in.mp4" in probe
    check "-of" in probe
    check "json" in probe

    let sample = buildSampleFramesArgv("/tmp/in.mp4", 2.0, 320,
      "/tmp/out/f_%05d.png")
    check "/tmp/in.mp4" in sample
    check "/tmp/out/f_%05d.png" in sample
    var hasFps = false
    var hasScale = false
    for a in sample:
      if a.contains("fps="): hasFps = true
      if a.contains("scale="): hasScale = true
    check hasFps
    check hasScale

    let extract = buildExtractFrameArgv("/tmp/in.mp4", 1.5, "/tmp/frame.png")
    check "-ss" in extract
    check "/tmp/frame.png" in extract
    check "/tmp/in.mp4" in extract

# ---------------------------------------------------------------------------
# End-to-end against real ffmpeg
# ---------------------------------------------------------------------------

suite "video_analysis e2e":
  test "e2e_segment_two_state_video":
    let ffmpeg = resolveFfmpegForFixture()
    let tmp = createTempDir("tvideo_e2e_", "")
    defer: removeDir(tmp)
    let fixture = tmp / "two_state.mp4"
    let useDrawtext = ffmpegSupportsDrawtext(ffmpeg)
    generateTwoStateVideo(ffmpeg, fixture, useDrawtext)

    # Sanity: ffprobe reports a ~3s clip.
    let info = probeVideo(fixture)
    check info.width > 0
    check info.height > 0
    check abs(info.durationS - 3.0) < 0.6

    let segments = segmentByChange(fixture)
    # Exactly two distinct states.
    check segments.len == 2
    # The second segment must begin near the 1.5s colour switch (±0.5s).
    check abs(segments[1].tStart - 1.5) < 0.5
    # The entering change score of the second state should be substantial.
    check segments[1].changeScore > 0.12
    # The first segment starts at 0 with a full change score by convention.
    check segments[0].tStart == 0.0
    check segments[0].changeScore == 1.0
