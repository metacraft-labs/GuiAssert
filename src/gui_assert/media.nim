## GuiAssert Media Composition Pipeline
##
## Builds the ffmpeg invocation that stitches together:
##   * a raw screencast video produced by `ah desktop record` (M1),
##   * a narration WAV produced by the speech synthesizer (this milestone),
##   * a "talking head" avatar video clipped into a circle and parked in the
##     bottom-right corner,
##   * one or more time-bounded captions rendered with `drawtext`,
##
## into a single faststart-flagged MP4 ready for distribution.
##
## The implementation is split into two procs:
##
##   * `buildComposeArgv` is pure: it constructs the argv that would be
##     handed to ffmpeg. This lets tests inspect the filter graph and assert
##     on its shape without paying the cost of an actual render.
##
##   * `composeVideoWithOverlay` is effectful: it calls `buildComposeArgv`
##     and then runs ffmpeg as a subprocess, surfacing failures as a typed
##     `MediaCompositionError`.
##
## The filter graph:
##
##   [0:v] scale=W:H,setsar=1                                         -> [bg]
##   [2:v] scale=AVATAR_W:AVATAR_H,format=yuva420p,
##         geq=lum='p(X,Y)':a='if(...circle mask...)'                 -> [avatar]
##   [bg][avatar] overlay=W-overlay_w-MARGIN:H-overlay_h-MARGIN       -> [vbase]
##   [vbase] drawtext=...,drawtext=...                                -> [vout]
##   [0:a][1:a] amix=inputs=2:duration=longest:dropout_transition=0   -> [aout]
##
## Input streams are wired as:
##
##   -i screencast.mp4    (index 0, has video and possibly silent audio)
##   -i narration.wav     (index 1, audio only)
##   -i avatar.mp4        (index 2, video only — audio is ignored even if present)
##
## When the screencast has no audio track ffmpeg's amix would fail; we
## sidestep that by always synthesising a silent stereo source via the
## `anullsrc` lavfi pseudo-input. The amix then mixes narration with that
## silent base, producing audio that is exactly the narration but routed
## through a stable filter graph regardless of source audio presence.

import std/[options, os, osproc, streams, strformat, strtabs, strutils]

type
  MediaCompositionError* = object of CatchableError
    ## Raised when ffmpeg cannot be invoked, exits non-zero, or fails to
    ## produce the requested output file.

  Caption* = object
    ## A single time-bounded subtitle overlay rendered through ffmpeg's
    ## `drawtext` filter.
    text*: string
    startTime*: float
    endTime*: float
    x*: Option[string]
      ## Optional ffmpeg-expression override for the X coordinate. When
      ## absent the caption is centered horizontally: `(w-text_w)/2`.
    y*: Option[string]
      ## Optional ffmpeg-expression override for the Y coordinate. When
      ## absent the caption is placed in the lower third, above the avatar:
      ## `h-(h/6)-text_h`.

  OverlayMode* = enum
    ## How the avatar source is composited onto the screencast.
    omCircle = "circle"
      ## Classic bottom-right circular crop (the historical default).
      ## `avatarWidth` x `avatarHeight` are honoured verbatim, and a
      ## hard alpha-circle mask is drawn via the `geq` filter.
    omChromaKey = "chromakey"
      ## Green-screen extraction (default for the new presenter
      ## layout). The avatar source is scaled to `avatarHeight`
      ## preserving aspect, its chosen colour is removed via
      ## `chromakey`, and the remaining pixels are anchored to the
      ## canvas's bottom edge so the figure naturally extends to
      ## the lower edge of the video.

  OverlayAnchor* = enum
    oaBottomLeft = "bottom_left"
    oaBottomRight = "bottom_right"
    oaBottomCenter = "bottom_center"

  KeyMethod* = enum
    ## How the avatar's background colour is removed in `omChromaKey`
    ## mode.  Different backends emit different background characters
    ## so different ffmpeg filters key them cleanly:
    kmChroma = "chroma"
      ## `chromakey` — YUV-space difference against the target colour.
      ## Best fit for *chromatic* backgrounds (green / blue screens)
      ## where the chrominance is far from any pixel in the foreground.
      ## Falls down on neutral-toned backgrounds (white / grey) where
      ## every grayscale pixel shares the target's chrominance and the
      ## filter mistakenly keys out parts of the figure.
    kmColor = "color"
      ## `colorkey` — RGB-space distance against the target colour.
      ## Best fit for *solid neutral* backgrounds (white, black, grey)
      ## or any single RGB tone the figure does not contain.  Use this
      ## for the white-studio outputs HeyGen / D-ID / Synthesia emit
      ## by default, where the presenter is in colour and the
      ## background is near-white.
    kmLuma = "luma"
      ## `lumakey` — luminance-only threshold.  Useful when the
      ## background is the brightest (or darkest) thing in frame and
      ## the figure contains the target colour too — e.g. a presenter
      ## in a white shirt on a slightly-grey wall, where colorkey on
      ## white would eat the shirt.

  ChromaKeyConfig* = object
    ## Tuning for the background-removal filter applied in
    ## `omChromaKey` mode.  Defaults are picked so HeyGen / Synthesia
    ## / D-ID green-screen outputs key cleanly without hand-tuning.
    `method`*: KeyMethod
      ## Picks `chromakey` vs `colorkey` vs `lumakey`.  See `KeyMethod`
      ## for the trade-offs.  Defaults to `kmChroma` so the
      ## green-screen path keeps working without an explicit setting.
    color*: string         ## ffmpeg colour expression, e.g. "0x00ff00"
    similarity*: float     ## 0.01 .. 0.5 — how close to `color` counts
    blend*: float          ## 0.0 .. 1.0 — soft edge falloff
    lumaThreshold*: float  ## 0.0 .. 1.0 — only used by `kmLuma`
    lumaTolerance*: float  ## 0.0 .. 1.0 — only used by `kmLuma`

  ComposeOptions* = object
    ## Tunable parameters for the composition. Default values match the
    ## defaults documented in the milestones file: 1920x1080 canvas,
    ## 320x320 circular avatar, 30 px margin.
    canvasWidth*: int
    canvasHeight*: int
    avatarWidth*: int
    avatarHeight*: int
    margin*: int
    overlayMode*: OverlayMode
    overlayAnchor*: OverlayAnchor
    chromaKey*: ChromaKeyConfig
    fontFile*: Option[string]
      ## Optional absolute path to a TTF font. When omitted we rely on
      ## ffmpeg's drawtext defaults (which on macOS falls back to the
      ## fontconfig-discovered system font).
    fontSize*: int
    fontColor*: string
    boxColor*: string
      ## ffmpeg color expression for the caption background box (e.g.
      ## "black@0.5" for 50%-opaque black). Set to the empty string to
      ## disable the background box entirely.

proc resolveFfmpegBinary*(): string =
  ## Locate an `ffmpeg` binary on disk. Honors the `FFMPEG_BIN` environment
  ## variable (must point at an executable), otherwise falls back to the
  ## first `ffmpeg` on `PATH`. Raises `MediaCompositionError` if no binary
  ## is found.
  let envBin = getEnv("FFMPEG_BIN")
  if envBin.len > 0:
    if not fileExists(envBin):
      raise newException(
        MediaCompositionError,
        "FFMPEG_BIN points at " & envBin & " but no file exists there."
      )
    return envBin
  let p = findExe("ffmpeg")
  if p.len == 0:
    raise newException(
      MediaCompositionError,
      "ffmpeg not found on PATH and FFMPEG_BIN is unset."
    )
  return p

proc sanitizedEnvForFfmpeg(ffmpegPath: string): StringTableRef =
  ## Build an environment for invoking the chosen ffmpeg. On macOS, when the
  ## binary lives in `/nix/store`, we strip `DYLD_LIBRARY_PATH` so the dynamic
  ## linker does not splice in incompatible libraries from `/opt/homebrew/lib`
  ## (a common situation on Apple Silicon dev boxes where Homebrew's ffmpeg
  ## libs co-exist with the Nix-built ones).
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if k == "DYLD_LIBRARY_PATH" or k == "DYLD_FALLBACK_LIBRARY_PATH":
      when defined(macosx):
        if ffmpegPath.startsWith("/nix/"): continue
    result[k] = v

proc defaultChromaKey*(): ChromaKeyConfig =
  ## Defaults tuned for the green-screen outputs HeyGen / Synthesia /
  ## D-ID emit when their `background` field is set to a solid green.
  ChromaKeyConfig(`method`: kmChroma, color: "0x00ff00",
                  similarity: 0.18, blend: 0.08,
                  lumaThreshold: 0.9, lumaTolerance: 0.05)

proc whiteScreenChromaKey*(): ChromaKeyConfig =
  ## RGB-space `colorkey` against pure white, tuned to extract a
  ## presenter from the default HeyGen / D-ID / Synthesia studio
  ## background without keying the figure's skin highlights.  Use
  ## this when you have an existing render whose background is white
  ## and you don't want to spend a credit re-rendering with
  ## `background = green_screen`.
  ChromaKeyConfig(`method`: kmColor, color: "white",
                  similarity: 0.10, blend: 0.05,
                  lumaThreshold: 0.9, lumaTolerance: 0.05)

proc defaultComposeOptions*(): ComposeOptions =
  ## Returns the canonical composition options used by the verification
  ## harness and by callers who do not pass overrides.
  ComposeOptions(
    canvasWidth: 1920,
    canvasHeight: 1080,
    avatarWidth: 320,
    avatarHeight: 320,
    margin: 30,
    overlayMode: omCircle,
    overlayAnchor: oaBottomRight,
    chromaKey: defaultChromaKey(),
    fontFile: none(string),
    fontSize: 36,
    fontColor: "white",
    boxColor: "black@0.5"
  )

proc presenterComposeOptions*(): ComposeOptions =
  ## Returns options for the green-screen presenter layout: the
  ## avatar's green background is chroma-keyed out and the remaining
  ## figure is anchored to the canvas's bottom-left edge so the
  ## human body extends naturally to the lower edge of the video.
  result = defaultComposeOptions()
  result.overlayMode = omChromaKey
  result.overlayAnchor = oaBottomLeft
  # Avatar height defaults to ~60% of canvas height so the head fits
  # within the upper portion while the body extends to the bottom.
  result.avatarHeight = int(float(result.canvasHeight) * 0.6)
  result.avatarWidth = -1                 ## preserve aspect

# ---------------------------------------------------------------------------
# drawtext escaping
# ---------------------------------------------------------------------------
#
# ffmpeg's filter graph syntax is famously irritating. Inside a filter
# argument we must escape backslashes, single quotes, colons, percents, and
# any other separator-like character. The standard recipe is to wrap the
# value in single quotes and escape internal single quotes as `\''`, then
# additionally escape backslashes themselves.

proc escapeDrawtext*(s: string): string =
  ## Escape a string for inclusion as a `drawtext` option value, wrapped
  ## inside single quotes by the caller.
  result = newStringOfCap(s.len + 8)
  for ch in s:
    case ch
    of '\\': result.add("\\\\")
    of '\'': result.add("\\'")
    of ':':  result.add("\\:")
    of '%':  result.add("\\%")
    else:    result.add(ch)

proc buildDrawtextFilter(c: Caption, opts: ComposeOptions): string =
  ## Build a single `drawtext=...` clause for a `Caption`. The clause is
  ## ready to be joined into a longer filter chain with commas.
  let xExpr =
    if c.x.isSome: c.x.get
    else: "(w-text_w)/2"
  let yExpr =
    if c.y.isSome: c.y.get
    else: "h-(h/6)-text_h"
  var parts: seq[string] = @[]
  parts.add("text='" & escapeDrawtext(c.text) & "'")
  if opts.fontFile.isSome:
    parts.add("fontfile='" & escapeDrawtext(opts.fontFile.get) & "'")
  parts.add("fontsize=" & $opts.fontSize)
  parts.add("fontcolor=" & opts.fontColor)
  if opts.boxColor.len > 0:
    parts.add("box=1")
    parts.add("boxcolor=" & opts.boxColor)
    parts.add("boxborderw=12")
  parts.add("x=" & xExpr)
  parts.add("y=" & yExpr)
  parts.add(&"enable='between(t,{c.startTime:.3f},{c.endTime:.3f})'")
  result = "drawtext=" & parts.join(":")

# ---------------------------------------------------------------------------
# Filter graph assembly
# ---------------------------------------------------------------------------

proc avatarFilterCircle(opts: ComposeOptions): string =
  ## Build the avatar chain for `omCircle` mode (legacy default).
  ## Scales the source down to the configured target size, promotes
  ## to yuva420p so the `geq` filter can write an alpha channel, and
  ## draws a hard circular alpha mask leaving Y/U/V untouched.
  &"[2:v]scale={opts.avatarWidth}:{opts.avatarHeight}," &
    "format=yuva420p," &
    "geq=lum='p(X,Y)':cb='p(X,Y)':cr='p(X,Y)':" &
    "a='if(lte(hypot(X-W/2,Y-H/2),W/2),255,0)'[avatar]"

proc avatarFilterChromaKey(opts: ComposeOptions): string =
  ## Build the avatar chain for `omChromaKey` mode.  Scales the
  ## source preserving aspect (passing `width = -1` so ffmpeg
  ## derives the proportional width), promotes to `yuva420p` so the
  ## chosen keying filter can write into the alpha channel, then
  ## removes the configured background via one of three filters:
  ## `chromakey` (YUV) for green / blue screens, `colorkey` (RGB)
  ## for white / solid neutral backgrounds, or `lumakey` for
  ## brightness-thresholded extraction.  The remaining alpha buffer
  ## is bottom-anchored downstream in `overlayFilter`, so the human
  ## figure naturally extends to the lower edge of the canvas.
  let w =
    if opts.avatarWidth <= 0: -1
    else: opts.avatarWidth
  let ck = opts.chromaKey
  let keyExpr =
    case ck.`method`
    of kmChroma:
      &"chromakey={ck.color}:{ck.similarity}:{ck.blend}"
    of kmColor:
      &"colorkey=color={ck.color}:similarity={ck.similarity}:blend={ck.blend}"
    of kmLuma:
      &"lumakey=threshold={ck.lumaThreshold}:tolerance={ck.lumaTolerance}"
  &"[2:v]scale={w}:{opts.avatarHeight}," &
    "format=yuva420p," &
    keyExpr & "[avatar]"

proc overlayExpression(opts: ComposeOptions): string =
  ## Compute the `overlay=x:y` expression for the configured anchor.
  ## `H`/`W` resolve to the canvas dimensions and `overlay_w`/
  ## `overlay_h` to the scaled avatar dimensions; the bottom-anchored
  ## modes drop the margin from the y coordinate so the figure
  ## extends right up to the lower edge.
  case opts.overlayAnchor
  of oaBottomRight:
    &"W-overlay_w-{opts.margin}:H-overlay_h-{opts.margin}"
  of oaBottomLeft:
    case opts.overlayMode
    of omCircle:
      &"{opts.margin}:H-overlay_h-{opts.margin}"
    of omChromaKey:
      &"{opts.margin}:H-overlay_h"
  of oaBottomCenter:
    case opts.overlayMode
    of omCircle:
      &"(W-overlay_w)/2:H-overlay_h-{opts.margin}"
    of omChromaKey:
      "(W-overlay_w)/2:H-overlay_h"

proc buildFilterComplex*(
    captions: seq[Caption], opts: ComposeOptions): string =
  ## Build the full `-filter_complex` argument value.
  let bgScale = &"[0:v]scale={opts.canvasWidth}:{opts.canvasHeight}:force_original_aspect_ratio=decrease," &
                &"pad={opts.canvasWidth}:{opts.canvasHeight}:(ow-iw)/2:(oh-ih)/2,setsar=1[bg]"

  let avatarFilter =
    case opts.overlayMode
    of omCircle:    avatarFilterCircle(opts)
    of omChromaKey: avatarFilterChromaKey(opts)

  let overlayFilter =
    "[bg][avatar]overlay=" & overlayExpression(opts)

  # Captions chain. If there are no captions we close out the overlay
  # straight into [vout] so downstream `-map [vout]` still works.
  var captionChain = ""
  if captions.len > 0:
    var pieces: seq[string] = @[]
    for c in captions:
      pieces.add(buildDrawtextFilter(c, opts))
    captionChain = "," & pieces.join(",")
  let videoChain = overlayFilter & captionChain & "[vout]"

  # Audio: mix narration (input 1) with a synthesized silent base (input 3
  # via the `anullsrc` lavfi pseudo-input added in `buildComposeArgv`). This
  # keeps the graph stable whether or not the screencast itself has audio.
  let audioChain = "[3:a][1:a]amix=inputs=2:duration=longest:dropout_transition=0[aout]"

  result = @[
    bgScale,
    avatarFilter,
    videoChain,
    audioChain
  ].join(";")

# ---------------------------------------------------------------------------
# Full argv assembly
# ---------------------------------------------------------------------------

proc buildComposeArgv*(
    screencastPath, narrationWavPath, avatarVideoPath, outputPath: string,
    captions: seq[Caption],
    opts: ComposeOptions = defaultComposeOptions(),
    ffmpegBin: string = "ffmpeg"): seq[string] =
  ## Build the complete ffmpeg argv. The result is suitable both for direct
  ## subprocess invocation and for inspection in unit tests. `ffmpegBin`
  ## defaults to the bare token "ffmpeg" so the argv reads naturally in
  ## tests; pass `resolveFfmpegBinary()` when actually shelling out.
  let filter = buildFilterComplex(captions, opts)
  result = @[
    ffmpegBin,
    "-y",
    "-hide_banner",
    "-loglevel", "error",
    "-i", screencastPath,
    "-i", narrationWavPath,
    "-i", avatarVideoPath,
    "-f", "lavfi", "-t", "3600",
    "-i", "anullsrc=channel_layout=stereo:sample_rate=44100",
    "-filter_complex", filter,
    "-map", "[vout]",
    "-map", "[aout]",
    "-c:v", "libx264",
    "-preset", "veryfast",
    "-pix_fmt", "yuv420p",
    "-c:a", "aac",
    "-b:a", "192k",
    "-movflags", "+faststart",
    "-shortest",
    outputPath
  ]

proc composeVideoWithOverlay*(
    screencastPath, narrationWavPath, avatarVideoPath, outputPath: string,
    captions: seq[Caption],
    opts: ComposeOptions = defaultComposeOptions()) =
  ## Run ffmpeg with the argv produced by `buildComposeArgv` and validate
  ## that an output file landed at `outputPath`. Raises
  ## `MediaCompositionError` on any failure.
  if not fileExists(screencastPath):
    raise newException(MediaCompositionError, "Screencast not found: " & screencastPath)
  if not fileExists(narrationWavPath):
    raise newException(MediaCompositionError, "Narration WAV not found: " & narrationWavPath)
  if not fileExists(avatarVideoPath):
    raise newException(MediaCompositionError, "Avatar video not found: " & avatarVideoPath)

  let parent = outputPath.parentDir()
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)

  let ffmpegBin = resolveFfmpegBinary()
  let argv = buildComposeArgv(
    screencastPath, narrationWavPath, avatarVideoPath, outputPath,
    captions, opts, ffmpegBin
  )

  let envForFfmpeg = sanitizedEnvForFfmpeg(ffmpegBin)
  let process = startProcess(
    command = argv[0],
    args = argv[1 .. ^1],
    env = envForFfmpeg,
    options = {poStdErrToStdOut}
  )
  let output = process.outputStream().readAll()
  let exitCode = process.waitForExit()
  process.close()
  if exitCode != 0:
    raise newException(
      MediaCompositionError,
      "ffmpeg exited with code " & $exitCode & ":\n" & output
    )
  if not fileExists(outputPath):
    raise newException(
      MediaCompositionError,
      "ffmpeg reported success but no file at " & outputPath
    )
  if getFileSize(outputPath) <= 0:
    raise newException(
      MediaCompositionError,
      "ffmpeg produced a zero-byte file at " & outputPath
    )
