## GuiAssert core: the Structural Similarity Index (SSIM).
##
## SSIM is computed with the canonical formula (Wang et al., "Image Quality
## Assessment: From Error Visibility to Structural Similarity", IEEE TIP 2004):
##
##   SSIM(x, y) = (2*muX*muY + C1) * (2*sigmaXY + C2)
##              / ((muX^2 + muY^2 + C1) * (sigmaX^2 + sigmaY^2 + C2))
##
## `computeSsim` takes the statistics over the **whole image** (a "global"
## SSIM, no sliding Gaussian window): identical images score 1.0, and the
## visual review loop compares whole frames against frozen goldens, not
## patches. Global SSIM is dominated by large unchanged regions, so
## `tiledSsim` splits the frame into a grid and reports the most-changed cell
## (`minLocal`) as well as the mean: a small change confined to one cell pulls
## `minLocal` down while the global SSIM stays near 1.0.

import ./[geometry, image]

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
  # Identical pixels are exactly 1.0 by definition; the arithmetic below can
  # round that to 1.0000000000000002, which a caller testing `== 1.0` (or
  # reading the documented range) must not see.
  if a.pixels == b.pixels:
    return 1.0

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
  # Rounding can carry the ratio a hair past the documented range.
  result = clamp(numerator / denominator, -1.0, 1.0)


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
      let cell = rect(x0, y0, cw, ch)
      let sa = crop(a, cell)
      let sb = crop(b, cell)
      let s = computeSsim(sa, sb)
      if count == 0 or s < minLocal: minLocal = s
      sum += s
      inc count
  if count == 0:
    let g = computeSsim(a, b)
    return (g, g)
  result = (minLocal, sum / float(count))
