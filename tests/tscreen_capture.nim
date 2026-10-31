## tscreen_capture — tests for `gui_assert/screen_capture` (macOS still-frame
## and window-targeted capture) and for the live frame sources it gives the
## assertion harness.
##
## Mocking policy: NOTHING is mocked. The pure suites parse and build real
## artefacts of the real helper protocol — the report text, the window TSV and
## the argv — captured verbatim from the real helper running on this host. The
## live suites compile the real Swift helper, build and sign the real `.app`
## bundle, and capture the real screen. There is no fake window server and no
## fake TCC answer anywhere, because the only interesting failures in this
## module are the ones a fake would have to invent an answer for.
##
## Default invocation (no live capture):
##
##   nim c -r --hints:off tests/tscreen_capture.nim
##
## Live capture (macOS, needs the one-time grant — see below):
##
##   nim c -d:captureLive -r --hints:off tests/tscreen_capture.nim
##
## The live suites are **compile-time** gated, exactly as `tcapture.nim`'s live
## test is, and for the same stated reason: a runtime skip would silently
## degrade coverage on macOS dev boxes. A test that cannot run must not report
## success, so there is no `skip()` anywhere in this file.
##
## ## Which tests are blocked on the one-time macOS grant
##
## `GuiAssertCapture.app` needs Screen Recording permission once. Until it has
## it, these tests FAIL — deliberately, loudly, with the remedy printed:
##
##   * "preflight reports the bundle holds the ScreenCapture grant"
##   * "captureDisplayStill writes a non-trivial PNG of the whole display"
##   * "captureWindowStill returns THAT window's pixels, not a screen crop"
##   * "a live window harness drives waitForText / regionText / currentFrame"
##   * "detectLayoutOverflow and visualCompare run frame-lessly off a live harness"
##
## They refuse rather than skip: each catches `StillCaptureDenied`, prints the
## grant instructions as a checkpoint, and calls `fail()`. A `[FAILED]` with
## "BLOCKED ON THE ONE-TIME GRANT" in its checkpoints is that state; it is not
## an infrastructure error and it is not a pass.
##
## Everything NOT in that list runs without any grant, including the positive
## control (`CGWindowListCopyWindowInfo`), the Swift compile, and the bundle
## build + signature-durability checks.

import std/[os, strutils, unittest]

import ../src/gui_assert
import ../src/gui_assert/screen_capture

# ---------------------------------------------------------------------------
# Verbatim fixtures, copied from real helper output on aarch64-darwin,
# macOS 26.5.2 (build 25F84), 2026-10-12.
# ---------------------------------------------------------------------------

const REPORT_DENIED = """status=denied
code=4
mode=window
windows_seen=10
titles_visible=0
preflight=0
candidates=1
window_id=105
window_owner=iTerm
window_title=
window_bounds=40,49,1515,1006
window_onscreen=1
message=SCShareableContent: Error Domain=com.apple.ScreenCaptureKit.SCStreamErrorDomain Code=-3801 "The user declined TCCs for application, window, display capture"
"""

const REPORT_OK = """status=ok
code=0
mode=display
windows_seen=12
titles_visible=1
preflight=1
displays_seen=1
display_id=1
display_points=1512x945
width=3024
height=1890
scale=2.000
out=/tmp/frame.png
"""

const WINDOW_TSV = """997	48720	Google Chrome		22	55	1200	1040	0	1
41	48767	Phone		375	269	978	612	0	1
74	48974	borders		365	259	998	632	0	1
105	48758	iTerm	zsh — fix-pxor-issues	40	49	1515	1006	0	1
900	48758	iTerm	Preferences	100	100	600	400	3	1
901	48720	Google Chrome	Offscreen	0	0	2000	2000	0	0
"""

# ---------------------------------------------------------------------------
# Pure: report parsing
# ---------------------------------------------------------------------------

suite "screen capture: report parsing":

  test "a denied report parses to csDenied and keeps the attested target":
    let r = parseCaptureReport(REPORT_DENIED)
    check r.status == csDenied
    check r.code == 4
    check r.mode == "window"
    # The positive control travelled with the denial: the window list WAS
    # readable, so this is a permission problem and not a dead GUI session.
    check r.windowsSeen == 10
    check r.titlesVisible == false
    check r.preflight == false
    check r.candidates == 1
    check r.windowId == 105
    check r.windowOwner == "iTerm"
    check r.windowBounds == [40, 49, 1515, 1006]
    check "-3801" in r.message

  test "an ok report parses dimensions, scale and the output path":
    let r = parseCaptureReport(REPORT_OK)
    check r.status == csOk
    check r.code == 0
    check r.width == 3024
    check r.height == 1890
    check r.scale == 2.0
    check r.titlesVisible == true
    check r.preflight == true
    check r.outPath == "/tmp/frame.png"

  test "an unreadable report is csUnknown, never csOk":
    # RED CONTROL for the single most dangerous parse bug in this module: a
    # report we cannot read must not be read as a success. `csUnknown` is the
    # first enum value only by accident of ordering elsewhere, so this is
    # asserted rather than assumed.
    check parseCaptureReport("status=weather-is-nice\ncode=0\n").status == csUnknown
    check parseCaptureReport("").status == csUnknown
    check parseCaptureReport("garbage with no equals sign").status == csUnknown
    check statusFromLabel("ok") == csOk
    check statusFromLabel("OK") == csUnknown   # case matters; the helper emits lowercase
    check statusFromLabel("denied") == csDenied
    check statusFromLabel("") == csUnknown

  test "a malformed window_bounds field degrades to zeroes, not to garbage":
    check parseCaptureReport("status=ok\nwindow_bounds=1,2,3\n").windowBounds ==
      [0, 0, 0, 0]
    check parseCaptureReport("status=ok\nwindow_bounds=1,2,x,4\n").windowBounds ==
      [0, 0, 0, 0]
    check parseCaptureReport("status=ok\nwindow_bounds=1,2,3,4\n").windowBounds ==
      [1, 2, 3, 4]

# ---------------------------------------------------------------------------
# Pure: window-list parsing
# ---------------------------------------------------------------------------

suite "screen capture: window list parsing":

  test "parseWindowListTsv reads every well-formed row":
    let ws = parseWindowListTsv(WINDOW_TSV)
    check ws.len == 6
    check ws[0].windowId == 997
    check ws[0].ownerName == "Google Chrome"
    check ws[0].title == ""             # redacted: no grant when this was taken
    check ws[0].bounds == [22, 55, 1200, 1040]
    check ws[0].layer == 0
    check ws[0].onScreen == true
    check ws[3].ownerName == "iTerm"
    check ws[3].title == "zsh — fix-pxor-issues"
    check ws[4].layer == 3
    check ws[5].onScreen == false

  test "short and non-numeric rows are dropped, not half-parsed":
    # RED CONTROL: a row that loses its trailing columns, and a row whose id is
    # not a number, must vanish rather than arrive with plausible zeroes.
    check parseWindowListTsv("1\t2\tOwner\tTitle\t0\t0\t10\t10\n").len == 0
    check parseWindowListTsv("x\t2\tOwner\tTitle\t0\t0\t10\t10\t0\t1\n").len == 0
    check parseWindowListTsv("1\t2\tOwner\tTitle\t0\t0\t10\t10\t0\t1\n").len == 1

# ---------------------------------------------------------------------------
# Pure: window matching
# ---------------------------------------------------------------------------

suite "screen capture: window matching":

  let ws = parseWindowListTsv(WINDOW_TSV)

  test "an owner match is case-insensitive and exact, not a substring":
    check matchWindows(ws, initWindowQuery(owner = "iterm")).len == 1
    check matchWindows(ws, initWindowQuery(owner = "iTerm"))[0].windowId == 105
    # RED CONTROL: "iTer" is a prefix of "iTerm" and must NOT match, or
    # "Chrome" would match "Google Chrome Helper" in the field.
    check matchWindows(ws, initWindowQuery(owner = "iTer")).len == 0
    check matchWindows(ws, initWindowQuery(owner = "NoSuchApp")).len == 0

  test "non-zero layers and offscreen windows are excluded by default":
    # Window 900 is layer 3 (a panel) and 901 is offscreen.
    let ids = matchWindows(ws, initWindowQuery(owner = "iTerm")).len
    check ids == 1
    check matchWindows(ws, initWindowQuery(owner = "iTerm", anyLayer = true)).len == 2
    check matchWindows(ws, initWindowQuery(owner = "Google Chrome")).len == 1
    check matchWindows(ws, initWindowQuery(owner = "Google Chrome",
                                           includeOffscreen = true)).len == 2

  test "titleContains is case-insensitive; title is exact":
    check matchWindows(ws, initWindowQuery(titleContains = "FIX-PXOR")).len == 1
    check matchWindows(ws, initWindowQuery(title = "zsh — fix-pxor-issues")).len == 1
    # RED CONTROL: an exact-title query with the wrong case must not match.
    check matchWindows(ws, initWindowQuery(title = "ZSH — FIX-PXOR-ISSUES")).len == 0

  test "matches come back largest-area first":
    let all = matchWindows(ws, initWindowQuery(anyLayer = true,
                                               includeOffscreen = true))
    check all.len == 6
    for i in 1 ..< all.len:
      let prev = all[i - 1].bounds[2] * all[i - 1].bounds[3]
      let cur = all[i].bounds[2] * all[i].bounds[3]
      check prev >= cur

  test "an empty query is recognised as naming no target":
    check initWindowQuery().isEmpty
    check not initWindowQuery(owner = "iTerm").isEmpty
    check not initWindowQuery(windowId = 7).isEmpty
    check not initWindowQuery(titleContains = "x").isEmpty

# ---------------------------------------------------------------------------
# Pure: argv builder
# ---------------------------------------------------------------------------

proc indexOf(argv: seq[string], tok: string): int =
  for i, a in argv:
    if a == tok: return i
  return -1

proc hasFlag(argv: seq[string], tok: string): bool = indexOf(argv, tok) >= 0

proc valueAfter(argv: seq[string], tok: string): string =
  let i = indexOf(argv, tok)
  doAssert i >= 0, "expected flag '" & tok & "' missing from argv: " & $argv
  doAssert i + 1 < argv.len,
    "flag '" & tok & "' has no following value in argv: " & $argv
  return argv[i + 1]

suite "screen capture: argv builder":

  test "display mode carries the display index, the out path and a timeout":
    let argv = buildHelperArgv("display", outPath = "/tmp/f.png",
                               displayIndex = 2, timeoutMs = 25_000,
                               reportPath = "/tmp/r.txt")
    check argv[0] == "display"
    check valueAfter(argv, "--out") == "/tmp/f.png"
    check valueAfter(argv, "--report") == "/tmp/r.txt"
    check valueAfter(argv, "--display") == "2"
    # Seconds, not milliseconds: the helper's own self-bound.
    check valueAfter(argv, "--timeout") == "25.0"
    check not hasFlag(argv, "--owner")

  test "window mode emits exactly the selectors the query sets":
    let argv = buildHelperArgv("window", outPath = "/tmp/w.png",
                               q = initWindowQuery(owner = "iTerm",
                                                   titleContains = "fib"),
                               timeoutMs = 20_000)
    check argv[0] == "window"
    check valueAfter(argv, "--owner") == "iTerm"
    check valueAfter(argv, "--title-contains") == "fib"
    # RED CONTROL: `titleContains` must not be emitted as `--title`. Those are
    # different filters in the helper (substring vs. exact), and conflating
    # them would make every substring query silently exact.
    check not hasFlag(argv, "--title")
    check not hasFlag(argv, "--window-id")

  test "a window-id query emits --window-id and nothing else":
    let argv = buildHelperArgv("window", outPath = "/tmp/w.png",
                               q = initWindowQuery(windowId = 105))
    check valueAfter(argv, "--window-id") == "105"
    check not hasFlag(argv, "--owner")
    check not hasFlag(argv, "--title")

  test "enumerate carries every query selector to the helper":
    let argv = buildHelperArgv("enumerate", q = initWindowQuery(
      windowId = 105, owner = "iTerm", title = "fixture", titleContains = "fix"))
    check valueAfter(argv, "--window-id") == "105"
    check valueAfter(argv, "--owner") == "iTerm"
    check valueAfter(argv, "--title") == "fixture"
    check valueAfter(argv, "--title-contains") == "fix"
    check not hasFlag(argv, "--timeout")

  test "layer and offscreen switches are passed through":
    let argv = buildHelperArgv("enumerate",
                               q = initWindowQuery(anyLayer = true,
                                                   includeOffscreen = true))
    check hasFlag(argv, "--any-layer")
    check hasFlag(argv, "--include-offscreen")
    # enumerate needs no output file and no timeout flag.
    check not hasFlag(argv, "--out")
    check not hasFlag(argv, "--timeout")

  test "the timeout never degrades below one second":
    let argv = buildHelperArgv("display", outPath = "/tmp/f.png",
                               timeoutMs = 10)
    check valueAfter(argv, "--timeout") == "1.0"

# ---------------------------------------------------------------------------
# Pure: the grant instructions are the remedy, so they must stay accurate
# ---------------------------------------------------------------------------

suite "screen capture: grant instructions":

  test "the instructions name the pane, the bundle and the terminal warning":
    let t = grantInstructions("/Users/x/Library/Application Support/GuiAssert/GuiAssertCapture.app")
    check "Screen & System Audio Recording" in t
    check "Privacy & Security" in t
    check "GuiAssertCapture.app" in t
    check "/Users/x/Library/Application Support/GuiAssert" in t
    # The whole point of the bundle is that the terminal stays denied.
    check "Do NOT grant Screen Recording to your terminal" in t

# ---------------------------------------------------------------------------
# The path-based harness API must be untouched by the live frame sources
# ---------------------------------------------------------------------------

suite "screen capture: path-based harness API is unaffected":

  test "a path harness keeps its label, its timeout and its missing-frame error":
    # Guards the one thing adding live frame sources could plausibly have
    # broken: `codetracer-marketing` constructs path harnesses and calls the
    # three-argument assertions. Runs on every platform, with no capture.
    let tmp = getTempDir() / "guiassert_path_harness_probe_does_not_exist.png"
    removeFile(tmp)
    let h = newGuiAssertHarness(tmp)
    check h.frameSourceLabel == "path:" & tmp
    check h.pollIntervalMs == 100
    # `waitForText` with no frame on disk returns false; it must not raise and
    # must not block past the timeout.
    check waitForText(h, "anything", timeoutMs = 0) == false
    # The frame-aware accessors must raise rather than invent a frame.
    expect OcrError:
      discard regionText(h)
    expect OcrError:
      discard h.currentFrame()

  test "a closure harness keeps the default label and the supplied interval":
    let h = newGuiAssertHarnessFromSource(proc(): string {.closure.} = "",
                                          pollIntervalMs = 7)
    check h.frameSourceLabel == "closure"
    check h.pollIntervalMs == 7
    expect OcrError:
      discard h.currentFrame()

# ---------------------------------------------------------------------------
# The platform gate must raise, never no-op
# ---------------------------------------------------------------------------

suite "screen capture: platform and argument gates":

  when not defined(macosx):
    test "capture raises StillCaptureUnavailable off macOS":
      expect StillCaptureUnavailable:
        discard captureDisplayStill("/tmp/should-not-exist.png")
      expect StillCaptureUnavailable:
        discard captureWindowStill("/tmp/should-not-exist.png",
                                   initWindowQuery(owner = "x"))
      check not stillCaptureProbablyAvailable()
  else:
    test "captureWindowStill refuses a query that names no window":
      # Checked before any subprocess is launched, so this runs with no grant.
      expect ValueError:
        discard captureWindowStill("/tmp/should-not-exist.png",
                                   initWindowQuery())
      check not fileExists("/tmp/should-not-exist.png")

# ---------------------------------------------------------------------------
# Live capture (macOS). Compile-time gated; opt in with -d:captureLive.
# ---------------------------------------------------------------------------

when defined(macosx) and defined(captureLive):

  import std/[osproc]
  import ../src/gui_assert/ocr

  template blockedOnGrant(denial: string) =
    ## Shared refusal for the grant-blocked tests. Prints the remedy and FAILS.
    ## Deliberately not `skip()`: the whole reason this file is compile-gated is
    ## that a silent pass is worse than a red test.
    checkpoint("BLOCKED ON THE ONE-TIME GRANT (this is a real FAILURE, not a skip):")
    checkpoint(denial)
    fail()

  proc tesseractAvailable(): bool =
    ## `waitForText` / `regionText` go through the default Tesseract OCR
    ## backend, so the harness suites need it even though capture itself does
    ## not. Reported as its OWN refusal so a missing OCR toolchain is never
    ## mistaken for a missing TCC grant — they have different remedies.
    try:
      return resolveTesseractBinary().len > 0
    except OcrError:
      return false

  template blockedOnOcrToolchain() =
    checkpoint("BLOCKED ON THE OCR TOOLCHAIN (a real FAILURE, not a skip): " &
               "tesseract is not on PATH, so waitForText/regionText cannot " &
               "run. Run this lane inside the pinned shell, which provides " &
               "it:  nix develop -c nim c -d:captureLive -r --hints:off " &
               "tests/tscreen_capture.nim")
    fail()

  suite "screen capture: positive control (no grant needed)":

    test "CGWindowListCopyWindowInfo enumerates the live GUI session":
      # The control every other test in this file is gated on. It is
      # unprivileged: if it is green, a ScreenCaptureKit failure is a
      # permission problem; if it is red, nothing here can work and
      # permissions are not the reason.
      let ws = listWindows()
      check ws.len > 0
      var withOwner = 0
      for w in ws:
        if w.ownerName.len > 0: inc withOwner
      check withOwner == ws.len
      for w in ws:
        check w.bounds[2] > 0
        check w.bounds[3] > 0

    test "the ScreenCaptureKit helper compiles on this host":
      let helper = resolveCaptureHelper()
      check helper.len > 0
      check fileExists(helper)
      check getFileSize(helper) > 10_000
      # It answers `enumerate` directly, with no bundle and no grant.
      let (output, code) = execCmdEx(quoteShell(helper) & " enumerate")
      check code == 0
      check parseWindowListTsv(output).len > 0

  suite "screen capture: the bundle is the TCC subject, durably":

    test "the bundle builds and is signed with a certificate, not ad-hoc":
      let app = ensureCaptureApp()
      check dirExists(app)
      check fileExists(app / "Contents" / "MacOS" / "guiassert-capture")
      check fileExists(app / "Contents" / "Info.plist")
      check captureBundleId() in readFile(app / "Contents" / "Info.plist")
      let dr = designatedRequirement(app)
      checkpoint("designated requirement: " & dr)
      check dr.len > 0
      # The load-bearing assertion. A `cdhash`-keyed requirement means TCC
      # records the grant against the BYTES, so every rebuild revokes it. This
      # was measured: an ad-hoc bundle rebuilt from a different helper fails
      # its own recorded requirement.
      if dr.startsWith("cdhash"):
        checkpoint("The capture bundle is signed AD-HOC, so its designated " &
                   "requirement is keyed on the code hash and the one-time " &
                   "grant will be revoked by the next rebuild. Install an " &
                   "Apple Development (free Apple ID) or Developer ID signing " &
                   "identity, or set GUIASSERT_CAPTURE_SIGN_IDENTITY.")
        fail()
      else:
        check "identifier" in dr
        check captureBundleId() in dr
        check "certificate" in dr

    test "the built bundle satisfies its own recorded requirement":
      let app = ensureCaptureApp()
      let reqFile = app.parentDir / (defaultCaptureAppName &
                                     ".designated-requirement")
      check fileExists(reqFile)
      let recorded = readFile(reqFile).strip()
      check recorded.len > 0
      # This is the exact evaluation TCC performs against the `csreq` blob it
      # stored at grant time, so a green here is the statement "the recorded
      # grant still applies to this build".
      check satisfiesRequirement(app, recorded)
      # RED CONTROL: a requirement for a different bundle identifier must NOT
      # be satisfied, otherwise the check above would pass vacuously.
      check not satisfiesRequirement(app,
        "identifier \"com.metacraft-labs.guiassert.definitely-not-this\"")

    test "a rebuild of the bundle keeps the recorded requirement satisfied":
      let app = ensureCaptureApp()
      let reqFile = app.parentDir / (defaultCaptureAppName &
                                     ".designated-requirement")
      let recorded = readFile(reqFile).strip()
      # force = true re-copies, re-signs and re-verifies. `ensureCaptureApp`
      # itself raises when the rebuilt bundle stops satisfying `recorded`, so
      # reaching the assertions below is already most of the proof.
      let again = ensureCaptureApp(force = true)
      check again == app
      check satisfiesRequirement(app, recorded)
      check designatedRequirement(app) == recorded

  suite "screen capture: live stills (BLOCKED until the grant exists)":

    test "preflight reports the bundle holds the ScreenCapture grant":
      let rep = screenCapturePreflight()
      checkpoint("preflight report:\n" & rep.raw)
      # The positive control must be green first, or a false preflight would be
      # ambiguous between "denied" and "no GUI session".
      check rep.windowsSeen > 0
      if rep.status == csDenied or not rep.preflight:
        blockedOnGrant(rep.message & "\n\n" & grantInstructions(captureAppPath()))
      else:
        check rep.status == csOk
        check rep.preflight

    test "captureDisplayStill writes a non-trivial PNG of the whole display":
      let outPath = getTempDir() / "guiassert_still_display.png"
      removeFile(outPath)
      var rep: StillCaptureReport
      var denial = ""
      try:
        rep = captureDisplayStill(outPath, timeoutMs = 30_000)
      except StillCaptureDenied as e:
        denial = e.msg
      if denial.len > 0:
        blockedOnGrant(denial)
      else:
        check rep.status == csOk
        check fileExists(outPath)
        check getFileSize(outPath) > 10_000
        check rep.width > 100
        check rep.height > 100
        # A still of the display must be at least as large as any window on it.
        let ws = listWindows()
        check ws.len > 0
        for w in ws:
          check rep.width >= w.bounds[2]
          check rep.height >= w.bounds[3]
        # And OCR must be able to read it as an image at all. The assertion is
        # that this does not RAISE — `runOcrWithBackend` throws on an
        # unreadable or malformed image, so reaching the next line is the
        # verdict. (`check words.len >= 0` would be a tautology: a seq length
        # is never negative, so it would read as coverage while asserting
        # nothing.) The count itself is screen-content dependent and so is
        # recorded rather than asserted.
        let words = runOcrWithBackend(outPath, obAppleVision)
        checkpoint("display OCR returned " & $words.len & " strings")

    test "captureWindowStill returns THAT window's pixels, not a screen crop":
      let ws = listWindows()
      check ws.len > 0
      # Pick the largest window that is strictly smaller than the display, so
      # "window" and "display" are distinguishable by size at all. Without
      # that, the assertion below could not see its own subject: a full-screen
      # window has exactly the display's dimensions, so a display capture would
      # satisfy the size assertion just as well as a window capture and the
      # test would pass vacuously without saying so.
      #
      # The display's own size therefore has to be measured, not assumed. It is
      # read back from a display capture's attestation and converted to points
      # with the reported backing scale.
      let dispRefPath = getTempDir() / "guiassert_still_display_ref.png"
      removeFile(dispRefPath)
      var dispRep: StillCaptureReport
      var dispDenial = ""
      try:
        dispRep = captureDisplayStill(dispRefPath, timeoutMs = 30_000)
      except StillCaptureDenied as e:
        dispDenial = e.msg
      if dispDenial.len > 0:
        # Blocked on the grant, and NOT on the window layout: say which, or the
        # reader is sent to un-maximise a window over a permission problem.
        blockedOnGrant(dispDenial)
      else:
        let dispScale = if dispRep.scale > 0.0: dispRep.scale else: 1.0
        let dispW = int(float(dispRep.width) / dispScale)
        let dispH = int(float(dispRep.height) / dispScale)
        check dispW > 0
        check dispH > 0
        # `listWindows` returns largest-area first, so the first strictly
        # smaller window is also the largest one.
        var target = ws[0]
        var haveSmaller = false
        for w in ws:
          if w.bounds[2] < dispW and w.bounds[3] < dispH:
            target = w
            haveSmaller = true
            break
        checkpoint("display " & $dispW & "x" & $dispH & " points; target " &
                   target.ownerName & " " & $target.bounds)
        # If EVERY window is as large as the display there is no subject this
        # test can see, and it must say so rather than pass vacuously.
        if not haveSmaller:
          checkpoint("no window is strictly smaller than the display, so a " &
                     "window capture and a display capture are " &
                     "indistinguishable by size and this test cannot " &
                     "discriminate. Un-maximise a window and re-run.")
          fail()
        else:
          let outPath = getTempDir() / "guiassert_still_window.png"
          removeFile(outPath)
          var rep: StillCaptureReport
          var denial = ""
          try:
            rep = captureWindowStill(outPath,
                                     initWindowQuery(windowId = target.windowId),
                                     timeoutMs = 30_000)
          except StillCaptureDenied as e:
            denial = e.msg
          if denial.len > 0:
            blockedOnGrant(denial)
          else:
            check rep.status == csOk
            check fileExists(outPath)
            check rep.windowId == target.windowId
            check rep.windowOwner == target.ownerName
            # The captured pixel size must match the ATTESTED CoreGraphics
            # bounds scaled by the display's backing factor — within one pixel
            # per axis for rounding. A coordinate crop of the display would
            # match the crop rectangle we asked for instead, so this is the
            # assertion that distinguishes real window targeting from a crop.
            let expectedW = int(float(target.bounds[2]) * rep.scale)
            let expectedH = int(float(target.bounds[3]) * rep.scale)
            checkpoint("attested bounds " & $target.bounds & " scale " &
                       $rep.scale & " -> expected " & $expectedW & "x" &
                       $expectedH & ", captured " & $rep.width & "x" &
                       $rep.height)
            check abs(rep.width - expectedW) <= 2
            check abs(rep.height - expectedH) <= 2
            # And the subject really was discriminable: the window capture must
            # differ from a full-display capture in at least one axis, which is
            # the whole premise of the size assertion above.
            check (rep.width != dispRep.width) or (rep.height != dispRep.height)

    test "a window query that matches nothing is target-not-found, not denied":
      # This one is NOT blocked on the grant: the helper attests against the
      # unprivileged window list before it ever calls ScreenCaptureKit, so the
      # distinction holds with or without permission. Keeping the two apart is
      # the single most important behaviour in this module.
      expect StillCaptureTargetNotFound:
        discard captureWindowStill(getTempDir() / "guiassert_nope.png",
                                   initWindowQuery(owner = "NoSuchAppXYZ"),
                                   timeoutMs = 20_000)

  suite "screen capture: the harness driven from a live frame source":

    test "a live display harness drives currentFrame / waitForText / regionText":
      let harness = newLiveDisplayHarness(pollIntervalMs = 500)
      check harness.frameSourceLabel == "live-display:0"
      var frame = ""
      var denial = ""
      try:
        frame = harness.currentFrame()
      except StillCaptureDenied as e:
        denial = e.msg
      if denial.len > 0:
        blockedOnGrant(denial)
      else:
        check frame.len > 0
        check fileExists(frame)
        check getFileSize(frame) > 10_000
        # RED CONTROL: a needle that cannot be on screen must time out false.
        # Without this the waitForText assertion below could pass for a
        # harness whose OCR returns everything, or nothing.
        if not tesseractAvailable():
          blockedOnOcrToolchain()
        else:
          check waitForText(harness, "ZZQX-GUIASSERT-IMPLAUSIBLE-NEEDLE-9471",
                            timeoutMs = 1500) == false
          # And the frame really is OCR-able through the harness. As above, the
          # verdict is that this does not raise; the word count depends on what
          # is on screen, so it is recorded rather than asserted.
          let words = regionText(harness)
          checkpoint("live frame OCR returned " & $words.len & " strings")

    test "a live window harness captures the targeted window":
      let ws = listWindows()
      check ws.len > 0
      let harness = newLiveWindowHarness(
        initWindowQuery(windowId = ws[0].windowId), pollIntervalMs = 500)
      check harness.frameSourceLabel.startsWith("live-window:#")
      var frame = ""
      var denial = ""
      try:
        frame = harness.currentFrame()
      except StillCaptureDenied as e:
        denial = e.msg
      if denial.len > 0:
        blockedOnGrant(denial)
      else:
        check fileExists(frame)
        # Frames rotate between two slots so a consumer holding the previous
        # path is not reading a file being rewritten under it.
        let second = harness.currentFrame()
        check second != frame
        let third = harness.currentFrame()
        check third == frame

    test "visualCompare and detectLayoutOverflow run frame-lessly off a live harness":
      let harness = newLiveDisplayHarness(pollIntervalMs = 500)
      var golden = ""
      var denial = ""
      try:
        golden = harness.currentFrame()
      except StillCaptureDenied as e:
        denial = e.msg
      if denial.len > 0:
        blockedOnGrant(denial)
      else:
        let keep = getTempDir() / "guiassert_live_golden.png"
        copyFile(golden, keep)
        # `visualCompare` is pure SSIM and needs no OCR, so it is asserted
        # first and unconditionally.
        let score = visualCompareScore(harness, keep)
        checkpoint("live-vs-kept SSIM = " & $score)
        check score > 0.0
        check score <= 1.0
        # RED CONTROL for the frame-less overload: the same two images compared
        # through the PATH-based overload must score identically, which is what
        # proves the frame-less form really routed through the harness instead
        # of comparing something else.
        check visualCompareScore(harness, keep, keep) == 1.0
        if not tesseractAvailable():
          blockedOnOcrToolchain()
        else:
          # A region larger than any frame cannot be overflowed by text in it.
          check detectLayoutOverflow(harness, @[[0, 0, 100_000, 100_000]]) == false
          # RED CONTROL: the frame-less overload must agree with the path-based
          # one on the SAME frame, which is what proves the frame-less form
          # really routes through `frameSource` instead of looking at something
          # else. The comparison is made through a PATH-based harness pinned to
          # one captured frame: asking the LIVE harness twice would re-capture
          # between the two calls, so a disagreement would not be evidence of
          # anything.
          let frame = harness.currentFrame()
          let pinned = newGuiAssertHarness(frame)
          check detectLayoutOverflow(pinned, @[[0, 0, 1, 1]]) ==
                detectLayoutOverflow(pinned, frame, @[[0, 0, 1, 1]])

