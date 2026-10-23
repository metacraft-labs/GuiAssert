## The Linux parity harness (GS13): the REAL `guiassert` binary driving an
## invented application (`fixtures/parity_lab.c`, GTK 3 and GTK 4) in REAL
## private sessions it starts with `session-start` (`linux-sway`,
## `linux-xvfb`, and on request `linux-gnome`), through the scenarios of the
## Linux computer-use end-to-end suite of GuiAssert's desktop consumer,
## restated in GuiAssert's own terms (Planned-Work/
## Desktop-Substrate.milestones.org, GS13):
##
## | Id | Scenario                                    | GuiAssert verbs                                   |
## |----+---------------------------------------------+---------------------------------------------------|
## | S1 | click / scroll / drag roundtrip             | find, click, scroll, drag, element-action, wait   |
## | S2 | capability report of a live session         | capabilities --probe --session                    |
## | S3 | element find by role, name and state        | find (role, name, name-contains, state), element  |
## | S4 | form fill, submit, status readback          | element-action focus/press, type --stdin, key     |
## | S5 | OCR of a canvas-drawn fixture               | windows, ocr --window, find                       |
## | S6 | screenshot and recording pipeline           | screenshot, record, record-start/stop, ocr --image|
## | S7 | waiting for a timer-driven dialog           | app-launch, wait --element, wait --window         |
## | S8 | zero-touch session bootstrap and teardown   | session-start/info/list/stop, app-launch, find    |
## | S9 | tree-then-OCR text extraction               | find, element, ocr --region                       |
##
## Every check reads the effect back through what the application or the
## produced file reports (the AT-SPI tree, the decoded PNG, ffprobe), never
## through what GuiAssert said it sent, and every scenario has a negative
## control (the effect is absent before the action, or absent where the
## action did not go). A scenario passes only when every one of its checks
## holds; one failing check fails it, and the harness exits 1.
##
## Output: one line per scenario and run (`PARITY <run> <id> PASS|FAIL …`),
## and the evidence file (`--evidence PATH`, schema `guiassert-parity/1`,
## see `writeEvidence`), which holds no absolute path, user or host name.
##
## Usage (inside `nix develop`, after `just build-cli`; tests/parity/
## linux_parity.sh does both steps):
##
##   linux_parity [--evidence PATH] [--sessions sway,xvfb[,gnome]]
##                [--toolkits gtk3,gtk4] [--only S1,S4,…]
##
## Stand-ins: none. A session, fixture or tool that cannot start fails the
## scenarios of its run with a `GS13-LINUX BLOCKED:` line; nothing skips.

when not defined(linux):
  {.error: "tests/parity/linux_parity.nim runs on Linux only".}

import std/[json, monotimes, os, osproc, parseopt, sequtils, streams, strtabs, strutils, times]
from std/posix import nil

import ../contract/harness
import ../live/linux_live
from ../../src/gui_assert/backends/session/linux_private import taggedProcesses

const
  appName = "guiassert-parity"
  account = "harbor-pilot"
  passcode = "copper-key-11"         ## invented; must never appear in any output
  signWords = ["COPPER", "LANTERN", "52"]
  displayW = 1280
  displayH = 800
  verbTimeoutMs = 120_000

# ---------------------------------------------------------------------------
# Checks and scenario results
# ---------------------------------------------------------------------------

type
  Check = object
    name: string
    ok: bool
    observed: string

  Scenario = object
    id, title: string
    consumerScenarios: seq[string]   ## the consumer's e2e scenarios restated
    verbs: seq[string]
    checks: seq[Check]
    notes: seq[string]               ## observations that are not checks (routes taken)
    error: string                    ## a setup failure (BLOCKED) or an exception
    elapsedMs: int

  Run = object
    label: string                    ## e.g. "linux-sway/gtk4"
    backend, toolkit: string
    selected: JsonNode               ## the session's backends, as capabilities reports
    scenarios: seq[Scenario]

  ScenarioFailure = object of CatchableError

proc passed(s: Scenario): bool =
  s.error.len == 0 and s.checks.len > 0 and s.checks.allIt(it.ok)

proc expect(s: var Scenario, name: string, ok: bool, observed = "") =
  s.checks.add Check(name: name, ok: ok, observed: observed)

proc gs13(msg: string): string =
  ## A BLOCKED line of the shared live helpers, named for this milestone.
  msg.replace("GS5-LINUX BLOCKED", "GS13-LINUX BLOCKED")

var scratchDirs: seq[(string, string)]
  ## Each run's own directories (`freshDir`) and the placeholder that stands
  ## for each in the evidence, so an error naming a file under one carries no
  ## absolute path.

proc sanitize(s: string): string =
  ## No absolute path in the evidence: this run's scratch directories, the
  ## checkout and the user's home are each replaced by a placeholder.
  result = s
  for (dir, placeholder) in scratchDirs: result = result.replace(dir, placeholder)
  result = result.replace(repoRootDir, "<repo>").replace(
    getHomeDir().strip(leading = false, chars = {'/'}), "~")

proc short(s: string, n = 160): string =
  result = s.replace('\n', ' ')
  if result.len > n: result = result[0 ..< n] & "…"

# ---------------------------------------------------------------------------
# Running the binary
# ---------------------------------------------------------------------------

var outputs: seq[string]
  ## Every stdout and stderr of every run (the passcode must be in none).

type Ga = object
  env: StringTableRef
  session: string
  stateDir: string

proc call(g: Ga, args: seq[string], input = "", inSession = true): tuple[exit: int,
    env: JsonNode, raw: string] =
  ## One `guiassert` run; `input` goes to its standard input.
  let argv = (if inSession and g.session.len > 0: @["--session", g.session] else: @[]) & args
  let p = startProcess(contractBin(), args = argv, env = g.env, options = {})
  var stdoutText, stderrText: string
  try:
    if input.len > 0: p.inputStream.write(input)
    p.inputStream.close()
    let code = p.waitForExit(verbTimeoutMs)
    if p.running:
      p.kill()
      raise newException(ScenarioFailure, "guiassert " & argv.join(" ") & " did not exit")
    stdoutText = p.outputStream.readAll()
    stderrText = p.errorStream.readAll()
    result.exit = code
  finally:
    p.close()
  outputs.add stdoutText
  outputs.add stderrText
  result.raw = stdoutText.strip & (if stderrText.len > 0: " | " & stderrText.strip else: "")
  try: result.env = parseJson(stdoutText)
  except JsonParsingError: result.env = newJNull()

proc data(g: Ga, args: seq[string], input = "", inSession = true): JsonNode =
  ## The data of a run that must succeed.
  let r = g.call(args, input, inSession)
  if r.exit != 0 or r.env.kind != JObject or not r.env{"ok"}.getBool:
    raise newException(ScenarioFailure, "guiassert " & args.join(" ") & " -> exit " &
      $r.exit & ": " & short(r.raw, 400))
  r.env["data"]

proc reason(r: tuple[exit: int, env: JsonNode, raw: string]): string =
  let er = if r.env.kind == JObject: r.env{"error"} else: nil
  if er != nil and er.kind == JObject: er{"reason"}.getStr else: ""

type Box = tuple[x, y, w, h: int]
proc boxOf(j: JsonNode): Box = (j[0].getInt, j[1].getInt, j[2].getInt, j[3].getInt)
proc centre(b: Box): (int, int) = (b.x + b.w div 2, b.y + b.h div 2)
proc at(p: (int, int)): string = $p[0] & "," & $p[1]
proc inside(p: (int, int), b: Box): bool =
  p[0] >= b.x and p[0] < b.x + b.w and p[1] >= b.y and p[1] < b.y + b.h

proc find(g: Ga, pid: int, extra: seq[string]): seq[JsonNode] =
  g.data(@["find", "--pid", $pid] & extra)["elements"].getElems

proc one(g: Ga, pid: int, name: string, role = ""): JsonNode =
  var args = @["--name", name]
  if role.len > 0: args.add @["--role", role]
  let es = g.find(pid, args)
  if es.len != 1:
    raise newException(ScenarioFailure, "not exactly one element named " & name & ": " &
      $es.len)
  es[0]

proc status(g: Ga, pid: int): string =
  ## The fixture's status label ("State: …").
  let es = g.find(pid, @["--role", "label", "--name-contains", "State: "])
  if es.len != 1:
    raise newException(ScenarioFailure, "not one status label: " & $es.len)
  es[0]["name"].getStr

proc pollStatus(g: Ga, pid: int, accept: proc (s: string): bool, ms = 10_000): string =
  ## The status once `accept` holds, or as it is after `ms`.
  let deadline = epochTime() + ms / 1000
  while true:
    result = g.status(pid)
    if accept(result) or epochTime() > deadline: return
    sleep(100)

proc trailingInt(s: string): int =
  ## The number a status ends with ("State: volume 97" → 97), else -1.
  let parts = s.splitWhitespace
  if parts.len == 0: return -1
  try: parseInt(parts[^1]) except ValueError: -1

# ---------------------------------------------------------------------------
# The fixture
# ---------------------------------------------------------------------------

var fixtureBins: array[2, string]   ## [GTK 3, GTK 4], compiled once

proc fixtureBin(work, toolkit: string): string =
  let i = if toolkit == "gtk4": 1 else: 0
  if fixtureBins[i].len == 0:
    fixtureBins[i] = compileC(work, "parity_lab_" & toolkit,
      currentSourcePath().parentDir / "fixtures" / "parity_lab.c",
      [if toolkit == "gtk4": "gtk4" else: "gtk+-3.0"])
  fixtureBins[i]

type Lab = object
  pid: int
  title: string
  windowId: string

proc launch(g: Ga, exe, gdkBackend: string, extra: seq[string] = @[]): Lab =
  ## The fixture through `app-launch`, once its Sign in button is on the
  ## session's AT-SPI bus (the readiness the consumer's bootstrap checks).
  result.title = "Parity Lab " & nonce()
  let d = g.data(@["app-launch", "--wait-window-ms", "30000", "--env",
                   "GDK_BACKEND=" & gdkBackend, "--env", "GSK_RENDERER=cairo", "--",
                   exe, "--title", result.title, "--name", appName] & extra)
  result.pid = d["app"]["pid"].getInt
  if d["window"].kind == JObject: result.windowId = d["window"]["id"].getStr
  let deadline = epochTime() + 30
  while true:
    let r = g.call(@["find", "--pid", $result.pid, "--role", "button", "--name", "Sign in"])
    if r.exit == 0 and r.env["data"]["elements"].len == 1: break
    if epochTime() > deadline:
      raise newException(ScenarioFailure, "GS13-LINUX BLOCKED: the fixture never reached " &
        "the AT-SPI bus: " & short(r.raw))
    sleep(200)

proc windowOf(g: Ga, lab: Lab): JsonNode =
  let ws = g.data(@["windows", "--pid", $lab.pid, "--title", lab.title])["windows"]
  if ws.len != 1: raise newException(ScenarioFailure, "fixture window not listed once")
  ws[0]

proc ocrWords(d: JsonNode): seq[tuple[text: string, desktop: (int, int), left: int]] =
  ## Each OCR word with the desktop point of its box centre
  ## (desktop = origin + image px / scale, spec §5).
  let img = d["image"]
  let scale = img["scale"].getFloat
  let ox = img["origin"][0].getInt
  let oy = img["origin"][1].getInt
  for w in d["words"]:
    let b = boxOf(w["bbox"])
    result.add (w["text"].getStr,
                (ox + int((b.x.float + b.w.float / 2) / scale),
                 oy + int((b.y.float + b.h.float / 2) / scale)),
                ox + int(b.x.float / scale))

proc hasWord(d: JsonNode, word: string): bool =
  d["words"].getElems.anyIt(it["text"].getStr.toUpperAscii == word) or
    word in d["text"].getStr.toUpperAscii.splitWhitespace

# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------

proc scenario(id, title: string, consumer, verbs: seq[string]): Scenario =
  Scenario(id: id, title: title, consumerScenarios: consumer, verbs: verbs)

template guarded(s: var Scenario, body: untyped) =
  let t0 = getMonoTime()
  try:
    body
  except CatchableError, Defect:
    s.error = gs13(getCurrentExceptionMsg()).short(400)
  s.elapsedMs = int((getMonoTime() - t0).inMilliseconds)

proc s2Capabilities(g: Ga, run: var Run, backend: string): Scenario =
  result = scenario("S2", "capability report of a live session",
    @["e2e_linux_doctor_reports_capabilities"], @["capabilities --probe --session"])
  guarded(result):
    let d = g.data(@["capabilities", "--probe"])
    run.selected = d["selected"]
    result.expect("platform is linux", d["platform"].getStr == "linux", d["platform"].getStr)
    let want = case backend
      of "linux-sway": ["linux-wlr", "linux-atspi", "linux-wlr-virtual"]
      of "linux-xvfb": ["linux-x11", "linux-atspi", "linux-xtest"]
      else: ["linux-gnome", "linux-atspi", "linux-mutter"]
    let sel = d["selected"]
    result.expect("selected backends follow the session",
      sel["capture"].getStr == want[0] and sel["tree"].getStr == want[1] and
        sel["input"].getStr == want[2] and sel["session"].getStr == backend and
        sel["ocr"].getStr == "tesseract", $sel)
    let vocab = specFeatures().mapIt(it[0])
    let names = d["features"].getElems.mapIt(it["feature"].getStr)
    result.expect("every feature of the vocabulary exactly once",
      names.len == vocab.len and vocab.allIt(names.count(it) == 1), $names.len & " of " &
        $vocab.len)
    var reasonsOk = true
    for f in d["features"]:
      let st = f["state"].getStr
      let hasReason = f["reason"].kind == JString and f["reason"].getStr.len > 0
      if (st in ["available", "supported"]) == hasReason: reasonsOk = false
    result.expect("a reason exactly where a feature is not available", reasonsOk)
    # What the consumer's scenarios need, available in the session.
    var missing: seq[string]
    for need in ["window-enumeration", "display-capture", "window-capture", "region-capture",
                 "recording", "ocr", "tree-read", "element-actions", "pointer-input",
                 "keyboard-input", "app-management", "session-management"]:
      let entries = d["features"].getElems.filterIt(it["feature"].getStr == need)
      if entries.len == 0: missing.add need & "=absent"
      for f in entries:
        if f["state"].getStr notin ["available", "supported", "degraded"]:
          missing.add need & "=" & f["state"].getStr & "/" & f["reason"].getStr
    result.expect("the features the scenarios need are usable (degraded counts, with its reason)", missing.len == 0,
      missing.join(","))
    # Negative control: a session that does not exist is not reported.
    let none = Ga(env: g.env, session: "no-such-parity-session").call(@["capabilities"])
    result.expect("an unknown session is exit 3 / not-found", none.exit == 3,
      "exit " & $none.exit & " " & reason(none))

proc s3Find(g: Ga, lab: Lab): Scenario =
  result = scenario("S3", "element find by role, name and state",
    @["e2e_linux_find_elements_filters_role_name_and_state"],
    @["find --role", "find --state", "find --name", "find --name-contains --ignore-case",
      "element"])
  guarded(result):
    # A compositor without server-side decorations (GNOME) makes the toolkit
    # draw its own window controls, which are buttons too; they are not the
    # form's and are left out of the comparison.
    const decorations = ["Close", "Minimize", "Maximize", "Restore"]
    let buttons = g.find(lab.pid, @["--role", "button"]).filterIt(
      it["name"].getStr notin decorations)
    let names = buttons.mapIt(it["name"].getStr)
    result.expect("role button finds Sign in and Archive",
      names.len == 2 and "Sign in" in names and "Archive" in names, $names)
    let enabled = g.find(lab.pid, @["--role", "button", "--state", "enabled"]).filterIt(
      it["name"].getStr notin decorations)
    result.expect("state enabled keeps only Sign in",
      enabled.len == 1 and enabled[0]["name"].getStr == "Sign in", $enabled.mapIt(it["name"]))
    let archive = buttons.filterIt(it["name"].getStr == "Archive")
    result.expect("the disabled button carries no enabled state",
      archive.len == 1 and "enabled" notin archive[0]["states"].getElems.mapIt(it.getStr),
      if archive.len == 1: $archive[0]["states"] else: "")
    let fields = g.find(lab.pid, @["--role", "text-field", "--state", "editable", "--name",
                                   "Account"])
    result.expect("an editable text-field named Account, once", fields.len == 1)
    if fields.len == 1:
      let again = g.find(lab.pid, @["--role", "text-field", "--name", "Account"])
      result.expect("its path is stable across reads",
        again.len == 1 and again[0]["path"] == fields[0]["path"], fields[0]["path"].getStr)
      let el = g.data(@["element", fields[0]["path"].getStr])["element"]
      result.expect("element <path> resolves to it", el["name"].getStr == "Account" and
        el["role"].getStr == "text-field")
    let ci = g.find(lab.pid, @["--name-contains", "sign", "--ignore-case", "--role", "button"])
    result.expect("name-contains --ignore-case finds Sign in",
      ci.len == 1 and ci[0]["name"].getStr == "Sign in")
    # Negative control: matching is case-sensitive without --ignore-case.
    let cs = g.find(lab.pid, @["--name-contains", "sign", "--role", "button"])
    result.expect("without --ignore-case the lower-case needle finds nothing", cs.len == 0,
      $cs.len)

proc s4Form(g: Ga, lab: Lab): Scenario =
  result = scenario("S4", "form fill, submit and status readback",
    @["e2e_linux_form_fill_submit_and_status_readback"],
    @["element-action focus", "type --stdin", "key Tab", "element-action press", "wait --element"])
  guarded(result):
    result.expect("status idle before submit (negative control)",
      g.status(lab.pid) == "State: idle", g.status(lab.pid))
    let acct = g.one(lab.pid, "Account", "text-field")
    # Focus the field the way the consumer's `focus <path>` does
    # (element-action focus); a toolkit whose node offers no focus action
    # (GTK 4 implements no AT-SPI GrabFocus) is focused by a click at its
    # centre instead, and the evidence says which route was taken.
    if "focus" in acct["actions"].getElems.mapIt(it.getStr):
      discard g.data(@["element-action", acct["path"].getStr, "focus"])
      result.notes.add "Account focused by element-action focus"
    else:
      discard g.data(@["click", "--at", at(centre(boxOf(acct["bounds"])))])
      result.notes.add "Account offers no focus action (actions " & $acct["actions"] &
        "); focused by a click at its centre"
      sleep(200)
    let t = g.data(@["type", "--stdin"], input = account)["input"]
    result.expect("type reports the length, not the text",
      t["length"].getInt == account.len and account notin $t)
    var v = ""
    for _ in 1 .. 30:
      v = g.one(lab.pid, "Account", "text-field")["value"].getStr
      if v == account: break
      sleep(100)
    result.expect("the Account field holds the typed text", v == account, v)
    # Tab, then the passcode: it must land in Passcode, which is protected (no
    # value to read), so the effect is read back as the Account field left
    # unchanged and the length the submission reports below.
    discard g.data(@["key", "Tab"])
    let focusedNow = g.find(lab.pid, @["--state", "focused"]).mapIt(it["name"].getStr)
    result.notes.add "focused after Tab: " & $focusedNow
    discard g.data(@["type", "--stdin"], input = passcode)
    sleep(300)
    let after = g.one(lab.pid, "Account", "text-field")["value"].getStr
    result.expect("after Tab the typing no longer reaches Account", after == account, after)
    let p = g.one(lab.pid, "Passcode", "text-field")
    result.expect("the passcode field is protected and reports no value",
      "protected" in p["states"].getElems.mapIt(it.getStr) and p["value"].kind == JNull and
        p["text"].kind == JNull)
    let signIn = g.one(lab.pid, "Sign in", "button")
    discard g.data(@["element-action", signIn["path"].getStr, "press"])
    let want = "State: signed in 1 as " & account & "; passcode of " & $passcode.len &
               " characters"
    let w = g.call(@["wait", "--element", "--pid", $lab.pid, "--role", "label", "--name", want,
                     "--wait-ms", "10000"])
    result.expect("the status label reads back the submission", w.exit == 0,
      g.status(lab.pid))
    result.expect("the passcode appears in no output", outputs.allIt(passcode notin it))

proc s1Pointer(g: Ga, lab: Lab): Scenario =
  result = scenario("S1", "click, scroll and drag roundtrip",
    @["e2e_linux_click_scroll_drag_roundtrip", "e2e_linux_zero_touch_session_bootstrap"],
    @["click --at", "scroll --at", "drag --from --to", "element-action set-value"])
  guarded(result):
    let before = g.status(lab.pid)
    let n0 = if before.startsWith("State: signed in "): parseInt(before.splitWhitespace[3])
             else: 0
    # Click: the disabled Archive button does nothing (negative control),
    # Sign in counts one more sign-in.
    let archive = boxOf(g.one(lab.pid, "Archive", "button")["bounds"])
    discard g.data(@["click", "--at", at(centre(archive))])
    sleep(400)
    result.expect("a click on the disabled button changes nothing", g.status(lab.pid) == before,
      g.status(lab.pid))
    let signIn = boxOf(g.one(lab.pid, "Sign in", "button")["bounds"])
    let c = g.data(@["click", "--at", at(centre(signIn))])["input"]
    result.expect("the click is reported at the requested point",
      c["at"] == %*[centre(signIn)[0], centre(signIn)[1]] and c["delivery"].getStr == "injected")
    let want = "State: signed in " & $(n0 + 1) & " as "
    let after = g.pollStatus(lab.pid, proc (s: string): bool = s.startsWith(want))
    result.expect("the click on Sign in activates it", after.startsWith(want), after)
    # Scroll: over the signboard nothing scrolls (negative control); over
    # the rows the list scrolls.
    let sign = boxOf(g.one(lab.pid, "Signboard")["bounds"])
    discard g.data(@["scroll", "--at", at(centre(sign)), "--dx", "0", "--dy", "3"])
    sleep(400)
    result.expect("a scroll beside the list scrolls nothing",
      not g.status(lab.pid).startsWith("State: scrolled"), g.status(lab.pid))
    # The scrolled area, not the list inside it: the list is taller than the
    # area, so its centre can lie outside what is shown.
    let areas = g.find(lab.pid, @["--role", "scroll-area"])
    # GTK 3 reports the scrolled window and its viewport, both the shown area.
    if areas.len notin 1 .. 2:
      raise newException(ScenarioFailure, "not one scrolled area: " & $areas.len)
    let rows = boxOf(areas[0]["bounds"])
    discard g.data(@["scroll", "--at", at(centre(rows)), "--dx", "0", "--dy", "3"])
    let scrolled = g.pollStatus(lab.pid, proc (s: string): bool =
      s.startsWith("State: scrolled ") and trailingInt(s) > 0)
    result.expect("a scroll over the list moves it down",
      scrolled.startsWith("State: scrolled ") and trailingInt(scrolled) > 0, scrolled)
    # Drag: the slider's knob from the middle to the right end.
    let vol = g.one(lab.pid, "Volume", "slider")
    discard g.data(@["element-action", vol["path"].getStr, "set-value", "--value", "50"])
    let level = boxOf(vol["bounds"])
    let v0 = g.one(lab.pid, "Volume", "slider")["value"].getStr
    result.expect("the slider is at 50 before the drag (negative control)",
      v0 in ["50", "50.0"], v0)
    let d = g.data(@["drag", "--from", at(centre(level)),
                     "--to", at((level.x + level.w - 2, level.y + level.h div 2)),
                     "--steps", "8", "--duration-ms", "400"])["input"]
    result.expect("the drag reports its path", d["path"].len == 2)
    let dragged = g.pollStatus(lab.pid, proc (s: string): bool =
      s.startsWith("State: volume ") and trailingInt(s) >= 90)
    result.expect("the drag moves the slider to the right end",
      dragged.startsWith("State: volume ") and trailingInt(dragged) >= 90, dragged)

proc s5Ocr(g: Ga, lab: Lab, work: string): Scenario =
  result = scenario("S5", "OCR of a canvas-drawn fixture",
    @["e2e_linux_ocr_extracts_text_from_canvas_fixture"], @["windows", "ocr --window", "find"])
  guarded(result):
    let tree = g.data(@["tree", "--pid", $lab.pid])
    let treeText = ($tree).toUpperAscii
    result.expect("the painted words are in no accessible node (negative control)",
      "LANTERN" notin treeText and "COPPER" notin treeText)
    let win = g.windowOf(lab)
    let d = g.data(@["ocr", "--window", win["id"].getStr, "--out", work / "ocr-window.png",
                     "--lang", "eng"])
    let found = signWords.filterIt(d.hasWord(it))
    result.expect("OCR reads every painted word", found.len == signWords.len,
      found.join(" ") & " | " & d["text"].getStr.short(80))
    let sign = boxOf(g.one(lab.pid, "Signboard")["bounds"])
    var placed = true
    var firstLeft = -1
    for w in ocrWords(d):
      if w.text.toUpperAscii in signWords and not inside(w.desktop, sign): placed = false
      if w.text.toUpperAscii == signWords[0] and firstLeft < 0: firstLeft = w.left
    result.expect("each painted word maps inside the canvas's desktop bounds", placed,
      $sign)
    # The fixture paints its text 16 px from the canvas's left edge: the first
    # word's box, mapped to the desktop, starts there (within a glyph's side
    # bearing), so a box offset anywhere along the line is caught.
    result.expect("the first painted word starts where it is painted (16 px in, ±10 px)",
      firstLeft >= 0 and abs(firstLeft - (sign.x + 16)) <= 10,
      "word at x " & $firstLeft & ", canvas at x " & $sign.x)
    result.expect("the capture is the window's", d["image"]["source"]["kind"].getStr in
      ["window", "window-crop"], d["image"]["source"]["kind"].getStr)

proc s9TreeThenOcr(g: Ga, lab: Lab, work: string): Scenario =
  result = scenario("S9", "tree-then-OCR text extraction",
    @["e2e_linux_visual_fallback_trace_shows_tree_then_ocr"],
    @["find", "element", "ocr --region"])
  guarded(result):
    # Stage 1, the tree: the canvas is found, but it carries no text.
    let node = g.one(lab.pid, "Signboard")
    let el = g.data(@["element", node["path"].getStr])["element"]
    result.expect("the tree stage finds the canvas without text",
      el["text"].kind == JNull and el["value"].kind == JNull and el["bounds"].kind == JArray)
    # Contrast: a button's text is in the tree (that stage suffices there).
    result.expect("a labelled button needs no OCR",
      g.one(lab.pid, "Sign in", "button")["name"].getStr == "Sign in")
    # Stage 2, OCR of the element's own bounds.
    let b = boxOf(el["bounds"])
    let d = g.data(@["ocr", "--region", $b.x & "," & $b.y & "," & $b.w & "," & $b.h,
                     "--out", work / "ocr-region.png", "--lang", "eng"])
    let found = signWords.filterIt(d.hasWord(it))
    result.expect("OCR of the element's bounds reads its text", found.len == signWords.len,
      found.join(" ") & " | " & d["text"].getStr.short(80))
    result.expect("the capture is the element's region",
      d["image"]["origin"] == %*[b.x, b.y] and d["image"]["source"]["kind"].getStr == "region",
      $d["image"]["origin"])
    # Negative control: the region of the Account field holds none of them.
    let acct = boxOf(g.one(lab.pid, "Account", "text-field")["bounds"])
    let n = g.data(@["ocr", "--region", $acct.x & "," & $acct.y & "," & $acct.w & "," & $acct.h,
                     "--out", work / "ocr-account.png", "--lang", "eng"])
    result.expect("OCR of another element's bounds does not read the canvas",
      signWords.allIt(not n.hasWord(it)), n["text"].getStr.short(60))

proc s6Capture(g: Ga, lab: Lab, work, preLaunchShot: string): Scenario =
  result = scenario("S6", "screenshot and recording pipeline",
    @["e2e_linux_screenshot_recording_pipeline"],
    @["screenshot", "record --duration-ms", "record-start", "record-stop", "ocr --image"])
  guarded(result):
    let shot = work / "display.png"
    let img = g.data(@["screenshot", "--out", shot])["image"]
    let png = loadPng(shot)
    result.expect("the PNG decodes to the reported size",
      png.width == img["width"].getInt and png.height == img["height"].getInt,
      $png.width & "x" & $png.height)
    result.expect("the display capture is the session's display size",
      img["width"].getInt == displayW and img["height"].getInt == displayH)
    let seen = g.data(@["ocr", "--image", shot, "--lang", "eng"], inSession = false)
    result.expect("the screenshot shows the fixture", seen.hasWord("LANTERN"))
    if preLaunchShot.len > 0:
      let empty = g.data(@["ocr", "--image", preLaunchShot, "--lang", "eng"], inSession = false)
      result.expect("a capture from before the launch does not (negative control)",
        not empty.hasWord("LANTERN"))
    let win = g.windowOf(lab)
    let wimg = g.data(@["screenshot", "--window", win["id"].getStr, "--out",
                        work / "window.png"])["image"]
    let wb = boxOf(win["bounds"])
    result.expect("a window capture is the window's size",
      wimg["width"].getInt == wb.w and wimg["height"].getInt == wb.h,
      $wimg["width"] & "x" & $wimg["height"] & " vs " & $wb)
    let mp4 = work / "record.mp4"
    let rec = g.data(@["record", "--out", mp4, "--duration-ms", "3000"])["recording"]
    let probe = ffprobeVideo(mp4)
    result.expect("record: a finalized MP4 of the reported size",
      rec["state"].getStr == "stopped" and probe.width == rec["width"].getInt and
        probe.height == rec["height"].getInt and probe.frames > 0,
      $probe.width & "x" & $probe.height & " " & $probe.frames & " frames")
    result.expect("record: duration about 3 s (2.5 s .. 4.5 s)",
      probe.durationMs >= 2500 and probe.durationMs <= 4500 and
        abs(rec["durationMs"].getInt - probe.durationMs) <= 250,
      $probe.durationMs & " ms, reported " & $rec["durationMs"])
    let mp4b = work / "record-start.mp4"
    let started = g.data(@["record-start", "--out", mp4b])["recording"]
    result.expect("record-start returns a recording in progress",
      started["state"].getStr == "recording" and started["id"].getStr.len > 0)
    sleep(2000)
    let stopped = g.data(@["record-stop", started["id"].getStr])["recording"]
    let probeB = ffprobeVideo(mp4b)
    result.expect("record-stop finalizes it",
      stopped["state"].getStr == "stopped" and probeB.frames > 0 and
        probeB.durationMs >= 1500 and stopped["durationMs"].getInt >= 1500,
      $probeB.durationMs & " ms")

proc s7Wait(g: Ga, exe, gdkBackend: string): Scenario =
  result = scenario("S7", "waiting for a timer-driven dialog",
    @["e2e_linux_wait_observes_timer_driven_dialog"],
    @["app-launch", "wait --element --role dialog", "wait --window", "app-quit"])
  guarded(result):
    let lab = g.launch(exe, gdkBackend, @["--dialog-after-ms", "2500"])
    let t0 = epochTime()
    try:
      let early = g.call(@["wait", "--element", "--pid", $lab.pid, "--role", "dialog",
                           "--wait-ms", "300"])
      result.expect("before the timer the wait expires (negative control)",
        early.exit == 7 and reason(early) == "condition-not-met",
        "exit " & $early.exit & " " & reason(early))
      let w = g.data(@["wait", "--element", "--pid", $lab.pid, "--role", "dialog", "--name",
                       "Reminder", "--wait-ms", "20000", "--interval-ms", "100"])
      let waited = int((epochTime() - t0) * 1000)
      result.expect("the wait resolves on the dialog",
        w["matched"].getBool and w["element"]["name"].getStr == "Reminder" and
          w["attempts"].getInt >= 2, $w["attempts"] & " attempts")
      result.expect("it resolves after the timer, not before",
        waited >= 1500 and waited < 20_000, $waited & " ms")
      let ww = g.data(@["wait", "--window", "--pid", $lab.pid, "--title", "Reminder",
                        "--wait-ms", "10000"])
      result.expect("the dialog's window is enumerated",
        ww["matched"].getBool and ww["window"]["title"].getStr == "Reminder")
    finally:
      discard g.call(@["app-quit", $lab.pid])

# ---------------------------------------------------------------------------
# One run: a session, the fixture, every scenario, teardown
# ---------------------------------------------------------------------------

proc wanted(only: seq[string], id: string): bool = only.len == 0 or id in only

proc runOne(backend, toolkit: string, only: seq[string]): Run =
  result = Run(label: backend & "/" & toolkit, backend: backend, toolkit: toolkit,
               selected: newJNull())
  let st = freshDir("parity-st")
  let work = freshDir("parity-work")
  scratchDirs.add (st, "<state>")
  scratchDirs.add (work, "<work>")
  let name = "parity-" & backend[6 .. ^1] & "-" & toolkit
  var g = Ga(env: runEnv(st, newStringTable(modeCaseSensitive)), stateDir: st)
  let gdkBackend = if backend == "linux-xvfb": "x11" else: "wayland"
  var s8 = scenario("S8", "zero-touch session bootstrap and teardown",
    @["e2e_linux_zero_touch_session_bootstrap"],
    @["session-start --kind headless", "session-info", "session-list", "app-launch",
      "find", "session-stop"])
  var lab: Lab
  var started = false
  var tag, runtimeDir: string
  var preLaunchShot = ""
  let t0 = getMonoTime()
  try:
    let exe = fixtureBin(work, toolkit)
    let absent = g.call(@["session-info", name], inSession = false)
    s8.expect("the session does not exist before the start (negative control)",
      absent.exit == 3, "exit " & $absent.exit)
    let s = g.data(@["--session-backend", backend, "session-start", "--kind", "headless",
                     "--name", name, "--width", $displayW, "--height", $displayH],
                   inSession = false)["session"]
    started = true
    g.session = name
    s8.expect("session-start returns a running headless session",
      s["state"].getStr == "running" and s["kind"].getStr == "headless" and
        s["backend"].getStr == backend, s["state"].getStr)
    let env = s["env"]
    let displayKey = if backend == "linux-xvfb": "DISPLAY" else: "WAYLAND_DISPLAY"
    s8.expect("its environment names a private display and buses",
      [displayKey, "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS", "AT_SPI_BUS_ADDRESS"].allIt(
        env.hasKey(it) and env[it].getStr.len > 0))
    runtimeDir = env["XDG_RUNTIME_DIR"].getStr
    var info: posix.Stat
    s8.expect("its runtime directory is the caller's, mode 0700",
      posix.stat(runtimeDir.cstring, info) == 0 and (info.st_mode.int and 0o777) == 0o700 and
        info.st_uid == posix.getuid())
    tag = parseJson(readFile(st / "sessions" / (name & ".json")))["private"]["tag"].getStr
    let listed = g.data(@["session-list"], inSession = false)["sessions"].getElems
    s8.expect("session-list has it", listed.anyIt(it["id"].getStr == name and
      it["state"].getStr == "running"))
    preLaunchShot = work / "pre-launch.png"
    discard g.data(@["screenshot", "--out", preLaunchShot])
    lab = g.launch(exe, gdkBackend)
    s8.expect("a launched client is on the session's AT-SPI bus and listed",
      g.windowOf(lab)["pid"].getInt == lab.pid)
  except CatchableError, Defect:
    s8.error = gs13(getCurrentExceptionMsg()).short(400)
    if not started and "BLOCKED" notin s8.error:
      s8.error = "GS13-LINUX BLOCKED: the " & backend & " session did not start: " & s8.error
  if s8.error.len == 0:
    if wanted(only, "S2"): result.scenarios.add s2Capabilities(g, result, backend)
    if wanted(only, "S3"): result.scenarios.add s3Find(g, lab)
    if wanted(only, "S4"): result.scenarios.add s4Form(g, lab)
    if wanted(only, "S1"): result.scenarios.add s1Pointer(g, lab)
    if wanted(only, "S5"): result.scenarios.add s5Ocr(g, lab, work)
    if wanted(only, "S9"): result.scenarios.add s9TreeThenOcr(g, lab, work)
    if wanted(only, "S6"): result.scenarios.add s6Capture(g, lab, work, preLaunchShot)
    if wanted(only, "S7"):
      result.scenarios.add s7Wait(g, fixtureBin(work, toolkit), gdkBackend)
  else:
    # The session never came up: every scenario of the run fails with it.
    for (id, title) in [("S1", "click, scroll and drag roundtrip"),
                        ("S2", "capability report of a live session"),
                        ("S3", "element find by role, name and state"),
                        ("S4", "form fill, submit and status readback"),
                        ("S5", "OCR of a canvas-drawn fixture"),
                        ("S6", "screenshot and recording pipeline"),
                        ("S7", "waiting for a timer-driven dialog"),
                        ("S9", "tree-then-OCR text extraction")]:
      if wanted(only, id):
        var s = scenario(id, title, @[], @[])
        s.error = "the session did not start: " & s8.error
        result.scenarios.add s
  # Teardown, part of S8: nothing of the session remains.
  if started:
    try:
      let stopped = g.data(@["session-stop", name], inSession = false)["session"]
      s8.expect("session-stop reports it stopped", stopped["state"].getStr == "stopped")
      let gone = g.call(@["session-info", name], inSession = false)
      s8.expect("session-info no longer finds it", gone.exit == 3, "exit " & $gone.exit)
      s8.expect("its record is gone", not fileExists(st / "sessions" / (name & ".json")))
      var left = taggedProcesses(tag)
      let deadline = epochTime() + 10
      while left.len > 0 and epochTime() < deadline:
        sleep(100)
        left = taggedProcesses(tag)
      s8.expect("no process of the session is left", left.len == 0, $left.len & " left")
      s8.expect("the fixture is gone with it",
        lab.pid == 0 or not dirExists("/proc/" & $lab.pid), $lab.pid)
      s8.expect("its runtime directory is gone", not dirExists(runtimeDir))
    except CatchableError, Defect:
      if s8.error.len == 0: s8.error = getCurrentExceptionMsg().short(400)
      discard g.call(@["session-stop", name, "--force"], inSession = false)
  s8.elapsedMs = int((getMonoTime() - t0).inMilliseconds)
  if wanted(only, "S8"): result.scenarios.add s8

# ---------------------------------------------------------------------------
# Evidence
# ---------------------------------------------------------------------------

proc gitCommit(): string =
  let (o, code) = execCmdEx("git -C " & quoteShell(repoRootDir) &
                            " describe --always --dirty --abbrev=10")
  if code == 0: o.strip else: "unknown"

proc writeEvidence(path: string, runs: seq[Run], version: JsonNode) =
  ## `guiassert-parity/1`: what was run, where, and every check's outcome.
  ## Only invented fixture strings, backend names and numbers: no path, user
  ## or host name.
  var rs = newJArray()
  for r in runs:
    var ss = newJArray()
    for s in r.scenarios:
      var cs = newJArray()
      for c in s.checks: cs.add %*{"check": c.name, "ok": c.ok, "observed": sanitize(c.observed)}
      ss.add %*{"id": s.id, "scenario": s.title, "consumerScenarios": s.consumerScenarios,
                "verbs": s.verbs, "result": (if s.passed: "pass" else: "fail"),
                "error": (if s.error.len > 0: %sanitize(s.error) else: newJNull()),
                "elapsedMs": s.elapsedMs, "notes": s.notes.mapIt(sanitize(it)), "checks": cs}
    rs.add %*{"run": r.label, "sessionBackend": r.backend, "toolkit": r.toolkit,
              "selected": r.selected, "scenarios": ss}
  let (kernel, _) = execCmdEx("uname -r")
  let doc = %*{
    "schema": "guiassert-parity/1",
    "milestone": "GS13",
    "platform": "linux",
    "arch": hostCPU,
    "kernel": kernel.strip,
    "measuredAt": now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
    "guiassert": {"commit": gitCommit(), "version": version},
    "display": [displayW, displayH],
    "runs": rs,
    "outOfScope": [
      {"consumerScenario": "e2e_linux_remote_view_start_stop_preserves_session_identity",
       "why": "remote view is a consumer surface (Desktop-Substrate.md §11)"},
      {"consumerScenario": "e2e_linux_isolated_session_rustdesk_click_roundtrip",
       "why": "RustDesk remote view is a consumer surface; the consumer's own test skips it"},
      {"consumerScenario": "e2e_linux_orca_form_labels_required_state_and_alerts",
       "why": "screen-reader speech capture is not in this initiative"},
      {"consumerScenario": "e2e_linux_orca_read_all_matches_golden_transcript",
       "why": "screen-reader speech capture is not in this initiative"},
      {"consumerScenario": "e2e_linux_speech_dispatcher_module_emits_ndjson",
       "why": "screen-reader speech capture is not in this initiative"},
      {"consumerScenario": "e2e_linux_appium_and_orca_run_concurrently_without_loss",
       "why": "speech capture alongside a tree backend; the tree half is S3/S4"},
      {"consumerScenario": "e2e_linux_mcp_roundtrip_matches_cli_tree_output",
       "why": "MCP is a consumer surface; CLI/serve parity is the contract suite's"},
      {"consumerScenario": "e2e_linux_run_script_stdin_roundtrip_with_artifacts",
       "why": "script running is a consumer surface"},
      {"consumerScenario": "e2e_linux_agent_owned_profile_persists_login_without_profile_transfer",
       "why": "browser profiles are a consumer surface; no desktop verb is involved"},
      {"consumerScenario": "e2e_linux_appium_backend_attaches_to_gtk_fixture",
       "why": "the consumer's Appium driver; GuiAssert reads the same AT-SPI tree directly (S3, S8)"}]}
  createDir(path.parentDir)
  writeFile(path, doc.pretty & "\n")

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

proc main(): int =
  var evidence = repoRootDir / "build" / "parity" / "linux-parity.json"
  var sessions = @["sway", "xvfb"]
  var toolkits = @["gtk3", "gtk4"]
  var only: seq[string]
  # `--key value` as well as `--key=value` (a non-empty longNoVal enables it).
  for kind, key, val in getopt(commandLineParams(), longNoVal = @["help"]):
    case kind
    of cmdLongOption:
      case key
      of "evidence": evidence = absolutePath(val)
      of "sessions": sessions = val.split(',')
      of "toolkits": toolkits = val.split(',')
      of "only": only = val.split(',')
      else:
        stderr.writeLine "linux_parity: unknown option --" & key
        return 2
    else:
      stderr.writeLine "linux_parity: unexpected argument " & key
      return 2
  let version = Ga(env: baseEnv()).data(@["version"], inSession = false)
  var runs: seq[Run]
  for s in sessions:
    let backend = case s
      of "sway": "linux-sway"
      of "xvfb": "linux-xvfb"
      of "gnome": "linux-gnome"
      else:
        stderr.writeLine "linux_parity: unknown session " & s
        return 2
    for tk in toolkits:
      if tk notin ["gtk3", "gtk4"]:
        stderr.writeLine "linux_parity: unknown toolkit " & tk
        return 2
      let r = runOne(backend, tk, only)
      for sc in r.scenarios:
        var line = "PARITY " & r.label & " " & sc.id & " " &
                   (if sc.passed: "PASS" else: "FAIL") & " (" &
                   $sc.checks.countIt(it.ok) & "/" & $sc.checks.len & " checks, " &
                   $sc.elapsedMs & " ms) " & sc.title
        if sc.error.len > 0: line.add " — " & sc.error
        else:
          for c in sc.checks:
            if not c.ok:
              line.add " — failed: " & c.name & (if c.observed.len > 0: " [" & c.observed & "]"
                                                 else: "")
              break
        echo line
      runs.add r
  writeEvidence(evidence, runs, version)
  # Nothing this harness started may outlive it.
  var left = ownProcesses()
  let deadline = epochTime() + 10
  while left.len > 0 and epochTime() < deadline:
    sleep(100)
    left = ownProcesses()
  killProcesses(left)
  cleanupFreshDirs()
  let failed = runs.mapIt(it.scenarios.countIt(not it.passed)).foldl(a + b, 0)
  let total = runs.mapIt(it.scenarios.len).foldl(a + b, 0)
  echo "PARITY SUMMARY ", total - failed, "/", total, " scenario runs passed",
       (if left.len > 0: "; " & $left.len & " leftover process(es) killed" else: ""),
       "; evidence: ", evidence.relativePath(repoRootDir)
  if failed > 0 or left.len > 0: 1 else: 0

when isMainModule:
  quit(main())
