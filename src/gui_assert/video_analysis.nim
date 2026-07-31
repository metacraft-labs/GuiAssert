## GuiAssert Video Analysis — segmentation by visual change
##
## This module turns a recorded screencast into a *timeline of distinct visual
## states*. It composes the primitives that already exist in GuiAssert:
##
##   * `media.resolveFfmpegBinary` (+ an `ffprobe` sibling) to discover the
##     pinned ffmpeg/ffprobe binaries,
##   * `image_math.decodeGray` to decode sampled frames to 8-bit grayscale,
##   * `image_math.computeSsim` to score consecutive frames for similarity.
##
## The recording is sampled at a low fps and downscaled (SSIM over whole
## frames is cheap and robust at small sizes). A new *segment* begins whenever
## `1 - SSIM(frame i, frame i+1)` exceeds a threshold; runs of visually similar
## frames collapse into a single segment. Each segment carries a `[tStart,
## tEnd)` time range (derived from the frame index / sample fps) and a
## `changeScore` (how different the entering frame was from its predecessor).
##
## As in the rest of GuiAssert, the *pure* argv-builders and the segmentation
## core (`buildProbeArgv`, `parseProbeJson`, `buildSampleFramesArgv`,
## `buildExtractFrameArgv`, `segmentBoundaries`) are separated from the
## *effectful* procs (`probeVideo`, `segmentByChange`) so the former are unit
## testable without a subprocess and the latter are integration tested against
## real ffmpeg.
##
## The `Keyframe.words`/`text`/`urls` fields are declared here (so the full
## timeline shape is stable) but are only *populated* by VU2's OCR pass; VU1
## fills in the segmentation fields only.

import std/[json, os, osproc, streams, strtabs, strutils, algorithm, tempfiles]

import ./media
import ./image_math
import ./ocr

type
  VideoAnalysisError* = object of CatchableError
    ## Raised on ffprobe/ffmpeg failures, malformed probe JSON, or when a
    ## sampled frame cannot be decoded.

  VideoInfo* = object
    ## Container-level facts about a video, read from ffprobe.
    path*: string
    durationS*: float
    width*, height*: int

  Keyframe* = object
    ## One detected distinct visual state. VU1 populates the segmentation
    ## fields (`index`, `tStart`, `tEnd`, `changeScore`, `imagePath`); the
    ## OCR-derived fields (`words`, `text`, `urls`) are filled by VU2.
    index*: int
    tStart*, tEnd*: float
    changeScore*: float          ## 1 - SSIM vs the previous kept state
    imagePath*: string           ## extracted full-res PNG (VU2)
    words*: seq[OcrWord]
    text*: string                ## reconstructed reading-order text (VU2)
    urls*: seq[string]           ## extracted URLs / host:port paths (VU2)

  VideoAnalysis* = object
    info*: VideoInfo
    frames*: seq[Keyframe]       ## one per detected distinct state

# ---------------------------------------------------------------------------
# Pure argv builders
# ---------------------------------------------------------------------------
#
# These return the *arguments* only (no leading binary token): the effectful
# procs below prepend the resolved ffprobe/ffmpeg path. This keeps the builders
# trivial to assert on and independent of binary discovery.

proc buildProbeArgv*(path: string): seq[string] =
  ## ffprobe argv emitting JSON with the first video stream's width/height
  ## and the container duration.
  @[
    "-v", "error",
    "-select_streams", "v:0",
    "-show_entries", "stream=width,height:format=duration",
    "-of", "json",
    path
  ]

proc buildSampleFramesArgv*(path: string, fps: float, scaleW: int,
                            outPattern: string): seq[string] =
  ## ffmpeg argv extracting frames at `fps` fps, downscaled to width `scaleW`
  ## while preserving the aspect ratio (`scale=W:-2` keeps the height even, a
  ## requirement of most encoders and harmless for raw PNG output), written to
  ## `outPattern` (e.g. `dir/f_%05d.png`).
  let fpsStr = formatFloat(fps, ffDecimal, precision = 4).strip(
    leading = false, trailing = true, chars = {'0'}).strip(
    leading = false, trailing = true, chars = {'.'})
  @[
    "-hide_banner",
    "-loglevel", "error",
    "-y",
    "-i", path,
    "-vf", "fps=" & fpsStr & ",scale=" & $scaleW & ":-2",
    outPattern
  ]

proc buildExtractFrameArgv*(path: string, t: float, outPng: string): seq[string] =
  ## ffmpeg argv extracting one full-resolution PNG at timestamp `t`. `-ss`
  ## precedes `-i` for a fast (keyframe-accurate) seek.
  let tStr = formatFloat(t, ffDecimal, precision = 3)
  @[
    "-hide_banner",
    "-loglevel", "error",
    "-y",
    "-ss", tStr,
    "-i", path,
    "-frames:v", "1",
    outPng
  ]

# ---------------------------------------------------------------------------
# Pure parsing
# ---------------------------------------------------------------------------

proc parseProbeJson*(jsonText: string): VideoInfo =
  ## Parse the JSON emitted by `buildProbeArgv` into a `VideoInfo`. The
  ## `format.duration` field is emitted by ffprobe as a *string* ("49.72"),
  ## but we also accept a JSON number for robustness.
  var node: JsonNode
  try:
    node = parseJson(jsonText)
  except JsonParsingError as e:
    raise newException(VideoAnalysisError,
      "Could not parse ffprobe JSON: " & e.msg)

  if node.hasKey("streams") and node["streams"].kind == JArray and
     node["streams"].len > 0:
    let s = node["streams"][0]
    if s.hasKey("width"): result.width = s["width"].getInt
    if s.hasKey("height"): result.height = s["height"].getInt

  if node.hasKey("format") and node["format"].hasKey("duration"):
    let d = node["format"]["duration"]
    case d.kind
    of JString:
      try:
        result.durationS = parseFloat(d.getStr)
      except ValueError:
        result.durationS = 0.0
    of JFloat: result.durationS = d.getFloat
    of JInt: result.durationS = float(d.getInt)
    else: discard

# ---------------------------------------------------------------------------
# Pure segmentation core
# ---------------------------------------------------------------------------

proc segmentBoundaries*(ssims: seq[float], threshold: float): seq[int] =
  ## Given `ssims`, where `ssims[i]` is the SSIM between frame `i` and frame
  ## `i+1`, return the frame indices at which a *new* segment begins.
  ##
  ## Frame 0 is always an implicit segment start, so the result always begins
  ## with `0`. A boundary is recorded at frame `i+1` when
  ## `1.0 - ssims[i] > threshold` (i.e. frame `i+1` differs enough from frame
  ## `i` to count as a new state). Consecutive sub-threshold frames therefore
  ## collapse into one segment.
  result = @[0]
  for i in 0 ..< ssims.len:
    if (1.0 - ssims[i]) > threshold:
      result.add(i + 1)

# ---------------------------------------------------------------------------
# Binary discovery (honors FFMPEG / FFPROBE, then FFMPEG_BIN / PATH)
# ---------------------------------------------------------------------------

proc sanitizedEnv(binPath: string): StringTableRef =
  ## Mirror image_math/media: on nix-store binaries drop DYLD_* so the dynamic
  ## linker does not splice in incompatible Homebrew libs.
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if (k == "DYLD_LIBRARY_PATH" or k == "DYLD_FALLBACK_LIBRARY_PATH") and
       binPath.startsWith("/nix/"):
      continue
    result[k] = v

proc resolveFfmpeg(): string =
  ## Locate ffmpeg. Honors `FFMPEG`, then delegates to
  ## `media.resolveFfmpegBinary` (which honors `FFMPEG_BIN`, then `$PATH`).
  let envBin = getEnv("FFMPEG")
  if envBin.len > 0:
    if not fileExists(envBin):
      raise newException(VideoAnalysisError,
        "FFMPEG points at " & envBin & " but no file exists there.")
    return envBin
  try:
    return resolveFfmpegBinary()
  except MediaCompositionError as e:
    raise newException(VideoAnalysisError, e.msg)

proc resolveFfprobe(ffmpegPath: string): string =
  ## Locate ffprobe. Honors `FFPROBE`, else derives it from the resolved
  ## ffmpeg path (replacing a trailing `ffmpeg` with `ffprobe`), else falls
  ## back to `$PATH`.
  let envBin = getEnv("FFPROBE")
  if envBin.len > 0:
    if not fileExists(envBin):
      raise newException(VideoAnalysisError,
        "FFPROBE points at " & envBin & " but no file exists there.")
    return envBin
  if ffmpegPath.endsWith("ffmpeg"):
    let candidate = ffmpegPath[0 ..< ^len("ffmpeg")] & "ffprobe"
    if fileExists(candidate):
      return candidate
  let p = findExe("ffprobe")
  if p.len == 0:
    raise newException(VideoAnalysisError,
      "ffprobe not found alongside ffmpeg at " & ffmpegPath &
      " and none on PATH (set FFPROBE).")
  return p

# ---------------------------------------------------------------------------
# Effectful procs
# ---------------------------------------------------------------------------

proc probeVideo*(path: string): VideoInfo =
  ## Run ffprobe on `path` and parse the result into a `VideoInfo`.
  if not fileExists(path):
    raise newException(VideoAnalysisError, "Video not found: " & path)
  let ffprobeBin = resolveFfprobe(resolveFfmpeg())
  let env = sanitizedEnv(ffprobeBin)
  let p = startProcess(
    command = ffprobeBin,
    args = buildProbeArgv(path),
    env = env,
    options = {poStdErrToStdOut}
  )
  let output = p.outputStream().readAll()
  let code = p.waitForExit()
  p.close()
  if code != 0:
    raise newException(VideoAnalysisError,
      "ffprobe failed (" & $code & ") on " & path & ": " & output)
  result = parseProbeJson(output)
  result.path = path

proc segmentByChange*(path: string, sampleFps = 2.0, scaleW = 320,
                      ssimThreshold = 0.12):
                      seq[tuple[tStart, tEnd, changeScore: float]] =
  ## Sample `path` at `sampleFps` fps (downscaled to width `scaleW`), score
  ## consecutive frames with SSIM, and collapse visually similar runs into
  ## segments. Returns one entry per detected distinct state.
  ##
  ## Defaults: `sampleFps = 2.0` gives enough temporal resolution to place a
  ## boundary within ~0.5s while keeping the SSIM work small; `scaleW = 320`
  ## downscales heavily so whole-frame SSIM is fast yet still discriminates a
  ## full-screen state change; `ssimThreshold = 0.12` (i.e. a state change
  ## must drop SSIM by >12%) sits comfortably above the sub-1% jitter between
  ## visually identical frames while remaining well below the large drop a
  ## real screen transition produces. These are the values validated by the
  ## 2-state e2e fixture.
  if not fileExists(path):
    raise newException(VideoAnalysisError, "Video not found: " & path)

  let ffmpegBin = resolveFfmpeg()
  let tmpDir = createTempDir("gui_assert_seg_", "")
  try:
    let outPattern = tmpDir / "f_%05d.png"
    let argv = buildSampleFramesArgv(path, sampleFps, scaleW, outPattern)
    let env = sanitizedEnv(ffmpegBin)
    let p = startProcess(
      command = ffmpegBin,
      args = argv,
      env = env,
      options = {poStdErrToStdOut}
    )
    let output = p.outputStream().readAll()
    let code = p.waitForExit()
    p.close()
    if code != 0:
      raise newException(VideoAnalysisError,
        "ffmpeg frame sampling failed (" & $code & ") on " & path & ": " &
        output)

    var frameFiles: seq[string] = @[]
    for f in walkFiles(tmpDir / "f_*.png"):
      frameFiles.add(f)
    sort(frameFiles)

    if frameFiles.len == 0:
      raise newException(VideoAnalysisError,
        "ffmpeg produced no frames sampling " & path)

    if frameFiles.len == 1:
      # A single sampled frame is one segment spanning one sample interval.
      return @[(0.0, 1.0 / sampleFps, 1.0)]

    # Decode consecutive pairs and compute SSIM between them.
    var ssims: seq[float] = @[]
    var prev = decodeGray(frameFiles[0])
    for i in 1 ..< frameFiles.len:
      let cur = decodeGray(frameFiles[i])
      ssims.add(computeSsim(prev, cur))
      prev = cur

    let numFrames = frameFiles.len
    let boundaries = segmentBoundaries(ssims, ssimThreshold)

    result = @[]
    for si in 0 ..< boundaries.len:
      let b = boundaries[si]
      let nb = if si + 1 < boundaries.len: boundaries[si + 1] else: numFrames
      let tStart = float(b) / sampleFps
      let tEnd = float(nb) / sampleFps
      let score = if b == 0: 1.0 else: 1.0 - ssims[b - 1]
      result.add((tStart, tEnd, score))
  finally:
    try:
      removeDir(tmpDir)
    except OSError:
      discard
