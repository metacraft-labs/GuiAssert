## Unit + integration tests for `gui_assert/talking_head`.
##
## After the SadTalker extraction (sibling repo `GuiAssert-SadTalker`),
## this file covers only the **registry + built-in stock_avatar**
## path.  SadTalker-specific tests live in
## `GuiAssert-SadTalker/tests/tsadtalker.nim`.
##
## What we assert here:
##   * provider-name normalisation collapses the documented aliases,
##   * cache keys are deterministic and depend on every ingredient,
##   * the registry rejects nil/empty plugins, looks up by canonical
##     name, and reports membership / listings correctly,
##   * `optsFromMetadata` translates the YAML metadata into runtime
##     options (avatar path resolution + extras → CLI args + structured
##     providerSettings),
##   * the built-in `stock_avatar` provider produces a non-empty MP4
##     either by copying a pre-baked placeholder or by synthesising
##     one via ffmpeg's `testsrc2` source,
##   * `applyCache` actually caches: a second render with the same key
##     skips the generator closure.

import std/[json, options, os, tables, unittest]

import ../src/gui_assert/parser
import ../src/gui_assert/talking_head

# ---------------------------------------------------------------------------
# Tiny WAV / PNG fixtures
# ---------------------------------------------------------------------------

proc writeTinyWav(path: string, payloadByte: byte = 0x00'u8) =
  ## Write a minimal 44-byte WAV header + a few sample bytes.  The
  ## exact bytes don't matter for cache-key tests — they just need
  ## to be deterministic.
  let buf = "RIFF\x24\x00\x00\x00WAVEfmt " &
            "\x10\x00\x00\x00\x01\x00\x01\x00\x40\x1f\x00\x00" &
            "\x40\x1f\x00\x00\x01\x00\x08\x00data\x00\x00\x00\x00" &
            $cast[char](payloadByte) & $cast[char](payloadByte)
  writeFile(path, buf)

proc writeTinyPng(path: string, payloadByte: byte = 0x01'u8) =
  ## Write a 1x1 PNG.  Sufficient for cache-key tests — we only need
  ## the file to exist and have stable bytes.
  let header = "\x89PNG\r\n\x1a\n"
  let chunk = "\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89"
  let trailer = "\x00\x00\x00\x00IEND\xaeB`\x82"
  writeFile(path, header & chunk & $cast[char](payloadByte) & trailer)

# ---------------------------------------------------------------------------
# Provider name normalisation
# ---------------------------------------------------------------------------

suite "talking_head provider name normalisation":

  test "stock_avatar aliases collapse to the canonical form":
    check normalizeProviderName("") == "stock_avatar"
    check normalizeProviderName("stock") == "stock_avatar"
    check normalizeProviderName("stock_avatar") == "stock_avatar"
    check normalizeProviderName("placeholder") == "stock_avatar"
    check normalizeProviderName(" STOCK_AVATAR ") == "stock_avatar"

  test "d-id and did both normalise to did":
    check normalizeProviderName("did") == "did"
    check normalizeProviderName("d-id") == "did"
    check normalizeProviderName("D-ID") == "did"

  test "unknown names round-trip lowercased":
    check normalizeProviderName("SadTalker") == "sadtalker"
    check normalizeProviderName("  MuseTalk  ") == "musetalk"

# ---------------------------------------------------------------------------
# Cache key
# ---------------------------------------------------------------------------

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

    let k = cacheKeyFor(av, nar, "sadtalker", "mps")
    check k.len == 16
    # Deterministic.
    check k == cacheKeyFor(av, nar, "sadtalker", "mps")
    # Aliased provider name normalises to the same key.
    check k == cacheKeyFor(av, nar, "SadTalker", "mps")
    # Different avatar -> different key.
    check k != cacheKeyFor(av2, nar, "sadtalker", "mps")
    # Different narration -> different key.
    check k != cacheKeyFor(av, nar2, "sadtalker", "mps")
    # Different provider -> different key.
    check k != cacheKeyFor(av, nar, "stock_avatar", "mps")
    # Different device -> different key.
    check k != cacheKeyFor(av, nar, "sadtalker", "cpu")

  test "missing avatar raises":
    let tmp = getTempDir() / "ttalking_head_cache_missing"
    if dirExists(tmp): removeDir(tmp)
    createDir(tmp)
    let nar = tmp / "n.wav"
    writeTinyWav(nar)
    expect TalkingHeadError:
      discard cacheKeyFor(tmp / "nope.png", nar, "sadtalker", "auto")

  test "missing narration raises":
    let tmp = getTempDir() / "ttalking_head_cache_missing2"
    if dirExists(tmp): removeDir(tmp)
    createDir(tmp)
    let av = tmp / "a.png"
    writeTinyPng(av)
    expect TalkingHeadError:
      discard cacheKeyFor(av, tmp / "nope.wav", "sadtalker", "auto")

# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------

suite "talking_head registry":

  test "newRegistry pre-registers stock_avatar":
    let r = newRegistry()
    check hasProvider(r, "stock_avatar")
    check hasProvider(r, "")             # empty alias
    check hasProvider(r, "placeholder")  # alias
    let names = listProviders(r)
    check "stock_avatar" in names

  test "registerProvider rejects nil registry":
    var p = newStockAvatarProvider()
    p.name = "demo"
    expect TalkingHeadError:
      registerProvider(nil, p)

  test "registerProvider rejects empty name":
    let r = newRegistry()
    var p = newStockAvatarProvider()
    p.name = ""
    expect TalkingHeadError:
      registerProvider(r, p)

  test "registerProvider rejects missing callbacks":
    let r = newRegistry()
    let p = TalkingHeadProvider(name: "broken")
    expect TalkingHeadError:
      registerProvider(r, p)

  test "unknown providers raise on lookup and dispatch":
    let r = newRegistry()
    expect TalkingHeadError:
      discard getProvider(r, "no-such-provider")
    let tmp = getTempDir() / "ttalking_head_unknown"
    if dirExists(tmp): removeDir(tmp)
    createDir(tmp)
    let nar = tmp / "n.wav"
    writeTinyWav(nar)
    expect TalkingHeadError:
      generateTalkingHead(r, "musetalk", nar, tmp / "out.mp4",
                          TalkingHeadOpts())

  test "registerProvider overwrites by canonical name":
    let r = newRegistry()
    var fakeCalled = 0
    let p = TalkingHeadProvider(
      name: "stock_avatar",
      isAvailable: proc(): bool {.gcsafe.} = true,
      generate: proc(narrationWav, outputMp4: string,
                     opts: TalkingHeadOpts) {.gcsafe.} =
        inc fakeCalled
        writeFile(outputMp4, "fake")
    )
    registerProvider(r, p)
    let tmp = getTempDir() / "ttalking_head_overwrite"
    if dirExists(tmp): removeDir(tmp)
    createDir(tmp)
    let nar = tmp / "n.wav"
    writeTinyWav(nar)
    let outMp4 = tmp / "out.mp4"
    generateTalkingHead(r, "stock_avatar", nar, outMp4, TalkingHeadOpts())
    check fakeCalled == 1
    check fileExists(outMp4)
    check readFile(outMp4) == "fake"

# ---------------------------------------------------------------------------
# applyCache
# ---------------------------------------------------------------------------

suite "talking_head applyCache":

  test "applyCache skips the generator on a cache hit":
    let tmp = getTempDir() / "ttalking_head_apply_cache"
    if dirExists(tmp): removeDir(tmp)
    createDir(tmp)
    let cacheDir = tmp / "cache"
    let outMp4 = tmp / "out.mp4"
    let key = "abcdef0123456789"

    var calls = 0
    let gen = proc() =
      inc calls
      writeFile(outMp4, "v1")

    let r1 = applyCache(cacheDir, key, outMp4, gen)
    check r1.hit == false
    check calls == 1
    check fileExists(cacheDir / (key & ".mp4"))

    # Second call must hit the cache without running the generator.
    let outMp4_2 = tmp / "out2.mp4"
    let gen2 = proc() =
      inc calls
      writeFile(outMp4_2, "v2")
    let r2 = applyCache(cacheDir, key, outMp4_2, gen2)
    check r2.hit == true
    check calls == 1  # generator NOT called the second time
    check fileExists(outMp4_2)
    check readFile(outMp4_2) == "v1"  # cached content reused

  test "applyCache raises when generator produces nothing":
    let tmp = getTempDir() / "ttalking_head_apply_cache_empty"
    if dirExists(tmp): removeDir(tmp)
    createDir(tmp)
    let cacheDir = tmp / "cache"
    let outMp4 = tmp / "out.mp4"
    let gen = proc() = discard
    expect TalkingHeadError:
      discard applyCache(cacheDir, "deadbeef", outMp4, gen)

# ---------------------------------------------------------------------------
# optsFromMetadata
# ---------------------------------------------------------------------------

suite "talking_head optsFromMetadata":

  test "defaults are sensible when metadata is empty":
    var meta = TalkingHeadMeta(extras: initTable[string, string]())
    let opts = optsFromMetadata(meta)
    check opts.avatarImagePath.isNone
    check opts.device.len == 0
    check opts.extraArgs.len == 0
    check opts.providerSettings.kind == JObject
    check opts.providerSettings.len == 0

  test "relative avatar path resolves against scriptDir":
    var meta = TalkingHeadMeta(provider: "sadtalker",
      avatarImage: "assets/founder.png",
      device: "auto",
      extras: initTable[string, string]())
    let opts = optsFromMetadata(meta, scriptDir = "/repo/scripts")
    check opts.avatarImagePath == some("/repo/scripts/assets/founder.png")
    check opts.device == "auto"

  test "absolute avatar path is preserved":
    var meta = TalkingHeadMeta(provider: "sadtalker",
      avatarImage: "/abs/path.png",
      extras: initTable[string, string]())
    let opts = optsFromMetadata(meta, scriptDir = "/repo")
    check opts.avatarImagePath == some("/abs/path.png")

  test "extras translate into both CLI args and providerSettings":
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
    # Structured mirror.
    check opts.providerSettings["preprocess"].getStr == "full"
    check opts.providerSettings["enhancer"].getStr == "gfpgan"
    check opts.providerSettings["pose_style"].getStr == "5"

# ---------------------------------------------------------------------------
# Built-in stock_avatar provider
# ---------------------------------------------------------------------------

suite "talking_head stock_avatar provider":

  test "isAvailable is always true":
    let p = newStockAvatarProvider()
    check p.name == "stock_avatar"
    check p.isAvailable()

  test "generateTalkingHead via registry produces a non-empty MP4":
    let r = newRegistry()
    let tmp = getTempDir() / "ttalking_head_stock"
    if dirExists(tmp): removeDir(tmp)
    createDir(tmp)
    let nar = tmp / "n.wav"
    writeTinyWav(nar)
    let outMp4 = tmp / "out.mp4"
    let opts = TalkingHeadOpts(cacheDir: some(tmp / "cache"))
    # Synthesises via ffmpeg's testsrc2 because no avatarImagePath is
    # supplied.
    generateTalkingHead(r, "stock_avatar", nar, outMp4, opts)
    check fileExists(outMp4)
    check getFileSize(outMp4) > 0

  test "stock provider copies a pre-baked MP4 verbatim when supplied":
    let r = newRegistry()
    let tmp = getTempDir() / "ttalking_head_stock_copy"
    if dirExists(tmp): removeDir(tmp)
    createDir(tmp)
    let nar = tmp / "n.wav"
    writeTinyWav(nar)
    # Build a "pre-baked" mp4 surrogate (the stock provider only checks
    # existence + non-empty; it does not validate the container format).
    let prebaked = tmp / "prebaked.mp4"
    writeFile(prebaked, "fake-mp4-bytes-12345678")
    let outMp4 = tmp / "out.mp4"
    let opts = TalkingHeadOpts(avatarImagePath: some(prebaked))
    generateTalkingHead(r, "stock_avatar", nar, outMp4, opts)
    check fileExists(outMp4)
    check readFile(outMp4) == "fake-mp4-bytes-12345678"

  test "empty / placeholder provider names route to the built-in":
    let r = newRegistry()
    let tmp = getTempDir() / "ttalking_head_stock_alias"
    if dirExists(tmp): removeDir(tmp)
    createDir(tmp)
    let nar = tmp / "n.wav"
    writeTinyWav(nar)
    let opts = TalkingHeadOpts()
    let outA = tmp / "a.mp4"
    let outB = tmp / "b.mp4"
    generateTalkingHead(r, "", nar, outA, opts)
    generateTalkingHead(r, "placeholder", nar, outB, opts)
    check fileExists(outA)
    check fileExists(outB)
    check getFileSize(outA) > 0
    check getFileSize(outB) > 0
