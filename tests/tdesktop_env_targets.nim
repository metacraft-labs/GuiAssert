## The desktop-environment targets, each against its REAL compositor.
##
## Build & run (inside `nix develop`, Linux only):
##   nim c -r tests/tdesktop_env_targets.nim
##   GUIENV_TARGETS=gnome nim c -r tests/tdesktop_env_targets.nim
##
## ONE suite, run unchanged on every target (default: sway, then GNOME). Each
## case starts a private session — compositor, session bus, settings portal —
## drives it through the target interface, and checks the result against
## the COMPOSITOR's own report, never against the driver's intent. The
## windows are real Wayland clients: `wm_probe map hold=MS` maps a 320x200
## grey window and keeps it open.
##
## The one per-target table is `measured`: the values each target's facts
## are expected to measure, which is a test OF the target's measurement —
## not a scenario branching on a desktop's name.
##
## MOCKS: none. Real compositors (sway; GNOME Shell with Mutter), a real
## dbus-daemon and a real xdg-desktop-portal.
##
## NEGATIVE CONTROLS: a stopped target makes `windows` and pointer operations
## fail BY NAME (`EnvError` naming the target and operation); an unknown
## fact, setting or key is refused rather than answered.

import std/[os, osproc, strutils, tables, unittest]
import gui_assert/desktop_env
import gui_assert/desktop_env/[gnome, helpers, sway]

const probeApp = "gui-assert-wm-probe"

let measured = {
  "sway": {"decorations.default": "server", "decorations.serverAvailable": "true",
           "decorations.honoursClientRequest": "floating-only",
           "window.canMinimize": "false", "window.canMaximize": "false",
           "window.canFullscreen": "true", "window.hasWindowMenu": "true"}.toTable,
  "gnome": {"decorations.default": "client", "decorations.serverAvailable": "false",
            "decorations.honoursClientRequest": "always",
            "window.canMinimize": "true", "window.canMaximize": "true",
            "window.canFullscreen": "true", "window.hasWindowMenu": "true"}.toTable,
}.toTable

proc newTarget(name: string): TargetEnvironment =
  case name
  of "sway": newSwayTarget(1280, 800)
  of "gnome": newGnomeTarget(1280, 800)
  else: raise newException(ValueError, "unknown target " & name)

proc holdWindow(t: TargetEnvironment; ms = 30000): Process =
  t.spawn(@[helper("wm_probe"), "map", "hold=" & $ms])

proc byPid(t: TargetEnvironment; pid: int): EnvWindow =
  t.waitUntil("window of pid " & $pid, proc(): bool =
    for w in t.windows():
      if w.pid == pid: return true
    false)
  for w in t.windows():
    if w.pid == pid: return w

for name in getEnv("GUIENV_TARGETS", "sway,gnome").split(','):
  suite "desktop targets — " & name:

    var t: TargetEnvironment

    setup:
      t = newTarget(name)
      t.start()

    teardown:
      t.stop()

    test "facts are measured from the compositor":
      for fact, value in measured[name]:
        checkpoint fact
        check t.fact(fact).value == value
        check t.fact(fact).provenance == fpMeasured

    test "an unknown fact is refused by name, never answered":
      expect EnvError:
        discard t.fact("window.canTeleport")

    test "a window is read back from the compositor":
      let p = t.holdWindow()
      let w = t.byPid(p.processID)
      check w.appId == probeApp
      check wsFloating in w.states
      check w.rect.w == 320 and w.rect.h == 200

    test "a click with the pointer device focuses the window under it":
      # Two windows apart; the desktop focuses the one clicked. Focus is read
      # back from the compositor, so this shows the pointer DEVICE reaches its
      # own input routing at the position the driver named.
      proc placed(pid, x, y: int): EnvWindow =
        t.placeWindow(t.byPid(pid), x, y)
        t.waitUntil("pid " & $pid & " at " & $x & "," & $y, proc(): bool =
          let w = t.byPid(pid)
          w.rect.x == x and w.rect.y == y)
        result = t.byPid(pid)
        discard t.captureSettled(result.rect)
      let first = t.holdWindow().processID
      discard placed(first, 40, 80)
      let second = t.holdWindow().processID
      discard placed(second, 700, 400)
      for target in [first, second, first]:
        t.click(t.byPid(target).rect.center)
        t.waitUntil("pid " & $target & " focused by a click", proc(): bool =
          t.byPid(target).focused)

    test "a capture returns the frame at the requested size":
      let p = t.holdWindow()
      let w = t.byPid(p.processID)
      let img = t.captureSettled(w.rect)
      check img.width == 320 and img.height == 200
      # The probe fills its buffer with 0x80 grey.
      check img.pixel(160, 100) == (0x80'u8, 0x80'u8, 0x80'u8)

    test "a region partly off the output is captured at the size asked, off-screen black":
      let p = t.holdWindow()
      let w = t.byPid(p.processID)
      t.placeWindow(w, 1280 - 100, 300)
      t.waitUntil("placed half off the output", proc(): bool =
        t.byPid(p.processID).rect.x == 1180)
      let r = t.byPid(p.processID).rect
      let img = t.captureSettled(r)
      check (img.width, img.height) == (r.w, r.h)
      check img.pixel(50, 100) == (0x80'u8, 0x80'u8, 0x80'u8)   # on screen
      check img.pixel(r.w - 10, 100) == (0'u8, 0'u8, 0'u8)      # past the edge

    test "fullscreen from the desktop's side":
      let p = t.holdWindow()
      let w = t.byPid(p.processID)
      t.setFullscreen(w, true)
      t.waitUntil("fullscreen", proc(): bool = wsFullscreen in t.byPid(p.processID).states)
      t.setFullscreen(t.byPid(p.processID), false)
      t.waitUntil("restored", proc(): bool = wsFullscreen notin t.byPid(p.processID).states)

    test "key chords and text are injected":
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

    test "operations on a stopped target fail by name":
      t.stop()
      try:
        discard t.windows()
        fail()
      except EnvError as e:
        check e.target == name
        check e.operation == "windows"
      expect EnvError:
        t.pointerMove(10, 10)
