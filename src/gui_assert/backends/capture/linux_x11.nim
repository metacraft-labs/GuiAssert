## The `linux-x11` capture backend: an X server (Xvfb, or any X11 display)
## read with XGetImage, for X11-only sessions (spec §4.2). It is the default
## capture backend of an X11 session without Wayland.
##
## Everything goes through GuiAssert's `x11_probe` helper
## (`helpers/linux/x11_probe.c`), which talks Xlib to the invocation's
## `DISPLAY`:
##
## * **Displays.** One per X screen: the screen number is the id, its size
##   the bounds (the root window is at the desktop origin), scale 1 (X11 has
##   no logical-to-physical scale), `primary` true, `name` null and
##   `virtual` false (an X server does not say whether it is Xvfb).
## * **Windows** are the client windows (the ones carrying `WM_STATE` under a
##   reparenting window manager, the root's children without one), front to
##   back from the server's stacking order (`XQueryTree` lists bottom to
##   top). `bounds` is the client's geometry in root coordinates; `pid` is
##   `_NET_WM_PID`, else the owning client's pid from the X-Resource
##   extension, else 0 (a remote client the server cannot attribute);
##   `app` is the `WM_CLASS` class (else its instance) and `appId` null;
##   `title` is `_NET_WM_NAME`, else `WM_NAME`; `onScreen` is "viewable";
##   `focused` holds the input focus; override-redirect windows (menus,
##   tooltips) are layer 1 and listed only with `--all-layers`; `minimized`
##   is false and `document` null (C4: X11 has no equivalent).
## * **Captures** are XGetImage of the root window: what is on screen. A
##   region must lie within the screen. A window capture crops the screen to
##   the window (`source.kind` `window-crop`, `window-capture` degraded with
##   reason `window-crop`): without a compositing manager an X server keeps
##   no pixels of the covered part of a window, so `--own-pixels` is refused
##   (exit 4 / `unsupported-option`). XGetImage never includes the cursor.
##   The helper writes a PPM, which is encoded to PNG by the pure core.
## * **Recordings.** The helper grabs one XGetImage frame every 1/fps
##   seconds and pipes the raw frames into ffmpeg (H.264 in MP4); SIGINT
##   ends the grabbing, ffmpeg finalizes the file, and the helper's status
##   file says `stopped` only once it has. (The pinned ffmpeg is built
##   without its `x11grab` device, so the grabbing is GuiAssert's own; the
##   encoding is ffmpeg's either way.)
##
## Xlib: https://www.x.org/releases/current/doc/libX11/libX11/libX11.html

import std/[algorithm, json, options, os, tables]

import ../../core/[geometry, desktop_types, interfaces, image, contract]
import ../../state_store
import ../../cancel
import ./linux_common

const linuxX11Name* = "linux-x11"
  ## The backend's contract name.

type
  X11Snapshot* = object
    ## One `x11_probe list` answer.
    screen*: int
    size*: Size
    windows*: seq[Window]    ## front to back, every client window

proc optStr(n: JsonNode): Option[string] =
  if n != nil and n.kind == JString: some(n.getStr) else: none(string)

proc parseX11List*(text: string): X11Snapshot =
  ## The snapshot of an `x11_probe list` line (module doc). Raises
  ## `ValueError` for anything that is not one.
  let j = try: parseJson(text) except JsonParsingError as e:
    raise newException(ValueError, "x11_probe's answer is not JSON: " & e.msg)
  if kindOf(j) != JObject or kindOf(j{"windows"}) != JArray:
    raise newException(ValueError, "x11_probe's answer has no window list")
  result.screen = j{"screen"}.getInt
  result.size = Size(width: j{"width"}.getInt, height: j{"height"}.getInt)
  let focus = j{"focus"}
  let display = some($result.screen)
  var rows: seq[Window]
  for w in j["windows"]:
    let class = optStr(w{"class"})
    let instance = optStr(w{"instance"})
    let id = $w{"id"}.getBiggestInt
    rows.add Window(id: id,
      pid: (if kindOf(w{"pid"}) == JInt: w{"pid"}.getInt else: 0),
      app: class.get(instance.get("")), appId: none(string), title: optStr(w{"title"}),
      document: none(string),
      bounds: rect(w{"x"}.getInt, w{"y"}.getInt, w{"width"}.getInt, w{"height"}.getInt),
      display: display, layer: (if w{"overrideRedirect"}.getBool: 1 else: 0),
      onScreen: w{"mapped"}.getBool,
      focused: kindOf(focus) == JInt and $focus.getBiggestInt == id, minimized: false)
  rows.reverse()
  result.windows = rows

proc screenDisplay*(s: X11Snapshot): Display =
  ## The display of an X screen (module doc).
  Display(id: $s.screen, name: none(string),
          bounds: rect(0, 0, s.size.width, s.size.height), scale: 1.0,
          primary: true, isVirtual: false)

proc x11Geometry*(r: Rect): string =
  ## A rectangle as the helper takes it: `WxH+X+Y`.
  $r.width & "x" & $r.height & "+" & $r.x & "+" & $r.y

# ---------------------------------------------------------------------------
# The X server
# ---------------------------------------------------------------------------

const displayRemedy = "linux-x11 captures the X display named by DISPLAY: set it " &
  "(for example inside an Xvfb session), or select the capture backend of " &
  "this session's compositor"

proc requireDisplay(cfg: LinuxCaptureConfig) =
  if cfg.env.getOrDefault("DISPLAY", "").len == 0:
    raise unavailableWith(linuxX11Name, "display-server-unsupported",
      "DISPLAY is not set: no X server to capture", displayRemedy)

proc probeFailure(r: ToolRun): ref BackendError =
  if r.code == 3:
    return unavailableWith(linuxX11Name, "display-server-unsupported",
      "cannot open the X display: " & lastLine(r.errors), displayRemedy)
  captureFailed(linuxX11Name, "x11_probe failed (exit " & $r.code & "): " & lastLine(r.errors))

proc snapshot(cfg: LinuxCaptureConfig): X11Snapshot =
  cfg.requireDisplay()
  let r = cfg.runTool(linuxX11Name, @[cfg.helperPath(linuxX11Name, "x11_probe"), "list"])
  if r.code != 0: raise probeFailure(r)
  try: parseX11List(r.output)
  except ValueError as e: raise captureFailed(linuxX11Name, e.msg)

type Target = object
  rect: Rect
  source: ImageSource

proc resolveTarget(cfg: LinuxCaptureConfig, session: string, t: CaptureTarget,
                   ownPixels: bool): Target =
  let snap = cfg.snapshot()
  let screen = snap.screenDisplay
  case t.kind
  of ctkDisplay:
    let d = pickDisplay(linuxX11Name, @[screen], t.id)
    Target(rect: d.bounds,
           source: ImageSource(kind: iskDisplay, id: some(d.id), session: some(session)))
  of ctkRegion:
    requireRegionOnOneDisplay(t.region, @[screen])
    Target(rect: t.region,
           source: ImageSource(kind: iskRegion, id: none(string), session: some(session)))
  of ctkWindow:
    if ownPixels:
      raise unavailableWith(linuxX11Name, "unsupported-option",
        "an X server without a compositing manager keeps no pixels of a covered " &
        "window: a linux-x11 window capture is a crop of the screen (source.kind " &
        "window-crop), never the window's own pixels",
        "omit --own-pixels to capture the window's rectangle as it appears on screen")
    if t.id.isNone:
      raise badArgs("missing-argument", "a window capture names the window")
    for w in snap.windows:
      if w.id == t.id.get:
        if not w.onScreen:
          raise captureFailed(linuxX11Name, "window '" & w.id &
            "' is not viewable; a window-crop capture shows only what is on screen")
        if not screen.bounds.contains(w.bounds):
          raise captureFailed(linuxX11Name, "window '" & w.id & "' lies partly off " &
            "the screen; a window-crop capture shows only what is on screen")
        return Target(rect: w.bounds,
          source: ImageSource(kind: iskWindowCrop, id: some(w.id), session: some(session)))
    raise notFound(linuxX11Name, "window", "no window '" & t.id.get & "'")

proc capture(cfg: LinuxCaptureConfig, req: CaptureRequest): ImageRef =
  cfg.token.checkpoint()
  let t = cfg.resolveTarget(req.session, req.target, req.ownPixels)
  let outPath = absolutePath(req.outPath)
  let tmpPng = outputTemp(linuxX11Name, outPath, $getCurrentProcessId(), ".png")
  let tmpPpm = outputTemp(linuxX11Name, outPath, $getCurrentProcessId(), ".ppm")
  try:
    let r = cfg.runTool(linuxX11Name, @[cfg.helperPath(linuxX11Name, "x11_probe"), "grab",
      "--geometry", x11Geometry(t.rect), "--out", tmpPpm])
    if r.code != 0: raise probeFailure(r)
    var img: RgbImage
    try:
      img = decodePpmRgb(readFileCapped(tmpPpm, maxImageFileBytes))
    except IOError, ValueError:
      raise captureFailed(linuxX11Name, "the grabbed frame cannot be read: " &
        getCurrentExceptionMsg())
    if img.width != t.rect.width or img.height != t.rect.height:
      raise captureFailed(linuxX11Name, "the grabbed frame is " & $img.width & "x" &
        $img.height & ", not the " & $t.rect.width & "x" & $t.rect.height & " asked for")
    result = writePngFile(linuxX11Name, tmpPng, outPath, img, point(t.rect.x, t.rect.y),
                          t.rect.width, t.source)
  finally:
    removeQuietly(tmpPpm)
    removeQuietly(tmpPng)

proc record(cfg: LinuxCaptureConfig, req: RecordRequest): Recording =
  let t = cfg.resolveTarget(req.session, req.target, false)
  let probe = cfg.helperPath(linuxX11Name, "x11_probe")
  let ffmpeg = cfg.findTool(linuxX11Name, "ffmpeg", overrideVar = "FFMPEG_BIN")
  let outPath = absolutePath(req.outPath)
  startRecording(cfg, linuxX11Name, "x11", req,
    proc (id, controlDir: string): RecorderLaunch =
      let tmp = outputTemp(linuxX11Name, outPath, id, ".mp4")
      let status = controlDir / "status"
      RecorderLaunch(
        argv: @[probe, "record", "--geometry", x11Geometry(t.rect), "--fps", fpsText(req.fps),
          "--report", status, "--"] &
          rawRgbEncoder(ffmpeg, $t.rect.width, $t.rect.height, req.fps, tmp),
        tmpPath: tmp, statusPath: status, startedStates: @["recording"],
        width: t.rect.width, height: t.rect.height, source: t.source))

proc x11Features(cfg: LinuxCaptureConfig, probe: bool): seq[Feature] =
  const n = linuxX11Name
  let ownPixels = feature(n, "own-pixels-capture", fsUnavailable, "unsupported-option",
    "an X server without a compositing manager keeps no pixels of a covered window")
  var state = fsAvailable
  var reason, remedy = ""
  if cfg.env.getOrDefault("DISPLAY", "").len == 0:
    state = fsUnavailable
    reason = "display-server-unsupported"
    remedy = displayRemedy
  else:
    try:
      discard cfg.helperPath(n, "x11_probe")
      if probe:
        discard cfg.snapshot()
        state = fsSupported
    except BackendError as e:
      state = fsUnavailable
      reason = unavailableReason(e)
      remedy = e.msg
  result.add feature(n, "window-enumeration", state, reason, remedy)
  result.add feature(n, "display-capture", state, reason, remedy)
  result.add(if state == fsUnavailable: feature(n, "window-capture", state, reason, remedy)
             else: feature(n, "window-capture", fsDegraded, "window-crop"))
  result.add feature(n, "region-capture", state, reason, remedy)
  result.add ownPixels
  var rec = feature(n, "recording", (if state == fsSupported: fsAvailable else: state),
                    reason, remedy)
  if state != fsUnavailable:
    try: discard cfg.findTool(n, "ffmpeg", overrideVar = "FFMPEG_BIN")
    except BackendUnavailableError as e:
      rec = feature(n, "recording", fsUnavailable, "missing-tool", e.msg)
  result.add rec

proc newLinuxX11Capture*(cfg: LinuxCaptureConfig): CaptureBackend =
  ## The `linux-x11` backend (module doc).
  when not defined(linux):
    return wrongPlatformCapture(linuxX11Name)
  result.name = linuxX11Name
  result.displays = proc (session: string): seq[Display] = @[cfg.snapshot().screenDisplay]
  result.windows = proc (session: string, filter: WindowFilter): WindowList =
    WindowList(windows: filterWindows(cfg.snapshot().windows, filter), titlesVisible: true)
  result.capture = proc (req: CaptureRequest): ImageRef = cfg.capture(req)
  result.startRecording = proc (req: RecordRequest): Recording = cfg.record(req)
  result.stopRecording = proc (id: string): Recording = stopRecording(cfg, linuxX11Name, id)
  result.recordings = proc (): seq[Recording] = listRecordings(cfg, linuxX11Name)
  result.features = proc (probe: bool): seq[Feature] = cfg.x11Features(probe)
  result.screenRecording = proc (probe: bool):
      tuple[state: PermissionState, identity: Option[string]] =
    # Every client of an X server may read its screen: no permission to hold.
    (psNotApplicable, none(string))
