## What the Linux input backends (`linux-wlr-virtual`, `linux-mutter`,
## `linux-xtest`, `linux-uinput`; spec §4.2) share and need no display
## server for: each input verb PLANNED as a list of primitive events, the
## keysyms and key codes of the key table and of typed text, the input script
## the C helpers execute, the reports, and the stream coordinates of Mutter's
## remote-desktop API. Everything here is pure, so `tests/tlinux_input.nim`
## checks it without a session.
##
## **One plan, four transports.** A verb becomes the same events on every
## backend: pointer motion to desktop points, button presses and releases,
## wheel notches or pixel scrolls, key presses and releases named by X keysym
## (https://www.x.org/releases/current/doc/xproto/x11protocol.html#keysym_encoding),
## and waits. `linux-wlr-virtual`, `linux-xtest` and `linux-uinput` write the
## plan as an input script to their helper's standard input (never its
## command line, so typed text is not in any process's argv; spec §7.5
## "Secrets off argv"); `linux-mutter` sends it as D-Bus calls. The order is
## the plan's: the per-session lock of the input verbs (`cli/verbs`) and the
## arrival order of `serve` (spec §8.5) keep two verbs from interleaving.
##
## **Conventions.** `scroll --dy N` with N > 0 scrolls DOWN (towards the end
## of the content, as a wheel turned towards the user), `--dx N` > 0 to the
## right; `--unit line` turns the wheel N notches, `--unit pixel` scrolls N
## logical pixels smoothly. Typed text is one key press and release per code
## point, a newline (LF, CR or CR LF) as `Return` and a tab as `Tab`; any
## other control character has no key and is refused before anything is
## sent. A drag presses at its first point, moves through every later point
## (`steps` motion events per segment, the last of each exactly on the
## vertex) and releases at its last; `--duration-ms` is spread evenly over
## the motion events.

import std/[math, options, strutils, unicode]

import ../../core/[geometry, desktop_types, interfaces, keys]

type
  InputOpKind* = enum
    ioMove, ioButton, ioScroll, ioKey, ioSleep

  InputOp* = object
    ## One primitive event of a plan.
    case kind*: InputOpKind
    of ioMove:
      at*: Point                 ## desktop coordinates
    of ioButton:
      button*: MouseButton
      pressed*: bool
    of ioScroll:
      vertical*: bool
      amount*: int               ## notches or pixels; > 0 down / right
      unit*: ScrollUnit
    of ioKey:
      keysym*: uint32
      keyDown*: bool
    of ioSleep:
      ms*: int

  InputPlanError* = object of CatchableError
    ## A verb that cannot be planned (a control character in typed text).

const
  pressHoldMs* = 15
    ## Between a button's press and its release, so a toolkit that reads
    ## the press and the release in two frames sees both.
  multiClickGapMs* = 40
    ## Between the clicks of `click --count N`: well inside every toolkit's
    ## double-click time (GTK and Qt default to 400 ms), and long enough
    ## for each click to be its own event.
  dragPressMs* = 30
    ## After a drag's press, before its first motion, so the press is the
    ## toolkit's grab before the pointer moves.
  modifierSettleMs* = 30
    ## The wait between pressing the modifiers of `click --modifiers` and
    ## moving the pointer, for the transports that need one (`planClick`'s
    ## `modifierSettle`). `linux-mutter`: Mutter applies a virtual keyboard's
    ## modifier state to pointer events a moment after it delivers the keys,
    ## and its API offers nothing to wait on (measured on GNOME Shell 49:
    ## with no wait, the first press of a modified double click came without
    ## its modifiers in one of three runs). `linux-uinput`: its keys and its
    ## pointer are two evdev devices, which the compositor reads as two file
    ## descriptors with no order between them. `linux-wlr-virtual` and
    ## `linux-xtest` need none: the compositor or X server handles one
    ## connection's requests in order, so the modifiers are in effect before
    ## the button (measured with no wait: 20 modified clicks on sway and
    ## Xvfb, each carried its modifiers).

  keysymShiftL* = 0xffe1'u32
  keysymControlL* = 0xffe3'u32
  keysymAltL* = 0xffe9'u32
  keysymSuperL* = 0xffeb'u32
  keysymReturn* = 0xff0d'u32
  keysymTab* = 0xff09'u32

  modifierKeysyms*: array[Modifier, uint32] = [keysymControlL, keysymAltL, keysymShiftL,
                                               keysymSuperL]
    ## The key each modifier of the key table presses: the left Control,
    ## Alt, Shift and Super keys (`cmd` is the Super key on Linux, spec §7.5).

  namedKeysyms*: seq[tuple[name: string, keysym: uint32]] = @[
    ("Return", 0xff0d'u32), ("Tab", 0xff09'u32), ("Escape", 0xff1b'u32),
    ("BackSpace", 0xff08'u32), ("Delete", 0xffff'u32), ("Insert", 0xff63'u32),
    ("Space", 0x20'u32), ("Home", 0xff50'u32), ("End", 0xff57'u32),
    ("PageUp", 0xff55'u32), ("PageDown", 0xff56'u32), ("Pause", 0xff13'u32),
    ("Up", 0xff52'u32), ("Down", 0xff54'u32), ("Left", 0xff51'u32), ("Right", 0xff53'u32)]
    ## The keysym of every named key of the key table but the function keys
    ## (X11 keysymdef.h: `XK_Return`, `XK_Prior` for PageUp, `XK_Next` for
    ## PageDown, …).

  keysymF1* = 0xffbe'u32
    ## `XK_F1`; `F<n>` is `XK_F1 + n - 1` up to `XK_F35`.

# ---------------------------------------------------------------------------
# Keysyms
# ---------------------------------------------------------------------------

proc keysymOfRune*(r: Rune): uint32 =
  ## The keysym that types code point `r`: Latin-1's printable characters
  ## are their own keysyms, every other one the Unicode keysym
  ## `0x01000000 + code point` (X11 keysym encoding, Appendix A).
  let c = uint32(r)
  if (c >= 0x20 and c <= 0x7e) or (c >= 0xa0 and c <= 0xff): c
  else: 0x0100_0000'u32 + c

proc keysymOfKey*(canonical: string): uint32 =
  ## The keysym of a key of the table, by its canonical spelling
  ## (`core/keys.canonicalKey`): a named key, `F1`..`F24`, or a single
  ## printable character (a letter is its lower-case keysym).
  for (name, ks) in namedKeysyms:
    if name == canonical: return ks
  if canonical.len >= 2 and canonical[0] == 'F' and canonical[1 .. ^1].allCharsInSet(Digits):
    let n = parseInt(canonical[1 .. ^1])
    if n >= 1 and n <= maxFunctionKey: return keysymF1 + uint32(n - 1)
  if canonical.runeLen == 1: return keysymOfRune(canonical.runeAt(0))
  raise newException(InputPlanError, "no keysym for key '" & canonical & "'")

proc isModifierKeysym*(ks: uint32): bool =
  ks in [keysymShiftL, keysymControlL, keysymAltL, keysymSuperL]

# ---------------------------------------------------------------------------
# Plans
# ---------------------------------------------------------------------------

proc move(p: Point): InputOp = InputOp(kind: ioMove, at: p)
proc btn(b: MouseButton, down: bool): InputOp = InputOp(kind: ioButton, button: b, pressed: down)
proc key(ks: uint32, down: bool): InputOp = InputOp(kind: ioKey, keysym: ks, keyDown: down)
proc wait(ms: int): InputOp = InputOp(kind: ioSleep, ms: ms)

proc modifierSet(modifiers: seq[string]): set[Modifier] =
  for m in modifiers: result.incl parseModifier(m)

proc pressModifiers(ops: var seq[InputOp], mods: set[Modifier]) =
  for m in Modifier:
    if m in mods: ops.add key(modifierKeysyms[m], true)

proc releaseModifiers(ops: var seq[InputOp], mods: set[Modifier]) =
  for m in countdown(high(Modifier), low(Modifier)):
    if m in mods: ops.add key(modifierKeysyms[m], false)

proc planMove*(to: Point): seq[InputOp] = @[move(to)]

proc planClick*(at: Point, button: MouseButton, count: int,
                modifiers: seq[string], modifierSettle = 0): seq[InputOp] =
  ## Hold `modifiers` (canonical spellings), wait `modifierSettle` ms when
  ## there are any (see `modifierSettleMs`), move to `at`, click `count`
  ## times, release the modifiers.
  let mods = modifierSet(modifiers)
  result.pressModifiers(mods)
  if mods != {} and modifierSettle > 0: result.add wait(modifierSettle)
  result.add move(at)
  for i in 0 ..< count:
    if i > 0: result.add wait(multiClickGapMs)
    result.add btn(button, true)
    result.add wait(pressHoldMs)
    result.add btn(button, false)
  result.releaseModifiers(mods)

proc planDrag*(path: seq[Point], button: MouseButton, steps,
               durationMs: int): seq[InputOp] =
  ## Press at `path[0]`, move through every later vertex (`steps` motion
  ## events per segment, interpolated linearly, the last exactly on the
  ## vertex), release at the last vertex.
  if path.len < 2: raise newException(InputPlanError, "a drag needs a start and an end point")
  let steps = max(1, steps)
  let events = steps * (path.len - 1)
  let per = if events > 0: durationMs div events else: 0
  result.add move(path[0])
  result.add btn(button, true)
  result.add wait(dragPressMs)
  for s in 0 ..< path.len - 1:
    let a = path[s]
    let b = path[s + 1]
    for k in 1 .. steps:
      let p = if k == steps: b
              else: point(a.x + int(round((b.x - a.x).float * k.float / steps.float)),
                          a.y + int(round((b.y - a.y).float * k.float / steps.float)))
      result.add move(p)
      if per > 0: result.add wait(per)
  result.add btn(button, false)

proc planScroll*(at: Point, dx, dy: int, unit: ScrollUnit): seq[InputOp] =
  result.add move(at)
  if dy != 0: result.add InputOp(kind: ioScroll, vertical: true, amount: dy, unit: unit)
  if dx != 0: result.add InputOp(kind: ioScroll, vertical: false, amount: dx, unit: unit)

proc typedKeysyms*(text: string): seq[uint32] =
  ## The keysym of every key `text` types, in order (module doc,
  ## "Conventions"). Raises `InputPlanError` naming the POSITION of a control
  ## character that has no key, never the character or the text (captured
  ## content stays off messages, spec §7.5).
  let runes = text.toRunes
  var i = 0
  while i < runes.len:
    let c = int(runes[i])
    if c == 0x0d:
      result.add keysymReturn
      if i + 1 < runes.len and int(runes[i + 1]) == 0x0a: inc i
    elif c == 0x0a: result.add keysymReturn
    elif c == 0x09: result.add keysymTab
    elif c < 0x20 or (c >= 0x7f and c <= 0x9f):
      raise newException(InputPlanError, "character " & $(i + 1) &
        " of the text is a control character that no key types")
    else: result.add keysymOfRune(runes[i])
    inc i

proc planTypeKeysyms*(keysyms: seq[uint32], intervalMs: int): seq[InputOp] =
  for i, ks in keysyms:
    if i > 0 and intervalMs > 0: result.add wait(intervalMs)
    result.add key(ks, true)
    result.add key(ks, false)

proc planType*(text: string, intervalMs: int): seq[InputOp] =
  ## One press and release per key of `text`, `intervalMs` apart.
  planTypeKeysyms(typedKeysyms(text), intervalMs)

proc planKey*(combo: string): seq[InputOp] =
  ## `combo` (normalized, `core/keys.normalizeCombo`): its modifiers pressed
  ## in the table's order, the key pressed and released, the modifiers
  ## released in reverse.
  let c = parseCombo(combo)
  result.pressModifiers(c.modifiers)
  let ks = keysymOfKey(c.key)
  result.add key(ks, true)
  result.add key(ks, false)
  result.releaseModifiers(c.modifiers)

proc plannedMs*(ops: seq[InputOp]): int =
  ## The time the waits of a plan add up to.
  for o in ops:
    if o.kind == ioSleep: result += o.ms

proc movePoints*(ops: seq[InputOp]): seq[Point] =
  for o in ops:
    if o.kind == ioMove: result.add o.at

proc keysymsOf*(ops: seq[InputOp]): seq[uint32] =
  ## The distinct keysyms a plan presses, in first-use order.
  for o in ops:
    if o.kind == ioKey and o.keysym notin result: result.add o.keysym

# ---------------------------------------------------------------------------
# The input script (helpers/linux/input_script.h)
# ---------------------------------------------------------------------------

proc keysymHex*(ks: uint32): string = "0x" & toHex(ks, 8).toLowerAscii

proc scriptLine(o: InputOp): string =
  case o.kind
  of ioMove: "move " & $o.at.x & " " & $o.at.y
  of ioButton: "button " & $o.button & (if o.pressed: " down" else: " up")
  of ioScroll: "scroll " & (if o.vertical: "v " else: "h ") & $o.amount & " " & $o.unit
  of ioKey: "key " & keysymHex(o.keysym) & (if o.keyDown: " down" else: " up")
  of ioSleep: "sleep " & $o.ms

proc toScript*(ops: seq[InputOp]): string =
  ## The plan as the helpers' input script, one event per line.
  for o in ops:
    result.add scriptLine(o)
    result.add '\n'

# ---------------------------------------------------------------------------
# US key codes (linux-uinput)
# ---------------------------------------------------------------------------

type UsKey* = tuple[code: int, shift: bool]

const
  keyLeftShift* = 42
  usModifierCodes*: array[Modifier, int] = [29, 56, 42, 125]
    ## KEY_LEFTCTRL, KEY_LEFTALT, KEY_LEFTSHIFT, KEY_LEFTMETA
    ## (linux/input-event-codes.h).
  usRows = [
    (" ", 57, ' '),
    ("1234567890", 2, ' '), ("!@#$%^&*()", 2, 's'),
    ("qwertyuiop", 16, ' '), ("QWERTYUIOP", 16, 's'),
    ("asdfghjkl", 30, ' '), ("ASDFGHJKL", 30, 's'),
    ("zxcvbnm", 44, ' '), ("ZXCVBNM", 44, 's')]
  usSingles = [('-', 12, false), ('=', 13, false), ('_', 12, true), ('+', 13, true),
               ('[', 26, false), (']', 27, false), ('{', 26, true), ('}', 27, true),
               (';', 39, false), ('\'', 40, false), (':', 39, true), ('"', 40, true),
               ('`', 41, false), ('~', 41, true), ('\\', 43, false), ('|', 43, true),
               (',', 51, false), ('.', 52, false), ('/', 53, false),
               ('<', 51, true), ('>', 52, true), ('?', 53, true)]
  usNamed = [(0xff0d'u32, 28), (0xff09'u32, 15), (0xff1b'u32, 1), (0xff08'u32, 14),
             (0xffff'u32, 111), (0xff63'u32, 110), (0xff50'u32, 102), (0xff57'u32, 107),
             (0xff55'u32, 104), (0xff56'u32, 109), (0xff13'u32, 119), (0xff52'u32, 103),
             (0xff54'u32, 108), (0xff51'u32, 105), (0xff53'u32, 106),
             (keysymShiftL, 42), (keysymControlL, 29), (keysymAltL, 56), (keysymSuperL, 125)]
  usFunctionCodes = [59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 87, 88,
                     183, 184, 185, 186, 187, 188, 189, 190, 191, 192, 193, 194]
    ## KEY_F1..KEY_F10, KEY_F11, KEY_F12, KEY_F13..KEY_F24.

proc usKeyOf*(ks: uint32): Option[UsKey] =
  ## The Linux key code (and whether Shift is needed) that produces keysym
  ## `ks` on a US layout; none for a keysym the layout has no key for.
  for (k, code) in usNamed:
    if k == ks: return some((code, false))
  if ks >= keysymF1 and ks < keysymF1 + uint32(usFunctionCodes.len):
    return some((usFunctionCodes[int(ks - keysymF1)], false))
  if ks < 0x20 or ks > 0x7e: return none(UsKey)
  let ch = char(ks)
  for (row, first, shift) in usRows:
    # Each row of keys has contiguous key codes.
    let i = row.find(ch)
    if i >= 0: return some((first + i, shift == 's'))
  for (c, code, shift) in usSingles:
    if c == ch: return some((code, shift))
  none(UsKey)

# ---------------------------------------------------------------------------
# Reports
# ---------------------------------------------------------------------------

proc newReport*(kind, session: string): InputReport =
  InputReport(kind: kind, delivery: dInjected, session: session)

proc moveReport*(session: string, to: Point): InputReport =
  result = newReport("move", session)
  result.to = some(to)

proc clickReport*(session: string, at: Point, button: MouseButton, count: int,
                  modifiers: seq[string]): InputReport =
  result = newReport("click", session)
  result.at = some(at)
  result.button = some($button)
  result.count = some(count)
  if modifiers.len > 0: result.keys = some(modifiers.join("+"))

proc dragReport*(session: string, path: seq[Point], button: MouseButton): InputReport =
  result = newReport("drag", session)
  result.at = some(path[0])
  result.to = some(path[^1])
  result.button = some($button)
  result.path = some(path)

proc scrollReport*(session: string, at: Point): InputReport =
  result = newReport("scroll", session)
  result.at = some(at)

proc typeReport*(session, text: string): InputReport =
  ## Typed text by its length in code points only (spec §7.5).
  result = newReport("type", session)
  result.length = some(text.runeLen)

proc keyReport*(session, combo: string): InputReport =
  result = newReport("key", session)
  result.keys = some(combo)

# ---------------------------------------------------------------------------
# Mutter's stream coordinates (linux-mutter)
# ---------------------------------------------------------------------------

type
  MutterMonitor* = object
    ## One logical monitor of `org.gnome.Mutter.DisplayConfig.GetCurrentState`.
    connector*: string       ## its first monitor's connector (`Meta-0`)
    bounds*: Rect            ## desktop (stage) coordinates
    scale*: float

proc streamPosition*(monitors: seq[MutterMonitor], logicalLayout: bool,
                     p: Point): Option[tuple[connector: string, x, y: float]] =
  ## Where desktop point `p` is in the screen-cast stream of the monitor that
  ## holds it, as `NotifyPointerMotionAbsolute` takes it: Mutter maps a
  ## stream position back with `layout.x + stream_x / scale`, where `scale`
  ## is the monitor's when stage views are scaled (the "logical" layout
  ## mode, `layout-mode` 1) and 1 otherwise
  ## (meta-screen-cast-monitor-stream.c, `transform_position`). None when no
  ## monitor holds `p`. The position maps back exactly onto `p`.
  for m in monitors:
    if p.x >= m.bounds.x and p.y >= m.bounds.y and p.x < m.bounds.right and
       p.y < m.bounds.bottom:
      let s = if logicalLayout and m.scale > 0: m.scale else: 1.0
      return some((m.connector, float(p.x - m.bounds.x) * s,
                   float(p.y - m.bounds.y) * s))
  none(tuple[connector: string, x, y: float])
