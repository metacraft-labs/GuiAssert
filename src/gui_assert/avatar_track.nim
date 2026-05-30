## Avatar Track — animated source-crop + output-rect timeline.
##
## A `Script` may carry an optional `AvatarTrack` describing how a single
## talking-head source video is composited onto the screencast.  The
## track is an ordered sequence of `AvatarKeyframe`s; each keyframe
## anchors a complete geometry + key configuration at a specific
## timeline `time`.  Between keyframes every continuous parameter is
## linearly interpolated, while discrete fields (key method, key
## colour) snap to the value of the keyframe at or before `t`.
##
## Source crop coordinates are in *source pixels*.  Output destination
## coordinates are in *canvas pixels* of the composed video.  Both are
## stored as floats so the editor UI can drag sub-pixel without
## clamping noise; the renderer rounds to integers in the final
## ffmpeg expression.

import std/[json, options, strutils, tables]

type
  RectF* = object
    ## Floating-point rectangle in the relevant coordinate system.
    x*, y*, w*, h*: float

  AvatarKeyMethod* = enum
    akmChroma = "chroma"
    akmColor  = "color"
    akmLuma   = "luma"

  AvatarKeyframe* = object
    time*: float
      ## Timeline second this keyframe is anchored to (relative to the
      ## screencast).  Must be ≥ 0 and strictly increasing within an
      ## `AvatarTrack.keyframes` sequence.
    srcCrop*: RectF
      ## Sub-rectangle of the source video to lift, in *source pixels*.
      ## `w` or `h` ≤ 0 means "to the source's right / bottom edge".
    dstRect*: RectF
      ## Destination rectangle on the canvas, in *canvas pixels*.
      ## The cropped + keyed source is scaled to `dstRect.w` × `dstRect.h`
      ## and overlaid at `(dstRect.x, dstRect.y)`.
    keyMethod*: AvatarKeyMethod
    keyColor*: string         ## "white", "0x00ff00", "#dcdcdc" etc.
    keySimilarity*: float
    keyBlend*: float
    lumaThreshold*: float
    lumaTolerance*: float
    despill*: bool
    despillType*: string

  AvatarTrack* = object
    sourceVideo*: string
      ## Absolute path to the provider's raw greenscreen render.
    keyframes*: seq[AvatarKeyframe]

proc initRectF*(x, y, w, h: float): RectF =
  RectF(x: x, y: y, w: w, h: h)

proc defaultAvatarKeyframe*(time = 0.0): AvatarKeyframe =
  AvatarKeyframe(
    time: time,
    srcCrop: initRectF(0.0, 0.0, 0.0, 0.0),
    dstRect: initRectF(0.0, 0.0, 320.0, 320.0),
    keyMethod: akmChroma,
    keyColor: "0x00ff00",
    keySimilarity: 0.18,
    keyBlend: 0.10,
    lumaThreshold: 0.9,
    lumaTolerance: 0.05,
    despill: true,
    despillType: "green",
  )

proc isEmpty*(t: AvatarTrack): bool =
  t.sourceVideo.len == 0 and t.keyframes.len == 0

# ---------------------------------------------------------------------------
# JSON roundtrip
# ---------------------------------------------------------------------------

proc rectToJson*(r: RectF): JsonNode =
  result = newJObject()
  result["x"] = %r.x
  result["y"] = %r.y
  result["w"] = %r.w
  result["h"] = %r.h

proc rectFromJson*(node: JsonNode, path: string): RectF =
  if node.kind != JObject:
    raise newException(ValueError,
      path & " must be an object {x,y,w,h}, got " & $node.kind)
  proc f(name: string): float =
    if not node.hasKey(name):
      raise newException(ValueError,
        path & " is missing field `" & name & "`")
    let v = node[name]
    case v.kind
    of JInt:   float(v.getInt)
    of JFloat: v.getFloat
    else:
      raise newException(ValueError,
        path & "." & name & " must be numeric, got " & $v.kind)
  result = RectF(x: f("x"), y: f("y"), w: f("w"), h: f("h"))

proc keyframeToJson*(k: AvatarKeyframe): JsonNode =
  result = newJObject()
  result["time"] = %k.time
  result["src_crop"] = rectToJson(k.srcCrop)
  result["dst_rect"] = rectToJson(k.dstRect)
  result["key_method"] = %($k.keyMethod)
  result["key_color"] = %k.keyColor
  result["key_similarity"] = %k.keySimilarity
  result["key_blend"] = %k.keyBlend
  result["luma_threshold"] = %k.lumaThreshold
  result["luma_tolerance"] = %k.lumaTolerance
  result["despill"] = %k.despill
  result["despill_type"] = %k.despillType

proc parseKeyMethod*(s: string): AvatarKeyMethod =
  case s.toLowerAscii
  of "chroma": akmChroma
  of "color":  akmColor
  of "luma":   akmLuma
  else: raise newException(ValueError, "unknown key method: " & s)

proc keyframeFromJson*(node: JsonNode, path: string): AvatarKeyframe =
  if node.kind != JObject:
    raise newException(ValueError,
      path & " must be an object, got " & $node.kind)
  result = defaultAvatarKeyframe()
  proc f(name: string, default: float): float =
    if not node.hasKey(name): return default
    let v = node[name]
    case v.kind
    of JInt:   float(v.getInt)
    of JFloat: v.getFloat
    else:
      raise newException(ValueError,
        path & "." & name & " must be numeric")
  proc s(name, default: string): string =
    if not node.hasKey(name): return default
    if node[name].kind != JString:
      raise newException(ValueError,
        path & "." & name & " must be a string")
    node[name].getStr
  proc b(name: string, default: bool): bool =
    if not node.hasKey(name): return default
    if node[name].kind != JBool:
      raise newException(ValueError,
        path & "." & name & " must be a bool")
    node[name].getBool
  result.time = f("time", 0.0)
  if node.hasKey("src_crop"):
    result.srcCrop = rectFromJson(node["src_crop"], path & ".src_crop")
  if node.hasKey("dst_rect"):
    result.dstRect = rectFromJson(node["dst_rect"], path & ".dst_rect")
  result.keyMethod = parseKeyMethod(s("key_method", $result.keyMethod))
  result.keyColor = s("key_color", result.keyColor)
  result.keySimilarity = f("key_similarity", result.keySimilarity)
  result.keyBlend = f("key_blend", result.keyBlend)
  result.lumaThreshold = f("luma_threshold", result.lumaThreshold)
  result.lumaTolerance = f("luma_tolerance", result.lumaTolerance)
  result.despill = b("despill", result.despill)
  result.despillType = s("despill_type", result.despillType)

proc avatarTrackToJson*(t: AvatarTrack): JsonNode =
  result = newJObject()
  result["source_video"] = %t.sourceVideo
  let kfs = newJArray()
  for k in t.keyframes:
    kfs.add keyframeToJson(k)
  result["keyframes"] = kfs

proc avatarTrackFromJson*(node: JsonNode, path = "avatar"): AvatarTrack =
  if node.kind != JObject:
    raise newException(ValueError,
      path & " must be an object, got " & $node.kind)
  if node.hasKey("source_video"):
    if node["source_video"].kind != JString:
      raise newException(ValueError,
        path & ".source_video must be a string")
    result.sourceVideo = node["source_video"].getStr
  if node.hasKey("keyframes"):
    if node["keyframes"].kind != JArray:
      raise newException(ValueError,
        path & ".keyframes must be an array")
    for i, k in node["keyframes"].elems:
      result.keyframes.add keyframeFromJson(k, path & ".keyframes[" & $i & "]")

# ---------------------------------------------------------------------------
# Validation + interpolation
# ---------------------------------------------------------------------------

proc validate*(t: AvatarTrack) =
  ## Raise if the track is not monotonic in time.
  for i in 1 ..< t.keyframes.len:
    if t.keyframes[i].time <= t.keyframes[i - 1].time:
      raise newException(ValueError,
        "avatar keyframes must have strictly increasing time, but " &
        "keyframe " & $i & " at t=" & $t.keyframes[i].time &
        " is not after keyframe " & $(i - 1) & " at t=" &
        $t.keyframes[i - 1].time)

proc sampleAt*(t: AvatarTrack, time: float): AvatarKeyframe =
  ## Return the interpolated keyframe at `time`.  Continuous fields
  ## (rect dimensions, key tuning floats) are linearly interpolated
  ## between the surrounding keyframes; discrete fields (method,
  ## colour, despill) snap to the value of the keyframe at or before
  ## `time`.  Outside the track range we hold the boundary value.
  if t.keyframes.len == 0:
    return defaultAvatarKeyframe(time)
  if time <= t.keyframes[0].time:
    return t.keyframes[0]
  if time >= t.keyframes[^1].time:
    return t.keyframes[^1]
  var i = 0
  while i + 1 < t.keyframes.len and t.keyframes[i + 1].time <= time:
    inc i
  let k0 = t.keyframes[i]
  let k1 = t.keyframes[i + 1]
  let span = k1.time - k0.time
  let u = if span > 0: (time - k0.time) / span else: 0.0
  proc lerp(a, b: float): float = a + (b - a) * u
  result = k0
  result.time = time
  result.srcCrop = RectF(
    x: lerp(k0.srcCrop.x, k1.srcCrop.x),
    y: lerp(k0.srcCrop.y, k1.srcCrop.y),
    w: lerp(k0.srcCrop.w, k1.srcCrop.w),
    h: lerp(k0.srcCrop.h, k1.srcCrop.h),
  )
  result.dstRect = RectF(
    x: lerp(k0.dstRect.x, k1.dstRect.x),
    y: lerp(k0.dstRect.y, k1.dstRect.y),
    w: lerp(k0.dstRect.w, k1.dstRect.w),
    h: lerp(k0.dstRect.h, k1.dstRect.h),
  )
  result.keySimilarity = lerp(k0.keySimilarity, k1.keySimilarity)
  result.keyBlend = lerp(k0.keyBlend, k1.keyBlend)
  result.lumaThreshold = lerp(k0.lumaThreshold, k1.lumaThreshold)
  result.lumaTolerance = lerp(k0.lumaTolerance, k1.lumaTolerance)
