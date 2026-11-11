## The Linux live capture suite (GS5): the REAL `guiassert` binary with the
## `linux-x11`, `linux-wlr`, `linux-portal-pipewire` and `linux-gnome`
## capture backends against real display servers that the suite starts for
## itself (spec §4.2, §9.3):
##
## * a private **Xvfb** (no TCP listener) for `linux-x11`;
## * a private **headless sway** (`desktop_env/sway`) for `linux-wlr`, and on
##   it the **portal stack** (PipeWire, WirePlumber, xdg-desktop-portal with
##   its wlroots backend, configured to stream the headless output without a
##   chooser) for `linux-portal-pipewire`;
## * a private **headless GNOME Shell** (`desktop_env/gnome`) for
##   `linux-gnome`.
##
## None of them is connected to the operator's display: each has its own
## runtime directory and session bus, and every `guiassert` run gets only
## that session's variables (`linux_live.runEnv`).
##
## Run it with `just test-live-linux` (inside `nix develop`; builds the CLI
## first), or `nim c -r --hints:off tests/live/tcapture_linux.nim`.
##
## Stand-ins: none. The windows captured are real clients of the real
## servers, drawn by GuiAssert's own helpers so that every pixel is known in
## advance: `wm_probe` (a Wayland xdg-toplevel of one solid colour, 320x200;
## with `pulse` its blue channel alternates by one step every 100 ms so a
## screen cast that sends frames only on damage has frames to send) and
## `x11_probe window` (an X11 window of one solid colour at a requested
## geometry). Recordings are measured by the real ffprobe. One fault is
## injected: `slow_x264.c`, preloaded into the linux-wlr recorder's encoder,
## delays one libx264 encode call (an encoder latency spike, the cause of an
## earlier flake), because no real encoder stalls on demand; the encoder
## still encodes every frame.
##
## Negative controls: pixels outside the fixture window are the background,
## not its colour; a moved window's crop follows the compositor's new
## rectangle and the old place shows the background; a window that is gone
## is no longer listed and no longer drawn; a recorder killed before it
## finalizes yields exit 5, never a stopped recording.
##
## A server that cannot start fails every test that needs it with a
## `GS5-LINUX BLOCKED:` line; nothing here skips.

when not defined(linux):
  {.error: "tests/live/tcapture_linux.nim runs on Linux only".}

import std/[json, os, osproc, posix, strtabs, strutils, unittest, times]

import ../contract/harness
import ./linux_live
import ../../src/gui_assert/core/png

const
  colour = [0x33, 0x66, 0x99]   ## the fixture windows' colour, "336699"
  black = [0, 0, 0]

template live(problem: string, body: untyped) =
  ## Run `body` when the suite's server started; otherwise FAIL with the
  ## BLOCKED line (never skip).
  if problem.len > 0:
    checkpoint problem
    echo "  ", problem
    fail()
  else:
    body

proc windowOf(env: StringTableRef, backend: string, pid: int): JsonNode =
  let ws = ok(@["--capture-backend", backend, "windows", "--pid", $pid], env)["windows"]
  doAssert ws.len == 1, backend & " lists " & $ws.len & " windows of pid " & $pid & ": " & $ws
  ws[0]

proc rectJson(r: desktop_env.Rect): JsonNode = %*[r.x, r.y, r.w, r.h]

template failure(args: seq[string], env: StringTableRef, code: int, reason: string): JsonNode =
  ## The error of an invocation that must fail with `code` / `reason`.
  ## (Templates, not procs, so that `check` counts against the test.)
  block:
    let (x, e, err) = run(args, env)
    if x != code: checkpoint "guiassert " & args.join(" ") & " -> " & $e & "\n" & err
    check x == code
    check e["ok"].getBool == false
    check e["error"]["reason"].getStr == reason
    e["error"]

template checkRecorder(env: StringTableRef, st, work, backend: string,
                     target: seq[string], stderrs: untyped) =
  ## C12 for one recorder: record-stop reports frames, duration and size
  ## equal to ffprobe's count of the finalized file; a recorder killed before
  ## finalizing is exit 5 / capture-failed with details.recording failed.
  let outPath = work / (backend & "-measured.mp4")
  let started = ok(@["--capture-backend", backend, "record-start", "--out", outPath,
                     "--fps", "10"] & target, env)["recording"]
  check started["state"].getStr == "recording"
  check not fileExists(outPath)                  # temp-and-rename: nothing at --out yet
  sleep(2000)
  let (sx, se, serr) = run(@["--capture-backend", backend, "record-stop",
                             started["id"].getStr], env)
  stderrs.add serr
  if sx != 0: checkpoint $se
  check sx == 0
  let r = se["data"]["recording"]
  check r["state"].getStr == "stopped"
  check fileExists(outPath)
  check partialSiblings(outPath).len == 0
  let probe = ffprobeVideo(outPath)
  checkpoint "reported " & $r & "; ffprobe " & $probe
  check r["frames"].getInt == probe.frames
  check r["width"].getInt == probe.width
  check r["height"].getInt == probe.height
  check abs(r["durationMs"].getInt - probe.durationMs) <= 1
  check probe.frames >= 5                         # it really recorded
  # The blocking `record` measures the same way.
  let blockingOut = work / (backend & "-blocking.mp4")
  let b = ok(@["--capture-backend", backend, "record", "--out", blockingOut,
               "--duration-ms", "1500", "--fps", "10"] & target, env)["recording"]
  let bp = ffprobeVideo(blockingOut)
  check b["state"].getStr == "stopped"
  check b["frames"].getInt == bp.frames and b["width"].getInt == bp.width
  check abs(b["durationMs"].getInt - bp.durationMs) <= 1
  # Killed before finalizing: exit 5, details.recording failed, no file.
  let killedOut = work / (backend & "-killed.mp4")
  let k = ok(@["--capture-backend", backend, "record-start", "--out", killedOut,
               "--fps", "10"] & target, env)["recording"]
  sleep(1500)
  let pid = recorderPid(st, k["id"].getStr)
  check kill(Pid(pid), SIGKILL) == 0
  let deadline = epochTime() + 5
  while kill(Pid(pid), 0) == 0 and epochTime() < deadline: sleep(20)
  let (kx, ke, kerr) = run(@["--capture-backend", backend, "record-stop", k["id"].getStr], env)
  stderrs.add kerr
  check kx == 5
  check ke["error"]["kind"].getStr == "backend-error"
  check ke["error"]["reason"].getStr == "capture-failed"
  check ke["error"]["details"]["recording"]["state"].getStr == "failed"
  check ke["error"]["details"]["recording"]["frames"].kind == JNull
  check not fileExists(killedOut)
  check partialSiblings(killedOut).len == 0
  var listed = false
  for x in ok(@["--capture-backend", backend, "recordings"], env)["recordings"]:
    if x["id"].getStr == k["id"].getStr:
      listed = true
      check x["state"].getStr == "failed"
  check listed

proc featureMap(env: StringTableRef, backend: string): JsonNode =
  ## The capture features `capabilities --probe` reports with `backend`.
  result = newJObject()
  for f in ok(@["--capture-backend", backend, "capabilities", "--probe"], env)["features"]:
    if f["backend"].getStr == backend: result[f["feature"].getStr] = f

template checkState(fs: JsonNode, feature, state: string, reason = "") =
  checkpoint feature & ": " & $fs{feature}
  check fs{feature}{"state"}.getStr == state
  if reason.len > 0: check fs{feature}{"reason"}.getStr == reason
  else: check fs{feature}{"reason"} == newJNull()

# ---------------------------------------------------------------------------
# linux-x11
# ---------------------------------------------------------------------------

suite "linux-x11 in a private Xvfb":
  var xvfb: Xvfb
  var problem = ""
  try: xvfb = startXvfb(640, 480)
  except AssertionDefect as e: problem = e.msg
  let st = freshDir("x11-state")
  let work = freshDir("x11-work")
  let title = nonce()
  var stderrs: seq[string]
  var fixture: tuple[process: Process, id: string]
  if problem.len == 0:
    try: fixture = xvfb.x11Window("200x120+100+80", "336699", title)
    except AssertionDefect as e: problem = e.msg
  let env = if problem.len == 0: runEnv(st, xvfb.env) else: nil

  test "test_linux_x11_screenshot_in_xvfb":
    live problem:
      # The capture default follows the session: X11 without Wayland.
      check ok(@["capabilities"], env)["selected"]["capture"].getStr == "linux-x11"
      let ds = ok(@["displays"], env)["displays"]
      check ds.len == 1
      check ds[0]["bounds"] == %*[0, 0, 640, 480]
      check ds[0]["primary"].getBool and ds[0]["scale"].getFloat == 1.0
      let w = windowOf(env, "linux-x11", fixture.process.processID)
      check w["id"].getStr == fixture.id
      check w["bounds"] == %*[100, 80, 200, 120]
      check w["title"].getStr == title
      check w["app"].getStr == "gui-assert-x11-probe"
      check w["document"].kind == JNull and w["onScreen"].getBool
      # The display: the expected size, the window's pixels where the
      # server put it, the background elsewhere.
      let shot = work / "display.png"
      let (sx, se, serr) = run(@["screenshot", "--out", shot], env)
      stderrs.add serr
      check sx == 0
      let img = se["data"]["image"]
      check img["width"].getInt == 640 and img["height"].getInt == 480
      check img["origin"] == %*[0, 0] and img["source"]["kind"].getStr == "display"
      check partialSiblings(shot).len == 0
      let png = loadPng(shot)
      check png.width == 640 and png.height == 480
      check fractionNear(png, colour, 100, 80, 300, 200) > 0.99
      check fractionNear(png, black, 0, 0, 100, 80) > 0.99           # negative control
      check fractionNear(png, colour, 300, 200, 640, 480) == 0.0
      # The window: a crop of the screen at the window's rectangle.
      let crop = ok(@["screenshot", "--window", fixture.id, "--out", work / "window.png"],
                    env)["image"]
      check crop["source"]["kind"].getStr == "window-crop"
      check crop["source"]["id"].getStr == fixture.id
      check crop["origin"] == %*[100, 80]
      check crop["width"].getInt == 200 and crop["height"].getInt == 120
      check fractionNear(loadPng(work / "window.png"), colour, 0, 0, 200, 120) > 0.99
      # A region straddling the window's left edge.
      let reg = ok(@["screenshot", "--region", "80,90,40,20", "--out", work / "region.png"],
                   env)["image"]
      check reg["origin"] == %*[80, 90] and reg["width"].getInt == 40
      let rp = loadPng(work / "region.png")
      check fractionNear(rp, black, 0, 0, 20, 20) > 0.99
      check fractionNear(rp, colour, 20, 0, 40, 20) > 0.99
      # A region off the screen is refused before anything is captured.
      discard failure(@["screenshot", "--region", "600,400,100,100", "--out",
                        work / "off.png"], env, 2, "invalid-value")
      check not fileExists(work / "off.png")
      # Negative control: once the window is gone it is neither listed nor drawn.
      stopProcess(fixture.process)
      sleep(300)
      check ok(@["windows", "--pid", $fixture.process.processID], env)["windows"].len == 0
      discard ok(@["screenshot", "--out", work / "after.png"], env)
      check fractionNear(loadPng(work / "after.png"), black, 100, 80, 300, 200) > 0.99
      fixture = xvfb.x11Window("200x120+100+80", "336699", title)

  test "test_live_recording_metadata_measured_and_killed_recorder_is_exit_5 [linux-x11]":
    live problem:
      checkRecorder(env, st, work, "linux-x11", @["--region", "100,80,200,120"], stderrs)

  test "test_capture_backends_report_their_features_and_name_them_on_exit_4_6 [linux-x11]":
    live problem:
      let fs = featureMap(env, "linux-x11")
      fs.checkState("window-enumeration", "supported")
      fs.checkState("display-capture", "supported")
      fs.checkState("region-capture", "supported")
      fs.checkState("window-capture", "degraded", "window-crop")
      fs.checkState("own-pixels-capture", "unavailable", "unsupported-option")
      fs.checkState("recording", "available")
      let e = failure(@["screenshot", "--window", fixture.id, "--own-pixels", "--out",
                        work / "own.png"], env, 4, "unsupported-option")
      check e["details"]["feature"].getStr == "own-pixels-capture"
      check e["details"]["backend"].getStr == "linux-x11"
      check not fileExists(work / "own.png")
      # No X display: the backend names what is missing (exit 4, feature).
      let noDisplay = runEnv(st, newStringTable(modeCaseSensitive))
      let e2 = failure(@["--capture-backend", "linux-x11", "windows"], noDisplay, 4,
                       "display-server-unsupported")
      check e2["details"]["feature"].getStr == "window-enumeration"
      # Linux has no capture permission: never exit 6.
      check ok(@["--capture-backend", "linux-x11", "capabilities"], env)["permissions"][
        "screenRecording"].getStr == "not-applicable"

  test "test_capture_backends_keep_captured_content_off_stderr [linux-x11]":
    live problem:
      let (wx, we, werr) = run(@["windows"], env)
      check wx == 0 and title in $we["data"]        # the title is data …
      stderrs.add werr
      let (_, me, merr) = run(@["screenshot", "--window", "424242", "--out",
                                work / "missing.png"], env)
      stderrs.add merr
      check title notin $me
      for s in stderrs: check title notin s       # … and never on stderr,
      check title notin stateFilesText(st)        # … nor in a state record
      for w in ok(@["windows", "--all-layers", "--include-offscreen"], env)["windows"]:
        check w["document"].kind == JNull          # C4

  stopProcess(fixture.process)
  xvfb.stop()

# ---------------------------------------------------------------------------
# linux-wlr and linux-portal-pipewire
# ---------------------------------------------------------------------------

suite "linux-wlr and linux-portal-pipewire in a private sway":
  let t = newSwayTarget(800, 600)
  var problem = ""
  try: t.startTarget()
  except AssertionDefect as e: problem = e.msg
  let st = freshDir("wlr-state")
  let work = freshDir("wlr-work")
  let title = nonce()
  var stderrs: seq[string]
  var probe: Process
  var shown: EnvWindow
  if problem.len == 0:
    try:
      probe = t.probeWindow("336699", title, pulse = true)
      shown = t.waitPidWindow(probe.processID)
      sleep(500)                                  # its first frame is presented
    except CatchableError, AssertionDefect:
      problem = "GS5-LINUX BLOCKED: wm_probe's window did not appear: " &
        getCurrentExceptionMsg()
  let env = if problem.len == 0: runEnv(st, t.sessionEnv) else: nil

  test "test_linux_wlr_screenshot_matches_wm_probe_window":
    live problem:
      check ok(@["capabilities"], env)["selected"]["capture"].getStr == "linux-wlr"
      let ds = ok(@["displays"], env)["displays"]
      check ds.len == 1 and ds[0]["id"].getStr == "HEADLESS-1"
      check ds[0]["bounds"] == %*[0, 0, 800, 600] and ds[0]["virtual"].getBool
      let w = windowOf(env, "linux-wlr", probe.processID)
      check w["bounds"] == rectJson(shown.rect)    # the compositor-reported rect
      check w["title"].getStr == title
      check w["appId"].getStr == "gui-assert-wm-probe" and w["document"].kind == JNull
      let r = shown.rect
      let shot = work / "display.png"
      let img = ok(@["screenshot", "--out", shot], env)["image"]
      check img["width"].getInt == 800 and img["source"]["id"].getStr == "HEADLESS-1"
      let png = loadPng(shot)
      check fractionNear(png, colour, r.x, r.y, r.x + r.w, r.y + r.h) > 0.99
      check fractionNear(png, colour, 0, 0, r.x, r.y) == 0.0          # negative control
      # Window capture: a crop at the compositor's rectangle, reported as such.
      let crop = ok(@["screenshot", "--window", w["id"].getStr, "--out",
                      work / "window.png"], env)["image"]
      check crop["source"]["kind"].getStr == "window-crop"
      check crop["origin"] == %*[r.x, r.y]
      check crop["width"].getInt == r.w and crop["height"].getInt == r.h
      check fractionNear(loadPng(work / "window.png"), colour, 0, 0, r.w, r.h) > 0.99
      # Negative control: moved by the compositor, the crop follows it and
      # the old place shows the background.
      t.placeWindow(shown, 40, 50)
      t.waitUntil("the window moved", proc(): bool =
        t.waitPidWindow(probe.processID).rect.x == 40)
      sleep(300)
      let moved = t.waitPidWindow(probe.processID).rect
      let w2 = windowOf(env, "linux-wlr", probe.processID)
      check w2["bounds"] == rectJson(moved)
      let crop2 = ok(@["screenshot", "--window", w["id"].getStr, "--out",
                       work / "moved.png"], env)["image"]
      check crop2["origin"] == %*[moved.x, moved.y]
      check fractionNear(loadPng(work / "moved.png"), colour, 0, 0, moved.w, moved.h) > 0.99
      discard ok(@["screenshot", "--out", work / "after-move.png"], env)
      let after = loadPng(work / "after-move.png")
      check fractionNear(after, colour, moved.x + moved.w + 1, r.y,
                         r.x + r.w, r.y + r.h) == 0.0
      check fractionNear(after, colour, moved.x, moved.y, moved.x + moved.w,
                         moved.y + moved.h) > 0.99
      shown = t.waitPidWindow(probe.processID)

  test "test_live_recording_metadata_measured_and_killed_recorder_is_exit_5 [linux-wlr]":
    live problem:
      checkRecorder(env, st, work, "linux-wlr", @[], stderrs)

  test "test_linux_wlr_recording_keeps_every_frame_through_an_encoder_stall":
    # The cause of the linux-wlr flake (GS5 Outstanding Tasks): an encoder
    # busy on one frame for longer than the rest of the recording. Here the
    # stall is injected, longer than the recording itself: the second libx264
    # encode call waits 2.5 s. A recorder that drops what it captured while
    # the encoder was busy (wf-recorder kept the first frame only) fails;
    # the stall may delay the stop, never shorten the file.
    live problem:
      let shim = slowX264Shim(work)
      let mark = work / "stall-served"
      let stalled = runEnv(st, t.sessionEnv, [("LD_PRELOAD", shim),
        ("SLOW_X264_AT", "2"), ("SLOW_X264_MS", "2500"), ("SLOW_X264_MARK", mark)])
      let outPath = work / "wlr-stalled.mp4"
      let (x, e, err) = run(@["--capture-backend", "linux-wlr", "record", "--out", outPath,
                              "--duration-ms", "1500", "--fps", "10"], stalled)
      stderrs.add err
      if x != 0: checkpoint $e & "\n" & err
      check x == 0
      check fileExists(mark)                       # the stall reached the encoder
      if x == 0:
        let r = e["data"]["recording"]
        let p = ffprobeVideo(outPath)
        checkpoint "reported " & $r & "; ffprobe " & $p
        check r["state"].getStr == "stopped"
        check r["frames"].getInt == p.frames
        # 1.5 s at 10 fps: 15 frames after the first, which is copied at 0.
        check p.frames >= 15
        check p.durationMs >= 1500

  test "test_capture_backends_report_their_features_and_name_them_on_exit_4_6 [linux-wlr]":
    live problem:
      let fs = featureMap(env, "linux-wlr")
      fs.checkState("window-enumeration", "supported")
      fs.checkState("display-capture", "supported")
      fs.checkState("region-capture", "supported")
      fs.checkState("window-capture", "degraded", "window-crop")
      fs.checkState("own-pixels-capture", "unavailable", "unsupported-option")
      fs.checkState("recording", "available")
      let id = windowOf(env, "linux-wlr", probe.processID)["id"].getStr
      let e = failure(@["screenshot", "--window", id, "--own-pixels", "--out",
                        work / "own.png"], env, 4, "unsupported-option")
      check e["details"]["feature"].getStr == "own-pixels-capture"
      check e["details"]["backend"].getStr == "linux-wlr"
      check not fileExists(work / "own.png")
      check ok(@["capabilities"], env)["permissions"]["screenRecording"].getStr ==
        "not-applicable"

  var portal: PortalStack
  var portalProblem = problem
  if problem.len == 0:
    try: portal = t.startPortalStack()
    except AssertionDefect as e: portalProblem = e.msg

  test "test_linux_portal_pipewire_record_decodes":
    live portalProblem:
      let outPath = work / "portal.mp4"
      let (x, e, err) = run(@["--capture-backend", "linux-portal-pipewire", "record",
                              "--out", outPath, "--duration-ms", "2000", "--fps", "10"], env)
      stderrs.add err
      if x != 0: checkpoint $e & "\n" & err & "\nlogs in " & portal.logs
      check x == 0
      let r = e["data"]["recording"]
      check r["state"].getStr == "stopped"
      let p = ffprobeVideo(outPath)
      checkpoint "reported " & $r & "; ffprobe " & $p
      check r["frames"].getInt == p.frames
      check r["width"].getInt == p.width and r["height"].getInt == p.height
      check p.width == 800 and p.height == 600
      check p.frames >= 10
      check abs(r["durationMs"].getInt - p.durationMs) <= 1
      check partialSiblings(outPath).len == 0
      # A still through the same portal: the monitor, its origin, the window.
      let shot = work / "portal.png"
      let img = ok(@["--capture-backend", "linux-portal-pipewire", "screenshot",
                     "--out", shot], env)["image"]
      check img["origin"] == %*[0, 0] and img["width"].getInt == 800
      check img["scale"].getFloat == 1.0
      let s = shown.rect
      check fractionNear(loadPng(shot), colour, s.x, s.y, s.x + s.w, s.y + s.h) > 0.99
      check fractionNear(loadPng(shot), colour, 0, 0, s.x, s.y) == 0.0

  test "test_live_recording_metadata_measured_and_killed_recorder_is_exit_5 [linux-portal-pipewire]":
    live portalProblem:
      checkRecorder(env, st, work, "linux-portal-pipewire", @[], stderrs)

  test "test_capture_backends_report_their_features_and_name_them_on_exit_4_6 [linux-portal-pipewire]":
    live portalProblem:
      let fs = featureMap(env, "linux-portal-pipewire")
      fs.checkState("display-capture", "supported")
      fs.checkState("recording", "available")
      fs.checkState("window-enumeration", "unavailable", "display-server-unsupported")
      fs.checkState("window-capture", "unavailable", "display-server-unsupported")
      fs.checkState("own-pixels-capture", "unavailable", "display-server-unsupported")
      fs.checkState("region-capture", "unavailable", "not-implemented")
      let e = failure(@["--capture-backend", "linux-portal-pipewire", "windows"], env, 4,
                      "display-server-unsupported")
      check e["details"]["feature"].getStr == "window-enumeration"
      let e2 = failure(@["--capture-backend", "linux-portal-pipewire", "screenshot",
                         "--region", "0,0,10,10", "--out", work / "r.png"], env, 4,
                       "not-implemented")
      check e2["details"]["feature"].getStr == "region-capture"
      let e3 = failure(@["--capture-backend", "linux-portal-pipewire", "screenshot",
                         "--display", "HEADLESS-1", "--out", work / "d.png"], env, 4,
                       "unsupported-option")
      check e3["details"]["feature"].getStr == "display-capture"
      check not fileExists(work / "r.png") and not fileExists(work / "d.png")

  test "test_capture_backends_keep_captured_content_off_stderr [linux-wlr, linux-portal-pipewire]":
    live problem:
      let (wx, we, werr) = run(@["windows"], env)
      check wx == 0 and title in $we["data"]
      stderrs.add werr
      for s in stderrs: check title notin s
      check title notin stateFilesText(st)
      for w in ok(@["windows", "--all-layers", "--include-offscreen"], env)["windows"]:
        check w["document"].kind == JNull

  portal.stop()
  stopProcess(probe)
  t.stop()

# ---------------------------------------------------------------------------
# linux-gnome
# ---------------------------------------------------------------------------

suite "linux-gnome in a private headless GNOME Shell":
  let t = newGnomeTarget(1024, 768)
  var problem = ""
  try: t.startTarget()
  except AssertionDefect as e: problem = e.msg
  let st = freshDir("gnome-state")
  let work = freshDir("gnome-work")
  let title = nonce()
  var stderrs: seq[string]
  var probe: Process
  var shown: EnvWindow
  if problem.len == 0:
    try:
      probe = t.probeWindow("336699", title)
      shown = t.waitPidWindow(probe.processID)
      sleep(800)
    except CatchableError, AssertionDefect:
      problem = "GS5-LINUX BLOCKED: wm_probe's window did not appear: " &
        getCurrentExceptionMsg()
  let env = if problem.len == 0: runEnv(st, t.sessionEnv) else: nil

  test "test_linux_gnome_screenshot_in_private_gnome_shell":
    live problem:
      check ok(@["capabilities"], env)["selected"]["capture"].getStr == "linux-gnome"
      let ds = ok(@["displays"], env)["displays"]
      check ds.len == 1 and ds[0]["bounds"] == %*[0, 0, 1024, 768]
      check ds[0]["primary"].getBool
      let w = windowOf(env, "linux-gnome", probe.processID)
      check w["bounds"] == rectJson(shown.rect)    # the Shell-reported rect
      check w["title"].getStr == title
      check w["appId"].getStr == "gui-assert-wm-probe" and w["document"].kind == JNull
      let r = shown.rect
      let shot = work / "display.png"
      let (sx, se, serr) = run(@["screenshot", "--out", shot], env)
      stderrs.add serr
      check sx == 0
      check se["data"]["image"]["width"].getInt == 1024
      check partialSiblings(shot).len == 0
      let png = loadPng(shot)
      check fractionNear(png, colour, r.x, r.y, r.x + r.w, r.y + r.h) > 0.99
      check fractionNear(png, colour, 0, 0, max(r.x, 1), max(r.y, 1)) == 0.0
      let crop = ok(@["screenshot", "--window", w["id"].getStr, "--out",
                      work / "window.png"], env)["image"]
      check crop["source"]["kind"].getStr == "window-crop"
      check crop["origin"] == %*[r.x, r.y]
      check crop["width"].getInt == r.w and crop["height"].getInt == r.h
      check fractionNear(loadPng(work / "window.png"), colour, 0, 0, r.w, r.h) > 0.99
      # Negative control: moved by the Shell, the crop follows it.
      t.placeWindow(shown, 30, 60)
      t.waitUntil("the window moved", proc(): bool =
        t.waitPidWindow(probe.processID).rect.x == 30)
      sleep(300)
      let moved = t.waitPidWindow(probe.processID).rect
      let crop2 = ok(@["screenshot", "--window", w["id"].getStr, "--out",
                       work / "moved.png"], env)["image"]
      check crop2["origin"] == %*[moved.x, moved.y]
      check fractionNear(loadPng(work / "moved.png"), colour, 0, 0, moved.w, moved.h) > 0.99

  test "test_capture_backends_report_their_features_and_name_them_on_exit_4_6 [linux-gnome]":
    live problem:
      let fs = featureMap(env, "linux-gnome")
      fs.checkState("window-enumeration", "supported")
      fs.checkState("display-capture", "supported")
      fs.checkState("region-capture", "supported")
      fs.checkState("window-capture", "degraded", "window-crop")
      fs.checkState("own-pixels-capture", "unavailable", "unsupported-option")
      fs.checkState("recording", "unavailable", "not-implemented")
      let e = failure(@["record-start", "--out", work / "g.mp4"], env, 4, "not-implemented")
      check e["details"]["feature"].getStr == "recording"
      let id = windowOf(env, "linux-gnome", probe.processID)["id"].getStr
      let e2 = failure(@["screenshot", "--window", id, "--own-pixels", "--out",
                         work / "own.png"], env, 4, "unsupported-option")
      check e2["details"]["feature"].getStr == "own-pixels-capture"
      check not fileExists(work / "own.png") and not fileExists(work / "g.mp4")

  test "test_capture_backends_keep_captured_content_off_stderr [linux-gnome]":
    live problem:
      let (wx, we, werr) = run(@["windows"], env)
      check wx == 0 and title in $we["data"]
      stderrs.add werr
      for s in stderrs: check title notin s
      check title notin stateFilesText(st)
      for w in ok(@["windows", "--all-layers", "--include-offscreen"], env)["windows"]:
        check w["document"].kind == JNull

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
