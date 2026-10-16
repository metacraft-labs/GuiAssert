## GUIENV-M1 — the headless sway target, against a REAL sway.
##
## Build & run (inside `nix develop`, Linux only):
##   nim c -r tests/tdesktop_env_sway.nim
##
## Each case starts a private headless sway with its session bus and
## settings portal, drives it through the target interface, and checks the
## result against the COMPOSITOR's own report (sway IPC), never against the
## driver's intent. The windows are real Wayland clients: `wm_probe map
## hold=MS` maps a 320x200 grey window and keeps it open.
##
## MOCKS: none. Every operation goes to a real sway, a real dbus-daemon and
## a real xdg-desktop-portal.
##
## NEGATIVE CONTROLS: a killed compositor makes `windows` and pointer
## operations fail BY NAME (`EnvError` naming the target and operation),
## and an unknown fact or setting is refused rather than answered.

import std/[osproc, unittest]
import gui_assert/desktop_env
import gui_assert/desktop_env/[sway, helpers]

const probeApp = "gui-assert-wm-probe"

proc holdWindow(t: TargetEnvironment; ms = 30000): Process =
  t.spawn(@[helper("wm_probe"), "map", "hold=" & $ms])

suite "GUIENV-M1 — headless sway target":

  var t: SwayTarget

  setup:
    t = newSwayTarget(1280, 800)
    t.start()

  teardown:
    t.stop()

  test "facts are measured from the compositor":
    check t.fact("decorations.default").value == "server"
    check t.fact("decorations.default").provenance == fpMeasured
    check t.fact("decorations.honoursClientRequest").value == "floating-only"
    check not t.boolFact("window.canMinimize")
    check not t.boolFact("window.canMaximize")
    check t.boolFact("window.canFullscreen")
    check t.boolFact("window.hasWindowMenu")
    check t.fact("window.floatingByDefault").provenance == fpDeclared

  test "an unknown fact is refused by name, never answered":
    expect EnvError:
      discard t.fact("window.canTeleport")

  test "a window is read back from the compositor":
    discard t.holdWindow()
    let w = t.waitWindow(probeApp)
    check wsFloating in w.states
    check w.rect.w == 320 and w.rect.h == 200
    check w.pid > 0

  test "a click with the pointer device focuses the window under it":
    # Two windows apart; sway focuses the one clicked. Focus is read back
    # from the compositor, so this shows the pointer DEVICE reaches sway's
    # own input routing at the position the driver named.
    proc byPid(pid: int): EnvWindow =
      t.waitUntil("window of pid " & $pid, proc(): bool =
        for w in t.windows():
          if w.pid == pid: return true
        false)
      for w in t.windows():
        if w.pid == pid: return w
    proc placed(pid, x, y: int): EnvWindow =
      # Placed, then painted: sway lists a window before its first frame is
      # presented, and a click before that can land on nothing.
      t.command("[pid=" & $pid & "] move position " & $x & " " & $y)
      t.waitUntil("pid " & $pid & " at " & $x & "," & $y, proc(): bool =
        let w = byPid(pid)
        w.rect.x == x and w.rect.y == y)
      result = byPid(pid)
      discard t.captureSettled(result.rect)
    let first = t.holdWindow().processID
    discard placed(first, 40, 40)
    let second = t.holdWindow().processID
    discard placed(second, 700, 400)
    for target in [first, second, first]:
      t.click(byPid(target).rect.center)
      t.waitUntil("pid " & $target & " focused by a click", proc(): bool =
        byPid(target).focused)

  test "a capture returns the frame at the requested size":
    discard t.holdWindow()
    let w = t.waitWindow(probeApp)
    let img = t.captureSettled(w.rect)
    check img.width == 320 and img.height == 200
    # The probe fills its buffer with 0x80 grey.
    check img.pixel(160, 100) == (0x80'u8, 0x80'u8, 0x80'u8)
    # And the desktop beside it is not the window: the capture is of the
    # region asked for, not of whatever is focused.
    check t.captureSettled(Rect(x: 0, y: 0, w: 40, h: 40)).pixel(5, 5) ==
          (0'u8, 0'u8, 0'u8)

  test "key chords and text are injected through the virtual keyboard":
    # wtype creates its own virtual keyboard per call; a chord or text it
    # cannot type fails the call (and so the operation, by name).
    t.keys("ctrl+shift+a")
    t.keys("Escape")
    t.typeText("hello")
    expect EnvError:
      t.keys("ctrl+NoSuchKeyName")

  test "a configured setting is served by the session's settings portal":
    t.configure("buttonLayout", "close,minimize:maximize")
    check t.fact("buttonLayout").value == "close,minimize:maximize"
    check t.fact("buttonLayout").provenance == fpConfigured
    t.configure("buttonLayout", ":close")
    check t.fact("buttonLayout").value == ":close"

  test "an unknown setting is refused":
    expect EnvError:
      t.configure("wallpaper", "none")

  test "operations on a dead compositor fail by name":
    t.stop()
    try:
      discard t.windows()
      fail()
    except EnvError as e:
      check e.target == "sway"
      check e.operation == "windows"
    expect EnvError:
      t.pointerMove(10, 10)
