## VU8 tests: change-detection hardening (tiled/local SSIM, DCT perceptual
## hash + dedup, edge-change ratio).
##
## Mocking policy: these tests mock NOTHING. Every case constructs `GrayImage`
## values directly in memory and exercises the real pure procs from
## `image_math` / `video_analysis` — no ffmpeg, no tesseract, no subprocess.
## The point of the suite is to prove pure-CV facts about the new signals:
##   * a small, localised change drives tiled `minLocal` far below 1.0 while the
##     whole-frame SSIM stays high (the whole motivation for tiled SSIM);
##   * the DCT pHash is 0 for identical frames, small for a tiny local change,
##     large for a structurally different frame, and its Hamming-distance dedup
##     collapses near-duplicates while keeping distinct states;
##   * the edge-change ratio is high when edges appear and ~0 for a pure uniform
##     brightness shift that preserves structure.
## (The real-ffmpeg 2-state regression stays in tvideo_analysis.nim.)

import std/[unittest]

import ../src/gui_assert/image_math
import ../src/gui_assert/video_analysis

# ---------------------------------------------------------------------------
# In-memory GrayImage builders (no ffmpeg)
# ---------------------------------------------------------------------------

proc mkGray(w, h: int, fill: uint8): GrayImage =
  result.width = w
  result.height = h
  result.pixels = newString(w * h)
  for i in 0 ..< w * h:
    result.pixels[i] = char(fill)

proc noiseImg(w, h: int, seed: uint32): GrayImage =
  ## Deterministic textured image (an LCG) — gives both global and local SSIM a
  ## well-defined, non-degenerate value.
  result.width = w
  result.height = h
  result.pixels = newString(w * h)
  var s = seed
  for i in 0 ..< w * h:
    s = s * 1664525'u32 + 1013904223'u32
    result.pixels[i] = char(uint8((s shr 24) and 0xFF))

proc smoothGrad(w, h: int, maxV = 255): GrayImage =
  ## Smooth diagonal gradient in [0, maxV]; well-behaved for pHash / edges.
  result.width = w
  result.height = h
  result.pixels = newString(w * h)
  for y in 0 ..< h:
    for x in 0 ..< w:
      result.pixels[y * w + x] = char(uint8((x + y) * maxV div (w + h)))

proc rect(img: var GrayImage, x0, y0, rw, rh: int, v: uint8) =
  for y in y0 ..< y0 + rh:
    for x in x0 ..< x0 + rw:
      img.pixels[y * img.width + x] = char(v)

# ---------------------------------------------------------------------------
# Tiled / local SSIM
# ---------------------------------------------------------------------------

suite "vu8 tiled ssim":
  test "test_tiled_ssim_local_change":
    # Two 128x128 textured frames identical EXCEPT a small bright rectangle that
    # fills most of the top-left cell of the default 4x4 grid. The change is
    # ~3% of the frame, so whole-frame SSIM barely moves, but it dominates ONE
    # cell so tiled minLocal collapses.
    let size = 128
    let cell = size div 4
    var a = noiseImg(size, size, 12345)
    var b = a
    b.rect(2, 2, cell - 4, cell - 4, 255)

    let global = computeSsim(a, b)
    let tiled = tiledSsim(a, b)   # default 4x4 grid

    # Global SSIM stays HIGH (near 1.0): a whole-frame detector would NOT fire
    # (1 - global is well below the 0.35 local threshold).
    check global > 0.85
    check (1.0 - global) < 0.35
    # ...yet the most-changed cell collapses: the local detector DOES fire.
    check tiled.minLocal < 0.5
    check (1.0 - tiled.minLocal) > 0.35
    # The min is meaningfully below the mean (one cell changed, the rest are ~1).
    check tiled.minLocal < tiled.meanLocal - 0.3

  test "identical frames -> minLocal 1.0":
    let a = noiseImg(80, 60, 7)
    let t = tiledSsim(a, a)
    check abs(t.minLocal - 1.0) < 1e-9
    check abs(t.meanLocal - 1.0) < 1e-9

# ---------------------------------------------------------------------------
# DCT perceptual hash + Hamming dedup
# ---------------------------------------------------------------------------

suite "vu8 phash":
  test "test_phash_hamming":
    let base = smoothGrad(128, 128)

    # Identical images -> distance 0.
    check hammingDistance(dctHash(base), dctHash(base)) == 0

    # A small local change (a tiny 10x10 patch) -> small distance.
    var tiny = base
    tiny.rect(4, 4, 10, 10, 255)
    let dTiny = hammingDistance(dctHash(base), dctHash(tiny))
    check dTiny > 0
    check dTiny <= 6            # within the default dedup radius

    # A structurally very different image -> large distance.
    var chk = base
    for y in 0 ..< 128:
      for x in 0 ..< 128:
        chk.pixels[y * 128 + x] =
          char(if ((x div 16) + (y div 16)) mod 2 == 0: 240'u8 else: 15'u8)
    let dBig = hammingDistance(dctHash(base), dctHash(chk))
    check dBig >= 20
    # Small change is unambiguously closer than a very different frame.
    check dTiny < dBig

  test "dedup collapses near-dupes, keeps distinct":
    # Three states: base, a near-duplicate (tiny patch), and a very different
    # frame. Dedup at the default radius must fold the first two into one state
    # and keep the third distinct.
    let base = smoothGrad(128, 128)
    var tiny = base
    tiny.rect(4, 4, 10, 10, 255)
    var chk = base
    for y in 0 ..< 128:
      for x in 0 ..< 128:
        chk.pixels[y * 128 + x] =
          char(if ((x div 16) + (y div 16)) mod 2 == 0: 240'u8 else: 15'u8)

    let hashes = @[dctHash(base), dctHash(tiny), dctHash(chk)]

    var a: VideoAnalysis
    a.info = VideoInfo(path: "/tmp/x.mp4", durationS: 3.0, width: 128, height: 128)
    var f0, f1, f2: Keyframe
    f0.index = 0; f0.tStart = 0.0; f0.tEnd = 1.0
    f1.index = 1; f1.tStart = 1.0; f1.tEnd = 2.0
    f2.index = 2; f2.tStart = 2.0; f2.tEnd = 3.0
    a.frames = @[f0, f1, f2]

    let d = dedupeConsecutive(a, hashes, maxDist = 6)
    # base+tiny collapse into one; chk stays -> exactly 2 distinct states.
    check d.frames.len == 2
    # The kept first state absorbed the near-dup's time range.
    check d.frames[0].tStart == 0.0
    check d.frames[0].tEnd == 2.0
    check d.frames[0].index == 0
    # The distinct state survived and was re-indexed.
    check d.frames[1].tStart == 2.0
    check d.frames[1].tEnd == 3.0
    check d.frames[1].index == 1

    # With a radius of 0, nothing merges (all three kept).
    let d0 = dedupeConsecutive(a, hashes, maxDist = 0)
    check d0.frames.len == 3

# ---------------------------------------------------------------------------
# Edge-change ratio
# ---------------------------------------------------------------------------

suite "vu8 edge change ratio":
  test "test_edge_change_ratio":
    # Adding edges: a is a flat field (no edges); b draws a bright box -> the
    # box outline is all-new edges -> ECR is high (every edge in the union is a
    # symmetric-difference edge).
    var flat = mkGray(80, 80, 100)
    var boxed = flat
    boxed.rect(20, 20, 30, 30, 250)
    let ecrAdded = edgeChangeRatio(flat, boxed)
    check ecrAdded > 0.8

    # A pure uniform brightness shift over a structured image keeps the same
    # gradient structure, so the edge map is unchanged -> ECR ~ 0. The gradient
    # tops out well below 255 so the +20 shift never clamps (which would forge
    # or erase edges).
    let g = smoothGrad(80, 80, maxV = 200)
    var gShift = g
    for i in 0 ..< gShift.pixels.len:
      gShift.pixels[i] = char(uint8(int(gShift.pixels[i].uint8) + 20))
    let ecrShift = edgeChangeRatio(g, gShift)
    check ecrShift < 0.05
    # And the added-edges case is unambiguously the higher signal.
    check ecrShift < ecrAdded
