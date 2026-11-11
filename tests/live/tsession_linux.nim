## The Linux live session suite (GS10): the REAL `guiassert` binary starting,
## using, reconciling and stopping REAL private sessions with the
## `linux-sway`, `linux-gnome` and `linux-xvfb` session backends, and the
## `linux-host` attach check against a sway this suite starts as the
## "caller's own" session (spec §6.1, §6.3, §7.5; decisions C6, C9, C10,
## C11):
##
## * `session-start --kind headless` returns a `running` session whose
##   `env` names a private display, runtime directory, session bus and
##   AT-SPI bus, and `app-launch --session` starts a client whose window the
##   session's `windows` lists and whose pixels its `screenshot` shows (sway,
##   GNOME Shell, Xvfb);
## * Xvfb's access control: a client without the session's `XAUTHORITY` is
##   refused by the X server;
## * `--vnc` serves the session's framebuffer on 127.0.0.1 only: the
##   listener is on the loopback address and nowhere else (/proc/net/tcp and
##   tcp6), and an RFB client (`rfb_client`) reads the colour of a window
##   launched into the session at its reported position (and not before it
##   was launched); the port is closed after `session-stop`; and the VNC
##   server holds no other listening TCP socket at all (GS17: x11vnc also
##   listened on [::1]:5900);
## * `--vnc-socket` (GS17, contract 1.1) serves it on a Unix socket in the
##   session's 0700 runtime directory and nowhere on TCP: the server holds
##   the listening socket at that path and no TCP listener, an RFB client
##   over the socket reads a launched window's colour, and the socket is gone
##   after `session-stop`; `--vnc` with `--vnc-socket` is exit 2;
## * a killed session host makes `session-info` report `state: "error"`
##   with `stateReason: "host-exited"` (and a killed compositor
##   `compositor-exited`), never `running`; `session-stop` then ends every
##   process of the session;
## * C10 readiness: an AT-SPI read right after `session-start` succeeds; a
##   start whose `--timeout-ms` leaves no time for readiness is exit 5 /
##   `session-failed` before the deadline, and a host whose display server
##   exits at once is exit 5 at once, each leaving no record and no
##   process; a name in use is exit 2 / `name-in-use`;
## * C6: a GTK client the TEST spawns itself, from a polluted caller
##   environment minus `envUnset` plus `env`, appears in the session's
##   windows and tree; spawned without removing `envUnset` it does not
##   (the negative control: the polluted `GDK_BACKEND` / `DISPLAY` route it
##   away and it exits);
## * C11: `--env` reaches the launched process (its /proc environ), the
##   caller's polluted variables do not, and a windowless launch with
##   `--wait-window-ms` is exit 7 / `condition-not-met` with `details.app`,
##   still running and quittable;
## * C9: after the host dies every verb in the session is exit 4 /
##   `session-not-running` with `details.feature` null;
## * linux-host: attached to a running sway, the host session reports its
##   displays and windows and changes no compositor setting (outputs,
##   inputs, seats and configuration read back identical); with no
##   reachable display server it is `error` / `no-display-server` and its
##   application verbs are exit 4 / `session-not-running`.
##
## The last test checks that nothing this run started is still running.
##
## Run it with `just test-live-linux` (inside `nix develop`), or
## `nim c -r --hints:off tests/live/tsession_linux.nim` after `just
## build-cli`. Stand-ins: none. A server that cannot start fails the test
## that needs it with a `GS10-LINUX BLOCKED:` line; nothing here skips.

when not defined(linux):
  {.error: "tests/live/tsession_linux.nim runs on Linux only".}

import std/[json, monotimes, os, osproc, posix, sequtils, strtabs, strutils, tables, times,
            unittest]

import ../contract/harness
import ./[linux_live, rfb_client]
import ../../src/gui_assert/desktop_env/helpers as env_helpers
from ../../src/gui_assert/backends/session/linux_private import TcpSocketRow,
  taggedProcesses, parseProcNetTcp, listenersOn, tcpListenersOf, parseProcNetUnix

const
  sessionTimeoutMs = 120_000
  colourA = [210, 60, 120]     ## invented window colours
  colourB = [40, 160, 90]
  colourC = [230, 180, 30]

proc hex(c: array[3, int]): string =
  toHex(c[0], 2).toLowerAscii & toHex(c[1], 2).toLowerAscii & toHex(c[2], 2).toLowerAscii

proc gs10(msg: string): string = msg.replace("GS5-LINUX BLOCKED", "GS10-LINUX BLOCKED")

proc msSince(t: MonoTime): int = int((getMonoTime() - t).inMilliseconds)

var outputs: seq[string]
  ## Every stderr of every run (no captured content on stderr, C15).

var startedSessions: seq[tuple[st, id: string]]
  ## Every session started, stopped at the end even when a test failed.

var launched: seq[int]
  ## Every process a test spawned itself, killed at the end.

template mustRun(args: seq[string], env: StringTableRef): JsonNode =
  ## The data of a successful run. A template, so a failed `check` counts
  ## against the test.
  block:
    let r = runCli(args, env, timeoutMs = sessionTimeoutMs)
    outputs.add r.stderr
    if r.exit != 0: checkpoint "guiassert " & args.join(" ") & " -> " & r.stdout & r.stderr
    check r.exit == 0
    let e = envelopeOf(r)
    (if e["ok"].getBool: e["data"] else: newJObject())

template failsWith(args: seq[string], env: StringTableRef, code: int,
                   reason: string): JsonNode =
  block:
    let r = runCli(args, env, timeoutMs = sessionTimeoutMs)
    outputs.add r.stderr
    let e = envelopeOf(r)
    if r.exit != code: checkpoint "guiassert " & args.join(" ") & " -> " & $e & r.stderr
    check r.exit == code
    check e["ok"].getBool == false
    if e["ok"].getBool == false:
      check e["error"]["reason"].getStr == reason
      e["error"]
    else: newJObject()

proc callerEnv(st: string): StringTableRef =
  ## A caller with no display of its own (the suite's sessions are private).
  runEnv(st, newStringTable(modeCaseSensitive))

proc start(backend, st, name: string, extra: seq[string] = @[]): JsonNode =
  ## A running session, or the suite's BLOCKED line.
  let r = runCli(@["--session-backend", backend, "session-start", "--kind", "headless",
                   "--name", name] & extra, callerEnv(st), timeoutMs = sessionTimeoutMs)
  outputs.add r.stderr
  if r.exit != 0:
    let e = blocked("the " & backend & " session did not start: " & r.stdout & r.stderr)
    e.msg = gs10(e.msg)   # `blocked` names GS5; this suite is GS10's
    raise e
  startedSessions.add (st, name)
  envelopeOf(r)["data"]["session"]

proc privateOf(st, id: string): JsonNode =
  parseJson(readFile(st / "sessions" / (id & ".json")))["private"]

proc tagged(tag: string): seq[(int, string)] =
  ## The live processes of a session (its tag in their environment), each
  ## with the base name of its program (argv[0] of /proc/<pid>/cmdline; a
  ## wrapped Nix program's comm is `.<name>-wrapped`, truncated).
  for p in taggedProcesses(tag):
    var name = ""
    try: name = readFile("/proc/" & $p.pid & "/cmdline").split('\0')[0].extractFilename
    except IOError, OSError: discard
    result.add (p.pid, name)

proc envTable(s: JsonNode): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for k, v in s["env"]: result[k] = v.getStr

proc spawnInto(s: JsonNode, caller: StringTableRef, argv: seq[string],
               honourUnset = true): Process =
  ## What a caller that spawns processes itself does (spec §6.1): its own
  ## environment, minus `envUnset` (unless `honourUnset` is false, the
  ## negative control), plus `env`.
  var env = newStringTable(modeCaseSensitive)
  for k, v in caller: env[k] = v
  if honourUnset:
    for k in s["envUnset"]: env.del(k.getStr)
  for k, v in s["env"]: env[k] = v.getStr
  result = startProcess(argv[0], args = argv[1 .. ^1], env = env,
                        options = {poStdErrToStdOut})
  launched.add result.processID

proc windowOf(env: StringTableRef, session: string, pid: int, waitMs = 30_000): JsonNode =
  ## The session's report of the window of `pid`, once it lists one.
  let t0 = getMonoTime()
  while true:
    let r = runCli(@["--session", session, "windows", "--pid", $pid], env)
    if r.exit == 0:
      let ws = envelopeOf(r)["data"]["windows"]
      if ws.len > 0: return ws[0]
    if msSince(t0) > waitMs: return newJNull()
    sleep(100)

proc centreOf(w: JsonNode): (int, int) =
  let b = w["bounds"]
  (b[0].getInt + b[2].getInt div 2, b[1].getInt + b[3].getInt div 2)

proc swayProbe(title: string, colour: array[3, int]): seq[string] =
  @[env_helpers.helper("wm_probe"), "title=" & title, "map", "rgb=" & hex(colour),
    "hold=600000"]

proc x11Probe(title: string, colour: array[3, int], geometry: string): seq[string] =
  @[env_helpers.helper("x11_probe"), "window", "--geometry", geometry, "--rgb", hex(colour),
    "--title", title, "--hold", "600000"]

proc screenshotColour(env: StringTableRef, session, windowId, work: string,
                      want: array[3, int]): array[3, int] =
  ## The colour at the centre of a capture of the window, through the
  ## session's own capture backend. A compositor lists a window once it is
  ## mapped, and composites its first buffer on its next frame (measured on
  ## the headless sway: the capture right after `app-launch` returned was
  ## black), so the capture is repeated, bounded, until it shows `want`.
  let shot = work / ("shot-" & windowId & ".png")
  let t0 = getMonoTime()
  while true:
    let r = runCli(@["--session", session, "screenshot", "--window", windowId, "--out", shot],
                   env, timeoutMs = sessionTimeoutMs)
    outputs.add r.stderr
    if r.exit != 0 or not fileExists(shot): return [-1, -1, -1]
    let img = loadPng(shot)
    result = img.pixelAt(img.width div 2, img.height div 2)
    if near(result, want) or msSince(t0) > 10_000: return
    sleep(100)

proc stopSession(st, id: string) =
  discard runCli(@["session-stop", id], callerEnv(st), timeoutMs = sessionTimeoutMs)
  for i in countdown(startedSessions.high, 0):
    if startedSessions[i] == (st, id): startedSessions.delete(i)

template live(body: untyped) =
  ## Run `body`; a BLOCKED server fails the test with its line (never a skip).
  try:
    body
  except AssertionDefect as e:
    if "BLOCKED" in e.msg:
      echo "  ", e.msg
      checkpoint e.msg
      fail()
    else: raise

# ---------------------------------------------------------------------------
# Start, launch, list, capture, stop
# ---------------------------------------------------------------------------

template checkSessionShape(s: JsonNode, backend: string, capture, input: string,
                           displayKey: string) =
  check s["state"].getStr == "running"
  check s["stateReason"].kind == JNull
  check s["kind"].getStr == "headless"
  check s["backend"].getStr == backend
  check s["platform"].getStr == "linux"
  check s["isolation"] == %*{"pixels": true, "input": true, "clipboard": true}
  check s["hostPid"].getInt > 0
  check s["backends"] == %*{"capture": capture, "tree": "linux-atspi", "input": input}
  check s["displays"].len == 1
  let env = s["env"]
  for k in [displayKey, "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS", "AT_SPI_BUS_ADDRESS"]:
    check env.hasKey(k) and env[k].getStr.len > 0
  let rt = env["XDG_RUNTIME_DIR"].getStr
  check rt.startsWith("/tmp/")
  var info: Stat
  check stat(rt.cstring, info) == 0 and (info.st_mode.int and 0o777) == 0o700 and
        info.st_uid == getuid()
  check rt in env["AT_SPI_BUS_ADDRESS"].getStr
  check rt in env["DBUS_SESSION_BUS_ADDRESS"].getStr
  for k in ["NO_AT_BRIDGE", "GTK_A11Y", "GDK_BACKEND", "QT_QPA_PLATFORM"]:
    check s["envUnset"].getElems.anyIt(it.getStr == k)
  for k in s["envUnset"]: check not env.hasKey(k.getStr)

template checkStoppedClean(st, id, tag, rt: string) =
  check not fileExists(st / "sessions" / (id & ".json"))
  check tagged(tag).len == 0
  check not dirExists(rt)

suite "linux-sway: a private headless sway":
  let st = freshDir("sess-sway")
  let work = freshDir("sess-sway-work")

  test "test_session_start_sway_returns_env_and_runs_app":
    live:
      let env = callerEnv(st)
      let s = start("linux-sway", st, "sway-a", @["--width", "1024", "--height", "768"])
      checkSessionShape(s, "linux-sway", "linux-wlr", "linux-wlr-virtual", "WAYLAND_DISPLAY")
      check s["env"].hasKey("SWAYSOCK")
      check not s["env"].hasKey("DISPLAY")
      check s["displays"][0]["bounds"] == %*[0, 0, 1024, 768]
      check s["vnc"].kind == JNull
      let tag = privateOf(st, "sway-a")["tag"].getStr
      let rt = s["env"]["XDG_RUNTIME_DIR"].getStr
      check tagged(tag).anyIt(it[1] == "sway")
      # The record and session-info agree; session-list has it after host.
      let info = mustRun(@["session-info", "sway-a"], env)["session"]
      check info["state"].getStr == "running" and info["env"] == s["env"]
      let list = mustRun(@["session-list"], env)["sessions"]
      check list[0]["id"].getStr == "host"
      check list.getElems.anyIt(it["id"].getStr == "sway-a")
      # A client launched into the session.
      let title = "Session Probe " & nonce()
      check mustRun(@["--session", "sway-a", "windows", "--title", title],
                    env)["windows"].len == 0          # negative control: not yet
      let d = mustRun(@["--session", "sway-a", "app-launch", "--wait-window-ms", "20000",
                        "--"] & swayProbe(title, colourA), env)
      let pid = d["app"]["pid"].getInt
      check d["window"]["pid"].getInt == pid
      let ws = mustRun(@["--session", "sway-a", "windows", "--title", title], env)["windows"]
      check ws.len == 1 and ws[0]["pid"].getInt == pid
      check near(screenshotColour(env, "sway-a", ws[0]["id"].getStr, work, colourA), colourA)
      check mustRun(@["--session", "sway-a", "apps"], env)["apps"].getElems.anyIt(
        it["pid"].getInt == pid)
      check mustRun(@["--session", "sway-a", "app-quit", $pid], env)["exited"].getBool
      # Stop: nothing of the session remains.
      let stopped = mustRun(@["session-stop", "sway-a"], env)["session"]
      check stopped["state"].getStr == "stopped"
      stopSession(st, "sway-a")
      checkStoppedClean(st, "sway-a", tag, rt)
      discard failsWith(@["session-info", "sway-a"], env, 3, "session")

suite "linux-xvfb: a private Xvfb":
  let st = freshDir("sess-xvfb")
  let work = freshDir("sess-xvfb-work")

  test "test_session_start_xvfb_runs_x11_fixture":
    live:
      let env = callerEnv(st)
      let s = start("linux-xvfb", st, "xvfb-a", @["--width", "800", "--height", "600"])
      checkSessionShape(s, "linux-xvfb", "linux-x11", "linux-xtest", "DISPLAY")
      check not s["env"].hasKey("WAYLAND_DISPLAY")
      check s["displays"][0]["bounds"] == %*[0, 0, 800, 600]
      let auth = s["env"]["XAUTHORITY"].getStr
      var info: Stat
      check stat(auth.cstring, info) == 0 and (info.st_mode.int and 0o077) == 0
      let tag = privateOf(st, "xvfb-a")["tag"].getStr
      let rt = s["env"]["XDG_RUNTIME_DIR"].getStr
      check tagged(tag).anyIt(it[1] == "Xvfb") and tagged(tag).anyIt(it[1] in ["openbox", ".openbox-wrapped"])
      let title = "X11 Probe " & nonce()
      let d = mustRun(@["--session", "xvfb-a", "app-launch", "--wait-window-ms", "20000",
                        "--"] & x11Probe(title, colourB, "300x200+120+90"), env)
      let pid = d["app"]["pid"].getInt
      let ws = mustRun(@["--session", "xvfb-a", "windows", "--title", title], env)["windows"]
      check ws.len == 1 and ws[0]["pid"].getInt == pid
      check ws[0]["bounds"][2].getInt == 300 and ws[0]["bounds"][3].getInt == 200
      check near(screenshotColour(env, "xvfb-a", ws[0]["id"].getStr, work, colourB), colourB)
      # The X server's access control: the session's cookie admits a
      # client, its absence does not (another local user has no cookie).
      let probe = env_helpers.helper("x11_probe")
      var noCookie = newStringTable(modeCaseSensitive)
      noCookie["PATH"] = getEnv("PATH")
      noCookie["HOME"] = work
      noCookie["DISPLAY"] = s["env"]["DISPLAY"].getStr
      let refused = execCmdEx(quoteShellCommand([probe, "list"]), env = noCookie)
      check refused.exitCode != 0
      noCookie["XAUTHORITY"] = auth
      let admitted = execCmdEx(quoteShellCommand([probe, "list"]), env = noCookie)
      check admitted.exitCode == 0 and title in admitted.output
      check mustRun(@["--session", "xvfb-a", "app-quit", $pid], env)["exited"].getBool
      stopSession(st, "xvfb-a")
      checkStoppedClean(st, "xvfb-a", tag, rt)

suite "linux-gnome: a private headless GNOME Shell":
  let st = freshDir("sess-gnome")

  test "test_session_start_gnome_headless_runs_app":
    live:
      let env = callerEnv(st)
      let s = start("linux-gnome", st, "gnome-a", @["--width", "1280", "--height", "800"])
      checkSessionShape(s, "linux-gnome", "linux-gnome", "linux-mutter", "WAYLAND_DISPLAY")
      check s["displays"][0]["bounds"] == %*[0, 0, 1280, 800]
      let tag = privateOf(st, "gnome-a")["tag"].getStr
      let rt = s["env"]["XDG_RUNTIME_DIR"].getStr
      check tagged(tag).anyIt(it[1] in ["gnome-shell", ".gnome-shell-wrapped"])
      let title = "Gnome Probe " & nonce()
      let d = mustRun(@["--session", "gnome-a", "app-launch", "--wait-window-ms", "30000",
                        "--"] & swayProbe(title, colourC), env)
      let pid = d["app"]["pid"].getInt
      let ws = mustRun(@["--session", "gnome-a", "windows", "--title", title], env)["windows"]
      check ws.len == 1 and ws[0]["pid"].getInt == pid
      check mustRun(@["--session", "gnome-a", "apps"], env)["apps"].getElems.anyIt(
        it["pid"].getInt == pid)
      # GNOME offers no VNC endpoint: refused before anything starts.
      let v = failsWith(@["--session-backend", "linux-gnome", "session-start", "--kind",
                          "headless", "--name", "gnome-vnc", "--vnc"], env, 4,
                          "unsupported-option")
      check v["details"]["feature"].getStr == "session-vnc"
      check not fileExists(st / "sessions" / "gnome-vnc.json")
      check mustRun(@["--session", "gnome-a", "app-quit", $pid], env)["exited"].getBool
      stopSession(st, "gnome-a")
      checkStoppedClean(st, "gnome-a", tag, rt)

# ---------------------------------------------------------------------------
# VNC
# ---------------------------------------------------------------------------

proc listeners(port: int): tuple[v4, v6: seq[TcpSocketRow]] =
  (listenersOn(parseProcNetTcp(readFile("/proc/net/tcp")), port),
   listenersOn(parseProcNetTcp(readFile("/proc/net/tcp6")), port))

proc vncServerSockets(st, name: string): seq[string] =
  ## The socket inodes the session's VNC server (x11vnc or wayvnc, found by
  ## the session's tag) holds open.
  let tag = privateOf(st, name)["tag"].getStr
  for (pid, prog) in tagged(tag):
    if "x11vnc" in prog or "wayvnc" in prog:
      for kind, path in walkDir("/proc/" & $pid & "/fd"):
        try:
          let target = expandSymlink(path)
          if target.startsWith("socket:["): result.add target[8 .. ^2]
        except OSError: discard

proc serverTcpListeners(st, name: string): seq[TcpSocketRow] =
  ## Every listening TCP socket (IPv4 and IPv6, any port) of the session's
  ## VNC server.
  tcpListenersOf(parseProcNetTcp(readFile("/proc/net/tcp")),
                 parseProcNetTcp(readFile("/proc/net/tcp6")), vncServerSockets(st, name))

template checkVnc(backend, name: string, st, work: string,
                  launch: proc (title: string): seq[string]) =
  let env = callerEnv(st)
  let s = start(backend, st, name, @["--width", "640", "--height", "480", "--vnc"])
  check s["vnc"].kind == JObject
  check s["vncSocket"].kind == JNull
  let host = s["vnc"]["host"].getStr
  let port = s["vnc"]["port"].getInt
  check host == "127.0.0.1" and port > 0
  # The listener is on the loopback address only: no wildcard, no IPv6.
  let (v4, v6) = listeners(port)
  check v4.len == 1 and v4[0].localAddr == "0100007F"
  check v6.len == 0
  # And it is the server's ONLY listening TCP socket, on any port (GS17).
  let all = serverTcpListeners(st, name)
  check vncServerSockets(st, name).len > 0       # the server was found
  check all.len == 1 and all[0].localPort == port and all[0].localAddr == "0100007F"
  # Its framebuffer is the session's.
  let title = "Vnc Probe " & nonce()
  let before = readFrame(host, port)
  check before.width == 640 and before.height == 480
  let d = mustRun(@["--session", name, "app-launch", "--wait-window-ms", "20000", "--"] &
                  launch(title), env)
  let w = d["window"]
  let (cx, cy) = centreOf(w)
  check not near(before.pixel(cx, cy), colourA)       # negative control
  var after: RfbFrame
  # A frame reaches the VNC server when the compositor next renders; the
  # client asks again until it does (bounded), rather than sleeping.
  let t0 = getMonoTime()
  while true:
    after = readFrame(host, port)
    if near(after.pixel(cx, cy), colourA) or msSince(t0) > 10_000: break
    sleep(100)
  check near(after.pixel(cx, cy), colourA)
  check after.width == 640
  stopSession(st, name)
  let (gone4, gone6) = listeners(port)
  check gone4.len == 0 and gone6.len == 0

template checkVncSocket(backend, name: string, st, work: string,
                        launch: proc (title: string): seq[string]) =
  let env = callerEnv(st)
  let s = start(backend, st, name, @["--width", "640", "--height", "480", "--vnc-socket"])
  check s["vnc"].kind == JNull
  check s["vncSocket"].kind == JString
  let path = s["vncSocket"].getStr
  let rt = privateOf(st, name)["runtimeDir"].getStr
  check path == rt / "vnc.sock"
  # The directory is the caller's and 0700: no other user can reach the
  # socket in it.
  var dst: Stat
  check stat(rt.cstring, dst) == 0
  check (dst.st_mode.int and 0o777) == 0o700 and dst.st_uid == getuid()
  # The server listens there and on no TCP port.
  let mine = vncServerSockets(st, name)
  check mine.len > 0
  let rows = parseProcNetUnix(readFile("/proc/net/unix"))
  check rows.anyIt(it.path == path and it.inode in mine and (it.flags and 0x10000) != 0)
  check serverTcpListeners(st, name).len == 0
  # Its framebuffer is the session's.
  let title = "Vnc Probe " & nonce()
  let before = readFrameUnix(path)
  check before.width == 640 and before.height == 480
  let d = mustRun(@["--session", name, "app-launch", "--wait-window-ms", "20000", "--"] &
                  launch(title), env)
  let (cx, cy) = centreOf(d["window"])
  check not near(before.pixel(cx, cy), colourA)       # negative control
  var after: RfbFrame
  let t0 = getMonoTime()
  while true:
    after = readFrameUnix(path)
    if near(after.pixel(cx, cy), colourA) or msSince(t0) > 10_000: break
    sleep(100)
  check near(after.pixel(cx, cy), colourA)
  stopSession(st, name)
  check not fileExists(path) and not dirExists(rt)

suite "--vnc-socket: an owner-only VNC socket (GS17)":
  let st = freshDir("sess-vncs")
  let work = freshDir("sess-vncs-work")

  test "test_session_vnc_socket_is_owner_only [sway]":
    live:
      checkVncSocket("linux-sway", "vncs-sway", st, work,
                     proc (title: string): seq[string] = swayProbe(title, colourA))

  test "test_session_vnc_socket_is_owner_only [xvfb]":
    live:
      checkVncSocket("linux-xvfb", "vncs-xvfb", st, work,
                     proc (title: string): seq[string] = x11Probe(title, colourA, "200x150+300+200"))

  test "test_session_vnc_and_vnc_socket_conflict":
    let x = failsWith(@["--session-backend", "linux-xvfb", "session-start", "--kind",
                        "headless", "--name", "vncs-both", "--vnc", "--vnc-socket"],
                      callerEnv(st), 2, "conflicting-arguments")
    check x["kind"].getStr == "bad-args"
    check not fileExists(st / "sessions" / "vncs-both.json")

suite "--vnc: a loopback VNC endpoint":
  let st = freshDir("sess-vnc")
  let work = freshDir("sess-vnc-work")

  test "test_session_vnc_endpoint_is_loopback_only [sway]":
    live:
      checkVnc("linux-sway", "vnc-sway", st, work,
               proc (title: string): seq[string] = swayProbe(title, colourA))

  test "test_session_vnc_endpoint_is_loopback_only [xvfb]":
    live:
      checkVnc("linux-xvfb", "vnc-xvfb", st, work,
               proc (title: string): seq[string] = x11Probe(title, colourA, "200x150+300+200"))

# ---------------------------------------------------------------------------
# A dead host, a dead compositor
# ---------------------------------------------------------------------------

proc waitState(env: StringTableRef, id, state: string, reason = "",
               ms = 10_000): JsonNode =
  ## `session-info` until the session is in `state` (with `stateReason`
  ## `reason`, when given): the host writes the record when it notices;
  ## this waits for that write, bounded.
  let t0 = getMonoTime()
  while true:
    result = envelopeOf(runCli(@["session-info", id], env))["data"]["session"]
    if result["state"].getStr == state and
       (reason.len == 0 or result["stateReason"].getStr == reason): return
    if msSince(t0) > ms: return
    sleep(50)

suite "a session whose host or compositor dies":
  let st = freshDir("sess-death")

  test "test_session_host_death_is_reported_as_error":
    live:
      let env = callerEnv(st)
      for backend in ["linux-sway", "linux-xvfb"]:
        let name = "dies-" & backend[6 .. ^1]
        let s = start(backend, st, name)
        let tag = privateOf(st, name)["tag"].getStr
        let rt = s["env"]["XDG_RUNTIME_DIR"].getStr
        check posix.kill(Pid(s["hostPid"].getInt), SIGKILL) == 0
        let info = waitState(env, name, "error")
        check info["state"].getStr == "error"
        check info["stateReason"].getStr == "host-exited"
        let listed = mustRun(@["session-list"], env)["sessions"].getElems.filterIt(
          it["id"].getStr == name)
        check listed.len == 1 and listed[0]["state"].getStr == "error"
        # The session's processes outlived their host; session-stop ends them.
        check tagged(tag).len > 0
        check mustRun(@["session-stop", name], env)["session"]["state"].getStr == "stopped"
        stopSession(st, name)
        checkStoppedClean(st, name, tag, rt)
      # The compositor dies under a live host: the host records why and
      # tears the session down.
      let s = start("linux-sway", st, "dies-compositor")
      let tag = privateOf(st, "dies-compositor")["tag"].getStr
      let sway = tagged(tag).filterIt(it[1] == "sway")
      check sway.len == 1
      if sway.len == 1: check posix.kill(Pid(sway[0][0]), SIGKILL) == 0
      let info = waitState(env, "dies-compositor", "error", "compositor-exited")
      check info["state"].getStr == "error"
      check info["stateReason"].getStr == "compositor-exited"
      let a = failsWith(@["--session", "dies-compositor", "apps"], env, 4,
                        "session-not-running")
      check a["details"]["feature"].kind == JNull
      check mustRun(@["session-stop", "dies-compositor"], env)["session"]["state"].getStr ==
            "stopped"
      stopSession(st, "dies-compositor")
      check tagged(tag).len == 0

# ---------------------------------------------------------------------------
# C6, C9, C10, C11
# ---------------------------------------------------------------------------

proc fakeServerDir(work, tool: string): string =
  ## A directory holding a `tool` that exits at once (a display server that
  ## cannot start), for a PATH that finds it first.
  result = work / ("fake-" & tool)
  createDir(result)
  writeFile(result / tool, "#!/bin/sh\necho 'invented failure: no output' >&2\nexit 3\n")
  setFilePermissions(result / tool, {fpUserRead, fpUserWrite, fpUserExec})

proc environOf(pid: int): Table[string, string] =
  for kv in readFile("/proc/" & $pid & "/environ").split('\0'):
    let eq = kv.find('=')
    if eq > 0: result[kv[0 ..< eq]] = kv[eq + 1 .. ^1]

proc waitExit(p: Process, ms: int): bool =
  ## Whether `p` exits within `ms` (its exit is the signal waited for).
  let t0 = getMonoTime()
  while p.running:
    if msSince(t0) > ms: return false
    sleep(20)
  true

template checkReadiness(backend, name, st, work: string, polluted: StringTableRef,
                        fakeTool: string, fakeVar = "") =
  let env = callerEnv(st)
  # Readiness: an AT-SPI read right after the start succeeds (exit 0, not 6).
  let s = start(backend, st, name)
  let id = name
  check mustRun(@["--session", id, "permissions"], env)["permissions"]["accessibility"].getStr ==
        "granted"
  check mustRun(@["--session", id, "find", "--role", "button", "--name", "Nothing " & nonce()],
                env)["elements"].len == 0
  # A name in use: exit 2, the record untouched.
  let recordBefore = readFile(st / "sessions" / (id & ".json"))
  let inUse = failsWith(@["--session-backend", backend, "session-start", "--kind", "headless",
                          "--name", id], env, 2, "name-in-use")
  check inUse["details"]["name"].getStr == id and inUse["details"]["state"].getStr == "running"
  check readFile(st / "sessions" / (id & ".json")) == recordBefore
  # C6: a GTK client the caller spawns itself from env / envUnset.
  let form = buildFormFixture(work, 3)
  let title = "Env Form " & nonce()
  let good = spawnInto(s, polluted, @[form, "--title", title])
  let w = windowOf(env, id, good.processID)
  check w.kind == JObject and w{"title"}.getStr == title
  # On the session's AT-SPI bus: its registration follows its window, so
  # the read is repeated (bounded) until the form's Submit button is there.
  var submit = 0
  let tr = getMonoTime()
  while submit != 1 and msSince(tr) < 30_000:
    let r = runCli(@["--session", id, "find", "--pid", $good.processID, "--role", "button",
                     "--name", "Submit"], env)
    if r.exit == 0: submit = envelopeOf(r)["data"]["elements"].len
    if submit != 1: sleep(100)
  check submit == 1
  let tree = mustRun(@["--session", id, "tree", "--pid", $good.processID], env)
  check "Display name" in $tree
  # The negative control: the same spawn without removing envUnset is routed
  # away by the polluted variables, and exits without a window.
  let bad = spawnInto(s, polluted, @[form, "--title", title & " bad"], honourUnset = false)
  check waitExit(bad, 15_000)
  check bad.peekExitCode != 0
  # C11: --env reaches the launched process; the caller's routing does not.
  let mark = "mark-" & nonce()
  let x = failsWith(@["--session", id, "app-launch", "--wait-window-ms", "800", "--env",
                      "GA_SESSION_MARK=" & mark, "--", "sleep", "600"], polluted, 7,
                      "condition-not-met")
  let spid = x["details"]["app"]["pid"].getInt
  launched.add spid
  check fileExists("/proc/" & $spid & "/stat")
  let launchedEnv = environOf(spid)
  check launchedEnv.getOrDefault("GA_SESSION_MARK") == mark
  for k, v in s["env"]: check launchedEnv.getOrDefault(k) == v.getStr
  for k in s["envUnset"]: check k.getStr notin launchedEnv
  check mustRun(@["--session", id, "app-quit", $spid], env)["exited"].getBool
  # Readiness failures: no time left for it (exit 5 before the deadline),
  # and a display server that exits at once (exit 5 at once); neither leaves
  # a record or a process.
  let before = ownProcesses().mapIt(it[0])
  let dirsBefore = sessionRuntimeDirs()
  let t0 = getMonoTime()
  startedSessions.add (st, id & "-late")      # stopped at the end if it starts after all
  startedSessions.add (st, id & "-early")
  let late = failsWith(@["--timeout-ms", "300", "--session-backend", backend, "session-start",
                      "--kind", "headless", "--name", id & "-late"], env, 5, "session-failed")
  let lateMs = msSince(t0)
  checkpoint "the --timeout-ms 300 start answered after " & $lateMs & " ms: " &
    late{"message"}.getStr
  check lateMs < 300
  check not fileExists(st / "sessions" / (id & "-late.json"))
  var broken = callerEnv(st)
  if fakeVar.len > 0:
    broken[fakeVar] = fakeServerDir(work, fakeTool) / fakeTool
  else:
    broken["PATH"] = fakeServerDir(work, fakeTool) & ":" & broken["PATH"]
  let t1 = getMonoTime()
  let early = failsWith(@["--session-backend", backend, "session-start", "--kind", "headless",
                          "--name", id & "-early"], broken, 5, "session-failed")
  check msSince(t1) < 8000
  check "session host could not start" in early["message"].getStr
  check not fileExists(st / "sessions" / (id & "-early.json"))
  block:
    let t2 = getMonoTime()
    var extra = ownProcesses().filterIt(it[0] notin before)
    while extra.len > 0 and msSince(t2) < 5000:
      sleep(50)
      extra = ownProcesses().filterIt(it[0] notin before)
    if extra.len > 0: checkpoint "left behind: " & $extra
    check extra.len == 0
  # ... and no runtime directory (a host killed part way through its start).
  check sessionRuntimeDirs().filterIt(it notin dirsBefore) == newSeq[string]()
  # C9: the host dies; every verb in the session is exit 4.
  check posix.kill(Pid(s["hostPid"].getInt), SIGKILL) == 0
  discard waitState(env, id, "error")
  let shot = work / (id & "-dead.png")
  for args in [@["apps"], @["app-launch", "--", "true"], @["app-quit", "1"], @["displays"],
               @["windows"], @["screenshot", "--out", shot],
               @["record", "--out", work / "dead.mp4", "--duration-ms", "200"],
               @["tree", "--focused"], @["find", "--role", "button"],
               @["element", "/app[1]/window[0]"], @["element-action", "/app[1]/button[0]", "press"],
               @["wait", "--window", "--title", "x", "--wait-ms", "100"],
               @["move", "--to", "1,1"], @["click", "--at", "1,1"],
               @["scroll", "--at", "1,1", "--dx", "0", "--dy", "1"], @["type", "abc"],
               @["key", "Return"], @["window-focus", "1"],
               @["window-set-bounds", "1", "--bounds", "0,0,10,10"],
               @["ocr", "--display", "0", "--out", shot]]:
    let e = failsWith(@["--session", id] & args, env, 4, "session-not-running")
    check e["details"]["feature"].kind == JNull
  check not fileExists(shot)
  check mustRun(@["--session", id, "capabilities"], env)["platform"].getStr == "linux"
  check mustRun(@["session-info", id], env)["session"]["state"].getStr == "error"
  check mustRun(@["session-stop", id], env)["session"]["state"].getStr == "stopped"
  stopSession(st, id)
  check not fileExists(st / "sessions" / (id & ".json"))
  for p in [good, bad]:
    if p.running: p.kill()
    discard p.waitForExit(2000)
    p.close()

suite "C6, C9, C10, C11 on the private sessions":
  let st = freshDir("sess-ready")
  let work = freshDir("sess-ready-work")

  proc pollutedCaller(extra: openArray[(string, string)]): StringTableRef =
    ## A caller whose environment would route a client away from the
    ## session or switch its accessibility off (an operator's own session
    ## variables, as an agent process typically inherits them).
    result = callerEnv(st)
    result["NO_AT_BRIDGE"] = "1"
    result["GTK_A11Y"] = "none"
    result["AT_SPI_BUS_ADDRESS"] = "unix:path=/nonexistent/gs10/at-spi"
    result["DBUS_SESSION_BUS_ADDRESS"] = "unix:path=/nonexistent/gs10/bus"
    for (k, v) in extra: result[k] = v

  test "test_linux_session_readiness_env_and_dead_host [sway]":
    live:
      checkReadiness("linux-sway", "ready-sway", st, work,
                     pollutedCaller({"DISPLAY": ":987", "GDK_BACKEND": "x11"}), "sway")

  test "test_linux_session_readiness_env_and_dead_host [xvfb]":
    live:
      checkReadiness("linux-xvfb", "ready-xvfb", st, work,
                     pollutedCaller({"WAYLAND_DISPLAY": "wayland-gs10-none",
                                     "GDK_BACKEND": "wayland"}), "Xvfb")

  test "test_linux_session_readiness_env_and_dead_host [gnome]":
    live:
      checkReadiness("linux-gnome", "ready-gnome", st, work,
                     pollutedCaller({"DISPLAY": ":987", "GDK_BACKEND": "x11"}), "gnome-shell",
                     fakeVar = "GUI_ASSERT_GNOME_SHELL")

# ---------------------------------------------------------------------------
# linux-host: attaching to the caller's own sway
# ---------------------------------------------------------------------------

proc swayState(t: SwayTarget): string =
  ## Everything of sway's own state a careless attach could change: its
  ## outputs (mode, scale, position, power), inputs, seats and configuration
  ## (sway-ipc(7): GET_OUTPUTS, GET_INPUTS, GET_SEATS, GET_CONFIG).
  for kind in ["get_outputs", "get_inputs", "get_seats", "get_config"]:
    let (o, code) = execCmdEx(quoteShellCommand(["swaymsg", "-s", t.sessionEnv["SWAYSOCK"],
                                                 "-t", kind, "-r"]))
    doAssert code == 0, "swaymsg " & kind & ": " & o
    result.add kind & "\n" & o & "\n"

suite "linux-host: the caller's own session":
  let st = freshDir("sess-host")
  let t = newSwayTarget(960, 720)
  var problem = ""
  var probe: Process
  try:
    startTarget(t)
  except AssertionDefect as e:
    problem = gs10(e.msg)

  test "test_linux_host_attach_reports_existing_session":
    if problem.len > 0:
      echo "  ", problem
      checkpoint problem
      fail()
    else:
      let env = runEnv(st, t.sessionEnv)
      let title = "Host Probe " & nonce()
      probe = t.probeWindow(hex(colourB), title)
      let w = t.waitPidWindow(probe.processID)
      check w.pid == probe.processID
      let before = swayState(t)
      let host = mustRun(@["session-info", "host"], env)["session"]
      check host["state"].getStr == "running" and host["stateReason"].kind == JNull
      check host["backend"].getStr == "linux-host" and host["kind"].getStr == "host"
      check host["displays"].len == 1 and host["displays"][0]["bounds"] == %*[0, 0, 960, 720]
      check host["env"].len == 0 and host["envUnset"].len == 0
      check host["isolation"] == %*{"pixels": false, "input": false, "clipboard": false}
      let list = mustRun(@["session-list"], env)["sessions"]
      check list.len >= 1 and list[0]["id"].getStr == "host"
      check mustRun(@["displays"], env)["displays"] == host["displays"]
      let ws = mustRun(@["windows", "--title", title], env)["windows"]
      check ws.len == 1 and ws[0]["pid"].getInt == probe.processID
      check mustRun(@["apps"], env)["apps"].getElems.anyIt(it["pid"].getInt == probe.processID)
      check mustRun(@["capabilities"], env)["selected"]["session"].getStr == "linux-host"
      # Nothing of the compositor changed.
      check swayState(t) == before
      # Starting a private session is another backend's.
      let refused = failsWith(@["session-start", "--kind", "headless"], env, 4,
                              "unsupported-option")
      check "linux-sway" in refused["remedy"].getStr
      # The negative control: no display server reachable.
      let empty = freshRuntimeDir()
      var gone = runEnv(st, newStringTable(modeCaseSensitive))
      gone["XDG_RUNTIME_DIR"] = empty
      gone["WAYLAND_DISPLAY"] = "wayland-gs10-none"
      for e in [gone, runEnv(st, newStringTable(modeCaseSensitive))]:
        let info = mustRun(@["session-info", "host"], e)["session"]
        check info["state"].getStr == "error"
        check info["stateReason"].getStr == "no-display-server"
        for args in [@["apps"], @["app-launch", "--", "true"], @["app-quit", "1"]]:
          let x = failsWith(args, e, 4, "session-not-running")
          check x["details"]["feature"].kind == JNull
      removeDir(empty)
      stopProcess(probe)
  t.stop()

# ---------------------------------------------------------------------------
# Nothing left behind
# ---------------------------------------------------------------------------

suite "the run's own processes":
  test "test_live_suite_leaves_no_process_running":
    # Every session above was stopped (a failed test's too, here); nothing
    # this run started (a session host, a compositor, a bus, an AT-SPI
    # registry, a VNC server, a fixture, a bus-activated service) may
    # outlive it (`linux_live.ownProcesses`).
    for (st, id) in startedSessions:
      discard runCli(@["session-stop", id], callerEnv(st), timeoutMs = sessionTimeoutMs)
    startedSessions.setLen 0
    terminateAll(launched)
    checkLeavesNoProcess()   # nor any session runtime directory
    # No captured content on stderr: the suite's runs wrote nothing there
    # but diagnostics, and none of them a window title.
    for o in outputs: check "Probe " notin o and "Env Form" notin o

cleanupFreshDirs()
