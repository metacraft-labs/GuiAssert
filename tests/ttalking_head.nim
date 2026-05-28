## Unit + integration tests for `gui_assert/talking_head`.
##
## ## Pure tests (always run)
##
## These exercise the small algorithmic surface of the module:
##   * provider-name parsing accepts the documented aliases,
##   * cache keys are deterministic and depend on (avatar, narration,
##     provider, device),
##   * `isAvailable` returns true for `thpStockAvatar` always and is
##     gated by Python+script presence for `thpSadTalker`,
##   * `optsFromMetadata` translates the YAML metadata into runtime
##     options including resolving relative avatar paths and forwarding
##     extras as CLI arguments,
##   * the stock-avatar provider produces a valid MP4 (copies the
##     marketing repo's placeholder when reachable, otherwise
##     synthesises one via ffmpeg).
##
## ## Live test (compile-time-gated)
##
## When compiled with `-d:sadtalkerLive` an additional suite runs:
##   * spawns the SadTalker python wrapper against a real avatar +
##     WAV fixture from the codetracer-marketing checkout,
##   * asserts that the produced MP4 has a video stream whose duration
##     is within ±0.5 s of the input WAV duration.
##
## The gate is on by community agreement (see Video-Session-Capture.md
## §3 Visual Overlay Options): we never silently skip the heavy live
## path, but we also don't make the default test suite block on it.

import std/[json, options, os, osproc, streams, strformat, strutils,
            tables, times, unittest]

import ../src/gui_assert/parser
import ../src/gui_assert/talking_head

# ---------------------------------------------------------------------------
# Repo paths
# ---------------------------------------------------------------------------

proc guiAssertRoot(): string =
  ## `currentSourcePath` is .../GuiAssert/tests/ttalking_head.nim
  currentSourcePath().parentDir().parentDir()

proc workspaceRoot(): string =
  ## metacraft/ — the parent of GuiAssert.
  guiAssertRoot().parentDir()

proc marketingRoot(): string =
  workspaceRoot() / "codetracer-marketing"

proc marketingAsset(p: string): string =
  marketingRoot() / "assets" / p

proc marketingTool(p: string): string =
  marketingRoot() / "tools" / "sadtalker" / p

# ---------------------------------------------------------------------------
# Tiny WAV / PNG fixtures
# ---------------------------------------------------------------------------

proc writeTinyWav(path: string, payloadByte: byte = 0x00'u8) =
  ## Write a minimal 44-byte WAV header + a few sample bytes.  The exact
  ## bytes don't matter for the cache-key tests — they just need to be
  ## deterministic.
  let buf = "RIFF\x24\x00\x00\x00WAVEfmt " &
            "\x10\x00\x00\x00\x01\x00\x01\x00\x40\x1f\x00\x00" &
            "\x40\x1f\x00\x00\x01\x00\x08\x00data\x00\x00\x00\x00" &
            $cast[char](payloadByte) & $cast[char](payloadByte)
  writeFile(path, buf)

proc writeTinyPng(path: string, payloadByte: byte = 0x01'u8) =
  ## Write a 1x1 PNG. Hand-rolled bytes — sufficient for cache-key
  ## tests where we only need the file to exist and have stable bytes.
  let header = "\x89PNG\r\n\x1a\n"
  let chunk = "\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89"
  let trailer = "\x00\x00\x00\x00IEND\xaeB`\x82"
  writeFile(path, header & chunk & $cast[char](payloadByte) & trailer)

# ---------------------------------------------------------------------------
# Pure tests
# ---------------------------------------------------------------------------

suite "talking_head provider name parsing":

  test "stock_avatar is the default for missing/empty input":
    check parseTalkingHeadProvider("") == thpStockAvatar
    check parseTalkingHeadProvider("stock") == thpStockAvatar
    check parseTalkingHeadProvider("stock_avatar") == thpStockAvatar
    check parseTalkingHeadProvider("placeholder") == thpStockAvatar

  test "sadtalker is recognised case-insensitively":
    check parseTalkingHeadProvider("sadtalker") == thpSadTalker
    check parseTalkingHeadProvider("SadTalker") == thpSadTalker
    check parseTalkingHeadProvider("  SADTALKER  ") == thpSadTalker

  test "future providers parse to their reserved enum values":
    check parseTalkingHeadProvider("did") == thpDid
    check parseTalkingHeadProvider("d-id") == thpDid
    check parseTalkingHeadProvider("heygen") == thpHeyGen
    check parseTalkingHeadProvider("hedra") == thpHedra

  test "unknown provider raises TalkingHeadError":
    expect TalkingHeadError:
      discard parseTalkingHeadProvider("nope")

suite "talking_head isAvailable":

  test "thpStockAvatar is always available":
    check isAvailable(thpStockAvatar)
    check isAvailable(thpStockAvatar, TalkingHeadOpts())

  test "thpSadTalker requires python binary + render script":
    # With empty opts and no marketing repo on disk we cannot guarantee
    # availability — but we *can* assert that bogus paths return false.
    var opts = TalkingHeadOpts()
    opts.pythonBinary = some("/nonexistent/python")
    opts.renderScriptPath = some("/nonexistent/render.py")
    check not isAvailable(thpSadTalker, opts)

  test "thpSadTalker becomes available when both paths exist":
    # Create dummy executables under tmp.
    let tmp = getTempDir() / "ttalking_head_avail"
    if dirExists(tmp): removeDir(tmp)
    createDir(tmp)
    let py = tmp / "python"
    let scr = tmp / "render.py"
    writeFile(py, "#!/bin/sh\nexit 0\n")
    writeFile(scr, "print('hello')\n")
    var opts = TalkingHeadOpts()
    opts.pythonBinary = some(py)
    opts.renderScriptPath = some(scr)
    check isAvailable(thpSadTalker, opts)

  test "future providers report unavailable":
    check not isAvailable(thpDid)
    check not isAvailable(thpHeyGen)
    check not isAvailable(thpHedra)

suite "talking_head cache key":

  test "cache key depends on every input":
    let tmp = getTempDir() / "ttalking_head_cache"
    if dirExists(tmp): removeDir(tmp)
    createDir(tmp)
    let av = tmp / "a.png"
    let av2 = tmp / "b.png"
    let nar = tmp / "n.wav"
    let nar2 = tmp / "m.wav"
    writeTinyPng(av, 0x01'u8)
    writeTinyPng(av2, 0x02'u8)
    writeTinyWav(nar, 0x10'u8)
    writeTinyWav(nar2, 0x20'u8)

    let k = computeCacheKey(av, nar, thpSadTalker, "mps")
    check k.len == 16
    # Deterministic.
    check k == computeCacheKey(av, nar, thpSadTalker, "mps")
    # Different avatar -> different key.
    check k != computeCacheKey(av2, nar, thpSadTalker, "mps")
    # Different narration -> different key.
    check k != computeCacheKey(av, nar2, thpSadTalker, "mps")
    # Different provider -> different key.
    check k != computeCacheKey(av, nar, thpStockAvatar, "mps")
    # Different device -> different key.
    check k != computeCacheKey(av, nar, thpSadTalker, "cpu")

  test "missing avatar raises":
    let tmp = getTempDir() / "ttalking_head_cache_missing"
    if dirExists(tmp): removeDir(tmp)
    createDir(tmp)
    let nar = tmp / "n.wav"
    writeTinyWav(nar)
    expect TalkingHeadError:
      discard computeCacheKey(tmp / "nope.png", nar, thpSadTalker, "auto")

  test "missing narration raises":
    let tmp = getTempDir() / "ttalking_head_cache_missing2"
    if dirExists(tmp): removeDir(tmp)
    createDir(tmp)
    let av = tmp / "a.png"
    writeTinyPng(av)
    expect TalkingHeadError:
      discard computeCacheKey(av, tmp / "nope.wav", thpSadTalker, "auto")

suite "talking_head optsFromMetadata":

  test "defaults to stock_avatar when metadata is empty":
    var meta = TalkingHeadMeta(extras: initTable[string, string]())
    let opts = optsFromMetadata(meta)
    check opts.provider == thpStockAvatar
    check opts.avatarImagePath.isNone
    check opts.device.len == 0
    check opts.extraArgs.len == 0

  test "explicit provider + relative avatar path resolves against scriptDir":
    var meta = TalkingHeadMeta(provider: "sadtalker",
      avatarImage: "assets/founder.png",
      device: "auto",
      extras: initTable[string, string]())
    let opts = optsFromMetadata(meta, scriptDir = "/repo/scripts")
    check opts.provider == thpSadTalker
    check opts.avatarImagePath == some("/repo/scripts/assets/founder.png")
    check opts.device == "auto"

  test "absolute avatar path is preserved":
    var meta = TalkingHeadMeta(provider: "sadtalker",
      avatarImage: "/abs/path.png",
      extras: initTable[string, string]())
    let opts = optsFromMetadata(meta, scriptDir = "/repo")
    check opts.avatarImagePath == some("/abs/path.png")

  test "extras translate into CLI args":
    var extras = initTable[string, string]()
    extras["preprocess"] = "full"
    extras["enhancer"] = "gfpgan"
    extras["still"] = "true"
    extras["pose_style"] = "5"
    var meta = TalkingHeadMeta(provider: "sadtalker",
      avatarImage: "/x.png",
      extras: extras)
    let opts = optsFromMetadata(meta)
    check "--preprocess" in opts.extraArgs
    check "full" in opts.extraArgs
    check "--enhancer" in opts.extraArgs
    check "gfpgan" in opts.extraArgs
    check "--still-mode" in opts.extraArgs
    # Unknown keys are forwarded as kebab-case flags.
    check "--pose-style" in opts.extraArgs
    check "5" in opts.extraArgs

# ---------------------------------------------------------------------------
# Stock-avatar provider produces a real MP4
# ---------------------------------------------------------------------------

suite "talking_head stock_avatar provider":

  test "generateTalkingHead with thpStockAvatar produces a non-empty MP4":
    let tmp = getTempDir() / "ttalking_head_stock"
    if dirExists(tmp): removeDir(tmp)
    createDir(tmp)
    let nar = tmp / "n.wav"
    writeTinyWav(nar)
    let outMp4 = tmp / "out.mp4"
    var opts = TalkingHeadOpts(provider: thpStockAvatar,
      cacheDir: some(tmp / "cache"))
    # If the marketing repo's placeholder exists, we'll copy it;
    # otherwise we synthesise via ffmpeg. Either path must produce a
    # non-empty file.
    generateTalkingHead(nar, outMp4, opts)
    check fileExists(outMp4)
    check getFileSize(outMp4) > 0

# ---------------------------------------------------------------------------
# Live SadTalker test — compile-time-gated.
# ---------------------------------------------------------------------------
#
#   nim c -d:sadtalkerLive --hints:off --path:../src tests/ttalking_head.nim
#
# Requires:
#   * codetracer-marketing/tools/sadtalker/.venv (Python 3.10 + deps)
#   * the wrapper script at .../tools/sadtalker/render_talking_head.py
#   * the SadTalker model weights under tools/sadtalker/upstream/checkpoints
#   * the avatar fixture at codetracer-marketing/assets/avatar-default.png
#   * a real narration WAV at codetracer-marketing/build/narration.wav
when defined(sadtalkerLive):

  proc ffprobeJson(path: string): JsonNode =
    let ffprobe =
      block:
        let env = getEnv("FFPROBE_BIN")
        if env.len > 0 and fileExists(env): env
        else: findExe("ffprobe")
    doAssert ffprobe.len > 0 and fileExists(ffprobe),
      "ffprobe not on PATH; install ffmpeg to run the live SadTalker test."
    let p = startProcess(
      command = ffprobe,
      args = @["-hide_banner", "-v", "error", "-print_format", "json",
               "-show_streams", "-show_format", path],
      options = {poStdErrToStdOut}
    )
    let raw = p.outputStream.readAll()
    let code = p.waitForExit()
    p.close()
    doAssert code == 0, "ffprobe failed (" & $code & "): " & raw
    parseJson(raw)

  suite "talking_head SadTalker live run":

    test "renders a real talking head against the marketing fixture":
      let avatar = marketingAsset("avatar-default.png")
      doAssert fileExists(avatar),
        "missing avatar fixture: " & avatar &
        " (create one under codetracer-marketing/assets/)"
      # Prefer the existing build/narration.wav fixture if present.
      var narration = marketingRoot() / "build" / "narration.wav"
      if not fileExists(narration):
        narration = marketingTool("upstream/examples/driven_audio/RD_Radio31_000.wav")
      doAssert fileExists(narration),
        "no narration WAV fixture found at build/narration.wav or in " &
        "tools/sadtalker/upstream/examples/driven_audio/"

      let tmp = getTempDir() / "ttalking_head_live"
      if dirExists(tmp): removeDir(tmp)
      createDir(tmp)
      let outMp4 = tmp / "live.mp4"
      var opts = TalkingHeadOpts(
        provider: thpSadTalker,
        avatarImagePath: some(avatar),
        device: "mps",
        cacheDir: some(tmp / "cache"),
        extraArgs: @["--still-mode", "--preprocess", "crop"],
      )
      doAssert isAvailable(thpSadTalker, opts),
        "thpSadTalker not available — see Part A install instructions."

      let started = epochTime()
      generateTalkingHead(narration, outMp4, opts)
      let dt = epochTime() - started
      echo &"  live SadTalker render took {dt:.1f}s"

      doAssert fileExists(outMp4), "no MP4 at " & outMp4
      let sz = getFileSize(outMp4)
      check sz > 1024
      echo &"  output: {sz} bytes"

      # Validate via ffprobe: must have a video stream and a duration.
      let probe = ffprobeJson(outMp4)
      var hasVideo = false
      for s in probe{"streams"}.items:
        if s{"codec_type"}.getStr() == "video": hasVideo = true
      check hasVideo

      # Duration should roughly match the narration WAV.
      let videoDur = parseFloat(probe{"format", "duration"}.getStr())
      let narProbe = ffprobeJson(narration)
      let narDur = parseFloat(narProbe{"format", "duration"}.getStr())
      echo &"  narration dur: {narDur:.3f}s; talking-head dur: {videoDur:.3f}s"
      check abs(videoDur - narDur) <= 0.5

      # Cache hit: second call must return instantly (no SadTalker run).
      let secondStart = epochTime()
      let outMp4_2 = tmp / "live2.mp4"
      generateTalkingHead(narration, outMp4_2, opts)
      let secondDt = epochTime() - secondStart
      echo &"  second call (cache hit) took {secondDt:.3f}s"
      check secondDt < 5.0  # generous; a real hit is well under 1s
      check fileExists(outMp4_2)
      check getFileSize(outMp4_2) == getFileSize(outMp4)
