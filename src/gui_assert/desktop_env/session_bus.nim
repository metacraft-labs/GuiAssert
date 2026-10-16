## A private desktop session for a headless target.
##
## The application under test reads desktop settings the way it would on a
## real desktop: from `org.freedesktop.portal.Settings`, served by
## `xdg-desktop-portal` with its GTK backend, which reads GSettings. Here all
## three are private to the run:
##
##   * a `dbus-daemon --session` on a socket in the run's runtime directory;
##   * GSettings on the `keyfile` backend, under the run's `XDG_CONFIG_HOME`,
##     with the schemas pinned by GuiAssert's flake
##     (`GUI_ASSERT_GSETTINGS_SCHEMAS`);
##   * `xdg-desktop-portal-gtk` and `xdg-desktop-portal`, started directly
##     (not bus-activated), the frontend told to prefer the GTK backend.
##
## Nothing on the host — its session bus, its dconf database, its portals —
## is read or written.
##
## Settings portal: https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.Settings.html

import std/[os, osproc, streams, strtabs, strutils, times]

type
  SessionBus* = object
    runtimeDir*: string
    configDir*: string
    env*: StringTableRef        ## what a client of the session needs
    processes: seq[Process]
    started*: bool

proc pathExists*(path: string): bool =
  ## Whether anything — a socket included — exists at `path`. `fileExists`
  ## is true for regular files only, and the session bus is a socket.
  try:
    discard getFileInfo(path, followSymlink = false)
    true
  except OSError:
    false

proc requireEnvPath(name: string): string =
  result = getEnv(name)
  if result.len == 0 or not (fileExists(result) or dirExists(result)):
    raise newException(OSError, name & " is not set to an existing path " &
                       "(run inside GuiAssert's `nix develop`)")

proc childEnv(bus: SessionBus): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs(): result[k] = v
  for k, v in bus.env: result[k] = v

proc launch(bus: var SessionBus; exe: string; args: seq[string]; log: string) =
  let p = startProcess("/bin/sh", args = @["-c",
    "exec " & quoteShellCommand(@[exe] & args) & " >" & quoteShell(log) & " 2>&1"],
    env = bus.childEnv, options = {})
  bus.processes.add p

proc call(bus: SessionBus; args: seq[string]): (string, int) =
  let p = startProcess(args[0], args = args[1 .. ^1], env = bus.childEnv,
                       options = {poUsePath, poStdErrToStdOut})
  let output = p.outputStream.readAll()
  let code = p.waitForExit()
  p.close()
  (output, code)

proc readSetting*(bus: SessionBus; namespace, key: string): (string, int) =
  ## Read a setting THROUGH THE PORTAL, as an application does.
  bus.call(@["gdbus", "call", "--session", "-d", "org.freedesktop.portal.Desktop",
             "-o", "/org/freedesktop/portal/desktop",
             "-m", "org.freedesktop.portal.Settings.ReadOne", namespace, key])

proc gsettings*(bus: SessionBus; args: varargs[string]): string =
  let (output, code) = bus.call(@["gsettings"] & @args)
  if code != 0:
    raise newException(OSError, "gsettings " & args.join(" ") & ": " & output.strip())
  output.strip()

proc startSessionBus*(runtimeDir, desktopName: string;
                      displayEnv: StringTableRef): SessionBus =
  ## Start the bus and the portal stack. `displayEnv` is the compositor's
  ## (`WAYLAND_DISPLAY`, `XDG_RUNTIME_DIR`); the GTK backend is a GTK
  ## program and needs a display. Raises `OSError` naming what failed.
  let portal = requireEnvPath("GUI_ASSERT_XDG_DESKTOP_PORTAL")
  let portalGtk = requireEnvPath("GUI_ASSERT_XDG_DESKTOP_PORTAL_GTK")
  let schemas = requireEnvPath("GUI_ASSERT_GSETTINGS_SCHEMAS")
  result.runtimeDir = runtimeDir
  result.configDir = runtimeDir / "config"
  createDir(result.configDir / "xdg-desktop-portal")
  # The frontend picks a backend per interface from portals.conf; GTK is the
  # one that implements Settings over GSettings.
  writeFile(result.configDir / "xdg-desktop-portal" / "portals.conf",
            "[preferred]\ndefault=gtk\n")
  let busSocket = runtimeDir / "bus"
  result.env = newStringTable(modeCaseSensitive)
  for k, v in displayEnv: result.env[k] = v
  result.env["DBUS_SESSION_BUS_ADDRESS"] = "unix:path=" & busSocket
  result.env["GSETTINGS_BACKEND"] = "keyfile"
  result.env["GSETTINGS_SCHEMA_DIR"] = schemas
  result.env["XDG_CONFIG_HOME"] = result.configDir
  result.env["XDG_CURRENT_DESKTOP"] = desktopName
  # Where the frontend finds the backend's `gtk.portal` definition.
  result.env["XDG_DESKTOP_PORTAL_DIR"] =
    portalGtk.parentDir.parentDir / "share" / "xdg-desktop-portal" / "portals"
  # GIO must not reach for the host's gvfs or dconf.
  result.env["GIO_USE_VFS"] = "local"
  result.env["GTK_USE_PORTAL"] = "0"

  result.launch(findExe("dbus-daemon"), @["--session", "--nofork",
                "--address=unix:path=" & busSocket], runtimeDir / "dbus.log")
  let deadline = epochTime() + 5
  while not pathExists(busSocket):
    if epochTime() > deadline:
      raise newException(OSError, "the private session bus did not start: " &
                         readFile(runtimeDir / "dbus.log"))
    sleep(20)
  result.launch(portalGtk, @["--replace"], runtimeDir / "portal-gtk.log")
  result.launch(portal, @["--replace"], runtimeDir / "portal.log")
  # Ready when the frontend answers a Settings read.
  while true:
    let (output, code) = result.readSetting("org.gnome.desktop.wm.preferences",
                                            "button-layout")
    if code == 0: break
    if epochTime() > deadline + 10:
      raise newException(OSError, "the settings portal did not answer: " &
                         output.strip())
    sleep(100)
  result.started = true

proc stop*(bus: var SessionBus) =
  for p in bus.processes:
    try:
      if p.running:
        p.terminate()
        let deadline = epochTime() + 2
        while p.running and epochTime() < deadline: sleep(20)
        if p.running: p.kill()
      p.close()
    except OSError: discard
  bus.processes.setLen 0
  # xdg-desktop-portal mounts the document portal's FUSE filesystem under
  # the runtime directory; it must be unmounted before the directory can go.
  for mount in ["doc"]:
    let path = bus.runtimeDir / mount
    if dirExists(path):
      discard execCmdEx(quoteShellCommand(["fusermount", "-uz", path]))
  bus.started = false
