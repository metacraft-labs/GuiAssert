## tmacos_capture — the parts of the macOS capture backends (`macos-sck`,
## `macos-cgwindow`) that need no window server and no TCC grant, so they
## run in the default suite on every host (spec §9.1, §9.4):
##
## * assembling the `windows` answer from a window-server snapshot (order,
##   filters, redacted titles, the focused window, the display of a window);
## * the recorder's status file and the mapping of helper outcomes to
##   contract errors, the exit-6 denial with its identity and click-path
##   included;
## * finalizing a recording (C12) on real MP4 files that ffmpeg encodes here:
##   a finalized one is measured and renamed into place, one without its
##   `moov` index is failed and removed;
## * the backends off macOS: every operation `wrong-platform`; on macOS,
##   `macos-cgwindow` refuses every capture as `not-implemented`.
##
## Stand-ins: the window-server snapshots are literal `CgSnapshot` values,
## because the code under test is the pure assembly that consumes one; the
## live suite (`tests/live/tcapture_macos.nim`) runs the same code on real
## snapshots. Nothing else is stood in for: the MP4 files are encoded by the
## real ffmpeg and measured by the real `core/mp4`.

import std/[options, os, osproc, strutils, unittest]

import ../src/gui_assert/core/[geometry, desktop_types, interfaces]
import ../src/gui_assert/screen_capture
import ../src/gui_assert/backends/capture/[macos_cgwindow, macos_sck]

proc row(id, pid: int, owner: string, title = none(string), bounds = rect(0, 0, 100, 100),
         layer = 0, onScreen = true): CgWindowRow =
  CgWindowRow(id: id, pid: pid, owner: owner, title: title, bounds: bounds,
              layer: layer, onScreen: onScreen, bundleId: some("dev.example." & owner))

let displays = @[
  Display(id: "1", bounds: rect(0, 0, 1000, 800), scale: 2.0, primary: true),
  Display(id: "2", bounds: rect(1000, 0, 800, 600), scale: 1.0)]

let snap = CgSnapshot(displays: displays, frontPid: 20, titlesVisible: true, rows: @[
  row(5, 10, "Menu", some("menubar"), rect(0, 0, 1000, 24), layer = 25),
  row(7, 20, "Notes", some("Shopping list"), rect(100, 100, 400, 300)),
  row(8, 20, "Notes", some("Ideas"), rect(900, 50, 300, 200)),
  row(9, 30, "Mail", some("Inbox"), rect(1100, 100, 300, 300)),
  row(11, 30, "Mail", some("Draft"), rect(0, 0, 10, 10), onScreen = false)])

suite "macos-cgwindow: assembling the windows answer":

  test "front to back, layer 0 and on screen by default":
    let l = assembleWindows(snap, WindowFilter())
    check l.titlesVisible
    var ids: seq[string]
    for w in l.windows: ids.add w.id
    check ids == @["7", "8", "9"]

  test "--all-layers and --include-offscreen widen the list":
    let l = assembleWindows(snap, WindowFilter(allLayers: true, includeOffscreen: true))
    check l.windows.len == 5
    check l.windows[0].id == "5" and l.windows[0].layer == 25

  test "the frontmost application's frontmost layer-0 window is the focused one":
    let l = assembleWindows(snap, WindowFilter())
    check l.windows[0].focused        # 7: Notes, frontmost
    check not l.windows[1].focused    # 8: Notes, behind 7
    check not l.windows[2].focused    # 9: Mail
    var noFront = snap
    noFront.frontPid = 0
    for w in assembleWindows(noFront, WindowFilter()).windows: check not w.focused

  test "every window carries its pid, app, bundle id and a null document":
    let w = assembleWindows(snap, WindowFilter()).windows[0]
    check w.pid == 20 and w.app == "Notes" and w.appId == some("dev.example.Notes")
    check w.document.isNone and not w.minimized
    check w.bounds == rect(100, 100, 400, 300)

  test "a window's display is the one holding most of it":
    let ws = assembleWindows(snap, WindowFilter()).windows
    check ws[0].display == some("1")
    check ws[1].display == some("2")   # 900..1200: 100 on display 1, 200 on display 2
    check ws[2].display == some("2")
    check displayOf(rect(5000, 5000, 10, 10), displays).isNone

  test "--app and --pid filter; --app matches the name exactly":
    check assembleWindows(snap, WindowFilter(app: some("Mail"))).windows.len == 1
    check assembleWindows(snap, WindowFilter(app: some("mail"))).windows.len == 0
    check assembleWindows(snap, WindowFilter(app: some("Mai"))).windows.len == 0
    check assembleWindows(snap, WindowFilter(pid: some(20))).windows.len == 2

  test "--title is exact and --title-contains a case-sensitive substring":
    check assembleWindows(snap, WindowFilter(title: some("Ideas"))).windows.len == 1
    check assembleWindows(snap, WindowFilter(title: some("ideas"))).windows.len == 0
    check assembleWindows(snap, WindowFilter(titleContains: some("list"))).windows.len == 1
    check assembleWindows(snap, WindowFilter(titleContains: some("List"))).windows.len == 0

  test "without the grant every title is null and a title filter matches nothing":
    var redacted = snap
    redacted.titlesVisible = false
    let l = assembleWindows(redacted, WindowFilter())
    check not l.titlesVisible
    check l.windows.len == 3
    for w in l.windows: check w.title.isNone
    check assembleWindows(redacted, WindowFilter(title: some("Ideas"))).windows.len == 0
    check assembleWindows(redacted, WindowFilter(titleContains: some("I"))).windows.len == 0

  test "the enumeration-only features name what is missing":
    let fs = cgwindowFeatures(macosCgwindowName, true, false)
    check fs[0].feature == "window-enumeration" and fs[0].state == fsDegraded
    check fs[0].reason == some("titles-redacted")
    check cgwindowFeatures(macosCgwindowName, true, true)[0].state == fsSupported
    check fs.len == 6
    for f in fs[1 .. ^1]:
      check f.state == fsUnavailable and f.reason == some("not-implemented")
      check f.remedy.get.contains("macos-sck")

suite "macos-sck: helper outcomes and errors":

  test "the recorder status file parses; an unreadable one is no state":
    let s = parseRecorderStatus("state=recording\npid=4242\nwidth=640\nheight=480\n" &
                                "scale=2.000\nfps=10.0\nframes=37\n")
    check s.state == "recording" and s.pid == 4242 and s.frames == 37
    check s.width == 640 and s.height == 480 and s.scale == 2.0
    let f = parseRecorderStatus("state=failed\ncode=3\npid=1\nmessage=window 9 is not among the 4\n")
    check f.state == "failed" and f.code == 3 and f.message.startsWith("window 9")
    check parseRecorderStatus("").state == ""
    check parseRecorderStatus("garbage\nno equals\n").state == ""

  test "a denial is exit 6 / tcc-screen-recording naming the identity and click-path":
    let e = errorForStatus(csDenied, 4, "CGPreflightScreenCaptureAccess() is false",
                           "/Apps/GuiAssertCapture.app", "dev.example.capture", "display")
    check e of ref PermissionDeniedError
    check e.reason == "tcc-screen-recording" and e.backend == "macos-sck"
    check "dev.example.capture" in e.msg and "/Apps/GuiAssertCapture.app" in e.msg
    check "/Apps/GuiAssertCapture.app" in e.remedy
    check "dev.example.capture" in e.remedy
    check "Screen & System Audio Recording" in e.remedy
    check "Shift-Cmd-G" in e.remedy
    check "terminal" in e.remedy

  test "a missing target is not-found; anything else is capture-failed":
    let w = errorForStatus(csTargetNotFound, 3, "window 9 is gone", "a", "b", "window")
    check w of ref BackendNotFoundError and w.reason == "window"
    let d = errorForStatus(csTargetNotFound, 3, "no display 7", "a", "b", "display")
    check d.reason == "display"
    for st in [csCaptureFailed, csWriteFailed, csTimeout, csUnknown, csUsage]:
      let x = errorForStatus(st, 5, "boom", "a", "b", "display")
      check not (x of ref PermissionDeniedError) and not (x of ref BackendNotFoundError)
      check not (x of ref BackendUnavailableError)
      check x.reason == "capture-failed"

  test "pngSize reads the IHDR and refuses anything else":
    let png = "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x02\x80\x00\x00\x01\xe0" & "\x08\x06\x00\x00\x00"
    check pngSize(png) == (640, 480)
    expect ValueError: discard pngSize("GIF89a" & repeat('\0', 30))
    expect ValueError: discard pngSize("\x89PNG")

suite "macos-sck: finalizing a recording (C12)":
  let work = getTempDir() / ("tmacos_capture_" & $getCurrentProcessId())
  removeDir(work)
  createDir(work)
  let ffmpeg = findExe("ffmpeg")
  let ffprobe = findExe("ffprobe")

  proc encode(path: string, frames, fps: int) =
    let (o, code) = execCmdEx(ffmpeg & " -v error -y -f lavfi -i color=c=red:s=64x48:r=" &
      $fps & " -frames:v " & $frames & " -c:v mpeg4 -pix_fmt yuv420p " & quoteShell(path))
    doAssert code == 0, o

  proc counted(path: string): int =
    let (o, code) = execCmdEx(ffprobe & " -v error -count_frames -select_streams v:0 " &
      "-show_entries stream=nb_read_frames -of csv=p=0 " & quoteShell(path))
    doAssert code == 0, o
    parseInt(o.strip)

  proc recording(path: string): Recording =
    Recording(id: "sck-1", path: path, state: rsRecording, format: rfMp4,
              width: 1, height: 1, fps: 10.0,
              source: ImageSource(kind: iskDisplay, id: some("1"), session: some("host")),
              startedAt: "2026-10-20T00:00:00.000Z")

  test "ffmpeg and ffprobe are on PATH (the suite measures real files)":
    check ffmpeg.len > 0 and ffprobe.len > 0

  test "a finalized MP4 is measured from its container and renamed into place":
    let tmp = work / ".out.mp4.partial-sck-1.mp4"
    let outp = work / "out.mp4"
    encode(tmp, 15, 10)
    var r = recording(outp)
    check finalizeRecording(r, tmp, "") == ""
    check r.state == rsStopped
    check fileExists(outp) and not fileExists(tmp)
    check r.frames == some(counted(outp))
    check r.frames == some(15)
    check r.durationMs == some(1500)
    check r.width == 64 and r.height == 48

  test "an MP4 without its moov index is failed and removed, never stopped":
    let tmp = work / ".cut.mp4.partial-sck-2.mp4"
    let outp = work / "cut.mp4"
    encode(tmp, 10, 10)
    let bytes = readFile(tmp)
    let i = bytes.find("moov")
    check i >= 4
    writeFile(tmp, bytes[0 ..< i - 4])
    var r = recording(outp)
    let why = finalizeRecording(r, tmp, "")
    check "moov" in why
    check r.state == rsFailed and r.frames.isNone and r.durationMs.isNone
    check not fileExists(tmp) and not fileExists(outp)

  test "a recorder that reported a problem fails the recording even with a good file":
    let tmp = work / ".bad.mp4.partial-sck-3.mp4"
    let outp = work / "bad.mp4"
    encode(tmp, 5, 10)
    var r = recording(outp)
    let why = finalizeRecording(r, tmp, "the recorder failed: the stream stopped")
    check "the stream stopped" in why
    check r.state == rsFailed
    check not fileExists(tmp) and not fileExists(outp)

  test "a recorder that left no file fails the recording":
    var r = recording(work / "none.mp4")
    check "no file" in finalizeRecording(r, work / ".missing.partial.mp4", "")
    check r.state == rsFailed

  removeDir(work)

suite "the macOS backends' constructors":

  test "macos-cgwindow never captures":
    let b = newMacosCgwindowCapture()
    check b.name == "macos-cgwindow"
    try:
      discard b.capture(CaptureRequest(session: "host", outPath: "/nonexistent/x.png",
                                       target: CaptureTarget(kind: ctkDisplay)))
      check false
    except BackendUnavailableError as e:
      when defined(macosx): check e.reason == "not-implemented"
      else: check e.reason == "wrong-platform"
    expect BackendUnavailableError:
      discard b.startRecording(RecordRequest(session: "host", outPath: "/nonexistent/x.mp4",
                                             fps: 10.0, target: CaptureTarget(kind: ctkDisplay)))

  when not defined(macosx):
    test "off macOS every macos-sck operation is wrong-platform":
      let b = newMacosSckCapture(MacosSckConfig(stateDir: getTempDir()))
      for f in b.features(false): check f.reason == some("wrong-platform")
      try:
        discard b.displays("host")
        check false
      except BackendUnavailableError as e:
        check e.reason == "wrong-platform"
      try:
        discard b.windows("host", WindowFilter())
        check false
      except BackendUnavailableError as e:
        check e.reason == "wrong-platform"
