## VU1 tests for gui_assert/video_analysis.
##
## Mocking policy: the pure procs (argv builders, JSON parse, segmentation
## core) are tested against inline fixtures with no subprocess. The e2e test
## deliberately mocks NOTHING — it generates a real 2-state mp4 with the real
## ffmpeg binary (resolved via FFMPEG / PATH) and runs the real
## `segmentByChange` pipeline (real ffmpeg frame sampling + real SSIM) against
## it, per the workspace "mock as little as possible" policy.

import std/[unittest, os, osproc, streams, strtabs, strutils, tempfiles, json]

import ../src/gui_assert/video_analysis
import ../src/gui_assert/ocr

# ---------------------------------------------------------------------------
# Helpers for the e2e fixture
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
  ## Probe the build for the drawtext filter (needs libfreetype). If absent we
  ## fall back to plain solid colours.
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
  ## Build a ~3s mp4: ~1.5s of red (labelled ALPHA) then ~1.5s of blue
  ## (labelled BETA), concatenated via the lavfi concat filter. 8 fps.
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
  let p = startProcess(
    command = ffmpeg,
    args = args,
    env = sanitizedEnvFor(ffmpeg),
    options = {poStdErrToStdOut}
  )
  let output = p.outputStream().readAll()
  let code = p.waitForExit()
  p.close()
  doAssert code == 0, "fixture ffmpeg failed (" & $code & "): " & output
  doAssert fileExists(outPath) and getFileSize(outPath) > 0,
    "fixture produced no file"

# ---------------------------------------------------------------------------
# Pure procs
# ---------------------------------------------------------------------------

suite "video_analysis pure":
  test "test_parse_probe_json":
    let sample = """
      {
        "streams": [ { "width": 1600, "height": 900 } ],
        "format": { "duration": "49.72" }
      }
    """
    let info = parseProbeJson(sample)
    check info.width == 1600
    check info.height == 900
    check abs(info.durationS - 49.72) < 0.001

    # duration may also arrive as a JSON number.
    let numeric = """{"streams":[{"width":640,"height":480}],
      "format":{"duration":12.5}}"""
    let info2 = parseProbeJson(numeric)
    check info2.width == 640
    check info2.height == 480
    check abs(info2.durationS - 12.5) < 0.001

  test "test_segment_boundaries":
    # ssims[i] = SSIM(frame i, frame i+1); boundary at i+1 when 1-ssim>thr.
    let ssims = @[0.99, 0.98, 0.30, 0.99, 0.40]
    check segmentBoundaries(ssims, 0.12) == @[0, 3, 5]

    # An all-similar series collapses to a single segment.
    check segmentBoundaries(@[0.99, 0.98, 0.99], 0.12) == @[0]

    # A high threshold swallows even the big drops -> one segment.
    check segmentBoundaries(ssims, 0.9) == @[0]

    # A very low threshold makes every transition a boundary.
    check segmentBoundaries(ssims, 0.001) == @[0, 1, 2, 3, 4, 5]

    # An empty series (one frame) is still one segment.
    check segmentBoundaries(@[], 0.12) == @[0]

  test "test_build_argv_shapes":
    let probe = buildProbeArgv("/tmp/in.mp4")
    check "/tmp/in.mp4" in probe
    check "-of" in probe
    check "json" in probe

    let sample = buildSampleFramesArgv("/tmp/in.mp4", 2.0, 320,
      "/tmp/out/f_%05d.png")
    check "/tmp/in.mp4" in sample
    check "/tmp/out/f_%05d.png" in sample
    var hasFps = false
    var hasScale = false
    for a in sample:
      if a.contains("fps="): hasFps = true
      if a.contains("scale="): hasScale = true
    check hasFps
    check hasScale

    let extract = buildExtractFrameArgv("/tmp/in.mp4", 1.5, "/tmp/frame.png")
    check "-ss" in extract
    check "/tmp/frame.png" in extract
    check "/tmp/in.mp4" in extract

# ---------------------------------------------------------------------------
# End-to-end against real ffmpeg
# ---------------------------------------------------------------------------

suite "video_analysis e2e":
  test "e2e_segment_two_state_video":
    let ffmpeg = resolveFfmpegForFixture()
    let tmp = createTempDir("tvideo_e2e_", "")
    defer: removeDir(tmp)
    let fixture = tmp / "two_state.mp4"
    let useDrawtext = ffmpegSupportsDrawtext(ffmpeg)
    generateTwoStateVideo(ffmpeg, fixture, useDrawtext)

    # Sanity: ffprobe reports a ~3s clip.
    let info = probeVideo(fixture)
    check info.width > 0
    check info.height > 0
    check abs(info.durationS - 3.0) < 0.6

    let segments = segmentByChange(fixture)
    # Exactly two distinct states.
    check segments.len == 2
    # The second segment must begin near the 1.5s colour switch (±0.5s).
    check abs(segments[1].tStart - 1.5) < 0.5
    # The entering change score of the second state should be substantial.
    check segments[1].changeScore > 0.12
    # The first segment starts at 0 with a full change score by convention.
    check segments[0].tStart == 0.0
    check segments[0].changeScore == 1.0

# ---------------------------------------------------------------------------
# VU2 pure procs
# ---------------------------------------------------------------------------

proc mkWord(text: string, x, y: int, blockNum, lineNum: int): OcrWord =
  result.text = text
  result.confidence = 90.0
  result.bbox = [x, y, 40, 18]
  result.blockNum = blockNum
  result.lineNum = lineNum

suite "video_analysis vu2 pure":
  test "test_extract_urls":
    let noisy =
      "gatewayBaseUrl — root URL of the server, e.g. http://127.0.0.1:5000. " &
      "The client then fetches 127.0.0.1:8080/docs/index.html for the docs. " &
      "See unit 217 of CodeTracer 1.55.0 for details."
    let urls = extractUrls(noisy)
    # Both real URLs are pulled out...
    check "http://127.0.0.1:5000" in urls
    check "127.0.0.1:8080/docs/index.html" in urls
    # ...and the distractors are NOT mistaken for URLs.
    check "unit" notin urls
    check "217" notin urls
    check "1.55.0" notin urls
    check "CodeTracer" notin urls
    # The full form's embedded host:port is not double-reported as a bare URL.
    check "127.0.0.1:5000" notin urls
    check urls.len == 2

  test "test_reading_order":
    # Two lines across two blocks, words supplied out of order. Reading order
    # must be top line first (words left→right), then bottom line.
    let words = @[
      mkWord("Bar", 80, 60, 1, 0),
      mkWord("World", 100, 10, 0, 0),
      mkWord("Foo", 20, 62, 1, 0),
      mkWord("Hello", 10, 12, 0, 0),
    ]
    check wordsToReadingOrderText(words) == "Hello World\nFoo Bar"

  test "test_digest_json_shape":
    var a: VideoAnalysis
    a.info = VideoInfo(path: "/tmp/demo.mp4", durationS: 3.0,
                       width: 640, height: 480)
    var f0: Keyframe
    f0.index = 0
    f0.tStart = 0.0
    f0.tEnd = 1.5
    f0.changeScore = 1.0
    f0.imagePath = "/tmp/kf/state_00000.png"
    f0.words = @[mkWord("Home", 0, 0, 0, 0), mkWord("page", 50, 0, 0, 0)]
    f0.text = "Home page http://127.0.0.1:5000 welcome"
    f0.urls = @["http://127.0.0.1:5000"]
    var f1: Keyframe
    f1.index = 1
    f1.tStart = 1.5
    f1.tEnd = 3.0
    f1.changeScore = 0.8
    f1.imagePath = "/tmp/kf/state_00001.png"
    f1.words = @[mkWord("Docs", 0, 0, 0, 0)]
    f1.text = "Docs 127.0.0.1:8080/docs/index.html"
    f1.urls = @["127.0.0.1:8080/docs/index.html"]
    a.frames = @[f0, f1]

    # JSON: one entry per frame, every field present.
    let j = toJson(a)
    check j["info"]["path"].getStr == "/tmp/demo.mp4"
    check j["info"]["width"].getInt == 640
    check j["frames"].len == 2
    for idx in 0 ..< 2:
      let fj = j["frames"][idx]
      check fj["index"].getInt == idx
      check fj.hasKey("tStart")
      check fj.hasKey("tEnd")
      check fj.hasKey("changeScore")
      check fj.hasKey("imagePath")
      check fj.hasKey("text")
      check fj.hasKey("urls")
      check fj.hasKey("wordCount")
    check j["frames"][0]["wordCount"].getInt == 2
    check j["frames"][0]["urls"][0].getStr == "http://127.0.0.1:5000"
    check j["frames"][1]["wordCount"].getInt == 1

    # Digest: markdown timeline mentioning every state, its t-range, URL, text.
    let d = toDigest(a)
    check d.contains("/tmp/demo.mp4")
    check d.contains("640x480")
    check d.contains("State 0")
    check d.contains("State 1")
    check d.contains("0.00–1.50 s")
    check d.contains("1.50–3.00 s")
    check d.contains("http://127.0.0.1:5000")
    check d.contains("127.0.0.1:8080/docs/index.html")
    check d.contains("Home page")
    check d.contains("Docs")

# ---------------------------------------------------------------------------
# VU2 end-to-end: analyze a generated 2-state fixture with real ffmpeg+tesseract
# ---------------------------------------------------------------------------

suite "video_analysis vu2 e2e":
  test "e2e_analyze_fixture_video":
    let ffmpeg = resolveFfmpegForFixture()
    check ffmpegSupportsDrawtext(ffmpeg)  # OCR labels require real drawtext
    let tmp = createTempDir("tvideo_vu2_e2e_", "")
    defer: removeDir(tmp)
    let fixture = tmp / "two_state.mp4"
    generateTwoStateVideo(ffmpeg, fixture, useDrawtext = true)

    let analysis = analyzeVideo(fixture)
    # Exactly two distinct states, each with an extracted keyframe on disk.
    check analysis.frames.len == 2
    for f in analysis.frames:
      check fileExists(f.imagePath)
      check getFileSize(f.imagePath) > 0

    # The OCR'd label of each state (allowing OCR noise: uppercased substring).
    let t0 = analysis.frames[0].text.toUpperAscii
    let t1 = analysis.frames[1].text.toUpperAscii
    check t0.contains("ALPHA")
    check t1.contains("BETA")

# ---------------------------------------------------------------------------
# VU3 pure query / assertion API
# ---------------------------------------------------------------------------
#
# Matching rules under test (see video_analysis.nim):
#   * containsText — text-level substring over each frame's reading-order text.
#   * locateText   — word-level substring over each individual OcrWord.text.
# Both case-insensitive by default. All hand-built; no ffmpeg/tesseract.

proc mkWordWH(text: string, x, y, w, h: int, blockNum, lineNum: int): OcrWord =
  ## Like mkWord but with an explicit bbox width/height for region tests.
  result.text = text
  result.confidence = 90.0
  result.bbox = [x, y, w, h]
  result.blockNum = blockNum
  result.lineNum = lineNum

suite "video_analysis vu3 pure":
  test "test_contains_locate":
    var a: VideoAnalysis
    a.info = VideoInfo(path: "/tmp/demo.mp4", durationS: 3.0,
                       width: 640, height: 480)
    var f0: Keyframe
    f0.index = 0
    f0.words = @[mkWord("Home", 0, 0, 0, 0), mkWord("page", 50, 0, 0, 0)]
    f0.text = wordsToReadingOrderText(f0.words)   # "Home page"
    var f1: Keyframe
    f1.index = 1
    f1.words = @[mkWord("Docs", 0, 0, 0, 0), mkWord("Settings", 60, 0, 0, 0)]
    f1.text = wordsToReadingOrderText(f1.words)   # "Docs Settings"
    a.frames = @[f0, f1]

    # containsText: present text found case-insensitively; absent text false.
    check containsText(a, "home")            # lowercase needle, "Home" word
    check containsText(a, "SETTINGS")        # uppercase needle, "Settings"
    check containsText(a, "Home page")       # multi-word phrase, text-level
    check containsText(a, "Home", caseInsensitive = false)   # exact case
    check not containsText(a, "home", caseInsensitive = false)  # case matters
    check not containsText(a, "Login")       # absent
    check not containsText(a, "")            # empty needle never matches

    # locateText: right frame index + matching word for a present needle.
    let hits = locateText(a, "docs")
    check hits.len == 1
    check hits[0].frame == 1
    check hits[0].word.text == "Docs"

    # A needle present in two frames' words returns two hits with correct words.
    let sHits = locateText(a, "s")   # "page"? no. matches "Docs","Settings"
    # "s" appears in "Docs" and "Settings" only (word-level).
    check sHits.len == 2
    check sHits[0].frame == 1
    check sHits[0].word.text == "Docs"
    check sHits[1].frame == 1
    check sHits[1].word.text == "Settings"

    # Absent needle -> empty seq.
    check locateText(a, "Login").len == 0
    # Multi-word phrase does NOT match at the word level (documented rule).
    check locateText(a, "Home page").len == 0

  test "test_seen_url_and_state_count":
    var a: VideoAnalysis
    a.info = VideoInfo(path: "/tmp/demo.mp4", durationS: 3.0,
                       width: 640, height: 480)
    var f0: Keyframe
    f0.index = 0
    f0.urls = @["http://127.0.0.1:5000"]
    var f1: Keyframe
    f1.index = 1
    f1.urls = @["127.0.0.1:8080/docs/index.html"]
    a.frames = @[f0, f1]

    # seenUrl: substring present in some frame's urls -> true.
    check seenUrl(a, "127.0.0.1:5000")
    check seenUrl(a, "/docs/index.html")
    check seenUrl(a, "8080")
    # Absent substring -> false.
    check not seenUrl(a, "example.com")
    check not seenUrl(a, "9999")
    check not seenUrl(a, "")

    # distinctStateCount equals the number of frames.
    check distinctStateCount(a) == 2

  test "test_text_in_region":
    var a: VideoAnalysis
    a.info = VideoInfo(path: "/tmp/demo.mp4", durationS: 1.0,
                       width: 640, height: 480)
    var f0: Keyframe
    f0.index = 0
    # Two words at known, non-overlapping bboxes:
    #   "Save"  at [10,10,40,20]  (x:10..50,  y:10..30)
    #   "Cancel" at [200,200,60,20] (x:200..260, y:200..220)
    f0.words = @[
      mkWordWH("Save", 10, 10, 40, 20, 0, 0),
      mkWordWH("Cancel", 200, 200, 60, 20, 1, 0),
    ]
    a.frames = @[f0]

    # A rect over the "Save" word finds it.
    check textInRegion(a, 0, 0, 0, 60, 40, "Save")
    # Case-insensitive by default.
    check textInRegion(a, 0, 0, 0, 60, 40, "save")
    # A rect that overlaps "Save" but queries the wrong needle -> false.
    check not textInRegion(a, 0, 0, 0, 60, 40, "Cancel")
    # A rect over the "Cancel" word finds it (not "Save").
    check textInRegion(a, 0, 190, 190, 100, 60, "Cancel")
    check not textInRegion(a, 0, 190, 190, 100, 60, "Save")
    # A rect in an empty area intersects nothing -> false even for present text.
    check not textInRegion(a, 0, 400, 400, 50, 50, "Save")
    check not textInRegion(a, 0, 400, 400, 50, 50, "Cancel")
    # Touching-but-not-overlapping edge (rect ends exactly at x=10) -> false.
    check not textInRegion(a, 0, 0, 10, 10, 20, "Save")
    # Out-of-range frame -> false.
    check not textInRegion(a, 5, 0, 0, 640, 480, "Save")
