## Artifact Project — sibling-folder layout for the multi-stage render
## pipeline produced by the timeline editor.
##
## Given a script at `<dir>/<stem>.yaml`, the artifacts live at
## `<dir>/<stem>.artifacts/` with one canonical file per stage:
##
##   manifest.json
##   automation.mkv            FFV1 lossless screencast (re-recorded
##                             whenever the timeline's actions change)
##   local-audio.wav           local TTS (espeak / `say`)
##   local-head.mp4            local talking-head model output
##                             (SadTalker / Wav2Lip / MuseTalk)
##   commercial-audio.mp3      commercial TTS (ElevenLabs, etc.)
##   commercial-head.mp4       commercial talking-head provider output
##                             (HeyGen / Synthesia / Tavus / D-ID)
##   final.mp4                 the optimised, h.264-compressed
##                             publication video
##
## Every stage records the input *hash* that produced it inside the
## manifest, so the editor can flag stages as `fresh` / `stale` /
## `missing` without re-running the renderer.

import std/[hashes, json, options, os, strformat, strutils, times]

import ./parser
import ./avatar_track

type
  RenderStage* = enum
    rsAutomation       = "automation"
    rsLocalAudio       = "local-audio"
    rsLocalHead        = "local-head"
    rsCommercialAudio  = "commercial-audio"
    rsCommercialHead   = "commercial-head"
    rsFinal            = "final"

  StageStatus* = enum
    ssMissing = "missing"
      ## no file at the expected path
    ssFresh   = "fresh"
      ## file exists and the input hash matches the manifest
    ssStale   = "stale"
      ## file exists but its inputs have changed since the last render

  AudioMode* = enum
    amAudio = "audio"
      ## render plain narration audio (no talking head video)
    amHead  = "head"
      ## render a full talking-head video (audio + face)

  RenderOptions* = object
    captions*: bool
      ## When true, the final compose overlays drawtext captions.
    audioMode*: AudioMode
      ## audio-only vs talking-head as the narration carrier.
    localHeadModel*: string
      ## Plugin id of the chosen local talking-head model
      ## ("sadtalker" | "wav2lip" | "musetalk").
    commercialProvider*: string
      ## Plugin id of the chosen commercial provider
      ## ("heygen" | "synthesia" | "tavus" | "did" | "elevenlabs").

  StageRecord* = object
    stage*: RenderStage
    path*: string         ## absolute path of the rendered artifact
    inputHash*: string    ## hash of the inputs that produced it
    size*: int64          ## file size in bytes (0 if missing)
    mtime*: float         ## seconds since epoch (0 if missing)

  ProjectManifest* = object
    schema*: int
    options*: RenderOptions
    stages*: seq[StageRecord]

const
  ManifestSchemaVersion* = 1
  ArtifactSuffix*        = ".artifacts"
  ManifestFilename*      = "manifest.json"

proc defaultRenderOptions*(): RenderOptions =
  RenderOptions(
    captions: true,
    audioMode: amHead,
    localHeadModel: "sadtalker",
    commercialProvider: "heygen",
  )

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

proc projectDir*(scriptPath: string): string =
  ## Sibling artifact directory for `scriptPath`.  If the script has
  ## no parent directory (anonymous in-memory scripts) we use the
  ## working directory.
  let (parent, stem, _) = scriptPath.splitFile()
  let dir = if parent.len > 0: parent else: getCurrentDir()
  dir / (stem & ArtifactSuffix)

proc stageFilename*(stage: RenderStage): string =
  case stage
  of rsAutomation:      "automation.mkv"
  of rsLocalAudio:      "local-audio.wav"
  of rsLocalHead:       "local-head.mp4"
  of rsCommercialAudio: "commercial-audio.mp3"
  of rsCommercialHead:  "commercial-head.mp4"
  of rsFinal:           "final.mp4"

proc stagePath*(scriptPath: string, stage: RenderStage): string =
  projectDir(scriptPath) / stageFilename(stage)

proc manifestPath*(scriptPath: string): string =
  projectDir(scriptPath) / ManifestFilename

proc ensureProjectDir*(scriptPath: string) =
  let dir = projectDir(scriptPath)
  if not dirExists(dir):
    createDir(dir)

# ---------------------------------------------------------------------------
# Hashing — what each stage's *inputs* are
# ---------------------------------------------------------------------------
#
# A stage's `inputHash` is a stable hash of the subset of the Script
# that the renderer reads.  If the user changes a different part of the
# script (e.g. avatar geometry, but the narration text is unchanged),
# the audio stages stay `fresh`.

proc hashStable(s: string): string =
  ## Stable Hash -> hex string, identical across runs.  We use Nim's
  ## `hashes.hash` (FNV) and serialise the resulting `Hash` (int).
  let h = hash(s)
  ($(!$h)).replace("-", "n")

proc narrationSig(script: Script): string =
  ## Stable concatenation of every keyframe's `(time, narration)`.
  var parts: seq[string] = @[]
  for kf in script.timeline:
    let text = if kf.narration.isSome: kf.narration.get else: ""
    parts.add($kf.time & ":" & text)
  parts.join("|")

proc timelineSig(script: Script): string =
  ## Stable signature of the *automation* — anything the runner replays.
  var parts: seq[string] = @[]
  for kf in script.timeline:
    parts.add($kf.time & ":" & kf.action & ":" & $kf.params & ":" & kf.targetWindow)
  parts.join("|")

proc avatarSig(script: Script): string =
  ## Stable signature of the avatar overlay geometry.
  if script.avatar.isEmpty: return ""
  let j = avatarTrackToJson(script.avatar)
  $j

proc inputHashFor*(stage: RenderStage; script: Script;
                   options: RenderOptions): string =
  ## Build the stable input hash for `stage`.  Different stages depend
  ## on different parts of the script; e.g. `local-audio` does not
  ## depend on avatar geometry.
  case stage
  of rsAutomation:
    hashStable("auto:" & timelineSig(script))
  of rsLocalAudio:
    hashStable("la:" & narrationSig(script))
  of rsLocalHead:
    hashStable("lh:" & narrationSig(script) & "|" & options.localHeadModel)
  of rsCommercialAudio:
    hashStable("ca:" & narrationSig(script) & "|" & options.commercialProvider)
  of rsCommercialHead:
    hashStable("ch:" & narrationSig(script) & "|" & options.commercialProvider)
  of rsFinal:
    hashStable("final:" &
      timelineSig(script) & "|" &
      narrationSig(script) & "|" &
      avatarSig(script) & "|" &
      $options.captions & "|" &
      $options.audioMode & "|" &
      options.localHeadModel & "|" &
      options.commercialProvider)

# ---------------------------------------------------------------------------
# Manifest I/O
# ---------------------------------------------------------------------------

proc emptyManifest*(): ProjectManifest =
  ProjectManifest(
    schema: ManifestSchemaVersion,
    options: defaultRenderOptions(),
    stages: @[],
  )

proc stageRecord(scriptPath: string, stage: RenderStage,
                 inputHash: string): StageRecord =
  let path = stagePath(scriptPath, stage)
  var size: int64 = 0
  var mtime: float = 0.0
  if fileExists(path):
    size = getFileSize(path).int64
    mtime = toUnixFloat(getLastModificationTime(path))
  StageRecord(stage: stage, path: path, inputHash: inputHash,
              size: size, mtime: mtime)

proc loadManifest*(scriptPath: string): ProjectManifest =
  let p = manifestPath(scriptPath)
  if not fileExists(p):
    return emptyManifest()
  try:
    let root = parseJson(readFile(p))
    if root.kind != JObject:
      return emptyManifest()
    result.schema = if root.hasKey("schema"):
                      root["schema"].getInt
                    else: ManifestSchemaVersion
    if root.hasKey("options"):
      let o = root["options"]
      if o.kind == JObject:
        result.options = defaultRenderOptions()
        if o.hasKey("captions") and o["captions"].kind == JBool:
          result.options.captions = o["captions"].getBool
        if o.hasKey("audio_mode") and o["audio_mode"].kind == JString:
          result.options.audioMode =
            if o["audio_mode"].getStr == "audio": amAudio else: amHead
        if o.hasKey("local_head_model") and o["local_head_model"].kind == JString:
          result.options.localHeadModel = o["local_head_model"].getStr
        if o.hasKey("commercial_provider") and o["commercial_provider"].kind == JString:
          result.options.commercialProvider = o["commercial_provider"].getStr
    else:
      result.options = defaultRenderOptions()
    if root.hasKey("stages") and root["stages"].kind == JArray:
      for s in root["stages"].elems:
        if s.kind != JObject: continue
        var rec = StageRecord()
        if s.hasKey("stage") and s["stage"].kind == JString:
          let name = s["stage"].getStr
          for st in RenderStage:
            if $st == name: rec.stage = st
        rec.path = if s.hasKey("path"): s["path"].getStr else: ""
        rec.inputHash = if s.hasKey("input_hash"): s["input_hash"].getStr else: ""
        rec.size = if s.hasKey("size"):
                     case s["size"].kind
                     of JInt: s["size"].getInt.int64
                     else: 0
                   else: 0
        rec.mtime = if s.hasKey("mtime"):
                      case s["mtime"].kind
                      of JFloat: s["mtime"].getFloat
                      of JInt: float(s["mtime"].getInt)
                      else: 0.0
                    else: 0.0
        result.stages.add rec
  except CatchableError:
    return emptyManifest()

proc saveManifest*(scriptPath: string, manifest: ProjectManifest) =
  ensureProjectDir(scriptPath)
  let p = manifestPath(scriptPath)
  let obj = newJObject()
  obj["schema"] = %manifest.schema
  let opt = newJObject()
  opt["captions"] = %manifest.options.captions
  opt["audio_mode"] = %($manifest.options.audioMode)
  opt["local_head_model"] = %manifest.options.localHeadModel
  opt["commercial_provider"] = %manifest.options.commercialProvider
  obj["options"] = opt
  let stages = newJArray()
  for s in manifest.stages:
    let sObj = newJObject()
    sObj["stage"] = %($s.stage)
    sObj["path"] = %s.path
    sObj["input_hash"] = %s.inputHash
    sObj["size"] = %s.size
    sObj["mtime"] = %s.mtime
    stages.add sObj
  obj["stages"] = stages
  writeFile(p, $obj)

proc updateStage*(manifest: var ProjectManifest;
                  scriptPath: string;
                  stage: RenderStage;
                  inputHash: string) =
  ## Record (or refresh) the stage row in the manifest with the latest
  ## file stats from disk.
  let rec = stageRecord(scriptPath, stage, inputHash)
  for i in 0 ..< manifest.stages.len:
    if manifest.stages[i].stage == stage:
      manifest.stages[i] = rec
      return
  manifest.stages.add rec

# ---------------------------------------------------------------------------
# Staleness
# ---------------------------------------------------------------------------

proc stageStatus*(manifest: ProjectManifest;
                  scriptPath: string;
                  stage: RenderStage;
                  expectedHash: string): StageStatus =
  ## Compare the expected hash to the manifest's stored hash and to
  ## the file on disk.  `missing` short-circuits everything else.
  let path = stagePath(scriptPath, stage)
  if not fileExists(path): return ssMissing
  if getFileSize(path) <= 0: return ssMissing
  for s in manifest.stages:
    if s.stage == stage:
      if s.inputHash == expectedHash: return ssFresh
      else: return ssStale
  return ssStale
