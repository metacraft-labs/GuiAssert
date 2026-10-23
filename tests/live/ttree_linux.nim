## The Linux live accessibility-tree suite (GS7): the REAL `guiassert` binary
## with the `linux-atspi` tree backend (and the `linux-host` session backend
## for `apps`, `app-launch` and `app-quit`) reading invented form windows
## of three toolkit bridges over AT-SPI (GTK 3 through at-spi2-atk, GTK 4's
## own, Qt 6's own), in display servers this suite starts for itself (spec
## §4.2, §5, §7.5, §9.3):
##
## * a private **headless sway** (scale 1) for GTK 3, GTK 4 and Qt 6 Wayland
##   clients, and GTK 3 drawing its own decorations and shadow;
## * a private headless sway at **scale 2**, for GTK 3;
## * a private **Xvfb** for GTK 3, GTK 4 and Qt 6 X11 clients.
##
## Each has its own session bus and its **own AT-SPI bus**, started here with
## the pinned at-spi-bus-launcher inside the session's private runtime
## directory; `AT_SPI_BUS_ADDRESS` and the operator's session variables never
## reach a `guiassert` run or a fixture (`linux_live.runEnv`).
##
## Run it with `just test-live-linux` (inside `nix develop`; it builds the CLI
## first), or `nim c -r --hints:off tests/live/ttree_linux.nim`.
##
## **The fixture** is `fixtures/atspi_form.c`, compiled here against GTK 3
## and GTK 4, and its Qt 6 Widgets twin `fixtures/atspi_form_qt.cpp`
## (registered because the session's AT-SPI bus says `IsEnabled`, as it does
## once an assistive technology runs): a window titled by the test
## (`Order Form <nonce>`) holding the
## labels "Display name", "Passphrase", "Delivery notes", a text field, a
## password field, the checkbox "Remember this device", a multi-line text
## view with NOTES in it, and a "Submit" button whose press ADDS the status
## label "Submitted <display name>; passphrase of <n> characters". It is
## started through `guiassert app-launch` (linux-host), so the pid the tree
## names is the pid GuiAssert launched.
##
## **What is checked** (the GS7 Linux verification entries):
##
## * the tree holds the fixture's golden names, its window a child of its
##   application node (vacuity guard), with paths, counts and truncation;
## * `find` filters by role, name and state; an unknown filter key, role or
##   state is bad-args;
## * C1: every node's bounds are desktop coordinates: the window node's are
##   the compositor's (or X server's) window, the button lies inside it away
##   from the desktop origin, and a REAL pointer click at the centre of the
##   reported bounds of Submit presses it (the status label appears; it is
##   absent before). With no way to place the frame (the capture backend
##   cannot enumerate this session's windows) every bounds is null;
## * C2–C5: a label's and the text view's `text` (distinct from `name`), a
##   password field typed into with real key events is `protected` with
##   value and text null on `tree`, `find`, `element`, the re-read of
##   `element-action` and `wait --element` (its typed length shows only in
##   the fixture's own status label), `Window.document` is null, and `apps`
##   reports the fixture `accessible: true`, a client without an
##   accessibility bridge `false`, and every application `null` when the
##   session has no AT-SPI bus to ask;
## * C13/C16: `--name` is case-sensitive, `--ignore-case` folds, two
##   instances make `--app` ambiguous (exit 2, `details.pids`), and
##   `set-value --value ""` (and `--value-stdin`) set and clear the field as
##   read back through the tree;
## * C7: `tree-read` and `element-actions` are reported by linux-atspi
##   (`available`, probed `supported`); a session without an AT-SPI bus, or
##   without a session bus, is exit 6 / `atspi-disabled` naming the feature,
##   and reading it starts no AT-SPI bus;
## * C15: no captured content (names, text, the typed passphrase) on any
##   stderr, in a serve event or a state record;
## * `element-action press` on Submit makes the status label appear;
## * linux-host launches, lists and quits the fixture; and the role and state
##   tables of the backend are at-spi2-core's own enumerations.
##
## **Negative controls.** The status label is absent until Submit is
## pressed; a click away from the button changes nothing; a window placed
## away from the desktop origin makes window-relative bounds wrong; a bare
## session bus (no AT-SPI) proves exit 6 rather than an empty tree.
##
## Stand-ins: none. A server, bus or fixture that cannot start fails every
## test that needs it with a `GS7-LINUX BLOCKED:` line; nothing here skips.

when not defined(linux):
  {.error: "tests/live/ttree_linux.nim runs on Linux only".}

import std/[algorithm, json, os, osproc, sequtils, streams, strtabs, strutils, tables, times,
            unittest]
from std/posix import nil

import ../contract/harness
import ./linux_live
import ../../src/gui_assert/desktop_env/session_bus
import ../../src/gui_assert/backends/tree/linux_atspi

const
  goldenNames = ["Display name", "Passphrase", "Remember this device", "Delivery notes",
                 "Submit"]
  notes = "Leave the parcel at the side door."
  appName = "guiassert-form"
  passphrase = "copper-lantern-42"
    ## Invented; typed with real key events into the password field.
  secondPassphrase = "amber-signal-7"
    ## Invented; set through `element-action set-value --value-stdin`.

proc gs7(msg: string): string = msg.replace("GS5-LINUX BLOCKED", "GS7-LINUX BLOCKED")

template live(problem: string, body: untyped) =
  ## Run `body` when the suite's server started; otherwise FAIL with the
  ## BLOCKED line (never skip).
  if problem.len > 0:
    checkpoint problem
    echo "  ", problem
    fail()
  else:
    body

var outputs: seq[string]
  ## Every stdout and stderr of every run, for "the passphrase never appears".

template mustRead(args: seq[string], env: StringTableRef): JsonNode =
  ## The data of a successful run, its stderr empty (C15). A template, so a
  ## failed `check` counts against the test.
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
    check e["error"]["reason"].getStr == reason
    e["error"]

proc runWithStdin(args: seq[string], env: StringTableRef, input: string):
    tuple[exit: int, stdout, stderr: string] =
  ## One run with `input` on its standard input.
  let p = startProcess(contractBin(), args = args, env = env, options = {})
  try:
    p.inputStream.write(input)
    p.inputStream.close()
    result.exit = p.waitForExit(60_000)
    result.stdout = p.outputStream.readAll()
    result.stderr = p.errorStream.readAll()
  finally:
    p.close()

# ---------------------------------------------------------------------------
# Trees as JSON
# ---------------------------------------------------------------------------

proc allNodes(n: JsonNode, acc: var seq[JsonNode]) =
  acc.add n
  for c in n["children"]: allNodes(c, acc)

proc allNodes(n: JsonNode): seq[JsonNode] = allNodes(n, result)

proc namesOf(root: JsonNode): seq[string] =
  for n in allNodes(root):
    if n["name"].kind == JString: result.add n["name"].getStr

proc nodesWith(root: JsonNode, role: string, name = ""): seq[JsonNode] =
  for n in allNodes(root):
    if n["role"].getStr == role and (name.len == 0 or n["name"].getStr == name): result.add n

type Box = tuple[x, y, w, h: int]

proc boxOf(j: JsonNode): Box = (j[0].getInt, j[1].getInt, j[2].getInt, j[3].getInt)
proc centre(b: Box): (int, int) = (b.x + b.w div 2, b.y + b.h div 2)
proc inside(a, b: Box): bool =
  a.x >= b.x and a.y >= b.y and a.x + a.w <= b.x + b.w and a.y + a.h <= b.y + b.h

proc statusLabels(env: StringTableRef, pid: int): JsonNode =
  mustRead(@["find", "--pid", $pid, "--role", "label", "--name-contains", "Submitted"],
           env)["elements"]

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

type Form = object
  pid: int
  title: string
  kit: string    ## "gtk3", "gtk4" or "qt6"
  name: string   ## its application name

var launched: seq[int]
  ## Every fixture pid, killed at the end even when a test failed.

proc launchForm(env: StringTableRef, exe: string, kit: string, display: string,
                extra: seq[string] = @[], name = appName): Form =
  ## Start the fixture (`kit` "gtk3", "gtk4" or "qt6", on `display`
  ## "wayland" or "x11") through `guiassert app-launch` (linux-host) and wait
  ## until its Submit button is on the session's AT-SPI bus.
  result.kit = kit
  result.name = name
  result.title = "Order Form " & nonce()
  var envArgs: seq[string]
  if kit == "qt6":
    let plugins = getEnv("GUI_ASSERT_QT_PLUGIN_PATH")
    if not dirExists(plugins / "platforms"):
      raise blocked("GUI_ASSERT_QT_PLUGIN_PATH names no Qt plugins (run inside `nix develop`)")
    envArgs = @["--env", "QT_PLUGIN_PATH=" & plugins, "--env",
                "QT_QPA_PLATFORM=" & (if display == "x11": "xcb" else: "wayland")]
  else:
    envArgs = @["--env", "GDK_BACKEND=" & display, "--env", "GSK_RENDERER=cairo"]
  let r = runCli(@["app-launch", "--wait-window-ms", "30000"] & envArgs & @["--", exe,
                   "--title", result.title, "--name", name] & extra, env, timeoutMs = 60_000)
  if r.exit != 0: raise blocked("the " & kit & " fixture did not start: " & r.stdout & r.stderr)
  let d = envelopeOf(r)["data"]
  result.pid = d["app"]["pid"].getInt
  launched.add result.pid
  # `wait --element --pid` is exit 3 while the pid is not on the bus yet
  # (as `find --pid` is), so the registration itself is polled here.
  let deadline = epochTime() + 30
  var last = ""
  while true:
    let mine = runCli(@["find", "--pid", $result.pid, "--role", "button", "--name", "Submit"],
                      env)
    if mine.exit == 0 and envelopeOf(mine)["data"]["elements"].len == 1: break
    last = mine.stdout
    if epochTime() > deadline:
      raise blocked("the " & kit & " fixture never reached the AT-SPI bus: " & last)
    sleep(200)

proc quitAll() =
  var pids = launched
  launched.setLen 0
  terminateAll(pids)

proc pathOf(env: StringTableRef, pid: int, role, name: string): string =
  let es = mustRead(@["find", "--pid", $pid, "--role", role, "--name", name], env)["elements"]
  doAssert es.len == 1, "no single " & role & " named " & name & ": " & $es
  es[0]["path"].getStr

proc windowBox(env: StringTableRef, pid: int): Box =
  let ws = mustRead(@["windows", "--pid", $pid], env)["windows"]
  doAssert ws.len == 1, "not one window of pid " & $pid & ": " & $ws
  boxOf(ws[0]["bounds"])

# ---------------------------------------------------------------------------
# Shared checks
# ---------------------------------------------------------------------------

template checkGoldenTree(env: StringTableRef, f: Form) =
  ## The fixture's tree holds its golden names; its window is a child of its
  ## application node (the vacuity guard); counts, paths and truncation.
  block:
    let t = mustRead(@["tree", "--pid", $f.pid], env)
    let root = t["root"]
    check root["path"].getStr == "/app[" & $f.pid & "]"
    check root["role"].getStr == "application"
    check root["name"].getStr == f.name
    check root["children"].len >= 1
    let windows = root["children"].getElems.filterIt(it["role"].getStr == "window")
    check windows.len == 1
    if windows.len == 1:
      check windows[0]["name"].getStr == f.title
      check windows[0]["path"].getStr == "/app[" & $f.pid & "]/window[0]"
    let names = namesOf(root)
    for g in goldenNames:
      checkpoint "golden " & g & " in " & $names
      check g in names
    check t["nodeCount"].getInt == allNodes(root).len
    check t["truncated"].getBool == false
    check nodesWith(root, "button", "Submit").len == 1
    check nodesWith(root, "checkbox", "Remember this device").len == 1
    check nodesWith(root, "text-field", "Display name").len == 1
    check nodesWith(root, "text-area", "Delivery notes").len == 1
    for n in allNodes(root):
      check n["path"].getStr.startsWith("/app[" & $f.pid & "]")
      check n["childCount"].getInt >= n["children"].len
    # Bounded reads: one level, and three nodes.
    let shallow = mustRead(@["tree", "--pid", $f.pid, "--depth", "1"], env)
    check shallow["truncated"].getBool == false
    for c in shallow["root"]["children"]:
      check c["children"].len == 0
      if c["role"].getStr == "window": check c["childCount"].getInt >= 1
    let small = mustRead(@["tree", "--pid", $f.pid, "--max-nodes", "3"], env)
    check small["truncated"].getBool == true
    check small["nodeCount"].getInt == 3
    check allNodes(small["root"]).len == 3
    # `--window` names the same application's window (`--app` is checked
    # with a name of its own, the suite's forms share theirs).
    let wid = mustRead(@["windows", "--pid", $f.pid], env)["windows"][0]["id"].getStr
    let byWindow = mustRead(@["tree", "--window", wid], env)["root"]
    check byWindow["path"].getStr == "/app[" & $f.pid & "]/window[0]"
    check byWindow["name"].getStr == f.title

template checkFind(env: StringTableRef, f: Form) =
  block:
    let b = mustRead(@["find", "--pid", $f.pid, "--role", "button", "--name", "Submit"],
                     env)["elements"]
    check b.len == 1
    if b.len == 1:
      check "press" in b[0]["actions"].getElems.mapIt(it.getStr)
      check b[0]["children"].len == 0
      check b[0]["nativeRole"].getStr == "button"
    let fields = mustRead(@["find", "--pid", $f.pid, "--role", "text-field"], env)["elements"]
    check fields.len == 2
    let prot = mustRead(@["find", "--pid", $f.pid, "--state", "protected"], env)["elements"]
    check prot.len == 1
    if prot.len == 1:
      check prot[0]["name"].getStr == "Passphrase"
      check prot[0]["role"].getStr == "text-field"
    let both = mustRead(@["find", "--pid", $f.pid, "--role", "text-field", "--state",
                          "editable", "--state", "protected"], env)["elements"]
    check both.len == 1
    check mustRead(@["find", "--pid", $f.pid, "--role", "button", "--state", "protected"],
                   env)["elements"].len == 0
    let contains = mustRead(@["find", "--pid", $f.pid, "--role", "label", "--name-contains",
                              "notes"], env)["elements"]
    check contains.len == 1 and contains[0]["name"].getStr == "Delivery notes"
    let limited = mustRead(@["find", "--pid", $f.pid, "--role", "label", "--limit", "1"], env)
    check limited["elements"].len == 1 and limited["truncated"].getBool
    let e1 = failsWith(@["find", "--pid", $f.pid, "--colour", "red"], env, 2, "unknown-flag")
    check e1["kind"].getStr == "bad-args"
    discard failsWith(@["find", "--pid", $f.pid, "--role", "knob"], env, 2, "invalid-value")
    discard failsWith(@["find", "--pid", $f.pid, "--state", "shiny"], env, 2, "invalid-value")

template checkBoundsByClick(env: StringTableRef, f: Form, clickAt: untyped,
                            framed: bool) =
  ## C1: the reported bounds are where a real pointer reaches the element.
  ## `clickAt(p)` clicks at desktop point `p`. With `framed` the window node
  ## is the window's surface (a toolkit shadow around it), else exactly the
  ## window the server reports.
  block:
    let wb = windowBox(env, f.pid)
    let root = mustRead(@["tree", "--pid", $f.pid], env)["root"]
    let win = nodesWith(root, "window")[0]
    let winBox = boxOf(win["bounds"])
    checkpoint "window " & $wb & ", window node " & $winBox
    if framed: check inside(wb, winBox)
    else: check winBox == wb
    let button = nodesWith(root, "button", "Submit")[0]
    let bb = boxOf(button["bounds"])
    checkpoint "Submit " & $bb
    check inside(bb, wb)
    check bb.x >= wb.x and bb.y >= wb.y and wb.x > 0 and wb.y > 0
    for n in allNodes(root):
      # Every visible element has bounds (the application itself is no
      # element on the desktop; Qt calls it visible all the same).
      if n["role"].getStr != "application" and
         "visible" in n["states"].getElems.mapIt(it.getStr):
        checkpoint "a visible node without bounds: " & $n
        check n["bounds"].kind == JArray
    # Negative control: no status label yet, and a click beside the button
    # (in the window, below the form) presses nothing.
    check statusLabels(env, f.pid).len == 0
    clickAt((bb.x + bb.w div 2, wb.y + wb.h - 4))
    sleep(400)
    check statusLabels(env, f.pid).len == 0
    clickAt(centre(bb))
    let w = mustRead(@["wait", "--element", "--pid", $f.pid, "--role", "label",
                       "--name-contains", "Submitted", "--wait-ms", "10000"], env)
    check w["matched"].getBool
    check w["element"]["name"].getStr.startsWith("Submitted")

template checkUnplaceable(env: StringTableRef, f: Form) =
  ## A frame that cannot be placed (no capture backend can enumerate this
  ## session's windows: linux-x11 with no X display) gives null bounds,
  ## never window-relative ones; the read itself succeeds.
  block:
    let t = mustRead(@["--capture-backend", "linux-x11", "tree", "--pid", $f.pid], env)
    for n in allNodes(t["root"]): check n["bounds"].kind == JNull
    let p = pathOf(env, f.pid, "button", "Submit")
    check mustRead(@["--capture-backend", "linux-x11", "element", p],
                   env)["element"]["bounds"].kind == JNull

template checkProtected(env: StringTableRef, f: Form, clickAt, typeKeys: untyped) =
  ## C2–C4: text, protected fields, documents.
  block:
    let root = mustRead(@["tree", "--pid", $f.pid], env)["root"]
    let label = nodesWith(root, "label", "Display name")[0]
    # A GTK label's text is its Text interface's; Qt's labels implement no
    # Text interface (Qt 6.10), so theirs is null rather than the name.
    if f.kit == "qt6": check label["text"].kind == JNull
    else: check label["text"].getStr == "Display name"
    let area = nodesWith(root, "text-area", "Delivery notes")[0]
    check area["text"].getStr == notes
    check area["value"].getStr == notes
    check area["name"].getStr != area["text"].getStr
    check "multi line" notin $area                   # contract states only
    let button = nodesWith(root, "button", "Submit")[0]
    check button["value"].kind == JNull
    # Type the passphrase with real key events into the password field,
    # focused by a click at the centre of its reported bounds.
    let pw = nodesWith(root, "text-field", "Passphrase")[0]
    clickAt(centre(boxOf(pw["bounds"])))
    sleep(300)
    typeKeys(passphrase)
    sleep(500)
    let pwPath = pw["path"].getStr
    template checkPw(n: JsonNode) =
      check n["role"].getStr == "text-field"
      check n["nativeRole"].getStr == "password text"
      check "protected" in n["states"].getElems.mapIt(it.getStr)
      check n["value"].kind == JNull
      check n["text"].kind == JNull
    for n in nodesWith(mustRead(@["tree", "--pid", $f.pid], env)["root"], "text-field",
                       "Passphrase"):
      checkPw(n)
    let found = mustRead(@["find", "--pid", $f.pid, "--state", "protected"], env)["elements"]
    check found.len == 1
    if found.len == 1: checkPw(found[0])
    checkPw(mustRead(@["element", pwPath], env)["element"])
    let waited = mustRead(@["wait", "--element", "--pid", $f.pid, "--state", "protected",
                            "--wait-ms", "5000"], env)
    checkPw(waited["element"])
    # The keys reached the field: the fixture's own status label counts them
    # (and only counts them).
    let submit = pathOf(env, f.pid, "button", "Submit")
    discard mustRead(@["element-action", submit, "press"], env)
    discard mustRead(@["wait", "--element", "--pid", $f.pid, "--role", "label",
                       "--name-contains", "passphrase of " & $passphrase.len & " characters",
                       "--wait-ms", "10000"], env)
    # The re-read of element-action, setting another passphrase from stdin
    # (C14); the status label counts its characters in turn.
    let r = runWithStdin(@["element-action", pwPath, "set-value", "--value-stdin"], env,
                         secondPassphrase)
    outputs.add r.stdout
    outputs.add r.stderr
    check r.exit == 0
    check r.stderr == ""
    if r.exit == 0: checkPw(parseJson(r.stdout)["data"]["element"])
    discard mustRead(@["element-action", submit, "press"], env)
    discard mustRead(@["wait", "--element", "--pid", $f.pid, "--role", "label",
                       "--name-contains", "passphrase of " & $secondPassphrase.len &
                       " characters", "--wait-ms", "10000"], env)
    # C4: no document on Linux.
    for w in mustRead(@["windows", "--pid", $f.pid], env)["windows"]:
      check w["document"].kind == JNull

template checkMatchingAndSetValue(env: StringTableRef, f, g: Form, name = appName) =
  ## C13 and C16 with two instances `f` and `g` of one application name.
  block:
    let e = failsWith(@["tree", "--app", name], env, 2, "conflicting-arguments")
    var pids = @[f.pid, g.pid]
    pids.sort()
    check e["details"]["pids"] == %pids
    discard failsWith(@["find", "--app", name, "--role", "button"], env, 2,
                      "conflicting-arguments")
    discard failsWith(@["wait", "--element", "--app", name, "--role", "button",
                        "--wait-ms", "100"], env, 2, "conflicting-arguments")
    check failsWith(@["tree", "--app", name & "-absent"], env, 3, "app")["kind"].getStr ==
      "not-found"
    check mustRead(@["tree", "--pid", $g.pid], env)["root"]["path"].getStr == "/app[" & $g.pid & "]"
    # Case: exact by default, folded with --ignore-case.
    check mustRead(@["find", "--role", "button", "--name", "submit"], env)["elements"].len == 0
    check mustRead(@["find", "--role", "button", "--name", "Submit"], env)["elements"].len >= 2
    let folded = mustRead(@["find", "--role", "button", "--name", "SUBMIT", "--ignore-case"],
                          env)["elements"]
    check folded.len >= 2
    check folded.getElems.anyIt(it["path"].getStr.startsWith("/app[" & $f.pid & "]"))
    check folded.getElems.anyIt(it["path"].getStr.startsWith("/app[" & $g.pid & "]"))
    check mustRead(@["find", "--pid", $f.pid, "--name-contains", "DELIVERY"],
                   env)["elements"].len == 0
    check mustRead(@["find", "--pid", $f.pid, "--name-contains", "DELIVERY", "--ignore-case"],
                   env)["elements"].len == 2      # the label and the text view
    discard failsWith(@["find", "--pid", $f.pid, "--role", "button", "--ignore-case"], env, 2,
                      "conflicting-arguments")
    # set-value, read back through the tree, then cleared with "".
    let field = pathOf(env, f.pid, "text-field", "Display name")
    let set = mustRead(@["element-action", field, "set-value", "--value", "Robin Vale"], env)
    check set["action"].getStr == "set-value"
    check set["element"]["value"].getStr == "Robin Vale"
    let back = mustRead(@["element", field], env)["element"]
    check back["value"].getStr == "Robin Vale" and back["text"].getStr == "Robin Vale"
    let viaStdin = runWithStdin(@["element-action", field, "set-value", "--value-stdin"], env,
                                "Ash Corlett")
    check viaStdin.exit == 0 and viaStdin.stderr == ""
    check mustRead(@["element", field], env)["element"]["text"].getStr == "Ash Corlett"
    let cleared = mustRead(@["element-action", field, "set-value", "--value", ""], env)
    check cleared["element"]["value"].getStr == ""
    let reread = nodesWith(mustRead(@["tree", "--pid", $f.pid], env)["root"], "text-field",
                           "Display name")[0]
    check reread["value"].getStr == "" and reread["text"].getStr == ""
    # The other instance was not touched.
    check mustRead(@["element", field.replace("/app[" & $f.pid & "]", "/app[" & $g.pid & "]")],
                   env)["element"]["value"].getStr == ""
    # A path that does not resolve, and an action the element lacks.
    discard failsWith(@["element", "/app[" & $f.pid & "]/window[0]/slider[7]"], env, 3,
                      "element")
    discard failsWith(@["element-action", pathOf(env, f.pid, "label", "Passphrase"),
                        "set-value", "--value", "x"], env, 5, "tree-failed")

template checkPress(env: StringTableRef, f: Form) =
  block:
    check statusLabels(env, f.pid).len == 0
    let p = pathOf(env, f.pid, "button", "Submit")
    let r = mustRead(@["element-action", p, "press"], env)
    check r["action"].getStr == "press"
    check r["element"]["path"].getStr == p
    let w = mustRead(@["wait", "--element", "--pid", $f.pid, "--role", "label",
                       "--name-contains", "Submitted", "--wait-ms", "10000"], env)
    check w["element"]["name"].getStr.startsWith("Submitted")
    check namesOf(mustRead(@["tree", "--pid", $f.pid], env)["root"]).anyIt(
      it.startsWith("Submitted"))

proc featureOf(caps: JsonNode, name: string): JsonNode =
  for f in caps["features"]:
    if f["feature"].getStr == name: return f
  newJNull()

proc startBareBus(dir: string): Process =
  ## A session bus with nothing on it (no AT-SPI bus, no portal).
  result = startProcess(requireExe("dbus-daemon"), args = ["--session", "--nofork",
    "--address=unix:path=" & dir / "bare-bus"], options = {})
  let deadline = epochTime() + 5
  while not pathExists(dir / "bare-bus"):
    if epochTime() > deadline: raise blocked("the bare session bus did not start")
    sleep(20)

template checkFeatures(env: StringTableRef, sessionEnv: StringTableRef, st, work: string,
                       f: Form) =
  ## C7: features and exit 6.
  block:
    let caps = mustRead(@["capabilities"], env)
    check caps["selected"]["tree"].getStr == "linux-atspi"
    check caps["selected"]["session"].getStr == "linux-host"
    for name in ["tree-read", "element-actions"]:
      let x = featureOf(caps, name)
      check x["backend"].getStr == "linux-atspi"
      check x["state"].getStr == "available"
      check x["reason"].kind == JNull
    let probed = mustRead(@["capabilities", "--probe"], env)
    for name in ["tree-read", "element-actions"]:
      check featureOf(probed, name)["state"].getStr == "supported"
    check probed["permissions"]["accessibility"].getStr == "granted"
    # A session bus with no AT-SPI bus on it.
    let bare = startBareBus(work)
    try:
      var benv = runEnv(st, sessionEnv, [("DBUS_SESSION_BUS_ADDRESS",
                                          "unix:path=" & work / "bare-bus")])
      for (argv, feature) in [(@["tree", "--pid", $f.pid], "tree-read"),
                              (@["find", "--role", "button"], "tree-read"),
                              (@["element", "/app[" & $f.pid & "]/window[0]"], "tree-read"),
                              (@["wait", "--element", "--role", "button", "--wait-ms", "200"],
                               "tree-read"),
                              (@["element-action", "/app[" & $f.pid & "]/window[0]", "press"],
                               "element-actions")]:
        let e = failsWith(argv, benv, 6, "atspi-disabled")
        check e["kind"].getStr == "permission-denied"
        check e["details"]["feature"].getStr == feature
        check e["details"]["backend"].getStr == "linux-atspi"
        check "at-spi-bus-launcher" in e["remedy"].getStr
      let bcaps = mustRead(@["capabilities", "--probe"], benv)
      for name in ["tree-read", "element-actions"]:
        let x = featureOf(bcaps, name)
        check x["state"].getStr == "unavailable"
        check x["reason"].getStr == "atspi-disabled"
        check x["remedy"].kind == JString
      check bcaps["permissions"]["accessibility"].getStr == "denied"
      # Reading started no AT-SPI bus on it.
      var bareSession = newStringTable(modeCaseSensitive)
      bareSession["DBUS_SESSION_BUS_ADDRESS"] = "unix:path=" & work / "bare-bus"
      bareSession["XDG_RUNTIME_DIR"] = work
      check a11yAddressOf(bareSession) == ""
    finally:
      stopProcess(bare)
    # No session bus at all.
    var nenv = runEnv(st, sessionEnv)
    nenv.del("DBUS_SESSION_BUS_ADDRESS")
    let n = failsWith(@["tree", "--pid", $f.pid], nenv, 6, "atspi-disabled")
    check n["details"]["feature"].getStr == "tree-read"
    let ncaps = mustRead(@["capabilities"], nenv)
    check featureOf(ncaps, "tree-read")["state"].getStr == "unavailable"
    check ncaps["permissions"]["accessibility"].getStr == "unknown"

template checkApps(env: StringTableRef, sessionEnv: StringTableRef, st: string, f: Form,
                   opaquePid: int) =
  ## C5: accessible true / false / null.
  block:
    let apps = mustRead(@["apps"], env)["apps"]
    var byPid = initTable[int, JsonNode]()
    for a in apps: byPid[a["pid"].getInt] = a
    check f.pid in byPid
    if f.pid in byPid:
      check byPid[f.pid]["accessible"].getBool == true
      check byPid[f.pid]["name"].getStr == f.name
    check opaquePid in byPid
    if opaquePid in byPid: check byPid[opaquePid]["accessible"] == %false
    var nenv = runEnv(st, sessionEnv)
    nenv.del("DBUS_SESSION_BUS_ADDRESS")
    let blind = mustRead(@["apps"], nenv)["apps"]
    check blind.len >= 2
    for a in blind: check a["accessible"].kind == JNull

template checkNoContentLeaks(env: StringTableRef, st: string, f: Form) =
  ## C15: captured content stays in `data`.
  block:
    var sv = startServe(@["serve", "--stdio"], env)
    sv.send(runReq("w1", @["wait", "--element", "--pid", $f.pid, "--role", "text-area",
                           "--name", "Delivery notes", "--wait-ms", "5000", "--interval-ms",
                           "50"]))
    sv.send(runReq("t1", @["tree", "--pid", $f.pid]))
    var events: seq[string]
    var results = 0
    var resultText = ""
    while results < 2:
      let line = sv.recvRaw(60_000)
      let msg = parseJson(line)
      if msg["type"].getStr == "event": events.add line
      elif msg["type"].getStr == "result":
        inc results
        check msg["exit"].getInt == 0
        resultText.add line
    check notes in resultText                 # positive control: it is data
    check events.len >= 1                     # the wait's poll events
    for line in events:
      for s in [notes, "Delivery notes", "Display name", passphrase, secondPassphrase]:
        check s notin line
    sv.closeInput()
    discard sv.p.waitForExit(30_000)
    let daemonErr = sv.p.errorStream.readAll()
    sv.p.close()
    check daemonErr == ""
    let state = stateFilesText(st)
    for s in [notes, "Delivery notes", "Submitted", passphrase, secondPassphrase]:
      check s notin state
    for o in outputs:
      check passphrase notin o
      check secondPassphrase notin o

template checkHostApps(env: StringTableRef, exe: string, gdk: string, st: string) =
  ## linux-host: launch, list, quit; the refusals.
  block:
    let title = "Order Form " & nonce()
    let d = mustRead(@["app-launch", "--wait-window-ms", "30000", "--env", "GDK_BACKEND=" & gdk,
                       "--", exe, "--title", title], env)
    let pid = d["app"]["pid"].getInt
    launched.add pid
    check pid > 0
    check d["window"]["pid"].getInt == pid
    check d["window"]["title"].getStr == title
    check mustRead(@["apps"], env)["apps"].getElems.anyIt(it["pid"].getInt == pid)
    let q = mustRead(@["app-quit", $pid], env)
    check q["pid"].getInt == pid and q["exited"].getBool
    check not fileExists("/proc/" & $pid & "/stat") or
      readFile("/proc/" & $pid & "/stat").split(") ")[^1].startsWith("Z")
    check not mustRead(@["apps"], env)["apps"].getElems.anyIt(it["pid"].getInt == pid)
    discard failsWith(@["app-quit", $pid], env, 3, "app")
    let b = failsWith(@["app-launch", "--bundle-id", "dev.example.Form"], env, 4,
                      "unsupported-option")
    check b["details"]["feature"].getStr == "app-management"
    discard failsWith(@["app-launch", "--", "no-such-program-" & nonce()], env, 3, "file")
    # A windowless program: exit 7 with the App, still running, then quit.
    let x = failsWith(@["app-launch", "--wait-window-ms", "500", "--", "sleep", "60"], env, 7,
                      "condition-not-met")
    let spid = x["details"]["app"]["pid"].getInt
    launched.add spid
    check fileExists("/proc/" & $spid & "/stat")
    check mustRead(@["app-quit", $spid], env)["exited"].getBool
    let sessions = mustRead(@["session-list"], env)["sessions"]
    check sessions.len == 1 and sessions[0]["id"].getStr == "host"
    check sessions[0]["backend"].getStr == "linux-host"
    check sessions[0]["platform"].getStr == "linux"
    check sessions[0]["backends"]["tree"].getStr == "linux-atspi"

proc strs(j: JsonNode): seq[string] = j.getElems.mapIt(it.getStr)

proc focusedPaths(env: StringTableRef, pid: int): seq[string] =
  mustRead(@["find", "--pid", $pid, "--state", "focused"], env)["elements"].getElems.mapIt(
    it["path"].getStr)

template checkFocus(env: StringTableRef, f: Form) =
  ## `element-action focus` moves the keyboard focus: through Component
  ## GrabFocus where the toolkit implements it (GTK 3, Qt 6), by a click at
  ## the element's centre where it does not (GTK 4, linux-atspi "Focus by
  ## pointer"). Read back three ways: the re-read element and `find --state
  ## focused` name exactly the focused field, keys typed with the `type`
  ## verb land in it, and after `key Tab` the focus is still reported, on
  ## another element (the session's seat keeps its keyboard focus between
  ## verbs). Negative controls: Passphrase is focused first so that focusing
  ## Display name has to MOVE the focus; on GTK 4 a button offers no
  ## `focus` (a click would press it) and is refused.
  block:
    let name = pathOf(env, f.pid, "text-field", "Display name")
    let pw = pathOf(env, f.pid, "text-field", "Passphrase")
    check "focus" in strs(mustRead(@["element", name], env)["element"]["actions"])
    for p in [pw, name]:
      let r = mustRead(@["element-action", p, "focus"], env)
      check r["action"].getStr == "focus"
      check "focused" in strs(r["element"]["states"])
      check focusedPaths(env, f.pid) == @[p]
    discard mustRead(@["element-action", name, "set-value", "--value", ""], env)
    discard mustRead(@["type", "Quill Ash"], env)
    var v = ""
    for _ in 1 .. 30:
      v = mustRead(@["element", name], env)["element"]["value"].getStr
      if v == "Quill Ash": break
      sleep(100)
    check v == "Quill Ash"
    discard mustRead(@["key", "Tab"], env)
    sleep(300)
    let after = focusedPaths(env, f.pid)
    check after.len == 1
    check name notin after
    if f.kit == "gtk4":
      let submit = pathOf(env, f.pid, "button", "Submit")
      check "focus" notin strs(mustRead(@["element", submit], env)["element"]["actions"])
      let e = failsWith(@["element-action", submit, "focus"], env, 5, "tree-failed")
      check "does not offer 'focus'" in e["message"].getStr
    discard mustRead(@["element-action", name, "set-value", "--value", ""], env)

template checkClippedFocus(env: StringTableRef, exe: string, display: string) =
  ## `focus` by pointer never clicks what the element does not show
  ## (linux_atspi "Focus by pointer", `pointerFocusPoint`): the GTK 4 form
  ## with `--clipped-field` has a text field scrolled out of its viewport
  ## whose own centre lies on Submit. GTK 4 still reports the field
  ## `showing`, so it offers `focus`; performing it is exit 5 /
  ## `tree-failed` without a click, read back as Submit never pressed (no
  ## status label) and the field not focused. Likewise its "Covered note"
  ## field, unclipped but with a button over its centre that presses like
  ## Submit (the toolkit's hit test refuses it). Positive control: the same
  ## window's Display name is still focused by pointer.
  block:
    let c = launchForm(env, exe, "gtk4", display, extra = @["--clipped-field"])
    try:
      let hidden = pathOf(env, c.pid, "text-field", "Archived note")
      check "focus" in strs(mustRead(@["element", hidden], env)["element"]["actions"])
      let e = failsWith(@["element-action", hidden, "focus"], env, 5, "tree-failed")
      check "scrolled out of view" in e["message"].getStr
      sleep(500)
      check statusLabels(env, c.pid).len == 0
      check hidden notin focusedPaths(env, c.pid)
      # Unclipped, but a button lies over its centre: GTK 4 reports the
      # button at that point (GetAccessibleAtPoint), so no click either.
      let covered = pathOf(env, c.pid, "text-field", "Covered note")
      check "focus" in strs(mustRead(@["element", covered], env)["element"]["actions"])
      let e2 = failsWith(@["element-action", covered, "focus"], env, 5, "tree-failed")
      check "reports another element" in e2["message"].getStr
      sleep(500)
      check statusLabels(env, c.pid).len == 0
      check covered notin focusedPaths(env, c.pid)
      let name = pathOf(env, c.pid, "text-field", "Display name")
      let r = mustRead(@["element-action", name, "focus"], env)
      check "focused" in strs(r["element"]["states"])
      check statusLabels(env, c.pid).len == 0
    finally:
      terminateAll(@[c.pid])

# ---------------------------------------------------------------------------
# The backend's tables are at-spi2-core's
# ---------------------------------------------------------------------------

proc headerEnum(header, typeName, prefix: string): seq[string] =
  ## The enumerators of `typedef enum { … } <typeName>;` in order, spelled as
  ## the backend's tables spell them, aliases and `LAST_DEFINED` dropped.
  let stop = header.find("} " & typeName & ";")
  doAssert stop > 0, typeName & " not found"
  let start = header.rfind("typedef enum", last = stop)
  for line in header[start ..< stop].splitLines:
    let l = line.strip
    if not l.startsWith(prefix): continue
    let ident = l[prefix.len .. ^1].split({',', ' ', '='})[0]
    if ident == "LAST_DEFINED" or '=' in l: continue
    result.add ident.toLowerAscii.replace('_', ' ')

suite "linux-atspi's tables":
  test "test_atspi_role_and_state_tables_match_at_spi2_core":
    let (dir, code) = execCmdEx("pkg-config --variable=includedir atspi-2")
    if code != 0:
      echo "  GS7-LINUX BLOCKED: pkg-config knows no atspi-2 (run inside `nix develop`)"
      fail()
    else:
      let header = readFile(dir.strip / "at-spi-2.0" / "atspi" / "atspi-constants.h")
      check headerEnum(header, "AtspiRole", "ATSPI_ROLE_") == @atspiRoleNames
      check headerEnum(header, "AtspiStateType", "ATSPI_STATE_") == @atspiStateNames

# ---------------------------------------------------------------------------
# A private headless sway at scale 1: GTK 3, GTK 4, Qt 6, GTK 3's own frame
# ---------------------------------------------------------------------------

const qtName = "guiassert-form-qt"
  ## The Qt form's application name (and Wayland app id), its own so that
  ## the GTK forms' shared name stays a pair for the ambiguity checks.

suite "linux-atspi in a private headless sway":
  let st = freshDir("tree-sway-state")
  let work = freshDir("tree-sway-work")
  let t = newSwayTarget(1500, 1000, floatingAppIds = @[appName, qtName])
  var bus: AtspiBus
  var problem = ""
  var gtk3, gtk4, qt6: string
  var f3, f4, fq, csd, twin: Form
  var opaque: Process
  var env: StringTableRef
  proc place(f: Form, x, y: int) =
    let w = t.waitPidWindow(f.pid)
    t.placeWindow(w, x, y)
    t.waitUntil("the window moved", proc(): bool =
      let r = t.waitPidWindow(f.pid).rect
      r.x == x and r.y == y)
    sleep(400)
  try:
    gtk3 = buildFormFixture(work, 3)
    gtk4 = buildFormFixture(work, 4)
    qt6 = buildQtFixture(work)
    t.startTarget()
    bus = startAtspiBus(t.sessionEnv)
    env = runEnv(st, t.sessionEnv)
    f3 = launchForm(env, gtk3, "gtk3", "wayland")
    place(f3, 130, 170)
    f4 = launchForm(env, gtk4, "gtk4", "wayland")
    place(f4, 640, 150)
    fq = launchForm(env, qt6, "qt6", "wayland", name = qtName)
    place(fq, 1060, 200)
    opaque = t.probeWindow("80c0ff", "opaque " & nonce())
    # Clear of every form (sway centres a new floating window, over them).
    let ow = t.waitPidWindow(opaque.processID)
    t.placeWindow(ow, 20, 700)
    t.waitUntil("the opaque window moved", proc(): bool =
      t.waitPidWindow(opaque.processID).rect.y == 700)
  except AssertionDefect, CatchableError:
    problem = gs7(getCurrentExceptionMsg())
    if "BLOCKED" notin problem: problem = "GS7-LINUX BLOCKED: " & problem
  let clickSway = proc (p: (int, int)) = t.click(p)
  let typeSway = proc (s: string) = t.typeText(s)

  test "test_atspi_tree_of_gtk_fixture_in_private_sway [gtk3]":
    live problem: checkGoldenTree(env, f3)

  test "test_atspi_tree_of_gtk_fixture_in_private_sway [gtk4]":
    live problem: checkGoldenTree(env, f4)

  test "test_atspi_tree_of_gtk_fixture_in_private_sway [qt6]":
    live problem: checkGoldenTree(env, fq)

  test "test_atspi_find_filters_role_name_state [gtk3]":
    live problem: checkFind(env, f3)

  test "test_atspi_find_filters_role_name_state [gtk4]":
    live problem: checkFind(env, f4)

  test "test_atspi_find_filters_role_name_state [qt6]":
    live problem: checkFind(env, fq)

  test "test_tree_bounds_are_desktop_coordinates [sway, gtk3]":
    live problem:
      checkBoundsByClick(env, f3, clickSway, framed = false)
      checkUnplaceable(env, f3)

  test "test_tree_bounds_are_desktop_coordinates [sway, gtk4]":
    live problem:
      checkBoundsByClick(env, f4, clickSway, framed = false)
      checkUnplaceable(env, f4)

  test "test_tree_bounds_are_desktop_coordinates [sway, qt6]":
    live problem:
      checkBoundsByClick(env, fq, clickSway, framed = false)
      checkUnplaceable(env, fq)

  test "test_tree_bounds_are_desktop_coordinates [sway, gtk3 drawing its own frame]":
    live problem:
      csd = launchForm(env, gtk3, "gtk3", "wayland", @["--csd"])
      place(csd, 300, 240)
      checkBoundsByClick(env, csd, clickSway, framed = true)
      terminateAll(@[csd.pid])

  test "test_tree_text_protected_document_accessible [sway, gtk3]":
    live problem:
      checkProtected(env, f3, clickSway, typeSway)
      checkApps(env, t.sessionEnv, st, f3, opaque.processID)

  test "test_tree_text_protected_document_accessible [sway, gtk4]":
    live problem:
      checkProtected(env, f4, clickSway, typeSway)
      checkApps(env, t.sessionEnv, st, f4, opaque.processID)

  test "test_tree_text_protected_document_accessible [sway, qt6]":
    live problem:
      checkProtected(env, fq, clickSway, typeSway)
      checkApps(env, t.sessionEnv, st, fq, opaque.processID)

  test "test_tree_matching_rules_and_set_value_empty [sway, gtk3 and gtk4]":
    live problem:
      # f3 and f4 share the application name; a third would too.
      checkMatchingAndSetValue(env, f3, f4)
      twin = launchForm(env, gtk3, "gtk3", "wayland")
      let e = failsWith(@["tree", "--app", appName], env, 2, "conflicting-arguments")
      check e["details"]["pids"].len == 3
      terminateAll(@[twin.pid])
      # A name of its own is not ambiguous.
      check mustRead(@["tree", "--app", qtName], env)["root"]["path"].getStr ==
        "/app[" & $fq.pid & "]"

  test "test_tree_matching_rules_and_set_value_empty [sway, qt6]":
    live problem:
      # Two Qt instances of one name.
      let qtwin = launchForm(env, qt6, "qt6", "wayland", name = qtName)
      checkMatchingAndSetValue(env, fq, qtwin, qtName)
      terminateAll(@[qtwin.pid])

  test "test_tree_backends_name_features_on_exit_4_6 [sway]":
    live problem: checkFeatures(env, t.sessionEnv, st, work, f3)

  test "test_element_action_press_changes_status [sway, gtk3, gtk4 and qt6]":
    live problem:
      let a = launchForm(env, gtk3, "gtk3", "wayland")
      checkPress(env, a)
      let b = launchForm(env, gtk4, "gtk4", "wayland")
      checkPress(env, b)
      let c = launchForm(env, qt6, "qt6", "wayland", name = qtName & "-press")
      checkPress(env, c)
      terminateAll(@[a.pid, b.pid, c.pid])

  test "test_element_action_focus_moves_the_keyboard_focus [sway, gtk3]":
    live problem: checkFocus(env, f3)

  test "test_element_action_focus_moves_the_keyboard_focus [sway, gtk4]":
    live problem: checkFocus(env, f4)

  test "test_element_action_focus_never_clicks_a_clipped_field [sway, gtk4]":
    live problem: checkClippedFocus(env, gtk4, "wayland")

  test "test_element_action_focus_moves_the_keyboard_focus [sway, qt6]":
    live problem: checkFocus(env, fq)

  test "test_tree_content_never_on_stderr_or_serve_events [sway]":
    live problem: checkNoContentLeaks(env, st, f3)

  test "test_linux_host_launches_lists_and_quits_apps [sway]":
    live problem: checkHostApps(env, gtk3, "wayland", st)

  quitAll()
  stopProcess(opaque)
  bus.stop()
  t.stop()

# ---------------------------------------------------------------------------
# A private headless sway at scale 2
# ---------------------------------------------------------------------------

suite "linux-atspi in a private headless sway at scale 2":
  let st = freshDir("tree-sway2-state")
  let work = freshDir("tree-sway2-work")
  let t = newSwayTarget(1920, 1600, floatingAppIds = @[appName], scale = 2.0)
  var bus: AtspiBus
  var problem = ""
  var f: Form
  var env: StringTableRef
  try:
    let gtk3 = buildFormFixture(work, 3)
    t.startTarget()
    bus = startAtspiBus(t.sessionEnv)
    env = runEnv(st, t.sessionEnv)
    f = launchForm(env, gtk3, "gtk3", "wayland")
    let w = t.waitPidWindow(f.pid)
    t.placeWindow(w, 90, 60)
    t.waitUntil("the window moved", proc(): bool = t.waitPidWindow(f.pid).rect.x == 90)
    sleep(400)
  except AssertionDefect, CatchableError:
    problem = gs7(getCurrentExceptionMsg())
    if "BLOCKED" notin problem: problem = "GS7-LINUX BLOCKED: " & problem
  let clickSway = proc (p: (int, int)) = t.click(p)

  test "test_tree_bounds_are_desktop_coordinates [sway scale 2, gtk3]":
    live problem:
      # Logical coordinates: the window spans half the output's pixels.
      check mustRead(@["displays"], env)["displays"][0]["scale"].getFloat == 2.0
      checkBoundsByClick(env, f, clickSway, framed = false)

  quitAll()
  bus.stop()
  t.stop()

# ---------------------------------------------------------------------------
# A private Xvfb: GTK 3, GTK 4 and Qt 6 X11 clients
# ---------------------------------------------------------------------------

suite "linux-atspi in a private Xvfb":
  let st = freshDir("tree-x11-state")
  let work = freshDir("tree-x11-work")
  var xvfb: Xvfb
  var session: SessionBus
  var bus: AtspiBus
  var problem = ""
  var f3, f4, fq: Form
  var gtk3, gtk4: string
  var input: string
  var opaque: tuple[process: Process, id: string]
  var env: StringTableRef
  var sessionEnv = newStringTable(modeCaseSensitive)
  proc x11(args: seq[string]) =
    var e = newStringTable(modeCaseSensitive)
    for k, v in envPairs(): e[k] = v
    e["DISPLAY"] = xvfb.display
    let (o, code) = execCmdEx(quoteShellCommand(@[input] & args), env = e)
    doAssert code == 0, "x11_input " & args.join(" ") & ": " & o
  try:
    gtk3 = buildFormFixture(work, 3)
    gtk4 = buildFormFixture(work, 4)
    let qt6 = buildQtFixture(work)
    input = buildX11Input(work)
    xvfb = startXvfb(1500, 1000)
    let runtime = freshRuntimeDir()
    sessionEnv["DISPLAY"] = xvfb.display
    sessionEnv["XDG_RUNTIME_DIR"] = runtime
    session = startSessionBus(runtime, "x11", sessionEnv)
    for k, v in session.env: sessionEnv[k] = v
    bus = startAtspiBus(sessionEnv)
    env = runEnv(st, sessionEnv)
    f3 = launchForm(env, gtk3, "gtk3", "x11")
    x11(@["place", $f3.pid, "130", "170"])
    f4 = launchForm(env, gtk4, "gtk4", "x11")
    x11(@["place", $f4.pid, "640", "150"])
    fq = launchForm(env, qt6, "qt6", "x11", name = qtName)
    x11(@["place", $fq.pid, "1060", "200"])
    opaque = xvfb.x11Window("200x120+40+800", "80c0ff", "opaque " & nonce())
    sleep(400)
  except AssertionDefect, CatchableError:
    problem = gs7(getCurrentExceptionMsg())
    if "BLOCKED" notin problem: problem = "GS7-LINUX BLOCKED: " & problem
  let clickX = proc (p: (int, int)) = x11(@["click", $p[0], $p[1]])
  let typeX = proc (s: string) = x11(@["type", s])

  test "test_atspi_tree_of_gtk_fixture_in_private_xvfb [gtk3]":
    live problem: checkGoldenTree(env, f3)

  test "test_atspi_tree_of_gtk_fixture_in_private_xvfb [gtk4]":
    live problem: checkGoldenTree(env, f4)

  test "test_atspi_tree_of_gtk_fixture_in_private_xvfb [qt6]":
    live problem: checkGoldenTree(env, fq)

  test "test_tree_bounds_are_desktop_coordinates [x11, gtk3]":
    live problem: checkBoundsByClick(env, f3, clickX, framed = false)

  test "test_tree_bounds_are_desktop_coordinates [x11, gtk4]":
    live problem: checkBoundsByClick(env, f4, clickX, framed = false)

  test "test_tree_bounds_are_desktop_coordinates [x11, qt6]":
    live problem: checkBoundsByClick(env, fq, clickX, framed = false)

  test "test_tree_text_protected_document_accessible [x11, gtk3]":
    live problem:
      checkProtected(env, f3, clickX, typeX)
      checkApps(env, sessionEnv, st, f3, opaque.process.processID)

  test "test_tree_text_protected_document_accessible [x11, gtk4]":
    live problem: checkProtected(env, f4, clickX, typeX)

  test "test_tree_text_protected_document_accessible [x11, qt6]":
    live problem: checkProtected(env, fq, clickX, typeX)

  test "test_element_action_focus_moves_the_keyboard_focus [x11, gtk3]":
    live problem: checkFocus(env, f3)

  test "test_element_action_focus_moves_the_keyboard_focus [x11, gtk4]":
    live problem: checkFocus(env, f4)

  test "test_element_action_focus_never_clicks_a_clipped_field [x11, gtk4]":
    live problem: checkClippedFocus(env, gtk4, "x11")

  test "test_element_action_focus_moves_the_keyboard_focus [x11, qt6]":
    live problem: checkFocus(env, fq)

  test "test_tree_backends_name_features_on_exit_4_6 [x11]":
    live problem: checkFeatures(env, sessionEnv, st, work, f4)

  test "test_linux_host_launches_lists_and_quits_apps [x11]":
    live problem: checkHostApps(env, gtk3, "x11", st)

  quitAll()
  stopProcess(opaque.process)
  bus.stop()
  session.stop()
  xvfb.stop()

# ---------------------------------------------------------------------------
# Nothing left behind
# ---------------------------------------------------------------------------

suite "the run's own processes":
  test "test_live_suite_leaves_no_process_running":
    # Every server above was stopped; nothing this run started (a server, an
    # AT-SPI bus or registry, a fixture, a bus-activated service, a
    # `guiassert` run) may outlive it (`linux_live.ownProcesses`).
    checkLeavesNoProcess()

cleanupFreshDirs()
