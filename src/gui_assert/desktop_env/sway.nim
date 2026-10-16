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
import ../desktop_env, ./helpers, ./session_bus

type
  SwayTarget* = ref object of TargetEnvironment
    width*, height*: int
    floatingAppIds*: seq[string]
      ## App ids sway floats on map (a `for_window … floating enable` rule),
      ## so a scenario can move and resize them. Tiled otherwise.
    runtimeDir: string
    swaySock: string
    sway: Process
    pointer: Process
    bus: SessionBus
    facts: Table[string, Fact]
    probed: bool

proc newSwayTarget*(width = 1920; height = 1080;
                    floatingAppIds: seq[string] = @[]): SwayTarget =
  SwayTarget(name: "sway", width: width, height: height,
             floatingAppIds: floatingAppIds,
             sessionEnv: newStringTable(modeCaseSensitive))

proc swayConfig(t: SwayTarget): string =
  # No `bg`: sway hands it to `swaybg` and waits for that before opening
  # its socket, so a missing `swaybg` is a hang. The headless output is
  # black without it.
  result = "output HEADLESS-1 {\n  mode " & $t.width & "x" & $t.height &
           "@60Hz\n  pos 0 0\n}\n" &
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

method start*(t: SwayTarget) =
  if t.started: return
  # Under /tmp, not $TMPDIR: sway's IPC socket
  # (`<runtime>/sway-ipc.<uid>.<pid>.sock`) must fit `sun_path` (108 bytes),
  # and a nix-shell TMPDIR plus a temp-dir name can exceed it — sway then
  # refuses to start ("Socket path won't fit into ipc_sockaddr->sun_path").
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
  try:
    t.pointer = startProcess(helper("virtual_pointer"),
                             args = @[$t.width, $t.height], options = {})
  except OSError as e:
    raise t.envError("start", "the pointer helper: " & e.msg)
  var line: string
  if not t.pointer.outputStream.readLine(line) or line != "ready":
    raise t.envError("start", "the pointer helper did not start: " & line)
  t.started = true

method stop*(t: SwayTarget) =
  t.stopSpawned()
  if t.pointer != nil:
    try:
      t.pointer.inputStream.writeLine("quit")
      t.pointer.inputStream.flush()
      discard t.pointer.waitForExit(2000)
    except IOError, OSError: discard
    t.pointer.close()
    t.pointer = nil
  t.bus.stop()
  if t.sway != nil:
    if t.sway.running:
      t.sway.terminate()
      discard t.sway.waitForExit(3000)
      if t.sway.running: t.sway.kill()
    t.sway.close()
    t.sway = nil
  if t.runtimeDir.len > 0:
    try: removeDir(t.runtimeDir)
    except OSError: discard
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

method wheel*(t: SwayTarget; notches: int) =
  t.pointerCommand("wheel " & $notches, "wheel")

proc wtype(t: SwayTarget; args: seq[string]; operation: string) =
  let (output, code) = execCmdEx(quoteShellCommand(@["wtype"] & args))
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

proc probe(t: SwayTarget; args: varargs[string]): JsonNode =
  let (output, code) = execCmdEx(quoteShellCommand(@[helper("wm_probe")] & @args))
  if code != 0: raise t.envError("probe " & args.join(" "), output.strip())
  try: parseJson(output.strip().splitLines()[^1])
  except JsonParsingError, IndexDefect:
    raise t.envError("probe " & args.join(" "), "unreadable output: " & output)

proc measureFacts(t: SwayTarget) =
  if t.probed: return
  let chosen = t.probe()
  let asked = t.probe("client")
  let askedFloating = t.probe("client", "fixed")
  let mapped = t.probe("map")
  proc put(name, value: string; prov: FactProvenance; detail: string) =
    t.facts[name] = Fact(name: name, value: value, provenance: prov, detail: detail)
  put("decorations.default", chosen["decoration_mode"].getStr, fpMeasured,
      "the mode a window that asks for none is granted")
  let honoured =
    if asked["decoration_mode"].getStr == "client": "always"
    elif askedFloating["decoration_mode"].getStr == "client": "floating-only"
    else: "never"
  put("decorations.honoursClientRequest", honoured, fpMeasured,
      "client-side requested by a tiled and by a floating window")
  var caps: seq[string]
  for c in chosen["capabilities"]: caps.add c.getStr
  let reported = chosen["capabilities_reported"].getBool
  put("window.capabilities", caps.join(","), fpMeasured,
      if reported: "xdg_toplevel.wm_capabilities" else: "not reported: all assumed")
  proc advertised(c: string): string = $(not reported or c in caps)
  put("window.canMinimize", advertised("minimize"), fpMeasured,
      "advertised by wm_capabilities; a client cannot observe the minimized state")
  put("window.hasWindowMenu", advertised("window_menu"), fpMeasured,
      "advertised by wm_capabilities")
  put("window.canMaximize", $mapped["maximize_honoured"].getBool, fpMeasured,
      "a mapped floating window asked to maximize")
  put("window.canFullscreen", $mapped["fullscreen_honoured"].getBool, fpMeasured,
      "a mapped floating window asked to go fullscreen")
  put("window.floatingByDefault", "false", fpDeclared,
      "sway tiles a window unless a rule or a fixed size floats it")
  put("window.reportsMinimized", "false", fpDeclared,
      "sway has no minimized state to report")
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

method configure*(t: SwayTarget; setting, value: string) =
  let key = case setting
    of "buttonLayout": "button-layout"
    of "doubleClickTitlebar": "action-double-click-titlebar"
    else: raise t.envError("configure " & setting, "unknown setting")
  try: discard t.bus.gsettings("set", "org.gnome.desktop.wm.preferences", key, value)
  except OSError as e: raise t.envError("configure " & setting, e.msg)
  # The portal re-reads the keyfile on change; wait until it serves the
  # new value, so the application under test can be told.
  t.waitUntil("the settings portal serving " & setting & "=" & value, proc(): bool =
    let (output, code) = t.bus.readSetting("org.gnome.desktop.wm.preferences", key)
    code == 0 and ("'" & value & "'") in output)
