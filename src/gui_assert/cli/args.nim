## The `guiassert` argument parser (spec §7.1).
##
## `guiassert [global flags] <verb> [verb positionals] [verb flags] [-- <argv>]`.
## Global flags may come before or after the verb. Every flag takes its value
## as the next argument (`--out /tmp/a.png`); there is no `--flag=value`
## form. A token that starts with `--` is a flag; any other token (including
## `-5`) is a positional. `--` ends flag parsing and is accepted only by verbs
## that take a pass-through argv (`app-launch`).
##
## Reject, don't drop (spec §2, §7.4): an unknown flag, a missing value, a
## repeated flag that is not repeatable, an unexpected positional, a
## pass-through argv where none is accepted: all `bad-args`, each with its
## reason. The value parsers below turn a flag's text into a typed value the
## same way for every verb.

import std/[options, strutils, tables, math]

import ../core/[contract, geometry]
import ./registry

type
  Invocation* = object
    ## A parsed invocation.
    verb*: string                         ## the canonical verb name
    globals*: Table[string, string]       ## global flags given explicitly
    positionals*: seq[string]
    flags*: Table[string, seq[string]]    ## verb flags; a switch maps to @[""]
    passthrough*: seq[string]             ## the argv after `--`
    hasPassthrough*: bool

proc isFlag(tok: string): bool = tok.len > 2 and tok.startsWith("--")

proc findVerbToken*(argv: seq[string]): string =
  ## The verb token as given (for the envelope of an invocation that fails to
  ## parse): the first argument that is not a global flag or its value, or
  ## "" when there is none.
  var i = 0
  while i < argv.len:
    let tok = argv[i]
    if tok == "--": return ""
    if tok.isFlag:
      if tok[2 .. ^1] in globalFlags: i += 2
      else: return ""
    else:
      return tok
  ""

proc parseInvocation*(argv: seq[string]): Invocation =
  ## Parse `argv` (without the program name). Raises `ContractError`
  ## (`bad-args`) for any malformed invocation.
  var i = 0
  var spec: VerbSpec
  var haveVerb = false
  while i < argv.len:
    let tok = argv[i]
    if tok == "--":
      if not haveVerb:
        raise badArgs("missing-argument", "no verb before '--'")
      if not spec.passthrough:
        raise badArgs("invalid-value", "'" & spec.name & "' takes no '-- <argv>'")
      result.hasPassthrough = true
      result.passthrough = argv[i + 1 .. ^1]
      break
    if tok.isFlag:
      let name = tok[2 .. ^1]
      if name in globalFlags:
        if i + 1 >= argv.len:
          raise badArgs("missing-argument", tok & " needs a value")
        if name in result.globals:
          raise badArgs("conflicting-arguments", tok & " is given more than once")
        result.globals[name] = argv[i + 1]
        i += 2
        continue
      if not haveVerb:
        raise badArgs("unknown-flag", "unknown flag " & tok)
      var kind = fkSwitch
      var found = false
      for f in spec.flags:
        if f.name == name:
          kind = f.kind
          found = true
      if not found:
        raise badArgs("unknown-flag", "'" & spec.name & "' has no flag " & tok)
      if name in result.flags and kind != fkRepeated:
        raise badArgs("conflicting-arguments", tok & " is given more than once")
      if kind == fkSwitch:
        result.flags[name] = @[""]
        inc i
      else:
        if i + 1 >= argv.len:
          raise badArgs("missing-argument", tok & " needs a value")
        result.flags.mgetOrPut(name, @[]).add argv[i + 1]
        i += 2
      continue
    if not haveVerb:
      let vi = findVerb(tok)
      if vi < 0:
        raise badArgs("unknown-verb", "unknown verb '" & tok & "'")
      spec = verbSpecs[vi]
      result.verb = tok
      haveVerb = true
    else:
      if result.positionals.len >= spec.positionals.len:
        # The token is not echoed: it may be text to type (spec §7.5,
        # "Captured content").
        raise badArgs("invalid-value", "unexpected argument #" &
          $(result.positionals.len + 1) & " for '" & spec.name & "'")
      result.positionals.add tok
    inc i
  if not haveVerb:
    raise badArgs("missing-argument", "no verb given (see `guiassert --help`)")
  for pi, p in spec.positionals:
    if not p.endsWith("?") and pi >= result.positionals.len:
      raise badArgs("missing-argument", "'" & spec.name & "' needs <" & p & ">")

# ---------------------------------------------------------------------------
# Flag access and typed values
# ---------------------------------------------------------------------------

proc has*(inv: Invocation, flag: string): bool =
  ## True when the verb flag was given.
  flag in inv.flags

proc value*(inv: Invocation, flag: string): Option[string] =
  ## The value of a single-valued verb flag, if given.
  if flag in inv.flags: some(inv.flags[flag][^1]) else: none(string)

proc values*(inv: Invocation, flag: string): seq[string] =
  ## Every value of a repeatable verb flag.
  inv.flags.getOrDefault(flag, @[])

proc require*(inv: Invocation, flag: string): string =
  ## The value of a required verb flag; `missing-argument` when absent.
  let v = inv.value(flag)
  if v.isNone:
    raise badArgs("missing-argument", "'" & inv.verb & "' needs --" & flag)
  v.get

proc parseIntValue*(what, s: string, lo = low(int), hi = high(int)): int =
  ## A decimal integer in `lo..hi`; `invalid-value` otherwise.
  try:
    result = parseInt(s)
  except ValueError:
    raise badArgs("invalid-value", what & ": '" & s & "' is not an integer")
  if result < lo or result > hi:
    raise badArgs("invalid-value", what & ": " & $result & " is outside " &
      $lo & ".." & $hi)

proc parseFloatValue*(what, s: string, lo = -Inf, hi = Inf,
                      loInclusive = true): float =
  ## A finite decimal number in the range; `invalid-value` otherwise.
  try:
    result = parseFloat(s)
  except ValueError:
    raise badArgs("invalid-value", what & ": '" & s & "' is not a number")
  if classify(result) in {fcNan, fcInf, fcNegInf} or result > hi or
     (if loInclusive: result < lo else: result <= lo):
    raise badArgs("invalid-value", what & ": " & s & " is out of range")

proc parseInts(what, s: string, n: int): seq[int] =
  let parts = s.split(',')
  if parts.len != n:
    raise badArgs("invalid-value", what & ": '" & s & "' is not " & $n &
      " comma-separated integers")
  for p in parts: result.add parseIntValue(what, p.strip)

proc parsePointValue*(what, s: string): Point =
  ## `x,y` in desktop coordinates.
  let v = parseInts(what, s, 2)
  point(v[0], v[1])

proc parseRectValue*(what, s: string): Rect =
  ## `x,y,w,h` with a positive extent.
  let v = parseInts(what, s, 4)
  if v[2] <= 0 or v[3] <= 0:
    raise badArgs("invalid-value", what & ": a rectangle needs a positive width and height")
  rect(v[0], v[1], v[2], v[3])

proc parseChoice*(what, s: string, choices: openArray[string]): string =
  ## `s` when it is one of `choices`; `invalid-value` otherwise.
  if s notin choices:
    raise badArgs("invalid-value", what & ": '" & s & "' is not one of " &
      choices.join(", "))
  s

proc intFlag*(inv: Invocation, flag: string, lo = low(int), hi = high(int)): Option[int] =
  ## An optional integer verb flag.
  let v = inv.value(flag)
  if v.isSome: some(parseIntValue("--" & flag, v.get, lo, hi)) else: none(int)

proc floatFlag*(inv: Invocation, flag: string, lo = -Inf, hi = Inf,
                loInclusive = true): Option[float] =
  ## An optional number verb flag.
  let v = inv.value(flag)
  if v.isSome: some(parseFloatValue("--" & flag, v.get, lo, hi, loInclusive))
  else: none(float)

proc pointFlag*(inv: Invocation, flag: string): Option[Point] =
  ## An optional `x,y` verb flag.
  let v = inv.value(flag)
  if v.isSome: some(parsePointValue("--" & flag, v.get)) else: none(Point)

proc rectFlag*(inv: Invocation, flag: string): Option[Rect] =
  ## An optional `x,y,w,h` verb flag.
  let v = inv.value(flag)
  if v.isSome: some(parseRectValue("--" & flag, v.get)) else: none(Rect)

proc exclusive*(inv: Invocation, flags: openArray[string], required: bool): string =
  ## Which one of the mutually exclusive verb `flags` was given ("" for
  ## none). Two or more is `conflicting-arguments`; none, when `required`, is
  ## `missing-argument`.
  var given: seq[string]
  for f in flags:
    if inv.has(f): given.add f
  if given.len > 1:
    raise badArgs("conflicting-arguments", "--" & given.join(" and --") &
      " exclude each other")
  if given.len == 0:
    if required:
      raise badArgs("missing-argument", "'" & inv.verb & "' needs one of --" &
        flags.join(", --"))
    return ""
  given[0]

proc refuse*(inv: Invocation, flags: openArray[string], because: string) =
  ## `conflicting-arguments` when any of `flags` was given: they do not apply
  ## (`because` says why). Used so an inapplicable flag is never ignored.
  for f in flags:
    if inv.has(f):
      raise badArgs("conflicting-arguments", "--" & f & " does not apply " & because)
