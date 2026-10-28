## The `guiassert` verbs (spec §7.5): argument validation, backend
## selection, and the `data` object of every verb.
##
## Each verb validates its arguments completely before it touches a backend,
## so a malformed invocation never has a side effect, then calls the
## selected backend through the interfaces of `core/interfaces` and builds
## its `data` with the serializers of `core/contract`. Backend selection
## follows spec §3.4: per module, the first of `--<module>-backend`,
## `--backend`, `GUIASSERT_<MODULE>_BACKEND`, `GUIASSERT_BACKEND`, the
## session's own backends and the default (the platform's, which on Linux
## follows the caller's session for capture); an explicit selection
## never falls back to another backend.
##
## Every exit 4 and exit 6 failure names the capability it lacked in
## `details.feature`, a name of the closed vocabulary of `core/contract`
## (spec §7.3, §7.5 "Features"): each backend call runs inside `featured`
## with the feature it needs, and `verbFeature` gives the verb's own feature
## for everything else.

import std/[json, options, os, strutils, tables, math, times]

import ../core/[contract, geometry, image, png, ssim, hashing, segmentation,
                vision_windows, ocr_types, tree_types, desktop_types, interfaces,
                keys, sha256, secret_guard]
import ../[cancel, state_store]
import ../backends/fixture_desktop
import ../backends/capture/fixture as capture_fixture
import ../backends/ocr/fixture as ocr_fixture
import ../backends/tree/fixture as tree_fixture
import ../backends/input/fixture as input_fixture
import ../backends/session/fixture as session_fixture
import ./[args, context, registry, state]

when mediaCompiledIn:
  import ../media
  import ../backends/media/ffmpeg as media_ffmpeg

when macosCaptureCompiledIn:
  import ../backends/capture/macos_sck
  import ../backends/capture/macos_cgwindow

when linuxCaptureCompiledIn:
  import ../backends/capture/[linux_common, linux_wlr, linux_gnome, linux_x11,
                                linux_portal_pipewire]

when linuxTreeCompiledIn or linuxSessionCompiledIn:
  import ../backends/tree/linux_atspi

when linuxSessionCompiledIn:
  import ../backends/session/[linux_host, linux_private, linux_sway, linux_xvfb]
  import ../backends/session/linux_gnome as session_gnome

when linuxInputCompiledIn:
  import ../backends/input/[linux_common as input_common, linux_wlr_virtual, linux_mutter,
                              linux_xtest, linux_uinput]

when appleVisionCompiledIn:
  import ../backends/ocr/apple_vision

when tesseractCompiledIn:
  import ../backends/ocr/tesseract

proc fromBackendError*(e: ref BackendError): ref ContractError =
  ## The contract error for a backend error: not found (3), unavailable (4),
  ## permission denied (6) or failed (5), carrying the backend's reason and
  ## remedy. A reason outside the kind's closed set becomes `internal`.
  let kind =
    if e of ref BackendNotFoundError: ekNotFound
    elif e of ref BackendUnavailableError: ekBackendUnavailable
    elif e of ref PermissionDeniedError: ekPermissionDenied
    else: ekBackendError
  newContractError(kind, e.reason, e.msg, e.remedy,
                   %*{"backend": e.backend})

template featured*(feature: string, body: untyped): untyped =
  ## Run `body`; an exit 4 or exit 6 failure it raises carries `feature` as
  ## `details.feature` unless it names one already (`withFeature`).
  try:
    body
  except ContractError as x:
    raise withFeature(x, feature)
  except BackendError as x:
    raise withFeature(fromBackendError(x), feature)

type
  Selected* = object
    ## The backend chosen for a module and the rule that chose it.
    name*: string
    source*: string   ## module-flag, backend-flag, module-env, backend-env,
                      ## session, default

  VerbEnv* = object
    ## Everything a verb runs with once the global flags are resolved.
    inv*: Invocation
    ctx*: RunContext
    stateDir*: string
    session*: string                 ## the session the verb acts in
    sessionRecord*: Option[Session]  ## its record (none for `host`)
    selection*: array[Module, Selected]
    fixtureSelected*: bool
    fixtureCfg*: FixtureConfig
    timeoutMs*: Option[int]

const
  sessionPositionalVerbs = ["session-info", "session-stop"]
    ## Verbs whose session is their positional id rather than `--session`.
  sessionStateExempt = ["session-info", "session-stop", "session-list",
                        "session-start", "capabilities", "permissions"]
    ## Verbs that still run when the session is not running.
  defaultFps = 10.0
  defaultIntervalMs = 200

proc global(inv: Invocation, ctx: RunContext, name: string): Option[string] =
  ## A global flag: the invocation's own value, else the daemon default.
  if name in inv.globals: some(inv.globals[name])
  elif name in ctx.defaults: some(ctx.defaults[name])
  else: none(string)

proc emit(e: VerbEnv, event: string, data: JsonNode) =
  if e.ctx.emit != nil: e.ctx.emit(event, data)

proc resolvePath(e: VerbEnv, p: string): string =
  ## A path argument made absolute against the caller's directory.
  if p.len == 0: raise badArgs("invalid-value", "an empty path was given")
  absolutePath(p, e.ctx.cwd)

# ---------------------------------------------------------------------------
# Global resolution: contract, state dir, session, backends
# ---------------------------------------------------------------------------

proc reconcileRecord(s: Session): Session =
  ## A recorded session whose host process died is in state `error`.
  result = s
  if s.state in {ssRunning, ssStarting} and s.hostPid.isSome and
     not processAlive(s.hostPid.get):
    result.state = ssError
    result.stateReason = some("host-exited")

proc selectBackends(e: var VerbEnv) =
  ## Apply the selection rules of spec §3.4 to every module.
  let backendFlag = global(e.inv, e.ctx, "backend")
  let backendEnv = e.ctx.env.getOrDefault("GUIASSERT_BACKEND", "")
  for m in Module:
    if backendFlag.isSome and not isKnownBackend(m, backendFlag.get):
      raise badArgs("unknown-backend", "--backend '" & backendFlag.get &
        "' is not a " & $m & " backend")
    if backendEnv.len > 0 and not isKnownBackend(m, backendEnv):
      raise badArgs("unknown-backend", "GUIASSERT_BACKEND='" & backendEnv &
        "' is not a " & $m & " backend")
    let modFlag = global(e.inv, e.ctx, $m & "-backend")
    let modEnvName = "GUIASSERT_" & toUpperAscii($m) & "_BACKEND"
    let modEnv = e.ctx.env.getOrDefault(modEnvName, "")
    if modFlag.isSome and not isKnownBackend(m, modFlag.get):
      raise badArgs("unknown-backend", "--" & $m & "-backend '" & modFlag.get &
        "' is not a " & $m & " backend")
    if modEnv.len > 0 and not isKnownBackend(m, modEnv):
      raise badArgs("unknown-backend", modEnvName & "='" & modEnv &
        "' is not a " & $m & " backend")
    var sessionChoice = ""
    if e.sessionRecord.isSome:
      let s = e.sessionRecord.get
      sessionChoice = case m
        of modCapture: s.backends.capture
        of modTree: s.backends.tree
        of modInput: s.backends.input
        of modSession: s.backend
        of modOcr: ""
    e.selection[m] =
      if modFlag.isSome: Selected(name: modFlag.get, source: "module-flag")
      elif backendFlag.isSome: Selected(name: backendFlag.get, source: "backend-flag")
      elif modEnv.len > 0: Selected(name: modEnv, source: "module-env")
      elif backendEnv.len > 0: Selected(name: backendEnv, source: "backend-env")
      elif sessionChoice.len > 0 and isKnownBackend(m, sessionChoice):
        Selected(name: sessionChoice, source: "session")
      else: Selected(name: defaultFor(m, e.ctx.env), source: "default")

proc prepare*(inv: Invocation, ctx: RunContext): VerbEnv =
  ## Resolve the global flags of an invocation (spec §7.1). Raises
  ## `ContractError` for an unsupported contract, a bad flag value, a
  ## session that does not exist, an unknown backend, or a fixture scenario
  ## without a fixture backend.
  result.inv = inv
  result.ctx = ctx
  let contractFlag = global(inv, ctx, "contract")
  if contractFlag.isSome and not contractSupported(contractFlag.get):
    raise newContractError(ekBadArgs, "contract-unsupported",
      "this guiassert implements contract " & contractName & "/" & $contractMajor &
      ", not major '" & contractFlag.get & "'",
      details = %*{"implemented": [contractMajor]})
  let t = global(inv, ctx, "timeout-ms")
  if t.isSome:
    result.timeoutMs = some(parseIntValue("--timeout-ms", t.get, 1, 86_400_000))
  if inv.verb != "version":
    result.stateDir = resolveStateDir(global(inv, ctx, "state-dir"), ctx.env, ctx.cwd).dir
  # The session.
  let explicitSession = "session" in inv.globals
  if inv.verb in sessionlessVerbs and explicitSession:
    raise badArgs("conflicting-arguments", "'" & inv.verb &
      "' touches no session; --session does not apply")
  if inv.verb == "ocr" and inv.has("image") and explicitSession:
    raise badArgs("conflicting-arguments",
      "ocr --image reads a file; --session does not apply")
  result.session =
    if inv.verb in sessionPositionalVerbs: inv.positionals[0]
    else: global(inv, ctx, "session").get(hostSessionId)
  if result.session != hostSessionId and not isValidName(result.session):
    raise badArgs("invalid-name", "invalid session id '" & result.session &
      "' (session ids match [A-Za-z0-9][A-Za-z0-9._-]{0,63})")
  if result.session != hostSessionId and result.stateDir.len > 0:
    let rec = readSessionRecord(result.stateDir, result.session)
    if rec.isNone:
      raise newContractError(ekNotFound, "session", "no session '" &
        result.session & "'")
    result.sessionRecord = some(reconcileRecord(rec.get.session))
    when linuxSessionCompiledIn:
      # A private Linux session (GS10): reconciled against its host (pid and
      # start time) and its display server, and every backend of the verb
      # runs with the session's environment, as a process spawned into it
      # does (spec §6.1: the caller's minus envUnset, plus env).
      if rec.get.session.backend in linuxPrivateBackendNames:
        result.sessionRecord = some(reconcilePrivate(rec.get.session, rec.get.private))
        result.ctx.env = composeSessionEnv(ctx.env, rec.get.session)
    if inv.verb notin sessionStateExempt and
       result.sessionRecord.get.state != ssRunning:
      raise newContractError(ekBackendUnavailable, "session-not-running",
        "session '" & result.session & "' is " & $result.sessionRecord.get.state &
          (if result.sessionRecord.get.stateReason.isSome:
             " (" & result.sessionRecord.get.stateReason.get & ")" else: ""),
        remedy = "stop it with session-stop and start a new one",
        details = %*{"feature": nil, "session": result.session,
                     "state": $result.sessionRecord.get.state})
  if ctx.stdinOffered and not (inv.has("stdin") or inv.has("value-stdin") or
                               inv.has("secret-stdin")):
    raise badArgs("conflicting-arguments", "the request carries stdin, but '" &
      inv.verb & "' reads none (only type --stdin, element-action " &
      "--value-stdin, and screenshot and ocr --secret-stdin do)")
  selectBackends(result)
  for m in Module:
    if result.selection[m].name == fixtureBackendName:
      result.fixtureSelected = true
  let scenarioFlag = global(inv, ctx, "fixture-scenario")
  if scenarioFlag.isSome and not result.fixtureSelected:
    raise badArgs("conflicting-arguments",
      "--fixture-scenario applies only when a module selects the fixture backend")
  if result.fixtureSelected:
    var scenario = scenarioFlag
    if scenario.isNone:
      let s = ctx.env.getOrDefault("GUIASSERT_FIXTURE_SCENARIO", "")
      if s.len > 0: scenario = some(s)
    let ctxEmit = ctx.emit
    result.fixtureCfg = FixtureConfig(
      stateDir: result.stateDir,
      scenarioPath: (if scenario.isSome: some(absolutePath(scenario.get, ctx.cwd))
                     else: none(string)),
      env: parseFixtureEnv(ctx.env), token: ctx.token,
      emit: proc (event: string, data: JsonNode) =
        if ctxEmit != nil: ctxEmit(event, data),
      selfExe: ctx.selfExe, mediaAvailable: mediaCompiledIn)
    when mediaCompiledIn:
      try: result.fixtureCfg.ffmpegExe = resolveFfmpegBinary()
      except CatchableError: result.fixtureCfg.ffmpegExe = ""

proc fixtureInjection*(e: VerbEnv) =
  ## Apply GUIASSERT_FIXTURE_DELAY_MS and GUIASSERT_FIXTURE_FAIL to the verb
  ## when the fixture is selected.
  if not e.fixtureSelected: return
  let delay = e.fixtureCfg.env.delays.getOrDefault(e.inv.verb, 0)
  if delay > 0: e.ctx.token.sleepCancellable(delay)
  let f = e.fixtureCfg.env.injectedFailure(e.inv.verb)
  if f.isSome: raise f.get

proc captureFeatureOf(inv: Invocation): string =
  ## The capture feature a `--display` / `--window` / `--region` /
  ## `--own-pixels` target needs.
  if inv.has("own-pixels"): "own-pixels-capture"
  elif inv.has("window"): "window-capture"
  elif inv.has("region"): "region-capture"
  else: "display-capture"

proc verbFeature*(inv: Invocation): string =
  ## The feature of the vocabulary (spec §7.5, "Features") verb `inv` needs
  ## first, or "" for a verb that needs none (`version`, `capabilities`,
  ## `vision-compare`). A verb that needs two (ocr of a capture) names the
  ## other where it calls that backend.
  result = case inv.verb
    of "permissions", "session-list", "session-info", "session-stop": "session-management"
    of "session-start":
      if inv.has("vnc") or inv.has("vnc-socket"): "session-vnc"
      else: "session-" & inv.value("kind").get("")
    of "apps", "app-launch", "app-quit": "app-management"
    of "displays", "windows": "window-enumeration"
    of "window-focus", "window-set-bounds": "window-management"
    of "screenshot": captureFeatureOf(inv)
    of "record", "record-start", "record-stop", "recordings": "recording"
    of "ocr", "vision-windows": "ocr"
    of "tree", "find", "element": "tree-read"
    of "element-action": "element-actions"
    of "wait":
      if inv.has("element"): "tree-read"
      elif inv.has("text"): "ocr"
      else: "window-enumeration"
    of "move", "click", "drag", "scroll", "gesture": "pointer-input"
    of "type", "key": "keyboard-input"
    of "vision-segment": "video-decode"
    of "watch": (if inv.has("frames"): "display-capture" else: "window-enumeration")
    else: ""
  if result.len > 0 and not isFeature(result): result = ""

proc ensureAvailable(e: VerbEnv, m: Module) =
  let sel = e.selection[m]
  let u = unavailability(m, sel.name)
  if not u.ok:
    raise newContractError(ekBackendUnavailable, u.reason, u.message, u.remedy,
      %*{"module": $m, "backend": sel.name, "selectedBy": sel.source})
  if e.stateDir.len > 0: ensurePrivateDir(e.stateDir)

proc noConstructor(m: Module, name: string): ref ContractError =
  newContractError(ekInternal, "exception", "no constructor for the " & $m &
    " backend '" & name & "'")

when linuxCaptureCompiledIn:
  proc linuxCaptureNamed(e: VerbEnv, name: string,
                         env: Table[string, string]): Option[CaptureBackend] =
    ## The Linux capture backend `name` running with environment `env`, none
    ## for a name that is not one.
    let ctxEmit = e.ctx.emit
    let cfg = LinuxCaptureConfig(stateDir: e.stateDir, token: e.ctx.token, env: env,
      emit: proc (event: string, data: JsonNode) =
        if ctxEmit != nil: ctxEmit(event, data))
    if name == linuxWlrName: return some(newLinuxWlrCapture(cfg))
    if name == linuxGnomeName: return some(newLinuxGnomeCapture(cfg))
    if name == linuxX11Name: return some(newLinuxX11Capture(cfg))
    if name == linuxPortalPipewireName: return some(newLinuxPortalPipewireCapture(cfg))
    none(CaptureBackend)

proc captureBackend*(e: VerbEnv): CaptureBackend =
  ## The selected capture backend.
  e.ensureAvailable(modCapture)
  let name = e.selection[modCapture].name
  if name == fixtureBackendName: return newFixtureCapture(e.fixtureCfg)
  when macosCaptureCompiledIn:
    if name == macosSckName:
      let ctxEmit = e.ctx.emit
      return newMacosSckCapture(MacosSckConfig(stateDir: e.stateDir, token: e.ctx.token,
        emit: proc (event: string, data: JsonNode) =
          if ctxEmit != nil: ctxEmit(event, data)))
    if name == macosCgwindowName: return newMacosCgwindowCapture()
  when linuxCaptureCompiledIn:
    let linux = e.linuxCaptureNamed(name, e.ctx.env)
    if linux.isSome: return linux.get
  raise noConstructor(modCapture, name)

proc ocrBackend*(e: VerbEnv): OcrEngine =
  ## The selected OCR engine.
  e.ensureAvailable(modOcr)
  let name = e.selection[modOcr].name
  if name == fixtureBackendName: return newFixtureOcr(e.fixtureCfg)
  when appleVisionCompiledIn:
    if name == appleVisionName:
      return newAppleVisionOcr(AppleVisionConfig(token: e.ctx.token))
  when tesseractCompiledIn:
    if name == tesseractName:
      return newTesseractOcr(TesseractConfig(token: e.ctx.token))
  raise noConstructor(modOcr, name)

proc inputBackend*(e: VerbEnv): InputBackend
  ## (Below; `atspiConfig` clicks through it.)

when linuxTreeCompiledIn or linuxSessionCompiledIn:
  proc atspiConfig(e: VerbEnv): LinuxAtspiConfig =
    ## The `linux-atspi` configuration of an invocation: its environment
    ## names the session's buses, and its capture backend places frames on
    ## the desktop (a capture backend that cannot run here leaves bounds
    ## null rather than failing the tree read).
    ##
    ## Its input backend focuses the element's window before `focus` and
    ## clicks for `focus` by pointer (linux_atspi module doc, "Focus" and
    ## "Focus by pointer") when that backend can run in this binary;
    ## otherwise both are nil, and `focus` acts inside the window only and
    ## is not offered by pointer. Both go through the backend directly, not
    ## the `window-focus` and `click` verbs: the caller (`element-action`)
    ## already holds the session's lock.
    let env = e
    result = LinuxAtspiConfig(env: e.ctx.env, token: e.ctx.token,
      windows: proc (): seq[Window] =
        env.captureBackend().windows(env.session,
          WindowFilter(allLayers: true, includeOffscreen: true)).windows)
    let input = e.selection[modInput].name
    if input != fixtureBackendName and unavailability(modInput, input).ok:
      result.pointerClick = proc (at: Point) =
        discard env.inputBackend().click(env.session, at, mbLeft, 1, @[])
      result.focusWindow = proc (windowId: string) =
        # A backend that cannot focus windows (linux-uinput, an input
        # device) leaves the window as it is; `focus` then still has to see
        # the element `focused` to succeed.
        try: discard env.inputBackend().focusWindow(env.session, windowId)
        except BackendUnavailableError: discard

proc treeBackend*(e: VerbEnv): TreeBackend =
  ## The selected accessibility-tree backend.
  e.ensureAvailable(modTree)
  let name = e.selection[modTree].name
  if name == fixtureBackendName: return newFixtureTree(e.fixtureCfg)
  when linuxTreeCompiledIn:
    if name == linuxAtspiName: return newLinuxAtspiTree(e.atspiConfig)
  raise noConstructor(modTree, name)

proc inputBackend*(e: VerbEnv): InputBackend =
  ## The selected input backend. A Linux backend learns the session's
  ## displays and windows from the session's capture backend (the pointer
  ## extent of linux-uinput, the window `window-focus` reports).
  e.ensureAvailable(modInput)
  let name = e.selection[modInput].name
  if name == fixtureBackendName: return newFixtureInput(e.fixtureCfg)
  when linuxInputCompiledIn:
    let env = e
    let cfg = LinuxInputConfig(stateDir: e.stateDir, token: e.ctx.token, env: e.ctx.env,
      displays: proc (): seq[Display] = env.captureBackend().displays(env.session),
      windows: proc (): seq[Window] =
        env.captureBackend().windows(env.session,
          WindowFilter(allLayers: true, includeOffscreen: true)).windows)
    if name == linuxWlrVirtualName: return newLinuxWlrVirtualInput(cfg)
    if name == linuxMutterName: return newLinuxMutterInput(cfg)
    if name == linuxXtestName: return newLinuxXtestInput(cfg)
    if name == linuxUinputName: return newLinuxUinputInput(cfg)
  raise noConstructor(modInput, name)

when linuxSessionCompiledIn:
  proc linuxPrivateServer*(name: string): Option[PrivateServer] =
    ## The private Linux session server of backend `name`, none for another.
    case name
    of linuxSwaySessionName: some(linuxSwayServer())
    of linuxGnomeSessionName: some(linuxGnomeServer())
    of linuxXvfbSessionName: some(linuxXvfbServer())
    else: none(PrivateServer)

  proc linuxPrivateServers*(): seq[PrivateServer] =
    ## Every private Linux session server (for the session host).
    @[linuxSwayServer(), linuxGnomeServer(), linuxXvfbServer()]

proc sessionBackend*(e: VerbEnv): SessionBackend =
  ## The selected session backend.
  e.ensureAvailable(modSession)
  let name = e.selection[modSession].name
  if name == fixtureBackendName: return newFixtureSession(e.fixtureCfg)
  when linuxSessionCompiledIn:
    let env = e
    let stateDir = e.stateDir
    let hostCfg = LinuxHostConfig(env: e.ctx.env, token: e.ctx.token,
      stateDir: e.stateDir, atspi: e.atspiConfig,
      capture: proc (): CaptureBackend = env.captureBackend(),
      backends: SessionBackends(capture: e.selection[modCapture].name,
                                tree: e.selection[modTree].name,
                                input: e.selection[modInput].name),
      privateSessions: proc (): seq[Session] = listPrivateSessions(stateDir),
      session: e.session)
    if name == linuxHostName: return newLinuxHostSession(hostCfg)
    let server = linuxPrivateServer(name)
    if server.isSome:
      return newLinuxPrivateSession(LinuxPrivateConfig(env: e.ctx.env, token: e.ctx.token,
        stateDir: e.stateDir, selfExe: e.ctx.selfExe, host: hostCfg,
        displays: proc (sessionEnv: Table[string, string], capture: string): seq[Display] =
          # The session's displays through its own capture backend, with its
          # environment (the starter's check that its display server answers).
          when linuxCaptureCompiledIn:
            let cap = env.linuxCaptureNamed(capture, sessionEnv)
            if cap.isSome: return cap.get.displays(env.session)
          raise newContractError(ekBackendUnavailable, "not-compiled-in",
            "the capture backend '" & capture & "' is not compiled into this binary")),
        server.get)
  raise noConstructor(modSession, name)

template withSessionLock(e: VerbEnv, id: string, body: untyped) =
  ## Serialize verbs that change session `id` across processes (spec §7.6).
  ensurePrivateDir(e.stateDir / "sessions")
  withLock(sessionLockDir(e.stateDir, id), e.ctx.token):
    body

# ---------------------------------------------------------------------------
# Shared argument shapes
# ---------------------------------------------------------------------------

proc readInput(e: VerbEnv, flag: string): string =
  ## The whole standard input of the invocation, for `flag` (spec §7.5):
  ## taken exactly as given, nothing stripped, at most `maxTextFileBytes`.
  if e.ctx.stdin == nil:
    raise badArgs("missing-argument", flag & " reads standard input, and this " &
      "invocation has none (a serve request passes it as \"stdin\")")
  try: e.ctx.stdin(maxTextFileBytes)
  except FileTooLargeError as x: raise badArgs("invalid-value", flag & ": " & x.msg)
  except IOError as x: raise badArgs("invalid-value", flag & ": cannot read stdin: " & x.msg)

proc captureTarget(e: VerbEnv): CaptureTarget =
  ## `--display <id> | --window <id> | --region x,y,w,h`; none: the
  ## session's primary display.
  case e.inv.exclusive(["display", "window", "region"], required = false)
  of "display": CaptureTarget(kind: ctkDisplay, id: e.inv.value("display"))
  of "window": CaptureTarget(kind: ctkWindow, id: e.inv.value("window"))
  of "region": CaptureTarget(kind: ctkRegion, region: e.inv.rectFlag("region").get)
  else: CaptureTarget(kind: ctkDisplay, id: none(string))

proc windowFilter(e: VerbEnv): WindowFilter =
  WindowFilter(app: e.inv.value("app"), pid: e.inv.intFlag("pid", 0),
               title: e.inv.value("title"),
               titleContains: e.inv.value("title-contains"),
               allLayers: e.inv.has("all-layers"),
               includeOffscreen: e.inv.has("include-offscreen"))

proc elementFilter(e: VerbEnv): ElementFilter =
  if e.inv.has("role"):
    try: result.role = some(parseRole(e.inv.value("role").get))
    except TreeError as x: raise badArgs("invalid-value", "--role: " & x.msg)
  result.name = e.inv.value("name")
  result.nameContains = e.inv.value("name-contains")
  result.ignoreCase = e.inv.has("ignore-case")
  if result.ignoreCase and result.name.isNone and result.nameContains.isNone:
    raise badArgs("conflicting-arguments", "--ignore-case applies to --name or --name-contains")
  for s in e.inv.values("state"):
    try: result.states.incl parseNodeState(s)
    except TreeError as x: raise badArgs("invalid-value", "--state: " & x.msg)

proc button(e: VerbEnv): MouseButton =
  case e.inv.value("button").get("left")
  of "left": mbLeft
  of "right": mbRight
  of "middle": mbMiddle
  else: raise badArgs("invalid-value", "--button is left, right or middle")

proc windowsData(l: WindowList): JsonNode =
  var ws = newJArray()
  for w in l.windows: ws.add w.toJson
  %*{"windows": ws, "titlesVisible": l.titlesVisible}

proc fileImageRef(path: string): ImageRef =
  ## The `ImageRef` of an existing PNG file (`source.kind: "file"`): the
  ## file's own size, digest and modification time; its desktop origin is
  ## not known, so it is `[0, 0]` at scale 1.
  if not fileExists(path):
    raise newContractError(ekNotFound, "file", "no image at " & path)
  var bytes: string
  try: bytes = readFileCapped(path, maxImageFileBytes)
  except FileTooLargeError as x:
    raise badArgs("invalid-value", x.msg)
  except IOError as x:
    raise newContractError(ekNotFound, "file", "cannot read " & path & ": " & x.msg)
  var img: PngImage
  try: img = decodePng(bytes)
  except PngError as x:
    raise badArgs("invalid-value", path & " is not a PNG GuiAssert can read: " & x.msg)
  let mt = getLastModificationTime(path)
  ImageRef(path: path, format: "png", width: img.width, height: img.height,
           scale: 1.0, origin: point(0, 0), sha256: sha256Hex(bytes),
           capturedAt: formatTimestamp(mt.toUnix * 1000 + int64(mt.nanosecond div 1_000_000)),
           source: ImageSource(kind: iskFile, id: none(string), session: none(string)))

proc readGrayPng(path: string): GrayImage =
  if not fileExists(path):
    raise newContractError(ekNotFound, "file", "no image at " & path)
  try:
    result = decodePngGray(readFileCapped(path, maxImageFileBytes))
  except PngError as x:
    raise badArgs("invalid-value", path & " is not a PNG GuiAssert can read: " & x.msg)
  except FileTooLargeError as x:
    raise badArgs("invalid-value", x.msg)
  except IOError as x:
    raise newContractError(ekNotFound, "file", "cannot read " & path & ": " & x.msg)

proc ocrDataJson(img: ImageRef, r: OcrResult): JsonNode =
  var words = newJArray()
  for w in r.words: words.add w.toJson
  %*{"image": img.toJson, "backend": r.backend, "languages": r.languages,
     "words": words, "text": r.text}

proc ocrRequest(e: VerbEnv, imagePath: string): OcrRequest =
  result.imagePath = imagePath
  result.languages = e.inv.values("lang")
  for l in result.languages:
    if l.len == 0: raise badArgs("invalid-value", "--lang is empty")
  result.psm = e.inv.intFlag("psm", 0, 13)
  result.upscale = e.inv.floatFlag("upscale", 0.0, 8.0, loInclusive = false)
  if e.inv.has("invert"):
    result.invert = some(case parseChoice("--invert", e.inv.value("invert").get,
                                          ["auto", "never", "always"])
      of "auto": oiAuto
      of "never": oiNever
      else: oiAlways)
  result.minConfidence = e.inv.floatFlag("min-confidence", 0.0, 100.0)

# ---------------------------------------------------------------------------
# Meta
# ---------------------------------------------------------------------------

proc verbVersion(e: VerbEnv): JsonNode =
  var compiled = newJObject()
  for m in Module: compiled[$m] = %compiledBackends(m)
  compiled["media"] = (if mediaCompiledIn: %["ffmpeg"] else: newJArray())
  %*{"guiassert": guiassertVersion, "contract": contractJson(),
     "platform": $currentPlatform, "arch": currentArch, "compiled": compiled}

proc unknownPermissions(): Permissions =
  Permissions(screenRecording: psUnknown, accessibility: psUnknown,
              inputSynthesis: psUnknown, desktopAccess: psUnknown,
              identity: none(string))

proc unavailableFeatures(m: Module, name: string, x: ref Exception): seq[Feature] =
  ## Every feature of module `m` as unavailable, for a backend that cannot
  ## even be constructed here, with the reason it gave.
  var reason = "not-implemented"
  var remedy = ""
  if x of ref ContractError:
    reason = (ref ContractError)(x).reason
    remedy = (ref ContractError)(x).remedy
  elif x of ref BackendError:
    reason = (ref BackendError)(x).reason
    remedy = (ref BackendError)(x).remedy
  for f in featuresOfModule($m):
    result.add Feature(feature: f, backend: name, state: fsUnavailable,
                       reason: some(reason),
                       remedy: (if remedy.len > 0: some(remedy) else: none(string)))

proc mediaFeatures(probe: bool): seq[Feature] =
  ## The media module's features: video input to `vision-segment`, through
  ## ffmpeg when the media backend is compiled in.
  when mediaCompiledIn:
    @[videoDecodeFeature(probe)]
  else:
    @[Feature(feature: "video-decode", backend: "ffmpeg", state: fsUnavailable,
              reason: some("not-compiled-in"),
              remedy: some("decode the video to PNG frames and pass --frames <dir>"))]

proc verbCapabilities(e: VerbEnv): JsonNode =
  let probe = e.inv.has("probe")
  var selected = newJObject()
  var features = newJArray()
  for m in Module:
    selected[$m] = %e.selection[m].name
    var fs: seq[Feature]
    try:
      fs = case m
        of modCapture: e.captureBackend().features(probe)
        of modOcr: e.ocrBackend().features(probe)
        of modTree: e.treeBackend().features(probe)
        of modInput: e.inputBackend().features(probe)
        of modSession: e.sessionBackend().features(probe)
    except ContractError, BackendUnavailableError:
      fs = unavailableFeatures(m, e.selection[m].name, getCurrentException())
    for f in fs: features.add f.toJson
  for f in mediaFeatures(probe): features.add f.toJson
  var perms = unknownPermissions()
  try: perms = e.sessionBackend().permissions(none(string))
  except ContractError, BackendUnavailableError: discard
  # A capture backend that captures through a permission of its own (the
  # macOS helper bundle's Screen Recording grant) answers for it when the
  # session backend could not.
  if perms.screenRecording == psUnknown:
    try:
      let cap = e.captureBackend()
      if cap.screenRecording != nil:
        let (state, identity) = cap.screenRecording(probe)
        perms.screenRecording = state
        if perms.identity.isNone: perms.identity = identity
    except ContractError, BackendError: discard
  %*{"platform": $currentPlatform, "selected": selected, "features": features,
     "permissions": perms.toJson}

proc verbPermissions(e: VerbEnv): JsonNode =
  let req = e.inv.value("request")
  if req.isSome:
    discard parseChoice("--request", req.get, ["screen-recording", "accessibility"])
  let p = e.sessionBackend().permissions(req)
  %*{"permissions": p.toJson, "requested": (if req.isSome: %req.get else: newJNull())}

# ---------------------------------------------------------------------------
# Sessions and applications
# ---------------------------------------------------------------------------

proc verbSessionStart(e: VerbEnv): JsonNode =
  var spec: SessionSpec
  let kind = parseChoice("--kind", e.inv.require("kind"),
                         ["host", "virtual-display", "isolated", "headless"])
  spec.kind = parseEnumValue[SessionKind](kind)
  if e.inv.has("name"):
    let n = e.inv.value("name").get
    if not isValidName(n):
      raise badArgs("invalid-name", "invalid session name '" & n &
        "' (names match [A-Za-z0-9][A-Za-z0-9._-]{0,63})")
    spec.name = some(n)
  let w = e.inv.intFlag("width", 1, 32768)
  let h = e.inv.intFlag("height", 1, 32768)
  if w.isSome != h.isSome:
    raise badArgs("missing-argument", "--width and --height are given together")
  if w.isSome: spec.size = some(Size(width: w.get, height: h.get))
  spec.scale = e.inv.floatFlag("scale", 0.0, 8.0, loInclusive = false)
  spec.displays = e.inv.intFlag("displays", 1, 16).get(1)
  spec.lifetime = parseEnumValue[SessionLifetime](
    parseChoice("--lifetime", e.inv.value("lifetime").get("detached"),
                ["detached", "owner"]))
  if spec.lifetime == slOwner and e.ctx.owner.isNone:
    raise newContractError(ekBackendUnavailable, "unsupported-option",
      "--lifetime owner needs an owner that outlives the call; it is honoured " &
      "only under `guiassert serve`", remedy = "use --lifetime detached, or serve",
      details = %*{"feature": nil})
  if e.inv.has("vnc") and e.inv.has("vnc-socket"):
    raise badArgs("conflicting-arguments", "give --vnc or --vnc-socket, not both")
  spec.vnc = e.inv.has("vnc")
  spec.vncSocket = e.inv.has("vnc-socket")
  if e.inv.has("account"):
    if spec.kind != skIsolated:
      raise badArgs("conflicting-arguments", "--account applies only to --kind isolated")
    spec.account = e.inv.value("account")
  elif spec.kind == skIsolated:
    raise badArgs("missing-argument", "--kind isolated needs --account <user>")
  let b = e.sessionBackend()
  %*{"session": b.start(spec).toJson}

proc verbSessionList(e: VerbEnv): JsonNode =
  var ss = newJArray()
  for s in e.sessionBackend().list(): ss.add s.toJson
  %*{"sessions": ss}

proc verbSessionInfo(e: VerbEnv): JsonNode =
  %*{"session": e.sessionBackend().info(e.session).toJson}

proc verbSessionStop(e: VerbEnv): JsonNode =
  if e.session == hostSessionId:
    raise badArgs("invalid-value", "the host session is never stopped")
  let b = e.sessionBackend()
  var s: Session
  e.withSessionLock(e.session):
    s = b.stop(e.session, e.inv.has("force"))
  %*{"session": s.toJson}

proc verbApps(e: VerbEnv): JsonNode =
  var a = newJArray()
  for x in e.sessionBackend().apps(e.session): a.add x.toJson
  %*{"apps": a}

proc verbAppLaunch(e: VerbEnv): JsonNode =
  var given: seq[string]
  if e.inv.has("bundle-id"): given.add "--bundle-id"
  if e.inv.has("app"): given.add "--app"
  if e.inv.hasPassthrough: given.add "-- <argv>"
  if given.len == 0:
    raise badArgs("missing-argument", "app-launch needs --bundle-id, --app or -- <argv>")
  if given.len > 1:
    raise badArgs("conflicting-arguments", given.join(" and ") & " exclude each other")
  let wait = e.inv.intFlag("wait-window-ms", 0, 600_000)
  var envPairs: seq[(string, string)]
  for kv in e.inv.values("env"):
    let eq = kv.find('=')
    if eq <= 0:
      raise badArgs("invalid-value", "--env takes KEY=VALUE")
    let k = kv[0 ..< eq]
    if k[0] notin {'A'..'Z', 'a'..'z', '_'} or
       not k.allCharsInSet({'A'..'Z', 'a'..'z', '0'..'9', '_'}):
      raise badArgs("invalid-value", "--env: '" & k &
        "' is not a variable name ([A-Za-z_][A-Za-z0-9_]*)")
    for (pk, _) in envPairs:
      if pk == k:
        raise badArgs("conflicting-arguments", "--env " & k & " is given more than once")
    envPairs.add (k, kv[eq + 1 .. ^1])
  var spec: LaunchSpec
  if e.inv.has("bundle-id"):
    spec = LaunchSpec(kind: lkBundleId, bundleId: e.inv.value("bundle-id").get)
  elif e.inv.has("app"):
    spec = LaunchSpec(kind: lkAppPath, appPath: e.resolvePath(e.inv.value("app").get))
  else:
    if e.inv.passthrough.len == 0 or e.inv.passthrough[0].len == 0:
      raise badArgs("missing-argument", "app-launch -- needs a program")
    spec = LaunchSpec(kind: lkArgv, argv: e.inv.passthrough)
  spec.waitWindowMs = wait
  spec.env = envPairs
  let b = e.sessionBackend()
  var r: LaunchReport
  e.withSessionLock(e.session):
    r = b.launch(e.session, spec)
  %*{"app": r.app.toJson,
     "window": (if r.window.isSome: r.window.get.toJson else: newJNull())}

proc verbAppQuit(e: VerbEnv): JsonNode =
  let pid = parseIntValue("<pid>", e.inv.positionals[0], 1)
  let b = e.sessionBackend()
  var r: QuitReport
  e.withSessionLock(e.session):
    r = b.quit(e.session, pid, e.inv.has("force"))
  %*{"pid": r.pid, "exited": r.exited,
     "exitCode": (if r.exitCode.isSome: %r.exitCode.get else: newJNull())}

# ---------------------------------------------------------------------------
# Displays and windows
# ---------------------------------------------------------------------------

proc verbDisplays(e: VerbEnv): JsonNode =
  var ds = newJArray()
  for d in e.captureBackend().displays(e.session): ds.add d.toJson
  %*{"displays": ds}

proc verbWindows(e: VerbEnv): JsonNode =
  let f = e.windowFilter()
  windowsData(e.captureBackend().windows(e.session, f))

proc verbWindowFocus(e: VerbEnv): JsonNode =
  let b = e.inputBackend()
  var w: Window
  e.withSessionLock(e.session):
    w = b.focusWindow(e.session, e.inv.positionals[0])
  %*{"window": w.toJson}

proc verbWindowSetBounds(e: VerbEnv): JsonNode =
  let r = parseRectValue("--bounds", e.inv.require("bounds"))
  let b = e.inputBackend()
  var w: Window
  e.withSessionLock(e.session):
    w = b.setWindowBounds(e.session, e.inv.positionals[0], r)
  %*{"window": w.toJson, "requested": r.toJson}

# ---------------------------------------------------------------------------
# Capture
# ---------------------------------------------------------------------------

proc readSecret(e: VerbEnv): string =
  ## The secret of `--secret-stdin` (spec §7.5, "Secret-guarded frames"),
  ## read and checked before anything is captured or recognized. Its
  ## characters never reach a message.
  result = e.readInput("--secret-stdin")
  if not isValidUtf8(result):
    raise badArgs("invalid-value", "the --secret-stdin secret is not valid UTF-8")
  if secretRunes(result) < minSecretRunes:
    raise badArgs("invalid-value", "the --secret-stdin secret has fewer than " &
      $minSecretRunes & " characters besides white space")

proc secretVisibleIn(r: OcrResult, secret: string): bool =
  ## Whether `secret` is legible in what the engine read, in reading order
  ## or in the engine's own word order.
  secretVisible(r.text, secret) or secretVisible(concatenatedText(r.words), secret)

proc secretVisibleError(): ref ContractError =
  newContractError(ekBackendError, "secret-visible",
    "the secret given on --secret-stdin is legible in the frame; no frame, " &
    "word or text of it is reported",
    remedy = "bring the screen to a state that does not show the secret " &
      "(a masked field) and capture again")

proc removeQuietly(path: string) =
  try: removeFile(path)
  except OSError: discard

proc verbScreenshot(e: VerbEnv): JsonNode =
  let req = CaptureRequest(session: e.session, target: e.captureTarget(),
                           outPath: e.resolvePath(e.inv.require("out")),
                           ownPixels: e.inv.has("own-pixels"),
                           cursor: not e.inv.has("no-cursor"))
  if req.ownPixels and req.target.kind != ctkWindow:
    raise badArgs("conflicting-arguments", "--own-pixels applies to --window captures")
  if not e.inv.has("secret-stdin"):
    return %*{"image": e.captureBackend().capture(req).toJson}
  # Secret-guarded: the secret and the OCR engine first, so a refusal
  # leaves no frame; then the frame, read and judged before it is reported.
  let secret = e.readSecret()
  let ocr = featured("ocr"): e.ocrBackend()
  let img = e.captureBackend().capture(req)
  var visible = false
  try:
    visible = featured("ocr"):
      secretVisibleIn(ocr.recognize(OcrRequest(imagePath: req.outPath)), secret)
  except CatchableError:
    removeQuietly(req.outPath)
    raise
  if visible:
    removeQuietly(req.outPath)
    raise secretVisibleError()
  %*{"image": img.toJson}

proc recordRequest(e: VerbEnv, blocking: bool): RecordRequest =
  result = RecordRequest(session: e.session, target: e.captureTarget(),
                         outPath: e.resolvePath(e.inv.require("out")),
                         fps: e.inv.floatFlag("fps", 0.0, 240.0, loInclusive = false).get(defaultFps))
  if blocking:
    result.durationMs = some(parseIntValue("--duration-ms", e.inv.require("duration-ms"),
                                           1, 86_400_000))

proc verbRecord(e: VerbEnv): JsonNode =
  let req = e.recordRequest(blocking = true)
  %*{"recording": e.captureBackend().startRecording(req).toJson}

proc verbRecordStart(e: VerbEnv): JsonNode =
  let req = e.recordRequest(blocking = false)
  %*{"recording": e.captureBackend().startRecording(req).toJson}

proc verbRecordStop(e: VerbEnv): JsonNode =
  let id = e.inv.positionals[0]
  if not isValidName(id):
    raise badArgs("invalid-name", "invalid recording id '" & id & "'")
  %*{"recording": e.captureBackend().stopRecording(id).toJson}

proc verbRecordings(e: VerbEnv): JsonNode =
  var rs = newJArray()
  for r in e.captureBackend().recordings(): rs.add r.toJson
  %*{"recordings": rs}

# ---------------------------------------------------------------------------
# OCR
# ---------------------------------------------------------------------------

proc verbOcr(e: VerbEnv): JsonNode =
  ## `ocr` of an image file, or of a frame it captures to `--out` first. The
  ## engine's option checks run before the capture, so a refused option
  ## leaves no frame behind; a frame whose recognition then fails is removed
  ## too, because a failure reports no image (spec §7.5, "Captured content").
  let guarded = e.inv.has("secret-stdin")
  let secret = if guarded: e.readSecret() else: ""
  proc judged(ocr: OcrEngine, req: OcrRequest): OcrResult =
    ## The engine's reading of `req`; guarded, the secret is judged against
    ## every word it read, before `--min-confidence` drops any, and a
    ## visible secret raises `secret-visible`.
    if not guarded: return ocr.recognize(req)
    var whole = req
    whole.minConfidence = none(float)
    let r = ocr.recognize(whole)
    if secretVisibleIn(r, secret): raise secretVisibleError()
    if req.minConfidence.isNone: return r
    var kept: seq[OcrWord]
    for w in r.words:
      if w.confidence >= req.minConfidence.get: kept.add w
    initOcrResult(kept, r.backend, r.languages)
  if e.inv.has("image"):
    e.inv.refuse(["out", "display", "window", "region"],
                 "with --image (it reads an existing file)")
    let path = e.resolvePath(e.inv.value("image").get)
    let req = e.ocrRequest(path)
    let ocr = e.ocrBackend()
    if ocr.validate != nil: ocr.validate(req)
    let img = fileImageRef(path)
    return ocrDataJson(img, judged(ocr, req))
  if not (e.inv.has("display") or e.inv.has("window") or e.inv.has("region")):
    raise badArgs("missing-argument", "ocr needs --image, or --display, --window " &
      "or --region with --out")
  let outPath = e.resolvePath(e.inv.require("out"))
  let req = e.ocrRequest(outPath)
  let ocr = e.ocrBackend()
  if ocr.validate != nil: ocr.validate(req)
  let img = featured(captureFeatureOf(e.inv)):
    e.captureBackend().capture(CaptureRequest(session: e.session,
      target: e.captureTarget(), outPath: outPath, cursor: false))
  try:
    result = ocrDataJson(img, judged(ocr, req))
  except CatchableError:
    removeQuietly(outPath)
    raise

# ---------------------------------------------------------------------------
# Accessibility tree
# ---------------------------------------------------------------------------

proc treeTarget(e: VerbEnv, required: bool): Option[TreeTarget] =
  let flags = if e.inv.verb == "tree": @["pid", "app", "window", "focused"]
              else: @["pid", "app", "window"]
  case e.inv.exclusive(flags, required)
  of "pid": some(TreeTarget(kind: ttkPid, pid: e.inv.intFlag("pid", 1).get))
  of "app": some(TreeTarget(kind: ttkApp, app: e.inv.value("app").get))
  of "window": some(TreeTarget(kind: ttkWindow, windowId: e.inv.value("window").get))
  of "focused": some(TreeTarget(kind: ttkFocused))
  else: none(TreeTarget)

proc verbTree(e: VerbEnv): JsonNode =
  let target = e.treeTarget(required = true).get
  let depth = e.inv.intFlag("depth", 0, 10_000)
  let maxNodes = e.inv.intFlag("max-nodes", 1, 1_000_000).get(5000)
  let r = e.treeBackend().tree(e.session, target, depth, maxNodes)
  %*{"root": r.root.toJson, "nodeCount": r.nodeCount, "truncated": r.truncated}

proc elementsJson(es: seq[Node]): JsonNode =
  result = newJArray()
  for x in es: result.add x.elementToJson

proc verbFind(e: VerbEnv): JsonNode =
  let target = e.treeTarget(required = false)
  let f = e.elementFilter()
  let limit = e.inv.intFlag("limit", 1, 1_000_000).get(high(int))
  let r = e.treeBackend().find(e.session, target, f, limit)
  %*{"elements": elementsJson(r.elements), "truncated": r.truncated}

proc verbElement(e: VerbEnv): JsonNode =
  let path = e.inv.positionals[0]
  try: discard parseTreePath(path)
  except TreeError as x: raise badArgs("invalid-value", x.msg)
  %*{"element": e.treeBackend().element(e.session, path).elementToJson}

proc verbElementAction(e: VerbEnv): JsonNode =
  let path = e.inv.positionals[0]
  try: discard parseTreePath(path)
  except TreeError as x: raise badArgs("invalid-value", x.msg)
  var action: NodeAction
  try: action = parseNodeAction(e.inv.positionals[1])
  except TreeError as x: raise badArgs("invalid-value", x.msg)
  let hasValue = e.inv.has("value")
  let hasStdin = e.inv.has("value-stdin")
  if action == actSetValue and not (hasValue or hasStdin):
    raise badArgs("missing-argument", "set-value needs --value or --value-stdin")
  if action != actSetValue and (hasValue or hasStdin):
    raise badArgs("conflicting-arguments", "--value and --value-stdin apply only to set-value")
  if hasValue and hasStdin:
    raise badArgs("conflicting-arguments", "give --value or --value-stdin, not both")
  var value = e.inv.value("value")
  if hasStdin: value = some(e.readInput("--value-stdin"))
  if value.isSome and not isValidUtf8(value.get):
    raise badArgs("invalid-value", "the value is not valid UTF-8")
  let b = e.treeBackend()
  var n: Node
  e.withSessionLock(e.session):
    n = b.perform(e.session, path, action, value)
  %*{"element": n.elementToJson, "action": $action}

# ---------------------------------------------------------------------------
# wait
# ---------------------------------------------------------------------------

proc findWord(words: seq[OcrWord], needle: string): Option[OcrWord] =
  ## The first word of the first run of consecutive words whose text
  ## contains `needle`.
  for i in 0 ..< words.len:
    var s = ""
    for j in i ..< words.len:
      if j > i: s.add ' '
      s.add words[j].text
      if needle in s: return some(words[i])
      if s.len > needle.len + words[i].text.len: break
  none(OcrWord)

const waitFrameName = "wait-frame.png"
  ## The one file `wait --text` writes in `--out-dir`: each attempt's frame
  ## replaces the last, and it is reported (`data.image`) or removed.

proc verbWaitLoop(e: VerbEnv): JsonNode =
  let mode = e.inv.exclusive(["element", "text", "window", "window-gone"],
                             required = true)
  let waitMs = parseIntValue("--wait-ms", e.inv.require("wait-ms"), 0, 86_400_000)
  let interval = e.inv.intFlag("interval-ms", 10, 3_600_000).get(defaultIntervalMs)
  if e.timeoutMs.isSome and e.timeoutMs.get <= waitMs:
    raise badArgs("conflicting-arguments", "--timeout-ms (" & $e.timeoutMs.get &
      ") must be larger than --wait-ms (" & $waitMs & ")")
  const elementFlags = ["role", "name", "name-contains", "state"]
  const windowFlags = ["title", "title-contains"]
  const textFlags = ["ocr-region", "out-dir"]
  var elFilter: ElementFilter
  var elTarget: Option[TreeTarget]
  var winFilter: WindowFilter
  var tree: TreeBackend
  var cap: CaptureBackend
  var ocr: OcrEngine
  var outDir = ""
  case mode
  of "element":
    e.inv.refuse(@windowFlags & @textFlags, "to wait --element")
    if e.inv.has("pid") and e.inv.has("app"):
      raise badArgs("conflicting-arguments", "--pid and --app exclude each other")
    if e.inv.has("pid"): elTarget = some(TreeTarget(kind: ttkPid, pid: e.inv.intFlag("pid", 1).get))
    elif e.inv.has("app"): elTarget = some(TreeTarget(kind: ttkApp, app: e.inv.value("app").get))
    elFilter = e.elementFilter()
    tree = e.treeBackend()
  of "text":
    e.inv.refuse(@elementFlags & @windowFlags & @["pid", "app"], "to wait --text")
    outDir = e.resolvePath(e.inv.require("out-dir"))
    if not dirExists(outDir):
      raise newContractError(ekNotFound, "file", "--out-dir does not exist: " & outDir)
    discard e.inv.rectFlag("ocr-region")
    ocr = e.ocrBackend()
    cap = featured(if e.inv.has("ocr-region"): "region-capture" else: "display-capture"):
      e.captureBackend()
  else:
    e.inv.refuse(@elementFlags & @textFlags, "to wait --" & mode)
    winFilter = e.windowFilter()
    cap = e.captureBackend()
  var attempt = 0
  while true:
    inc attempt
    let elapsed = (attempt - 1) * interval
    e.ctx.token.checkpoint()
    var data = %*{"matched": true, "elapsedMs": elapsed, "attempts": attempt,
                  "element": nil, "word": nil, "image": nil, "window": nil}
    var observed = 0
    var matched = false
    case mode
    of "element":
      let r = tree.find(e.session, elTarget, elFilter, 1)
      observed = r.elements.len
      if observed > 0:
        matched = true
        data["element"] = r.elements[0].elementToJson
    of "text":
      let target = if e.inv.has("ocr-region"):
                     CaptureTarget(kind: ctkRegion, region: e.inv.rectFlag("ocr-region").get)
                   else: CaptureTarget(kind: ctkDisplay, id: none(string))
      let img = featured(if e.inv.has("ocr-region"): "region-capture" else: "display-capture"):
        cap.capture(CaptureRequest(session: e.session, target: target,
                                   outPath: outDir / waitFrameName))
      let r = ocr.recognize(OcrRequest(imagePath: img.path))
      observed = r.words.len
      let w = findWord(r.words, e.inv.value("text").get)
      if w.isSome:
        matched = true
        data["word"] = w.get.toJson
        data["image"] = img.toJson
    else:
      let l = cap.windows(e.session, winFilter)
      observed = l.windows.len
      if mode == "window" and observed > 0:
        matched = true
        data["window"] = l.windows[0].toJson
      elif mode == "window-gone" and observed == 0:
        matched = true
    e.emit("poll", %*{"attempt": attempt, "elapsedMs": elapsed, "observed": observed})
    if matched: return data
    if attempt * interval > waitMs:
      raise newContractError(ekTimeout, "condition-not-met",
        "the condition did not hold within --wait-ms " & $waitMs,
        details = %*{"attempts": attempt, "elapsedMs": elapsed})
    e.ctx.token.sleepCancellable(interval)

proc verbWait(e: VerbEnv): JsonNode =
  ## `wait`. A `--text` wait reports every image file it wrote: the frame
  ## that matched is `data.image`; when it ends any other way (expiry,
  ## cancellation, an error) the frame it wrote is removed (spec §7.5,
  ## "Captured content").
  var frame = ""
  if e.inv.has("text") and e.inv.has("out-dir"):
    frame = e.resolvePath(e.inv.value("out-dir").get) / waitFrameName
  try:
    result = verbWaitLoop(e)
  except CatchableError:
    if frame.len > 0:
      try: removeFile(frame) except OSError: discard
    raise

# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

template inputVerb(e: VerbEnv, call: untyped): JsonNode =
  let ib {.inject.} = e.inputBackend()
  var rep: InputReport
  e.withSessionLock(e.session):
    rep = call
  %*{"input": rep.toJson}

proc verbMove(e: VerbEnv): JsonNode =
  let to = parsePointValue("--to", e.inv.require("to"))
  e.inputVerb(ib.move(e.session, to))

proc modifierList(e: VerbEnv): seq[string] =
  ## `--modifiers`, in canonical spellings and the table's order.
  if e.inv.has("modifiers"):
    try:
      let s = parseModifiers(e.inv.value("modifiers").get)
      for m in Modifier:
        if m in s: result.add $m
    except KeyComboError as x: raise badArgs("invalid-value", "--modifiers: " & x.msg)

proc verbClick(e: VerbEnv): JsonNode =
  let at = parsePointValue("--at", e.inv.require("at"))
  let btn = e.button()
  let count = e.inv.intFlag("count", 1, 10).get(1)
  e.inputVerb(ib.click(e.session, at, btn, count, e.modifierList()))

const maxDragWaypoints = 1000
  ## The most `drag --path` waypoints one drag takes.

proc verbDrag(e: VerbEnv): JsonNode =
  let src = parsePointValue("--from", e.inv.require("from"))
  let dst = parsePointValue("--to", e.inv.require("to"))
  var path = @[src]
  if e.inv.has("path"):
    let spec = e.inv.value("path").get
    let parts = spec.split(';')
    if parts.len > maxDragWaypoints:
      raise badArgs("invalid-value", "--path takes at most " & $maxDragWaypoints &
        " waypoints, got " & $parts.len)
    for p in parts:
      if p.len == 0:
        raise badArgs("invalid-value", "--path is x,y;x,y;… with no empty waypoint")
      path.add parsePointValue("--path", p)
  path.add dst
  let btn = e.button()
  let steps = e.inv.intFlag("steps", 1, 1000).get(10)
  let dur = e.inv.intFlag("duration-ms", 0, 600_000).get(0)
  e.inputVerb(ib.drag(e.session, path, btn, steps, dur, e.modifierList()))

const maxGestureSteps = 10_000

proc parseGestureStep(spec: string): GestureStep =
  ## `move X,Y` | `press X,Y [BUTTON]` | `release X,Y [BUTTON]` |
  ## `key-down COMBO` | `key-up COMBO` | `wait MS`
  let w = spec.strip.splitWhitespace
  if w.len == 0: raise badArgs("invalid-value", "--steps has an empty step")
  proc btnOf(i: int): MouseButton =
    if w.len <= i: return mbLeft
    case w[i]
    of "left": mbLeft
    of "right": mbRight
    of "middle": mbMiddle
    else: raise badArgs("invalid-value", "--steps: unknown button '" & w[i] & "'")
  case w[0]
  of "move":
    if w.len != 2: raise badArgs("invalid-value", "--steps: move X,Y")
    GestureStep(kind: gsMove, to: parsePointValue("--steps", w[1]))
  of "press", "release":
    if w.len notin 2 .. 3: raise badArgs("invalid-value", "--steps: " & w[0] & " X,Y [BUTTON]")
    let at = parsePointValue("--steps", w[1])
    if w[0] == "press": GestureStep(kind: gsPress, at: at, button: btnOf(2))
    else: GestureStep(kind: gsRelease, at: at, button: btnOf(2))
  of "key-down", "key-up":
    if w.len != 2: raise badArgs("invalid-value", "--steps: " & w[0] & " COMBO")
    var combo = w[1]
    try:
      let mods = parseModifiers(combo)
      var names: seq[string]
      for m in Modifier:
        if m in mods: names.add $m
      combo = names.join("+")
    except KeyComboError:
      try: combo = normalizeCombo(combo)
      except KeyComboError as x: raise badArgs("invalid-value", "--steps: " & x.msg)
    if w[0] == "key-down": GestureStep(kind: gsKeyDown, combo: combo)
    else: GestureStep(kind: gsKeyUp, combo: combo)
  of "wait":
    if w.len != 2: raise badArgs("invalid-value", "--steps: wait MS")
    GestureStep(kind: gsWait, ms: parseIntValue("--steps", w[1], 0, 600_000))
  else: raise badArgs("invalid-value", "--steps: unknown step '" & w[0] & "'")

proc verbGesture(e: VerbEnv): JsonNode =
  let parts = e.inv.require("steps").split(';')
  if parts.len > maxGestureSteps:
    raise badArgs("invalid-value", "--steps takes at most " & $maxGestureSteps & " steps")
  var steps: seq[GestureStep]
  for p in parts: steps.add parseGestureStep(p)
  e.inputVerb(ib.gesture(e.session, steps))

proc verbScroll(e: VerbEnv): JsonNode =
  let at = parsePointValue("--at", e.inv.require("at"))
  let dx = parseIntValue("--dx", e.inv.require("dx"), -100_000, 100_000)
  let dy = parseIntValue("--dy", e.inv.require("dy"), -100_000, 100_000)
  let unit = case parseChoice("--unit", e.inv.value("unit").get("line"), ["line", "pixel"])
    of "line": suLine
    else: suPixel
  e.inputVerb(ib.scroll(e.session, at, dx, dy, unit))

proc verbType(e: VerbEnv): JsonNode =
  let hasText = e.inv.positionals.len > 0
  var given = 0
  for b in [hasText, e.inv.has("text-file"), e.inv.has("stdin")]:
    if b: inc given
  if given != 1:
    raise (if given > 1: badArgs("conflicting-arguments",
                                 "give one of <text>, --text-file and --stdin")
           else: badArgs("missing-argument", "type needs <text>, --text-file or --stdin"))
  var text = if hasText: e.inv.positionals[0] else: ""
  if e.inv.has("stdin"): text = e.readInput("--stdin")
  if e.inv.has("text-file"):
    let p = e.resolvePath(e.inv.value("text-file").get)
    if not fileExists(p): raise newContractError(ekNotFound, "file", "no file at " & p)
    try: text = readFileCapped(p, maxTextFileBytes)
    except FileTooLargeError as x: raise badArgs("invalid-value", x.msg)
    except IOError as x: raise newContractError(ekNotFound, "file", "cannot read " & p & ": " & x.msg)
  if not isValidUtf8(text):
    raise badArgs("invalid-value", "the text to type is not valid UTF-8")
  let interval = e.inv.intFlag("interval-ms", 0, 10_000).get(0)
  e.inputVerb(ib.typeText(e.session, text, interval))

proc verbKey(e: VerbEnv): JsonNode =
  var combo: string
  try: combo = normalizeCombo(e.inv.positionals[0])
  except KeyComboError as x: raise badArgs("invalid-value", x.msg)
  e.inputVerb(ib.key(e.session, combo))

# ---------------------------------------------------------------------------
# Vision (pure core)
# ---------------------------------------------------------------------------

proc verbVisionCompare(e: VerbEnv): JsonNode =
  let a = readGrayPng(e.resolvePath(e.inv.positionals[0]))
  let b = readGrayPng(e.resolvePath(e.inv.positionals[1]))
  if a.width != b.width or a.height != b.height:
    raise badArgs("invalid-value", "the images differ in size (" & $a.width & "x" &
      $a.height & " vs " & $b.width & "x" & $b.height & "); they are not resized")
  var tiles = newJNull()
  if e.inv.has("tiles"):
    let t = e.inv.value("tiles").get.split('x')
    if t.len != 2:
      raise badArgs("invalid-value", "--tiles is <columns>x<rows>, e.g. 4x4")
    let gx = parseIntValue("--tiles", t[0], 1, 64)
    let gy = parseIntValue("--tiles", t[1], 1, 64)
    var values = newJArray()
    var mn = Inf
    for y in 0 ..< gy:
      let y0 = y * a.height div gy
      let y1 = (y + 1) * a.height div gy
      for x in 0 ..< gx:
        let x0 = x * a.width div gx
        let x1 = (x + 1) * a.width div gx
        if x1 <= x0 or y1 <= y0:
          raise badArgs("invalid-value", "--tiles is finer than the image")
        let cell = rect(x0, y0, x1 - x0, y1 - y0)
        let s = computeSsim(crop(a, cell), crop(b, cell))
        values.add finiteJson(s, "a tile SSIM")
        mn = min(mn, s)
    tiles = %*{"grid": [gx, gy], "values": values, "min": finiteJson(mn, "the minimum tile SSIM")}
  %*{"width": a.width, "height": a.height, "ssim": finiteJson(computeSsim(a, b), "SSIM"),
     "tiles": tiles, "phashDistance": hammingDistance(dctHash(a), dctHash(b)),
     "edgeChangeRatio": finiteJson(edgeChangeRatio(a, b), "the edge change ratio")}

proc segmentsJson(segs: seq[Segment]): JsonNode =
  result = newJArray()
  for i, s in segs:
    result.add %*{"index": i, "tStart": finiteJson(s.tStart), "tEnd": finiteJson(s.tEnd),
                  "changeScore": finiteJson(s.changeScore)}

proc visionSegmentVideo(e: VerbEnv, fps: Option[float], threshold: float,
                        scaleWidth: Option[int]): JsonNode =
  ## `vision-segment <video>`: the media backend's `segmentVideo`, serialized.
  when mediaCompiledIn:
    let details = %*{"module": "media", "backend": "ffmpeg"}
    try: discard resolveMediaTools()
    except MediaToolMissingError as x:
      raise newContractError(ekBackendUnavailable, "missing-tool", x.msg,
        remedy = "install ffmpeg (with ffprobe beside it) on PATH or set FFMPEG_BIN",
        details = details)
    let path = e.resolvePath(e.inv.positionals[0])
    if not fileExists(path):
      raise newContractError(ekNotFound, "file", "no video at " & path)
    let token = e.ctx.token
    var r: VideoSegmentation
    try:
      r = segmentVideo(path, fps.get(defaultVideoFps),
                       scaleWidth.get(defaultVideoScaleWidth), threshold,
                       checkpoint = proc () = token.checkpoint())
    except MediaToolMissingError as x:
      raise newContractError(ekBackendUnavailable, "missing-tool", x.msg, details = details)
    except VideoDecodeError as x:
      raise badArgs("invalid-value", x.msg)
    except FrameTooLargeError as x:
      # The video at this --scale-width exceeds `maxImagePixels` (spec §7.5).
      raise badArgs("invalid-value", x.msg)
    %*{"source": {"path": path,
                  "durationS": (if r.source.durationS.isSome:
                                  finiteJson(r.source.durationS.get, "the video duration")
                                else: newJNull()),
                  "width": r.source.width, "height": r.source.height},
       "params": {"fps": finiteJson(r.fps), "scaleWidth": r.scaleWidth,
                  "threshold": finiteJson(r.threshold)},
       "segments": segmentsJson(r.segments)}
  else:
    raise newContractError(ekBackendUnavailable, "not-compiled-in",
      "video input needs the media backend, which is not compiled into this binary",
      remedy = "decode the video to PNG frames and pass --frames <dir>",
      details = %*{"module": "media", "backend": "ffmpeg"})

proc verbVisionSegment(e: VerbEnv): JsonNode =
  let hasVideo = e.inv.positionals.len > 0
  if hasVideo == e.inv.has("frames"):
    raise (if hasVideo: badArgs("conflicting-arguments", "give <video> or --frames, not both")
           else: badArgs("missing-argument", "vision-segment needs <video> or --frames <dir>"))
  let threshold = e.inv.floatFlag("threshold", 0.0, 1.0).get(defaultChangeThreshold)
  let scaleWidth = e.inv.intFlag("scale-width", 8, 16384)
  let fps = e.inv.floatFlag("fps", 0.0, 240.0, loInclusive = false)
  if hasVideo:
    return e.visionSegmentVideo(fps, threshold, scaleWidth)
  let dir = e.resolvePath(e.inv.value("frames").get)
  if not dirExists(dir):
    raise newContractError(ekNotFound, "file", "--frames directory does not exist: " & dir)
  let files = sortedNames(dir, ".png")
  if files.len == 0:
    raise badArgs("invalid-value", "--frames " & dir & " holds no .png frames")
  # Frames are scored one pair at a time, as video frames are, so a long
  # sequence never has to fit in memory; `segmentsFromSeries` splits the
  # series exactly as `core/segmentation.segmentFrames` does.
  var series: seq[float]
  var prev: GrayImage
  var srcW, srcH = 0
  for i, f in files:
    e.ctx.token.checkpoint()
    var g = readGrayPng(f)
    if i == 0:
      srcW = g.width
      srcH = g.height
      # The scaled frame obeys the same pixel cap as a decoded one (spec
      # §7.5); refused before the first scaled buffer is allocated.
      if scaleWidth.isSome and
         not fitsPixelCap(scaleWidth.get, scaledHeight(srcW, srcH, scaleWidth.get)):
        raise badArgs("invalid-value", "--scale-width " & $scaleWidth.get & " makes the " &
          $srcW & "x" & $srcH & " frames " & $scaleWidth.get & "x" &
          $scaledHeight(srcW, srcH, scaleWidth.get) & ", more than the limit of " &
          $maxImagePixels & " pixels")
    elif g.width != srcW or g.height != srcH:
      raise badArgs("invalid-value", "the frames differ in size (" & f & " is " &
        $g.width & "x" & $g.height & ", the first frame " & $srcW & "x" & $srcH & ")")
    if scaleWidth.isSome:
      g = scaleNearest(g, scaleWidth.get, scaledHeight(srcW, srcH, scaleWidth.get))
    if i > 0: series.add frameSimilarity(prev, g)
    prev = g
  let rate = fps.get(1.0)
  let segs = segmentsFromSeries(series, files.len, rate, threshold)
  %*{"source": {"path": dir, "durationS": finiteJson(float(files.len) / rate),
                "width": srcW, "height": srcH},
     "params": {"fps": finiteJson(rate), "scaleWidth": (if scaleWidth.isSome: %scaleWidth.get
                                                         else: newJNull()),
                "threshold": finiteJson(threshold)},
     "segments": segmentsJson(segs)}

proc verbVisionWindows(e: VerbEnv): JsonNode =
  let path = e.resolvePath(e.inv.positionals[0])
  let img = readGrayPng(path)
  let rects = detectWindowRects(img)
  let thr = otsuThreshold(img)
  var words: seq[OcrWord]
  let withOcr = e.inv.has("ocr")
  if withOcr:
    words = e.ocrBackend().recognize(OcrRequest(imagePath: path)).words
  var ws = newJArray()
  for r in rects:
    var fg = 0
    for y in r[1] ..< r[1] + r[3]:
      for x in r[0] ..< r[0] + r[2]:
        if ord(img.pixels[y * img.width + x]) > thr: inc fg
    let conf = clamp(float(fg) / float(max(1, r[2] * r[3])), 0.0, 1.0)
    var title = newJNull()
    var text = newJNull()
    if withOcr:
      let box = rect(r)
      let band = rect(r[0], r[1], r[2], min(r[3], max(8, min(32, r[3] * 8 div 100 + 24))))
      var inside, inBand: seq[OcrWord]
      for w in words:
        if box.contains(rect(w.bbox)): inside.add w
        if band.contains(rect(w.bbox)): inBand.add w
      text = %wordsToReadingOrderText(inside)
      title = %wordsToReadingOrderText(inBand)
    ws.add %*{"bbox": rect(r).toJson, "confidence": finiteJson(conf), "titleText": title,
              "text": text}
  %*{"image": {"path": path, "width": img.width, "height": img.height}, "windows": ws}

# ---------------------------------------------------------------------------
# watch
# ---------------------------------------------------------------------------

proc verbWatch(e: VerbEnv): JsonNode =
  let mode = e.inv.exclusive(["windows", "frames"], required = true)
  let duration = e.inv.intFlag("duration-ms", 1, 86_400_000)
  let eventsFile = if e.inv.has("events-file"): e.resolvePath(e.inv.value("events-file").get)
                   else: ""
  if e.ctx.owner.isNone:
    if duration.isNone:
      raise badArgs("missing-argument", "the one-shot watch needs --duration-ms")
    if eventsFile.len == 0:
      raise badArgs("missing-argument", "the one-shot watch needs --events-file " &
        "(stdout carries only the envelope)")
  if eventsFile.len > 0 and not dirExists(eventsFile.parentDir):
    raise newContractError(ekNotFound, "file", "the --events-file directory does not exist")
  var outDir = ""
  var fps = 1.0
  if mode == "frames":
    outDir = e.resolvePath(e.inv.require("out-dir"))
    if not dirExists(outDir):
      raise newContractError(ekNotFound, "file", "--out-dir does not exist: " & outDir)
    fps = e.inv.floatFlag("fps", 0.0, 60.0, loInclusive = false).get(1.0)
  else:
    e.inv.refuse(["out-dir", "fps"], "to watch --windows")
  let cap = e.captureBackend()
  let period = if mode == "frames": max(1, int(round(1000.0 / fps))) else: 100
  var evSeq = 0
  var events = 0
  var last = ""
  var tick = 0
  var f: File
  if eventsFile.len > 0 and not open(f, eventsFile, fmAppend):
    raise newContractError(ekNotFound, "file", "cannot open --events-file " & eventsFile)
  proc record(event: string, data: JsonNode) =
    if eventsFile.len > 0:
      f.writeLine($(%*{"v": serveProtocolVersion, "id": nil, "type": "event",
                        "seq": evSeq, "event": event, "data": data}))
      f.flushFile()
    e.emit(event, data)
    inc evSeq
    inc events
  try:
    while duration.isNone or tick * period < duration.get:
      e.ctx.token.checkpoint()
      if mode == "windows":
        let l = cap.windows(e.session, WindowFilter())
        let now = $windowsData(l)
        if now != last:
          record("windows-changed", windowsData(l))
          last = now
      else:
        let img = cap.capture(CaptureRequest(session: e.session,
          target: CaptureTarget(kind: ctkDisplay, id: none(string)),
          outPath: outDir / (align($tick, 6, '0') & ".png"), cursor: true))
        record("frame", %*{"index": tick, "image": img.toJson})
      inc tick
      if duration.isNone or tick * period < duration.get:
        e.ctx.token.sleepCancellable(period)
  finally:
    if eventsFile.len > 0: f.close()
  %*{"events": events, "elapsedMs": duration.get(tick * period)}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

proc dispatchVerb(e: VerbEnv): JsonNode =
  case e.inv.verb
  of "version": verbVersion(e)
  of "capabilities": verbCapabilities(e)
  of "permissions": verbPermissions(e)
  of "session-start": verbSessionStart(e)
  of "session-list": verbSessionList(e)
  of "session-info": verbSessionInfo(e)
  of "session-stop": verbSessionStop(e)
  of "apps": verbApps(e)
  of "app-launch": verbAppLaunch(e)
  of "app-quit": verbAppQuit(e)
  of "displays": verbDisplays(e)
  of "windows": verbWindows(e)
  of "window-focus": verbWindowFocus(e)
  of "window-set-bounds": verbWindowSetBounds(e)
  of "screenshot": verbScreenshot(e)
  of "record": verbRecord(e)
  of "record-start": verbRecordStart(e)
  of "record-stop": verbRecordStop(e)
  of "recordings": verbRecordings(e)
  of "ocr": verbOcr(e)
  of "tree": verbTree(e)
  of "find": verbFind(e)
  of "element": verbElement(e)
  of "element-action": verbElementAction(e)
  of "wait": verbWait(e)
  of "move": verbMove(e)
  of "click": verbClick(e)
  of "drag": verbDrag(e)
  of "gesture": verbGesture(e)
  of "scroll": verbScroll(e)
  of "type": verbType(e)
  of "key": verbKey(e)
  of "vision-compare": verbVisionCompare(e)
  of "vision-segment": verbVisionSegment(e)
  of "vision-windows": verbVisionWindows(e)
  of "watch": verbWatch(e)
  else:
    raise newContractError(ekInternal, "exception", "verb '" & e.inv.verb &
      "' is in the registry but has no implementation")

proc dispatch*(e: VerbEnv): JsonNode =
  ## Run the verb of `e` and return its `data`. An exit 4 or exit 6 failure
  ## that does not name its feature yet names the verb's (`verbFeature`).
  featured(verbFeature(e.inv)):
    dispatchVerb(e)
