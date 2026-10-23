## The headless GNOME target.
##
## GNOME is where an application must draw its own window decorations (Mutter
## implements no `xdg-decoration`), so it is a real target rather than an
## emulation: `gnome-shell --headless --wayland --virtual-monitor` — GNOME
## Shell 49 with its Mutter, as a desktop session runs it — inside a private
## runtime directory and session bus, with settings on a private GSettings
## keyfile served by the settings portal.
##
## The shell is started with `--unsafe-mode`, which opens its `Eval` method to
## this run, and the target drives everything through it:
##
##   * **input** through Clutter virtual input devices created inside the
##     shell (`ClutterSeat.create_virtual_device`) — the same mechanism
##     Mutter's remote-desktop interface uses — so events take the
##     compositor's own routing, as a mouse's and a keyboard's would;
##   * **window readback** from Mutter's own windows (`MetaWindow`): frame
##     rectangle (the window geometry), app id, pid, maximized, minimized,
##     fullscreen, focus. `org.gnome.Shell.Introspect` reports no positions,
##     which a move cannot be checked without;
##   * **capture** through `org.gnome.Shell.Screenshot.ScreenshotArea`.
##
## Facts are measured with `wm_probe` like on every Wayland target. Measured
## 2026-10-16 (GNOME Shell 49.4): no decoration manager (the client always
## decorates), all four capabilities advertised, maximize and fullscreen both
## honoured.
##
## Isolation: the runtime directory, session bus, settings and portals are
## the run's own. The SYSTEM bus is the host's: GNOME Shell reads logind
## (which session it belongs to) and NetworkManager over it, as any session
## does. It writes nothing there, and its attempt to register with GDM fails.
##
## Two first-login behaviours are switched off before the shell starts, both
## measured as breaking a scenario: the modal Welcome dialog (it covers
## windows and takes the focus) and animations. The Activities overview,
## which the shell opens when its startup ends, is closed once it has.
##
## A new virtual pointer drops the x of its first absolute motion (measured:
## a first motion to (300, 250) arrived at (0, 250)), so each device is primed
## with one motion when it is created.

import std/[json, os, osproc, sequtils, strtabs, strutils, tables, tempfiles, times]
import ../desktop_env, ./session_bus, ./wayland_probe

type
  GnomeTarget* = ref object of TargetEnvironment
    width*, height*: int
    runtimeDir: string
    presetRuntimeDir: string
      ## The runtime directory `start` uses instead of making one (see
      ## `newGnomeTarget`), "" for a fresh one.
    shell: Process
    bus: SessionBus
    facts: Table[string, Fact]
    probed: bool
    evalSeq: int

proc newGnomeTarget*(width = 1920; height = 1080; runtimeDir = ""): GnomeTarget =
  ## A private headless GNOME Shell. `runtimeDir`, when given, is the
  ## directory (an existing one or one to create, mode 0700) the session
  ## runs in, instead of a fresh `/tmp/guienv-*` (see `newSwayTarget`).
  GnomeTarget(name: "gnome", width: width, height: height, presetRuntimeDir: runtimeDir,
              sessionEnv: newStringTable(modeCaseSensitive))

proc attachGnomeTarget*(allowConfigure = false): GnomeTarget =
  ## A target for the GNOME session this process runs in. Nothing is
  ## started, and `stop` leaves the shell alone (it removes the virtual
  ## devices it made). `configure` is refused unless `allowConfigure`, and
  ## what it changes `stop` restores.
  ##
  ## It needs GNOME Shell's unsafe mode, which opens `Eval` — the same path
  ## the headless target drives. A running session keeps it off, and the
  ## target never turns it on: the developer does, for the session, in
  ## Looking Glass (Alt+F2, `lg`, then `global.context.unsafe_mode = true`).
  ## Without it, `start` fails by name and says so. Window readback has no
  ## other route on a real session: `org.gnome.Shell.Introspect` answers
  ## only GNOME's own portal backends outside unsafe mode, and gives no
  ## window positions in any mode.
  GnomeTarget(name: "gnome", attached: true, allowConfigure: allowConfigure,
              sessionEnv: newStringTable(modeCaseSensitive))

proc requirePath(t: GnomeTarget; name: string): string =
  result = getEnv(name)
  if result.len == 0 or not fileExists(result):
    raise t.envError("start", name & " is not set to an existing file " &
                     "(run inside GuiAssert's `nix develop`)")

proc eval*(t: GnomeTarget; js: string): JsonNode =
  ## Evaluate `js` (an expression) inside GNOME Shell and return its value.
  ## The result is written by the shell to a file as JSON rather than parsed
  ## out of `Eval`'s reply, whose string quoting is GVariant's.
  inc t.evalSeq
  let outPath = t.runtimeDir / ("eval-" & $t.evalSeq & ".json")
  let wrapped = "(function(){ const GLib = imports.gi.GLib; " &
    "const Clutter = imports.gi.Clutter; const Meta = imports.gi.Meta; let out; " &
    "try { out = {ok: true, value: (" & js & ")}; } " &
    "catch (e) { out = {ok: false, error: String(e)}; } " &
    "GLib.file_set_contents(" & escapeJson(outPath) & ", JSON.stringify(out)); " &
    "return 'done'; })()"
  let (output, code) = t.bus.call(@["gdbus", "call", "--session", "-d", "org.gnome.Shell",
    "-o", "/org/gnome/Shell", "-m", "org.gnome.Shell.Eval", wrapped])
  if code != 0 or not fileExists(outPath):
    raise t.envError("eval", "GNOME Shell did not evaluate: " & output.strip())
  let reply = parseJson(readFile(outPath))
  removeFile(outPath)
  if not reply["ok"].getBool:
    raise t.envError("eval", reply["error"].getStr)
  reply{"value"}

proc createDevices(t: GnomeTarget) =
  ## The virtual pointer and keyboard, primed (see the module comment).
  discard t.eval("(() => { const seat = Clutter.get_default_backend().get_default_seat(); " &
    "global._gaPointer = seat.create_virtual_device(Clutter.InputDeviceType.POINTER_DEVICE); " &
    "global._gaKeyboard = seat.create_virtual_device(Clutter.InputDeviceType.KEYBOARD_DEVICE); " &
    "const now = GLib.get_monotonic_time(); " &
    "global._gaPointer.notify_absolute_motion(now, 1, 1); " &
    "global._gaPointer.notify_absolute_motion(now + 1000, 1, 1); return 1; })()")

proc startAttached(t: GnomeTarget) =
  for k in ["WAYLAND_DISPLAY", "DBUS_SESSION_BUS_ADDRESS"]:
    if getEnv(k).len == 0:
      raise t.envError("start", "cannot attach: " & k & " is not set " &
                       "(run inside the GNOME session)")
  t.bus = attachedSessionBus()
  for k, v in t.bus.env: t.sessionEnv[k] = v
  # Eval's results are written here, by the shell, which runs as this user.
  t.runtimeDir = createTempDir("guienv-attach-", "", "/tmp")
  t.started = true
  var size: JsonNode
  try:
    size = t.eval("global.display.get_size()")
  except EnvError:
    t.started = false
    removeDir(t.runtimeDir)
    raise t.envError("start", "cannot attach: GNOME Shell's Eval is closed. " &
      "Unsafe mode is off in this session; turn it on for the session in " &
      "Looking Glass (Alt+F2, `lg`, `global.context.unsafe_mode = true`) " &
      "and attach again")
  t.width = size[0].getInt
  t.height = size[1].getInt
  t.createDevices()

method start*(t: GnomeTarget) =
  if t.started: return
  if t.attached:
    t.startAttached()
    return
  let shellExe = t.requirePath("GUI_ASSERT_GNOME_SHELL")
  let schemaDirs = getEnv("GUI_ASSERT_GNOME_SCHEMA_DATA_DIRS")
  # Short, under /tmp: sockets live here (see the sway target).
  if t.presetRuntimeDir.len > 0:
    t.runtimeDir = t.presetRuntimeDir
    createDir(t.runtimeDir)
  else:
    t.runtimeDir = createTempDir("guienv-", "", "/tmp")
  setFilePermissions(t.runtimeDir, {fpUserRead, fpUserWrite, fpUserExec})
  t.sessionEnv["XDG_RUNTIME_DIR"] = t.runtimeDir
  t.sessionEnv["XDG_SESSION_TYPE"] = "wayland"
  try:
    t.bus = startSessionBus(t.runtimeDir, "GNOME", t.sessionEnv, withPortals = false,
      extraEnv = [("XDG_DATA_DIRS", schemaDirs & ":" & getEnv("XDG_DATA_DIRS"))])
  except OSError as e:
    raise t.envError("start", "the session bus: " & e.msg)
  # No animations: a window that maximizes or a menu that opens is in its
  # final state when the compositor reports it, not part way there.
  # A fresh profile's first login opens GNOME Shell's modal Welcome dialog
  # over every window, and it takes the focus (measured: it covered the
  # probe window and swallowed the click meant for it). It is shown once
  # per version; this records it as shown for every version.
  try:
    discard t.bus.gsettings("set", "org.gnome.desktop.interface",
                            "enable-animations", "false")
    discard t.bus.gsettings("set", "org.gnome.shell",
                            "welcome-dialog-last-shown-version", "999999")
  except OSError as e: raise t.envError("start", e.msg)
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if k notin ["WAYLAND_DISPLAY", "DISPLAY", "SWAYSOCK", "XDG_SESSION_ID"]:
      env[k] = v
  for k, v in t.bus.env: env[k] = v
  try:
    t.shell = startProcess("/bin/sh", args = @["-c", "exec " & quoteShellCommand(
      [shellExe, "--headless", "--wayland", "--no-x11", "--unsafe-mode",
       "--virtual-monitor", $t.width & "x" & $t.height]) & " >" &
      quoteShell(t.runtimeDir / "gnome-shell.log") & " 2>&1"], env = env)
  except OSError as e:
    raise t.envError("start", "cannot run gnome-shell: " & e.msg)
  let deadline = epochTime() + 30
  while not pathExists(t.runtimeDir / "wayland-0"):
    if not t.shell.running or epochTime() > deadline:
      raise t.envError("start", "GNOME Shell did not start:\n" &
                       readFile(t.runtimeDir / "gnome-shell.log"))
    sleep(100)
  t.sessionEnv["WAYLAND_DISPLAY"] = "wayland-0"
  for k, v in t.bus.env: t.sessionEnv[k] = v
  # Up when Eval answers; then the portals, which need the display.
  while true:
    try:
      if t.eval("global.display.get_n_monitors()").getInt >= 1: break
    except EnvError:
      discard
    if epochTime() > deadline:
      raise t.envError("start", "GNOME Shell never answered Eval:\n" &
                       readFile(t.runtimeDir / "gnome-shell.log"))
    sleep(200)
  # GNOME Shell shows the Activities overview, where windows are
  # thumbnails, once its startup animation ends: a click or a capture would
  # be of the overview. Hidden after startup, and checked to STAY hidden
  # (hidden during startup, it reopened — measured).
  while t.eval("Main.layoutManager._startingUp").getBool:
    if epochTime() > deadline:
      raise t.envError("start", "GNOME Shell did not finish starting up")
    sleep(100)
  var hiddenFor = 0
  while hiddenFor < 5:
    if t.eval("Main.overview.visible").getBool:
      hiddenFor = 0
      discard t.eval("(Main.overview.hide(), 1)")
    else:
      inc hiddenFor
    if epochTime() > deadline:
      raise t.envError("start", "the Activities overview did not stay closed")
    sleep(100)
  try:
    t.bus.startPortals(t.sessionEnv)
  except OSError as e:
    raise t.envError("start", "the portals: " & e.msg)
  for k, v in t.bus.env: t.sessionEnv[k] = v
  t.started = true
  t.createDevices()

proc restoreSettings(t: GnomeTarget)

method stop*(t: GnomeTarget) =
  t.stopSpawned()
  t.restoreSettings()
  if t.attached:
    if t.started:
      # The devices are the shell's; dropping the last reference removes
      # them from the developer's seat.
      try: discard t.eval("(global._gaPointer = null, global._gaKeyboard = null, 1)")
      except EnvError: discard
    t.started = false
    if t.runtimeDir.len > 0:
      try: removeDir(t.runtimeDir)
      except OSError: discard
    return
  t.bus.stop()
  if t.shell != nil:
    if t.shell.running:
      t.shell.terminate()
      discard t.shell.waitForExit(5000)
      if t.shell.running: t.shell.kill()
    t.shell.close()
    t.shell = nil
  if t.runtimeDir.len > 0:
    for mount in ["doc", "gvfs"]:
      if dirExists(t.runtimeDir / mount):
        discard execCmdEx(quoteShellCommand(["fusermount", "-uz", t.runtimeDir / mount]))
    try: removeDir(t.runtimeDir)
    except OSError: discard
  t.started = false

proc requireStarted(t: GnomeTarget; operation: string) =
  if not t.started: raise t.envError(operation, "the target is not started")

method windows*(t: GnomeTarget): seq[EnvWindow] =
  ## The normal windows that have been shown. Mutter knows a window before it
  ## is first shown, with a 0x0 frame (measured: an Electron window created
  ## hidden); sway lists a window only once it is mapped, and so does this.
  ## A minimized window keeps its frame and is listed.
  t.requireStarted("windows")
  let list = t.eval("global.get_window_actors().map(a => a.meta_window)" &
    ".filter(w => w.get_window_type() === Meta.WindowType.NORMAL && " &
    "w.get_frame_rect().width > 0).map(w => { " &
    "const r = w.get_frame_rect(); return {appId: w.get_wm_class() || '', " &
    "title: w.get_title() || '', pid: w.get_pid(), x: r.x, y: r.y, w: r.width, " &
    "h: r.height, maximized: w.is_maximized ? w.is_maximized() : w.get_maximized() === 3, " &
    "minimized: w.minimized, fullscreen: w.is_fullscreen(), focused: w.has_focus()}; })")
  for n in list:
    var w = EnvWindow(appId: n["appId"].getStr, title: n["title"].getStr,
                      pid: n["pid"].getInt, focused: n["focused"].getBool,
                      rect: Rect(x: n["x"].getInt, y: n["y"].getInt,
                                 w: n["w"].getInt, h: n["h"].getInt))
    w.states.incl wsFloating
    if n["maximized"].getBool: w.states.incl wsMaximized
    if n["minimized"].getBool: w.states.incl wsMinimized
    if n["fullscreen"].getBool: w.states.incl wsFullscreen
    result.add w

proc metaWindow(w: EnvWindow): string =
  ## A JS expression for the MetaWindow of `w`, by pid and app id.
  "global.get_window_actors().map(a => a.meta_window).find(m => m.get_pid() === " &
    $w.pid & " && (m.get_wm_class() || '') === " & escapeJson(w.appId) & ")"

proc onWindow(t: GnomeTarget; w: EnvWindow; operation, action: string) =
  let done = t.eval("(() => { const m = " & metaWindow(w) &
    "; if (!m) return false; " & action & "; return true; })()")
  if not done.getBool:
    raise t.envError(operation, "no window " & w.appId.escape & " of pid " & $w.pid)

method placeWindow*(t: GnomeTarget; w: EnvWindow; x, y: int) =
  t.onWindow(w, "placeWindow", "m.move_frame(true, " & $x & ", " & $y & ")")

method setFullscreen*(t: GnomeTarget; w: EnvWindow; on: bool) =
  t.onWindow(w, "setFullscreen",
             if on: "m.make_fullscreen()" else: "m.unmake_fullscreen()")

method focusWindow*(t: GnomeTarget; w: EnvWindow) =
  t.onWindow(w, "focusWindow", "m.activate(global.get_current_time())")

method pointerMove*(t: GnomeTarget; x, y: int) =
  t.requireStarted("pointerMove")
  if x < 0 or y < 0 or x > t.width or y > t.height:
    raise t.envError("pointerMove", "position outside the monitor")
  discard t.eval("global._gaPointer.notify_absolute_motion(GLib.get_monotonic_time(), " &
                 $x & ", " & $y & ")")

method pointerButton*(t: GnomeTarget; button: PointerButton; pressed: bool) =
  t.requireStarted("pointerButton")
  # Clutter button numbers: 1 left, 2 middle, 3 right.
  let n = case button
    of pbLeft: 1
    of pbMiddle: 2
    of pbRight: 3
  discard t.eval("global._gaPointer.notify_button(GLib.get_monotonic_time(), " & $n &
    ", Clutter.ButtonState." & (if pressed: "PRESSED" else: "RELEASED") & ")")

method wheel*(t: GnomeTarget; notches: int) =
  t.requireStarted("wheel")
  let dir = if notches >= 0: "DOWN" else: "UP"
  for _ in 1 .. abs(notches):
    discard t.eval("global._gaPointer.notify_discrete_scroll(GLib.get_monotonic_time(), " &
      "Clutter.ScrollDirection." & dir & ", Clutter.ScrollSource.WHEEL)")

proc keyval(name: string): string =
  ## A JS expression for the keyval of a key name: a modifier spelled as
  ## wtype spells it, a single character, or an X keysym name (`Escape`).
  case name
  of "ctrl": "Clutter.KEY_Control_L"
  of "shift": "Clutter.KEY_Shift_L"
  of "alt": "Clutter.KEY_Alt_L"
  of "logo", "win", "super": "Clutter.KEY_Super_L"
  else:
    if name.len == 1: "Clutter.unicode_to_keysym(" & $ord(name[0]) & ")"
    else: "Clutter.KEY_" & name

method keys*(t: GnomeTarget; chord: string) =
  t.requireStarted("keys")
  let parts = chord.split('+')
  var js = "(() => { const k = global._gaKeyboard; let t = GLib.get_monotonic_time(); " &
           "const vals = [" & parts.mapIt(keyval(it)).join(", ") & "]; " &
           "if (vals.some(v => v === undefined || v === 0)) throw new Error('unknown key in " &
           chord.escape("", "") & "'); " &
           "for (const v of vals) k.notify_keyval(t += 1000, v, Clutter.KeyState.PRESSED); " &
           "for (const v of vals.slice().reverse()) k.notify_keyval(t += 1000, v, Clutter.KeyState.RELEASED); " &
           "return 1; })()"
  discard t.eval(js)

method typeText*(t: GnomeTarget; text: string) =
  for ch in text: t.keys($ch)

proc captureOnScreen(t: GnomeTarget; region: Rect): RgbImage

method capture*(t: GnomeTarget; region: Rect): RgbImage =
  ## The region as on screen, the size asked for: the part outside the
  ## monitor is black. `ScreenshotArea` refuses a region that is not wholly
  ## on the monitor ("Invalid params" — measured, for a 1900x1400 window on a
  ## 1600x1000 monitor), where `grim` on sway composites what is there, so
  ## the on-screen part is captured and placed.
  t.requireStarted("capture")
  let x0 = max(region.x, 0)
  let y0 = max(region.y, 0)
  let x1 = min(region.x + region.w, t.width)
  let y1 = min(region.y + region.h, t.height)
  if x1 <= x0 or y1 <= y0:
    raise t.envError("capture", "the region " & $region & " is not on the monitor")
  if (x0, y0, x1, y1) == (region.x, region.y, region.x + region.w, region.y + region.h):
    return t.captureOnScreen(region)
  let part = t.captureOnScreen(Rect(x: x0, y: y0, w: x1 - x0, h: y1 - y0))
  result = RgbImage(width: region.w, height: region.h,
                    data: newSeq[uint8](region.w * region.h * 3))
  for row in 0 ..< part.height:
    let src = row * part.width * 3
    let dst = ((y0 - region.y + row) * region.w + (x0 - region.x)) * 3
    for i in 0 ..< part.width * 3:
      result.data[dst + i] = part.data[src + i]

proc captureOnScreen(t: GnomeTarget; region: Rect): RgbImage =
  inc t.evalSeq
  let png = t.runtimeDir / ("shot-" & $t.evalSeq & ".png")
  let (output, code) = t.bus.call(@["gdbus", "call", "--session",
    "-d", "org.gnome.Shell.Screenshot", "-o", "/org/gnome/Shell/Screenshot",
    "-m", "org.gnome.Shell.Screenshot.ScreenshotArea", $region.x, $region.y,
    $region.w, $region.h, "false", png])
  if code != 0 or not fileExists(png):
    raise t.envError("capture", output.strip())
  let ffmpeg = getEnv("FFMPEG_BIN", "ffmpeg")
  # Decoded to a FILE: neither ffmpeg's diagnostics nor a pipe's handling
  # can then corrupt the image.
  let ppmPath = png.changeFileExt("ppm")
  let (log, rc) = execCmdEx(quoteShellCommand([ffmpeg, "-v", "error", "-y", "-i", png,
    "-frames:v", "1", "-pix_fmt", "rgb24", ppmPath]))
  removeFile(png)
  if rc != 0 or not fileExists(ppmPath):
    raise t.envError("capture", "cannot decode the screenshot: " & log)
  let bytes = readFile(ppmPath)
  removeFile(ppmPath)
  try: decodePpm(bytes)
  except ValueError as e: raise t.envError("capture", e.msg)

proc measureFacts(t: GnomeTarget) =
  if t.probed: return
  measureWaylandFacts(t, t.facts)
  proc put(name, value: string; detail: string) =
    t.facts[name] = Fact(name: name, value: value, provenance: fpDeclared, detail: detail)
  put("window.floatingByDefault", "true", "GNOME places every window freely")
  put("window.reportsMinimized", "true", "MetaWindow.minimized")
  t.probed = true

proc settingFact(t: GnomeTarget; name, key: string): Fact =
  let value = try: t.bus.gsettings("get", "org.gnome.desktop.wm.preferences", key)
              except OSError as e: raise t.envError("fact " & name, e.msg)
  Fact(name: name, value: value.strip(chars = {'\''}), provenance: fpConfigured,
       detail: "org.gnome.desktop.wm.preferences " & key & " in this session")

method fact*(t: GnomeTarget; name: string): Fact =
  t.requireStarted("fact " & name)
  case name
  of "buttonLayout": return t.settingFact(name, "button-layout")
  of "doubleClickTitlebar": return t.settingFact(name, "action-double-click-titlebar")
  else: discard
  t.measureFacts()
  if name notin t.facts:
    raise t.envError("fact " & name, "this target cannot establish it")
  t.facts[name]

method factNames*(t: GnomeTarget): seq[string] =
  t.measureFacts()
  for k in t.facts.keys: result.add k
  result.add @["buttonLayout", "doubleClickTitlebar"]

proc settingKey(t: GnomeTarget; setting: string): string =
  case setting
  of "buttonLayout": "button-layout"
  of "doubleClickTitlebar": "action-double-click-titlebar"
  else: raise t.envError("configure " & setting, "unknown setting")

proc restoreSettings(t: GnomeTarget) =
  for (setting, previous) in t.changedSettings:
    try: discard t.bus.gsettings("set", "org.gnome.desktop.wm.preferences",
                                 t.settingKey(setting), previous)
    except OSError, EnvError: discard
  t.changedSettings.setLen 0

method configure*(t: GnomeTarget; setting, value: string) =
  let key = t.settingKey(setting)
  t.guardConfigure(setting)
  if t.attached:
    let previous = try: t.bus.gsettings("get", "org.gnome.desktop.wm.preferences", key)
                   except OSError as e: raise t.envError("configure " & setting, e.msg)
    t.changedSettings.insert((setting, previous), 0)
  try: discard t.bus.gsettings("set", "org.gnome.desktop.wm.preferences", key, value)
  except OSError as e: raise t.envError("configure " & setting, e.msg)
  t.waitUntil("the settings portal serving " & setting & "=" & value, proc(): bool =
    let (output, code) = t.bus.readSetting("org.gnome.desktop.wm.preferences", key)
    code == 0 and ("'" & value & "'") in output)
