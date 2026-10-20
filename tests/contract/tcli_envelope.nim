## The one-shot CLI's envelope and exit codes (spec §7.2, §7.3), and the
## reject-don't-drop rule (spec §2, §7.4), checked against the REAL built
## binary run as a subprocess.
##
## Stand-ins: the fixture backend only (spec §9.2), selected below the real
## binary. Its failure-injection variables are how exits 1..8 are produced
## on demand; the failures a real backend cannot be made to produce on a
## test host (permission denied, a backend error) are exactly the ones the
## fixture exists to inject.

import std/[json, os, osproc, sequtils, streams, strtabs, strutils, tables, unittest, times, monotimes]

when defined(posix):
  import std/posix

import ./harness
from ../../src/gui_assert/backends/fixture_desktop import builtinScenarioJson

const
  frozenKinds = ["internal", "bad-args", "not-found", "backend-unavailable",
                 "backend-error", "permission-denied", "timeout", "cancelled"]
    ## Spec §7.3: the kind of exit code i+1.
  frozenReasons = {
    "internal": @["exception", "serialization"],
    "bad-args": @["unknown-verb", "unknown-flag", "missing-argument", "invalid-value",
                  "conflicting-arguments", "unknown-backend", "contract-unsupported",
                  "invalid-name", "name-in-use"],
    "not-found": @["session", "display", "window", "app", "element", "recording",
                   "file", "request"],
    "backend-unavailable": @["not-compiled-in", "wrong-platform", "missing-tool",
                             "display-server-unsupported", "unsupported-option",
                             "not-implemented", "no-isolated-session",
                             "session-not-running"],
    "backend-error": @["capture-failed", "ocr-failed", "tree-failed", "input-failed",
                       "session-failed", "busy", "stale-path"],
    "permission-denied": @["tcc-screen-recording", "tcc-accessibility",
                           "uinput-access", "atspi-disabled", "desktop-access"],
    "timeout": @["deadline", "condition-not-met"],
    "cancelled": @["request", "signal", "shutdown"]}.toTable
    ## Spec §7.3, copied by hand from the table so the test does not trust
    ## the implementation's own copy.

template checkFailure(exit: int, e: JsonNode, line: string) =
  ## The shape every failure envelope has (spec §7.2). A template, so its
  ## checks fail the test that uses it (a `check` in a proc does not).
  check e["ok"].getBool == false
  check toSeq(e.keys) == @["ok", "verb", "error"]
  let err = e["error"]
  check toSeq(err.keys) == @["code", "kind", "message", "reason", "remedy", "details"]
  check err["code"].getInt == exit
  check exit in 1..8
  if exit in 1..8:
    check err["kind"].getStr == frozenKinds[exit - 1]
  check err["message"].kind == JString and err["message"].getStr.len > 0
  check err["reason"].kind in {JString, JNull}
  if err["reason"].kind == JString:
    check err["reason"].getStr in frozenReasons[err["kind"].getStr]
  check err["remedy"].kind in {JString, JNull}
  check err["details"].kind in {JObject, JNull}
  # Exit 4 and exit 6 always name the feature they lacked (spec §7.2): a
  # name of the spec's vocabulary, or null exactly for the reasons that are
  # not about a capability.
  if exit in {4, 6}:
    check err["details"].kind == JObject
    if err["details"].kind == JObject:
      check err["details"].hasKey("feature")
      let f = err["details"]{"feature"}
      if f != nil:
        check f.kind in {JString, JNull}
        if f.kind == JString:
          check specFeatures().anyIt(it[0] == f.getStr)
          check err["reason"].getStr != "session-not-running"
        if err["reason"].getStr == "session-not-running": check f.kind == JNull
  check $parseJson(line) == line      # compact, one line

suite "CLI envelope":
  test "test_envelope_success_is_one_line_with_ok_verb_data":
    let st = freshDir("ok")
    let work = freshDir("ok-work")
    prepareWork(work)
    let env = fixtureEnv(st)
    for argv in everyVerbScenario(work):
      let r = runCli(argv, env)
      check r.exit == 0
      check r.stdout.count('\n') == 1 and r.stdout.endsWith("\n")
      let line = r.stdout[0 ..< ^1]
      let e = parseJson(line)
      check toSeq(e.keys) == @["ok", "verb", "data"]
      check e["ok"].getBool
      check e["verb"].getStr == argv[0]
      check e["data"].kind == JObject
      # Compact: re-rendering the parsed value reproduces the line exactly.
      check $e == line
      if r.exit != 0: checkpoint argv.join(" ") & " -> " & r.stdout

  test "test_envelope_failure_carries_code_kind_message_and_matching_exit":
    let st = freshDir("fail")
    let env = fixtureEnv(st)
    # Failures the binary produces on its own, one per kind it can reach
    # without injection, plus every injected code.
    var cases: seq[(seq[string], StringTableRef, int)] = @[
      (@["no-such-verb"], env, 2),
      (@["session-info", "nobody"], env, 3),
      (@["displays"], baseEnv(), 4),                      # the platform default
      (@["--session", "ghost", "displays"], env, 3),
      (@["ocr", "--image", st / "missing.png"], env, 3)]
    for code in 1..8:
      cases.add (@["displays"], fixtureEnv(st, {"GUIASSERT_FIXTURE_FAIL": "displays:" & $code}), code)
    for (argv, e, want) in cases:
      let r = runCli(argv, e)
      let envl = envelopeOf(r)
      check r.exit == want
      checkFailure(r.exit, envl, r.stdout[0 ..< ^1])
      check envl["verb"].getStr == argv[^1] or envl["verb"].getStr == argv[0]
    # Keys that do not apply are null, not empty (spec §7.2): an injected
    # failure and an unknown verb carry neither remedy nor details ...
    for argv in [@["no-such-verb"]]:
      let (_, e, _) = cli(argv, env)
      check e["error"]["details"].kind == JNull and e["error"]["remedy"].kind == JNull
    let (_, inj, _) = cli(@["displays"], fixtureEnv(st, {"GUIASSERT_FIXTURE_FAIL": "displays:5"}))
    check inj["error"]["details"].kind == JNull and inj["error"]["remedy"].kind == JNull
    # ... while an unavailable backend says which one, and what to do.
    let (_, un, _) = cli(@["displays"], baseEnv())
    check un["error"]["details"]["module"].getStr == "capture"
    check un["error"]["remedy"].kind == JString

  test "test_fixture_failure_injection_maps_every_exit_code":
    let st = freshDir("inject")
    for kindIdx, kind in frozenKinds:
      let code = kindIdx + 1
      # The default reason is the kind's first one.
      let (exit, e, line) = cli(@["windows"], fixtureEnv(st,
        {"GUIASSERT_FIXTURE_FAIL": "windows:" & $code}))
      check exit == code
      check e.errorKind == kind
      check e.errorReason == frozenReasons[kind][0]
      checkFailure(exit, e, line)
      # Every reason of the kind can be injected and comes back verbatim.
      for reason in frozenReasons[kind]:
        let (x2, e2, _) = cli(@["windows"], fixtureEnv(st,
          {"GUIASSERT_FIXTURE_FAIL": "windows:" & $code & ":" & reason}))
        check x2 == code
        check e2.errorReason == reason
    # Injection names a verb: another verb is unaffected.
    let (okExit, _, _) = cli(@["displays"], fixtureEnv(st, {"GUIASSERT_FIXTURE_FAIL": "windows:5"}))
    check okExit == 0
    # A reason from another kind is refused, not passed through.
    let (badExit, bad, _) = cli(@["windows"], fixtureEnv(st,
      {"GUIASSERT_FIXTURE_FAIL": "windows:5:deadline"}))
    check badExit == 2
    check bad.errorReason == "invalid-value"
    # DENY and UNAVAILABLE produce 6 and 4 through the real code paths.
    let (dx, de, _) = cli(@["screenshot", "--out", st / "x.png"],
                          fixtureEnv(st, {"GUIASSERT_FIXTURE_DENY": "screen-recording"}))
    check dx == 6
    check de.errorReason == "tcc-screen-recording"
    check de["error"]["remedy"].kind == JString
    check not fileExists(st / "x.png")
    let (ax, ae, _) = cli(@["tree", "--pid", "4242"],
                          fixtureEnv(st, {"GUIASSERT_FIXTURE_DENY": "accessibility"}))
    check ax == 6
    check ae.errorReason == "tcc-accessibility"
    let (ux, ue, _) = cli(@["displays"], fixtureEnv(st, {"GUIASSERT_FIXTURE_UNAVAILABLE": "capture"}))
    check ux == 4
    check ue.errorKind == "backend-unavailable"
    # A denied Screen Recording is never an empty success: windows reports
    # its titles as hidden instead of dropping them silently.
    let (wx, we, _) = cli(@["windows"], fixtureEnv(st, {"GUIASSERT_FIXTURE_DENY": "screen-recording"}))
    check wx == 0
    check we.data["titlesVisible"].getBool == false
    check we.data["windows"].len == 1
    check we.data["windows"][0]["title"].kind == JNull

  test "test_unknown_verb_and_unknown_flag_are_bad_args":
    let st = freshDir("badargs")
    let env = fixtureEnv(st)
    let (x1, e1, _) = cli(@["windowz"], env)
    check x1 == 2 and e1.errorReason == "unknown-verb" and e1["verb"].getStr == "windowz"
    let (x2, e2, _) = cli(@["windows", "--bogus"], env)
    check x2 == 2 and e2.errorReason == "unknown-flag" and e2["verb"].getStr == "windows"
    let (x3, e3, _) = cli(@["--bogus", "windows"], env)
    check x3 == 2 and e3.errorReason == "unknown-flag"
    let (x4, e4, _) = cli(@["--backend", "no-such-backend", "windows"], env)
    check x4 == 2 and e4.errorReason == "unknown-backend"
    let (x5, e5, _) = cli(@["windows"], fixtureEnv(st, {"GUIASSERT_CAPTURE_BACKEND": "nope"}))
    check x5 == 2 and e5.errorReason == "unknown-backend"
    let (x6, e6, _) = cli(@["--capture-backend", "apple-vision", "windows"], env)
    check x6 == 2 and e6.errorReason == "unknown-backend"    # an OCR name, not a capture one
    let (x7, e7, _) = cli(@["screenshot", "--out"], env)
    check x7 == 2 and e7.errorReason == "missing-argument"
    let (x8, e8, _) = cli(@["windows", "--pid", "1", "--pid", "2"], env)
    check x8 == 2 and e8.errorReason == "conflicting-arguments"
    let (x9, e9, _) = cli(@["displays", "extra"], env)
    check x9 == 2 and e9.errorReason == "invalid-value"
    let (x10, e10, _) = cli(@[], env)
    check x10 == 2 and e10.errorReason == "missing-argument" and e10["verb"].getStr == ""
    let (x11, e11, _) = cli(@["windows", "--", "x"], env)
    check x11 == 2 and e11.errorReason == "invalid-value"
    let (x12, e12, _) = cli(@["key", "cmd+nosuchkey"], env)
    check x12 == 2 and e12.errorReason == "invalid-value"
    let (x13, e13, _) = cli(@["--fixture-scenario", "s.json", "displays"], baseEnv())
    check x13 == 2 and e13.errorReason == "conflicting-arguments"
    # Inputs read from files are bounded: an oversized text file or scenario
    # is refused, never read without limit (spec §7.4, values out of range).
    let big = freshDir("badargs-big")
    writeFile(big / "big.txt", "a".repeat((1 shl 20) + 1))
    let (x14, e14, _) = cli(@["type", "--text-file", big / "big.txt"], env)
    check x14 == 2 and e14.errorReason == "invalid-value"
    writeFile(big / "big.json", "{\"pad\":\"" & "a".repeat(4 shl 20) & "\"}")
    let (x15, e15, _) = cli(@["displays"], fixtureEnv(st,
      {"GUIASSERT_FIXTURE_SCENARIO": big / "big.json"}))
    check x15 == 2 and e15.errorReason == "invalid-value"
    # Scenario files are parsed strictly (spec §7.4, §9.2): an unknown key,
    # at the top or nested in a window, is refused, never ignored.
    var top = parseJson(builtinScenarioJson)
    top["colour"] = %"blue"
    writeFile(big / "top.json", $top)
    var nested = parseJson(builtinScenarioJson)
    nested["windows"][0]["opacity"] = %0.5
    writeFile(big / "nested.json", $nested)
    # (A state directory of its own: the fixture state belongs to one scenario.)
    let scenEnv = fixtureEnv(freshDir("badargs-scen"))
    for f in ["top.json", "nested.json"]:
      let (sx, se, _) = cli(@["--fixture-scenario", big / f, "windows"], scenEnv)
      check sx == 2 and se.errorReason == "invalid-value"
      check "unknown key" in se["error"]["message"].getStr
    # Control: the same scenario without the extra key is accepted.
    writeFile(big / "plain.json", builtinScenarioJson)
    check cli(@["--fixture-scenario", big / "plain.json", "windows"], scenEnv).exit == 0
    # Control: the same invocations, well-formed, succeed.
    let (ok1, _, _) = cli(@["windows", "--pid", "4242"], env)
    check ok1 == 0
    let (ok2, _, _) = cli(@["key", "cmd+s"], env)
    check ok2 == 0
    writeFile(big / "small.txt", "a".repeat(200))
    let (ok3, oe3, _) = cli(@["type", "--text-file", big / "small.txt"], env)
    check ok3 == 0 and oe3.data["input"]["length"].getInt == 200

  test "test_reject_dont_drop_unsupported_option_is_exit_4":
    let st = freshDir("reject")
    let work = freshDir("reject-work")
    # A scenario like a compositor without per-window capture.
    var scen = parseJson(builtinScenarioJson)
    scen["windowCapture"] = %"crop"
    writeFile(work / "crop.json", $scen)
    let cropEnv = fixtureEnv(st, {"GUIASSERT_FIXTURE_SCENARIO": work / "crop.json"})
    let (x1, e1, _) = cli(@["screenshot", "--window", "fixture-window-1", "--own-pixels",
                            "--out", work / "own.png"], cropEnv)
    check x1 == 4
    check e1.errorReason == "unsupported-option"
    check not fileExists(work / "own.png")
    # Control: without --own-pixels the crop is taken and says so.
    let (c1, ce1, _) = cli(@["screenshot", "--window", "fixture-window-1",
                             "--out", work / "crop.png"], cropEnv)
    check c1 == 0
    check ce1.data["image"]["source"]["kind"].getStr == "window-crop"
    # Control: the default scenario has per-window capture.
    let st2 = freshDir("reject-own")
    let (c2, ce2, _) = cli(@["screenshot", "--window", "fixture-window-1", "--own-pixels",
                             "--out", work / "own2.png"], fixtureEnv(st2))
    check c2 == 0
    check ce2.data["image"]["source"]["kind"].getStr == "window"
    # --lifetime owner from the one-shot CLI cannot be honoured.
    let (x2, e2, _) = cli(@["session-start", "--kind", "headless", "--lifetime", "owner"],
                          fixtureEnv(st2))
    check x2 == 4
    check e2.errorReason == "unsupported-option"
    check not dirExists(st2 / "sessions") or toSeq(walkFiles(st2 / "sessions" / "*.json")).len == 0
    # Tesseract-only OCR knobs and an unknown language are refused by the fixture OCR.
    let shot = work / "shot.png"
    let (s0, _, _) = cli(@["screenshot", "--out", shot], fixtureEnv(st2))
    check s0 == 0
    for extra in [@["--psm", "6"], @["--invert", "auto"], @["--upscale", "2"], @["--lang", "deu"]]:
      let (x, e, _) = cli(@["ocr", "--image", shot] & extra, fixtureEnv(st2))
      check x == 4
      check e.errorReason == "unsupported-option"
    let (x3, e3, _) = cli(@["session-start", "--kind", "headless", "--vnc"], fixtureEnv(st2))
    check x3 == 4 and e3.errorReason == "unsupported-option"

  test "test_wait_condition_not_met_exits_7_with_attempts":
    let st = freshDir("wait")
    let env = fixtureEnv(st)
    let (x, e, line) = cli(@["wait", "--element", "--role", "dialog", "--wait-ms", "300",
                             "--interval-ms", "100"], env)
    check x == 7
    check e.errorReason == "condition-not-met"
    check e["error"]["details"]["attempts"].getInt == 4    # at 0, 100, 200, 300 ms
    checkFailure(x, e, line)
    # --timeout-ms not larger than --wait-ms is refused up front.
    let (x2, e2, _) = cli(@["--timeout-ms", "300", "wait", "--element", "--role", "dialog",
                            "--wait-ms", "300"], env)
    check x2 == 2 and e2.errorReason == "conflicting-arguments"
    let (x3, _, _) = cli(@["--timeout-ms", "5000", "wait", "--element", "--role", "dialog",
                           "--wait-ms", "100", "--interval-ms", "50"], env)
    check x3 == 7
    # Negative control: a condition the fixture satisfies matches at once.
    let (ok, oe, _) = cli(@["wait", "--element", "--role", "button", "--name", "Submit",
                            "--wait-ms", "300"], env)
    check ok == 0
    check oe.data["matched"].getBool
    check oe.data["attempts"].getInt == 1
    check oe.data["element"]["name"].getStr == "Submit"
    # --window-gone on a window that stays open expires the same way.
    let (gone, ge, _) = cli(@["wait", "--window-gone", "--title", "Fixture Form",
                              "--wait-ms", "200", "--interval-ms", "50"], env)
    check gone == 7 and ge.errorReason == "condition-not-met"

  # SIGTERM is POSIX; on Windows the cancellation path is covered through
  # serve (tserve_protocol), so this test exists only where the signal does.
  when defined(posix):
    test "test_sigterm_exits_8_with_envelope":
      let st = freshDir("sigterm")
      let env = fixtureEnv(st, {"GUIASSERT_FIXTURE_DELAY_MS": "displays:20000"})
      let p = startProcess(contractBin(), args = @["displays"], env = env, options = {})
      sleep(400)
      let started = getMonoTime()
      check posix.kill(Pid(p.processID), SIGTERM) == 0
      let code = p.waitForExit(10_000)
      let took = (getMonoTime() - started).inMilliseconds
      let output = p.outputStream.readAll()
      p.close()
      check code == 8
      check took < 5000                        # interrupted, not run to the end
      check output.count('\n') == 1
      let e = parseJson(output)
      check e.errorKind == "cancelled"
      check e.errorReason == "signal"
      check e["verb"].getStr == "displays"

cleanupFreshDirs()
