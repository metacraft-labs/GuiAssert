## tlinux_capture — the parts of the Linux capture backends (`linux-wlr`,
## `linux-gnome`, `linux-x11`, `linux-portal-pipewire`) that need no display
## server, so they run in the default suite (spec §9.1):
##
## * reading what a display server answers into contract objects: sway's
##   `get_outputs` and `get_tree` replies, `x11_probe list`, GNOME Shell's
##   monitor and window lists (order, content rectangles, titles, focus,
##   layers, what is off screen);
## * the `windows` filters, the one-display rule for regions, display
##   selection, PPM decoding, helper status files and the portal helper's
##   exit statuses;
## * the capture default that follows the caller's session;
## * finalizing a recording (C12) on real MP4 files that ffmpeg encodes here;
## * on Linux, the process machinery recorders depend on: running a tool
##   with the invocation's environment (and only it), its deadline and
##   cancellation, a detached process that outlives its starter and is
##   identified by its start time, never by a pid alone;
## * the backends' features when no session is reachable, and every backend
##   off Linux: `wrong-platform`.
##
## Stand-ins: the display-server answers are literal JSON in the shapes the
## real servers emit (each shape was taken from a real reply: sway 1.11,
## GNOME Shell 49, the x11_probe helper on Xvfb), because the code under
## test is the pure reading of such a reply; the live suite
## (`tests/live/tcapture_linux.nim`) runs the same code on real replies.
## Nothing else is stood in for: MP4 files are encoded by the real ffmpeg
## and measured by the real `core/mp4`, and processes are real processes.

import std/[json, options, os, osproc, posix, sequtils, strutils, tables, unittest]

import ../src/gui_assert/core/[geometry, desktop_types, interfaces, contract]
import ../src/gui_assert/cancel
import ../src/gui_assert/cli/registry
import ../src/gui_assert/backends/capture/[linux_common, linux_wlr, linux_gnome, linux_x11,
                                           linux_portal_pipewire]

const swayOutputs = """[
  {"name": "HEADLESS-1", "make": "Unknown", "model": "Unknown", "active": true,
   "rect": {"x": 0, "y": 0, "width": 800, "height": 600}, "scale": 1.0},
  {"name": "DP-2", "make": "Example", "model": "Panel 27", "active": true,
   "rect": {"x": 800, "y": 0, "width": 1280, "height": 720}, "scale": 2.0},
  {"name": "DP-3", "make": "Example", "model": "Off", "active": false,
   "rect": {"x": 0, "y": 0, "width": 0, "height": 0}, "scale": 1.0}]"""

const swayTree = """{"id": 1, "type": "root", "nodes": [
  {"id": 2, "type": "output", "name": "__i3", "nodes": [
    {"id": 3, "type": "workspace", "name": "__i3_scratch", "nodes": [], "floating_nodes": [
      {"id": 30, "type": "floating_con", "name": "Hidden notes", "app_id": "dev.example.notes",
       "pid": 300, "visible": false, "focused": false,
       "rect": {"x": 10, "y": 10, "width": 100, "height": 100},
       "window_rect": {"x": 0, "y": 0, "width": 100, "height": 100}}]}]},
  {"id": 4, "type": "output", "name": "HEADLESS-1", "nodes": [
    {"id": 5, "type": "workspace", "name": "1", "nodes": [
      {"id": 10, "type": "con", "name": "Editor", "app_id": "dev.example.editor", "pid": 100,
       "visible": true, "focused": false,
       "rect": {"x": 0, "y": 0, "width": 400, "height": 600},
       "window_rect": {"x": 2, "y": 24, "width": 396, "height": 574}},
      {"id": 11, "type": "con", "name": null, "app_id": null, "pid": 101,
       "window_properties": {"class": "XTerm", "instance": "xterm"},
       "visible": true, "focused": true,
       "rect": {"x": 400, "y": 0, "width": 400, "height": 600},
       "window_rect": {"x": 0, "y": 0, "width": 400, "height": 600}}],
     "floating_nodes": [
      {"id": 20, "type": "floating_con", "name": "Below", "app_id": "dev.example.a", "pid": 200,
       "visible": true, "focused": false,
       "rect": {"x": 100, "y": 100, "width": 200, "height": 100},
       "window_rect": {"x": 0, "y": 0, "width": 200, "height": 100}},
      {"id": 21, "type": "floating_con", "name": "Above", "app_id": "dev.example.b", "pid": 201,
       "visible": true, "focused": false,
       "rect": {"x": 150, "y": 150, "width": 200, "height": 100},
       "window_rect": {"x": 0, "y": 0, "width": 200, "height": 100}}]}]}]}"""

const x11List = """{"screen": 0, "width": 640, "height": 480, "wm": false, "focus": 4194305,
  "windows": [
    {"id": 2097153, "pid": 4100, "class": "Bottom-app", "instance": "bottom", "title": "First",
     "x": 0, "y": 0, "width": 100, "height": 100, "mapped": true, "overrideRedirect": false},
    {"id": 3145729, "pid": null, "class": null, "instance": "anon", "title": null,
     "x": 10, "y": 10, "width": 50, "height": 50, "mapped": false, "overrideRedirect": false},
    {"id": 4194305, "pid": 4200, "class": "Top-app", "instance": "top", "title": "Ünïcode",
     "x": 100, "y": 80, "width": 200, "height": 120, "mapped": true, "overrideRedirect": false},
    {"id": 5242881, "pid": 4200, "class": "Top-app", "instance": "menu", "title": null,
     "x": 120, "y": 100, "width": 80, "height": 40, "mapped": true, "overrideRedirect": true}]}"""

const gnomeMonitors = """[{"id": "0", "x": 0, "y": 0, "width": 1024, "height": 768,
  "scale": 1, "primary": true}, {"id": "1", "x": 1024, "y": 0, "width": 800, "height": 600,
  "scale": 2, "primary": false}]"""

const gnomeWindows = """[
  {"id": "7", "pid": 70, "app": "Text Editor", "appId": "org.example.Editor",
   "title": "notes.txt", "x": 30, "y": 60, "width": 320, "height": 200, "monitor": 0,
   "layer": 2, "normalLayer": true, "minimized": false, "onScreen": true, "focused": true},
  {"id": "8", "pid": 80, "app": null, "appId": "gui-assert-wm-probe", "title": null,
   "x": 0, "y": 0, "width": 10, "height": 10, "monitor": -1, "layer": 2,
   "normalLayer": true, "minimized": true, "onScreen": false, "focused": false},
  {"id": "9", "pid": 90, "app": "Panel", "appId": null, "title": "dock",
   "x": 0, "y": 700, "width": 1024, "height": 68, "monitor": 0, "layer": 6,
   "normalLayer": false, "minimized": false, "onScreen": true, "focused": false}]"""

proc ids(ws: seq[Window]): seq[string] =
  for w in ws: result.add w.id

suite "linux-wlr: reading sway's answers":

  test "outputs: active only, the one at the origin primary, headless is virtual":
    let ds = parseSwayOutputs(swayOutputs)
    check ds.len == 2
    check ds[0].id == "HEADLESS-1" and ds[0].primary and ds[0].isVirtual
    check ds[0].name.isNone                        # "Unknown" is not a name
    check ds[0].bounds == rect(0, 0, 800, 600)
    check ds[1].id == "DP-2" and not ds[1].primary and not ds[1].isVirtual
    check ds[1].name == some("Example Panel 27") and ds[1].scale == 2.0

  test "outputs: with none at the origin the first is primary; junk is refused":
    let ds = parseSwayOutputs("""[{"name": "DP-1", "active": true, "scale": 1,
      "rect": {"x": 100, "y": 0, "width": 10, "height": 10}}]""")
    check ds.len == 1 and ds[0].primary
    expect ValueError: discard parseSwayOutputs("not json")
    expect ValueError: discard parseSwayOutputs("""{"name": "x"}""")

  test "tree: focused first, then floating top-most first, then tiled in order":
    let ws = parseSwayTree(swayTree)
    check ids(ws) == @["11", "21", "20", "30", "10"]

  test "tree: content rectangles, app ids, Xwayland classes, displays, scratchpad":
    var byId = initTable[string, Window]()
    for w in parseSwayTree(swayTree): byId[w.id] = w
    check byId["10"].bounds == rect(2, 24, 396, 574)    # rect + window_rect
    check byId["10"].app == "dev.example.editor"
    check byId["10"].appId == some("dev.example.editor")
    check byId["10"].display == some("HEADLESS-1")
    check byId["11"].app == "XTerm" and byId["11"].appId.isNone
    check byId["11"].title.isNone and byId["11"].focused
    check not byId["30"].onScreen and byId["30"].display.isNone
    for w in byId.values:
      check w.document.isNone and w.layer == 0 and not w.minimized
    expect ValueError: discard parseSwayTree("[]")

  test "grim geometry":
    check grimGeometry(rect(10, 20, 300, 40)) == "10,20 300x40"

suite "linux-x11: reading x11_probe":

  test "front to back, the focus, unknown pids and classes, override-redirect":
    let s = parseX11List(x11List)
    check s.size == Size(width: 640, height: 480)
    check ids(s.windows) == @["5242881", "4194305", "3145729", "2097153"]
    let top = s.windows[1]
    check top.focused and top.app == "Top-app" and top.title == some("Ünïcode")
    check top.bounds == rect(100, 80, 200, 120) and top.appId.isNone
    check s.windows[0].layer == 1                   # override-redirect
    check s.windows[2].pid == 0 and s.windows[2].app == "anon"
    check not s.windows[2].onScreen and s.windows[2].title.isNone
    let d = s.screenDisplay
    check d.id == "0" and d.primary and d.bounds == rect(0, 0, 640, 480)
    expect ValueError: discard parseX11List("{}")
    check x11Geometry(rect(5, 6, 7, 8)) == "7x8+5+6"

suite "linux-gnome: reading GNOME Shell's answers":

  test "monitors and windows":
    let ds = parseGnomeDisplays(parseJson(gnomeMonitors))
    check ds.len == 2 and ds[0].primary and ds[1].scale == 2.0
    check ds[1].bounds == rect(1024, 0, 800, 600)
    let ws = parseGnomeWindows(parseJson(gnomeWindows))
    check ids(ws) == @["7", "8", "9"]
    check ws[0].app == "Text Editor" and ws[0].appId == some("org.example.Editor")
    check ws[0].display == some("0") and ws[0].layer == 0 and ws[0].focused
    check ws[1].app == "gui-assert-wm-probe" and ws[1].minimized and not ws[1].onScreen
    check ws[1].display.isNone and ws[1].title.isNone
    check ws[2].layer == 6
    expect ValueError: discard parseGnomeWindows(newJObject())
    expect ValueError: discard parseGnomeDisplays(nil)

suite "linux_common: windows, regions, displays, files":
  let ws = parseGnomeWindows(parseJson(gnomeWindows))

  test "filters: layer 0 and on screen by default, widened by the flags":
    check ids(filterWindows(ws, WindowFilter())) == @["7"]
    check ids(filterWindows(ws, WindowFilter(allLayers: true, includeOffscreen: true))) ==
      @["7", "8", "9"]

  test "filters: app exact, pid, title exact and case-sensitive substring":
    let all = WindowFilter(allLayers: true, includeOffscreen: true)
    var f = all
    f.app = some("Text Editor")
    check ids(filterWindows(ws, f)) == @["7"]
    f.app = some("text editor")
    check filterWindows(ws, f).len == 0
    f = all
    f.pid = some(90)
    check ids(filterWindows(ws, f)) == @["9"]
    f = all
    f.titleContains = some("notes")
    check ids(filterWindows(ws, f)) == @["7"]
    f.titleContains = some("Notes")
    check filterWindows(ws, f).len == 0
    f = all
    f.title = some("dock")
    check ids(filterWindows(ws, f)) == @["9"]   # a null title matches no title filter

  test "a region lies within one display or is refused; display selection":
    let ds = parseGnomeDisplays(parseJson(gnomeMonitors))
    requireRegionOnOneDisplay(rect(1100, 10, 50, 50), ds)
    for bad in [rect(1000, 0, 100, 10), rect(0, 0, 0, 10), rect(-5, 0, 10, 10)]:
      try:
        requireRegionOnOneDisplay(bad, ds)
        check false
      except ContractError as e:
        check e.kind == ekBadArgs and e.reason == "invalid-value"
    check pickDisplay("t", ds, none(string)).id == "0"
    check pickDisplay("t", ds, some("1")).id == "1"
    expect BackendNotFoundError: discard pickDisplay("t", ds, some("2"))
    expect BackendError: discard pickDisplay("t", @[], none(string))
    check displayOfRect(rect(1000, 0, 100, 10), ds) == some("1")
    check displayOfRect(rect(5000, 0, 10, 10), ds).isNone

  test "PPM decoding":
    let img = decodePpmRgb("P6\n# a comment\n2 1\n255\n" & "\x01\x02\x03\xfa\xfb\xfc")
    check img.width == 2 and img.height == 1
    check img.pixels == "\x01\x02\x03\xfa\xfb\xfc"
    expect ValueError: discard decodePpmRgb("P5\n2 1\n255\n\0\0")
    expect ValueError: discard decodePpmRgb("P6\n2 1\n255\n\x01")
    expect ValueError: discard decodePpmRgb("P6\n2 1\n65535\n" & repeat('\0', 12))

  test "status files and the portal helper's exit statuses":
    let st = parseStatusFile("state=streaming\nnode=43\nwidth=800\nbad line\nx=oops\n")
    check st["state"] == "streaming" and st.intOf("width") == 800
    check st.intOf("x", 7) == 7 and st.intOf("missing") == 0
    let e3 = helperFailure(3, st, "")
    check e3 of ref BackendUnavailableError and e3.reason == "display-server-unsupported"
    check helperFailure(4, st, "").reason == "capture-failed"
    check "refused" in helperFailure(4, st, "").msg
    check helperFailure(7, st, "").reason == "capture-failed"
    check helperFailure(6, parseStatusFile("message=the consumer exited\n"), "").msg.endsWith(
      "the consumer exited")

  test "a failed probe gives its feature a reason the contract allows":
    # A probe that failed with exit 5 (the portal refused, the server's answer
    # was unreadable) must not put `capture-failed` into a feature: that is
    # not a backend-unavailable reason, and serializing it is exit 8.
    let refused = helperFailure(4, StatusFile(), "")
    check unavailableReason(refused) == "display-server-unsupported"
    check featureProblem(feature("linux-portal-pipewire", "display-capture", fsUnavailable,
      unavailableReason(refused), refused.msg)) == ""
    check featureProblem(feature("linux-portal-pipewire", "display-capture", fsUnavailable,
      refused.reason, refused.msg)) != ""                       # the rule it guards
    # A backend-unavailable reason is kept as it is.
    check unavailableReason(helperFailure(3, StatusFile(), "")) == "display-server-unsupported"
    check unavailableReason(unavailableWith("linux-x11", "missing-tool", "m", "r")) ==
      "missing-tool"

  test "lastLine bounds a tool's diagnostics":
    check lastLine("one\ntwo\n\n") == "two"
    check lastLine(repeat('x', 400)).len < 310

suite "the capture default follows the caller's session (spec §4.2)":

  test "sway, GNOME on Wayland, X11 without Wayland, otherwise linux-wlr":
    check linuxHostCaptureDefault({"SWAYSOCK": "/run/s", "WAYLAND_DISPLAY": "w",
      "XDG_CURRENT_DESKTOP": "GNOME"}.toTable) == "linux-wlr"
    check linuxHostCaptureDefault({"WAYLAND_DISPLAY": "w",
      "XDG_CURRENT_DESKTOP": "ubuntu:GNOME"}.toTable) == "linux-gnome"
    check linuxHostCaptureDefault({"WAYLAND_DISPLAY": "w", "DISPLAY": ":0",
      "XDG_CURRENT_DESKTOP": "KDE"}.toTable) == "linux-wlr"
    check linuxHostCaptureDefault({"DISPLAY": ":99"}.toTable) == "linux-x11"
    check linuxHostCaptureDefault({"DISPLAY": ":99", "XDG_CURRENT_DESKTOP": "GNOME"}.toTable) ==
      "linux-x11"                                   # GNOME on Xorg: X11
    check linuxHostCaptureDefault(initTable[string, string]()) == "linux-wlr"
    when defined(linux):
      check defaultFor(modCapture, {"DISPLAY": ":1"}.toTable) == "linux-x11"
      check defaultFor(modOcr, {"DISPLAY": ":1"}.toTable) == "tesseract"

suite "linux_common: finalizing a recording (C12)":
  let work = getTempDir() / ("tlinux_capture_" & $getCurrentProcessId())
  removeDir(work)
  createDir(work)
  let ffmpeg = findExe("ffmpeg")
  let ffprobe = findExe("ffprobe")

  proc encode(path: string, frames, fps: int) =
    let (o, code) = execCmdEx(ffmpeg & " -v error -y -f lavfi -i color=c=blue:s=64x48:r=" &
      $fps & " -frames:v " & $frames & " -c:v libx264 -pix_fmt yuv420p -f mp4 " & quoteShell(path))
    doAssert code == 0, o

  proc counted(path: string): int =
    let (o, code) = execCmdEx(ffprobe & " -v error -count_frames -select_streams v:0 " &
      "-show_entries stream=nb_read_frames -of csv=p=0 " & quoteShell(path))
    doAssert code == 0, o
    parseInt(o.strip)

  proc recording(path: string): Recording =
    Recording(id: "wlr-1", path: path, state: rsRecording, format: rfMp4,
              width: 1, height: 1, fps: 10.0,
              source: ImageSource(kind: iskDisplay, id: some("HEADLESS-1"), session: some("host")),
              startedAt: "2026-10-21T00:00:00.000Z")

  test "ffmpeg and ffprobe are on PATH (the suite measures real files)":
    check ffmpeg.len > 0 and ffprobe.len > 0

  test "a finalized MP4 is measured from its container and renamed into place":
    let tmp = work / ".out.mp4.partial-wlr-1.mp4"
    let outp = work / "out.mp4"
    encode(tmp, 12, 10)
    var r = recording(outp)
    check finalizeRecording(r, tmp, "") == ""
    check r.state == rsStopped
    check fileExists(outp) and not fileExists(tmp)
    check r.frames == some(counted(outp)) and r.frames == some(12)
    check r.durationMs == some(1200)
    check r.width == 64 and r.height == 48

  test "an MP4 without its moov index is failed and removed, never stopped":
    let tmp = work / ".cut.mp4.partial-wlr-2.mp4"
    let outp = work / "cut.mp4"
    encode(tmp, 10, 10)
    let bytes = readFile(tmp)
    let i = bytes.find("moov")
    check i >= 4
    writeFile(tmp, bytes[0 ..< i - 4])
    var r = recording(outp)
    check "moov" in finalizeRecording(r, tmp, "")
    check r.state == rsFailed and r.frames.isNone and r.durationMs.isNone
    check not fileExists(tmp) and not fileExists(outp)

  test "a recorder that reported a problem fails the recording even with a good file":
    let tmp = work / ".bad.mp4.partial-wlr-3.mp4"
    encode(tmp, 5, 10)
    var r = recording(work / "bad.mp4")
    check "stream ended" in finalizeRecording(r, tmp, "the recorder failed: stream ended")
    check r.state == rsFailed and not fileExists(tmp) and not fileExists(work / "bad.mp4")

  test "a recorder that left no file fails the recording":
    var r = recording(work / "none.mp4")
    check "no file" in finalizeRecording(r, work / ".none.partial.mp4", "")
    check r.state == rsFailed

  removeDir(work)

when defined(linux):
  suite "linux_common: tools and detached recorders (real processes)":
    let state = getTempDir() / ("tlinux_capture_state_" & $getCurrentProcessId())
    removeDir(state)
    createDir(state)
    let token = newCancelToken()
    var env = initTable[string, string]()
    env["PATH"] = getEnv("PATH")
    env["GA_PLANTED"] = "only-in-the-invocation"
    let cfg = LinuxCaptureConfig(stateDir: state, token: token, env: env)

    test "a tool runs with the invocation's environment, and only it":
      putEnv("GA_PROCESS_ONLY", "leaked")
      let sh = cfg.findTool("t", "sh")
      let r = cfg.runTool("t", @[sh, "-c", "echo \"$GA_PLANTED|$GA_PROCESS_ONLY\"; echo oops >&2; exit 3"])
      check r.code == 3
      check r.output.strip == "only-in-the-invocation|"
      check r.errors.strip == "oops"
      delEnv("GA_PROCESS_ONLY")

    test "a missing tool is exit 4 / missing-tool":
      try:
        discard cfg.findTool("t", "no-such-tool-gs5")
        check false
      except BackendUnavailableError as e:
        check e.reason == "missing-tool"

    test "a tool past its bound is killed and fails; a deadline wins as a deadline":
      let sleepExe = cfg.findTool("t", "sleep")
      let started = monoNowNs()
      expect BackendError: discard cfg.runTool("t", @[sleepExe, "30"], timeoutMs = 200)
      check elapsedMsSince(started) < 5000
      let t2 = newCancelToken()
      t2.setDeadline(150)
      var c2 = cfg
      c2.token = t2
      try:
        discard c2.runTool("t", @[sleepExe, "30"])
        check false
      except ContractError as e:
        check e.kind == ekTimeout
      t2.free()

    test "a detached process outlives nothing of ours and is named by its start time":
      let sleepExe = cfg.findTool("t", "sleep")
      let log = state / "detached.log"
      let (pid, startTime) = cfg.spawnDetached("t", @[sleepExe, "30"], log)
      check pid > 0 and startTime.len > 0
      check processIs(pid, startTime)
      check not processIs(pid, startTime & "0")       # another start time: not it
      # It is not our child (double fork): its parent is not this process.
      let stat = readFile("/proc/" & $pid & "/stat")
      let ppid = stat[stat.rfind(')') + 1 .. ^1].splitWhitespace[1]
      check ppid != $getCurrentProcessId()
      discard kill(Pid(pid), SIGKILL)
      var waited = 0
      while processIs(pid, startTime) and waited < 3000:
        sleep(10)
        waited += 10
      check not processIs(pid, startTime)
      check processStartTime(0) == "" and processStartTime(-1) == ""

    test "features without a session name what is missing":
      let none = LinuxCaptureConfig(stateDir: state, token: token,
                                    env: {"PATH": getEnv("PATH")}.toTable)
      for f in newLinuxWlrCapture(none).features(false):
        if f.feature == "own-pixels-capture":
          check f.reason == some("unsupported-option")
        else:
          check f.state == fsUnavailable and f.reason == some("display-server-unsupported")
      for f in newLinuxX11Capture(none).features(false):
        if f.feature != "own-pixels-capture":
          check f.reason == some("display-server-unsupported")
      for f in newLinuxGnomeCapture(none).features(false):
        if f.feature notin ["own-pixels-capture", "recording"]:
          check f.reason == some("display-server-unsupported")
      for f in newLinuxPortalPipewireCapture(none).features(false):
        if f.feature in ["display-capture", "recording"]:
          check f.reason == some("display-server-unsupported")
      var names: seq[string]
      for f in newLinuxWlrCapture(none).features(false): names.add f.feature
      for n in captureFeatureNames: check names.filterIt(it == n).len == 1
      try:
        discard newLinuxWlrCapture(none).displays("host")
        check false
      except BackendUnavailableError as e:
        check e.reason == "display-server-unsupported"

    token.free()
    removeDir(state)
else:
  suite "the Linux capture backends off Linux":
    test "every operation is wrong-platform":
      let cfg = LinuxCaptureConfig(stateDir: getTempDir())
      for b in [newLinuxWlrCapture(cfg), newLinuxGnomeCapture(cfg), newLinuxX11Capture(cfg),
                newLinuxPortalPipewireCapture(cfg)]:
        for f in b.features(false): check f.reason == some("wrong-platform")
        try:
          discard b.displays("host")
          check false
        except BackendUnavailableError as e:
          check e.reason == "wrong-platform"
