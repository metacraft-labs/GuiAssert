## GuiAssert core: perceptual hashing and edge-change scoring.
##
## Signals that complement SSIM when deciding whether two frames show the same
## state:
##
## * `dctHash` is a 64-bit DCT perceptual hash (pHash); `hammingDistance`
##   scores two hashes. Frames within a small Hamming radius are
##   near-duplicates.
## * `edgeChangeRatio` measures the symmetric difference of the two binary
##   edge maps over their union: high when text or a box appears or
##   disappears, low for a pure colour or brightness shift that keeps the same
##   structure.

import std/[math, bitops, algorithm]

import ./image

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
