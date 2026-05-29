## verify_tts_audio_generation, verify_ffmpeg_video_composition
##
## End-to-end verification for M3:
##   1. `synthesize` produces a WAV with non-zero amplitude samples on
##      the host OS's native TTS engine.
##   2. `composeVideoWithOverlay` invokes ffmpeg and produces a valid MP4
##      whose duration is within ±200 ms of the 5-second synthetic inputs.
##
## Both tests are *not* mocked: they shell out to real `say`/`espeak-ng`
## and real `ffmpeg`/`ffprobe` binaries. If a binary is missing the test
## fails loudly — there are no graceful skips.

import std/[algorithm, json, options, os, osproc, sequtils, streams,
            strformat, strtabs, strutils, unittest]
import ../src/gui_assert/speech_synth
import ../src/gui_assert/media

# ---------------------------------------------------------------------------
# ffmpeg discovery
# ---------------------------------------------------------------------------
#
# The Homebrew ffmpeg on Apple Silicon (`/opt/homebrew/bin/ffmpeg`) is
# typically built without `--enable-libfreetype`, which means the
# `drawtext` filter required by the milestone is absent. We probe for an
# ffmpeg binary that does support `drawtext` and export it via
# `$FFMPEG_BIN` so the media module picks it up. Candidates, in order:
#   1. Anything already in `$FFMPEG_BIN`.
#   2. The first `ffmpeg` on `$PATH` if it advertises `drawtext`.
#   3. Any `/nix/store/*ffmpeg-full*bin/bin/ffmpeg` (Nix's ffmpeg-full
#      always carries libfreetype).
#   4. Any `/nix/store/*ffmpeg*bin/bin/ffmpeg`.
# If none of those carry `drawtext` we FAIL LOUDLY — no skipping.

proc ffmpegFiltersOutput(path: string): string =
  ## Run the candidate ffmpeg and capture its `-filters` listing. We strip
  ## DYLD_LIBRARY_PATH for Nix-store binaries to avoid Homebrew lib
  ## interposition (the same workaround the media module applies).
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

  # Walk /nix/store/*ffmpeg*bin/bin/ffmpeg, preferring "full" builds.
  var candidates: seq[string] = @[]
  if dirExists("/nix/store"):
    for entry in walkDir("/nix/store"):
      if entry.kind == pcDir:
        let base = entry.path.extractFilename
        if "ffmpeg" in base and base.endsWith("-bin"):
          let bin = entry.path / "bin" / "ffmpeg"
          if fileExists(bin):
            candidates.add(bin)
  # Sort: ffmpeg-full first, then by version descending.
  candidates.sort(proc(a, b: string): int =
    let aFull = if "ffmpeg-full" in a: 0 else: 1
    let bFull = if "ffmpeg-full" in b: 0 else: 1
    if aFull != bFull: return aFull - bFull
    return cmp(b, a)
  )
  for c in candidates:
    if hasDrawtext(c):
      return c
  raise newException(
    ValueError,
    "No ffmpeg binary with `drawtext` filter found. Searched $FFMPEG_BIN, " &
    "$PATH, and /nix/store/*ffmpeg*-bin/bin/ffmpeg. Install ffmpeg-full " &
    "(e.g. `nix profile install nixpkgs#ffmpeg-full`)."
  )

# Discover ffmpeg once at module load and export via env so the media
# module's `resolveFfmpegBinary` picks the same binary the test fixtures use.
let ffmpegPath = discoverFfmpegWithDrawtext()
putEnv("FFMPEG_BIN", ffmpegPath)
echo "Using ffmpeg: ", ffmpegPath

proc runFfmpegEx(args: seq[string]): tuple[output: string, exitCode: int] =
  ## Invoke the discovered ffmpeg with a sanitized environment so DYLD
  ## interposition from Homebrew does not break Nix-store ffmpeg binaries.
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

# ---------------------------------------------------------------------------
# WAV header parser
# ---------------------------------------------------------------------------
#
# We walk a RIFF WAVE file just far enough to find the `data` chunk and
# verify that at least one 16-bit PCM sample inside it has non-zero
# amplitude. This is the "non-zero audio amplitude" check called out in the
# milestones org file.

type
  WavScanResult = object
    sampleCount: int
    nonZeroSamples: int
    peakAbsoluteAmplitude: int
    bitsPerSample: int
    numChannels: int
    sampleRate: int

proc readU16Le(data: string, offset: int): int =
  result = (data[offset].uint8.int) or (data[offset + 1].uint8.int shl 8)

proc readU32Le(data: string, offset: int): int =
  result = (data[offset].uint8.int) or
           (data[offset + 1].uint8.int shl 8) or
           (data[offset + 2].uint8.int shl 16) or
           (data[offset + 3].uint8.int shl 24)

proc readS16Le(data: string, offset: int): int =
  let v = readU16Le(data, offset)
  if v >= 0x8000: result = v - 0x10000
  else: result = v

proc scanWav(path: string): WavScanResult =
  ## Parse a RIFF WAVE file from `path` and return amplitude stats for the
  ## first `data` chunk. Asserts the file is RIFF/WAVE and PCM 16-bit.
  let data = readFile(path)
  doAssert data.len >= 44, "WAV file too small: " & $data.len & " bytes"
  doAssert data[0 .. 3] == "RIFF", "Not a RIFF file: " & repr(data[0 .. 3])
  doAssert data[8 .. 11] == "WAVE", "Not a WAVE file: " & repr(data[8 .. 11])

  # Walk chunks starting at offset 12.
  var i = 12
  var fmtFound = false
  while i + 8 <= data.len:
    let id = data[i .. i + 3]
    let size = readU32Le(data, i + 4)
    let bodyStart = i + 8
    if id == "fmt ":
      doAssert size >= 16, "fmt chunk too small: " & $size
      let audioFormat = readU16Le(data, bodyStart)
      result.numChannels = readU16Le(data, bodyStart + 2)
      result.sampleRate = readU32Le(data, bodyStart + 4)
      result.bitsPerSample = readU16Le(data, bodyStart + 14)
      doAssert audioFormat == 1,
        "Expected PCM (format 1), got " & $audioFormat &
        " — adjust the data-format flags passed to the TTS engine."
      doAssert result.bitsPerSample == 16,
        "Expected 16-bit PCM, got " & $result.bitsPerSample & "-bit"
      fmtFound = true
    elif id == "data":
      doAssert fmtFound, "data chunk before fmt chunk"
      let bytesPerSample = result.bitsPerSample div 8
      let dataEnd = min(bodyStart + size, data.len)
      var pos = bodyStart
      while pos + bytesPerSample <= dataEnd:
        let sample = readS16Le(data, pos)
        let absSample = if sample < 0: -sample else: sample
        if absSample > 0:
          inc result.nonZeroSamples
        if absSample > result.peakAbsoluteAmplitude:
          result.peakAbsoluteAmplitude = absSample
        inc result.sampleCount
        pos += bytesPerSample
      return result
    i = bodyStart + size
    # RIFF chunks are word-aligned.
    if (size and 1) == 1: inc i

  raise newException(ValueError, "No data chunk found in WAV file: " & path)

# ---------------------------------------------------------------------------
# ffprobe helpers
# ---------------------------------------------------------------------------

proc ffprobeJson(path: string): JsonNode =
  ## Run `ffprobe -show_streams -show_format -print_format json -v error`
  ## against `path` and return the parsed JSON object. We co-locate
  ## ffprobe alongside the discovered ffmpeg so we get matching libraries.
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
  let exitCode = p.waitForExit()
  p.close()
  doAssert exitCode == 0, "ffprobe failed (" & $exitCode & "): " & output
  result = parseJson(output)

# ---------------------------------------------------------------------------
# Test fixtures
# ---------------------------------------------------------------------------

proc generateTestScreencast(path: string) =
  ## Generate a 5-second `testsrc` MP4 at 640x360.
  let (output, code) = runFfmpegEx(@[
    "-y", "-hide_banner", "-loglevel", "error",
    "-f", "lavfi",
    "-i", "testsrc=duration=5:size=640x360:rate=30",
    "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
    path
  ])
  doAssert code == 0, "screencast generation failed: " & output

proc generateTestAvatar(path: string) =
  ## Generate a 5-second `testsrc2` MP4 at 200x200.
  let (output, code) = runFfmpegEx(@[
    "-y", "-hide_banner", "-loglevel", "error",
    "-f", "lavfi",
    "-i", "testsrc2=duration=5:size=200x200:rate=30",
    "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
    path
  ])
  doAssert code == 0, "avatar generation failed: " & output

proc generateTestSineWav(path: string) =
  ## Generate a 5-second 440 Hz sine WAV.
  let (output, code) = runFfmpegEx(@[
    "-y", "-hide_banner", "-loglevel", "error",
    "-f", "lavfi",
    "-i", "sine=frequency=440:duration=5:sample_rate=44100",
    "-c:a", "pcm_s16le",
    path
  ])
  doAssert code == 0, "sine wav generation failed: " & output

proc generateGreenScreenAvatar(path: string) =
  ## Generate a 5-second 400x600 MP4 with a solid green background
  ## and a smaller red rectangle in the centre.  Used by the
  ## `omChromaKey` end-to-end test as a synthetic stand-in for a
  ## HeyGen / Synthesia green-screen avatar render.  The chromakey
  ## filter should remove the green channel and leave the red
  ## rectangle visible against the screencast underneath.
  let (output, code) = runFfmpegEx(@[
    "-y", "-hide_banner", "-loglevel", "error",
    "-f", "lavfi",
    "-i", "color=color=0x00ff00:size=400x600:duration=5:rate=30",
    "-f", "lavfi",
    "-i", "color=color=red:size=200x300:duration=5:rate=30",
    "-filter_complex", "[0:v][1:v]overlay=100:150[v]",
    "-map", "[v]",
    "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
    path
  ])
  doAssert code == 0, "green-screen avatar generation failed: " & output

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "M3: Audio & Visual Overlay Assembly Line":

  test "verify_tts_audio_generation":
    let outDir = getTempDir() / "gui_assert_m3"
    createDir(outDir)
    let wavPath = outDir / "narration.wav"
    if fileExists(wavPath):
      removeFile(wavPath)

    # Real subprocess invocation of the host OS's native TTS engine.
    synthesize("Hello CodeTracer testing one two three", wavPath)

    check fileExists(wavPath)
    let size = getFileSize(wavPath)
    check size > 1024
    echo &"  TTS wav size: {size} bytes at {wavPath}"

    let stats = scanWav(wavPath)
    echo &"  WAV: {stats.numChannels}ch @ {stats.sampleRate}Hz, " &
         &"{stats.bitsPerSample}-bit, {stats.sampleCount} samples, " &
         &"non-zero: {stats.nonZeroSamples}, peak |amp|: {stats.peakAbsoluteAmplitude}"

    # The spec's "non-zero audio amplitude" requirement: at least one sample
    # in the PCM stream must be non-zero, and the peak amplitude must be
    # meaningfully above the noise floor (a fully silent file would have
    # peak 0; even a near-silent file would have peak < 100; real speech
    # readily clears 1000+).
    check stats.sampleCount > 0
    check stats.nonZeroSamples > 0
    check stats.peakAbsoluteAmplitude > 100

  test "verify_ffmpeg_video_composition":
    let outDir = getTempDir() / "gui_assert_m3"
    createDir(outDir)
    let screencast = outDir / "screencast.mp4"
    let avatar = outDir / "avatar.mp4"
    let narration = outDir / "sine.wav"
    let outputMp4 = outDir / "composed.mp4"

    for p in [screencast, avatar, narration, outputMp4]:
      if fileExists(p): removeFile(p)

    generateTestScreencast(screencast)
    generateTestAvatar(avatar)
    generateTestSineWav(narration)

    let captions = @[
      Caption(
        text: "Recording in progress",
        startTime: 0.5,
        endTime: 2.0,
        x: none(string),
        y: none(string)
      ),
      Caption(
        text: "Composition demo",
        startTime: 2.5,
        endTime: 4.5,
        x: none(string),
        y: none(string)
      )
    ]

    # Argv inspection — quick structural sanity check against the pure
    # builder before paying for the real render.
    let argv = buildComposeArgv(
      screencast, narration, avatar, outputMp4, captions
    )
    check argv[0] == "ffmpeg"
    check "-filter_complex" in argv
    let filterIdx = argv.find("-filter_complex")
    let filter = argv[filterIdx + 1]
    check "geq=lum=" in filter
    check "hypot(X-W/2,Y-H/2)" in filter
    check "overlay=W-overlay_w-30:H-overlay_h-30" in filter
    check "amix=inputs=2" in filter
    check "drawtext=" in filter

    # Real render.
    composeVideoWithOverlay(screencast, narration, avatar, outputMp4, captions)

    check fileExists(outputMp4)
    let outSize = getFileSize(outputMp4)
    check outSize > 0
    echo &"  Composed mp4 size: {outSize} bytes at {outputMp4}"

    let probe = ffprobeJson(outputMp4)

    # Container check — ffprobe reports `mov,mp4,m4a,3gp,3g2,mj2` for MP4
    # files because libavformat groups them.
    let formatName = probe{"format", "format_name"}.getStr()
    check "mp4" in formatName or "mov" in formatName
    echo &"  format_name: {formatName}"

    # Duration check.
    let durationStr = probe{"format", "duration"}.getStr()
    let duration = parseFloat(durationStr)
    echo &"  duration: {duration:.3f}s"
    check duration >= 4.8
    check duration <= 5.2

    # Stream presence checks.
    var hasVideo = false
    var hasAudio = false
    for s in probe{"streams"}.items:
      case s{"codec_type"}.getStr()
      of "video": hasVideo = true
      of "audio": hasAudio = true
      else: discard
    check hasVideo
    check hasAudio

# ---------------------------------------------------------------------------
# Chromakey / presenter compose-mode argv tests (pure)
# ---------------------------------------------------------------------------

suite "presenter compose mode (chromakey)":

  test "presenterComposeOptions defaults to chromakey + bottom-left anchor":
    let p = presenterComposeOptions()
    check p.overlayMode == omChromaKey
    check p.overlayAnchor == oaBottomLeft
    check p.avatarWidth == -1
    check p.avatarHeight == int(float(p.canvasHeight) * 0.6)
    check p.chromaKey.color == "0x00ff00"

  test "buildFilterComplex emits the chromakey filter chain":
    let p = presenterComposeOptions()
    let f = buildFilterComplex(@[], p)
    check "chromakey=" in f
    check "0x00ff00" in f
    # The avatar scaling preserves aspect when avatarWidth == -1.
    check &"scale=-1:{p.avatarHeight}" in f
    # Bottom-anchored overlay: y=H-overlay_h (no margin) so the
    # human figure extends naturally to the lower edge.
    check "overlay=" & $p.margin & ":H-overlay_h" in f

  test "buildFilterComplex still emits the geq circle filter in omCircle mode":
    var p = defaultComposeOptions()
    p.overlayMode = omCircle
    let f = buildFilterComplex(@[], p)
    check "geq=" in f
    check "hypot" in f
    check "chromakey=" notin f

  test "bottom-right anchor in chromakey mode places overlay on the right edge":
    var p = presenterComposeOptions()
    p.overlayAnchor = oaBottomRight
    let f = buildFilterComplex(@[], p)
    check "W-overlay_w-" & $p.margin in f

  test "bottom-center anchor in chromakey mode hugs the bottom edge":
    var p = presenterComposeOptions()
    p.overlayAnchor = oaBottomCenter
    let f = buildFilterComplex(@[], p)
    check "(W-overlay_w)/2:H-overlay_h" in f

  test "ChromaKey config tuning flows through to the filter":
    var p = presenterComposeOptions()
    p.chromaKey = ChromaKeyConfig(color: "0x22ff22", similarity: 0.25,
                                  blend: 0.15)
    let f = buildFilterComplex(@[], p)
    check "chromakey=0x22ff22:0.25:0.15" in f

  test "real ffmpeg render with chromakey-keyed presenter":
    let outDir = getTempDir() / "gui_assert_chromakey"
    createDir(outDir)
    let screencast = outDir / "screencast.mp4"
    let avatar = outDir / "green_avatar.mp4"
    let narration = outDir / "sine.wav"
    let outputMp4 = outDir / "presenter.mp4"

    for p in [screencast, avatar, narration, outputMp4]:
      if fileExists(p): removeFile(p)

    generateTestScreencast(screencast)
    generateGreenScreenAvatar(avatar)
    generateTestSineWav(narration)

    var opts = presenterComposeOptions()
    opts.canvasWidth = 1280
    opts.canvasHeight = 720
    opts.avatarHeight = 360  # half-canvas presenter
    composeVideoWithOverlay(screencast, narration, avatar, outputMp4,
                            @[], opts)
    check fileExists(outputMp4)
    let outSize = getFileSize(outputMp4)
    check outSize > 0
    let probe = ffprobeJson(outputMp4)
    var hasVideo = false
    var hasAudio = false
    for s in probe{"streams"}.items:
      case s{"codec_type"}.getStr()
      of "video": hasVideo = true
      of "audio": hasAudio = true
      else: discard
    check hasVideo
    check hasAudio
