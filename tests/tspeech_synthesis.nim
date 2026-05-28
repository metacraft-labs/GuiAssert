## Tests for the M7 `SpeechSynthesisProvider` contract.
##
## ## Pure tests (always run)
##
##   * Registry construction, registration, lookup, listing.
##   * `sayProvider` value shape (name, non-nil callbacks).
##   * `sayIsAvailable` reflects whether `/usr/bin/say` is on disk.
##   * `buildSayArgv` produces the expected argv shape, honouring
##     voice / rate / sample-rate knobs.
##   * `speechCacheKeyFor` determinism + per-input sensitivity.
##   * `applySpeechCache` round-trip + cache-hit path.
##   * `effectiveSampleRateHz`, `effectiveVoiceId`, name normalisation.
##   * `newDefaultSpeechRegistry` pre-registers the host-OS provider.
##
## ## Live tests (compile-time-gated via `-d:speechLive`, macOS-only)
##
##   nim c -d:speechLive -r --hints:off tests/tspeech_synthesis.nim
##
## The live suite invokes the real `say` provider, then runs ffprobe
## against the produced WAV to verify the file is a valid 16-bit PCM
## RIFF WAV with non-zero duration.

import std/[json, options, os, osproc, streams, strformat, strutils,
            unittest]

import ../src/gui_assert/speech_synthesis
import ../src/gui_assert/speech_synthesis/core
import ../src/gui_assert/speech_synthesis/say_provider

# ---------------------------------------------------------------------------
# Pure tests
# ---------------------------------------------------------------------------

suite "speech provider-name normalisation":

  test "lowercases + collapses aliases for `say`":
    check normalizeSpeechProviderName("Say") == "say"
    check normalizeSpeechProviderName("macos") == "say"
    check normalizeSpeechProviderName("DARWIN") == "say"
    check normalizeSpeechProviderName("  say  ") == "say"

  test "collapses elevenlabs spelling variants":
    check normalizeSpeechProviderName("ElevenLabs") == "elevenlabs"
    check normalizeSpeechProviderName("eleven-labs") == "elevenlabs"
    check normalizeSpeechProviderName("eleven_labs") == "elevenlabs"
    check normalizeSpeechProviderName("11labs") == "elevenlabs"

  test "collapses espeak / sapi spellings":
    check normalizeSpeechProviderName("ESPEAK-NG") == "espeak"
    check normalizeSpeechProviderName("espeakng") == "espeak"
    check normalizeSpeechProviderName("Linux") == "espeak"
    check normalizeSpeechProviderName("SAPI5") == "sapi"
    check normalizeSpeechProviderName("Windows") == "sapi"

  test "passes unknown names through verbatim (lowercased)":
    check normalizeSpeechProviderName("CoquiTTS") == "coquitts"

suite "speech defaults":

  test "DefaultSpeechSampleRateHz matches the legacy say pipeline":
    check DefaultSpeechSampleRateHz == 22050

  test "effectiveSampleRateHz returns default when opts.sampleRateHz unset":
    let opts = SpeechSynthesisOpts(sampleRateHz: none(int))
    check effectiveSampleRateHz(opts) == 22050

  test "effectiveSampleRateHz returns override when set":
    let opts = SpeechSynthesisOpts(sampleRateHz: some(44100))
    check effectiveSampleRateHz(opts) == 44100

  test "effectiveSampleRateHz rejects non-positive overrides":
    let opts = SpeechSynthesisOpts(sampleRateHz: some(0))
    check effectiveSampleRateHz(opts) == 22050

  test "effectiveVoiceId returns provided default when unset":
    let opts = SpeechSynthesisOpts(voiceId: none(string))
    check effectiveVoiceId(opts, "Rachel") == "Rachel"

  test "effectiveVoiceId returns override when set":
    let opts = SpeechSynthesisOpts(voiceId: some("Samantha"))
    check effectiveVoiceId(opts, "Rachel") == "Samantha"

  test "defaultSpeechCacheDir ends in gui_assert/speech_synthesis":
    let d = defaultSpeechCacheDir()
    check d.endsWith("gui_assert" / "speech_synthesis")

suite "say argv construction":

  test "buildSayArgv emits canonical flags with default sample rate":
    let argv = buildSayArgv("/tmp/out.wav", "", 0, 22050)
    check argv == @[
      "/usr/bin/say",
      "--file-format=WAVE",
      "--data-format=LEI16@22050",
      "-o", "/tmp/out.wav",
    ]

  test "buildSayArgv inserts -v <voice> when voiceId is non-empty":
    let argv = buildSayArgv("/tmp/out.wav", "Samantha", 0, 22050)
    check argv == @[
      "/usr/bin/say",
      "--file-format=WAVE",
      "--data-format=LEI16@22050",
      "-v", "Samantha",
      "-o", "/tmp/out.wav",
    ]

  test "buildSayArgv inserts -r <wpm> when rate > 0":
    let argv = buildSayArgv("/tmp/out.wav", "", 180, 22050)
    check argv == @[
      "/usr/bin/say",
      "--file-format=WAVE",
      "--data-format=LEI16@22050",
      "-r", "180",
      "-o", "/tmp/out.wav",
    ]

  test "buildSayArgv honours sample-rate override":
    let argv = buildSayArgv("/tmp/out.wav", "", 0, 44100)
    check argv[2] == "--data-format=LEI16@44100"

suite "say provider value":

  test "sayProvider builds a provider with the canonical name":
    let p = sayProvider()
    check p.name == "say"
    check p.name == SayProviderName
    check (not p.isAvailable.isNil)
    check (not p.synthesize.isNil)

  test "newSayProvider is an alias for sayProvider":
    let p1 = sayProvider()
    let p2 = newSayProvider()
    check p1.name == p2.name

  test "sayIsAvailable reflects whether /usr/bin/say exists":
    # On macOS, /usr/bin/say is always present.  On Linux / CI without
    # a Mac, it is absent.  The provider returns the file-existence
    # check verbatim, so we can compare against the same predicate.
    check sayIsAvailable() == fileExists("/usr/bin/say")

suite "speech registry":

  test "newSpeechRegistry returns an empty registry":
    let r = newSpeechRegistry()
    check (not r.isNil)
    check listSpeechProviders(r).len == 0

  test "registerSpeechProvider stores under normalised name":
    let r = newSpeechRegistry()
    registerSpeechProvider(r, sayProvider())
    check hasSpeechProvider(r, "say")
    check hasSpeechProvider(r, "SAY")
    check hasSpeechProvider(r, "macos")

  test "listSpeechProviders returns sorted canonical names":
    let r = newSpeechRegistry()
    registerSpeechProvider(r, sayProvider())
    registerSpeechProvider(r, espeakProvider())
    let names = listSpeechProviders(r)
    check names == @["espeak", "say"]

  test "getSpeechProvider raises on unknown name":
    let r = newSpeechRegistry()
    registerSpeechProvider(r, sayProvider())
    expect SpeechSynthesisError:
      discard getSpeechProvider(r, "no-such-provider")

  test "registerSpeechProvider rejects providers with empty name":
    let r = newSpeechRegistry()
    let bad = SpeechSynthesisProvider(
      name: "",
      isAvailable: proc(): bool {.gcsafe.} = true,
      synthesize: proc(t, p: string, o: SpeechSynthesisOpts) {.gcsafe.} =
        discard
    )
    expect SpeechSynthesisError:
      registerSpeechProvider(r, bad)

  test "registerSpeechProvider rejects providers with nil callbacks":
    let r = newSpeechRegistry()
    let bad = SpeechSynthesisProvider(name: "broken")
    expect SpeechSynthesisError:
      registerSpeechProvider(r, bad)

  test "newDefaultSpeechRegistry pre-registers the host-OS provider":
    let r = newDefaultSpeechRegistry()
    when defined(macosx):
      check hasSpeechProvider(r, "say")
    elif defined(linux):
      check hasSpeechProvider(r, "espeak")
    elif defined(windows):
      check hasSpeechProvider(r, "sapi")

suite "speech dispatch":

  test "synthesizeWith raises on unavailable provider":
    let r = newSpeechRegistry()
    let unavailable = SpeechSynthesisProvider(
      name: "always-down",
      isAvailable: proc(): bool {.gcsafe.} = false,
      synthesize: proc(t, p: string, o: SpeechSynthesisOpts) {.gcsafe.} =
        writeFile(p, "ignored")
    )
    registerSpeechProvider(r, unavailable)
    let opts = SpeechSynthesisOpts(providerSettings: newJObject())
    let outPath = getTempDir() / "tspeech_unavail.wav"
    expect SpeechSynthesisError:
      synthesizeWith(r, "always-down", "hi", outPath, opts)

  test "synthesizeWith raises when provider writes zero bytes":
    let r = newSpeechRegistry()
    let empty = SpeechSynthesisProvider(
      name: "writes-nothing",
      isAvailable: proc(): bool {.gcsafe.} = true,
      synthesize: proc(t, p: string, o: SpeechSynthesisOpts) {.gcsafe.} =
        writeFile(p, "")
    )
    registerSpeechProvider(r, empty)
    let opts = SpeechSynthesisOpts(providerSettings: newJObject())
    let outPath = getTempDir() / "tspeech_empty.wav"
    expect SpeechSynthesisError:
      synthesizeWith(r, "writes-nothing", "hi", outPath, opts)

  test "synthesizeWith routes the call to the registered provider":
    let r = newSpeechRegistry()
    let fake = SpeechSynthesisProvider(
      name: "fake",
      isAvailable: proc(): bool {.gcsafe.} = true,
      synthesize: proc(t, p: string, o: SpeechSynthesisOpts) {.gcsafe.} =
        writeFile(p, "PAYLOAD:" & t)
    )
    registerSpeechProvider(r, fake)
    let opts = SpeechSynthesisOpts(providerSettings: newJObject())
    let outPath = getTempDir() / "tspeech_fake.wav"
    if fileExists(outPath): removeFile(outPath)
    synthesizeWith(r, "fake", "hello-world", outPath, opts)
    check fileExists(outPath)
    check readFile(outPath) == "PAYLOAD:hello-world"

suite "speech cache key":

  test "speechCacheKeyFor is deterministic for identical inputs":
    let k1 = speechCacheKeyFor("hi", "say", "Samantha", "22050")
    let k2 = speechCacheKeyFor("hi", "say", "Samantha", "22050")
    check k1 == k2
    check k1.len == 16

  test "speechCacheKeyFor differs when text differs":
    let k1 = speechCacheKeyFor("hello", "say", "Samantha", "22050")
    let k2 = speechCacheKeyFor("goodbye", "say", "Samantha", "22050")
    check k1 != k2

  test "speechCacheKeyFor differs when provider differs":
    let k1 = speechCacheKeyFor("hi", "say", "Samantha", "22050")
    let k2 = speechCacheKeyFor("hi", "elevenlabs", "Samantha", "22050")
    check k1 != k2

  test "speechCacheKeyFor differs when voiceId differs":
    let k1 = speechCacheKeyFor("hi", "say", "Samantha", "22050")
    let k2 = speechCacheKeyFor("hi", "say", "Daniel", "22050")
    check k1 != k2

  test "speechCacheKeyFor differs when sample-rate salt differs":
    let k1 = speechCacheKeyFor("hi", "say", "Samantha", "22050")
    let k2 = speechCacheKeyFor("hi", "say", "Samantha", "44100")
    check k1 != k2

  test "speechCacheKeyFor folds provider-name aliases together":
    # macos -> say + Say -> say, so identical keys.
    let k1 = speechCacheKeyFor("hi", "Say", "Samantha", "22050")
    let k2 = speechCacheKeyFor("hi", "macos", "Samantha", "22050")
    check k1 == k2

suite "applySpeechCache round-trip":

  setup:
    let cacheDir = getTempDir() / "tspeech_cache"
    if dirExists(cacheDir): removeDir(cacheDir)
    createDir(cacheDir)
    let outWav = getTempDir() / "tspeech_cache_out.wav"
    if fileExists(outWav): removeFile(outWav)

  test "first call invokes the generator and copies into the cache":
    var calls = 0
    let gen = proc() =
      calls.inc
      writeFile(outWav, "FAKE-WAV-BYTES-A")
    let res = applySpeechCache(cacheDir, "k_aaaaaaaaaaaaaaaa", outWav, gen)
    check (not res.hit)
    check res.outputPath == outWav
    check calls == 1
    check fileExists(cacheDir / "k_aaaaaaaaaaaaaaaa.wav")
    check readFile(cacheDir / "k_aaaaaaaaaaaaaaaa.wav") ==
      "FAKE-WAV-BYTES-A"

  test "second call with the same key short-circuits the generator":
    var calls = 0
    let gen = proc() =
      calls.inc
      writeFile(outWav, "FAKE-WAV-BYTES-B")

    discard applySpeechCache(cacheDir, "k_bbbbbbbbbbbbbbbb", outWav, gen)
    check calls == 1

    let out2 = getTempDir() / "tspeech_cache_out2.wav"
    if fileExists(out2): removeFile(out2)
    let res = applySpeechCache(cacheDir, "k_bbbbbbbbbbbbbbbb", out2, gen)
    check res.hit
    check calls == 1  # generator NOT re-invoked
    check fileExists(out2)
    check readFile(out2) == "FAKE-WAV-BYTES-B"

  test "applySpeechCache raises when generator writes nothing":
    let gen = proc() =
      # Intentionally write nothing.  Make sure no stale file is left
      # at outWav from a previous test.
      if fileExists(outWav): removeFile(outWav)
    expect SpeechSynthesisError:
      discard applySpeechCache(cacheDir, "k_cccccccccccccccc",
                              outWav, gen)

# ---------------------------------------------------------------------------
# Live test — compile-time-gated.  Real `say` invocation + ffprobe.
# ---------------------------------------------------------------------------
when defined(speechLive):

  proc ffprobeJson(path: string): JsonNode =
    let ffprobe =
      block:
        let env = getEnv("FFPROBE_BIN")
        if env.len > 0 and fileExists(env): env
        else: findExe("ffprobe")
    doAssert ffprobe.len > 0 and fileExists(ffprobe),
      "ffprobe not on PATH; install ffmpeg to run the live `say` test."
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

  suite "say live render":

    test "synthesizes a real WAV via /usr/bin/say + ffprobe verification":
      when not defined(macosx):
        doAssert false,
          "speechLive is macOS-only (uses /usr/bin/say). Re-run on " &
          "macOS or omit -d:speechLive."
      doAssert fileExists("/usr/bin/say"),
        "/usr/bin/say not found — cannot run the live say test."

      let tmp = getTempDir() / "tspeech_live"
      if dirExists(tmp): removeDir(tmp)
      createDir(tmp)

      let r = newDefaultSpeechRegistry()
      let outWav = tmp / "say-live.wav"
      let opts = SpeechSynthesisOpts(
        voiceId: none(string),
        rate: none(int),
        sampleRateHz: some(22050),
        cacheDir: some(tmp / "cache"),
        providerSettings: newJObject(),
        extraArgs: @[],
      )
      synthesizeWith(r, "say",
                    "Hello GuiAssert speech synthesis live test.",
                    outWav, opts)

      doAssert fileExists(outWav), "no WAV at " & outWav
      let sz = getFileSize(outWav)
      echo &"  say live WAV size: {sz} bytes"
      check sz > 1024

      let probe = ffprobeJson(outWav)
      var hasAudio = false
      var sampleRate = 0
      for s in probe{"streams"}.items:
        let kind = s{"codec_type"}.getStr()
        if kind == "audio":
          hasAudio = true
          let rateNode = s{"sample_rate"}
          if not rateNode.isNil and rateNode.kind == JString:
            sampleRate = parseInt(rateNode.getStr())
      check hasAudio
      check sampleRate == 22050

      let formatName = probe{"format", "format_name"}.getStr()
      echo &"  format_name: {formatName}, sample_rate: {sampleRate}"
      check "wav" in formatName.toLowerAscii()

      let dur = parseFloat(probe{"format", "duration"}.getStr())
      echo &"  say live duration: {dur:.3f}s"
      check dur > 0.5
