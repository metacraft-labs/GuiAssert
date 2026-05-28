## Speech-synthesis (TTS) provider interface (plugin contract).
##
## Wraps the various local + commercial providers that turn a
## narration string into a WAV file on disk.  Sibling plugin repos
## (e.g. `GuiAssert-ElevenLabs`) implement the
## `SpeechSynthesisProvider` contract from
## `gui_assert/speech_synthesis/core`; this umbrella module additionally
## ships the lightweight built-ins (`say` on macOS, `sapi` on Windows,
## `espeak` on Linux) that the existing non-pluggable
## `gui_assert/speech_synth` dispatcher already uses.
##
## ## Plugin model
##
## The plugin model mirrors `gui_assert/talking_head`:
##
##   * The `SpeechSynthesisProvider` value type wires `name` +
##     `isAvailable` + `synthesize` together.
##   * The `SpeechSynthesisRegistry` ref maps canonical provider names
##     to provider values.
##   * `newSpeechRegistry()` returns a registry; `newDefaultSpeechRegistry()`
##     additionally pre-registers the host-OS built-in.
##
## ## Backward compatibility
##
## The existing top-level `synthesize(text, outputWavPath)` proc in
## `gui_assert/speech_synth` continues to work unchanged for downstream
## callers.  Internally it now goes through `newDefaultSpeechRegistry()`
## plus `synthesizeWith`, so the new contract is exercised by every
## legacy call site too.

import std/[options, os, osproc, strutils]

import ./speech_synthesis/core
import ./speech_synthesis/say_provider

export core
export say_provider

# ---------------------------------------------------------------------------
# Linux espeak-ng built-in
# ---------------------------------------------------------------------------

const EspeakProviderName* = "espeak"

proc buildEspeakNgArgvCore*(text, outputWavPath: string): seq[string] =
  ## Argv for `espeak-ng -w <out> <text>`.  Voice / rate are honoured
  ## via the optional `-v` / `-s` flags layered on top by
  ## `espeakSynthesize`.
  @["espeak-ng", "-w", outputWavPath, text]

proc espeakIsAvailable(): bool {.gcsafe.} =
  findExe("espeak-ng").len > 0

proc espeakSynthesize(text, outputWavPath: string,
                     opts: SpeechSynthesisOpts) {.gcsafe.} =
  if text.len == 0:
    raise newException(SpeechSynthesisError,
      "espeak provider: refusing to synthesize an empty narration string.")
  let exe = findExe("espeak-ng")
  if exe.len == 0:
    raise newException(SpeechSynthesisError,
      "espeak provider: espeak-ng not found on PATH; install via " &
      "`nix profile install nixpkgs#espeak-ng` or the distribution " &
      "equivalent.")
  let parent = outputWavPath.parentDir()
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)
  if fileExists(outputWavPath):
    removeFile(outputWavPath)
  var argv = @[exe, "-w", outputWavPath]
  if opts.voiceId.isSome and opts.voiceId.get.len > 0:
    argv.add @["-v", opts.voiceId.get]
  if opts.rate.isSome and opts.rate.get > 0:
    argv.add @["-s", $opts.rate.get]
  argv.add text
  let (output, exitCode) = execCmdEx(
    quoteShellCommand(argv),
    options = {poUsePath, poStdErrToStdOut}
  )
  if exitCode != 0:
    raise newException(SpeechSynthesisError,
      "espeak-ng exited with code " & $exitCode & ": " & output.strip())

proc espeakProvider*(): SpeechSynthesisProvider =
  result = SpeechSynthesisProvider(
    name: EspeakProviderName,
    isAvailable: espeakIsAvailable,
    synthesize: espeakSynthesize,
  )

# ---------------------------------------------------------------------------
# Windows SAPI built-in
# ---------------------------------------------------------------------------

const SapiProviderName* = "sapi"

proc buildWindowsSapiArgvCore*(text, outputWavPath: string): seq[string] =
  ## Argv for the PowerShell SAPI one-liner.  Mirrors the legacy
  ## `gui_assert/speech_synth.buildWindowsSapiArgv` shape so Windows
  ## CI hosts have one canonical pipeline.
  let escapedText = text.replace("'", "''")
  let escapedPath = outputWavPath.replace("'", "''")
  let script =
    "Add-Type -AssemblyName System.Speech; " &
    "$s = New-Object System.Speech.Synthesis.SpeechSynthesizer; " &
    "$s.SetOutputToWaveFile('" & escapedPath & "'); " &
    "$s.Speak('" & escapedText & "'); " &
    "$s.Dispose()"
  @[
    "powershell.exe",
    "-NoProfile",
    "-NonInteractive",
    "-Command", script
  ]

proc sapiIsAvailable(): bool {.gcsafe.} =
  when defined(windows): true
  else: false

proc sapiSynthesize(text, outputWavPath: string,
                   opts: SpeechSynthesisOpts) {.gcsafe.} =
  discard opts  # SAPI honours system voice settings; no per-call knobs yet.
  if text.len == 0:
    raise newException(SpeechSynthesisError,
      "sapi provider: refusing to synthesize an empty narration string.")
  when not defined(windows):
    raise newException(SpeechSynthesisError,
      "sapi provider: only available on Windows builds.")
  else:
    let parent = outputWavPath.parentDir()
    if parent.len > 0 and not dirExists(parent):
      createDir(parent)
    if fileExists(outputWavPath):
      removeFile(outputWavPath)
    let argv = buildWindowsSapiArgvCore(text, outputWavPath)
    let (output, exitCode) = execCmdEx(
      quoteShellCommand(argv),
      options = {poUsePath, poStdErrToStdOut}
    )
    if exitCode != 0:
      raise newException(SpeechSynthesisError,
        "Windows SAPI PowerShell synth exited with code " & $exitCode &
        ": " & output.strip())

proc sapiProvider*(): SpeechSynthesisProvider =
  result = SpeechSynthesisProvider(
    name: SapiProviderName,
    isAvailable: sapiIsAvailable,
    synthesize: sapiSynthesize,
  )

# ---------------------------------------------------------------------------
# Default host-OS registry
# ---------------------------------------------------------------------------

proc defaultHostProvider*(): SpeechSynthesisProvider =
  ## Returns the built-in provider for the current host OS.  This is
  ## the provider that the legacy `gui_assert/speech_synth.synthesize`
  ## proc dispatches to under the hood.
  when defined(macosx):
    result = sayProvider()
  elif defined(windows):
    result = sapiProvider()
  elif defined(linux):
    result = espeakProvider()
  else:
    # Defer the error to dispatch time: build a provider whose
    # `isAvailable` is always false so the caller sees a clean
    # diagnostic from `synthesizeWith` rather than a compile-time
    # surprise.
    let unavailable = proc(): bool {.gcsafe.} = false
    let raiseProc = proc(text, outputWavPath: string,
                         opts: SpeechSynthesisOpts) {.gcsafe.} =
      discard text; discard outputWavPath; discard opts
      raise newException(SpeechSynthesisError,
        "no built-in speech-synthesis provider for this OS.")
    result = SpeechSynthesisProvider(
      name: "unsupported",
      isAvailable: unavailable,
      synthesize: raiseProc,
    )

proc defaultHostProviderName*(): string =
  ## Canonical name of the host-OS built-in.  Used by
  ## `gui_assert/speech_synth.synthesize` to route through
  ## `synthesizeWith`.
  when defined(macosx): SayProviderName
  elif defined(windows): SapiProviderName
  elif defined(linux): EspeakProviderName
  else: "unsupported"

proc newDefaultSpeechRegistry*(): SpeechSynthesisRegistry =
  ## Returns a registry with the host-OS built-in already registered.
  ## Plugins layer more providers via `registerSpeechProvider`.
  result = newSpeechRegistry()
  registerSpeechProvider(result, defaultHostProvider())
