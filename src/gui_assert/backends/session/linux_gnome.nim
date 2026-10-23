## The `linux-gnome` session backend (spec §6.3, GS10): a private
## `gnome-shell --headless --wayland --virtual-monitor WxH`, started by the
## session host through the existing desktop-environment target
## (`desktop_env/gnome`): its own runtime directory under /tmp, its own
## session bus, settings on a private GSettings keyfile served by the
## settings portal, unsafe mode on (GNOME Shell's `Eval`, which the
## `linux-gnome` capture backend and `linux-mutter`'s window management
## read through). The shared lifecycle, the AT-SPI bus and the environment
## contract are `linux_private`'s.
##
## A GNOME session runs PipeWire, and `linux-mutter` needs it for pointer
## motion (Mutter defines absolute motion only against a screen-cast
## stream; GS8): the host starts `pipewire` in the session when it is on the
## PATH, and waits for its socket (`$XDG_RUNTIME_DIR/pipewire-0`). Without
## it the session still starts, and linux-mutter's pointer verbs answer
## exit 4 / `missing-tool` naming PipeWire, as GS8 specified.
##
## The session's verbs select `linux-gnome` (capture), `linux-atspi` (tree)
## and `linux-mutter` (input) unless the caller selects others (spec §3.4
## rule 5). The virtual monitor has scale 1; `--scale` other than 1 is exit
## 4 / `unsupported-option`, and so is `--vnc`: Mutter offers no
## wlr-screencopy for wayvnc, and GNOME's own remote desktop needs a user
## session's credentials store.
##
## The system bus is the host's (`desktop_env/gnome` module doc): GNOME
## Shell reads logind and NetworkManager there, as any session does, and
## writes nothing.

import std/[os, osproc, strtabs, tables]

import ../../core/desktop_types
import ../../[cancel, desktop_env]
import ../../desktop_env/[gnome, session_bus]
import ./[linux_host, linux_private]

const
  linuxGnomeSessionName* = "linux-gnome"
    ## The backend's contract name.
  pipewireStartMs = 10_000

proc gnomeShellPath(env: Table[string, string]): string =
  ## `GUI_ASSERT_GNOME_SHELL`, else `gnome-shell` on the PATH, else "".
  let named = env.getOrDefault("GUI_ASSERT_GNOME_SHELL", "")
  if named.len > 0: return (if fileExists(named): named else: "")
  onPath(env, "gnome-shell")

proc gnomePreflight(env: Table[string, string], vnc: bool) =
  ## What a GNOME session needs, checked before anything is started.
  if gnomeShellPath(env).len == 0:
    raise missingTool(linuxGnomeSessionName, "no gnome-shell (GUI_ASSERT_GNOME_SHELL is unset " &
      "or names no file, and none is on the PATH)",
      "install GNOME Shell or set GUI_ASSERT_GNOME_SHELL (GuiAssert's `nix develop` does)")
  for tool in ["dbus-daemon", "gdbus", "gsettings"]:
    discard requireOnPath(linuxGnomeSessionName, env, tool)
  for v in ["GUI_ASSERT_XDG_DESKTOP_PORTAL", "GUI_ASSERT_XDG_DESKTOP_PORTAL_GTK",
            "GUI_ASSERT_GSETTINGS_SCHEMAS"]:
    discard requireEnvFile(linuxGnomeSessionName, env, v)
  requireAtspiLauncher(linuxGnomeSessionName, env)

proc gnomeHostStart(spec: HostSpec): ServerRun =
  ## In the session host: the target, then PipeWire when it is installed.
  if getEnv("GUI_ASSERT_GNOME_SHELL").len == 0:
    putEnv("GUI_ASSERT_GNOME_SHELL", gnomeShellPath(processEnv()))
  let t = newGnomeTarget(spec.width, spec.height, runtimeDir = spec.runtimeDir)
  try:
    t.start()
  except CatchableError:
    # A start that failed part way stops what it started (and removes its
    # runtime directory) before the failure is reported.
    try: t.stop()
    except CatchableError: discard
    raise
  var env = initOrderedTable[string, string]()
  for k, v in t.sessionEnv: env[k] = v
  env["XDG_SESSION_TYPE"] = "wayland"
  result.env = env
  result.runtimeDir = env.getOrDefault("XDG_RUNTIME_DIR", "")
  var pipewire: Process = nil
  let pw = findExe("pipewire")
  if pw.len > 0:
    let log = result.runtimeDir / "pipewire.log"
    pipewire = launchLogged(childEnv(env, baseEnvUnset), pw, @[], log)
    let startNs = monoNowNs()
    while not pathExists(result.runtimeDir / "pipewire-0"):
      if not pipewire.running or elapsedMsSince(startNs) > pipewireStartMs:
        stopProcess(pipewire)
        try: t.stop()
        except CatchableError: discard
        raise newException(OSError, "PipeWire did not start in the session: " & logTail(log))
      sleep(20)
  var plain = initTable[string, string]()
  for k, v in env: plain[k] = v
  result.alive = proc (): string =
    if not displayAnswers(plain).ok: "compositor-exited" else: ""
  result.stop = proc () =
    stopProcess(pipewire)
    try: t.stop()
    except CatchableError: discard

proc linuxGnomeServer*(): PrivateServer =
  ## The `linux-gnome` server for `linux_private`.
  PrivateServer(name: linuxGnomeSessionName, idPrefix: "gnome",
    backends: SessionBackends(capture: "linux-gnome", tree: "linux-atspi",
                              input: "linux-mutter"),
    supportsVnc: false, supportsScale: false,
    preflight: gnomePreflight, hostStart: gnomeHostStart)
