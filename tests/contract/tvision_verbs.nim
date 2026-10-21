## The vision verbs (spec §7.5 "Vision"): `vision-compare`, `vision-segment`
## (PNG frames and video) and `vision-windows`, run through the REAL built
## binaries as subprocesses and over the REAL `guiassert serve`.
##
## Every input is invented here: frames are drawn with the pure core's raster
## and encoded with its PNG encoder, videos are encoded from such frames (or
## from ffmpeg's own `testsrc` pattern) with the pinned ffmpeg, and the
## two-window desktop is a fixture scenario written by the test. Each result
## the CLI reports is also computed with the library API on the same input
## (`core/ssim`, `core/hashing`, `core/segmentation`, `core/vision_windows`,
## and the media backend's `segmentVideo`), and the two must be equal: the
## verbs are the library, serialized.
##
## Media-backend behaviour is checked against the build that has it
## (`guiassert`) and the refusal against the build that has not
## (`guiassert-fixture`), whichever of the two the suite runs against: the
## other is taken from beside it (`siblingBin`), so each run covers both.
##
## Stand-ins: the fixture backend (spec §9.2) is the only one. It draws the
## two-window frame (`screenshot`) and is the OCR engine of `vision-windows
## --ocr`: it is the one OCR engine whose words are known exactly, because it
## reads back the words it drew. The vision maths below it is the real core.
##
## One more stand-in, on POSIX only: `test_vision_segment_frame_size_cap_is_
## refused_before_decoding` points `FFMPEG_BIN` at a two-line shell script
## that records its own name and then `exec`s the real ffmpeg (and one beside
## it for ffprobe). The pinned tools still do all the work; the record is the
## only way to observe from outside that the refusal came before ffmpeg was
## started, not after a decode or an allocation.

import std/[algorithm, json, options, os, osproc, sequtils, streams, strtabs, strutils, unittest,
            times, monotimes]

import ./harness
import ../../src/gui_assert/core/[image, geometry, raster, png, ssim, hashing,
                                  segmentation, vision_windows]
import ../../src/gui_assert/backends/media/ffmpeg as media_ffmpeg
from ../../src/gui_assert/backends/fixture_desktop import builtinScenarioJson

# ---------------------------------------------------------------------------
# Invented inputs
# ---------------------------------------------------------------------------

proc patternFrame(w, h: int): RgbImage =
  ## A textured frame (a diagonal gradient with a few panels), so SSIM has
  ## structure to compare rather than a flat field.
  result = newImage(RgbImage, w, h)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let v = (x * 3 + y * 2) mod 160 + 40
      result.setPixel(x, y, (v, v div 2 + 30, 200 - v div 2))
  result.fillRect(rect(w div 10, h div 8, w div 4, h div 5), (230, 230, 230))
  result.fillRect(rect(w div 2, h div 2, w div 3, h div 4), (20, 60, 120))

proc withBox(img: RgbImage, r: Rect): RgbImage =
  ## `img` with a white box drawn over `r`.
  result = img
  result.fillRect(r, (255, 255, 255))

proc writePng(path: string, img: RgbImage) = writeFile(path, encodePng(img))

proc grayOf(path: string): GrayImage = decodePngGray(readFile(path))

proc ffmpegTool(): string =
  ## The pinned ffmpeg (FFMPEG_BIN, else PATH), the one the binary uses.
  result = getEnv("FFMPEG_BIN")
  if result.len == 0: result = findExe("ffmpeg")
  doAssert result.len > 0 and fileExists(result),
    "ffmpeg is needed to encode the test videos; run inside `nix develop`"

proc runFfmpeg(args: seq[string]) =
  let p = startProcess(ffmpegTool(), args = @["-hide_banner", "-loglevel", "error",
                       "-nostdin", "-y"] & args, options = {poStdErrToStdOut})
  let output = p.outputStream.readAll()
  let code = p.waitForExit()
  p.close()
  doAssert code == 0, "ffmpeg " & args.join(" ") & " failed: " & output

proc twoStateFrames(dir: string, w, h, before, after: int): RgbImage =
  ## `before` frames of the pattern, then `after` frames with a box over
  ## most of its top-left quarter, as f000.png, f001.png, … Returns the
  ## changed frame.
  createDir(dir)
  let a = patternFrame(w, h)
  let b = a.withBox(rect(w div 16, h div 16, w * 3 div 8, h * 3 div 8))
  for i in 0 ..< before + after:
    writePng(dir / ("f" & align($i, 3, '0') & ".png"), if i < before: a else: b)
  b

proc twoStateVideo(work: string): string =
  ## A 4 s, 10 fps H.264 video: 2 s of the pattern, then 2 s with the box.
  let frames = work / "src-frames"
  discard twoStateFrames(frames, 160, 120, 20, 20)
  result = work / "two-state.mp4"
  runFfmpeg(@["-framerate", "10", "-i", frames / "f%03d.png", "-c:v", "libx264",
              "-threads", "1", "-pix_fmt", "yuv420p", result])

proc twoWindowScenario(dir: string): string =
  ## The built-in scenario with its desktop replaced by two windows that have
  ## no accessibility tree, far apart on the 800x600 display.
  var n = parseJson(builtinScenarioJson)
  n["apps"] = %*[
    {"pid": 5101, "name": "Alpha", "bundleId": "dev.example.alpha", "appId": nil,
     "frontmost": true, "hidden": false, "accessible": false},
    {"pid": 5102, "name": "Beta", "bundleId": "dev.example.beta", "appId": nil,
     "frontmost": false, "hidden": false, "accessible": false}]
  n["windows"] = %*[
    {"id": "w-alpha", "pid": 5101, "app": "Alpha", "appId": nil, "title": "Alpha Notes",
     "document": nil, "bounds": [40, 50, 300, 220], "display": "fixture-display-1",
     "layer": 0, "onScreen": true, "focused": true, "minimized": false},
    {"id": "w-beta", "pid": 5102, "app": "Beta", "appId": nil, "title": "Beta Ledger",
     "document": nil, "bounds": [420, 280, 340, 260], "display": "fixture-display-1",
     "layer": 0, "onScreen": true, "focused": false, "minimized": false}]
  n["trees"] = newJArray()
  n["pointer"] = %*[790, 10]
  result = dir / "two-windows.json"
  writeFile(result, $n)

# ---------------------------------------------------------------------------
# Assertion helpers: templates, so a failed `check` fails the calling test.
# ---------------------------------------------------------------------------

template ok(args: seq[string], vars: StringTableRef, exe = ""): JsonNode =
  ## The data of a run that must succeed.
  let run = cli(args, vars, exe)
  if run.exit != 0: checkpoint args.join(" ") & " -> " & run.line
  check run.exit == 0
  (if run.exit == 0: run.env.data else: newJObject())

template failure(args: seq[string], vars: StringTableRef, code: int, kind, reason: string,
                 exe = ""): JsonNode =
  ## The error object of a run that must fail with `code` / `kind` / `reason`.
  let run = cli(args, vars, exe)
  if run.exit != code: checkpoint args.join(" ") & " -> " & run.line
  check run.exit == code
  check run.env{"ok"}.getBool(true) == false
  check run.env{"error", "kind"}.getStr == kind
  check run.env{"error", "reason"}.getStr == reason
  (if run.env.hasKey("error"): run.env["error"] else: newJObject())

template checkSegmentsEqual(reported: JsonNode, expected: seq[Segment]) =
  ## The CLI's `segments` are the library's, in order, value for value.
  check reported.len == expected.len
  if reported.len == expected.len:
    for i, s in expected:
      check reported[i]["index"].getInt == i
      check reported[i]["tStart"].getFloat == s.tStart
      check reported[i]["tEnd"].getFloat == s.tEnd
      check reported[i]["changeScore"].getFloat == s.changeScore

proc mediaBin(): string =
  ## The build with the media backend.
  if isMinimalBinary(): siblingBin("guiassert") else: contractBin()

proc minimalBin(): string =
  ## The build without it.
  if isMinimalBinary(): contractBin() else: siblingBin("guiassert-fixture")

proc msSince(start: MonoTime): int64 = (getMonoTime() - start).inMilliseconds

proc hugePng(w, h: uint32): string =
  ## A PNG whose IHDR claims `w` x `h` 8-bit gray pixels and whose image data
  ## is an empty zlib stream: a header that names a size and holds no pixels.
  proc be32(v: uint32): string =
    result = newString(4)
    for i in 0 ..< 4: result[i] = char((v shr (24 - 8 * i)) and 0xff)
  proc chunk(kind, body: string): string =
    be32(uint32(body.len)) & kind & body & be32(crc32(kind & body))
  "\x89PNG\r\n\x1a\n" & chunk("IHDR", be32(w) & be32(h) & "\x08\x00\x00\x00\x00") &
    chunk("IDAT", "\x78\x9c\x03\x00\x00\x00\x00\x01") & chunk("IEND", "")

proc recordingTools(dir: string): string =
  ## POSIX: an `ffmpeg` and an `ffprobe` in `dir` that append their own name
  ## to `dir/calls` and `exec` the pinned tool; returns the `ffmpeg` path, for
  ## `FFMPEG_BIN` (the media backend takes ffprobe from beside it).
  let real = ffmpegTool()
  let realProbe = real.parentDir / "ffprobe"
  doAssert fileExists(realProbe), "no ffprobe beside " & real
  createDir(dir)
  for (name, target) in [("ffmpeg", real), ("ffprobe", realProbe)]:
    let script = dir / name
    writeFile(script, "#!/bin/sh\necho " & name & " >> '" & dir / "calls" &
              "'\nexec '" & target & "' \"$@\"\n")
    setFilePermissions(script, {fpUserRead, fpUserWrite, fpUserExec})
  dir / "ffmpeg"

proc callsOf(dir: string): seq[string] =
  ## The tool names `recordingTools` recorded, in order.
  if fileExists(dir / "calls"): readFile(dir / "calls").splitLines.filterIt(it.len > 0)
  else: @[]

proc sparseVideo(work: string): string =
  ## A video that keeps ffmpeg busy for seconds before it writes anything at
  ## `sparseFps`: 1 000 000 tiny frames (1000 s at 1000 fps). Each costs ffmpeg
  ## a demux and a decode, and `sparseFps` samples one frame per 2000 s, more
  ## than the whole video, so ffmpeg writes its only output frame at the end:
  ## the wait for that frame is the whole decode (~10 s on an unloaded x86_64
  ## Linux host). Deterministic (`testsrc`, single-threaded x264).
  result = work / "sparse.mp4"
  runFfmpeg(@["-f", "lavfi", "-i", "testsrc=size=32x32:rate=1000:duration=1000",
              "-c:v", "libx264", "-preset", "ultrafast", "-threads", "1",
              "-pix_fmt", "yuv420p", result])

const
  sparseFps = "0.0005"
    ## The sample rate the low-fps test reads `sparseVideo` at.
  sparseQuietMs = 4000
    ## How long ffmpeg must stay silent over `sparseVideo` for the low-fps
    ## test to mean anything: about three times the largest bound it checks
    ## (1400 ms), so a wait that is not interrupted between frames is far
    ## beyond every bound while the correct one stays far below it.

suite "vision verbs":
  test "test_vision_compare_identical_is_one_and_changed_is_lower":
    let work = freshDir("vc")
    let a = patternFrame(128, 96)
    let changed = a.withBox(rect(8, 8, 40, 30))
    writePng(work / "a.png", a)
    writePng(work / "a2.png", a)
    writePng(work / "b.png", changed)
    let env = baseEnv()
    # Identical images (two files with the same pixels): 1.0 and distance 0.
    let same = ok(@["vision-compare", work / "a.png", work / "a2.png", "--tiles", "4x4"], env)
    check same["width"].getInt == 128 and same["height"].getInt == 96
    check same["ssim"].getFloat == 1.0
    check same["phashDistance"].getInt == 0
    check same["edgeChangeRatio"].getFloat == 0.0
    check same["tiles"]["grid"] == %*[4, 4]
    check same["tiles"]["values"].len == 16
    check same["tiles"]["values"].getElems.allIt(it.getFloat == 1.0)
    check same["tiles"]["min"].getFloat == 1.0
    # A drawn box: lower SSIM, and the box's tile lower still.
    let diff = ok(@["vision-compare", work / "a.png", work / "b.png", "--tiles", "4x4"], env)
    let s = diff["ssim"].getFloat
    let tmin = diff["tiles"]["min"].getFloat
    check s < 1.0
    check tmin < s
    # The box (8,8)-(48,38) touches tiles (0,0), (1,0), (0,1) and (1,1) of
    # the 32x24 grid; every other tile is unchanged, exactly 1.0, and the
    # minimum is one of the four.
    let touched = [0, 1, 4, 5]
    for i in 0 ..< 16:
      if i notin touched: check diff["tiles"]["values"][i].getFloat == 1.0
      else: check diff["tiles"]["values"][i].getFloat < 1.0
    check touched.anyIt(diff["tiles"]["values"][it].getFloat == tmin)
    check diff["edgeChangeRatio"].getFloat > 0.0
    # Without --tiles, tiles is null and the rest is unchanged.
    let plain = ok(@["vision-compare", work / "a.png", work / "b.png"], env)
    check plain["tiles"].kind == JNull
    check plain["ssim"].getFloat == s
    # The CLI reports what the library computes on the same pixels.
    let ga = grayOf(work / "a.png")
    let gb = grayOf(work / "b.png")
    check s == computeSsim(ga, gb)
    check diff["phashDistance"].getInt == hammingDistance(dctHash(ga), dctHash(gb))
    check diff["edgeChangeRatio"].getFloat == edgeChangeRatio(ga, gb)
    check tmin == tiledSsim(ga, gb, 4, 4).minLocal
    var k = 0
    for ty in 0 ..< 4:
      for tx in 0 ..< 4:
        let cell = rect(tx * 128 div 4, ty * 96 div 4, 128 div 4, 96 div 4)
        check diff["tiles"]["values"][k].getFloat == computeSsim(crop(ga, cell), crop(gb, cell))
        inc k

  test "test_vision_compare_size_mismatch_is_bad_args":
    let work = freshDir("vcsize")
    writePng(work / "a.png", patternFrame(64, 48))
    writePng(work / "b.png", patternFrame(64, 50))
    writePng(work / "c.png", patternFrame(64, 48))
    let env = baseEnv()
    let err = failure(@["vision-compare", work / "a.png", work / "b.png"], env, 2,
                      "bad-args", "invalid-value")
    check "64x48" in err{"message"}.getStr and "64x50" in err{"message"}.getStr
    # Either order; and the control: the same size compares.
    discard failure(@["vision-compare", work / "b.png", work / "a.png"], env, 2,
                    "bad-args", "invalid-value")
    check ok(@["vision-compare", work / "a.png", work / "c.png"], env)["ssim"].getFloat == 1.0
    # A grid finer than the image is refused, not clipped.
    discard failure(@["vision-compare", work / "a.png", work / "c.png", "--tiles", "64x64"],
                    env, 2, "bad-args", "invalid-value")

  test "test_vision_segment_two_state_frames_finds_one_boundary":
    let work = freshDir("vsf")
    let dir = work / "frames"
    discard twoStateFrames(dir, 160, 120, 6, 4)
    let env = baseEnv()
    let d = ok(@["vision-segment", "--frames", dir, "--fps", "2"], env)
    check d["source"]["path"].getStr == dir
    check d["source"]["width"].getInt == 160 and d["source"]["height"].getInt == 120
    check d["source"]["durationS"].getFloat == 5.0
    check d["params"]["fps"].getFloat == 2.0
    check d["params"]["scaleWidth"].kind == JNull
    check d["params"]["threshold"].getFloat == defaultChangeThreshold
    let segs = d["segments"]
    check segs.len == 2
    if segs.len == 2:
      check segs[0]["tStart"].getFloat == 0.0 and segs[0]["tEnd"].getFloat == 3.0
      check segs[1]["tStart"].getFloat == 3.0 and segs[1]["tEnd"].getFloat == 5.0
      check segs[0]["changeScore"].getFloat == 1.0
      check segs[1]["changeScore"].getFloat > defaultChangeThreshold
    # The library on the same frames gives the same segments.
    var frames: seq[GrayImage]
    for f in toSeq(walkFiles(dir / "*.png")).sorted: frames.add grayOf(f)
    checkSegmentsEqual(segs, segmentFrames(frames, 2.0))
    # --scale-width scales the frames but the source keeps its own size.
    let scaled = ok(@["vision-segment", "--frames", dir, "--fps", "2", "--scale-width", "80"], env)
    check scaled["params"]["scaleWidth"].getInt == 80
    check scaled["source"]["width"].getInt == 160 and scaled["source"]["height"].getInt == 120
    var small: seq[GrayImage]
    for g in frames: small.add scaleNearest(g, 80, scaledHeight(160, 120, 80))
    checkSegmentsEqual(scaled["segments"], segmentFrames(small, 2.0))
    check scaled["segments"].len == 2
    # Control: frames of one state are one segment; a threshold of 1.0 never
    # splits.
    let one = work / "one"
    discard twoStateFrames(one, 160, 120, 5, 0)
    check ok(@["vision-segment", "--frames", one], env)["segments"].len == 1
    check ok(@["vision-segment", "--frames", dir, "--threshold", "1"], env)["segments"].len == 1
    # Frames of different sizes are refused.
    writePng(dir / "f999.png", patternFrame(100, 100))
    discard failure(@["vision-segment", "--frames", dir], env, 2, "bad-args", "invalid-value")

  test "test_vision_segment_video_without_media_backend_is_exit_4":
    let work = freshDir("vsv4")
    let video = twoStateVideo(work)
    let env = baseEnv()
    let fixtureBin = minimalBin()
    check isMinimalBinary(fixtureBin)
    let err = failure(@["vision-segment", video], env, 4, "backend-unavailable",
                      "not-compiled-in", fixtureBin)
    check err["details"]["feature"].getStr == "video-decode"
    check err["details"]["module"].getStr == "media"
    check err["remedy"].getStr.len > 0
    # The same binary accepts --frames.
    let d = ok(@["vision-segment", "--frames", work / "src-frames", "--fps", "10"], env,
               fixtureBin)
    check d["segments"].len == 2
    # Its capabilities say so too.
    let caps = ok(@["capabilities"], fixtureEnv(freshDir("vsv4-st")), fixtureBin)
    let vd = caps["features"].getElems.filterIt(it["feature"].getStr == "video-decode")
    check vd.len == 1
    if vd.len == 1:
      check vd[0]["state"].getStr == "unavailable"
      check vd[0]["reason"].getStr == "not-compiled-in"

  test "test_vision_segment_video_two_states_matches_library":
    # (Added in GS4.) Video input through the media backend: the two-state
    # video has exactly two segments with the boundary at the switch, and the
    # CLI reports exactly what `segmentVideo` returns for the same file.
    let work = freshDir("vsv")
    let video = twoStateVideo(work)
    let env = baseEnv()
    let bin = mediaBin()
    let d = ok(@["vision-segment", video], env, bin)
    check d["source"]["path"].getStr == video
    check d["source"]["width"].getInt == 160 and d["source"]["height"].getInt == 120
    check d["source"]["durationS"].getFloat == 4.0
    check d["params"]["fps"].getFloat == defaultVideoFps
    check d["params"]["scaleWidth"].getInt == defaultVideoScaleWidth
    check d["params"]["threshold"].getFloat == defaultChangeThreshold
    let segs = d["segments"]
    check segs.len == 2
    if segs.len == 2:
      check segs[0]["tStart"].getFloat == 0.0
      check segs[0]["tEnd"].getFloat == 2.0
      check segs[1]["tStart"].getFloat == 2.0
      check segs[1]["tEnd"].getFloat == 4.0
    let lib = segmentVideo(video)
    check lib.frames == 8
    check lib.source.width == 160 and lib.source.height == 120
    checkSegmentsEqual(segs, lib.segments)
    # Explicit parameters reach the library unchanged.
    let custom = ok(@["vision-segment", video, "--fps", "4", "--scale-width", "64",
                      "--threshold", "0.2"], env, bin)
    check custom["params"]["fps"].getFloat == 4.0
    check custom["params"]["scaleWidth"].getInt == 64
    check custom["params"]["threshold"].getFloat == 0.2
    let lib2 = segmentVideo(video, 4.0, 64, 0.2)
    check lib2.frames == 16 and lib2.scaledHeight == 48
    checkSegmentsEqual(custom["segments"], lib2.segments)
    check custom["segments"].len == 2
    # A missing file is not-found; a file that is not a video is bad-args; no
    # ffmpeg is exit 4 / missing-tool naming the feature.
    discard failure(@["vision-segment", work / "absent.mp4"], env, 3, "not-found", "file", bin)
    writeFile(work / "not-a-video.mp4", "this is text, not a container")
    discard failure(@["vision-segment", work / "not-a-video.mp4"], env, 2, "bad-args",
                    "invalid-value", bin)
    let noTool = baseEnv()
    noTool["FFMPEG_BIN"] = work / "no-such-ffmpeg"
    let mt = failure(@["vision-segment", video], noTool, 4, "backend-unavailable",
                     "missing-tool", bin)
    check mt["details"]["feature"].getStr == "video-decode"
    # capabilities: available unprobed, supported when probed, and
    # unavailable / missing-tool without the tool.
    proc videoFeature(caps: JsonNode): JsonNode =
      for f in caps["features"]:
        if f["feature"].getStr == "video-decode": return f
      newJNull()
    let st = freshDir("vsv-st")
    let c1 = videoFeature(ok(@["capabilities"], fixtureEnv(st), bin))
    check c1["state"].getStr == "available" and c1["backend"].getStr == "ffmpeg"
    let c2 = videoFeature(ok(@["capabilities", "--probe"], fixtureEnv(st), bin))
    check c2["state"].getStr == "supported" and c2["reason"].kind == JNull
    let c3 = videoFeature(ok(@["capabilities", "--probe"],
                             fixtureEnv(st, {"FFMPEG_BIN": work / "no-such-ffmpeg"}), bin))
    check c3["state"].getStr == "unavailable" and c3["reason"].getStr == "missing-tool"

  test "test_vision_segment_video_damaged_or_oddly_named_input":
    # (Added in GS4 review.) A video whose header is intact but whose frames
    # are damaged makes ffmpeg log every bad macroblock: far more than a pipe
    # holds. The verb must still finish (stderr is drained while frames are
    # read, not after) and ffprobe's warnings must not corrupt its JSON. And
    # a file name is a file name: one that starts with `-` or looks like an
    # ffmpeg protocol (`pipe:0`) is read as that file.
    let work = freshDir("vsdmg")
    let clean = work / "clean.mp4"
    runFfmpeg(@["-f", "lavfi", "-i", "testsrc2=size=320x240:rate=30:duration=30",
                "-c:v", "libx264", "-preset", "ultrafast", "-threads", "1",
                "-pix_fmt", "yuv420p", "-movflags", "+faststart", clean])
    # Flip bytes past the first third only (the moov atom is at the front),
    # with a fixed generator so every run damages the same bytes.
    var bytes = readFile(clean)
    var state = 7'u32
    for i in 0 ..< 6000:
      state = state * 1664525'u32 + 1013904223'u32
      let at = bytes.len div 3 + int(state mod uint32(bytes.len - bytes.len div 3 - 16))
      bytes[at] = char(ord(bytes[at]) xor 0xff)
    let damaged = work / "damaged.mp4"
    writeFile(damaged, bytes)
    # Control: this input really does overflow a pipe (64 KiB on Linux and
    # macOS) with ffmpeg's diagnostics at the verb's own log level.
    let probe = startProcess(ffmpegTool(), args = @["-hide_banner", "-loglevel", "error",
      "-nostdin", "-i", damaged, "-vf", "fps=2,scale=320:240", "-f", "null", "-"],
      options = {poStdErrToStdOut})
    let diagnostics = probe.outputStream.readAll()
    discard probe.waitForExit()
    probe.close()
    check diagnostics.len > 65536
    let bin = mediaBin()
    let start = getMonoTime()
    let r = runCli(@["vision-segment", damaged], baseEnv(), timeoutMs = 60_000, bin = bin)
    check msSince(start) < 60_000
    if r.exit != 0: checkpoint r.stdout
    check r.exit == 0
    if r.exit == 0:
      let d = envelopeOf(r).data
      check d["source"]["width"].getInt == 320 and d["source"]["height"].getInt == 240
      check d["segments"].len > 0
      check d["segments"][^1]["tEnd"].getFloat == 30.0
    # Odd names, through the library (a relative name reaches ffmpeg as the
    # caller wrote it) and through the CLI (which makes it absolute).
    let video = twoStateVideo(work)
    let expected = segmentVideo(video).segments
    let here = getCurrentDir()
    setCurrentDir(work)
    try:
      for name in ["-two-state.mp4", "pipe:0"]:
        copyFile(video, work / name)
        let lib = segmentVideo(name)
        check lib.segments == expected
        let d = ok(@["vision-segment", "./" & name], baseEnv(), bin)
        checkSegmentsEqual(d["segments"], expected)
    finally:
      setCurrentDir(here)

  test "test_vision_segment_frame_size_cap_is_refused_before_decoding":
    # (GS4 follow-up.) A decoded frame holds at most `maxImagePixels` pixels
    # (the PNG decoder's cap, spec §7.5). A tall video scaled wide would ask
    # for a 16384 x 2 097 152 frame (34 GB); it is refused with exit 2 /
    # invalid-value before ffmpeg starts, not by an allocation that fails.
    let work = freshDir("vscap")
    let tall = work / "tall.mp4"
    runFfmpeg(@["-f", "lavfi", "-i", "testsrc=size=16x2048:rate=10:duration=1",
                "-c:v", "libx264", "-preset", "ultrafast", "-threads", "1",
                "-pix_fmt", "yuv420p", tall])
    let bin = mediaBin()
    let env = baseEnv()
    # 16x2048 at 1449 wide is 1449 x 185 472 = 268 748 928 pixels, just over
    # the cap; at 16384 wide it is over it 128-fold.
    check not fitsPixelCap(1449, scaledHeight(16, 2048, 1449))
    for width in ["1449", "16384"]:
      let err = failure(@["vision-segment", tall, "--scale-width", width], env, 2,
                        "bad-args", "invalid-value", bin)
      check $maxImagePixels in err["message"].getStr
    expect FrameTooLargeError:
      discard segmentVideo(tall, scaleWidth = 16384)
    # Control: the same video at a width that fits is segmented.
    let fits = ok(@["vision-segment", tall, "--scale-width", "64"], env, bin)
    check fits["source"]["width"].getInt == 16 and fits["source"]["height"].getInt == 2048
    check fits["segments"].len >= 1
    when defined(posix):
      # Refused after ffprobe, before ffmpeg: the recording tools see ffprobe
      # only; the control run that fits sees both.
      let rec = work / "tools"
      let recEnv = baseEnv()
      recEnv["FFMPEG_BIN"] = recordingTools(rec)
      discard failure(@["vision-segment", tall, "--scale-width", "16384"], recEnv, 2,
                      "bad-args", "invalid-value", bin)
      check callsOf(rec) == @["ffprobe"]
      discard ok(@["vision-segment", tall, "--scale-width", "64"], recEnv, bin)
      check callsOf(rec) == @["ffprobe", "ffprobe", "ffmpeg"]
    # --frames obeys the same cap after --scale-width.
    let frames = work / "frames"
    createDir(frames)
    var tallFrame = newImage(RgbImage, 16, 2048)
    tallFrame.fillRect(rect(0, 0, 16, 1024), (200, 200, 200))
    writePng(frames / "f000.png", tallFrame)
    writePng(frames / "f001.png", tallFrame)
    let ferr = failure(@["vision-segment", "--frames", frames, "--scale-width", "16384"], env,
                       2, "bad-args", "invalid-value")
    check $maxImagePixels in ferr["message"].getStr
    check ok(@["vision-segment", "--frames", frames, "--scale-width", "64"], env)["segments"].len == 1
    # The legacy gray decode refuses a 20000x20000 header before ffmpeg
    # decodes anything, as the pure PNG decoder does with the same constant.
    # (ffprobe itself reports this header as 0x0, ffmpeg's own size check;
    # the refusal is the size check in decodeGray either way.)
    check maxPngPixels == maxImagePixels
    let huge = work / "huge.png"
    writeFile(huge, hugePng(20000, 20000))
    expect PngError:
      discard decodePngGray(readFile(huge))
    try:
      discard media_ffmpeg.decodeGray(huge)
      check false   # must not decode
    except ImageMathError as x:
      check "limit" in x.msg
    when defined(posix):
      let rec2 = work / "tools2"
      let saved = getEnv("FFMPEG_BIN")
      putEnv("FFMPEG_BIN", recordingTools(rec2))
      try:
        expect ImageMathError:
          discard media_ffmpeg.decodeGray(huge)
        check callsOf(rec2) == @["ffprobe"]
      finally:
        if saved.len > 0: putEnv("FFMPEG_BIN", saved) else: delEnv("FFMPEG_BIN")

  test "test_vision_segment_low_fps_deadline_and_cancel_are_prompt":
    # (GS4 follow-up.) At a low --fps ffmpeg decodes seconds of video between
    # two frames it writes; the wait for its output goes in ~50 ms slices, so
    # --timeout-ms (exit 7) and a serve cancel (exit 8) are honoured promptly
    # rather than at the next frame.
    let work = freshDir("vslow")
    let video = sparseVideo(work)
    let bin = mediaBin()
    # Control: ffmpeg itself writes nothing over this input at this rate for
    # at least `sparseQuietMs` while it keeps decoding, so a deadline or a
    # cancel honoured only when a frame arrives would answer at least that
    # late, about three times the bounds below. The output goes to a file:
    # one frame is 320x320 bytes, more than ffmpeg's output buffer, so a
    # frame written is on disk, and an empty file means no frame yet.
    let quietOut = work / "quiet.gray"
    let probe = startProcess(ffmpegTool(), args = @["-hide_banner", "-loglevel", "error",
      "-nostdin", "-y", "-i", video, "-vf", "fps=" & sparseFps & ",scale=320:320",
      "-f", "rawvideo", "-pix_fmt", "gray", quietOut], options = {})
    sleep(sparseQuietMs)
    let stillDecoding = probe.running
    let quietBytes = (if fileExists(quietOut): getFileSize(quietOut) else: 0'i64)
    probe.kill()
    discard probe.waitForExit()
    probe.close()
    checkpoint "after " & $sparseQuietMs & " ms ffmpeg was running: " &
      $stillDecoding & ", its output held " & $quietBytes & " bytes"
    check stillDecoding
    check quietBytes == 0
    # The one-shot CLI: a 400 ms deadline answers exit 7 within ~1 s.
    let start = getMonoTime()
    let r = runCli(@["--timeout-ms", "400", "vision-segment", video, "--fps", sparseFps],
                   baseEnv(), timeoutMs = 60_000, bin = bin)
    let elapsed = msSince(start)
    checkpoint "the --timeout-ms 400 run took " & $elapsed & " ms: " & r.stdout
    check r.exit == 7
    if r.exit == 7:
      let e = envelopeOf(r)
      check e.errorKind == "timeout" and e.errorReason == "deadline"
    check elapsed < 1400
    # Over serve: a cancel sent while ffmpeg is busy is answered within 1 s.
    var d = startServe(@["serve"], fixtureEnv(freshDir("vslow-st")), bin)
    d.send(runReq("seg", @["vision-segment", video, "--fps", sparseFps]))
    sleep(600)
    when defined(posix):
      # Control: ffmpeg is still running, so the cancel is what ends it.
      let kids = execProcess("pgrep", args = ["-P", $d.p.processID, "ffmpeg"],
                             options = {poUsePath}).strip
      check kids.len > 0
    let cancelAt = getMonoTime()
    d.send(%*{"v": 1, "id": "c", "op": "cancel", "target": "seg"})
    var seg, c: JsonNode
    while seg.isNil or c.isNil:
      let m = d.recv(10_000)
      if m["type"].getStr == "result":
        if m["id"].getStr == "seg": seg = m
        elif m["id"].getStr == "c": c = m
    let cancelMs = msSince(cancelAt)
    checkpoint "the cancel was answered in " & $cancelMs & " ms"
    check cancelMs < 1000
    check seg["exit"].getInt == 8
    check seg["envelope"]["error"]["kind"].getStr == "cancelled"
    check c["envelope"]["data"]["state"].getStr == "cancelled"
    when defined(posix):
      sleep(300)
      let left = execProcess("pgrep", args = ["-P", $d.p.processID, "ffmpeg"],
                             options = {poUsePath}).strip
      check left.len == 0
    d.closeInput()
    while d.recv()["type"].getStr != "shutdown": discard
    check d.finish() == 0
    # The library: a checkpoint that raises once a deadline passes stops
    # segmentVideo within the same bound.
    let libStart = getMonoTime()
    let libDeadline = libStart + initDuration(milliseconds = 300)
    expect ValueError:
      discard segmentVideo(video, fps = parseFloat(sparseFps), checkpoint = proc () =
        if getMonoTime() >= libDeadline: raise newException(ValueError, "deadline"))
    let libMs = msSince(libStart)
    checkpoint "segmentVideo stopped after " & $libMs & " ms"
    check libMs < 1300

  test "test_vision_windows_two_window_frame":
    let st = freshDir("vw")
    let work = freshDir("vw-work")
    let env = fixtureEnv(st, {"GUIASSERT_FIXTURE_SCENARIO": twoWindowScenario(work)})
    let shot = work / "desk.png"
    discard ok(@["screenshot", "--out", shot], env)
    # Without --ocr: two windows, no text. The fixture draws each window as a
    # light body with a full-width title bar along its top and a 1-px gray-90
    # border, and 90 is the frame's Otsu threshold, so the border counts as
    # background: the bar keeps the left, right and top edges, and only the
    # bottom border row is lost. Each rect is the window's bounds one row
    # shorter.
    let plain = ok(@["vision-windows", shot], baseEnv())
    check plain["image"]["path"].getStr == shot
    check plain["image"]["width"].getInt == 800 and plain["image"]["height"].getInt == 600
    let ws = plain["windows"]
    check ws.len == 2
    if ws.len == 2:
      check ws[0]["bbox"] == %*[40, 50, 300, 219]
      check ws[1]["bbox"] == %*[420, 280, 340, 259]
      for w in ws:
        check w["titleText"].kind == JNull and w["text"].kind == JNull
        check w["confidence"].getFloat > 0.5 and w["confidence"].getFloat <= 1.0
    # The library on the same pixels finds the same rects.
    let rects = detectWindowRects(grayOf(shot))
    check rects.len == ws.len
    for i in 0 ..< min(rects.len, ws.len):
      check ws[i]["bbox"] == %*[rects[i][0], rects[i][1], rects[i][2], rects[i][3]]
    # With --ocr each window carries its own title and only its own text.
    let withOcr = ok(@["vision-windows", shot, "--ocr"], env)
    let wo = withOcr["windows"]
    check wo.len == 2
    if wo.len == 2:
      check wo[0]["bbox"] == ws[0]["bbox"] and wo[1]["bbox"] == ws[1]["bbox"]
      check wo[0]["titleText"].getStr == "Alpha Notes"
      check wo[1]["titleText"].getStr == "Beta Ledger"
      check wo[0]["text"].getStr == "Alpha Notes"
      check wo[1]["text"].getStr == "Beta Ledger"
    # Control: a frame with no window yields none.
    var blank = newImage(RgbImage, 320, 240)
    blank.fillRect(rect(0, 0, 320, 240), (40, 44, 52))
    writePng(work / "blank.png", blank)
    check ok(@["vision-windows", work / "blank.png"], baseEnv())["windows"].len == 0

  test "test_vision_verbs_over_serve_equal_the_cli":
    # (Added in GS4.) Each vision verb gives the same envelope, byte for byte,
    # over `guiassert serve` as from the one-shot CLI, on both builds (video
    # input only where the media backend is compiled in).
    let work = freshDir("vserve")
    writePng(work / "a.png", patternFrame(96, 72))
    writePng(work / "b.png", patternFrame(96, 72).withBox(rect(4, 4, 30, 20)))
    discard twoStateFrames(work / "frames", 96, 72, 3, 3)
    let video = twoStateVideo(work)
    for bin in [mediaBin(), minimalBin()]:
      let st = freshDir("vserve-st")
      let env = fixtureEnv(st)
      let argvs = @[
        @["vision-compare", work / "a.png", work / "b.png", "--tiles", "3x2"],
        @["vision-compare", work / "a.png", work / "b.png"],
        @["vision-segment", "--frames", work / "frames", "--fps", "3"],
        @["vision-segment", video, "--fps", "2"],
        @["vision-windows", work / "a.png"]]
      var d = startServe(@["serve"], env, bin)
      for i, argv in argvs:
        let cliLine = cli(argv, env, bin).line
        let id = "v" & $i
        d.send(runReq(id, argv))
        var line = ""
        while true:
          line = d.recvRaw()
          let m = parseJson(line)
          if m{"id"}.getStr == id and m["type"].getStr == "result": break
        let served = envelopeText(line)
        if served != cliLine:
          checkpoint bin & " " & argv.join(" ") & "\n  cli:   " & cliLine & "\n  serve: " & served
        check served == cliLine
      d.closeInput()
      while d.recv()["type"].getStr != "shutdown": discard
      check d.finish() == 0

  test "test_serve_cancels_a_running_video_segmentation":
    # (Added in GS4.) A long decode is cancellable: the cancel answers exit 8
    # promptly and ffmpeg does not outlive the request.
    let work = freshDir("vcancel")
    let video = work / "long.mp4"
    runFfmpeg(@["-f", "lavfi", "-i", "testsrc=size=64x48:rate=30:duration=120",
                "-c:v", "libx264", "-preset", "ultrafast", "-threads", "1",
                "-pix_fmt", "yuv420p", video])
    let bin = mediaBin()
    var d = startServe(@["serve"], fixtureEnv(freshDir("vcancel-st")), bin)
    let start = getMonoTime()
    d.send(runReq("seg", @["vision-segment", video, "--fps", "240", "--scale-width", "1024"]))
    sleep(700)
    # Control: the request is still running (28 800 frames at 1024 wide take
    # far longer than 700 ms), so the cancel below is what ends it.
    when defined(posix):
      let kids = execProcess("pgrep", args = ["-P", $d.p.processID, "ffmpeg"],
                             options = {poUsePath}).strip
      check kids.len > 0
    d.send(%*{"v": 1, "id": "c", "op": "cancel", "target": "seg"})
    var seg, c: JsonNode
    while seg.isNil or c.isNil:
      let m = d.recv(10_000)
      if m["type"].getStr == "result":
        if m["id"].getStr == "seg": seg = m
        elif m["id"].getStr == "c": c = m
    check msSince(start) < 5000
    check c["envelope"]["data"]["state"].getStr == "cancelled"
    check seg["exit"].getInt == 8
    check seg["envelope"]["error"]["kind"].getStr == "cancelled"
    when defined(posix):
      sleep(300)
      let left = execProcess("pgrep", args = ["-P", $d.p.processID, "ffmpeg"],
                             options = {poUsePath}).strip
      check left.len == 0
    d.closeInput()
    while d.recv()["type"].getStr != "shutdown": discard
    check d.finish() == 0

cleanupFreshDirs()
