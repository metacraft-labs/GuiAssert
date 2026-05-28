## Talking-head provider interface
##
## Wraps the various AI/non-AI providers that turn a narration WAV +
## portrait image into an animated talking-head MP4.  The marketing
## runner composes this MP4 into the bottom-right corner of the final
## demo video via `media.composeVideoWithOverlay`.
##
## Supported providers:
##
##   * `thpStockAvatar` — the legacy `testsrc2` placeholder. Used when
##     no live model is wanted (CI dry-runs, smoke tests, fallback for
##     scripts that don't opt in to a generative provider).
##   * `thpSadTalker`   — local SadTalker invocation via the Python
##     wrapper at `codetracer-marketing/tools/sadtalker/render_talking_head.py`.
##     SadTalker is installed in a Python 3.10 venv and accelerated by
##     Apple's MPS backend on Apple Silicon.
##   * `thpDid`, `thpHeyGen`, `thpHedra` — reserved stub identifiers
##     for future cloud providers.  Calling them raises
##     `TalkingHeadError` until they are implemented.
##
## All providers produce a single MP4 at `outputMp4`.  The MP4 has at
## minimum one video stream; whether it also has an audio stream is
## provider-specific.  Downstream consumers (the marketing compose
## pipeline) ignore the avatar's audio track and inject narration via
## a separate input.
##
## ## Caching
##
## Generation is expensive (SadTalker takes ~minutes on Apple Silicon).
## Results are cached on disk in `opts.cacheDir` (default
## `$XDG_CACHE_HOME/gui_assert/talking_head/`).  The cache key is a
## SHA-256 digest of the avatar image bytes + narration WAV bytes +
## provider name + device, truncated to 16 hex characters.  A cache
## hit copies the cached MP4 to `outputMp4` and returns immediately;
## a miss invokes the provider and stores the produced MP4 under
## `<cacheDir>/<key>.mp4` next to a log file documenting the run.

import std/[options, os, osproc, sha1, streams, strutils, strformat, tables,
            times]

import ./parser

type
  TalkingHeadProvider* = enum
    thpStockAvatar = "stock_avatar"
    thpSadTalker   = "sadtalker"
    thpDid         = "did"
    thpHeyGen      = "heygen"
    thpHedra       = "hedra"

  TalkingHeadOpts* = object
    ## Provider-agnostic runtime configuration.  See module docs for
    ## defaults.
    provider*: TalkingHeadProvider
    avatarImagePath*: Option[string]
    pythonBinary*: Option[string]
    renderScriptPath*: Option[string]
    device*: string
      ## "auto" | "mps" | "cpu" — passed through to providers that
      ## care.  Stock avatar ignores it.  Empty / "" coerces to
      ## "auto".
    cacheDir*: Option[string]
    extraArgs*: seq[string]
      ## Provider-specific extra CLI args.  SadTalker honours
      ## "--preprocess <mode>", "--size <N>", "--enhancer <name>",
      ## and "--still-mode" verbatim.

  TalkingHeadError* = object of CatchableError

const
  StockAvatarRelPath* = "assets/avatar-placeholder.mp4"
    ## Path of the legacy testsrc2 placeholder, relative to the
    ## codetracer-marketing repo root.  Documented as a constant so
    ## callers in the marketing repo can locate it without re-hardcoding
    ## the string.

# ---------------------------------------------------------------------------
# Provider-name parsing
# ---------------------------------------------------------------------------

proc parseTalkingHeadProvider*(name: string): TalkingHeadProvider =
  ## Parse a YAML-friendly provider name (e.g. "sadtalker",
  ## "stock_avatar") into the `TalkingHeadProvider` enum.  Raises
  ## `TalkingHeadError` on unknown names.  The empty string maps to
  ## `thpStockAvatar` so omitting `metadata.talking_head` is the same
  ## as opting in to the stock placeholder.
  let n = name.strip.toLowerAscii
  case n
  of "", "stock", "stock_avatar", "placeholder":
    return thpStockAvatar
  of "sadtalker":
    return thpSadTalker
  of "did", "d-id":
    return thpDid
  of "heygen":
    return thpHeyGen
  of "hedra":
    return thpHedra
  else:
    raise newException(TalkingHeadError,
      "unknown talking-head provider: '" & name & "'. Expected one of: " &
      "stock_avatar, sadtalker, did, heygen, hedra.")

proc providerName*(p: TalkingHeadProvider): string =
  ## Stable string representation matching the YAML form.  Used in the
  ## cache key.
  $p

# ---------------------------------------------------------------------------
# Defaults + path resolution
# ---------------------------------------------------------------------------

proc defaultCacheDir*(): string =
  ## `$XDG_CACHE_HOME/gui_assert/talking_head/`.  Falls back to
  ## `$HOME/.cache/gui_assert/talking_head/` per the XDG spec.
  let xdg = getEnv("XDG_CACHE_HOME")
  let base =
    if xdg.len > 0: xdg
    else: getHomeDir() / ".cache"
  result = base / "gui_assert" / "talking_head"

proc defaultDevice*(): string = "auto"

proc effectiveDevice(opts: TalkingHeadOpts): string =
  if opts.device.len == 0: defaultDevice() else: opts.device.toLowerAscii

proc effectiveCacheDir(opts: TalkingHeadOpts): string =
  if opts.cacheDir.isSome: opts.cacheDir.get
  else: defaultCacheDir()

proc resolvedPythonBinary*(opts: TalkingHeadOpts): string =
  ## Returns the python binary to invoke for `thpSadTalker`.
  ## Resolution order:
  ##   1. `opts.pythonBinary` if set.
  ##   2. `$SADTALKER_PYTHON` env var if set.
  ##   3. `<repo-root>/tools/sadtalker/.venv/bin/python` discovered by
  ##      walking up from `currentSourcePath` to the marketing repo.
  ##      The walk is bounded — we look for a "tools/sadtalker/.venv"
  ##      directory at increasingly high parents up to 6 levels deep.
  if opts.pythonBinary.isSome and opts.pythonBinary.get.len > 0:
    return opts.pythonBinary.get
  let envBin = getEnv("SADTALKER_PYTHON")
  if envBin.len > 0:
    return envBin
  # Walk up from this source file to find the marketing repo's venv.
  var dir = currentSourcePath().parentDir()
  for _ in 0 ..< 8:
    let candidate = dir / "tools" / "sadtalker" / ".venv" / "bin" / "python"
    if fileExists(candidate):
      return candidate
    let next = dir.parentDir()
    if next == dir: break
    dir = next
  # Same walk but checking sibling directories — handles the case
  # where GuiAssert and codetracer-marketing are siblings under the
  # same workspace root.
  dir = currentSourcePath().parentDir()
  for _ in 0 ..< 8:
    let candidate = dir.parentDir() / "codetracer-marketing" / "tools" /
                    "sadtalker" / ".venv" / "bin" / "python"
    if fileExists(candidate):
      return candidate
    let next = dir.parentDir()
    if next == dir: break
    dir = next
  return ""

proc resolvedRenderScript*(opts: TalkingHeadOpts): string =
  ## Same lookup contract as `resolvedPythonBinary` but for the
  ## wrapper script `render_talking_head.py`.
  if opts.renderScriptPath.isSome and opts.renderScriptPath.get.len > 0:
    return opts.renderScriptPath.get
  let envBin = getEnv("SADTALKER_RENDER_SCRIPT")
  if envBin.len > 0:
    return envBin
  var dir = currentSourcePath().parentDir()
  for _ in 0 ..< 8:
    let candidate = dir / "tools" / "sadtalker" / "render_talking_head.py"
    if fileExists(candidate):
      return candidate
    let next = dir.parentDir()
    if next == dir: break
    dir = next
  dir = currentSourcePath().parentDir()
  for _ in 0 ..< 8:
    let candidate = dir.parentDir() / "codetracer-marketing" / "tools" /
                    "sadtalker" / "render_talking_head.py"
    if fileExists(candidate):
      return candidate
    let next = dir.parentDir()
    if next == dir: break
    dir = next
  return ""

# ---------------------------------------------------------------------------
# Availability check
# ---------------------------------------------------------------------------

proc isAvailable*(provider: TalkingHeadProvider,
                  opts: TalkingHeadOpts = TalkingHeadOpts()): bool =
  ## Returns `true` iff the provider's runtime dependencies are
  ## present.  `thpStockAvatar` is always available (we synthesise the
  ## placeholder on demand).  `thpSadTalker` requires both the Python
  ## binary and the wrapper script to exist on disk.  Other providers
  ## are reserved for future work and currently always return false.
  case provider
  of thpStockAvatar:
    return true
  of thpSadTalker:
    let py = resolvedPythonBinary(opts)
    let scr = resolvedRenderScript(opts)
    return py.len > 0 and fileExists(py) and scr.len > 0 and fileExists(scr)
  else:
    return false

# ---------------------------------------------------------------------------
# Cache key
# ---------------------------------------------------------------------------

proc digestToHex(d: Sha1Digest): string =
  ## Convert a 20-byte Sha1Digest to a 40-char lowercase hex string.
  ## Nim's `$Sha1Digest` prints an array; we want hex.
  result = newStringOfCap(40)
  for b in d:
    result.add(b.toHex(2).toLowerAscii)

proc fileSha256Hex(path: string): string =
  ## Streaming SHA-1 (Nim's stdlib doesn't expose SHA-256, and the
  ## marketing pipeline doesn't need cryptographic strength here —
  ## SHA-1 is more than enough to disambiguate cache entries by
  ## avatar/narration bytes).  Returns 40-char lowercase hex.
  ##
  ## We use Nim's `std/sha1` rather than `std/sha256` because the
  ## latter isn't in the stdlib.
  if not fileExists(path):
    raise newException(TalkingHeadError, "cannot hash missing file: " & path)
  let f = newFileStream(path, fmRead)
  if f.isNil:
    raise newException(TalkingHeadError, "cannot open for hashing: " & path)
  defer: f.close()
  var ctx: Sha1State = newSha1State()
  var buf: array[64 * 1024, char]
  while true:
    let n = f.readData(addr buf[0], buf.len)
    if n <= 0: break
    ctx.update(buf.toOpenArray(0, n - 1))
  result = digestToHex(ctx.finalize())

proc computeCacheKey*(avatarPath, narrationPath: string,
                      provider: TalkingHeadProvider,
                      device: string): string =
  ## Cache key = first 16 hex chars of sha1(avatarBytes || narrationBytes
  ## || provider_name || device).  Truncating to 16 chars (~64 bits)
  ## is collision-safe for an on-disk cache that holds at most thousands
  ## of entries and is keyed by deterministic inputs.
  ##
  ## The key is independent of `outputMp4` so different callers asking
  ## for the same talking head reuse one render.
  if not fileExists(avatarPath):
    raise newException(TalkingHeadError, "avatar image not found: " & avatarPath)
  if not fileExists(narrationPath):
    raise newException(TalkingHeadError, "narration WAV not found: " & narrationPath)
  let avatarDigest = fileSha256Hex(avatarPath)
  let narrationDigest = fileSha256Hex(narrationPath)
  let salt = providerName(provider) & "|" & device
  var ctx: Sha1State = newSha1State()
  ctx.update(avatarDigest)
  ctx.update(narrationDigest)
  ctx.update(salt)
  let full = digestToHex(ctx.finalize())
  result = full[0 ..< 16]

# ---------------------------------------------------------------------------
# Stock-avatar provider — copies (or synthesises) the testsrc2 placeholder.
# ---------------------------------------------------------------------------

proc resolveStockAvatarPath(opts: TalkingHeadOpts): string =
  ## Find the legacy placeholder MP4 by walking up from
  ## `currentSourcePath` to locate `codetracer-marketing/assets/
  ## avatar-placeholder.mp4`.  This is a fallback used only when the
  ## caller hasn't pinned `opts.avatarImagePath`.
  if opts.avatarImagePath.isSome and opts.avatarImagePath.get.len > 0:
    return opts.avatarImagePath.get
  var dir = currentSourcePath().parentDir()
  for _ in 0 ..< 8:
    let candidate = dir.parentDir() / "codetracer-marketing" / StockAvatarRelPath
    if fileExists(candidate):
      return candidate
    let next = dir.parentDir()
    if next == dir: break
    dir = next
  return ""

proc ensureStockPlaceholder(outputMp4: string) =
  ## Synthesise a 5-second `testsrc2` MP4 at `outputMp4`.  Mirrors the
  ## runner's `ensureAvatarPlaceholder` but is duplicated here so
  ## GuiAssert tests don't need to import the runner.
  let parent = outputMp4.parentDir()
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)
  # Look for an ffmpeg via $FFMPEG_BIN / PATH. We deliberately avoid
  # depending on the media module's heavier resolver here — this is
  # only used as a fallback path that's already trivially exercised
  # by the runner.
  var ffmpeg = getEnv("FFMPEG_BIN")
  if ffmpeg.len == 0:
    ffmpeg = findExe("ffmpeg")
  if ffmpeg.len == 0:
    raise newException(TalkingHeadError,
      "ffmpeg not on PATH; cannot synthesise stock avatar placeholder.")
  let p = startProcess(
    command = ffmpeg,
    args = @[
      "-y", "-hide_banner", "-loglevel", "error",
      "-f", "lavfi",
      "-i", "testsrc2=duration=5:size=320x320:rate=30",
      "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
      outputMp4,
    ],
    options = {poStdErrToStdOut}
  )
  let logTxt = p.outputStream.readAll()
  let code = p.waitForExit()
  p.close()
  if code != 0:
    raise newException(TalkingHeadError,
      "stock avatar placeholder generation failed (" & $code & "): " & logTxt)

proc generateStockAvatar(narrationWav, outputMp4: string,
                         opts: TalkingHeadOpts) =
  ## Stock provider: copy the pre-existing testsrc2 placeholder to
  ## `outputMp4`, synthesising it on the fly if it isn't materialised.
  let src = resolveStockAvatarPath(opts)
  let outParent = outputMp4.parentDir()
  if outParent.len > 0 and not dirExists(outParent):
    createDir(outParent)
  if src.len > 0 and fileExists(src):
    copyFile(src, outputMp4)
  else:
    # Synthesise directly into the destination — keeps GuiAssert
    # self-contained for environments where the marketing repo isn't
    # adjacent (e.g. standalone GuiAssert checkout).
    ensureStockPlaceholder(outputMp4)

# ---------------------------------------------------------------------------
# SadTalker provider — spawns the Python wrapper subprocess.
# ---------------------------------------------------------------------------

proc generateSadTalker(narrationWav, outputMp4: string,
                       opts: TalkingHeadOpts, cacheDir: string,
                       cacheKey: string) =
  ## Invoke the SadTalker Python wrapper.  stdout+stderr are captured
  ## into a log file under the cache dir so the runner has a recorded
  ## trace of every render.  Non-zero exits propagate as
  ## `TalkingHeadError` carrying the tail of the log.
  if opts.avatarImagePath.isNone or opts.avatarImagePath.get.len == 0:
    raise newException(TalkingHeadError,
      "thpSadTalker requires avatarImagePath to be set.")
  let avatar = opts.avatarImagePath.get
  if not fileExists(avatar):
    raise newException(TalkingHeadError,
      "thpSadTalker avatar image not found: " & avatar)
  let py = resolvedPythonBinary(opts)
  if py.len == 0 or not fileExists(py):
    raise newException(TalkingHeadError,
      "SadTalker python binary not found (set SADTALKER_PYTHON or " &
      "TalkingHeadOpts.pythonBinary).")
  let script = resolvedRenderScript(opts)
  if script.len == 0 or not fileExists(script):
    raise newException(TalkingHeadError,
      "SadTalker render script not found (set SADTALKER_RENDER_SCRIPT or " &
      "TalkingHeadOpts.renderScriptPath).")
  if not dirExists(cacheDir):
    createDir(cacheDir)
  let logPath = cacheDir / (cacheKey & ".log")

  var argv: seq[string] = @[
    script,
    "--audio", narrationWav,
    "--source-image", avatar,
    "--output", outputMp4,
    "--device", effectiveDevice(opts),
  ]
  for extra in opts.extraArgs:
    argv.add extra

  let started = epochTime()
  let logFile = open(logPath, fmWrite)
  var tail = ""
  var exitCode = -1
  try:
    let p = startProcess(
      command = py,
      args = argv,
      options = {poStdErrToStdOut}
    )
    try:
      let s = p.outputStream
      while not s.atEnd:
        let line =
          try: s.readLine()
          except IOError: break
        logFile.writeLine(line)
        logFile.flushFile()
        if tail.len < 8192:
          tail.add(line)
          tail.add('\n')
        else:
          # Keep only the last 8 KB.
          tail = tail[tail.len - 6144 .. ^1] & line & "\n"
      exitCode = p.waitForExit()
    finally:
      p.close()
  finally:
    logFile.close()
  let elapsed = epochTime() - started

  if exitCode != 0:
    raise newException(TalkingHeadError,
      &"SadTalker failed (exit={exitCode}, elapsed={elapsed:.1f}s). " &
      "Log: " & logPath & "\nTail:\n" & tail)
  if not fileExists(outputMp4) or getFileSize(outputMp4) == 0:
    raise newException(TalkingHeadError,
      "SadTalker reported success but produced no MP4 at " & outputMp4 &
      ". See log: " & logPath)

# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

proc generateTalkingHead*(narrationWav, outputMp4: string,
                          opts: TalkingHeadOpts) =
  ## Produce an MP4 at `outputMp4` for the given narration WAV under
  ## the requested provider.  Blocks until the render completes.
  ##
  ## Behaviour:
  ##   * Uses an on-disk cache keyed by avatar/narration bytes +
  ##     provider + device.  Cache hits copy the cached file in
  ##     constant time.
  ##   * Stock provider always succeeds (synthesises a placeholder if
  ##     none exists).
  ##   * SadTalker provider raises `TalkingHeadError` if Python /
  ##     script / weights are missing, or if the inference subprocess
  ##     exits non-zero.
  ##
  ## Side effects: writes cache files under `effectiveCacheDir(opts)`
  ## including a `<key>.mp4` and a `<key>.log`.

  let outParent = outputMp4.parentDir()
  if outParent.len > 0 and not dirExists(outParent):
    createDir(outParent)

  case opts.provider
  of thpStockAvatar:
    # Stock placeholder is so cheap (no model invocation) that we
    # bypass the cache entirely.
    generateStockAvatar(narrationWav, outputMp4, opts)
    if not fileExists(outputMp4):
      raise newException(TalkingHeadError,
        "stock_avatar provider produced no output at " & outputMp4)
    return
  of thpSadTalker:
    if opts.avatarImagePath.isNone:
      raise newException(TalkingHeadError,
        "thpSadTalker requires avatarImagePath to be set.")
    let avatar = opts.avatarImagePath.get
    let cacheDir = effectiveCacheDir(opts)
    if not dirExists(cacheDir):
      createDir(cacheDir)
    let key = computeCacheKey(avatar, narrationWav, opts.provider,
                              effectiveDevice(opts))
    let cachedMp4 = cacheDir / (key & ".mp4")
    if fileExists(cachedMp4) and getFileSize(cachedMp4) > 0:
      copyFile(cachedMp4, outputMp4)
      return
    # Miss — run SadTalker, write into the cache, then copy to the
    # requested destination.  Writing into the cache first means a
    # crash partway through doesn't leave a corrupt `outputMp4`.
    generateSadTalker(narrationWav, cachedMp4, opts, cacheDir, key)
    copyFile(cachedMp4, outputMp4)
  of thpDid, thpHeyGen, thpHedra:
    raise newException(TalkingHeadError,
      "talking-head provider " & $opts.provider &
      " is reserved for future revisions and not yet implemented.")

# ---------------------------------------------------------------------------
# YAML script integration helpers
# ---------------------------------------------------------------------------

proc optsFromMetadata*(meta: TalkingHeadMeta,
                       scriptDir: string = ""): TalkingHeadOpts =
  ## Translate the `metadata.talking_head` block from a parsed `Script`
  ## into a runtime `TalkingHeadOpts`.  `scriptDir` is used to resolve
  ## relative `avatar_image` paths against the script's directory.
  let providerName =
    if meta.provider.len == 0: "stock_avatar" else: meta.provider
  result = TalkingHeadOpts(
    provider: parseTalkingHeadProvider(providerName),
    avatarImagePath: none(string),
    pythonBinary: none(string),
    renderScriptPath: none(string),
    device: meta.device,
    cacheDir: none(string),
    extraArgs: @[],
  )
  if meta.avatarImage.len > 0:
    let raw = meta.avatarImage
    let abs =
      if isAbsolute(raw): raw
      elif scriptDir.len > 0: scriptDir / raw
      else: raw
    result.avatarImagePath = some(abs)
  # Apply forward-compat extras as CLI tail args so the SadTalker
  # wrapper gets them verbatim (e.g. preprocess: full, enhancer:
  # gfpgan).  Recognised keys map to canonical flags; unknown keys
  # turn into --kebab-case-keys.
  for k, v in meta.extras.pairs:
    case k.toLowerAscii
    of "preprocess":   result.extraArgs.add @["--preprocess", v]
    of "size":         result.extraArgs.add @["--size", v]
    of "enhancer":     result.extraArgs.add @["--enhancer", v]
    of "still", "still_mode":
      if v.toLowerAscii in ["true", "1", "yes", "on"]:
        result.extraArgs.add "--still-mode"
    else:
      # Generic --kebab-flag value pair.
      let flag = "--" & k.replace("_", "-")
      result.extraArgs.add @[flag, v]
