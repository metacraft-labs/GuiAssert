## The fixture backend's desktop: a deterministic, OS-free desktop that every
## fixture backend (capture, OCR, tree, input, session) reads and changes.
##
## Spec §9.2. The fixture is the one sanctioned stand-in below the contract:
## the real CLI, the real `serve` daemon and the real serializers run above
## it, and Agent Harbor's contract tests drive it through the same binary.
## So it behaves like a small but real desktop, not like a canned answer:
##
## * A **scenario** (built-in `fixture-form`, or a JSON file named by
##   `--fixture-scenario` / `GUIASSERT_FIXTURE_SCENARIO`) describes displays,
##   applications, windows (front to back), one accessibility tree per
##   application, the pointer, a base frame and the OCR languages. It is
##   parsed strictly: an unknown key is an error.
## * The **state** lives under `<state-dir>/fixture/`, so verbs compose
##   across separate processes: `desktops/<session>.json` holds each
##   session's desktop (seeded from the scenario), `meta.json` the logical
##   clock and id counters, `frames/<sha256>.json` the words drawn on every
##   frame the fixture wrote. All of it is read and written under one lock.
## * **Frames** are rendered by the pure core (`core/raster`): the
##   background, every window back to front with its title bar, and the
##   widgets of its tree (labels, text fields with their value, checkboxes,
##   buttons). The words drawn are recorded per frame, so OCR of a fixture
##   frame returns exactly the words on it, with their pixel boxes.
## * **Input changes the tree**: typing goes into the focused editable node;
##   a click focuses the window and the node under the pointer, toggles a
##   checkbox and presses a button, whose `onPress` effect adds a label (the
##   fixture-form Submit button adds "Submitted <name field value>").
## * **Time is logical**: every timestamp the fixture reports is the
##   scenario's clock start plus `stepMs` per timestamp taken, so the same
##   sequence of verbs against the same state yields byte-identical output.
## * **Failure injection** (`GUIASSERT_FIXTURE_FAIL`, `_DENY`, `_UNAVAILABLE`,
##   `_DELAY_MS`) is parsed here (`parseFixtureEnv`).

import std/[json, options, os, strutils, tables, algorithm, sequtils, math, unicode]

import ../core/[geometry, image, png, raster, contract, desktop_types,
                ocr_types, tree_types, interfaces, sha256]
import ../[cancel, state_store]

const
  fixtureBackendName* = "fixture"
  scenarioSchema* = "guiassert/fixture-scenario/1"
  desktopSchema = "guiassert/fixture-desktop/1"
  metaSchema = "guiassert/fixture-meta/1"
  frameSchema = "guiassert/fixture-frame/1"
  titleBarHeight = 28

  builtinScenarioJson* = """
{
  "schema": "guiassert/fixture-scenario/1",
  "name": "fixture-form",
  "clock": {"start": "2026-01-01T00:00:00.000Z", "stepMs": 1000},
  "languages": ["eng"],
  "ocrConfidence": 96.5,
  "windowCapture": "own-pixels",
  "launchWindow": true,
  "background": [40, 44, 52],
  "baseFrame": null,
  "pointer": [0, 0],
  "displays": [
    {"id": "fixture-display-1", "name": "Fixture Display", "bounds": [0, 0, 800, 600],
     "scale": 1.0, "primary": true, "virtual": false}
  ],
  "apps": [
    {"pid": 4242, "name": "Fixture Form", "bundleId": "dev.guiassert.fixture-form",
     "appId": null, "frontmost": true, "hidden": false, "accessible": true}
  ],
  "windows": [
    {"id": "fixture-window-1", "pid": 4242, "app": "Fixture Form", "appId": null,
     "title": "Fixture Form", "document": "file:///fixture/Documents/Form.fixture",
     "bounds": [100, 80, 600, 400], "display": "fixture-display-1",
     "layer": 0, "onScreen": true, "focused": true, "minimized": false}
  ],
  "trees": [
    {"pid": 4242, "root": {
      "role": "application", "nativeRole": "AXApplication", "name": "Fixture Form",
      "children": [
        {"role": "window", "nativeRole": "AXWindow", "name": "Fixture Form",
         "bounds": [100, 80, 600, 400], "states": ["visible"],
         "children": [
           {"role": "label", "nativeRole": "AXStaticText", "name": "Name",
            "bounds": [130, 140, 80, 24], "states": ["visible", "enabled"]},
           {"role": "text-field", "nativeRole": "AXTextField", "name": "Name",
            "value": "", "bounds": [220, 136, 300, 32],
            "states": ["focused", "focusable", "enabled", "editable", "visible"],
            "actions": ["focus", "set-value"]},
           {"role": "checkbox", "nativeRole": "AXCheckBox", "name": "Subscribe",
            "bounds": [130, 200, 200, 24],
            "states": ["focusable", "enabled", "visible"], "actions": ["press", "focus"]},
           {"role": "button", "nativeRole": "AXButton", "name": "Submit",
            "bounds": [130, 260, 120, 36],
            "states": ["focusable", "enabled", "visible"], "actions": ["press", "focus"],
            "onPress": {"addLabel": {"name": "Submitted {field:Name}",
                                     "bounds": [130, 320, 400, 24]}}},
           {"role": "label", "nativeRole": "AXStaticText", "name": "Password",
            "bounds": [130, 384, 80, 24], "states": ["visible", "enabled"]},
           {"role": "text-field", "nativeRole": "AXSecureTextField", "name": "Password",
            "value": "", "bounds": [220, 380, 300, 32],
            "states": ["focusable", "enabled", "editable", "visible", "protected"],
            "actions": ["focus", "set-value"]}
         ]}
      ]}}
  ]
}
"""
    ## The built-in `fixture-form` scenario: one window with a labelled text
    ## field, a checkbox, a Submit button and a protected Password field
    ## (spec §9.2).

type
  PressEffect* = object
    ## What pressing a node does: add (or update) a status label, appended to
    ## the pressed node's parent. `{field:<name>}` in the label name expands
    ## to the value of the text field of that name in the same application.
    labelName*: string
    labelBounds*: Rect

  FNode* = object
    ## One node of a fixture accessibility tree, as the scenario states it.
    role*: Role
    nativeRole*: string
    name*, value*, description*: Option[string]
    text*: Option[string]
      ## The text content the scenario states; none: derived (`nodeText`).
    bounds*: Option[Rect]
    states*: set[NodeState]
    actions*: set[NodeAction]
    children*: seq[FNode]
    onPress*: Option[PressEffect]

  AppTree* = object
    pid*: int
    root*: FNode

  Desktop* = object
    ## One session's desktop: the scenario plus everything verbs changed.
    scenarioId*: string
    name*: string
    clockStartMs*: int64
    clockStepMs*: int
    languages*: seq[string]
    ocrConfidence*: float
    windowCapture*: string           ## "own-pixels" or "crop"
    launchWindow*: bool
      ## Whether an application `app-launch` starts opens a window (false:
      ## it runs without one, so `--wait-window-ms` expires).
    background*: Rgb
    baseFrame*: Option[string]       ## absolute path of a PNG
    pointer*: Point
    displays*: seq[Display]
    apps*: seq[App]
    windows*: seq[Window]            ## front to back
    trees*: seq[AppTree]
    nextPid*: int

  FixtureModule* = enum
    fmCapture = "capture", fmOcr = "ocr", fmTree = "tree", fmInput = "input",
    fmSession = "session"

  FailRule* = object
    verb*: string
    kind*: ErrorKind
    reason*: string

  FixtureEnv* = object
    ## The fixture's failure-injection settings (spec §9.2).
    fail*: seq[FailRule]                ## GUIASSERT_FIXTURE_FAIL
    denyScreenRecording*: bool          ## GUIASSERT_FIXTURE_DENY
    denyAccessibility*: bool
    unavailable*: set[FixtureModule]    ## GUIASSERT_FIXTURE_UNAVAILABLE
    delays*: Table[string, int]         ## GUIASSERT_FIXTURE_DELAY_MS
    hostMode*: string
      ## GUIASSERT_FIXTURE_HOST: "" (a healthy session host),
      ## "exit-before-ready" or "never-ready".
    recordingFault*: string
      ## GUIASSERT_FIXTURE_RECORDING: "" or "unfinalized" (recordings are
      ## written without their container index, as a recorder that died
      ## would leave them).

  EventSink* = proc (event: string, data: JsonNode) {.closure.}
    ## Receives the streaming events of an operation (spec §8.4).

  FixtureConfig* = object
    ## What every fixture backend is constructed with.
    stateDir*: string                ## the state directory root
    scenarioPath*: Option[string]    ## none: the built-in scenario
    env*: FixtureEnv
    token*: CancelToken
    emit*: EventSink
    selfExe*: string                 ## the program that runs a session host
    mediaAvailable*: bool            ## the ffmpeg media backend is compiled in
    ffmpegExe*: string               ## "" when no ffmpeg was found

  Meta = object
    scenarioId: string
    tick: int
    nextRecording: int
    nextSession: int

# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------

proc notFound*(reason, msg: string): ref BackendNotFoundError =
  newBackendError(BackendNotFoundError, fixtureBackendName, reason, msg)

proc failed*(reason, msg: string): ref BackendError =
  newBackendError(BackendError, fixtureBackendName, reason, msg)

proc unsupported*(msg: string): ref BackendUnavailableError =
  unavailable(fixtureBackendName, "unsupported-option", msg)

proc denied*(screenRecording: bool): ref PermissionDeniedError =
  ## The permission error the fixture raises under GUIASSERT_FIXTURE_DENY.
  if screenRecording:
    result = newBackendError(PermissionDeniedError, fixtureBackendName,
      "tcc-screen-recording", "Screen Recording is denied (GUIASSERT_FIXTURE_DENY)")
    result.remedy = "grant Screen Recording to the GuiAssert helper in System " &
      "Settings > Privacy & Security > Screen & System Audio Recording " &
      "(fixture: unset GUIASSERT_FIXTURE_DENY)"
  else:
    result = newBackendError(PermissionDeniedError, fixtureBackendName,
      "tcc-accessibility", "Accessibility is denied (GUIASSERT_FIXTURE_DENY)")
    result.remedy = "grant Accessibility to the GuiAssert helper in System " &
      "Settings > Privacy & Security > Accessibility " &
      "(fixture: unset GUIASSERT_FIXTURE_DENY)"

proc scenarioError(msg: string): ref ContractError =
  badArgs("invalid-value", "fixture scenario: " & msg)

# ---------------------------------------------------------------------------
# Failure-injection variables
# ---------------------------------------------------------------------------

proc parseFixtureEnv*(env: Table[string, string]): FixtureEnv =
  ## Parse the fixture's failure-injection variables from `env`. A malformed
  ## value is `bad-args` / `invalid-value` (never ignored):
  ##
  ## * `GUIASSERT_FIXTURE_FAIL=<verb>:<code>[:<reason>],…` — `code` 1..8,
  ##   `reason` one of that kind's reasons (default: its first);
  ## * `GUIASSERT_FIXTURE_DENY=screen-recording|accessibility,…`;
  ## * `GUIASSERT_FIXTURE_UNAVAILABLE=<module>,…` — capture, ocr, tree,
  ##   input, session;
  ## * `GUIASSERT_FIXTURE_DELAY_MS=<verb>:<ms>,…`;
  ## * `GUIASSERT_FIXTURE_HOST=exit-before-ready|never-ready` — the session
  ##   host `session-start` waits for exits, or never reports ready;
  ## * `GUIASSERT_FIXTURE_RECORDING=unfinalized` — recordings are written
  ##   without their container index.
  proc entries(name: string): seq[string] =
    let v = env.getOrDefault(name, "")
    if v.len == 0: return @[]
    for e in v.split(','):
      if e.len == 0:
        raise badArgs("invalid-value", name & ": empty entry in '" & v & "'")
      result.add e
  for e in entries("GUIASSERT_FIXTURE_FAIL"):
    let p = e.split(':')
    if p.len notin 2..3 or p[0].len == 0:
      raise badArgs("invalid-value", "GUIASSERT_FIXTURE_FAIL: '" & e &
        "' is not <verb>:<code>[:<reason>]")
    var code = 0
    try: code = parseInt(p[1])
    except ValueError: discard
    if code < 1 or code > 8:
      raise badArgs("invalid-value", "GUIASSERT_FIXTURE_FAIL: code '" & p[1] &
        "' is not 1..8")
    let kind = kindOfCode(code)
    let reason = if p.len == 3: p[2] else: reasonsOf(kind)[0]
    if reason notin reasonsOf(kind):
      raise badArgs("invalid-value", "GUIASSERT_FIXTURE_FAIL: '" & reason &
        "' is not a " & $kind & " reason")
    result.fail.add FailRule(verb: p[0], kind: kind, reason: reason)
  for e in entries("GUIASSERT_FIXTURE_DENY"):
    case e
    of "screen-recording": result.denyScreenRecording = true
    of "accessibility": result.denyAccessibility = true
    else:
      raise badArgs("invalid-value", "GUIASSERT_FIXTURE_DENY: '" & e &
        "' is not screen-recording or accessibility")
  for e in entries("GUIASSERT_FIXTURE_UNAVAILABLE"):
    var found = false
    for m in FixtureModule:
      if $m == e:
        result.unavailable.incl m
        found = true
    if not found:
      raise badArgs("invalid-value", "GUIASSERT_FIXTURE_UNAVAILABLE: '" & e &
        "' is not a module (capture, ocr, tree, input, session)")
  for e in entries("GUIASSERT_FIXTURE_DELAY_MS"):
    let p = e.split(':')
    var ms = -1
    if p.len == 2 and p[0].len > 0:
      try: ms = parseInt(p[1])
      except ValueError: discard
    if ms < 0:
      raise badArgs("invalid-value", "GUIASSERT_FIXTURE_DELAY_MS: '" & e &
        "' is not <verb>:<milliseconds>")
    result.delays[p[0]] = ms
  let host = env.getOrDefault("GUIASSERT_FIXTURE_HOST", "")
  if host notin ["", "exit-before-ready", "never-ready"]:
    raise badArgs("invalid-value", "GUIASSERT_FIXTURE_HOST: '" & host &
      "' is not exit-before-ready or never-ready")
  result.hostMode = host
  let rf = env.getOrDefault("GUIASSERT_FIXTURE_RECORDING", "")
  if rf notin ["", "unfinalized"]:
    raise badArgs("invalid-value", "GUIASSERT_FIXTURE_RECORDING: '" & rf &
      "' is not unfinalized")
  result.recordingFault = rf

proc injectedFailure*(fe: FixtureEnv, verb: string): Option[ref ContractError] =
  ## The failure GUIASSERT_FIXTURE_FAIL injects into `verb`, if any.
  for r in fe.fail:
    if r.verb == verb:
      return some(newContractError(r.kind, r.reason,
        "injected by GUIASSERT_FIXTURE_FAIL (" & verb & ":" & $r.kind.code & ")"))
  none(ref ContractError)

proc checkModuleAvailable*(cfg: FixtureConfig, m: FixtureModule) =
  ## Raise `backend-unavailable` when GUIASSERT_FIXTURE_UNAVAILABLE names `m`.
  if m in cfg.env.unavailable:
    raise unavailable(fixtureBackendName, "missing-tool",
      "the fixture " & $m & " module is unavailable (GUIASSERT_FIXTURE_UNAVAILABLE)")

# ---------------------------------------------------------------------------
# Scenario / desktop JSON
# ---------------------------------------------------------------------------

proc rgbFromJson(n: JsonNode, path: string): Rgb =
  if n.kind != JArray or n.len != 3:
    raise scenarioError(path & ": a colour is [r, g, b]")
  var c: array[3, int]
  for i in 0 .. 2:
    if n[i].kind != JInt or n[i].getInt notin 0..255:
      raise scenarioError(path & ": colour channels are integers 0..255")
    c[i] = n[i].getInt
  (c[0], c[1], c[2])

proc fnodeFromJson(n: JsonNode, path: string): FNode =
  expectObject(n, path, ["role"], ["nativeRole", "name", "value", "text",
               "description", "bounds", "states", "actions", "children", "onPress"])
  result.role = readEnum[Role](n, "role", path)
  result.nativeRole = if n.hasKey("nativeRole"): readStr(n, "nativeRole", path)
                      else: $result.role
  if n.hasKey("name"): result.name = readOptStr(n, "name", path)
  if n.hasKey("value"): result.value = readOptStr(n, "value", path)
  if n.hasKey("description"): result.description = readOptStr(n, "description", path)
  if n.hasKey("text"): result.text = readOptStr(n, "text", path)
  if n.hasKey("bounds") and n["bounds"].kind != JNull:
    result.bounds = some(rectFromJson(n["bounds"], path & ".bounds"))
  if n.hasKey("states"):
    for i, s in readArray(n, "states", path):
      if s.kind != JString: raise scenarioError(path & ".states: strings")
      try: result.states.incl parseNodeState(s.getStr)
      except TreeError as e: raise scenarioError(path & ".states: " & e.msg)
  if n.hasKey("actions"):
    for i, a in readArray(n, "actions", path):
      if a.kind != JString: raise scenarioError(path & ".actions: strings")
      try: result.actions.incl parseNodeAction(a.getStr)
      except TreeError as e: raise scenarioError(path & ".actions: " & e.msg)
  if n.hasKey("children"):
    for i, c in readArray(n, "children", path):
      result.children.add fnodeFromJson(c, path & ".children[" & $i & "]")
  if n.hasKey("onPress") and n["onPress"].kind != JNull:
    let p = n["onPress"]
    expectObject(p, path & ".onPress", ["addLabel"])
    let l = p["addLabel"]
    expectObject(l, path & ".onPress.addLabel", ["name", "bounds"])
    result.onPress = some(PressEffect(
      labelName: readStr(l, "name", path & ".onPress.addLabel"),
      labelBounds: rectFromJson(l["bounds"], path & ".onPress.addLabel.bounds")))

proc toJson(n: FNode): JsonNode =
  result = %*{"role": $n.role, "nativeRole": n.nativeRole}
  result["name"] = if n.name.isSome: %n.name.get else: newJNull()
  result["value"] = if n.value.isSome: %n.value.get else: newJNull()
  result["description"] = if n.description.isSome: %n.description.get else: newJNull()
  result["text"] = if n.text.isSome: %n.text.get else: newJNull()
  result["bounds"] = if n.bounds.isSome: n.bounds.get.toJson else: newJNull()
  result["states"] = %toSeq(n.states).mapIt($it)
  result["actions"] = %toSeq(n.actions).mapIt($it)
  var ch = newJArray()
  for c in n.children: ch.add c.toJson
  result["children"] = ch
  result["onPress"] =
    if n.onPress.isNone: newJNull()
    else: %*{"addLabel": {"name": n.onPress.get.labelName,
                          "bounds": n.onPress.get.labelBounds.toJson}}

proc desktopFromJson(n: JsonNode, baseDir: string, isState: bool): Desktop =
  ## Parse a scenario (`isState` false) or a saved desktop (true). Both share
  ## one format; a saved desktop also carries its scenario id and pid counter.
  const required = ["schema", "name", "displays", "apps", "windows", "trees"]
  const optional = ["clock", "languages", "ocrConfidence", "windowCapture",
                    "launchWindow", "background", "baseFrame", "pointer"]
  let path = if isState: "desktop" else: "scenario"
  if isState:
    expectObject(n, path, @required & @["scenarioId", "nextPid"], optional)
  else:
    expectObject(n, path, required, optional)
  let schema = readStr(n, "schema", path)
  if schema != (if isState: desktopSchema else: scenarioSchema):
    raise scenarioError("schema is '" & schema & "', expected " & scenarioSchema)
  result.name = readStr(n, "name", path)
  result.clockStartMs = parseTimestamp("2026-01-01T00:00:00.000Z")
  result.clockStepMs = 1000
  if n.hasKey("clock"):
    let c = n["clock"]
    expectObject(c, path & ".clock", ["start", "stepMs"])
    result.clockStartMs = parseTimestamp(readStr(c, "start", path & ".clock"))
    result.clockStepMs = readInt(c, "stepMs", path & ".clock")
    if result.clockStepMs < 1:
      raise scenarioError("clock.stepMs must be at least 1")
  result.languages = @["eng"]
  if n.hasKey("languages"):
    result.languages = @[]
    for i, l in readArray(n, "languages", path):
      if l.kind != JString or l.getStr.len == 0:
        raise scenarioError("languages are non-empty strings")
      result.languages.add l.getStr
  result.ocrConfidence = 96.5
  if n.hasKey("ocrConfidence"):
    result.ocrConfidence = readFloat(n, "ocrConfidence", path)
    if result.ocrConfidence < 0.0 or result.ocrConfidence > 100.0:
      raise scenarioError("ocrConfidence is on the 0..100 scale")
  result.windowCapture = "own-pixels"
  if n.hasKey("windowCapture"):
    result.windowCapture = readStr(n, "windowCapture", path)
    if result.windowCapture notin ["own-pixels", "crop"]:
      raise scenarioError("windowCapture is \"own-pixels\" or \"crop\"")
  result.launchWindow = true
  if n.hasKey("launchWindow"):
    result.launchWindow = readBool(n, "launchWindow", path)
  result.background = (40, 44, 52)
  if n.hasKey("background"):
    result.background = rgbFromJson(n["background"], path & ".background")
  if n.hasKey("baseFrame") and n["baseFrame"].kind != JNull:
    let p = readStr(n, "baseFrame", path)
    result.baseFrame = some(if isAbsolute(p): p else: baseDir / p)
  if n.hasKey("pointer"):
    result.pointer = pointFromJson(n["pointer"], path & ".pointer")
  for i, d in readArray(n, "displays", path):
    result.displays.add Display.fromJson(d, path & ".displays[" & $i & "]")
  if result.displays.len == 0:
    raise scenarioError("a scenario has at least one display")
  for i, a in readArray(n, "apps", path):
    result.apps.add App.fromJson(a, path & ".apps[" & $i & "]")
  for i, w in readArray(n, "windows", path):
    result.windows.add Window.fromJson(w, path & ".windows[" & $i & "]")
  for i, t in readArray(n, "trees", path):
    let tp = path & ".trees[" & $i & "]"
    expectObject(t, tp, ["pid", "root"])
    result.trees.add AppTree(pid: readInt(t, "pid", tp),
                             root: fnodeFromJson(t["root"], tp & ".root"))
  for a in result.apps:
    if a.accessible.isSome:
      var hasTree = false
      for t in result.trees: hasTree = hasTree or t.pid == a.pid
      if a.accessible.get != hasTree:
        raise scenarioError("app " & $a.pid & " says accessible " & $a.accessible.get &
          " but has " & (if hasTree: "a" else: "no") & " tree")
  var maxPid = 1000
  for a in result.apps: maxPid = max(maxPid, a.pid)
  result.nextPid = maxPid + 1
  if isState:
    result.scenarioId = readStr(n, "scenarioId", path)
    result.nextPid = readInt(n, "nextPid", path)

proc desktopToJson(d: Desktop): JsonNode =
  result = %*{"schema": desktopSchema, "name": d.name,
              "clock": {"start": formatTimestamp(d.clockStartMs),
                        "stepMs": d.clockStepMs},
              "languages": d.languages, "ocrConfidence": d.ocrConfidence,
              "windowCapture": d.windowCapture, "launchWindow": d.launchWindow,
              "background": [d.background.r, d.background.g, d.background.b],
              "baseFrame": (if d.baseFrame.isSome: %d.baseFrame.get else: newJNull()),
              "pointer": d.pointer.toJson,
              "scenarioId": d.scenarioId, "nextPid": d.nextPid}
  result["displays"] = newJArray()
  for x in d.displays: result["displays"].add x.toJson
  result["apps"] = newJArray()
  for x in d.apps: result["apps"].add x.toJson
  result["windows"] = newJArray()
  for x in d.windows: result["windows"].add x.toJson
  result["trees"] = newJArray()
  for t in d.trees: result["trees"].add %*{"pid": t.pid, "root": t.root.toJson}

proc loadScenario*(scenarioPath: Option[string]): Desktop =
  ## Parse the scenario: the file at `scenarioPath`, or the built-in
  ## `fixture-form`. Raises `bad-args` (`invalid-value`, or `not-found` /
  ## `file` for a missing file) for anything that is not a valid scenario.
  var text = builtinScenarioJson
  var baseDir = ""
  var id = "builtin:fixture-form"
  if scenarioPath.isSome:
    let p = scenarioPath.get
    if not fileExists(p):
      raise newContractError(ekNotFound, "file", "fixture scenario not found: " & p)
    try: text = readFileCapped(p, maxRecordBytes)
    except IOError as e: raise scenarioError("cannot read " & p & ": " & e.msg)
    baseDir = absolutePath(p).parentDir
    id = "file:" & sha256Hex(text)
  var n: JsonNode
  try: n = parseJson(text)
  except CatchableError as e: raise scenarioError("not JSON: " & e.msg)
  try:
    result = desktopFromJson(n, baseDir, isState = false)
  except JsonShapeError as e:
    raise scenarioError(e.msg)
  result.scenarioId = id

# ---------------------------------------------------------------------------
# State: desktops, meta (clock and counters), frame registry
# ---------------------------------------------------------------------------

proc fixtureDir*(cfg: FixtureConfig): string = cfg.stateDir / "fixture"
proc lockDir(cfg: FixtureConfig): string = cfg.fixtureDir / "lock"
proc desktopPath(cfg: FixtureConfig, session: string): string =
  cfg.fixtureDir / "desktops" / (session & ".json")
proc metaPath(cfg: FixtureConfig): string = cfg.fixtureDir / "meta.json"

template withFixtureLock*(cfg: FixtureConfig, body: untyped) =
  ## Run `body` holding the fixture state lock.
  ensurePrivateDir(cfg.fixtureDir)
  withLock(cfg.lockDir, cfg.token):
    body

proc loadMeta(cfg: FixtureConfig, scenarioId: string): Meta =
  let r = readRecord(cfg.metaPath, metaSchema)
  if r.isNone:
    return Meta(scenarioId: scenarioId, tick: 0, nextRecording: 1, nextSession: 1)
  let n = r.get
  try:
    expectObject(n, "meta", ["scenarioId", "tick", "nextRecording", "nextSession"])
    result = Meta(scenarioId: readStr(n, "scenarioId", "meta"),
                  tick: readInt(n, "tick", "meta"),
                  nextRecording: readInt(n, "nextRecording", "meta"),
                  nextSession: readInt(n, "nextSession", "meta"))
  except JsonShapeError as e:
    raise newContractError(ekInternal, "exception", "fixture meta: " & e.msg)
  if result.scenarioId != scenarioId:
    raise badArgs("conflicting-arguments",
      "the state directory holds fixture state of scenario " & result.scenarioId &
      ", not of " & scenarioId & "; use another --state-dir")

proc saveMeta(cfg: FixtureConfig, m: Meta) =
  writeRecord(cfg.metaPath, metaSchema,
    %*{"scenarioId": m.scenarioId, "tick": m.tick,
       "nextRecording": m.nextRecording, "nextSession": m.nextSession})

type
  FixtureTxn* = object
    ## The state read under the lock by `transact`.
    scenario*: Desktop
    meta: Meta

proc nowStamp*(t: var FixtureTxn): string =
  ## Take the next logical timestamp.
  inc t.meta.tick
  formatTimestamp(t.scenario.clockStartMs + int64(t.meta.tick) * int64(t.scenario.clockStepMs))

proc currentTick*(t: FixtureTxn): int = t.meta.tick
proc stepMs*(t: FixtureTxn): int = t.scenario.clockStepMs

proc nextRecordingId*(t: var FixtureTxn): string =
  result = "rec-" & $t.meta.nextRecording
  inc t.meta.nextRecording

proc nextSessionId*(t: var FixtureTxn): string =
  result = "fixture-" & $t.meta.nextSession
  inc t.meta.nextSession

proc loadDesktop*(cfg: FixtureConfig, t: FixtureTxn, session: string): Desktop =
  ## The desktop of `session` (seeded from the scenario the first time).
  let r = readRecord(cfg.desktopPath(session), desktopSchema)
  if r.isNone:
    return t.scenario
  var n = r.get
  n["schema"] = %desktopSchema
  try:
    result = desktopFromJson(n, "", isState = true)
  except JsonShapeError as e:
    raise newContractError(ekInternal, "exception", "fixture desktop: " & e.msg)
  except ContractError as e:
    raise newContractError(ekInternal, "exception", "fixture desktop: " & e.msg)

proc saveDesktop*(cfg: FixtureConfig, session: string, d: Desktop) =
  var n = desktopToJson(d)
  n.delete("schema")
  writeRecord(cfg.desktopPath(session), desktopSchema, n)

proc removeDesktop*(cfg: FixtureConfig, session: string) =
  removeRecord(cfg.desktopPath(session))

template transact*(cfg: FixtureConfig, txn: untyped, body: untyped) =
  ## Run `body` under the fixture lock with `txn` (a `FixtureTxn`) holding
  ## the scenario and the counters; the counters are saved afterwards.
  let scen = loadScenario(cfg.scenarioPath)
  withFixtureLock(cfg):
    var txn = FixtureTxn(scenario: scen, meta: loadMeta(cfg, scen.scenarioId))
    body
    saveMeta(cfg, txn.meta)

# ---------------------------------------------------------------------------
# Trees
# ---------------------------------------------------------------------------

proc treeIndex*(d: Desktop, pid: int): int =
  for i, t in d.trees:
    if t.pid == pid: return i
  -1

proc nodeText*(n: FNode): Option[string] =
  ## A node's text content (spec §7.5 `Node.text`): what the scenario states,
  ## else what a platform text interface would report for its role: a
  ## label's displayed string, a text field's or text area's content; none
  ## for a role without a text interface.
  if n.text.isSome: return n.text
  case n.role
  of roleLabel: n.name
  of roleTextField, roleTextArea: some(n.value.get(""))
  else: none(string)

proc contractNode(n: FNode, path: string): Node =
  ## The contract node of a fixture node (children not converted). The
  ## serializer blanks a protected node's value and text; the fixture blanks
  ## them here as well, so no layer above it holds the characters.
  result = Node(path: path, role: n.role, nativeRole: n.nativeRole, name: n.name,
                value: n.value, text: nodeText(n), description: n.description,
                bounds: n.bounds, states: n.states, actions: n.actions,
                childCount: n.children.len)
  if stProtected in n.states:
    result.value = none(string)
    result.text = none(string)

proc toNode(n: FNode, path: string, depthLeft: int, budget: var int,
            truncated: var bool, count: var int): Node =
  ## Convert with paths; at most `budget` nodes, `depthLeft` levels below.
  result = contractNode(n, path)
  dec budget
  inc count
  if depthLeft == 0:
    return
  var seen = initCountTable[Role]()
  for c in n.children:
    let idx = seen.getOrDefault(c.role, 0)
    seen.inc c.role
    if budget <= 0:
      truncated = true
      return
    result.children.add toNode(c, childPath(path, c.role, idx), depthLeft - 1,
                               budget, truncated, count)

proc appPath(pid: int): string = "/app[" & $pid & "]"

proc nodeTree*(d: Desktop, ti: int, depth: Option[int], maxNodes: int):
    tuple[root: Node, count: int, truncated: bool] =
  ## The tree of application `d.trees[ti]` as contract nodes.
  var budget = maxNodes
  var truncated = false
  var count = 0
  let root = toNode(d.trees[ti].root, appPath(d.trees[ti].pid),
                    (if depth.isSome: depth.get else: -1), budget, truncated, count)
  (root, count, truncated)

proc resolvePath*(d: var Desktop, path: string):
    tuple[ti: int, chain: seq[int]] =
  ## Locate the node at `path`: the tree index and the child-index chain.
  ## Raises `bad-args` for a malformed path and `not-found` / `element` when
  ## it does not resolve.
  var tp: TreePath
  try: tp = parseTreePath(path)
  except TreeError as e: raise badArgs("invalid-value", e.msg)
  let ti = d.treeIndex(tp.pid)
  if ti < 0: raise notFound("element", "no application with pid " & $tp.pid)
  result.ti = ti
  var node = d.trees[ti].root
  for st in tp.steps:
    var seen = 0
    var found = -1
    for ci, c in node.children:
      if c.role == st.role:
        if seen == st.index:
          found = ci
          break
        inc seen
    if found < 0:
      raise notFound("element", "no element at " & path)
    result.chain.add found
    node = node.children[found]

proc walk*(n: var FNode, chain: seq[int]): var FNode =
  ## The descendant of `n` a child-index chain names.
  if chain.len == 0: return n
  result = n.children[chain[0]].walk(chain[1 .. ^1])

template nodeAt*(d: var Desktop, ti: int, chain: seq[int]): var FNode =
  ## The node a `resolvePath` result names, as a mutable location.
  d.trees[ti].root.walk(chain)

proc pathOf*(d: Desktop, ti: int, chain: seq[int]): string =
  ## The path of the node a chain names.
  result = appPath(d.trees[ti].pid)
  var node = d.trees[ti].root
  for ci in chain:
    let c = node.children[ci]
    var idx = 0
    for j in 0 ..< ci:
      if node.children[j].role == c.role: inc idx
    result = childPath(result, c.role, idx)
    node = c

proc elementAt*(d: Desktop, ti: int, chain: seq[int]): Node =
  ## The node at a chain as a contract element (no children).
  var dd = d
  let n = dd.trees[ti].root.walk(chain)
  contractNode(n, d.pathOf(ti, chain))

proc shiftBounds*(n: var FNode, dx, dy: int) =
  ## Move a node, its descendants and the labels its press adds by (dx, dy).
  if n.bounds.isSome:
    let b = n.bounds.get
    n.bounds = some(rect(b.x + dx, b.y + dy, b.width, b.height))
  if n.onPress.isSome:
    let b = n.onPress.get.labelBounds
    n.onPress = some(PressEffect(labelName: n.onPress.get.labelName,
                                 labelBounds: rect(b.x + dx, b.y + dy, b.width, b.height)))
  for c in n.children.mitems: c.shiftBounds(dx, dy)

proc clearFocus(n: var FNode) =
  n.states.excl stFocused
  for c in n.children.mitems: clearFocus(c)

proc focusedChain(n: FNode, chain: var seq[int]): bool =
  if stFocused in n.states: return true
  for i, c in n.children:
    chain.add i
    if focusedChain(c, chain): return true
    discard chain.pop()
  false

proc fieldValue(n: FNode, name: string): Option[string] =
  ## The value of the text field named `name`; a protected field's value is
  ## never expanded into a label.
  if n.role == roleTextField and n.name == some(name):
    return (if stProtected in n.states: some("") else: n.value)
  for c in n.children:
    let v = fieldValue(c, name)
    if v.isSome: return v

proc expandTemplate(d: Desktop, ti: int, s: string): string =
  ## Expand `{field:<name>}` with that text field's value.
  result = s
  while true:
    let a = result.find("{field:")
    if a < 0: break
    let b = result.find('}', a)
    if b < 0: break
    let name = result[a + 7 ..< b]
    let v = fieldValue(d.trees[ti].root, name).get("")
    result = result[0 ..< a] & v & result[b + 1 .. ^1]
  result = result.strip

proc press*(d: var Desktop, ti: int, chain: seq[int]) =
  ## Press the node: toggle a checkbox, run a button's `onPress` effect.
  var node = d.nodeAt(ti, chain)
  if node.role == roleCheckbox:
    if stChecked in node.states: d.nodeAt(ti, chain).states.excl stChecked
    else: d.nodeAt(ti, chain).states.incl stChecked
  if node.onPress.isSome and chain.len > 0:
    let eff = node.onPress.get
    let label = FNode(role: roleLabel, nativeRole: "AXStaticText",
                      name: some(d.expandTemplate(ti, eff.labelName)),
                      bounds: some(eff.labelBounds),
                      states: {stVisible, stEnabled})
    let parentChain = chain[0 ..< chain.high]
    var replaced = false
    for c in d.nodeAt(ti, parentChain).children.mitems:
      if c.role == roleLabel and c.bounds == some(eff.labelBounds):
        c = label
        replaced = true
    if not replaced:
      d.nodeAt(ti, parentChain).children.add label

proc focusNode*(d: var Desktop, ti: int, chain: seq[int]) =
  ## Give the node keyboard focus (when it is focusable).
  if stFocusable notin d.nodeAt(ti, chain).states: return
  clearFocus(d.trees[ti].root)
  d.nodeAt(ti, chain).states.incl stFocused

proc focusedEditable*(d: var Desktop): Option[tuple[ti: int, chain: seq[int]]] =
  ## The focused editable node of the frontmost application, if any.
  if d.windows.len == 0: return
  let ti = d.treeIndex(d.windows[0].pid)
  if ti < 0: return
  var chain: seq[int]
  if focusedChain(d.trees[ti].root, chain):
    if stEditable in d.nodeAt(ti, chain).states:
      return some((ti, chain))

# ---------------------------------------------------------------------------
# Windows
# ---------------------------------------------------------------------------

proc windowIndex*(d: Desktop, id: string): int =
  for i, w in d.windows:
    if w.id == id: return i
  -1

proc focusWindowAt*(d: var Desktop, wi: int) =
  ## Bring window `wi` to the front and give it (and its application) focus.
  var w = d.windows[wi]
  d.windows.delete(wi)
  d.windows.insert(w, 0)
  for i in 0 ..< d.windows.len:
    d.windows[i].focused = i == 0
  for a in d.apps.mitems:
    a.frontmost = a.pid == w.pid

proc hitTest*(d: var Desktop, p: Point): Option[tuple[wi, ti: int, chain: seq[int]]] =
  ## The front-most window under `p` and the deepest node of its
  ## application whose bounds contain `p`.
  for wi, w in d.windows:
    if not w.onScreen or w.minimized or not w.bounds.contains(p): continue
    let ti = d.treeIndex(w.pid)
    var chain: seq[int]
    if ti >= 0:
      var node = d.trees[ti].root
      var descended = true
      while descended:
        descended = false
        for ci in countdown(node.children.high, 0):
          let c = node.children[ci]
          if c.bounds.isSome and c.bounds.get.contains(p):
            chain.add ci
            node = c
            descended = true
            break
    return some((wi, ti, chain))
  none(tuple[wi, ti: int, chain: seq[int]])

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

type
  Frame* = object
    image*: RgbImage
    words*: seq[OcrWord]

proc px(v: int, scale: float): int = int(round(float(v) * scale))
proc pxRect(r: Rect, origin: Point, scale: float): Rect =
  rect(px(r.x - origin.x, scale), px(r.y - origin.y, scale),
       px(r.width, scale), px(r.height, scale))

proc addText(f: var Frame, text: string, at: Point, color: Rgb, fs: int,
             conf: float) =
  ## Draw `text` and record each of its words with its pixel box.
  if text.len == 0: return
  discard f.image.drawText(text, at, color, fs)
  let blk = f.words.mapIt(it.blockNum).foldl(max(a, b), 0) + 1
  var i = 0
  while i < text.len:
    if text[i] == ' ':
      inc i
      continue
    var j = i
    while j < text.len and text[j] != ' ': inc j
    let word = text[i ..< j]
    let s = textSize(word, fs)
    f.words.add OcrWord(text: word, confidence: conf,
                        bbox: [at.x + i * cellWidth * fs, at.y, s.width, s.height],
                        lineNum: 1, blockNum: blk)
    i = j

proc drawNode(f: var Frame, n: FNode, origin: Point, scale: float, fs: int,
              conf: float) =
  if n.bounds.isSome and n.role != roleWindow:
    let r = pxRect(n.bounds.get, origin, scale)
    let textH = glyphHeight * fs
    let midY = r.y + max(0, (r.height - textH) div 2)
    case n.role
    of roleLabel:
      f.addText(n.name.get(""), point(r.x, midY), (20, 20, 20), fs, conf)
    of roleTextField, roleTextArea:
      f.image.fillRect(r, (255, 255, 255))
      f.image.strokeRect(r, (if stFocused in n.states: (40, 100, 220)
                             else: (120, 120, 120)), 2)
      # A protected field shows one mask character per character, as a
      # secure text field does; its characters are never drawn.
      let shown = if stProtected in n.states: repeat('*', n.value.get("").runeLen)
                  else: n.value.get("")
      f.addText(shown, point(r.x + px(6, scale), midY), (20, 20, 20), fs, conf)
    of roleCheckbox:
      let box = rect(r.x, r.y + max(0, (r.height - px(16, scale)) div 2),
                     px(16, scale), px(16, scale))
      f.image.fillRect(box, (255, 255, 255))
      f.image.strokeRect(box, (80, 80, 80), 2)
      if stChecked in n.states:
        f.image.fillRect(rect(box.x + px(4, scale), box.y + px(4, scale),
                              px(8, scale), px(8, scale)), (40, 100, 220))
      f.addText(n.name.get(""), point(r.x + px(24, scale), midY), (20, 20, 20), fs, conf)
    of roleButton:
      f.image.fillRect(r, (60, 100, 200))
      f.image.strokeRect(r, (30, 50, 120), 2)
      let label = n.name.get("")
      let s = textSize(label, fs)
      f.addText(label, point(r.x + max(0, (r.width - s.width) div 2), midY),
                (255, 255, 255), fs, conf)
    else: discard
  for c in n.children:
    if c.role != roleWindow:
      f.drawNode(c, origin, scale, fs, conf)

proc drawWindow(f: var Frame, d: Desktop, w: Window, origin: Point, scale: float,
                fs: int) =
  let r = pxRect(w.bounds, origin, scale)
  f.image.fillRect(r, (236, 236, 236))
  f.image.strokeRect(r, (90, 90, 90), 1)
  let bar = rect(r.x, r.y, r.width, px(titleBarHeight, scale))
  f.image.fillRect(bar, (200, 200, 205))
  f.addText(w.title.get(""), point(r.x + px(10, scale),
            r.y + max(0, (bar.height - glyphHeight * fs) div 2)), (30, 30, 30), fs,
            d.ocrConfidence)
  let ti = d.treeIndex(w.pid)
  if ti < 0: return
  # The window's own subtree: the window node whose bounds are the window's.
  for c in d.trees[ti].root.children:
    if c.role == roleWindow and (c.bounds == some(w.bounds) or c.name == w.title):
      f.drawNode(c, origin, scale, fs, d.ocrConfidence)
      return

proc displayOf*(d: Desktop, id: Option[string]): Display =
  ## The display `id`, or the primary one. Raises `not-found` / `display`.
  if id.isNone:
    for x in d.displays:
      if x.primary: return x
    return d.displays[0]
  for x in d.displays:
    if x.id == id.get: return x
  raise notFound("display", "no display '" & id.get & "'")

proc renderArea*(d: Desktop, area: Rect, scale: float, onlyWindow = "",
                 cursor = true): Frame =
  ## Render the desktop region `area` (desktop coordinates) at `scale`. With
  ## `onlyWindow`, only that window is drawn (its own pixels).
  result.image = newImage(RgbImage, px(area.width, scale), px(area.height, scale))
  result.image.fillRect(rect(0, 0, result.image.width, result.image.height),
                        d.background)
  if d.baseFrame.isSome and onlyWindow.len == 0:
    let primary = d.displayOf(none(string))
    var base: RgbImage
    try:
      base = decodePngRgb(readFileCapped(d.baseFrame.get, maxImageFileBytes))
    except CatchableError as e:
      raise failed("capture-failed", "cannot read the scenario's base frame " &
        d.baseFrame.get & ": " & e.msg)
    let off = pxRect(primary.bounds, point(area.x, area.y), scale)
    for y in 0 ..< base.height:
      for x in 0 ..< base.width:
        let i = (y * base.width + x) * 3
        result.image.setPixel(off.x + x, off.y + y,
          (ord(base.pixels[i]), ord(base.pixels[i + 1]), ord(base.pixels[i + 2])))
  let fs = max(1, int(round(2.0 * scale)))
  for i in countdown(d.windows.high, 0):
    let w = d.windows[i]
    if not w.onScreen or w.minimized: continue
    if onlyWindow.len > 0 and w.id != onlyWindow: continue
    if intersection(w.bounds, area).isEmpty: continue
    result.drawWindow(d, w, point(area.x, area.y), scale, fs)
  if cursor and onlyWindow.len == 0 and area.contains(d.pointer):
    let c = pxRect(rect(d.pointer.x, d.pointer.y, 1, 1), point(area.x, area.y), scale)
    for row in 0 ..< px(12, scale):
      result.image.fillRect(rect(c.x, c.y + row, max(1, row * 2 div 3), 1), (0, 0, 0))
  # Keep only the words that lie entirely inside the image.
  let bounds = rect(0, 0, result.image.width, result.image.height)
  result.words = result.words.filterIt(bounds.contains(rect(it.bbox)))

# ---------------------------------------------------------------------------
# Frames on disk
# ---------------------------------------------------------------------------

proc framePath(cfg: FixtureConfig, sha: string): string =
  cfg.fixtureDir / "frames" / (sha & ".json")

proc registerFrame*(cfg: FixtureConfig, sha: string, words: seq[OcrWord],
                    origin: Point, scale: float) =
  ## Remember the words drawn on the frame whose PNG has SHA-256 `sha`.
  var ws = newJArray()
  for w in words: ws.add w.toJson
  writeRecord(cfg.framePath(sha), frameSchema,
    %*{"words": ws, "origin": origin.toJson, "scale": scale})

proc lookupFrame*(cfg: FixtureConfig, sha: string):
    Option[tuple[words: seq[OcrWord], origin: Point, scale: float]] =
  ## The words of a frame the fixture wrote, by the SHA-256 of its PNG.
  let r = readRecord(cfg.framePath(sha), frameSchema)
  if r.isNone: return
  let n = r.get
  try:
    expectObject(n, "frame", ["words", "origin", "scale"])
    var words: seq[OcrWord]
    for i, w in readArray(n, "words", "frame"):
      words.add OcrWord.fromJson(w, "frame.words[" & $i & "]")
    result = some((words, pointFromJson(n["origin"], "frame.origin"),
                   readFloat(n, "scale", "frame")))
  except JsonShapeError as e:
    raise newContractError(ekInternal, "exception", "fixture frame record: " & e.msg)

proc writeFileAtomic*(path, content: string) =
  ## Write a capture output: a temporary name in the same directory, then a
  ## rename, so a reader never sees a partial file (spec §7.5). The
  ## directory must exist (`not-found` / `file` otherwise).
  let dir = path.parentDir
  if not dirExists(dir):
    raise notFound("file", "the output directory does not exist: " & dir)
  let tmp = dir / ("." & path.extractFilename & ".partial-" & $getCurrentProcessId() &
                   "-" & $getThreadId())
  try:
    writeFile(tmp, content)
    moveFile(tmp, path)
  except IOError, OSError:
    let msg = getCurrentExceptionMsg()
    try: removeFile(tmp) except OSError: discard
    raise failed("capture-failed", "cannot write " & path & ": " & msg)

proc sortedNames*(dir: string, ext: string): seq[string] =
  ## The files of `dir` with extension `ext`, sorted by name.
  for k, p in walkDir(dir):
    if k in {pcFile, pcLinkToFile} and p.endsWith(ext): result.add p
  result.sort()
