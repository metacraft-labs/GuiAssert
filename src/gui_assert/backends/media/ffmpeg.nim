## GuiAssert opt-in media backend: image decoding through ffmpeg.
##
## The pure core decodes PNG itself (`core/png`). Every other image format,
## and every video, goes through this module, which runs the `ffmpeg` and
## `ffprobe` binaries as subprocesses. Import it only when that dependency is
## acceptable; nothing in `core/` imports it.
##
## Binary discovery goes through `media.resolveFfmpegBinary` (which honours
## `FFMPEG_BIN`, then `$PATH`), so the same binary is used everywhere in
## GuiAssert, and `ffprobe` is taken from beside it when it is there. When
## the binary lives in the Nix store, `DYLD_LIBRARY_PATH` and
## `DYLD_FALLBACK_LIBRARY_PATH` are removed from its environment so the
## dynamic linker cannot splice host libraries into it.
##
## `decodeGray` and `probeImageSize` are re-exported by `gui_assert/image_math`
## under their historical names.

import std/[os, osproc, streams, strtabs, strutils]

import ../../media
import ../../core/image

proc sanitizedEnv(ffmpegPath: string): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if (k == "DYLD_LIBRARY_PATH" or k == "DYLD_FALLBACK_LIBRARY_PATH") and
       ffmpegPath.startsWith("/nix/"):
      continue
    result[k] = v

proc ffprobeBinaryFor(ffmpegPath: string): string =
  if ffmpegPath.endsWith("/ffmpeg"):
    let candidate = ffmpegPath[0 ..< ^len("ffmpeg")] & "ffprobe"
    if fileExists(candidate):
      return candidate
  let p = findExe("ffprobe")
  if p.len == 0:
    raise newException(ImageMathError,
      "ffprobe not found alongside ffmpeg at " & ffmpegPath)
  return p

proc probeImageSize*(path: string): tuple[width, height: int] =
  ## Use ffprobe to read the pixel dimensions of an image file. Any decoded
  ## format ffmpeg understands works: PNG, JPEG, BMP, even single MP4 frames.
  if not fileExists(path):
    raise newException(ImageMathError, "Image not found: " & path)
  let ffmpegPath = resolveFfmpegBinary()
  let ffprobeBin = ffprobeBinaryFor(ffmpegPath)
  let env = sanitizedEnv(ffprobeBin)
  let p = startProcess(
    command = ffprobeBin,
    args = @[
      "-hide_banner",
      "-v", "error",
      "-select_streams", "v:0",
      "-show_entries", "stream=width,height",
      "-of", "csv=p=0:s=x",
      path
    ],
    env = env,
    options = {poStdErrToStdOut}
  )
  let output = p.outputStream().readAll().strip()
  let code = p.waitForExit()
  p.close()
  if code != 0:
    raise newException(ImageMathError,
      "ffprobe failed (" & $code & ") reading " & path & ": " & output)
  # Output format: "1920x1080"
  let parts = output.split('x')
  if parts.len < 2:
    raise newException(ImageMathError,
      "Unexpected ffprobe size output for " & path & ": '" & output & "'")
  try:
    result.width = parseInt(parts[0])
    result.height = parseInt(parts[1])
  except ValueError:
    raise newException(ImageMathError,
      "Could not parse ffprobe dimensions: '" & output & "'")

proc decodeGray*(path: string): GrayImage =
  ## Decode `path` into an 8-bit grayscale raw buffer using ffmpeg.
  ##
  ## We first probe the dimensions with ffprobe (cheap, deterministic),
  ## then pipe the rawvideo bytes out of ffmpeg. The resulting buffer is
  ## exactly `width * height` bytes long.
  let (w, h) = probeImageSize(path)
  let ffmpegPath = resolveFfmpegBinary()
  let env = sanitizedEnv(ffmpegPath)
  let p = startProcess(
    command = ffmpegPath,
    args = @[
      "-hide_banner",
      "-loglevel", "error",
      "-i", path,
      "-vframes", "1",
      "-f", "rawvideo",
      "-pix_fmt", "gray",
      "pipe:1"
    ],
    env = env,
    options = {}
  )
  let buffer = p.outputStream().readAll()
  let code = p.waitForExit()
  p.close()
  if code != 0:
    raise newException(ImageMathError,
      "ffmpeg decode failed (" & $code & ") for " & path)
  let expected = w * h
  if buffer.len != expected:
    raise newException(ImageMathError,
      "ffmpeg produced " & $buffer.len & " gray bytes but expected " &
      $expected & " (" & $w & "x" & $h & ") for " & path)
  result = GrayImage(width: w, height: h, pixels: buffer)
