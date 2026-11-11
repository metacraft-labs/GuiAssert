## The macOS live OCR suite (GS6): the REAL `guiassert` binary with the
## `apple-vision` OCR engine (macOS Vision, `VNRecognizeTextRequest`, through
## the Swift helper GuiAssert builds with the system `swiftc`) and, for the
## capture-then-read test, the `macos-sck` capture backend against the real
## window server (spec §4.1, §9.3, §9.4).
##
## Run it with `just test-live-macos` (builds the CLI first), or
##
##   nim c -d:tccLive -r --hints:off tests/live/tocr_macos.nim
##
## Stand-ins: none. Every image is invented and drawn here, deterministically,
## with the pure core's bitmap font (`core/raster`, a 5x7 design on a 6x8
## cell, at scale 6) and encoded with the core's PNG encoder, so each word's
## glyph rectangle is known exactly (`raster.drawText` returns it) and no host
## font or renderer is involved. The words are chosen from letters and digits
## Vision reads unambiguously in that font (measured on macOS 26.5: the
## random-letter strings it misreads, such as V for U or M for N, are left
## out). The capture test's window is `tests/live/fixtures/solid_window.swift`,
## a real AppKit window showing a label in the system font; it reports the
## label's on-screen rect.
##
## **Tolerances.** Vision's box for a word is not its glyph rectangle: it
## overshoots by part of the adjacent inter-word gap (measured: up to 30 px of
## a 36 px cell on the left edge of a word that follows a space, about 20 px
## on the right of one that precedes one, and 2-4 px top and bottom). So a
## word's box must lie within one character cell (6 x scale px) of its glyph
## rectangle on every edge and overlap it with an intersection-over-union of
## at least 0.6. A box from another word, or a line box given to a word, fails
## both.
##
## **Image files need no permission.** Vision reads the file; nothing touches
## the screen. Only the capture test needs the Screen Recording grant of the
## GuiAssert helper bundle and an unlocked GUI session; without them it FAILS
## with the `BLOCKED:` line of the live gate (`macos_live.gated`), never
## skips.

when not defined(tccLive):
  {.error: "tests/live/tocr_macos.nim is a live suite: compile it with -d:tccLive " &
           "(just test-live-macos)".}
when not defined(macosx):
  {.error: "tests/live/tocr_macos.nim runs on macOS only".}

import std/[json, os, osproc, random, sequtils, streams, strtabs, strutils, unittest]

import ../contract/harness
import ./macos_live
import ../../src/gui_assert/core/[image, raster, png, geometry]

const
  fontScale = 6
  cell = cellWidth * fontScale      ## one character cell, px
  minIou = 0.6

# ---------------------------------------------------------------------------
# Invented images
# ---------------------------------------------------------------------------

proc renderWords(path: string, size: Size,
                 words: openArray[(string, Point)]): seq[Rect] =
  ## Draw each `(text, top-left)` in black on white at `fontScale` and write
  ## the PNG to `path`; returns each text's glyph rectangle.
  var img = newImage(RgbImage, size.width, size.height, 255)
  for (text, at) in words:
    result.add img.drawText(text, at, (0, 0, 0), fontScale)
  writeFile(path, encodePng(img))

proc glyphRectOf(text: string, at: Point): Rect =
  ## The rectangle `text` occupies when drawn at `at` (`raster.textSize`).
  let s = textSize(text, fontScale)
  rect(at.x, at.y, s.width, s.height)

proc iou(a, b: Rect): float =
  let i = intersection(a, b)
  if i.isEmpty: return 0.0
  i.area / (a.area + b.area - i.area)

proc bboxOf(w: JsonNode): Rect =
  let b = w["bbox"]
  rect(b[0].getInt, b[1].getInt, b[2].getInt, b[3].getInt)

proc wordsNamed(data: JsonNode, text: string): seq[JsonNode] =
  for w in data["words"]:
    if w["text"].getStr == text: result.add w

proc planted(): string =
  ## A word that appears nowhere but in the image this run draws: PLANTED and
  ## five digits 2..9 (all read exactly by Vision in the core font).
  randomize()
  result = "PLANTED"
  for i in 0 ..< 5: result.add char(ord('2') + rand(7))

# The helpers that check are templates, not procs: `check` marks the test
# that runs it as failed only when it expands inside the test's own scope.

template checkWordAt(data: JsonNode, text: string, glyph: Rect) =
  ## `text` is recognized exactly once, with a box within one cell of
  ## `glyph` on every edge and an IoU of at least `minIou` with it.
  let found = wordsNamed(data, text)
  checkpoint "words: " & $data["words"]
  check found.len == 1
  if found.len == 1:
    let b = bboxOf(found[0])
    checkpoint text & ": box " & $b & " vs glyph " & $glyph & ", IoU " & $iou(b, glyph)
    check abs(b.x - glyph.x) <= cell
    check abs(b.y - glyph.y) <= cell
    check abs(b.right - glyph.right) <= cell
    check abs(b.bottom - glyph.bottom) <= cell
    check iou(b, glyph) >= minIou
    let c = found[0]["confidence"].getFloat
    check c >= 50.0 and c <= 100.0

template checkRefused(r: CliRun, reason, backend: string, secret: string) =
  ## Exit 4 / `reason`, naming feature `ocr` and `backend`, with nothing on
  ## stderr and `secret` nowhere in the envelope.
  let e = envelopeOf(r)
  checkpoint $e
  check r.exit == 4
  check e["error"]["kind"].getStr == "backend-unavailable"
  check e["error"]["reason"].getStr == reason
  check e["error"]["details"]["feature"].getStr == "ocr"
  check e["error"]["details"]["backend"].getStr == backend
  check r.stderr == ""
  check secret notin r.stdout

proc ocrFeature(caps: JsonNode): JsonNode =
  for f in caps["features"]:
    if f["feature"].getStr == "ocr": return f
  newJNull()

# ---------------------------------------------------------------------------
# The tests
# ---------------------------------------------------------------------------

suite "macOS live OCR (GS6)":

  test "test_apple_vision_ocr_reads_rendered_label_with_bbox":
    let st = freshDir("av-file")
    let work = freshDir("av-file-work")
    let env = liveEnv(st)
    let img = work / "labels.png"
    let at1 = point(60, 50)
    let at2 = point(60, 170)
    discard renderWords(img, Size(width: 900, height: 300),
                        [("QUARTZ 4719", at1), ("PELICAN DOCK", at2)])
    # The default OCR engine on macOS, selected by default.
    let caps = ok(@["capabilities"], env)
    check caps["selected"]["ocr"].getStr == "apple-vision"
    let d = ok(@["ocr", "--image", img], env)
    check d["backend"].getStr == "apple-vision"
    check d["languages"] == %["en-US"]
    check d["image"]["source"]["kind"].getStr == "file"
    check d["image"]["width"].getInt == 900 and d["image"]["height"].getInt == 300
    check d["words"].len == 4
    checkWordAt(d, "QUARTZ", glyphRectOf("QUARTZ", at1))
    checkWordAt(d, "4719", glyphRectOf("4719", point(at1.x + 7 * cell, at1.y)))
    checkWordAt(d, "PELICAN", glyphRectOf("PELICAN", at2))
    checkWordAt(d, "DOCK", glyphRectOf("DOCK", point(at2.x + 8 * cell, at2.y)))
    # Reading order: rows top to bottom, words left to right; the two words of
    # the first row are one line although Vision returns them apart.
    check d["text"].getStr == "QUARTZ 4719\nPELICAN DOCK"
    check wordsNamed(d, "QUARTZ")[0]["line"] == wordsNamed(d, "4719")[0]["line"]
    check wordsNamed(d, "QUARTZ")[0]["line"].getInt < wordsNamed(d, "DOCK")[0]["line"].getInt
    # Control: the same labels the other way round are read the other way
    # round, at their own places (the engine reads the pixels, not a cache).
    let swapped = work / "swapped.png"
    discard renderWords(swapped, Size(width: 900, height: 300),
                        [("PELICAN DOCK", at1), ("QUARTZ 4719", at2)])
    let s = ok(@["ocr", "--image", swapped], env)
    check s["text"].getStr == "PELICAN DOCK\nQUARTZ 4719"
    checkWordAt(s, "PELICAN", glyphRectOf("PELICAN", at1))
    checkWordAt(s, "QUARTZ", glyphRectOf("QUARTZ", at2))
    # Negative control: a blank image holds no words, and says so.
    let blank = work / "blank.png"
    discard renderWords(blank, Size(width: 900, height: 300), [])
    let b = ok(@["ocr", "--image", blank], env)
    check b["words"].len == 0 and b["text"].getStr == ""
    # --lang is passed to Vision and reported; --min-confidence 0 keeps all.
    let fr = ok(@["ocr", "--image", img, "--lang", "fr-FR"], env)
    check fr["languages"] == %["fr-FR"]
    check wordsNamed(fr, "4719").len == 1
    check ok(@["ocr", "--image", img, "--min-confidence", "0"], env)["words"].len == 4

  test "test_ocr_capture_then_read_maps_bbox_to_desktop":
    gated:
      let st = freshDir("av-capture")
      let work = freshDir("av-capture-work")
      let env = liveEnv(st)
      let label = "QUARTZ 4719"
      var fx = launchFixture("GuiAssert OCR Fixture " & nonce(), [240, 220, 640, 180],
                             [255, 255, 255], label = label, labelAt = [24, 40],
                             labelSize = 48)
      var plain = launchFixture("GuiAssert OCR Blank " & nonce(), [240, 460, 640, 180],
                                [255, 255, 255])
      try:
        let lr = fx.label
        check lr.len == 4
        let labelRect = rect(lr[0], lr[1], lr[2], lr[3])
        let outPng = work / "window.png"
        let d = ok(@["ocr", "--window", fx.window, "--out", outPng], env)
        check d["backend"].getStr == "apple-vision"
        let im = d["image"]
        check im["path"].getStr == outPng and fileExists(outPng)
        check im["source"]["kind"].getStr == "window"
        check im["source"]["id"].getStr == fx.window
        let origin = point(im["origin"][0].getInt, im["origin"][1].getInt)
        let scale = im["scale"].getFloat
        check scale >= 1.0
        checkpoint "label " & $labelRect & ", origin " & $origin & ", scale " & $scale &
          ", words " & $d["words"]
        var mapped: seq[Rect]
        for text in ["QUARTZ", "4719"]:
          let ws = wordsNamed(d, text)
          check ws.len == 1
          if ws.len == 1:
            let r = imageToDesktop(bboxOf(ws[0]), origin, scale)
            mapped.add r
            checkpoint text & " on the desktop: " & $r
            # The word lies on the label: its centre inside the label's
            # typographic rect, and the word inside that rect grown by a
            # quarter of the font size (Vision's boxes overshoot glyphs).
            check labelRect.contains(r.center)
            let grown = rect(labelRect.x - 12, labelRect.y - 12,
                             labelRect.width + 24, labelRect.height + 24)
            check grown.contains(r)
        if mapped.len == 2:
          # Together the two words span most of the label's width.
          let left = min(mapped[0].x, mapped[1].x)
          let right = max(mapped[0].right, mapped[1].right)
          check (right - left) >= labelRect.width * 6 div 10
          check mapped[0].x < mapped[1].x          # left to right
        check d["text"].getStr == label
        # Negative control: the same window without a label reads no words.
        let n = ok(@["ocr", "--window", plain.window, "--out", work / "plain.png"], env)
        check n["words"].len == 0
      finally:
        fx.stop()
        plain.stop()

  test "test_ocr_text_never_on_stderr_and_features_named":
    let st = freshDir("av-c15")
    let work = freshDir("av-c15-work")
    let env = liveEnv(st)
    let secret = planted()
    let img = work / "planted.png"
    discard renderWords(img, Size(width: 900, height: 160), [(secret, point(40, 50))])
    # Positive control: the data holds the planted word, so its absence
    # elsewhere means something.
    let r = runCli(@["ocr", "--image", img], env)
    check r.exit == 0
    let d = envelopeOf(r)["data"]
    check wordsNamed(d, secret).len == 1
    check d["text"].getStr == secret
    check r.stderr == ""
    # Refusals (C7): the Tesseract knobs name the feature and the engine, and
    # an unsupported language is refused, not dropped; none of them leaks
    # the word.
    for extra in [@["--psm", "6"], @["--upscale", "2"], @["--invert", "auto"]]:
      checkRefused(runCli(@["ocr", "--image", img] & extra, env),
                   "unsupported-option", "apple-vision", secret)
    checkRefused(runCli(@["ocr", "--image", img, "--lang", "xx-YY"], env),
                 "unsupported-option", "apple-vision", secret)
    # A refused option is refused before the capture: no frame is written
    # (the fixture capture backend would write one).
    let refusedOut = work / "refused.png"
    let rr = runCli(@["--capture-backend", "fixture", "ocr", "--region",
                      "0,0,40,40", "--out", refusedOut, "--psm", "6"], env)
    checkRefused(rr, "unsupported-option", "apple-vision", secret)
    check not fileExists(refusedOut)
    # Not merely removed afterwards: never captured (the fixture registers
    # every frame it captures).
    check toSeq(walkFiles(st / "fixture" / "frames" / "*.json")).len == 0
    # Over serve: the result carries the word, no event and no stderr does.
    var sv = startServe(@["serve", "--stdio"], env)
    sv.send(runReq("o1", @["ocr", "--image", img]))
    var events: seq[string]
    var result1: JsonNode
    while true:
      let line = sv.recvRaw(120_000)
      let msg = parseJson(line)
      if msg["type"].getStr == "event": events.add line
      elif msg["type"].getStr == "result":
        result1 = msg
        break
    check result1["exit"].getInt == 0
    check wordsNamed(result1["envelope"]["data"], secret).len == 1
    for line in events: check secret notin line
    sv.closeInput()
    discard sv.p.waitForExit(30_000)
    let daemonErr = sv.p.errorStream.readAll()
    sv.p.close()
    check secret notin daemonErr
    # capabilities: the engine's ocr feature, probed (C7).
    let probed = ocrFeature(ok(@["capabilities", "--probe"], env))
    check probed["backend"].getStr == "apple-vision"
    check probed["state"].getStr == "supported"
    check probed["reason"].kind == JNull
    let plainCaps = ocrFeature(ok(@["capabilities"], env))
    check plainCaps["backend"].getStr == "apple-vision"
    check plainCaps["state"].getStr == "available"

cleanupFreshDirs()
