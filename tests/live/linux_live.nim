## Shared support of the Linux live suites (`tests/live/tcapture_linux.nim`,
## capture, and `tests/live/tocr_linux.nim`, OCR over captures): the private
## display servers they start (headless sway, headless GNOME Shell, Xvfb, and
## the portal stack of PipeWire, WirePlumber and xdg-desktop-portal with its
## wlroots backend on a private sway), the fixture windows, the environment a
## `guiassert` run gets, and reading what a run left behind.
##
## Every server is the run's own: a private runtime directory, a private
## session bus, nothing connected to the operator's display. A server that
## cannot start FAILS the test that needs it, with `GS5-LINUX BLOCKED:` and
## the reason (never a skip).

import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, times, unittest]
from std/posix import nil

import ../contract/harness
import ../../src/gui_assert/desktop_env
import ../../src/gui_assert/desktop_env/[helpers, sway, gnome, session_bus]
import ../../src/gui_assert/core/png

export desktop_env, sway, gnome

const sessionVars = ["WAYLAND_DISPLAY", "DISPLAY", "SWAYSOCK", "DBUS_SESSION_BUS_ADDRESS",
                     "XDG_RUNTIME_DIR", "XDG_CURRENT_DESKTOP", "XDG_SESSION_TYPE",
                     "XDG_CONFIG_HOME", "XDG_DESKTOP_PORTAL_DIR", "GSETTINGS_BACKEND",
                     "GSETTINGS_SCHEMA_DIR"]
  ## What a `guiassert` run must not inherit from the operator's session.

# ---------------------------------------------------------------------------
# The run's own processes
# ---------------------------------------------------------------------------

const runTagVar = "GA_LIVE_SUITE_RUN"
  ## Set in this process's environment when the module loads. Every server,
  ## helper and `guiassert` run a suite starts inherits it (each environment
  ## here is built from this process's), and so does whatever those start in
  ## turn (dbus-run-session's bus, a bus-activated service), so a process
  ## that carries this run's value was started by this run, however it was
  ## reparented. Not a GUIASSERT_* name: `harness.baseEnv` drops those.

let runTag = "run-" & $getCurrentProcessId() & "-" & $(epochTime() * 1000).int64
putEnv(runTagVar, runTag)

proc ownProcesses*(): seq[(int, string)] =
  ## The live processes other than this one whose environment carries this
  ## run's tag, with their names (proc(5): `/proc/<pid>/environ`, `comm`,
  ## `stat`; zombies excluded).
  let me = getCurrentProcessId()
  let needle = runTagVar & "=" & runTag
  for kind, path in walkDir("/proc"):
    let pid = try: parseInt(path.extractFilename) except ValueError: 0
    if pid <= 0 or pid == me: continue
    try:
      if needle notin readFile(path / "environ").split('\0'): continue
      let stat = readFile(path / "stat")
      let close = stat.rfind(')')
      if close < 0 or stat[close + 1 .. ^1].strip.startsWith("Z"): continue
      result.add (pid, readFile(path / "comm").strip)
    except IOError, OSError:
      discard   # gone meanwhile, or not ours to read

proc killProcesses*(processes: seq[(int, string)]) =
  ## SIGKILL each of `processes` (pids from `ownProcesses`).
  for (pid, _) in processes: discard posix.kill(posix.Pid(pid), posix.SIGKILL)

template checkLeavesNoProcess*() =
  ## Inside a test run after every server was stopped: fails the test when
  ## anything this run started is still running 10 s later (processes that
  ## were signalled may take a moment to exit), naming each, and then kills
  ## them so a failing run leaves nothing behind either.
  block:
    var left = ownProcesses()
    let deadline = epochTime() + 10
    while left.len > 0 and epochTime() < deadline:
      sleep(100)
      left = ownProcesses()
    if left.len > 0: checkpoint "still running: " & $left
    check left.len == 0
    killProcesses(left)

proc blocked*(reason: string): ref AssertionDefect =
  newException(AssertionDefect, "GS5-LINUX BLOCKED: " & reason)

proc requireExe*(name: string): string =
  result = findExe(name)
  if result.len == 0:
    raise blocked("'" & name & "' is not on the PATH (run inside GuiAssert's `nix develop`)")

proc requireEnvPath*(name: string): string =
  result = getEnv(name)
  if result.len == 0 or not fileExists(result):
    raise blocked(name & " is not set to an existing file (run inside GuiAssert's `nix develop`)")

proc runEnv*(stateDir: string, session: StringTableRef,
             extra: openArray[(string, string)] = []): StringTableRef =
  ## The environment of a `guiassert` run in `session`: the caller's without
  ## any GUIASSERT_* variable (harness rule) and without the operator's own
  ## display, bus and desktop variables, plus the session's, plus the state
  ## directory.
  result = baseEnv()
  for k in sessionVars: result.del(k)
  for k, v in session: result[k] = v
  result["GUIASSERT_STATE_DIR"] = stateDir
  for (k, v) in extra: result[k] = v

# ---------------------------------------------------------------------------
# Running the binary
# ---------------------------------------------------------------------------

proc run*(args: seq[string], env: StringTableRef, timeoutMs = 90_000):
    tuple[exit: int, env: JsonNode, stderr: string] =
  let r = runCli(args, env, timeoutMs = timeoutMs)
  (r.exit, envelopeOf(r), r.stderr)

proc ok*(args: seq[string], env: StringTableRef): JsonNode =
  let (x, e, err) = run(args, env)
  if x != 0:
    checkpoint "guiassert " & args.join(" ") & " -> " & $e & "\nstderr: " & err
  doAssert x == 0, "guiassert " & args.join(" ") & " exited " & $x & ": " & $e
  e["data"]

# ---------------------------------------------------------------------------
# Pixels and files
# ---------------------------------------------------------------------------

proc pixelAt*(img: PngImage, x, y: int): array[3, int] =
  let c = ord(img.channels)
  let o = (y * img.width + x) * c
  if c >= 3: [ord(img.pixels[o]), ord(img.pixels[o + 1]), ord(img.pixels[o + 2])]
  else: [ord(img.pixels[o]), ord(img.pixels[o]), ord(img.pixels[o])]

proc near*(px, want: array[3, int], tolerance = 6): bool =
  for i in 0 .. 2:
    if abs(px[i] - want[i]) > tolerance: return false
  true

proc fractionNear*(img: PngImage, want: array[3, int], x0, y0, x1, y1: int): float =
  ## The fraction of pixels in [x0, x1) x [y0, y1) near `want`.
  var n, hit = 0
  for y in countup(y0, y1 - 1, 2):
    for x in countup(x0, x1 - 1, 2):
      inc n
      if near(img.pixelAt(x, y), want): inc hit
  if n == 0: 0.0 else: hit / n

proc loadPng*(path: string): PngImage = decodePng(readFile(path))

proc ffprobeVideo*(path: string): tuple[frames, width, height: int, durationMs: int] =
  ## The video stream of `path` as ffprobe counts it (decoding every frame).
  let ffprobe = getEnv("FFPROBE", "ffprobe")
  let (o, code) = execCmdEx(quoteShellCommand([ffprobe, "-v", "error", "-count_frames",
    "-select_streams", "v:0", "-show_entries", "stream=nb_read_frames,width,height,duration",
    "-of", "json", path]))
  doAssert code == 0, "ffprobe failed on " & path & ": " & o
  let s = parseJson(o)["streams"][0]
  (parseInt(s["nb_read_frames"].getStr), s["width"].getInt, s["height"].getInt,
   int(parseFloat(s["duration"].getStr) * 1000 + 0.5))

proc partialSiblings*(outPath: string): seq[string] =
  ## Temp-and-rename leftovers next to `outPath`.
  for k, p in walkDir(outPath.parentDir):
    if p.extractFilename.startsWith("." & outPath.extractFilename & ".partial"): result.add p

proc stateFilesText*(stateDir: string): string =
  ## Every file under the state directory, concatenated (for "no captured
  ## content in state records").
  for p in walkDirRec(stateDir):
    try: result.add readFile(p)
    except IOError: discard

proc recorderPid*(stateDir, id: string): int =
  parseJson(readFile(stateDir / "recordings" / (id & ".json")))["private"]["pid"].getInt

proc nonce*(): string = "Gx" & $getCurrentProcessId() & "t" & $(epochTime() * 1000).int64

proc slowX264Shim*(dir: string): string =
  ## `tests/live/slow_x264.c` compiled into `dir`: an LD_PRELOAD library that
  ## delays one libx264 encode call (an encoder latency spike; see the file).
  let cc = requireExe("cc")
  result = dir / "slow_x264.so"
  let (o, code) = execCmdEx(quoteShellCommand([cc, "-shared", "-fPIC", "-O1", "-Wall",
    "-Werror", "-o", result, currentSourcePath().parentDir / "slow_x264.c", "-ldl"]))
  if code != 0: raise blocked("the encoder-stall injector did not compile: " & o.strip)

# ---------------------------------------------------------------------------
# Servers
# ---------------------------------------------------------------------------

proc startTarget*(t: TargetEnvironment) =
  try: t.start()
  except EnvError as e: raise blocked("the private " & t.name & " did not start: " & e.msg)

proc waitPidWindow*(t: TargetEnvironment, pid: int): EnvWindow =
  ## The compositor's own report of the window of `pid`, once it is mapped.
  t.waitUntil("window of pid " & $pid, proc(): bool =
    for w in t.windows():
      if w.pid == pid and w.rect.w > 0: return true
    false, initDuration(seconds = 20))
  for w in t.windows():
    if w.pid == pid: return w

proc probeWindow*(t: TargetEnvironment, rgb: string, title: string, holdMs = 900_000,
                  pulse = false, image = ""): Process =
  ## wm_probe's mapped 320x200 window of colour `rgb`, titled `title`; with
  ## `image` (a binary PPM), a window of the image's size showing it instead.
  var args = @[helper("wm_probe"), "title=" & title, "map",
               (if image.len > 0: "image=" & image else: "rgb=" & rgb), "hold=" & $holdMs]
  if pulse: args.add "pulse"
  t.spawn(args)

type
  Xvfb* = object
    process*: Process
    display*: string         ## ":<n>"
    env*: StringTableRef
    width*, height*: int

proc startXvfb*(width, height: int): Xvfb =
  ## A private Xvfb on the first free display number from 90, listening on
  ## no TCP port.
  let exe = requireExe("Xvfb")
  for n in 90 .. 140:
    if fileExists("/tmp/.X" & $n & "-lock") or pathExists("/tmp/.X11-unix/X" & $n): continue
    let p = startProcess(exe, args = [":" & $n, "-screen", "0", $width & "x" & $height & "x24",
      "-nolisten", "tcp", "-noreset"], options = {poStdErrToStdOut})
    let deadline = epochTime() + 10
    while epochTime() < deadline and p.running and not pathExists("/tmp/.X11-unix/X" & $n):
      sleep(50)
    if p.running and pathExists("/tmp/.X11-unix/X" & $n):
      result = Xvfb(process: p, display: ":" & $n, width: width, height: height,
                    env: newStringTable(modeCaseSensitive))
      result.env["DISPLAY"] = result.display
      return
    if p.running: p.kill()
    p.close()
  raise blocked("no private Xvfb could be started on displays :90..:140")

proc stop*(x: var Xvfb) =
  if x.process != nil:
    if x.process.running:
      x.process.terminate()
      discard x.process.waitForExit(3000)
      if x.process.running: x.process.kill()
    x.process.close()
    x.process = nil

proc x11Window*(x: Xvfb, geometry, rgb, title: string, holdMs = 900_000, image = ""):
    tuple[process: Process, id: string] =
  ## x11_probe's window of colour `rgb` at `geometry` (`WxH+X+Y`); with
  ## `image` (a binary PPM of the geometry's size), showing the image instead.
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs(): env[k] = v
  env["DISPLAY"] = x.display
  let p = startProcess(helper("x11_probe"), args = ["window", "--geometry", geometry,
    (if image.len > 0: "--image" else: "--rgb"), (if image.len > 0: image else: rgb),
    "--title", title, "--hold", $holdMs], env = env, options = {})
  var line: string
  if not p.outputStream.readLine(line):
    raise blocked("x11_probe's window did not open on " & x.display)
  (p, $parseJson(line)["id"].getBiggestInt)

proc stopProcess*(p: Process) =
  if p == nil: return
  try:
    if p.running:
      p.terminate()
      discard p.waitForExit(3000)
      if p.running: p.kill()
    p.close()
  except OSError: discard

type
  PortalStack* = object
    ## PipeWire, WirePlumber, xdg-desktop-portal-wlr and xdg-desktop-portal,
    ## on a private sway's session bus.
    processes*: seq[Process]
    logs*: string

proc launchLogged(env: StringTableRef, exe: string, args: seq[string], log: string): Process =
  startProcess("/bin/sh", args = @["-c", "exec " & quoteShellCommand(@[exe] & args) &
    " >" & quoteShell(log) & " 2>&1"], env = env, options = {})

proc startPortalStack*(t: SwayTarget): PortalStack =
  ## The ScreenCast portal on the target's private bus: the frontend is
  ## restarted (`--replace`) with the wlroots backend preferred for
  ## ScreenCast and Screenshot, and the wlroots backend is configured to pick
  ## the headless output without a chooser.
  let portal = requireEnvPath("GUI_ASSERT_XDG_DESKTOP_PORTAL")
  let portalWlr = requireEnvPath("GUI_ASSERT_XDG_DESKTOP_PORTAL_WLR")
  let portalGtk = requireEnvPath("GUI_ASSERT_XDG_DESKTOP_PORTAL_GTK")
  let pipewire = requireExe("pipewire")
  let wireplumber = requireExe("wireplumber")
  let runtime = t.sessionEnv["XDG_RUNTIME_DIR"]
  let config = t.sessionEnv["XDG_CONFIG_HOME"]
  result.logs = runtime
  createDir(config / "xdg-desktop-portal-wlr")
  writeFile(config / "xdg-desktop-portal-wlr" / "config",
    "[screencast]\nchooser_type=none\noutput_name=HEADLESS-1\nmax_fps=30\n")
  writeFile(config / "xdg-desktop-portal" / "portals.conf",
    "[preferred]\ndefault=gtk\norg.freedesktop.impl.portal.ScreenCast=wlr\n" &
    "org.freedesktop.impl.portal.Screenshot=wlr\n")
  let portalsDir = runtime / "portals"
  createDir(portalsDir)
  for (exe, file) in [(portalGtk, "gtk.portal"), (portalWlr, "wlr.portal")]:
    let src = exe.parentDir.parentDir / "share" / "xdg-desktop-portal" / "portals" / file
    if not fileExists(src): raise blocked("the portal definition " & src & " does not exist")
    createSymlink(src, portalsDir / file)
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs(): env[k] = v
  for k in ["DISPLAY"]: env.del(k)
  for k, v in t.sessionEnv: env[k] = v
  env["XDG_DESKTOP_PORTAL_DIR"] = portalsDir
  env["XDG_STATE_HOME"] = runtime / "state"
  env["XDG_DATA_HOME"] = runtime / "data"
  result.processes.add launchLogged(env, pipewire, @[], runtime / "pipewire.log")
  let deadline = epochTime() + 10
  while not pathExists(runtime / "pipewire-0"):
    if epochTime() > deadline:
      raise blocked("PipeWire did not start: " & readFile(runtime / "pipewire.log"))
    sleep(50)
  result.processes.add launchLogged(env, wireplumber, @[], runtime / "wireplumber.log")
  result.processes.add launchLogged(env, portalWlr, @[], runtime / "xdpw.log")
  sleep(300)
  result.processes.add launchLogged(env, portal, @["--replace"], runtime / "xdp.log")
  # Ready when the frontend answers for the ScreenCast interface.
  while true:
    let (o, code) = execCmdEx(quoteShellCommand(["gdbus", "call", "--session", "-d",
      "org.freedesktop.portal.Desktop", "-o", "/org/freedesktop/portal/desktop", "-m",
      "org.freedesktop.DBus.Properties.Get", "org.freedesktop.portal.ScreenCast", "version"]),
      env = env)
    if code == 0 and "uint32" in o: break
    if epochTime() > deadline + 10:
      raise blocked("the ScreenCast portal did not answer: " & o.strip)
    sleep(200)

proc stop*(s: var PortalStack) =
  for i in countdown(s.processes.high, 0): stopProcess(s.processes[i])
  s.processes.setLen 0

proc freshRuntimeDir*(): string =
  ## A short private directory under /tmp (sockets must fit `sun_path`).
  result = createTempDir("gacl-", "", "/tmp")
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})
