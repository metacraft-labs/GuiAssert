## The `linux-host` session backend (spec §4.2, §6.3): the caller's own Linux
## session, the one its environment names (a sway, GNOME Shell or X server
## with its session bus), attached to rather than started.
##
## GS7 gives it what the accessibility-tree verbs need of a session and what
## an attached session can do without starting anything (the private
## sessions, `linux-sway`, `linux-gnome` and `linux-xvfb`, and the attach
## checks of the host session are GS10's):
##
## * **`session-list` / `session-info host`**: the one `host` session, its
##   displays as the session's capture backend reports them, its backends the
##   ones this invocation selected, `createdAt` the host's boot time
##   (`/proc/stat` `btime`; the session cannot be older). No other session
##   exists here; `session-start` is exit 4 / `not-implemented`.
## * **`apps`**: every process that owns a window in the session (the capture
##   backend's `windows`) or is registered on the session's AT-SPI bus. An
##   application's `name` is its AT-SPI name (what `tree --app` matches),
##   else its process name (`/proc/<pid>/comm`); `appId` its Wayland app id;
##   `frontmost` whether it owns the focused window; `accessible` (C5) true
##   when it is registered on the session's AT-SPI bus, false when it is not,
##   null when the session has no reachable AT-SPI bus (never false for
##   "could not look"). `hidden` is false: Linux sessions have no hidden
##   applications.
## * **`app-launch -- <argv>` / `--app <path>`**: the program in a session of
##   its own (double fork, `setsid`), standard streams on /dev/null, with the
##   invocation's environment and `--env` over it; `--bundle-id` is exit 4 /
##   `unsupported-option` (Linux has no bundles). `--wait-window-ms` polls the
##   session's windows for an on-screen one of the new pid (an X11 toolkit
##   also owns unmapped helper windows, which are not "a window appeared").
## * **`app-quit <pid>`**: SIGTERM (SIGKILL with `--force`) to an application
##   of the session (one `apps` lists, or a process whose environment names
##   this session's display, runtime directory and bus, such as a windowless
##   program `app-launch` started), and a wait of up to 5 s for it to exit;
##   `exitCode` is null, since the process is not this one's child. Any other
##   pid is exit 3 / `app`.
## * **`permissions`**: Linux has no Screen Recording or desktop-access
##   permission (`not-applicable`); `accessibility` is `granted` when the
##   session's AT-SPI bus answers, `denied` when the session has no AT-SPI
##   bus to answer (`atspi-disabled`), `unknown` when it has no session bus.
##   Input synthesis is GS8's (`unknown`).

import std/[algorithm, json, options, os, posix, sequtils, sets, strutils, tables]

import ../../core/[contract, desktop_types, interfaces]
import ../../cancel
import ../capture/linux_common
import ../tree/linux_atspi

const
  linuxHostName* = "linux-host"
    ## The backend's contract name.
  quitWaitMs = 5000
  pollMs = 100

type
  LinuxHostConfig* = object
    ## What the backend runs with.
    env*: Table[string, string]      ## the invocation's environment
    token*: CancelToken
    stateDir*: string
    capture*: proc (): CaptureBackend {.closure.}
      ## The session's capture backend (its displays and windows); raises
      ## when it cannot be had.
    atspi*: LinuxAtspiConfig         ## the session's AT-SPI bus
    backends*: SessionBackends       ## what this invocation selected

proc sessionFailed(msg: string): ref BackendError =
  newBackendError(BackendError, linuxHostName, "session-failed", msg)

proc notFoundErr(reason, msg: string): ref BackendNotFoundError =
  newBackendError(BackendNotFoundError, linuxHostName, reason, msg)

proc bootTimeMs(): int64 =
  ## The host's boot time, Unix milliseconds (proc(5), `/proc/stat` `btime`).
  try:
    for line in readFile("/proc/stat").splitLines:
      if line.startsWith("btime "): return parseBiggestInt(line[6 .. ^1].strip) * 1000
  except IOError, OSError, ValueError: discard
  0

proc processName(pid: int): string =
  try: readFile("/proc/" & $pid & "/comm").strip
  except IOError, OSError: ""

proc processRunning(pid: int): bool =
  ## Whether `pid` is a live process (a zombie is not).
  processStartTime(pid).len > 0

proc windowsOf(cfg: LinuxHostConfig, session: string): seq[Window] =
  let cap = cfg.capture()
  cap.windows(session, WindowFilter(allLayers: true, includeOffscreen: true)).windows

proc hostSession(cfg: LinuxHostConfig): Session =
  var displays: seq[Display]
  try: displays = cfg.capture().displays(hostSessionId)
  except CatchableError: displays = @[]
  Session(id: hostSessionId, name: none(string), kind: skHost, backend: linuxHostName,
          platform: spLinux, state: ssRunning, lifetime: slDetached,
          isolation: hostIsolation(), displays: displays, backends: cfg.backends,
          createdAt: formatTimestamp(bootTimeMs()), hostPid: none(int))

proc listApps(cfg: LinuxHostConfig, session: string): seq[App] =
  var windows: seq[Window]
  var windowError: ref Exception = nil
  try: windows = cfg.windowsOf(session)
  except CatchableError as e: windowError = e
  let registered = registeredApps(cfg.atspi)
  if windowError != nil and (registered.isNone or registered.get.len == 0):
    raise windowError
  var names = initTable[int, string]()
  if registered.isSome:
    for a in registered.get:
      if a.name.len > 0 and a.pid notin names: names[a.pid] = a.name
  var pids = initHashSet[int]()
  for w in windows: pids.incl w.pid
  if registered.isSome:
    for a in registered.get: pids.incl a.pid
  var sorted = toSeq(pids)
  sorted.sort()
  for pid in sorted:
    if pid <= 0: continue
    var app = App(pid: pid, hidden: false)
    app.name = names.getOrDefault(pid, processName(pid))
    for w in windows:
      if w.pid == pid:
        if app.appId.isNone: app.appId = w.appId
        if app.name.len == 0: app.name = w.app
        if w.focused: app.frontmost = true
    if app.name.len == 0: app.name = "pid-" & $pid
    app.accessible = if registered.isNone: none(bool)
                     else: some(registered.get.anyIt(it.pid == pid))
    result.add app

proc sessionKeys(env: Table[string, string]): seq[(string, string)] =
  ## The variables that name a session: its display, its runtime directory
  ## and its bus.
  for k in ["WAYLAND_DISPLAY", "XDG_RUNTIME_DIR", "DISPLAY", "DBUS_SESSION_BUS_ADDRESS"]:
    let v = env.getOrDefault(k, "")
    if v.len > 0: result.add (k, v)

proc runsInSession(cfg: LinuxHostConfig, pid: int): bool =
  ## Whether process `pid` was started into this session: its environment
  ## (`/proc/<pid>/environ`, readable for this user's own processes) names
  ## the same display, runtime directory and bus as the invocation's.
  let ours = sessionKeys(cfg.env)
  if ours.len == 0: return false
  var theirs = initTable[string, string]()
  try:
    for kv in readFile("/proc/" & $pid & "/environ").split('\0'):
      let eq = kv.find('=')
      if eq > 0: theirs[kv[0 ..< eq]] = kv[eq + 1 .. ^1]
  except IOError, OSError:
    return false
  for (k, v) in ours:
    if theirs.getOrDefault(k, "") != v: return false
  true

proc resolveProgram(cfg: LinuxHostConfig, exe: string): string =
  ## `exe` as an executable path: as given when it has a slash, else found
  ## on the invocation's PATH. Not found (exit 3 / `file`) otherwise.
  if '/' in exe:
    if fileExists(exe) and access(exe.cstring, X_OK) == 0: return exe
    raise notFoundErr("file", "no executable at " & exe)
  for dir in cfg.env.getOrDefault("PATH", "").split(':'):
    if dir.len == 0: continue
    let p = dir / exe
    if fileExists(p) and access(p.cstring, X_OK) == 0: return p
  raise notFoundErr("file", "'" & exe & "' is not on the PATH")

proc newLinuxHostSession*(cfg: LinuxHostConfig): SessionBackend =
  ## The `linux-host` session backend.
  result.name = linuxHostName

  result.start = proc (spec: SessionSpec): Session =
    if spec.kind == skHost:
      raise badArgs("invalid-value", "the host session always exists; it is never started")
    raise unavailable(linuxHostName, "not-implemented", "linux-host attaches to the " &
      "caller's own session; private " & $spec.kind & " sessions are not implemented yet")

  result.list = proc (): seq[Session] = @[cfg.hostSession()]

  result.info = proc (id: string): Session =
    if id != hostSessionId: raise notFoundErr("session", "no session '" & id & "'")
    cfg.hostSession()

  result.stop = proc (id: string, force: bool): Session =
    raise notFoundErr("session", "no session '" & id & "'")

  result.apps = proc (session: string): seq[App] = cfg.listApps(session)

  result.launch = proc (session: string, spec: LaunchSpec): LaunchReport =
    var argv: seq[string]
    case spec.kind
    of lkBundleId:
      raise unavailable(linuxHostName, "unsupported-option",
        "Linux applications have no bundle ids; launch them with -- <argv> or --app <path>")
    of lkAppPath: argv = @[spec.appPath]
    of lkArgv: argv = spec.argv
    argv[0] = cfg.resolveProgram(argv[0])
    var env = cfg.env
    for (k, v) in spec.env: env[k] = v
    let capCfg = LinuxCaptureConfig(stateDir: cfg.stateDir, token: cfg.token, env: env)
    var started: tuple[pid: int, startTime: string]
    try:
      started = spawnDetached(capCfg, linuxHostName, argv, "/dev/null")
    except BackendError as e:
      raise sessionFailed("cannot start " & argv[0].extractFilename & ": " & e.msg)
    let app = App(pid: started.pid, name: argv[0].extractFilename, hidden: false,
                  accessible: none(bool))
    result = LaunchReport(app: app, window: none(Window))
    proc firstWindow(): Option[Window] =
      try:
        for w in cfg.windowsOf(session):
          if w.pid == started.pid and w.onScreen: return some(w)
      except CatchableError: discard
      none(Window)
    result.window = firstWindow()
    if result.window.isNone and spec.waitWindowMs.isSome:
      let startNs = monoNowNs()
      while result.window.isNone:
        if not processRunning(started.pid):
          raise sessionFailed(argv[0].extractFilename & " (pid " & $started.pid &
            ") exited before it showed a window")
        if elapsedMsSince(startNs) >= spec.waitWindowMs.get:
          raise newContractError(ekTimeout, "condition-not-met",
            "application " & $started.pid & " opened no window within --wait-window-ms " &
            $spec.waitWindowMs.get & "; it is still running",
            details = %*{"app": app.toJson})
        cfg.token.sleepCancellable(pollMs)
        result.window = firstWindow()

  result.quit = proc (session: string, pid: int, force: bool): QuitReport =
    # The process is identified by pid AND start time, read before it is
    # vetted: a pid reused while this verb runs is neither signalled nor
    # mistaken for the application still running. (pid <= 0 would signal a
    # process group; no process has such a pid, so it is not found.)
    let started = if pid > 0: processStartTime(pid) else: ""
    if started.len == 0 or
       not (cfg.runsInSession(pid) or cfg.listApps(session).anyIt(it.pid == pid)):
      raise notFoundErr("app", "no application with pid " & $pid & " in this session")
    proc same(): bool = processStartTime(pid) == started
    if not same():
      raise notFoundErr("app", "no application with pid " & $pid & " in this session")
    if kill(Pid(pid), (if force: SIGKILL else: SIGTERM)) != 0:
      if errno == ESRCH: return QuitReport(pid: pid, exited: true, exitCode: none(int))
      raise sessionFailed("cannot signal pid " & $pid & ": " & $strerror(errno))
    let startNs = monoNowNs()
    while same() and elapsedMsSince(startNs) < quitWaitMs:
      cfg.token.sleepCancellable(20)
    QuitReport(pid: pid, exited: not same(), exitCode: none(int))

  result.permissions = proc (request: Option[string]): Permissions =
    let hasBus = cfg.env.getOrDefault("AT_SPI_BUS_ADDRESS", "").len > 0 or
                 cfg.env.getOrDefault("DBUS_SESSION_BUS_ADDRESS", "").len > 0
    let ax = if not hasBus: psUnknown
             elif atspiReachable(cfg.atspi): psGranted
             else: psDenied
    Permissions(screenRecording: psNotApplicable, accessibility: ax,
                inputSynthesis: psUnknown, desktopAccess: psNotApplicable,
                identity: none(string))

  result.features = proc (probe: bool): seq[Feature] =
    for f in ["session-management", "app-management"]:
      result.add Feature(feature: f, backend: linuxHostName, state: fsAvailable,
                         reason: none(string), remedy: none(string))
    for f in ["session-virtual-display", "session-isolated", "session-headless",
              "session-vnc"]:
      result.add Feature(feature: f, backend: linuxHostName, state: fsUnavailable,
                         reason: some("not-implemented"),
                         remedy: some("select a session backend that starts private " &
                                      "sessions (see `guiassert capabilities`)"))
