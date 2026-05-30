## GuiAssert Script Timed Timeline Parser
##
## Parses JSON and YAML keyframe scripts that drive the timed action engine.
## The grammar is documented in `Video-Session-Capture.md` section 2 and
## consists of a top-level mapping with a `metadata` block and a `timeline`
## sequence of keyframes.
##
## Validation is two-fold:
##   1. Out-of-order timestamps (a later keyframe has an earlier `time` than
##      its predecessor) raise `ScriptValidationError`.
##   2. Timing overlaps (a keyframe's narration runs past the next keyframe's
##      `time`) also raise `ScriptValidationError`. The narration duration is
##      estimated at `wordsPerMinute = 150.0`.
##
## The YAML subset implemented here covers the schema actually used by the
## script protocol: scalar mappings, sequences of mappings, inline flow
## sequences `[a, b, c]`, integer and float scalars, double-quoted strings,
## and plain scalars. Indentation is normalised to spaces.

import std/[json, options, strutils, tables]

import ./emotive
import ./avatar_track

export emotive
export avatar_track

type
  ScriptValidationError* = object of CatchableError
  ScriptParseError* = object of CatchableError

  WindowLayout* = object
    ## Pixel rectangle describing where a logical window should be
    ## placed on the desktop.  Used by the three-window orchestrator
    ## (see `metadata.window_layout` in the script schema).
    x*: int
    y*: int
    width*: int
    height*: int

  TalkingHeadMeta* = object
    ## Optional `metadata.talking_head` block describing how the
    ## animated talking-head overlay should be produced.  Used by the
    ## runner to pick between the stock testsrc2 placeholder and a
    ## generative AI provider (SadTalker today; D-ID / HeyGen / Hedra
    ## are reserved for future revisions).
    provider*: string
      ## Provider identifier as it appears in the YAML — e.g.
      ## "stock_avatar" (default), "sadtalker", "did", "heygen",
      ## "hedra".  When the block is absent provider is "".
    avatarImage*: string
      ## Filesystem path (absolute or relative to the script) of the
      ## portrait image fed to the talking-head provider.  Required
      ## for non-stock providers; ignored by the stock provider.
    device*: string
      ## Optional acceleration hint — one of "auto" (default), "mps",
      ## or "cpu".  Forwarded verbatim to the provider implementation;
      ## unknown values are passed through so future providers can use
      ## them without a parser change.
    extras*: Table[string, string]
      ## Additional `key: value` scalars under `metadata.talking_head`.
      ## Captures forward-looking knobs (e.g. `pose_style`,
      ## `enhancer`) without forcing schema bumps for each one.

  ScriptMetadata* = object
    title*: string
    resolution*: string
    fps*: int
    targets*: seq[string]
      ## Optional list of window IDs the script drives — for example
      ## `["desktop", "terminal", "vscode"]`.  Empty for scripts that
      ## predate the multi-window schema.
    windowLayout*: Table[string, WindowLayout]
      ## Optional per-target pixel layout map.  Keys must be subsets
      ## of `targets`; validation enforces this.
    talkingHead*: TalkingHeadMeta
      ## Optional talking-head provider configuration.  When the
      ## `metadata.talking_head` block is absent the `provider` field
      ## is the empty string and callers should default to the stock
      ## testsrc2 placeholder.
    emotiveDefaults*: CommonEmotiveConfig
      ## Script-level emotive baseline (emotion, voice settings,
      ## gesture knobs, background mode).  Per-keyframe `emotive`
      ## blocks layer on top via `overlay()`.  Empty for legacy
      ## scripts.
    avatarPreferences*: AvatarPreferences
      ## Ordered preferred-avatar list plus an optional fallback.
      ## Each plugin's avatar-discovery proc matches against this
      ## ranking; explicit `per_provider` IDs short-circuit matching.

  Keyframe* = object
    time*: float
    action*: string
    params*: JsonNode
    narration*: Option[string]
    targetWindow*: string
    emotive*: CommonEmotiveConfig
      ## Per-keyframe emotive override.  Layered on top of
      ## `metadata.emotive_defaults` via `effectiveEmotive()`.
      ## Which logical window (one of `metadata.targets`) this
      ## keyframe is dispatched to.  Defaults to "desktop" when
      ## absent and at least one of the targets is "desktop"; if
      ## `targets` is empty this field is also empty (legacy single-
      ## window scripts).

  Script* = object
    metadata*: ScriptMetadata
    timeline*: seq[Keyframe]
    avatar*: AvatarTrack
      ## Optional animated talking-head overlay.  Empty for legacy
      ## scripts that do not need a presenter-PiP composition.

const
  WordsPerMinute* = 150.0
    ## Average narration speed used to estimate how long a `narration` field
    ## would take to deliver. Chosen to be intentionally close to "calm
    ## technical voiceover" speed.

# ---------------------------------------------------------------------------
# Narration timing helpers
# ---------------------------------------------------------------------------

proc estimateNarrationSeconds*(text: string): float =
  ## Estimate how long it would take to speak `text` at `WordsPerMinute`.
  ## Tokens are split on whitespace; punctuation is part of the surrounding
  ## word. Empty / whitespace-only text returns 0.
  if text.len == 0:
    return 0.0
  var words = 0
  var inWord = false
  for ch in text:
    if ch in {' ', '\t', '\r', '\n'}:
      inWord = false
    else:
      if not inWord:
        inc words
      inWord = true
  if words == 0:
    return 0.0
  result = (float(words) / WordsPerMinute) * 60.0

# ---------------------------------------------------------------------------
# JsonNode helpers (shared between JSON + YAML paths)
# ---------------------------------------------------------------------------

proc extractIntField(node: JsonNode, fieldName, path: string): int =
  ## Read an integer or float-rounded-to-int from a JSON object.
  ## Used by the `WindowLayout` parser for `x`/`y`/`width`/`height`.
  if not node.hasKey(fieldName):
    raise newException(ScriptParseError,
      path & " is missing required field `" & fieldName & "`")
  let v = node[fieldName]
  case v.kind
  of JInt:   return int(v.getInt)
  of JFloat: return int(v.getFloat)
  else:
    raise newException(ScriptParseError,
      path & "." & fieldName & " must be numeric, got " & $v.kind)

proc extractWindowLayout(node: JsonNode, name: string): WindowLayout =
  if node.kind != JObject:
    raise newException(ScriptParseError,
      "metadata.window_layout." & name & " must be an object, got " & $node.kind)
  let path = "metadata.window_layout." & name
  result = WindowLayout(
    x: extractIntField(node, "x", path),
    y: extractIntField(node, "y", path),
    width: extractIntField(node, "width", path),
    height: extractIntField(node, "height", path),
  )

proc extractTalkingHead(node: JsonNode): TalkingHeadMeta =
  ## Parse the optional `metadata.talking_head` block. Unknown scalar
  ## keys are captured under `result.extras` verbatim so future provider
  ## knobs do not require parser changes.
  result = TalkingHeadMeta(provider: "", avatarImage: "", device: "",
    extras: initTable[string, string]())
  if node.kind != JObject:
    raise newException(ScriptParseError,
      "metadata.talking_head must be an object, got " & $node.kind)
  for key, val in node.pairs:
    case key
    of "provider":
      if val.kind != JString:
        raise newException(ScriptParseError,
          "metadata.talking_head.provider must be a string")
      result.provider = val.getStr.strip()
    of "avatar_image":
      if val.kind != JString:
        raise newException(ScriptParseError,
          "metadata.talking_head.avatar_image must be a string")
      result.avatarImage = val.getStr
    of "device":
      if val.kind != JString:
        raise newException(ScriptParseError,
          "metadata.talking_head.device must be a string")
      result.device = val.getStr.strip()
    else:
      # Forward-compat: store any extra scalar verbatim.  Sub-objects
      # are rejected because we don't have a use for nested provider
      # parameters yet.
      case val.kind
      of JString: result.extras[key] = val.getStr
      of JInt:    result.extras[key] = $val.getInt
      of JFloat:  result.extras[key] = $val.getFloat
      of JBool:   result.extras[key] = $val.getBool
      of JNull:   result.extras[key] = ""
      else:
        raise newException(ScriptParseError,
          "metadata.talking_head." & key &
          " must be a scalar (string/number/bool/null), got " & $val.kind)

proc extractMetadata(node: JsonNode): ScriptMetadata =
  if node.isNil or node.kind == JNull:
    # Default values when metadata is omitted entirely.
    return ScriptMetadata(title: "", resolution: "", fps: 0,
      targets: @[], windowLayout: initTable[string, WindowLayout](),
      talkingHead: TalkingHeadMeta(extras: initTable[string, string]()),
      emotiveDefaults: initEmotive(),
      avatarPreferences: AvatarPreferences())
  if node.kind != JObject:
    raise newException(ScriptParseError,
      "expected `metadata` to be an object, got " & $node.kind)
  result = ScriptMetadata(title: "", resolution: "", fps: 0,
    targets: @[], windowLayout: initTable[string, WindowLayout](),
    talkingHead: TalkingHeadMeta(extras: initTable[string, string]()),
    emotiveDefaults: initEmotive(),
    avatarPreferences: AvatarPreferences())
  if node.hasKey("title"):
    let t = node["title"]
    if t.kind != JString:
      raise newException(ScriptParseError, "metadata.title must be a string")
    result.title = t.getStr
  if node.hasKey("resolution"):
    let r = node["resolution"]
    if r.kind != JString:
      raise newException(ScriptParseError, "metadata.resolution must be a string")
    result.resolution = r.getStr
  if node.hasKey("fps"):
    let f = node["fps"]
    case f.kind
    of JInt:    result.fps = int(f.getInt)
    of JFloat:  result.fps = int(f.getFloat)
    else:       raise newException(ScriptParseError, "metadata.fps must be numeric")
  if node.hasKey("targets"):
    let t = node["targets"]
    if t.kind != JArray:
      raise newException(ScriptParseError,
        "metadata.targets must be an array of strings")
    for i, el in t.elems:
      if el.kind != JString:
        raise newException(ScriptParseError,
          "metadata.targets[" & $i & "] must be a string")
      result.targets.add el.getStr
  if node.hasKey("window_layout"):
    let wl = node["window_layout"]
    if wl.kind != JObject:
      raise newException(ScriptParseError,
        "metadata.window_layout must be an object")
    for key, val in wl.pairs:
      result.windowLayout[key] = extractWindowLayout(val, key)
  if node.hasKey("talking_head"):
    result.talkingHead = extractTalkingHead(node["talking_head"])
  if node.hasKey("emotive_defaults"):
    let em = node["emotive_defaults"]
    if em.kind != JObject and em.kind != JNull:
      raise newException(ScriptParseError,
        "metadata.emotive_defaults must be an object, got " & $em.kind)
    result.emotiveDefaults = emotiveFromJson(em)
  if node.hasKey("avatar_preferences"):
    let av = node["avatar_preferences"]
    if av.kind notin {JObject, JArray, JNull}:
      raise newException(ScriptParseError,
        "metadata.avatar_preferences must be an object or array, got " &
        $av.kind)
    result.avatarPreferences = avatarPrefsFromJson(av)

proc keyframeFromJson(node: JsonNode, index: int): Keyframe =
  if node.kind != JObject:
    raise newException(ScriptParseError,
      "timeline[" & $index & "] must be an object")
  if not node.hasKey("time"):
    raise newException(ScriptParseError,
      "timeline[" & $index & "] is missing required `time` field")
  if not node.hasKey("action"):
    raise newException(ScriptParseError,
      "timeline[" & $index & "] is missing required `action` field")
  let timeNode = node["time"]
  result.time =
    case timeNode.kind
    of JInt:    float(timeNode.getInt)
    of JFloat:  timeNode.getFloat
    else:
      raise newException(ScriptParseError,
        "timeline[" & $index & "].time must be numeric")
  let actNode = node["action"]
  if actNode.kind != JString:
    raise newException(ScriptParseError,
      "timeline[" & $index & "].action must be a string")
  result.action = actNode.getStr
  result.params =
    if node.hasKey("params"): node["params"]
    else: newJObject()
  if node.hasKey("narration"):
    let nNode = node["narration"]
    if nNode.kind == JNull:
      result.narration = none(string)
    elif nNode.kind == JString:
      result.narration = some(nNode.getStr)
    else:
      raise newException(ScriptParseError,
        "timeline[" & $index & "].narration must be a string or null")
  else:
    result.narration = none(string)
  if node.hasKey("target_window"):
    let tw = node["target_window"]
    if tw.kind != JString:
      raise newException(ScriptParseError,
        "timeline[" & $index & "].target_window must be a string")
    result.targetWindow = tw.getStr
  else:
    result.targetWindow = ""
  result.emotive = initEmotive()
  if node.hasKey("emotive"):
    let em = node["emotive"]
    if em.kind != JObject and em.kind != JNull:
      raise newException(ScriptParseError,
        "timeline[" & $index & "].emotive must be an object")
    result.emotive = emotiveFromJson(em)

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

proc applyTargetWindowDefaults*(script: var Script) =
  ## Fill in default `targetWindow` values per the schema rules:
  ##
  ##   * When `metadata.targets` is empty the script is a legacy
  ##     single-window script — leave `targetWindow` as the empty
  ##     string so dispatchers can ignore it.
  ##   * Otherwise default to `"desktop"` when that's a member of
  ##     `targets`; otherwise default to the first listed target.
  if script.metadata.targets.len == 0:
    return
  var fallback = "desktop"
  if "desktop" notin script.metadata.targets:
    fallback = script.metadata.targets[0]
  for i in 0 ..< script.timeline.len:
    if script.timeline[i].targetWindow.len == 0:
      script.timeline[i].targetWindow = fallback

proc validateScript*(script: Script) =
  ## Run all post-parse validation rules. Raises `ScriptValidationError` on
  ## the first issue. Empty timelines are valid.
  # window_layout keys must be members of `targets`.
  for key in script.metadata.windowLayout.keys:
    if key notin script.metadata.targets:
      raise newException(ScriptValidationError,
        "metadata.window_layout key '" & key &
        "' is not listed in metadata.targets")
  # Per-keyframe target_window must be one of metadata.targets when
  # targets is non-empty.  Legacy scripts (no targets) accept any
  # target_window verbatim.
  if script.metadata.targets.len > 0:
    for i, kf in script.timeline:
      if kf.targetWindow.len > 0 and kf.targetWindow notin script.metadata.targets:
        raise newException(ScriptValidationError,
          "timeline[" & $i & "].target_window '" & kf.targetWindow &
          "' references an unlisted target (declared: " &
          script.metadata.targets.join(", ") & ")")
  for i in 1 ..< script.timeline.len:
    let prev = script.timeline[i - 1]
    let cur = script.timeline[i]
    if cur.time < prev.time:
      raise newException(ScriptValidationError,
        "keyframe " & $i & " (time=" & $cur.time &
        ") is earlier than predecessor " & $(i - 1) &
        " (time=" & $prev.time & ")")
    if prev.narration.isSome:
      let narrationEnd = prev.time + estimateNarrationSeconds(prev.narration.get)
      if narrationEnd > cur.time + 1e-9:
        raise newException(ScriptValidationError,
          "narration on keyframe " & $(i - 1) &
          " runs until t=" & formatFloat(narrationEnd, ffDecimal, 3) &
          " which overlaps keyframe " & $i &
          " starting at t=" & $cur.time)

# ---------------------------------------------------------------------------
# JSON parser
# ---------------------------------------------------------------------------

proc scriptFromJsonNode(root: JsonNode): Script =
  if root.kind != JObject:
    raise newException(ScriptParseError, "top-level JSON must be an object")
  if root.hasKey("metadata"):
    result.metadata = extractMetadata(root["metadata"])
  else:
    result.metadata = ScriptMetadata(title: "", resolution: "", fps: 0,
      targets: @[], windowLayout: initTable[string, WindowLayout](),
      talkingHead: TalkingHeadMeta(extras: initTable[string, string]()),
      emotiveDefaults: initEmotive(),
      avatarPreferences: AvatarPreferences())
  result.timeline = @[]
  if root.hasKey("timeline"):
    let tl = root["timeline"]
    if tl.kind == JNull:
      discard
    elif tl.kind != JArray:
      raise newException(ScriptParseError, "`timeline` must be an array")
    else:
      for i, item in tl.elems:
        result.timeline.add keyframeFromJson(item, i)
  if root.hasKey("avatar") and root["avatar"].kind == JObject:
    try:
      result.avatar = avatarTrackFromJson(root["avatar"], "avatar")
      validate(result.avatar)
    except ValueError as e:
      raise newException(ScriptParseError, e.msg)

proc parseScriptJson*(input: string): Script =
  ## Parse a JSON-encoded script and validate it.
  var root: JsonNode
  try:
    root = parseJson(input)
  except JsonParsingError as e:
    raise newException(ScriptParseError, "JSON parse error: " & e.msg)
  result = scriptFromJsonNode(root)
  applyTargetWindowDefaults(result)
  validateScript(result)

# ---------------------------------------------------------------------------
# Minimal YAML subset parser
# ---------------------------------------------------------------------------
#
# Supported grammar (tailored to the driving script schema):
#
#   document   := block-mapping
#   block-mapping := (mapping-entry)+
#   mapping-entry := KEY ":" (inline-value | NEWLINE indented-block)
#   inline-value := scalar | flow-sequence
#   indented-block := block-mapping | block-sequence
#   block-sequence := ("- " (inline-value | mapping-entry-rest) NEWLINE)+
#   flow-sequence := "[" scalar ("," scalar)* "]"
#   scalar := double-quoted-string | plain-scalar | integer | float
#
# Indentation is significant. Tab characters are rejected.
# Comments start with `#` outside of double-quoted strings and run to end of
# line.

type
  YamlValue = JsonNode

  YamlLine = object
    raw: string       # original line text (without trailing newline)
    indent: int       # number of leading spaces
    content: string   # text after stripping indent + trailing whitespace
    lineNo: int

proc tokenizeLines(input: string): seq[YamlLine] =
  ## Split into significant lines, stripping comments and blank lines.
  var rawLines = input.splitLines()
  for idx, raw in rawLines:
    if raw.contains('\t'):
      raise newException(ScriptParseError,
        "tab characters are not allowed in YAML script (line " & $(idx + 1) & ")")
    # Strip comments outside strings.
    var stripped = newStringOfCap(raw.len)
    var inStr = false
    var escape = false
    for ch in raw:
      if escape:
        stripped.add ch
        escape = false
        continue
      if inStr:
        if ch == '\\':
          stripped.add ch
          escape = true
        elif ch == '"':
          stripped.add ch
          inStr = false
        else:
          stripped.add ch
      else:
        if ch == '#':
          break
        if ch == '"':
          stripped.add ch
          inStr = true
        else:
          stripped.add ch
    # Compute indent + content from `stripped`.
    var indent = 0
    while indent < stripped.len and stripped[indent] == ' ':
      inc indent
    let trimmed = stripped[indent .. ^1].strip(leading = false, trailing = true)
    if trimmed.len == 0:
      continue
    result.add YamlLine(
      raw: raw,
      indent: indent,
      content: trimmed,
      lineNo: idx + 1,
    )

proc parseScalar(text: string, lineNo: int): YamlValue =
  let s = text.strip()
  if s.len == 0:
    return newJNull()
  if s[0] == '"':
    if s.len < 2 or s[^1] != '"':
      raise newException(ScriptParseError,
        "unterminated double-quoted string on line " & $lineNo)
    var buf = newStringOfCap(s.len - 2)
    var i = 1
    while i < s.len - 1:
      if s[i] == '\\' and i + 1 < s.len - 1:
        case s[i + 1]
        of 'n': buf.add '\n'
        of 't': buf.add '\t'
        of 'r': buf.add '\r'
        of '"': buf.add '"'
        of '\\': buf.add '\\'
        of '/': buf.add '/'
        else:
          buf.add s[i + 1]
        i += 2
      else:
        buf.add s[i]
        inc i
    return newJString(buf)
  if s[0] == '[':
    if s[^1] != ']':
      raise newException(ScriptParseError,
        "unterminated flow sequence on line " & $lineNo)
    let inner = s[1 .. ^2].strip()
    let arr = newJArray()
    if inner.len == 0:
      return arr
    # Split on commas at depth 0 (we do not nest flow sequences in this schema
    # but be tolerant of quoted strings containing commas).
    var parts: seq[string] = @[]
    var depth = 0
    var inStr = false
    var cur = ""
    for ch in inner:
      if inStr:
        cur.add ch
        if ch == '"':
          inStr = false
        continue
      case ch
      of '"':
        cur.add ch
        inStr = true
      of '[':
        inc depth
        cur.add ch
      of ']':
        dec depth
        cur.add ch
      of ',':
        if depth == 0:
          parts.add cur
          cur = ""
        else:
          cur.add ch
      else:
        cur.add ch
    parts.add cur
    for p in parts:
      arr.add parseScalar(p.strip(), lineNo)
    return arr
  # Boolean / null literals.
  case s.toLowerAscii
  of "true": return newJBool(true)
  of "false": return newJBool(false)
  of "null", "~": return newJNull()
  else: discard
  # Numeric scalar?
  try:
    if '.' in s or 'e' in s or 'E' in s:
      let f = parseFloat(s)
      return newJFloat(f)
    else:
      let i = parseInt(s)
      return newJInt(i)
  except ValueError:
    discard
  return newJString(s)

proc parseBlock(lines: seq[YamlLine], start: var int, indent: int): YamlValue

proc parseSequenceBlock(lines: seq[YamlLine], start: var int, indent: int): YamlValue =
  result = newJArray()
  while start < lines.len and lines[start].indent == indent and
        lines[start].content.startsWith("- "):
    let line = lines[start]
    let afterDash = line.content[2 .. ^1].strip()
    inc start
    if afterDash.len == 0:
      # Block-style child: next lines must be indented further.
      var childIndent = -1
      if start < lines.len and lines[start].indent > indent:
        childIndent = lines[start].indent
      if childIndent == -1:
        result.add newJNull()
      else:
        result.add parseBlock(lines, start, childIndent)
    elif ':' in afterDash and not afterDash.startsWith('"'):
      # Inline first key of a mapping: "- key: value" then more keys indented
      # at indent + 2.
      let colonIdx = afterDash.find(':')
      let firstKey = afterDash[0 ..< colonIdx].strip()
      let firstValRaw = afterDash[colonIdx + 1 .. ^1].strip()
      let obj = newJObject()
      if firstValRaw.len == 0:
        # Value continues as nested block at `indent + 2` (typical 2-space).
        if start < lines.len and lines[start].indent > indent + 1:
          let nested = parseBlock(lines, start, lines[start].indent)
          obj[firstKey] = nested
        else:
          obj[firstKey] = newJNull()
      else:
        obj[firstKey] = parseScalar(firstValRaw, line.lineNo)
      # Remaining sibling keys at indent + 2.
      while start < lines.len and lines[start].indent > indent and
            not lines[start].content.startsWith("- "):
        let sub = lines[start]
        if sub.indent < indent + 2:
          break
        if sub.indent > indent + 2:
          # Unexpected — should have been consumed by nested block.
          raise newException(ScriptParseError,
            "unexpected indentation on line " & $sub.lineNo)
        if ':' notin sub.content:
          raise newException(ScriptParseError,
            "expected mapping entry on line " & $sub.lineNo)
        let cIdx = sub.content.find(':')
        let k = sub.content[0 ..< cIdx].strip()
        let v = sub.content[cIdx + 1 .. ^1].strip()
        inc start
        if v.len == 0:
          if start < lines.len and lines[start].indent > sub.indent:
            obj[k] = parseBlock(lines, start, lines[start].indent)
          else:
            obj[k] = newJNull()
        else:
          obj[k] = parseScalar(v, sub.lineNo)
      result.add obj
    else:
      # Inline scalar sequence element.
      result.add parseScalar(afterDash, line.lineNo)

proc parseMappingBlock(lines: seq[YamlLine], start: var int, indent: int): YamlValue =
  result = newJObject()
  while start < lines.len and lines[start].indent == indent and
        not lines[start].content.startsWith("- "):
    let line = lines[start]
    if ':' notin line.content:
      raise newException(ScriptParseError,
        "expected mapping entry with ':' on line " & $line.lineNo)
    let colonIdx = line.content.find(':')
    let k = line.content[0 ..< colonIdx].strip()
    let v = line.content[colonIdx + 1 .. ^1].strip()
    inc start
    if v.len == 0:
      # Nested block — either mapping or sequence — at deeper indent.
      if start < lines.len and lines[start].indent > indent:
        let childIndent = lines[start].indent
        result[k] = parseBlock(lines, start, childIndent)
      else:
        result[k] = newJNull()
    else:
      result[k] = parseScalar(v, line.lineNo)

proc parseBlock(lines: seq[YamlLine], start: var int, indent: int): YamlValue =
  if start >= lines.len:
    return newJNull()
  if lines[start].content.startsWith("- "):
    return parseSequenceBlock(lines, start, indent)
  return parseMappingBlock(lines, start, indent)

proc parseScriptYaml*(input: string): Script =
  ## Parse a YAML-subset-encoded script (see module docs) and validate it.
  let lines = tokenizeLines(input)
  if lines.len == 0:
    # Treat empty input as an empty script.
    result = Script(
      metadata: ScriptMetadata(title: "", resolution: "", fps: 0,
        targets: @[], windowLayout: initTable[string, WindowLayout](),
        talkingHead: TalkingHeadMeta(extras: initTable[string, string]()),
        emotiveDefaults: initEmotive(),
        avatarPreferences: AvatarPreferences()),
      timeline: @[],
    )
    return
  if lines[0].indent != 0:
    raise newException(ScriptParseError,
      "document must start at column 0 (line " & $lines[0].lineNo & ")")
  var idx = 0
  let root = parseBlock(lines, idx, 0)
  if idx != lines.len:
    raise newException(ScriptParseError,
      "stray content after document at line " & $lines[idx].lineNo)
  result = scriptFromJsonNode(root)
  applyTargetWindowDefaults(result)
  validateScript(result)

proc effectiveEmotive*(meta: ScriptMetadata, kf: Keyframe):
    CommonEmotiveConfig =
  ## Project the script-level emotive defaults onto the keyframe and
  ## layer its own overrides on top.  Plugins call this when building
  ## the per-keyframe render request.
  result = overlay(meta.emotiveDefaults, kf.emotive)

# Avoid an unused-symbol warning when callers only import the type aliases.
when defined(guiAssertParserSelfTest):
  echo estimateNarrationSeconds("hello world this is a test")
