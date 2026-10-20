## The contract 1.0 decisions C1–C17 (milestone GS2.1; the requests and the
## decisions are recorded under GS0 in
## Planned-Work/Desktop-Substrate.milestones.org), each checked against the
## REAL built binary as a subprocess, one process per verb, and over the
## REAL `guiassert serve` where the decision concerns it.
##
## Every test is written from the specification (spec §6.1, §7.2, §7.5,
## §8.3, §9.2); where a closed list matters (the feature vocabulary, the key
## table) the test reads it from the specification's own text, not from the
## implementation.
##
## Stand-ins: the fixture backend (spec §9.2), selected below the real
## binary, is the only one. Its scenario files and its documented
## misbehaviour switches (GUIASSERT_FIXTURE_HOST, GUIASSERT_FIXTURE_RECORDING,
## GUIASSERT_FIXTURE_DENY, GUIASSERT_FIXTURE_UNAVAILABLE) produce the
## conditions a real backend cannot be made to produce on demand: a session
## that never gets ready, a recording that was not finalized, a missing
## permission. One test rewrites the `backends` of a real session record to
## name non-fixture backends, because "capabilities honours --session" can
## only be told apart from "capabilities reports the default" when the two
## differ, and the fixture is the only session backend that exists yet.
## Recordings are measured independently with the pinned `ffprobe`.

import std/[json, os, osproc, sequtils, sets, streams, strtabs, strutils, tables,
            unittest, times, monotimes]

when defined(posix):
  import std/posix

import ./harness
from ../../src/gui_assert/backends/fixture_desktop import builtinScenarioJson

const
  submitCenter = "190,278"     ## the built-in form's Submit button
  passwordCenter = "370,396"   ## its Password field
  nameCenter = "370,152"       ## its Name field

proc msSince(start: MonoTime): int64 = (getMonoTime() - start).inMilliseconds

proc runCliInput(args: seq[string], env: StringTableRef, input: string): CliRun =
  ## `runCli` with `input` on the binary's standard input.
  let p = startProcess(contractBin(), args = args, env = env, options = {})
  try:
    p.inputStream.write(input)
    p.inputStream.close()
    result.exit = p.waitForExit(cliTimeoutMs)
    result.stdout = p.outputStream.readAll()
    result.stderr = p.errorStream.readAll()
  finally:
    p.close()

proc cliIn(args: seq[string], env: StringTableRef, input: string):
    tuple[exit: int, env: JsonNode, line: string] =
  let r = runCliInput(args, env, input)
  (r.exit, envelopeOf(r), r.stdout.strip(leading = false, chars = {'\n'}))

# The helpers that check are templates, not procs: `check` marks the test
# that runs it as failed only when it expands inside the test's own scope.

template ok(args: seq[string], vars: StringTableRef): JsonNode =
  ## The data of a run that must succeed.
  let run = cli(args, vars)
  if run.exit != 0: checkpoint args.join(" ") & " -> " & run.line
  check run.exit == 0
  (if run.exit == 0: run.env.data else: newJObject())

template failure(args: seq[string], vars: StringTableRef, code: int,
                 reason: string): JsonNode =
  ## The error object of a run that must fail with `code` / `reason`.
  let run = cli(args, vars)
  if run.exit != code or run.env{"error", "reason"}.getStr != reason:
    checkpoint args.join(" ") & " -> " & run.line
  check run.exit == code
  check run.env{"error", "reason"}.getStr == reason
  (if run.env.hasKey("error"): run.env["error"] else: newJObject())

template element(vars: StringTableRef, path: string): JsonNode =
  ok(@["element", path], vars)["element"]

proc scenarioFile(dir: string, edit: proc (n: JsonNode)): string =
  ## A scenario file: the built-in one, changed by `edit`.
  var n = parseJson(builtinScenarioJson)
  edit(n)
  result = dir / "scenario.json"
  writeFile(result, $n)

template ocrWords(vars: StringTableRef, work, name: string): JsonNode =
  ## The OCR words of a fresh screenshot of the primary display.
  discard ok(@["screenshot", "--out", work / name], vars)
  ok(@["ocr", "--image", work / name], vars)["words"]

proc ffprobeTool(): string =
  ## The pinned ffprobe (beside FFMPEG_BIN, else on PATH).
  let ff = getEnv("FFMPEG_BIN")
  if ff.len > 0 and fileExists(ff.parentDir / ("ffprobe" & ExeExt)):
    return ff.parentDir / ("ffprobe" & ExeExt)
  result = findExe("ffprobe")
  doAssert result.len > 0, "ffprobe is needed to measure recordings independently"

proc ffprobe(path: string): tuple[frames, width, height, durationMs: int] =
  let (o, code) = execCmdEx(quoteShellCommand(@[ffprobeTool(), "-v", "error",
    "-select_streams", "v:0", "-count_frames", "-show_entries",
    "stream=nb_read_frames,width,height,duration", "-of", "default=noprint_wrappers=1",
    path]))
  doAssert code == 0, "ffprobe failed on " & path & ": " & o
  for line in o.splitLines:
    let kv = line.split('=', 1)
    if kv.len != 2: continue
    case kv[0]
    of "nb_read_frames": result.frames = parseInt(kv[1])
    of "width": result.width = parseInt(kv[1])
    of "height": result.height = parseInt(kv[1])
    of "duration": result.durationMs = int(parseFloat(kv[1]) * 1000.0 + 0.5)
    else: discard

proc pngSize(path: string): (int, int) =
  ## Width and height from a PNG's IHDR (bytes 16..23, big-endian).
  let b = readFile(path)
  doAssert b.len > 24 and b[1 .. 3] == "PNG", path & " is not a PNG"
  proc be(i: int): int =
    (ord(b[i]) shl 24) or (ord(b[i + 1]) shl 16) or (ord(b[i + 2]) shl 8) or ord(b[i + 3])
  (be(16), be(20))

proc sessionHostsOf(stateDir: string): int =
  ## How many session-host processes of `stateDir` are alive.
  when defined(posix):
    let (o, _) = execCmdEx("pgrep -f " & quoteShell("__session-host --state-dir " & stateDir))
    for l in o.splitLines:
      if l.strip.len > 0: inc result

proc killHost(hostPid: int) =
  when defined(posix):
    discard posix.kill(Pid(hostPid), SIGKILL)
    let start = getMonoTime()
    while posix.kill(Pid(hostPid), 0) == 0 and msSince(start) < 5000: sleep(20)

suite "contract 1.0 decisions":
  test "test_node_bounds_are_desktop_coordinates":
    # C1. A node's bounds are desktop coordinates: inside its window's
    # (window-server) bounds, where a click reaches it, where OCR of a
    # capture (mapped through origin and scale) finds its text, and they
    # follow the window when it moves.
    let st = freshDir("c1")
    let work = freshDir("c1-work")
    let env = fixtureEnv(st)
    let win = ok(@["windows"], env)["windows"][0]
    let wb = win["bounds"]
    let submit = ok(@["find", "--role", "button", "--name", "Submit"], env)["elements"][0]
    let b = submit["bounds"]
    check b[0].getInt >= wb[0].getInt and b[1].getInt >= wb[1].getInt
    check b[0].getInt + b[2].getInt <= wb[0].getInt + wb[2].getInt
    check b[1].getInt + b[3].getInt <= wb[1].getInt + wb[3].getInt
    # OCR word "Submit" of a display capture, mapped to the desktop.
    let shot = work / "c1.png"
    let img = ok(@["screenshot", "--out", shot], env)["image"]
    var found = false
    for w in ok(@["ocr", "--image", shot], env)["words"]:
      if w["text"].getStr == "Submit":
        let s = img["scale"].getFloat
        let dx = img["origin"][0].getInt + int(float(w["bbox"][0].getInt) / s)
        let dy = img["origin"][1].getInt + int(float(w["bbox"][1].getInt) / s)
        check dx >= b[0].getInt and dx < b[0].getInt + b[2].getInt
        check dy >= b[1].getInt and dy < b[1].getInt + b[3].getInt
        found = true
    check found
    # Move the window: the node's bounds move by the same delta.
    let (ddx, ddy) = (150, 40)
    discard ok(@["window-set-bounds", "fixture-window-1", "--bounds",
                 $(wb[0].getInt + ddx) & "," & $(wb[1].getInt + ddy) & "," &
                 $wb[2].getInt & "," & $wb[3].getInt], env)
    let moved = ok(@["find", "--role", "button", "--name", "Submit"], env)["elements"][0]["bounds"]
    check moved[0].getInt == b[0].getInt + ddx and moved[1].getInt == b[1].getInt + ddy
    # Negative control: the old centre no longer presses Submit ...
    discard ok(@["click", "--at", $(b[0].getInt + b[2].getInt div 2) & "," &
                 $(b[1].getInt + b[3].getInt div 2)], env)
    check ok(@["find", "--role", "label", "--name-contains", "Submitted"], env)["elements"].len == 0
    # ... and the centre of the reported bounds does.
    discard ok(@["click", "--at", $(moved[0].getInt + moved[2].getInt div 2) & "," &
                 $(moved[1].getInt + moved[3].getInt div 2)], env)
    check ok(@["find", "--role", "label", "--name-contains", "Submitted"], env)["elements"].len == 1

  test "test_node_text_is_distinct_from_name_and_value":
    # C2. `text` is the text content: a label's string, a field's content,
    # a document's body; null where there is no text interface.
    let st = freshDir("c2")
    let env = fixtureEnv(st)
    let label = element(env, "/app[4242]/window[0]/label[0]")
    check label["name"].getStr == "Name" and label["text"].getStr == "Name"
    check label["value"].kind == JNull
    discard ok(@["type", "Ada"], env)
    let field = element(env, "/app[4242]/window[0]/text-field[0]")
    check field["name"].getStr == "Name"
    check field["value"].getStr == "Ada" and field["text"].getStr == "Ada"
    check element(env, "/app[4242]/window[0]/button[0]")["text"].kind == JNull
    # A node whose text differs from both its name and its value.
    let dir = freshDir("c2-scn")
    let scn = scenarioFile(dir, proc (n: JsonNode) =
      n["trees"][0]["root"]["children"][0]["children"].add %*{
        "role": "group", "nativeRole": "AXGroup", "name": "Notes",
        "text": "Remember the milk", "bounds": [130, 440, 300, 24]})
    let env2 = fixtureEnv(freshDir("c2b"), {"GUIASSERT_FIXTURE_SCENARIO": scn})
    let g = element(env2, "/app[4242]/window[0]/group[0]")
    check g["name"].getStr == "Notes" and g["text"].getStr == "Remember the milk"
    check g["value"].kind == JNull
    let found = ok(@["find", "--role", "group"], env2)["elements"]
    check found.len == 1 and found[0]["text"].getStr == "Remember the milk"

  test "test_protected_field_never_reports_value_or_text":
    # C3. The Password field is `protected`: value and text null on every
    # verb that reads it, its characters in no envelope, none drawn.
    let st = freshDir("c3")
    let work = freshDir("c3-work")
    let env = fixtureEnv(st)
    const secret = "Pw4secretX"
    const secret2 = "Rq8otherY"
    discard ok(@["click", "--at", passwordCenter], env)
    let typed = cliIn(@["type", "--stdin"], env, secret)
    check typed.exit == 0 and secret notin typed.line
    let path = "/app[4242]/window[0]/text-field[1]"
    var lines: seq[string]
    for argv in [@["element", path], @["tree", "--pid", "4242"],
                 @["find", "--role", "text-field"],
                 @["find", "--name", "Password", "--role", "text-field"],
                 @["wait", "--element", "--name", "Password", "--role", "text-field",
                   "--wait-ms", "100"],
                 @["element-action", path, "set-value", "--value", secret2],
                 @["element-action", path, "focus"]]:
      let (x, _, line) = cli(argv, env)
      check x == 0
      lines.add line
    for line in lines:
      check secret notin line and secret2 notin line
    let e = element(env, path)
    check "protected" in e["states"].mapIt(it.getStr)
    check e["value"].kind == JNull and e["text"].kind == JNull
    check e["role"].getStr == "text-field" and e["name"].getStr == "Password"
    # Nothing of it is drawn: the frame shows one mask character per
    # character of the value it now holds, never the characters.
    var text = ""
    for w in ocrWords(env, work, "c3.png"): text.add w["text"].getStr & " "
    check secret notin text and secret2 notin text
    check repeat('*', secret2.len) in text
    # Control: the unprotected Name field reports what was typed into it.
    discard ok(@["click", "--at", nameCenter], env)
    discard ok(@["type", "Visible1"], env)
    let name = element(env, "/app[4242]/window[0]/text-field[0]")
    check name["value"].getStr == "Visible1" and name["text"].getStr == "Visible1"

  test "test_window_document_is_reported_or_null":
    # C4. `document` names the window's document; null where there is none.
    let st = freshDir("c4")
    let env = fixtureEnv(st)
    let w = ok(@["windows"], env)["windows"][0]
    check w["document"].getStr == "file:///fixture/Documents/Form.fixture"
    check ok(@["window-focus", "fixture-window-1"], env)["window"]["document"].getStr ==
      "file:///fixture/Documents/Form.fixture"
    let launched = ok(@["app-launch", "--bundle-id", "dev.example.Notes"], env)
    check launched["window"]["document"].kind == JNull
    var docs: seq[JsonNode]
    for x in ok(@["windows"], env)["windows"]: docs.add x["document"]
    check docs.len == 2 and docs.countIt(it.kind == JNull) == 1

  test "test_app_accessible_is_true_false_or_unknown":
    # C5. `accessible`: true with a tree, false without, null when the
    # permission to look is missing (never false for "could not look").
    let st = freshDir("c5")
    let env = fixtureEnv(st)
    check ok(@["apps"], env)["apps"][0]["accessible"].getBool == true
    let dir = freshDir("c5-scn")
    let scn = scenarioFile(dir, proc (n: JsonNode) =
      n["apps"].add %*{"pid": 5000, "name": "Opaque", "bundleId": nil, "appId": nil,
                       "frontmost": false, "hidden": false, "accessible": false})
    let env2 = fixtureEnv(freshDir("c5b"), {"GUIASSERT_FIXTURE_SCENARIO": scn})
    var acc = initTable[string, JsonNode]()
    for a in ok(@["apps"], env2)["apps"]: acc[a["name"].getStr] = a["accessible"]
    check acc["Fixture Form"].getBool == true and acc["Opaque"].getBool == false
    discard failure(@["tree", "--pid", "5000"], env2, 3, "app")
    let denied = fixtureEnv(freshDir("c5c"), {"GUIASSERT_FIXTURE_DENY": "accessibility"})
    check ok(@["apps"], denied)["apps"][0]["accessible"].kind == JNull
    # A scenario that claims a tree it does not have is refused.
    let lie = scenarioFile(freshDir("c5-lie"), proc (n: JsonNode) =
      n["apps"].add %*{"pid": 5001, "name": "Liar", "bundleId": nil, "appId": nil,
                       "frontmost": false, "hidden": false, "accessible": true})
    discard failure(@["apps"], fixtureEnv(freshDir("c5d"),
                    {"GUIASSERT_FIXTURE_SCENARIO": lie}), 2, "invalid-value")

  test "test_session_env_and_env_unset":
    # C6. A session states what a spawned process needs set (`env`) and
    # must not inherit (`envUnset`); app-launch applies both, `--env` last.
    let st = freshDir("c6")
    let env = fixtureEnv(st)
    let s = ok(@["session-start", "--kind", "headless", "--name", "e1"], env)["session"]
    check s["env"]["GUIASSERT_SESSION"].getStr == "e1"
    check s["envUnset"].mapIt(it.getStr) == @["DISPLAY", "WAYLAND_DISPLAY"]
    check ok(@["session-info", "e1"], env)["session"]["envUnset"] == s["envUnset"]
    var hostSession: JsonNode
    for x in ok(@["session-list"], env)["sessions"]:
      if x["id"].getStr == "host": hostSession = x
    check hostSession["envUnset"].len == 0
    let app = ok(@["--session", "e1", "app-launch", "--bundle-id", "dev.example.Notes",
                   "--env", "ACCESSIBILITY_ENABLED=1", "--env", "DISPLAY=:9",
                   "--env", "EMPTY="], env)["app"]
    let rec = parseJson(readFile(st / "fixture" / "launches" / ($app["pid"].getInt & ".json")))
    check rec["schema"].getStr == "guiassert/fixture-launch/1"
    check rec["session"].getStr == "e1"
    check rec["env"] == %*{"GUIASSERT_SESSION": "e1", "ACCESSIBILITY_ENABLED": "1",
                            "DISPLAY": ":9", "EMPTY": ""}
    # DISPLAY was set explicitly, so only WAYLAND_DISPLAY stays unset.
    check rec["envUnset"].mapIt(it.getStr) == @["WAYLAND_DISPLAY"]
    # Control: without --env the launch gets exactly the session's.
    let plain = ok(@["--session", "e1", "app-launch", "--bundle-id", "dev.example.Notes"],
                   env)["app"]
    let rec2 = parseJson(readFile(st / "fixture" / "launches" / ($plain["pid"].getInt & ".json")))
    check rec2["env"] == s["env"] and rec2["envUnset"] == s["envUnset"]
    # Malformed --env is refused, never ignored.
    for bad in ["NOEQUALS", "=x", "1A=x", "A-B=x"]:
      discard failure(@["--session", "e1", "app-launch", "--bundle-id", "dev.example.N",
                        "--env", bad], env, 2, "invalid-value")
    discard failure(@["--session", "e1", "app-launch", "--bundle-id", "dev.example.N",
                      "--env", "A=1", "--env", "A=2"], env, 2, "conflicting-arguments")
    discard ok(@["session-stop", "e1"], env)

  test "test_capabilities_vocabulary_and_details_feature":
    # C7. capabilities lists every feature of the spec's vocabulary exactly
    # once, each from its module's selected backend, honouring --session;
    # every exit 4 / 6 names its feature (null only where spec §7.2 says).
    let vocab = specFeatures()
    let degraded = specDegradedReasons()
    let reasons = specReasons()
    check vocab.len >= 19
    let st = freshDir("c7")
    let env = fixtureEnv(st)
    proc checkReport(caps: JsonNode) =
      var seen: seq[string]
      for f in caps["features"]:
        let name = f["feature"].getStr
        seen.add name
        var module = ""
        for (n, m) in vocab:
          if n == name: module = m
        check module.len > 0
        if module.len > 0 and module != "media":
          check f["backend"].getStr == caps["selected"][module].getStr
        case f["state"].getStr
        of "supported", "available": check f["reason"].kind == JNull
        of "degraded": check f["reason"].getStr in degraded
        of "unavailable":
          check f["reason"].getStr in reasons["backend-unavailable"] or
                f["reason"].getStr in reasons["permission-denied"]
        else: check false
      check seen.len == vocab.len
      check toHashSet(seen) == toHashSet(vocab.mapIt(it[0]))
    let caps = ok(@["capabilities"], env)
    checkReport(caps)
    for f in caps["features"]:
      if f["feature"].getStr in ["tree-read", "display-capture", "session-headless"]:
        check f["state"].getStr == "supported"
    # --session: that session's backends (its record rewritten to name
    # others, see the header).
    discard ok(@["session-start", "--kind", "headless", "--name", "caps"], env)
    let recPath = st / "sessions" / "caps.json"
    let original = readFile(recPath)
    var rec = parseJson(original)
    rec["backends"] = %*{"capture": "linux-x11", "tree": "fixture", "input": "fixture"}
    writeFile(recPath, $rec)
    let plain = baseEnv()
    plain["GUIASSERT_STATE_DIR"] = st
    plain["GUIASSERT_TREE_BACKEND"] = "fixture"
    let sc = ok(@["--session", "caps", "capabilities"], plain)
    check sc["selected"]["capture"].getStr == "linux-x11"
    checkReport(sc)
    for f in sc["features"]:
      if f["feature"].getStr == "window-capture":
        check f["backend"].getStr == "linux-x11" and f["state"].getStr == "unavailable"
      if f["feature"].getStr == "tree-read":
        check f["backend"].getStr == "fixture" and f["state"].getStr == "supported"
    writeFile(recPath, original)
    discard ok(@["session-stop", "caps"], env)
    # details.feature of exit 4 and exit 6.
    let work = freshDir("c7-work")
    let shot = work / "s.png"
    discard ok(@["screenshot", "--out", shot], env)
    let crop = scenarioFile(freshDir("c7-crop"), proc (n: JsonNode) =
      n["windowCapture"] = %"crop")
    let deadSt = freshDir("c7-dead")
    let deadEnv = fixtureEnv(deadSt)
    let dead = ok(@["session-start", "--kind", "headless", "--name", "gone"], deadEnv)
    killHost(dead["session"]["hostPid"].getInt)
    let cases: seq[(seq[string], StringTableRef, int, string, string)] = @[
      (@["displays"], baseEnv(), 4, "", "window-enumeration"),
      (@["screenshot", "--window", "fixture-window-1", "--own-pixels", "--out", work / "a.png"],
       fixtureEnv(freshDir("c7a"), {"GUIASSERT_FIXTURE_SCENARIO": crop}), 4,
       "unsupported-option", "own-pixels-capture"),
      (@["ocr", "--image", shot, "--psm", "6"], env, 4, "unsupported-option", "ocr"),
      (@["--capture-backend", "linux-x11", "ocr", "--region", "0,0,10,10", "--out",
         work / "b.png"], env, 4, "", "region-capture"),
      (@["--ocr-backend", "tesseract", "ocr", "--region", "0,0,10,10", "--out",
         work / "c.png"], env, 4, "", "ocr"),
      (@["session-start", "--kind", "headless", "--vnc"], env, 4, "unsupported-option",
       "session-vnc"),
      (@["session-start", "--kind", "headless", "--lifetime", "owner"], env, 4,
       "unsupported-option", "null"),
      (@["screenshot", "--out", work / "d.png"],
       fixtureEnv(st, {"GUIASSERT_FIXTURE_DENY": "screen-recording"}), 6,
       "tcc-screen-recording", "display-capture"),
      (@["screenshot", "--region", "0,0,20,20", "--out", work / "e.png"],
       fixtureEnv(st, {"GUIASSERT_FIXTURE_DENY": "screen-recording"}), 6,
       "tcc-screen-recording", "region-capture"),
      (@["record", "--out", work / "f.mp4", "--duration-ms", "100"],
       fixtureEnv(st, {"GUIASSERT_FIXTURE_DENY": "screen-recording"}), 6,
       "tcc-screen-recording", "recording"),
      (@["wait", "--text", "x", "--ocr-region", "0,0,20,20", "--out-dir", work,
         "--wait-ms", "100"],
       fixtureEnv(st, {"GUIASSERT_FIXTURE_DENY": "screen-recording"}), 6,
       "tcc-screen-recording", "region-capture"),
      (@["tree", "--pid", "4242"], fixtureEnv(st, {"GUIASSERT_FIXTURE_DENY": "accessibility"}),
       6, "tcc-accessibility", "tree-read"),
      (@["element-action", "/app[4242]/window[0]/button[0]", "press"],
       fixtureEnv(st, {"GUIASSERT_FIXTURE_DENY": "accessibility"}), 6, "tcc-accessibility",
       "element-actions"),
      (@["click", "--at", "1,1"], fixtureEnv(st, {"GUIASSERT_FIXTURE_DENY": "accessibility"}),
       6, "tcc-accessibility", "pointer-input"),
      (@["type", "x"], fixtureEnv(st, {"GUIASSERT_FIXTURE_DENY": "accessibility"}), 6,
       "tcc-accessibility", "keyboard-input"),
      (@["key", "a"], fixtureEnv(st, {"GUIASSERT_FIXTURE_UNAVAILABLE": "input"}), 4,
       "missing-tool", "keyboard-input"),
      (@["apps"], fixtureEnv(st, {"GUIASSERT_FIXTURE_UNAVAILABLE": "session"}), 4,
       "missing-tool", "app-management"),
      (@["windows"], fixtureEnv(st, {"GUIASSERT_FIXTURE_FAIL": "windows:4"}), 4,
       "not-compiled-in", "window-enumeration"),
      (@["window-focus", "fixture-window-1"],
       fixtureEnv(st, {"GUIASSERT_FIXTURE_FAIL": "window-focus:6:desktop-access"}), 6,
       "desktop-access", "window-management"),
      # Without the media backend (guiassert-fixture) or without ffmpeg
      # (guiassert, FFMPEG_BIN naming no file): exit 4 for video-decode.
      (@["vision-segment", work / "v.mp4"],
       fixtureEnv(st, {"FFMPEG_BIN": work / "no-such-ffmpeg"}), 4, "", "video-decode"),
      (@["--session", "gone", "click", "--at", "1,1"], deadEnv, 4, "session-not-running",
       "null"),
      (@["windows"], fixtureEnv(st, {"GUIASSERT_FIXTURE_FAIL": "windows:4:session-not-running"}),
       4, "session-not-running", "null")]
    for (argv, e, code, reason, feature) in cases:
      let (x, envl, line) = cli(argv, e)
      checkpoint argv.join(" ") & " -> " & line
      check x == code
      if x != code: continue
      let err = envl["error"]
      if reason.len > 0: check err["reason"].getStr == reason
      check err["details"].kind == JObject
      check err["details"].hasKey("feature")
      if feature == "null": check err["details"]["feature"].kind == JNull
      else: check err["details"]["feature"].getStr == feature
    # Exit codes other than 4 and 6 carry no feature.
    let (x5, e5, _) = cli(@["windows"], fixtureEnv(st, {"GUIASSERT_FIXTURE_FAIL": "windows:5"}))
    check x5 == 5 and e5["error"]["details"].kind == JNull
    check ok(@["session-stop", "gone"], deadEnv)["session"]["state"].getStr == "stopped"

  test "test_key_table_is_case_insensitive_with_aliases":
    # C8. Every spelling of the spec's key table, in any case, is accepted
    # and normalized to the canonical spelling; anything else is refused.
    let st = freshDir("c8")
    let env = fixtureEnv(st)
    proc keys(combo: string): string =
      let (x, e, line) = cli(@["key", combo], env)
      if x != 0: checkpoint "key " & combo & " -> " & line
      check x == 0
      if x == 0: e.data["input"]["keys"].getStr else: ""
    var named, modifiers = 0
    for row in specTable(["Kind", "Canonical", "Also accepted"]):
      let canonical = backticked(row[1])
      let aliases = backticked(row[2])
      case row[0]
      of "named":
        inc named
        for spelling in canonical & aliases:
          for variant in [spelling, spelling.toLowerAscii, spelling.toUpperAscii]:
            check keys(variant) == canonical[0]
      of "modifier":
        inc modifiers
        for spelling in canonical & aliases:
          for variant in [spelling, spelling.toUpperAscii]:
            check keys(variant & "+a") == canonical[0] & "+a"
      of "function":
        check canonical == @["F1", "F24"]
        for n in [1, 12, 24]:
          check keys("f" & $n) == "F" & $n
        for bad in ["F0", "F25"]:
          discard failure(@["key", bad], env, 2, "invalid-value")
      of "character":
        for (c, want) in [("A", "a"), ("z", "z"), ("7", "7"), ("+", "+"), ("é", "é"),
                          ("?", "?")]:
          check keys(c) == want
      else: check false
    check named == 16 and modifiers == 4
    check keys("Control+Option+Shift+Command+Enter") == "ctrl+alt+shift+cmd+Return"
    check keys("ctrl++") == "ctrl++"
    for bad in ["PgUp", "page_up", "ctrl+control+a", "cmd+win+a", "hyper+a", "ctrl+", "a b"]:
      discard failure(@["key", bad], env, 2, "invalid-value")
    let click = ok(@["click", "--at", "1,1", "--modifiers", "Meta,OPTION"], env)
    check click["input"]["keys"].getStr == "alt+cmd"
    # The alias reaches the same key: lower-case backspace deletes a character.
    discard ok(@["type", "Ab"], env)
    check keys("backspace") == "BackSpace"
    check element(env, "/app[4242]/window[0]/text-field[0]")["value"].getStr == "A"

  test "test_dead_session_verbs_answer_exit_4_session_not_running":
    # C9. A session whose host died: every verb that targets it answers
    # exit 4 / session-not-running (never 3 or 5); session-info reports it.
    let st = freshDir("c9")
    let work = freshDir("c9-work")
    let env = fixtureEnv(st)
    let s = ok(@["session-start", "--kind", "headless", "--name", "dies"], env)["session"]
    # Control: while it runs, the same verbs work.
    discard ok(@["--session", "dies", "windows"], env)
    killHost(s["hostPid"].getInt)
    for argv in [@["windows"], @["displays"], @["apps"], @["screenshot", "--out", work / "x.png"],
                 @["record-start", "--out", work / "x.mp4"], @["tree", "--pid", "4242"],
                 @["find", "--role", "button"],
                 @["element-action", "/app[4242]/window[0]/button[0]", "press"],
                 @["click", "--at", submitCenter], @["type", "x"], @["key", "Return"],
                 @["drag", "--from", "1,1", "--to", "2,2"],
                 @["app-launch", "--bundle-id", "dev.example.Notes"], @["app-quit", "4242"],
                 @["window-focus", "fixture-window-1"],
                 @["wait", "--element", "--role", "button", "--wait-ms", "100"]]:
      let err = failure(@["--session", "dies"] & argv, env, 4, "session-not-running")
      check err{"details", "feature"} != nil and err["details"]["feature"].kind == JNull
    let info = ok(@["session-info", "dies"], env)["session"]
    check info["state"].getStr == "error"
    check ok(@["session-stop", "dies"], env)["session"]["state"].getStr == "stopped"
    discard failure(@["--session", "dies", "windows"], env, 3, "session")

  test "test_session_start_readiness_and_name_in_use":
    # C10. session-start returns a running session or exit 5 within the
    # readiness bound, leaving nothing behind; a name in use is exit 2 /
    # name-in-use.
    let st = freshDir("c10")
    let env = fixtureEnv(st)
    let s = ok(@["session-start", "--kind", "headless", "--name", "r1"], env)["session"]
    check s["state"].getStr == "running"
    when defined(posix):
      check posix.kill(Pid(s["hostPid"].getInt), 0) == 0
    # Usable at once.
    check ok(@["--session", "r1", "app-launch", "--bundle-id", "dev.example.Notes"],
             env)["window"].kind == JObject
    let before = readFile(st / "sessions" / "r1.json")
    let inUse = failure(@["session-start", "--kind", "headless", "--name", "r1"], env, 2,
                        "name-in-use")
    check inUse["details"]["name"].getStr == "r1" and inUse["details"]["state"].getStr == "running"
    check readFile(st / "sessions" / "r1.json") == before
    # A session in error still holds its name.
    killHost(s["hostPid"].getInt)
    let inErr = failure(@["session-start", "--kind", "headless", "--name", "r1"], env, 2,
                        "name-in-use")
    check inErr["details"]["state"].getStr == "error"
    # Stopped, the name is free again (control).
    discard ok(@["session-stop", "r1"], env)
    discard ok(@["session-start", "--kind", "headless", "--name", "r1"], env)
    discard ok(@["session-stop", "r1"], env)
    # A generated id never takes a name in use.
    discard ok(@["session-start", "--kind", "headless", "--name", "fixture-1"], env)
    let gen = ok(@["session-start", "--kind", "headless"], env)["session"]["id"].getStr
    check gen != "fixture-1" and gen.startsWith("fixture-")
    discard ok(@["session-stop", gen], env)
    discard ok(@["session-stop", "fixture-1"], env)
    # A host that exits before it is ready: exit 5 at once, no record.
    let t0 = getMonoTime()
    discard failure(@["session-start", "--kind", "headless", "--name", "r2"],
                    fixtureEnv(st, {"GUIASSERT_FIXTURE_HOST": "exit-before-ready"}), 5,
                    "session-failed")
    check msSince(t0) < 5000
    check not fileExists(st / "sessions" / "r2.json")
    # A host that never reports ready: exit 5 (not 7) within --timeout-ms.
    let t1 = getMonoTime()
    discard failure(@["--timeout-ms", "1500", "session-start", "--kind", "headless",
                      "--name", "r3"],
                    fixtureEnv(st, {"GUIASSERT_FIXTURE_HOST": "never-ready"}), 5,
                    "session-failed")
    let took = msSince(t1)
    check took >= 1000 and took < 1500
    check not fileExists(st / "sessions" / "r3.json")
    check ok(@["session-list"], env)["sessions"].len == 1      # host only
    when defined(posix):
      check sessionHostsOf(st) == 0
    discard failure(@["session-start", "--kind", "headless"],
                    fixtureEnv(st, {"GUIASSERT_FIXTURE_HOST": "sometimes"}), 2, "invalid-value")

  test "test_app_launch_wait_expiry_reports_the_app":
    # C11. When --wait-window-ms expires with the process running, exit 7 /
    # condition-not-met carries the App so the caller can quit it.
    let scn = scenarioFile(freshDir("c11-scn"), proc (n: JsonNode) =
      n["launchWindow"] = %false)
    let st = freshDir("c11")
    let env = fixtureEnv(st, {"GUIASSERT_FIXTURE_SCENARIO": scn})
    let t0 = getMonoTime()
    let err = failure(@["app-launch", "--bundle-id", "dev.example.Headless",
                        "--wait-window-ms", "300"], env, 7, "condition-not-met")
    check msSince(t0) >= 300
    let app = err["details"]["app"]
    check app["name"].getStr == "Headless" and app["pid"].getInt > 0
    # Still running, and the caller can quit it.
    check ok(@["apps"], env)["apps"].anyIt(it["pid"] == app["pid"])
    check ok(@["app-quit", $app["pid"].getInt], env)["exited"].getBool
    check not ok(@["apps"], env)["apps"].anyIt(it["pid"] == app["pid"])
    # Without --wait-window-ms nothing is waited for: window null, exit 0.
    let nowait = ok(@["app-launch", "--bundle-id", "dev.example.Headless"], env)
    check nowait["window"].kind == JNull
    # Control: an application that opens a window satisfies the wait.
    let st2 = freshDir("c11b")
    let withWin = ok(@["app-launch", "--bundle-id", "dev.example.Notes",
                       "--wait-window-ms", "300"], fixtureEnv(st2))
    check withWin["window"]["pid"] == withWin["app"]["pid"]

  test "test_recording_metadata_is_measured_and_unfinalized_is_exit_5":
    # C12. The reported frames, duration and size are what the file
    # measures; a file that is not finalized is exit 5, never stopped.
    let st = freshDir("c12")
    let work = freshDir("c12-work")
    let env = fixtureEnv(st)
    let minimal = isMinimalBinary()
    proc measured(r: JsonNode) =
      let path = r["path"].getStr
      if minimal:
        check r["format"].getStr == "png-sequence"
        var frames: seq[string]
        for f in walkFiles(path / "*.png"): frames.add f
        check r["frames"].getInt == frames.len
        check pngSize(frames[0]) == (r["width"].getInt, r["height"].getInt)
        check r["durationMs"].getInt == int(float(frames.len) * 1000.0 / r["fps"].getFloat + 0.5)
      else:
        check r["format"].getStr == "mp4"
        let p = ffprobe(path)
        check r["frames"].getInt == p.frames
        check r["width"].getInt == p.width and r["height"].getInt == p.height
        check r["durationMs"].getInt == p.durationMs
    let blocking = ok(@["record", "--out", work / "a.mp4", "--duration-ms", "300",
                        "--fps", "10"], env)["recording"]
    check blocking["state"].getStr == "stopped" and blocking["frames"].getInt == 3
    measured(blocking)
    discard ok(@["record-start", "--out", work / "b.mp4", "--fps", "5"], env)
    let stopped = ok(@["record-stop", "rec-2"], env)["recording"]
    check stopped["state"].getStr == "stopped"
    measured(stopped)
    # Unfinalized: exit 5 / capture-failed, the recording failed.
    let bad = fixtureEnv(st, {"GUIASSERT_FIXTURE_RECORDING": "unfinalized"})
    let e1 = failure(@["record", "--out", work / "c.mp4", "--duration-ms", "200"], bad, 5,
                     "capture-failed")
    check e1["details"]["recording"]["state"].getStr == "failed"
    check e1["details"]["recording"]["frames"].kind == JNull
    discard ok(@["record-start", "--out", work / "d.mp4"], bad)
    let e2 = failure(@["record-stop", "rec-4"], bad, 5, "capture-failed")
    check e2["details"]["recording"]["id"].getStr == "rec-4"
    var states = initTable[string, string]()
    for r in ok(@["recordings"], env)["recordings"]: states[r["id"].getStr] = r["state"].getStr
    check states == {"rec-1": "stopped", "rec-2": "stopped", "rec-3": "failed",
                     "rec-4": "failed"}.toTable
    discard failure(@["record", "--out", work / "e.mp4", "--duration-ms", "100"],
                    fixtureEnv(st, {"GUIASSERT_FIXTURE_RECORDING": "sometimes"}), 2,
                    "invalid-value")

  test "test_matching_is_case_sensitive_with_ignore_case_and_unambiguous_app":
    # C13. --name / --name-contains are case-sensitive; --ignore-case folds
    # case; --app is exact and refuses an ambiguous name with the pids.
    let st = freshDir("c13")
    let env = fixtureEnv(st)
    proc count(args: seq[string]): int = ok(@["find"] & args, env)["elements"].len
    check count(@["--name", "Submit"]) == 1
    check count(@["--name", "submit"]) == 0
    check count(@["--name", "SUBMIT", "--ignore-case"]) == 1
    check count(@["--name-contains", "ubmi"]) == 1
    check count(@["--name-contains", "UBMI"]) == 0
    check count(@["--name-contains", "UBMI", "--ignore-case"]) == 1
    discard failure(@["find", "--ignore-case"], env, 2, "conflicting-arguments")
    discard failure(@["wait", "--element", "--name", "submit", "--wait-ms", "100"], env, 7,
                    "condition-not-met")
    check ok(@["wait", "--element", "--name", "submit", "--ignore-case", "--wait-ms", "100"],
             env)["element"]["name"].getStr == "Submit"
    # --app: exact name; two applications of one name are refused.
    check ok(@["tree", "--app", "Fixture Form"], env)["root"]["path"].getStr == "/app[4242]"
    discard failure(@["tree", "--app", "fixture form"], env, 3, "app")
    let p1 = ok(@["app-launch", "--bundle-id", "dev.example.Notes"], env)["app"]["pid"].getInt
    let p2 = ok(@["app-launch", "--bundle-id", "org.example.Notes"], env)["app"]["pid"].getInt
    for argv in [@["tree", "--app", "Notes"], @["find", "--app", "Notes", "--role", "window"],
                 @["wait", "--element", "--app", "Notes", "--role", "window", "--wait-ms", "100"]]:
      let err = failure(argv, env, 2, "conflicting-arguments")
      check err["details"]["pids"] == %*[p1, p2]
    check ok(@["tree", "--pid", $p1], env)["root"]["path"].getStr == "/app[" & $p1 & "]"
    # windows --app is a filter: both applications' windows.
    check ok(@["windows", "--app", "Notes"], env)["windows"].len == 2
    check ok(@["windows", "--app", "notes"], env)["windows"].len == 0

  test "test_secret_input_from_stdin_never_on_argv":
    # C14. type --stdin and element-action --value-stdin take the secret
    # from standard input (the serve request's `stdin` key), exactly.
    let st = freshDir("c14")
    let env = fixtureEnv(st)
    let field = "/app[4242]/window[0]/text-field[0]"
    let typed = cliIn(@["type", "--stdin"], env, "Ada L\n")
    check typed.exit == 0
    check typed.env.data["input"]["length"].getInt == 6
    check element(env, field)["value"].getStr == "Ada L\n"     # nothing stripped
    let set = cliIn(@["element-action", field, "set-value", "--value-stdin"], env, "Grace")
    check set.exit == 0 and set.env.data["element"]["value"].getStr == "Grace"
    for (argv, reason) in [(@["type", "x", "--stdin"], "conflicting-arguments"),
                           (@["type", "--stdin", "--text-file", "/nonexistent"],
                            "conflicting-arguments"),
                           (@["element-action", field, "press", "--value-stdin"],
                            "conflicting-arguments"),
                           (@["element-action", field, "set-value", "--value", "a",
                              "--value-stdin"], "conflicting-arguments")]:
      let r = cliIn(argv, env, "zz")
      check r.exit == 2 and r.env.errorReason == reason
    let invalid = cliIn(@["type", "--stdin"], env, "\xff\xfe")
    check invalid.exit == 2 and invalid.env.errorReason == "invalid-value"
    let huge = cliIn(@["type", "--stdin"], env, repeat('a', (1 shl 20) + 1))
    check huge.exit == 2 and huge.env.errorReason == "invalid-value"
    check element(env, field)["value"].getStr == "Grace"         # neither had an effect
    when defined(posix):
      # A writer that never closes stdin cannot hold the verb past the
      # global --timeout-ms deadline (spec §7.1): exit 7 / deadline, at once.
      let t0 = getMonoTime()
      let held = startProcess(contractBin(), args = @["--timeout-ms", "400", "type", "--stdin"],
                              env = env, options = {})
      let heldExit = held.waitForExit(10_000)
      let heldOut = held.outputStream.readAll()
      held.inputStream.close()
      held.close()
      check heldExit == 7 and parseJson(heldOut.strip)["error"]["reason"].getStr == "deadline"
      check msSince(t0) < 3000
    # Over serve: the request's stdin, byte-identical to the CLI.
    let cliLine = cliIn(@["type", "--stdin"], env, "Hopper").line
    var d = startServe(@["serve", "--stdio"], env)
    d.send(%*{"v": 1, "id": "t1", "op": "run", "argv": ["type", "--stdin"],
              "stdin": "Hopper"})
    let r1 = d.recvRaw()
    check envelopeText(r1) == cliLine
    d.send(%*{"v": 1, "id": "t2", "op": "run",
              "argv": ["element-action", field, "set-value", "--value-stdin"],
              "stdin": ""})
    check parseJson(d.recvRaw())["envelope"]["data"]["element"]["value"].getStr == ""
    d.send(%*{"v": 1, "id": "t3", "op": "run", "argv": ["windows"], "stdin": "unused"})
    let r3 = parseJson(d.recvRaw())
    check r3["exit"].getInt == 2 and r3["envelope"]["error"]["reason"].getStr ==
      "conflicting-arguments"
    d.send(%*{"v": 1, "id": "t4", "op": "run", "argv": ["type", "--stdin"]})
    let r4 = parseJson(d.recvRaw())
    check r4["exit"].getInt == 2 and r4["envelope"]["error"]["reason"].getStr ==
      "missing-argument"
    d.send(%*{"v": 1, "id": "t5", "op": "run", "argv": ["type", "--stdin"], "stdin": 5})
    check parseJson(d.recvRaw())["type"].getStr == "protocol-error"
    d.closeInput()
    discard d.reader.readLine(30_000)        # the shutdown line
    check d.finish() == 0

  test "test_no_captured_content_outside_data":
    # C15. Typed text, set values, protected characters and OCR text never
    # reach stderr, a serve event or an error message; every image file
    # wait --text and watch --frames write is reported.
    const typedText = "Zq7typed"
    const setText = "Vx9value"
    const secret = "Pw4secret"
    const extraArg = "Mk2extra"
    let planted = [typedText, setText, secret, extraArg, "Submitted"]
    let st = freshDir("c15")
    let work = freshDir("c15-work")
    let env = fixtureEnv(st)
    var stderrs: seq[string]
    var r = runCliInput(@["type", "--stdin"], env, typedText)
    check r.exit == 0
    stderrs.add r.stderr
    r = runCliInput(@["element-action", "/app[4242]/window[0]/text-field[1]", "set-value",
                      "--value-stdin"], env, secret)
    check r.exit == 0 and secret notin r.stdout
    stderrs.add r.stderr
    # An extra argument to `type` is refused without echoing it.
    let extra = runCli(@["type", typedText, extraArg], env)
    check extra.exit == 2 and extraArg notin extra.stdout and typedText notin extra.stdout
    stderrs.add extra.stderr
    for argv in [@["click", "--at", submitCenter], @["screenshot", "--out", work / "s.png"],
                 @["ocr", "--image", work / "s.png"], @["tree", "--pid", "4242"]]:
      let x = runCli(argv, env)
      check x.exit == 0
      stderrs.add x.stderr
    check typedText in runCli(@["ocr", "--image", work / "s.png"], env).stdout   # in data
    # The one-shot watch's events file holds events only.
    let framesCli = work / "frames-cli"
    createDir(framesCli)
    let evFile = work / "events.ndjson"
    let w = runCli(@["watch", "--frames", "--out-dir", framesCli, "--fps", "10",
                     "--duration-ms", "300", "--events-file", evFile], env)
    check w.exit == 0
    stderrs.add w.stderr
    var cliFramePaths: seq[string]
    for line in readFile(evFile).splitLines:
      if line.len == 0: continue
      for p in planted: check p notin line
      let ev = parseJson(line)
      if ev["event"].getStr == "frame": cliFramePaths.add ev["data"]["image"]["path"].getStr
    var onDisk: seq[string]
    for f in walkFiles(framesCli / "*"): onDisk.add f
    check cliFramePaths.len == 3
    check toHashSet(onDisk) == toHashSet(cliFramePaths)
    # wait --text: a match reports its one frame; a miss leaves nothing.
    let hit = work / "hit"
    let miss = work / "miss"
    createDir(hit)
    createDir(miss)
    let wh = ok(@["wait", "--text", typedText, "--out-dir", hit, "--wait-ms", "500"], env)
    var hitFiles: seq[string]
    for f in walkFiles(hit / "*"): hitFiles.add f
    check hitFiles == @[wh["image"]["path"].getStr]
    let wm = runCli(@["wait", "--text", "Nowhere9", "--out-dir", miss, "--wait-ms", "200",
                      "--interval-ms", "50"], env)
    check wm.exit == 7
    stderrs.add wm.stderr
    check toSeq(walkFiles(miss / "*")).len == 0
    for s in stderrs:
      for p in planted: check p notin s
    # Over serve: no event carries captured content; stderr neither.
    var sv = startServe(@["serve", "--stdio"], env)
    let framesServe = work / "frames-serve"
    let cancelDir = work / "cancelled"
    createDir(framesServe)
    createDir(cancelDir)
    var events: seq[string]
    var results = initTable[string, JsonNode]()
    proc request(d: var Daemon, id: string, argv: seq[string], stdin = "") =
      var m = %*{"v": 1, "id": id, "op": "run", "argv": argv}
      if stdin.len > 0: m["stdin"] = %stdin
      d.send(m)
      while true:
        let line = d.recvRaw()
        let msg = parseJson(line)
        if msg["type"].getStr == "event": events.add line
        elif msg["type"].getStr == "result" and msg["id"].getStr == id:
          results[id] = msg
          return
    sv.request("a", @["type", "--stdin"], typedText & "2")
    sv.request("b", @["element-action", "/app[4242]/window[0]/text-field[0]", "set-value",
                      "--value-stdin"], setText)
    sv.request("c", @["click", "--at", submitCenter])
    sv.request("d", @["wait", "--text", setText, "--out-dir", hit, "--wait-ms", "500"])
    sv.request("e", @["watch", "--windows", "--duration-ms", "300"])
    sv.request("f", @["watch", "--frames", "--out-dir", framesServe, "--fps", "10",
                      "--duration-ms", "300"])
    sv.request("g", @["record", "--out", work / "r.mp4", "--duration-ms", "300"])
    sv.request("h", @["wait", "--text", "Nowhere9", "--out-dir", miss, "--wait-ms", "200",
                      "--interval-ms", "50"])
    sv.request("i", @["tree", "--pid", "4242"])
    for id in ["a", "b", "c", "d", "e", "f", "g", "i"]:
      check results[id]["exit"].getInt == 0
    check results["h"]["exit"].getInt == 7
    check setText in $results["i"]["envelope"]["data"]          # data has it
    check events.len >= 10
    for line in events:
      for p in planted: check p notin line
    var serveFrames: seq[string]
    for line in events:
      let ev = parseJson(line)
      if ev["event"].getStr == "frame": serveFrames.add ev["data"]["image"]["path"].getStr
    check toHashSet(toSeq(walkFiles(framesServe / "*"))) == toHashSet(serveFrames)
    check serveFrames.len == 3
    check toSeq(walkFiles(miss / "*")).len == 0
    # A cancelled wait --text leaves no frame behind either.
    sv.send(%*{"v": 1, "id": "w", "op": "run",
               "argv": ["wait", "--text", "Nowhere9", "--out-dir", cancelDir,
                        "--wait-ms", "20000", "--interval-ms", "50"]})
    sleep(300)
    sv.send(%*{"v": 1, "id": "x", "op": "cancel", "target": "w"})
    var cancelled = false
    while not cancelled:
      let m = sv.recv()
      if m["type"].getStr == "event":
        for p in planted: check p notin $m
      if m["type"].getStr == "result" and m["id"].getStr == "w":
        check m["exit"].getInt == 8
        cancelled = true
    check toSeq(walkFiles(cancelDir / "*")).len == 0
    sv.closeInput()
    while true:
      let m = sv.recv()
      if m["type"].getStr == "shutdown": break
    discard sv.p.waitForExit(30_000)
    let daemonStderr = sv.p.errorStream.readAll()
    for p in planted: check p notin daemonStderr
    sv.p.close()

  test "test_set_value_empty_clears_the_field":
    # C16. set-value --value "" is valid and clears the field.
    let st = freshDir("c16")
    let work = freshDir("c16-work")
    let env = fixtureEnv(st)
    let field = "/app[4242]/window[0]/text-field[0]"
    discard ok(@["element-action", field, "set-value", "--value", "Ada"], env)
    check element(env, field)["value"].getStr == "Ada"
    var text = ""
    for w in ocrWords(env, work, "before.png"): text.add w["text"].getStr & " "
    check "Ada" in text                                         # control
    let cleared = ok(@["element-action", field, "set-value", "--value", ""], env)["element"]
    check cleared["value"].getStr == "" and cleared["text"].getStr == ""
    text = ""
    for w in ocrWords(env, work, "after.png"): text.add w["text"].getStr & " "
    check "Ada" notin text
    discard ok(@["element-action", field, "set-value", "--value", "Bo"], env)
    let viaStdin = cliIn(@["element-action", field, "set-value", "--value-stdin"], env, "")
    check viaStdin.exit == 0 and viaStdin.env.data["element"]["value"].getStr == ""

  test "test_drag_path_delivers_waypoints_in_order":
    # C17. drag --path adds waypoints between --from and --to, delivered in
    # order with the button held; the report says what was delivered.
    let st = freshDir("c17")
    let env = fixtureEnv(st)
    let t0 = getMonoTime()
    let d = ok(@["drag", "--from", "1,1", "--path", "10,20;30,40;50,5", "--to", "60,60",
                 "--duration-ms", "300", "--steps", "3"], env)["input"]
    check msSince(t0) >= 300
    check d["path"] == %*[[1, 1], [10, 20], [30, 40], [50, 5], [60, 60]]
    check d["at"] == %*[1, 1] and d["to"] == %*[60, 60] and d["button"].getStr == "left"
    let plain = ok(@["drag", "--from", "1,1", "--to", "60,60"], env)["input"]
    check plain["path"] == %*[[1, 1], [60, 60]]
    check ok(@["move", "--to", "5,5"], env)["input"]["path"].kind == JNull
    for bad in ["10,20;", ";10,20", "10;20", "a,b", "1,2,3", ""]:
      discard failure(@["drag", "--from", "1,1", "--to", "2,2", "--path", bad], env, 2,
                      "invalid-value")
    var many: seq[string]
    for i in 0 ..< 1001: many.add $i & "," & $i
    discard failure(@["drag", "--from", "1,1", "--to", "2,2", "--path", many.join(";")], env,
                    2, "invalid-value")
    let most = ok(@["drag", "--from", "1,1", "--to", "2,2", "--path",
                    many[0 ..< 1000].join(";"), "--steps", "1"], env)["input"]
    check most["path"].len == 1002

cleanupFreshDirs()
