## GuiAssert Visual Math Engine
##
## Implements the Structural Similarity Index (SSIM) used by the M4 visual
## verification loop. The implementation is pure Nim — only an `ffmpeg`
## subprocess is used to decode arbitrary input images (PNG, JPEG, etc.) into
## an 8-bit grayscale raw buffer of known dimensions.
##
## SSIM is computed using the canonical formula:
##
##   SSIM(x, y) = (2*muX*muY + C1) * (2*sigmaXY + C2)
##              / ((muX^2 + muY^2 + C1) * (sigmaX^2 + sigmaY^2 + C2))
##
## where the statistics are taken over the **whole image** (a "global" SSIM).
## The milestone only requires SSIM in the [0.0, 1.0] range with a tunable
## tolerance threshold; we deliberately stay simple — no sliding Gaussian
## window — because identical images must score 1.0 and the visual review
## loop is comparing whole frames against frozen goldens, not patches.
##
## All ffmpeg invocations go through `resolveFfmpegBinary()` from `media.nim`
## so the same DYLD-sanitised binary is used everywhere in GuiAssert.

import std/[options, os, osproc, streams, strformat, strtabs, strutils]
import ./media

type
  ImageMathError* = object of CatchableError
    ## Raised on ffmpeg decode failures, mismatched dimensions, or other
    ## structural problems that prevent SSIM computation.

  GrayImage* = object
    ## An 8-bit single-channel image. `pixels` is row-major (width * height
    ## bytes). `width` and `height` are in pixels.
    width*: int
    height*: int
    pixels*: string

# ---------------------------------------------------------------------------
# ffmpeg decode helpers
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# SSIM math
# ---------------------------------------------------------------------------

proc computeSsim*(a, b: GrayImage): float =
  ## Compute the global SSIM between two same-sized 8-bit grayscale images.
  ## Returns a value in [-1.0, 1.0]; 1.0 means pixel-identical inputs.
  ##
  ## Raises `ImageMathError` if the dimensions disagree or either image is
  ## empty.
  if a.width != b.width or a.height != b.height:
    raise newException(ImageMathError,
      "SSIM size mismatch: " & $a.width & "x" & $a.height & " vs " &
      $b.width & "x" & $b.height)
  let n = a.width * a.height
  if n == 0:
    raise newException(ImageMathError, "SSIM on empty image")
  if a.pixels.len != n or b.pixels.len != n:
    raise newException(ImageMathError,
      "SSIM pixel buffer size mismatch (expected " & $n & " got " &
      $a.pixels.len & "/" & $b.pixels.len & ")")

  # Compute pixel means.
  var sumA = 0.0
  var sumB = 0.0
  for i in 0 ..< n:
    sumA += float(a.pixels[i].uint8)
    sumB += float(b.pixels[i].uint8)
  let muA = sumA / float(n)
  let muB = sumB / float(n)

  # Compute variances and covariance.
  var varA = 0.0
  var varB = 0.0
  var covAB = 0.0
  for i in 0 ..< n:
    let dA = float(a.pixels[i].uint8) - muA
    let dB = float(b.pixels[i].uint8) - muB
    varA += dA * dA
    varB += dB * dB
    covAB += dA * dB
  varA /= float(n)
  varB /= float(n)
  covAB /= float(n)

  # SSIM constants per Wang et al. 2004 (L=255 for 8-bit).
  const L = 255.0
  const K1 = 0.01
  const K2 = 0.03
  const C1 = (K1 * L) * (K1 * L)
  const C2 = (K2 * L) * (K2 * L)

  let numerator = (2.0 * muA * muB + C1) * (2.0 * covAB + C2)
  let denominator = (muA * muA + muB * muB + C1) * (varA + varB + C2)
  if denominator == 0.0:
    # Both images constant and equal → perfect similarity.
    return 1.0
  result = numerator / denominator

proc ssimFromPaths*(a, b: string): float =
  ## Convenience wrapper: decode both images and compute SSIM.
  let imgA = decodeGray(a)
  let imgB = decodeGray(b)
  result = computeSsim(imgA, imgB)
