## GuiAssert Zero-Dependency Local Text-to-Speech Synthesis
##
## This module exposes a single high-level proc, `synthesize`, that turns a
## narration string into a WAV file on disk using whatever local TTS engine
## is available on the host operating system. No cloud APIs, no Python
## runtimes, no auxiliary binaries beyond what each OS ships in its base
## install (or what the standard Nix dev shell already provisions).
##
## Backend dispatch:
##
##   * macOS   — `/usr/bin/say` is the canonical local TTS utility on Darwin
##               (matching the GuiAssert spec's "NSSpeechSynthesizer Obj-C
##               API or the `say` command utility" choice). We invoke it with
##               `--file-format=WAVE --data-format=LEI16@22050` to write a
##               standards-compliant 16-bit little-endian PCM RIFF WAV file
##               at 22.05 kHz mono. We pass the text via stdin to avoid
##               argv length and quoting surprises.
##
##   * Windows — SAPI 5 via Win32 COM, driven through a single PowerShell
##               one-liner that creates a `System.Speech.Synthesis.SpeechSynthesizer`,
##               sets its output to a WAV via `SetOutputToWaveFile`, and
##               speaks the narration. Since this module is exercised today
##               on macOS, the Windows path is gated behind
##               `when defined(windows):` and emits the canonical argv that a
##               future Windows CI machine can wire up. The proc still runs
##               the subprocess for real when the binary is built on Windows.
##
##   * Linux   — `espeak-ng -w <out> <text>`. espeak-ng is a small, fully
##               offline synthesizer that the standard Nix dev shell can
##               provision in a few hundred kilobytes. We deliberately do not
##               reach for Coqui-TTS (large Python runtime) or for a cloud
##               REST API (non-reproducible, network-dependent) — the
##               Video-Session-Capture spec presents these as
##               interchangeable options and espeak-ng is the simplest and
##               most reproducible of the three.
##
## All backends share the same post-conditions:
##   * the output file exists,
##   * the output file is non-empty,
##   * any failure surfaces as a typed `TtsError` exception with a
##     human-readable diagnostic.

import std/[os, osproc, streams, strutils]

type
  TtsError* = object of CatchableError
    ## Raised when text-to-speech synthesis fails for any reason: missing
    ## backend binary, non-zero exit, missing or empty output file.

# ---------------------------------------------------------------------------
# Argv construction helpers (pure, side-effect free, testable)
# ---------------------------------------------------------------------------

proc buildMacSayArgv*(outputWavPath: string): seq[string] =
  ## Returns the argv used to invoke `/usr/bin/say` so it writes a
  ## little-endian 16-bit PCM WAV at 22.05 kHz mono to `outputWavPath`.
  ## The narration text is fed via stdin (the `-f /dev/stdin` style would
  ## also work, but reading stdin by default is the documented behaviour
  ## when no `-f` and no positional argument are supplied).
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
  ## Returns the PowerShell argv that, when executed on Windows, drives
  ## SAPI's `System.Speech.Synthesis.SpeechSynthesizer` to write a WAV file.
  ##
  ## The one-liner is intentionally self-contained: it loads the
  ## `System.Speech` assembly, instantiates a synthesizer, redirects output
  ## to the requested WAV path, speaks the text, and disposes the object.
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
# Backend runners
# ---------------------------------------------------------------------------

proc runMacSay(text, outputWavPath: string) =
  ## Run `say` with the text piped on stdin. We use `startProcess` so we can
  ## hand the binary the text via stdin rather than as argv (sidestepping
  ## shell quoting for newlines, quotes, parentheses, etc.).
  let argv = buildMacSayArgv(outputWavPath)
  let process = startProcess(
    command = argv[0],
    args = argv[1 .. ^1],
    options = {poUsePath, poStdErrToStdOut}
  )
  try:
    let stdinStream = process.inputStream()
    stdinStream.write(text)
    stdinStream.close()
    let exitCode = process.waitForExit()
    if exitCode != 0:
      let output = process.outputStream().readAll()
      raise newException(
        TtsError,
        "macOS `say` exited with code " & $exitCode & ": " & output.strip()
      )
  finally:
    process.close()

proc runEspeakNg(text, outputWavPath: string) =
  ## Run `espeak-ng -w <out> <text>` on Linux. We use `execProcess` because
  ## the text appears once on the command line and no stdin streaming is
  ## required.
  let argv = buildEspeakNgArgv(text, outputWavPath)
  if findExe(argv[0]).len == 0:
    raise newException(
      TtsError,
      "espeak-ng not found on PATH; install it via `nix profile install nixpkgs#espeak-ng` " &
      "or the equivalent on your distribution."
    )
  let (output, exitCode) = execCmdEx(
    quoteShellCommand(argv),
    options = {poUsePath, poStdErrToStdOut}
  )
  if exitCode != 0:
    raise newException(
      TtsError,
      "espeak-ng exited with code " & $exitCode & ": " & output.strip()
    )

proc runWindowsSapi(text, outputWavPath: string) =
  ## Run the PowerShell SAPI one-liner on Windows.
  let argv = buildWindowsSapiArgv(text, outputWavPath)
  let (output, exitCode) = execCmdEx(
    quoteShellCommand(argv),
    options = {poUsePath, poStdErrToStdOut}
  )
  if exitCode != 0:
    raise newException(
      TtsError,
      "Windows SAPI PowerShell synth exited with code " & $exitCode & ": " &
      output.strip()
    )

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc synthesize*(text: string, outputWavPath: string) =
  ## Synthesize `text` to a WAV file at `outputWavPath` using the host OS's
  ## local TTS engine. Raises `TtsError` if the engine is missing, exits
  ## non-zero, or fails to produce a non-empty file.
  if text.len == 0:
    raise newException(TtsError, "Refusing to synthesize an empty narration string.")

  # Make sure the parent directory exists; `say` and friends do not create
  # parents on demand.
  let parent = outputWavPath.parentDir()
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)

  # Remove any stale file at the destination so we can unambiguously assert
  # the engine produced fresh output below.
  if fileExists(outputWavPath):
    removeFile(outputWavPath)

  when defined(macosx):
    if not fileExists("/usr/bin/say"):
      raise newException(
        TtsError,
        "/usr/bin/say not found; macOS TTS backend unavailable."
      )
    runMacSay(text, outputWavPath)
  elif defined(windows):
    runWindowsSapi(text, outputWavPath)
  elif defined(linux):
    runEspeakNg(text, outputWavPath)
  else:
    raise newException(
      TtsError,
      "No local TTS backend implemented for this OS."
    )

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
