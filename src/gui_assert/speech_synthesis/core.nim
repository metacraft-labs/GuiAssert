## Core types + registry for the speech-synthesis (TTS) plugin contract.
##
## GuiAssert ships a non-pluggable, host-OS-driven text-to-speech
## dispatcher in `gui_assert/speech_synth` (macOS `say`, Windows SAPI,
## Linux `espeak-ng`).  That dispatcher remains the primary entry point
## for consumers that just want a WAV on disk without caring which
## backend produced it.  The contract defined in this module is the
## second, *pluggable* TTS surface: it lets sibling plugin repos
## (e.g. `GuiAssert-ElevenLabs`) provide alternative voices whose
## runtime cost or licence terms differ from the host-OS defaults.
##
## The shape of the contract intentionally mirrors
## `gui_assert/talking_head/core` — same `Opts` / `Provider` /
## `Registry` triple, same `cacheKeyFor` + `applyCache` helpers — so
## that plugin authors who have already written one provider have
## almost no new surface area to learn for the second.
##
## ## Module layout
##
##   * `gui_assert/speech_synthesis/core` (this module) — types,
##     registry, helpers.  No subprocess or HTTP code; safe for
##     header-only plugin authors.
##   * `gui_assert/speech_synthesis/say_provider` — the built-in
##     `say` provider (macOS).  Shells out to `/usr/bin/say` + ffmpeg.
##   * `gui_assert/speech_synthesis` (umbrella) — re-exports both
##     and adds `newSpeechRegistry()`, which returns a registry with
##     the appropriate built-in for the host OS already registered.

import std/[algorithm, json, options, os, sha1, strutils, tables]

type
  SpeechSynthesisOpts* = object
    ## Provider-agnostic runtime configuration.
    voiceId*: Option[string]
      ## Provider-specific voice identifier — e.g. an ElevenLabs voice
      ## id (`21m00Tcm4TlvDq8ikWAM`) or a `say` voice name
      ## (`Samantha`).  Plugins fall back to a sensible default when
      ## unset.
    rate*: Option[int]
      ## Words per minute, for `say`-like backends that expose a rate
      ## knob.  Cloud TTS providers typically ignore this.
    sampleRateHz*: Option[int]
      ## Output WAV sample rate.  Defaults to 22050 Hz to match the
      ## existing `gui_assert/speech_synth` non-pluggable dispatcher.
    cacheDir*: Option[string]
      ## Override for the on-disk cache directory.  When unset, plugins
      ## should default to `defaultSpeechCacheDir()`.
    providerSettings*: JsonNode
      ## Plugin-specific structured config, opaque to GuiAssert.  Used
      ## by HTTP-API plugins to carry api_key / api_base / model
      ## overrides without bloating the core opts shape.
    extraArgs*: seq[string]
      ## Provider-specific extra CLI args, for plugins that exec a
      ## subprocess.

  SpeechSynthesisAvailabilityProc* = proc(): bool {.gcsafe.}
    ## Returns `true` iff the provider's runtime dependencies are
    ## present.  Cheap to call; plugins should not perform real TTS
    ## synthesis here.

  SpeechSynthesisProviderProc* = proc(text, outputWavPath: string,
                                      opts: SpeechSynthesisOpts) {.gcsafe.}
    ## Produces a WAV at `outputWavPath` for the given narration text.
    ## Blocks until synthesis completes.  Raises
    ## `SpeechSynthesisError` (or a subclass) on failure.

  SpeechSynthesisProvider* = object
    ## The plugin contract.  Built-ins and plugins both build values of
    ## this shape and pass them to `registerSpeechProvider`.
    name*: string
      ## Stable identifier — e.g. "say", "elevenlabs", "sapi",
      ## "espeak".  Looked up case-insensitively at dispatch time.
    isAvailable*: SpeechSynthesisAvailabilityProc
    synthesize*: SpeechSynthesisProviderProc

  SpeechSynthesisRegistry* = ref object
    ## Mutable lookup from provider name to provider value.  Construct
    ## via the umbrella module's `newSpeechRegistry`, which pre-registers
    ## the appropriate host-OS built-in.
    providers*: Table[string, SpeechSynthesisProvider]

  SpeechSynthesisError* = object of CatchableError

# ---------------------------------------------------------------------------
# Provider-name normalisation
# ---------------------------------------------------------------------------

proc normalizeSpeechProviderName*(name: string): string =
  ## Canonical form: lowercase, trimmed, common aliases collapsed.
  let n = name.strip.toLowerAscii
  case n
  of "macos", "darwin", "say": "say"
  of "windows", "win", "sapi", "sapi5": "sapi"
  of "linux", "espeak", "espeak-ng", "espeakng": "espeak"
  of "11labs", "eleven-labs", "eleven_labs", "elevenlabs": "elevenlabs"
  else: n

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

const
  DefaultSpeechSampleRateHz* = 22050
    ## Matches the legacy `gui_assert/speech_synth` macOS pipeline:
    ## 16-bit little-endian PCM mono at 22.05 kHz.

proc defaultSpeechCacheDir*(): string =
  ## `$XDG_CACHE_HOME/gui_assert/speech_synthesis/`.  Falls back to
  ## `$HOME/.cache/gui_assert/speech_synthesis/` per the XDG spec.
  let xdg = getEnv("XDG_CACHE_HOME")
  let base =
    if xdg.len > 0: xdg
    else: getHomeDir() / ".cache"
  result = base / "gui_assert" / "speech_synthesis"

proc effectiveSampleRateHz*(opts: SpeechSynthesisOpts): int =
  if opts.sampleRateHz.isSome and opts.sampleRateHz.get > 0:
    opts.sampleRateHz.get
  else: DefaultSpeechSampleRateHz

proc effectiveSpeechCacheDir*(opts: SpeechSynthesisOpts): string =
  if opts.cacheDir.isSome and opts.cacheDir.get.len > 0: opts.cacheDir.get
  else: defaultSpeechCacheDir()

proc effectiveVoiceId*(opts: SpeechSynthesisOpts, default: string): string =
  if opts.voiceId.isSome and opts.voiceId.get.len > 0: opts.voiceId.get
  else: default

# ---------------------------------------------------------------------------
# Cache helpers shared between plugins
# ---------------------------------------------------------------------------

proc digestToHex(d: Sha1Digest): string =
  ## Convert a 20-byte Sha1Digest to a 40-char lowercase hex string.
  result = newStringOfCap(40)
  for b in d:
    result.add(b.toHex(2).toLowerAscii)

proc speechCacheKeyFor*(text, providerName, voiceId,
                        sampleRateHash: string): string =
  ## Stable hash of (text + provider name + voice id + sample-rate
  ## salt).  Returns 16 lowercase hex characters (~64 bits — plenty
  ## for an on-disk cache holding at most thousands of deterministic
  ## entries).
  ##
  ## `sampleRateHash` is a free-form string the caller folds in (e.g.
  ## `$sampleRateHz`) — kept as a string so a future revision can mix
  ## in additional discriminators without breaking the signature.
  var ctx: Sha1State = newSha1State()
  ctx.update(normalizeSpeechProviderName(providerName))
  ctx.update("|")
  ctx.update(voiceId)
  ctx.update("|")
  ctx.update(sampleRateHash)
  ctx.update("|")
  ctx.update(text)
  let full = digestToHex(ctx.finalize())
  result = full[0 ..< 16]

proc applySpeechCache*(cacheDir, cacheKey, outputWavPath: string,
                      generator: proc(): void): tuple[hit: bool,
                                                      outputPath: string] =
  ## Helper for plugins: checks `cacheDir/<cacheKey>.wav`.  If the file
  ## exists and is non-empty, copies it to `outputWavPath` and returns
  ## `(hit: true, ...)`.  Otherwise calls `generator` (which must write
  ## the WAV to `outputWavPath`), then caches the result by copying
  ## `outputWavPath` to `<cacheDir>/<cacheKey>.wav`.
  ##
  ## The cache copy step is best-effort: failures (e.g. read-only
  ## cacheDir) are swallowed so a successful synthesis is still
  ## returned.
  if cacheDir.len > 0 and not dirExists(cacheDir):
    createDir(cacheDir)
  let cachedWav = cacheDir / (cacheKey & ".wav")
  if fileExists(cachedWav) and getFileSize(cachedWav) > 0:
    let outParent = outputWavPath.parentDir()
    if outParent.len > 0 and not dirExists(outParent):
      createDir(outParent)
    copyFile(cachedWav, outputWavPath)
    return (hit: true, outputPath: outputWavPath)
  generator()
  if not fileExists(outputWavPath) or getFileSize(outputWavPath) == 0:
    raise newException(SpeechSynthesisError,
      "speech-synthesis provider generator returned but did not " &
      "produce " & outputWavPath)
  try:
    if cacheDir.len > 0:
      copyFile(outputWavPath, cachedWav)
  except OSError:
    # Caching is best-effort; do not let a cache-write failure mask
    # a successful synthesis.
    discard
  result = (hit: false, outputPath: outputWavPath)

# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------

proc newSpeechRegistry*(): SpeechSynthesisRegistry =
  ## Returns an empty `SpeechSynthesisRegistry`.  The umbrella module's
  ## host-OS helper layers the appropriate built-in (`sayProvider` on
  ## macOS, etc.) on top of this.
  result = SpeechSynthesisRegistry(
    providers: initTable[string, SpeechSynthesisProvider]()
  )

proc registerSpeechProvider*(r: SpeechSynthesisRegistry,
                            p: SpeechSynthesisProvider) =
  ## Insert / overwrite a provider keyed by its canonical name.
  if r.isNil:
    raise newException(SpeechSynthesisError,
      "registerSpeechProvider: registry is nil")
  if p.name.len == 0:
    raise newException(SpeechSynthesisError,
      "registerSpeechProvider: provider has empty name")
  if p.isAvailable.isNil or p.synthesize.isNil:
    raise newException(SpeechSynthesisError,
      "registerSpeechProvider: provider '" & p.name &
      "' is missing isAvailable / synthesize procs")
  r.providers[normalizeSpeechProviderName(p.name)] = p

proc hasSpeechProvider*(r: SpeechSynthesisRegistry, name: string): bool =
  ## Returns true iff a provider by this canonical name is registered.
  if r.isNil:
    return false
  normalizeSpeechProviderName(name) in r.providers

proc listSpeechProviders*(r: SpeechSynthesisRegistry): seq[string] =
  ## Sorted list of registered provider names (canonical form).
  result = @[]
  if r.isNil:
    return
  for k in r.providers.keys:
    result.add k
  result.sort(cmp)

proc getSpeechProvider*(r: SpeechSynthesisRegistry,
                       name: string): SpeechSynthesisProvider =
  ## Look up a registered provider by name.  Raises
  ## `SpeechSynthesisError` when the name is unknown.
  let canonical = normalizeSpeechProviderName(name)
  if r.isNil or canonical notin r.providers:
    raise newException(SpeechSynthesisError,
      "unknown speech-synthesis provider: '" & name &
      "'. Registered providers: " & listSpeechProviders(r).join(", "))
  result = r.providers[canonical]

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

proc synthesizeWith*(r: SpeechSynthesisRegistry, providerName: string,
                    text, outputWavPath: string,
                    opts: SpeechSynthesisOpts) =
  ## Synthesise `text` to a WAV at `outputWavPath` using the registered
  ## provider named `providerName`.  Blocks until synthesis completes.
  ##
  ## Raises `SpeechSynthesisError` if the provider is unknown,
  ## currently unavailable, or fails to produce a non-empty WAV.
  let outParent = outputWavPath.parentDir()
  if outParent.len > 0 and not dirExists(outParent):
    createDir(outParent)
  let provider = getSpeechProvider(r, providerName)
  if not provider.isAvailable():
    raise newException(SpeechSynthesisError,
      "speech-synthesis provider '" & provider.name &
      "' is registered but its dependencies are missing. " &
      "Run the plugin's install / setup script before re-trying.")
  provider.synthesize(text, outputWavPath, opts)
  if not fileExists(outputWavPath) or getFileSize(outputWavPath) == 0:
    raise newException(SpeechSynthesisError,
      "speech-synthesis provider '" & provider.name &
      "' returned success but produced no WAV at " & outputWavPath)
