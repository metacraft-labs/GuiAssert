## The `macos-sck` capture backend: ScreenCaptureKit stills and recordings
## (spec §4.1), the default capture backend on macOS.
##
## **Where the pixels come from.** Every capture runs inside the signed
## GuiAssert helper bundle (`GuiAssertCapture.app`, built and signed by
## `gui_assert/screen_capture`), launched through `open` so that the bundle is
## its own TCC-responsible process and the Screen Recording grant is bound to
## GuiAssert's code identity, never to a terminal (spec §9.4). The bundle's
## designated requirement is keyed on its bundle id and signing certificate
## (`GUIASSERT_CAPTURE_SIGN_IDENTITY`), so a rebuild keeps the grant.
##
## * `screenshot` of a display, a region (a display capture with a source
##   rectangle) or a window. A window capture is always the window's **own
##   pixels** (`SCContentFilter(desktopIndependentWindow:)`), whatever covers
##   it, so `--own-pixels` is honoured as asked and `source.kind` is
##   `window`. Pixels are delivered in sRGB, so a known colour reads back as
##   itself. The PNG is written to a temporary name in the output directory
##   and renamed when complete.
## * `record-start` launches the helper's `record` mode detached: it streams
##   `SCStream` frames into an `AVAssetWriter` MP4 at a constant rate,
##   reporting through a status file in the state directory, until
##   `record-stop` sends it SIGTERM and it finalizes the file. `record` is
##   `record-start`, a cancellable wait that streams `progress` events, and
##   `record-stop`; a cancelled or timed-out `record` still finalizes.
## * `record-stop` reports `durationMs`, `frames`, `width` and `height`
##   **measured from the finalized file** with `core/mp4` (C12). A recorder
##   that died, or did not finalize, or a file that does not measure, is
##   exit 5 / `capture-failed` with `details.recording` in state `failed`,
##   never `stopped`; its unfinalized output is removed, so no partial MP4 is
##   left at or near `--out`.
## * A missing Screen Recording grant is exit 6 / `tcc-screen-recording`,
##   with the bundle identity and the System Settings click-path in
##   `remedy`. The helper checks the grant with
##   `CGPreflightScreenCaptureAccess` before it touches ScreenCaptureKit, so
##   an ungranted identity gets a refusal, never a system prompt and never an
##   empty success.
##
## **Enumeration** (`displays`, `windows`) is `macos-cgwindow`'s, in-process.
## When the process running GuiAssert cannot read window titles, `windows`
## asks the helper bundle for them, so `titlesVisible` follows GuiAssert's
## own grant.
##
## **Captured content off stderr** (C15). The helper's own stdout and stderr
## (which repeat window titles in their reports) are never passed through:
## `open` discards them, and every message this module builds names ids,
## owners and paths, never titles or pixels.

import std/[algorithm, json, options, os, strutils]

import ../../core/[geometry, desktop_types, interfaces, contract, mp4, sha256]
import ../../[cancel, state_store, screen_capture]
import ./macos_cgwindow

const
  macosSckName* = "macos-sck"
    ## The backend's contract name.
  recordingSchema = "guiassert/recording/1"
  helperTimeoutMs = 30_000
    ## Bound on one still capture by the helper (it bounds itself as well).
  recorderStartMs = 20_000
    ## How long `record-start` waits for the recorder to report frames.
  recorderStopMs = 30_000
    ## How long `record-stop` waits for the recorder to finalize.

type
  MacosSckConfig* = object
    ## What the backend runs with.
    stateDir*: string        ## the state directory (spec §7.6)
    token*: CancelToken      ## cancellation and the `--timeout-ms` deadline
    emit*: proc (event: string, data: JsonNode) {.closure.}
      ## Streaming events (`progress` of `record`); nil drops them.

  RecorderStatus* = object
    ## The recorder's `--status` file.
    state*: string           ## starting, recording, stopped, failed, denied
    code*: int               ## the helper's exit status on failure, else 0
    pid*: int
    width*, height*: int
    scale*: float
    frames*: int
    message*: string

# ---------------------------------------------------------------------------
# Pure: reports, statuses and errors
# ---------------------------------------------------------------------------

proc parseRecorderStatus*(text: string): RecorderStatus =
  ## Parse a recorder status file (`key=value` lines). A missing `state`
  ## leaves `state` empty: a status that cannot be read is never taken for a
  ## running recorder.
  result.scale = 1.0
  for raw in text.splitLines:
    let eq = raw.find('=')
    if eq <= 0: continue
    let key = raw[0 ..< eq]
    let val = raw[eq + 1 .. ^1].strip
    template intVal(): int = (try: parseInt(val) except ValueError: 0)
    case key
    of "state": result.state = val
    of "code": result.code = intVal()
    of "pid": result.pid = intVal()
    of "width": result.width = intVal()
    of "height": result.height = intVal()
    of "frames": result.frames = intVal()
    of "scale": result.scale = (try: parseFloat(val) except ValueError: 1.0)
    of "message": result.message = val
    else: discard

proc grantRemedy*(appPath, bundleId: string): string =
  ## The `remedy` of a missing Screen Recording grant: the permission, the
  ## identity that needs it and the click-path (spec §7.3).
  "grant Screen Recording to the GuiAssert capture helper " & bundleId & " (" &
    appPath & "): System Settings > Privacy & Security > Screen & System Audio " &
    "Recording, click +, press Shift-Cmd-G, paste the bundle path, click Open " &
    "and switch it on; do not grant it to a terminal"

proc deniedError*(appPath, bundleId: string): ref PermissionDeniedError =
  ## Exit 6 / `tcc-screen-recording` for the helper bundle.
  result = newBackendError(PermissionDeniedError, macosSckName, "tcc-screen-recording",
    "Screen Recording is not granted to " & bundleId & " (" & appPath & ")")
  result.remedy = grantRemedy(appPath, bundleId)

proc errorForStatus*(status: CaptureStatus, code: int, message: string,
                     appPath, bundleId, what: string): ref BackendError =
  ## The backend error of a helper that did not succeed: a denial is exit 6
  ## (`deniedError`), a target ScreenCaptureKit does not hold is exit 3
  ## (`what`: `window` or `display`), and everything else is exit 5 /
  ## `capture-failed`. (Targets and regions are validated before the helper
  ## runs, so its usage refusals mean a GuiAssert bug.) `message` is the
  ## helper's own, which names ids, owners and paths only.
  case status
  of csDenied: deniedError(appPath, bundleId)
  of csTargetNotFound:
    newBackendError(BackendNotFoundError, macosSckName, what,
      "the capture target is gone: " & message)
  of csUsage:
    newBackendError(BackendError, macosSckName, "capture-failed",
      "the capture helper refused its arguments (a GuiAssert bug): " & message)
  else:
    newBackendError(BackendError, macosSckName, "capture-failed",
      "ScreenCaptureKit capture failed (" & $status & ", code " & $code & "): " & message)

proc statusOfCode(code: int): CaptureStatus =
  case code
  of 0: csOk
  of 2: csUsage
  of 3: csTargetNotFound
  of 4: csDenied
  of 6: csWriteFailed
  of 7: csTimeout
  else: csCaptureFailed

proc pngSize*(bytes: string): tuple[width, height: int] =
  ## The width and height in a PNG's IHDR. Raises `ValueError` when `bytes`
  ## does not start with a PNG signature and an IHDR chunk.
  const sig = "\x89PNG\r\n\x1a\n"
  if bytes.len < 24 or bytes[0 ..< 8] != sig or bytes[12 ..< 16] != "IHDR":
    raise newException(ValueError, "not a PNG image")
  proc be(i: int): int =
    (ord(bytes[i]) shl 24) or (ord(bytes[i + 1]) shl 16) or
      (ord(bytes[i + 2]) shl 8) or ord(bytes[i + 3])
  (be(16), be(20))

proc finalizeRecording*(r: var Recording, tmpPath, recorderProblem: string): string =
  ## Turn the recorder's output at `tmpPath` into the recording at `r.path`:
  ## measure it with `core/mp4` and, when it is a finalized MP4 and the
  ## recorder reported no problem (`recorderProblem` ""), rename it to
  ## `r.path` and record what it measures, state `stopped`. Otherwise remove
  ## it, mark `r` failed (no frames, no duration) and return why; "" on
  ## success. `stoppedAt` is the caller's.
  var why = recorderProblem
  var info: Mp4Info
  if not fileExists(tmpPath):
    why = "the recorder left no file" & (if why.len > 0: " (" & why & ")" else: "")
  else:
    try:
      info = probeMp4File(tmpPath)
    except Mp4Error, IOError:
      why = getCurrentExceptionMsg() & (if why.len > 0: " (" & why & ")" else: "")
  if why.len == 0:
    try:
      moveFile(tmpPath, r.path)
    except OSError as e:
      why = "cannot move the recording to " & r.path & ": " & e.msg
  if why.len > 0:
    try: removeFile(tmpPath)
    except OSError: discard
    r.state = rsFailed
    r.frames = none(int)
    r.durationMs = none(int)
    return why
  r.state = rsStopped
  r.width = info.width
  r.height = info.height
  r.frames = some(info.frames)
  r.durationMs = some(info.durationMs)
  ""

proc nowStamp(): string = formatTimestamp(unixNowMs())

# ---------------------------------------------------------------------------
# Host-dependent: targets, the helper bundle, recordings
# ---------------------------------------------------------------------------

when defined(macosx):
  proc proc_pidpath(pid: cint, buf: pointer, size: uint32): cint {.importc, cdecl.}

  proc isCaptureHelper(pid: int): bool =
    ## True when `pid` runs the capture bundle's executable, so a recycled
    ## pid is never signalled.
    var buf = newString(4096)
    let n = proc_pidpath(cint(pid), addr buf[0], uint32(buf.len))
    n > 0 and buf[0 ..< n].endsWith("/Contents/MacOS/guiassert-capture")

proc helperError(status: CaptureStatus, code: int, message, what: string): ref BackendError =
  ## `errorForStatus` for the bundle in use, except that a failure while the
  ## screen is locked is exit 5 / `capture-failed` naming the lock: a locked
  ## session is the usual reason ScreenCaptureKit lists no display or cannot
  ## start a stream, and the helper cannot tell (its "target not found"
  ## would otherwise claim that an existing display or window is gone).
  when defined(macosx):
    if status notin {csOk, csDenied} and screenLocked():
      return newBackendError(BackendError, macosSckName, "capture-failed",
        "the screen is locked; ScreenCaptureKit captures nothing until the GUI " &
        "session is unlocked (" & message & ")")
  errorForStatus(status, code, message, captureAppPath(), captureBundleId(), what)

type
  Target = object
    args: seq[string]        ## the helper's target arguments
    origin: Point
    source: ImageSource
    what: string             ## `display` or `window`, for not-found

proc unavailableTool(msg: string): ref BackendUnavailableError =
  result = unavailable(macosSckName, "missing-tool", msg)
  result.remedy = "install the Xcode command line tools (swiftc), or point " &
    "GUIASSERT_CAPTURE_APP at a built GuiAssertCapture.app"

proc resolveTarget(session: string, t: CaptureTarget): Target =
  ## Validate a capture target against the window server before the helper
  ## runs, so an unknown display or window is exit 3 and a bad region exit 2
  ## without a capture attempt.
  when defined(macosx):
    case t.kind
    of ctkDisplay:
      let displays = readDisplays()
      var d: Display
      var found = false
      for x in displays:
        if (t.id.isSome and x.id == t.id.get) or (t.id.isNone and x.primary):
          d = x
          found = true
      if not found:
        if t.id.isSome:
          raise newBackendError(BackendNotFoundError, macosSckName, "display",
            "no display '" & t.id.get & "'")
        raise newBackendError(BackendError, macosSckName, "capture-failed",
          "the window server reports no primary display")
      result = Target(args: @["--display-id", d.id], origin: point(d.bounds.x, d.bounds.y),
        source: ImageSource(kind: iskDisplay, id: some(d.id), session: some(session)),
        what: "display")
    of ctkWindow:
      if t.id.isNone:
        raise badArgs("missing-argument", "a window capture names the window")
      let id = try: parseInt(t.id.get) except ValueError: -1
      var bounds: Rect
      var found = false
      if id > 0:
        for r in readSnapshot(true).rows:
          if r.id == id:
            bounds = r.bounds
            found = true
            break
      if not found:
        raise newBackendError(BackendNotFoundError, macosSckName, "window",
          "no window '" & t.id.get & "'")
      result = Target(args: @["--window-id", $id], origin: point(bounds.x, bounds.y),
        source: ImageSource(kind: iskWindow, id: some($id), session: some(session)),
        what: "window")
    of ctkRegion:
      if t.region.isEmpty:
        raise badArgs("invalid-value", "the capture region is empty")
      var inside = false
      for d in readDisplays():
        if d.bounds.contains(t.region): inside = true
      if not inside:
        raise badArgs("invalid-value", "the region " & $t.region &
          " does not lie within one display")
      let r = t.region
      result = Target(args: @["--region", $r.x & "," & $r.y & "," & $r.width & "," & $r.height],
        origin: point(r.x, r.y),
        source: ImageSource(kind: iskRegion, id: none(string), session: some(session)),
        what: "display")
  else:
    raise unavailable(macosSckName, "wrong-platform", "the macos-sck backend runs on macOS only")

proc outputTemp(outPath, tag, ext: string): string =
  ## The temporary sibling of `outPath` a capture is written to before the
  ## rename. The output directory must exist (`not-found` / `file`).
  let dir = outPath.parentDir
  if not dirExists(dir):
    raise newBackendError(BackendNotFoundError, macosSckName, "file",
      "the output directory does not exist: " & dir)
  dir / ("." & outPath.extractFilename & ".partial-" & tag & ext)

proc helperBudget(token: CancelToken): int =
  ## The time one helper run may take: the fixed bound, or less when the
  ## invocation's deadline is nearer (never under a second, so a nearly
  ## expired deadline fails as a deadline, not as a capture failure).
  max(1000, min(helperTimeoutMs, token.remainingMs))

proc privateTempDir(cfg: MacosSckConfig, tag: string): string =
  ## A fresh private directory under the state directory for one helper
  ## run's report files; the caller removes it.
  let base = cfg.stateDir / "macos-sck"
  ensurePrivateDir(base)
  result = base / (tag & "-" & $getCurrentProcessId() & "-" & $unixNowMs())
  var n = 0
  while dirExists(result):
    inc n
    result = base / (tag & "-" & $getCurrentProcessId() & "-" & $unixNowMs() & "-" & $n)
  ensurePrivateDir(result)

proc runBundle(cfg: MacosSckConfig, args: seq[string], tag: string,
               extra: proc (reportPath: string) {.closure.} = nil): StillCaptureReport =
  ## Run the helper inside the bundle and return its report. `extra` reads
  ## any side file the mode writes next to the report before the directory
  ## is removed.
  let dir = cfg.privateTempDir(tag)
  try:
    let rp = dir / "report.txt"
    try:
      result = runHelperViaApp(args & @["--report", rp], cfg.token.helperBudget + 15_000, rp)
    except StillCaptureUnavailable as e:
      raise unavailableTool("the capture helper bundle is unavailable: " & e.msg)
    if extra != nil: extra(rp)
  finally:
    try: removeDir(dir)
    except OSError: discard

proc capture(cfg: MacosSckConfig, req: CaptureRequest): ImageRef =
  cfg.token.checkpoint()
  let t = resolveTarget(req.session, req.target)
  let outPath = absolutePath(req.outPath)
  let tmp = outputTemp(outPath, $getCurrentProcessId(), ".png")
  let mode = if req.target.kind == ctkWindow: "window" else: "display"
  var args = @[mode, "--out", tmp, "--srgb", "--timeout",
               formatFloat(float(cfg.token.helperBudget) / 1000.0, ffDecimal, 1)] & t.args
  if mode == "display" and not req.cursor: args.add "--no-cursor"
  # A window is named by id; the helper's attestation must not drop one on
  # another layer (a floating panel) or off screen before ScreenCaptureKit
  # is asked for it.
  if mode == "window": args.add @["--any-layer", "--include-offscreen"]
  var rep: StillCaptureReport
  try:
    rep = cfg.runBundle(args, "still")
    cfg.token.checkpoint()
    if rep.status != csOk:
      raise helperError(rep.status, rep.code, rep.message, t.what)
    if not fileExists(tmp):
      raise newBackendError(BackendError, macosSckName, "capture-failed",
        "the capture helper reported success but wrote no image")
    var bytes: string
    try: bytes = readFileCapped(tmp, maxImageFileBytes)
    except IOError as e:
      raise newBackendError(BackendError, macosSckName, "capture-failed",
        "cannot read the captured image: " & e.msg)
    let (w, h) = try: pngSize(bytes)
                 except ValueError:
                   raise newBackendError(BackendError, macosSckName, "capture-failed",
                     "the capture helper wrote something that is not a PNG")
    try: moveFile(tmp, outPath)
    except OSError as e:
      raise newBackendError(BackendError, macosSckName, "capture-failed",
        "cannot write " & outPath & ": " & e.msg)
    let scale = if rep.scale > 0: rep.scale else: 1.0
    result = ImageRef(path: outPath, format: "png", width: w, height: h,
                      scale: scale, origin: t.origin, sha256: sha256Hex(bytes),
                      capturedAt: nowStamp(), source: t.source)
  finally:
    if fileExists(tmp):
      try: removeFile(tmp)
      except OSError: discard

# --- recordings --------------------------------------------------------------

proc recordingsDir(cfg: MacosSckConfig): string = cfg.stateDir / "recordings"
proc recordingPath(cfg: MacosSckConfig, id: string): string =
  cfg.recordingsDir / (id & ".json")
proc lockDir(cfg: MacosSckConfig): string = cfg.recordingsDir / ".macos-sck.lock"

proc save(cfg: MacosSckConfig, r: Recording, priv: JsonNode) =
  writeRecord(cfg.recordingPath(r.id), recordingSchema,
              %*{"recording": r.toJson, "private": priv})

proc load(cfg: MacosSckConfig, id: string): tuple[r: Recording, priv: JsonNode] =
  if not isValidName(id):
    raise badArgs("invalid-name", "invalid recording id '" & id & "'")
  let rec = readRecord(cfg.recordingPath(id), recordingSchema)
  if rec.isNone:
    raise newBackendError(BackendNotFoundError, macosSckName, "recording",
      "no recording '" & id & "'")
  try:
    result = (Recording.fromJson(rec.get["recording"]), rec.get["private"])
  except JsonShapeError, KeyError:
    raise newContractError(ekInternal, "exception", "recording record " & id &
      " is malformed: " & getCurrentExceptionMsg())

proc readStatus(path: string): RecorderStatus =
  try: parseRecorderStatus(readFileCapped(path, maxRecordBytes))
  except IOError: RecorderStatus(scale: 1.0)

proc newRecordingId(cfg: MacosSckConfig): string =
  result = "sck-" & $unixNowMs() & "-" & $getCurrentProcessId()
  var n = 0
  while fileExists(cfg.recordingPath(result)):
    inc n
    result = "sck-" & $unixNowMs() & "-" & $getCurrentProcessId() & "-" & $n

proc isOurs(priv: JsonNode): bool =
  priv.kind == JObject and priv.getOrDefault("backend").getStr == macosSckName

proc recorderAlive(pid: int): bool =
  when defined(macosx):
    pid > 0 and processAlive(pid) and isCaptureHelper(pid)
  else:
    false

proc stopRecorder(cfg: MacosSckConfig, r: var Recording, priv: JsonNode): string =
  ## Stop the recorder of `r` (if it still runs), wait for it to finalize,
  ## and finalize the recording; "" when it is `stopped`, else why it is
  ## `failed`. Persists the record either way and removes the control dir.
  let pid = priv["helperPid"].getInt
  let statusPath = priv["statusPath"].getStr
  var problem = ""
  if recorderAlive(pid):
    signalProcess(pid, force = false)
    var waited = 0
    while recorderAlive(pid) and waited < recorderStopMs:
      sleep(20)
      waited += 20
    if recorderAlive(pid):
      signalProcess(pid, force = true)
      discard waitProcessGone(pid, 2000)
      problem = "the recorder did not finalize within " & $recorderStopMs & " ms"
  let st = readStatus(statusPath)
  if problem.len == 0 and st.state != "stopped":
    problem = if st.state in ["failed", "denied"]: "the recorder failed: " & st.message
              else: "the recorder exited without finalizing (state " &
                    (if st.state.len > 0: st.state else: "unknown") & ")"
  r.stoppedAt = some(nowStamp())
  result = finalizeRecording(r, priv["tmpPath"].getStr, problem)
  cfg.save(r, priv)
  try: removeDir(priv["controlDir"].getStr)
  except OSError: discard

proc failedRecording(r: Recording, why: string): ref ContractError =
  newContractError(ekBackendError, "capture-failed", "recording '" & r.id &
    "' at " & r.path & " is not a finalized recording: " & why,
    details = %*{"recording": r.toJson})

proc startRecording(cfg: MacosSckConfig, req: RecordRequest): Recording =
  if not (req.fps > 0.0) or req.fps > 240.0:
    raise badArgs("invalid-value", "--fps must be in (0, 240]")
  cfg.token.checkpoint()
  let t = resolveTarget(req.session, req.target)
  let outPath = absolutePath(req.outPath)
  ensurePrivateDir(cfg.recordingsDir)
  var id, controlDir, statusPath, tmp: string
  withLock(cfg.lockDir, cfg.token):
    id = cfg.newRecordingId()
    controlDir = cfg.recordingsDir / (id & ".d")
    ensurePrivateDir(controlDir)
  statusPath = controlDir / "status"
  tmp = outputTemp(outPath, id, ".mp4")
  let args = @["record", "--out", tmp, "--status", statusPath, "--fps", $req.fps,
               "--srgb", "--timeout", "20"] & t.args
  var st: RecorderStatus
  try:
    try:
      let (code, output) = launchHelperDetached(args)
      if code != 0:
        raise newBackendError(BackendError, macosSckName, "capture-failed",
          "cannot launch the capture helper bundle (open exited " & $code & "): " &
          output.strip)
    except StillCaptureUnavailable as e:
      raise unavailableTool("the capture helper bundle is unavailable: " & e.msg)
    let startNs = monoNowNs()
    while true:
      st = readStatus(statusPath)
      if st.state in ["recording", "failed", "denied", "stopped"]: break
      if elapsedMsSince(startNs) > recorderStartMs:
        if recorderAlive(st.pid): signalProcess(st.pid, force = true)
        raise newBackendError(BackendError, macosSckName, "capture-failed",
          "the recorder did not start within " & $recorderStartMs & " ms")
      cfg.token.sleepCancellable(25)
    if st.state != "recording":
      raise helperError(statusOfCode(if st.state == "denied": 4 else: st.code),
        st.code, st.message, t.what)
  except CatchableError:
    # Interrupted or refused before the recording existed: stop whatever
    # started and leave nothing behind.
    if recorderAlive(st.pid): signalProcess(st.pid, force = true)
    if fileExists(tmp):
      try: removeFile(tmp)
      except OSError: discard
    try: removeDir(controlDir)
    except OSError: discard
    raise
  result = Recording(id: id, path: outPath, state: rsRecording, format: rfMp4,
                     width: st.width, height: st.height, fps: req.fps,
                     source: t.source, startedAt: nowStamp())
  let priv = %*{"backend": macosSckName, "helperPid": st.pid, "tmpPath": tmp,
                "statusPath": statusPath, "controlDir": controlDir}
  withLock(cfg.lockDir, cfg.token):
    cfg.save(result, priv)
  if req.durationMs.isNone: return
  # Blocking `record`: progress events while it runs; finalized however the
  # wait ends (spec §8.6).
  let startNs = monoNowNs()
  var interruption: ref Exception = nil
  try:
    while true:
      let left = req.durationMs.get - elapsedMsSince(startNs)
      if left <= 0: break
      cfg.token.sleepCancellable(min(left, 500))
      if cfg.emit != nil:
        cfg.emit("progress", %*{"elapsedMs": min(elapsedMsSince(startNs), req.durationMs.get),
                                "frames": readStatus(statusPath).frames})
  except ContractError:
    interruption = getCurrentException()
  # Finalizing must not be skipped because the invocation was cancelled:
  # the lock is taken on a token of its own (bounded by the lock's wait).
  var why: string
  let lockToken = newCancelToken()
  try:
    withLock(cfg.lockDir, lockToken):
      why = cfg.stopRecorder(result, priv)
  finally:
    lockToken.free()
  if interruption != nil: raise interruption
  if why.len > 0: raise failedRecording(result, why)

proc stopRecording(cfg: MacosSckConfig, id: string): Recording =
  var why: string
  withLock(cfg.lockDir, cfg.token):
    var (r, priv) = cfg.load(id)
    if not isOurs(priv):
      raise newBackendError(BackendError, macosSckName, "capture-failed",
        "recording '" & id & "' was not made by the macos-sck backend")
    if r.state != rsRecording:
      raise newBackendError(BackendError, macosSckName, "capture-failed",
        "recording '" & id & "' is not running (" & $r.state & ")")
    why = cfg.stopRecorder(r, priv)
    result = r
  if why.len > 0: raise failedRecording(result, why)

proc listRecordings(cfg: MacosSckConfig): seq[Recording] =
  ## Every recording record, newest last. A macos-sck recording whose
  ## recorder is gone without having been stopped is reconciled to `failed`
  ## (its unfinalized output removed) before it is listed.
  let dir = cfg.recordingsDir
  if not dirExists(dir): return
  withLock(cfg.lockDir, cfg.token):
    var names: seq[string]
    for k, p in walkDir(dir):
      if k in {pcFile, pcLinkToFile} and p.endsWith(".json"): names.add p
    names.sort()
    for p in names:
      let id = p.extractFilename[0 ..< ^5]
      var (r, priv) = cfg.load(id)
      if isOurs(priv) and r.state == rsRecording and
         not recorderAlive(priv["helperPid"].getInt):
        discard cfg.stopRecorder(r, priv)
      result.add r

# --- features and permission -------------------------------------------------

proc preflightBundle(cfg: MacosSckConfig): tuple[ok: bool, granted: bool, why: string] =
  ## Ask the bundle whether it holds the grant. `ok` is false when the
  ## bundle could not answer at all.
  try:
    let rep = cfg.runBundle(@["preflight"], "preflight")
    case rep.status
    of csOk: (true, true, "")
    of csDenied: (true, false, "")
    else: (false, false, "the capture helper did not answer the preflight: " & rep.message)
  except BackendUnavailableError as e:
    (false, false, e.msg)

proc sckFeatures(cfg: MacosSckConfig, probe: bool): seq[Feature] =
  let names = ["display-capture", "window-capture", "region-capture",
               "own-pixels-capture", "recording"]
  proc f(name: string, state: FeatureState, reason = "", remedy = ""): Feature =
    Feature(feature: name, backend: macosSckName, state: state,
            reason: (if reason.len > 0: some(reason) else: none(string)),
            remedy: (if remedy.len > 0: some(remedy) else: none(string)))
  when not defined(macosx):
    result.add f("window-enumeration", fsUnavailable, "wrong-platform",
                 "select a capture backend for this platform")
    for n in names:
      result.add f(n, fsUnavailable, "wrong-platform", "select a capture backend for this platform")
  else:
    if not stillCaptureProbablyAvailable():
      result.add f("window-enumeration", fsAvailable)
      for n in names:
        result.add f(n, fsUnavailable, "missing-tool",
          "install the Xcode command line tools (swiftc), or set GUIASSERT_CAPTURE_APP")
      return
    if not probe:
      result.add f("window-enumeration", fsAvailable)
      for n in names: result.add f(n, fsAvailable)
      return
    let enumerates = try: readSnapshot(false).rows.len > 0
                     except BackendError: false
    let pf = cfg.preflightBundle()
    if not enumerates:
      result.add f("window-enumeration", fsUnavailable, "display-server-unsupported",
                   "run inside a logged-in macOS GUI session")
    elif pf.granted or screenRecordingPreflight():
      result.add f("window-enumeration", fsSupported)
    else:
      result.add f("window-enumeration", fsDegraded, "titles-redacted")
    for n in names:
      result.add(
        if not pf.ok: f(n, fsUnavailable, "missing-tool", pf.why)
        elif pf.granted: f(n, fsSupported)
        else: f(n, fsUnavailable, "tcc-screen-recording",
                grantRemedy(captureAppPath(), captureBundleId())))

proc screenRecordingState*(cfg: MacosSckConfig, probe: bool):
    tuple[state: PermissionState, identity: Option[string]] =
  ## Screen Recording as the helper bundle holds it: `granted` or `denied`
  ## when `probe` asked the bundle, `unknown` otherwise (or when the bundle
  ## could not answer). `identity` is the bundle the grant is evaluated for.
  when defined(macosx):
    let identity = some(captureBundleId() & " (" & captureAppPath() & ")")
    if not probe: return (psUnknown, identity)
    let pf = cfg.preflightBundle()
    if not pf.ok: return (psUnknown, identity)
    ((if pf.granted: psGranted else: psDenied), identity)
  else:
    (psNotApplicable, none(string))

proc windowsWithTitles(cfg: MacosSckConfig, filter: WindowFilter): WindowList =
  ## `macos-cgwindow`'s enumeration, with the titles read by the helper
  ## bundle when this process cannot read them itself.
  when defined(macosx):
    var snap = readSnapshot(filter.includeOffscreen)
    if not snap.titlesVisible and stillCaptureProbablyAvailable():
      var titles: seq[WindowInfo]
      var granted = false
      try:
        let rep = cfg.runBundle(@["enumerate", "--any-layer", "--include-offscreen"],
          "enumerate", proc (rp: string) =
            let tsv = rp & ".tsv"
            if fileExists(tsv):
              titles = parseWindowListTsv(readFileCapped(tsv, maxRecordBytes)))
        granted = rep.preflight
      except BackendUnavailableError, IOError:
        # The bundle cannot help; titles stay redacted, which the answer
        # says (titlesVisible false). Not an enumeration failure.
        granted = false
      if granted:
        snap.titlesVisible = true
        for r in snap.rows.mitems:
          r.title = none(string)
          for w in titles:
            if w.windowId == r.id and w.title.len > 0:
              r.title = some(w.title)
              break
    assembleWindows(snap, filter)
  else:
    raise unavailable(macosSckName, "wrong-platform", "the macos-sck backend runs on macOS only")

# ---------------------------------------------------------------------------
# The backend
# ---------------------------------------------------------------------------

proc newMacosSckCapture*(cfg: MacosSckConfig): CaptureBackend =
  ## The `macos-sck` backend (module doc). Off macOS every operation raises
  ## `backend-unavailable` / `wrong-platform`.
  result.name = macosSckName
  let enumeration = newMacosCgwindowCapture()
  result.displays = enumeration.displays
  result.windows = proc (session: string, filter: WindowFilter): WindowList =
    cfg.windowsWithTitles(filter)
  result.capture = proc (req: CaptureRequest): ImageRef = cfg.capture(req)
  result.startRecording = proc (req: RecordRequest): Recording = cfg.startRecording(req)
  result.stopRecording = proc (id: string): Recording = cfg.stopRecording(id)
  result.recordings = proc (): seq[Recording] = cfg.listRecordings()
  result.features = proc (probe: bool): seq[Feature] = cfg.sckFeatures(probe)
  result.screenRecording = proc (probe: bool):
      tuple[state: PermissionState, identity: Option[string]] =
    cfg.screenRecordingState(probe)
