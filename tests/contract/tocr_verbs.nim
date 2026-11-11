## The `ocr` verb's option refusals by engine (spec §2 "reject, don't drop",
## §7.5 "OCR"), run through the REAL built binaries as subprocesses.
##
## `--psm`, `--upscale` and `--invert` are Tesseract preprocessing knobs; an
## engine with no equivalent refuses them with exit 4 / `unsupported-option`,
## naming feature `ocr` and itself, and refuses them **before** it captures
## the frame it would read. The `apple-vision` engine is the one checked here:
## on macOS in `guiassert` it runs, and its refusal is the property; in every
## other build the same invocation is exit 4 for the reason that build has
## (`not-compiled-in` in `guiassert-fixture`, `wrong-platform` off macOS), so
## the suite holds both binaries on every platform to one exit code.
##
## The image is invented: a label drawn with the pure core's bitmap font and
## encoded with its PNG encoder. On macOS in `guiassert` the positive control
## runs Vision on it (the same invocation without the knob succeeds and reads
## the label), so the refusal is not a refusal of everything.
##
## Stand-ins: the fixture capture backend (spec §9.2), selected only for the
## capture form, because it records every frame it captures in its state
## directory: that is what makes "refused before the capture" observable (no
## frame is captured at all, not merely none left behind).

import std/[json, os, sequtils, strtabs, strutils, unittest]

import ./harness
import ../../src/gui_assert/core/[image, raster, png, geometry]

proc renderLabel(path: string) =
  var img = newImage(RgbImage, 600, 140, 255)
  discard img.drawText("QUARTZ 4719", point(40, 40), (0, 0, 0), 6)
  writeFile(path, encodePng(img))

proc fixtureFrames(stateDir: string): int =
  ## How many frames the fixture capture backend has captured in `stateDir`
  ## (it registers each one under `fixture/frames/`, spec §9.2).
  toSeq(walkFiles(stateDir / "fixture" / "frames" / "*.json")).len

proc runsAppleVision(): bool =
  ## True when the binary under test has a usable `apple-vision` engine:
  ## `guiassert` on macOS.
  when defined(macosx): not isMinimalBinary() else: false

proc expectedReason(): string =
  ## Why `apple-vision` is exit 4 in this build when it does not run.
  if isMinimalBinary(): "not-compiled-in" else: "wrong-platform"

# The helpers that check are templates, not procs: `check` marks the test
# that runs it as failed only when it expands inside the test's own scope.

template checkOcrRefusal(argv: seq[string], env: StringTableRef, reason: string) =
  let r = runCli(argv, env)
  let e = envelopeOf(r)
  checkpoint argv.join(" ") & " -> " & $e
  check r.exit == 4
  check e["ok"].getBool == false
  check e["error"]["kind"].getStr == "backend-unavailable"
  check e["error"]["reason"].getStr == reason
  check e["error"]["details"]["feature"].getStr == "ocr"
  check e["error"]["details"]["backend"].getStr == "apple-vision"
  check r.stderr == ""

suite "ocr verb option refusals (GS6)":

  test "test_ocr_unsupported_psm_on_apple_vision_is_exit_4":
    let st = freshDir("ocrv")
    let work = freshDir("ocrv-work")
    let env = baseEnv()
    env["GUIASSERT_STATE_DIR"] = st
    let img = work / "label.png"
    renderLabel(img)
    let reason = if runsAppleVision(): "unsupported-option" else: expectedReason()
    let base = @["--ocr-backend", "apple-vision", "ocr", "--image", img]
    for knob in [@["--psm", "6"], @["--upscale", "2"], @["--invert", "auto"],
                 @["--invert", "never"]]:
      checkOcrRefusal(base & knob, env, reason)
    # The capture form refuses before capturing: the fixture capture backend
    # would have written the frame.
    let shot = work / "never-written.png"
    checkOcrRefusal(@["--capture-backend", "fixture", "--ocr-backend", "apple-vision",
                      "ocr", "--region", "0,0,40,40", "--out", shot, "--psm", "6"],
                    env, reason)
    check not fileExists(shot)
    check fixtureFrames(st) == 0
    if runsAppleVision():
      # Positive control: without the knob the engine runs and reads.
      let r = runCli(base, env, timeoutMs = 180_000)
      let e = envelopeOf(r)
      checkpoint $e
      check r.exit == 0
      check e["data"]["backend"].getStr == "apple-vision"
      check e["data"]["text"].getStr == "QUARTZ 4719"
      # And the capture form without the knob captures and reads.
      let cap = work / "captured.png"
      let c = runCli(@["--capture-backend", "fixture", "--ocr-backend", "apple-vision",
                       "ocr", "--region", "0,0,400,120", "--out", cap], env,
                     timeoutMs = 180_000)
      checkpoint c.stdout
      check c.exit == 0
      check fileExists(cap)
      check fixtureFrames(st) == 1     # the probe above sees captures

cleanupFreshDirs()
