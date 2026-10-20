## GuiAssert core: the `guiassert-desktop/1` contract.
##
## Everything a process-boundary consumer of GuiAssert reads is defined here
## once (spec §7):
##
## * the **envelope** every invocation prints (`successEnvelope`,
##   `failureEnvelope`, `renderEnvelope`);
## * the frozen **exit codes, kinds and reasons** (`ErrorKind`, `reasonsOf`)
##   and the error every layer raises to produce a failure envelope
##   (`ContractError`);
## * the **one `toJson` and one strict `fromJson` of every object** of spec
##   §7.5, used by the CLI, by `serve`, by the fixture backend and by the
##   state records alike (spec §7.4, "one serializer per object").
##
## Serialization rules (spec §7.4) enforced here: keys are camelCase; an
## absent optional value is `null`, never an omitted key; arrays are never
## `null`; a string that is not valid UTF-8 is repaired with U+FFFD and its
## object gains `"lossy": true`; integers must fit in 53 bits and floats must
## be finite, otherwise rendering fails with `internal` / `serialization`
## rather than writing a value a consumer would misread. Parsing is strict:
## an unknown key, a missing key or a value of the wrong JSON type is a
## `JsonShapeError` naming the offending path, never ignored.
##
## Pure (spec §3.2): no I/O, no clock, no environment.

import std/[json, options, tables, strutils, times]

import ./[geometry, desktop_types, ocr_types, tree_types]

const
  contractName* = "guiassert-desktop"
  contractMajor* = 1
  contractMinor* = 0
    ## Contract 1.0 is frozen (spec §7.7): every later change is an additive
    ## 1.x minor (a new verb, flag, key, reason, feature, event or backend
    ## name); changing a shape or a meaning needs a new major.
  serveProtocolVersion* = 1
    ## The `"v"` of every serve message; moves with the contract major.
  maxSafeInteger* = 9007199254740991'i64
    ## 2^53 - 1, the largest integer every JSON consumer reads exactly.

type
  ErrorKind* = enum
    ## The failure kinds; the exit code of kind `k` is `ord(k) + 1`
    ## (`code`). The table is frozen (spec §7.3).
    ekInternal = "internal"                    ## 1
    ekBadArgs = "bad-args"                     ## 2
    ekNotFound = "not-found"                   ## 3
    ekBackendUnavailable = "backend-unavailable" ## 4
    ekBackendError = "backend-error"           ## 5
    ekPermissionDenied = "permission-denied"   ## 6
    ekTimeout = "timeout"                      ## 7
    ekCancelled = "cancelled"                  ## 8

  ContractError* = object of CatchableError
    ## A failure that becomes a failure envelope. `msg` is the human
    ## message; `reason` is one of `reasonsOf(kind)`; `remedy` and `details`
    ## are empty / nil when they do not apply.
    kind*: ErrorKind
    reason*: string
    remedy*: string
    details*: JsonNode

  JsonShapeError* = object of CatchableError
    ## A JSON value does not have the documented shape (unknown or missing
    ## key, wrong type, value out of range). `msg` names the path.

const
  kindReasons: array[ErrorKind, seq[string]] = [
    @["exception", "serialization"],
    @["unknown-verb", "unknown-flag", "missing-argument", "invalid-value",
      "conflicting-arguments", "unknown-backend", "contract-unsupported",
      "invalid-name", "name-in-use"],
    @["session", "display", "window", "app", "element", "recording", "file",
      "request"],
    @["not-compiled-in", "wrong-platform", "missing-tool",
      "display-server-unsupported", "unsupported-option", "not-implemented",
      "no-isolated-session", "session-not-running"],
    @["capture-failed", "ocr-failed", "tree-failed", "input-failed",
      "session-failed", "busy", "stale-path"],
    @["tcc-screen-recording", "tcc-accessibility", "uinput-access",
      "atspi-disabled", "desktop-access"],
    @["deadline", "condition-not-met"],
    @["request", "signal", "shutdown"]]
    ## The closed reason set of each kind (spec §7.3, contract 1.0).

  featureVocabulary*: seq[tuple[feature, module: string]] = @[
    ("window-enumeration", "capture"), ("display-capture", "capture"),
    ("window-capture", "capture"), ("region-capture", "capture"),
    ("own-pixels-capture", "capture"), ("recording", "capture"),
    ("ocr", "ocr"),
    ("tree-read", "tree"), ("element-actions", "tree"),
    ("pointer-input", "input"), ("keyboard-input", "input"),
    ("window-management", "input"),
    ("session-management", "session"), ("app-management", "session"),
    ("session-virtual-display", "session"), ("session-isolated", "session"),
    ("session-headless", "session"), ("session-vnc", "session"),
    ("video-decode", "media")]
    ## The closed set of `capabilities.features[].feature` names and the
    ## module whose backend provides each (spec §7.5, "Features"). The same
    ## names are `details.feature` of every exit 4 and exit 6 envelope.

  degradedReasons*: seq[string] = @["window-crop", "png-sequence",
    "fixture-frames-only", "titles-redacted", "posted-delivery"]
    ## The closed set of `reason`s of a feature whose state is `degraded`
    ## (spec §7.5, "Features").

func code*(k: ErrorKind): int = ord(k) + 1
  ## The process exit code of kind `k`.

proc kindOfCode*(code: int): ErrorKind =
  ## The kind whose exit code is `code` (1..8). Raises `ValueError` for any
  ## other code.
  if code < 1 or code > 8:
    raise newException(ValueError, "no error kind has exit code " & $code)
  ErrorKind(code - 1)

func reasonsOf*(k: ErrorKind): seq[string] = kindReasons[k]
  ## The reasons kind `k` may carry.

proc parseErrorKind*(s: string): ErrorKind =
  ## The kind spelled `s`. Raises `ValueError` for an unknown spelling.
  for k in ErrorKind:
    if $k == s: return k
  raise newException(ValueError, "unknown error kind '" & s & "'")

proc newContractError*(kind: ErrorKind, reason, msg: string, remedy = "",
                       details: JsonNode = nil): ref ContractError =
  ## Build the error behind a failure envelope. A `reason` outside the
  ## kind's closed set is a programming error and becomes an `internal`
  ## error that says so, so an unlisted reason never reaches a consumer.
  if reason notin kindReasons[kind]:
    result = newException(ContractError,
      "internal: reason '" & reason & "' is not a " & $kind &
      " reason (while reporting: " & msg & ")")
    result.kind = ekInternal
    result.reason = "exception"
    return
  result = newException(ContractError, msg)
  result.kind = kind
  result.reason = reason
  result.remedy = remedy
  result.details = details

proc badArgs*(reason, msg: string, details: JsonNode = nil): ref ContractError =
  ## Shorthand for a `bad-args` error.
  newContractError(ekBadArgs, reason, msg, details = details)

proc isFeature*(name: string): bool =
  ## True when `name` is in the feature vocabulary.
  for (f, _) in featureVocabulary:
    if f == name: return true
  false

proc featureModule*(name: string): string =
  ## The module whose backend provides feature `name` ("" for an unknown one).
  for (f, m) in featureVocabulary:
    if f == name: return m
  ""

proc featuresOfModule*(module: string): seq[string] =
  ## The features module `module` provides, in vocabulary order.
  for (f, m) in featureVocabulary:
    if m == module: result.add f

const featureFreeReasons* = ["session-not-running"]
  ## The `backend-unavailable` reasons whose `details.feature` is always
  ## null: the session, not a capability, is missing (spec §7.3).

proc withFeature*(e: ref ContractError, feature: string): ref ContractError =
  ## Attach `details.feature` to an exit 4 or exit 6 error that does not
  ## carry one yet (spec §7.3): `feature`, or null for a feature-free reason
  ## or when `feature` is "". Any other error is returned unchanged; an error
  ## that already names its feature (or null) keeps it.
  result = e
  if e.kind notin {ekBackendUnavailable, ekPermissionDenied}: return
  if e.details.isNil: e.details = newJObject()
  elif e.details.kind != JObject: return
  if e.details.hasKey("feature"): return
  e.details["feature"] =
    if feature.len == 0 or e.reason in featureFreeReasons: newJNull()
    else: %feature

proc shapeError(path, msg: string): ref JsonShapeError =
  newException(JsonShapeError, path & ": " & msg)

# ---------------------------------------------------------------------------
# Scalars: strings, numbers, timestamps
# ---------------------------------------------------------------------------

proc sanitizeUtf8*(s: string, lossy: var bool): string =
  ## `s` with every byte that does not start or continue a well-formed UTF-8
  ## sequence (RFC 3629: no overlong forms, no surrogates, at most U+10FFFF)
  ## replaced by U+FFFD. Sets `lossy` when anything was replaced.
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    let b0 = ord(s[i])
    var n = 0
    var lo = 0x80
    var hi = 0xBF
    if b0 < 0x80: n = 0
    elif b0 >= 0xC2 and b0 <= 0xDF: n = 1
    elif b0 == 0xE0: (n, lo) = (2, 0xA0)
    elif b0 >= 0xE1 and b0 <= 0xEC: n = 2
    elif b0 == 0xED: (n, hi) = (2, 0x9F)
    elif b0 >= 0xEE and b0 <= 0xEF: n = 2
    elif b0 == 0xF0: (n, lo) = (3, 0x90)
    elif b0 >= 0xF1 and b0 <= 0xF3: n = 3
    elif b0 == 0xF4: (n, hi) = (3, 0x8F)
    else: n = -1
    # A lead byte needs `n` continuation bytes at i+1 .. i+n, all present.
    var ok = n >= 0 and i + n <= s.len - 1
    if ok:
      for j in 1 .. n:
        let b = ord(s[i + j])
        let (l, h) = if j == 1: (lo, hi) else: (0x80, 0xBF)
        if b < l or b > h:
          ok = false
          break
    if ok:
      result.add s[i .. i + n]
      i += n + 1
    else:
      result.add "\xEF\xBF\xBD"
      lossy = true
      inc i

proc isValidUtf8*(s: string): bool =
  ## True when `s` is well-formed UTF-8.
  var lossy = false
  discard sanitizeUtf8(s, lossy)
  not lossy

proc formatTimestamp*(unixMs: int64): string =
  ## The contract spelling of an instant: RFC 3339 UTC with milliseconds,
  ## `2026-10-20T09:15:02.123Z`.
  let t = fromUnix(unixMs div 1000).utc
  t.format("yyyy-MM-dd'T'HH:mm:ss") & "." & align($(unixMs mod 1000), 3, '0') & "Z"

proc parseTimestamp*(s: string): int64 =
  ## The Unix time in milliseconds of a contract timestamp. Raises
  ## `JsonShapeError` unless `s` is exactly `YYYY-MM-DDTHH:MM:SS.mmmZ`.
  if s.len != 24 or s[19] != '.' or s[23] != 'Z':
    raise shapeError("timestamp", "expected YYYY-MM-DDTHH:MM:SS.mmmZ, got '" & s & "'")
  for i in 20 .. 22:
    if s[i] notin Digits:
      raise shapeError("timestamp", "malformed milliseconds in '" & s & "'")
  try:
    let dt = parse(s[0 .. 18], "yyyy-MM-dd'T'HH:mm:ss", utc())
    result = dt.toTime.toUnix * 1000 + parseInt(s[20 .. 22])
  except TimeParseError, ValueError:
    raise shapeError("timestamp", "malformed timestamp '" & s & "'")
  if formatTimestamp(result) != s:
    raise shapeError("timestamp", "non-canonical timestamp '" & s & "'")

proc finiteJson*(f: float, what = "a number"): JsonNode =
  ## `f` as a JSON number. Raises `ContractError` (`internal` /
  ## `serialization`) for NaN or an infinity: `std/json` would write those as
  ## the strings "nan" / "inf", which a consumer would misread, so every
  ## float of the contract goes through here.
  if f != f or f == Inf or f == NegInf:
    raise newContractError(ekInternal, "serialization",
      "cannot serialize the non-finite value of " & what)
  newJFloat(f)

proc checkSerializable*(n: JsonNode, path = "$") =
  ## Raise `ContractError` (`internal` / `serialization`) when `n` holds a
  ## float that is not finite or an integer beyond 53 bits.
  case n.kind
  of JFloat:
    let f = n.getFloat
    if f != f or f == Inf or f == NegInf:
      raise newContractError(ekInternal, "serialization",
        "cannot serialize the non-finite number at " & path)
  of JInt:
    let v = n.getBiggestInt
    if v > maxSafeInteger or v < -maxSafeInteger:
      raise newContractError(ekInternal, "serialization",
        "the integer at " & path & " does not fit in 53 bits")
  of JArray:
    for i, e in n.elems: checkSerializable(e, path & "[" & $i & "]")
  of JObject:
    for k, v in n.pairs: checkSerializable(v, path & "." & k)
  else: discard

# ---------------------------------------------------------------------------
# Strict reading helpers
# ---------------------------------------------------------------------------

proc expectKind(n: JsonNode, k: set[JsonNodeKind], path, what: string) =
  if n.isNil or n.kind notin k:
    raise shapeError(path, "expected " & what & ", got " &
      (if n.isNil: "nothing" else: $n.kind))

proc expectObject*(n: JsonNode, path: string, keys: openArray[string],
                   optional: openArray[string] = []) =
  ## Require `n` to be an object holding every key of `keys`, optionally
  ## keys of `optional`, and nothing else. Raises `JsonShapeError`.
  expectKind(n, {JObject}, path, "an object")
  for k in keys:
    if not n.hasKey(k):
      raise shapeError(path, "missing key \"" & k & "\"")
  for k in n.keys:
    if k notin keys and k notin optional:
      raise shapeError(path, "unknown key \"" & k & "\"")

proc readStr*(n: JsonNode, key, path: string): string =
  ## The string at `n[key]`.
  expectKind(n[key], {JString}, path & "." & key, "a string")
  n[key].getStr

proc readOptStr*(n: JsonNode, key, path: string): Option[string] =
  ## The string or null at `n[key]`.
  if n[key].kind == JNull: return none(string)
  some(readStr(n, key, path))

proc readInt*(n: JsonNode, key, path: string): int =
  ## The integer at `n[key]` (a JSON integer within 53 bits).
  let v = n[key]
  expectKind(v, {JInt}, path & "." & key, "an integer")
  let b = v.getBiggestInt
  if b > maxSafeInteger or b < -maxSafeInteger:
    raise shapeError(path & "." & key, "integer out of range")
  int(b)

proc readOptInt*(n: JsonNode, key, path: string): Option[int] =
  ## The integer or null at `n[key]`.
  if n[key].kind == JNull: return none(int)
  some(readInt(n, key, path))

proc readFloat*(n: JsonNode, key, path: string): float =
  ## The number at `n[key]` (an integer is accepted for a float field).
  let v = n[key]
  expectKind(v, {JInt, JFloat}, path & "." & key, "a number")
  v.getFloat

proc readBool*(n: JsonNode, key, path: string): bool =
  ## The boolean at `n[key]`.
  expectKind(n[key], {JBool}, path & "." & key, "a boolean")
  n[key].getBool

proc readArray*(n: JsonNode, key, path: string): seq[JsonNode] =
  ## The elements of the array at `n[key]` (never null).
  expectKind(n[key], {JArray}, path & "." & key, "an array")
  n[key].elems

proc readEnum*[T: enum](n: JsonNode, key, path: string): T =
  ## The member of `T` spelled by the string at `n[key]`.
  let s = readStr(n, key, path)
  for v in T:
    if $v == s: return v
  raise shapeError(path & "." & key, "'" & s & "' is not a valid " & $T)

proc readLossy(n: JsonNode, path: string): bool =
  if n.hasKey("lossy"):
    return readBool(n, "lossy", path)

# ---------------------------------------------------------------------------
# Geometry
# ---------------------------------------------------------------------------

proc toJson*(r: Rect): JsonNode =
  ## `[x, y, w, h]`.
  %[r.x, r.y, r.width, r.height]

proc toJson*(p: Point): JsonNode =
  ## `[x, y]`.
  %[p.x, p.y]

proc rectFromJson*(n: JsonNode, path: string): Rect =
  ## A rectangle from `[x, y, w, h]` with a non-negative extent.
  expectKind(n, {JArray}, path, "an [x, y, w, h] array")
  if n.len != 4:
    raise shapeError(path, "a rectangle has 4 integers, got " & $n.len)
  var a: array[4, int]
  for i in 0 .. 3:
    expectKind(n[i], {JInt}, path & "[" & $i & "]", "an integer")
    a[i] = int(n[i].getBiggestInt)
  if a[2] < 0 or a[3] < 0:
    raise shapeError(path, "a rectangle has a non-negative width and height")
  rect(a)

proc pointFromJson*(n: JsonNode, path: string): Point =
  ## A point from `[x, y]`.
  expectKind(n, {JArray}, path, "an [x, y] array")
  if n.len != 2:
    raise shapeError(path, "a point has 2 integers, got " & $n.len)
  for i in 0 .. 1:
    expectKind(n[i], {JInt}, path & "[" & $i & "]", "an integer")
  point(int(n[0].getBiggestInt), int(n[1].getBiggestInt))

proc optToJson[T](o: Option[T]): JsonNode =
  if o.isNone: newJNull()
  else:
    when T is Rect or T is Point: o.get.toJson
    else: %o.get

proc strField(s: string, lossy: var bool): JsonNode =
  %sanitizeUtf8(s, lossy)

proc optStrField(s: Option[string], lossy: var bool): JsonNode =
  if s.isNone: newJNull() else: %sanitizeUtf8(s.get, lossy)

proc addLossy(n: JsonNode, lossy: bool) =
  if lossy: n["lossy"] = %true

# ---------------------------------------------------------------------------
# Desktop objects
# ---------------------------------------------------------------------------

proc toJson*(d: Display): JsonNode =
  ## `Display` (spec §7.5).
  var lossy = false
  result = %*{"id": strField(d.id, lossy), "name": optStrField(d.name, lossy),
              "bounds": d.bounds.toJson, "scale": finiteJson(d.scale, "Display.scale"),
              "primary": d.primary, "virtual": d.isVirtual}
  result.addLossy lossy

proc fromJson*(_: typedesc[Display], n: JsonNode, path = "display"): Display =
  ## Strict inverse of `toJson(Display)`.
  expectObject(n, path, ["id", "name", "bounds", "scale", "primary", "virtual"],
               ["lossy"])
  discard readLossy(n, path)
  result = Display(id: readStr(n, "id", path), name: readOptStr(n, "name", path),
                   bounds: rectFromJson(n["bounds"], path & ".bounds"),
                   scale: readFloat(n, "scale", path),
                   primary: readBool(n, "primary", path),
                   isVirtual: readBool(n, "virtual", path))
  if not (result.scale > 0.0) or result.scale == Inf:
    raise shapeError(path & ".scale", "scale must be positive and finite")

proc toJson*(w: Window): JsonNode =
  ## `Window` (spec §7.5).
  var lossy = false
  result = %*{"id": strField(w.id, lossy), "pid": w.pid,
              "app": strField(w.app, lossy), "appId": optStrField(w.appId, lossy),
              "title": optStrField(w.title, lossy),
              "document": optStrField(w.document, lossy), "bounds": w.bounds.toJson,
              "display": optStrField(w.display, lossy), "layer": w.layer,
              "onScreen": w.onScreen, "focused": w.focused,
              "minimized": w.minimized}
  result.addLossy lossy

proc fromJson*(_: typedesc[Window], n: JsonNode, path = "window"): Window =
  ## Strict inverse of `toJson(Window)`.
  expectObject(n, path, ["id", "pid", "app", "appId", "title", "document",
                         "bounds", "display", "layer", "onScreen", "focused",
                         "minimized"], ["lossy"])
  discard readLossy(n, path)
  Window(id: readStr(n, "id", path), pid: readInt(n, "pid", path),
         app: readStr(n, "app", path), appId: readOptStr(n, "appId", path),
         title: readOptStr(n, "title", path),
         document: readOptStr(n, "document", path),
         bounds: rectFromJson(n["bounds"], path & ".bounds"),
         display: readOptStr(n, "display", path),
         layer: readInt(n, "layer", path),
         onScreen: readBool(n, "onScreen", path),
         focused: readBool(n, "focused", path),
         minimized: readBool(n, "minimized", path))

proc toJson*(a: App): JsonNode =
  ## `App` (spec §7.5).
  var lossy = false
  result = %*{"pid": a.pid, "name": strField(a.name, lossy),
              "bundleId": optStrField(a.bundleId, lossy),
              "appId": optStrField(a.appId, lossy),
              "frontmost": a.frontmost, "hidden": a.hidden,
              "accessible": (if a.accessible.isNone: newJNull() else: %a.accessible.get)}
  result.addLossy lossy

proc fromJson*(_: typedesc[App], n: JsonNode, path = "app"): App =
  ## Strict inverse of `toJson(App)`.
  expectObject(n, path, ["pid", "name", "bundleId", "appId", "frontmost",
                         "hidden", "accessible"], ["lossy"])
  discard readLossy(n, path)
  result = App(pid: readInt(n, "pid", path), name: readStr(n, "name", path),
               bundleId: readOptStr(n, "bundleId", path),
               appId: readOptStr(n, "appId", path),
               frontmost: readBool(n, "frontmost", path),
               hidden: readBool(n, "hidden", path))
  if n["accessible"].kind != JNull:
    result.accessible = some(readBool(n, "accessible", path))

proc toJson*(i: Isolation): JsonNode =
  ## `Isolation` (spec §7.5).
  %*{"pixels": i.pixels, "input": i.input, "clipboard": i.clipboard}

proc fromJson*(_: typedesc[Isolation], n: JsonNode, path = "isolation"): Isolation =
  ## Strict inverse of `toJson(Isolation)`.
  expectObject(n, path, ["pixels", "input", "clipboard"])
  Isolation(pixels: readBool(n, "pixels", path), input: readBool(n, "input", path),
            clipboard: readBool(n, "clipboard", path))

proc toJson*(s: Session): JsonNode =
  ## `Session` (spec §7.5).
  var env = newJObject()
  for k, v in s.env: env[k] = %v
  var envUnset = newJArray()
  for k in s.envUnset: envUnset.add %k
  var displays = newJArray()
  for d in s.displays: displays.add d.toJson
  result = %*{"id": s.id, "name": optToJson(s.name), "kind": $s.kind,
              "backend": s.backend, "platform": $s.platform,
              "state": $s.state, "stateReason": optToJson(s.stateReason),
              "lifetime": $s.lifetime, "isolation": s.isolation.toJson,
              "displays": displays, "env": env, "envUnset": envUnset,
              "vnc": (if s.vnc.isNone: newJNull()
                      else: %*{"host": s.vnc.get.host, "port": s.vnc.get.port}),
              "backends": {"capture": s.backends.capture, "tree": s.backends.tree,
                           "input": s.backends.input},
              "createdAt": s.createdAt, "hostPid": optToJson(s.hostPid)}

proc fromJson*(_: typedesc[Session], n: JsonNode, path = "session"): Session =
  ## Strict inverse of `toJson(Session)`.
  const keys = ["id", "name", "kind", "backend", "platform", "state",
                "stateReason", "lifetime", "isolation", "displays", "env",
                "envUnset", "vnc", "backends", "createdAt", "hostPid"]
  expectObject(n, path, keys)
  result.id = readStr(n, "id", path)
  result.name = readOptStr(n, "name", path)
  result.kind = readEnum[SessionKind](n, "kind", path)
  result.backend = readStr(n, "backend", path)
  result.platform = readEnum[SessionPlatform](n, "platform", path)
  result.state = readEnum[SessionState](n, "state", path)
  result.stateReason = readOptStr(n, "stateReason", path)
  result.lifetime = readEnum[SessionLifetime](n, "lifetime", path)
  result.isolation = Isolation.fromJson(n["isolation"], path & ".isolation")
  for i, d in readArray(n, "displays", path):
    result.displays.add Display.fromJson(d, path & ".displays[" & $i & "]")
  expectKind(n["env"], {JObject}, path & ".env", "an object")
  for k, v in n["env"].pairs:
    expectKind(v, {JString}, path & ".env." & k, "a string")
    result.env[k] = v.getStr
  for i, k in readArray(n, "envUnset", path):
    expectKind(k, {JString}, path & ".envUnset[" & $i & "]", "a string")
    result.envUnset.add k.getStr
  if n["vnc"].kind != JNull:
    let v = n["vnc"]
    expectObject(v, path & ".vnc", ["host", "port"])
    result.vnc = some(VncEndpoint(host: readStr(v, "host", path & ".vnc"),
                                  port: readInt(v, "port", path & ".vnc")))
  let b = n["backends"]
  expectObject(b, path & ".backends", ["capture", "tree", "input"])
  result.backends = SessionBackends(capture: readStr(b, "capture", path & ".backends"),
                                    tree: readStr(b, "tree", path & ".backends"),
                                    input: readStr(b, "input", path & ".backends"))
  result.createdAt = readStr(n, "createdAt", path)
  discard parseTimestamp(result.createdAt)
  result.hostPid = readOptInt(n, "hostPid", path)

proc toJson*(s: ImageSource): JsonNode =
  ## `ImageRef.source` (spec §7.5).
  %*{"kind": $s.kind, "id": optToJson(s.id), "session": optToJson(s.session)}

proc fromJson*(_: typedesc[ImageSource], n: JsonNode, path = "source"): ImageSource =
  ## Strict inverse of `toJson(ImageSource)`.
  expectObject(n, path, ["kind", "id", "session"])
  ImageSource(kind: readEnum[ImageSourceKind](n, "kind", path),
              id: readOptStr(n, "id", path), session: readOptStr(n, "session", path))

proc toJson*(i: ImageRef): JsonNode =
  ## `ImageRef` (spec §7.5).
  %*{"path": i.path, "format": i.format, "width": i.width, "height": i.height,
     "scale": finiteJson(i.scale, "ImageRef.scale"), "origin": i.origin.toJson,
     "sha256": i.sha256,
     "capturedAt": i.capturedAt, "source": i.source.toJson}

proc fromJson*(_: typedesc[ImageRef], n: JsonNode, path = "image"): ImageRef =
  ## Strict inverse of `toJson(ImageRef)`.
  expectObject(n, path, ["path", "format", "width", "height", "scale", "origin",
                         "sha256", "capturedAt", "source"])
  result = ImageRef(path: readStr(n, "path", path), format: readStr(n, "format", path),
                    width: readInt(n, "width", path), height: readInt(n, "height", path),
                    scale: readFloat(n, "scale", path),
                    origin: pointFromJson(n["origin"], path & ".origin"),
                    sha256: readStr(n, "sha256", path),
                    capturedAt: readStr(n, "capturedAt", path),
                    source: ImageSource.fromJson(n["source"], path & ".source"))
  if result.format != "png":
    raise shapeError(path & ".format", "contract 1 images are png")

proc toJson*(r: Recording): JsonNode =
  ## `Recording` (spec §7.5).
  %*{"id": r.id, "path": r.path, "state": $r.state, "format": $r.format,
     "width": r.width, "height": r.height, "fps": finiteJson(r.fps, "Recording.fps"),
     "durationMs": optToJson(r.durationMs), "frames": optToJson(r.frames),
     "source": r.source.toJson, "startedAt": r.startedAt,
     "stoppedAt": optToJson(r.stoppedAt)}

proc fromJson*(_: typedesc[Recording], n: JsonNode, path = "recording"): Recording =
  ## Strict inverse of `toJson(Recording)`.
  expectObject(n, path, ["id", "path", "state", "format", "width", "height", "fps",
                         "durationMs", "frames", "source", "startedAt",
                         "stoppedAt"])
  Recording(id: readStr(n, "id", path), path: readStr(n, "path", path),
            state: readEnum[RecordingState](n, "state", path),
            format: readEnum[RecordingFormat](n, "format", path),
            width: readInt(n, "width", path), height: readInt(n, "height", path),
            fps: readFloat(n, "fps", path),
            durationMs: readOptInt(n, "durationMs", path),
            frames: readOptInt(n, "frames", path),
            source: ImageSource.fromJson(n["source"], path & ".source"),
            startedAt: readStr(n, "startedAt", path),
            stoppedAt: readOptStr(n, "stoppedAt", path))

proc toJson*(w: OcrWord): JsonNode =
  ## `OcrWord` (spec §7.5): confidence 0..100, bbox in image pixels.
  var lossy = false
  result = %*{"text": strField(w.text, lossy),
              "confidence": finiteJson(w.confidence, "OcrWord.confidence"),
              "bbox": rect(w.bbox).toJson, "line": w.lineNum, "block": w.blockNum}
  result.addLossy lossy

proc fromJson*(_: typedesc[OcrWord], n: JsonNode, path = "word"): OcrWord =
  ## Strict inverse of `toJson(OcrWord)`.
  expectObject(n, path, ["text", "confidence", "bbox", "line", "block"], ["lossy"])
  discard readLossy(n, path)
  result = OcrWord(text: readStr(n, "text", path),
                   confidence: readFloat(n, "confidence", path),
                   bbox: rectFromJson(n["bbox"], path & ".bbox").toArray,
                   lineNum: readInt(n, "line", path), blockNum: readInt(n, "block", path))
  if result.confidence < 0.0 or result.confidence > 100.0:
    raise shapeError(path & ".confidence", "confidence is on the 0..100 scale")

proc toJson*(n: Node): JsonNode =
  ## `Node` (spec §7.5), children included. A `protected` node (a password
  ## or secure text field) is written with `value` and `text` null whatever
  ## the backend put there, so its characters never cross the contract.
  var lossy = false
  let protected = stProtected in n.states
  var states = newJArray()
  for s in NodeState:
    if s in n.states: states.add %($s)
  var actions = newJArray()
  for a in NodeAction:
    if a in n.actions: actions.add %($a)
  var children = newJArray()
  for c in n.children: children.add c.toJson
  result = %*{"path": n.path, "role": $n.role,
              "nativeRole": strField(n.nativeRole, lossy),
              "name": optStrField(n.name, lossy),
              "value": (if protected: newJNull() else: optStrField(n.value, lossy)),
              "text": (if protected: newJNull() else: optStrField(n.text, lossy)),
              "description": optStrField(n.description, lossy),
              "bounds": optToJson(n.bounds), "states": states, "actions": actions,
              "childCount": n.childCount, "children": children}
  result.addLossy lossy

proc elementToJson*(n: Node): JsonNode =
  ## An `Element`: the node with `"children": []` (its `childCount` kept).
  var e = n
  e.children = @[]
  e.toJson

proc fromJson*(_: typedesc[Node], n: JsonNode, path = "node"): Node =
  ## Strict inverse of `toJson(Node)`.
  expectObject(n, path, ["path", "role", "nativeRole", "name", "value", "text",
                         "description", "bounds", "states", "actions",
                         "childCount", "children"], ["lossy"])
  discard readLossy(n, path)
  result.path = readStr(n, "path", path)
  try:
    discard parseTreePath(result.path)
  except TreeError as e:
    raise shapeError(path & ".path", e.msg)
  result.role = readEnum[Role](n, "role", path)
  result.nativeRole = readStr(n, "nativeRole", path)
  result.name = readOptStr(n, "name", path)
  result.value = readOptStr(n, "value", path)
  result.text = readOptStr(n, "text", path)
  result.description = readOptStr(n, "description", path)
  if n["bounds"].kind != JNull:
    result.bounds = some(rectFromJson(n["bounds"], path & ".bounds"))
  for i, s in readArray(n, "states", path):
    expectKind(s, {JString}, path & ".states[" & $i & "]", "a string")
    try: result.states.incl parseNodeState(s.getStr)
    except TreeError as e: raise shapeError(path & ".states", e.msg)
  for i, a in readArray(n, "actions", path):
    expectKind(a, {JString}, path & ".actions[" & $i & "]", "a string")
    try: result.actions.incl parseNodeAction(a.getStr)
    except TreeError as e: raise shapeError(path & ".actions", e.msg)
  if stProtected in result.states and (result.value.isSome or result.text.isSome):
    raise shapeError(path, "a protected node reports neither value nor text")
  result.childCount = readInt(n, "childCount", path)
  for i, c in readArray(n, "children", path):
    result.children.add Node.fromJson(c, path & ".children[" & $i & "]")
  if result.childCount < result.children.len:
    raise shapeError(path & ".childCount", "childCount is below the number of children")

proc toJson*(r: InputReport): JsonNode =
  ## `InputReport` (spec §7.5). Typed text never appears: only `length`.
  var path = newJNull()
  if r.path.isSome:
    path = newJArray()
    for p in r.path.get: path.add p.toJson
  %*{"kind": r.kind, "at": optToJson(r.at), "to": optToJson(r.to),
     "button": optToJson(r.button), "count": optToJson(r.count),
     "length": optToJson(r.length), "keys": optToJson(r.keys), "path": path,
     "delivery": $r.delivery, "session": r.session}

proc fromJson*(_: typedesc[InputReport], n: JsonNode, path = "input"): InputReport =
  ## Strict inverse of `toJson(InputReport)`.
  expectObject(n, path, ["kind", "at", "to", "button", "count", "length", "keys",
                         "path", "delivery", "session"])
  result = InputReport(kind: readStr(n, "kind", path),
                       button: readOptStr(n, "button", path),
                       count: readOptInt(n, "count", path),
                       length: readOptInt(n, "length", path),
                       keys: readOptStr(n, "keys", path),
                       delivery: readEnum[Delivery](n, "delivery", path),
                       session: readStr(n, "session", path))
  if n["at"].kind != JNull: result.at = some(pointFromJson(n["at"], path & ".at"))
  if n["to"].kind != JNull: result.to = some(pointFromJson(n["to"], path & ".to"))
  if n["path"].kind != JNull:
    var pts: seq[Point]
    for i, p in readArray(n, "path", path):
      pts.add pointFromJson(p, path & ".path[" & $i & "]")
    result.path = some(pts)

proc toJson*(p: Permissions): JsonNode =
  ## `Permissions` (spec §7.5, `permissions` verb).
  %*{"screenRecording": $p.screenRecording, "accessibility": $p.accessibility,
     "inputSynthesis": $p.inputSynthesis, "desktopAccess": $p.desktopAccess,
     "identity": optToJson(p.identity)}

proc fromJson*(_: typedesc[Permissions], n: JsonNode, path = "permissions"): Permissions =
  ## Strict inverse of `toJson(Permissions)`.
  expectObject(n, path, ["screenRecording", "accessibility", "inputSynthesis",
                         "desktopAccess", "identity"])
  Permissions(screenRecording: readEnum[PermissionState](n, "screenRecording", path),
              accessibility: readEnum[PermissionState](n, "accessibility", path),
              inputSynthesis: readEnum[PermissionState](n, "inputSynthesis", path),
              desktopAccess: readEnum[PermissionState](n, "desktopAccess", path),
              identity: readOptStr(n, "identity", path))

proc featureProblem*(f: Feature): string =
  ## "" when `f` follows the feature rules of spec §7.5, else what is wrong:
  ## the name is in the vocabulary; `supported` and `available` carry no
  ## reason; `degraded` carries one of `degradedReasons`; `unavailable`
  ## carries a `backend-unavailable` or `permission-denied` reason.
  if not isFeature(f.feature): return "'" & f.feature & "' is not a feature of the vocabulary"
  case f.state
  of fsSupported, fsAvailable:
    if f.reason.isSome: return "a " & $f.state & " feature carries no reason"
  of fsDegraded:
    if f.reason.isNone or f.reason.get notin degradedReasons:
      return "a degraded feature's reason is one of " & degradedReasons.join(", ")
  of fsUnavailable:
    if f.reason.isNone or (f.reason.get notin kindReasons[ekBackendUnavailable] and
                           f.reason.get notin kindReasons[ekPermissionDenied]):
      return "an unavailable feature's reason is a backend-unavailable or " &
             "permission-denied reason"
  ""

proc toJson*(f: Feature): JsonNode =
  ## One `capabilities` feature entry (spec §7.5). A feature outside the
  ## rules (`featureProblem`) is an `internal` / `serialization` error, so an
  ## undocumented name or reason never reaches a consumer.
  let problem = featureProblem(f)
  if problem.len > 0:
    raise newContractError(ekInternal, "serialization",
      "cannot serialize the feature entry: " & problem)
  %*{"feature": f.feature, "backend": f.backend, "state": $f.state,
     "reason": optToJson(f.reason), "remedy": optToJson(f.remedy)}

proc fromJson*(_: typedesc[Feature], n: JsonNode, path = "feature"): Feature =
  ## Strict inverse of `toJson(Feature)`.
  expectObject(n, path, ["feature", "backend", "state", "reason", "remedy"])
  result = Feature(feature: readStr(n, "feature", path),
                   backend: readStr(n, "backend", path),
                   state: readEnum[FeatureState](n, "state", path),
                   reason: readOptStr(n, "reason", path),
                   remedy: readOptStr(n, "remedy", path))
  let problem = featureProblem(result)
  if problem.len > 0: raise shapeError(path, problem)

proc contractJson*(): JsonNode =
  ## `{"name": "guiassert-desktop", "major": 1, "minor": 0}`.
  %*{"name": contractName, "major": contractMajor, "minor": contractMinor}

# ---------------------------------------------------------------------------
# The envelope
# ---------------------------------------------------------------------------

proc successEnvelope*(verb: string, data: JsonNode): JsonNode =
  ## `{"ok": true, "verb": …, "data": …}`.
  doAssert data != nil and data.kind == JObject, "envelope data is an object"
  %*{"ok": true, "verb": verb, "data": data}

proc errorJson*(e: ref ContractError): JsonNode =
  ## The `error` object of a failure envelope; `reason`, `remedy` and
  ## `details` are always present (null when they do not apply).
  %*{"code": e.kind.code, "kind": $e.kind, "message": e.msg,
     "reason": (if e.reason.len == 0: newJNull() else: %e.reason),
     "remedy": (if e.remedy.len == 0: newJNull() else: %e.remedy),
     "details": (if e.details.isNil: newJNull() else: e.details)}

proc failureEnvelope*(verb: string, e: ref ContractError): JsonNode =
  ## `{"ok": false, "verb": …, "error": {…}}`.
  %*{"ok": false, "verb": verb, "error": errorJson(e)}

proc renderEnvelope*(env: JsonNode): string =
  ## The compact one-line spelling of an envelope. Raises `ContractError`
  ## (`internal` / `serialization`) for a value that cannot be written
  ## faithfully.
  checkSerializable(env)
  var lossy = false
  result = sanitizeUtf8($env, lossy)
  if lossy:
    raise newContractError(ekInternal, "serialization",
      "the envelope holds a string that is not valid UTF-8")
  if '\n' in result:
    raise newContractError(ekInternal, "serialization",
      "the rendered envelope spans several lines")

proc envelopeExitCode*(env: JsonNode): int =
  ## The exit code an envelope implies: 0 on success, `error.code` otherwise.
  if env["ok"].getBool: 0 else: env["error"]["code"].getInt
