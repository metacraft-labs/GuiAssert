## Built-in `stock_avatar` talking-head provider.
##
## Produces a 5-second `testsrc2` placeholder MP4 — useful in CI dry
## runs, smoke tests, and as the default for scripts that don't opt
## into a heavyweight generative provider.  Shelling out to ffmpeg is
## the only runtime dependency.
##
## The stock provider deliberately bypasses the on-disk cache: each
## render is cheap (sub-second ffmpeg invocation) and synthesising
## fresh output is more predictable than reading a possibly stale
## cached MP4.
##
## A pre-baked placeholder MP4 may also live at
## `<repoRoot>/assets/avatar-placeholder.mp4` (the marketing repo's
## convention).  When `opts.avatarImagePath` points at such an MP4 we
## copy it verbatim; otherwise we synthesise via `ffmpeg testsrc2`.

import std/[options, os, osproc, streams]

import ./core

const StockAvatarName* = "stock_avatar"

proc ensureStockPlaceholder(outputMp4: string) =
  ## Synthesise a 5-second `testsrc2` MP4 at `outputMp4`.  Looks up
  ## ffmpeg via `$FFMPEG_BIN` then `PATH`.
  let parent = outputMp4.parentDir()
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)
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
                        opts: TalkingHeadOpts) {.gcsafe.} =
  ## The stock provider ignores `narrationWav` because the placeholder
  ## is a single canned animation.  If `opts.avatarImagePath` points at
  ## a real MP4 (the marketing repo's `assets/avatar-placeholder.mp4`
  ## convention) we copy it verbatim; otherwise we synthesise via
  ## ffmpeg's `testsrc2` lavfi source.
  discard narrationWav
  let outParent = outputMp4.parentDir()
  if outParent.len > 0 and not dirExists(outParent):
    createDir(outParent)
  if opts.avatarImagePath.isSome:
    let src = opts.avatarImagePath.get
    if src.len > 0 and fileExists(src):
      copyFile(src, outputMp4)
      return
  ensureStockPlaceholder(outputMp4)

proc stockAvatarIsAvailable(): bool {.gcsafe.} =
  ## Stock avatar is always available — even without ffmpeg on PATH,
  ## the function exists; the user just gets a clearer error at
  ## render time.  We deliberately return true here so callers don't
  ## confuse "stock provider isn't usable" with the legitimate "this
  ## host has no ffmpeg" failure surfaced during render.
  true

proc newStockAvatarProvider*(): TalkingHeadProvider =
  ## Build the `stock_avatar` provider value.  Plugins compose against
  ## this same shape.
  result = TalkingHeadProvider(
    name: StockAvatarName,
    isAvailable: stockAvatarIsAvailable,
    generate: generateStockAvatar,
  )
