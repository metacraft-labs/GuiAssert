## Built-in `say` speech-synthesis provider (macOS).
##
## Wraps `/usr/bin/say`, the canonical local TTS utility on Darwin,
## with the same `--file-format=WAVE --data-format=LEI16@<rate>` flags
## the legacy `gui_assert/speech_synth` dispatcher has used since the
## first GuiAssert release.  Honours:
##
##   * `opts.voiceId`         — passed through as `-v <name>` when set
##                              (e.g. "Samantha").  Omitted when unset,
##                              which lets `say` use the system default.
##   * `opts.rate`            — passed through as `-r <wpm>` when set.
##   * `opts.sampleRateHz`    — drives the `LEI16@<rate>` data-format
##                              suffix.  Defaults to 22050 Hz.
##
## The text is fed via stdin to sidestep argv length and quoting
## surprises (newlines, quotes, parentheses, etc.).

import std/[options, os, osproc, streams, strutils]

import ./core

const SayProviderName* = "say"

proc buildSayArgv*(outputWavPath: string, voiceId: string,
                  rate: int, sampleRateHz: int): seq[string] =
  ## Returns the argv used to invoke `/usr/bin/say` so it writes a
  ## little-endian 16-bit PCM WAV at `sampleRateHz` mono to
  ## `outputWavPath`.  `voiceId` is appended as `-v <id>` when
  ## non-empty; `rate` is appended as `-r <wpm>` when > 0.
  result = @[
    "/usr/bin/say",
    "--file-format=WAVE",
    "--data-format=LEI16@" & $sampleRateHz,
  ]
  if voiceId.len > 0:
    result.add @["-v", voiceId]
  if rate > 0:
    result.add @["-r", $rate]
  result.add @["-o", outputWavPath]

proc runSay(text, outputWavPath: string, voiceId: string,
           rate: int, sampleRateHz: int) =
  ## Run `say` with the text piped on stdin.
  let argv = buildSayArgv(outputWavPath, voiceId, rate, sampleRateHz)
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
        SpeechSynthesisError,
        "macOS `say` exited with code " & $exitCode & ": " & output.strip()
      )
  finally:
    process.close()

proc sayIsAvailable*(): bool {.gcsafe.} =
  ## True iff `/usr/bin/say` exists at the canonical location.  `say`
  ## ships with the macOS base install; this returns true on every
  ## Darwin host that hasn't manually deleted the binary.
  fileExists("/usr/bin/say")

proc sayGenerate(text, outputWavPath: string,
                opts: SpeechSynthesisOpts) {.gcsafe.} =
  ## `synthesize` callback for the built-in `say` provider.  Reads
  ## the voice / rate / sample rate knobs from `opts` and dispatches
  ## to `runSay`.  Refuses empty narration text to preserve the
  ## semantics of the legacy `synthesize(text, path)` proc.
  if text.len == 0:
    raise newException(SpeechSynthesisError,
      "say provider: refusing to synthesize an empty narration string.")
  if not sayIsAvailable():
    raise newException(SpeechSynthesisError,
      "say provider: /usr/bin/say not found; macOS TTS backend " &
      "unavailable.")
  let parent = outputWavPath.parentDir()
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)
  if fileExists(outputWavPath):
    removeFile(outputWavPath)
  let voice =
    if opts.voiceId.isSome: opts.voiceId.get
    else: ""
  let rate =
    if opts.rate.isSome: opts.rate.get
    else: 0
  let sampleRate = effectiveSampleRateHz(opts)
  runSay(text, outputWavPath, voice, rate, sampleRate)

proc sayProvider*(): SpeechSynthesisProvider =
  ## Build the `say` provider value.  Plugins compose against this
  ## same shape.
  result = SpeechSynthesisProvider(
    name: SayProviderName,
    isAvailable: sayIsAvailable,
    synthesize: sayGenerate,
  )

proc newSayProvider*(): SpeechSynthesisProvider =
  ## Alias for `sayProvider()`.  Provided to match the
  ## `newStockAvatarProvider()` naming used by the sibling
  ## talking-head built-in.
  sayProvider()
