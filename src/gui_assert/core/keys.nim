## GuiAssert core: the key table and key-combination syntax of the contract.
##
## The `key` verb takes a combination such as `cmd+s`, `ctrl+shift+Tab` or
## `Return`, and `click --modifiers` a list of modifiers (spec §7.5). Both
## are checked against the fixed table below; an unknown name is refused,
## never guessed, so a typo cannot turn into a different key.
##
## The syntax is `[<modifier>+]...<key>`:
##
## * modifiers, lower case: `ctrl`, `alt`, `shift`, `cmd` (each at most once);
## * the key, exactly one of:
##   - a lower-case letter `a`..`z` or a digit `0`..`9`;
##   - one of the punctuation keys `` - = [ ] \ ; ' , . / ` ``;
##   - a named key: `Return`, `Tab`, `Escape`, `BackSpace`, `Delete`,
##     `Space`, `Up`, `Down`, `Left`, `Right`, `Home`, `End`, `PageUp`,
##     `PageDown`, `Insert`, `F1`..`F24`.
##
## The normalized spelling (`normalizeCombo`) lists the modifiers in the
## table's order (`ctrl`, `alt`, `shift`, `cmd`) followed by the key, so two
## spellings of one combination normalize to one string. `cmd` is the
## Command key on macOS and the Windows/Super key elsewhere.

import std/strutils

type
  KeyComboError* = object of CatchableError
    ## Raised for an unknown key or modifier name, or a malformed combination.

  Modifier* = enum
    ## The modifier keys, in their normalized order.
    modCtrl = "ctrl"
    modAlt = "alt"
    modShift = "shift"
    modCmd = "cmd"

  KeyCombo* = object
    ## A parsed combination: its modifiers and its key name.
    modifiers*: set[Modifier]
    key*: string

const
  namedKeys* = ["Return", "Tab", "Escape", "BackSpace", "Delete", "Space",
                "Up", "Down", "Left", "Right", "Home", "End", "PageUp",
                "PageDown", "Insert"]
    ## The named, non-function keys.
  punctuationKeys* = "-=[]\\;',./`"
    ## The single-character punctuation keys.
  maxFunctionKey* = 24

proc parseModifier*(s: string): Modifier =
  ## The modifier spelled `s`. Raises `KeyComboError` for anything else.
  for m in Modifier:
    if $m == s: return m
  raise newException(KeyComboError, "unknown modifier '" & s &
    "' (expected one of ctrl, alt, shift, cmd)")

proc isKeyName*(s: string): bool =
  ## True when `s` names a key of the table.
  if s.len == 1:
    return s[0] in {'a'..'z', '0'..'9'} or s[0] in punctuationKeys
  if s in namedKeys: return true
  if s.len in 2..3 and s[0] == 'F' and s[1] in {'1'..'9'}:
    for c in s[1 .. ^1]:
      if c notin Digits: return false
    let n = parseInt(s[1 .. ^1])
    return n >= 1 and n <= maxFunctionKey
  false

proc parseModifiers*(list: string): set[Modifier] =
  ## Parse a comma-separated modifier list (`cmd,shift`). Raises
  ## `KeyComboError` for an empty entry, an unknown name or a repeated one.
  for part in list.split(','):
    let m = parseModifier(part)
    if m in result:
      raise newException(KeyComboError, "modifier '" & part & "' given twice")
    result.incl m

proc parseCombo*(s: string): KeyCombo =
  ## Parse a combination. The last `+`-separated part is the key; every
  ## part before it is a modifier. A combination whose key is `+` cannot be
  ## written; there is no `+` key in the table. Raises `KeyComboError`.
  if s.len == 0:
    raise newException(KeyComboError, "empty key combination")
  let parts = s.split('+')
  for i in 0 ..< parts.high:
    let m = parseModifier(parts[i])
    if m in result.modifiers:
      raise newException(KeyComboError, "modifier '" & parts[i] &
        "' given twice in '" & s & "'")
    result.modifiers.incl m
  let key = parts[^1]
  if not isKeyName(key):
    raise newException(KeyComboError, "unknown key '" & key & "' in '" & s &
      "' (see the key table in gui_assert/core/keys)")
  result.key = key

proc modifierSpelling*(mods: set[Modifier]): string =
  ## The modifiers of `mods` joined with `+`, in the normalized order.
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
