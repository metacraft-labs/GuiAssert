## tartifact_pipeline — integration test for the multi-stage render
## pipeline.
##
## The local stages (`local-audio`) use the real implementation — local
## TTS via `say` / `espeak-ng`.  The commercial stages and the heavy
## `local-head` stage are wired through mock renderers so the test is
## hermetic, fast, and free of provider credit.  Tests drive the
## backend through its HTTP API end-to-end via an ephemeral-port
## server, the same way the JS frontend does.

import std/[algorithm, asyncdispatch, httpclient, json, options, os,
            osproc, sequtils, strformat, strtabs, strutils, streams,
            tables, times, unittest]

import ../src/gui_assert/parser
import ../src/gui_assert/avatar_track
import ../src/gui_assert/artifact_project
import ../src/gui_assert/editor_backend

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

const SampleYaml = """
metadata:
  title: "Pipeline Test"
  resolution: "1280x720"
  fps: 30
timeline:
  - time: 0.0
    action: focus_window
    params:
      window: "term"
    narration: "Hello there."
  - time: 4.0
    action: type_text
    params:
      window: "term"
      text: "step in"
    narration: "Now we step into the call."
"""

proc tempProjectScript(label: string): string =
  ## Write the sample YAML to a fresh temporary file and return its path.
  ## The sibling `<stem>.artifacts/` dir is cleared if it exists so each
  ## test starts from a known state.
  let dir = getTempDir() / ("gui_assert_pipeline_" & label)
  if dirExists(dir): removeDir(dir)
  createDir(dir)
  let p = dir / (label & ".yaml")
  writeFile(p, SampleYaml)
  return p

proc sanitizedFfmpegEnv(ffmpegPath: string): StringTableRef =
  ## Mirror `editor_backend.sanitizedFfmpegEnv`: nix-store ffmpegs ABI-
  ## conflict with the host's homebrew libavfilter when DYLD_*
  ## environment is inherited.  Strip those so the nix binary loads
  ## its own bundled libs.
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if (k == "DYLD_LIBRARY_PATH" or k == "DYLD_FALLBACK_LIBRARY_PATH") and
       ffmpegPath.startsWith("/nix/"):
      continue
    result[k] = v

proc runFfmpegMock(ffmpegBin: string; args: seq[string]; outPath: string) =
  let env = sanitizedFfmpegEnv(ffmpegBin)
  let p = startProcess(ffmpegBin, args = args,
                       env = env, options = {poStdErrToStdOut})
  let output = p.outputStream().readAll()
  let exit = p.waitForExit()
  p.close()
  doAssert fileExists(outPath),
    "ffmpeg failed to produce " & outPath & " (exit=" & $exit & "):\n" & output

proc writeFakeMp4(path: string, durationSec = 3.0) =
  ## Produce a tiny but *real* mp4 via ffmpeg's lavfi color source so
  ## the editor's `fileExists + getFileSize > 0` checks pass and the
  ## frontend could actually play it back.  Used for mock commercial
  ## providers.
  let parent = path.parentDir()
  if parent.len > 0 and not dirExists(parent): createDir(parent)
  let bin = getEnv("FFMPEG_BIN")
  let ffmpegBin = if bin.len > 0 and fileExists(bin): bin
                  else: findExe("ffmpeg")
  doAssert ffmpegBin.len > 0, "ffmpeg not found for mock mp4 generation"
  runFfmpegMock(ffmpegBin, @[
    "-y", "-hide_banner", "-loglevel", "error",
    "-f", "lavfi",
    "-i", &"color=c=0x00ff00:s=160x90:r=15:d={durationSec:.2f}",
    "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
    path
  ], path)

proc writeFakeMp3(path: string, durationSec = 3.0) =
  let parent = path.parentDir()
  if parent.len > 0 and not dirExists(parent): createDir(parent)
  let bin = getEnv("FFMPEG_BIN")
  let ffmpegBin = if bin.len > 0 and fileExists(bin): bin
                  else: findExe("ffmpeg")
  doAssert ffmpegBin.len > 0, "ffmpeg not found for mock mp3 generation"
  runFfmpegMock(ffmpegBin, @[
    "-y", "-hide_banner", "-loglevel", "error",
    "-f", "lavfi",
    "-i", &"sine=frequency=440:duration={durationSec:.2f}",
    "-c:a", "libmp3lame", "-b:a", "64k",
    path
  ], path)

proc writeFakeMkv(path: string, durationSec = 5.0) =
  ## Stand-in for the lossless screencast.  We deliberately use h264
  ## here rather than FFV1 because not every dev shell's ffmpeg ships
  ## with the FFV1 codec — the test only cares that "automation.mkv"
  ## exists and is non-empty.  Production wires the real FFV1
  ## recorder; this mock just keeps the manifest happy.
  let parent = path.parentDir()
  if parent.len > 0 and not dirExists(parent): createDir(parent)
  let bin = getEnv("FFMPEG_BIN")
  let ffmpegBin = if bin.len > 0 and fileExists(bin): bin
                  else: findExe("ffmpeg")
  doAssert ffmpegBin.len > 0
  runFfmpegMock(ffmpegBin, @[
    "-y", "-hide_banner", "-loglevel", "error",
    "-f", "lavfi",
    "-i", &"color=c=0x202020:s=320x180:r=30:d={durationSec:.2f}",
    "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
    path
  ], path)

# ---------------------------------------------------------------------------
# ffmpeg discovery (copied from tmedia / teditor)
# ---------------------------------------------------------------------------

proc ffmpegFiltersOutput(path: string): string =
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if (k == "DYLD_LIBRARY_PATH" or k == "DYLD_FALLBACK_LIBRARY_PATH") and
       path.startsWith("/nix/"):
      continue
    env[k] = v
  let p = startProcess(command = path, args = @["-hide_banner", "-filters"],
                       env = env, options = {poStdErrToStdOut})
  result = p.outputStream().readAll()
  discard p.waitForExit()
  p.close()

proc hasDrawtext(path: string): bool =
  try:
    let listing = ffmpegFiltersOutput(path)
    result = listing.splitLines.anyIt(it.contains(" drawtext "))
  except CatchableError:
    result = false

proc discoverFfmpeg(): string =
  let envBin = getEnv("FFMPEG_BIN")
  if envBin.len > 0 and fileExists(envBin) and hasDrawtext(envBin): return envBin
  let pathBin = findExe("ffmpeg")
  if pathBin.len > 0 and hasDrawtext(pathBin): return pathBin
  if dirExists("/nix/store"):
    for entry in walkDir("/nix/store"):
      if entry.kind == pcDir:
        let base = entry.path.extractFilename
        if "ffmpeg-full" in base and base.endsWith("-bin"):
          let bin = entry.path / "bin" / "ffmpeg"
          if fileExists(bin) and hasDrawtext(bin): return bin
    for entry in walkDir("/nix/store"):
      if entry.kind == pcDir:
        let base = entry.path.extractFilename
        if "ffmpeg" in base and base.endsWith("-bin"):
          let bin = entry.path / "bin" / "ffmpeg"
          if fileExists(bin) and hasDrawtext(bin): return bin
  raise newException(ValueError, "No ffmpeg with drawtext found")

let ffmpegPath = discoverFfmpeg()
putEnv("FFMPEG_BIN", ffmpegPath)
echo "Using ffmpeg: ", ffmpegPath

# ---------------------------------------------------------------------------
# Backend with real local audio + mock commercial / local-head
# ---------------------------------------------------------------------------

proc buildPipelineBackend(scriptPath: string;
                          localHeadCalls, commercialAudioCalls,
                          commercialHeadCalls, automationCalls,
                          finalCalls: ref int): EditorBackend =
  let cacheDir = scriptPath.parentDir / "cache"
  if not dirExists(cacheDir): createDir(cacheDir)
  let webRoot = currentSourcePath().parentDir().parentDir() / "editor-web"
  let script = parseScriptYaml(readFile(scriptPath))
  result = newEditorBackend(
    webRoot = webRoot,
    cacheDir = cacheDir,
    initialScript = script,
    ffmpegBin = ffmpegPath,
  )
  result.scriptPath = scriptPath
  result.registerDefaultStageRenderers()   # real local-audio

  let backend = result
  let lhc = localHeadCalls
  let cac = commercialAudioCalls
  let chc = commercialHeadCalls
  let auc = automationCalls
  let fic = finalCalls

  # Mock automation: writes a small FFV1 mkv to the canonical path.
  registerStageRenderer(backend, rsAutomation,
    proc(b: EditorBackend): string {.closure, gcsafe.} =
      inc auc[]
      let path = stagePath(b.scriptPath, rsAutomation)
      writeFakeMkv(path)
      return path)

  # Mock local-head: in the production sessions this would invoke
  # SadTalker / Wav2Lip / MuseTalk against the local-audio WAV.  The
  # mock just writes a green test card with the right duration so
  # downstream stages can consume it.
  registerStageRenderer(backend, rsLocalHead,
    proc(b: EditorBackend): string {.closure, gcsafe.} =
      inc lhc[]
      let path = stagePath(b.scriptPath, rsLocalHead)
      writeFakeMp4(path)
      return path)

  registerStageRenderer(backend, rsCommercialAudio,
    proc(b: EditorBackend): string {.closure, gcsafe.} =
      inc cac[]
      let path = stagePath(b.scriptPath, rsCommercialAudio)
      writeFakeMp3(path)
      return path)

  registerStageRenderer(backend, rsCommercialHead,
    proc(b: EditorBackend): string {.closure, gcsafe.} =
      inc chc[]
      let path = stagePath(b.scriptPath, rsCommercialHead)
      writeFakeMp4(path)
      return path)

  registerStageRenderer(backend, rsFinal,
    proc(b: EditorBackend): string {.closure, gcsafe.} =
      inc fic[]
      let path = stagePath(b.scriptPath, rsFinal)
      writeFakeMp4(path)
      return path)

# ---------------------------------------------------------------------------
# Server lifecycle helper (mirrors teditor.nim)
# ---------------------------------------------------------------------------

proc spawnServerAndRequest(
    backend: EditorBackend,
    requests: proc(baseUrl: string): Future[void]) =
  backend.startEditorBackend(port = 0)
  let port = int(backend.port)
  let baseUrl = "http://127.0.0.1:" & $port
  proc driver() {.async.} =
    let serveLoop = proc() {.async.} =
      while true:
        try:
          let alive = await backend.pumpOnce()
          if not alive: break
        except CatchableError:
          break
    let server = serveLoop()
    await requests(baseUrl)
    backend.stop()
    try: await server except CatchableError: discard
  waitFor driver()

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "pipeline HTTP integration":

  test "every stage renders, manifest tracks each one":
    let scriptPath = tempProjectScript("all-stages")
    var lhc, cac, chc, auc, fic: ref int
    new lhc; new cac; new chc; new auc; new fic
    let backend = buildPipelineBackend(scriptPath, lhc, cac, chc, auc, fic)
    spawnServerAndRequest(backend, proc(baseUrl: string): Future[void] {.async.} =
      let client = newAsyncHttpClient()
      client.headers = newHttpHeaders([("Content-Type", "application/json")])
      defer: client.close()
      # Initial state: everything missing.
      let stateBefore = parseJson(await client.getContent(baseUrl & "/api/render-state"))
      check stateBefore["stages"].len == 6
      for s in stateBefore["stages"].elems:
        check s["status"].getStr == "missing"
      # Render every stage in order.
      for stage in ["automation", "local-audio", "local-head",
                    "commercial-audio", "commercial-head", "final"]:
        let r = await client.post(
          baseUrl & "/api/render?stage=" & stage, body = "{}")
        let body = await r.body
        check r.code == Http200
        let j = parseJson(body)
        check j["ok"].getBool
        check j["stage"].getStr == stage
        check j["path"].getStr.len > 0
        check fileExists(j["path"].getStr)
      # Verify the manifest captured each one.
      let manifest = loadManifest(scriptPath)
      check manifest.stages.len == 6
      let stageNames = manifest.stages.mapIt($it.stage).sorted
      check stageNames == @["automation", "commercial-audio", "commercial-head",
                            "final", "local-audio", "local-head"]
      for s in manifest.stages:
        check s.inputHash.len > 0
        check s.size > 0
      # Mock renderers were each called exactly once.
      check lhc[] == 1 and cac[] == 1 and chc[] == 1 and auc[] == 1 and fic[] == 1
    )

  test "render-options POST persists to manifest and shifts hashes":
    let scriptPath = tempProjectScript("options")
    var lhc, cac, chc, auc, fic: ref int
    new lhc; new cac; new chc; new auc; new fic
    let backend = buildPipelineBackend(scriptPath, lhc, cac, chc, auc, fic)
    spawnServerAndRequest(backend, proc(baseUrl: string): Future[void] {.async.} =
      let client = newAsyncHttpClient()
      client.headers = newHttpHeaders([("Content-Type", "application/json")])
      defer: client.close()
      # Render local-head once with default options.
      discard await client.post(
        baseUrl & "/api/render?stage=local-head",
        body = "{}")
      let s1 = parseJson(await client.getContent(baseUrl & "/api/render-state"))
      let lhStatus1 = s1["stages"].elems.filterIt(it["stage"].getStr == "local-head")[0]
      check lhStatus1["status"].getStr == "fresh"
      # Flip the local-head model in options — the local-head hash should
      # shift, which marks the previously-rendered file as stale.
      let optsBody = %* {
        "captions": true, "audioMode": "head",
        "localHeadModel": "wav2lip", "commercialProvider": "heygen"
      }
      let r = await client.post(
        baseUrl & "/api/render-options",
        body = $optsBody)
      check r.code == Http200
      let s2 = parseJson(await client.getContent(baseUrl & "/api/render-state"))
      let lhStatus2 = s2["stages"].elems.filterIt(it["stage"].getStr == "local-head")[0]
      check lhStatus2["status"].getStr == "stale"
      # The persisted manifest reflects the new options.
      let manifest = loadManifest(scriptPath)
      check manifest.options.localHeadModel == "wav2lip"
    )

  test "narration change invalidates audio stages but spares automation":
    let scriptPath = tempProjectScript("narration-edit")
    var lhc, cac, chc, auc, fic: ref int
    new lhc; new cac; new chc; new auc; new fic
    let backend = buildPipelineBackend(scriptPath, lhc, cac, chc, auc, fic)
    spawnServerAndRequest(backend, proc(baseUrl: string): Future[void] {.async.} =
      let client = newAsyncHttpClient()
      client.headers = newHttpHeaders([("Content-Type", "application/json")])
      defer: client.close()
      # Render everything first.
      for stage in ["automation", "local-audio", "local-head",
                    "commercial-audio", "commercial-head", "final"]:
        discard await client.post(
          baseUrl & "/api/render?stage=" & stage,
          body = "{}")
      # Now change the narration on the first keyframe via /api/script.
      let scriptJson = parseJson(await client.getContent(baseUrl & "/api/script"))
      scriptJson["timeline"][0]["narration"] = %"A completely different opening line."
      discard await client.post(
        baseUrl & "/api/script",
        body = $scriptJson)
      # State now: narration-dependent stages stale, automation fresh.
      let s = parseJson(await client.getContent(baseUrl & "/api/render-state"))
      var statuses: Table[string, string]
      statuses = initTable[string, string]()
      for st in s["stages"].elems:
        statuses[st["stage"].getStr] = st["status"].getStr
      check statuses["automation"]       == "fresh"
      check statuses["local-audio"]      == "stale"
      check statuses["local-head"]       == "stale"
      check statuses["commercial-audio"] == "stale"
      check statuses["commercial-head"]  == "stale"
      check statuses["final"]            == "stale"
    )

  test "timeline action change invalidates automation + final only":
    let scriptPath = tempProjectScript("action-edit")
    var lhc, cac, chc, auc, fic: ref int
    new lhc; new cac; new chc; new auc; new fic
    let backend = buildPipelineBackend(scriptPath, lhc, cac, chc, auc, fic)
    spawnServerAndRequest(backend, proc(baseUrl: string): Future[void] {.async.} =
      let client = newAsyncHttpClient()
      client.headers = newHttpHeaders([("Content-Type", "application/json")])
      defer: client.close()
      for stage in ["automation", "local-audio", "local-head",
                    "commercial-audio", "commercial-head", "final"]:
        discard await client.post(
          baseUrl & "/api/render?stage=" & stage,
          body = "{}")
      # Change the action on a keyframe (narration unchanged).
      let scriptJson = parseJson(await client.getContent(baseUrl & "/api/script"))
      scriptJson["timeline"][1]["action"] = %"swap_window"
      discard await client.post(
        baseUrl & "/api/script",
        body = $scriptJson)
      let s = parseJson(await client.getContent(baseUrl & "/api/render-state"))
      var statuses: Table[string, string]
      statuses = initTable[string, string]()
      for st in s["stages"].elems:
        statuses[st["stage"].getStr] = st["status"].getStr
      # Action change affects automation + final (because final hashes
      # the full timeline) but leaves narration-only stages alone.
      check statuses["automation"]       == "stale"
      check statuses["final"]            == "stale"
      check statuses["local-audio"]      == "fresh"
      check statuses["local-head"]       == "fresh"
      check statuses["commercial-audio"] == "fresh"
      check statuses["commercial-head"]  == "fresh"
    )

  test "avatar-track update invalidates only the final composite":
    let scriptPath = tempProjectScript("avatar-edit")
    var lhc, cac, chc, auc, fic: ref int
    new lhc; new cac; new chc; new auc; new fic
    let backend = buildPipelineBackend(scriptPath, lhc, cac, chc, auc, fic)
    spawnServerAndRequest(backend, proc(baseUrl: string): Future[void] {.async.} =
      let client = newAsyncHttpClient()
      client.headers = newHttpHeaders([("Content-Type", "application/json")])
      defer: client.close()
      for stage in ["automation", "local-audio", "local-head",
                    "commercial-audio", "commercial-head", "final"]:
        discard await client.post(
          baseUrl & "/api/render?stage=" & stage,
          body = "{}")
      # Push a new avatar track.  This needs an avatar source video on
      # disk that the backend can probe; we reuse the commercial-head
      # mock mp4 the previous render just produced.
      let avatarTrack = %* {
        "source_video": stagePath(scriptPath, rsCommercialHead),
        "keyframes": [
          {
            "time": 0.0,
            "src_crop": {"x": 0, "y": 0, "w": 0, "h": 0},
            "dst_rect": {"x": 100, "y": 100, "w": 80, "h": 80},
            "key_method": "chroma", "key_color": "0x00ff00",
            "key_similarity": 0.2, "key_blend": 0.1,
            "luma_threshold": 0.9, "luma_tolerance": 0.05,
            "despill": true, "despill_type": "green"
          }
        ]
      }
      discard await client.post(
        baseUrl & "/api/avatar-track",
        body = $avatarTrack)
      let s = parseJson(await client.getContent(baseUrl & "/api/render-state"))
      var statuses: Table[string, string]
      statuses = initTable[string, string]()
      for st in s["stages"].elems:
        statuses[st["stage"].getStr] = st["status"].getStr
      # Only the final composite cares about avatar geometry; everything
      # else stays fresh.
      check statuses["automation"]       == "fresh"
      check statuses["local-audio"]      == "fresh"
      check statuses["local-head"]       == "fresh"
      check statuses["commercial-audio"] == "fresh"
      check statuses["commercial-head"]  == "fresh"
      check statuses["final"]            == "stale"
    )

  test "unregistered stage returns a clear 500":
    let scriptPath = tempProjectScript("missing-renderer")
    let cacheDir = scriptPath.parentDir / "cache"
    if not dirExists(cacheDir): createDir(cacheDir)
    let webRoot = currentSourcePath().parentDir().parentDir() / "editor-web"
    let script = parseScriptYaml(readFile(scriptPath))
    let backend = newEditorBackend(
      webRoot = webRoot,
      cacheDir = cacheDir,
      initialScript = script,
      ffmpegBin = ffmpegPath,
    )
    backend.scriptPath = scriptPath
    # *No* default renderers — only the unimplemented stub path.
    spawnServerAndRequest(backend, proc(baseUrl: string): Future[void] {.async.} =
      let client = newAsyncHttpClient()
      client.headers = newHttpHeaders([("Content-Type", "application/json")])
      defer: client.close()
      let r = await client.post(
        baseUrl & "/api/render?stage=local-audio",
        body = "{}")
      check r.code == Http500
      let body = await r.body
      check body.contains("no registered renderer") or body.contains("not yet wired")
    )
