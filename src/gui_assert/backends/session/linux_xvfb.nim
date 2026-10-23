## The `linux-xvfb` session backend (spec §6.3, GS10): a private Xvfb with a
## minimal window manager, for X11-only applications. The session host
## starts, in a private runtime directory under /tmp (`gaxv-*`, mode 0700):
##
## * **Xvfb** (Xvfb(1)) on the first free display number, which it reports
##   through `-displayfd` once it accepts connections (the readiness signal;
##   no display number is guessed, so two sessions, or an operator's own X
##   server, never collide), with one screen of the requested size at depth
##   24, no TCP listener (`-nolisten tcp`), and **access control**: `-auth`
##   names an Xauthority file holding one MIT-MAGIC-COOKIE-1 of 128 random
##   bits (Xsecurity(7)), so only a client given the session's `XAUTHORITY`
##   connects; another local user cannot, although the X socket itself is
##   world-writable. The file is written in the Xau format
##   (https://gitlab.freedesktop.org/xorg/lib/libxau, `Xauth.h`) by
##   `xauthEntry`, with the wildcard family so it matches the local socket
##   under any host name;
## * its own **session bus**, `dbus-daemon --session`, ready when it prints
##   its address (`--print-address`);
## * **Openbox** (http://openbox.org/) as the window manager, with a private
##   configuration directory (so no operator configuration is read), ready
##   when it has claimed the screen: the root window carries
##   `_NET_SUPPORTING_WM_CHECK` (EWMH), which the `x11_probe` helper reports
##   as `"wm": true`. A window manager gives the session focus handling and
##   stacking as a desktop has them; `x11_probe` (and so `linux-x11`) reports
##   the CLIENT windows inside Openbox's frames (ICCCM `WM_STATE`).
##
## The shared lifecycle, the AT-SPI bus and the environment contract are
## `linux_private`'s. The session's verbs select `linux-x11` (capture),
## `linux-atspi` (tree) and `linux-xtest` (input) unless the caller selects
## others (spec §3.4 rule 5). `--scale` other than 1 is exit 4 /
## `unsupported-option` (X11 has no output scale).
##
## **VNC** (`--vnc`): `x11vnc` (x11vnc(1)) serves the display, with the
## session's cookie, bound to 127.0.0.1 only (`-localhost`, `-noipv6`), no
## rc file (`-norc`) and no password: the contract's `Session.vnc` is
## `{host, port}` and carries no credential, so the endpoint is reachable by
## any local user, never from another host; `linux_private.waitVncListening`
## checks that x11vnc itself listens there and only there.

import std/[json, options, os, osproc, sequtils, streams, strutils, sysrand, tables,
            tempfiles]

import ../../core/desktop_types
import ../../cancel
import ../capture/linux_common
import ../../desktop_env/session_bus
import ./[linux_host, linux_private]

const
  linuxXvfbSessionName* = "linux-xvfb"
    ## The backend's contract name.
  startStepMs = 10_000
    ## The bound of each start step (the session's own readiness bound,
    ## 10 s, cuts the whole start shorter in the starter).
  vncAttempts = 3
  familyWild = 0xFFFF
    ## Xau's FamilyWild: an entry that matches any address.

proc xauthEntry*(number: string, cookie: string): string =
  ## One Xauthority entry (libXau `Xauth.h`, the file format of
  ## `XauWriteAuth`): family, address, display number, auth name and data,
  ## each counted field a big-endian 16-bit length and its bytes. Family
  ## FamilyWild with an empty address, so it matches the local socket
  ## whatever the host is called.
  proc field(s: string): string =
    result.add char((s.len shr 8) and 0xFF)
    result.add char(s.len and 0xFF)
    result.add s
  result.add char((familyWild shr 8) and 0xFF)
  result.add char(familyWild and 0xFF)
  result.add field("")
  result.add field(number)
  result.add field("MIT-MAGIC-COOKIE-1")
  result.add field(cookie)

proc parseDisplayFd*(text: string): int =
  ## The display number Xvfb wrote to its `-displayfd` (a decimal line), or
  ## -1 while it has not written a whole one.
  if not text.endsWith("\n"): return -1
  let t = text.strip
  if t.len == 0 or t.len > 6 or not t.allCharsInSet(Digits): return -1
  parseInt(t)

proc xvfbPreflight(env: Table[string, string], vnc: bool) =
  ## What an Xvfb session needs, checked before anything is started.
  for tool in ["Xvfb", "openbox", "dbus-daemon"]:
    discard requireOnPath(linuxXvfbSessionName, env, tool)
  requireAtspiLauncher(linuxXvfbSessionName, env)
  discard helperPath(LinuxCaptureConfig(env: env), linuxXvfbSessionName, "x11_probe")
  if vnc: discard requireOnPath(linuxXvfbSessionName, env, "x11vnc")

proc readSmall(path: string): string =
  try: readFile(path)
  except IOError, OSError: ""

proc writeAuth(path, number, cookie: string) =
  writeFile(path, xauthEntry(number, cookie))
  setFilePermissions(path, {fpUserRead, fpUserWrite})

proc launchWithFd3(env: Table[string, string], exe: string, args: seq[string],
                   fd3, log: string): Process =
  ## `launchLogged` with descriptor 3 redirected to the file `fd3`, where
  ## Xvfb's `-displayfd 3` and dbus-daemon's `--print-address=3` write.
  launchLogged(env, "/bin/sh", @["-c", "exec " & quoteShellCommand(@[exe] & args) &
    " 3>" & quoteShell(fd3), "sh"], log)

proc xvfbHostStart(spec: HostSpec): ServerRun =
  ## In the session host: Xvfb, its bus, Openbox, then x11vnc when asked.
  # The host made it (`linux_private.sessionRuntimeDir`).
  let rt = if spec.runtimeDir.len > 0: spec.runtimeDir
           else: createTempDir("gaxv-", "", "/tmp")
  setFilePermissions(rt, {fpUserRead, fpUserWrite, fpUserExec})
  result.runtimeDir = rt
  var procs: seq[Process]
  proc stopAll() =
    for i in countdown(procs.high, 0): stopProcess(procs[i])
  try:
    let host = processEnv()
    let auth = rt / "Xauthority"
    let cookie = urandom(16).mapIt(char(it)).join("")
    # The server reads the cookie at start (any display number matches on
    # its side); the entry is rewritten with the number once it is known,
    # for the clients' side.
    writeAuth(auth, "0", cookie)
    let xvfb = launchWithFd3(childEnv(initOrderedTable[string, string](), baseEnvUnset),
      findExe("Xvfb"), @["-displayfd", "3", "-screen", "0",
      $spec.width & "x" & $spec.height & "x24", "-nolisten", "tcp", "-noreset", "-auth", auth],
      rt / "displayfd", rt / "xvfb.log")
    procs.add xvfb
    var n = -1
    let startNs = monoNowNs()
    while n < 0:
      n = parseDisplayFd(readSmall(rt / "displayfd"))
      if n >= 0: break
      if not xvfb.running or elapsedMsSince(startNs) > startStepMs:
        raise newException(OSError, "Xvfb did not start: " & logTail(rt / "xvfb.log"))
      sleep(10)
    writeAuth(auth, $n, cookie)
    var env = initOrderedTable[string, string]()
    env["DISPLAY"] = ":" & $n
    env["XAUTHORITY"] = auth
    env["XDG_RUNTIME_DIR"] = rt
    env["XDG_SESSION_TYPE"] = "x11"
    env["XDG_CONFIG_HOME"] = rt / "config"
    env["GSETTINGS_BACKEND"] = "memory"
    env["GIO_USE_VFS"] = "local"
    createDir(rt / "config")
    # The session bus.
    let dbusDaemon = findExe("dbus-daemon")
    let dbus = launchWithFd3(childEnv(env, baseEnvUnset), dbusDaemon,
      sessionBusArgs(dbusDaemon) & @["--nofork", "--address=unix:path=" & rt / "bus", "--print-address=3"],
      rt / "bus-address", rt / "dbus.log")
    procs.add dbus
    while true:
      let a = readSmall(rt / "bus-address")
      if a.endsWith("\n") and a.strip.len > 0:
        env["DBUS_SESSION_BUS_ADDRESS"] = a.strip
        break
      if not dbus.running or elapsedMsSince(startNs) > 2 * startStepMs:
        raise newException(OSError, "the session bus did not start: " & logTail(rt / "dbus.log"))
      sleep(10)
    # The window manager, ready once it claims the screen.
    let wm = launchLogged(childEnv(env, baseEnvUnset), findExe("openbox"), @["--sm-disable"],
                          rt / "openbox.log")
    procs.add wm
    let probe = helperPath(LinuxCaptureConfig(env: host), linuxXvfbSessionName, "x11_probe")
    var plainEnv = childEnv(env, baseEnvUnset)
    while true:
      var claimed = false
      try:
        let p = startProcess(probe, args = ["list"], env = plainEnv.toStringTable,
                             options = {})
        let output = p.outputStream.readAll()
        discard p.waitForExit(5000)
        p.close()
        let line = output.strip.splitLines
        if line.len > 0: claimed = parseJson(line[0]){"wm"}.getBool
      except CatchableError: discard
      if claimed: break
      if not wm.running or elapsedMsSince(startNs) > 3 * startStepMs:
        raise newException(OSError, "Openbox did not manage the screen: " &
                                    logTail(rt / "openbox.log"))
      sleep(20)
    # The VNC endpoint.
    var vnc: Process = nil
    if spec.vnc:
      var why = ""
      for attempt in 1 .. vncAttempts:
        let port = freeLoopbackPort()
        let p = launchLogged(childEnv(env, baseEnvUnset), findExe("x11vnc"),
          @["-display", ":" & $n, "-auth", auth, "-localhost", "-noipv6", "-rfbport", $port,
            "-forever", "-shared", "-nopw", "-norc", "-quiet"], rt / "x11vnc.log")
        why = waitVncListening(p.processID, proc (): bool = p.running, port,
                               monoNowNs() + int64(startStepMs) * 1_000_000)
        if why.len == 0:
          vnc = p
          procs.add p
          result.vnc = some(VncEndpoint(host: "127.0.0.1", port: port))
          break
        why.add ": " & logTail(rt / "x11vnc.log")
        stopProcess(p)
      if vnc == nil: raise newException(OSError, why)
    result.env = env
    var plain = initTable[string, string]()
    for k, v in env: plain[k] = v
    result.alive = proc (): string =
      if not xvfb.running or not displayAnswers(plain).ok: return "compositor-exited"
      if not wm.running: return "window-manager-exited"
      if vnc != nil and not vnc.running: return "vnc-exited"
      ""
    result.stop = proc () = stopAll()
  except CatchableError:
    stopAll()
    removeRuntimeDir(rt)
    raise

proc linuxXvfbServer*(): PrivateServer =
  ## The `linux-xvfb` server for `linux_private`.
  PrivateServer(name: linuxXvfbSessionName, idPrefix: "xvfb",
    backends: SessionBackends(capture: "linux-x11", tree: "linux-atspi",
                              input: "linux-xtest"),
    supportsVnc: true, supportsScale: false,
    preflight: xvfbPreflight, hostStart: xvfbHostStart)
