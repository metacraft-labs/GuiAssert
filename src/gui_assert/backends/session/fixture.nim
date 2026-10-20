## The fixture session backend (spec §6.1, §9.2): sessions, applications and
## permissions of the fixture desktop.
##
## A fixture session is real in the ways the contract can observe: its
## record lives at `<state-dir>/sessions/<id>.json`, it is owned by a
## detached **session host** process (this program run with the internal,
## non-contract verb `__session-host`) whose pid is recorded, and every read
## reconciles the record against that process: a session whose host died is
## reported with `state: "error"`, never as running. Each session gets its
## own fixture desktop, seeded from the scenario.
##
## The reserved session `host` always exists and is never started or
## stopped. `--vnc` is refused (`unsupported-option`): the fixture has no
## remote-view endpoint to offer, and inventing one would be a lie.

import std/[json, options, os, osproc, streams, strutils, tables]

when defined(posix):
  import std/posix
else:
  import std/winlean

import ../../core/[geometry, contract, desktop_types, interfaces, tree_types]
import ../../[cancel, state_store]
import ../fixture_desktop

const
  hostGraceMs = 5000
    ## How long a session host waits for its record before giving up.

proc fixtureBackends(): SessionBackends =
  SessionBackends(capture: fixtureBackendName, tree: fixtureBackendName,
                  input: fixtureBackendName)

proc hostSession(scen: Desktop): Session =
  ## The always-present `host` session of the fixture desktop.
  Session(id: hostSessionId, name: none(string), kind: skHost,
          backend: fixtureBackendName, platform: spFixture, state: ssRunning,
          lifetime: slDetached, isolation: hostIsolation(),
          displays: scen.displays, backends: fixtureBackends(),
          createdAt: formatTimestamp(scen.clockStartMs), hostPid: none(int))

proc isolationOf(kind: SessionKind): Isolation =
  ## The fixture's isolation per kind, stated the way the platforms state it:
  ## a virtual display isolates pixels only; the other kinds isolate all.
  case kind
  of skHost: hostIsolation()
  of skVirtualDisplay: Isolation(pixels: true, input: false, clipboard: false)
  of skIsolated, skHeadless: Isolation(pixels: true, input: true, clipboard: true)

proc reconcile(s: Session): Session =
  ## The session as it really is: a running session whose host process is
  ## gone is in state `error`.
  result = s
  if s.state in {ssRunning, ssStarting} and s.hostPid.isSome and
     not processAlive(s.hostPid.get):
    result.state = ssError
    result.stateReason = some("host-exited")

proc spawnHost(cfg: FixtureConfig, id: string): int =
  ## Start the detached session host for session `id`; returns its pid.
  ##
  ## The program started here forks the real host, prints the host's pid and
  ## exits (POSIX), so the host is never a child of the starter: a starter
  ## that lives on (the `serve` daemon) would otherwise keep every stopped
  ## host as a zombie that still looks alive to every other process.
  if cfg.selfExe.len == 0 or not fileExists(cfg.selfExe):
    raise failed("session-failed", "cannot start a session host: the guiassert " &
      "executable is unknown")
  when defined(windows):
    # Windows has no fork: the host is this child. Keep the caller's own
    # standard handles out of it, or a caller reading our stdout to EOF
    # would wait for the session to end. (Untested on Windows so far; see
    # the GS2 notes in Desktop-Substrate.milestones.org.)
    for h in [STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE]:
      discard setHandleInformation(getStdHandle(h), DWORD(HANDLE_FLAG_INHERIT), 0)
  var p: Process
  try:
    p = startProcess(cfg.selfExe,
                     args = @["__session-host", "--state-dir", cfg.stateDir, id],
                     options = {})
  except OSError as e:
    raise failed("session-failed", "cannot start the session host: " & e.msg)
  try:
    p.inputStream.close()
    var line = ""
    let ok = p.outputStream.readLine(line)
    when defined(posix):
      discard p.waitForExit(10_000)
    try:
      result = if ok: parseInt(line.strip) else: 0
    except ValueError:
      result = 0
    if result <= 0:
      raise failed("session-failed", "the session host did not report its pid")
  finally:
    p.close()

proc sessionHostLoop(stateDir, id: string): int =
  ## Live as long as the session record names this process.
  let me = getCurrentProcessId()
  var waited = 0
  var everMine = false
  while true:
    var mine = false
    try:
      let r = readSessionRecord(stateDir, id)
      mine = r.isSome and r.get.session.hostPid == some(me)
    except CatchableError:
      return 1
    if mine: everMine = true
    elif everMine: return 0             # stopped: the record is gone
    elif waited >= hostGraceMs: return 0 # the starter never recorded us
    sleep(100)
    waited += 100

proc runFixtureSessionHost*(stateDir, id: string): int =
  ## The body of `guiassert __session-host`: detach the real host (POSIX:
  ## fork, new session, no inherited descriptors), print its pid on stdout
  ## for the starter, and live as long as the session record names it.
  ## Returns the exit code.
  when defined(posix):
    let child = fork()
    if child < 0:
      stderr.writeLine("guiassert __session-host: fork failed")
      return 1
    if child > 0:
      stdout.writeLine($child)
      stdout.flushFile()
      return 0
    discard setsid()
    # Hold nothing of the starter's: its stdio and any descriptor it leaked
    # to us (a pipe its own caller reads to EOF would otherwise stay open for
    # the life of the session).
    let devnull = posix.open("/dev/null", O_RDWR)
    if devnull >= 0:
      for fd in 0 .. 2: discard dup2(devnull, cint(fd))
      if devnull > 2: discard posix.close(devnull)
    for fd in 3 ..< 1024: discard posix.close(cint(fd))
  else:
    stdout.writeLine($getCurrentProcessId())
    stdout.flushFile()
  sessionHostLoop(stateDir, id)

proc newFixtureSession*(cfg: FixtureConfig): SessionBackend =
  ## The fixture session backend. Raises `backend-unavailable` when
  ## GUIASSERT_FIXTURE_UNAVAILABLE names `session`.
  cfg.checkModuleAvailable(fmSession)
  result.name = fixtureBackendName

  result.start = proc (spec: SessionSpec): Session =
    if spec.kind == skHost:
      raise badArgs("invalid-value", "the host session always exists; it is never started")
    if spec.vnc:
      raise unsupported("the fixture has no remote-view endpoint; --vnc cannot be honoured")
    let scen = loadScenario(cfg.scenarioPath)
    var displays = scen.displays
    if spec.size.isSome or spec.scale.isSome or spec.displays != 1:
      let size = spec.size.get(scen.displays[0].bounds.size)
      let scale = spec.scale.get(1.0)
      displays = @[]
      for i in 0 ..< spec.displays:
        displays.add Display(id: "display-" & $(i + 1),
                             name: some("Fixture Display " & $(i + 1)),
                             bounds: rect(i * size.width, 0, size.width, size.height),
                             scale: scale, primary: i == 0, isVirtual: true)
    cfg.transact(t):
      let id = if spec.name.isSome: spec.name.get else: t.nextSessionId()
      if id == hostSessionId:
        raise badArgs("invalid-name", "'host' is the reserved id of the caller's session")
      if readSessionRecord(cfg.stateDir, id).isSome:
        raise badArgs("conflicting-arguments", "a session named '" & id &
          "' already exists")
      result = Session(id: id, name: spec.name, kind: spec.kind,
                       backend: fixtureBackendName, platform: spFixture,
                       state: ssRunning, lifetime: spec.lifetime,
                       isolation: isolationOf(spec.kind), displays: displays,
                       backends: fixtureBackends(), createdAt: t.nowStamp())
      result.env["GUIASSERT_SESSION"] = id
      var d = scen
      d.displays = displays
      cfg.saveDesktop(id, d)
      # The record exists (state starting) before the host does, so the
      # host never waits on a record that will not appear.
      var starting = result
      starting.state = ssStarting
      writeSessionRecord(cfg.stateDir, starting,
                         %*{"backend": fixtureBackendName,
                            "account": (if spec.account.isSome: %spec.account.get
                                        else: newJNull())})
      let pid = cfg.spawnHost(id)
      result.hostPid = some(pid)
      writeSessionRecord(cfg.stateDir, result,
                         %*{"backend": fixtureBackendName,
                            "account": (if spec.account.isSome: %spec.account.get
                                        else: newJNull())})

  result.list = proc (): seq[Session] =
    let scen = loadScenario(cfg.scenarioPath)
    result.add hostSession(scen)
    for id in listSessionIds(cfg.stateDir):
      let r = readSessionRecord(cfg.stateDir, id)
      if r.isSome: result.add reconcile(r.get.session)

  result.info = proc (id: string): Session =
    if id == hostSessionId:
      return hostSession(loadScenario(cfg.scenarioPath))
    let r = readSessionRecord(cfg.stateDir, id)
    if r.isNone: raise notFound("session", "no session '" & id & "'")
    reconcile(r.get.session)

  result.stop = proc (id: string, force: bool): Session =
    if id == hostSessionId:
      raise badArgs("invalid-value", "the host session is never stopped")
    let r = readSessionRecord(cfg.stateDir, id)
    if r.isNone: raise notFound("session", "no session '" & id & "'")
    result = r.get.session
    if result.hostPid.isSome:
      signalProcess(result.hostPid.get, force)
      if not waitProcessGone(result.hostPid.get, 3000):
        signalProcess(result.hostPid.get, true)
        if not waitProcessGone(result.hostPid.get, 2000):
          raise failed("session-failed", "the session host " & $result.hostPid.get &
            " does not exit")
    cfg.transact(t):
      removeRecord(sessionRecordPath(cfg.stateDir, id))
      cfg.removeDesktop(id)
    result.state = ssStopped
    result.stateReason = none(string)

  result.apps = proc (session: string): seq[App] =
    cfg.transact(t):
      result = cfg.loadDesktop(t, session).apps

  result.launch = proc (session: string, spec: LaunchSpec): LaunchReport =
    cfg.token.checkpoint()
    cfg.transact(t):
      var d = cfg.loadDesktop(t, session)
      let name = case spec.kind
        of lkBundleId: spec.bundleId.rsplit('.', 1)[^1]
        of lkAppPath: spec.appPath.extractFilename.changeFileExt("")
        of lkArgv: spec.argv[0].extractFilename
      if name.len == 0:
        raise badArgs("invalid-value", "cannot derive an application name")
      let pid = d.nextPid
      inc d.nextPid
      let app = App(pid: pid, name: name,
                    bundleId: (if spec.kind == lkBundleId: some(spec.bundleId)
                               else: none(string)),
                    appId: none(string), frontmost: true, hidden: false)
      for a in d.apps.mitems: a.frontmost = false
      d.apps.add app
      let wb = rect(160, 120, 480, 320)
      let win = Window(id: "fixture-window-" & $pid, pid: pid, app: name,
                       appId: none(string), title: some(name), bounds: wb,
                       display: some(d.displayOf(none(string)).id), layer: 0,
                       onScreen: true, focused: true, minimized: false)
      for w in d.windows.mitems: w.focused = false
      d.windows.insert(win, 0)
      d.trees.add AppTree(pid: pid, root: FNode(
        role: roleApplication, nativeRole: "AXApplication", name: some(name),
        children: @[FNode(role: roleWindow, nativeRole: "AXWindow", name: some(name),
                          bounds: some(wb), states: {stVisible})]))
      cfg.saveDesktop(session, d)
      result = LaunchReport(app: app, window: some(win))

  result.quit = proc (session: string, pid: int, force: bool): QuitReport =
    cfg.transact(t):
      var d = cfg.loadDesktop(t, session)
      var found = false
      for i in countdown(d.apps.high, 0):
        if d.apps[i].pid == pid:
          d.apps.delete(i)
          found = true
      if not found: raise notFound("app", "no application with pid " & $pid)
      for i in countdown(d.windows.high, 0):
        if d.windows[i].pid == pid: d.windows.delete(i)
      for i in countdown(d.trees.high, 0):
        if d.trees[i].pid == pid: d.trees.delete(i)
      if d.windows.len > 0:
        d.windows[0].focused = true
        for a in d.apps.mitems: a.frontmost = a.pid == d.windows[0].pid
      cfg.saveDesktop(session, d)
      result = QuitReport(pid: pid, exited: true,
                          exitCode: (if force: some(137) else: some(0)))

  result.permissions = proc (request: Option[string]): Permissions =
    let sr = if cfg.env.denyScreenRecording: psDenied else: psGranted
    let ax = if cfg.env.denyAccessibility: psDenied else: psGranted
    Permissions(screenRecording: sr, accessibility: ax, inputSynthesis: ax,
                desktopAccess: psNotApplicable, identity: some("guiassert-fixture"))

  result.features = proc (probe: bool): seq[Feature] =
    for k in [skVirtualDisplay, skIsolated, skHeadless]:
      result.add Feature(feature: "session-" & $k, backend: fixtureBackendName,
                         state: fsSupported, reason: none(string),
                         remedy: none(string))
    result.add Feature(feature: "session-vnc", backend: fixtureBackendName,
                       state: fsUnavailable, reason: some("unsupported-option"),
                       remedy: none(string))
