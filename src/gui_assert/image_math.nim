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

import std/[options, os, osproc, streams, strformat, strtabs, strutils,
            math, bitops, algorithm]
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

# ---------------------------------------------------------------------------
# VU8: change-detection hardening — tiled/local SSIM, perceptual hash, ECR
# ---------------------------------------------------------------------------
#
# Global SSIM is dominated by large unchanged regions and misses small but
# important UI changes (a new dialog, an address-bar edit); it also fails to
# recognise near-duplicate frames. These pure-CV signals complement it:
#
#   * `tiledSsim` splits the frame into a grid and returns the MIN (most-changed
#     cell) and MEAN local SSIM. A small change confined to one cell drives
#     `minLocal` down even while the global SSIM stays near 1.0.
#   * `dctHash` is a 64-bit DCT perceptual hash (pHash); `hammingDistance`
#     scores two hashes. Consecutive keyframes within a small Hamming radius are
#     near-duplicates and can be collapsed before OCR.
#   * `edgeChangeRatio` measures the symmetric difference of the two binary edge
#     maps over their union — high when text / a box appears or disappears, low
#     for a pure colour / brightness shift that keeps the same structure.

proc cropGray(img: GrayImage, x0, y0, cw, ch: int): GrayImage =
  ## Extract the `cw`x`ch` sub-image whose top-left corner is `(x0, y0)`.
  result.width = cw
  result.height = ch
  result.pixels = newString(cw * ch)
  for row in 0 ..< ch:
    let srcStart = (y0 + row) * img.width + x0
    let dstStart = row * cw
    for col in 0 ..< cw:
      result.pixels[dstStart + col] = img.pixels[srcStart + col]

proc tiledSsim*(a, b: GrayImage, gridX = 4, gridY = 4):
                tuple[minLocal: float, meanLocal: float] =
  ## Divide both same-sized images into a `gridX` x `gridY` grid, compute SSIM
  ## per cell, and return the MINIMUM local SSIM (the most-changed cell) and the
  ## MEAN local SSIM. A change localised to one cell pulls `minLocal` far below
  ## the (area-weighted) global SSIM, so small dialogs / address-bar edits that
  ## global SSIM would smear away still trigger a boundary.
  ##
  ## Cell boundaries are computed with integer division so the cells tile the
  ## image exactly (the last row/column absorbs any remainder). Cells with zero
  ## extent (grid finer than the image) are skipped. Falls back to a single
  ## whole-image SSIM if no cell has a positive area.
  if a.width != b.width or a.height != b.height:
    raise newException(ImageMathError,
      "tiledSsim size mismatch: " & $a.width & "x" & $a.height & " vs " &
      $b.width & "x" & $b.height)
  var minLocal = 0.0
  var sum = 0.0
  var count = 0
  for gy in 0 ..< gridY:
    let y0 = gy * a.height div gridY
    let y1 = (gy + 1) * a.height div gridY
    let ch = y1 - y0
    if ch <= 0: continue
    for gx in 0 ..< gridX:
      let x0 = gx * a.width div gridX
      let x1 = (gx + 1) * a.width div gridX
      let cw = x1 - x0
      if cw <= 0: continue
      let sa = cropGray(a, x0, y0, cw, ch)
      let sb = cropGray(b, x0, y0, cw, ch)
      let s = computeSsim(sa, sb)
      if count == 0 or s < minLocal: minLocal = s
      sum += s
      inc count
  if count == 0:
    let g = computeSsim(a, b)
    return (g, g)
  result = (minLocal, sum / float(count))

proc downscaleGray(img: GrayImage, nw, nh: int): seq[float] =
  ## Area-average downscale to `nw` x `nh` (row-major floats). Each destination
  ## pixel is the mean of the source pixels that map into it, which suppresses
  ## aliasing far better than nearest-neighbour and gives a stable pHash.
  result = newSeq[float](nw * nh)
  for oy in 0 ..< nh:
    let sy0 = oy * img.height div nh
    var sy1 = (oy + 1) * img.height div nh
    if sy1 <= sy0: sy1 = sy0 + 1
    if sy1 > img.height: sy1 = img.height
    for ox in 0 ..< nw:
      let sx0 = ox * img.width div nw
      var sx1 = (ox + 1) * img.width div nw
      if sx1 <= sx0: sx1 = sx0 + 1
      if sx1 > img.width: sx1 = img.width
      var acc = 0.0
      var cnt = 0
      for yy in sy0 ..< sy1:
        let rowStart = yy * img.width
        for xx in sx0 ..< sx1:
          acc += float(img.pixels[rowStart + xx].uint8)
          inc cnt
      result[oy * nw + ox] = if cnt > 0: acc / float(cnt) else: 0.0

proc dctHash*(img: GrayImage): uint64 =
  ## 64-bit DCT perceptual hash (pHash). The image is area-downscaled to 32x32,
  ## a 2D DCT-II is taken, and the top-left 8x8 low-frequency block is kept. The
  ## median of the 63 non-DC coefficients is the threshold: bit `i` (row-major
  ## over the 8x8 block, MSB-free little-endian by shift) is set when
  ## `coeff[i] > median`. Subtracting the median makes the hash invariant to
  ## overall brightness/contrast, so two frames that differ only in colour tone
  ## hash identically while a structural change flips several bits.
  const N = 32
  const K = 8
  if img.width == 0 or img.height == 0 or img.pixels.len == 0:
    raise newException(ImageMathError, "dctHash on empty image")
  let small = downscaleGray(img, N, N)

  # Precompute the DCT cosine table for the K low frequencies we keep.
  var cosT: array[K, array[N, float]]
  for u in 0 ..< K:
    for x in 0 ..< N:
      cosT[u][x] = cos((2.0 * float(x) + 1.0) * float(u) * PI / (2.0 * float(N)))

  # Separable DCT: first over x (rows), then over y (columns).
  var temp: array[K, array[N, float]]
  for u in 0 ..< K:
    for y in 0 ..< N:
      var s = 0.0
      let rowStart = y * N
      for x in 0 ..< N:
        s += small[rowStart + x] * cosT[u][x]
      temp[u][y] = s

  var coeffs: array[K * K, float]
  for u in 0 ..< K:
    for v in 0 ..< K:
      var s = 0.0
      for y in 0 ..< N:
        s += temp[u][y] * cosT[v][y]
      coeffs[u * K + v] = s

  # Median of the 63 AC (non-DC) coefficients.
  var vals: seq[float] = @[]
  for i in 1 ..< K * K:
    vals.add(coeffs[i])
  vals.sort()
  let median =
    if vals.len mod 2 == 1: vals[vals.len div 2]
    else: (vals[vals.len div 2 - 1] + vals[vals.len div 2]) / 2.0

  result = 0'u64
  for i in 0 ..< K * K:
    if coeffs[i] > median:
      result = result or (1'u64 shl uint(i))

proc hammingDistance*(a, b: uint64): int =
  ## Number of differing bits between two 64-bit hashes (popcount of the XOR).
  countSetBits(a xor b)

proc edgeMap(img: GrayImage, threshold: int): seq[bool] =
  ## Binary edge map via gradient magnitude approximated by the sum of the
  ## absolute forward differences in x and y; a pixel is an edge when that sum
  ## exceeds `threshold`. The last row / column have no forward neighbour and
  ## contribute a zero difference there.
  result = newSeq[bool](img.width * img.height)
  for y in 0 ..< img.height:
    let rowStart = y * img.width
    for x in 0 ..< img.width:
      let idx = rowStart + x
      let p = int(img.pixels[idx].uint8)
      var gx = 0
      var gy = 0
      if x + 1 < img.width:
        gx = abs(int(img.pixels[idx + 1].uint8) - p)
      if y + 1 < img.height:
        gy = abs(int(img.pixels[idx + img.width].uint8) - p)
      if gx + gy > threshold:
        result[idx] = true

proc edgeChangeRatio*(a, b: GrayImage, threshold = 32): float =
  ## Fraction of edge pixels that appear-or-disappear between `a` and `b`:
  ## |edges(a) XOR edges(b)| / |edges(a) OR edges(b)|. High when text / a box
  ## appears or vanishes (many edges toggle); low — zero, in fact — for a pure
  ## uniform brightness shift that leaves the gradient structure unchanged.
  ## Returns 0.0 when neither image has any edge pixel. `threshold` is the
  ## gradient-magnitude cutoff on the 0..255 scale.
  if a.width != b.width or a.height != b.height:
    raise newException(ImageMathError,
      "edgeChangeRatio size mismatch: " & $a.width & "x" & $a.height & " vs " &
      $b.width & "x" & $b.height)
  let ea = edgeMap(a, threshold)
  let eb = edgeMap(b, threshold)
  var union = 0
  var sym = 0
  for i in 0 ..< ea.len:
    if ea[i] or eb[i]:
      inc union
      if ea[i] != eb[i]:
        inc sym
  if union == 0:
    return 0.0
  result = float(sym) / float(union)
