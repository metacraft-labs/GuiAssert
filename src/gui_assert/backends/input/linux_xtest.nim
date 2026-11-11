## The `linux-xtest` input backend (spec §4.2): pointer and keyboard input on
## an X server through the XTest extension, and window focus and placement
## through core X requests. It is the default input backend of an X session
## (an Xvfb, `DISPLAY` without `WAYLAND_DISPLAY`).
##
## * **Input** is GuiAssert's `xtest_input` helper (helpers/linux), which
##   executes the verb's plan (`linux_plan`) as XTest fake device events; the
##   server routes them as a mouse's and a keyboard's. Desktop coordinates
##   are the root window's. A keysym the server's keyboard mapping lacks (a
##   character outside its layout) is typed through a key code the mapping
##   leaves empty, borrowed for the verb (the helper's module comment).
##   `scroll --unit pixel` is exit 4 / `unsupported-option`: the X core
##   protocol scrolls in wheel notches (buttons 4–7) only.
## * **Window management**: `window-focus` raises the window and gives it
##   the input focus (`XRaiseWindow`, `XSetInputFocus`), what a click-to-focus
##   window manager does and what an X server without one never does by
##   itself; `window-set-bounds` is `XMoveResizeWindow` (a window manager may
##   adjust it; the window is read back from the session's capture backend).
##   Window ids are the X window ids `linux-x11` reports.

import std/strutils

import ../../core/[geometry, desktop_types, interfaces]
import ./[linux_common, linux_plan]
import ../capture/linux_common as capture_common

const
  linuxXtestName* = "linux-xtest"
  xtestRemedy* = "linux-xtest sends input to the X server named by DISPLAY: set it " &
    "(for example inside an Xvfb session), or select the input backend of this " &
    "session's compositor (linux-wlr-virtual for sway, linux-mutter for GNOME)"

proc helper(cfg: LinuxInputConfig): string =
  cfg.requireEnv(linuxXtestName, ["DISPLAY"], "X display", xtestRemedy)
  cfg.helperPath(linuxXtestName, "xtest_input")

proc run(cfg: LinuxInputConfig, args: seq[string], input: string, timeoutMs: int): HelperRun =
  result = cfg.runHelper(linuxXtestName, @[cfg.helper] & args, input, timeoutMs)
  if result.code != 0 or not result.line.startsWith("ok"):
    cfg.raiseHelperFailure(linuxXtestName, result, xtestRemedy)

proc runPlan(cfg: LinuxInputConfig, ops: seq[InputOp]) =
  discard cfg.run(@["run"], toScript(ops), helperBaseTimeoutMs + plannedMs(ops))

proc requireWindowId(id: string): string =
  if id.len == 0 or not id.allCharsInSet(Digits) or id.len > 12:
    raise newBackendError(BackendNotFoundError, linuxXtestName, "window",
      "no window '" & id & "' in this session (X window ids are numbers)")
  id

proc xtestFeatures(cfg: LinuxInputConfig, probe: bool): seq[Feature] =
  var input: tuple[state: FeatureState, reason, remedy: string]
  try:
    if probe:
      let r = cfg.run(@["probe"], "", helperBaseTimeoutMs)
      input = if "xtest=1" in r.line: (fsSupported, "", "")
              else: (fsUnavailable, "display-server-unsupported",
                     "the X server has no XTEST extension: " & xtestRemedy)
    else:
      discard cfg.helper()
      input = (fsAvailable, "", "")
  except BackendError as e:
    input = problemOf(e)
  # Window management needs only the core protocol: it stands or falls with
  # the connection.
  let windows = if input.state == fsUnavailable and input.reason == "display-server-unsupported" and
                   "XTEST" in input.remedy:
                  ((if probe: fsSupported else: fsAvailable), "", "")
                else: input
  inputFeatures(linuxXtestName, input, input, windows)

proc newLinuxXtestInput*(cfg: LinuxInputConfig): InputBackend =
  ## The `linux-xtest` input backend for the invocation `cfg`.
  when not defined(linux):
    return wrongPlatformInput(linuxXtestName)
  else:
    result.name = linuxXtestName
    result.move = proc (session: string, to: Point): InputReport =
      cfg.runPlan(planMove(to))
      moveReport(session, to)
    result.click = proc (session: string, at: Point, button: MouseButton, count: int,
                         modifiers: seq[string]): InputReport =
      cfg.runPlan(planClick(at, button, count, modifiers))
      clickReport(session, at, button, count, modifiers)
    result.drag = proc (session: string, path: seq[Point], button: MouseButton,
                        steps, durationMs: int, modifiers: seq[string]): InputReport =
      cfg.runPlan(planDrag(path, button, steps, durationMs, modifiers))
      dragReport(session, path, button, modifiers)
    result.gesture = proc (session: string, steps: seq[GestureStep]): InputReport =
      cfg.runPlan(planGesture(steps))
      gestureReport(session, steps)
    result.scroll = proc (session: string, at: Point, dx, dy: int,
                          unit: ScrollUnit): InputReport =
      if unit == suPixel:
        raise unavailableWith(linuxXtestName, "unsupported-option",
          "--unit pixel: the X core protocol scrolls in wheel notches only",
          "scroll with --unit line on X11")
      cfg.runPlan(planScroll(at, dx, dy, unit))
      scrollReport(session, at)
    result.typeText = proc (session, text: string, intervalMs: int): InputReport =
      let ops = try: planType(text, intervalMs)
                except InputPlanError as e:
                  raise unavailableWith(linuxXtestName, "unsupported-option", e.msg,
                    "type the text without the control character")
      cfg.runPlan(ops)
      typeReport(session, text)
    result.key = proc (session, combo: string): InputReport =
      cfg.runPlan(planKey(combo))
      keyReport(session, combo)
    result.focusWindow = proc (session, windowId: string): Window =
      discard cfg.run(@["focus", requireWindowId(windowId)], "", helperBaseTimeoutMs)
      cfg.settledWindow(linuxXtestName, windowId, proc (w: Window): bool = true, 0)
    result.setWindowBounds = proc (session, windowId: string, bounds: Rect): Window =
      if bounds.width < 1 or bounds.height < 1:
        raise inputFailed(linuxXtestName, "a window cannot be smaller than 1x1")
      discard cfg.run(@["bounds", requireWindowId(windowId), $bounds.x, $bounds.y,
                        $bounds.width, $bounds.height], "", helperBaseTimeoutMs)
      cfg.settledWindow(linuxXtestName, windowId, proc (w: Window): bool = w.bounds == bounds)
    result.features = proc (probe: bool): seq[Feature] = cfg.xtestFeatures(probe)
