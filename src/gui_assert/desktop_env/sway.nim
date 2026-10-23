## The headless sway target.
##
## A private sway on a headless output, with a private runtime directory, a
## private session bus serving desktop settings (`session_bus`), a pointer DEVICE
## (`virtual_pointer`, wlroots' virtual-pointer protocol), keys through
## `wtype` (the virtual-keyboard protocol), frames through `grim`
## (wlr-screencopy) and window readback through sway's IPC (`get_tree`).
##
## Facts are MEASURED from the running compositor where a client can observe
## them, with `wm_probe`: the decoration mode a window is granted, whether a
## client-side request is honoured (sway: only for a floating window), the
## capabilities `xdg_toplevel.wm_capabilities` advertises, and whether a
## maximize or fullscreen request on a mapped window takes effect (sway
## advertises maximize and ignores it for a floating window, and honours
## fullscreen without advertising it — measured 2026-10-16, sway 1.11).
##
## Sway IPC: https://man.archlinux.org/man/sway-ipc.7

import std/[json, os, osproc, streams, strtabs, strutils, tables, tempfiles, times]
from std/posix import nil
import ../desktop_env, ./helpers, ./runtime_dir, ./session_bus, ./wayland_probe

type
  SwayTarget* = ref object of TargetEnvironment
    width*, height*: int
      ## The headless output's mode, in physical pixels.
    scale*: float
      ## The headless output's scale (physical pixels per logical pixel);
      ## its logical size is the mode divided by it. 1 unless asked.
    floatingAppIds*: seq[string]
      ## App ids sway floats on map (a `for_window … floating enable` rule),
      ## so a scenario can move and resize them. Tiled otherwise.
    runtimeDir: string
    presetRuntimeDir: string
      ## The runtime directory `start` uses instead of making one (see
      ## `newSwayTarget`), "" for a fresh one.
    endClients: bool
      ## Whether `stop` ends every process still naming the runtime
      ## directory (`newSwayTarget`).
    swaySock: string
    sway: Process
    pointer: Process
    bus: SessionBus
    facts: Table[string, Fact]
    probed: bool

proc newSwayTarget*(width = 1920; height = 1080;
                    floatingAppIds: seq[string] = @[]; scale = 1.0;
                    runtimeDir = ""; endClients = true): SwayTarget =
  ## A private headless sway. `runtimeDir`, when given, is the directory
  ## (an existing one or one to create, mode 0700) the session runs in,
  ## instead of a fresh `/tmp/guienv-*`: a caller that must be able to
  ## remove it after a crash names it before anything is started in it.
  ## `stop` removes it either way (`runtime_dir.removeRuntimeTree`), and
  ## with `endClients` first ends every process of this user that still
  ## names it as its `XDG_RUNTIME_DIR` (the session's own helpers and the
  ## clients started into it); a caller that ends the session's processes
  ## itself, by its own rule, passes false.
  SwayTarget(name: "sway", width: width, height: height, scale: scale,
             floatingAppIds: floatingAppIds, presetRuntimeDir: runtimeDir,
             endClients: endClients, sessionEnv: newStringTable(modeCaseSensitive))

proc outputScale(t: SwayTarget): float =
  ## `scale`, or 1 for a target built without one (`attachSwayTarget`).
  if t.scale > 0: t.scale else: 1.0

proc swayConfig(t: SwayTarget): string =
  # No `bg`: sway hands it to `swaybg` and waits for that before opening
  # its socket, so a missing `swaybg` is a hang. The headless output is
  # black without it.
  result = "output HEADLESS-1 {\n  mode " & $t.width & "x" & $t.height &
           "@60Hz\n  pos 0 0\n  scale " & $t.outputScale & "\n}\n" &
           "default_border none\ntitlebar_border_thickness 0\n" &
           "titlebar_padding 0\nbar {\n  mode invisible\n}\n" &
           "focus_follows_mouse no\nxwayland disable\n"
  for id in t.floatingAppIds & @["gui-assert-wm-probe"]:
    result.add "for_window [app_id=\"" & id & "\"] floating enable\n"

proc swaymsg(t: SwayTarget; args: varargs[string]): string =
  let (output, code) = execCmdEx(quoteShellCommand(
    @["swaymsg", "-s", t.swaySock] & @args))
  if code != 0:
    raise t.envError("swaymsg " & args.join(" "), output.strip())
  output

proc command*(t: SwayTarget; cmd: string) =
  ## Run a sway command (`swaymsg <cmd>`) — for a scenario that must arrange
  ## the compositor itself, e.g. `"[app_id=x] floating enable"`.
  let reply = parseJson(t.swaymsg(cmd))
  for r in reply:
    if not r{"success"}.getBool:
      raise t.envError("command " & cmd.escape, $r)

proc expectLine(t: SwayTarget; p: Process; operation: string) =
  ## Read the helper's acknowledgement for the command just sent.
  var line: string
  if not p.outputStream.readLine(line):
    raise t.envError(operation, "the pointer helper exited")
  if line != "ok":
    raise t.envError(operation, line)

proc attachSwayTarget*(allowConfigure = false): SwayTarget =
  ## A target for the sway session this process runs in (`SWAYSOCK`,
  ## `WAYLAND_DISPLAY`): nothing is started but the pointer device, and
  ## `stop` leaves sway alone. `configure` is refused unless
  ## `allowConfigure`, and what it changes `stop` restores.
  SwayTarget(name: "sway", attached: true, allowConfigure: allowConfigure,
             sessionEnv: newStringTable(modeCaseSensitive))

proc outputExtent(t: SwayTarget): (int, int) =
  ## The layout's extent over the active outputs: what absolute pointer
  ## positions are measured against.
  let outputs = parseJson(t.swaymsg("-t", "get_outputs", "-r"))
  for o in outputs:
    if o{"active"}.getBool:
      let r = o["rect"]
      result = (max(result[0], r["x"].getInt + r["width"].getInt),
                max(result[1], r["y"].getInt + r["height"].getInt))

proc logicalWidth(t: SwayTarget): int =
  ## The output's logical width: what absolute pointer positions span.
  int(t.width.float / t.outputScale + 0.5)

proc logicalHeight(t: SwayTarget): int = int(t.height.float / t.outputScale + 0.5)

proc startPointer(t: SwayTarget) =
  try:
    t.pointer = startProcess(helper("virtual_pointer"),
                             args = @[$t.logicalWidth, $t.logicalHeight], options = {})
  except OSError as e:
    raise t.envError("start", "the pointer helper: " & e.msg)
  var line: string
  if not t.pointer.outputStream.readLine(line) or line != "ready":
    raise t.envError("start", "the pointer helper did not start: " & line)

proc startAttached(t: SwayTarget) =
  for k in ["SWAYSOCK", "WAYLAND_DISPLAY", "XDG_RUNTIME_DIR"]:
    if getEnv(k).len == 0:
      raise t.envError("start", "cannot attach: " & k & " is not set " &
                       "(run inside the sway session)")
  t.swaySock = getEnv("SWAYSOCK")
  t.bus = attachedSessionBus()
  for k, v in t.bus.env: t.sessionEnv[k] = v
  (t.width, t.height) = t.outputExtent()
  if t.width == 0:
    raise t.envError("start", "cannot attach: sway reports no active output")
  t.startPointer()
  t.started = true

method start*(t: SwayTarget) =
  if t.started: return
  if t.attached:
    t.startAttached()
    return
  # Under /tmp, not $TMPDIR: sway's IPC socket
  # (`<runtime>/sway-ipc.<uid>.<pid>.sock`) must fit `sun_path` (108 bytes),
  # and a nix-shell TMPDIR plus a temp-dir name can exceed it — sway then
  # refuses to start ("Socket path won't fit into ipc_sockaddr->sun_path").
  if t.presetRuntimeDir.len > 0:
    t.runtimeDir = t.presetRuntimeDir
    createDir(t.runtimeDir)
  else:
    t.runtimeDir = createTempDir("guienv-", "", "/tmp")
  setFilePermissions(t.runtimeDir, {fpUserRead, fpUserWrite, fpUserExec})
  writeFile(t.runtimeDir / "sway.conf", t.swayConfig)
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if k notin ["WAYLAND_DISPLAY", "DISPLAY", "SWAYSOCK", "DBUS_SESSION_BUS_ADDRESS"]:
      env[k] = v
  env["XDG_RUNTIME_DIR"] = t.runtimeDir
  env["WLR_BACKENDS"] = "headless"
  env["WLR_RENDERER"] = getEnv("WLR_RENDERER", "pixman")
  env["WLR_LIBINPUT_NO_DEVICES"] = "1"
  try:
    t.sway = startProcess("/bin/sh", args = @["-c", "exec sway -c " &
      quoteShell(t.runtimeDir / "sway.conf") & " >" &
      quoteShell(t.runtimeDir / "sway.log") & " 2>&1"], env = env)
  except OSError as e:
    raise t.envError("start", "cannot run sway: " & e.msg)
  let deadline = epochTime() + 10
  var socket = ""
  while socket.len == 0:
    # `walkPattern`, not `walkFiles`: the latter yields regular files only,
    # and these are sockets.
    for f in walkPattern(t.runtimeDir / "wayland-*"):
      if not f.endsWith(".lock"): socket = f.extractFilename
    for f in walkPattern(t.runtimeDir / "sway-ipc.*.sock"): t.swaySock = f
    if socket.len > 0 and t.swaySock.len > 0: break
    socket = ""
    if not t.sway.running or epochTime() > deadline:
      var listing: seq[string]
      for f in walkDir(t.runtimeDir): listing.add f.path.extractFilename
      raise t.envError("start", "sway did not start (running: " &
                       $t.sway.running & ", runtime dir: " & listing.join(" ") &
                       "):\n" & readFile(t.runtimeDir / "sway.log"))
    sleep(50)
  t.sessionEnv["XDG_RUNTIME_DIR"] = t.runtimeDir
  t.sessionEnv["WAYLAND_DISPLAY"] = socket
  t.sessionEnv["SWAYSOCK"] = t.swaySock
  # Helpers and tools run with the session's display, not the host's.
  for k in ["XDG_RUNTIME_DIR", "WAYLAND_DISPLAY", "SWAYSOCK"]:
    putEnv(k, t.sessionEnv[k])
  delEnv("DISPLAY")
  try:
    t.bus = startSessionBus(t.runtimeDir, "sway", t.sessionEnv)
  except OSError as e:
    raise t.envError("start", "the session bus: " & e.msg)
  for k, v in t.bus.env: t.sessionEnv[k] = v
  t.startPointer()
  t.started = true

proc restoreSettings(t: SwayTarget)

proc compositorPid(t: SwayTarget): int =
  ## The pid of this target's running sway, 0 when there is none. sway names
  ## its IPC socket `sway-ipc.<uid>.<pid>.sock` (sway/ipc-server.c); the pid
  ## counts only while that process runs (not a zombie) with this target's
  ## own config on its command line, so a recycled pid is never signalled.
  let parts = t.swaySock.extractFilename.split('.')
  if parts.len != 4 or parts[0] != "sway-ipc" or parts[3] != "sock": return 0
  let pid = try: parseInt(parts[2]) except ValueError: 0
  if pid <= 0: return 0
  try:
    let stat = readFile("/proc/" & $pid & "/stat")
    let close = stat.rfind(')')
    if close < 0 or stat[close + 1 .. ^1].strip.startsWith("Z"): return 0
    let cmdline = readFile("/proc/" & $pid & "/cmdline")
    if (t.runtimeDir / "sway.conf") notin cmdline.split('\0'): return 0
  except IOError, OSError:
    return 0
  pid

proc childPids(parent: int): seq[int] =
  ## The running children of `parent` (from each process's `/proc/<pid>/stat`
  ## parent field; proc(5)). Empty when there are none or /proc is unreadable.
  for kind, path in walkDir("/proc"):
    let pid = try: parseInt(path.extractFilename) except ValueError: 0
    if pid <= 0: continue
    try:
      let stat = readFile(path / "stat")
      let close = stat.rfind(')')
      if close < 0: continue
      let fields = stat[close + 1 .. ^1].splitWhitespace
      # fields[0] is the state, fields[1] the parent pid.
      if fields.len > 1 and fields[0] != "Z" and parseInt(fields[1]) == parent:
        result.add pid
    except IOError, OSError, ValueError:
      discard

method stop*(t: SwayTarget) =
  t.stopSpawned()
  t.restoreSettings()
  if t.pointer != nil:
    try:
      t.pointer.inputStream.writeLine("quit")
      t.pointer.inputStream.flush()
      discard t.pointer.waitForExit(2000)
    except IOError, OSError: discard
    t.pointer.close()
    t.pointer = nil
  if t.attached:
    t.started = false
    return
  t.bus.stop()
  if t.sway != nil:
    # The compositor itself first. Without DBUS_SESSION_BUS_ADDRESS the
    # packaged `sway` wrapper runs it under `dbus-run-session`, which does
    # not pass SIGTERM on: terminating only the started process left the
    # compositor running, reparented to init.
    #
    # dbus-run-session ends its private bus only when the program it runs
    # exits (dbus-run-session(1)); a SIGTERM to dbus-run-session itself kills
    # it with the default action and orphans that dbus-daemon. So its
    # children (the bus and the compositor) are noted now, the compositor is
    # stopped, and dbus-run-session is given the time to end its bus and
    # exit by itself. Only if it does not are the noted children still
    # under it signalled before it is.
    let wrapperChildren = childPids(t.sway.processID)
    let compositor = compositorPid(t)
    if compositor > 0:
      discard posix.kill(posix.Pid(compositor), posix.SIGTERM)
      let deadline = epochTime() + 3
      while compositorPid(t) == compositor and epochTime() < deadline: sleep(20)
      if compositorPid(t) == compositor:
        discard posix.kill(posix.Pid(compositor), posix.SIGKILL)
    if compositor > 0: discard t.sway.waitForExit(3000)
    if t.sway.running:
      # Still the parent of each child it has not reaped, so none of these
      # pids can have been reused by an unrelated process.
      let remaining = childPids(t.sway.processID)
      for child in wrapperChildren:
        if child in remaining:
          discard posix.kill(posix.Pid(child), posix.SIGTERM)
      let deadline = epochTime() + 3
      while t.sway.running and childPids(t.sway.processID).len > 0 and
          epochTime() < deadline:
        sleep(20)
    if t.sway.running:
      t.sway.terminate()
      discard t.sway.waitForExit(3000)
      if t.sway.running: t.sway.kill()
    t.sway.close()
    t.sway = nil
  if t.runtimeDir.len > 0:
    removeRuntimeTree(t.runtimeDir, endProcesses = t.endClients)
  t.started = false

proc pointerCommand(t: SwayTarget; cmd, operation: string) =
  if not t.started: raise t.envError(operation, "the target is not started")
  try:
    t.pointer.inputStream.writeLine(cmd)
    t.pointer.inputStream.flush()
  except IOError, OSError:
    raise t.envError(operation, "the pointer helper is gone")
  t.expectLine(t.pointer, operation)

method pointerMove*(t: SwayTarget; x, y: int) =
  t.pointerCommand("abs " & $x & " " & $y, "pointerMove")

method pointerButton*(t: SwayTarget; button: PointerButton; pressed: bool) =
  t.pointerCommand((if pressed: "down " else: "up ") & $button, "pointerButton")

method settleGrab*(t: SwayTarget; at: (int, int)) =
  ## Sway applies a floating window's interactive resize from a pointer
  ## motion that arrives while the window still owes it a commit only on the
  ## NEXT pointer event. A drag that ends on such motions leaves the window
  ## short. Measured on sway 1.11 with a GPUI window, tracing every configure
  ## it was sent: for a 40px drag in ten 4px steps, sway's configures stopped
  ## at +36px; under load, at +28px; one more motion at the same point
  ## produced the next configure.
  ##
  ## So the last position is sent again until the windows sway reports stop
  ## changing between two repeats — as many repeats as the client needs to
  ## catch up, which a fixed count cannot know. Bounded at 40 repeats (4 s).
  proc snapshot(): seq[Rect] =
    for w in t.windows(): result.add w.rect
  var last = snapshot()
  var unchanged = 0
  for _ in 1 .. 40:
    sleep(50)
    t.pointerMove(at[0], at[1])
    sleep(50)
    let now = snapshot()
    if now == last:
      inc unchanged
      if unchanged == 2: return
    else:
      unchanged = 0
    last = now

method placeWindow*(t: SwayTarget; w: EnvWindow; x, y: int) =
  t.command("[pid=" & $w.pid & "] move position " & $x & " " & $y)

method setFullscreen*(t: SwayTarget; w: EnvWindow; on: bool) =
  t.command("[pid=" & $w.pid & "] fullscreen " & (if on: "enable" else: "disable"))

method focusWindow*(t: SwayTarget; w: EnvWindow) =
  t.command("[pid=" & $w.pid & "] focus")

method wheel*(t: SwayTarget; notches: int) =
  t.pointerCommand("wheel " & $notches, "wheel")

proc wtype(t: SwayTarget; args: seq[string]; operation: string) =
  ## Every `wtype` call creates a new virtual keyboard, and a client is sent
  ## that keyboard's keymap only once it appears: keys sent at once can
  ## arrive before the keymap and be dropped. Measured with a GPUI window on
  ## this target: an unprimed `wtype v` reached nothing. So a shift tap goes
  ## first, and the keys follow 400 ms later (the priming isonim-gpui's and
  ## CodeTracer's window lanes established).
  let primed = @["-M", "shift", "-m", "shift", "-s", "400"] & args
  let (output, code) = execCmdEx(quoteShellCommand(@["wtype"] & primed))
  if code != 0: raise t.envError(operation, output.strip())

method keys*(t: SwayTarget; chord: string) =
  ## `ctrl+shift+t`: modifiers held with -M/-m around the key (wtype's
  ## modifier names: shift, capslock, ctrl, logo, win, alt, altgr).
  let parts = chord.split('+')
  var args: seq[string]
  for m in parts[0 ..< ^1]: args.add @["-M", m]
  args.add @["-k", parts[^1]]
  for i in countdown(parts.len - 2, 0): args.add @["-m", parts[i]]
  t.wtype(args, "keys " & chord)

method typeText*(t: SwayTarget; text: string) =
  t.wtype(@["--", text], "typeText")

method capture*(t: SwayTarget; region: Rect): RgbImage =
  let (output, code) = execCmdEx(quoteShellCommand(["grim", "-t", "ppm", "-g",
    $region.x & "," & $region.y & " " & $region.w & "x" & $region.h, "-"]))
  if code != 0: raise t.envError("capture", output.strip())
  try: decodePpm(output)
  except ValueError as e: raise t.envError("capture", e.msg)

proc collectWindows(node: JsonNode; floating: bool; acc: var seq[EnvWindow]) =
  let isView = node{"type"}.getStr in ["con", "floating_con"] and
               (node{"app_id"}.kind == JString or node{"window_properties"} != nil)
  if isView and node{"pid"}.getInt > 0:
    let r = node["rect"]
    var w = EnvWindow(appId: node{"app_id"}.getStr, title: node{"name"}.getStr,
                      pid: node{"pid"}.getInt, focused: node{"focused"}.getBool,
                      rect: Rect(x: r["x"].getInt, y: r["y"].getInt,
                                 w: r["width"].getInt, h: r["height"].getInt))
    w.states.incl(if floating: wsFloating else: wsTiled)
    if node{"fullscreen_mode"}.getInt > 0: w.states.incl wsFullscreen
    acc.add w
  for child in node{"nodes"}: collectWindows(child, floating, acc)
  for child in node{"floating_nodes"}: collectWindows(child, true, acc)

method windows*(t: SwayTarget): seq[EnvWindow] =
  if not t.started: raise t.envError("windows", "the target is not started")
  let tree = try: parseJson(t.swaymsg("-t", "get_tree", "-r"))
             except JsonParsingError as e: raise t.envError("windows", e.msg)
  collectWindows(tree, false, result)

# ---------------------------------------------------------------------------
# Facts
# ---------------------------------------------------------------------------

proc measureFacts(t: SwayTarget) =
  if t.probed: return
  measureWaylandFacts(t, t.facts)
  proc put(name, value: string; detail: string) =
    t.facts[name] = Fact(name: name, value: value, provenance: fpDeclared, detail: detail)
  put("window.floatingByDefault", "false",
      "sway tiles a window unless a rule or a fixed size floats it")
  put("window.reportsMinimized", "false", "sway has no minimized state to report")
  t.probed = true

proc settingFact(t: SwayTarget; name, key: string): Fact =
  let value = try: t.bus.gsettings("get", "org.gnome.desktop.wm.preferences", key)
              except OSError as e: raise t.envError("fact " & name, e.msg)
  Fact(name: name, value: value.strip(chars = {'\''}), provenance: fpConfigured,
       detail: "org.gnome.desktop.wm.preferences " & key & " in this session")

method fact*(t: SwayTarget; name: string): Fact =
  if not t.started: raise t.envError("fact " & name, "the target is not started")
  case name
  of "buttonLayout": return t.settingFact(name, "button-layout")
  of "doubleClickTitlebar": return t.settingFact(name, "action-double-click-titlebar")
  else: discard
  t.measureFacts()
  if name notin t.facts:
    raise t.envError("fact " & name, "this target cannot establish it")
  t.facts[name]

method factNames*(t: SwayTarget): seq[string] =
  t.measureFacts()
  for k in t.facts.keys: result.add k
  result.add @["buttonLayout", "doubleClickTitlebar"]

proc settingKey(t: TargetEnvironment; setting: string): string =
  case setting
  of "buttonLayout": "button-layout"
  of "doubleClickTitlebar": "action-double-click-titlebar"
  else: raise t.envError("configure " & setting, "unknown setting")

proc restoreSettings(t: SwayTarget) =
  for (setting, previous) in t.changedSettings:
    try: discard t.bus.gsettings("set", "org.gnome.desktop.wm.preferences",
                                 t.settingKey(setting), previous)
    except OSError, EnvError: discard
  t.changedSettings.setLen 0

method configure*(t: SwayTarget; setting, value: string) =
  let key = t.settingKey(setting)
  t.guardConfigure(setting)
  if t.attached:
    let previous = try: t.bus.gsettings("get", "org.gnome.desktop.wm.preferences", key)
                   except OSError as e: raise t.envError("configure " & setting, e.msg)
    t.changedSettings.insert((setting, previous), 0)
  try: discard t.bus.gsettings("set", "org.gnome.desktop.wm.preferences", key, value)
  except OSError as e: raise t.envError("configure " & setting, e.msg)
  # The portal re-reads the keyfile on change; wait until it serves the
  # new value, so the application under test can be told.
  t.waitUntil("the settings portal serving " & setting & "=" & value, proc(): bool =
    let (output, code) = t.bus.readSetting("org.gnome.desktop.wm.preferences", key)
    code == 0 and ("'" & value & "'") in output)
