## Core types + registry for the talking-head plugin contract.
##
## This module is internal to `gui_assert/talking_head`.  Callers
## should import `gui_assert/talking_head` (the umbrella module),
## which re-exports everything in here plus the built-in
## `stock_avatar` provider.  Plugins that don't need stock_avatar
## (and therefore don't need ffmpeg as a transitive dep) can import
## this module directly.

import std/[algorithm, json, options, os, sha1, streams, strutils, tables]

import ../parser  # for TalkingHeadMeta

type
  TalkingHeadOpts* = object
    ## Provider-agnostic runtime configuration.
    avatarImagePath*: Option[string]
      ## Filesystem path of the portrait image fed to the talking-head
      ## provider.  Required by non-stock providers; ignored by the
      ## stock provider.
    device*: string
      ## "auto" | "cpu" | "mps" | "cuda" — passed through to providers
      ## that care.  Empty / "" coerces to "auto".
    cacheDir*: Option[string]
      ## Override for the on-disk cache directory.  When unset, plugins
      ## should default to `defaultCacheDir()`.
    providerSettings*: JsonNode
      ## Plugin-specific structured config, opaque to GuiAssert.
    extraArgs*: seq[string]
      ## Provider-specific extra CLI args, accumulated by
      ## `optsFromMetadata` from forward-compat YAML keys.

  TalkingHeadAvailabilityProc* = proc(): bool {.gcsafe.}
    ## Returns `true` iff the provider's runtime dependencies are
    ## present.  Cheap to call; plugins should not perform inference
    ## here.

  TalkingHeadProviderProc* = proc(narrationWav, outputMp4: string,
                                  opts: TalkingHeadOpts) {.gcsafe.}
    ## Produces an MP4 at `outputMp4` for the given narration WAV.
    ## Blocks until the render completes.  Raises `TalkingHeadError`
    ## (or a subclass) on failure.

  TalkingHeadProvider* = object
    ## The plugin contract.  Built-ins and plugins both build values of
    ## this shape and pass them to `registerProvider`.
    name*: string
      ## Stable, YAML-facing identifier — e.g. "stock_avatar",
      ## "sadtalker".  Looked up case-insensitively at dispatch time.
    isAvailable*: TalkingHeadAvailabilityProc
    generate*: TalkingHeadProviderProc

  TalkingHeadRegistry* = ref object
    ## Mutable lookup from provider name to provider value.  Construct
    ## via `newRegistry` (in the umbrella module), which pre-registers
    ## the built-in `stock_avatar` provider.  Plugins register
    ## themselves via `registerProvider`.
    providers*: Table[string, TalkingHeadProvider]

  TalkingHeadError* = object of CatchableError

# ---------------------------------------------------------------------------
# Provider-name normalisation
# ---------------------------------------------------------------------------

proc normalizeProviderName*(name: string): string =
  ## Canonical form: lowercase, trimmed, common aliases collapsed.
  ## The empty string maps to "stock_avatar".
  let n = name.strip.toLowerAscii
  case n
  of "", "stock", "stock_avatar", "placeholder": "stock_avatar"
  of "d-id": "did"
  else: n

# ---------------------------------------------------------------------------
# Defaults
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

proc effectiveDevice*(opts: TalkingHeadOpts): string =
  ## Returns `opts.device` lowercased, or "auto" when unset.
  if opts.device.len == 0: defaultDevice() else: opts.device.toLowerAscii

proc effectiveCacheDir*(opts: TalkingHeadOpts): string =
  if opts.cacheDir.isSome and opts.cacheDir.get.len > 0: opts.cacheDir.get
  else: defaultCacheDir()

# ---------------------------------------------------------------------------
# Cache helpers shared between plugins
# ---------------------------------------------------------------------------

proc digestToHex(d: Sha1Digest): string =
  ## Convert a 20-byte Sha1Digest to a 40-char lowercase hex string.
  result = newStringOfCap(40)
  for b in d:
    result.add(b.toHex(2).toLowerAscii)

proc fileSha1Hex(path: string): string =
  ## Streaming SHA-1 of `path`.  Used as an ingredient of the cache key.
  ## SHA-1 is more than enough to disambiguate cache entries; this is
  ## not a cryptographic context.
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

proc cacheKeyFor*(avatarImagePath, narrationWav, providerName,
                  device: string): string =
  ## Stable hash of (avatar bytes + narration bytes + provider name +
  ## device).  Returns 16 lowercase hex characters (~64 bits — plenty
  ## for an on-disk cache holding at most thousands of deterministic
  ## entries).  Raises `TalkingHeadError` if either input file is
  ## missing.
  if not fileExists(avatarImagePath):
    raise newException(TalkingHeadError,
      "avatar image not found: " & avatarImagePath)
  if not fileExists(narrationWav):
    raise newException(TalkingHeadError,
      "narration WAV not found: " & narrationWav)
  let avatarDigest = fileSha1Hex(avatarImagePath)
  let narrationDigest = fileSha1Hex(narrationWav)
  let salt = normalizeProviderName(providerName) & "|" & device.toLowerAscii
  var ctx: Sha1State = newSha1State()
  ctx.update(avatarDigest)
  ctx.update(narrationDigest)
  ctx.update(salt)
  let full = digestToHex(ctx.finalize())
  result = full[0 ..< 16]

proc applyCache*(cacheDir, cacheKey, outputMp4: string,
                 generator: proc()): tuple[hit: bool, outputPath: string] =
  ## Helper for plugins: checks `cacheDir/<cacheKey>.mp4`.  If the file
  ## exists and is non-empty, copies it to `outputMp4` and returns
  ## `(hit: true, ...)`.  Otherwise calls `generator` (which must write
  ## the rendered MP4 to `outputMp4`), then caches the result by
  ## copying `outputMp4` to `<cacheDir>/<cacheKey>.mp4`.
  ##
  ## The cache copy step is best-effort: failures (e.g. read-only
  ## cacheDir) are swallowed so a successful render is still returned.
  if cacheDir.len > 0 and not dirExists(cacheDir):
    createDir(cacheDir)
  let cachedMp4 = cacheDir / (cacheKey & ".mp4")
  if fileExists(cachedMp4) and getFileSize(cachedMp4) > 0:
    let outParent = outputMp4.parentDir()
    if outParent.len > 0 and not dirExists(outParent):
      createDir(outParent)
    copyFile(cachedMp4, outputMp4)
    return (hit: true, outputPath: outputMp4)
  generator()
  if not fileExists(outputMp4) or getFileSize(outputMp4) == 0:
    raise newException(TalkingHeadError,
      "provider generator returned but did not produce " & outputMp4)
  try:
    if cacheDir.len > 0:
      copyFile(outputMp4, cachedMp4)
  except OSError:
    # Caching is best-effort; do not let a cache-write failure mask
    # a successful render.
    discard
  result = (hit: false, outputPath: outputMp4)

# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------

proc registerProvider*(r: TalkingHeadRegistry, p: TalkingHeadProvider) =
  ## Insert / overwrite a provider keyed by its canonical name.
  if r.isNil:
    raise newException(TalkingHeadError,
      "registerProvider: registry is nil")
  if p.name.len == 0:
    raise newException(TalkingHeadError,
      "registerProvider: provider has empty name")
  if p.isAvailable.isNil or p.generate.isNil:
    raise newException(TalkingHeadError,
      "registerProvider: provider '" & p.name &
      "' is missing isAvailable / generate procs")
  r.providers[normalizeProviderName(p.name)] = p

proc hasProvider*(r: TalkingHeadRegistry, name: string): bool =
  ## Returns true iff a provider by this canonical name is registered.
  if r.isNil:
    return false
  normalizeProviderName(name) in r.providers

proc listProviders*(r: TalkingHeadRegistry): seq[string] =
  ## Sorted list of registered provider names (canonical form).
  result = @[]
  if r.isNil:
    return
  for k in r.providers.keys:
    result.add k
  result.sort(cmp)

proc getProvider*(r: TalkingHeadRegistry, name: string): TalkingHeadProvider =
  ## Look up a registered provider by name.  Raises `TalkingHeadError`
  ## when the name is unknown.
  let canonical = normalizeProviderName(name)
  if r.isNil or canonical notin r.providers:
    raise newException(TalkingHeadError,
      "unknown talking-head provider: '" & name &
      "'. Registered providers: " & listProviders(r).join(", "))
  result = r.providers[canonical]

proc newEmptyRegistry*(): TalkingHeadRegistry =
  ## Returns an empty registry.  The umbrella module's `newRegistry`
  ## wraps this and pre-registers `stock_avatar`.
  result = TalkingHeadRegistry(
    providers: initTable[string, TalkingHeadProvider]()
  )

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

proc generateTalkingHead*(r: TalkingHeadRegistry, providerName: string,
                          narrationWav, outputMp4: string,
                          opts: TalkingHeadOpts) =
  ## Produce an MP4 at `outputMp4` for the given narration WAV under
  ## the registered provider named `providerName`.  Blocks until the
  ## render completes.
  ##
  ## Raises `TalkingHeadError` if the provider is unknown, currently
  ## unavailable, or fails to produce a non-empty MP4.
  let outParent = outputMp4.parentDir()
  if outParent.len > 0 and not dirExists(outParent):
    createDir(outParent)
  let provider = getProvider(r, providerName)
  if not provider.isAvailable():
    raise newException(TalkingHeadError,
      "talking-head provider '" & provider.name &
      "' is registered but its dependencies are missing. " &
      "Run the plugin's install / setup script before re-trying.")
  provider.generate(narrationWav, outputMp4, opts)
  if not fileExists(outputMp4) or getFileSize(outputMp4) == 0:
    raise newException(TalkingHeadError,
      "talking-head provider '" & provider.name &
      "' returned success but produced no MP4 at " & outputMp4)

# ---------------------------------------------------------------------------
# YAML metadata translation
# ---------------------------------------------------------------------------

proc optsFromMetadata*(meta: TalkingHeadMeta,
                       scriptDir: string = ""): TalkingHeadOpts =
  ## Translate the `metadata.talking_head` block from a parsed `Script`
  ## into a runtime `TalkingHeadOpts`.  `scriptDir` is used to resolve
  ## relative `avatar_image` paths against the script's directory.
  ##
  ## The provider name itself is NOT stored on `TalkingHeadOpts` — it
  ## is looked up by the runner against the registry.  We still capture
  ## forward-compat scalar extras as both kebab-cased CLI flags (so
  ## CLI-subprocess plugins can pass them through verbatim) and as
  ## structured `providerSettings` JSON for plugins that want
  ## structured config.
  result = TalkingHeadOpts(
    avatarImagePath: none(string),
    device: meta.device,
    cacheDir: none(string),
    providerSettings: newJObject(),
    extraArgs: @[],
  )
  if meta.avatarImage.len > 0:
    let raw = meta.avatarImage
    let abs =
      if isAbsolute(raw): raw
      elif scriptDir.len > 0: scriptDir / raw
      else: raw
    result.avatarImagePath = some(abs)
  for k, v in meta.extras.pairs:
    # Mirror the kebab-flag forwarding shape the previous SadTalker
    # codepath relied on, so plugins that exec a CLI subprocess can
    # consume the legacy YAML schema verbatim.
    case k.toLowerAscii
    of "preprocess":   result.extraArgs.add @["--preprocess", v]
    of "size":         result.extraArgs.add @["--size", v]
    of "enhancer":     result.extraArgs.add @["--enhancer", v]
    of "still", "still_mode":
      if v.toLowerAscii in ["true", "1", "yes", "on"]:
        result.extraArgs.add "--still-mode"
    else:
      let flag = "--" & k.replace("_", "-")
      result.extraArgs.add @[flag, v]
    # Always preserve the original key under providerSettings as the
    # structured fallback for plugins that don't want CLI semantics.
    result.providerSettings[k] = newJString(v)
