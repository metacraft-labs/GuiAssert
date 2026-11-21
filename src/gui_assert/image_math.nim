## GuiAssert Visual Math Engine (compatibility module)
##
## The image maths that used to live here is now part of the pure core, and
## the ffmpeg-backed decoding is the opt-in media backend:
##
## * `GrayImage` and `ImageMathError` live in `gui_assert/core/image`;
## * `computeSsim` and `tiledSsim` in `gui_assert/core/ssim`;
## * `dctHash`, `hammingDistance` and `edgeChangeRatio` in
##   `gui_assert/core/hashing`;
## * `decodeGray` and `probeImageSize` (ffmpeg / ffprobe subprocesses) in
##   `gui_assert/backends/media/ffmpeg`.
##
## This module re-exports all of them under their historical names, so code
## that imports `gui_assert/image_math` compiles unchanged, and keeps the one
## convenience that needs both halves, `ssimFromPaths`. New code that wants
## only the maths imports the core modules directly and links no subprocess
## code.

import ./core/[image, ssim, hashing]
import ./backends/media/ffmpeg

export image.ImageMathError, image.GrayImage
export ssim, hashing
export ffmpeg.decodeGray, ffmpeg.probeImageSize

proc ssimFromPaths*(a, b: string): float =
  ## Convenience wrapper: decode both images with ffmpeg (`decodeGray`) and
  ## compute their global SSIM.
  let imgA = decodeGray(a)
  let imgB = decodeGray(b)
  result = computeSsim(imgA, imgB)
