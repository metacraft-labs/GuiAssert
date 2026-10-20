## GuiAssert core: the key table and key-combination syntax of the contract.
##
## The `key` verb takes a combination such as `cmd+s`, `ctrl+shift+Tab` or
## `Return`, and `click --modifiers` a list of modifiers (spec §7.5, "The key
## table"). Both are checked against the fixed table below; an unknown name is
## refused, never guessed, so a typo cannot turn into a different key. The
## table is part of the frozen contract: the specification publishes the same
## rows, and `tests/contract/tcontract_schema.nim` checks the two agree.
##
## The syntax is `[<modifier>+]...<key>`, matched **case-insensitively**:
##
## * modifiers (each at most once, under any of its spellings): `ctrl`
##   (`control`), `alt` (`option`), `shift`, `cmd` (`command`, `meta`,
##   `super`, `win`);
## * the key, exactly one of:
##   - a named key of `namedKeyTable` (`Return` / `Enter`, `Escape` / `Esc`,
##     `PageUp`, `Pause`, the arrows, …) or a function key `F1`..`F24`;
##   - any single printable character (one Unicode code point that is not a
##     control character and not white space; the space bar is `Space`).
##     The letters `A`..`Z` name the same key as `a`..`z`: a key names a
##     physical key, and an upper-case letter is `shift+a` (or `type A`).
##     `+` itself is written as the last character (`ctrl++`, or `+`).
##
## The normalized spelling (`normalizeCombo`) lists the modifiers in the
## table's order (`ctrl`, `alt`, `shift`, `cmd`) under their canonical
## spelling, followed by the key's canonical spelling, so every spelling of
## one combination normalizes to one string. `cmd` is the Command key on
## macOS and the Windows / Super key elsewhere.

import std/[strutils, unicode]

type
  KeyComboError* = object of CatchableError
    ## Raised for an unknown key or modifier name, or a malformed combination.

  Modifier* = enum
    ## The modifier keys, in their normalized order; the string is the
    ## canonical spelling.
    modCtrl = "ctrl"
    modAlt = "alt"
    modShift = "shift"
    modCmd = "cmd"

  KeyCombo* = object
    ## A parsed combination: its modifiers and its key's canonical spelling.
    modifiers*: set[Modifier]
    key*: string

const
  modifierSpellings*: array[Modifier, seq[string]] = [
    @["ctrl", "control"],
    @["alt", "option"],
    @["shift"],
    @["cmd", "command", "meta", "super", "win"]]
    ## Every accepted spelling of each modifier, the canonical one first.

  namedKeyTable*: seq[tuple[canonical: string, aliases: seq[string]]] = @[
    ("Return", @["Enter"]), ("Tab", @[]), ("Escape", @["Esc"]),
    ("BackSpace", @[]), ("Delete", @[]), ("Insert", @[]), ("Space", @[]),
    ("Home", @[]), ("End", @[]), ("PageUp", @[]), ("PageDown", @[]),
    ("Pause", @[]), ("Up", @[]), ("Down", @[]), ("Left", @[]), ("Right", @[])]
    ## The named keys other than the function keys: canonical spelling and
    ## the other accepted spellings.

  maxFunctionKey* = 24
    ## Function keys run `F1` .. `F24`.

proc parseModifier*(s: string): Modifier =
  ## The modifier spelled `s` (any accepted spelling, any case). Raises
  ## `KeyComboError` for anything else.
  let l = s.toLowerAscii
  for m in Modifier:
    if l in modifierSpellings[m]: return m
  raise newException(KeyComboError, "unknown modifier '" & s &
    "' (expected ctrl/control, alt/option, shift, cmd/command/meta/super/win)")

proc isPrintableChar(s: string): bool =
  ## True when `s` is exactly one Unicode code point that is printable: not a
  ## C0/C1 control character, not DEL and not white space.
  if s.len == 0 or validateUtf8(s) >= 0 or s.runeLen != 1: return false
  let r = s.runeAt(0)
  let c = int(r)
  if c < 0x20 or c == 0x7F or (c >= 0x80 and c <= 0x9F): return false
  not r.isWhiteSpace

proc canonicalKey*(s: string): string =
  ## The canonical spelling of the key named `s`, or "" when `s` names no
  ## key of the table. Names and aliases match case-insensitively; a single
  ## ASCII letter normalizes to lower case; any other single printable
  ## character is its own spelling.
  if s.len == 0: return ""
  if isPrintableChar(s):
    return (if s.len == 1 and s[0] in {'A'..'Z'}: $toLowerAscii(s[0]) else: s)
  let l = s.toLowerAscii
  for (canonical, aliases) in namedKeyTable:
    if l == canonical.toLowerAscii: return canonical
    for a in aliases:
      if l == a.toLowerAscii: return canonical
  if l.len in 2..3 and l[0] == 'f' and l[1] in {'1'..'9'}:
    for c in l[1 .. ^1]:
      if c notin Digits: return ""
    let n = parseInt(l[1 .. ^1])
    if n >= 1 and n <= maxFunctionKey: return "F" & $n
  ""

proc isKeyName*(s: string): bool =
  ## True when `s` names a key of the table.
  canonicalKey(s).len > 0

proc parseModifiers*(list: string): set[Modifier] =
  ## Parse a comma-separated modifier list (`cmd,shift`). Raises
  ## `KeyComboError` for an empty entry, an unknown name or a repeated one
  ## (also when repeated under two spellings, `cmd,meta`).
  for part in list.split(','):
    let m = parseModifier(part)
    if m in result:
      raise newException(KeyComboError, "modifier '" & part & "' given twice")
    result.incl m

proc parseCombo*(s: string): KeyCombo =
  ## Parse a combination. The part after the last `+` is the key and every
  ## part before it a modifier; a combination ending in `+` names the `+`
  ## key (`ctrl++`, `+`). Raises `KeyComboError`.
  if s.len == 0:
    raise newException(KeyComboError, "empty key combination")
  var modPart, key: string
  if s == "+":
    key = "+"
  elif s.endsWith("++"):
    key = "+"
    modPart = s[0 ..< s.len - 2]
    if modPart.len == 0:
      raise newException(KeyComboError, "malformed key combination '" & s & "'")
  elif s.endsWith("+"):
    raise newException(KeyComboError, "a key combination ends with its key: '" & s & "'")
  else:
    let i = s.rfind('+')
    if i < 0: key = s
    else:
      key = s[i + 1 .. ^1]
      modPart = s[0 ..< i]
      if modPart.len == 0:
        raise newException(KeyComboError, "malformed key combination '" & s & "'")
  if modPart.len > 0:
    for part in modPart.split('+'):
      let m = parseModifier(part)
      if m in result.modifiers:
        raise newException(KeyComboError, "modifier '" & part &
          "' given twice in '" & s & "'")
      result.modifiers.incl m
  let c = canonicalKey(key)
  if c.len == 0:
    raise newException(KeyComboError, "unknown key '" & key & "' in '" & s &
      "' (see the key table, spec §7.5)")
  result.key = c

proc modifierSpelling*(mods: set[Modifier]): string =
  ## The modifiers of `mods` joined with `+`, in the normalized order and
  ## canonical spelling.
  for m in Modifier:
    if m in mods:
      if result.len > 0: result.add '+'
      result.add $m

proc `$`*(c: KeyCombo): string =
  ## The normalized spelling of `c`.
  result = modifierSpelling(c.modifiers)
  if result.len > 0: result.add '+'
  result.add c.key

proc normalizeCombo*(s: string): string =
  ## Parse `s` and return its normalized spelling. Raises `KeyComboError`.
  $parseCombo(s)
