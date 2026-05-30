## tartifact_project — pure-data tests for the artifact-project layer.
##
## No HTTP server, no ffmpeg, no provider APIs.  Verifies path
## resolution, manifest JSON round-trip, hash stability, and the
## staleness recomputation contract that the editor relies on.

import std/[json, options, os, strutils, tables, unittest]

import ../src/gui_assert/parser
import ../src/gui_assert/avatar_track
import ../src/gui_assert/artifact_project

# A minimal script with two narrated keyframes and a 2-keyframe
# avatar track.  All later tests are built against derivatives of
# this so changes to specific subsets are isolated.
proc baseScript(): Script =
  result.metadata.title = "T"
  result.metadata.resolution = "1280x720"
  result.metadata.fps = 30
  result.timeline = @[
    Keyframe(time: 0.0, action: "focus",
             params: %* {"window": "term"},
             narration: some("Hello there."),
             targetWindow: "term"),
    Keyframe(time: 4.0, action: "type",
             params: %* {"text": "step in"},
             narration: some("Now we step into the call."),
             targetWindow: "term"),
  ]
  var k0 = defaultAvatarKeyframe(0.0)
  k0.srcCrop = initRectF(0, 0, 600, 600)
  k0.dstRect = initRectF(900, 400, 240, 240)
  result.avatar = AvatarTrack(
    sourceVideo: "/tmp/source.mp4",
    keyframes: @[k0],
  )

# Make a fresh temporary directory; cleanup is via teardown.
proc mkTempScriptPath(name: string): string =
  let dir = getTempDir() / ("guiassert-test-" & name)
  if dirExists(dir): removeDir(dir)
  createDir(dir)
  dir / (name & ".yaml")

suite "artifact_project paths":
  test "projectDir uses sibling <stem>.artifacts":
    let p = projectDir("/some/where/foo.yaml")
    check p == "/some/where/foo.artifacts"
  test "projectDir on bare filename uses cwd":
    let p = projectDir("bare.yaml")
    check p.endsWith("/bare.artifacts")
  test "stageFilename is canonical per stage":
    check stageFilename(rsAutomation)      == "automation.mkv"
    check stageFilename(rsLocalAudio)      == "local-audio.wav"
    check stageFilename(rsLocalHead)       == "local-head.mp4"
    check stageFilename(rsCommercialAudio) == "commercial-audio.mp3"
    check stageFilename(rsCommercialHead)  == "commercial-head.mp4"
    check stageFilename(rsFinal)           == "final.mp4"
  test "stagePath stitches project dir + canonical name":
    let p = stagePath("/x/y.yaml", rsLocalAudio)
    check p == "/x/y.artifacts/local-audio.wav"

suite "artifact_project input hashes":
  test "automation hash depends on timeline action but not narration":
    let s1 = baseScript()
    var s2 = s1
    s2.timeline[1].narration = some("Totally different narration.")
    let opts = defaultRenderOptions()
    check inputHashFor(rsAutomation, s1, opts) ==
          inputHashFor(rsAutomation, s2, opts)
    # …but if the *action* changes, the automation hash must change.
    var s3 = s1
    s3.timeline[1].action = "different-action"
    check inputHashFor(rsAutomation, s1, opts) !=
          inputHashFor(rsAutomation, s3, opts)

  test "local-audio hash depends on narration text but not action":
    let s1 = baseScript()
    let opts = defaultRenderOptions()
    var s2 = s1
    s2.timeline[0].action = "totally-different"
    check inputHashFor(rsLocalAudio, s1, opts) ==
          inputHashFor(rsLocalAudio, s2, opts)
    var s3 = s1
    s3.timeline[0].narration = some("Changed line.")
    check inputHashFor(rsLocalAudio, s1, opts) !=
          inputHashFor(rsLocalAudio, s3, opts)

  test "final hash bundles timeline + narration + avatar + options":
    let opts = defaultRenderOptions()
    let s1 = baseScript()
    let h1 = inputHashFor(rsFinal, s1, opts)
    var s2 = s1
    s2.timeline[0].narration = some("X")
    check inputHashFor(rsFinal, s2, opts) != h1
    var s3 = s1
    s3.timeline[0].action = "X"
    check inputHashFor(rsFinal, s3, opts) != h1
    var s4 = s1
    s4.avatar.keyframes[0].dstRect.x = 0
    check inputHashFor(rsFinal, s4, opts) != h1
    var opts2 = opts
    opts2.captions = not opts.captions
    check inputHashFor(rsFinal, s1, opts2) != h1

  test "local-head hash includes localHeadModel":
    let s = baseScript()
    var optsA = defaultRenderOptions(); optsA.localHeadModel = "sadtalker"
    var optsB = defaultRenderOptions(); optsB.localHeadModel = "wav2lip"
    check inputHashFor(rsLocalHead, s, optsA) !=
          inputHashFor(rsLocalHead, s, optsB)

suite "artifact_project manifest roundtrip":
  test "save/load preserves stages and options":
    let scriptPath = mkTempScriptPath("rt")
    try:
      var m = emptyManifest()
      m.options.captions = false
      m.options.audioMode = amAudio
      m.options.localHeadModel = "wav2lip"
      m.options.commercialProvider = "elevenlabs"
      # Pretend a render produced a local-audio file on disk so the
      # mtime/size fields are populated through updateStage.
      let audioPath = stagePath(scriptPath, rsLocalAudio)
      createDir(projectDir(scriptPath))
      writeFile(audioPath, "PCM-stub")
      m.updateStage(scriptPath, rsLocalAudio, "abc123")
      saveManifest(scriptPath, m)
      let m2 = loadManifest(scriptPath)
      check m2.schema == ManifestSchemaVersion
      check m2.options.captions == false
      check m2.options.audioMode == amAudio
      check m2.options.localHeadModel == "wav2lip"
      check m2.options.commercialProvider == "elevenlabs"
      check m2.stages.len == 1
      check m2.stages[0].stage == rsLocalAudio
      check m2.stages[0].inputHash == "abc123"
      check m2.stages[0].size > 0
    finally:
      removeDir(projectDir(scriptPath).parentDir)

  test "loadManifest on missing file returns empty defaults":
    let m = loadManifest("/does/not/exist/script.yaml")
    check m.schema == ManifestSchemaVersion
    check m.options.captions == defaultRenderOptions().captions
    check m.stages.len == 0

suite "artifact_project staleness":
  test "missing file -> ssMissing regardless of hash":
    let scriptPath = mkTempScriptPath("miss")
    try:
      let m = emptyManifest()
      check stageStatus(m, scriptPath, rsLocalAudio, "any") == ssMissing
    finally:
      removeDir(projectDir(scriptPath).parentDir)

  test "matching hash -> ssFresh, mismatching -> ssStale":
    let scriptPath = mkTempScriptPath("fresh")
    try:
      createDir(projectDir(scriptPath))
      let p = stagePath(scriptPath, rsLocalAudio)
      writeFile(p, "AUDIO")
      var m = emptyManifest()
      m.updateStage(scriptPath, rsLocalAudio, "h1")
      check stageStatus(m, scriptPath, rsLocalAudio, "h1") == ssFresh
      check stageStatus(m, scriptPath, rsLocalAudio, "different") == ssStale
    finally:
      removeDir(projectDir(scriptPath).parentDir)
