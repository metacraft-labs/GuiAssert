## Attaching a target to a session that is already running.
##
## Build & run (inside `nix develop`, Linux only):
##   nim c -r tests/tdesktop_env_attach.nim     (GUIENV_TARGETS=sway,gnome)
##
## The "running session" is one a headless target starts for the case. The
## attached target is then pointed at it exactly as at a developer's own
## session — through the process environment (`WAYLAND_DISPLAY`,
## `SWAYSOCK`, the session bus) — so the attach path is exercised without
## touching the developer's desktop.
##
## Asserted:
##   * an attached target reads the session's windows back and drives its
##     pointer (a click focuses the window under it);
##   * `configure` is refused unless allowed, by name;
##   * allowed, what it changes is restored by `stop`;
##   * stopping an attached target leaves the session — compositor, windows —
##     running;
##   * GNOME: attaching to a shell whose unsafe mode is off fails by name and
##     names the remedy (unsafe mode is what opens Eval).
##
## MOCKS: none. The sessions are real (sway; GNOME Shell), and so are the
## clients (`wm_probe map hold=MS`).

import std/[os, osproc, strtabs, strutils, unittest]
import gui_assert/desktop_env
import gui_assert/desktop_env/[gnome, helpers, sway]

proc newHost(name: string): TargetEnvironment =
  case name
  of "sway": newSwayTarget(1280, 800)
  of "gnome": newGnomeTarget(1280, 800)
  else: raise newException(ValueError, "unknown target " & name)

proc attach(name: string; allowConfigure = false): TargetEnvironment =
  case name
  of "sway": attachSwayTarget(allowConfigure)
  of "gnome": attachGnomeTarget(allowConfigure)
  else: raise newException(ValueError, "unknown target " & name)

proc byPid(t: TargetEnvironment; pid: int): EnvWindow =
  t.waitUntil("window of pid " & $pid, proc(): bool =
    for w in t.windows():
      if w.pid == pid: return true
    false)
  for w in t.windows():
    if w.pid == pid: return w

for name in getEnv("GUIENV_TARGETS", "sway,gnome").split(','):
  suite "attaching to a running session — " & name:

    var host: TargetEnvironment
    var saved: seq[(string, string, bool)]

    setup:
      host = newHost(name)
      host.start()
      # Into the process environment, as a developer's session would be.
      saved.setLen 0
      for k, v in host.sessionEnv:
        saved.add (k, getEnv(k), existsEnv(k))
        putEnv(k, v)

    teardown:
      host.stop()
      for (k, v, had) in saved:
        if had: putEnv(k, v) else: delEnv(k)

    test "an attached target reads the session's windows and drives its pointer":
      let a = attach(name)
      a.start()
      defer: a.stop()
      let first = host.spawn(@[helper("wm_probe"), "map", "hold=30000"]).processID
      let second = host.spawn(@[helper("wm_probe"), "map", "hold=30000"]).processID
      a.placeWindow(a.byPid(first), 40, 80)
      a.placeWindow(a.byPid(second), 700, 400)
      for pid in [first, second]:
        a.waitUntil("pid " & $pid & " placed", proc(): bool =
          let r = a.byPid(pid).rect
          (r.x, r.y) in [(40, 80), (700, 400)])
        discard a.captureSettled(a.byPid(pid).rect)
      for pid in [first, second, first]:
        a.click(a.byPid(pid).rect.center)
        a.waitUntil("pid " & $pid & " focused", proc(): bool = a.byPid(pid).focused)

    test "configure is refused unless allowed":
      let a = attach(name)
      a.start()
      defer: a.stop()
      try:
        a.configure("buttonLayout", "close:")
        fail()
      except EnvError as e:
        check e.operation == "configure buttonLayout"
        check "refused" in e.msg

    test "allowed, what configure changes is restored by stop":
      let previous = host.fact("buttonLayout").value
      let a = attach(name, allowConfigure = true)
      a.start()
      a.configure("buttonLayout", "close:")
      a.configure("buttonLayout", "close,minimize:")
      check host.fact("buttonLayout").value == "close,minimize:"
      a.stop()
      check host.fact("buttonLayout").value == previous

    test "stopping an attached target leaves the session running":
      let p = host.spawn(@[helper("wm_probe"), "map", "hold=30000"]).processID
      let a = attach(name)
      a.start()
      discard a.byPid(p)
      a.stop()
      # The compositor still answers, and the window is still there.
      check host.byPid(p).pid == p
      check host.windows().len >= 1

    if name == "sway":
      test "an attached sway target holds no keyboard on the seat":
        # desktop_env/sway "Why a held keyboard": a target that owns its
        # sway holds one keyboard on the seat for its lifetime; an attached
        # target never adds one to a session that is not its own (the seat
        # is its owner's), and when it stops the seat is as it was.
        proc keyboards(): int =
          let (o, code) = execCmdEx("swaymsg -t get_inputs -r")
          doAssert code == 0, o
          o.count("\"type\": \"keyboard\"")
        check keyboards() == 1      # the host target's own held keyboard
        let a = attach(name)
        a.start()
        let p = host.spawn(@[helper("wm_probe"), "map", "hold=30000"]).processID
        a.click(a.byPid(p).rect.center)
        check keyboards() == 1
        a.stop()
        check keyboards() == 1

    if name == "gnome":
      test "attaching without unsafe mode fails by name and names the remedy":
        discard GnomeTarget(host).eval("(global.context.unsafe_mode = false, 1)")
        try:
          attach(name).start()
          fail()
        except EnvError as e:
          check e.target == "gnome"
          check e.operation == "start"
          check "unsafe mode" in e.msg.toLowerAscii
