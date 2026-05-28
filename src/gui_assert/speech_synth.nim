## GuiAssert Zero-Dependency Local Text-to-Speech Synthesis
##
## This module exposes the high-level `synthesize` proc that turns a
## narration string into a WAV file on disk using whatever local TTS
## engine is available on the host operating system.  No cloud APIs,
## no Python runtimes, no auxiliary binaries beyond what each OS
## ships in its base install (or what the standard Nix dev shell
## already provisions).
##
## ## Backend dispatch
##
## As of the M7 plugin-ecosystem refactor, dispatch goes through the
## `SpeechSynthesisRegistry` defined in
## `gui_assert/speech_synthesis/core`.  The built-in providers live
## under `gui_assert/speech_synthesis` and are pre-registered by
## `newDefaultSpeechRegistry()`:
##
##   * macOS   — `/usr/bin/say` invoked with
##               `--file-format=WAVE --data-format=LEI16@22050` to
##               write a 16-bit little-endian PCM RIFF WAV at
##               22.05 kHz mono.  Text is fed via stdin.
##   * Windows — SAPI 5 via PowerShell + `System.Speech.Synthesis`.
##   * Linux   — `espeak-ng -w <out> <text>`.
##
## The single-arg `synthesize(text, outputWavPath)` entry point keeps
## the legacy contract downstream consumers depend on: same signature,
## same `TtsError` exception type, same post-conditions.  Internally it
## builds a default registry, dispatches to the host-OS provider, and
## translates `SpeechSynthesisError` -> `TtsError` so existing
## `except TtsError` blocks keep catching every failure mode.
##
## Consumers that want to swap in an alternative provider (e.g.
## `GuiAssert-ElevenLabs`) should import `gui_assert/speech_synthesis`
## directly, build their own registry, and call `synthesizeWith`.
##
## All post-conditions remain:
##   * the output file exists,
##   * the output file is non-empty,
##   * any failure surfaces as a typed `TtsError` exception with a
##     human-readable diagnostic.

import std/[options, os, strutils]

import ./speech_synthesis
export speech_synthesis

type
  TtsError* = object of CatchableError
    ## Raised when text-to-speech synthesis fails for any reason: missing
    ## backend binary, non-zero exit, missing or empty output file.
    ## Preserved as a distinct type from the new `SpeechSynthesisError`
    ## so existing `except TtsError` blocks in downstream consumers
    ## (e.g. `editor_backend.nim`) keep catching every legacy failure.

# ---------------------------------------------------------------------------
# Argv construction helpers (pure, side-effect free, testable).
# These were the public surface of the pre-M7 module and remain exported
# so any caller that wired against them keeps compiling.  The actual
# subprocess invocations now live in the per-provider modules under
# `gui_assert/speech_synthesis/`.
# ---------------------------------------------------------------------------

proc buildMacSayArgv*(outputWavPath: string): seq[string] =
  ## Returns the argv used to invoke `/usr/bin/say` so it writes a
  ## little-endian 16-bit PCM WAV at 22.05 kHz mono to `outputWavPath`.
  ## Kept for backwards compatibility; the live `say` provider uses
  ## `gui_assert/speech_synthesis/say_provider.buildSayArgv`, which
  ## adds optional `-v` / `-r` / variable sample-rate support.
  @[
    "/usr/bin/say",
    "--file-format=WAVE",
    "--data-format=LEI16@22050",
    "-o", outputWavPath
  ]

proc buildEspeakNgArgv*(text, outputWavPath: string): seq[string] =
  ## Returns the argv for espeak-ng to produce a WAV at `outputWavPath`.
  @["espeak-ng", "-w", outputWavPath, text]

proc buildWindowsSapiArgv*(text, outputWavPath: string): seq[string] =
  ## Returns the PowerShell argv that drives SAPI on Windows.
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

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc synthesize*(text: string, outputWavPath: string) =
  ## Synthesize `text` to a WAV file at `outputWavPath` using the host
  ## OS's local TTS engine.  Raises `TtsError` if the engine is
  ## missing, exits non-zero, or fails to produce a non-empty file.
  ##
  ## As of M7 this is a thin wrapper over the
  ## `SpeechSynthesisRegistry` contract: it builds the default
  ## host-OS registry and dispatches to the appropriate built-in
  ## provider.  `SpeechSynthesisError` instances raised by the
  ## provider are re-raised as `TtsError` so existing call sites
  ## (e.g. `editor_backend.nim`) keep catching every failure mode
  ## through the legacy exception type.
  if text.len == 0:
    raise newException(TtsError,
      "Refusing to synthesize an empty narration string.")

  let parent = outputWavPath.parentDir()
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)

  # Remove any stale file at the destination so we can unambiguously
  # assert the engine produced fresh output below.
  if fileExists(outputWavPath):
    removeFile(outputWavPath)

  let registry = newDefaultSpeechRegistry()
  let hostName = defaultHostProviderName()
  let opts = SpeechSynthesisOpts(
    voiceId: none(string),
    rate: none(int),
    sampleRateHz: none(int),
    cacheDir: none(string),
    providerSettings: nil,
    extraArgs: @[],
  )
  try:
    synthesizeWith(registry, hostName, text, outputWavPath, opts)
  except SpeechSynthesisError as e:
    raise newException(TtsError, e.msg)

  # Post-conditions
  if not fileExists(outputWavPath):
    raise newException(
      TtsError,
      "TTS backend reported success but no file at " & outputWavPath
    )
  let size = getFileSize(outputWavPath)
  if size <= 0:
    raise newException(
      TtsError,
      "TTS backend produced a zero-byte file at " & outputWavPath
    )
