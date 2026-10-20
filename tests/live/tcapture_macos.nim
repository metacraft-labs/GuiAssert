## The macOS live capture suite (GS5): the REAL `guiassert` binary with the
## `macos-sck` and `macos-cgwindow` capture backends against the real window
## server, the real signed helper bundle and a real AppKit fixture
## application (spec §9.3, §9.4).
##
## Run it with `just test-live-macos` (builds the CLI first), or
##
##   nim c -d:tccLive -r --hints:off tests/live/tcapture_macos.nim
##
## Stand-ins: none. The application under capture is
## `tests/live/fixtures/solid_window.swift`, compiled from source at test
## time: one borderless window of one solid sRGB colour at a requested
## place, so every pixel a capture returns is known in advance. That is a
## real AppKit window on the real window server, not a stand-in for one.
##
## **TCC.** Screen Recording is granted to the GuiAssert helper bundle
## (`~/Library/Application Support/GuiAssert/GuiAssertCapture.app`, bundle id
## `com.metacraft-labs.guiassert.capture`, signed with a certificate so the
## grant survives rebuilds), never to a terminal. The suite first runs the
## unprivileged positive control (window enumeration through
## `macos-cgwindow`), then asks the bundle for its grant. A test that needs
## the grant and runs without it FAILS with `BLOCKED: TCC Screen Recording
## for <bundle>` and the click-path; a test that needs an unlocked screen and
## runs on a locked one fails with `BLOCKED: the GUI session is locked`.
## Nothing here skips, so a missing grant can never pass as green.
##
## The denial tests build a second bundle under a bundle id that was never
## granted (`…capture.ungranted-test`) in a temporary directory: an identity
## without the grant, signed the same way. Its helper checks the grant with
## `CGPreflightScreenCaptureAccess` before touching ScreenCaptureKit, so the
## denial raises no system prompt.

when not defined(tccLive):
  {.error: "tests/live/tcapture_macos.nim is TCC-gated: compile it with -d:tccLive " &
           "(just test-live-macos)".}
when not defined(macosx):
  {.error: "tests/live/tcapture_macos.nim runs on macOS only".}

import std/[json, os, osproc, sequtils, strtabs, strutils, unittest, times]

import ../contract/harness
import ./macos_live
import ../../src/gui_assert/core/png

const
  grantedBundleId = "com.metacraft-labs.guiassert.capture"
  ungrantedBundleId = "com.metacraft-labs.guiassert.capture.ungranted-test"
  red = [220, 30, 40]
  blue = [30, 60, 220]
  tolerance = 12

var ungrantedDir = ""

proc ungrantedEnv(stateDir: string): StringTableRef =
  ## An environment whose capture bundle is an identity with no grant.
  if ungrantedDir.len == 0: ungrantedDir = freshDir("ungranted-app")
  result = liveEnv(stateDir, {"GUIASSERT_CAPTURE_APP_DIR": ungrantedDir,
                              "GUIASSERT_CAPTURE_BUNDLE_ID": ungrantedBundleId})
  result.del("GUIASSERT_CAPTURE_APP")

# ---------------------------------------------------------------------------
# Pixels
# ---------------------------------------------------------------------------

proc near(px: array[3, int], want: array[3, int]): bool =
  for i in 0 .. 2:
    if abs(px[i] - want[i]) > tolerance: return false
  true

proc pixelAt(img: PngImage, x, y: int): array[3, int] =
  let c = ord(img.channels)
  let o = (y * img.width + x) * c
  if c >= 3: [ord(img.pixels[o]), ord(img.pixels[o + 1]), ord(img.pixels[o + 2])]
  else: [ord(img.pixels[o]), ord(img.pixels[o]), ord(img.pixels[o])]

proc fractionNear(img: PngImage, want: array[3, int], x0, y0, x1, y1: int): float =
  ## The fraction of pixels in [x0, x1) x [y0, y1) within `tolerance` of
  ## `want`, sampled every 4th pixel.
  var n, hit = 0
  var y = y0
  while y < y1:
    var x = x0
    while x < x1:
      inc n
      if near(img.pixelAt(x, y), want): inc hit
      x += 4
    y += 4
  if n == 0: 0.0 else: hit / n

proc loadPng(path: string): PngImage = decodePng(readFile(path))

# ---------------------------------------------------------------------------
# Recordings
# ---------------------------------------------------------------------------

proc ffprobeFrames(path: string): tuple[frames, width, height: int, duration: float] =
  ## ffprobe's own decode of the video stream: decoded frame count, size and
  ## container duration.
  let (o, code) = execCmdEx("ffprobe -v error -count_frames -select_streams v:0 " &
    "-show_entries stream=nb_read_frames,width,height:format=duration -of json " &
    quoteShell(path))
  doAssert code == 0, "ffprobe failed: " & o
  let j = parseJson(o)
  let s = j["streams"][0]
  (parseInt(s["nb_read_frames"].getStr), s["width"].getInt, s["height"].getInt,
   parseFloat(j["format"]["duration"].getStr))

proc decodesCleanly(path: string): bool =
  let (o, code) = execCmdEx("ffmpeg -v error -i " & quoteShell(path) & " -f null -")
  code == 0 and o.strip.len == 0

proc firstFrame(path, png: string): PngImage =
  let (o, code) = execCmdEx("ffmpeg -v error -y -i " & quoteShell(path) &
    " -frames:v 1 " & quoteShell(png))
  doAssert code == 0, "ffmpeg could not extract a frame: " & o
  loadPng(png)

# ---------------------------------------------------------------------------
# The tests
# ---------------------------------------------------------------------------

suite "macOS live capture (GS5)":

  test "test_macos_windows_lists_fixture_app_window":
    let st = freshDir("windows")
    let env = liveEnv(st)
    let title = "GuiAssert Fixture " & nonce()
    var fx = launchFixture(title, [240, 220, 300, 200], red)
    try:
      # Positive control: unprivileged in-process enumeration.
      let cg = ok(@["--capture-backend", "macos-cgwindow", "windows", "--pid", $fx.pid], env)
      check cg["windows"].len == 1
      let w = cg["windows"][0]
      check w["id"].getStr == fx.window
      check w["pid"].getInt == fx.pid
      # The window server's bounds are the window's frame as AppKit has it
      # now, within the few points the window server keeps for itself
      # (measured on macOS 26.5: kCGWindowBounds is NSWindow.frame inset by
      # 3 points left and right and 2 top and bottom, for borderless and
      # titled windows alike), and near the requested frame.
      let cgBounds = w["bounds"].getElems.mapIt(it.getInt)
      check near(cgBounds, fx.currentBounds, 8)
      check near(fx.bounds, @[240, 220, 300, 200], 24)
      check w["document"].kind == JNull
      check w["layer"].getInt == 0 and w["onScreen"].getBool
      check w["display"].kind == JString
      # The default backend lists the same window, with its title when the
      # helper bundle holds the grant.
      let sck = ok(@["windows", "--pid", $fx.pid], env)
      check sck["windows"].len == 1
      check sck["windows"][0]["bounds"] == w["bounds"]
      check sck["windows"][0]["id"].getStr == fx.window
      let caps = ok(@["capabilities", "--probe"], env)
      if caps["permissions"]["screenRecording"].getStr == "granted":
        check sck["titlesVisible"].getBool
        check sck["windows"][0]["title"].getStr == title
        check ok(@["windows", "--title", title], env)["windows"].len == 1
        check ok(@["windows", "--title-contains", title[^12 .. ^1]], env)["windows"].len == 1
        # Case-sensitive (spec §7.5 matching rules).
        check ok(@["windows", "--title", title.toLowerAscii], env)["windows"].len == 0
      else:
        checkpoint "BLOCKED: TCC Screen Recording for " &
          caps["permissions"]["identity"].getStr & ": titles stay redacted. " & grantClickPath()
        check sck["titlesVisible"].getBool == false
        check sck["windows"][0]["title"].kind == JNull
        fail()
    finally:
      fx.stop()
    # Negative control: once the fixture is gone, so is its window.
    sleep(300)
    check ok(@["--capture-backend", "macos-cgwindow", "windows", "--pid", $fx.pid],
             env)["windows"].len == 0

  test "test_macos_screenshot_window_own_pixels_matches_fixture_color":
    gated:
      let st = freshDir("ownpx")
      let work = freshDir("ownpx-work")
      let env = liveEnv(st)
      var a = launchFixture("GuiAssert Fixture A " & nonce(), [200, 200, 320, 240], red)
      var b = launchFixture("GuiAssert Fixture B " & nonce(), [360, 280, 320, 240], blue,
                            floating = true)
      try:
        # The windows as the window server places them (what GuiAssert
        # reports and captures), near the frames the fixtures report.
        proc serverBounds(f: var Fixture): seq[int] =
          let ws = ok(@["windows", "--pid", $f.pid, "--all-layers"], env)["windows"]
          doAssert ws.len == 1, "fixture " & $f.pid & " has " & $ws.len & " windows"
          result = ws[0]["bounds"].getElems.mapIt(it.getInt)
          doAssert near(result, f.currentBounds, 8), $result & " vs " & $f.bounds
        let ab = serverBounds(a)
        let bb = serverBounds(b)
        # B overlaps A (both as the window server placed them), and A keeps a
        # part B does not cover; otherwise the test could not tell them apart.
        let ov = [max(ab[0], bb[0]), max(ab[1], bb[1]),
                  min(ab[0] + ab[2], bb[0] + bb[2]), min(ab[1] + ab[3], bb[1] + bb[3])]
        doAssert ov[2] - ov[0] >= 60 and ov[3] - ov[1] >= 60,
          "the fixture windows do not overlap: " & $ab & " " & $bb
        doAssert bb[0] - ab[0] >= 40 and bb[1] - ab[1] >= 40,
          "fixture A has no uncovered corner: " & $ab & " " & $bb
        let shot = work / "a.png"
        let img = ok(@["screenshot", "--window", a.window, "--own-pixels", "--out", shot],
                     env)["image"]
        check img["source"]["kind"].getStr == "window"
        check img["source"]["id"].getStr == a.window
        check img["origin"] == %[ab[0], ab[1]]
        let scale = img["scale"].getFloat
        check scale >= 1.0
        let p = loadPng(shot)
        check p.width == img["width"].getInt and p.height == img["height"].getInt
        check p.width == int(float(ab[2]) * scale) and p.height == int(float(ab[3]) * scale)
        # The whole window is red, including the part B covers on screen.
        check fractionNear(p, red, 0, 0, p.width, p.height) > 0.99
        let cx0 = int(float(ov[0] - ab[0] + 10) * scale)
        let cy0 = int(float(ov[1] - ab[1] + 10) * scale)
        let cx1 = int(float(ov[2] - ab[0] - 10) * scale)
        let cy1 = int(float(ov[3] - ab[1] - 10) * scale)
        check near(p.pixelAt(cx0, cy0), red)
        check fractionNear(p, red, cx0, cy0, cx1, cy1) > 0.99
        # Negative control: a region capture of the overlap shows B's colour.
        let reg = work / "r.png"
        let region = [ov[0] + 10, ov[1] + 10, ov[2] - ov[0] - 20, ov[3] - ov[1] - 20]
        let ri = ok(@["screenshot", "--region", region.mapIt($it).join(","), "--out", reg],
                    env)["image"]
        check ri["source"]["kind"].getStr == "region"
        check ri["origin"] == %[region[0], region[1]]
        let rp = loadPng(reg)
        check rp.width == int(float(region[2]) * scale)
        check fractionNear(rp, blue, 0, 0, rp.width, rp.height) > 0.95
        check fractionNear(rp, red, 0, 0, rp.width, rp.height) < 0.01
        # ... and so does a display capture, at the same place.
        let disp = work / "d.png"
        let di = ok(@["screenshot", "--out", disp, "--no-cursor"], env)["image"]
        check di["source"]["kind"].getStr == "display"
        let dp = loadPng(disp)
        let s = di["scale"].getFloat
        let o = di["origin"]
        proc at(x, y: int): array[3, int] =
          dp.pixelAt(int(float(x - o[0].getInt) * s), int(float(y - o[1].getInt) * s))
        check near(at((ov[0] + ov[2]) div 2, (ov[1] + ov[3]) div 2), blue)
        check near(at(ab[0] + 15, ab[1] + 15), red)     # A where nothing covers it
        # No temporary file is left next to the outputs.
        for k, f in walkDir(work):
          check ".partial" notin f
      finally:
        b.stop()
        a.stop()

  test "test_macos_record_start_stop_produces_decodable_mp4":
    gated:
      let st = freshDir("rec")
      let work = freshDir("rec-work")
      let env = liveEnv(st)
      var fx = launchFixture("GuiAssert Fixture R " & nonce(), [220, 240, 300, 200], red)
      try:
        let outp = work / "rec.mp4"
        let started = ok(@["record-start", "--window", fx.window, "--fps", "10",
                           "--out", outp], env)["recording"]
        check started["state"].getStr == "recording"
        check started["format"].getStr == "mp4"
        check started["durationMs"].kind == JNull and started["frames"].kind == JNull
        check started["source"]["kind"].getStr == "window"
        check not fileExists(outp)            # nothing at --out until finalized
        let listed = ok(@["recordings"], env)["recordings"]
        check listed.len == 1 and listed[0]["state"].getStr == "recording"
        sleep(1500)
        let r = ok(@["record-stop", started["id"].getStr], env)["recording"]
        check r["state"].getStr == "stopped"
        check r["stoppedAt"].kind == JString
        check fileExists(outp)
        let probe = ffprobeFrames(outp)
        check r["frames"].getInt == probe.frames
        check r["width"].getInt == probe.width and r["height"].getInt == probe.height
        check r["frames"].getInt >= 10       # at least ~1.5 s at 10 fps
        check abs(r["durationMs"].getInt - int(probe.duration * 1000)) <= 100
        check decodesCleanly(outp)
        let f0 = firstFrame(outp, work / "f0.png")
        check fractionNear(f0, red, 4, 4, f0.width - 4, f0.height - 4) > 0.95
        for k, f in walkDir(work):
          check ".partial" notin f
        check ok(@["recordings"], env)["recordings"][0]["state"].getStr == "stopped"
      finally:
        fx.stop()

  test "test_macos_capture_without_grant_is_exit_6":
    let st = freshDir("deny")
    let work = freshDir("deny-work")
    let env = ungrantedEnv(st)
    let (x, e, _) = run(@["screenshot", "--out", work / "d.png"], env)
    check x == 6
    check e["error"]["kind"].getStr == "permission-denied"
    check e["error"]["reason"].getStr == "tcc-screen-recording"
    check e["error"]["details"]["feature"].getStr == "display-capture"
    check e["error"]["details"]["backend"].getStr == "macos-sck"
    let remedy = e["error"]["remedy"].getStr
    check ungrantedBundleId in remedy
    check ungrantedDir in remedy
    check "Screen & System Audio Recording" in remedy
    check not fileExists(work / "d.png")
    check toSeq(walkDir(work)).len == 0     # never an empty success, nor a partial file
    let (rx, re, _) = run(@["record-start", "--out", work / "r.mp4"], env)
    check rx == 6
    check re["error"]["reason"].getStr == "tcc-screen-recording"
    check re["error"]["details"]["feature"].getStr == "recording"
    check toSeq(walkDir(work)).len == 0
    check ok(@["recordings"], env)["recordings"].len == 0
    let (wx, we, _) = run(@["screenshot", "--region", "0,0,50,50", "--out", work / "w.png"], env)
    check wx == 6 and we["error"]["details"]["feature"].getStr == "region-capture"
    let caps = ok(@["capabilities", "--probe"], env)
    check caps["permissions"]["screenRecording"].getStr == "denied"
    check ungrantedBundleId in caps["permissions"]["identity"].getStr
    for f in caps["features"]:
      if f["feature"].getStr in ["display-capture", "window-capture", "region-capture",
                                 "own-pixels-capture", "recording"]:
        check f["state"].getStr == "unavailable"
        check f["reason"].getStr == "tcc-screen-recording"
        check ungrantedBundleId in f["remedy"].getStr
    # Vacuity guard: the same capture from the granted identity succeeds, so
    # the refusal above is about the identity and nothing else.
    gated:
      let good = ok(@["screenshot", "--out", work / "g.png"], liveEnv(st))
      check good["image"]["width"].getInt > 0
      check fileExists(work / "g.png")

  test "test_live_recording_metadata_measured_and_killed_recorder_is_exit_5":
    gated:
      let st = freshDir("meta")
      let work = freshDir("meta-work")
      let env = liveEnv(st)
      var fx = launchFixture("GuiAssert Fixture M " & nonce(), [260, 260, 240, 160], blue)
      try:
        # A blocking record: metadata measured from the finalized file.
        let outp = work / "blocking.mp4"
        let r = ok(@["record", "--window", fx.window, "--duration-ms", "1500", "--fps", "10",
                     "--out", outp], env)["recording"]
        check r["state"].getStr == "stopped"
        let probe = ffprobeFrames(outp)
        check r["frames"].getInt == probe.frames
        check r["width"].getInt == probe.width and r["height"].getInt == probe.height
        check abs(r["durationMs"].getInt - int(probe.duration * 1000)) <= 100
        check r["durationMs"].getInt >= 1300 and r["durationMs"].getInt <= 2500
        # A recorder killed before it finalized: exit 5, state failed.
        let killedOut = work / "killed.mp4"
        let started = ok(@["record-start", "--region", "260,260,200,120", "--fps", "10",
                           "--out", killedOut], env)["recording"]
        let id = started["id"].getStr
        sleep(800)
        let rec = parseJson(readFile(st / "recordings" / (id & ".json")))
        let pid = rec["private"]["helperPid"].getInt
        check pid > 0
        check execCmdEx("kill -9 " & $pid).exitCode == 0
        sleep(300)
        let (x, e, _) = run(@["record-stop", id], env)
        check x == 5
        check e["error"]["reason"].getStr == "capture-failed"
        let failedRec = e["error"]["details"]["recording"]
        check failedRec["state"].getStr == "failed"
        check failedRec["frames"].kind == JNull and failedRec["durationMs"].kind == JNull
        check not fileExists(killedOut)
        for k, f in walkDir(work):
          check ".partial" notin f
        var states: seq[string]
        for x in ok(@["recordings"], env)["recordings"]:
          if x["id"].getStr == id: states.add x["state"].getStr
        check states == @["failed"]
        # A killed recorder nobody stopped is reconciled to failed by
        # `recordings`, never listed as recording or stopped.
        let s2 = ok(@["record-start", "--window", fx.window, "--out", work / "k2.mp4"],
                    env)["recording"]
        let rec2 = parseJson(readFile(st / "recordings" / (s2["id"].getStr & ".json")))
        check execCmdEx("kill -9 " & $rec2["private"]["helperPid"].getInt).exitCode == 0
        sleep(300)
        for x in ok(@["recordings"], env)["recordings"]:
          if x["id"].getStr == s2["id"].getStr: check x["state"].getStr == "failed"
        check not fileExists(work / "k2.mp4")
      finally:
        fx.stop()

  test "test_capture_backends_report_their_features_and_name_them_on_exit_4_6":
    let st = freshDir("feat")
    let work = freshDir("feat-work")
    let env = liveEnv(st)
    const captureFeatures = ["window-enumeration", "display-capture", "window-capture",
                             "region-capture", "own-pixels-capture", "recording"]
    proc byFeature(caps: JsonNode): JsonNode =
      result = newJObject()
      for f in caps["features"]:
        check not result.hasKey(f["feature"].getStr)   # each exactly once
        result[f["feature"].getStr] = f
    # Without --probe: present, not probed.
    let plain = byFeature(ok(@["capabilities"], env))
    for n in captureFeatures:
      check plain[n]["backend"].getStr == "macos-sck"
      check plain[n]["state"].getStr == "available"
    # macos-cgwindow: enumeration only, the captures named as not implemented.
    let cgCaps = ok(@["--capture-backend", "macos-cgwindow", "capabilities", "--probe"], env)
    check cgCaps["selected"]["capture"].getStr == "macos-cgwindow"
    let cg = byFeature(cgCaps)
    check cg["window-enumeration"]["state"].getStr in ["supported", "degraded"]
    if cg["window-enumeration"]["state"].getStr == "degraded":
      check cg["window-enumeration"]["reason"].getStr == "titles-redacted"
    for n in captureFeatures[1 .. ^1]:
      check cg[n]["state"].getStr == "unavailable"
      check cg[n]["reason"].getStr == "not-implemented"
    let (x4, e4, _) = run(@["--capture-backend", "macos-cgwindow", "screenshot", "--out",
                            work / "n.png"], env)
    check x4 == 4
    check e4["error"]["reason"].getStr == "not-implemented"
    check e4["error"]["details"]["feature"].getStr == "display-capture"
    check e4["error"]["details"]["backend"].getStr == "macos-cgwindow"
    let (r4, re4, _) = run(@["--capture-backend", "macos-cgwindow", "record-start", "--out",
                             work / "n.mp4"], env)
    check r4 == 4 and re4["error"]["details"]["feature"].getStr == "recording"
    let (w4, we4, _) = run(@["--capture-backend", "macos-cgwindow", "screenshot", "--window",
                             "1", "--own-pixels", "--out", work / "o.png"], env)
    check w4 == 4 and we4["error"]["details"]["feature"].getStr == "own-pixels-capture"
    # Exit 6 names its feature (the ungranted identity).
    # A window that exists (the unprivileged enumeration names it), so the
    # only reason left to refuse is the missing grant.
    let anyWin = ok(@["--capture-backend", "macos-cgwindow", "windows", "--all-layers"],
                    env)["windows"]
    doAssert anyWin.len > 0, "the window server lists no window at all"
    let (x6, e6, _) = run(@["screenshot", "--window", anyWin[0]["id"].getStr, "--out",
                            work / "u.png"], ungrantedEnv(freshDir("feat-deny")))
    check x6 == 6
    check e6["error"]["details"]["feature"].getStr == "window-capture"
    # With --probe and the grant: every capture feature supported.
    gated:
      let probed = ok(@["capabilities", "--probe"], env)
      check probed["permissions"]["screenRecording"].getStr == "granted"
      check grantedBundleId in probed["permissions"]["identity"].getStr
      let p = byFeature(probed)
      for n in captureFeatures:
        check p[n]["backend"].getStr == "macos-sck"
        check p[n]["state"].getStr == "supported"
        check p[n]["reason"].kind == JNull

  test "test_capture_backends_keep_captured_content_off_stderr":
    gated:
      let st = freshDir("c15")
      let work = freshDir("c15-work")
      let env = liveEnv(st)
      let secret = "SecretTitle" & nonce()
      var fx = launchFixture(secret, [300, 300, 200, 150], red)
      try:
        var stderrs, messages: seq[string]
        proc record(r: tuple[exit: int, env: JsonNode, stderr: string]) =
          stderrs.add r.stderr
          if r.env.hasKey("error"): messages.add $r.env["error"]
        let wl = run(@["windows"], env)
        record(wl)
        check secret in $wl.env["data"]          # the title IS reported, in data
        # C4: no window has a document on this backend.
        for w in wl.env["data"]["windows"]: check w["document"].kind == JNull
        record(run(@["windows", "--title", secret], env))
        record(run(@["screenshot", "--window", fx.window, "--out", work / "a.png"], env))
        let started = run(@["record-start", "--window", fx.window, "--out", work / "r.mp4"], env)
        record(started)
        sleep(600)
        record(run(@["record-stop", started.env["data"]["recording"]["id"].getStr], env))
        record(run(@["screenshot", "--window", fx.window, "--out", work / "u.png"],
                   ungrantedEnv(freshDir("c15-deny"))))
        record(run(@["screenshot", "--window", "999999999", "--out", work / "x.png"], env))
        for s in stderrs: check secret notin s
        for m in messages: check secret notin m
        # Nor in any state record or helper file the backend keeps.
        for f in walkDirRec(st):
          check secret notin readFile(f)
      finally:
        fx.stop()

cleanupFreshDirs()
