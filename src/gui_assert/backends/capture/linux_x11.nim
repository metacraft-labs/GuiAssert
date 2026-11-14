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
## * **The pointer's shape** (`x11PointerShape`): the server draws the
##   pointer itself, so no capture shows it. The helper's `cursor` mode reads
##   the cursor's image and name through the XFixes extension, and
##   `pointerShapeOf` names its shape — by the name the client gave it when
##   there is one (a themed cursor), else from the image's own form (the
##   core cursor font's glyphs have no names).
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

type
  PointerImage* = object
    ## One `x11_probe cursor` answer: the pointer's image as the X server
    ## draws it.
    name*: string                ## the cursor's name, "" when it has none
    serial*: int
    width*, height*, xhot*, yhot*: int
    at*: Point                   ## where the pointer is, screen pixels
    mask*: seq[string]           ## the image's opaque pixels, `#` per pixel

proc parsePointerImage*(text: string): PointerImage =
  ## The image of an `x11_probe cursor` line. Raises `ValueError`.
  var j: JsonNode
  try: j = parseJson(text)
  except JsonParsingError as e:
    raise newException(ValueError, "x11_probe's cursor answer is not JSON: " & e.msg)
  if j.kind != JObject or not j.hasKey("mask"):
    raise newException(ValueError, "x11_probe's cursor answer has no image")
  result = PointerImage(name: j{"name"}.getStr(""), serial: j{"serial"}.getInt,
                        width: j{"width"}.getInt, height: j{"height"}.getInt,
                        xhot: j{"xhot"}.getInt, yhot: j{"yhot"}.getInt,
                        at: Point(x: j{"x"}.getInt, y: j{"y"}.getInt))
  for row in j["mask"]: result.mask.add row.getStr

const pointerNames = {
  # CSS cursor names (the ones toolkits ask a theme for) and the X core
  # cursor font's, as the shape a pointer-affordance check names them
  "default": "default", "left_ptr": "default", "arrow": "default",
  "top_left_arrow": "default", "left_arrow": "default",
  "pointer": "pointer", "hand": "pointer", "hand1": "pointer", "hand2": "pointer",
  "pointing_hand": "pointer",
  "text": "text", "xterm": "text", "ibeam": "text", "vertical-text": "text",
  "col-resize": "col-resize", "ew-resize": "col-resize", "sb_h_double_arrow": "col-resize",
  "split_h": "col-resize", "h_double_arrow": "col-resize", "e-resize": "col-resize",
  "w-resize": "col-resize",
  "row-resize": "row-resize", "ns-resize": "row-resize", "sb_v_double_arrow": "row-resize",
  "split_v": "row-resize", "v_double_arrow": "row-resize", "n-resize": "row-resize",
  "s-resize": "row-resize",
  "grab": "grab", "openhand": "grab", "fleur": "grab", "move": "grab", "all-scroll": "grab",
  "grabbing": "grabbing", "closedhand": "grabbing", "dnd-move": "grabbing",
  "not-allowed": "not-allowed", "crossed_circle": "not-allowed", "no-drop": "not-allowed",
  "circle": "not-allowed",
  "wait": "wait", "watch": "wait", "progress": "wait", "left_ptr_watch": "wait",
  "crosshair": "crosshair", "cross": "crosshair", "tcross": "crosshair"}.toOrderedTable

proc xcursorImage*(path: string; size: int): Option[PointerImage] =
  ## The image an Xcursor file (a theme's `cursors/<name>`,
  ## https://www.x.org/releases/current/doc/man/man3/Xcursor.3.xhtml) holds
  ## at the nominal size nearest `size`: its mask (`#` where at least half
  ## opaque) and hot spot, as `x11_probe cursor` reports a live one. none()
  ## for a file that is not one.
  var d: string
  try: d = readFile(path)
  except IOError: return none(PointerImage)
  proc u32(at: int): int =
    if at + 4 > d.len: return -1
    int(uint32(ord(d[at])) or (uint32(ord(d[at + 1])) shl 8) or
        (uint32(ord(d[at + 2])) shl 16) or (uint32(ord(d[at + 3])) shl 24))
  if d.len < 16 or d[0 .. 3] != "Xcur": return none(PointerImage)
  let ntoc = u32(8)
  var best = -1
  var bestSize = 0
  for i in 0 ..< ntoc:
    let e = 16 + 12 * i
    if u32(e) == 0xfffd0002:
      let sub = u32(e + 4)
      if best < 0 or abs(sub - size) < abs(bestSize - size):
        best = u32(e + 8)
        bestSize = sub
  if best < 0: return none(PointerImage)
  let w = u32(best + 16)
  let h = u32(best + 20)
  if w <= 0 or h <= 0 or best + 36 + 4 * w * h > d.len: return none(PointerImage)
  var r = PointerImage(width: w, height: h, xhot: u32(best + 24), yhot: u32(best + 28))
  for y in 0 ..< h:
    var row = newString(w)
    for x in 0 ..< w:
      row[x] = (if ord(d[best + 36 + 4 * (y * w + x) + 3]) >= 0x80: '#' else: '.')
    r.mask.add row
  some(r)

proc pointerShapeOf*(img: PointerImage): string

proc pointerShapeOf*(img: PointerImage; themeCursors: string): string =
  ## The pointer's shape, told by the cursor theme it came from: the shape of
  ## the theme cursor (`themeCursors`, the theme's `cursors` directory) whose
  ## image and hot spot are the pointer's, in `pointerNames`' order — the
  ## names a toolkit asks a theme for. A theme draws its own shapes (a column
  ## resize need not look like any other theme's), so this is exact where
  ## the image's form alone is a guess; with no theme, or no cursor of it
  ## matching, it is `pointerShapeOf(img)`.
  if img.name.len > 0 or themeCursors.len == 0 or not dirExists(themeCursors):
    return pointerShapeOf(img)
  for name, shape in pointerNames:
    let c = xcursorImage(themeCursors / name, img.width)
    if c.isSome and c.get.width == img.width and c.get.height == img.height and
       c.get.xhot == img.xhot and c.get.yhot == img.yhot and c.get.mask == img.mask:
      return shape
  pointerShapeOf(img)

proc pointerShapeOf*(img: PointerImage): string =
  ## The pointer's shape: `default`, `pointer`, `text`, `col-resize`,
  ## `row-resize`, `grab`, `grabbing`, `not-allowed`, `wait`, `crosshair`, or
  ## "" when neither its name nor its form says. A named cursor is named by
  ## its name. An unnamed one is told by its opaque pixels and its hot spot,
  ## which is how the shapes differ in every cursor set: the text beam is a
  ## narrow upright bar with the hot spot inside it; the arrow points up and
  ## left with the hot spot at its tip (the opaque area's top-left corner);
  ## the hand's hot spot is its fingertip, at the top but well inside the
  ## width; the resize arrows are much wider than tall (or taller than wide)
  ## with the hot spot in the middle.
  if pointerNames.hasKey(img.name): return pointerNames[img.name]
  var x0 = high(int)
  var y0 = high(int)
  var x1, y1 = -1
  for y, row in img.mask:
    for x, c in row:
      if c == '#':
        x0 = min(x0, x)
        y0 = min(y0, y)
        x1 = max(x1, x)
        y1 = max(y1, y)
  if x1 < 0: return ""
  let w = x1 - x0 + 1
  let h = y1 - y0 + 1
  let hx = img.xhot - x0
  let hy = img.yhot - y0
  let centred = abs(hx - w div 2) <= max(2, w div 5) and abs(hy - h div 2) <= max(2, h div 5)
  if w <= 9 and h >= 2 * w and centred: return "text"
  if hx <= 2 and hy <= 2: return "default"
  if w >= 2 * h and centred: return "col-resize"
  if h >= 2 * w and centred: return "row-resize"
  if hy <= h div 4 and hx > w div 5 and hx < w - w div 5: return "pointer"
  if centred and abs(w - h) <= max(2, w div 4):
    # a cross: its middle row and its middle column run (almost) across it
    # (the X server's own `X`, the cursor of a window that set none, does not)
    let my = y0 + h div 2
    let mx = x0 + w div 2
    var across, down = 0
    for x in x0 .. x1:
      if x < img.mask[my].len and img.mask[my][x] == '#': inc across
    for y in y0 .. y1:
      if mx < img.mask[y].len and img.mask[y][mx] == '#': inc down
    if across * 5 >= w * 4 and down * 5 >= h * 4: return "crosshair"
  ""

proc x11PointerShape*(cfg: LinuxCaptureConfig): PointerImage =
  ## The pointer's image on the display `cfg.env` names (module doc).
  cfg.requireDisplay()
  let r = cfg.runTool(linuxX11Name, @[cfg.helperPath(linuxX11Name, "x11_probe"), "cursor"])
  if r.code != 0: raise probeFailure(r)
  try: parsePointerImage(r.output)
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
