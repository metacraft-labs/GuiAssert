## GuiAssert Video Analysis — segmentation by visual change
##
## This module turns a recorded screencast into a *timeline of distinct visual
## states*. It composes the primitives that already exist in GuiAssert:
##
##   * `media.resolveFfmpegBinary` (+ an `ffprobe` sibling) to discover the
##     pinned ffmpeg/ffprobe binaries,
##   * `image_math.decodeGray` to decode sampled frames to 8-bit grayscale,
##   * `image_math.computeSsim` to score consecutive frames for similarity.
##
## The recording is sampled at a low fps and downscaled (SSIM over whole
## frames is cheap and robust at small sizes). A new *segment* begins whenever
## `1 - SSIM(frame i, frame i+1)` exceeds a threshold; runs of visually similar
## frames collapse into a single segment. Each segment carries a `[tStart,
## tEnd)` time range (derived from the frame index / sample fps) and a
## `changeScore` (how different the entering frame was from its predecessor).
##
## As in the rest of GuiAssert, the *pure* argv-builders and the segmentation
## core (`buildProbeArgv`, `parseProbeJson`, `buildSampleFramesArgv`,
## `buildExtractFrameArgv`, `segmentBoundaries`) are separated from the
## *effectful* procs (`probeVideo`, `segmentByChange`) so the former are unit
## testable without a subprocess and the latter are integration tested against
## real ffmpeg.
##
## The `Keyframe.words`/`text`/`urls` fields are declared here (so the full
## timeline shape is stable) but are only *populated* by VU2's OCR pass; VU1
## fills in the segmentation fields only.

import std/[json, os, osproc, streams, strtabs, strutils, algorithm,
            tempfiles, re, sets, tables]

import ./media
import ./image_math
import ./ocr

type
  VideoAnalysisError* = object of CatchableError
    ## Raised on ffprobe/ffmpeg failures, malformed probe JSON, or when a
    ## sampled frame cannot be decoded.

  VideoInfo* = object
    ## Container-level facts about a video, read from ffprobe.
    path*: string
    durationS*: float
    width*, height*: int

  Keyframe* = object
    ## One detected distinct visual state. VU1 populates the segmentation
    ## fields (`index`, `tStart`, `tEnd`, `changeScore`, `imagePath`); the
    ## OCR-derived fields (`words`, `text`, `urls`) are filled by VU2.
    index*: int
    tStart*, tEnd*: float
    changeScore*: float          ## 1 - SSIM vs the previous kept state
    imagePath*: string           ## extracted full-res PNG (VU2)
    words*: seq[OcrWord]
    text*: string                ## reconstructed reading-order text (VU2)
    urls*: seq[string]           ## extracted URLs / host:port paths (VU2)

  VideoAnalysis* = object
    info*: VideoInfo
    frames*: seq[Keyframe]       ## one per detected distinct state

# ---------------------------------------------------------------------------
# Pure argv builders
# ---------------------------------------------------------------------------
#
# These return the *arguments* only (no leading binary token): the effectful
# procs below prepend the resolved ffprobe/ffmpeg path. This keeps the builders
# trivial to assert on and independent of binary discovery.

proc buildProbeArgv*(path: string): seq[string] =
  ## ffprobe argv emitting JSON with the first video stream's width/height
  ## and the container duration.
  @[
    "-v", "error",
    "-select_streams", "v:0",
    "-show_entries", "stream=width,height:format=duration",
    "-of", "json",
    path
  ]

proc buildSampleFramesArgv*(path: string, fps: float, scaleW: int,
                            outPattern: string): seq[string] =
  ## ffmpeg argv extracting frames at `fps` fps, downscaled to width `scaleW`
  ## while preserving the aspect ratio (`scale=W:-2` keeps the height even, a
  ## requirement of most encoders and harmless for raw PNG output), written to
  ## `outPattern` (e.g. `dir/f_%05d.png`).
  let fpsStr = formatFloat(fps, ffDecimal, precision = 4).strip(
    leading = false, trailing = true, chars = {'0'}).strip(
    leading = false, trailing = true, chars = {'.'})
  @[
    "-hide_banner",
    "-loglevel", "error",
    "-y",
    "-i", path,
    "-vf", "fps=" & fpsStr & ",scale=" & $scaleW & ":-2",
    outPattern
  ]

proc buildExtractFrameArgv*(path: string, t: float, outPng: string): seq[string] =
  ## ffmpeg argv extracting one full-resolution PNG at timestamp `t`. `-ss`
  ## precedes `-i` for a fast (keyframe-accurate) seek.
  let tStr = formatFloat(t, ffDecimal, precision = 3)
  @[
    "-hide_banner",
    "-loglevel", "error",
    "-y",
    "-ss", tStr,
    "-i", path,
    "-frames:v", "1",
    outPng
  ]

# ---------------------------------------------------------------------------
# Pure parsing
# ---------------------------------------------------------------------------

proc parseProbeJson*(jsonText: string): VideoInfo =
  ## Parse the JSON emitted by `buildProbeArgv` into a `VideoInfo`. The
  ## `format.duration` field is emitted by ffprobe as a *string* ("49.72"),
  ## but we also accept a JSON number for robustness.
  var node: JsonNode
  try:
    node = parseJson(jsonText)
  except JsonParsingError as e:
    raise newException(VideoAnalysisError,
      "Could not parse ffprobe JSON: " & e.msg)

  if node.hasKey("streams") and node["streams"].kind == JArray and
     node["streams"].len > 0:
    let s = node["streams"][0]
    if s.hasKey("width"): result.width = s["width"].getInt
    if s.hasKey("height"): result.height = s["height"].getInt

  if node.hasKey("format") and node["format"].hasKey("duration"):
    let d = node["format"]["duration"]
    case d.kind
    of JString:
      try:
        result.durationS = parseFloat(d.getStr)
      except ValueError:
        result.durationS = 0.0
    of JFloat: result.durationS = d.getFloat
    of JInt: result.durationS = float(d.getInt)
    else: discard

# ---------------------------------------------------------------------------
# Pure segmentation core
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Pure OCR post-processing: URL extraction + reading-order reconstruction
# ---------------------------------------------------------------------------

proc trimUrlEnds(s: string): string =
  ## Strip surrounding punctuation that OCR / prose commonly glues onto a URL
  ## token (a trailing sentence period, wrapping brackets/quotes, etc.). Port
  ## and path separators are interior, so trimming the ends never touches them.
  const junk = {'.', ',', ';', ':', '!', '?', ')', '(', '[', ']', '{', '}',
                '\'', '"', '<', '>', '`', '\\'}
  result = s.strip()
  while result.len > 0 and result[0] in junk:
    result = result[1 .. ^1]
  while result.len > 0 and result[^1] in junk:
    result.setLen(result.len - 1)

# Full `http(s)://…` forms — grab everything up to the next whitespace, then
# let `trimUrlEnds` peel a trailing `.`/`)` etc.
let fullUrlRe = re"(?i)\bhttps?://[^\s]+"

# Bare `host[:port][/path]` forms. The host is an IPv4 literal or a dotted
# domain ending in an alphabetic TLD; a match must carry a `:port` and/or a
# `/path` so that plain dotted numbers (version strings like `1.2.3`) and bare
# words never qualify.
let bareUrlRe = re(
  r"(?i)\b(?:(?:\d{1,3}\.){3}\d{1,3}|(?:[a-z0-9-]+\.)+[a-z]{2,})" &
  r"(?::\d{1,5}(?:/[^\s]*)?|/[^\s]*)")

proc extractUrls*(text: string): seq[string] =
  ## Extract URLs from noisy OCR text. Recognises both fully-qualified
  ## `http(s)://host[:port]/path` URLs and bare `host:port/path` forms (e.g.
  ## `127.0.0.1:8080/docs/index.html`), de-duplicates while preserving first
  ## appearance order, and rejects non-URL tokens (plain words, bare numbers,
  ## dotted version strings). Fully-qualified matches are found first and
  ## masked out so their embedded host:port is not re-reported as a second,
  ## bare URL.
  result = @[]
  var seen = initHashSet[string]()

  var candidates: seq[string] = @[]
  for m in findAll(text, fullUrlRe):
    candidates.add(m)
  # Mask out fully-qualified matches so their embedded host:port is not
  # re-reported by the bare-form pass.
  let masked = replace(text, fullUrlRe, " ")
  for m in findAll(masked, bareUrlRe):
    candidates.add(m)

  for raw in candidates:
    let u = trimUrlEnds(raw)
    if u.len == 0: continue
    if u notin seen:
      seen.incl(u)
      result.add(u)

proc wordsToReadingOrderText*(words: seq[OcrWord]): string =
  ## Reconstruct human reading-order text from unordered OCR words. Words are
  ## grouped by `(blockNum, lineNum)`; the resulting lines are ordered by their
  ## top-y (the minimum `bbox[1]` in the group), and words within a line by
  ## their left-x (`bbox[0]`). Lines are joined with `"\n"`, words with a
  ## single space.
  var groups = initOrderedTable[(int, int), seq[OcrWord]]()
  for w in words:
    let key = (w.blockNum, w.lineNum)
    if key notin groups:
      groups[key] = @[]
    groups[key].add(w)

  type Line = tuple[topY: int, minX: int, text: string]
  var lines: seq[Line] = @[]
  for key, ws in groups:
    var ordered = ws
    ordered.sort(proc(a, b: OcrWord): int = cmp(a.bbox[0], b.bbox[0]))
    var topY = high(int)
    var minX = high(int)
    var pieces: seq[string] = @[]
    for w in ordered:
      if w.bbox[1] < topY: topY = w.bbox[1]
      if w.bbox[0] < minX: minX = w.bbox[0]
      pieces.add(w.text)
    lines.add((topY: topY, minX: minX, text: pieces.join(" ")))

  # Order lines top-to-bottom, tie-break left-to-right.
  lines.sort(proc(a, b: Line): int =
    result = cmp(a.topY, b.topY)
    if result == 0: result = cmp(a.minX, b.minX))

  var outLines: seq[string] = @[]
  for ln in lines:
    outLines.add(ln.text)
  result = outLines.join("\n")

# ---------------------------------------------------------------------------
# Pure serialization: JSON + markdown digest
# ---------------------------------------------------------------------------

proc toJson*(a: VideoAnalysis): JsonNode =
  ## Serialize a `VideoAnalysis` to a `JsonNode`: the container `info` plus one
  ## object per detected state carrying its index, time range, change score,
  ## keyframe image path, reading-order text, detected URLs and OCR word count.
  result = %*{
    "info": {
      "path": a.info.path,
      "durationS": a.info.durationS,
      "width": a.info.width,
      "height": a.info.height
    },
    "frames": newJArray()
  }
  for f in a.frames:
    result["frames"].add(%*{
      "index": f.index,
      "tStart": f.tStart,
      "tEnd": f.tEnd,
      "changeScore": f.changeScore,
      "imagePath": f.imagePath,
      "text": f.text,
      "urls": f.urls,
      "wordCount": f.words.len
    })

proc toDigest*(a: VideoAnalysis): string =
  ## Render a markdown timeline of the analysis: a header with the source path,
  ## dimensions and duration, then one `## State N [tStart–tEnd s]` section per
  ## detected state carrying its change score, any detected URLs and a short
  ## excerpt (~200 chars) of the state's reading-order text.
  var lines: seq[string] = @[]
  lines.add("# Video analysis: " & a.info.path)
  lines.add("")
  lines.add("- Dimensions: " & $a.info.width & "x" & $a.info.height)
  lines.add("- Duration: " & formatFloat(a.info.durationS, ffDecimal,
                                         precision = 2) & "s")
  lines.add("- States: " & $a.frames.len)
  lines.add("")
  for f in a.frames:
    let ts = formatFloat(f.tStart, ffDecimal, precision = 2)
    let te = formatFloat(f.tEnd, ffDecimal, precision = 2)
    let cs = formatFloat(f.changeScore, ffDecimal, precision = 3)
    lines.add("## State " & $f.index & "  [" & ts & "–" & te & " s]  change=" &
              cs)
    if f.urls.len > 0:
      lines.add("")
      lines.add("Detected URLs:")
      for u in f.urls:
        lines.add("- " & u)
    lines.add("")
    var excerpt = f.text.replace("\n", " ").strip()
    if excerpt.len > 200:
      excerpt = excerpt[0 ..< 200] & "…"
    lines.add("> " & excerpt)
    lines.add("")
  result = lines.join("\n")

# ---------------------------------------------------------------------------
# Pure query / assertion API (VU3)
# ---------------------------------------------------------------------------
#
# These operate over an already-assembled `VideoAnalysis` and never touch a
# subprocess or the filesystem — they let a test (or an agent) assert, from the
# pixels-derived timeline alone, "did text X appear?", "where?", "was URL Y
# seen?", "how many distinct states?", "is text X in this region of frame N?".
#
# Matching rules:
#   * `containsText` matches at the *text level*: the needle is searched as a
#     substring of each frame's reconstructed reading-order `text` (words joined
#     by spaces within a line and by "\n" across lines). This means a multi-word
#     needle like "Home page" can match across adjacent words on the same line.
#   * `locateText` matches at the *word level*: the needle is searched as a
#     substring of each individual `OcrWord.text`. A multi-word needle therefore
#     only matches if a *single* word contains it verbatim (OCR emits one token
#     per whitespace-separated word, so multi-word needles rarely match here —
#     use `containsText` for cross-word phrases).
# Both are case-insensitive by default (`caseInsensitive = true`).

proc matchesSub(haystack, needle: string, caseInsensitive: bool): bool =
  ## Substring test, optionally case-insensitive. An empty needle never matches
  ## (so `containsText`/`locateText` don't report spurious hits for "").
  if needle.len == 0:
    return false
  if caseInsensitive:
    haystack.toLowerAscii.contains(needle.toLowerAscii)
  else:
    haystack.contains(needle)

proc containsText*(a: VideoAnalysis, needle: string,
                   caseInsensitive = true): bool =
  ## True if any frame's reconstructed reading-order `text` contains `needle`
  ## as a substring (text-level match; case-insensitive by default). Because
  ## the match is against the joined line text, multi-word phrases can match.
  for f in a.frames:
    if matchesSub(f.text, needle, caseInsensitive):
      return true
  return false

proc locateText*(a: VideoAnalysis, needle: string,
                 caseInsensitive = true):
                 seq[tuple[frame: int, word: OcrWord]] =
  ## Return every occurrence of `needle` across the timeline as
  ## `(frame index, matching OcrWord)` pairs. The match is *word-level*: the
  ## needle must be a substring of an individual `OcrWord.text` (a multi-word
  ## needle only matches if a single OCR word contains it). Case-insensitive by
  ## default. Returns an empty seq when nothing matches.
  result = @[]
  for f in a.frames:
    for w in f.words:
      if matchesSub(w.text, needle, caseInsensitive):
        result.add((frame: f.index, word: w))

proc seenUrl*(a: VideoAnalysis, substr: string): bool =
  ## True if any frame's extracted `urls` contains an entry that has `substr`
  ## as a substring (case-sensitive, since URLs are compared verbatim). An
  ## empty `substr` never matches.
  if substr.len == 0:
    return false
  for f in a.frames:
    for u in f.urls:
      if u.contains(substr):
        return true
  return false

proc distinctStateCount*(a: VideoAnalysis): int =
  ## Number of detected distinct visual states (frames) in the timeline.
  a.frames.len

proc textInRegion*(a: VideoAnalysis, frame: int, x, y, w, h: int,
                   needle: string, caseInsensitive = true): bool =
  ## True if, in frame `frame`, some OCR word whose bounding box *intersects*
  ## the rectangle `(x, y, w, h)` has text containing `needle` (word-level,
  ## case-insensitive by default). Rectangles are `[x, y, w, h]` (top-left
  ## origin, width/height); intersection is the standard axis-aligned overlap
  ## test. An out-of-range `frame` index yields false.
  if frame < 0 or frame >= a.frames.len:
    return false
  for word in a.frames[frame].words:
    let wx = word.bbox[0]
    let wy = word.bbox[1]
    let ww = word.bbox[2]
    let wh = word.bbox[3]
    # Standard half-open axis-aligned rectangle intersection.
    let overlaps =
      wx < x + w and x < wx + ww and
      wy < y + h and y < wy + wh
    if overlaps and matchesSub(word.text, needle, caseInsensitive):
      return true
  return false

# ---------------------------------------------------------------------------
# Pure pHash dedup (VU8)
# ---------------------------------------------------------------------------
#
# After per-state keyframes are chosen, consecutive states whose keyframes are
# perceptual near-duplicates (small pHash Hamming distance) add no information
# and only bloat the index / OCR. `dedupeConsecutive` collapses such runs,
# extending the kept state's `tEnd` to cover the dropped one and re-indexing.
# It is pure: the caller supplies the pre-computed per-frame hashes (in the same
# order as `a.frames`), so the merge logic is unit-testable without decoding any
# image. `hammingDistance`/`dctHash` live in `image_math`.

proc dedupeConsecutive*(a: VideoAnalysis, hashes: seq[uint64],
                        maxDist = 6): VideoAnalysis =
  ## Collapse consecutive frames whose keyframe pHash Hamming distance is
  ## `<= maxDist` into the earlier frame (keeping its OCR / text as the
  ## representative and extending its `tEnd`). Distinct states — a Hamming
  ## distance above `maxDist` — are preserved. Frames are re-indexed `0..n-1`.
  ## `hashes[i]` must be the pHash of `a.frames[i]`.
  result.info = a.info
  result.frames = @[]
  if a.frames.len == 0:
    return
  doAssert hashes.len == a.frames.len,
    "dedupeConsecutive: hashes/frames length mismatch"
  var keptHashes: seq[uint64] = @[]
  for i in 0 ..< a.frames.len:
    if result.frames.len > 0 and
       hammingDistance(keptHashes[^1], hashes[i]) <= maxDist:
      # Near-duplicate of the previously kept state: extend its time range.
      result.frames[^1].tEnd = a.frames[i].tEnd
    else:
      result.frames.add(a.frames[i])
      keptHashes.add(hashes[i])
  for i in 0 ..< result.frames.len:
    result.frames[i].index = i

# ---------------------------------------------------------------------------
# Pure token-efficient agent index (VU5)
# ---------------------------------------------------------------------------
#
# The "video → document + retrieval" pattern (DrVideo/VideoAgent): rather than
# feeding many frames to an agent, we emit a compact hierarchical *index* the
# agent explores as text, pulling only 1–3 frames on demand. `buildIndex` emits
# three levels — a summary, a per-state segment timeline (each carrying a
# `textDiffVsPrev`), and a flat searchable text index (one row per OCR word) —
# and `findInIndex` "greps the video" over that flat index. All pure: no
# subprocess, no filesystem.

const
  diffAddPrefix = "+ "
  diffDelPrefix = "− "   # U+2212 MINUS SIGN + space
  diffMaxLines = 40           # cap the diff so a wholesale rewrite stays compact
  diffMaxLineLen = 160        # trim individual very long lines

proc nonEmptyStrippedLines(text: string): seq[string] =
  ## Split into lines, strip each, drop empties. Order preserved.
  result = @[]
  for l in text.splitLines:
    let s = l.strip()
    if s.len > 0:
      result.add(s)

proc firstNonEmptyLine(text: string): string =
  ## The first non-blank, stripped line of `text` (the "title" of a state), or
  ## the empty string when there is none.
  for l in text.splitLines:
    let s = l.strip()
    if s.len > 0:
      return s
  return ""

proc clampDiffLine(s: string): string =
  if s.len > diffMaxLineLen: s[0 ..< diffMaxLineLen] & "…" else: s

proc textDiff*(prevText, curText: string): string =
  ## Compact line-level diff of two reading-order texts. Lines present in `cur`
  ## but not `prev` are prefixed `"+ "`; lines present in `prev` but not `cur`
  ## are prefixed `"− "` (U+2212). Added lines are listed before removed lines,
  ## each group in its source order and de-duplicated. Comparison is on stripped
  ## lines, so leading/trailing whitespace differences are ignored. Returns the
  ## empty string when the two texts have identical (stripped) line sets. Very
  ## long lines are trimmed and the total is capped for token-efficiency.
  let prevLines = nonEmptyStrippedLines(prevText)
  let curLines = nonEmptyStrippedLines(curText)
  var prevSet = initHashSet[string]()
  for s in prevLines: prevSet.incl(s)
  var curSet = initHashSet[string]()
  for s in curLines: curSet.incl(s)

  var outLines: seq[string] = @[]
  var emitted = initHashSet[string]()   # de-dup within each group
  var count = 0

  emitted.clear()
  for s in curLines:
    if count >= diffMaxLines: break
    if s notin prevSet and s notin emitted:
      emitted.incl(s)
      outLines.add(diffAddPrefix & clampDiffLine(s))
      inc count

  emitted.clear()
  for s in prevLines:
    if count >= diffMaxLines: break
    if s notin curSet and s notin emitted:
      emitted.incl(s)
      outLines.add(diffDelPrefix & clampDiffLine(s))
      inc count

  result = outLines.join("\n")

proc bboxJson(b: array[4, int]): JsonNode =
  ## `[x, y, w, h]` as a JSON array.
  %*[b[0], b[1], b[2], b[3]]

proc buildIndex*(a: VideoAnalysis): JsonNode =
  ## Build the 3-level token-efficient agent index as a `JsonNode`:
  ##
  ## 1. `"summary"` — {video, durationS, width, height, frameCount, stateCount,
  ##    windowTitles (distinct first-line/window titles seen), urls (distinct
  ##    across all frames)}. Answers "what is this recording?" with no images.
  ## 2. `"segments"` — one row per detected state: {id, start, end, changeScore,
  ##    thumbnail (the keyframe imagePath), text, urls, textDiffVsPrev}. The
  ##    diff vs the previous state is the highest-signal / lowest-token account
  ##    of *what changed*.
  ## 3. `"textIndex"` — a flat array, one entry per OCR word across every frame:
  ##    {text, confidence, bbox, segmentId, timestamp}. `timestamp` is the
  ##    entry's segment `start`. This is what `findInIndex` greps.
  var windowTitles: seq[string] = @[]
  var wtSeen = initHashSet[string]()
  var urls: seq[string] = @[]
  var urlSeen = initHashSet[string]()
  for f in a.frames:
    let title = firstNonEmptyLine(f.text)
    if title.len > 0 and title notin wtSeen:
      wtSeen.incl(title)
      windowTitles.add(title)
    for u in f.urls:
      if u notin urlSeen:
        urlSeen.incl(u)
        urls.add(u)

  result = newJObject()
  result["summary"] = %*{
    "video": a.info.path,
    "durationS": a.info.durationS,
    "width": a.info.width,
    "height": a.info.height,
    "frameCount": a.frames.len,
    "stateCount": a.frames.len,
    "windowTitles": windowTitles,
    "urls": urls
  }

  let segments = newJArray()
  var prevText = ""
  for f in a.frames:
    segments.add(%*{
      "id": f.index,
      "start": f.tStart,
      "end": f.tEnd,
      "changeScore": f.changeScore,
      "thumbnail": f.imagePath,
      "text": f.text,
      "urls": f.urls,
      "textDiffVsPrev": textDiff(prevText, f.text)
    })
    prevText = f.text
  result["segments"] = segments

  let textIndex = newJArray()
  for f in a.frames:
    for w in f.words:
      textIndex.add(%*{
        "text": w.text,
        "confidence": w.confidence,
        "bbox": bboxJson(w.bbox),
        "segmentId": f.index,
        "timestamp": f.tStart
      })
  result["textIndex"] = textIndex

proc findInIndex*(index: JsonNode, query: string, regex = false): seq[JsonNode] =
  ## "Grep the video": search the `"textIndex"` level of an index built by
  ## `buildIndex`. When `regex` is false the match is a case-insensitive
  ## substring test on each entry's `text`; when true, `query` is compiled as a
  ## regular expression and matched anywhere in `text`. Returns one JSON object
  ## per matching entry carrying {text, timestamp, segmentId, bbox, confidence}.
  ## Returns an empty seq when nothing matches (or there is no text index).
  result = @[]
  if index.isNil or not index.hasKey("textIndex") or
     index["textIndex"].kind != JArray:
    return
  var rx: Regex
  let q = query.toLowerAscii
  if regex:
    rx = re(query)
  for e in index["textIndex"]:
    if not e.hasKey("text"): continue
    let text = e["text"].getStr
    let matched =
      if regex: text.contains(rx)
      else: text.toLowerAscii.contains(q)
    if matched:
      result.add(%*{
        "text": text,
        "timestamp": e["timestamp"],
        "segmentId": e["segmentId"],
        "bbox": e["bbox"],
        "confidence": e["confidence"]
      })

# ---------------------------------------------------------------------------
# Binary discovery (honors FFMPEG / FFPROBE, then FFMPEG_BIN / PATH)
# ---------------------------------------------------------------------------

proc sanitizedEnv(binPath: string): StringTableRef =
  ## Mirror image_math/media: on nix-store binaries drop DYLD_* so the dynamic
  ## linker does not splice in incompatible Homebrew libs.
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if (k == "DYLD_LIBRARY_PATH" or k == "DYLD_FALLBACK_LIBRARY_PATH") and
       binPath.startsWith("/nix/"):
      continue
    result[k] = v

proc resolveFfmpeg(): string =
  ## Locate ffmpeg. Honors `FFMPEG`, then delegates to
  ## `media.resolveFfmpegBinary` (which honors `FFMPEG_BIN`, then `$PATH`).
  let envBin = getEnv("FFMPEG")
  if envBin.len > 0:
    if not fileExists(envBin):
      raise newException(VideoAnalysisError,
        "FFMPEG points at " & envBin & " but no file exists there.")
    return envBin
  try:
    return resolveFfmpegBinary()
  except MediaCompositionError as e:
    raise newException(VideoAnalysisError, e.msg)

proc resolveFfprobe(ffmpegPath: string): string =
  ## Locate ffprobe. Honors `FFPROBE`, else derives it from the resolved
  ## ffmpeg path (replacing a trailing `ffmpeg` with `ffprobe`), else falls
  ## back to `$PATH`.
  let envBin = getEnv("FFPROBE")
  if envBin.len > 0:
    if not fileExists(envBin):
      raise newException(VideoAnalysisError,
        "FFPROBE points at " & envBin & " but no file exists there.")
    return envBin
  if ffmpegPath.endsWith("ffmpeg"):
    let candidate = ffmpegPath[0 ..< ^len("ffmpeg")] & "ffprobe"
    if fileExists(candidate):
      return candidate
  let p = findExe("ffprobe")
  if p.len == 0:
    raise newException(VideoAnalysisError,
      "ffprobe not found alongside ffmpeg at " & ffmpegPath &
      " and none on PATH (set FFPROBE).")
  return p

# ---------------------------------------------------------------------------
# Effectful procs
# ---------------------------------------------------------------------------

proc probeVideo*(path: string): VideoInfo =
  ## Run ffprobe on `path` and parse the result into a `VideoInfo`.
  if not fileExists(path):
    raise newException(VideoAnalysisError, "Video not found: " & path)
  let ffprobeBin = resolveFfprobe(resolveFfmpeg())
  let env = sanitizedEnv(ffprobeBin)
  let p = startProcess(
    command = ffprobeBin,
    args = buildProbeArgv(path),
    env = env,
    options = {poStdErrToStdOut}
  )
  let output = p.outputStream().readAll()
  let code = p.waitForExit()
  p.close()
  if code != 0:
    raise newException(VideoAnalysisError,
      "ffprobe failed (" & $code & ") on " & path & ": " & output)
  result = parseProbeJson(output)
  result.path = path

proc segmentByChange*(path: string, sampleFps = 2.0, scaleW = 320,
                      ssimThreshold = 0.12, useLocal = true,
                      gridX = 4, gridY = 4, localThreshold = 0.35):
                      seq[tuple[tStart, tEnd, changeScore: float]] =
  ## Sample `path` at `sampleFps` fps (downscaled to width `scaleW`), score
  ## consecutive frames, and collapse visually similar runs into segments.
  ## Returns one entry per detected distinct state.
  ##
  ## VU8: by DEFAULT (`useLocal = true`) the detector scores each consecutive
  ## pair by `tiledSsim(prev, cur, gridX, gridY).minLocal` — the SSIM of the
  ## MOST-changed cell of a `gridX` x `gridY` grid — and starts a new segment
  ## when `1 - minLocal > localThreshold`. This catches small, localised UI
  ## changes (a dialog, an address-bar edit) that a whole-frame SSIM, dominated
  ## by the unchanged background, would smear below the threshold. Set
  ## `useLocal = false` to fall back to the legacy global-SSIM path
  ## (`1 - computeSsim > ssimThreshold`) unchanged.
  ##
  ## Defaults: `sampleFps = 2.0` gives enough temporal resolution to place a
  ## boundary within ~0.5s while keeping the work small; `scaleW = 320`
  ## downscales heavily so per-cell SSIM is fast yet still discriminates a
  ## state change; `ssimThreshold = 0.12` is the legacy global cutoff;
  ## `gridX = gridY = 4` gives 16 cells (each cell is a meaningful UI region at
  ## `scaleW = 320`) and `localThreshold = 0.35` (the most-changed cell must
  ## drop by >35%) sits well above per-cell compression jitter between visually
  ## identical frames yet far below the near-total local drop a real change
  ## produces. Both paths keep the 2-state e2e fixture at exactly 2 states.
  if not fileExists(path):
    raise newException(VideoAnalysisError, "Video not found: " & path)

  let ffmpegBin = resolveFfmpeg()
  let tmpDir = createTempDir("gui_assert_seg_", "")
  try:
    let outPattern = tmpDir / "f_%05d.png"
    let argv = buildSampleFramesArgv(path, sampleFps, scaleW, outPattern)
    let env = sanitizedEnv(ffmpegBin)
    let p = startProcess(
      command = ffmpegBin,
      args = argv,
      env = env,
      options = {poStdErrToStdOut}
    )
    let output = p.outputStream().readAll()
    let code = p.waitForExit()
    p.close()
    if code != 0:
      raise newException(VideoAnalysisError,
        "ffmpeg frame sampling failed (" & $code & ") on " & path & ": " &
        output)

    var frameFiles: seq[string] = @[]
    for f in walkFiles(tmpDir / "f_*.png"):
      frameFiles.add(f)
    sort(frameFiles)

    if frameFiles.len == 0:
      raise newException(VideoAnalysisError,
        "ffmpeg produced no frames sampling " & path)

    if frameFiles.len == 1:
      # A single sampled frame is one segment spanning one sample interval.
      return @[(0.0, 1.0 / sampleFps, 1.0)]

    # Decode consecutive pairs and score them. In the default local mode the
    # series is each pair's tiled `minLocal` (most-changed cell); otherwise it
    # is the legacy whole-frame SSIM. Either way `segmentBoundaries` triggers a
    # new segment when `1 - series[i] > threshold`.
    var series: seq[float] = @[]
    var prev = decodeGray(frameFiles[0])
    for i in 1 ..< frameFiles.len:
      let cur = decodeGray(frameFiles[i])
      if useLocal:
        series.add(tiledSsim(prev, cur, gridX, gridY).minLocal)
      else:
        series.add(computeSsim(prev, cur))
      prev = cur

    let numFrames = frameFiles.len
    let threshold = if useLocal: localThreshold else: ssimThreshold
    let boundaries = segmentBoundaries(series, threshold)

    result = @[]
    for si in 0 ..< boundaries.len:
      let b = boundaries[si]
      let nb = if si + 1 < boundaries.len: boundaries[si + 1] else: numFrames
      let tStart = float(b) / sampleFps
      let tEnd = float(nb) / sampleFps
      let score = if b == 0: 1.0 else: 1.0 - series[b - 1]
      result.add((tStart, tEnd, score))
  finally:
    try:
      removeDir(tmpDir)
    except OSError:
      discard

proc extractKeyframe(ffmpegBin, path: string, t: float, outPng: string) =
  ## Run ffmpeg to write one full-resolution PNG at timestamp `t`.
  let argv = buildExtractFrameArgv(path, t, outPng)
  let env = sanitizedEnv(ffmpegBin)
  let p = startProcess(
    command = ffmpegBin,
    args = argv,
    env = env,
    options = {poStdErrToStdOut}
  )
  let output = p.outputStream().readAll()
  let code = p.waitForExit()
  p.close()
  if code != 0:
    raise newException(VideoAnalysisError,
      "ffmpeg keyframe extraction failed (" & $code & ") at t=" &
      formatFloat(t, ffDecimal, precision = 3) & " on " & path & ": " & output)
  if not (fileExists(outPng) and getFileSize(outPng) > 0):
    raise newException(VideoAnalysisError,
      "ffmpeg produced no keyframe at t=" &
      formatFloat(t, ffDecimal, precision = 3) & " on " & path)

proc analyzeVideo*(path: string, sampleFps = 2.0, scaleW = 320,
                   ssimThreshold = 0.12,
                   ocrPsms: seq[int] = @[6, 11],
                   ocrOpts = initOcrOptions(upscale = 2.0,
                                            invert = oiAuto),
                   phashDupThreshold = 6): VideoAnalysis =
  ## Full VU2 pipeline: probe `path`, segment it into distinct visual states
  ## (`segmentByChange`), then for each state extract ONE full-resolution
  ## keyframe at the state's temporal midpoint, OCR it, and assemble the
  ## timeline. Each `Keyframe` gets `words` (raw OCR), `text`
  ## (`wordsToReadingOrderText`) and `urls` (`extractUrls` over that text).
  ##
  ## VU9: the keyframe OCR now runs via `runOcrMultiPsm(ocrPsms, ocrOpts)` —
  ## by default a block (`--psm 6`) AND sparse (`--psm 11`) pass over a 2x
  ## Lanczos-upscaled, auto-inverted (dark-mode aware) keyframe, so small
  ## and/or light-on-dark window headings that a single block pass drops are
  ## surfaced into the index/digest. Word bboxes stay in original pixel space.
  ##
  ## Keyframe PNGs are written into a fresh temp directory that is *not*
  ## removed; the caller can read/relocate them via each frame's `imagePath`.
  ## Honors FFMPEG / FFPROBE / FFMPEG_BIN and TESSERACT_BIN like the rest of
  ## the module (the OCR pass resolves tesseract via `ocr.runOcr`).
  result.info = probeVideo(path)

  let segments = segmentByChange(path, sampleFps, scaleW, ssimThreshold)
  let ffmpegBin = resolveFfmpeg()

  # Persistent keyframe dir (deliberately not cleaned up): the returned
  # `imagePath`s point here so callers can use the extracted PNGs.
  let kfDir = createTempDir("gui_assert_kf_", "")

  # Extract one keyframe per segment and hash it (VU8 pHash), building the
  # timeline skeleton WITHOUT OCR yet.
  var prelim: VideoAnalysis
  prelim.info = result.info
  prelim.frames = @[]
  var hashes: seq[uint64] = @[]
  for i, seg in segments:
    let mid = (seg.tStart + seg.tEnd) / 2.0
    let outPng = kfDir / ("state_" & align($i, 5, '0') & ".png")
    extractKeyframe(ffmpegBin, path, mid, outPng)

    var kf: Keyframe
    kf.index = i
    kf.tStart = seg.tStart
    kf.tEnd = seg.tEnd
    kf.changeScore = seg.changeScore
    kf.imagePath = outPng
    prelim.frames.add(kf)
    hashes.add(dctHash(decodeGray(outPng)))

  # VU8: collapse consecutive near-duplicate states (pHash Hamming distance
  # <= phashDupThreshold) BEFORE OCR so redundant frames don't bloat the OCR
  # pass or the resulting index. `phashDupThreshold < 0` disables the pass.
  let deduped =
    if phashDupThreshold >= 0 and prelim.frames.len > 1:
      dedupeConsecutive(prelim, hashes, phashDupThreshold)
    else:
      prelim

  # OCR the surviving keyframes.
  result.frames = @[]
  for kf in deduped.frames:
    var f = kf
    f.words = runOcrMultiPsm(f.imagePath, ocrPsms, ocrOpts)
    f.text = wordsToReadingOrderText(f.words)
    f.urls = extractUrls(f.text)
    result.frames.add(f)

# ---------------------------------------------------------------------------
# Effectful frame emission for the CLI (VU5)
# ---------------------------------------------------------------------------

proc extractFrameTo*(path: string, t: float, outPng: string) =
  ## Emit exactly ONE full-resolution PNG at timestamp `t` from `path` to
  ## `outPng`, using the pure `buildExtractFrameArgv` and the resolved ffmpeg
  ## binary. Raises `VideoAnalysisError` on failure or if no PNG is produced.
  if not fileExists(path):
    raise newException(VideoAnalysisError, "Video not found: " & path)
  extractKeyframe(resolveFfmpeg(), path, t, outPng)

proc buildContactSheetArgv*(inPattern: string, cols, rows: int,
                            outPng: string): seq[string] =
  ## ffmpeg argv (no leading binary token) that tiles the image sequence
  ## `inPattern` (e.g. `dir/%05d.png`, numbered from 1) into a single
  ## `cols` x `rows` grid PNG at `outPng`.
  @[
    "-hide_banner",
    "-loglevel", "error",
    "-y",
    "-start_number", "1",
    "-i", inPattern,
    "-vf", "tile=" & $cols & "x" & $rows,
    "-frames:v", "1",
    outPng
  ]

proc contactSheet*(path: string, outPng: string, cols = 0) =
  ## Analyze `path`, then tile its per-state keyframes into one contact-sheet
  ## PNG at `outPng`. `cols` selects the grid width (default: up to 4). The
  ## keyframes are copied into a fresh temp dir as a numbered sequence and tiled
  ## with ffmpeg's `tile` filter. Raises `VideoAnalysisError` on failure.
  let a = analyzeVideo(path)
  let n = a.frames.len
  if n == 0:
    raise newException(VideoAnalysisError,
      "No keyframes to tile for " & path)
  let ncols = if cols > 0: cols else: min(n, 4)
  let nrows = (n + ncols - 1) div ncols

  let ffmpegBin = resolveFfmpeg()
  let tmpDir = createTempDir("gui_assert_cs_", "")
  try:
    for i, f in a.frames:
      copyFile(f.imagePath, tmpDir / (align($(i + 1), 5, '0') & ".png"))
    let argv = buildContactSheetArgv(tmpDir / "%05d.png", ncols, nrows, outPng)
    let env = sanitizedEnv(ffmpegBin)
    let p = startProcess(
      command = ffmpegBin,
      args = argv,
      env = env,
      options = {poStdErrToStdOut}
    )
    let output = p.outputStream().readAll()
    let code = p.waitForExit()
    p.close()
    if code != 0:
      raise newException(VideoAnalysisError,
        "ffmpeg contact-sheet tiling failed (" & $code & "): " & output)
    if not (fileExists(outPng) and getFileSize(outPng) > 0):
      raise newException(VideoAnalysisError,
        "ffmpeg produced no contact sheet at " & outPng)
  finally:
    try:
      removeDir(tmpDir)
    except OSError:
      discard
