## VU5 tests for the token-efficient agent index + the gui-assert-vision CLI.
##
## Mocking policy (per the workspace "mock as little as possible" policy):
##   * The pure tests (`test_cli_arg_parse`, `test_text_diff`,
##     `test_build_index_shape`, `test_find_in_index`) exercise the pure procs
##     (`parseVisionArgs`, `textDiff`, `buildIndex`, `findInIndex`) against
##     in-memory / hand-built fixtures with NO subprocess and NO filesystem.
##   * `e2e_cli_analyze_and_find` mocks NOTHING: it generates a real 2-state mp4
##     with the real ffmpeg binary, compiles the REAL CLI (`nim c` into a temp
##     dir), then runs the compiled binary end-to-end against the fixture with
##     real ffmpeg + real tesseract. No media is committed and no subprocess is
##     stubbed. The fixture generator is the same one used by tvideo_analysis.

import std/[unittest, os, osproc, streams, strtabs, strutils, tempfiles, json]

import ../src/gui_assert_vision
import ../src/gui_assert/video_analysis
import ../src/gui_assert/ocr

# ---------------------------------------------------------------------------
# Fixture helpers (shared shape with tvideo_analysis)
# ---------------------------------------------------------------------------

proc resolveFfmpegForFixture(): string =
  let envBin = getEnv("FFMPEG")
  if envBin.len > 0 and fileExists(envBin):
    return envBin
  let envBin2 = getEnv("FFMPEG_BIN")
  if envBin2.len > 0 and fileExists(envBin2):
    return envBin2
  result = findExe("ffmpeg")
  doAssert result.len > 0, "ffmpeg not found (set FFMPEG or add to PATH)"

proc ffmpegSupportsDrawtext(ffmpeg: string): bool =
  let (output, _) = execCmdEx(ffmpeg & " -hide_banner -filters")
  result = output.contains("drawtext")

proc sanitizedEnvFor(binPath: string): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if (k == "DYLD_LIBRARY_PATH" or k == "DYLD_FALLBACK_LIBRARY_PATH") and
       binPath.startsWith("/nix/"):
      continue
    result[k] = v

proc generateTwoStateVideo(ffmpeg, outPath: string, useDrawtext: bool) =
  ## Build a ~3s mp4: ~1.5s red (labelled ALPHA) then ~1.5s blue (labelled
  ## BETA), concatenated via lavfi concat. 8 fps.
  let redSrc = "color=c=red:s=320x240:d=1.5:r=8"
  let blueSrc = "color=c=blue:s=320x240:d=1.5:r=8"
  var filter: string
  if useDrawtext:
    filter =
      "[0:v]drawtext=text='ALPHA':fontcolor=white:fontsize=48:" &
      "x=(w-text_w)/2:y=(h-text_h)/2[a];" &
      "[1:v]drawtext=text='BETA':fontcolor=white:fontsize=48:" &
      "x=(w-text_w)/2:y=(h-text_h)/2[b];" &
      "[a][b]concat=n=2:v=1:a=0[v]"
  else:
    filter = "[0:v][1:v]concat=n=2:v=1:a=0[v]"
  let args = @[
    "-hide_banner", "-loglevel", "error", "-y",
    "-f", "lavfi", "-i", redSrc,
    "-f", "lavfi", "-i", blueSrc,
    "-filter_complex", filter,
    "-map", "[v]",
    "-c:v", "libx264", "-pix_fmt", "yuv420p",
    outPath
  ]
  let p = startProcess(command = ffmpeg, args = args,
                       env = sanitizedEnvFor(ffmpeg),
                       options = {poStdErrToStdOut})
  let output = p.outputStream().readAll()
  let code = p.waitForExit()
  p.close()
  doAssert code == 0, "fixture ffmpeg failed (" & $code & "): " & output
  doAssert fileExists(outPath) and getFileSize(outPath) > 0,
    "fixture produced no file"

proc runProc(bin: string, args: seq[string]): tuple[output: string, code: int] =
  ## Run a subprocess (inheriting this process's environment, incl. FFMPEG /
  ## FFPROBE / TESSERACT_BIN) and capture stdout+stderr merged.
  let p = startProcess(command = bin, args = args, options = {poStdErrToStdOut})
  let output = p.outputStream().readAll()
  let code = p.waitForExit()
  p.close()
  (output, code)

# ---------------------------------------------------------------------------
# Hand-built analysis fixture for the pure index tests
# ---------------------------------------------------------------------------

proc mkWord(text: string, x, y, w, h: int, blockNum, lineNum: int): OcrWord =
  result.text = text
  result.confidence = 91.0
  result.bbox = [x, y, w, h]
  result.blockNum = blockNum
  result.lineNum = lineNum

proc buildFixtureAnalysis(): VideoAnalysis =
  result.info = VideoInfo(path: "/tmp/demo.mp4", durationS: 3.0,
                          width: 640, height: 480)
  var f0: Keyframe
  f0.index = 0
  f0.tStart = 0.0
  f0.tEnd = 1.5
  f0.changeScore = 1.0
  f0.imagePath = "/tmp/kf/state_00000.png"
  f0.words = @[
    mkWord("Home", 10, 10, 40, 18, 0, 0),
    mkWord("page", 55, 10, 40, 18, 0, 0),
  ]
  f0.text = "Home page\nhttp://127.0.0.1:5000"
  f0.urls = @["http://127.0.0.1:5000"]
  var f1: Keyframe
  f1.index = 1
  f1.tStart = 1.5
  f1.tEnd = 3.0
  f1.changeScore = 0.83
  f1.imagePath = "/tmp/kf/state_00001.png"
  f1.words = @[
    mkWord("BETA", 120, 90, 88, 40, 0, 0),
    mkWord("Docs", 10, 150, 50, 18, 1, 0),
  ]
  f1.text = "BETA\nDocs 127.0.0.1:8080/docs/index.html"
  f1.urls = @["127.0.0.1:8080/docs/index.html"]
  result.frames = @[f0, f1]

# ---------------------------------------------------------------------------
# Pure: CLI argument parsing
# ---------------------------------------------------------------------------

suite "vision cli pure":
  test "test_cli_arg_parse":
    # analyze, default out
    block:
      let c = parseVisionArgs(@["analyze", "v.mp4"])
      check c.kind == vcAnalyze
      check c.anVideo == "v.mp4"
      check c.anOut == "vision-out"
    # analyze --out DIR (both spaced and inline forms)
    block:
      let c = parseVisionArgs(@["analyze", "v.mp4", "--out", "out-dir"])
      check c.kind == vcAnalyze
      check c.anOut == "out-dir"
      let c2 = parseVisionArgs(@["analyze", "--out=od", "v.mp4"])
      check c2.anVideo == "v.mp4"
      check c2.anOut == "od"
    # find, substring vs regex
    block:
      let c = parseVisionArgs(@["find", "BETA", "idx.json"])
      check c.kind == vcFind
      check c.fnQuery == "BETA"
      check c.fnTarget == "idx.json"
      check c.fnRegex == false
      let c2 = parseVisionArgs(@["find", "B.TA", "v.mp4", "--regex"])
      check c2.fnRegex == true
      check c2.fnTarget == "v.mp4"
    # extract-frame --at
    block:
      let c = parseVisionArgs(@["extract-frame", "v.mp4", "--at", "1.5"])
      check c.kind == vcExtractFrame
      check c.exHasAt
      check not c.exHasSeg
      check abs(c.exAt - 1.5) < 1e-9
      check c.exOut == ""
    # extract-frame --segment ID --out PNG
    block:
      let c = parseVisionArgs(
        @["extract-frame", "v.mp4", "--segment", "2", "--out", "f.png"])
      check c.exHasSeg
      check not c.exHasAt
      check c.exSeg == 2
      check c.exOut == "f.png"
    # contact-sheet --cols N --out PNG
    block:
      let c = parseVisionArgs(
        @["contact-sheet", "v.mp4", "--cols", "3", "--out", "cs.png"])
      check c.kind == vcContactSheet
      check c.csCols == 3
      check c.csOut == "cs.png"
      check c.csVideo == "v.mp4"
    # describe / windows
    block:
      let c = parseVisionArgs(@["describe", "img.png"])
      check c.kind == vcDescribe
      check c.dwImage == "img.png"
      let c2 = parseVisionArgs(@["windows", "img.png"])
      check c2.kind == vcWindows
      check c2.dwImage == "img.png"
    # help
    block:
      check parseVisionArgs(@["--help"]).kind == vcHelp
      check parseVisionArgs(@["help"]).kind == vcHelp

    # --- bad / missing args must be rejected ---
    expect VisionArgError: discard parseVisionArgs(@[])
    expect VisionArgError: discard parseVisionArgs(@["bogus"])
    expect VisionArgError: discard parseVisionArgs(@["analyze"])
    expect VisionArgError: discard parseVisionArgs(@["analyze", "v.mp4", "x.mp4"])
    expect VisionArgError: discard parseVisionArgs(@["analyze", "v.mp4", "--out"])
    expect VisionArgError: discard parseVisionArgs(@["find", "onlyone"])
    expect VisionArgError: discard parseVisionArgs(@["extract-frame", "v.mp4"])
    expect VisionArgError:
      discard parseVisionArgs(@["extract-frame", "v.mp4", "--at", "1", "--segment", "0"])
    expect VisionArgError:
      discard parseVisionArgs(@["extract-frame", "v.mp4", "--at", "notanum"])
    expect VisionArgError: discard parseVisionArgs(@["describe"])
    expect VisionArgError: discard parseVisionArgs(@["windows", "a.png", "b.png"])

  test "test_text_diff":
    let prev = "Home\nWelcome page\nFooter"
    let cur = "Home\nDocs\nFooter"
    let d = textDiff(prev, cur)
    # "Docs" added, "Welcome page" removed; "Home"/"Footer" unchanged (absent).
    check d.contains("+ Docs")
    check d.contains("− Welcome page")   # U+2212 removed-line prefix
    check not d.contains("Home")
    check not d.contains("Footer")
    # Added lines are listed before removed lines.
    check d.find("+ Docs") < d.find("− Welcome page")

    # Identical texts (whitespace-insensitive) -> empty diff.
    check textDiff("A\nB", "A\nB") == ""
    check textDiff("  A \n B ", "A\nB") == ""
    check textDiff("", "") == ""

    # Pure additions / pure removals.
    check textDiff("", "New line").contains("+ New line")
    check textDiff("Gone", "").contains("− Gone")

  test "test_build_index_shape":
    let a = buildFixtureAnalysis()
    let idx = buildIndex(a)

    # (1) summary — with windowTitles + urls + counts.
    check idx.hasKey("summary")
    let s = idx["summary"]
    check s["video"].getStr == "/tmp/demo.mp4"
    check s["width"].getInt == 640
    check s["height"].getInt == 480
    check s["frameCount"].getInt == 2
    check s["stateCount"].getInt == 2
    check s.hasKey("windowTitles")
    check s["windowTitles"].len == 2         # "Home page" and "BETA"
    var titles: seq[string] = @[]
    for t in s["windowTitles"]: titles.add(t.getStr)
    check "Home page" in titles
    check "BETA" in titles
    check s.hasKey("urls")
    var urls: seq[string] = @[]
    for u in s["urls"]: urls.add(u.getStr)
    check "http://127.0.0.1:5000" in urls
    check "127.0.0.1:8080/docs/index.html" in urls
    check urls.len == 2

    # (2) segments — one per state, each with a textDiffVsPrev.
    check idx.hasKey("segments")
    check idx["segments"].len == 2
    for seg in idx["segments"]:
      check seg.hasKey("id")
      check seg.hasKey("start")
      check seg.hasKey("end")
      check seg.hasKey("changeScore")
      check seg.hasKey("thumbnail")
      check seg.hasKey("text")
      check seg.hasKey("urls")
      check seg.hasKey("textDiffVsPrev")
    check idx["segments"][0]["id"].getInt == 0
    check idx["segments"][1]["id"].getInt == 1
    check idx["segments"][1]["thumbnail"].getStr == "/tmp/kf/state_00001.png"
    # State 1's diff vs state 0 introduces "BETA" and "Docs …".
    let diff1 = idx["segments"][1]["textDiffVsPrev"].getStr
    check diff1.len > 0
    check diff1.contains("+ BETA")

    # (3) textIndex — flat, one entry per OCR word, fully populated.
    check idx.hasKey("textIndex")
    check idx["textIndex"].len == 4          # 2 words in each of 2 frames
    var foundBeta = false
    for e in idx["textIndex"]:
      check e.hasKey("text")
      check e.hasKey("confidence")
      check e.hasKey("bbox")
      check e["bbox"].len == 4
      check e.hasKey("segmentId")
      check e.hasKey("timestamp")
      if e["text"].getStr == "BETA":
        foundBeta = true
        check e["segmentId"].getInt == 1
        check abs(e["timestamp"].getFloat - 1.5) < 1e-9
        check e["bbox"][0].getInt == 120
        check e["bbox"][1].getInt == 90
        check e["bbox"][2].getInt == 88
        check e["bbox"][3].getInt == 40
    check foundBeta

  test "test_find_in_index":
    let idx = buildIndex(buildFixtureAnalysis())

    # Substring, case-insensitive: "beta" locates the BETA word.
    let hits = findInIndex(idx, "beta")
    check hits.len == 1
    check hits[0]["text"].getStr == "BETA"
    check hits[0]["segmentId"].getInt == 1
    check abs(hits[0]["timestamp"].getFloat - 1.5) < 1e-9
    check hits[0]["bbox"][0].getInt == 120
    check hits[0].hasKey("confidence")

    # A word in the first state resolves to timestamp 0 / segment 0.
    let homeHits = findInIndex(idx, "home")
    check homeHits.len == 1
    check homeHits[0]["segmentId"].getInt == 0
    check abs(homeHits[0]["timestamp"].getFloat - 0.0) < 1e-9

    # Absent query -> empty.
    check findInIndex(idx, "nonexistent-zzz").len == 0

    # Regex mode.
    let rxHits = findInIndex(idx, "B.TA", regex = true)
    check rxHits.len == 1
    check rxHits[0]["text"].getStr == "BETA"
    check findInIndex(idx, "^Docs$", regex = true).len == 1

# ---------------------------------------------------------------------------
# End-to-end: compile + run the real CLI on a real fixture video
# ---------------------------------------------------------------------------

suite "vision cli e2e":
  test "e2e_cli_analyze_and_find":
    let ffmpeg = resolveFfmpegForFixture()
    check ffmpegSupportsDrawtext(ffmpeg)   # OCR labels need real drawtext

    let tmp = createTempDir("tvision_cli_e2e_", "")
    defer: removeDir(tmp)

    # 1. Generate the 2-state fixture video with real ffmpeg.
    let fixture = tmp / "two_state.mp4"
    generateTwoStateVideo(ffmpeg, fixture, useDrawtext = true)

    # 2. Compile the real CLI into the temp dir.
    let nimExe = findExe("nim")
    check nimExe.len > 0
    let cliSrc = currentSourcePath().parentDir.parentDir /
      "src" / "gui_assert_vision.nim"
    check fileExists(cliSrc)
    let cliBin = tmp / "gui_assert_vision"
    let (buildOut, buildCode) = runProc(nimExe,
      @["c", "--hints:off", "--warnings:off", "-o:" & cliBin, cliSrc])
    check buildCode == 0
    check fileExists(cliBin)
    if buildCode != 0:
      echo buildOut

    # 3. analyze -> writes a valid 3-level index.json with >= 2 states.
    let outDir = tmp / "out"
    let (anOut, anCode) = runProc(cliBin, @["analyze", fixture, "--out", outDir])
    check anCode == 0
    if anCode != 0: echo anOut
    let indexPath = outDir / "index.json"
    check fileExists(indexPath)
    check fileExists(outDir / "digest.md")
    let index = parseJson(readFile(indexPath))
    check index.hasKey("summary")
    check index.hasKey("segments")
    check index.hasKey("textIndex")
    check index["summary"]["stateCount"].getInt >= 2
    check index["segments"].len >= 2
    check index["textIndex"].len > 0

    # The 2nd state's start timestamp, read from the index.
    let secondStart = index["segments"][1]["start"].getFloat

    # 4. find BETA -> returns the 2nd state's timestamp / segment.
    let (findOut, findCode) = runProc(cliBin,
      @["find", "BETA", indexPath])
    check findCode == 0
    var matchedBeta = false
    for line in findOut.splitLines:
      let ln = line.strip()
      if ln.len == 0 or ln[0] != '{': continue
      let m = parseJson(ln)
      if m["text"].getStr.toUpperAscii.contains("BETA"):
        matchedBeta = true
        check m["segmentId"].getInt == 1
        check abs(m["timestamp"].getFloat - secondStart) < 1e-6
    check matchedBeta

    # 5. extract-frame --at <t> -> emits exactly one non-empty PNG.
    let onePng = tmp / "one.png"
    let (exOut, exCode) = runProc(cliBin,
      @["extract-frame", fixture, "--at", $secondStart, "--out", onePng])
    check exCode == 0
    if exCode != 0: echo exOut
    check fileExists(onePng)
    check getFileSize(onePng) > 0
