## Real macOS helper/report-transport regressions. No mocks: query checks run
## the compiled Swift helper against the live window server and inspect its
## actual TSV before Nim can filter it. Transport checks launch the signed app
## through LaunchServices. No screen-recording grant is needed: enumeration and
## preflight work without it, and target-not-found precedes permission checks.
## Run: nix develop --command just test-capture-reports-macos
## Temporary protocol data is confined to, and removed with, this test's directory.
import std/[os, osproc, strutils, tempfiles, unittest]
import ../src/gui_assert/screen_capture

when defined(macosx):
  let helper = resolveCaptureHelper()
  echo "Capture helper: ", helper
  let scratch = createTempDir("gui_assert_report_test_", "")
  let oldTmp = getEnv("TMPDIR")
  let oldHelper = getEnv("GUIASSERT_CAPTURE_HELPER")
  putEnv("GUIASSERT_CAPTURE_HELPER", helper)
  putEnv("TMPDIR", scratch)

  proc residue(): seq[string] =
    for kind, path in walkDir(scratch):
      if path.extractFilename.startsWith("gui_assert_capture_"):
        result.add(path.extractFilename)

  proc enumerate(q: WindowQuery, tag: string): seq[WindowInfo] =
    let path = scratch / (tag & ".txt")
    let args = buildHelperArgv("enumerate", q = q, reportPath = path)
    let (output, code) = execCmdEx(quoteShellCommand(@[helper] & args))
    doAssert code == 0
    let report = parseCaptureReport(readFile(path))
    doAssert report.windowsSeen > 0  # A dead desktop cannot satisfy exclusion tests.
    doAssert report.status == csOk
    result = parseWindowListTsv(readFile(path & ".tsv"))
    let stdoutWindows = parseWindowListTsv(output)
    doAssert stdoutWindows.len == result.len
    for j in 0 ..< result.len:
      doAssert stdoutWindows[j].windowId == result[j].windowId

  try:
    suite "screen capture: temporary report transport":
      test "the helper filters before serializing any window TSV":
        let all = enumerate(initWindowQuery(), "all")
        require all.len > 0
        let target = all[0]
        let queries = @[
          initWindowQuery(owner = "GuiAssert-no-such-owner-83a6197"),
          initWindowQuery(windowId = high(int32).int),
          initWindowQuery(title = "GuiAssert-no-such-title-83a6197"),
          initWindowQuery(titleContains = "GuiAssert-no-such-title-83a6197"),
          initWindowQuery(windowId = target.windowId),
          initWindowQuery(owner = target.ownerName.toUpperAscii),
          initWindowQuery(windowId = target.windowId,
                          owner = "GuiAssert-no-such-owner-83a6197")]
        for i, q in queries:
          let actual = enumerate(q, "query" & $i)
          let expected = matchWindows(all, q)
          check actual.len == expected.len
          for j in 0 ..< min(actual.len, expected.len):
            check actual[j].windowId == expected[j].windowId

      test "public calls remove reports and their directory before returning or raising":
        discard screenCapturePreflight()
        check residue() == newSeq[string]()
        let ws = listWindows(viaApp = true)
        require ws.len > 0
        check residue() == newSeq[string]()
        check listWindows(initWindowQuery(owner = "GuiAssert-no-such-owner-83a6197"),
                          viaApp = true).len == 0
        check residue() == newSeq[string]()
        expect StillCaptureTargetNotFound:
          discard captureWindowStill(scratch / "never.png",
            initWindowQuery(owner = "GuiAssert-no-such-owner-83a6197"))
        check not fileExists(scratch / "never.png")
        check residue() == newSeq[string]()
        let oldApp = getEnv("GUIASSERT_CAPTURE_APP")
        putEnv("GUIASSERT_CAPTURE_APP", scratch / "absent.app")
        try:
          expect StillCaptureUnavailable:
            discard screenCapturePreflight()
          check residue() == newSeq[string]()
          expect StillCaptureUnavailable:
            discard requestScreenCaptureAccess()
          check residue() == newSeq[string]()
          expect StillCaptureUnavailable:
            discard captureDisplayStill(scratch / "unavailable-display.png")
          check residue() == newSeq[string]()
          expect StillCaptureUnavailable:
            discard captureWindowStill(scratch / "unavailable-window.png",
              initWindowQuery(owner = "GuiAssert-no-such-owner-83a6197"))
          check residue() == newSeq[string]()
        finally:
          if oldApp.len == 0: delEnv("GUIASSERT_CAPTURE_APP")
          else: putEnv("GUIASSERT_CAPTURE_APP", oldApp)
  finally:
    if oldTmp.len == 0: delEnv("TMPDIR")
    else: putEnv("TMPDIR", oldTmp)
    if oldHelper.len == 0: delEnv("GUIASSERT_CAPTURE_HELPER")
    else: putEnv("GUIASSERT_CAPTURE_HELPER", oldHelper)
    removeDir(scratch)
else:
  {.error: "tscreen_capture_reports requires the real macOS window server".}
