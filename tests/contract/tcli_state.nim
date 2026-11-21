## State across invocations (spec §7.6, §6.1, §9.2) and backend selection
## (spec §3.4), through the REAL built binary, one process per verb.
##
## Stand-ins: the fixture backend (spec §9.2). One test also rewrites the
## `backends` of a real session record to name non-fixture backends, because
## the fixture is the only session backend that exists in GS2 and the rule
## "the session's own backends" can only be told apart from "GUIASSERT_BACKEND"
## when the two name different backends; the record format is the documented
## one (`guiassert/session/1`), and the session itself is real (its host
## process runs).

import std/[json, os, osproc, sequtils, strtabs, strutils, unittest]

when defined(posix):
  import std/posix

import ./harness

proc mode(path: string): int =
  when defined(posix):
    var st: Stat
    doAssert stat(path.cstring, st) == 0, "cannot stat " & path
    int(st.st_mode) and 0o777
  else:
    0

proc sessionRecords(stateDir: string): seq[string] =
  if dirExists(stateDir / "sessions"):
    for f in walkFiles(stateDir / "sessions" / "*.json"): result.add f.extractFilename

proc ocrText(env: StringTableRef, png: string): string =
  let (x, e, line) = cli(@["ocr", "--image", png], env)
  doAssert x == 0, line
  e.data["text"].getStr

suite "CLI state":
  test "test_state_dir_precedence_flag_env_default":
    let flagDir = freshDir("sd-flag")
    let envDir = freshDir("sd-env")
    let home = freshDir("sd-home")
    var env = baseEnv()
    env["GUIASSERT_BACKEND"] = "fixture"
    env["GUIASSERT_STATE_DIR"] = envDir
    env["HOME"] = home
    if env.hasKey("XDG_STATE_HOME"): env.del("XDG_STATE_HOME")
    when defined(windows): env["LOCALAPPDATA"] = home
    # 1. --state-dir wins over the environment.
    let (x1, _, l1) = cli(@["--state-dir", flagDir, "session-start", "--kind", "headless",
                            "--name", "p1"], env)
    check x1 == 0
    check fileExists(flagDir / "sessions" / "p1.json")
    check sessionRecords(envDir).len == 0
    if x1 != 0: checkpoint l1
    # 2. GUIASSERT_STATE_DIR wins over the platform default.
    let (x2, _, _) = cli(@["session-start", "--kind", "headless", "--name", "p2"], env)
    check x2 == 0
    check fileExists(envDir / "sessions" / "p2.json")
    # 3. The platform default, under HOME (or LOCALAPPDATA).
    env.del("GUIASSERT_STATE_DIR")
    let (x3, _, _) = cli(@["session-start", "--kind", "headless", "--name", "p3"], env)
    check x3 == 0
    let defaultDir =
      when defined(macosx): home / "Library" / "Application Support" / "GuiAssert" / "state"
      elif defined(windows): home / "GuiAssert" / "state"
      else: home / ".local" / "state" / "guiassert"
    check fileExists(defaultDir / "sessions" / "p3.json")
    when defined(linux):
      env["XDG_STATE_HOME"] = home / "xdg"
      let (x4, _, _) = cli(@["session-start", "--kind", "headless", "--name", "p4"], env)
      check x4 == 0
      check fileExists(home / "xdg" / "guiassert" / "sessions" / "p4.json")
      check cli(@["session-stop", "p4"], env).exit == 0
      env.del("XDG_STATE_HOME")
    # Records are 0600 in 0700 directories.
    when defined(posix):
      for d in [flagDir, envDir, defaultDir]:
        check mode(d) == 0o700
        check mode(d / "sessions") == 0o700
        check mode(d / "fixture") == 0o700
        check mode(d / "fixture" / "meta.json") == 0o600
      check mode(flagDir / "sessions" / "p1.json") == 0o600
      check mode(envDir / "sessions" / "p2.json") == 0o600
      check mode(defaultDir / "sessions" / "p3.json") == 0o600
    check cli(@["--state-dir", flagDir, "session-stop", "p1"], env).exit == 0
    env["GUIASSERT_STATE_DIR"] = envDir
    check cli(@["session-stop", "p2"], env).exit == 0
    env.del("GUIASSERT_STATE_DIR")
    check cli(@["session-stop", "p3"], env).exit == 0

  test "test_backend_selection_precedence":
    let st = freshDir("select")
    proc selected(args: seq[string], env: StringTableRef): JsonNode =
      let (x, e, line) = cli(args & @["capabilities"], env)
      doAssert x == 0, line
      e.data["selected"]
    # Platform default (spec §4, the bold entries) when nothing is selected.
    let plain = baseEnv()
    plain["GUIASSERT_STATE_DIR"] = st
    # On Linux the capture default follows the caller's session (spec §4.2);
    # without one (no Wayland, X11 or sway variables) it is the bold default.
    for k in ["WAYLAND_DISPLAY", "DISPLAY", "SWAYSOCK", "XDG_CURRENT_DESKTOP"]: plain.del(k)
    let d = selected(@[], plain)
    when defined(macosx):
      check d["capture"].getStr == "macos-sck" and d["ocr"].getStr == "apple-vision" and
            d["tree"].getStr == "macos-ax" and d["input"].getStr == "macos-cgevent" and
            d["session"].getStr == "macos-host"
    elif defined(windows):
      check d["capture"].getStr == "windows-dxgi" and d["ocr"].getStr == "windows-media"
    else:
      check d["capture"].getStr == "linux-wlr" and d["ocr"].getStr == "tesseract" and
            d["tree"].getStr == "linux-atspi" and d["session"].getStr == "linux-host"
      # The session-following capture default, from the environment alone:
      # sway, GNOME on Wayland, X11 without Wayland, and another wlroots
      # compositor. Each choice is the default (no rule above it applies).
      proc withVars(vars: openArray[(string, string)]): StringTableRef =
        result = newStringTable(modeCaseSensitive)
        for k, v in plain: result[k] = v
        for (k, v) in vars: result[k] = v
      check selected(@[], withVars({"WAYLAND_DISPLAY": "wayland-9",
        "SWAYSOCK": "/nonexistent/sway.sock"}))["capture"].getStr == "linux-wlr"
      check selected(@[], withVars({"WAYLAND_DISPLAY": "wayland-9",
        "XDG_CURRENT_DESKTOP": "ubuntu:GNOME"}))["capture"].getStr == "linux-gnome"
      check selected(@[], withVars({"DISPLAY": ":99"}))["capture"].getStr == "linux-x11"
      check selected(@[], withVars({"WAYLAND_DISPLAY": "wayland-9", "DISPLAY": ":0",
        "XDG_CURRENT_DESKTOP": "Hyprland"}))["capture"].getStr == "linux-wlr"
      # An explicit selection still beats the session-following default.
      check selected(@["--capture-backend", "linux-x11"], withVars({"WAYLAND_DISPLAY":
        "wayland-9", "XDG_CURRENT_DESKTOP": "GNOME"}))["capture"].getStr == "linux-x11"
    # GUIASSERT_BACKEND beats the default.
    let envAll = fixtureEnv(st)
    check selected(@[], envAll)["capture"].getStr == "fixture"
    # GUIASSERT_<MODULE>_BACKEND beats GUIASSERT_BACKEND.
    let envMod = fixtureEnv(st, {"GUIASSERT_CAPTURE_BACKEND": "windows-gdi"})
    let s3 = selected(@[], envMod)
    check s3["capture"].getStr == "windows-gdi" and s3["ocr"].getStr == "fixture"
    # --backend beats GUIASSERT_<MODULE>_BACKEND.
    check selected(@["--backend", "fixture"], envMod)["capture"].getStr == "fixture"
    # --<module>-backend beats --backend.
    let s5 = selected(@["--backend", "fixture", "--capture-backend", "linux-x11"], envMod)
    check s5["capture"].getStr == "linux-x11" and s5["tree"].getStr == "fixture"
    # The session's own backends beat the platform default, and lose to the
    # environment. Start a real session, then make its record name other
    # backends than the fixture.
    let (sx, _, sl) = cli(@["session-start", "--kind", "headless", "--name", "sel"], envAll)
    check sx == 0
    if sx != 0: checkpoint sl
    let recPath = st / "sessions" / "sel.json"
    var rec = parseJson(readFile(recPath))
    rec["backends"] = %*{"capture": "macos-cgwindow", "tree": "appium", "input": "linux-xtest"}
    writeFile(recPath, $rec)
    let s6 = selected(@["--session", "sel"], plain)
    check s6["capture"].getStr == "macos-cgwindow"
    check s6["tree"].getStr == "appium"
    check s6["input"].getStr == "linux-xtest"
    check s6["session"].getStr == "fixture"          # the record's own backend
    check s6["ocr"].getStr == d["ocr"].getStr        # sessions name no OCR backend
    check selected(@["--session", "sel"], envAll)["capture"].getStr == "fixture"
    # No fallback: an explicit backend that cannot run here is exit 4, even
    # with the fixture selected for every other module. (A backend of another
    # platform: every platform's own capture backends are implemented now.)
    let (nx, ne, _) = cli(@["--capture-backend", foreignCaptureBackend, "screenshot",
                            "--out", st / "nofallback.png"], envAll)
    check nx == 4
    check ne.errorKind == "backend-unavailable"
    check ne["error"]["details"]["backend"].getStr == foreignCaptureBackend
    check ne["error"]["details"]["selectedBy"].getStr == "module-flag"
    check ne.errorReason in ["wrong-platform", "not-implemented", "not-compiled-in"]
    check not fileExists(st / "nofallback.png")
    when defined(linux):
      # An implemented backend of this platform that cannot run here (no X
      # display in this environment) is exit 4 from that backend, never the
      # fixture (and never the operator's display: the display variables are
      # cleared).
      let noDisplay = fixtureEnv(st)
      for k in ["WAYLAND_DISPLAY", "DISPLAY", "SWAYSOCK", "XDG_CURRENT_DESKTOP"]:
        noDisplay.del(k)
      let (lx, le, _) = cli(@["--capture-backend", "linux-x11", "screenshot", "--out",
                              st / "nofallback-x11.png"], noDisplay)
      check lx == 4
      check le.errorKind == "backend-unavailable"
      check le["error"]["details"]["backend"].getStr == "linux-x11"
      check le.errorReason == (if isMinimalBinary(): "not-compiled-in"
                               else: "display-server-unsupported")
      check not fileExists(st / "nofallback-x11.png")
    # The platform default is not silently replaced either: guiassert-fixture
    # has no platform code at all, so its default is exit 4 / not-compiled-in
    # (never the fixture); in guiassert the default answers itself, or, where
    # it is not implemented yet, is exit 4 / not-implemented naming it, or
    # (Linux, whose default is implemented since GS5) finds no session to
    # capture in this environment and says so: exit 4 /
    # display-server-unsupported from the default backend itself.
    let (px, pe, pl) = cli(@["displays"], plain)
    if isMinimalBinary():
      check px == 4
      check pe["error"]["details"]["selectedBy"].getStr == "default"
      check pe.errorReason == "not-compiled-in"
    elif px == 0:
      # An implemented default (macos-sck since GS5) reports the host's own
      # displays, not the fixture's.
      check "fixture" notin pl
      check pe.data["displays"].kind == JArray
    elif pe.errorReason == "display-server-unsupported":
      check defined(linux)
      check px == 4
      check pe["error"]["details"]["backend"].getStr == d["capture"].getStr
      check pe["error"]["details"]["feature"].getStr == "window-enumeration"
    else:
      check px == 4
      check pe["error"]["details"]["selectedBy"].getStr == "default"
      check pe["error"]["details"]["backend"].getStr == d["capture"].getStr
      check pe.errorReason == "not-implemented"
    when defined(macosx):
      if not isMinimalBinary(): check px == 0
    rec["backends"] = %*{"capture": "fixture", "tree": "fixture", "input": "fixture"}
    writeFile(recPath, $rec)
    check cli(@["session-stop", "sel"], envAll).exit == 0

  test "test_fixture_state_persists_across_invocations":
    let st = freshDir("persist")
    let work = freshDir("persist-work")
    let env = fixtureEnv(st)
    check cli(@["type", "Ada"], env).exit == 0
    check cli(@["click", "--at", "190,278"], env).exit == 0      # the Submit button
    let (fx, fe, _) = cli(@["find", "--role", "label", "--name", "Submitted Ada"], env)
    check fx == 0
    check fe.data["elements"].len == 1
    let (tx, te, _) = cli(@["tree", "--pid", "4242"], env)
    check tx == 0
    check "Submitted Ada" in $te.data
    let (vx, ve, _) = cli(@["element", "/app[4242]/window[0]/text-field[0]"], env)
    check vx == 0 and ve.data["element"]["value"].getStr == "Ada"
    check cli(@["screenshot", "--out", work / "after.png"], env).exit == 0
    check "Submitted Ada" in ocrText(env, work / "after.png")
    # Negative control: the same typing without the click.
    let st2 = freshDir("persist-control")
    let env2 = fixtureEnv(st2)
    check cli(@["type", "Ada"], env2).exit == 0
    let (cx, ce, _) = cli(@["tree", "--pid", "4242"], env2)
    check cx == 0
    check "Submitted" notin $ce.data
    check "Ada" in $ce.data                                        # typing did persist
    check cli(@["screenshot", "--out", work / "before.png"], env2).exit == 0
    let text = ocrText(env2, work / "before.png")
    check "Submitted" notin text
    check "Ada" in text

  test "test_session_lifecycle_start_list_info_stop_via_fixture":
    let st = freshDir("life")
    let env = fixtureEnv(st)
    let (sx, se, _) = cli(@["session-start", "--kind", "headless", "--name", "life1"], env)
    check sx == 0
    let s = se.data["session"]
    check s["id"].getStr == "life1" and s["state"].getStr == "running"
    check s["hostPid"].kind == JInt
    let hostPid = s["hostPid"].getInt
    let (lx, le, _) = cli(@["session-list"], env)
    check lx == 0
    let ids = le.data["sessions"].elems.mapIt(it["id"].getStr)
    check "host" in ids and "life1" in ids
    let (ix, ie, _) = cli(@["session-info", "life1"], env)
    check ix == 0 and ie.data["session"] == s
    # A verb in the session uses the session's own desktop.
    check cli(@["--session", "life1", "type", "Bo"], env).exit == 0
    let (vx, ve, _) = cli(@["--session", "life1", "element",
                            "/app[4242]/window[0]/text-field[0]"], env)
    check vx == 0 and ve.data["element"]["value"].getStr == "Bo"
    let (hx, he, _) = cli(@["element", "/app[4242]/window[0]/text-field[0]"], env)
    check hx == 0 and he.data["element"]["value"].getStr == ""
    # Stop: the record goes, the host process exits.
    let (tx, te, _) = cli(@["session-stop", "life1"], env)
    check tx == 0
    check te.data["session"]["state"].getStr == "stopped"
    check not fileExists(st / "sessions" / "life1.json")
    let (gx, ge, _) = cli(@["session-info", "life1"], env)
    check gx == 3 and ge.errorReason == "session"
    when defined(posix):
      sleep(200)
      check posix.kill(Pid(hostPid), 0) != 0
    # Stopping host is bad-args.
    let (hsx, hse, _) = cli(@["session-stop", "host"], env)
    check hsx == 2 and hse.errorKind == "bad-args"
    # A session whose host died is reported as error, never as running.
    let (dx, de, _) = cli(@["session-start", "--kind", "virtual-display", "--name", "dies"], env)
    check dx == 0
    let deadPid = de.data["session"]["hostPid"].getInt
    when defined(posix):
      check posix.kill(Pid(deadPid), SIGKILL) == 0
    else:
      discard execCmd("taskkill /F /PID " & $deadPid)
    sleep(300)
    let (ex, ee, _) = cli(@["session-info", "dies"], env)
    check ex == 0
    check ee.data["session"]["state"].getStr == "error"
    check ee.data["session"]["stateReason"].getStr == "host-exited"
    let (lx2, le2, _) = cli(@["session-list"], env)
    check lx2 == 0
    for x in le2.data["sessions"]:
      if x["id"].getStr == "dies": check x["state"].getStr == "error"
    let (ux, ue, _) = cli(@["--session", "dies", "displays"], env)
    check ux == 4 and ue.errorReason == "session-not-running"
    check cli(@["session-stop", "dies"], env).exit == 0

  test "test_invalid_name_is_bad_args_never_sanitized":
    let st = freshDir("names")
    let env = fixtureEnv(st)
    for bad in ["a/b", ".hidden", "x".repeat(65), "", "-dash", "sp ace", "dots/../up"]:
      let (x, e, _) = cli(@["session-start", "--kind", "headless", "--name", bad], env)
      check x == 2
      check e.errorReason == "invalid-name"
      check sessionRecords(st).len == 0
    for bad in ["a/b", ".hidden", "x".repeat(65)]:
      let (x, e, _) = cli(@["--session", bad, "displays"], env)
      check x == 2 and e.errorReason == "invalid-name"
      let (rx, re, _) = cli(@["record-stop", bad], env)
      check rx == 2 and re.errorReason == "invalid-name"
    check sessionRecords(st).len == 0
    # Control: the longest valid name is accepted as given.
    let good = "A" & "x".repeat(62) & "9"
    let (gx, ge, _) = cli(@["session-start", "--kind", "headless", "--name", good], env)
    check gx == 0
    check ge.data["session"]["id"].getStr == good
    check sessionRecords(st) == @[good & ".json"]
    check cli(@["session-stop", good], env).exit == 0

cleanupFreshDirs()
