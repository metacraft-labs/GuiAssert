## The contract as written versus the contract as built (spec §7.5, §7.7).
##
## Both tests read Planned-Work/Desktop-Substrate.md itself, so neither can
## drift from the specification:
##
## * `test_every_documented_verb_is_implemented` parses every verb table of
##   spec §7.5 and requires the CLI registry to list exactly those verbs, the
##   built binary to resolve each of them (and to refuse a verb that is not
##   documented), and the every-verb scenario the other tests use to cover
##   them all.
## * `test_fixture_emits_every_documented_data_key` parses the `data` schema
##   of every verb (and the common objects they refer to) from the same
##   tables, runs every verb once against the fixture backend through the
##   real binary, and checks each `data` object key by key and type by type:
##   every documented key present with its documented JSON type, and no
##   undocumented key (`lossy` excepted, spec §7.4).
##
## Stand-ins: the fixture backend only (spec §9.2), selected below the real
## binary.

import std/[json, os, sequtils, sets, strutils, tables, unittest]

import ./harness
import ../../src/gui_assert/cli/registry

# ---------------------------------------------------------------------------
# A parser for the specification's schema notation
# ---------------------------------------------------------------------------

type
  TKind = enum tStr, tInt, tFloat, tBool, tNull, tTrue, tLit, tIntLit, tArray,
               tTuple, tObject, tMap, tRef, tUnion
  T = ref object
    case kind: TKind
    of tLit: lit: string
    of tIntLit: n: int
    of tArray: elem: T
    of tTuple: items: seq[T]
    of tObject: fields: seq[(string, T)]
    of tMap: value: T
    of tRef: name: string
    of tUnion: alts: seq[T]
    else: discard

  Parser = object
    toks: seq[string]
    pos: int

proc stripComments(s: string): string =
  var i = 0
  while i < s.len:
    if s[i] == '/' and i + 1 < s.len and s[i + 1] == '/':
      while i < s.len and s[i] != '\n': inc i
    elif s[i] == '/' and i + 1 < s.len and s[i + 1] == '*':
      let e = s.find("*/", i + 2)
      i = (if e < 0: s.len else: e + 2)
    else:
      result.add s[i]
      inc i

proc tokenize(s: string): seq[string] =
  var i = 0
  while i < s.len:
    let c = s[i]
    if c in Whitespace: inc i
    elif c in {'{', '}', '[', ']', ':', ',', '|', '='}:
      result.add $c
      inc i
    elif c == '"':
      let e = s.find('"', i + 1)
      doAssert e > i, "unterminated string in: " & s
      result.add s[i .. e]
      i = e + 1
    elif c in IdentChars or c in {'.', '-'}:
      var j = i
      while j < s.len and (s[j] in IdentChars or s[j] in {'.', '-'}): inc j
      result.add s[i ..< j]
      i = j
    else:
      raise newException(ValueError, "unexpected character '" & c & "' in: " & s)

proc peek(p: Parser): string = (if p.pos < p.toks.len: p.toks[p.pos] else: "")
proc take(p: var Parser): string =
  result = p.peek
  inc p.pos
proc expect(p: var Parser, t: string) =
  let got = p.take
  doAssert got == t, "expected '" & t & "', got '" & got & "' at token " & $p.pos &
    " of " & p.toks.join(" ")

proc parseType(p: var Parser): T

proc parseAtom(p: var Parser): T =
  let t = p.take
  case t
  of "str": T(kind: tStr)
  of "int": T(kind: tInt)
  of "float": T(kind: tFloat)
  of "bool": T(kind: tBool)
  of "null": T(kind: tNull)
  of "true": T(kind: tTrue)
  of "[":
    var items = @[p.parseType]
    while p.peek == ",":
      discard p.take
      items.add p.parseType
    p.expect "]"
    if items.len == 1: T(kind: tArray, elem: items[0]) else: T(kind: tTuple, items: items)
  of "{":
    if p.peek.startsWith("\""):
      var fields: seq[(string, T)]
      while true:
        let k = p.take
        doAssert k.startsWith("\""), "expected a key, got " & k
        if p.peek == ":":
          discard p.take
          fields.add (k[1 .. ^2], p.parseType)
        else:
          fields.add (k[1 .. ^2], T(kind: tStr))   # a key-only listing
        if p.peek == ",":
          discard p.take
          continue
        break
      p.expect "}"
      T(kind: tObject, fields: fields)
    else:
      discard p.take        # the key's type or name (`str`, `module`)
      p.expect ":"
      let v = p.parseType
      p.expect "}"
      T(kind: tMap, value: v)
  else:
    if t.startsWith("\""): T(kind: tLit, lit: t[1 .. ^2])
    elif t.allCharsInSet(Digits): T(kind: tIntLit, n: parseInt(t))
    else: T(kind: tRef, name: t)

proc parseType(p: var Parser): T =
  let first = p.parseAtom
  if p.peek != "|": return first
  result = T(kind: tUnion, alts: @[first])
  while p.peek == "|":
    discard p.take
    result.alts.add p.parseAtom

proc parseTypeText(s: string): T =
  var p = Parser(toks: tokenize(stripComments(s)))
  result = p.parseType
  doAssert p.pos == p.toks.len, "trailing tokens in: " & s

proc backtickSegments(cell: string): seq[string] =
  var i = 0
  while true:
    let a = cell.find('`', i)
    if a < 0: break
    let b = cell.find('`', a + 1)
    if b < 0: break
    result.add cell[a + 1 ..< b]
    i = b + 1

proc commonObjects(): Table[string, T] =
  ## `Name = type` definitions of the spec's common-objects block. The two
  ## coordinate types are `[x, y, w, h]` / `[x, y]` "ints" (their comment),
  ## and `Element` is a `Node` whose children are empty.
  let objBlock = specCommonObjects()
  doAssert "Rect      = [x, y, w, h]                        // ints" in objBlock,
    "the spec's Rect definition changed; update this parser"
  var p = Parser(toks: tokenize(stripComments(objBlock)))
  while p.pos < p.toks.len:
    let name = p.take
    p.expect "="
    result[name] = p.parseType
  for name in ["Rect", "Point"]:
    let t = result[name]
    doAssert t.kind == tTuple
    for i in 0 ..< t.items.len: t.items[i] = T(kind: tInt)
  result["Element"] = result["Node"]

proc dataSchemas(objects: var Table[string, T]): OrderedTable[string, T] =
  ## The `data` schema of every documented verb.
  for verb, cell in specVerbRows():
    var schema = ""
    for seg in backtickSegments(cell):
      if seg.startsWith("{"):
        schema = seg
        break
    doAssert schema.len > 0, "no data schema for " & verb & ": " & cell
    result[verb] = parseTypeText(schema)
    if verb == "permissions":
      # The spec defines Permissions in prose in this row: its keys, the
      # state union "each" of them takes, and the `identity` key.
      let segs = backtickSegments(cell)
      var keysSeg, statesSeg, identitySeg = ""
      for s in segs:
        if s.startsWith("Permissions = {"): keysSeg = s
        elif s.startsWith("\"granted\""): statesSeg = s
        elif s.startsWith("\"identity\""): identitySeg = s
      doAssert keysSeg.len > 0 and statesSeg.len > 0 and identitySeg.len > 0,
        "the spec's Permissions prose changed; update this parser: " & cell
      let keys = parseTypeText(keysSeg["Permissions = ".len .. ^1])
      let state = parseTypeText(statesSeg)
      var fields: seq[(string, T)]
      for (k, _) in keys.fields: fields.add (k, state)
      fields.add ("identity", parseTypeText(identitySeg.split(":", 1)[1]))
      objects["Permissions"] = T(kind: tObject, fields: fields)

proc resolve(objects: Table[string, T], name: string): T =
  if name in objects: return objects[name]
  let dot = name.find('.')
  if dot > 0 and name[0 ..< dot] in objects:
    let o = objects[name[0 ..< dot]]
    for (k, v) in o.fields:
      if k == name[dot + 1 .. ^1]: return v
  raise newException(KeyError, "the spec refers to an undefined type " & name)

proc check(objects: Table[string, T], v: JsonNode, t: T, path: string,
           errs: var seq[string]) =
  case t.kind
  of tStr:
    if v.kind != JString: errs.add path & ": expected a string, got " & $v.kind
  of tInt:
    if v.kind != JInt: errs.add path & ": expected an integer, got " & $v.kind
  of tFloat:
    if v.kind != JFloat: errs.add path & ": expected a float, got " & $v.kind
  of tBool:
    if v.kind != JBool: errs.add path & ": expected a boolean, got " & $v.kind
  of tNull:
    if v.kind != JNull: errs.add path & ": expected null, got " & $v.kind
  of tTrue:
    if v.kind != JBool or not v.getBool: errs.add path & ": expected true"
  of tLit:
    if v.kind != JString or v.getStr != t.lit:
      errs.add path & ": expected \"" & t.lit & "\", got " & $v
  of tIntLit:
    if v.kind != JInt or v.getInt != t.n:
      errs.add path & ": expected " & $t.n & ", got " & $v
  of tArray:
    if v.kind != JArray: errs.add path & ": expected an array, got " & $v.kind
    else:
      for i, e in v.elems: check(objects, e, t.elem, path & "[" & $i & "]", errs)
  of tTuple:
    if v.kind != JArray or v.len != t.items.len:
      errs.add path & ": expected an array of " & $t.items.len
    else:
      for i, e in v.elems: check(objects, e, t.items[i], path & "[" & $i & "]", errs)
  of tObject:
    if v.kind != JObject:
      errs.add path & ": expected an object, got " & $v.kind
      return
    var documented = initHashSet[string]()
    for (k, ft) in t.fields:
      documented.incl k
      if not v.hasKey(k): errs.add path & ": missing documented key \"" & k & "\""
      else: check(objects, v[k], ft, path & "." & k, errs)
    for k in v.keys:
      if k notin documented and k != "lossy":
        errs.add path & ": undocumented key \"" & k & "\""
  of tMap:
    if v.kind != JObject: errs.add path & ": expected an object, got " & $v.kind
    else:
      for k, e in v.pairs: check(objects, e, t.value, path & "." & k, errs)
  of tRef: check(objects, v, resolve(objects, t.name), path, errs)
  of tUnion:
    for a in t.alts:
      var sub: seq[string]
      check(objects, v, a, path, sub)
      if sub.len == 0: return
    errs.add path & ": " & $v & " matches none of the documented alternatives"

# ---------------------------------------------------------------------------

suite "contract schema":
  test "test_every_documented_verb_is_implemented":
    let documented = toSeq(specVerbRows().keys)
    check documented.len >= 30         # the parser really read the tables
    check toHashSet(documented).len == documented.len
    let registered = verbNames()
    check toHashSet(registered) == toHashSet(documented)
    for v in documented:
      if v notin registered: checkpoint "documented but not in the registry: " & v
    for v in registered:
      if v notin documented: checkpoint "in the registry but not documented: " & v
    # The binary resolves every documented verb (no `unknown-verb`), and
    # refuses one that is not documented (the control).
    let st = freshDir("verbs")
    let env = fixtureEnv(st)
    for v in documented:
      let (exit, e, _) = cli(@[v], env)
      check e["verb"].getStr == v
      if exit == 2: check e.errorReason != "unknown-verb"
    let (cexit, ce, _) = cli(@["frobnicate-window"], env)
    check cexit == 2
    check ce.errorReason == "unknown-verb"
    check ce["verb"].getStr == "frobnicate-window"
    # The contract version the binary reports is the one the spec names.
    let (_, ve, _) = cli(@["version"], baseEnv())
    check "## 7. The CLI contract (contract `" & ve.data["contract"]["name"].getStr &
          "/" & $ve.data["contract"]["major"].getInt & "`)" in specText()
    # The scenario the other tests use covers every verb.
    var covered = initHashSet[string]()
    for argv in everyVerbScenario("/w"): covered.incl argv[0]
    check covered == toHashSet(documented)

  test "test_fixture_emits_every_documented_data_key":
    var objects = commonObjects()
    let schemas = dataSchemas(objects)
    check schemas.len == specVerbRows().len
    let st = freshDir("schema")
    let work = freshDir("schema-work")
    prepareWork(work)
    let env = fixtureEnv(st)
    var seen = initHashSet[string]()
    for argv in everyVerbScenario(work):
      let (exit, e, line) = cli(argv, env)
      if exit != 0:
        checkpoint argv.join(" ") & " failed: " & line
      check exit == 0
      if exit != 0: continue
      var errs: seq[string]
      check(objects, e.data, schemas[argv[0]], argv[0], errs)
      for x in errs: checkpoint x
      check errs.len == 0
      seen.incl argv[0]
    check seen == toHashSet(toSeq(schemas.keys))

  test "schema checker control: a missing, a mistyped and an extra key are reported":
    # Negative control for the checker itself, on the spec's real Display.
    var objects = commonObjects()
    let display = objects["Display"]
    var errs: seq[string]
    let good = %*{"id": "d", "name": nil, "bounds": [0, 0, 1, 1], "scale": 1.0,
                  "primary": true, "virtual": false}
    check(objects, good, display, "d", errs)
    check errs.len == 0
    var missing = good.copy
    missing.delete("primary")
    check(objects, missing, display, "d", errs)
    check errs.len == 1
    errs.setLen(0)
    var mistyped = good.copy
    mistyped["scale"] = %1
    check(objects, mistyped, display, "d", errs)
    check errs.len == 1
    errs.setLen(0)
    var extra = good.copy
    extra["colour"] = %"blue"
    check(objects, extra, display, "d", errs)
    check errs.len == 1

cleanupFreshDirs()
