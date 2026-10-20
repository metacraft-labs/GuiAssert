## The fixture capture backend: displays, windows, stills and recordings of
## the fixture desktop (spec §9.2). No OS access: frames are rendered by the
## pure core from the session's fixture desktop (`backends/fixture_desktop`).
##
## * `capture` writes a PNG atomically and records the words drawn on it, so
##   the fixture OCR reads them back exactly.
## * A window capture is the window's own pixels by default; a scenario with
##   `"windowCapture": "crop"` behaves like a compositor without per-window
##   capture: it crops the display (`source.kind: "window-crop"`) and refuses
##   `--own-pixels` (`unsupported-option`) instead of pretending.
## * Recordings are `png-sequence` when the media backend is not compiled in
##   (`guiassert-fixture`), otherwise MP4 encoded by ffmpeg. A blocking
##   recording sleeps through its duration and streams `progress` events; a
##   started one is finished by `stopRecording`, its duration taken from the
##   fixture's logical clock, so the result is deterministic.

import std/[json, options, os, osproc, streams, strutils, math]

import ../../core/[geometry, image, png, contract, desktop_types, interfaces,
                   sha256]
import ../../[cancel, state_store]
import ../fixture_desktop

const recordingSchema = "guiassert/recording/1"

proc recordingPath(cfg: FixtureConfig, id: string): string =
  cfg.stateDir / "recordings" / (id & ".json")

proc targetToJson(t: CaptureTarget): JsonNode =
  case t.kind
  of ctkDisplay, ctkWindow:
    %*{"kind": $t.kind, "id": (if t.id.isSome: %t.id.get else: newJNull())}
  of ctkRegion: %*{"kind": $t.kind, "region": t.region.toJson}

proc targetFromJson(n: JsonNode): CaptureTarget =
  let kind = n["kind"].getStr
  case kind
  of "display", "window":
    let id = if n["id"].kind == JNull: none(string) else: some(n["id"].getStr)
    result = if kind == "display": CaptureTarget(kind: ctkDisplay, id: id)
             else: CaptureTarget(kind: ctkWindow, id: id)
  else:
    result = CaptureTarget(kind: ctkRegion,
                           region: rectFromJson(n["region"], "target.region"))

type
  Area = object
    rect: Rect          ## desktop coordinates
    scale: float
    onlyWindow: string
    source: ImageSource

proc resolveArea(d: Desktop, session: string, t: CaptureTarget, ownPixels: bool): Area =
  ## Where a capture target lies on the desktop, at which scale, and how the
  ## result's `source` is described.
  case t.kind
  of ctkDisplay:
    let disp = d.displayOf(t.id)
    Area(rect: disp.bounds, scale: disp.scale,
         source: ImageSource(kind: iskDisplay, id: some(disp.id), session: some(session)))
  of ctkWindow:
    if t.id.isNone:
      raise badArgs("missing-argument", "a window capture names the window")
    let wi = d.windowIndex(t.id.get)
    if wi < 0: raise notFound("window", "no window '" & t.id.get & "'")
    let w = d.windows[wi]
    let disp = d.displayOf(w.display)
    if d.windowCapture == "crop":
      if ownPixels:
        raise unsupported("this fixture scenario has no per-window capture " &
          "(windowCapture: crop); --own-pixels cannot be honoured")
      Area(rect: intersection(w.bounds, disp.bounds), scale: disp.scale,
           source: ImageSource(kind: iskWindowCrop, id: some(w.id), session: some(session)))
    else:
      Area(rect: w.bounds, scale: disp.scale, onlyWindow: w.id,
           source: ImageSource(kind: iskWindow, id: some(w.id), session: some(session)))
  of ctkRegion:
    if t.region.isEmpty:
      raise badArgs("invalid-value", "the capture region is empty")
    for disp in d.displays:
      if disp.bounds.contains(t.region):
        return Area(rect: t.region, scale: disp.scale,
                    source: ImageSource(kind: iskRegion, id: none(string),
                                        session: some(session)))
    raise badArgs("invalid-value", "the region " & $t.region &
      " does not lie within one display")

proc renderTarget(cfg: FixtureConfig, d: Desktop, a: Area, cursor: bool):
    tuple[png: string, frame: Frame] =
  let f = d.renderArea(a.rect, a.scale, a.onlyWindow, cursor)
  (encodePng(f.image), f)

proc checkScreenRecording(cfg: FixtureConfig) =
  if cfg.env.denyScreenRecording: raise denied(screenRecording = true)

proc writeOutputs(cfg: FixtureConfig, pngBytes: string, frames: int, fps: float,
                  outPath: string): tuple[format: RecordingFormat, width, height: int] =
  ## Write a recording of `frames` identical frames: a PNG directory without
  ## the media backend, an MP4 through ffmpeg with it.
  let img = decodePng(pngBytes)
  let dir = outPath.parentDir
  if not dirExists(dir):
    raise notFound("file", "the output directory does not exist: " & dir)
  let tmp = dir / ("." & outPath.extractFilename & ".partial-" & $getCurrentProcessId() &
                   "-" & $getThreadId())
  removeDir(tmp)
  createDir(tmp)
  try:
    for i in 0 ..< frames:
      writeFile(tmp / (align($i, 6, '0') & ".png"), pngBytes)
    if not cfg.mediaAvailable:
      if dirExists(outPath):
        for k, p in walkDir(outPath):
          let n = p.extractFilename
          if k != pcFile or n.len != 10 or not n.endsWith(".png") or
             not n[0 .. 5].allCharsInSet(Digits):
            raise badArgs("invalid-value", "--out " & outPath &
              " exists and is not a previous PNG-sequence recording")
        removeDir(outPath)
      elif fileExists(outPath):
        raise badArgs("invalid-value", "--out " & outPath & " exists and is a file")
      moveDir(tmp, outPath)
      return (rfPngSequence, img.width, img.height)
    if cfg.ffmpegExe.len == 0:
      raise unavailable(fixtureBackendName, "missing-tool",
        "MP4 recordings need ffmpeg, which was not found (set FFMPEG_BIN)")
    let tmpMp4 = tmp / "out.mp4"
    # mpeg4 is ffmpeg's built-in MPEG-4 Part 2 encoder: always present, and
    # bit-exact output keeps the file reproducible. yuv420p needs even sizes.
    let args = @["-hide_banner", "-loglevel", "error", "-y", "-framerate", $fps,
                 "-i", tmp / "%06d.png", "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2",
                 "-c:v", "mpeg4", "-q:v", "5", "-pix_fmt", "yuv420p",
                 "-fflags", "+bitexact", "-flags", "+bitexact", tmpMp4]
    let p = startProcess(cfg.ffmpegExe, args = args, options = {poStdErrToStdOut})
    let output = p.outputStream.readAll()
    let code = p.waitForExit()
    p.close()
    if code != 0 or not fileExists(tmpMp4):
      raise failed("capture-failed", "ffmpeg could not encode the recording: " &
        output.strip)
    moveFile(tmpMp4, outPath)
    removeDir(tmp)
    return (rfMp4, img.width + img.width mod 2, img.height + img.height mod 2)
  except OSError, IOError:
    raise failed("capture-failed", "cannot write the recording " & outPath & ": " &
      getCurrentExceptionMsg())
  finally:
    if dirExists(tmp): removeDir(tmp)

proc saveRecording(cfg: FixtureConfig, r: Recording, priv: JsonNode) =
  writeRecord(cfg.recordingPath(r.id), recordingSchema,
              %*{"recording": r.toJson, "private": priv})

proc loadRecording(cfg: FixtureConfig, id: string): tuple[r: Recording, priv: JsonNode] =
  if not isValidName(id):
    raise badArgs("invalid-name", "invalid recording id '" & id & "'")
  let rec = readRecord(cfg.recordingPath(id), recordingSchema)
  if rec.isNone: raise notFound("recording", "no recording '" & id & "'")
  try:
    result = (Recording.fromJson(rec.get["recording"]), rec.get["private"])
  except JsonShapeError, KeyError:
    raise newContractError(ekInternal, "exception", "recording record " & id &
      " is malformed: " & getCurrentExceptionMsg())

proc framesFor(durationMs: int, fps: float): int =
  max(1, int(round(float(durationMs) * fps / 1000.0)))

proc newFixtureCapture*(cfg: FixtureConfig): CaptureBackend =
  ## The fixture capture backend. Raises `backend-unavailable` when
  ## GUIASSERT_FIXTURE_UNAVAILABLE names `capture`.
  cfg.checkModuleAvailable(fmCapture)
  result.name = fixtureBackendName

  result.displays = proc (session: string): seq[Display] =
    cfg.transact(t):
      result = cfg.loadDesktop(t, session).displays

  result.windows = proc (session: string, filter: WindowFilter): WindowList =
    cfg.transact(t):
      let d = cfg.loadDesktop(t, session)
      result.titlesVisible = not cfg.env.denyScreenRecording
      for w in d.windows:
        if not filter.allLayers and w.layer != 0: continue
        if not filter.includeOffscreen and (not w.onScreen or w.minimized): continue
        if filter.app.isSome and w.app != filter.app.get: continue
        if filter.pid.isSome and w.pid != filter.pid.get: continue
        if filter.title.isSome or filter.titleContains.isSome:
          if not result.titlesVisible: continue
          if filter.title.isSome and w.title != filter.title: continue
          if filter.titleContains.isSome and
             not w.title.get("").contains(filter.titleContains.get): continue
        var x = w
        if not result.titlesVisible: x.title = none(string)
        result.windows.add x

  result.capture = proc (req: CaptureRequest): ImageRef =
    cfg.checkScreenRecording()
    cfg.token.checkpoint()
    cfg.transact(t):
      let d = cfg.loadDesktop(t, req.session)
      let a = resolveArea(d, req.session, req.target, req.ownPixels)
      let (bytes, frame) = cfg.renderTarget(d, a, req.cursor)
      let outPath = absolutePath(req.outPath)
      writeFileAtomic(outPath, bytes)
      let sha = sha256Hex(bytes)
      cfg.registerFrame(sha, frame.words, point(a.rect.x, a.rect.y), a.scale)
      result = ImageRef(path: outPath, format: "png", width: frame.image.width,
                        height: frame.image.height, scale: a.scale,
                        origin: point(a.rect.x, a.rect.y), sha256: sha,
                        capturedAt: t.nowStamp(), source: a.source)

  result.startRecording = proc (req: RecordRequest): Recording =
    cfg.checkScreenRecording()
    if not (req.fps > 0.0) or req.fps > 240.0:
      raise badArgs("invalid-value", "--fps must be in (0, 240]")
    let outPath = absolutePath(req.outPath)
    var d: Desktop
    var a: Area
    var id, startedAt: string
    var startTick: int
    cfg.transact(t):
      d = cfg.loadDesktop(t, req.session)
      a = resolveArea(d, req.session, req.target, false)
      id = t.nextRecordingId()
      startedAt = t.nowStamp()
      startTick = t.currentTick
    let (bytes, frame) = cfg.renderTarget(d, a, true)
    result = Recording(id: id, path: outPath, state: rsRecording,
                       format: (if cfg.mediaAvailable: rfMp4 else: rfPngSequence),
                       width: frame.image.width, height: frame.image.height,
                       fps: req.fps, source: a.source, startedAt: startedAt)
    let priv = %*{"session": req.session, "target": targetToJson(req.target),
                  "startTick": startTick}
    if req.durationMs.isNone:
      cfg.withFixtureLock:
        cfg.saveRecording(result, priv)
      return
    # Blocking: one frame per 1/fps, a progress event per frame, finalized
    # on cancellation so the partial output stays valid (spec §8.6).
    let total = framesFor(req.durationMs.get, req.fps)
    var done = 0
    try:
      for i in 0 ..< total:
        let due = int(round(float(i + 1) * 1000.0 / req.fps))
        let prev = int(round(float(i) * 1000.0 / req.fps))
        cfg.token.sleepCancellable(due - prev)
        done = i + 1
        cfg.emit("progress", %*{"elapsedMs": due, "frames": done})
    except ContractError:
      if done > 0:
        let o = cfg.writeOutputs(bytes, done, req.fps, outPath)
        result.format = o.format
        result.state = rsStopped
        result.frames = some(done)
        result.durationMs = some(int(round(float(done) * 1000.0 / req.fps)))
        cfg.transact(t):
          result.stoppedAt = some(t.nowStamp())
          cfg.saveRecording(result, priv)
      raise
    let o = cfg.writeOutputs(bytes, total, req.fps, outPath)
    result.format = o.format
    result.width = o.width
    result.height = o.height
    result.state = rsStopped
    result.frames = some(total)
    result.durationMs = some(req.durationMs.get)
    cfg.transact(t):
      result.stoppedAt = some(t.nowStamp())
      cfg.saveRecording(result, priv)

  result.stopRecording = proc (id: string): Recording =
    var priv: JsonNode
    var d: Desktop
    var stopTick, step: int
    cfg.transact(t):
      (result, priv) = cfg.loadRecording(id)
      if result.state != rsRecording:
        raise failed("capture-failed", "recording '" & id & "' is not running (" &
          $result.state & ")")
      d = cfg.loadDesktop(t, priv["session"].getStr)
      result.stoppedAt = some(t.nowStamp())
      stopTick = t.currentTick
      step = t.stepMs
    let durationMs = (stopTick - priv["startTick"].getInt) * step
    let target = targetFromJson(priv["target"])
    let a = resolveArea(d, priv["session"].getStr, target, false)
    let (bytes, _) = cfg.renderTarget(d, a, true)
    let frames = framesFor(durationMs, result.fps)
    let o = cfg.writeOutputs(bytes, frames, result.fps, result.path)
    result.format = o.format
    result.width = o.width
    result.height = o.height
    result.state = rsStopped
    result.frames = some(frames)
    result.durationMs = some(durationMs)
    cfg.withFixtureLock:
      cfg.saveRecording(result, priv)

  result.recordings = proc (): seq[Recording] =
    let dir = cfg.stateDir / "recordings"
    if not dirExists(dir): return
    cfg.withFixtureLock:
      for p in sortedNames(dir, ".json"):
        let id = p.extractFilename[0 ..< ^5]
        result.add cfg.loadRecording(id).r

  result.features = proc (probe: bool): seq[Feature] =
    let denied = cfg.env.denyScreenRecording
    proc f(name: string, state = fsSupported, reason = ""): Feature =
      var st = state
      var r = reason
      if denied and name != "window-enumeration":
        st = fsUnavailable
        r = "tcc-screen-recording"
      Feature(feature: name, backend: fixtureBackendName, state: st,
              reason: (if r.len > 0: some(r) else: none(string)),
              remedy: (if denied and name != "window-enumeration":
                         some("unset GUIASSERT_FIXTURE_DENY") else: none(string)))
    let scen = loadScenario(cfg.scenarioPath)
    result = @[f("window-enumeration"), f("display-capture"),
               (if scen.windowCapture == "crop":
                  f("window-capture", fsDegraded, "window-crop")
                else: f("window-capture")),
               f("region-capture"),
               (if cfg.mediaAvailable: f("recording-mp4")
                else: f("recording-png-sequence"))]
