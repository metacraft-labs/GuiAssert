## GuiAssert opt-in media backend: image decoding through ffmpeg.
##
## The pure core decodes PNG itself (`core/png`). Every other image format,
## and every video, goes through this module, which runs the `ffmpeg` and
## `ffprobe` binaries as subprocesses. Import it only when that dependency is
## acceptable; nothing in `core/` imports it.
##
## Binary discovery goes through `media.resolveFfmpegBinary` (which honours
## `FFMPEG_BIN`, then `$PATH`), so the same binary is used everywhere in
## GuiAssert, and `ffprobe` is taken from beside it when it is there. When
## the binary lives in the Nix store, `DYLD_LIBRARY_PATH` and
## `DYLD_FALLBACK_LIBRARY_PATH` are removed from its environment so the
## dynamic linker cannot splice host libraries into it.
##
## `decodeGray` and `probeImageSize` are re-exported by `gui_assert/image_math`
## under their historical names.
##
## Video segmentation (`segmentVideo`) is the library form of `guiassert
## vision-segment <video>`: ffmpeg samples and scales the video and pipes raw
## 8-bit gray frames, and the pure core (`core/segmentation`) scores and
## splits them, one frame pair at a time, so a long video never has to fit in
## memory. The CLI verb serializes exactly what this returns.

import std/[json, options, os, osproc, streams, strtabs, strutils, typedthreads]
when defined(windows):
  from std/winlean import nil
else:
  from std/posix import nil

import ../../media
import ../../core/[image, desktop_types, segmentation]

type
  MediaToolMissingError* = object of CatchableError
    ## `ffmpeg` or `ffprobe` cannot be found (`FFMPEG_BIN`, then `$PATH`).

  VideoDecodeError* = object of CatchableError
    ## The file is not a video ffmpeg can read, or decoding it failed.

  VideoSource* = object
    ## Container-level facts about a video, as ffprobe reports them.
    path*: string
    durationS*: Option[float]
      ## The container duration; none when the container does not state one.
    width*, height*: int
      ## The coded size of the first video stream.

  VideoSegmentation* = object
    ## The result of `segmentVideo`: the source, the parameters that were
    ## applied, and one segment per distinct visual state.
    source*: VideoSource
    fps*: float            ## the sample rate
    scaleWidth*: int       ## the width the frames were scaled to
    scaledHeight*: int     ## the height that follows from it (`scaledHeight`)
    threshold*: float      ## the change threshold of `segmentsFromSeries`
    frames*: int           ## how many frames were sampled
    segments*: seq[Segment]

const
  defaultVideoFps* = 2.0
    ## The default sample rate of `segmentVideo` (and `vision-segment <video>`):
    ## a boundary is placed within half a second at little cost.
  defaultVideoScaleWidth* = 320
    ## The default width frames are scaled to: small enough that the tiled
    ## SSIM is fast, large enough that each of its 16 cells is a UI region.

proc sanitizedEnv(ffmpegPath: string): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if (k == "DYLD_LIBRARY_PATH" or k == "DYLD_FALLBACK_LIBRARY_PATH") and
       ffmpegPath.startsWith("/nix/"):
      continue
    result[k] = v

proc ffprobeBinaryFor(ffmpegPath: string): string =
  if ffmpegPath.endsWith("/ffmpeg"):
    let candidate = ffmpegPath[0 ..< ^len("ffmpeg")] & "ffprobe"
    if fileExists(candidate):
      return candidate
  let p = findExe("ffprobe")
  if p.len == 0:
    raise newException(ImageMathError,
      "ffprobe not found alongside ffmpeg at " & ffmpegPath)
  return p

proc probeImageSize*(path: string): tuple[width, height: int] =
  ## Use ffprobe to read the pixel dimensions of an image file. Any decoded
  ## format ffmpeg understands works: PNG, JPEG, BMP, even single MP4 frames.
  if not fileExists(path):
    raise newException(ImageMathError, "Image not found: " & path)
  let ffmpegPath = resolveFfmpegBinary()
  let ffprobeBin = ffprobeBinaryFor(ffmpegPath)
  let env = sanitizedEnv(ffprobeBin)
  let p = startProcess(
    command = ffprobeBin,
    args = @[
      "-hide_banner",
      "-v", "error",
      "-select_streams", "v:0",
      "-show_entries", "stream=width,height",
      "-of", "csv=p=0:s=x",
      path
    ],
    env = env,
    options = {poStdErrToStdOut}
  )
  let output = p.outputStream().readAll().strip()
  let code = p.waitForExit()
  p.close()
  if code != 0:
    raise newException(ImageMathError,
      "ffprobe failed (" & $code & ") reading " & path & ": " & output)
  # Output format: "1920x1080"
  let parts = output.split('x')
  if parts.len < 2:
    raise newException(ImageMathError,
      "Unexpected ffprobe size output for " & path & ": '" & output & "'")
  try:
    result.width = parseInt(parts[0])
    result.height = parseInt(parts[1])
  except ValueError:
    raise newException(ImageMathError,
      "Could not parse ffprobe dimensions: '" & output & "'")

proc decodeGray*(path: string): GrayImage =
  ## Decode `path` into an 8-bit grayscale raw buffer using ffmpeg.
  ##
  ## We first probe the dimensions with ffprobe (cheap, deterministic),
  ## then pipe the rawvideo bytes out of ffmpeg. The resulting buffer is
  ## exactly `width * height` bytes long.
  let (w, h) = probeImageSize(path)
  let ffmpegPath = resolveFfmpegBinary()
  let env = sanitizedEnv(ffmpegPath)
  let p = startProcess(
    command = ffmpegPath,
    args = @[
      "-hide_banner",
      "-loglevel", "error",
      "-i", path,
      "-vframes", "1",
      "-f", "rawvideo",
      "-pix_fmt", "gray",
      "pipe:1"
    ],
    env = env,
    options = {}
  )
  let buffer = p.outputStream().readAll()
  let code = p.waitForExit()
  p.close()
  if code != 0:
    raise newException(ImageMathError,
      "ffmpeg decode failed (" & $code & ") for " & path)
  let expected = w * h
  if buffer.len != expected:
    raise newException(ImageMathError,
      "ffmpeg produced " & $buffer.len & " gray bytes but expected " &
      $expected & " (" & $w & "x" & $h & ") for " & path)
  result = GrayImage(width: w, height: h, pixels: buffer)

# ---------------------------------------------------------------------------
# Video: probing, frame sampling and segmentation
# ---------------------------------------------------------------------------

proc resolveMediaTools*(): tuple[ffmpeg, ffprobe: string] =
  ## The `ffmpeg` and `ffprobe` binaries this module runs. Raises
  ## `MediaToolMissingError` when either cannot be found.
  try:
    result.ffmpeg = resolveFfmpegBinary()
  except MediaCompositionError as e:
    raise newException(MediaToolMissingError, e.msg)
  try:
    result.ffprobe = ffprobeBinaryFor(result.ffmpeg)
  except ImageMathError as e:
    raise newException(MediaToolMissingError, e.msg)

proc videoDecodeFeature*(probe: bool): Feature =
  ## The `video-decode` feature of the `capabilities` report (spec §7.5).
  ## Without `probe` it is `available` when both binaries are found; with
  ## `probe` it is `supported` only when `ffmpeg -version` actually runs. A
  ## missing or broken binary is `unavailable` / `missing-tool`.
  const remedy = "install ffmpeg (with ffprobe beside it) on PATH or set FFMPEG_BIN"
  result = Feature(feature: "video-decode", backend: "ffmpeg", state: fsUnavailable,
                   reason: some("missing-tool"), remedy: some(remedy))
  var tools: tuple[ffmpeg, ffprobe: string]
  try: tools = resolveMediaTools()
  except MediaToolMissingError: return
  if not probe:
    return Feature(feature: "video-decode", backend: "ffmpeg", state: fsAvailable,
                   reason: none(string), remedy: none(string))
  try:
    let p = startProcess(tools.ffmpeg, args = @["-hide_banner", "-version"],
                         env = sanitizedEnv(tools.ffmpeg), options = {poStdErrToStdOut})
    try:
      discard p.outputStream.readAll()
      if p.waitForExit() == 0:
        result = Feature(feature: "video-decode", backend: "ffmpeg", state: fsSupported,
                         reason: none(string), remedy: none(string))
    finally:
      p.close()
  except OSError:
    discard

const stderrTailBytes = 4096
  ## How much of a child's stderr `StderrTail` keeps.

type
  StderrTail = object
    ## The first `stderrTailBytes` bytes a child writes to stderr. A thread
    ## of its own reads the pipe to its end and discards the rest, so the
    ## child never blocks on a full stderr pipe while its stdout is being
    ## read (a damaged video makes ffmpeg log every bad macroblock, hundreds
    ## of kilobytes at `-loglevel error`), and the memory kept stays bounded.
    handle: FileHandle
    len: int
    bytes: array[stderrTailBytes, char]

proc drainStderr(t: ptr StderrTail) {.thread.} =
  var chunk: array[4096, char]
  while true:
    var n: int
    when defined(windows):
      var got: int32 = 0
      if winlean.readFile(winlean.Handle(t.handle), addr chunk[0], int32(chunk.len),
                          addr got, nil) == 0:
        break
      n = int(got)
    else:
      n = int(posix.read(t.handle, addr chunk[0], chunk.len))
      if n < 0 and posix.errno == posix.EINTR: continue
    if n <= 0: break
    let keep = min(n, stderrTailBytes - t.len)
    if keep > 0:
      copyMem(addr t.bytes[t.len], addr chunk[0], keep)
      t.len += keep

proc text(t: StderrTail): string =
  result = newString(t.len)
  if t.len > 0: copyMem(addr result[0], unsafeAddr t.bytes[0], t.len)

proc firstLine(diag: string): string =
  ## The first line of a child's diagnostics, shortened for an error message.
  ## ffmpeg's and ffprobe's (`-loglevel error`) name the file, the demuxer and
  ## the codec; they carry no decoded content.
  result = diag.strip()
  let nl = result.find('\n')
  if nl >= 0: result.setLen(nl)
  result = result.strip()
  if result.len > 200: result = result[0 ..< 200] & "…"

proc stopChild(p: Process) =
  ## Stop a child whose output is no longer wanted, and reap it so it does not
  ## linger as a zombie. It is killed outright: it has nothing to flush, and a
  ## polite SIGTERM can sit unanswered while ffmpeg is blocked writing a frame
  ## nobody reads.
  try:
    if p.running: p.kill()
    discard p.waitForExit()
  except OSError, ValueError:
    discard

proc inputUrl(path: string): string =
  ## The input argument ffmpeg and ffprobe are given for `path`: an absolute
  ## path behind the `file:` protocol, so a name that starts with `-` cannot
  ## be read as an option and a name such as `concat:a|b`, `pipe:0` or
  ## `http://…` cannot select another protocol
  ## (https://ffmpeg.org/ffmpeg-protocols.html#file).
  "file:" & absolutePath(path)

proc checkVideoFile(path: string) =
  ## Raises `VideoDecodeError` unless `path` is a regular file (a FIFO or a
  ## device would block ffprobe on a read that never ends).
  var kind: PathComponent
  try: kind = getFileInfo(path).kind
  except OSError:
    raise newException(VideoDecodeError, "no video at " & path)
  if kind != pcFile:
    raise newException(VideoDecodeError, path & " is not a regular file")

proc parseVideoProbe*(jsonText, path: string): VideoSource =
  ## Parse the JSON of `ffprobe -show_entries stream=width,height:format=duration
  ## -of json`. `format.duration` is a string ("4.000000") in ffprobe's output;
  ## a missing or "N/A" duration is none. Raises `VideoDecodeError` when there
  ## is no video stream with a positive size.
  result.path = path
  var n: JsonNode
  try: n = parseJson(jsonText)
  except JsonParsingError, ValueError:
    raise newException(VideoDecodeError, "ffprobe printed no JSON for " & path)
  let streams = n{"streams"}
  if streams.isNil or streams.kind != JArray or streams.len == 0 or
     streams[0].kind != JObject:
    raise newException(VideoDecodeError, path & " has no video stream")
  let st = streams[0]
  if st{"width"}.isNil or st{"width"}.kind != JInt or
     st{"height"}.isNil or st{"height"}.kind != JInt:
    raise newException(VideoDecodeError, path & ": ffprobe reported no frame size")
  result.width = st["width"].getInt
  result.height = st["height"].getInt
  if result.width <= 0 or result.height <= 0:
    raise newException(VideoDecodeError, path & ": ffprobe reported a frame size of " &
      $result.width & "x" & $result.height)
  let d = n{"format", "duration"}
  if not d.isNil:
    var v = NaN
    case d.kind
    of JString:
      try: v = parseFloat(d.getStr)
      except ValueError: discard
    of JFloat, JInt: v = d.getFloat
    else: discard
    if v == v and v >= 0.0 and v != Inf: result.durationS = some(v)

proc probeVideoSource*(path: string): VideoSource =
  ## Run ffprobe on `path`. Raises `MediaToolMissingError` without ffprobe and
  ## `VideoDecodeError` when `path` is missing, is not a regular file or is
  ## not a video.
  if not fileExists(path):
    raise newException(VideoDecodeError, "no video at " & path)
  checkVideoFile(path)
  let tools = resolveMediaTools()
  var p: Process
  try:
    p = startProcess(tools.ffprobe,
      args = @["-hide_banner", "-v", "error", "-select_streams", "v:0",
               "-show_entries", "stream=width,height:format=duration", "-of", "json",
               inputUrl(path)],
      env = sanitizedEnv(tools.ffprobe), options = {})
  except OSError as e:
    raise newException(MediaToolMissingError, "cannot run " & tools.ffprobe & ": " & e.msg)
  # stdout and stderr are separate: ffprobe warns on stderr about a damaged
  # stream it can still describe, and those lines must not land in the JSON.
  var tail = StderrTail(handle: p.errorHandle)
  var drain: Thread[ptr StderrTail]
  var output = ""
  var code = -1
  var finished = false
  try:
    createThread(drain, drainStderr, addr tail)
    try:
      p.inputStream.close()
      output = p.outputStream.readAll()
      code = p.waitForExit()
      finished = true
    finally:
      if not finished: stopChild(p)
      joinThread(drain)
  finally:
    if not finished: stopChild(p)   # also when the drain thread did not start
    p.close()
  if code != 0:
    let diag = firstLine(tail.text)
    raise newException(VideoDecodeError, path & " is not a video ffprobe can read" &
      (if diag.len > 0: " (" & diag & ")" else: ""))
  parseVideoProbe(output, path)

proc rateText(f: float): string =
  ## A sample rate as ffmpeg's `fps` filter reads it, without exponent.
  result = formatFloat(f, ffDecimal, precision = 6)
  result = result.strip(leading = false, chars = {'0'})
  if result.endsWith("."): result.setLen(result.len - 1)

proc buildRawFramesArgv*(path: string, fps: float, width, height: int): seq[string] =
  ## ffmpeg arguments (without the binary) that sample `path` at `fps`, scale
  ## each frame to exactly `width` x `height` and write raw 8-bit gray frames
  ## to stdout. `-noautorotate` keeps the frames in the coded orientation
  ## ffprobe reported the size of; `-nostdin` keeps ffmpeg from reading the
  ## caller's input; the input goes behind the `file:` protocol (`inputUrl`).
  @["-hide_banner", "-loglevel", "error", "-nostdin", "-noautorotate",
    "-i", inputUrl(path),
    "-vf", "fps=" & rateText(fps) & ",scale=" & $width & ":" & $height,
    "-f", "rawvideo", "-pix_fmt", "gray", "pipe:1"]

proc segmentVideo*(path: string, fps = defaultVideoFps,
                   scaleWidth = defaultVideoScaleWidth,
                   threshold = defaultChangeThreshold,
                   checkpoint: proc () {.closure.} = nil): VideoSegmentation =
  ## Segment the video at `path` into distinct visual states: sample it at
  ## `fps`, scale each frame to `scaleWidth` wide (the height follows the
  ## aspect ratio, `core/segmentation.scaledHeight`), score consecutive frames
  ## with `frameSimilarity` and split with `segmentsFromSeries` at
  ## `threshold`. Only two frames are held at a time.
  ##
  ## `checkpoint`, when given, runs before each frame is read; an exception it
  ## raises (a cancellation) stops ffmpeg and propagates.
  ##
  ## Raises `ValueError` for a non-positive `fps` or `scaleWidth`,
  ## `MediaToolMissingError` without ffmpeg/ffprobe and `VideoDecodeError`
  ## when the file is missing, is not a video, fails to decode or yields no
  ## frame.
  if not (fps > 0.0) or fps == Inf:
    raise newException(ValueError, "fps must be positive and finite, got " & $fps)
  if scaleWidth <= 0:
    raise newException(ValueError, "scaleWidth must be positive, got " & $scaleWidth)
  let tools = resolveMediaTools()
  result.source = probeVideoSource(path)
  result.fps = fps
  result.scaleWidth = scaleWidth
  result.scaledHeight = scaledHeight(result.source.width, result.source.height, scaleWidth)
  result.threshold = threshold
  let w = scaleWidth
  let h = result.scaledHeight
  let frameBytes = w * h
  var series: seq[float]
  var prev, cur: GrayImage
  var code = -1
  var p: Process
  try:
    p = startProcess(tools.ffmpeg, args = buildRawFramesArgv(path, fps, w, h),
                     env = sanitizedEnv(tools.ffmpeg), options = {})
  except OSError as e:
    raise newException(MediaToolMissingError, "cannot run " & tools.ffmpeg & ": " & e.msg)
  var tail = StderrTail(handle: p.errorHandle)
  var drain: Thread[ptr StderrTail]
  var finished = false
  try:
    createThread(drain, drainStderr, addr tail)
    try:
      p.inputStream.close()
      let output = p.outputStream
      while true:
        if checkpoint != nil: checkpoint()
        var buf = newString(frameBytes)
        var got = 0
        while got < frameBytes:
          let n = output.readData(addr buf[got], frameBytes - got)
          if n <= 0: break
          got += n
        if got == 0: break
        if got < frameBytes:
          raise newException(VideoDecodeError, "ffmpeg ended " & path &
            " in the middle of a frame (" & $got & " of " & $frameBytes & " bytes)")
        cur = GrayImage(width: w, height: h, pixels: buf)
        if result.frames > 0:
          series.add frameSimilarity(prev, cur)
        prev = cur
        inc result.frames
      code = p.waitForExit()
      finished = true
    finally:
      # A cancellation, a deadline or a decode error stops ffmpeg here; the
      # drain thread then sees the end of stderr and is joined either way.
      if not finished: stopChild(p)
      joinThread(drain)
  finally:
    if not finished: stopChild(p)   # also when the drain thread did not start
    p.close()
  if code != 0:
    let diag = firstLine(tail.text)
    raise newException(VideoDecodeError, "ffmpeg could not decode " & path &
      " (exit " & $code & (if diag.len > 0: ": " & diag else: "") & ")")
  if result.frames == 0:
    raise newException(VideoDecodeError, "ffmpeg sampled no frame from " & path)
  result.segments = segmentsFromSeries(series, result.frames, fps, threshold)
