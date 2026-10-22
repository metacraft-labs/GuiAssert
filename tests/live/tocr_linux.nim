## The Linux live OCR suite (GS6): the REAL `guiassert` binary with the
## `tesseract` OCR engine (the Linux default, the flake's pinned tesseract and
## traineddata) reading frames that the Linux capture backends of GS5 capture
## from display servers this suite starts for itself (spec §4.2, §5, §9.3):
##
## * a private **Xvfb** (no TCP listener) for `linux-x11`;
## * a private **headless sway** for `linux-wlr`, once at scale 1 and once
##   with its output at **scale 2** (physical pixels twice the logical ones),
##   and on the scale-1 sway the **portal stack** for `linux-portal-pipewire`;
## * a private **headless GNOME Shell** for `linux-gnome`.
##
## None of them is connected to the operator's display (`linux_live`).
##
## Run it with `just test-live-linux` (inside `nix develop`; builds the CLI
## first, and runs the GS5 capture suite before this one), or
## `nim c -r --hints:off tests/live/tocr_linux.nim`.
##
## **The fixture.** Every window read here is a real client of the real
## server showing an invented label image: two lines of text drawn by the
## pinned ffmpeg in the flake's DejaVu Sans (`ocr_live.renderLines`), whose
## ink rectangles are measured from the rendered pixels (`ocr_live.inkWords`)
## and which is shown pixel for pixel by GuiAssert's own helpers (`wm_probe
## image=` on Wayland, `x11_probe window --image` on X11, both reading the
## binary PPM of those very pixels). So where each word lies on the desktop is
## known in advance: the window's position (from the server: sway's IPC, the
## Shell, or the geometry Xvfb was asked for) plus the word's measured ink.
##
## **What is checked.** `ocr --window | --display | --region … --out` returns
## words whose boxes, mapped through the captured image's `origin` and
## `scale` (`desktop = origin + image / scale`, `core/geometry`), land on the
## measured ink on the desktop within `boxSlack` (1) logical pixel per edge
## (measured exact on every backend, at scale 2 too; the one pixel allows
## for rounding in the mapping), with confidences in 0..100, the text in
## reading order and words of one line on one `line`. Languages are
## selected and reported (`--lang deu --lang eng`); an uninstalled language,
## a missing tesseract and a tesseract without its default traineddata are
## exit 4 with their reasons, `details.feature` `ocr`, and leave no frame
## behind. Capabilities report the engine's `ocr` feature (C7), and no
## recognized text reaches GuiAssert's stderr, a `serve` event, the daemon's
## stderr or a state record (C15).
##
## `linux-portal-pipewire` cannot be pointed at a display, window or region
## (spec §4.2; GS5), and `ocr` with a capture needs one of them (§7.5), so
## there OCR is applied to the portal's own screenshot (`ocr --image`) mapped
## through that screenshot's `origin` and `scale`, and `ocr --display` is
## checked to be refused before anything is captured.
##
## **Negative controls.** A region of the background reads no words; a region
## holding only the first line reads only its words; a mapping that ignored
## the origin or the scale would put every word elsewhere (the windows are
## placed away from the desktop origin, and the scale-2 output makes the
## scale matter).
##
## Stand-ins: none. A server that cannot start fails every test that needs
## it with a `GS6-LINUX BLOCKED:` line; nothing here skips.

when not defined(linux):
  {.error: "tests/live/tocr_linux.nim runs on Linux only".}

import std/[json, os, osproc, streams, strtabs, strutils, unittest]

import ../contract/harness
import ./linux_live
import ./ocr_live
import ../../src/gui_assert/core/geometry

const
  labelSize = Size(width: 480, height: 160)
  labelFont = 40
  lineOne = ("QUARTZ 4719", point(24, 24))
  lineTwo = ("PELICAN DOCK", point(24, 92))
  labelText = "QUARTZ 4719\nPELICAN DOCK"
  labelWords = ["QUARTZ", "4719", "PELICAN", "DOCK"]
  boxSlack = 1
    ## How far (logical px) a mapped word box may lie from its ink on the
    ## desktop: tighter than `ocr_live.inkSlack` (3), which also covers
    ## images no compositor showed; measured 0 here.

type
  Label = object
    ## The fixture image: its PPM for a window, and each word's ink in the
    ## image's pixels.
    ppm: string
    ink: seq[(string, geometry.Rect)]

proc gs6(msg: string): string = msg.replace("GS5-LINUX BLOCKED", "GS6-LINUX BLOCKED")

proc makeLabel(dir: string, lines = @[lineOne, lineTwo], name = "label"): Label =
  ## The label image in `dir`, its ink measured row by row.
  let png = dir / (name & ".png")
  renderLines(png, labelSize, lines, fontSize = labelFont)
  result.ppm = dir / (name & ".ppm")
  pngToPpm(png, result.ppm)
  for (text, at) in lines:
    let rects = inkWords(png, (at.y - 8, at.y + labelFont + 12), dark = true,
                         fontSize = labelFont)
    let words = text.splitWhitespace
    doAssert rects.len == words.len, "ink of '" & text & "': " & $rects
    for i, w in words: result.ink.add (w, rects[i])

proc inkOf(l: Label, word: string): geometry.Rect =
  for (w, r) in l.ink:
    if w == word: return r
  doAssert false, word & " is not on the label"

proc onDesktop(r: geometry.Rect, at: Point): geometry.Rect = rect(at.x + r.x, at.y + r.y, r.width, r.height)

proc imageOrigin(img: JsonNode): Point = point(img["origin"][0].getInt, img["origin"][1].getInt)

template mustRead(args: seq[string], env: StringTableRef, stderrs: var seq[string]): JsonNode =
  ## The data of a successful `guiassert` run, its stderr kept for C15.
  ## (Templates, not procs, so that `check` counts against the test.)
  block:
    let r = runCli(args, env, timeoutMs = 120_000)
    stderrs.add r.stderr
    if r.exit != 0: checkpoint "guiassert " & args.join(" ") & " -> " & r.stdout & r.stderr
    check r.exit == 0
    check r.stderr == ""
    envelopeOf(r)["data"]

template checkLabelRead(d: JsonNode, label: Label, labelAt: Point, words: openArray[string],
                        text: string, desktopShows = false) =
  ## `d` (an ocr result) holds exactly `words`, each once, each box mapped
  ## through the image's origin and scale onto the word's ink at `labelAt`
  ## on the desktop; `text` in reading order; one line per label line. With
  ## `desktopShows` the frame is a whole display that may show the desktop's
  ## own text too (GNOME Shell's top bar clock): exactly `words` lie on the
  ## label window, and `text` is a run of lines of the whole text.
  block:
    let im = d["image"]
    let origin = imageOrigin(im)
    let scale = im["scale"].getFloat
    checkpoint "origin " & $origin & ", scale " & $scale & ", words " & $d["words"]
    check d["backend"].getStr == "tesseract"
    if desktopShows:
      let window = rect(labelAt.x, labelAt.y, labelSize.width, labelSize.height)
      var onLabel = 0
      for w in d["words"]:
        if window.contains(imageToDesktop(bboxOf(w), origin, scale).center): inc onLabel
      check onLabel == words.len
      check ("\n" & d["text"].getStr & "\n").contains("\n" & text & "\n")
    else:
      check d["words"].len == words.len
      check d["text"].getStr == text
    var lines: seq[int]
    for word in words:
      let found = wordsNamed(d, word)
      check found.len == 1
      if found.len == 1:
        let mapped = imageToDesktop(bboxOf(found[0]), origin, scale)
        let want = label.inkOf(word).onDesktop(labelAt)
        checkpoint word & ": mapped " & $mapped & " vs ink on the desktop " & $want
        check abs(mapped.x - want.x) <= boxSlack
        check abs(mapped.y - want.y) <= boxSlack
        check abs(mapped.right - want.right) <= boxSlack
        check abs(mapped.bottom - want.bottom) <= boxSlack
        let c = found[0]["confidence"].getFloat
        check c >= 50.0 and c <= 100.0
        check found[0]["block"].kind == JInt
        lines.add found[0]["line"].getInt
    if lines.len == 4:
      check lines[0] == lines[1] and lines[2] == lines[3] and lines[0] != lines[2]

template failsWith(args: seq[string], env: StringTableRef, code: int, reason: string,
                   stderrs: var seq[string]): JsonNode =
  block:
    let r = runCli(args, env, timeoutMs = 120_000)
    stderrs.add r.stderr
    let e = envelopeOf(r)
    if r.exit != code: checkpoint "guiassert " & args.join(" ") & " -> " & $e & r.stderr
    check r.exit == code
    check r.stderr == ""
    check e["ok"].getBool == false
    check e["error"]["reason"].getStr == reason
    e["error"]

template live(problem: string, body: untyped) =
  ## Run `body` when the suite's server started; otherwise FAIL with the
  ## BLOCKED line (never skip).
  if problem.len > 0:
    checkpoint problem
    echo "  ", problem
    fail()
  else:
    body

proc ocrFeature(caps: JsonNode): JsonNode =
  for f in caps["features"]:
    if f["feature"].getStr == "ocr": return f
  newJNull()

template checkDefaultEngine(env: StringTableRef, stderrs: var seq[string]) =
  ## C7: with no --ocr-backend the session's engine is tesseract, and its
  ## `ocr` feature is probed `supported`.
  block:
    let caps = mustRead(@["capabilities", "--probe"], env, stderrs)
    check caps["selected"]["ocr"].getStr == "tesseract"
    let f = ocrFeature(caps)
    checkpoint $f
    check f["backend"].getStr == "tesseract"
    check f["state"].getStr == "supported"
    check f["reason"].kind == JNull

template checkNoTextOnStderr(stderrs: seq[string], st: string) =
  for s in stderrs:
    for w in labelWords: check w notin s
  for w in labelWords: check w notin stateFilesText(st)

# ---------------------------------------------------------------------------
# linux-x11
# ---------------------------------------------------------------------------

suite "tesseract over linux-x11 in a private Xvfb":
  var xvfb: Xvfb
  var problem = ""
  let st = freshDir("ocr-x11-state")
  let work = freshDir("ocr-x11-work")
  let label = makeLabel(work)
  let at = point(150, 200)
  var fixture: tuple[process: Process, id: string]
  try:
    xvfb = startXvfb(800, 600)
    fixture = xvfb.x11Window($labelSize.width & "x" & $labelSize.height & "+" & $at.x & "+" &
                             $at.y, "ffffff", nonce(), image = label.ppm)
  except AssertionDefect as e: problem = gs6(e.msg)
  let env = if problem.len == 0: runEnv(st, xvfb.env) else: nil
  var stderrs: seq[string]

  test "test_tesseract_ocr_reads_capture_mapped_to_desktop [linux-x11]":
    live problem:
      checkDefaultEngine(env, stderrs)
      # The window: a crop at the geometry Xvfb was asked for.
      let w = mustRead(@["ocr", "--window", fixture.id, "--out", work / "window.png"], env,
                       stderrs)
      check w["image"]["source"]["kind"].getStr == "window-crop"
      check w["image"]["origin"] == %*[at.x, at.y]
      check w["image"]["path"].getStr == work / "window.png"
      check fileExists(work / "window.png")
      checkLabelRead(w, label, at, labelWords, labelText)
      check w["languages"] == %["eng"]
      # The display: origin 0, the label where the window is.
      let displayId = mustRead(@["displays"], env, stderrs)["displays"][0]["id"].getStr
      let d = mustRead(@["ocr", "--display", displayId, "--out", work / "display.png"], env,
                       stderrs)
      check d["image"]["source"]["kind"].getStr == "display"
      checkLabelRead(d, label, at, labelWords, labelText)
      # A region holding the first line only: its origin is the region's.
      let r = mustRead(@["ocr", "--region", $(at.x + 4) & "," & $(at.y + 10) & ",400,64",
                         "--out", work / "region.png"], env, stderrs)
      check r["image"]["origin"] == %*[at.x + 4, at.y + 10]
      checkLabelRead(r, label, at, ["QUARTZ", "4719"], "QUARTZ 4719")
      # Negative control: the background holds no words.
      let bg = mustRead(@["ocr", "--region", "0,0,140,180", "--out", work / "bg.png"], env,
                        stderrs)
      check bg["words"].len == 0 and bg["text"].getStr == ""
      # Language selection over a capture: chosen, reported, used.
      let deu = mustRead(@["ocr", "--window", fixture.id, "--out", work / "deu.png", "--lang",
                           "deu", "--lang", "eng"], env, stderrs)
      check deu["languages"] == %["deu", "eng"]
      check wordsNamed(deu, "4719").len == 1
      checkNoTextOnStderr(stderrs, st)

  test "test_tesseract_missing_tool_and_traineddata_are_exit_4 [linux-x11]":
    live problem:
      # An uninstalled language: refused, the frame removed.
      let e = failsWith(@["ocr", "--window", fixture.id, "--out", work / "zzz.png", "--lang",
                          "zzz"], env, 4, "unsupported-option", stderrs)
      check e["details"]["feature"].getStr == "ocr"
      check e["details"]["backend"].getStr == "tesseract"
      check not fileExists(work / "zzz.png")
      # No tesseract at all.
      let menv = runEnv(st, xvfb.env, [("TESSERACT_BIN", work / "no-such-tesseract")])
      let m = failsWith(@["ocr", "--window", fixture.id, "--out", work / "missing.png"], menv,
                        4, "missing-tool", stderrs)
      check m["details"]["feature"].getStr == "ocr"
      check m["details"]["backend"].getStr == "tesseract"
      check "tesseract" in m["remedy"].getStr
      check not fileExists(work / "missing.png")
      let mf = ocrFeature(mustRead(@["capabilities", "--probe"], menv, stderrs))
      check mf["state"].getStr == "unavailable" and mf["reason"].getStr == "missing-tool"
      # A tesseract without its traineddata (an empty TESSDATA_PREFIX).
      let empty = work / "empty-tessdata"
      createDir(empty)
      let tenv = runEnv(st, xvfb.env, [("TESSDATA_PREFIX", empty & "/")])
      let t = failsWith(@["ocr", "--window", fixture.id, "--out", work / "nodata.png"], tenv,
                        4, "missing-tool", stderrs)
      checkpoint $t
      check t["details"]["feature"].getStr == "ocr"
      check "traineddata" in t["remedy"].getStr
      check not fileExists(work / "nodata.png")
      let tl = failsWith(@["ocr", "--window", fixture.id, "--out", work / "nodata-deu.png",
                           "--lang", "deu"], tenv, 4, "unsupported-option", stderrs)
      check tl["details"]["feature"].getStr == "ocr"
      check not fileExists(work / "nodata-deu.png")
      let tf = ocrFeature(mustRead(@["capabilities", "--probe"], tenv, stderrs))
      check tf["state"].getStr == "unavailable" and tf["reason"].getStr == "missing-tool"
      check "traineddata" in tf["remedy"].getStr
      # Positive control: the same window reads with the pinned data.
      check mustRead(@["ocr", "--window", fixture.id, "--out", work / "again.png"], env,
                     stderrs)["text"].getStr == labelText
      checkNoTextOnStderr(stderrs, st)

  test "test_ocr_text_never_on_stderr_and_features_named [linux-x11, serve]":
    live problem:
      let secret = planted()
      let sl = makeLabel(work, @[(secret, point(24, 50))], "planted")
      var pw: tuple[process: Process, id: string]
      try:
        pw = xvfb.x11Window($labelSize.width & "x" & $labelSize.height & "+150+380", "ffffff",
                            nonce(), image = sl.ppm)
        # Positive control: the CLI's data holds the word, its stderr is empty.
        let r = runCli(@["ocr", "--window", pw.id, "--out", work / "planted.png"], env,
                       timeoutMs = 120_000)
        check r.exit == 0
        check r.stderr == ""
        check wordsNamed(envelopeOf(r)["data"], secret).len == 1
        # Over serve: the result carries the word; no event and no daemon
        # stderr does.
        var sv = startServe(@["serve", "--stdio"], env)
        sv.send(runReq("o1", @["ocr", "--window", pw.id, "--out", work / "planted-serve.png"]))
        var events: seq[string]
        var res: JsonNode
        while true:
          let line = sv.recvRaw(120_000)
          let msg = parseJson(line)
          if msg["type"].getStr == "event": events.add line
          elif msg["type"].getStr == "result":
            res = msg
            break
        check res["exit"].getInt == 0
        check wordsNamed(res["envelope"]["data"], secret).len == 1
        for line in events: check secret notin line
        sv.closeInput()
        discard sv.p.waitForExit(30_000)
        let daemonErr = sv.p.errorStream.readAll()
        sv.p.close()
        check secret notin daemonErr
        check secret notin stateFilesText(st)
        # A refusal names the feature and the engine, carries no content, and
        # comes before the capture (C7).
        let x = runCli(@["ocr", "--window", pw.id, "--out", work / "p-refused.png", "--lang",
                         "eng+deu"], env)
        let xe = envelopeOf(x)
        check x.exit == 4
        check xe["error"]["reason"].getStr == "unsupported-option"
        check xe["error"]["details"]["feature"].getStr == "ocr"
        check xe["error"]["details"]["backend"].getStr == "tesseract"
        check secret notin x.stdout and x.stderr == ""
        check not fileExists(work / "p-refused.png")
      finally:
        stopProcess(pw.process)

  stopProcess(fixture.process)
  xvfb.stop()

# ---------------------------------------------------------------------------
# linux-wlr (scale 1 and scale 2) and linux-portal-pipewire
# ---------------------------------------------------------------------------

proc startSwayWithLabel(t: SwayTarget, label: Label): tuple[probe: Process, shown: EnvWindow,
                                                            problem: string] =
  try:
    t.startTarget()
    result.probe = t.probeWindow("ffffff", nonce(), pulse = true, image = label.ppm)
    result.shown = t.waitPidWindow(result.probe.processID)
    # Away from the desktop origin, so a mapping that ignores it fails.
    t.placeWindow(result.shown, 70, 90)
    let probe = result.probe
    t.waitUntil("the window moved", proc(): bool =
      t.waitPidWindow(probe.processID).rect.x == 70)
    sleep(500)
    result.shown = t.waitPidWindow(result.probe.processID)
  except AssertionDefect, CatchableError:
    result.problem = gs6(getCurrentExceptionMsg())
    if not result.problem.contains("BLOCKED"):
      result.problem = "GS6-LINUX BLOCKED: " & result.problem

template checkWlr(env: StringTableRef, work: string, label: Label, shown: EnvWindow,
                  scale: float, stderrs: var seq[string]) =
  block:
    checkDefaultEngine(env, stderrs)
    let at = point(shown.rect.x, shown.rect.y)
    # A buffer of scale 1: one buffer pixel per logical pixel, so the window
    # spans the label's size on the desktop and `scale` times it in the frame.
    check shown.rect.w == labelSize.width and shown.rect.h == labelSize.height
    var id = ""
    for w in mustRead(@["windows", "--pid", $shown.pid], env, stderrs)["windows"]:
      id = w["id"].getStr
    check id.len > 0
    let w = mustRead(@["ocr", "--window", id, "--out", work / "window.png"], env, stderrs)
    check w["image"]["source"]["kind"].getStr == "window-crop"
    check w["image"]["origin"] == %*[at.x, at.y]
    check w["image"]["scale"].getFloat == scale
    check w["image"]["width"].getInt == int(float(shown.rect.w) * scale)
    checkLabelRead(w, label, at, labelWords, labelText)
    let d = mustRead(@["ocr", "--display", "HEADLESS-1", "--out", work / "display.png"], env,
                     stderrs)
    check d["image"]["origin"] == %*[0, 0]
    checkLabelRead(d, label, at, labelWords, labelText)
    let firstLine = label.inkOf("4719")
    let r = mustRead(@["ocr", "--region", $(at.x + 4) & "," & $(at.y + 4) & "," &
                       $(firstLine.right + 12) & "," & $(firstLine.bottom + 10), "--out",
                       work / "region.png"], env, stderrs)
    check r["image"]["origin"] == %*[at.x + 4, at.y + 4]
    checkLabelRead(r, label, at, ["QUARTZ", "4719"], "QUARTZ 4719")
    let bg = mustRead(@["ocr", "--region", "0,0,60,80", "--out", work / "bg.png"], env, stderrs)
    check bg["words"].len == 0

suite "tesseract over linux-wlr and linux-portal-pipewire in a private sway":
  let st = freshDir("ocr-wlr-state")
  let work = freshDir("ocr-wlr-work")
  let label = makeLabel(work)
  let t = newSwayTarget(800, 600)
  var (probe, shown, problem) = startSwayWithLabel(t, label)
  let env = if problem.len == 0: runEnv(st, t.sessionEnv) else: nil
  var stderrs: seq[string]

  test "test_tesseract_ocr_reads_capture_mapped_to_desktop [linux-wlr]":
    live problem:
      checkWlr(env, work, label, shown, 1.0, stderrs)
      checkNoTextOnStderr(stderrs, st)

  var portal: PortalStack
  var portalProblem = problem
  if problem.len == 0:
    try: portal = t.startPortalStack()
    except AssertionDefect as e: portalProblem = gs6(e.msg)

  test "test_tesseract_ocr_reads_capture_mapped_to_desktop [linux-portal-pipewire]":
    live portalProblem:
      let shot = mustRead(@["--capture-backend", "linux-portal-pipewire", "screenshot",
                            "--no-cursor",
                            "--out", work / "portal.png"], env, stderrs)["image"]
      let d = mustRead(@["ocr", "--image", work / "portal.png"], env, stderrs)
      # The words are in the screenshot's pixels; its origin and scale map
      # them to the desktop.
      d["image"] = shot
      checkLabelRead(d, label, point(shown.rect.x, shown.rect.y), labelWords, labelText)
      # The capture form is refused before anything is captured.
      let e = failsWith(@["--capture-backend", "linux-portal-pipewire", "ocr", "--display",
                          "HEADLESS-1", "--out", work / "portal-ocr.png"], env, 4,
                        "unsupported-option", stderrs)
      check e["details"]["feature"].getStr == "display-capture"
      check not fileExists(work / "portal-ocr.png")
      checkNoTextOnStderr(stderrs, st)

  portal.stop()
  stopProcess(probe)
  t.stop()

suite "tesseract over linux-wlr in a private sway at scale 2":
  let st = freshDir("ocr-wlr2-state")
  let work = freshDir("ocr-wlr2-work")
  let label = makeLabel(work)
  let t = newSwayTarget(1280, 800, scale = 2.0)
  var (probe, shown, problem) = startSwayWithLabel(t, label)
  let env = if problem.len == 0: runEnv(st, t.sessionEnv) else: nil
  var stderrs: seq[string]

  test "test_tesseract_ocr_reads_capture_mapped_to_desktop [linux-wlr, scale 2]":
    live problem:
      let ds = mustRead(@["displays"], env, stderrs)["displays"]
      check ds[0]["scale"].getFloat == 2.0 and ds[0]["bounds"] == %*[0, 0, 640, 400]
      checkWlr(env, work, label, shown, 2.0, stderrs)
      checkNoTextOnStderr(stderrs, st)

  stopProcess(probe)
  t.stop()

# ---------------------------------------------------------------------------
# linux-gnome
# ---------------------------------------------------------------------------

suite "tesseract over linux-gnome in a private headless GNOME Shell":
  let st = freshDir("ocr-gnome-state")
  let work = freshDir("ocr-gnome-work")
  let label = makeLabel(work)
  let t = newGnomeTarget(1024, 768)
  var probe: Process
  var shown: EnvWindow
  var problem = ""
  try:
    t.startTarget()
    probe = t.probeWindow("ffffff", nonce(), image = label.ppm)
    shown = t.waitPidWindow(probe.processID)
    t.placeWindow(shown, 130, 170)
    t.waitUntil("the window moved", proc(): bool =
      t.waitPidWindow(probe.processID).rect.x == 130)
    sleep(800)
    shown = t.waitPidWindow(probe.processID)
  except AssertionDefect, CatchableError:
    problem = gs6(getCurrentExceptionMsg())
    if not problem.contains("BLOCKED"): problem = "GS6-LINUX BLOCKED: " & problem
  let env = if problem.len == 0: runEnv(st, t.sessionEnv) else: nil
  var stderrs: seq[string]

  test "test_tesseract_ocr_reads_capture_mapped_to_desktop [linux-gnome]":
    live problem:
      checkDefaultEngine(env, stderrs)
      let at = point(shown.rect.x, shown.rect.y)
      var id = ""
      for w in mustRead(@["windows", "--pid", $probe.processID], env, stderrs)["windows"]:
        id = w["id"].getStr
      check id.len > 0
      let w = mustRead(@["ocr", "--window", id, "--out", work / "window.png"], env, stderrs)
      check w["image"]["source"]["kind"].getStr == "window-crop"
      check w["image"]["origin"] == %*[at.x, at.y]
      checkLabelRead(w, label, at, labelWords, labelText)
      let displayId = mustRead(@["displays"], env, stderrs)["displays"][0]["id"].getStr
      let d = mustRead(@["ocr", "--display", displayId, "--out", work / "display.png"], env,
                       stderrs)
      checkLabelRead(d, label, at, labelWords, labelText, desktopShows = true)
      let r = mustRead(@["ocr", "--region", $(at.x + 6) & "," & $(at.y + 6) & ",400,66",
                         "--out", work / "region.png"], env, stderrs)
      check r["image"]["origin"] == %*[at.x + 6, at.y + 6]
      checkLabelRead(r, label, at, ["QUARTZ", "4719"], "QUARTZ 4719")
      checkNoTextOnStderr(stderrs, st)

  stopProcess(probe)
  t.stop()

# ---------------------------------------------------------------------------
# Nothing left behind
# ---------------------------------------------------------------------------

suite "the run's own processes":
  test "test_live_suite_leaves_no_process_running":
    # Every server above was stopped; nothing this run started (a server, a
    # helper, a session bus, a bus-activated service, a `guiassert` run) may
    # outlive it (`linux_live.ownProcesses`).
    checkLeavesNoProcess()

cleanupFreshDirs()
