## The `linux-sway` session backend (spec §6.3, GS10): a private headless
## sway (`WLR_BACKENDS=headless`), started by the session host through the
## existing desktop-environment target (`desktop_env/sway`): its own runtime
## directory under /tmp, its own session bus with the settings portal
## (`desktop_env/session_bus`), one headless output of the requested mode
## and scale, no Xwayland. The shared lifecycle, the AT-SPI bus and the
## environment contract are `linux_private`'s.
##
## The session's verbs select `linux-wlr` (capture), `linux-atspi` (tree)
## and `linux-wlr-virtual` (input) unless the caller selects others
## (spec §3.4 rule 5). `--width` / `--height` are the output's mode in
## pixels; with `--scale S` its logical size, which the session's display
## reports and desktop coordinates use, is the mode divided by S.
##
## **VNC** (`--vnc`): `wayvnc` (https://github.com/any1/wayvnc, wayvnc(1))
## serves the headless output, bound to 127.0.0.1 on a free port, with an
## empty configuration file (`-C`, so no user configuration enables
## anything else) and no authentication: the contract's `Session.vnc` is
## `{host, port}` and carries no credential, so the endpoint is reachable by
## any local user, never from another host. The start fails unless
## `linux_private.waitVncListening` sees wayvnc itself listening there and
## only there, greeting with an RFB banner (RFC 6143 §7.1.1).

import std/[options, os, osproc, strtabs, tables]

import ../../core/desktop_types
import ../../[cancel, desktop_env]
import ../../desktop_env/sway
import ./[linux_host, linux_private]

const
  linuxSwaySessionName* = "linux-sway"
    ## The backend's contract name.
  vncAttempts = 3
    ## Free ports tried for wayvnc (another process may take one first).
  vncStartMs = 10_000

proc swayPreflight(env: Table[string, string], vnc: bool) =
  ## What a sway session needs, checked before anything is started.
  for tool in ["sway", "swaymsg", "dbus-daemon"]:
    discard requireOnPath(linuxSwaySessionName, env, tool)
  for v in ["GUI_ASSERT_XDG_DESKTOP_PORTAL", "GUI_ASSERT_XDG_DESKTOP_PORTAL_GTK",
            "GUI_ASSERT_GSETTINGS_SCHEMAS"]:
    discard requireEnvFile(linuxSwaySessionName, env, v)
  requireAtspiLauncher(linuxSwaySessionName, env)
  if vnc: discard requireOnPath(linuxSwaySessionName, env, "wayvnc")

proc startWayvnc(env: OrderedTable[string, string], runtimeDir: string):
    tuple[process: Process, port: int] =
  ## wayvnc on 127.0.0.1 (module doc). Raises naming what failed.
  let exe = findExe("wayvnc")
  if exe.len == 0: raise newException(OSError, "wayvnc is not on the PATH")
  let config = runtimeDir / "wayvnc.config"
  writeFile(config, "")
  var why = ""
  for attempt in 1 .. vncAttempts:
    let port = freeLoopbackPort()
    let log = runtimeDir / "wayvnc.log"
    let p = launchLogged(childEnv(env, baseEnvUnset), exe,
                         @["-C", config, "-o", "HEADLESS-1", "127.0.0.1", $port], log)
    let pid = p.processID
    why = waitVncListening(pid, proc (): bool = p.running, port,
                           monoNowNs() + int64(vncStartMs) * 1_000_000)
    if why.len == 0: return (p, port)
    why.add ": " & logTail(log)
    stopProcess(p)
  raise newException(OSError, why)

proc swayHostStart(spec: HostSpec): ServerRun =
  ## In the session host: the target, then wayvnc when asked.
  let t = newSwayTarget(spec.width, spec.height, scale = spec.scale,
                        runtimeDir = spec.runtimeDir)
  # The session's own plumbing (the settings portal's GTK backend, the
  # bar) does not register on the AT-SPI bus: `apps` of a fresh session then
  # lists what was started into it, not the session's machinery.
  # `NO_AT_BRIDGE` is never in `Session.env` (it is in `envUnset`).
  putEnv("NO_AT_BRIDGE", "1")
  try:
    t.start()
  except CatchableError:
    # A start that failed part way stops what it started (and removes its
    # runtime directory) before the failure is reported.
    try: t.stop()
    except CatchableError: discard
    raise
  finally:
    delEnv("NO_AT_BRIDGE")
  var env = initOrderedTable[string, string]()
  for k, v in t.sessionEnv: env[k] = v
  env["XDG_SESSION_TYPE"] = "wayland"
  result.env = env
  result.runtimeDir = env.getOrDefault("XDG_RUNTIME_DIR", "")
  var vnc: Process = nil
  if spec.vnc:
    try:
      let (p, port) = startWayvnc(env, result.runtimeDir)
      vnc = p
      result.vnc = some(VncEndpoint(host: "127.0.0.1", port: port))
    except CatchableError:
      try: t.stop()
      except CatchableError: discard
      raise
  var plain = initTable[string, string]()
  for k, v in env: plain[k] = v
  let swaySock = env.getOrDefault("SWAYSOCK", "")
  result.alive = proc (): string =
    # The compositor answers on both its Wayland and its IPC socket.
    if not displayAnswers(plain).ok or not unixSocketAnswers(swaySock):
      return "compositor-exited"
    if vnc != nil and not vnc.running: return "vnc-exited"
    ""
  result.stop = proc () =
    stopProcess(vnc)
    try: t.stop()
    except CatchableError: discard

proc linuxSwayServer*(): PrivateServer =
  ## The `linux-sway` server for `linux_private`.
  PrivateServer(name: linuxSwaySessionName, idPrefix: "sway",
    backends: SessionBackends(capture: "linux-wlr", tree: "linux-atspi",
                              input: "linux-wlr-virtual"),
    supportsVnc: true, supportsScale: true,
    preflight: swayPreflight, hostStart: swayHostStart)
