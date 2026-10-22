## What the Linux capture backends (`linux-wlr`, `linux-gnome`, `linux-x11`,
## `linux-portal-pipewire`; spec §4.2) share: running the tools they capture
## with, recorders that outlive the invocation that started them, the
## recording records, writing outputs by temp-and-rename, and the pure
## assembly of the `windows` answer.
##
## **The display server is the invocation's.** Every tool and helper runs
## with the environment of the invocation (`RunContext.env`, passed in as
## `LinuxCaptureConfig.env`), never with this process's own, so the session
## a capture reaches is the one the caller named through `WAYLAND_DISPLAY`,
## `SWAYSOCK`, `DISPLAY`, `XDG_RUNTIME_DIR` and `DBUS_SESSION_BUS_ADDRESS`.
## Tools are looked up on that environment's `PATH`.
##
## **Temp-and-rename.** A still is written to a hidden sibling of `--out`
## (`.<name>.partial-<tag>.png`) and renamed once it is complete; a
## recording is written to such a sibling by its recorder and renamed only
## once its container measures as finalized (spec §7.5).
##
## **Recordings** (C12). A recorder is started detached (its own session,
## reparented away from the invocation) so that `record-start` can return
## while it runs. Its record under `<state-dir>/recordings/` names its pid
## and the kernel's start time of that pid, so a recycled pid is never
## signalled or mistaken for the recorder. `record-stop` interrupts it
## (SIGINT: every recorder used here finalizes its file on it), waits for it
## to exit, and measures the file with `core/mp4`: `durationMs`, `frames`,
## `width` and `height` come from the finalized container. A recorder that
## died or did not finalize leaves a file without its `moov` index (or no
## file), which is exit 5 / `capture-failed` with `details.recording` in
## state `failed`; the unfinalized output is removed.
##
## **Captured content off stderr** (C15). A recorder's or helper's own
## output never reaches GuiAssert's stderr: a still capture's tool output is
## read into memory and only its last line is quoted in an error message
## (the tools used name outputs, geometry and codecs, never window titles),
## and a detached recorder writes into a log in its private control
## directory under the state directory, which `record-stop` removes. Titles
## read from a compositor are parsed from the tool's standard output and
## appear only in `windows` data.

import std/[json, options, os, posix, strutils, tables, algorithm]

import ../../core/[geometry, desktop_types, interfaces, contract, mp4, png, image, sha256]
import ../../[cancel, state_store]
import ../../desktop_env/helpers as linux_helpers

const
  recordingSchema* = "guiassert/recording/1"
  toolTimeoutMs* = 30_000
    ## Bound on one still capture or enumeration by a tool.
  recorderStartMs* = 20_000
    ## How long `record-start` waits for a recorder to start.
  recorderStopMs* = 30_000
    ## How long `record-stop` waits for a recorder to finalize.

type
  LinuxCaptureConfig* = object
    ## What a Linux capture backend runs with.
    stateDir*: string        ## the state directory (spec §7.6)
    token*: CancelToken      ## cancellation and the `--timeout-ms` deadline
    env*: Table[string, string]
      ## The invocation's environment: the display server, the session bus,
      ## and the `PATH` tools are found on.
    emit*: proc (event: string, data: JsonNode) {.closure.}
      ## Streaming events (`progress` of `record`); nil drops them.

  ToolRun* = object
    ## What a tool run produced.
    code*: int               ## exit status; 128 + signal when killed
    output*: string          ## its standard output
    errors*: string          ## its standard error

  StatusFile* = Table[string, string]
    ## A helper's `key=value` status file.

# ---------------------------------------------------------------------------
# Pure: errors, status files, window lists, recordings
# ---------------------------------------------------------------------------

proc kindOf*(n: JsonNode): JsonNodeKind =
  ## The kind of a JSON value that may be missing (`{}` gives nil for a
  ## missing key): JNull for nil.
  if n.isNil: JNull else: n.kind

proc feature*(backend, name: string, state: FeatureState, reason = "",
              remedy = ""): Feature =
  ## One `capabilities` entry.
  Feature(feature: name, backend: backend, state: state,
          reason: (if reason.len > 0: some(reason) else: none(string)),
          remedy: (if remedy.len > 0: some(remedy) else: none(string)))

proc captureFailed*(backend, msg: string): ref BackendError =
  ## Exit 5 / `capture-failed`.
  newBackendError(BackendError, backend, "capture-failed", msg)

proc notFound*(backend, what, msg: string): ref BackendNotFoundError =
  ## Exit 3 with reason `what` (`display`, `window`, `file`, `recording`).
  newBackendError(BackendNotFoundError, backend, what, msg)

proc unavailableWith*(backend, reason, msg, remedy: string): ref BackendUnavailableError =
  ## Exit 4 with a remedy.
  result = unavailable(backend, reason, msg)
  result.remedy = remedy

proc unavailableReason*(e: ref BackendError): string =
  ## The `reason` of an `unavailable` feature whose probe failed with `e`.
  ## A feature's reason is a `backend-unavailable` or `permission-denied`
  ## reason (spec §7.5, `contract.featureProblem`), so a probe that failed
  ## with exit 5 (`capture-failed`: the display server answered nothing
  ## usable) reports `display-server-unsupported`, its message the remedy.
  if e.reason in reasonsOf(ekBackendUnavailable) or e.reason in reasonsOf(ekPermissionDenied):
    e.reason
  else:
    "display-server-unsupported"

proc lastLine*(text: string, maxLen = 300): string =
  ## The last non-empty line of a tool's diagnostics, bounded, for an error
  ## message (module doc, "Captured content off stderr").
  for line in text.splitLines:
    if line.strip.len > 0: result = line.strip
  if result.len > maxLen: result = result[0 ..< maxLen] & "…"

proc parseStatusFile*(text: string): StatusFile =
  ## A helper's status file: `key=value` lines; later keys win, lines
  ## without `=` are ignored.
  for raw in text.splitLines:
    let eq = raw.find('=')
    if eq > 0: result[raw[0 ..< eq]] = raw[eq + 1 .. ^1].strip

proc intOf*(s: StatusFile, key: string, default = 0): int =
  ## An integer of a status file, `default` when absent or malformed.
  try: parseInt(s.getOrDefault(key, $default)) except ValueError: default

proc filterWindows*(rows: seq[Window], filter: WindowFilter): seq[Window] =
  ## The `windows` answer for `filter` from a front-to-back list: layer 0
  ## and on-screen windows unless `--all-layers` / `--include-offscreen`
  ## widen it; `--app` exact, `--pid`; `--title` exact and
  ## `--title-contains` a case-sensitive substring, matching nothing for a
  ## window whose title is unknown (spec §7.5, "Matching rules").
  for w in rows:
    if not filter.allLayers and w.layer != 0: continue
    if not filter.includeOffscreen and not w.onScreen: continue
    if filter.app.isSome and w.app != filter.app.get: continue
    if filter.pid.isSome and w.pid != filter.pid.get: continue
    if filter.title.isSome or filter.titleContains.isSome:
      if w.title.isNone: continue
      if filter.title.isSome and w.title.get != filter.title.get: continue
      if filter.titleContains.isSome and filter.titleContains.get notin w.title.get:
        continue
    result.add w

proc displayOfRect*(bounds: Rect, displays: seq[Display]): Option[string] =
  ## The display holding the largest part of `bounds`; none when it lies on
  ## no display.
  var best = 0
  for d in displays:
    let a = intersection(bounds, d.bounds).area
    if a > best:
      best = a
      result = some(d.id)

proc requireRegionOnOneDisplay*(region: Rect, displays: seq[Display]) =
  ## Refuse (exit 2 / `invalid-value`) an empty region or one that does not
  ## lie within one display: a region capture never invents the pixels
  ## outside every display.
  if region.isEmpty:
    raise badArgs("invalid-value", "the capture region is empty")
  for d in displays:
    if d.bounds.contains(region): return
  raise badArgs("invalid-value", "the region " & $region & " does not lie within one display")

proc pickDisplay*(backend: string, displays: seq[Display], id: Option[string]): Display =
  ## The display `id` names, or the primary display. Exit 3 / `display` for
  ## an unknown id; exit 5 when the display server reports no display.
  for d in displays:
    if (id.isSome and d.id == id.get) or (id.isNone and d.primary): return d
  if id.isSome:
    raise notFound(backend, "display", "no display '" & id.get & "'")
  if displays.len > 0: return displays[0]
  raise captureFailed(backend, "the display server reports no display")

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

proc decodePpmRgb*(bytes: string): RgbImage =
  ## A binary PPM (P6, maxval 255) as an `RgbImage`
  ## (https://netpbm.sourceforge.net/doc/ppm.html). Raises `ValueError` for
  ## anything else or a truncated one.
  var pos = 0
  proc token(): string =
    while pos < bytes.len:
      if bytes[pos] == '#':
        while pos < bytes.len and bytes[pos] != '\n': inc pos
      elif bytes[pos] in Whitespace: inc pos
      else: break
    let start = pos
    while pos < bytes.len and bytes[pos] notin Whitespace: inc pos
    bytes[start ..< pos]
  if token() != "P6": raise newException(ValueError, "not a binary PPM")
  let w = parseInt(token())
  let h = parseInt(token())
  if parseInt(token()) != 255: raise newException(ValueError, "the PPM's maxval is not 255")
  if w <= 0 or h <= 0 or not fitsPixelCap(w, h):
    raise newException(ValueError, "the PPM's size is out of range")
  inc pos
  if bytes.len - pos < w * h * 3: raise newException(ValueError, "the PPM is truncated")
  result = newImage(RgbImage, w, h)
  for i in 0 ..< w * h * 3: result.pixels[i] = bytes[pos + i]

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
  elif why.len == 0:
    try:
      info = probeMp4File(tmpPath)
    except Mp4Error, IOError:
      why = getCurrentExceptionMsg()
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

proc nowStamp*(): string = formatTimestamp(unixNowMs())

# ---------------------------------------------------------------------------
# Tools, helpers and processes
# ---------------------------------------------------------------------------

proc findTool*(cfg: LinuxCaptureConfig, backend, name: string,
               overrideVar = "", remedy = ""): string =
  ## The executable `name` on the invocation's `PATH` (or the path in the
  ## invocation's `overrideVar`, e.g. `FFMPEG_BIN`). Exit 4 / `missing-tool`
  ## when there is none.
  if overrideVar.len > 0:
    let p = cfg.env.getOrDefault(overrideVar, "")
    if p.len > 0:
      if fileExists(p): return p
      raise unavailableWith(backend, "missing-tool", overrideVar & " points at " & p &
        ", which does not exist", "point " & overrideVar & " at an existing " & name)
  for dir in cfg.env.getOrDefault("PATH", "").split(':'):
    if dir.len == 0: continue
    let p = dir / name
    if fileExists(p) and access(p.cstring, X_OK) == 0: return p
  raise unavailableWith(backend, "missing-tool", "'" & name & "' is not on the PATH",
    if remedy.len > 0: remedy else: "install " & name & " (GuiAssert's `nix develop` provides it)")

proc helperPath*(cfg: LinuxCaptureConfig, backend, name: string): string =
  ## A GuiAssert Linux helper (`helpers/linux`): from the invocation's
  ## `GUI_ASSERT_HELPER_DIR` when it holds one, else built on first use by
  ## `desktop_env/helpers`. Exit 4 / `missing-tool` when it cannot be had.
  let dir = cfg.env.getOrDefault("GUI_ASSERT_HELPER_DIR", "")
  if dir.len > 0 and fileExists(dir / name): return dir / name
  try:
    result = linux_helpers.helper(name)
  except OSError as e:
    raise unavailableWith(backend, "missing-tool", "the GuiAssert helper '" & name &
      "' is not built and cannot be built here: " & lastLine(e.msg),
      "run inside GuiAssert's `nix develop`, or set GUI_ASSERT_HELPER_DIR to a " &
      "directory holding the built helpers (helpers/linux/build.sh <dir>)")

proc envBlock(env: Table[string, string]): cstringArray =
  var pairs: seq[string]
  for k, v in env: pairs.add k & "=" & v
  pairs.sort()
  allocCStringArray(pairs)

proc execChild(exe: cstring, argv, envp: cstringArray, outFd, errFd: cint) {.noreturn.} =
  ## In a forked child: standard input from /dev/null, the given output
  ## descriptors, then exec. Only async-signal-safe calls.
  let devnull = posix.open("/dev/null", O_RDONLY)
  if devnull >= 0: discard dup2(devnull, 0)
  if outFd >= 0: discard dup2(outFd, 1)
  if errFd >= 0: discard dup2(errFd, 2)
  # Nothing else crosses the exec: a descriptor this process inherited
  # without close-on-exec (the pipes of whoever started `guiassert`) held by
  # a detached recorder would keep that caller waiting for end-of-file.
  var maxFd = sysconf(SC_OPEN_MAX)
  if maxFd < 0 or maxFd > 65536: maxFd = 65536
  for fd in 3 ..< int(maxFd): discard posix.close(cint(fd))
  discard execve(exe, argv, envp)
  exitnow(127)

proc openOut(path: string): cint =
  posix.open(path.cstring, O_WRONLY or O_CREAT or O_TRUNC or O_CLOEXEC, 0o600)

proc privateTempDir*(cfg: LinuxCaptureConfig, backend, tag: string): string =
  ## A fresh private directory under the state directory for one run's
  ## files; the caller removes it.
  let base = cfg.stateDir / backend
  ensurePrivateDir(base)
  result = base / (tag & "-" & $getCurrentProcessId() & "-" & $unixNowMs())
  var n = 0
  while dirExists(result):
    inc n
    result = base / (tag & "-" & $getCurrentProcessId() & "-" & $unixNowMs() & "-" & $n)
  ensurePrivateDir(result)

proc runTool*(cfg: LinuxCaptureConfig, backend: string, argv: seq[string],
              timeoutMs = toolTimeoutMs): ToolRun =
  ## Run `argv` (its first element an absolute path) with the invocation's
  ## environment and wait for it, at most `timeoutMs` and never past the
  ## invocation's deadline; a cancellation or deadline kills it and raises
  ## the token's error, a timeout is exit 5 / `capture-failed`. Its output
  ## is collected in private files, never passed through.
  cfg.token.checkpoint()
  let dir = cfg.privateTempDir(backend, "run")
  try:
    let outFd = openOut(dir / "stdout")
    let errFd = openOut(dir / "stderr")
    if outFd < 0 or errFd < 0:
      if outFd >= 0: discard posix.close(outFd)
      if errFd >= 0: discard posix.close(errFd)
      raise captureFailed(backend, "cannot create the tool's output files under " & dir)
    let args = allocCStringArray(argv)
    let envp = envBlock(cfg.env)
    let pid = fork()
    if pid == 0: execChild(argv[0].cstring, args, envp, outFd, errFd)
    deallocCStringArray(args)
    deallocCStringArray(envp)
    discard posix.close(outFd)
    discard posix.close(errFd)
    if pid < 0: raise captureFailed(backend, "fork failed: " & osErrorMsg(osLastError()))
    var status: cint
    let startNs = monoNowNs()
    var exited = false
    try:
      while true:
        let r = waitpid(pid, status, WNOHANG)
        if r == pid:
          exited = true
          break
        if r < 0 and errno != EINTR:
          raise captureFailed(backend, "waitpid failed: " & osErrorMsg(osLastError()))
        if elapsedMsSince(startNs) > timeoutMs:
          raise captureFailed(backend, argv[0].extractFilename & " did not finish within " &
            $timeoutMs & " ms")
        cfg.token.sleepCancellable(5)
    finally:
      if not exited:
        discard kill(pid, SIGKILL)
        discard waitpid(pid, status, 0)
    result.code = if WIFEXITED(status): int(WEXITSTATUS(status))
                  else: 128 + int(WTERMSIG(status))
    result.output = readFileCapped(dir / "stdout", maxImageFileBytes)
    result.errors = readFileCapped(dir / "stderr", maxRecordBytes)
  finally:
    try: removeDir(dir)
    except OSError: discard

proc processStartTime*(pid: int): string =
  ## The kernel's start time of `pid` (field 22 of `/proc/<pid>/stat`, see
  ## proc_pid_stat(5)), "" when there is no such process or it is a zombie.
  ## A pid plus its start time names one process, never a recycled pid.
  if pid <= 0: return ""
  var text: string
  try: text = readFile("/proc/" & $pid & "/stat")
  except IOError, OSError: return ""
  let close = text.rfind(')')
  if close < 0: return ""
  let fields = text[close + 1 .. ^1].strip.splitWhitespace
  # fields[0] is the state (field 3); the start time is field 22.
  if fields.len < 20 or fields[0] == "Z" or fields[0] == "X": return ""
  fields[19]

proc processIs*(pid: int, startTime: string): bool =
  ## True while the process `pid` that started at `startTime` runs.
  startTime.len > 0 and processStartTime(pid) == startTime

proc spawnDetached*(cfg: LinuxCaptureConfig, backend: string, argv: seq[string],
                    logPath: string): tuple[pid: int, startTime: string] =
  ## Start `argv` in a session of its own, reparented away from this process
  ## (a double fork), with the invocation's environment and both output
  ## streams in `logPath`. It keeps running when the invocation exits.
  let logFd = openOut(logPath)
  if logFd < 0: raise captureFailed(backend, "cannot create the recorder log " & logPath)
  var fds: array[2, cint]
  if pipe(fds) != 0:
    discard posix.close(logFd)
    raise captureFailed(backend, "pipe failed: " & osErrorMsg(osLastError()))
  let args = allocCStringArray(argv)
  let envp = envBlock(cfg.env)
  let child = fork()
  if child == 0:
    discard posix.close(fds[0])
    discard setsid()
    let grandchild = fork()
    if grandchild == 0:
      discard posix.close(fds[1])
      execChild(argv[0].cstring, args, envp, logFd, logFd)
    var p = int32(grandchild)
    discard posix.write(fds[1], addr p, sizeof(p))
    exitnow(0)
  deallocCStringArray(args)
  deallocCStringArray(envp)
  discard posix.close(logFd)
  discard posix.close(fds[1])
  if child < 0:
    discard posix.close(fds[0])
    raise captureFailed(backend, "fork failed: " & osErrorMsg(osLastError()))
  var pid: int32 = -1
  let n = posix.read(fds[0], addr pid, sizeof(pid))
  discard posix.close(fds[0])
  var status: cint
  discard waitpid(child, status, 0)
  if n != sizeof(pid) or pid <= 0:
    raise captureFailed(backend, "the recorder could not be started")
  result.pid = int(pid)
  result.startTime = processStartTime(result.pid)

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

proc outputTemp*(backend, outPath, tag, ext: string): string =
  ## The hidden sibling of `outPath` a capture is written to before the
  ## rename. The output directory must exist (exit 3 / `file`).
  let dir = outPath.parentDir
  if not dirExists(dir):
    raise notFound(backend, "file", "the output directory does not exist: " & dir)
  dir / ("." & outPath.extractFilename & ".partial-" & tag & ext)

proc adoptPng*(backend, tmp, outPath: string, origin: Point, logicalWidth: int,
               source: ImageSource): ImageRef =
  ## Rename the PNG a tool wrote at `tmp` to `outPath` and describe it. The
  ## scale is measured: the image's pixel width over the captured logical
  ## width. Exit 5 when `tmp` is missing or not a PNG.
  if not fileExists(tmp):
    raise captureFailed(backend, "the capture tool reported success but wrote no image")
  var bytes: string
  try: bytes = readFileCapped(tmp, maxImageFileBytes)
  except IOError as e: raise captureFailed(backend, "cannot read the captured image: " & e.msg)
  let (w, h) = try: pngSize(bytes)
               except ValueError:
                 raise captureFailed(backend, "the capture tool wrote something that is not a PNG")
  try: moveFile(tmp, outPath)
  except OSError as e: raise captureFailed(backend, "cannot write " & outPath & ": " & e.msg)
  let scale = if logicalWidth > 0: w.float / logicalWidth.float else: 1.0
  ImageRef(path: outPath, format: "png", width: w, height: h, scale: scale,
           origin: origin, sha256: sha256Hex(bytes), capturedAt: nowStamp(),
           source: source)

proc writePngFile*(backend, tmp, outPath: string, img: RgbImage, origin: Point,
                   logicalWidth: int, source: ImageSource): ImageRef =
  ## Encode `img` as PNG to `tmp`, then `adoptPng` it.
  try: writeFile(tmp, encodePng(img))
  except IOError as e: raise captureFailed(backend, "cannot write " & tmp & ": " & e.msg)
  adoptPng(backend, tmp, outPath, origin, logicalWidth, source)

proc removeQuietly*(path: string) =
  if fileExists(path):
    try: removeFile(path)
    except OSError: discard

# ---------------------------------------------------------------------------
# Recordings
# ---------------------------------------------------------------------------

type
  RecorderLaunch* = object
    ## How one backend starts its recorder.
    argv*: seq[string]       ## the recorder, writing the MP4 to `tmpPath`
    tmpPath*: string
    statusPath*: string      ## "" when the recorder writes no status file
    startedStates*: seq[string]
      ## Status `state` values that mean "recording" (with a status file).
    width*, height*: int     ## the expected frame size (measured at the end)
    source*: ImageSource

proc recordingsDir(cfg: LinuxCaptureConfig): string = cfg.stateDir / "recordings"
proc recordingPath(cfg: LinuxCaptureConfig, id: string): string =
  cfg.recordingsDir / (id & ".json")
proc lockDir(cfg: LinuxCaptureConfig, backend: string): string =
  cfg.recordingsDir / ("." & backend & ".lock")

proc save(cfg: LinuxCaptureConfig, r: Recording, priv: JsonNode) =
  writeRecord(cfg.recordingPath(r.id), recordingSchema,
              %*{"recording": r.toJson, "private": priv})

proc load(cfg: LinuxCaptureConfig, backend, id: string): tuple[r: Recording, priv: JsonNode] =
  if not isValidName(id):
    raise badArgs("invalid-name", "invalid recording id '" & id & "'")
  let rec = readRecord(cfg.recordingPath(id), recordingSchema)
  if rec.isNone:
    raise notFound(backend, "recording", "no recording '" & id & "'")
  try:
    result = (Recording.fromJson(rec.get["recording"]), rec.get["private"])
  except JsonShapeError, KeyError:
    raise newContractError(ekInternal, "exception", "recording record " & id &
      " is malformed: " & getCurrentExceptionMsg())

proc isOurs(priv: JsonNode, backend: string): bool =
  priv.kind == JObject and priv.getOrDefault("backend").getStr == backend

proc readStatus(path: string): StatusFile =
  if path.len == 0: return
  try: result = parseStatusFile(readFileCapped(path, maxRecordBytes))
  except IOError: discard

proc recorderAlive(priv: JsonNode): bool =
  processIs(priv["pid"].getInt, priv["startTime"].getStr)

proc newRecordingId(cfg: LinuxCaptureConfig, prefix: string): string =
  result = prefix & "-" & $unixNowMs() & "-" & $getCurrentProcessId()
  var n = 0
  while fileExists(cfg.recordingPath(result)):
    inc n
    result = prefix & "-" & $unixNowMs() & "-" & $getCurrentProcessId() & "-" & $n

proc failedRecording(r: Recording, why: string): ref ContractError =
  newContractError(ekBackendError, "capture-failed", "recording '" & r.id &
    "' at " & r.path & " is not a finalized recording: " & why,
    details = %*{"recording": r.toJson})

proc logTail(priv: JsonNode): string =
  try: lastLine(readFileCapped(priv["logPath"].getStr, maxRecordBytes))
  except IOError, KeyError: ""

proc stopRecorder(cfg: LinuxCaptureConfig, r: var Recording, priv: JsonNode): string =
  ## Interrupt the recorder of `r` (if it still runs), wait for it to
  ## finalize, and finalize the recording; "" when it is `stopped`, else why
  ## it is `failed`. Persists the record and removes the control directory.
  let pid = priv["pid"].getInt
  var problem = ""
  if recorderAlive(priv):
    discard kill(Pid(pid), SIGINT)
    let startNs = monoNowNs()
    while recorderAlive(priv) and elapsedMsSince(startNs) < recorderStopMs:
      sleep(20)
    if recorderAlive(priv):
      discard kill(Pid(pid), SIGKILL)
      let killNs = monoNowNs()
      while recorderAlive(priv) and elapsedMsSince(killNs) < 2000: sleep(10)
      problem = "the recorder did not finalize within " & $recorderStopMs & " ms"
  let statusPath = priv{"statusPath"}.getStr
  if problem.len == 0 and statusPath.len > 0:
    let st = readStatus(statusPath)
    let state = st.getOrDefault("state", "")
    if state != "stopped":
      problem = if state in ["failed", "denied"]:
                  "the recorder failed: " & st.getOrDefault("message", "")
                else:
                  "the recorder exited without finalizing (state " &
                    (if state.len > 0: state else: "unknown") & ")"
  r.stoppedAt = some(nowStamp())
  result = finalizeRecording(r, priv["tmpPath"].getStr, problem)
  if result.len > 0:
    let tail = logTail(priv)
    if tail.len > 0: result.add " (recorder: " & tail & ")"
  cfg.save(r, priv)
  try: removeDir(priv["controlDir"].getStr)
  except OSError: discard

proc startRecording*(cfg: LinuxCaptureConfig, backend, idPrefix: string,
                     req: RecordRequest,
                     launch: proc (id, controlDir: string): RecorderLaunch {.closure.}): Recording =
  ## `record-start` / `record` for a Linux backend: `launch` names the
  ## recorder for a new recording id and its private control directory; it
  ## is started detached and waited for (its status file reaching a started
  ## state, or the output file appearing), then recorded. With
  ## `req.durationMs` the call blocks, streams `progress`, and finalizes
  ## however the wait ends (spec §8.6).
  if not (req.fps > 0.0) or req.fps > 240.0:
    raise badArgs("invalid-value", "--fps must be in (0, 240]")
  cfg.token.checkpoint()
  ensurePrivateDir(cfg.recordingsDir)
  var id, controlDir: string
  withLock(cfg.lockDir(backend), cfg.token):
    id = cfg.newRecordingId(idPrefix)
    controlDir = cfg.recordingsDir / (id & ".d")
    ensurePrivateDir(controlDir)
  var l: RecorderLaunch
  var spawned: tuple[pid: int, startTime: string]
  let logPath = controlDir / "recorder.log"
  try:
    l = launch(id, controlDir)
    spawned = cfg.spawnDetached(backend, l.argv, logPath)
    let startNs = monoNowNs()
    while true:
      let alive = processIs(spawned.pid, spawned.startTime)
      if l.statusPath.len > 0:
        let st = readStatus(l.statusPath)
        let state = st.getOrDefault("state", "")
        if state in l.startedStates: break
        if state in ["failed", "denied", "stopped"] or not alive:
          let msg = st.getOrDefault("message", "")
          raise captureFailed(backend, "the recorder did not start (" &
            (if state.len > 0: state else: "exited") & "): " &
            (if msg.len > 0: msg else: lastLine(readFileCapped(logPath, maxRecordBytes))))
      else:
        if fileExists(l.tmpPath) and getFileSize(l.tmpPath) > 0 and alive: break
        if not alive:
          raise captureFailed(backend, "the recorder exited before it started: " &
            lastLine(readFileCapped(logPath, maxRecordBytes)))
      if elapsedMsSince(startNs) > recorderStartMs:
        raise captureFailed(backend, "the recorder did not start within " &
          $recorderStartMs & " ms")
      cfg.token.sleepCancellable(20)
  except CatchableError:
    # Interrupted or refused before the recording existed: stop whatever
    # started and leave nothing behind.
    if processIs(spawned.pid, spawned.startTime): discard kill(Pid(spawned.pid), SIGKILL)
    if l.tmpPath.len > 0: removeQuietly(l.tmpPath)
    try: removeDir(controlDir)
    except OSError: discard
    raise
  if l.width <= 0 and l.statusPath.len > 0:
    # The recorder learnt the frame size once it started (a portal stream's
    # monitor); the finalized file's measurement replaces it either way.
    let st = readStatus(l.statusPath)
    l.width = st.intOf("frameWidth", st.intOf("width"))
    l.height = st.intOf("frameHeight", st.intOf("height"))
  result = Recording(id: id, path: absolutePath(req.outPath), state: rsRecording,
                     format: rfMp4, width: l.width, height: l.height, fps: req.fps,
                     source: l.source, startedAt: nowStamp())
  let priv = %*{"backend": backend, "pid": spawned.pid, "startTime": spawned.startTime,
                "tmpPath": l.tmpPath, "statusPath": l.statusPath,
                "controlDir": controlDir, "logPath": logPath}
  withLock(cfg.lockDir(backend), cfg.token):
    cfg.save(result, priv)
  if req.durationMs.isNone: return
  let startNs = monoNowNs()
  var interruption: ref Exception = nil
  try:
    while true:
      let left = req.durationMs.get - elapsedMsSince(startNs)
      if left <= 0: break
      cfg.token.sleepCancellable(min(left, 500))
      if cfg.emit != nil:
        let st = readStatus(l.statusPath)
        cfg.emit("progress", %*{"elapsedMs": min(elapsedMsSince(startNs), req.durationMs.get),
          "frames": (if st.hasKey("frames"): %st.intOf("frames") else: newJNull())})
  except ContractError:
    interruption = getCurrentException()
  # Finalizing must not be skipped because the invocation was cancelled: the
  # lock is taken on a token of its own (bounded by the lock's wait).
  var why: string
  let lockToken = newCancelToken()
  try:
    withLock(cfg.lockDir(backend), lockToken):
      why = cfg.stopRecorder(result, priv)
  finally:
    lockToken.free()
  if interruption != nil: raise interruption
  if why.len > 0: raise failedRecording(result, why)

proc stopRecording*(cfg: LinuxCaptureConfig, backend, id: string): Recording =
  ## `record-stop` of a recording this backend made.
  var why: string
  withLock(cfg.lockDir(backend), cfg.token):
    var (r, priv) = cfg.load(backend, id)
    if not isOurs(priv, backend):
      raise captureFailed(backend, "recording '" & id & "' was not made by the " &
        backend & " backend")
    if r.state != rsRecording:
      raise captureFailed(backend, "recording '" & id & "' is not running (" & $r.state & ")")
    why = cfg.stopRecorder(r, priv)
    result = r
  if why.len > 0: raise failedRecording(result, why)

proc listRecordings*(cfg: LinuxCaptureConfig, backend: string): seq[Recording] =
  ## Every recording record, by id. One of this backend's whose recorder is
  ## gone without having been stopped is finalized first (a recorder that
  ## died leaves no finalized file, so it is listed `failed`).
  let dir = cfg.recordingsDir
  if not dirExists(dir): return
  withLock(cfg.lockDir(backend), cfg.token):
    var names: seq[string]
    for k, p in walkDir(dir):
      if k in {pcFile, pcLinkToFile} and p.endsWith(".json"): names.add p
    names.sort()
    for p in names:
      let id = p.extractFilename[0 ..< ^5]
      var (r, priv) = cfg.load(backend, id)
      if isOurs(priv, backend) and r.state == rsRecording and not recorderAlive(priv):
        discard cfg.stopRecorder(r, priv)
      result.add r

# ---------------------------------------------------------------------------
# Off Linux
# ---------------------------------------------------------------------------

const captureFeatureNames* = ["window-enumeration", "display-capture", "window-capture",
                              "region-capture", "own-pixels-capture", "recording"]
  ## The capture module's features (spec §7.5).

proc wrongPlatformCapture*(backend: string): CaptureBackend =
  ## The backend `backend` built for another operating system: every
  ## operation is exit 4 / `wrong-platform` and it links no Linux code path
  ## (spec §3.3).
  proc wrong(): ref BackendUnavailableError =
    unavailableWith(backend, "wrong-platform", "the " & backend &
      " capture backend runs on Linux only", "select a capture backend for this platform")
  result.name = backend
  result.displays = proc (session: string): seq[Display] = raise wrong()
  result.windows = proc (session: string, filter: WindowFilter): WindowList = raise wrong()
  result.capture = proc (req: CaptureRequest): ImageRef = raise wrong()
  result.startRecording = proc (req: RecordRequest): Recording = raise wrong()
  result.stopRecording = proc (id: string): Recording = raise wrong()
  result.recordings = proc (): seq[Recording] = raise wrong()
  result.features = proc (probe: bool): seq[Feature] =
    for f in captureFeatureNames:
      result.add feature(backend, f, fsUnavailable, "wrong-platform",
                         "select a capture backend for this platform")
