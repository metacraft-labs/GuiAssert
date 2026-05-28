## GuiAssert Cross-Platform Screen Capture
##
## A pure-Nim subprocess wrapper around the host's preferred screen-capture
## backend. This module mirrors the agent-harbor Rust implementation at
## `agent-harbor/crates/ah-cli/src/use_cmd/desktop/capture.rs` so that
## GuiAssert-consuming projects (e.g. codetracer-marketing) do not need the
## `ah` CLI as a runtime dependency.
##
## Backends:
##
##   | OS      | Default       | Fallback   | Tool                  |
##   |---------|---------------|------------|-----------------------|
##   | macOS   | avfoundation  | (none)     | ffmpeg                |
##   | Windows | ddagrab       | gdigrab    | ffmpeg                |
##   | Linux   | wf-recorder (Wayland) / x11grab (X11), auto-detected. |
##
## Graceful stop:
##
##   * For ffmpeg-based backends we write the ASCII byte `q` to the child's
##     stdin (ffmpeg listens for this during record sessions and finalises
##     the MP4 container cleanly), then `waitForExit`.
##   * For `wf-recorder` we send SIGINT to the child PID (Unix-only).
##   * On Windows we use the same stdin-`q` trick because Nim's `osproc`
##     does not expose `CREATE_NEW_PROCESS_GROUP`. The child inherits the
##     parent's console, but the stdin path is sufficient to stop ffmpeg
##     cleanly without pulling in `windows-sys`.
##
## All argv-builders (`buildAvfoundationArgv`, `buildX11GrabArgv`,
## `buildWfRecorderArgv`, `buildWindowsArgv`) are pure and individually
## tested without spawning subprocesses. The macOS device-listing parser
## (`parseMacosScreenDeviceIndex`) is also pure and tested against a
## representative ffmpeg `-list_devices` stderr sample.

import std/[options, os, osproc, streams, strformat, strtabs, strutils]

when defined(posix):
  import std/posix

import ./media

# ---------------------------------------------------------------------------
# Public types
# ---------------------------------------------------------------------------

type
  CaptureBackend* = enum
    ## User-facing backend selector. `cbAuto` resolves to a per-OS default.
    cbAuto
    cbWfRecorder
    cbX11Grab
    cbAvfoundation
    cbDdagrab
    cbGdiGrab

  ResolvedBackend* = enum
    ## Concrete backend after `cbAuto` is resolved for the current OS.
    rbWfRecorder
    rbX11Grab
    rbAvfoundation
    rbDdagrab
    rbGdiGrab

  LinuxDisplayServer* = enum
    ldsWayland
    ldsX11
    ldsUnknown

  CaptureRegion* = object
    ## A pixel-coordinate rectangle. `x, y` is the top-left corner;
    ## `width, height` are strictly positive.
    x*, y*, width*, height*: int

  CaptureOptions* = object
    output*: string
      ## Absolute path to the output `.mp4`. Parent directory must exist or
      ## the caller must accept the validation failure that follows.
    durationSec*: Option[float]
      ## `none` => run until graceful stop. ffmpeg backends honour `-t`
      ## natively; `wf-recorder` ignores this and the caller drives the
      ## stop via `stopRecording`.
    region*: Option[CaptureRegion]
    backend*: CaptureBackend
    frameRate*: int  ## Defaults to 30 when zero.

  CaptureError* = object of CatchableError
    backend*: ResolvedBackend
    stage*: string  ## "resolve", "spawn", "wait", or "validate"

  CaptureHandle* = ref object
    ## Opaque handle to an in-progress async capture. Owns the underlying
    ## `Process` (and, on Unix wf-recorder, the PID we use for SIGINT).
    process: Process
    backend: ResolvedBackend
    outputPath: string
    usesStdinQ: bool
    pid: int

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

proc defaultCaptureOptions*(): CaptureOptions =
  ## Sensible defaults: 30 fps, no region, auto backend, blank output (the
  ## caller must populate `output` before calling `recordScreen`).
  CaptureOptions(
    output: "",
    durationSec: none(float),
    region: none(CaptureRegion),
    backend: cbAuto,
    frameRate: 30,
  )

# ---------------------------------------------------------------------------
# Error helpers
# ---------------------------------------------------------------------------

proc newCaptureError(stage: string, backend: ResolvedBackend, msg: string):
    ref CaptureError =
  result = (ref CaptureError)(msg: msg, backend: backend, stage: stage)

# ---------------------------------------------------------------------------
# Linux display-server detection
# ---------------------------------------------------------------------------

proc detectLinuxDisplayServer*(): LinuxDisplayServer =
  ## Examine the environment to pick between Wayland and X11. Returns
  ## `ldsUnknown` if neither `WAYLAND_DISPLAY` nor `DISPLAY` is set.
  if existsEnv("WAYLAND_DISPLAY"):
    return ldsWayland
  if existsEnv("DISPLAY"):
    return ldsX11
  return ldsUnknown

# ---------------------------------------------------------------------------
# Backend resolution
# ---------------------------------------------------------------------------

proc currentOsName(): string =
  when defined(macosx): "macos"
  elif defined(windows): "windows"
  elif defined(linux):   "linux"
  else:                  hostOS

proc resolveBackendImpl(choice: CaptureBackend, osName: string,
                        hint: LinuxDisplayServer): ResolvedBackend =
  ## Test-friendly resolver: takes an explicit OS name + display hint.
  ## `resolveBackend` wraps this with the running OS and live env detection.
  case choice
  of cbWfRecorder:
    if osName == "linux": return rbWfRecorder
  of cbX11Grab:
    if osName == "linux": return rbX11Grab
  of cbAvfoundation:
    if osName == "macos": return rbAvfoundation
  of cbDdagrab:
    if osName == "windows": return rbDdagrab
  of cbGdiGrab:
    if osName == "windows": return rbGdiGrab
  of cbAuto:
    case osName
    of "linux":
      case hint
      of ldsWayland:  return rbWfRecorder
      of ldsX11:      return rbX11Grab
      of ldsUnknown:
        raise newCaptureError("resolve", rbX11Grab,
          "Linux: neither WAYLAND_DISPLAY nor DISPLAY is set; cannot " &
          "auto-detect display server. Pass backend = cbWfRecorder or " &
          "cbX11Grab explicitly.")
    of "macos":   return rbAvfoundation
    of "windows": return rbDdagrab
    else: discard
  # Bogus combination, e.g. cbAvfoundation on linux. Pick a placeholder
  # backend purely so the exception carries *something* in `.backend`.
  let placeholder =
    case choice
    of cbWfRecorder:    rbWfRecorder
    of cbX11Grab:       rbX11Grab
    of cbAvfoundation:  rbAvfoundation
    of cbDdagrab:       rbDdagrab
    of cbGdiGrab:       rbGdiGrab
    of cbAuto:          rbX11Grab
  raise newCaptureError("resolve", placeholder,
    "Backend '" & $choice & "' is not supported on OS '" & osName & "'")

proc resolveBackend*(choice: CaptureBackend): ResolvedBackend =
  ## Map a user-facing `CaptureBackend` to a `ResolvedBackend` for the
  ## current OS. Raises `CaptureError` when the choice is incompatible
  ## with the running OS.
  let osName = currentOsName()
  let hint =
    when defined(linux): detectLinuxDisplayServer()
    else: ldsUnknown
  return resolveBackendImpl(choice, osName, hint)

# ---------------------------------------------------------------------------
# macOS device discovery
# ---------------------------------------------------------------------------

proc parseMacosScreenDeviceIndex*(text: string): int =
  ## Parse ffmpeg `-list_devices` stderr output and return the first index
  ## whose label starts with "Capture screen".
  ##
  ## A device line typically looks like:
  ##
  ##   [AVFoundation indev @ 0x7f8] [5] Capture screen 0
  ##
  ## The first `[...]` is the muxer tag; the second `[...]` carries the
  ## numeric index. We locate the second bracket pair and parse its
  ## contents. Lines without two bracket pairs are ignored.
  for line in text.splitLines:
    let firstClose = line.find(']')
    if firstClose < 0:
      continue
    let rest = line[firstClose + 1 .. ^1]
    let idxOpen = rest.find('[')
    if idxOpen < 0:
      continue
    let afterOpen = rest[idxOpen + 1 .. ^1]
    let idxClose = afterOpen.find(']')
    if idxClose < 0:
      continue
    let idxStr = afterOpen[0 ..< idxClose].strip()
    let label = afterOpen[idxClose + 1 .. ^1].strip()
    if not label.startsWith("Capture screen"):
      continue
    try:
      return parseInt(idxStr)
    except ValueError:
      raise newCaptureError("resolve", rbAvfoundation,
        "failed to parse avfoundation device index '" & idxStr & "'")
  raise newCaptureError("resolve", rbAvfoundation,
    "could not find 'Capture screen' device in ffmpeg avfoundation " &
    "device list. Check that Screen Recording permission is granted to " &
    "your terminal in System Settings > Privacy & Security > Screen Recording.")

proc sanitizedFfmpegEnv(ffmpegPath: string): StringTableRef =
  ## Mirror `media.sanitizedEnvForFfmpeg`: strip `DYLD_LIBRARY_PATH` and
  ## `DYLD_FALLBACK_LIBRARY_PATH` when invoking a Nix-store ffmpeg on macOS
  ## so Homebrew dylibs do not get spliced in.
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if k == "DYLD_LIBRARY_PATH" or k == "DYLD_FALLBACK_LIBRARY_PATH":
      when defined(macosx):
        if ffmpegPath.startsWith("/nix/"): continue
    result[k] = v

proc detectMacosScreenDeviceIndex*(): int =
  ## Spawn `ffmpeg -hide_banner -f avfoundation -list_devices true -i ""`
  ## and parse the stderr for the first `Capture screen N` line. ffmpeg
  ## exits non-zero from `-list_devices` (it cannot open the empty input)
  ## but still prints the device table to stderr.
  let ffmpegBin =
    try: resolveFfmpegBinary()
    except MediaCompositionError as e:
      raise newCaptureError("resolve", rbAvfoundation, e.msg)
  let env = sanitizedFfmpegEnv(ffmpegBin)
  let p = startProcess(
    command = ffmpegBin,
    args = @[
      "-hide_banner", "-f", "avfoundation", "-list_devices", "true",
      "-i", ""
    ],
    env = env,
    options = {poStdErrToStdOut}
  )
  let output = p.outputStream().readAll()
  discard p.waitForExit()
  p.close()
  return parseMacosScreenDeviceIndex(output)

# ---------------------------------------------------------------------------
# Argv builders — pure, tested in isolation
# ---------------------------------------------------------------------------

proc fmtDuration(d: float): string =
  ## Match the Rust formatter's `"{d:.3}"`. Nim's `formatFloat(..., ffDecimal, 3)`
  ## prints in non-scientific form to three decimals.
  formatFloat(d, ffDecimal, 3)

proc fmtRate(opts: CaptureOptions): string =
  let r = if opts.frameRate > 0: opts.frameRate else: 30
  return $r

proc buildAvfoundationArgv*(opts: CaptureOptions, screenDeviceIndex: int):
    seq[string] =
  ## ffmpeg argv for a macOS avfoundation capture. Region cropping is
  ## applied through the `crop` filter because avfoundation cannot natively
  ## crop the captured frame.
  result = @[
    "-hide_banner",
    "-y",
    "-f", "avfoundation",
    "-capture_cursor", "1",
    "-framerate", fmtRate(opts),
    "-i", $screenDeviceIndex & ":none",
  ]
  if opts.region.isSome:
    let r = opts.region.get
    result.add "-vf"
    result.add &"crop={r.width}:{r.height}:{r.x}:{r.y}"
  if opts.durationSec.isSome:
    result.add "-t"
    result.add fmtDuration(opts.durationSec.get)
  result.add @[
    "-c:v", "libx264",
    "-pix_fmt", "yuv420p",
    "-preset", "ultrafast",
    "-movflags", "+faststart",
  ]
  result.add opts.output

proc buildWindowsArgv*(opts: CaptureOptions, backend: ResolvedBackend):
    seq[string] =
  ## ffmpeg argv for ddagrab / gdigrab. ddagrab uses the Desktop
  ## Duplication API (preferred); gdigrab is the legacy fallback. Both
  ## support native region cropping via offset_x/offset_y + video_size.
  result = @[
    "-hide_banner",
    "-y",
    "-framerate", fmtRate(opts),
  ]
  case backend
  of rbDdagrab:
    result.add @["-f", "ddagrab"]
    if opts.region.isSome:
      let r = opts.region.get
      result.add @[
        "-offset_x", $r.x,
        "-offset_y", $r.y,
        "-video_size", &"{r.width}x{r.height}",
      ]
    result.add @["-i", "desktop"]
  of rbGdiGrab:
    result.add @["-f", "gdigrab"]
    if opts.region.isSome:
      let r = opts.region.get
      result.add @[
        "-offset_x", $r.x,
        "-offset_y", $r.y,
        "-video_size", &"{r.width}x{r.height}",
      ]
    result.add @["-i", "desktop"]
  else:
    # Caller bug: this builder is only meaningful for the Windows backends.
    result.add "--invalid-backend-for-windows-argv-builder"
  if opts.durationSec.isSome:
    result.add "-t"
    result.add fmtDuration(opts.durationSec.get)
  result.add @[
    "-c:v", "libx264",
    "-pix_fmt", "yuv420p",
    "-preset", "ultrafast",
    "-movflags", "+faststart",
  ]
  result.add opts.output

proc buildX11GrabArgv*(opts: CaptureOptions, display: string): seq[string] =
  ## ffmpeg argv for a Linux X11 capture. x11grab encodes the region via
  ## "+x,y" suffix on the input display + `-video_size WxH`.
  result = @[
    "-hide_banner",
    "-y",
    "-f", "x11grab",
    "-framerate", fmtRate(opts),
  ]
  var input = display
  if opts.region.isSome:
    let r = opts.region.get
    result.add "-video_size"
    result.add &"{r.width}x{r.height}"
    input = &"{display}+{r.x},{r.y}"
  result.add "-i"
  result.add input
  if opts.durationSec.isSome:
    result.add "-t"
    result.add fmtDuration(opts.durationSec.get)
  result.add @[
    "-c:v", "libx264",
    "-pix_fmt", "yuv420p",
    "-preset", "ultrafast",
    "-movflags", "+faststart",
  ]
  result.add opts.output

proc buildWfRecorderArgv*(opts: CaptureOptions, codec: string): seq[string] =
  ## wf-recorder argv. No `-t`: the caller drives the stop via SIGINT.
  result = @["-f", opts.output, "-c", codec]
  if opts.region.isSome:
    let r = opts.region.get
    result.add "-g"
    result.add &"{r.x},{r.y} {r.width}x{r.height}"

# Backwards-compatible single-entry argv builder.
proc buildArgv*(backend: ResolvedBackend, opts: CaptureOptions): seq[string] =
  ## Dispatch to the per-backend argv builder. macOS and wf-recorder need
  ## extra runtime info (device index, codec) so this proc fills sensible
  ## defaults — callers that want full control should use the per-backend
  ## builders directly.
  case backend
  of rbAvfoundation:
    # Tests inspect this output without spawning ffmpeg, so use a sentinel
    # device index of 0. Live capture flows through `spawnRecorder` and
    # uses `detectMacosScreenDeviceIndex()` instead.
    return buildAvfoundationArgv(opts, 0)
  of rbDdagrab, rbGdiGrab:
    return buildWindowsArgv(opts, backend)
  of rbX11Grab:
    let display = getEnv("DISPLAY", ":0")
    return buildX11GrabArgv(opts, display)
  of rbWfRecorder:
    return buildWfRecorderArgv(opts, "libx264")

# ---------------------------------------------------------------------------
# Spawn + graceful stop
# ---------------------------------------------------------------------------

proc spawnFfmpeg(argv: seq[string], backend: ResolvedBackend): Process =
  ## Spawn ffmpeg via `media.resolveFfmpegBinary` with the same sanitised
  ## environment used by the composition pipeline. `poParentStreams` is
  ## deliberately *not* set: we need the child's stdin piped so we can
  ## write `q` for graceful stop. stderr is merged into stdout so progress
  ## output is visible from the parent.
  let ffmpegBin =
    try: resolveFfmpegBinary()
    except MediaCompositionError as e:
      raise newCaptureError("spawn", backend, e.msg)
  let env = sanitizedFfmpegEnv(ffmpegBin)
  try:
    result = startProcess(
      command = ffmpegBin,
      args = argv,
      env = env,
      options = {poStdErrToStdOut}
    )
  except OSError as e:
    raise newCaptureError("spawn", backend,
      "failed to start ffmpeg: " & e.msg)

proc spawnWfRecorder(opts: CaptureOptions): Process =
  ## Try `h264_vaapi` first, fall back to `libx264`. The wf-recorder binary
  ## is expected to be on PATH; we do not synthesise a fake env for it the
  ## way we do for ffmpeg (it has no Nix/Homebrew dylib problem).
  for codec in ["h264_vaapi", "libx264"]:
    let argv = buildWfRecorderArgv(opts, codec)
    try:
      return startProcess(
        command = "wf-recorder",
        args = argv,
        options = {poUsePath, poStdErrToStdOut}
      )
    except OSError:
      discard
  raise newCaptureError("spawn", rbWfRecorder,
    "failed to start wf-recorder (tried h264_vaapi and libx264)")

proc spawnRecorder(backend: ResolvedBackend, opts: CaptureOptions): tuple[
    process: Process, usesStdinQ: bool] =
  ## Spawn the recorder process for the resolved backend.
  case backend
  of rbAvfoundation:
    when defined(macosx):
      let idx = detectMacosScreenDeviceIndex()
      let argv = buildAvfoundationArgv(opts, idx)
      return (spawnFfmpeg(argv, backend), true)
    else:
      raise newCaptureError("spawn", backend,
        "avfoundation backend is only available on macOS")
  of rbX11Grab:
    let display = getEnv("DISPLAY", ":0")
    let argv = buildX11GrabArgv(opts, display)
    return (spawnFfmpeg(argv, backend), true)
  of rbWfRecorder:
    return (spawnWfRecorder(opts), false)
  of rbDdagrab, rbGdiGrab:
    when defined(windows):
      let argv = buildWindowsArgv(opts, backend)
      return (spawnFfmpeg(argv, backend), true)
    else:
      raise newCaptureError("spawn", backend,
        $backend & " backend is only available on Windows")

proc gracefulStop(process: Process, usesStdinQ: bool,
                  backend: ResolvedBackend): int =
  ## Deliver the appropriate graceful-stop signal and wait for the child.
  ##
  ## ffmpeg listens on stdin for the literal byte `q` during capture
  ## sessions and finalises the MP4 container before exiting. The
  ## non-stdin path (wf-recorder) catches SIGINT and finalises similarly.
  if usesStdinQ:
    try:
      let s = process.inputStream()
      if not s.isNil:
        s.write("q\n")
        s.flush()
        s.close()
    except IOError, OSError:
      # Child may have already exited; treat as best-effort and proceed
      # to waitForExit which will surface the real status.
      discard
  else:
    when defined(posix):
      discard posix.kill(Pid(process.processID), SIGINT)
    else:
      # No portable SIGINT outside Unix. wf-recorder is Linux-only so this
      # branch is unreachable in practice.
      process.terminate()
  let code = process.waitForExit()
  process.close()
  return code

proc validateOutput(path: string, backend: ResolvedBackend) =
  if not fileExists(path):
    raise newCaptureError("validate", backend,
      "capture finished but no file at " & path)
  if getFileSize(path) <= 0:
    raise newCaptureError("validate", backend,
      "capture produced a zero-byte file at " & path)

# ---------------------------------------------------------------------------
# Blocking recordScreen
# ---------------------------------------------------------------------------

proc recordScreen*(opts: CaptureOptions): string {.discardable.} =
  ## Blocking screen capture. Spawns the resolved backend, sleeps for the
  ## requested duration (or until the child exits on its own via `-t`),
  ## then issues a graceful stop. Validates that the output exists and is
  ## non-empty before returning the path.
  if opts.output.len == 0:
    # We need *something* to raise — pick the auto-resolved backend so
    # the error carries an accurate `.backend` field.
    raise newCaptureError("validate", resolveBackend(opts.backend),
      "CaptureOptions.output must be a non-empty path")
  let backend = resolveBackend(opts.backend)
  # wf-recorder ignores -t, so we pass it through unchanged. The OS-level
  # ffmpeg backends honour -t natively.
  var spawnOpts = opts
  if backend == rbWfRecorder:
    spawnOpts.durationSec = none(float)
  let (process, usesStdinQ) = spawnRecorder(backend, spawnOpts)
  # Wait for the requested duration. ffmpeg backends usually exit on
  # their own when -t elapses; we still graceful-stop afterwards to be
  # safe (and to handle wf-recorder).
  if opts.durationSec.isSome:
    let ms = int(opts.durationSec.get * 1000.0)
    if ms > 0:
      sleep(ms)
  else:
    # No duration: block on process exit. This is uncommon — callers that
    # want non-blocking capture should use `startRecording` / `stopRecording`.
    discard process.waitForExit()
    process.close()
    validateOutput(opts.output, backend)
    return opts.output
  let code = gracefulStop(process, usesStdinQ, backend)
  # ffmpeg may exit non-zero after receiving "q" (it treats the stdin EOF
  # as a graceful interrupt). We only care about output validity.
  discard code
  validateOutput(opts.output, backend)
  return opts.output

# ---------------------------------------------------------------------------
# Async start / stop
# ---------------------------------------------------------------------------

proc startRecording*(opts: CaptureOptions): CaptureHandle =
  ## Non-blocking spawn. Returns a handle that owns the child process
  ## (and stdin pipe for ffmpeg-based backends).
  if opts.output.len == 0:
    raise newCaptureError("validate", resolveBackend(opts.backend),
      "CaptureOptions.output must be a non-empty path")
  let backend = resolveBackend(opts.backend)
  var spawnOpts = opts
  # For async capture we never pass -t — the stop signal terminates.
  spawnOpts.durationSec = none(float)
  let (process, usesStdinQ) = spawnRecorder(backend, spawnOpts)
  result = CaptureHandle(
    process: process,
    backend: backend,
    outputPath: opts.output,
    usesStdinQ: usesStdinQ,
    pid: process.processID,
  )

proc stopRecording*(h: CaptureHandle): string {.discardable.} =
  ## Graceful-stop the handle, validate the output, return the path.
  if h.isNil or h.process.isNil:
    raise newCaptureError("validate", rbAvfoundation,
      "stopRecording called with a nil handle")
  discard gracefulStop(h.process, h.usesStdinQ, h.backend)
  validateOutput(h.outputPath, h.backend)
  return h.outputPath
