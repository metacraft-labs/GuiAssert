## The `linux-uinput` input backend (spec §4.2): pointer and keyboard input
## through the kernel's uinput device, independent of the compositor or X
## server: whatever reads the host's input devices (libinput, in a session
## on the machine's own seat) sees two new devices.
##
## * **Access.** /dev/uinput is writable by root only unless the operator
##   grants more (a udev rule, a group). Without write access every input
##   verb is exit 6 / `uinput-access`, `details.feature` naming
##   `pointer-input` or `keyboard-input`, its remedy naming the device; it
##   is never a success that delivered nothing. `capabilities` reports the
##   same, from `access(2)` without `--probe` and from opening the device
##   with it.
## * **Input** is GuiAssert's `uinput_input` helper (helpers/linux): an
##   absolute pointer whose axes span the desktop (the bounding box of the
##   session's displays, from its capture backend), so a position is a
##   desktop coordinate where the compositor maps the device onto the whole
##   layout, as sway and libinput-based X servers do with such a device; and
##   a keyboard of Linux key codes. Keys and characters are translated with
##   the US layout (`linux_plan.usKeyOf`): the device sends key codes, and
##   which character a code makes is the session's layout's business, so a
##   character the US layout has no key for is exit 4 /
##   `unsupported-option` before anything is sent.
## * **Window management** is not a device's to do: exit 4 /
##   `unsupported-option`; select the compositor's own input backend.

import std/[options, posix, strutils]

import ../../core/[geometry, desktop_types, interfaces]
import ./[linux_common, linux_plan]

const
  linuxUinputName* = "linux-uinput"
  uinputDevice* = "/dev/uinput"
  uinputRemedy* = "linux-uinput writes input events to " & uinputDevice &
    ", which this user cannot write: grant write access to " & uinputDevice &
    " (for example a udev rule `KERNEL==\"uinput\", GROUP=\"input\", MODE=\"0660\"` " &
    "and membership of that group), or select the input backend of the session's " &
    "display server (linux-wlr-virtual, linux-mutter, linux-xtest)"
  layoutRemedy = "linux-uinput types with the US layout's keys; select the input backend " &
    "of the session's display server (linux-wlr-virtual, linux-mutter, linux-xtest) to " &
    "type other characters"

proc denied(msg: string): ref PermissionDeniedError =
  result = newBackendError(PermissionDeniedError, linuxUinputName, "uinput-access", msg)
  result.remedy = uinputRemedy

proc requireAccess() =
  ## Refuse before planning anything when the device cannot be written.
  if access(uinputDevice, W_OK) != 0:
    let err = errno
    if err == ENOENT:
      raise unavailableWith(linuxUinputName, "display-server-unsupported",
        uinputDevice & " does not exist (the uinput kernel module is not loaded)",
        "load the uinput module (modprobe uinput), or " & uinputRemedy)
    raise denied("no write access to " & uinputDevice & ": " & $strerror(err))

proc usScript*(ops: seq[InputOp]): string =
  ## `ops` as the uinput helper's script: each keysym as the US key code
  ## that makes it, Shift pressed around a key on its shift level unless the
  ## plan holds Shift itself. Raises `BackendUnavailableError`
  ## (`unsupported-option`) for a keysym the layout has no key for, naming
  ## its position in the plan, never the character.
  var shiftHeld = false
  var keyIndex = 0
  for o in ops:
    case o.kind
    of ioKey:
      if o.keyDown: inc keyIndex
      let k = usKeyOf(o.keysym)
      if k.isNone:
        raise unavailableWith(linuxUinputName, "unsupported-option", "key " & $keyIndex &
          " of the input has no key on the US layout", layoutRemedy)
      let (code, shift) = k.get
      if o.keysym == keysymShiftL: shiftHeld = o.keyDown
      let wrap = shift and o.keyDown and not shiftHeld
      if wrap: result.add "code " & $keyLeftShift & " down\n"
      result.add "code " & $code & (if o.keyDown: " down\n" else: " up\n")
      if wrap: result.add "code " & $keyLeftShift & " up\n"
    else:
      result.add toScript(@[o])

proc extent(cfg: LinuxInputConfig): Rect =
  ## The desktop's bounding box: what the absolute pointer spans.
  if cfg.displays == nil:
    raise unavailableWith(linuxUinputName, "display-server-unsupported",
      "the session's displays cannot be read, so the pointer has no extent",
      "select the capture backend of the session's display server")
  var first = true
  for d in cfg.displays():
    if first: result = d.bounds
    else:
      let x0 = min(result.x, d.bounds.x)
      let y0 = min(result.y, d.bounds.y)
      result = rect(x0, y0, max(result.right, d.bounds.right) - x0,
                    max(result.bottom, d.bounds.bottom) - y0)
    first = false
  if first or result.isEmpty:
    raise unavailableWith(linuxUinputName, "display-server-unsupported",
      "the session reports no display", "select the capture backend of the session's " &
      "display server")

proc runPlan(cfg: LinuxInputConfig, ops: seq[InputOp]) =
  requireAccess()
  let script = usScript(ops)
  var box = rect(0, 0, 1, 1)
  if movePoints(ops).len > 0: box = cfg.extent()
  let helper = cfg.helperPath(linuxUinputName, "uinput_input")
  let r = cfg.runHelper(linuxUinputName, @[helper, "run", $box.x, $box.y, $box.width,
                                           $box.height], script,
                        helperBaseTimeoutMs + plannedMs(ops))
  if r.code != 0 or not r.line.startsWith("ok"):
    cfg.raiseHelperFailure(linuxUinputName, r, uinputRemedy)

proc noWindows(): ref BackendUnavailableError =
  unavailableWith(linuxUinputName, "unsupported-option",
    "linux-uinput is an input device: it cannot focus or place windows",
    "select the input backend of the session's display server for window-focus and " &
    "window-set-bounds")

proc uinputFeatures(cfg: LinuxInputConfig, probe: bool): seq[Feature] =
  var input: tuple[state: FeatureState, reason, remedy: string]
  try:
    requireAccess()
    if probe:
      let helper = cfg.helperPath(linuxUinputName, "uinput_input")
      let r = cfg.runHelper(linuxUinputName, @[helper, "probe"], "", helperBaseTimeoutMs)
      if r.code != 0 or not r.line.startsWith("ok"):
        cfg.raiseHelperFailure(linuxUinputName, r, uinputRemedy)
    input = ((if probe: fsSupported else: fsAvailable), "", "")
  except BackendError as e:
    input = problemOf(e)
  inputFeatures(linuxUinputName, input, input,
                (fsUnavailable, "unsupported-option", noWindows().remedy))

proc newLinuxUinputInput*(cfg: LinuxInputConfig): InputBackend =
  ## The `linux-uinput` input backend for the invocation `cfg`.
  when not defined(linux):
    return wrongPlatformInput(linuxUinputName)
  else:
    result.name = linuxUinputName
    result.move = proc (session: string, to: Point): InputReport =
      cfg.runPlan(planMove(to))
      moveReport(session, to)
    result.click = proc (session: string, at: Point, button: MouseButton, count: int,
                         modifiers: seq[string]): InputReport =
      cfg.runPlan(planClick(at, button, count, modifiers, modifierSettleMs))
      clickReport(session, at, button, count, modifiers)
    result.drag = proc (session: string, path: seq[Point], button: MouseButton,
                        steps, durationMs: int): InputReport =
      cfg.runPlan(planDrag(path, button, steps, durationMs))
      dragReport(session, path, button)
    result.scroll = proc (session: string, at: Point, dx, dy: int,
                          unit: ScrollUnit): InputReport =
      cfg.runPlan(planScroll(at, dx, dy, unit))
      scrollReport(session, at)
    result.typeText = proc (session, text: string, intervalMs: int): InputReport =
      requireAccess()
      let ops = try: planType(text, intervalMs)
                except InputPlanError as e:
                  raise unavailableWith(linuxUinputName, "unsupported-option", e.msg,
                    "type the text without the control character")
      cfg.runPlan(ops)
      typeReport(session, text)
    result.key = proc (session, combo: string): InputReport =
      cfg.runPlan(planKey(combo))
      keyReport(session, combo)
    result.focusWindow = proc (session, windowId: string): Window = raise noWindows()
    result.setWindowBounds = proc (session, windowId: string, bounds: Rect): Window =
      raise noWindows()
    result.features = proc (probe: bool): seq[Feature] = cfg.uinputFeatures(probe)
