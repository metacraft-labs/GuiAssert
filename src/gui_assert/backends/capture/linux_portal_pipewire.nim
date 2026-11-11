## The `linux-portal-pipewire` capture backend: the xdg-desktop-portal
## ScreenCast interface and the PipeWire stream it opens, for compositors
## that offer screen capture only through the portal (spec §4.2).
##
## GuiAssert's `portal_screencast` helper (`helpers/linux/portal_screencast.c`)
## holds the portal session: CreateSession, SelectSources (one monitor; the
## cursor embedded or hidden as asked, when the portal offers the mode),
## Start, OpenPipeWireRemote. The portal is the consent point: its backend's
## chooser or dialog is shown when it has one, and the helper waits for the
## answer; GuiAssert never bypasses it. A refusal is exit 5 /
## `capture-failed` naming it. The helper consumes the stream itself with
## libpipewire, on the descriptor the portal handed over, returning every
## buffer to the stream as soon as its pixels are copied (see the helper for
## why a GStreamer consumer was not reliable with xdg-desktop-portal-wlr):
##
## * **screenshot** (a display): the first frame, as a PPM the pure core
##   encodes to PNG, written to the temporary sibling of `--out` and renamed. The portal picks the monitor,
##   so `--display <id>` is refused (exit 4 / `unsupported-option`); the
##   image's `origin` is the stream's `position` and its scale the frame's
##   pixel width over the stream's logical `size`.
## * **record**: the latest frame every 1/fps seconds (repeated while the
##   screen does not change, since a portal sends frames only on damage)
##   into ffmpeg (H.264 in MP4); SIGINT ends the frames, ffmpeg finalizes
##   the file, and the helper's status says `stopped` only once it has. The
##   file is measured as every Linux recording is (`linux_common`, C12).
##
## What the portal cannot do is refused by feature: it enumerates no
## displays or windows (`window-enumeration`, `display-server-unsupported`),
## cannot be pointed at a window by id (`window-capture`,
## `own-pixels-capture`), and region capture is not implemented
## (`region-capture`, `not-implemented`).
##
## ScreenCast portal: https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.ScreenCast.html ;
## PipeWire streams: https://docs.pipewire.org/page_streams.html

import std/[options, os, tables]

import ../../core/[geometry, desktop_types, interfaces, image]
import ../../state_store
import ../../cancel
import ./linux_common

const linuxPortalPipewireName* = "linux-portal-pipewire"
  ## The backend's contract name.

const
  noEnumeration = "the ScreenCast portal enumerates no displays or windows: " &
    "select the capture backend of this session's compositor (linux-wlr, " &
    "linux-gnome) to list them"
  busRemedy = "linux-portal-pipewire needs the session bus of a desktop session " &
    "with xdg-desktop-portal and a ScreenCast backend (DBUS_SESSION_BUS_ADDRESS)"

proc requireBus(cfg: LinuxCaptureConfig) =
  if cfg.env.getOrDefault("DBUS_SESSION_BUS_ADDRESS", "").len == 0:
    raise unavailableWith(linuxPortalPipewireName, "display-server-unsupported",
      "DBUS_SESSION_BUS_ADDRESS is not set: no portal to ask", busRemedy)

proc helperFailure*(code: int, status: StatusFile, errors: string): ref BackendError =
  ## The error of a `portal_screencast` run that did not succeed, from its
  ## exit status (helper doc) and status file.
  let msg = status.getOrDefault("message", lastLine(errors))
  case code
  of 3: unavailableWith(linuxPortalPipewireName, "display-server-unsupported",
          "no ScreenCast portal answers on this session bus: " & msg, busRemedy)
  of 4: captureFailed(linuxPortalPipewireName, "the screen cast was refused through " &
          "the portal (" & msg & ")")
  of 7: captureFailed(linuxPortalPipewireName, "the portal did not answer in time (" &
          msg & ")")
  else: captureFailed(linuxPortalPipewireName, "the portal screen cast failed (exit " &
          $code & "): " & msg)

proc refuseTarget(t: CaptureTarget, ownPixels: bool) =
  const n = linuxPortalPipewireName
  case t.kind
  of ctkDisplay:
    if t.id.isSome:
      raise unavailableWith(n, "unsupported-option", "the portal's chooser picks the " &
        "monitor; a display cannot be named by id", "omit --display")
  of ctkWindow:
    raise unavailableWith(n, "display-server-unsupported", "the ScreenCast portal " &
      "cannot be pointed at a window by id" & (if ownPixels: " (--own-pixels)" else: ""),
      "select the capture backend of this session's compositor for window captures")
  of ctkRegion:
    raise unavailableWith(n, "not-implemented", "region capture through the portal " &
      "is not implemented", "capture the display and crop it, or select the capture " &
      "backend of this session's compositor")

proc ffmpegExe(cfg: LinuxCaptureConfig): string =
  cfg.findTool(linuxPortalPipewireName, "ffmpeg", overrideVar = "FFMPEG_BIN")

proc helperArgs(cfg: LinuxCaptureConfig, report: string, cursor: bool): seq[string] =
  result = @[cfg.helperPath(linuxPortalPipewireName, "portal_screencast"),
             "--report", report, "--timeout-ms",
             $max(1000, min(toolTimeoutMs, cfg.token.remainingMs))]
  if cursor: result.add "--cursor"

proc capture(cfg: LinuxCaptureConfig, req: CaptureRequest): ImageRef =
  cfg.token.checkpoint()
  refuseTarget(req.target, req.ownPixels)
  cfg.requireBus()
  let outPath = absolutePath(req.outPath)
  let tmp = outputTemp(linuxPortalPipewireName, outPath, $getCurrentProcessId(), ".png")
  let tmpPpm = outputTemp(linuxPortalPipewireName, outPath, $getCurrentProcessId(), ".ppm")
  let dir = cfg.privateTempDir(linuxPortalPipewireName, "still")
  try:
    let report = dir / "report"
    let r = cfg.runTool(linuxPortalPipewireName, cfg.helperArgs(report, req.cursor) &
      @["--still", tmpPpm], timeoutMs = toolTimeoutMs + 5000)
    let st = try: parseStatusFile(readFile(report)) except IOError: StatusFile()
    if r.code != 0 or st.getOrDefault("state") != "stopped":
      raise helperFailure(r.code, st, r.errors)
    var img: RgbImage
    try: img = decodePpmRgb(readFileCapped(tmpPpm, maxImageFileBytes))
    except IOError, ValueError:
      raise captureFailed(linuxPortalPipewireName, "the streamed frame cannot be read: " &
        getCurrentExceptionMsg())
    result = writePngFile(linuxPortalPipewireName, tmp, outPath, img,
      point(st.intOf("x"), st.intOf("y")), st.intOf("width"),
      ImageSource(kind: iskDisplay, id: none(string), session: some(req.session)))
  finally:
    removeQuietly(tmpPpm)
    removeQuietly(tmp)
    try: removeDir(dir)
    except OSError: discard

proc record(cfg: LinuxCaptureConfig, req: RecordRequest): Recording =
  refuseTarget(req.target, false)
  cfg.requireBus()
  let ffmpeg = cfg.ffmpegExe()
  let outPath = absolutePath(req.outPath)
  startRecording(cfg, linuxPortalPipewireName, "portal", req,
    proc (id, controlDir: string): RecorderLaunch =
      let tmp = outputTemp(linuxPortalPipewireName, outPath, id, ".mp4")
      let status = controlDir / "status"
      RecorderLaunch(
        argv: cfg.helperArgs(status, true) & @["--fps", fpsText(req.fps), "--"] &
          rawRgbEncoder(ffmpeg, "%W%", "%H%", req.fps, tmp),
        tmpPath: tmp, statusPath: status, startedStates: @["streaming"],
        source: ImageSource(kind: iskDisplay, id: none(string), session: some(req.session))))

proc portalFeatures(cfg: LinuxCaptureConfig, probe: bool): seq[Feature] =
  const n = linuxPortalPipewireName
  var state = fsAvailable
  var reason, remedy = ""
  try:
    cfg.requireBus()
    discard cfg.helperPath(n, "portal_screencast")
    discard cfg.ffmpegExe()
    if probe:
      let dir = cfg.privateTempDir(n, "probe")
      try:
        let img = cfg.capture(CaptureRequest(session: "host",
          target: CaptureTarget(kind: ctkDisplay, id: none(string)),
          outPath: dir / "probe.png", cursor: false))
        if img.width > 0: state = fsSupported
      finally:
        try: removeDir(dir)
        except OSError: discard
  except BackendError as e:
    state = fsUnavailable
    reason = unavailableReason(e)
    remedy = if e.remedy.len > 0: e.remedy else: e.msg
  result.add feature(n, "window-enumeration", fsUnavailable, "display-server-unsupported",
                     noEnumeration)
  result.add feature(n, "display-capture", state, reason, remedy)
  result.add feature(n, "window-capture", fsUnavailable, "display-server-unsupported",
                     "the ScreenCast portal cannot be pointed at a window by id")
  result.add feature(n, "region-capture", fsUnavailable, "not-implemented",
                     "capture the display and crop it")
  result.add feature(n, "own-pixels-capture", fsUnavailable, "display-server-unsupported",
                     "the ScreenCast portal cannot be pointed at a window by id")
  result.add feature(n, "recording", (if state == fsSupported: fsAvailable else: state),
                     reason, remedy)

proc noEnumerationError(): ref BackendUnavailableError =
  unavailableWith(linuxPortalPipewireName, "display-server-unsupported",
    "the ScreenCast portal enumerates no displays or windows", noEnumeration)

proc newLinuxPortalPipewireCapture*(cfg: LinuxCaptureConfig): CaptureBackend =
  ## The `linux-portal-pipewire` backend (module doc).
  when not defined(linux):
    return wrongPlatformCapture(linuxPortalPipewireName)
  result.name = linuxPortalPipewireName
  result.displays = proc (session: string): seq[Display] = raise noEnumerationError()
  result.windows = proc (session: string, filter: WindowFilter): WindowList =
    raise noEnumerationError()
  result.capture = proc (req: CaptureRequest): ImageRef = cfg.capture(req)
  result.startRecording = proc (req: RecordRequest): Recording = cfg.record(req)
  result.stopRecording = proc (id: string): Recording =
    stopRecording(cfg, linuxPortalPipewireName, id)
  result.recordings = proc (): seq[Recording] = listRecordings(cfg, linuxPortalPipewireName)
  result.features = proc (probe: bool): seq[Feature] = cfg.portalFeatures(probe)
