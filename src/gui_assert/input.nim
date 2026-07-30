## GuiAssert synthetic keyboard + mouse input (macOS)
##
## The recorder needs to *drive* arbitrary GUI apps — type into an editor,
## fire a menu shortcut (Cmd+N / Cmd+S), move the pointer, click a button —
## so a scripted screencast can be replayed deterministically.  This module
## provides those primitives on macOS.
##
## ### Two backends, by concern
##
##   * **Keyboard** goes through AppleScript / `System Events`
##     (`keystroke "<text>"`, `keystroke "s" using {command down}`,
##     `key code 36`).  This is the *required baseline*: it needs no C FFI,
##     reuses the exact `osascript` plumbing R4 built for window control, and
##     routes keystrokes to whichever process is frontmost — so callers pair
##     it with `activateApp`/`focusWindow` from `window_layout`.
##   * **Mouse** goes through Core Graphics events (`CGEventCreateMouseEvent`
##     + `CGEventPost`) via a tiny, well-commented `{.importc.}` binding to
##     `ApplicationServices`.  System Events can click *accessibility
##     elements* but not arbitrary screen coordinates; CGEvent posts a real
##     HID-level event at an (x, y) pixel, which is what a screencast needs.
##
## ### TCC (permissions)
##
## Synthetic keystrokes and posted CGEvents both require the controlling
## process to hold macOS **Accessibility** permission (System Settings →
## Privacy & Security → Accessibility).  When it is not granted, `osascript`
## keystroke returns a non-zero exit (error `-1719`, "not allowed assistive
## access") which we surface as an `InputError`, and `CGEventPost` silently
## no-ops.  This is a *permission* condition, not a code fault — the pure
## command/keycode generation below is fully unit-tested independent of TCC.
##
## The command *builders* (`buildTypeTextScript`, `buildKeyStrokeScript`,
## `buildKeyCodeScript`, `keyCodeFor`, `buildModifierClause`) are pure and
## exported so tests can assert the exact wire format without invoking any
## subprocess or requiring any permission.

import std/[osproc, strutils, os, streams]
import ./window_layout  # applescriptEscape, buildOsascriptArgv

type
  KeyModifier* = enum
    ## The four modifier keys AppleScript's `System Events` understands in a
    ## `using {...}` clause.  Enum order is significant: iterating a
    ## `set[KeyModifier]` yields modifiers in this order, which makes the
    ## generated `using {...}` clause deterministic (and therefore testable).
    modCommand   ## the Command (⌘) key  -> "command down"
    modOption    ## the Option/Alt (⌥) key -> "option down"
    modControl   ## the Control (⌃) key  -> "control down"
    modShift     ## the Shift (⇧) key    -> "shift down"

  InputError* = object of CatchableError
    ## Raised on any `osascript` failure while injecting keyboard input
    ## (including a TCC/Accessibility denial), or when a key name is unknown.

# ---------------------------------------------------------------------------
# Pure command builders (no subprocess, no TCC — fully unit-tested)
# ---------------------------------------------------------------------------

const modifierPhrase: array[KeyModifier, string] = [
  modCommand: "command down",
  modOption:  "option down",
  modControl: "control down",
  modShift:   "shift down",
]

proc buildModifierClause*(modifiers: set[KeyModifier]): string =
  ## Render a modifier set as an AppleScript `{command down, shift down}`
  ## list.  Returns the empty string when no modifiers are set.  Modifiers
  ## are emitted in `KeyModifier` enum order for a stable, testable result.
  if modifiers.card == 0:
    return ""
  var parts: seq[string]
  for m in modifiers:            # set iteration follows enum order
    parts.add modifierPhrase[m]
  result = "{" & parts.join(", ") & "}"

proc buildTypeTextScript*(text: string): string =
  ## Build the AppleScript that types `text` into the frontmost app via
  ## `System Events`.  The text is escaped for a double-quoted AppleScript
  ## literal (reusing `applescriptEscape`) so quotes and backslashes survive.
  result = "tell application \"System Events\" to keystroke \"" &
    applescriptEscape(text) & "\""

proc buildKeyStrokeScript*(key: string,
                           modifiers: set[KeyModifier] = {}): string =
  ## Build the AppleScript for a single `keystroke` with optional modifiers,
  ## e.g. `keystroke "s" using {command down}` for Cmd+S.  `key` is normally
  ## a single character; it is escaped as an AppleScript literal.  With no
  ## modifiers the `using` clause is omitted entirely.
  let clause = buildModifierClause(modifiers)
  result = "tell application \"System Events\" to keystroke \"" &
    applescriptEscape(key) & "\""
  if clause.len > 0:
    result.add " using " & clause

proc buildKeyCodeScript*(code: int,
                         modifiers: set[KeyModifier] = {}): string =
  ## Build the AppleScript for a raw virtual `key code` with optional
  ## modifiers, e.g. `key code 36` (Return) or
  ## `key code 123 using {shift down}` (Shift+Left).  Use this for keys that
  ## have no printable character (arrows, Return, Escape, …).
  let clause = buildModifierClause(modifiers)
  result = "tell application \"System Events\" to key code " & $code
  if clause.len > 0:
    result.add " using " & clause

const keyCodeTable = {
  # macOS virtual key codes (also the codes CGEvent uses).  These match
  # AppleScript's `key code <n>` and are the non-printable keys a screencast
  # driver reaches for most often.
  "return":        36,
  "enter":         36,
  "tab":           48,
  "space":         49,
  "delete":        51,   # Backspace
  "backspace":     51,
  "escape":        53,
  "esc":           53,
  "forwarddelete": 117,  # the "fn+delete" forward delete
  "home":          115,
  "end":           119,
  "pageup":        116,
  "pagedown":      121,
  "left":          123,
  "right":         124,
  "down":          125,
  "up":            126,
}

proc keyCodeFor*(name: string): int =
  ## Map a friendly key name ("return", "tab", "left", …) to its macOS
  ## virtual key code.  Case-insensitive.  Raises `InputError` for an
  ## unknown name so callers get a clear failure rather than a wrong key.
  let lname = name.toLowerAscii()
  for (n, code) in keyCodeTable:
    if n == lname:
      return code
  raise newException(InputError, "unknown key name: " & name)

# ---------------------------------------------------------------------------
# osascript runner (mirrors window_layout's private helper; kept local so the
# two modules stay decoupled).
# ---------------------------------------------------------------------------

proc runInputOsascript(script: string): tuple[output: string, code: int] =
  let bin = findExe("osascript")
  if bin.len == 0:
    raise newException(InputError,
      "osascript not found on PATH (required for macOS synthetic input)")
  let p = startProcess(
    command = bin,
    args = buildOsascriptArgv(script),
    options = {poStdErrToStdOut})
  let combined = p.outputStream().readAll()
  let code = p.waitForExit()
  p.close()
  return (combined.strip(), code)

# ---------------------------------------------------------------------------
# Public keyboard API (System Events)
# ---------------------------------------------------------------------------

proc typeText*(text: string) =
  ## Type `text` into the frontmost application via `System Events`.
  ## Bring the target forward first with `activateApp`/`focusWindow`.
  ## Raises `InputError` on failure, including a TCC/Accessibility denial
  ## (osascript exits non-zero with error `-1719`).
  if text.len == 0:
    return
  let (osOut, osCode) = runInputOsascript(buildTypeTextScript(text))
  if osCode != 0:
    raise newException(InputError,
      "osascript keystroke failed (" & $osCode & "): " & osOut)

proc keyStroke*(key: string, modifiers: set[KeyModifier] = {}) =
  ## Send a single `keystroke` (optionally with modifiers) to the frontmost
  ## app, e.g. `keyStroke("s", {modCommand})` for Cmd+S.  Raises
  ## `InputError` on failure (including a TCC denial).
  let (osOut, osCode) = runInputOsascript(buildKeyStrokeScript(key, modifiers))
  if osCode != 0:
    raise newException(InputError,
      "osascript keystroke failed (" & $osCode & "): " & osOut)

proc keyCode*(code: int, modifiers: set[KeyModifier] = {}) =
  ## Send a raw virtual `key code` (optionally with modifiers) to the
  ## frontmost app.  Raises `InputError` on failure.
  let (osOut, osCode) = runInputOsascript(buildKeyCodeScript(code, modifiers))
  if osCode != 0:
    raise newException(InputError,
      "osascript key code failed (" & $osCode & "): " & osOut)

proc keyNamed*(name: string, modifiers: set[KeyModifier] = {}) =
  ## Convenience: send a named non-printable key ("return", "tab", "left",
  ## …) resolved through `keyCodeFor`.  Raises `InputError` for an unknown
  ## name or on osascript failure.
  keyCode(keyCodeFor(name), modifiers)

# ---------------------------------------------------------------------------
# Public mouse API (Core Graphics events)
# ---------------------------------------------------------------------------
#
# CGEvent posts a real HID-level event at an absolute screen coordinate,
# which System Events cannot do.  The binding is intentionally minimal: two
# imported functions plus CFRelease, and the handful of integer constants we
# use.  Like keyboard input, posting events requires Accessibility
# permission; without it CGEventPost silently no-ops (there is no return
# code to check), so mouse input is best-effort by nature.

when defined(macosx):
  {.passL: "-framework ApplicationServices -framework CoreFoundation".}

  type
    CGEventRef = pointer
    CGEventSourceRef = pointer
    CGPoint {.bycopy.} = object
      x: cdouble
      y: cdouble

  # Core Graphics event-type / button / tap constants (from CGEventTypes.h).
  const
    kCGEventLeftMouseDown = 1'u32
    kCGEventLeftMouseUp   = 2'u32
    kCGEventMouseMoved    = 5'u32
    kCGMouseButtonLeft    = 0'u32
    kCGHIDEventTap        = 0'u32  # post at the HID level (into the system)

  proc CGEventCreateMouseEvent(source: CGEventSourceRef, mouseType: uint32,
                               pos: CGPoint,
                               button: uint32): CGEventRef
    {.importc, cdecl.}
  proc CGEventPost(tap: uint32, event: CGEventRef) {.importc, cdecl.}
  proc CFRelease(cf: pointer) {.importc, cdecl.}

  proc postMouse(kind: uint32, x, y: int) =
    let pos = CGPoint(x: cdouble(x), y: cdouble(y))
    let ev = CGEventCreateMouseEvent(nil, kind, pos, kCGMouseButtonLeft)
    if ev == nil:
      raise newException(InputError, "CGEventCreateMouseEvent returned nil")
    CGEventPost(kCGHIDEventTap, ev)
    CFRelease(ev)

  proc mouseMove*(x, y: int) =
    ## Move the pointer to absolute screen coordinate (`x`, `y`) by posting a
    ## CGEvent.  Best-effort: silently no-ops if Accessibility is not granted.
    postMouse(kCGEventMouseMoved, x, y)

  proc mouseClick*(x, y: int) =
    ## Move to (`x`, `y`) then post a left-button down+up (a click).
    ## Best-effort (see `mouseMove`).
    postMouse(kCGEventMouseMoved, x, y)
    postMouse(kCGEventLeftMouseDown, x, y)
    postMouse(kCGEventLeftMouseUp, x, y)

else:
  proc mouseMove*(x, y: int) =
    ## Non-macOS stub: CGEvent mouse injection is macOS-only.
    raise newException(InputError,
      "mouseMove is only implemented on macOS (CGEvent)")

  proc mouseClick*(x, y: int) =
    ## Non-macOS stub: CGEvent mouse injection is macOS-only.
    raise newException(InputError,
      "mouseClick is only implemented on macOS (CGEvent)")
