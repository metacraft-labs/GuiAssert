## gui-assert-vision — token-efficient video understanding CLI (VU5)
##
## Two modes, mirroring the DrVideo/VideoAgent "video → document + retrieval"
## pattern: *explore* the recording as a compact text index, then *grep* it and
## pull only the 1–3 frames you actually need.
##
##   analyze <video> [--out DIR]
##       Run the full analysis pipeline, then write DIR/index.json (the 3-level
##       token-efficient index) and DIR/digest.md (human/agent-readable
##       timeline). The per-state keyframe PNGs already live on disk; their
##       paths are printed and referenced from the index (`thumbnail`).
##
##   find <query> <video-or-index.json> [--regex]
##       Grep the video. If given an index.json it is loaded directly; otherwise
##       the video is analyzed first. Prints one JSON line per match
##       ({timestamp, segmentId, bbox, confidence, text}).
##
##   extract-frame <video> (--at SECONDS | --segment ID) [--out PNG]
##       Emit ONLY the one requested frame (by timestamp, or the midpoint of a
##       segment). Prints the PNG path.
##
##   contact-sheet <video> [--out PNG] [--cols N]
##       Tile the per-state keyframes into one grid image. Prints the PNG path.
##
##   describe <image> / windows <image>
##       Detect top-level windows purely from pixels (no OS window API) and
##       print them as JSON (count + per-window bbox/text/titleText/confidence).
##
##   --help
##
## The argv parser (`parseVisionArgs`) is a pure function returning a
## `VisionCommand`, so it is unit-testable without any subprocess; `main`
## dispatches it to the effectful pipeline.

import std/[json, os, strutils]

import ./gui_assert/video_analysis
import ./gui_assert/vision_windows

type
  VisionArgError* = object of CatchableError
    ## Raised by `parseVisionArgs` on an unknown/missing subcommand, an unknown
    ## flag, a flag missing its value, or missing/duplicate positional args.

  VisionCmdKind* = enum
    vcHelp, vcAnalyze, vcFind, vcExtractFrame, vcContactSheet,
    vcDescribe, vcWindows

  VisionCommand* = object
    ## Parsed CLI invocation. One variant per subcommand.
    case kind*: VisionCmdKind
    of vcHelp:
      discard
    of vcAnalyze:
      anVideo*: string
      anOut*: string
    of vcFind:
      fnQuery*: string
      fnTarget*: string
      fnRegex*: bool
    of vcExtractFrame:
      exVideo*: string
      exHasAt*: bool
      exAt*: float
      exHasSeg*: bool
      exSeg*: int
      exOut*: string
    of vcContactSheet:
      csVideo*: string
      csOut*: string
      csCols*: int
    of vcDescribe, vcWindows:
      dwImage*: string

const helpText* = """gui-assert-vision — token-efficient video understanding

USAGE:
  gui-assert-vision analyze <video> [--out DIR]
  gui-assert-vision find <query> <video-or-index.json> [--regex]
  gui-assert-vision extract-frame <video> (--at SECONDS | --segment ID) [--out PNG]
  gui-assert-vision contact-sheet <video> [--out PNG] [--cols N]
  gui-assert-vision describe <image>
  gui-assert-vision windows <image>
  gui-assert-vision --help
"""

# ---------------------------------------------------------------------------
# Pure argv parsing
# ---------------------------------------------------------------------------

proc splitFlag(a: string): (string, string, bool) =
  ## For `--name=value` return (name, value, true); otherwise (a, "", false).
  if a.startsWith("--") and '=' in a:
    let eq = a.find('=')
    (a[0 ..< eq], a[eq + 1 .. ^1], true)
  else:
    (a, "", false)

proc parseVisionArgs*(argv: seq[string]): VisionCommand =
  ## Parse a full argv (subcommand + args) into a `VisionCommand`. Pure: it
  ## touches no filesystem and runs no subprocess. Raises `VisionArgError` on
  ## any malformed invocation so callers/tests can assert rejection.
  if argv.len == 0:
    raise newException(VisionArgError, "no subcommand given")
  let sub = argv[0]
  let rest = argv[1 .. ^1]

  case sub
  of "--help", "-h", "help":
    return VisionCommand(kind: vcHelp)

  of "analyze":
    var video = ""
    var outDir = "vision-out"
    var i = 0
    while i < rest.len:
      let (name, inlineVal, inlined) = splitFlag(rest[i])
      if name == "--out":
        if inlined:
          outDir = inlineVal
        else:
          if i + 1 >= rest.len:
            raise newException(VisionArgError, "--out requires a value")
          outDir = rest[i + 1]; inc i
      elif rest[i].startsWith("-"):
        raise newException(VisionArgError, "unknown flag: " & rest[i])
      elif video.len == 0:
        video = rest[i]
      else:
        raise newException(VisionArgError, "unexpected argument: " & rest[i])
      inc i
    if video.len == 0:
      raise newException(VisionArgError, "analyze requires a <video>")
    return VisionCommand(kind: vcAnalyze, anVideo: video, anOut: outDir)

  of "find":
    var positionals: seq[string] = @[]
    var regex = false
    var i = 0
    while i < rest.len:
      let a = rest[i]
      if a == "--regex":
        regex = true
      elif a.startsWith("-"):
        raise newException(VisionArgError, "unknown flag: " & a)
      else:
        positionals.add(a)
      inc i
    if positionals.len < 2:
      raise newException(VisionArgError,
        "find requires <query> <video-or-index.json>")
    if positionals.len > 2:
      raise newException(VisionArgError,
        "find takes exactly <query> <video-or-index.json>")
    return VisionCommand(kind: vcFind, fnQuery: positionals[0],
                         fnTarget: positionals[1], fnRegex: regex)

  of "extract-frame":
    var video = ""
    var hasAt = false
    var at = 0.0
    var hasSeg = false
    var seg = 0
    var outPng = ""
    var i = 0
    while i < rest.len:
      let (name, inlineVal, inlined) = splitFlag(rest[i])
      proc valueFor(): string =
        if inlined: return inlineVal
        if i + 1 >= rest.len:
          raise newException(VisionArgError, name & " requires a value")
        inc i
        return rest[i]
      case name
      of "--at":
        let v = valueFor()
        try: at = parseFloat(v)
        except ValueError:
          raise newException(VisionArgError, "--at expects a number, got " & v)
        hasAt = true
      of "--segment":
        let v = valueFor()
        try: seg = parseInt(v)
        except ValueError:
          raise newException(VisionArgError,
            "--segment expects an integer, got " & v)
        hasSeg = true
      of "--out":
        outPng = valueFor()
      else:
        if rest[i].startsWith("-"):
          raise newException(VisionArgError, "unknown flag: " & rest[i])
        elif video.len == 0:
          video = rest[i]
        else:
          raise newException(VisionArgError, "unexpected argument: " & rest[i])
      inc i
    if video.len == 0:
      raise newException(VisionArgError, "extract-frame requires a <video>")
    if hasAt == hasSeg:
      raise newException(VisionArgError,
        "extract-frame requires exactly one of --at or --segment")
    return VisionCommand(kind: vcExtractFrame, exVideo: video,
                         exHasAt: hasAt, exAt: at, exHasSeg: hasSeg,
                         exSeg: seg, exOut: outPng)

  of "contact-sheet":
    var video = ""
    var outPng = ""
    var cols = 0
    var i = 0
    while i < rest.len:
      let (name, inlineVal, inlined) = splitFlag(rest[i])
      proc valueFor(): string =
        if inlined: return inlineVal
        if i + 1 >= rest.len:
          raise newException(VisionArgError, name & " requires a value")
        inc i
        return rest[i]
      case name
      of "--out":
        outPng = valueFor()
      of "--cols":
        let v = valueFor()
        try: cols = parseInt(v)
        except ValueError:
          raise newException(VisionArgError, "--cols expects an integer, got " & v)
        if cols <= 0:
          raise newException(VisionArgError, "--cols must be positive")
      else:
        if rest[i].startsWith("-"):
          raise newException(VisionArgError, "unknown flag: " & rest[i])
        elif video.len == 0:
          video = rest[i]
        else:
          raise newException(VisionArgError, "unexpected argument: " & rest[i])
      inc i
    if video.len == 0:
      raise newException(VisionArgError, "contact-sheet requires a <video>")
    return VisionCommand(kind: vcContactSheet, csVideo: video,
                         csOut: outPng, csCols: cols)

  of "describe", "windows":
    var image = ""
    var i = 0
    while i < rest.len:
      if rest[i].startsWith("-"):
        raise newException(VisionArgError, "unknown flag: " & rest[i])
      elif image.len == 0:
        image = rest[i]
      else:
        raise newException(VisionArgError, "unexpected argument: " & rest[i])
      inc i
    if image.len == 0:
      raise newException(VisionArgError, sub & " requires an <image>")
    if sub == "describe":
      return VisionCommand(kind: vcDescribe, dwImage: image)
    else:
      return VisionCommand(kind: vcWindows, dwImage: image)

  else:
    raise newException(VisionArgError, "unknown subcommand: " & sub)

# ---------------------------------------------------------------------------
# Effectful dispatch
# ---------------------------------------------------------------------------

proc runAnalyze(cmd: VisionCommand) =
  createDir(cmd.anOut)
  let analysis = analyzeVideo(cmd.anVideo)
  let index = buildIndex(analysis)
  let indexPath = cmd.anOut / "index.json"
  let digestPath = cmd.anOut / "digest.md"
  writeFile(indexPath, pretty(index))
  writeFile(digestPath, toDigest(analysis))
  echo "index:  " & indexPath
  echo "digest: " & digestPath
  echo "keyframes:"
  for f in analysis.frames:
    echo "  " & f.imagePath

proc loadIndexFor(target: string): JsonNode =
  ## If `target` is an existing *.json file, load it as an index; otherwise
  ## analyze it as a video and build the index on the fly.
  if target.toLowerAscii.endsWith(".json") and fileExists(target):
    return parseJson(readFile(target))
  return buildIndex(analyzeVideo(target))

proc runFind(cmd: VisionCommand) =
  let index = loadIndexFor(cmd.fnTarget)
  let matches = findInIndex(index, cmd.fnQuery, cmd.fnRegex)
  for m in matches:
    echo $m

proc segmentMidpoint(video: string, segId: int): float =
  ## Analyze `video` and return the temporal midpoint of segment `segId`.
  let a = analyzeVideo(video)
  for f in a.frames:
    if f.index == segId:
      return (f.tStart + f.tEnd) / 2.0
  raise newException(VideoAnalysisError,
    "no segment with id " & $segId & " in " & video)

proc runExtractFrame(cmd: VisionCommand) =
  let t = if cmd.exHasAt: cmd.exAt else: segmentMidpoint(cmd.exVideo, cmd.exSeg)
  var outPng = cmd.exOut
  if outPng.len == 0:
    let tag = formatFloat(t, ffDecimal, precision = 3)
    outPng = "frame_at_" & tag & ".png"
  extractFrameTo(cmd.exVideo, t, outPng)
  echo outPng

proc runContactSheet(cmd: VisionCommand) =
  var outPng = cmd.csOut
  if outPng.len == 0:
    outPng = "contact-sheet.png"
  contactSheet(cmd.csVideo, outPng, cmd.csCols)
  echo outPng

proc runWindows(image: string) =
  let wins = detectWindows(image)
  let arr = newJArray()
  for w in wins:
    arr.add(%*{
      "bbox": %*[w.bbox[0], w.bbox[1], w.bbox[2], w.bbox[3]],
      "titleText": w.titleText,
      "text": w.text,
      "confidence": w.confidence
    })
  echo pretty(%*{"count": wins.len, "windows": arr})

proc main(argv: seq[string]): int =
  var cmd: VisionCommand
  try:
    cmd = parseVisionArgs(argv)
  except VisionArgError as e:
    stderr.writeLine("error: " & e.msg)
    stderr.writeLine("")
    stderr.write(helpText)
    return 2

  case cmd.kind
  of vcHelp:
    stdout.write(helpText)
  of vcAnalyze:
    runAnalyze(cmd)
  of vcFind:
    runFind(cmd)
  of vcExtractFrame:
    runExtractFrame(cmd)
  of vcContactSheet:
    runContactSheet(cmd)
  of vcDescribe, vcWindows:
    runWindows(cmd.dwImage)
  return 0

when isMainModule:
  quit(main(commandLineParams()))
