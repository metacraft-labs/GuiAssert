## The `linux-gnome` capture backend: GNOME Shell's own screenshot API and
## its window list (spec §4.2). It is the default capture backend of a GNOME
## session.
##
## Everything goes over the session bus of the invocation
## (`DBUS_SESSION_BUS_ADDRESS`), with `gdbus`:
##
## * **Displays and windows** are read inside the shell through
##   `org.gnome.Shell.Eval`, from Mutter's own objects: monitors
##   (`global.display` geometry, scale and primary monitor; the monitor index
##   is the id, `name` null, `virtual` false) and `MetaWindow`s (the window
##   id `get_id()`, the frame rectangle as `bounds`, the pid, the
##   application's name from the shell's window tracker as `app` and the
##   Wayland app id or X11 class as `appId`, the title, the monitor, focus,
##   minimized). `onScreen` is "not minimized and on the active workspace";
##   the order is Mutter's stacking order, front to back; windows of the
##   normal stack layer are layer 0, other layers keep Mutter's
##   `MetaStackLayer` value (and are listed with `--all-layers`). `document`
##   is null (C4). The result of each evaluation is written by the shell to
##   a file in a private directory under the state directory, as JSON,
##   rather than parsed out of `Eval`'s GVariant-quoted reply.
## * **Captures** are `org.gnome.Shell.Screenshot.ScreenshotArea` of the
##   display's, the region's or the window's rectangle (a window capture is
##   a crop: `source.kind` `window-crop`, `window-capture` degraded with
##   reason `window-crop`, `--own-pixels` refused with exit 4 /
##   `unsupported-option`, because `ScreenshotWindow` can capture only the
##   focused window). An area screenshot never includes the cursor. The shell
##   writes the PNG to the temporary sibling of `--out` itself.
## * **Recordings** are not implemented here (exit 4 / `not-implemented`
##   with `details.feature` `recording`): select `linux-portal-pipewire`,
##   whose GNOME portal backend records through the same compositor.
##
## **Which shells answer.** `Eval` and the screenshot API answer any caller
## only in GNOME Shell's unsafe mode, which a private shell started by
## GuiAssert (`gnome-shell --headless --unsafe-mode`, the `desktop_env/gnome`
## target and the `linux-gnome` session backend) runs in; a normal desktop
## session keeps them closed to everything but GNOME's own tools. There this
## backend answers exit 4 / `display-server-unsupported` naming it, never an
## empty list.
##
## D-Bus interfaces: https://gitlab.gnome.org/GNOME/gnome-shell/-/tree/main/data/dbus-interfaces

import std/[json, options, os, strutils, tables]

import ../../core/[geometry, desktop_types, interfaces, contract]
import ../../state_store
import ../../cancel
import ./linux_common

const linuxGnomeName* = "linux-gnome"
  ## The backend's contract name.

const closedRemedy = "GNOME Shell answers Eval and its screenshot API only in " &
  "unsafe mode: capture a private GNOME Shell (gnome-shell --headless " &
  "--unsafe-mode, as GuiAssert's GNOME session starts it), or select the " &
  "linux-portal-pipewire capture backend for a normal GNOME session"

# ---------------------------------------------------------------------------
# Pure: the shell's answers as contract objects
# ---------------------------------------------------------------------------

const
  displaysJs* = "(() => { const d = global.display; const p = d.get_primary_monitor(); " &
    "const out = []; for (let i = 0; i < d.get_n_monitors(); i++) { " &
    "const g = d.get_monitor_geometry(i); out.push({id: String(i), x: g.x, y: g.y, " &
    "width: g.width, height: g.height, scale: d.get_monitor_scale(i), primary: i === p}); } " &
    "return out; })()"
    ## The monitors, as `parseGnomeDisplays` reads them.

  windowsJs* = "(() => { const Shell = imports.gi.Shell; " &
    "const tracker = Shell.WindowTracker.get_default(); " &
    "const active = global.workspace_manager.get_active_workspace(); " &
    "const ws = global.get_window_actors().map(a => a.meta_window)" &
    ".filter(w => !w.is_override_redirect() && w.get_frame_rect().width > 0); " &
    "return global.display.sort_windows_by_stacking(ws).reverse().map(w => { " &
    "const r = w.get_frame_rect(); const app = tracker.get_window_app(w); " &
    "const onWs = w.is_on_all_workspaces() || w.get_workspace() === active; " &
    "return {id: String(w.get_id()), pid: w.get_pid(), " &
    "app: (app ? app.get_name() : null), appId: w.get_wm_class() || null, " &
    "title: w.get_title(), x: r.x, y: r.y, width: r.width, height: r.height, " &
    "monitor: w.get_monitor(), layer: w.get_layer(), " &
    "normalLayer: w.get_layer() === Meta.StackLayer.NORMAL, " &
    "minimized: w.minimized, onScreen: !w.minimized && onWs, focused: w.has_focus()}; }); })()"
    ## The windows, front to back, as `parseGnomeWindows` reads them.

proc parseGnomeDisplays*(j: JsonNode): seq[Display] =
  ## The displays of a `displaysJs` result. Raises `ValueError` for
  ## anything that is not a list.
  if j == nil or j.kind != JArray: raise newException(ValueError, "the monitor list is not a list")
  for m in j:
    result.add Display(id: m{"id"}.getStr, name: none(string),
      bounds: rect(m{"x"}.getInt, m{"y"}.getInt, m{"width"}.getInt, m{"height"}.getInt),
      scale: (if m{"scale"}.getFloat > 0: m{"scale"}.getFloat else: 1.0),
      primary: m{"primary"}.getBool, isVirtual: false)

proc parseGnomeWindows*(j: JsonNode): seq[Window] =
  ## The windows of a `windowsJs` result, front to back. Raises
  ## `ValueError` for anything that is not a list.
  if j == nil or j.kind != JArray: raise newException(ValueError, "the window list is not a list")
  for w in j:
    let appId = if kindOf(w{"appId"}) == JString: some(w{"appId"}.getStr) else: none(string)
    let app = if kindOf(w{"app"}) == JString: w{"app"}.getStr else: appId.get("")
    let title = if kindOf(w{"title"}) == JString: some(w{"title"}.getStr) else: none(string)
    let monitor = w{"monitor"}.getInt(-1)
    result.add Window(id: w{"id"}.getStr, pid: w{"pid"}.getInt, app: app, appId: appId,
      title: title, document: none(string),
      bounds: rect(w{"x"}.getInt, w{"y"}.getInt, w{"width"}.getInt, w{"height"}.getInt),
      display: (if monitor >= 0: some($monitor) else: none(string)),
      layer: (if w{"normalLayer"}.getBool: 0 else: w{"layer"}.getInt),
      onScreen: w{"onScreen"}.getBool, focused: w{"focused"}.getBool,
      minimized: w{"minimized"}.getBool)

# ---------------------------------------------------------------------------
# The shell
# ---------------------------------------------------------------------------

proc requireBus(cfg: LinuxCaptureConfig) =
  if cfg.env.getOrDefault("DBUS_SESSION_BUS_ADDRESS", "").len == 0:
    raise unavailableWith(linuxGnomeName, "display-server-unsupported",
      "DBUS_SESSION_BUS_ADDRESS is not set: no GNOME session to capture", closedRemedy)

proc gdbus(cfg: LinuxCaptureConfig, dest, path, meth: string, args: seq[string]): ToolRun =
  cfg.requireBus()
  let exe = cfg.findTool(linuxGnomeName, "gdbus")
  cfg.runTool(linuxGnomeName, @[exe, "call", "--session", "-d", dest, "-o", path,
                                "-m", meth] & args)

proc eval*(cfg: LinuxCaptureConfig, js: string): JsonNode =
  ## Evaluate `js` (an expression) inside GNOME Shell; its value comes back
  ## as JSON through a file the shell writes in a private directory.
  let dir = cfg.privateTempDir(linuxGnomeName, "eval")
  try:
    let outPath = dir / "result.json"
    let wrapped = "(function(){ const GLib = imports.gi.GLib; const Meta = imports.gi.Meta; " &
      "let out; try { out = {ok: true, value: (" & js & ")}; } " &
      "catch (e) { out = {ok: false, error: String(e)}; } " &
      "GLib.file_set_contents(" & escapeJson(outPath) & ", JSON.stringify(out)); " &
      "return 'done'; })()"
    let r = cfg.gdbus("org.gnome.Shell", "/org/gnome/Shell", "org.gnome.Shell.Eval", @[wrapped])
    if r.code != 0 or not fileExists(outPath):
      raise unavailableWith(linuxGnomeName, "display-server-unsupported",
        "GNOME Shell did not evaluate the window query (gdbus exit " & $r.code & ": " &
        lastLine(r.errors & "\n" & r.output) & ")", closedRemedy)
    let reply = try: parseJson(readFileCapped(outPath, maxRecordBytes))
                except JsonParsingError, IOError:
                  raise captureFailed(linuxGnomeName, "GNOME Shell's answer cannot be read: " &
                    getCurrentExceptionMsg())
    if not reply{"ok"}.getBool:
      raise captureFailed(linuxGnomeName, "GNOME Shell could not answer: " &
        lastLine(reply{"error"}.getStr))
    reply{"value"}
  finally:
    try: removeDir(dir)
    except OSError: discard

proc readDisplays(cfg: LinuxCaptureConfig): seq[Display] =
  try: parseGnomeDisplays(cfg.eval(displaysJs))
  except ValueError as e: raise captureFailed(linuxGnomeName, e.msg)

proc readWindows(cfg: LinuxCaptureConfig): seq[Window] =
  try: parseGnomeWindows(cfg.eval(windowsJs))
  except ValueError as e: raise captureFailed(linuxGnomeName, e.msg)

type Target = object
  rect: Rect
  source: ImageSource

proc resolveTarget(cfg: LinuxCaptureConfig, session: string, t: CaptureTarget,
                   ownPixels: bool): Target =
  let displays = cfg.readDisplays()
  case t.kind
  of ctkDisplay:
    let d = pickDisplay(linuxGnomeName, displays, t.id)
    Target(rect: d.bounds,
           source: ImageSource(kind: iskDisplay, id: some(d.id), session: some(session)))
  of ctkRegion:
    requireRegionOnOneDisplay(t.region, displays)
    Target(rect: t.region,
           source: ImageSource(kind: iskRegion, id: none(string), session: some(session)))
  of ctkWindow:
    if ownPixels:
      raise unavailableWith(linuxGnomeName, "unsupported-option",
        "GNOME Shell captures a window's own pixels only for the focused window: a " &
        "linux-gnome window capture is a crop of the display (source.kind window-crop)",
        "omit --own-pixels to capture the window's rectangle as it appears on screen")
    if t.id.isNone:
      raise badArgs("missing-argument", "a window capture names the window")
    for w in cfg.readWindows():
      if w.id == t.id.get:
        if not w.onScreen:
          raise captureFailed(linuxGnomeName, "window '" & w.id &
            "' is not on screen; a window-crop capture shows only what is on a display")
        var inside = false
        for d in displays:
          if d.bounds.contains(w.bounds): inside = true
        if not inside:
          raise captureFailed(linuxGnomeName, "window '" & w.id & "' does not lie within " &
            "one display; GNOME Shell's area screenshot captures only on-monitor areas")
        return Target(rect: w.bounds,
          source: ImageSource(kind: iskWindowCrop, id: some(w.id), session: some(session)))
    raise notFound(linuxGnomeName, "window", "no window '" & t.id.get & "'")

proc screenshotArea(cfg: LinuxCaptureConfig, r: Rect, path: string): ToolRun =
  cfg.gdbus("org.gnome.Shell.Screenshot", "/org/gnome/Shell/Screenshot",
    "org.gnome.Shell.Screenshot.ScreenshotArea",
    @[$r.x, $r.y, $r.width, $r.height, "false", path])

proc capture(cfg: LinuxCaptureConfig, req: CaptureRequest): ImageRef =
  cfg.token.checkpoint()
  let t = cfg.resolveTarget(req.session, req.target, req.ownPixels)
  let outPath = absolutePath(req.outPath)
  let tmp = outputTemp(linuxGnomeName, outPath, $getCurrentProcessId(), ".png")
  try:
    let r = cfg.screenshotArea(t.rect, tmp)
    if r.code != 0 or not r.output.strip.startsWith("(true"):
      if "AccessDenied" in r.errors or "not allowed" in r.errors:
        raise unavailableWith(linuxGnomeName, "display-server-unsupported",
          "GNOME Shell refused the screenshot: " & lastLine(r.errors), closedRemedy)
      raise captureFailed(linuxGnomeName, "GNOME Shell's ScreenshotArea failed (gdbus exit " &
        $r.code & "): " & lastLine(r.errors & "\n" & r.output))
    result = adoptPng(linuxGnomeName, tmp, outPath, point(t.rect.x, t.rect.y), t.rect.width,
                      t.source)
  finally:
    removeQuietly(tmp)

proc gnomeFeatures(cfg: LinuxCaptureConfig, probe: bool): seq[Feature] =
  const n = linuxGnomeName
  var state = fsAvailable
  var reason, remedy = ""
  try:
    cfg.requireBus()
    discard cfg.findTool(n, "gdbus")
    if probe:
      let d = pickDisplay(n, cfg.readDisplays(), none(string))
      let probeDir = cfg.privateTempDir(n, "probe")
      try:
        let r = cfg.screenshotArea(rect(d.bounds.x, d.bounds.y, 1, 1), probeDir / "probe.png")
        if r.code != 0 or not fileExists(probeDir / "probe.png"):
          raise unavailableWith(n, "display-server-unsupported",
            "GNOME Shell refused a screenshot: " & lastLine(r.errors), closedRemedy)
      finally:
        try: removeDir(probeDir)
        except OSError: discard
      state = fsSupported
  except BackendError as e:
    state = fsUnavailable
    reason = unavailableReason(e)
    remedy = if e.remedy.len > 0: e.remedy else: e.msg
  result.add feature(n, "window-enumeration", state, reason, remedy)
  result.add feature(n, "display-capture", state, reason, remedy)
  result.add(if state == fsUnavailable: feature(n, "window-capture", state, reason, remedy)
             else: feature(n, "window-capture", fsDegraded, "window-crop"))
  result.add feature(n, "region-capture", state, reason, remedy)
  result.add feature(n, "own-pixels-capture", fsUnavailable, "unsupported-option",
    "GNOME Shell captures a window's own pixels only for the focused window")
  result.add feature(n, "recording", fsUnavailable, "not-implemented",
    "select the linux-portal-pipewire capture backend to record a GNOME session")

proc notRecording(): ref BackendUnavailableError =
  unavailableWith(linuxGnomeName, "not-implemented",
    "the linux-gnome capture backend does not record",
    "select the linux-portal-pipewire capture backend to record a GNOME session")

proc newLinuxGnomeCapture*(cfg: LinuxCaptureConfig): CaptureBackend =
  ## The `linux-gnome` backend (module doc).
  when not defined(linux):
    return wrongPlatformCapture(linuxGnomeName)
  result.name = linuxGnomeName
  result.displays = proc (session: string): seq[Display] = cfg.readDisplays()
  result.windows = proc (session: string, filter: WindowFilter): WindowList =
    WindowList(windows: filterWindows(cfg.readWindows(), filter), titlesVisible: true)
  result.capture = proc (req: CaptureRequest): ImageRef = cfg.capture(req)
  result.startRecording = proc (req: RecordRequest): Recording = raise notRecording()
  result.stopRecording = proc (id: string): Recording = raise notRecording()
  result.recordings = proc (): seq[Recording] = raise notRecording()
  result.features = proc (probe: bool): seq[Feature] = cfg.gnomeFeatures(probe)
  result.screenRecording = proc (probe: bool):
      tuple[state: PermissionState, identity: Option[string]] =
    # A shell in unsafe mode answers every caller; a closed one refuses by
    # caller, which is not a grantable permission.
    (psNotApplicable, none(string))
