## The `linux-wlr-virtual` input backend (spec §4.2): pointer and keyboard
## input on a wlroots compositor through its virtual-pointer and
## virtual-keyboard protocols, and window focus and placement through sway's
## IPC. It is the default input backend of a sway session.
##
## * **Input** is GuiAssert's `wayland_input` helper (helpers/linux), which
##   creates a virtual pointer and a virtual keyboard for the time of one
##   verb and executes the verb's plan (`linux_plan`) through them: the
##   compositor routes every event to the surface under the cursor or with
##   the keyboard focus, as it would a mouse's and a keyboard's. The keyboard
##   carries a keymap written for the verb, so every key of the key table and
##   every character of a typed text has a key whatever layout the session
##   uses (the helper's module comment). Coordinates are the compositor's
##   logical layout (xdg-output), so a scaled output needs no conversion: a
##   point is where `windows` and the tree's bounds put it. A point on no
##   output is exit 3 / `display`, with nothing delivered.
## * **Window management** is sway's IPC (`swaymsg`, https://man.archlinux.org/man/sway-ipc.7):
##   `window-focus` is `[con_id=<id>] focus`; `window-set-bounds` floats the
##   window, then `move absolute position` and `resize set` it; the window is
##   read back from the session's capture backend. On a wlroots compositor
##   other than sway it is unavailable.
##
## Probing (`capabilities --probe`) runs the helper's `probe`, which reports
## whether the compositor offers the two device managers and xdg-output.

import std/[strutils, tables]

import ../../core/[geometry, desktop_types, interfaces]
import ./[linux_common, linux_plan]
import ../capture/linux_common as capture_common

const
  linuxWlrVirtualName* = "linux-wlr-virtual"
  wlrRemedy* = "linux-wlr-virtual sends input to a wlroots compositor (sway): run it in " &
    "such a session (WAYLAND_DISPLAY set), or select the input backend of this " &
    "session's display server (linux-mutter for GNOME, linux-xtest for X11)"
  swayRemedy = "window-focus and window-set-bounds on wlroots go through sway's IPC: " &
    "run in a sway session (SWAYSOCK set)"

proc runPlan(cfg: LinuxInputConfig, ops: seq[InputOp]) =
  cfg.requireEnv(linuxWlrVirtualName, ["WAYLAND_DISPLAY"], "Wayland session", wlrRemedy)
  let helper = cfg.helperPath(linuxWlrVirtualName, "wayland_input")
  let r = cfg.runHelper(linuxWlrVirtualName, @[helper, "run"], toScript(ops),
                        helperBaseTimeoutMs + plannedMs(ops))
  if r.code != 0 or not r.line.startsWith("ok"):
    cfg.raiseHelperFailure(linuxWlrVirtualName, r, wlrRemedy)

proc swaymsg(cfg: LinuxInputConfig, command: string): string =
  cfg.requireEnv(linuxWlrVirtualName, ["SWAYSOCK"], "sway session", swayRemedy)
  let c = cfg.captureCfg
  let exe = c.findTool(linuxWlrVirtualName, "swaymsg")
  let r = c.runTool(linuxWlrVirtualName, @[exe, "-s", cfg.env["SWAYSOCK"], command])
  if r.code != 0:
    if "No matching node" in r.output or "No matching node" in r.errors:
      raise newBackendError(BackendNotFoundError, linuxWlrVirtualName, "window",
        "sway has no window matching the request")
    raise inputFailed(linuxWlrVirtualName, "sway refused '" & command.split(' ', 1)[^1] &
      "' (exit " & $r.code & "): " & lastLine(r.errors & "\n" & r.output))
  r.output

proc requireConId(id: string): string =
  ## A sway container id: decimal digits only, so it cannot widen the
  ## criteria it is put into.
  if id.len == 0 or not id.allCharsInSet(Digits) or id.len > 18:
    raise newBackendError(BackendNotFoundError, linuxWlrVirtualName, "window",
      "no window '" & id & "' in this session (sway window ids are numbers)")
  id

proc swayFocusCommand*(id: string): string = "[con_id=" & requireConId(id) & "] focus"

proc swayBoundsCommand*(id: string, r: Rect): string =
  ## Float the window and give its content the rectangle `r` (the window's
  ## border is none in the sessions GuiAssert starts; with a border the
  ## content lies inside it).
  "[con_id=" & requireConId(id) & "] floating enable, resize set width " & $r.width &
    " px height " & $r.height & " px, move absolute position " & $r.x & " " & $r.y

proc probeHelper(cfg: LinuxInputConfig): tuple[pointer, keyboard: bool, problem: ref BackendError] =
  try:
    cfg.requireEnv(linuxWlrVirtualName, ["WAYLAND_DISPLAY"], "Wayland session", wlrRemedy)
    let helper = cfg.helperPath(linuxWlrVirtualName, "wayland_input")
    let r = cfg.runHelper(linuxWlrVirtualName, @[helper, "probe"], "", helperBaseTimeoutMs)
    if r.code != 0 or not r.line.startsWith("ok"):
      cfg.raiseHelperFailure(linuxWlrVirtualName, r, wlrRemedy)
    result.pointer = "pointer=1" in r.line
    result.keyboard = "keyboard=1" in r.line
  except BackendError as e:
    result.problem = e

proc wlrFeatures(cfg: LinuxInputConfig, probe: bool): seq[Feature] =
  var pointer, keyboard, windows: tuple[state: FeatureState, reason, remedy: string]
  if probe:
    let p = cfg.probeHelper()
    if p.problem != nil:
      pointer = problemOf(p.problem)
      keyboard = pointer
    else:
      const none = "the compositor offers no "
      pointer = if p.pointer: (fsSupported, "", "")
                else: (fsUnavailable, "display-server-unsupported",
                       none & "zwlr_virtual_pointer_manager_v1 or xdg-output: " & wlrRemedy)
      keyboard = if p.keyboard: (fsSupported, "", "")
                 else: (fsUnavailable, "display-server-unsupported",
                        none & "zwp_virtual_keyboard_manager_v1: " & wlrRemedy)
  else:
    try:
      cfg.requireEnv(linuxWlrVirtualName, ["WAYLAND_DISPLAY"], "Wayland session", wlrRemedy)
      discard cfg.helperPath(linuxWlrVirtualName, "wayland_input")
      pointer = (fsAvailable, "", "")
    except BackendError as e:
      pointer = problemOf(e)
    keyboard = pointer
  try:
    if probe: discard cfg.swaymsg("nop")
    else: cfg.requireEnv(linuxWlrVirtualName, ["SWAYSOCK"], "sway session", swayRemedy)
    windows = ((if probe: fsSupported else: fsAvailable), "", "")
  except BackendError as e:
    windows = problemOf(e)
  inputFeatures(linuxWlrVirtualName, pointer, keyboard, windows)

proc newLinuxWlrVirtualInput*(cfg: LinuxInputConfig): InputBackend =
  ## The `linux-wlr-virtual` input backend for the invocation `cfg`.
  when not defined(linux):
    return wrongPlatformInput(linuxWlrVirtualName)
  else:
    result.name = linuxWlrVirtualName
    result.move = proc (session: string, to: Point): InputReport =
      cfg.runPlan(planMove(to))
      moveReport(session, to)
    result.click = proc (session: string, at: Point, button: MouseButton, count: int,
                         modifiers: seq[string]): InputReport =
      cfg.runPlan(planClick(at, button, count, modifiers))
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
      let ops = try: planType(text, intervalMs)
                except InputPlanError as e:
                  raise unavailableWith(linuxWlrVirtualName, "unsupported-option", e.msg,
                    "type the text without the control character")
      cfg.runPlan(ops)
      typeReport(session, text)
    result.key = proc (session, combo: string): InputReport =
      cfg.runPlan(planKey(combo))
      keyReport(session, combo)
    result.focusWindow = proc (session, windowId: string): Window =
      discard cfg.swaymsg(swayFocusCommand(windowId))
      cfg.settledWindow(linuxWlrVirtualName, windowId, proc (w: Window): bool = w.focused)
    result.setWindowBounds = proc (session, windowId: string, bounds: Rect): Window =
      if bounds.width < 1 or bounds.height < 1:
        raise inputFailed(linuxWlrVirtualName, "a window cannot be smaller than 1x1")
      discard cfg.swaymsg(swayBoundsCommand(windowId, bounds))
      cfg.settledWindow(linuxWlrVirtualName, windowId, proc (w: Window): bool = w.bounds == bounds)
    result.features = proc (probe: bool): seq[Feature] = cfg.wlrFeatures(probe)
