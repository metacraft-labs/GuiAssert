## The `linux-wlr` capture backend: wlroots compositors through
## wlr-screencopy (`grim` stills, `wf-recorder` recordings), with displays and
## windows read from sway's IPC (spec §4.2). It is the default capture
## backend of a sway session.
##
## * **Displays** are sway's active outputs (`swaymsg -t get_outputs`): the
##   output name is the id, `rect` the bounds in layout (logical)
##   coordinates, `scale` the output scale. The primary display is the
##   output whose rectangle holds the layout origin (spec §5: desktop
##   coordinates have their origin at the primary display's top-left), else
##   the first. `name` is "make model" when the output reports them, and
##   `virtual` is true for wlroots' headless outputs (`HEADLESS-n`), which
##   exist only in software.
## * **Windows** are sway's views (`swaymsg -t get_tree`): the container id
##   is the window id; `bounds` is the view's content rectangle (`rect`
##   offset by `window_rect`, so borders and title bars are excluded); `app`
##   and `appId` are the Wayland `app_id` (an Xwayland window has its X11
##   class as `app` and no `appId`); `onScreen` is sway's `visible`;
##   `minimized` is always false (sway has no such state; a scratchpad
##   window is reported off screen). Sway's IPC states no stacking order, so
##   "front to back" is: the focused window, then floating windows (the
##   later in the tree, the higher), then tiled windows in tree order.
##   `document` is null (C4: Wayland has no equivalent).
## * **Captures.** A display capture is `grim -o <output>`; a region capture
##   is `grim -g`, and the region must lie within one display. wlr-screencopy
##   has no per-window capture, so a window capture **crops** the display to
##   the window's content rectangle and says so: `source.kind` is
##   `window-crop`, and `capabilities` reports `window-capture` degraded with
##   reason `window-crop`. `--own-pixels` is refused (exit 4 /
##   `unsupported-option`, `details.feature` `own-pixels-capture`): a crop
##   shows whatever covers the window. The scale is measured from the image
##   (its pixel width over the logical width captured).
## * **Recordings** are `wf-recorder` (H.264 in MP4, constant frame rate,
##   frames copied without waiting for damage so a still screen still yields
##   frames), finalized on SIGINT and measured from the file
##   (`linux_common`).
##
## Sway IPC: https://man.archlinux.org/man/sway-ipc.7 ;
## wlr-screencopy: https://wayland.app/protocols/wlr-screencopy-unstable-v1

import std/[algorithm, json, options, os, strutils, tables]

import ../../core/[geometry, desktop_types, interfaces, contract]
import ../../cancel
import ./linux_common

const linuxWlrName* = "linux-wlr"
  ## The backend's contract name.

# ---------------------------------------------------------------------------
# Pure: sway's answers as contract objects
# ---------------------------------------------------------------------------

proc rectOf(n: JsonNode): Rect =
  rect(n{"x"}.getInt, n{"y"}.getInt, n{"width"}.getInt, n{"height"}.getInt)

proc parseSwayOutputs*(text: string): seq[Display] =
  ## The displays of a `get_outputs` reply (module doc). Raises `ValueError`
  ## for a reply that is not a JSON array.
  let j = try: parseJson(text) except JsonParsingError as e:
    raise newException(ValueError, "sway's get_outputs reply is not JSON: " & e.msg)
  if j.kind != JArray: raise newException(ValueError, "sway's get_outputs reply is not a list")
  var primaryFound = false
  for o in j:
    if not o{"active"}.getBool: continue
    let r = rectOf(o{"rect"})
    var name = none(string)
    let make = o{"make"}.getStr
    let model = o{"model"}.getStr
    if make.len > 0 and make != "Unknown":
      name = some((make & " " & (if model != "Unknown": model else: "")).strip)
    var d = Display(id: o{"name"}.getStr, name: name, bounds: r,
                    scale: (if o{"scale"}.getFloat > 0: o{"scale"}.getFloat else: 1.0),
                    primary: false, isVirtual: o{"name"}.getStr.startsWith("HEADLESS-"))
    if not primaryFound and r.contains(point(0, 0)):
      d.primary = true
      primaryFound = true
    result.add d
  if not primaryFound and result.len > 0: result[0].primary = true

type ViewRow = object
  w: Window
  floating: bool
  order: int

proc collectViews(n: JsonNode, output: string, floating: bool, rows: var seq[ViewRow]) =
  var output = output
  if n{"type"}.getStr == "output": output = n{"name"}.getStr
  let isView = n{"type"}.getStr in ["con", "floating_con"] and n{"pid"}.getInt > 0 and
               (kindOf(n{"app_id"}) == JString or kindOf(n{"window_properties"}) == JObject)
  if isView:
    let r = rectOf(n{"rect"})
    let wr = rectOf(n{"window_rect"})
    let bounds = rect(r.x + wr.x, r.y + wr.y, wr.width, wr.height)
    let appId = if kindOf(n{"app_id"}) == JString: some(n{"app_id"}.getStr) else: none(string)
    let app = if appId.isSome: appId.get
              else: n{"window_properties"}{"class"}.getStr
    let title = if kindOf(n{"name"}) == JString: some(n{"name"}.getStr) else: none(string)
    let onScreen = n{"visible"}.getBool and not output.startsWith("__")
    rows.add ViewRow(floating: floating, order: rows.len, w: Window(
      id: $n{"id"}.getInt, pid: n{"pid"}.getInt, app: app, appId: appId, title: title,
      document: none(string), bounds: bounds,
      display: (if output.len > 0 and not output.startsWith("__"): some(output)
                else: none(string)),
      layer: 0, onScreen: onScreen, focused: n{"focused"}.getBool, minimized: false))
  # A node without children may omit the lists; a missing one is empty.
  if kindOf(n{"nodes"}) == JArray:
    for c in n["nodes"]: collectViews(c, output, floating, rows)
  if kindOf(n{"floating_nodes"}) == JArray:
    for c in n["floating_nodes"]: collectViews(c, output, true, rows)

proc parseSwayTree*(text: string): seq[Window] =
  ## The windows of a `get_tree` reply, front to back (module doc). Raises
  ## `ValueError` for a reply that is not a JSON object.
  let j = try: parseJson(text) except JsonParsingError as e:
    raise newException(ValueError, "sway's get_tree reply is not JSON: " & e.msg)
  if j.kind != JObject: raise newException(ValueError, "sway's get_tree reply is not a tree")
  var rows: seq[ViewRow]
  collectViews(j, "", false, rows)
  rows.sort(proc (a, b: ViewRow): int =
    if a.w.focused != b.w.focused: return (if a.w.focused: -1 else: 1)
    if a.floating != b.floating: return (if a.floating: -1 else: 1)
    if a.floating: cmp(b.order, a.order) else: cmp(a.order, b.order))
  for r in rows: result.add r.w

proc grimGeometry*(r: Rect): string =
  ## A rectangle as `grim -g` and `wf-recorder -g` spell it: `x,y wxh`.
  $r.x & "," & $r.y & " " & $r.width & "x" & $r.height

# ---------------------------------------------------------------------------
# The compositor
# ---------------------------------------------------------------------------

const ipcRemedy = "linux-wlr reads displays and windows through sway's IPC: run " &
  "it in a sway session (SWAYSOCK and WAYLAND_DISPLAY set), or select the " &
  "linux-portal-pipewire capture backend"

proc requireSession(cfg: LinuxCaptureConfig) =
  for k in ["WAYLAND_DISPLAY", "SWAYSOCK"]:
    if cfg.env.getOrDefault(k, "").len == 0:
      raise unavailableWith(linuxWlrName, "display-server-unsupported",
        k & " is not set: no sway session to capture", ipcRemedy)

proc swaymsg(cfg: LinuxCaptureConfig, kind: string): string =
  cfg.requireSession()
  let exe = cfg.findTool(linuxWlrName, "swaymsg")
  let r = cfg.runTool(linuxWlrName, @[exe, "-s", cfg.env["SWAYSOCK"], "-t", kind, "-r"])
  if r.code != 0:
    raise unavailableWith(linuxWlrName, "display-server-unsupported",
      "sway's IPC did not answer " & kind & " (exit " & $r.code & "): " &
      lastLine(r.errors & "\n" & r.output), ipcRemedy)
  r.output

proc readDisplays(cfg: LinuxCaptureConfig): seq[Display] =
  try: parseSwayOutputs(cfg.swaymsg("get_outputs"))
  except ValueError as e: raise captureFailed(linuxWlrName, e.msg)

proc readWindows(cfg: LinuxCaptureConfig): seq[Window] =
  try: parseSwayTree(cfg.swaymsg("get_tree"))
  except ValueError as e: raise captureFailed(linuxWlrName, e.msg)

type Target = object
  grimArgs: seq[string]    ## grim's / wf-recorder's target arguments
  origin: Point
  size: Size               ## logical
  scale: float
  source: ImageSource

proc resolveTarget(cfg: LinuxCaptureConfig, session: string, t: CaptureTarget,
                   ownPixels: bool): Target =
  ## Validate a capture target against the compositor before anything is
  ## captured: an unknown display or window is exit 3, a bad region exit 2.
  let displays = cfg.readDisplays()
  case t.kind
  of ctkDisplay:
    let d = pickDisplay(linuxWlrName, displays, t.id)
    Target(grimArgs: @["-o", d.id], origin: point(d.bounds.x, d.bounds.y),
           size: d.bounds.size, scale: d.scale,
           source: ImageSource(kind: iskDisplay, id: some(d.id), session: some(session)))
  of ctkRegion:
    requireRegionOnOneDisplay(t.region, displays)
    var scale = 1.0
    for d in displays:
      if d.bounds.contains(t.region): scale = d.scale
    Target(grimArgs: @["-g", grimGeometry(t.region)], origin: point(t.region.x, t.region.y),
           size: t.region.size, scale: scale,
           source: ImageSource(kind: iskRegion, id: none(string), session: some(session)))
  of ctkWindow:
    if ownPixels:
      raise unavailableWith(linuxWlrName, "unsupported-option",
        "wlr-screencopy has no per-window capture: a linux-wlr window capture is a crop " &
        "of the display (source.kind window-crop), never the window's own pixels",
        "omit --own-pixels to capture the window's rectangle as it appears on screen")
    if t.id.isNone:
      raise badArgs("missing-argument", "a window capture names the window")
    var found = false
    var w: Window
    for x in cfg.readWindows():
      if x.id == t.id.get:
        w = x
        found = true
    if not found:
      raise notFound(linuxWlrName, "window", "no window '" & t.id.get & "'")
    if not w.onScreen or w.bounds.isEmpty or displayOfRect(w.bounds, displays).isNone:
      raise captureFailed(linuxWlrName, "window '" & w.id &
        "' is not on screen; a window-crop capture shows only what is on a display")
    var scale = 1.0
    for d in displays:
      if some(d.id) == w.display: scale = d.scale
    Target(grimArgs: @["-g", grimGeometry(w.bounds)], origin: point(w.bounds.x, w.bounds.y),
           size: w.bounds.size, scale: scale,
           source: ImageSource(kind: iskWindowCrop, id: some(w.id), session: some(session)))

proc capture(cfg: LinuxCaptureConfig, req: CaptureRequest): ImageRef =
  cfg.token.checkpoint()
  let t = cfg.resolveTarget(req.session, req.target, req.ownPixels)
  let grim = cfg.findTool(linuxWlrName, "grim")
  let outPath = absolutePath(req.outPath)
  let tmp = outputTemp(linuxWlrName, outPath, $getCurrentProcessId(), ".png")
  try:
    var args = @[grim, "-t", "png"]
    if req.cursor: args.add "-c"
    args.add t.grimArgs
    args.add tmp
    let r = cfg.runTool(linuxWlrName, args)
    if r.code != 0:
      raise captureFailed(linuxWlrName, "grim failed (exit " & $r.code & "): " &
        lastLine(r.errors))
    result = adoptPng(linuxWlrName, tmp, outPath, t.origin, t.size.width, t.source)
  finally:
    removeQuietly(tmp)

proc record(cfg: LinuxCaptureConfig, req: RecordRequest): Recording =
  if req.target.kind == ctkWindow and req.target.id.isNone:
    raise badArgs("missing-argument", "a window recording names the window")
  let t = cfg.resolveTarget(req.session, req.target, false)
  let recorder = cfg.findTool(linuxWlrName, "wf-recorder")
  let outPath = absolutePath(req.outPath)
  startRecording(cfg, linuxWlrName, "wlr", req,
    proc (id, controlDir: string): RecorderLaunch =
      let tmp = outputTemp(linuxWlrName, outPath, id, ".mp4")
      RecorderLaunch(
        argv: @[recorder] & t.grimArgs & @["-r", $req.fps, "-D", "-y", "-c", "libx264", "-p", "bf=0",
          "-x", "yuv420p", "-m", "mp4", "-f", tmp],
        tmpPath: tmp,
        width: int(t.size.width.float * t.scale + 0.5),
        height: int(t.size.height.float * t.scale + 0.5),
        source: t.source))

proc wlrFeatures(cfg: LinuxCaptureConfig, probe: bool): seq[Feature] =
  ## The capture features (spec §7.5) as this session offers them.
  const n = linuxWlrName
  let ownPixels = feature(n, "own-pixels-capture", fsUnavailable, "unsupported-option",
    "wlr-screencopy has no per-window capture; window captures are display crops")
  var sessionProblem = ""
  for k in ["WAYLAND_DISPLAY", "SWAYSOCK"]:
    if sessionProblem.len == 0 and cfg.env.getOrDefault(k, "").len == 0:
      sessionProblem = k & " is not set"
  if sessionProblem.len > 0:
    for f in ["window-enumeration", "display-capture", "window-capture", "region-capture",
              "recording"]:
      result.add feature(n, f, fsUnavailable, "display-server-unsupported", ipcRemedy)
    result.add ownPixels
    return
  proc tool(name: string): string =
    try: (discard cfg.findTool(n, name); "")
    except BackendUnavailableError as e: e.msg
  let swayMissing = tool("swaymsg")
  let grimMissing = tool("grim")
  let recorderMissing = tool("wf-recorder")
  var enumState = fsAvailable
  var enumReason, enumRemedy = ""
  var captureState = fsAvailable
  if swayMissing.len > 0:
    enumState = fsUnavailable
    enumReason = "missing-tool"
    enumRemedy = swayMissing
  elif probe:
    try:
      discard cfg.readDisplays()
      enumState = fsSupported
    except BackendError as e:
      enumState = fsUnavailable
      enumReason = unavailableReason(e)
      enumRemedy = e.msg
  if probe and enumState == fsSupported and grimMissing.len == 0:
    # One real 1x1 capture of the primary display's corner.
    try:
      let d = pickDisplay(n, cfg.readDisplays(), none(string))
      let r = cfg.runTool(n, @[cfg.findTool(n, "grim"), "-t", "ppm", "-g",
        grimGeometry(rect(d.bounds.x, d.bounds.y, 1, 1)), "-"])
      captureState = if r.code == 0: fsSupported else: fsUnavailable
    except BackendError:
      captureState = fsUnavailable
  result.add feature(n, "window-enumeration", enumState, enumReason, enumRemedy)
  for f in ["display-capture", "region-capture", "window-capture"]:
    if grimMissing.len > 0:
      result.add feature(n, f, fsUnavailable, "missing-tool", grimMissing)
    elif enumState == fsUnavailable:
      result.add feature(n, f, fsUnavailable, enumReason, enumRemedy)
    elif captureState == fsUnavailable:
      result.add feature(n, f, fsUnavailable, "display-server-unsupported",
        "grim could not capture: does this compositor offer wlr-screencopy?")
    elif f == "window-capture":
      result.add feature(n, f, fsDegraded, "window-crop")
    else:
      result.add feature(n, f, captureState)
  result.add ownPixels
  result.add(
    if recorderMissing.len > 0: feature(n, "recording", fsUnavailable, "missing-tool", recorderMissing)
    elif enumState == fsUnavailable: feature(n, "recording", fsUnavailable, enumReason, enumRemedy)
    else: feature(n, "recording", fsAvailable))

proc newLinuxWlrCapture*(cfg: LinuxCaptureConfig): CaptureBackend =
  ## The `linux-wlr` backend (module doc).
  when not defined(linux):
    return wrongPlatformCapture(linuxWlrName)
  result.name = linuxWlrName
  result.displays = proc (session: string): seq[Display] = cfg.readDisplays()
  result.windows = proc (session: string, filter: WindowFilter): WindowList =
    let displays = cfg.readDisplays()
    var all = cfg.readWindows()
    for w in all.mitems:
      if w.display.isNone: w.display = displayOfRect(w.bounds, displays)
    WindowList(windows: filterWindows(all, filter), titlesVisible: true)
  result.capture = proc (req: CaptureRequest): ImageRef = cfg.capture(req)
  result.startRecording = proc (req: RecordRequest): Recording = cfg.record(req)
  result.stopRecording = proc (id: string): Recording =
    stopRecording(cfg, linuxWlrName, id)
  result.recordings = proc (): seq[Recording] = listRecordings(cfg, linuxWlrName)
  result.features = proc (probe: bool): seq[Feature] = cfg.wlrFeatures(probe)
  result.screenRecording = proc (probe: bool):
      tuple[state: PermissionState, identity: Option[string]] =
    # wlr-screencopy is offered to every client of the compositor: there is
    # no permission to hold.
    (psNotApplicable, none(string))
