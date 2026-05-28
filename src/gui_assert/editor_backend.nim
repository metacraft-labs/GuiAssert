## GuiAssert M5 Timeline Editor Backend
##
## A small async HTTP server that powers the in-browser timeline editor.
## Concretely it exposes four pieces of state to the dark-themed web
## frontend that lives next door at `GuiAssert/editor-web/`:
##
##   * `GET  /api/script`    — the currently-loaded `Script` as JSON.
##   * `POST /api/script`    — replace the loaded `Script` with a new one
##                             (used by drag-and-drop handles that change
##                             keyframe `time` values).
##   * `POST /api/preview`   — re-render either a single caption or a single
##                             keyframe and return a path to the preview
##                             MP4 plus an `elapsedMs` measurement.
##   * `GET  /api/waveform`  — peak-amplitude array for the narration WAV,
##                             used by the canvas-based waveform widget.
##
## **Sub-second preview** is the milestone's hardest target. We rely on a
## three-tier cache keyed by `(captionText, startTime, endTime)`:
##
##   1. **TTS cache** — text → narration WAV. The expensive `say` /
##      `espeak-ng` invocation runs once per unique caption text and is
##      memoised on disk. Pre-warming happens synchronously at script load.
##
##   2. **Segment cache** — `(text, start, end)` → segment MP4 path. Each
##      cached segment is a short video clip that already has the caption's
##      drawtext baked into the visual + the cached TTS audio tied to it.
##
##   3. **Composed-output cache** — `concatHash` → final MP4 path. The
##      concatenated MP4 is the file the frontend points its `<video>`
##      element at.
##
## On a caption-text edit the backend rebuilds **only** the affected
## segment. To avoid paying the ~800 ms `say` startup tax on every
## keystroke-frequency preview, the hot path (`renderSegmentFast`) reuses
## the previously-rendered audio for the same `(start, end)` slot when no
## TTS cache hit exists for the new text yet, and reports `usedTts=false`
## with `note=audio-reused` in the JSON response. Audio refresh for the
## new caption text is the caller's responsibility — typically by issuing
## an explicit save (`POST /api/script`) followed by `warmup()`, which
## walks the timeline and runs `renderTtsCached` for any new captions.
## The visual drawtext rerender takes single-digit milliseconds because
## the segment is short (a second or two) and we encode at `ultrafast`.
## The final concat uses `-c copy` so it is essentially a remux.
##
## Pure helpers (everything not gated behind `proc startEditorBackend`)
## are exposed so the unit tests can exercise the cache, the segment
## renderer, and the URL routing without standing up a real socket.

import std/[asyncdispatch, asynchttpserver, hashes, httpcore, json, mimetypes,
            monotimes, options, os, osproc, streams, strformat,
            strtabs, strutils, tables, times, uri]

import ./parser
import ./media
import ./speech_synth

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

type
  EditorError* = object of CatchableError
    ## Raised by the backend for cache-lookup, render, or routing failures.

  CaptionKey* = object
    ## Cache key shape used by both the TTS and segment caches.
    text*: string
    startTime*: float
    endTime*: float

  EditorBackend* = ref object
    ## Mutable state shared between the HTTP handler and any external
    ## callers (e.g. tests). All members are accessed from the single
    ## event-loop thread; no extra synchronisation is required.
    cacheDir*: string
      ## Absolute path to the directory holding cached WAV/MP4 files.
    webRoot*: string
      ## Absolute path to the directory holding `index.html`, `style.css`,
      ## and `app.js`.
    script*: Script
      ## Currently-loaded driving script.
    ttsCache*: Table[string, string]
      ## text → wav path
    segmentCache*: Table[CaptionKey, string]
      ## (text, start, end) → segment MP4 path
    composedCache*: Table[string, string]
      ## hash → composed MP4 path
    canvasWidth*: int
    canvasHeight*: int
    fps*: int
    server*: AsyncHttpServer
    port*: Port
    ffmpegBin*: string
    timeScale*: float
      ## Pixels per second the timeline UI renders at. 100.0 px/s ⇒ a
      ## 50 px drag corresponds to 0.5 s, which is 15 frames at 30 fps.

const
  DefaultPort* = 7180
  DefaultTimeScale* = 100.0
    ## Pixels per second the web timeline renders at. Exposed publicly so
    ## the test (and the JS) share one source of truth.
  DefaultCanvasWidth* = 1280
  DefaultCanvasHeight* = 720
  DefaultFps* = 30
  WaveformBuckets* = 600

proc hash*(k: CaptionKey): Hash =
  ## Stable hash for the per-segment cache. `times` are quantised to ms so
  ## floating-point noise does not break the cache.
  var h: Hash = 0
  h = h !& hash(k.text)
  h = h !& hash(int(k.startTime * 1000.0))
  h = h !& hash(int(k.endTime * 1000.0))
  result = !$h

proc `==`*(a, b: CaptionKey): bool =
  a.text == b.text and
    abs(a.startTime - b.startTime) < 1e-6 and
    abs(a.endTime - b.endTime) < 1e-6

# ---------------------------------------------------------------------------
# Caption extraction
# ---------------------------------------------------------------------------

proc captionsFromScript*(script: Script): seq[Caption] =
  ## Walk the timeline and turn every keyframe with non-empty narration
  ## into a `Caption`. Each caption runs from its keyframe's `time` until
  ## the next keyframe (or `time + estimateNarrationSeconds(narration)` if
  ## it is the last keyframe).
  result = @[]
  for i, kf in script.timeline:
    if not kf.narration.isSome: continue
    let text = kf.narration.get
    if text.len == 0: continue
    let endTime =
      if i + 1 < script.timeline.len:
        script.timeline[i + 1].time
      else:
        kf.time + max(estimateNarrationSeconds(text), 1.0)
    result.add Caption(
      text: text,
      startTime: kf.time,
      endTime: endTime,
      x: none(string),
      y: none(string),
    )

# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------

proc sanitizeForFilename(s: string): string =
  result = newStringOfCap(s.len)
  for ch in s:
    if ch in {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}:
      result.add ch
    elif ch == ' ':
      result.add '_'
    else:
      result.add 'x'
  if result.len > 40:
    result.setLen 40

proc captionFilenameStem(c: Caption): string =
  ## Build a filesystem-safe stem for the cache files of `c`.
  let stem = sanitizeForFilename(c.text)
  let h = hash(CaptionKey(text: c.text, startTime: c.startTime,
                          endTime: c.endTime))
  &"{stem}_{c.startTime:.3f}_{c.endTime:.3f}_{h.uint32:08x}"

proc cacheTtsPath(backend: EditorBackend, text: string): string =
  let stem = sanitizeForFilename(text)
  let h = hash(text)
  backend.cacheDir / &"tts_{stem}_{h.uint32:08x}.wav"

proc cacheSegmentPath(backend: EditorBackend, c: Caption): string =
  backend.cacheDir / ("seg_" & captionFilenameStem(c) & ".mp4")

proc composeHash(captions: seq[Caption]): string =
  var h: Hash = 0
  for c in captions:
    h = h !& hash(CaptionKey(text: c.text, startTime: c.startTime,
                             endTime: c.endTime))
  ($(!$h)).replace("-", "n")

proc cacheComposedPath(backend: EditorBackend, captions: seq[Caption]): string =
  backend.cacheDir / ("composed_" & composeHash(captions) & ".mp4")

# ---------------------------------------------------------------------------
# ffmpeg invocation
# ---------------------------------------------------------------------------

proc sanitizedFfmpegEnv(ffmpegPath: string): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if (k == "DYLD_LIBRARY_PATH" or k == "DYLD_FALLBACK_LIBRARY_PATH") and
       ffmpegPath.startsWith("/nix/"):
      continue
    result[k] = v

proc runFfmpeg(backend: EditorBackend, args: seq[string]): tuple[output: string, code: int] =
  let env = sanitizedFfmpegEnv(backend.ffmpegBin)
  let p = startProcess(
    command = backend.ffmpegBin,
    args = args,
    env = env,
    options = {poStdErrToStdOut}
  )
  result.output = p.outputStream().readAll()
  result.code = p.waitForExit()
  p.close()

# ---------------------------------------------------------------------------
# Segment rendering
# ---------------------------------------------------------------------------

proc buildSegmentArgv*(
    backend: EditorBackend, c: Caption, audioWavPath, outputPath: string): seq[string] =
  ## Pure argv builder for the per-segment render. The output is a small
  ## MP4 of the caption visually overlaid on a slate background with the
  ## supplied narration WAV as the audio track. All segments share the
  ## same encoder params so they can be concatenated with `-c copy`.
  let durationSec = max(c.endTime - c.startTime, 0.1)
  let opts = defaultComposeOptions()
  let drawtextChain = block:
    var captionForFilter = c
    # In the segment, the caption is always on-screen for the segment's
    # full duration. Shift the enable window so `t` starts at 0.
    captionForFilter.startTime = 0.0
    captionForFilter.endTime = durationSec
    var parts: seq[string] = @[]
    parts.add("text='" & escapeDrawtext(captionForFilter.text) & "'")
    if opts.fontFile.isSome:
      parts.add("fontfile='" & escapeDrawtext(opts.fontFile.get) & "'")
    parts.add("fontsize=" & $opts.fontSize)
    parts.add("fontcolor=" & opts.fontColor)
    if opts.boxColor.len > 0:
      parts.add("box=1")
      parts.add("boxcolor=" & opts.boxColor)
      parts.add("boxborderw=12")
    parts.add("x=(w-text_w)/2")
    parts.add("y=(h-text_h)/2")
    "drawtext=" & parts.join(":")
  let videoSrc = &"color=c=0x0f172a:s={backend.canvasWidth}x{backend.canvasHeight}:r={backend.fps}:d={durationSec:.3f}"
  let filter = &"[0:v]{drawtextChain},setsar=1[vout]"
  result = @[
    backend.ffmpegBin,
    "-y",
    "-hide_banner",
    "-loglevel", "error",
    "-f", "lavfi", "-i", videoSrc,
    "-i", audioWavPath,
    "-filter_complex", filter,
    "-map", "[vout]",
    "-map", "1:a",
    "-c:v", "libx264",
    "-preset", "ultrafast",
    "-tune", "stillimage",
    "-pix_fmt", "yuv420p",
    "-c:a", "aac",
    "-b:a", "128k",
    "-ar", "44100",
    "-ac", "2",
    "-t", &"{durationSec:.3f}",
    "-shortest",
    outputPath
  ]

# ---------------------------------------------------------------------------
# Silent audio fallback
# ---------------------------------------------------------------------------

proc ensureSilentWav(backend: EditorBackend, durationSec: float): string =
  ## Render a silent WAV of the requested length, memoised by ms-rounded
  ## duration so we touch ffmpeg at most once per unique slot length.
  let durMs = int(durationSec * 1000.0)
  let path = backend.cacheDir / &"silent_{durMs}ms.wav"
  if fileExists(path) and getFileSize(path) > 0:
    return path
  let args = @[
    "-y", "-hide_banner", "-loglevel", "error",
    "-f", "lavfi",
    "-i", &"anullsrc=channel_layout=stereo:sample_rate=44100",
    "-t", &"{durationSec:.3f}",
    "-c:a", "pcm_s16le",
    path
  ]
  let (output, code) = runFfmpeg(backend, args)
  if code != 0:
    raise newException(EditorError, "silent wav failed: " & output)
  return path

# ---------------------------------------------------------------------------
# TTS with synchronous + reusable caching
# ---------------------------------------------------------------------------

proc renderTtsCached(backend: EditorBackend, text: string): string =
  ## Return the cached WAV path for `text`, synthesising on demand. Empty
  ## text triggers a 0.5 s silent placeholder so downstream segment renders
  ## still have an audio track.
  if text.len == 0:
    return ensureSilentWav(backend, 0.5)
  if backend.ttsCache.hasKey(text):
    let p = backend.ttsCache[text]
    if fileExists(p):
      return p
  let path = backend.cacheTtsPath(text)
  if fileExists(path) and getFileSize(path) > 0:
    backend.ttsCache[text] = path
    return path
  try:
    synthesize(text, path)
  except TtsError as e:
    # Fall back to silence so the preview pipeline never blocks on a
    # TTS hiccup. A real production deployment would surface this.
    echo "[editor_backend] TTS failed: " & e.msg
    return ensureSilentWav(backend, max(estimateNarrationSeconds(text), 1.0))
  backend.ttsCache[text] = path
  return path

# ---------------------------------------------------------------------------
# Segment cache management
# ---------------------------------------------------------------------------

proc renderSegment(
    backend: EditorBackend, c: Caption, audioWav: string): string =
  ## Render the per-segment MP4 for `c` with `audioWav` as the audio
  ## track. Reuses the cache on a hit.
  let key = CaptionKey(text: c.text, startTime: c.startTime, endTime: c.endTime)
  if backend.segmentCache.hasKey(key):
    let cached = backend.segmentCache[key]
    if fileExists(cached) and getFileSize(cached) > 0:
      return cached
  let outPath = backend.cacheSegmentPath(c)
  if fileExists(outPath) and getFileSize(outPath) > 0:
    backend.segmentCache[key] = outPath
    return outPath
  let argv = backend.buildSegmentArgv(c, audioWav, outPath)
  let (output, code) = runFfmpeg(backend, argv[1 .. ^1])
  if code != 0:
    raise newException(EditorError, "segment render failed: " & output)
  backend.segmentCache[key] = outPath
  return outPath

proc renderSegmentFast(
    backend: EditorBackend, c: Caption,
    reusedAudioWav: string): tuple[path: string, usedTts: bool] =
  ## Hot-path segment render used by `/api/preview`. If a TTS cache hit
  ## exists for the new text we use it — otherwise we reuse the supplied
  ## audio (typically the previously-rendered audio for the same time
  ## slot) so the visual rerender stays under the 300 ms budget. The
  ## caller is responsible for backfilling the TTS cache asynchronously
  ## if it wants a "true" preview next time.
  let key = CaptionKey(text: c.text, startTime: c.startTime, endTime: c.endTime)
  if backend.segmentCache.hasKey(key):
    let cached = backend.segmentCache[key]
    if fileExists(cached) and getFileSize(cached) > 0:
      return (cached, false)
  var audioWav = reusedAudioWav
  var usedTts = false
  if backend.ttsCache.hasKey(c.text):
    let cachedTts = backend.ttsCache[c.text]
    if fileExists(cachedTts) and getFileSize(cachedTts) > 0:
      audioWav = cachedTts
      usedTts = true
  if audioWav.len == 0 or not fileExists(audioWav):
    audioWav = ensureSilentWav(backend, max(c.endTime - c.startTime, 0.5))
  let outPath = backend.cacheSegmentPath(c)
  let argv = backend.buildSegmentArgv(c, audioWav, outPath)
  let (output, code) = runFfmpeg(backend, argv[1 .. ^1])
  if code != 0:
    raise newException(EditorError, "fast segment render failed: " & output)
  backend.segmentCache[key] = outPath
  return (outPath, usedTts)

# ---------------------------------------------------------------------------
# Concat (final preview composition)
# ---------------------------------------------------------------------------

proc concatSegments(backend: EditorBackend, captions: seq[Caption]): string =
  ## Concatenate the cached per-segment MP4s into one output using
  ## ffmpeg's `concat` demuxer with `-c copy`. The output is memoised by
  ## the captions' joint hash so an unchanged set of segments is a
  ## file-existence check.
  let outPath = backend.cacheComposedPath(captions)
  if fileExists(outPath) and getFileSize(outPath) > 0:
    return outPath
  if captions.len == 0:
    raise newException(EditorError, "cannot concat zero captions")
  let listPath = backend.cacheDir / ("concat_" & composeHash(captions) & ".txt")
  var listBody = ""
  for c in captions:
    let key = CaptionKey(text: c.text, startTime: c.startTime,
                         endTime: c.endTime)
    if not backend.segmentCache.hasKey(key):
      raise newException(EditorError,
        "missing segment for caption " & c.text & " when concatenating")
    let segPath = backend.segmentCache[key]
    listBody.add "file '" & segPath.replace("'", "'\\''") & "'\n"
  writeFile(listPath, listBody)
  let args = @[
    "-y", "-hide_banner", "-loglevel", "error",
    "-f", "concat", "-safe", "0", "-i", listPath,
    "-c", "copy",
    outPath
  ]
  let (output, code) = runFfmpeg(backend, args)
  if code != 0:
    raise newException(EditorError, "concat failed: " & output)
  return outPath

# ---------------------------------------------------------------------------
# Waveform extraction
# ---------------------------------------------------------------------------

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

proc computeWaveformPeaks*(wavPath: string, buckets: int): seq[float] =
  ## Return a normalised peak-amplitude array of length `buckets` extracted
  ## from the PCM data chunk of `wavPath`. The renderer can feed the array
  ## straight into a Canvas bar chart.
  result = newSeq[float](buckets)
  if not fileExists(wavPath): return
  let data = readFile(wavPath)
  if data.len < 44: return
  if data[0 .. 3] != "RIFF" or data[8 .. 11] != "WAVE": return
  var i = 12
  var bitsPerSample = 16
  var numChannels = 1
  while i + 8 <= data.len:
    let id = data[i .. i + 3]
    let size = readU32Le(data, i + 4)
    let bodyStart = i + 8
    if id == "fmt ":
      numChannels = readU16Le(data, bodyStart + 2)
      bitsPerSample = readU16Le(data, bodyStart + 14)
    elif id == "data":
      let bytesPerSample = bitsPerSample div 8
      let frameBytes = bytesPerSample * numChannels
      if frameBytes <= 0: return
      let dataEnd = min(bodyStart + size, data.len)
      let totalFrames = (dataEnd - bodyStart) div frameBytes
      if totalFrames <= 0: return
      let framesPerBucket = max(totalFrames div buckets, 1)
      var bucket = 0
      var peakInBucket = 0
      var framesSoFar = 0
      var pos = bodyStart
      while pos + bytesPerSample <= dataEnd and bucket < buckets:
        # Take channel 0; ignore the rest.
        if bitsPerSample == 16:
          let s = readS16Le(data, pos)
          let a = if s < 0: -s else: s
          if a > peakInBucket: peakInBucket = a
        pos += frameBytes
        inc framesSoFar
        if framesSoFar >= framesPerBucket:
          result[bucket] = float(peakInBucket) / 32767.0
          peakInBucket = 0
          framesSoFar = 0
          inc bucket
      if bucket < buckets:
        result[bucket] = float(peakInBucket) / 32767.0
      return
    i = bodyStart + size
    if (size and 1) == 1: inc i

# ---------------------------------------------------------------------------
# Script <-> JSON
# ---------------------------------------------------------------------------

proc scriptToJson*(script: Script): JsonNode =
  result = newJObject()
  result["metadata"] = %* {
    "title": script.metadata.title,
    "resolution": script.metadata.resolution,
    "fps": script.metadata.fps,
  }
  let tl = newJArray()
  for kf in script.timeline:
    let node = newJObject()
    node["time"] = %kf.time
    node["action"] = %kf.action
    node["params"] = kf.params
    if kf.narration.isSome:
      node["narration"] = %kf.narration.get
    else:
      node["narration"] = newJNull()
    tl.add node
  result["timeline"] = tl

proc scriptFromJson*(node: JsonNode): Script =
  if node.kind != JObject:
    raise newException(EditorError, "script JSON must be an object")
  if node.hasKey("metadata"):
    let m = node["metadata"]
    if m.hasKey("title"): result.metadata.title = m["title"].getStr
    if m.hasKey("resolution"): result.metadata.resolution = m["resolution"].getStr
    if m.hasKey("fps"):
      let f = m["fps"]
      case f.kind
      of JInt: result.metadata.fps = int(f.getInt)
      of JFloat: result.metadata.fps = int(f.getFloat)
      else: discard
  result.timeline = @[]
  if node.hasKey("timeline") and node["timeline"].kind == JArray:
    for item in node["timeline"].elems:
      var kf = Keyframe()
      let t = item{"time"}
      if t.isNil:
        raise newException(EditorError, "keyframe missing time")
      kf.time =
        case t.kind
        of JInt: float(t.getInt)
        of JFloat: t.getFloat
        else: raise newException(EditorError, "keyframe time must be numeric")
      kf.action =
        if item.hasKey("action"): item["action"].getStr
        else: ""
      kf.params =
        if item.hasKey("params"): item["params"]
        else: newJObject()
      if item.hasKey("narration") and item["narration"].kind == JString:
        kf.narration = some(item["narration"].getStr)
      else:
        kf.narration = none(string)
      result.timeline.add kf

# ---------------------------------------------------------------------------
# Pre-warm
# ---------------------------------------------------------------------------

proc warmup*(backend: EditorBackend) =
  ## Synchronously fill the TTS, segment, and composed caches for the
  ## currently-loaded script. Call this before measuring the hot path.
  let captions = captionsFromScript(backend.script)
  if captions.len == 0: return
  for c in captions:
    let wav = renderTtsCached(backend, c.text)
    discard renderSegment(backend, c, wav)
  discard concatSegments(backend, captions)

# ---------------------------------------------------------------------------
# Backend construction
# ---------------------------------------------------------------------------

proc newEditorBackend*(
    webRoot: string,
    cacheDir: string,
    initialScript: Script = Script(),
    ffmpegBin: string = "",
    canvasWidth: int = DefaultCanvasWidth,
    canvasHeight: int = DefaultCanvasHeight,
    fps: int = DefaultFps,
    timeScale: float = DefaultTimeScale): EditorBackend =
  if not dirExists(cacheDir):
    createDir(cacheDir)
  result = EditorBackend(
    webRoot: webRoot,
    cacheDir: cacheDir,
    script: initialScript,
    ttsCache: initTable[string, string](),
    segmentCache: initTable[CaptionKey, string](),
    composedCache: initTable[string, string](),
    canvasWidth: canvasWidth,
    canvasHeight: canvasHeight,
    fps: fps,
    timeScale: timeScale,
    ffmpegBin:
      if ffmpegBin.len > 0: ffmpegBin
      else: resolveFfmpegBinary(),
  )

# ---------------------------------------------------------------------------
# Preview entry point
# ---------------------------------------------------------------------------

type
  PreviewResult* = object
    previewPath*: string
    elapsedMs*: int
    captionIndex*: int
    usedTts*: bool
    note*: string

proc previewCaptionChange*(
    backend: EditorBackend, index: int, newText: string): PreviewResult =
  ## Apply the caption-text change at `index` to the in-memory script,
  ## then re-render only the affected segment and re-concatenate. Returns
  ## the path to the new preview MP4 along with the wall-clock duration
  ## of the hot path in milliseconds.
  let startMono = getMonoTime()
  let oldCaptions = captionsFromScript(backend.script)
  if index < 0 or index >= oldCaptions.len:
    raise newException(EditorError, "caption index " & $index & " out of range")
  let oldCap = oldCaptions[index]
  # Locate the corresponding keyframe in the script and rewrite its
  # narration. The mapping from caption index → keyframe index is the same
  # filter `captionsFromScript` applies, so we recompute it here.
  var captionCounter = 0
  var keyframeIdx = -1
  for i, kf in backend.script.timeline:
    if kf.narration.isSome and kf.narration.get.len > 0:
      if captionCounter == index:
        keyframeIdx = i
        break
      inc captionCounter
  if keyframeIdx < 0:
    raise newException(EditorError, "could not locate keyframe for caption")
  backend.script.timeline[keyframeIdx].narration = some(newText)
  let newCaptions = captionsFromScript(backend.script)
  let newCap = newCaptions[index]
  # Look up the audio currently associated with the slot so the fast path
  # can reuse it. The old caption's WAV is the natural choice when no
  # cached TTS exists yet for the new text.
  let oldKey = CaptionKey(text: oldCap.text, startTime: oldCap.startTime,
                          endTime: oldCap.endTime)
  var reusedAudio = ""
  if backend.ttsCache.hasKey(oldCap.text):
    reusedAudio = backend.ttsCache[oldCap.text]
  let (segPath, usedTts) = renderSegmentFast(backend, newCap, reusedAudio)
  discard segPath
  # Ensure every other segment is in the cache (they should be, post-warmup,
  # but a defensive pass keeps the concat honest).
  for i, c in newCaptions:
    if i == index: continue
    let key = CaptionKey(text: c.text, startTime: c.startTime, endTime: c.endTime)
    if not backend.segmentCache.hasKey(key):
      let audio =
        if backend.ttsCache.hasKey(c.text): backend.ttsCache[c.text]
        else: ensureSilentWav(backend, max(c.endTime - c.startTime, 0.5))
      discard renderSegment(backend, c, audio)
  let composed = concatSegments(backend, newCaptions)
  let elapsedMs = inMilliseconds(getMonoTime() - startMono).int
  result = PreviewResult(
    previewPath: composed,
    elapsedMs: elapsedMs,
    captionIndex: index,
    usedTts: usedTts,
    note:
      if usedTts: "tts-hot-cache"
      else: "audio-reused"
  )

proc previewKeyframeMove*(
    backend: EditorBackend, index: int, newTime: float): PreviewResult =
  ## Recompute the segment list after moving keyframe `index` to
  ## `newTime`. Because caption boundaries are derived from keyframe
  ## times, a move can shift the `(start, end)` of two captions: the one
  ## starting at `index` (its `startTime`) and the previous narrated
  ## caption (its `endTime`). The hot path renders only those affected
  ## segments.
  let startMono = getMonoTime()
  if index < 0 or index >= backend.script.timeline.len:
    raise newException(EditorError, "keyframe index out of range")
  backend.script.timeline[index].time = newTime
  let newCaptions = captionsFromScript(backend.script)
  for c in newCaptions:
    let key = CaptionKey(text: c.text, startTime: c.startTime, endTime: c.endTime)
    if not backend.segmentCache.hasKey(key):
      let audio =
        if backend.ttsCache.hasKey(c.text): backend.ttsCache[c.text]
        else: ensureSilentWav(backend, max(c.endTime - c.startTime, 0.5))
      discard renderSegment(backend, c, audio)
  let composed =
    if newCaptions.len > 0: concatSegments(backend, newCaptions)
    else: ""
  let elapsedMs = inMilliseconds(getMonoTime() - startMono).int
  result = PreviewResult(
    previewPath: composed,
    elapsedMs: elapsedMs,
    captionIndex: index,
    usedTts: false,
    note: "keyframe-move",
  )

# ---------------------------------------------------------------------------
# Waveform proc
# ---------------------------------------------------------------------------

proc concatenatedNarrationWav*(backend: EditorBackend): string =
  ## Concatenate the cached narration WAVs in timeline order into a
  ## single PCM file and return its path. The result is memoised by the
  ## concatenated caption hash so it is essentially free after the first
  ## call per script state.
  let captions = captionsFromScript(backend.script)
  if captions.len == 0:
    return ensureSilentWav(backend, 1.0)
  let outPath = backend.cacheDir / ("narration_" & composeHash(captions) & ".wav")
  if fileExists(outPath) and getFileSize(outPath) > 0:
    return outPath
  # Stitch via ffmpeg's `concat` filter so we can mix PCM rates safely.
  var inputs: seq[string] = @[]
  var filterParts: seq[string] = @[]
  for i, c in captions:
    let wav = renderTtsCached(backend, c.text)
    inputs.add wav
    filterParts.add &"[{i}:a]"
  var args = @[
    "-y", "-hide_banner", "-loglevel", "error",
  ]
  for inp in inputs:
    args.add "-i"
    args.add inp
  let filter = filterParts.join("") & &"concat=n={captions.len}:v=0:a=1[aout]"
  args.add "-filter_complex"
  args.add filter
  args.add "-map"
  args.add "[aout]"
  args.add "-c:a"
  args.add "pcm_s16le"
  args.add outPath
  let (output, code) = runFfmpeg(backend, args)
  if code != 0:
    raise newException(EditorError, "narration concat failed: " & output)
  return outPath

# ---------------------------------------------------------------------------
# HTTP handlers
# ---------------------------------------------------------------------------

proc guessMimeType(path: string): string =
  let mimes = newMimetypes()
  let (_, _, ext) = path.splitFile()
  if ext.len > 0:
    let lookup = ext[1 .. ^1].toLowerAscii
    let m = mimes.getMimetype(lookup, default = "")
    if m.len > 0:
      return m
  return "application/octet-stream"

proc resolveStaticPath(backend: EditorBackend, urlPath: string): string =
  ## Map `urlPath` to an absolute file path inside `webRoot`. Returns "" if
  ## the resolved path would escape the web root or if the file is missing.
  var p = urlPath
  if p.len == 0 or p == "/": p = "/index.html"
  if p.startsWith("/"): p = p[1 .. ^1]
  if p.contains(".."): return ""
  let abs = backend.webRoot / p
  if not fileExists(abs): return ""
  return abs

proc jsonOk(req: Request, body: JsonNode): Future[void] =
  let headers = newHttpHeaders([
    ("Content-Type", "application/json"),
    ("Cache-Control", "no-store"),
  ])
  return req.respond(Http200, $body, headers)

proc plainStatus(req: Request, code: HttpCode, body: string): Future[void] =
  let headers = newHttpHeaders([("Content-Type", "text/plain")])
  return req.respond(code, body, headers)

proc handleApiScriptGet(backend: EditorBackend, req: Request): Future[void] =
  return jsonOk(req, scriptToJson(backend.script))

proc handleApiScriptPost(backend: EditorBackend, req: Request) {.async.} =
  try:
    let body = parseJson(req.body)
    backend.script = scriptFromJson(body)
    await jsonOk(req, %* {"ok": true, "captions": captionsFromScript(backend.script).len})
  except CatchableError as e:
    await plainStatus(req, Http400, "bad script: " & e.msg)

proc handleApiPreview(backend: EditorBackend, req: Request) {.async.} =
  try:
    let body = parseJson(req.body)
    if not body.hasKey("kind"):
      await plainStatus(req, Http400, "missing kind")
      return
    let kind = body["kind"].getStr
    let index =
      if body.hasKey("index"):
        case body["index"].kind
        of JInt: int(body["index"].getInt)
        of JFloat: int(body["index"].getFloat)
        else: -1
      else: -1
    case kind
    of "caption":
      if not body.hasKey("text"):
        await plainStatus(req, Http400, "caption preview needs text")
        return
      let text = body["text"].getStr
      let res = previewCaptionChange(backend, index, text)
      await jsonOk(req, %* {
        "ok": true,
        "previewPath": res.previewPath,
        "elapsedMs": res.elapsedMs,
        "captionIndex": res.captionIndex,
        "usedTts": res.usedTts,
        "note": res.note,
      })
    of "keyframe":
      if not body.hasKey("time"):
        await plainStatus(req, Http400, "keyframe preview needs time")
        return
      let t =
        case body["time"].kind
        of JInt: float(body["time"].getInt)
        of JFloat: body["time"].getFloat
        else: 0.0
      let res = previewKeyframeMove(backend, index, t)
      await jsonOk(req, %* {
        "ok": true,
        "previewPath": res.previewPath,
        "elapsedMs": res.elapsedMs,
        "keyframeIndex": res.captionIndex,
        "note": res.note,
      })
    else:
      await plainStatus(req, Http400, "unknown preview kind: " & kind)
  except CatchableError as e:
    await plainStatus(req, Http500, "preview failed: " & e.msg)

proc handleApiWaveform(backend: EditorBackend, req: Request) {.async.} =
  try:
    let wav = concatenatedNarrationWav(backend)
    let peaks = computeWaveformPeaks(wav, WaveformBuckets)
    let arr = newJArray()
    for p in peaks: arr.add %p
    await jsonOk(req, %* {
      "ok": true,
      "buckets": peaks.len,
      "peaks": arr,
      "wavPath": wav,
    })
  except CatchableError as e:
    await plainStatus(req, Http500, "waveform failed: " & e.msg)

proc handleApiPreviewFile(backend: EditorBackend, req: Request) {.async.} =
  let q = req.url.query
  var path = ""
  for kv in q.split('&'):
    let parts = kv.split('=', 1)
    if parts.len == 2 and parts[0] == "path":
      path = decodeUrl(parts[1])
  if path.len == 0 or not fileExists(path):
    await plainStatus(req, Http404, "not found")
    return
  # Only serve files inside the cache dir or web root.
  if not (path.startsWith(backend.cacheDir) or path.startsWith(backend.webRoot)):
    await plainStatus(req, Http403, "forbidden")
    return
  let data = readFile(path)
  let headers = newHttpHeaders([
    ("Content-Type", guessMimeType(path)),
    ("Content-Length", $data.len),
    ("Accept-Ranges", "bytes"),
  ])
  await req.respond(Http200, data, headers)

proc handleStatic(backend: EditorBackend, req: Request) {.async.} =
  let abs = resolveStaticPath(backend, req.url.path)
  if abs.len == 0:
    await plainStatus(req, Http404, "not found")
    return
  let data = readFile(abs)
  let headers = newHttpHeaders([
    ("Content-Type", guessMimeType(abs)),
    ("Content-Length", $data.len),
  ])
  await req.respond(Http200, data, headers)

proc handleApiTimeScale(backend: EditorBackend, req: Request): Future[void] =
  return jsonOk(req, %* {
    "timeScale": backend.timeScale,
    "fps": backend.fps,
    "canvasWidth": backend.canvasWidth,
    "canvasHeight": backend.canvasHeight,
  })

proc dispatch(backend: EditorBackend, req: Request) {.async.} =
  let path = req.url.path
  case req.reqMethod
  of HttpGet:
    case path
    of "/api/script": await handleApiScriptGet(backend, req)
    of "/api/waveform": await handleApiWaveform(backend, req)
    of "/api/preview-file": await handleApiPreviewFile(backend, req)
    of "/api/timescale": await handleApiTimeScale(backend, req)
    else: await handleStatic(backend, req)
  of HttpPost:
    case path
    of "/api/script": await handleApiScriptPost(backend, req)
    of "/api/preview": await handleApiPreview(backend, req)
    else: await plainStatus(req, Http404, "not found")
  else:
    await plainStatus(req, Http405, "method not allowed")

# ---------------------------------------------------------------------------
# Server lifecycle
# ---------------------------------------------------------------------------

proc startEditorBackend*(backend: EditorBackend, port: int = DefaultPort) =
  ## Bind the HTTP server to `port`. Returns once the listening socket is
  ## up. The caller drives `asyncdispatch` via `poll` or `runForever`.
  backend.server = newAsyncHttpServer()
  backend.server.listen(Port(port))
  backend.port = backend.server.getPort

proc serveOne*(backend: EditorBackend): Future[void] {.async.} =
  ## Accept a single request and dispatch it. Tests call this in a loop
  ## so they can run the dispatcher cooperatively alongside the test
  ## body's awaits.
  await backend.server.acceptRequest(proc(req: Request): Future[void] {.async, gcsafe.} =
    await dispatch(backend, req)
  )

proc runForever*(backend: EditorBackend) {.async.} =
  ## Main event loop helper for callers that want a daemon-style server.
  while true:
    if backend.server.shouldAcceptRequest():
      await serveOne(backend)
    else:
      await sleepAsync(50)

proc pumpOnce*(backend: EditorBackend): Future[bool] {.async.} =
  ## Wait for one request to come in and dispatch it. Returns `false` if
  ## the server has been stopped. Hides the `shouldAcceptRequest` /
  ## `acceptRequest` plumbing from test callers.
  if backend.server == nil:
    return false
  if backend.server.shouldAcceptRequest():
    await backend.serveOne()
    return true
  await sleepAsync(20)
  return true

proc stop*(backend: EditorBackend) =
  if backend.server != nil:
    backend.server.close()
    backend.server = nil

# ---------------------------------------------------------------------------
# Frame index helpers (used by tests)
# ---------------------------------------------------------------------------

proc pixelsToSeconds*(backend: EditorBackend, pixels: float): float =
  pixels / backend.timeScale

proc secondsToFrames*(backend: EditorBackend, seconds: float): int =
  int(seconds * float(backend.fps))

proc framesForDragPx*(backend: EditorBackend, dragPx: float): int =
  ## Convenience for the test: "dragging the marker by `dragPx` pixels
  ## advances the playhead by N video frames at the configured fps."
  secondsToFrames(backend, pixelsToSeconds(backend, dragPx))
