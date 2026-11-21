## The Linux live input suite (GS8): the REAL `guiassert` binary with the
## Linux input backends driving invented GTK 3, GTK 4 and Qt 6 forms in
## display servers this suite starts for itself, never the operator's
## (spec §4.2, §5, §7.5, §8.5, §9.3):
##
## * a private **headless sway** at scale 1 (`linux-wlr-virtual`: GTK 3,
##   GTK 4 and Qt 6 Wayland clients) and at **scale 2** (GTK 3);
## * a private **Xvfb** (`linux-xtest`: GTK 3, GTK 4 and Qt 6 X11 clients);
## * a private **headless GNOME Shell** with PipeWire running in it, as in
##   every GNOME session (`linux-mutter`: GTK 4);
## * `linux-uinput`, whose refusal without access to /dev/uinput is proved
##   on this host.
##
## Each session has its own session bus and AT-SPI bus, and **every effect is
## read back** through what the application reports, not through what
## GuiAssert sent: the `linux-atspi` tree (GS7) for the form's fields, the
## status label Submit adds and the "Level" slider's value, and the form's
## own input log for the events its "Sketch pad" and "Key log" canvases
## received (`fixtures/atspi_form.c --input-log`: presses with their click
## count and modifiers, the pointer trail with the button held, scroll
## deltas, and every key press with its keyval and modifiers).
##
## **What is checked** (the GS8 Linux verification entries):
##
## * click, scroll and drag reach the fixture (sway, each toolkit; GNOME;
##   X11), with a negative control each: no status label before Submit is
##   pressed and none after a click beside it; the slider unchanged by a
##   scroll beside it;
## * typing sets a field's value (any Unicode on wlroots and X11, through a
##   borrowed key code on X11; the session layout's characters on GNOME,
##   where a character outside it is exit 4 with nothing typed), from the
##   argument and from `--stdin`;
## * C8: every named key, function key, modifier (each spelling) and alias of
##   the key table, and printable characters, reach the key log as that key
##   on every backend;
## * C17: `drag --path` waypoints reach the canvas in order with the button
##   held, and the report's path is the requested vertices;
## * GADV-1: a `gesture`'s presses, moves, releases and held keys arrive in
##   order, what it leaves held is released when it ends, and `drag
##   --modifiers` holds them for the whole drag;
## * C7: each backend's pointer-input, keyboard-input and window-management
##   with probed states; exit 4 / 6 envelopes name their feature; the input
##   default follows the session;
## * scale 2: desktop coordinates are logical, a click at the tree's bounds
##   hits and the canvas receives exactly the requested points;
## * linux-uinput without write access to /dev/uinput is exit 6 /
##   `uinput-access` naming the device for every input verb;
## * C15: typed text is never in any process's argv, on stderr, in a serve
##   event or in a state record; spec §8.5: two `type` requests of one serve
##   session are typed one after the other, never interleaved;
## * window-focus and window-set-bounds on sway, X11 and GNOME.
##
## **The uinput positive control** needs write access to /dev/uinput, which
## this host does not grant without an operator: it runs only when
## `GUIASSERT_LIVE_UINPUT=1` is set, and then FAILS unless the device is
## writable (printing `GS8-LINUX BLOCKED: uinput device access needs
## operator`); without the variable the suite prints that line and registers
## no such test, so nothing is reported as skipped or passed for it.
##
## Stand-ins: none. A server, bus or fixture that cannot start fails every
## test that needs it with a `GS8-LINUX BLOCKED:` line; nothing here skips.

when not defined(linux):
  {.error: "tests/live/tinput_linux.nim runs on Linux only".}

import std/[json, os, osproc, sequtils, streams, strtabs, strutils, tables, times, unicode,
            unittest]
from std/posix import nil

import ../contract/harness
import ./linux_live
import ../../src/gui_assert/desktop_env/session_bus

const
  appName = "guiassert-form"
  qtName = "guiassert-form-qt"
  secret = "quartz-heron-5521-ünïcode"
    ## Invented; typed through every route that must not leak it.

proc gs8(msg: string): string = msg.replace("GS5-LINUX BLOCKED", "GS8-LINUX BLOCKED")

template live(problem: string, body: untyped) =
  ## Run `body` when the suite's server started; otherwise FAIL with the
  ## BLOCKED line (never skip).
  if problem.len > 0:
    checkpoint problem
    echo "  ", problem
    fail()
  else:
    body

template setUp(problem: var string, body: untyped) =
  try:
    body
  except AssertionDefect, CatchableError:
    problem = gs8(getCurrentExceptionMsg())
    if "BLOCKED" notin problem: problem = "GS8-LINUX BLOCKED: " & problem

var outputs: seq[string]
  ## Every stdout and stderr of every run, for "the secret never appears".

template mustRun(args: seq[string], env: StringTableRef): JsonNode =
  ## The data of a successful run, its stderr empty. A template, so a failed
  ## `check` counts against the test.
  block:
    let r = runCli(args, env, timeoutMs = 120_000)
    outputs.add r.stdout
    outputs.add r.stderr
    if r.exit != 0: checkpoint "guiassert " & args.join(" ") & " -> " & r.stdout & r.stderr
    check r.exit == 0
    check r.stderr == ""
    let e = envelopeOf(r)
    (if e["ok"].getBool: e["data"] else: newJObject())

template failsWith(args: seq[string], env: StringTableRef, code: int, reason: string): JsonNode =
  block:
    let r = runCli(args, env, timeoutMs = 120_000)
    outputs.add r.stdout
    outputs.add r.stderr
    let e = envelopeOf(r)
    if r.exit != code: checkpoint "guiassert " & args.join(" ") & " -> " & $e & r.stderr
    check r.exit == code
    check r.stderr == ""
    check e["ok"].getBool == false
    if e["ok"].getBool == false:
      check e["error"]["reason"].getStr == reason
      e["error"]
    else: newJObject()

proc okRun(args: seq[string], env: StringTableRef): JsonNode =
  ## The data of a run that must succeed, outside a test (session setup).
  let r = runCli(args, env, timeoutMs = 120_000)
  if r.exit != 0:
    raise blocked("guiassert " & args.join(" ") & " failed: " & r.stdout & r.stderr)
  envelopeOf(r)["data"]

proc runWithStdin(args: seq[string], env: StringTableRef, input: string):
    tuple[exit: int, stdout, stderr: string] =
  let p = startProcess(contractBin(), args = args, env = env, options = {})
  try:
    p.inputStream.write(input)
    p.inputStream.close()
    result.exit = p.waitForExit(60_000)
    result.stdout = p.outputStream.readAll()
    result.stderr = p.errorStream.readAll()
  finally:
    p.close()
  outputs.add result.stdout
  outputs.add result.stderr

# ---------------------------------------------------------------------------
# The fixture
# ---------------------------------------------------------------------------

type
  Box = tuple[x, y, w, h: int]
  Lab = object
    pid: int
    kit: string
    title: string
    log: string              ## its input log ("" for the Qt form)
    windowId: string

var launched: seq[int]

proc boxOf(j: JsonNode): Box = (j[0].getInt, j[1].getInt, j[2].getInt, j[3].getInt)
proc centre(b: Box): (int, int) = (b.x + b.w div 2, b.y + b.h div 2)
proc at(p: (int, int)): string = $p[0] & "," & $p[1]

proc launchLab(env: StringTableRef, exe, kit, display, work: string, name = appName,
               extra: seq[string] = @[]): Lab =
  ## The form (with its input lab unless it is the Qt form) through `guiassert
  ## app-launch`, once its Submit button is on the AT-SPI bus.
  result.kit = kit
  result.title = "Input Lab " & nonce()
  var args = @["app-launch", "--wait-window-ms", "30000"]
  if kit == "qt6":
    let plugins = getEnv("GUI_ASSERT_QT_PLUGIN_PATH")
    if not dirExists(plugins / "platforms"):
      raise blocked("GUI_ASSERT_QT_PLUGIN_PATH names no Qt plugins (run inside `nix develop`)")
    args.add @["--env", "QT_PLUGIN_PATH=" & plugins, "--env",
               "QT_QPA_PLATFORM=" & (if display == "x11": "xcb" else: "wayland")]
  else:
    args.add @["--env", "GDK_BACKEND=" & display, "--env", "GSK_RENDERER=cairo"]
    result.log = work / ("input-" & nonce() & ".log")
  args.add @["--", exe, "--title", result.title, "--name", name]
  if result.log.len > 0: args.add @["--input-log", result.log]
  args.add extra
  let r = runCli(args, env, timeoutMs = 60_000)
  if r.exit != 0: raise blocked("the " & kit & " fixture did not start: " & r.stdout & r.stderr)
  let d = envelopeOf(r)["data"]
  result.pid = d["app"]["pid"].getInt
  launched.add result.pid
  if d["window"].kind == JObject: result.windowId = d["window"]["id"].getStr
  let deadline = epochTime() + 30
  while true:
    let mine = runCli(@["find", "--pid", $result.pid, "--role", "button", "--name", "Submit"],
                      env)
    if mine.exit == 0 and envelopeOf(mine)["data"]["elements"].len == 1: break
    if epochTime() > deadline:
      raise blocked("the " & kit & " fixture never reached the AT-SPI bus: " & mine.stdout)
    sleep(200)

proc quitAll() =
  var pids = launched
  launched.setLen 0
  terminateAll(pids)

proc element(env: StringTableRef, pid: int, name: string, role = ""): JsonNode =
  var args = @["find", "--pid", $pid, "--name", name]
  if role.len > 0: args.add @["--role", role]
  let r = runCli(args, env, timeoutMs = 60_000)
  doAssert r.exit == 0, "find " & name & ": " & r.stdout & r.stderr
  let es = envelopeOf(r)["data"]["elements"]
  doAssert es.len == 1, "not one element named " & name & ": " & $es
  es[0]

proc boundsOf(env: StringTableRef, pid: int, name: string, role = ""): Box =
  boxOf(element(env, pid, name, role)["bounds"])

proc valueOf(env: StringTableRef, pid: int, name, role: string): string =
  element(env, pid, name, role)["value"].getStr

proc statusCount(env: StringTableRef, pid: int): int =
  let r = runCli(@["find", "--pid", $pid, "--role", "label", "--name-contains", "Submitted"],
                 env, timeoutMs = 60_000)
  doAssert r.exit == 0, r.stdout
  envelopeOf(r)["data"]["elements"].len

proc logLines(path: string): seq[string] =
  try:
    for l in readFile(path).splitLines:
      if l.len > 0: result.add l
  except IOError: discard

proc waitLog(path: string, atLeast: int, ms = 5000): seq[string] =
  ## The log once it has `atLeast` lines, or as it is after `ms`.
  let deadline = epochTime() + ms / 1000
  while true:
    result = logLines(path)
    if result.len >= atLeast or epochTime() > deadline: return
    sleep(30)

proc settle(path: string): seq[string] =
  ## The log once no line arrived for 300 ms.
  var last = -1
  while true:
    result = logLines(path)
    if result.len == last: return
    last = result.len
    sleep(300)

# ---------------------------------------------------------------------------
# Shared checks
# ---------------------------------------------------------------------------

template checkClickScrollDrag(env: StringTableRef, f: Lab) =
  ## Click, scroll and drag reach the fixture; read back through AT-SPI.
  block:
    let wb = boxOf(mustRun(@["windows", "--pid", $f.pid], env)["windows"][0]["bounds"])
    let submit = boundsOf(env, f.pid, "Submit", "button")
    # Negative control: nothing pressed yet, and a click just above the
    # button (the button spans the window's width).
    check statusCount(env, f.pid) == 0
    check wb.w > 0
    discard mustRun(@["click", "--at", at((submit.x + submit.w div 2, submit.y - 4))], env)
    sleep(400)
    check statusCount(env, f.pid) == 0
    let c = mustRun(@["click", "--at", at(centre(submit))], env)["input"]
    check c["kind"].getStr == "click"
    check c["at"] == %*[centre(submit)[0], centre(submit)[1]]
    check c["button"].getStr == "left" and c["count"].getInt == 1
    check c["delivery"].getStr == "injected" and c["session"].getStr == "host"
    check c["length"].kind == JNull and c["path"].kind == JNull
    let w = mustRun(@["wait", "--element", "--pid", $f.pid, "--role", "label",
                      "--name-contains", "Submitted", "--wait-ms", "10000"], env)
    check w["matched"].getBool
    # Scroll: the slider's value, read through AT-SPI, changes under the
    # pointer and not beside it.
    let level = boundsOf(env, f.pid, "Level", "slider")
    let pad = boundsOf(env, f.pid, "Sketch pad")
    discard mustRun(@["element-action", element(env, f.pid, "Level", "slider")["path"].getStr,
                      "set-value", "--value", "50"], env)
    check valueOf(env, f.pid, "Level", "slider") == "50"
    let s0 = mustRun(@["scroll", "--at", at(centre(pad)), "--dx", "0", "--dy", "3"], env)
    check s0["input"]["kind"].getStr == "scroll"
    sleep(300)
    check valueOf(env, f.pid, "Level", "slider") == "50"
    discard mustRun(@["scroll", "--at", at(centre(level)), "--dx", "0", "--dy", "3"], env)
    var moved = ""
    for _ in 1 .. 20:
      moved = valueOf(env, f.pid, "Level", "slider")
      if moved != "50": break
      sleep(100)
    checkpoint "slider after scroll: " & moved
    check moved != "50"
    # Drag: the slider's knob, from its value, to the right end.
    discard mustRun(@["element-action", element(env, f.pid, "Level", "slider")["path"].getStr,
                      "set-value", "--value", "0"], env)
    sleep(200)
    let d = mustRun(@["drag", "--from", at((level.x + 6, level.y + level.h div 2)),
                      "--to", at((level.x + level.w - 2, level.y + level.h div 2)),
                      "--steps", "8", "--duration-ms", "400"], env)["input"]
    check d["kind"].getStr == "drag"
    check d["path"].len == 2
    var dragged = 0.0
    for _ in 1 .. 20:
      dragged = parseFloat(valueOf(env, f.pid, "Level", "slider"))
      if dragged >= 90: break
      sleep(100)
    checkpoint "slider after drag: " & $dragged
    check dragged >= 90

template checkType(env: StringTableRef, f: Lab, text: string) =
  ## Typing sets the Display name field (read through AT-SPI), from the
  ## argument and from `--stdin`; nothing reaches the other field.
  block:
    let field = boundsOf(env, f.pid, "Display name", "text-field")
    let path = element(env, f.pid, "Display name", "text-field")["path"].getStr
    discard mustRun(@["element-action", path, "set-value", "--value", ""], env)
    check valueOf(env, f.pid, "Display name", "text-field") == ""
    discard mustRun(@["click", "--at", at(centre(field))], env)
    sleep(200)
    let t = mustRun(@["type", text], env)["input"]
    check t["kind"].getStr == "type"
    check t["length"].getInt == text.runeLen
    check text notin $t
    var v = ""
    for _ in 1 .. 30:
      v = valueOf(env, f.pid, "Display name", "text-field")
      if v == text: break
      sleep(100)
    check v == text
    discard mustRun(@["element-action", path, "set-value", "--value", ""], env)
    discard mustRun(@["click", "--at", at(centre(field))], env)
    sleep(200)
    let r = runWithStdin(@["type", "--stdin", "--interval-ms", "5"], env, text & "!")
    check r.exit == 0 and r.stderr == ""
    for _ in 1 .. 30:
      v = valueOf(env, f.pid, "Display name", "text-field")
      if v == text & "!": break
      sleep(100)
    check v == text & "!"
    check valueOf(env, f.pid, "Delivery notes", "text-area") == "Leave the parcel at the side door."

proc focusKeyLog(env: StringTableRef, f: Lab) =
  let kl = boundsOf(env, f.pid, "Key log")
  let r = runCli(@["click", "--at", at(centre(kl))], env, timeoutMs = 60_000)
  doAssert r.exit == 0, r.stdout
  sleep(300)

proc expectedKeyLine(canonical: string): string =
  ## The fixture's log name for a key of the table: its keyval name for a
  ## named or function key, its character for a printable one.
  case canonical
  of "Space": "key space U+0020"
  of "PageUp": "key Page_Up -"
  of "PageDown": "key Page_Down -"
  else:
    if canonical.runeLen == 1:
      "U+" & toHex(int(canonical.toLower.runeAt(0)), 4)
    else: "key " & canonical & " -"

template checkEveryKey(env: StringTableRef, f: Lab, nonLayout: bool) =
  ## C8: every key of the table, under every spelling, reaches the key log
  ## as that key. `nonLayout`: the backend types characters outside the
  ## session's layout too (else they are exit 4, nothing delivered).
  block:
    focusKeyLog(env, f)
    var named = @[("Return", "Return"), ("Enter", "Return"), ("enter", "Return"),
                  ("Tab", "Tab"), ("Escape", "Escape"), ("Esc", "Escape"),
                  ("BackSpace", "BackSpace"), ("Delete", "Delete"), ("Insert", "Insert"),
                  ("Space", "Space"), ("space", "Space"), ("Home", "Home"), ("End", "End"),
                  ("PageUp", "PageUp"), ("pagedown", "PageDown"), ("Pause", "Pause"),
                  ("Up", "Up"), ("Down", "Down"), ("Left", "Left"), ("RIGHT", "Right")]
    for n in 1 .. 24: named.add ("F" & $n, "F" & $n)
    named.add ("f7", "F7")
    for ch in ["a", "z", "A", "Q", "0", "9", "+", "-", ".", "/", "~", "[", "@"]:
      named.add (ch, ch)
    for (spelled, canonical) in named:
      let before = logLines(f.log).len
      let r = mustRun(@["key", spelled], env)["input"]
      check r["keys"].getStr == (if canonical.runeLen == 1: canonical.toLower else: canonical)
      let lines = waitLog(f.log, before + 1)
      checkpoint "key " & spelled & " -> " & $lines[before .. ^1]
      check lines.len == before + 1 or (lines.len == before + 2 and
                                        lines[before].startsWith("key Shift_L"))
      if lines.len > before:
        let last = lines[^1]
        check expectedKeyLine(canonical) in last
        # A character on the shift level of an X11 or US key comes with
        # Shift; nothing else carries a modifier.
        check last.endsWith(" -") or (canonical.runeLen == 1 and last.endsWith(" s"))
    # Modifiers, under each spelling, held around a key.
    for (spelled, sym, letter) in [("ctrl", "Control_L", "c"), ("control", "Control_L", "c"),
                                   ("alt", "Alt_L", "a"), ("option", "Alt_L", "a"),
                                   ("shift", "Shift_L", "s"),
                                   ("cmd", "Super_L", "m"), ("command", "Super_L", "m"),
                                   ("meta", "Super_L", "m"), ("super", "Super_L", "m"),
                                   ("win", "Super_L", "m")]:
      for key in ["a", "F13"]:
        let before = logLines(f.log).len
        let r = mustRun(@["key", spelled & "+" & key], env)["input"]
        check r["keys"].getStr == sym.split('_')[0].toLowerAscii.replace("control", "ctrl")
                                    .replace("super", "cmd") & "+" & key
        let lines = waitLog(f.log, before + 2)
        checkpoint spelled & "+" & key & " -> " & $lines[before .. ^1]
        check lines.len == before + 2
        if lines.len == before + 2:
          check lines[before].startsWith("key " & sym & " ")
          let want = if key == "a": "key a U+0061 " else: "key F13 - "
          check lines[before + 1] == want & letter
    # Two modifiers at once, in the table's order whatever the spelling.
    block:
      let before = logLines(f.log).len
      let r = mustRun(@["key", "SHIFT+Control+Tab"], env)["input"]
      check r["keys"].getStr == "ctrl+shift+Tab"
      let lines = waitLog(f.log, before + 3)
      check lines.len == before + 3
      if lines.len == before + 3:
        check lines[before].startsWith("key Control_L")
        check lines[before + 1].startsWith("key Shift_L")
        check lines[before + 2] == "key Tab - cs" or lines[before + 2] == "key ISO_Left_Tab - cs"
    # Characters outside an ASCII layout.
    let before = logLines(f.log).len
    if nonLayout:
      discard mustRun(@["key", "é"], env)
      discard mustRun(@["key", "中"], env)
      let lines = waitLog(f.log, before + 2)
      check lines.len == before + 2
      if lines.len == before + 2:
        check "U+00E9" in lines[before]
        check "U+4E2D" in lines[before + 1]
    else:
      let e = failsWith(@["key", "é"], env, 4, "unsupported-option")
      check e["details"]["feature"].getStr == "keyboard-input"
      sleep(300)
      check logLines(f.log).len == before
    # Unknown names are refused before any backend runs.
    discard failsWith(@["key", "Hyper+a"], env, 2, "invalid-value")
    discard failsWith(@["key", "F25"], env, 2, "invalid-value")
    discard failsWith(@["key", "ctrl+control+a"], env, 2, "invalid-value")

template checkDragPath(env: StringTableRef, f: Lab) =
  ## C17: every waypoint of `drag --path` reaches the canvas in order with
  ## the button held; the report's path is the requested vertices.
  block:
    let pad = boundsOf(env, f.pid, "Sketch pad")
    let pts = @[(pad.x + 12, pad.y + 10), (pad.x + 60, pad.y + 15), (pad.x + 75, pad.y + 90),
                (pad.x + 150, pad.y + 40), (pad.x + 210, pad.y + 100), (pad.x + 280, pad.y + 20)]
    let before = logLines(f.log).len
    var waypoints: seq[string]
    for p in pts[1 .. ^2]: waypoints.add at(p)
    let d = mustRun(@["drag", "--from", at(pts[0]), "--to", at(pts[^1]), "--path",
                      waypoints.join(";"), "--steps", "2", "--duration-ms", "800"], env)["input"]
    check d["kind"].getStr == "drag"
    var want = newJArray()
    for p in pts: want.add %*[p[0], p[1]]
    check d["path"] == want
    check d["at"] == want[0] and d["to"] == want[^1]
    let lines = settle(f.log)[before .. ^1]
    checkpoint "canvas: " & $lines
    check lines.len >= 3
    if lines.len >= 3:
      check lines[0].startsWith("press 1 1 " & $(pts[0][0] - pad.x) & " " & $(pts[0][1] - pad.y))
      check lines[^1] == "release 1 " & $(pts[^1][0] - pad.x) & " " & $(pts[^1][1] - pad.y)
      # The trail passes every vertex, in order, with nothing after the
      # release and no motion without the button.
      var i = 1
      for p in pts[1 .. ^1]:
        let want = "trail " & $(p[0] - pad.x) & " " & $(p[1] - pad.y)
        while i < lines.len - 1 and lines[i] != want: inc i
        checkpoint "vertex " & want
        check i < lines.len - 1
        inc i
      for l in lines[1 .. ^2]: check l.startsWith("trail ")

template checkGestureAndModifiedDrag(env: StringTableRef, f: Lab) =
  ## GADV-1: a gesture's presses, moves, releases and held keys reach the
  ## application in order; what a gesture leaves held is released when it
  ## ends; a drag holds its modifiers for the whole gesture.
  block:
    let pad = boundsOf(env, f.pid, "Sketch pad")
    let a = (pad.x + 30, pad.y + 30)
    let b = (pad.x + 120, pad.y + 70)
    proc local(p: (int, int)): string = $(p[0] - pad.x) & " " & $(p[1] - pad.y)
    proc pointerLines(from0: int): seq[string] =
      settle(f.log)[from0 .. ^1].filterIt(it.startsWith("press") or it.startsWith("release"))
    # a press here and a release there, the pointer moving with the button down
    var before = logLines(f.log).len
    let c = (pad.x + 200, pad.y + 20)   # off the line from a to b
    # a pause after each move: back-to-back motion is coalesced by the toolkit,
    # as it is for a real pointer
    let g = mustRun(@["gesture", "--steps", "press " & at(a) & "; wait 60; move " & at(c) &
                      "; wait 60; release " & at(b)], env)["input"]
    check g["kind"].getStr == "gesture"
    check g["path"] == %*[[a[0], a[1]], [c[0], c[1]], [b[0], b[1]]]
    var lines = settle(f.log)[before .. ^1]
    checkpoint "gesture: " & $lines
    check lines.len >= 3
    if lines.len >= 3:
      check lines[0] == "press 1 1 " & local(a) & " -"
      check ("trail " & local(c)) in lines
      check ("trail " & local(b)) in lines
      check lines[^1] == "release 1 " & local(b)
    # a key held between steps modifies the presses inside it, and only those
    before = logLines(f.log).len
    discard mustRun(@["gesture", "--steps", "key-down shift; press " & at(a) & " right; release " &
                      at(a) & " right; key-up shift; wait 50; press " & at(b) & "; release " & at(b)], env)
    lines = pointerLines(before)
    checkpoint "held key: " & $lines
    check lines == @["press 3 1 " & local(a) & " s", "release 3 " & local(a),
                     "press 1 1 " & local(b) & " -", "release 1 " & local(b)]
    # what a gesture leaves held is released when it ends
    before = logLines(f.log).len
    discard mustRun(@["gesture", "--steps", "key-down ctrl; press " & at(a)], env)
    lines = pointerLines(before)
    check lines == @["press 1 1 " & local(a) & " c", "release 1 " & local(a)]
    discard mustRun(@["click", "--at", at(b)], env)
    check pointerLines(before)[^2] == "press 1 1 " & local(b) & " -"
    # a drag with modifiers: they are down from the press to the release
    before = logLines(f.log).len
    let d = mustRun(@["drag", "--from", at(a), "--to", at(b), "--modifiers", "shift",
                      "--steps", "3"], env)["input"]
    check d["keys"].getStr == "shift"
    lines = pointerLines(before)
    check lines == @["press 1 1 " & local(a) & " s", "release 1 " & local(b)]
    discard failsWith(@["gesture", "--steps", "press " & at(a) & " thumb"], env, 2, "invalid-value")
    discard failsWith(@["gesture", "--steps", "hover " & at(a)], env, 2, "invalid-value")
    discard failsWith(@["drag", "--from", at(a), "--to", at(b), "--modifiers", "hyper"], env, 2,
                      "invalid-value")

template checkClickDetails(env: StringTableRef, f: Lab) =
  ## Buttons, click counts and modifiers held around a click reach the canvas.
  block:
    let pad = boundsOf(env, f.pid, "Sketch pad")
    let p = (pad.x + 40, pad.y + 50)
    let local = $(p[0] - pad.x) & " " & $(p[1] - pad.y)
    var before = logLines(f.log).len
    let c = mustRun(@["click", "--at", at(p), "--count", "2", "--modifiers", "shift,CTRL"],
                    env)["input"]
    check c["count"].getInt == 2 and c["keys"].getStr == "ctrl+shift"
    var lines = settle(f.log)[before .. ^1].filterIt(it.startsWith("press") or
                                                     it.startsWith("release"))
    checkpoint $lines
    # GTK 3 reports the second press twice (as a press, then as a double
    # press); GTK 4 once, with its count.
    check lines.len >= 4
    if lines.len >= 4:
      check lines[0] == "press 1 1 " & local & " cs"
      check "press 1 2 " & local & " cs" in lines
      check lines.countIt(it == "release 1 " & local) == 2
      check lines.allIt(it.endsWith(" cs") or it.startsWith("release"))
    before = logLines(f.log).len
    discard mustRun(@["click", "--at", at(p), "--button", "right"], env)
    discard mustRun(@["click", "--at", at(p), "--button", "middle"], env)
    lines = settle(f.log)[before .. ^1]
    check lines == @["press 3 1 " & local & " -", "release 3 " & local,
                     "press 2 1 " & local & " -", "release 2 " & local]

template checkScrollDirections(env: StringTableRef, f: Lab, pixel: bool) =
  ## Positive --dy scrolls down, positive --dx right; lines are notches.
  block:
    let pad = boundsOf(env, f.pid, "Sketch pad")
    let p = at(centre(pad))
    var before = logLines(f.log).len
    discard mustRun(@["scroll", "--at", p, "--dx", "0", "--dy", "2"], env)
    discard mustRun(@["scroll", "--at", p, "--dx", "-1", "--dy", "0"], env)
    var lines = settle(f.log)[before .. ^1]
    checkpoint $lines
    let downs = lines.filterIt(it.startsWith("scroll 0.00 ") and
                               parseFloat(it.split(' ')[2]) > 0)
    let lefts = lines.filterIt(it.startsWith("scroll -") and it.endsWith(" 0.00"))
    check downs.len == 2
    check lefts.len == 1
    check lines.len == 3
    if pixel:
      before = logLines(f.log).len
      discard mustRun(@["scroll", "--at", p, "--dx", "0", "--dy", "-30", "--unit", "pixel"], env)
      lines = settle(f.log)[before .. ^1]
      checkpoint $lines
      check lines.len >= 1
      check lines.allIt(it.startsWith("scroll 0.00 -"))

proc featureOf(caps: JsonNode, name: string): JsonNode =
  for f in caps["features"]:
    if f["feature"].getStr == name: return f
  newJNull()

template checkFeatures(env: StringTableRef, backend: string, windows = "supported") =
  ## C7: the session's input default and its probed features.
  block:
    let caps = mustRun(@["capabilities"], env)
    check caps["selected"]["input"].getStr == backend
    for name in ["pointer-input", "keyboard-input", "window-management"]:
      let x = featureOf(caps, name)
      check x["backend"].getStr == backend
      check x["state"].getStr == "available"
    let probed = mustRun(@["capabilities", "--probe"], env)
    for name in ["pointer-input", "keyboard-input"]:
      check featureOf(probed, name)["state"].getStr == "supported"
      check featureOf(probed, name)["reason"].kind == JNull
    check featureOf(probed, "window-management")["state"].getStr == windows

template checkWindowManagement(env: StringTableRef, f, g: Lab, target: (int, int, int, int)) =
  ## window-set-bounds places a window where the window server then reports
  ## it; window-focus gives the focus to one window, then to the other.
  block:
    let r = mustRun(@["window-set-bounds", f.windowId, "--bounds",
                      $target[0] & "," & $target[1] & "," & $target[2] & "," & $target[3]],
                    env)
    check r["window"]["id"].getStr == f.windowId
    check r["requested"] == %*[target[0], target[1], target[2], target[3]]
    let ws = mustRun(@["windows", "--pid", $f.pid], env)["windows"]
    check ws.len == 1
    if ws.len == 1:
      check ws[0]["bounds"][0].getInt == target[0] and ws[0]["bounds"][1].getInt == target[1]
      check r["window"]["bounds"] == ws[0]["bounds"]
    let a = mustRun(@["window-focus", g.windowId], env)["window"]
    check a["focused"].getBool
    check not mustRun(@["windows", "--pid", $f.pid], env)["windows"][0]["focused"].getBool
    let b = mustRun(@["window-focus", f.windowId], env)["window"]
    check b["focused"].getBool
    check not mustRun(@["windows", "--pid", $g.pid], env)["windows"][0]["focused"].getBool
    discard failsWith(@["window-focus", "987654321"], env, 3, "window")

# ---------------------------------------------------------------------------
# Session setup
# ---------------------------------------------------------------------------

proc place(t: SwayTarget, f: Lab, x, y: int) =
  let w = t.waitPidWindow(f.pid)
  t.placeWindow(w, x, y)
  t.waitUntil("the window moved", proc(): bool =
    let r = t.waitPidWindow(f.pid).rect
    r.x == x and r.y == y)
  sleep(400)

proc gsettingsIn(session: StringTableRef, schema, key, value: string) =
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs(): env[k] = v
  for k, v in session: env[k] = v
  let (o, code) = execCmdEx(quoteShellCommand(["gsettings", "set", schema, key, value]),
                            env = env)
  if code != 0: raise blocked("gsettings set " & schema & " " & key & ": " & o.strip)

# ---------------------------------------------------------------------------
# linux-uinput (no session needed: the device is the host's)
# ---------------------------------------------------------------------------

let uinputWritable = posix.access("/dev/uinput", posix.W_OK) == 0

suite "linux-uinput":
  let st = freshDir("input-uinput-state")

  # With GUIASSERT_LIVE_UINPUT=1 on a host whose /dev/uinput IS writable,
  # the refusal cannot happen here: the positive control below runs instead
  # (and the refusal stays proved by the runs on hosts without access).
  let positiveRun = getEnv("GUIASSERT_LIVE_UINPUT") == "1"
  if positiveRun and uinputWritable:
    echo "  linux-uinput: /dev/uinput is writable, so only the positive control runs"
  else:
    test "test_uinput_without_device_access_is_exit_6":
      # The refusal case is this host's: /dev/uinput is root's alone.
      checkpoint "/dev/uinput writable: " & $uinputWritable
      check not uinputWritable
      var env = runEnv(st, newStringTable(modeCaseSensitive),
                       [("GUIASSERT_INPUT_BACKEND", "linux-uinput")])
      for (argv, feature) in [(@["click", "--at", "10,10"], "pointer-input"),
                              (@["move", "--to", "10,10"], "pointer-input"),
                              (@["drag", "--from", "1,1", "--to", "5,5"], "pointer-input"),
                              (@["scroll", "--at", "1,1", "--dx", "0", "--dy", "1"], "pointer-input"),
                              (@["type", secret], "keyboard-input"),
                              (@["key", "ctrl+a"], "keyboard-input")]:
        let e = failsWith(argv, env, 6, "uinput-access")
        check e["kind"].getStr == "permission-denied"
        check e["details"]["feature"].getStr == feature
        check e["details"]["backend"].getStr == "linux-uinput"
        check "/dev/uinput" in e["remedy"].getStr
        check "/dev/uinput" in e["message"].getStr
        check secret notin $e
      let w = failsWith(@["window-focus", "1"], env, 4, "unsupported-option")
      check w["details"]["feature"].getStr == "window-management"
      for probe in [false, true]:
        let caps = mustRun(if probe: @["capabilities", "--probe"] else: @["capabilities"], env)
        check caps["selected"]["input"].getStr == "linux-uinput"
        for name in ["pointer-input", "keyboard-input"]:
          let x = featureOf(caps, name)
          check x["state"].getStr == "unavailable"
          check x["reason"].getStr == "uinput-access"
          check "/dev/uinput" in x["remedy"].getStr
        check featureOf(caps, "window-management")["state"].getStr == "unavailable"
      # A character the US layout has no key for is refused before the device
      # is touched only when the device is writable; here access is first.
      check failsWith(@["type", "é"], env, 6, "uinput-access")["details"]["feature"].getStr ==
        "keyboard-input"

  if positiveRun:
    test "test_uinput_with_device_access_delivers_and_reports_injected":
      # The negative control of the entry above: with access granted the
      # same click is delivered (run where the operator granted access, in a
      # session whose compositor reads the host's devices).
      if not uinputWritable:
        echo "  GS8-LINUX BLOCKED: uinput device access needs operator"
        checkpoint "GS8-LINUX BLOCKED: uinput device access needs operator"
        fail()
      else:
        var env = runEnv(st, newStringTable(modeCaseSensitive),
                         [("GUIASSERT_INPUT_BACKEND", "linux-uinput")])
        for (k, v) in envPairs():
          if k in ["WAYLAND_DISPLAY", "DISPLAY", "SWAYSOCK", "XDG_RUNTIME_DIR"]: env[k] = v
        let c = mustRun(@["click", "--at", "10,10"], env)["input"]
        check c["delivery"].getStr == "injected"
  else:
    echo "  GS8-LINUX BLOCKED: uinput device access needs operator (the positive " &
      "control runs with GUIASSERT_LIVE_UINPUT=1 where /dev/uinput is writable)"

# ---------------------------------------------------------------------------
# A private headless sway at scale 1
# ---------------------------------------------------------------------------

suite "linux-wlr-virtual in a private headless sway":
  let st = freshDir("input-sway-state")
  let work = freshDir("input-sway-work")
  let t = newSwayTarget(1600, 1000, floatingAppIds = @[appName, qtName])
  var bus: AtspiBus
  var problem = ""
  var f3, f4, fq: Lab
  var env: StringTableRef
  setUp(problem):
    let gtk3 = buildFormFixture(work, 3)
    let gtk4 = buildFormFixture(work, 4)
    let qt6 = buildQtFixture(work)
    t.startTarget()
    bus = startAtspiBus(t.sessionEnv)
    env = runEnv(st, t.sessionEnv)
    f3 = launchLab(env, gtk3, "gtk3", "wayland", work)
    t.place(f3, 60, 40)
    f4 = launchLab(env, gtk4, "gtk4", "wayland", work)
    t.place(f4, 520, 40)
    fq = launchLab(env, qt6, "qt6", "wayland", work, name = qtName)
    t.place(fq, 1000, 60)

  test "test_wlr_virtual_click_scroll_drag_roundtrip_in_sway [gtk3]":
    live problem: checkClickScrollDrag(env, f3)

  test "test_wlr_virtual_click_scroll_drag_roundtrip_in_sway [gtk4]":
    live problem: checkClickScrollDrag(env, f4)

  test "test_wlr_virtual_click_scroll_drag_roundtrip_in_sway [qt6 click and type]":
    live problem:
      check statusCount(env, fq.pid) == 0
      discard mustRun(@["click", "--at", at(centre(boundsOf(env, fq.pid, "Submit", "button")))],
                      env)
      discard mustRun(@["wait", "--element", "--pid", $fq.pid, "--role", "label",
                        "--name-contains", "Submitted", "--wait-ms", "10000"], env)
      checkType(env, fq, "Mira Okonkwo-Västberg 七")

  test "test_wlr_virtual_type_sets_field_value [gtk3, gtk4]":
    live problem:
      checkType(env, f3, "Robin Vale — ünïcode 中文 ✓")
      checkType(env, f4, "Ash Corlett — ö")

  test "test_every_key_of_the_table_is_delivered [linux-wlr-virtual, gtk3]":
    live problem: checkEveryKey(env, f3, nonLayout = true)

  test "test_every_key_of_the_table_is_delivered [linux-wlr-virtual, gtk4]":
    live problem: checkEveryKey(env, f4, nonLayout = true)

  test "test_gesture_held_keys_and_modified_drag [linux-wlr-virtual, gtk3]":
    live problem: checkGestureAndModifiedDrag(env, f3)

  test "test_drag_path_waypoints_reach_the_fixture_in_order [linux-wlr-virtual, gtk3]":
    live problem:
      checkDragPath(env, f3)
      checkClickDetails(env, f3)
      checkScrollDirections(env, f3, pixel = true)

  test "test_drag_path_waypoints_reach_the_fixture_in_order [linux-wlr-virtual, gtk4]":
    live problem:
      checkDragPath(env, f4)
      checkClickDetails(env, f4)
      checkScrollDirections(env, f4, pixel = true)

  test "test_input_backends_name_features_on_exit_4_6 [linux-wlr-virtual]":
    live problem:
      checkFeatures(env, "linux-wlr-virtual")
      # A point on no output: exit 3, nothing delivered.
      let e = failsWith(@["click", "--at", "5000,5000"], env, 3, "display")
      check e["kind"].getStr == "not-found"
      # Another session's backends refuse by name, with the feature.
      let x = failsWith(@["--input-backend", "linux-xtest", "type", secret], env, 4,
                        "display-server-unsupported")
      check x["details"]["feature"].getStr == "keyboard-input"
      check "DISPLAY" in x["message"].getStr
      var nodisp = runEnv(st, t.sessionEnv)
      nodisp.del("WAYLAND_DISPLAY")
      let y = failsWith(@["--input-backend", "linux-wlr-virtual", "click", "--at", "1,1"],
                        nodisp, 4, "display-server-unsupported")
      check y["details"]["feature"].getStr == "pointer-input"
      let caps = mustRun(@["--input-backend", "linux-wlr-virtual", "capabilities", "--probe"],
                         nodisp)
      check featureOf(caps, "pointer-input")["state"].getStr == "unavailable"
      check featureOf(caps, "pointer-input")["reason"].getStr == "display-server-unsupported"
      # A control character no key types: exit 4, nothing typed.
      let before = valueOf(env, f3.pid, "Display name", "text-field")
      let z = failsWith(@["type", "ab\x01cd"], env, 4, "unsupported-option")
      check z["details"]["feature"].getStr == "keyboard-input"
      check "character 3" in z["message"].getStr
      check valueOf(env, f3.pid, "Display name", "text-field") == before

  test "test_input_window_management_moves_and_focuses [sway]":
    live problem: checkWindowManagement(env, f3, f4, (90, 70, 380, 700))

  test "test_typed_text_never_in_argv_stderr_events_or_state [sway]":
    live problem:
      let field = boundsOf(env, f3.pid, "Display name", "text-field")
      let path = element(env, f3.pid, "Display name", "text-field")["path"].getStr
      discard mustRun(@["element-action", path, "set-value", "--value", ""], env)
      discard mustRun(@["click", "--at", at(centre(field))], env)
      # While a slow --stdin type runs, no process's argv holds the text.
      let p = startProcess(contractBin(), args = @["type", "--stdin", "--interval-ms", "60"],
                           env = env, options = {})
      p.inputStream.write(secret)
      p.inputStream.close()
      # While a slow --stdin type runs, no process's argv holds the text, in
      # either of its forms: as typed, or as the input script the helper
      # executes (its keysyms, `key 0x… down`). The helper itself must be
      # seen running, so the scan provably covered it.
      var scriptForm: seq[string]
      for r in secret.toRunes:
        let c = int(r)
        let ks = if (c >= 0x20 and c <= 0x7e) or (c >= 0xa0 and c <= 0xff): c
                 else: 0x0100_0000 + c
        scriptForm.add "0x" & toHex(ks, 8).toLowerAscii
      var seen = 0
      var looked = 0
      var helperSeen = 0
      while p.running:
        for kind, d in walkDir("/proc"):
          try:
            let cmd = readFile(d / "cmdline")
            inc looked
            if secret in cmd or secret.replace("-", "") in cmd: inc seen
            let argv = cmd.split('\0')
            if argv[0].extractFilename == "wayland_input":
              # Its whole argv is its path and its mode (`run`).
              inc helperSeen
              if argv.len > 3 or scriptForm.anyIt(it in cmd) or "key " in cmd:
                checkpoint "helper argv: " & cmd.replace('\0', ' ')
                inc seen
          except IOError, OSError: discard
        sleep(20)
      let code = p.waitForExit()
      let o = p.outputStream.readAll()
      let err = p.errorStream.readAll()
      p.close()
      outputs.add o
      outputs.add err
      check code == 0 and err == ""
      check looked > 0
      checkpoint "helper seen " & $helperSeen & " times"
      check helperSeen > 0
      check seen == 0
      check valueOf(env, f3.pid, "Display name", "text-field") == secret
      # Over serve: the result carries the length only; no event or stderr
      # carries the text.
      discard mustRun(@["element-action", path, "set-value", "--value", ""], env)
      var sv = startServe(@["serve", "--stdio"], env)
      sv.send(%*{"v": 1, "id": "t1", "op": "run", "argv": ["type", "--stdin"], "stdin": secret})
      var lines: seq[string]
      while true:
        let l = sv.recvRaw(60_000)
        lines.add l
        if parseJson(l)["type"].getStr == "result": break
      sv.closeInput()
      discard sv.p.waitForExit(30_000)
      let daemonErr = sv.p.errorStream.readAll()
      sv.p.close()
      check daemonErr == ""
      check parseJson(lines[^1])["exit"].getInt == 0
      for l in lines: check secret notin l
      check valueOf(env, f3.pid, "Display name", "text-field") == secret
      check secret notin stateFilesText(st)
      for o in outputs: check secret notin o

  test "test_per_session_input_is_ordered_over_serve [sway]":
    live problem:
      let field = boundsOf(env, f4.pid, "Display name", "text-field")
      let path = element(env, f4.pid, "Display name", "text-field")["path"].getStr
      discard mustRun(@["element-action", path, "set-value", "--value", ""], env)
      discard mustRun(@["click", "--at", at(centre(field))], env)
      # Three requests on one session, sent at once; each types slowly
      # enough that interleaving would show.
      var sv = startServe(@["serve", "--stdio"], env)
      let parts = ["alpha-", "beta-", "gamma"]
      for i, s in parts:
        sv.send(runReq("o" & $i, @["type", "--interval-ms", "40", s]))
      var order: seq[string]
      while order.len < parts.len:
        let m = sv.recv(60_000)
        if m["type"].getStr == "result":
          check m["exit"].getInt == 0
          order.add m["id"].getStr
      sv.closeInput()
      discard sv.finish()
      check order == @["o0", "o1", "o2"]
      var v = ""
      for _ in 1 .. 30:
        v = valueOf(env, f4.pid, "Display name", "text-field")
        if v == parts.join(""): break
        sleep(100)
      check v == parts.join("")

  quitAll()
  bus.stop()
  t.stop()

# ---------------------------------------------------------------------------
# A private headless sway at scale 2
# ---------------------------------------------------------------------------

suite "linux-wlr-virtual in a private headless sway at scale 2":
  let st = freshDir("input-sway2-state")
  let work = freshDir("input-sway2-work")
  let t = newSwayTarget(1920, 1800, floatingAppIds = @[appName], scale = 2.0)
  var bus: AtspiBus
  var problem = ""
  var f: Lab
  var env: StringTableRef
  setUp(problem):
    let gtk3 = buildFormFixture(work, 3)
    t.startTarget()
    bus = startAtspiBus(t.sessionEnv)
    env = runEnv(st, t.sessionEnv)
    f = launchLab(env, gtk3, "gtk3", "wayland", work)
    t.place(f, 300, 60)

  test "test_input_scale_2_maps_desktop_coordinates [sway scale 2, gtk3]":
    live problem:
      let d = mustRun(@["displays"], env)["displays"][0]
      check d["scale"].getFloat == 2.0
      check d["bounds"] == %*[0, 0, 960, 900]
      # The window lies beyond the output's half-width in logical
      # coordinates: a mapping that used physical pixels would miss it.
      checkClickScrollDrag(env, f)
      checkDragPath(env, f)
      checkClickDetails(env, f)

  quitAll()
  bus.stop()
  t.stop()

# ---------------------------------------------------------------------------
# A private Xvfb
# ---------------------------------------------------------------------------

suite "linux-xtest in a private Xvfb":
  let st = freshDir("input-x11-state")
  let work = freshDir("input-x11-work")
  var xvfb: Xvfb
  var session: SessionBus
  var bus: AtspiBus
  var problem = ""
  var f3, f4, fq: Lab
  var env: StringTableRef
  var sessionEnv = newStringTable(modeCaseSensitive)
  setUp(problem):
    let gtk3 = buildFormFixture(work, 3)
    let gtk4 = buildFormFixture(work, 4)
    let qt6 = buildQtFixture(work)
    xvfb = startXvfb(1600, 1000)
    let runtime = freshRuntimeDir()
    sessionEnv["DISPLAY"] = xvfb.display
    sessionEnv["XDG_RUNTIME_DIR"] = runtime
    session = startSessionBus(runtime, "x11", sessionEnv)
    for k, v in session.env: sessionEnv[k] = v
    bus = startAtspiBus(sessionEnv)
    env = runEnv(st, sessionEnv)
    f3 = launchLab(env, gtk3, "gtk3", "x11", work, extra = @["--position", "40,30"])
    f4 = launchLab(env, gtk4, "gtk4", "x11", work)
    fq = launchLab(env, qt6, "qt6", "x11", work, name = qtName)
    # No window manager: windows are placed through the backend's own
    # window-set-bounds.
    discard okRun(@["window-set-bounds", f4.windowId, "--bounds", "520,30,360,720"], env)
    discard okRun(@["window-set-bounds", fq.windowId, "--bounds", "1000,60,360,420"], env)

  proc focus(f: Lab) =
    let r = runCli(@["window-focus", f.windowId], env, timeoutMs = 60_000)
    doAssert r.exit == 0, r.stdout
    sleep(200)

  test "test_xtest_type_into_xvfb_fixture [gtk3]":
    live problem:
      focus(f3)
      checkType(env, f3, "Robin Vale — ünïcode 中文 ✓")

  test "test_xtest_type_into_xvfb_fixture [gtk4]":
    live problem:
      focus(f4)
      checkType(env, f4, "Ash Corlett éè")

  test "test_xtest_type_into_xvfb_fixture [qt6]":
    live problem:
      focus(fq)
      checkType(env, fq, "Mira Okonkwo-Västberg")

  test "test_xtest_click_scroll_drag_roundtrip_in_xvfb [gtk3, gtk4]":
    live problem:
      focus(f3)
      checkClickScrollDrag(env, f3)
      focus(f4)
      checkClickScrollDrag(env, f4)

  test "test_every_key_of_the_table_is_delivered [linux-xtest, gtk3]":
    live problem:
      focus(f3)
      checkEveryKey(env, f3, nonLayout = true)

  test "test_gesture_held_keys_and_modified_drag [linux-xtest, gtk3]":
    live problem:
      focus(f3)
      checkGestureAndModifiedDrag(env, f3)

  test "test_drag_path_waypoints_reach_the_fixture_in_order [linux-xtest, gtk3]":
    live problem:
      focus(f3)
      checkDragPath(env, f3)
      checkClickDetails(env, f3)
      checkScrollDirections(env, f3, pixel = false)

  test "test_input_backends_name_features_on_exit_4_6 [linux-xtest]":
    live problem:
      checkFeatures(env, "linux-xtest")
      let e = failsWith(@["scroll", "--at", "50,50", "--dx", "0", "--dy", "3", "--unit",
                          "pixel"], env, 4, "unsupported-option")
      check e["details"]["feature"].getStr == "pointer-input"
      discard failsWith(@["click", "--at", "1600,10"], env, 3, "display")
      let w = failsWith(@["--input-backend", "linux-wlr-virtual", "key", "Return"], env, 4,
                        "display-server-unsupported")
      check w["details"]["feature"].getStr == "keyboard-input"
      let m = failsWith(@["--input-backend", "linux-mutter", "click", "--at", "5,5"], env, 4,
                        "display-server-unsupported")
      check m["details"]["feature"].getStr == "pointer-input"

  test "test_input_window_management_moves_and_focuses [x11]":
    live problem: checkWindowManagement(env, f3, f4, (60, 50, 380, 700))

  quitAll()
  bus.stop()
  session.stop()
  xvfb.stop()

# ---------------------------------------------------------------------------
# A private headless GNOME Shell
# ---------------------------------------------------------------------------

suite "linux-mutter in a private headless GNOME Shell":
  let st = freshDir("input-gnome-state")
  let work = freshDir("input-gnome-work")
  let t = newGnomeTarget(1600, 1000)
  var bus: AtspiBus
  var pipewire: Process
  var problem = ""
  var f4, g4: Lab
  var env: StringTableRef
  setUp(problem):
    let gtk4 = buildFormFixture(work, 4)
    startTarget(t)
    # What a GNOME session configures for itself, here for a test session:
    # F13–F24 on their own keysyms (xkeyboard-config's `fkeys:basic_13-24`;
    # the default maps those keys to XF86 launchers), and no shell action on
    # the Super key or Super+A, which the key table test presses.
    gsettingsIn(t.sessionEnv, "org.gnome.desktop.input-sources", "xkb-options",
                "['fkeys:basic_13-24']")
    gsettingsIn(t.sessionEnv, "org.gnome.mutter", "overlay-key", "''")
    gsettingsIn(t.sessionEnv, "org.gnome.shell.keybindings", "toggle-application-view", "[]")
    var pwEnv = newStringTable(modeCaseSensitive)
    for k, v in envPairs(): pwEnv[k] = v
    pwEnv.del("DISPLAY")
    for k, v in t.sessionEnv: pwEnv[k] = v
    pipewire = startProcess(requireExe("pipewire"), env = pwEnv, options = {})
    let deadline = epochTime() + 10
    while not pathExists(t.sessionEnv["XDG_RUNTIME_DIR"] / "pipewire-0"):
      if epochTime() > deadline: raise blocked("PipeWire did not start in the GNOME session")
      sleep(50)
    bus = startAtspiBus(t.sessionEnv)
    env = runEnv(st, t.sessionEnv)
    f4 = launchLab(env, gtk4, "gtk4", "wayland", work)
    discard okRun(@["window-set-bounds", f4.windowId, "--bounds", "80,60,360,720"], env)
    g4 = launchLab(env, gtk4, "gtk4", "wayland", work)
    discard okRun(@["window-set-bounds", g4.windowId, "--bounds", "620,60,360,720"], env)
    discard okRun(@["window-focus", f4.windowId], env)

  test "test_mutter_virtual_input_click_in_private_gnome [gtk4]":
    live problem:
      checkClickScrollDrag(env, f4)
      checkType(env, f4, "Robin Vale 42")
      # A character outside the session's layout: exit 4, nothing typed.
      let path = element(env, f4.pid, "Display name", "text-field")["path"].getStr
      discard mustRun(@["element-action", path, "set-value", "--value", ""], env)
      discard mustRun(@["click", "--at", at(centre(boundsOf(env, f4.pid, "Display name",
                                                              "text-field")))], env)
      let e = failsWith(@["type", "Västberg"], env, 4, "unsupported-option")
      check e["details"]["feature"].getStr == "keyboard-input"
      check "key 2" in e["message"].getStr
      check "ä" notin $e
      # The position counts key presses, repeated characters included.
      let e2 = failsWith(@["type", "Saaä"], env, 4, "unsupported-option")
      check "key 4 " in e2["message"].getStr
      sleep(300)
      check valueOf(env, f4.pid, "Display name", "text-field") == ""

  test "test_every_key_of_the_table_is_delivered [linux-mutter, gtk4]":
    live problem: checkEveryKey(env, f4, nonLayout = false)

  test "test_drag_path_waypoints_reach_the_fixture_in_order [linux-mutter, gtk4]":
    live problem:
      checkDragPath(env, f4)
      checkClickDetails(env, f4)
      checkScrollDirections(env, f4, pixel = true)

  test "test_input_window_management_moves_and_focuses [gnome]":
    live problem: checkWindowManagement(env, f4, g4, (100, 80, 360, 720))

  test "test_input_backends_name_features_on_exit_4_6 [linux-mutter]":
    live problem:
      checkFeatures(env, "linux-mutter")
      # Without PipeWire Mutter starts no screen cast, so no absolute motion:
      # exit 4 naming PipeWire (keys need no stream and still work). Last in
      # the suite: the shell itself is left without PipeWire.
      stopProcess(pipewire)
      pipewire = nil
      let e = failsWith(@["click", "--at", "100,100"], env, 4, "missing-tool")
      check e["details"]["feature"].getStr == "pointer-input"
      check "PipeWire" in e["remedy"].getStr
      let caps = mustRun(@["capabilities", "--probe"], env)
      check featureOf(caps, "pointer-input")["state"].getStr == "unavailable"
      check featureOf(caps, "pointer-input")["reason"].getStr == "missing-tool"
      # Keys need no screen cast.
      check mustRun(@["key", "Escape"], env)["input"]["keys"].getStr == "Escape"

  quitAll()
  stopProcess(pipewire)
  bus.stop()
  t.stop()

# ---------------------------------------------------------------------------
# Nothing left behind
# ---------------------------------------------------------------------------

suite "the run's own processes":
  test "test_live_suite_leaves_no_process_running":
    checkLeavesNoProcess()

cleanupFreshDirs()
