## GuiAssert core: segmenting a frame series into distinct visual states.
##
## A recording is a series of frames sampled at a fixed rate. Consecutive
## frames are scored for similarity, and a new *segment* begins wherever the
## change between two neighbours exceeds a threshold; runs of visually similar
## frames collapse into one segment. Each segment carries a `[tStart, tEnd)`
## time range (from the frame index and the sample rate) and a `changeScore`
## (how different its first frame was from the one before it).
##
## Everything here works on decoded frames or on an already computed score
## series, so it is pure. Sampling and decoding a video file is the opt-in
## media backend's job (`gui_assert/video_analysis.segmentByChange` composes
## the two).

import ./[image, ssim]

type
  Segment* = tuple[tStart, tEnd, changeScore: float]
    ## One distinct visual state: its time range in seconds and the change
    ## score of its first frame (1.0 for the first segment).

  SegmentationError* = object of CatchableError
    ## Raised for parameters that cannot describe a frame series (a
    ## non-positive sample rate, a score series of the wrong length).

const
  defaultChangeThreshold* = 0.35
    ## The default change threshold of `segmentFrames`, the media backend's
    ## `segmentVideo` and `vision-segment`: the most-changed cell of the 4x4
    ## grid must drop by more than 35% (see `segmentFrames`).

proc scaledHeight*(width, height, scaleWidth: int): int =
  ## The height a `width` x `height` frame has when it is scaled to
  ## `scaleWidth` wide with its aspect ratio kept: rounded to the nearest
  ## pixel, at least 1. `vision-segment --scale-width` uses it for PNG frames
  ## and video alike. Raises `SegmentationError` for a non-positive size.
  if width <= 0 or height <= 0 or scaleWidth <= 0:
    raise newException(SegmentationError, "cannot scale a " & $width & "x" &
      $height & " frame to " & $scaleWidth & " wide")
  max(1, int(float(height) * float(scaleWidth) / float(width) + 0.5))

proc segmentBoundaries*(ssims: seq[float], threshold: float): seq[int] =
  ## Given `ssims`, where `ssims[i]` is the SSIM between frame `i` and frame
  ## `i+1`, return the frame indices at which a *new* segment begins.
  ##
  ## Frame 0 is always an implicit segment start, so the result always begins
  ## with `0`. A boundary is recorded at frame `i+1` when
  ## `1.0 - ssims[i] > threshold` (i.e. frame `i+1` differs enough from frame
  ## `i` to count as a new state). Consecutive sub-threshold frames therefore
  ## collapse into one segment.
  result = @[0]
  for i in 0 ..< ssims.len:
    if (1.0 - ssims[i]) > threshold:
      result.add(i + 1)

proc frameSimilarity*(prev, cur: GrayImage, useLocal = true,
                      gridX = 4, gridY = 4): float =
  ## The similarity score of two consecutive frames that `segmentBoundaries`
  ## consumes. With `useLocal` (the default) it is the SSIM of the
  ## most-changed cell of a `gridX` x `gridY` grid (`tiledSsim(...).minLocal`),
  ## which catches small, localised changes a whole-frame SSIM smears away;
  ## otherwise it is the global SSIM. Raises `ImageMathError` when the frames
  ## differ in size.
  if useLocal: tiledSsim(prev, cur, gridX, gridY).minLocal
  else: computeSsim(prev, cur)

proc segmentsFromSeries*(series: seq[float], numFrames: int,
                         sampleFps, threshold: float): seq[Segment] =
  ## Turn a similarity series into segments. `series[i]` scores frame `i`
  ## against frame `i+1`, so it has `numFrames - 1` entries; `sampleFps` is
  ## the rate the frames were sampled at. A single frame is one segment one
  ## sample interval long. Raises `SegmentationError` for a non-positive
  ## `sampleFps`, an empty series of frames, or a series of the wrong length.
  if not (sampleFps > 0.0):
    raise newException(SegmentationError,
      "sampleFps must be positive, got " & $sampleFps)
  if numFrames <= 0:
    raise newException(SegmentationError, "no frames to segment")
  if series.len != numFrames - 1:
    raise newException(SegmentationError,
      "a series of " & $numFrames & " frames has " & $(numFrames - 1) &
      " scores, got " & $series.len)
  if numFrames == 1:
    return @[(0.0, 1.0 / sampleFps, 1.0)]
  let boundaries = segmentBoundaries(series, threshold)
  for si in 0 ..< boundaries.len:
    let b = boundaries[si]
    let nb = if si + 1 < boundaries.len: boundaries[si + 1] else: numFrames
    let score = if b == 0: 1.0 else: 1.0 - series[b - 1]
    result.add((float(b) / sampleFps, float(nb) / sampleFps, score))

proc segmentFrames*(frames: seq[GrayImage], sampleFps: float,
                    threshold = defaultChangeThreshold, useLocal = true,
                    gridX = 4, gridY = 4): seq[Segment] =
  ## Segment an in-memory frame series: score each consecutive pair with
  ## `frameSimilarity` and split with `segmentsFromSeries`. The default
  ## `threshold` (0.35, applied to the most-changed cell) is the one
  ## `video_analysis.segmentByChange` uses for its local mode.
  var series: seq[float] = @[]
  for i in 1 ..< frames.len:
    series.add frameSimilarity(frames[i - 1], frames[i], useLocal, gridX, gridY)
  result = segmentsFromSeries(series, frames.len, sampleFps, threshold)
