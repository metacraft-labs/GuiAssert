## The `linux-mutter` input backend (spec §4.2): pointer and keyboard input
## in a GNOME session through Mutter's remote-desktop D-Bus API, which
## injects through Clutter virtual input devices inside the compositor, so
## events take GNOME's own routing as a mouse's and a keyboard's would. It is
## the default input backend of a GNOME Wayland session.
##
## **The API** (`org.gnome.Mutter.RemoteDesktop` and
## `org.gnome.Mutter.ScreenCast` on the session bus,
## https://gitlab.gnome.org/GNOME/mutter/-/blob/main/data/dbus-interfaces/org.gnome.Mutter.RemoteDesktop.xml),
## spoken in the D-Bus wire protocol by GuiAssert's own client
## (`backends/tree/dbus_wire`), so nothing is needed on the package's wrapper:
##
## * each verb creates a remote-desktop session, and for a verb that moves
##   the pointer a screen-cast session linked to it that records every
##   monitor a point of the verb lies on (absolute motion is only defined
##   against a stream), starts it, sends the plan (`linux_plan`) and stops
##   it; Mutter ends a session whose creator leaves the bus as well;
## * a screen cast needs PipeWire running in the session, as it does in
##   every GNOME session; without it the session does not start, which is
##   exit 4 / `missing-tool` naming PipeWire;
## * pointer positions: a desktop point (Mutter's stage coordinates, those
##   `linux-gnome` reports windows in) is sent in the coordinates of the
##   stream of the monitor that holds it (`linux_plan.streamPosition`, from
##   `org.gnome.Mutter.DisplayConfig.GetCurrentState`), and a point on no
##   monitor is exit 3 / `display` before anything is sent. A new virtual
##   pointer drops the x of its first absolute motion (measured on GNOME
##   Shell 49 by the headless GNOME target), so the first motion of a verb
##   is sent twice;
## * keys are sent as keysyms (`NotifyKeyboardKeysym`). Mutter finds a key
##   for a keysym in the session's current layout and adds the level's
##   modifiers itself, and silently drops a keysym the layout has no key
##   for. So before sending, the backend reads the seat keyboard's keymap
##   through GuiAssert's `wayland_input keysyms` helper and refuses a key the
##   layout lacks with exit 4 / `unsupported-option`, naming its position,
##   never the character.
##
## **Window management** (`window-focus`, `window-set-bounds`) has no
## remote-desktop request: it goes through GNOME Shell's `Eval`
## (`MetaWindow.activate`, `move_resize_frame`), which a shell answers only
## in unsafe mode, as `linux-gnome`'s window list does. Window ids are
## `linux-gnome`'s (`MetaWindow.get_id`).

import std/[json, options, os, posix, strutils, tables]

import ../../core/[geometry, desktop_types, interfaces]
import ../../cancel
import ../tree/dbus_wire
import ./[linux_common, linux_plan]
import ../capture/linux_common as capture_common
import ../capture/linux_gnome as capture_gnome

const
  linuxMutterName* = "linux-mutter"
  rdName = "org.gnome.Mutter.RemoteDesktop"
  rdPath = "/org/gnome/Mutter/RemoteDesktop"
  scName = "org.gnome.Mutter.ScreenCast"
  scPath = "/org/gnome/Mutter/ScreenCast"
  dcName = "org.gnome.Mutter.DisplayConfig"
  dcPath = "/org/gnome/Mutter/DisplayConfig"
  propsIface = "org.freedesktop.DBus.Properties"
  callTimeoutMs = 10_000
  mutterRemedy* = "linux-mutter sends input through Mutter's remote-desktop API on the " &
    "session bus: run it in a GNOME Wayland session (DBUS_SESSION_BUS_ADDRESS and " &
    "WAYLAND_DISPLAY set), or select the input backend of this session's display " &
    "server (linux-wlr-virtual for sway, linux-xtest for X11)"
  pipewireRemedy = "start PipeWire in the session (a GNOME session runs it; a private " &
    "one needs `pipewire` started with the session's XDG_RUNTIME_DIR)"
  layoutRemedy = "add a keyboard layout with that character to the session, or select " &
    "linux-wlr-virtual or linux-xtest, which type any character"
  evalRemedy = "window-focus and window-set-bounds on GNOME go through GNOME Shell's " &
    "Eval, which a shell answers only in unsafe mode (gnome-shell --unsafe-mode, as " &
    "GuiAssert's private GNOME session starts it)"
  btnCodes: array[MouseButton, int] = [0x110, 0x111, 0x112]
    ## BTN_LEFT, BTN_RIGHT, BTN_MIDDLE (linux/input-event-codes.h)
  axisFinish = 1'u32
  axisSourceFinger = 4'u32
    ## META_REMOTE_DESKTOP_NOTIFY_AXIS_FLAGS_* of the API.

# ---------------------------------------------------------------------------
# Pure: the display configuration
# ---------------------------------------------------------------------------

proc parseCurrentState*(body: seq[DValue]): tuple[monitors: seq[MutterMonitor], logical: bool] =
  ## The logical monitors of a `GetCurrentState` answer
  ## (`u a((ssss)a(siiddada{sv})a{sv}) a(iiduba(ssss)a{sv}) a{sv}`), each with
  ## the desktop rectangle it covers, and whether the layout is "logical"
  ## (`layout-mode` 1: stage views scaled) rather than "physical" (2).
  ## Raises `DbusError` for an answer of another shape.
  if body.len < 4: raise newException(DbusError, "GetCurrentState answered " & $body.len & " values")
  var modes = initTable[string, (int, int)]()
  for m in body[1].elems:
    let f = m.elems
    let connector = f[0].elems[0].asStr
    for mode in f[1].elems:
      let mf = mode.elems
      for entry in mf[6].elems:
        let kv = entry.elems
        if kv[0].asStr == "is-current" and kv[1].unwrap.asInt != 0:
          modes[connector] = (int(mf[1].asInt), int(mf[2].asInt))
  for entry in body[3].elems:
    let kv = entry.elems
    if kv[0].asStr == "layout-mode": result.logical = kv[1].unwrap.asInt == 1
  for lm in body[2].elems:
    let f = lm.elems
    let x = int(f[0].asInt)
    let y = int(f[1].asInt)
    let scale = f[2].asFloat
    let transform = f[3].asInt
    let mons = f[5].elems
    if mons.len == 0: continue
    let connector = mons[0].elems[0].asStr
    if connector notin modes: continue
    var (w, h) = modes[connector]
    if transform mod 2 == 1: swap(w, h)
    if result.logical and scale > 0:
      w = int(w.float / scale + 0.5)
      h = int(h.float / scale + 0.5)
    result.monitors.add MutterMonitor(connector: connector, bounds: rect(x, y, w, h),
                                      scale: scale)

# ---------------------------------------------------------------------------
# Sessions
# ---------------------------------------------------------------------------

type Remote = object
  c: DbusConnection
  session: string
  streams: Table[string, string]   ## connector -> stream path

proc failed(msg: string): ref BackendError = inputFailed(linuxMutterName, msg)

proc connect(cfg: LinuxInputConfig): DbusConnection =
  cfg.requireEnv(linuxMutterName, ["DBUS_SESSION_BUS_ADDRESS"], "GNOME session", mutterRemedy)
  let token = cfg.token
  try:
    connectBus(cfg.env["DBUS_SESSION_BUS_ADDRESS"], checkpoint = proc () = token.checkpoint())
  except DbusError as e:
    raise unavailableWith(linuxMutterName, "display-server-unsupported",
      "cannot connect to the session bus: " & e.msg, mutterRemedy)

proc unsupported(e: ref DbusError): ref BackendError =
  if e of ref DbusCallError and (ref DbusCallError)(e).errorName in [
      "org.freedesktop.DBus.Error.ServiceUnknown", "org.freedesktop.DBus.Error.UnknownMethod",
      "org.freedesktop.DBus.Error.UnknownObject", "org.freedesktop.DBus.Error.NameHasNoOwner"]:
    unavailableWith(linuxMutterName, "display-server-unsupported",
      "Mutter's remote-desktop API does not answer: " & e.msg, mutterRemedy)
  else:
    failed("Mutter refused the request: " & e.msg)

proc monitors(c: DbusConnection): tuple[monitors: seq[MutterMonitor], logical: bool] =
  try: parseCurrentState(c.call(dcName, dcPath, dcName, "GetCurrentState",
                                timeoutMs = callTimeoutMs))
  except DbusCallError as e: raise unsupported(e)
  except DbusError as e: raise failed("cannot read the display configuration: " & e.msg)

proc requirePipewire(cfg: LinuxInputConfig) =
  ## Refuse a screen cast in a session without PipeWire before asking
  ## Mutter for one: Mutter waits for a PipeWire that is gone rather than
  ## failing (measured on GNOME Shell 49: with the daemon stopped, Start did
  ## not answer, and the shell stopped answering Eval). The socket is where
  ## libpipewire looks for it (`PIPEWIRE_RUNTIME_DIR`, else
  ## `XDG_RUNTIME_DIR`; `PIPEWIRE_REMOTE`, else `pipewire-0`).
  var dir = cfg.env.getOrDefault("PIPEWIRE_RUNTIME_DIR", "")
  if dir.len == 0: dir = cfg.env.getOrDefault("XDG_RUNTIME_DIR", "")
  let name = cfg.env.getOrDefault("PIPEWIRE_REMOTE", "pipewire-0")
  let path = if name.isAbsolute: name else: dir / name
  var st: Stat
  if dir.len == 0 or stat(path.cstring, st) != 0:
    raise unavailableWith(linuxMutterName, "missing-tool", "PipeWire is not running in " &
      "the session (no socket at " & path & "), and absolute pointer motion needs a " &
      "screen cast", pipewireRemedy)

proc stopSession(c: DbusConnection, session: string) =
  ## Stop remote-desktop session `session` (and the screen cast linked to
  ## it), even while the invocation is being cancelled: the session must
  ## not outlive the verb.
  c.checkpoint = nil
  try: discard c.call(rdName, session, rdName & ".Session", "Stop", timeoutMs = 3000)
  except DbusError: discard

proc startSession(r: var Remote, connectors: seq[string]) =
  ## Link a screen cast recording each of `connectors` to `r`'s session
  ## (none for a plan without motion), then start the session.
  let c = r.c
  try:
    if connectors.len > 0:
      let id = c.call(rdName, r.session, propsIface, "Get",
                      [dstr(rdName & ".Session"), dstr("SessionId")],
                      timeoutMs = callTimeoutMs)[0].asStr
      let sc = c.call(scName, scPath, scName, "CreateSession",
                      [dvardict([("remote-desktop-session-id", dstr(id))])],
                      timeoutMs = callTimeoutMs)[0].asStr
      for conn in connectors:
        r.streams[conn] = c.call(scName, sc, scName & ".Session", "RecordMonitor",
          [dstr(conn), dvardict([("cursor-mode", duint32(0))])],
          timeoutMs = callTimeoutMs)[0].asStr
  except DbusCallError as e: raise unsupported(e)
  except DbusError as e: raise failed("cannot create a remote-desktop session: " & e.msg)
  try:
    discard c.call(rdName, r.session, rdName & ".Session", "Start",
                   timeoutMs = callTimeoutMs)
  except DbusCallError as e:
    if "pipewire" in e.msg.toLowerAscii:
      raise unavailableWith(linuxMutterName, "missing-tool",
        "Mutter cannot start a screen cast, which absolute pointer motion needs: " & e.msg,
        pipewireRemedy)
    raise unsupported(e)
  except DbusError as e: raise failed("cannot start the remote-desktop session: " & e.msg)

proc open(c: DbusConnection, connectors: seq[string]): Remote =
  ## A started remote-desktop session, with a stream for each of
  ## `connectors`. A session created but not started (a refused screen
  ## cast, a cancellation) is stopped before the error propagates.
  result.c = c
  try:
    result.session = c.call(rdName, rdPath, rdName, "CreateSession",
                            timeoutMs = callTimeoutMs)[0].asStr
  except DbusCallError as e: raise unsupported(e)
  except DbusError as e: raise failed("cannot create a remote-desktop session: " & e.msg)
  try:
    result.startSession(connectors)
  except CatchableError:
    c.stopSession(result.session)
    raise

proc close(r: var Remote) =
  if r.session.len == 0: return
  r.c.stopSession(r.session)
  r.session = ""

proc notify(r: Remote, member: string, args: openArray[DValue]) =
  try: discard r.c.call(rdName, r.session, rdName & ".Session", member, args,
                        timeoutMs = callTimeoutMs)
  except DbusCallError as e: raise failed(member & " was refused: " & e.msg)
  except DbusError as e: raise failed(member & " failed: " & e.msg)

proc checkKeysyms(cfg: LinuxInputConfig, ops: seq[InputOp]) =
  ## Refuse a plan whose keys the session's current layout cannot make
  ## (module doc), naming the POSITION of the first such key press among
  ## the plan's key presses, never its character.
  let keysyms = keysymsOf(ops)
  if keysyms.len == 0: return
  cfg.requireEnv(linuxMutterName, ["WAYLAND_DISPLAY"], "GNOME Wayland session", mutterRemedy)
  let helper = cfg.helperPath(linuxMutterName, "wayland_input")
  var input = ""
  for ks in keysyms: input.add keysymHex(ks) & "\n"
  let r = cfg.runHelper(linuxMutterName, @[helper, "keysyms"], input, helperBaseTimeoutMs)
  if r.code != 0 or not r.line.startsWith("ok"):
    cfg.raiseHelperFailure(linuxMutterName, r, mutterRemedy)
  let answers = r.output.splitLines()
  var missing: seq[uint32]
  for i, ks in keysyms:
    if i + 1 >= answers.len or answers[i + 1].strip notin ["0", "1"]:
      raise failed("the keymap reader answered " & $(answers.len - 1) & " of " &
                   $keysyms.len & " keys")
    if answers[i + 1].strip == "0": missing.add ks
  if missing.len == 0: return
  var position = 0
  for o in ops:
    if o.kind == ioKey and o.keyDown:
      inc position
      if o.keysym in missing:
        raise unavailableWith(linuxMutterName, "unsupported-option", "key " & $position &
          " of the input has no key in the session's keyboard layout (Mutter would drop it)",
          layoutRemedy)

proc runPlan(cfg: LinuxInputConfig, ops: seq[InputOp]) =
  var c = cfg.connect()
  try:
    # Before any remote-desktop session exists: a key the layout lacks is
    # refused with nothing sent.
    cfg.checkKeysyms(ops)
    var connectors: seq[string]
    var positions: seq[tuple[connector: string, x, y: float]]
    let points = movePoints(ops)
    if points.len > 0:
      let (mons, logical) = c.monitors()
      for p in points:
        let s = streamPosition(mons, logical, p)
        if s.isNone:
          raise newBackendError(BackendNotFoundError, linuxMutterName, "display",
            "no display of the session contains the point (" & $p.x & ", " & $p.y & ")")
        positions.add s.get
        if s.get.connector notin connectors: connectors.add s.get.connector
    if connectors.len > 0: cfg.requirePipewire()
    var r = c.open(connectors)
    var heldButtons: seq[MouseButton]
    var heldKeys: seq[uint32]
    try:
      var moveIndex = 0
      for o in ops:
        cfg.token.checkpoint()
        case o.kind
        of ioMove:
          let p = positions[moveIndex]
          let args = [dstr(r.streams[p.connector]), ddouble(p.x), ddouble(p.y)]
          if moveIndex == 0: r.notify("NotifyPointerMotionAbsolute", args)
          r.notify("NotifyPointerMotionAbsolute", args)
          inc moveIndex
        of ioButton:
          r.notify("NotifyPointerButton", [dint32(btnCodes[o.button]), dbool(o.pressed)])
          if o.pressed: heldButtons.add o.button
          else:
            let i = heldButtons.find(o.button)
            if i >= 0: heldButtons.delete(i)
        of ioScroll:
          if o.unit == suLine:
            r.notify("NotifyPointerAxisDiscrete", [duint32(if o.vertical: 0 else: 1),
                                                   dint32(o.amount)])
          else:
            let d = o.amount.float
            r.notify("NotifyPointerAxis", [ddouble(if o.vertical: 0.0 else: d),
                                          ddouble(if o.vertical: d else: 0.0),
                                          duint32(axisSourceFinger)])
            r.notify("NotifyPointerAxis", [ddouble(0.0), ddouble(0.0),
                                          duint32(axisFinish or axisSourceFinger)])
        of ioKey:
          r.notify("NotifyKeyboardKeysym", [duint32(o.keysym), dbool(o.keyDown)])
          if o.keyDown: heldKeys.add o.keysym
          else:
            let i = heldKeys.find(o.keysym)
            if i >= 0: heldKeys.delete(i)
        of ioSleep:
          cfg.token.sleepCancellable(o.ms)
    finally:
      # Nothing stays pressed, whether the plan finished, failed or was
      # cancelled.
      c.checkpoint = nil
      for b in heldButtons:
        try: r.notify("NotifyPointerButton", [dint32(btnCodes[b]), dbool(false)])
        except BackendError: discard
      for i in countdown(heldKeys.high, 0):
        try: r.notify("NotifyKeyboardKeysym", [duint32(heldKeys[i]), dbool(false)])
        except BackendError: discard
      r.close()
  finally:
    c.close()

# ---------------------------------------------------------------------------
# Window management through Eval
# ---------------------------------------------------------------------------

proc requireMetaId(id: string): string =
  if id.len == 0 or not id.allCharsInSet(Digits) or id.len > 18:
    raise newBackendError(BackendNotFoundError, linuxMutterName, "window",
      "no window '" & id & "' in this session (GNOME window ids are numbers)")
  id

proc shellEval(cfg: LinuxInputConfig, js: string): JsonNode =
  try: capture_gnome.eval(cfg.captureCfg, js)
  except BackendError as e:
    if e of ref BackendUnavailableError:
      raise unavailableWith(linuxMutterName, "display-server-unsupported", e.msg, evalRemedy)
    raise failed(e.msg)

proc windowJs(id, action: string): string =
  "(() => { const w = global.get_window_actors().map(a => a.meta_window)" &
    ".find(w => String(w.get_id()) === '" & requireMetaId(id) & "'); " &
    "if (!w) return false; " & action & "; return true; })()"

proc evalWindow(cfg: LinuxInputConfig, id, action: string) =
  let found = cfg.shellEval(windowJs(id, action))
  if found.kind != JBool or not found.getBool:
    raise newBackendError(BackendNotFoundError, linuxMutterName, "window",
      "no window '" & id & "' in this session")

# ---------------------------------------------------------------------------
# Features
# ---------------------------------------------------------------------------

proc mutterFeatures(cfg: LinuxInputConfig, probe: bool): seq[Feature] =
  var input, windows: tuple[state: FeatureState, reason, remedy: string]
  try:
    cfg.requireEnv(linuxMutterName, ["DBUS_SESSION_BUS_ADDRESS"], "GNOME session",
                   mutterRemedy)
    if probe:
      var c = cfg.connect()
      try:
        let types = try: c.call(rdName, rdPath, propsIface, "Get",
                                [dstr(rdName), dstr("SupportedDeviceTypes")],
                                timeoutMs = callTimeoutMs)[0].unwrap.asInt
                    except DbusCallError as e: raise unsupported(e)
                    except DbusError as e: raise failed(e.msg)
        if (types and 3) != 3:
          raise unavailableWith(linuxMutterName, "display-server-unsupported",
            "Mutter's remote desktop offers no virtual keyboard and pointer", mutterRemedy)
        let (mons, _) = c.monitors()
        var connectors: seq[string]
        if mons.len > 0: connectors.add mons[0].connector
        if connectors.len > 0: cfg.requirePipewire()
        var r = c.open(connectors)
        r.close()
      finally:
        c.close()
      input = (fsSupported, "", "")
    else:
      input = (fsAvailable, "", "")
  except BackendError as e:
    input = problemOf(e)
  try:
    if probe: discard cfg.shellEval("1")
    else: cfg.requireEnv(linuxMutterName, ["DBUS_SESSION_BUS_ADDRESS"], "GNOME session",
                         evalRemedy)
    windows = ((if probe: fsSupported else: fsAvailable), "", "")
  except BackendError as e:
    windows = problemOf(e)
  inputFeatures(linuxMutterName, input, input, windows)

proc newLinuxMutterInput*(cfg: LinuxInputConfig): InputBackend =
  ## The `linux-mutter` input backend for the invocation `cfg`.
  when not defined(linux):
    return wrongPlatformInput(linuxMutterName)
  else:
    result.name = linuxMutterName
    result.move = proc (session: string, to: Point): InputReport =
      cfg.runPlan(planMove(to))
      moveReport(session, to)
    result.click = proc (session: string, at: Point, button: MouseButton, count: int,
                         modifiers: seq[string]): InputReport =
      cfg.runPlan(planClick(at, button, count, modifiers, modifierSettleMs))
      clickReport(session, at, button, count, modifiers)
    result.drag = proc (session: string, path: seq[Point], button: MouseButton,
                        steps, durationMs: int): InputReport =
      cfg.runPlan(planDrag(path, button, steps, durationMs))
      dragReport(session, path, button)
    result.scroll = proc (session: string, at: Point, dx, dy: int,
                          unit: ScrollUnit): InputReport =
      cfg.runPlan(planScroll(at, dx, dy, unit))
      scrollReport(session, at)
    result.typeText = proc (session, text: string, intervalMs: int): InputReport =
      let ops = try: planType(text, intervalMs)
                except InputPlanError as e:
                  raise unavailableWith(linuxMutterName, "unsupported-option", e.msg,
                    "type the text without the control character")
      cfg.runPlan(ops)
      typeReport(session, text)
    result.key = proc (session, combo: string): InputReport =
      cfg.runPlan(planKey(combo))
      keyReport(session, combo)
    result.focusWindow = proc (session, windowId: string): Window =
      cfg.evalWindow(windowId, "w.activate(global.get_current_time())")
      cfg.settledWindow(linuxMutterName, windowId, proc (w: Window): bool = w.focused)
    result.setWindowBounds = proc (session, windowId: string, bounds: Rect): Window =
      if bounds.width < 1 or bounds.height < 1:
        raise failed("a window cannot be smaller than 1x1")
      cfg.evalWindow(windowId, "w.move_resize_frame(true, " & $bounds.x & ", " & $bounds.y &
                     ", " & $bounds.width & ", " & $bounds.height & ")")
      cfg.settledWindow(linuxMutterName, windowId, proc (w: Window): bool = w.bounds == bounds)
    result.features = proc (probe: bool): seq[Feature] = cfg.mutterFeatures(probe)
