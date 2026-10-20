## The tesseract OCR engine (GS6) through the REAL `guiassert` binary, against
## the tesseract and ffmpeg the flake pins (spec §4, §9.3). It runs on Linux
## and macOS alike, needs no permission and no display:
##
##   just test-live-tesseract      (inside `nix develop`)
##
## Stand-ins: one. To see what GuiAssert does with the diagnostics of a
## tesseract that FAILS, one check points `TESSERACT_BIN` at a three-line
## shell script that prints a diagnostic and exits 3: the pinned tesseract
## does not fail on demand, and the property under test (its diagnostics go
## into the error message, never to GuiAssert's stderr) is about GuiAssert,
## not tesseract. Everything else runs the pinned tesseract. The images are
## invented and rendered here by the pinned
## ffmpeg's `drawtext` with the flake's DejaVu Sans (the dev shell's
## `FONTCONFIG_FILE`), so they are the same on every host that uses the
## flake. Where each word's ink lies is measured from the rendered pixels
## themselves (`inkWords`), not assumed from the font: tesseract reports tight
## ink boxes, so its boxes must match the measured ones within `inkSlack`
## pixels on every edge (the one-pixel anti-aliasing fringe either side, and a
## pixel of rounding).

when not defined(posix):
  {.error: "tests/live/tocr_tesseract.nim runs on Linux and macOS".}

import std/[json, os, osproc, random, strtabs, strutils, unittest]

import ../contract/harness
import ../../src/gui_assert/core/[image, png, geometry]

const
  inkSlack = 3
  fontSize = 44

# ---------------------------------------------------------------------------
# Invented images
# ---------------------------------------------------------------------------

proc ffmpegBin(): string =
  result = getEnv("FFMPEG_BIN")
  if result.len == 0: result = findExe("ffmpeg")
  doAssert result.len > 0, "ffmpeg not found: run inside `nix develop`"

proc drawtextEscape(s: string): string =
  ## A value for drawtext's `text=` inside single quotes (letters, digits
  ## and spaces only are used here, so nothing needs escaping but the check).
  for c in s: doAssert c in {'A'..'Z', 'a'..'z', '0'..'9', ' '}, "unsupported character"
  s

proc renderLines(path: string, size: Size, lines: openArray[(string, Point)],
                 fg = "black", bg = "white") =
  ## `lines` drawn by ffmpeg at their top-left points in DejaVu Sans at
  ## `fontSize`, `fg` on `bg`, one PNG frame at `path`.
  var vf = "color=c=" & bg & ":s=" & $size.width & "x" & $size.height
  for (text, at) in lines:
    vf.add ",drawtext=font='DejaVu Sans':fontsize=" & $fontSize & ":fontcolor=" & fg &
      ":text='" & drawtextEscape(text) & "':x=" & $at.x & ":y=" & $at.y
  let (o, code) = execCmdEx(quoteShell(ffmpegBin()) & " -y -hide_banner -loglevel error " &
    "-f lavfi -i " & quoteShell(vf) & " -frames:v 1 " & quoteShell(path))
  doAssert code == 0, "ffmpeg failed: " & o

proc inkWords(path: string, band: tuple[top, bottom: int], dark: bool): seq[Rect] =
  ## The ink rectangles of the words in rows `band` of the image at `path`:
  ## columns holding ink (luma below 128 when `dark`, above it otherwise),
  ## split into words at gaps of at least a quarter of the font size, each
  ## word's rows of ink.
  let g = decodePngGray(readFile(path))
  proc ink(x, y: int): bool =
    let v = ord(g.pixels[y * g.width + x])
    if dark: v < 128 else: v >= 128
  var cols = newSeq[bool](g.width)
  for x in 0 ..< g.width:
    for y in band.top ..< band.bottom:
      if ink(x, y):
        cols[x] = true
        break
  var x = 0
  while x < g.width:
    if not cols[x]:
      inc x
      continue
    var x1 = x
    var gap = 0
    var j = x
    while j < g.width:
      if cols[j]:
        x1 = j
        gap = 0
      else:
        inc gap
        if gap >= fontSize div 4: break
      inc j
    var y0 = high(int)
    var y1 = -1
    for xx in x .. x1:
      for y in band.top ..< band.bottom:
        if ink(xx, y):
          y0 = min(y0, y)
          y1 = max(y1, y)
    result.add rect(x, y0, x1 - x + 1, y1 - y0 + 1)
    x = x1 + 1

proc planted(): string =
  ## A word that appears nowhere but in the image this run draws.
  randomize()
  result = "PLANTED"
  for i in 0 ..< 5: result.add char(ord('2') + rand(7))

# ---------------------------------------------------------------------------
# Running the binary
# ---------------------------------------------------------------------------

proc tessEnv(stateDir: string): StringTableRef =
  ## The caller's environment (it carries the dev shell's TESSERACT_BIN)
  ## without GUIASSERT_* variables, with the state directory.
  result = baseEnv()
  result["GUIASSERT_STATE_DIR"] = stateDir

proc bboxOf(w: JsonNode): Rect =
  let b = w["bbox"]
  rect(b[0].getInt, b[1].getInt, b[2].getInt, b[3].getInt)

proc wordsNamed(data: JsonNode, text: string): seq[JsonNode] =
  for w in data["words"]:
    if w["text"].getStr == text: result.add w

# The helpers that check are templates, not procs: `check` marks the test
# that runs it as failed only when it expands inside the test's own scope.

template ok(args: seq[string], env: StringTableRef): JsonNode =
  let r = runCli(args, env, timeoutMs = 120_000)
  if r.exit != 0: checkpoint "guiassert " & args.join(" ") & " -> " & r.stdout & r.stderr
  check r.exit == 0
  check r.stderr == ""
  envelopeOf(r)["data"]

template checkWordAt(data: JsonNode, text: string, inkRect: Rect) =
  ## `text` is recognized exactly once, its box within `inkSlack` of
  ## `inkRect` on every edge.
  let found = wordsNamed(data, text)
  checkpoint "words: " & $data["words"]
  check found.len == 1
  if found.len == 1:
    let b = bboxOf(found[0])
    checkpoint text & ": box " & $b & " vs ink " & $inkRect
    check abs(b.x - inkRect.x) <= inkSlack
    check abs(b.y - inkRect.y) <= inkSlack
    check abs(b.right - inkRect.right) <= inkSlack
    check abs(b.bottom - inkRect.bottom) <= inkSlack
    let c = found[0]["confidence"].getFloat
    check c >= 50.0 and c <= 100.0

# ---------------------------------------------------------------------------
# The tests
# ---------------------------------------------------------------------------

suite "tesseract OCR engine (GS6)":

  test "test_tesseract_ocr_verb_reads_rendered_text":
    let st = freshDir("tess")
    let work = freshDir("tess-work")
    let env = tessEnv(st)
    let img = work / "lines.png"
    let lines = [("QUARTZ 4719", point(40, 40)), ("PELICAN DOCK", point(40, 140))]
    renderLines(img, Size(width: 800, height: 240), lines)
    let row1 = inkWords(img, (30, 110), dark = true)
    let row2 = inkWords(img, (130, 210), dark = true)
    checkpoint "ink: " & $row1 & " " & $row2
    check row1.len == 2 and row2.len == 2    # the measurement itself is sound
    let d = ok(@["--ocr-backend", "tesseract", "ocr", "--image", img], env)
    check d["backend"].getStr == "tesseract"
    check d["languages"] == %["eng"]
    check d["image"]["source"]["kind"].getStr == "file"
    check d["words"].len == 4
    if row1.len == 2 and row2.len == 2:
      checkWordAt(d, "QUARTZ", row1[0])
      checkWordAt(d, "4719", row1[1])
      checkWordAt(d, "PELICAN", row2[0])
      checkWordAt(d, "DOCK", row2[1])
    check d["text"].getStr == "QUARTZ 4719\nPELICAN DOCK"
    # Control: the labels the other way round read the other way round.
    let swapped = work / "swapped.png"
    renderLines(swapped, Size(width: 800, height: 240),
                [("PELICAN DOCK", point(40, 40)), ("QUARTZ 4719", point(40, 140))])
    check ok(@["--ocr-backend", "tesseract", "ocr", "--image", swapped],
             env)["text"].getStr == "PELICAN DOCK\nQUARTZ 4719"
    # Negative control: a blank frame holds no words.
    let blank = work / "blank.png"
    renderLines(blank, Size(width: 800, height: 240), [])
    let b = ok(@["--ocr-backend", "tesseract", "ocr", "--image", blank], env)
    check b["words"].len == 0 and b["text"].getStr == ""
    # --upscale: boxes stay in the original image's pixels.
    let up = ok(@["--ocr-backend", "tesseract", "ocr", "--image", img, "--upscale", "2"], env)
    if row1.len == 2 and row2.len == 2:
      checkWordAt(up, "QUARTZ", row1[0])
      checkWordAt(up, "DOCK", row2[1])
    # --psm is passed to tesseract: single-line mode (7) reads one line.
    let one = work / "one.png"
    renderLines(one, Size(width: 800, height: 120), [("QUARTZ 4719", point(40, 30))])
    let p7 = ok(@["--ocr-backend", "tesseract", "ocr", "--image", one, "--psm", "7"], env)
    check p7["text"].getStr == "QUARTZ 4719"
    # --invert: light-on-dark text is read when GuiAssert inverts it.
    let darkImg = work / "dark.png"
    renderLines(darkImg, Size(width: 800, height: 240), lines, fg = "white", bg = "black")
    let inv = ok(@["--ocr-backend", "tesseract", "ocr", "--image", darkImg, "--invert",
                   "always"], env)
    check inv["text"].getStr == "QUARTZ 4719\nPELICAN DOCK"
    let auto = ok(@["--ocr-backend", "tesseract", "ocr", "--image", darkImg, "--invert",
                    "auto"], env)
    check auto["text"].getStr == "QUARTZ 4719\nPELICAN DOCK"
    let darkRow = inkWords(darkImg, (30, 110), dark = false)
    if darkRow.len == 2: checkWordAt(inv, "QUARTZ", darkRow[0])
    # --lang: an installed language is used and reported; several are joined.
    let deu = ok(@["--ocr-backend", "tesseract", "ocr", "--image", img, "--lang", "deu",
                   "--lang", "eng"], env)
    check deu["languages"] == %["deu", "eng"]
    check wordsNamed(deu, "4719").len == 1

  test "test_ocr_text_never_on_stderr_and_features_named":
    let st = freshDir("tess-c15")
    let work = freshDir("tess-c15-work")
    let env = tessEnv(st)
    let secret = planted()
    let img = work / "planted.png"
    renderLines(img, Size(width: 800, height: 140), [(secret, point(40, 40))])
    # Positive control: the data holds the planted word. The image carries no
    # resolution, so tesseract prints "Estimating resolution" diagnostics,
    # which must not reach GuiAssert's stderr either.
    let r = runCli(@["--ocr-backend", "tesseract", "ocr", "--image", img], env,
                   timeoutMs = 120_000)
    check r.exit == 0
    check r.stderr == ""
    let d = envelopeOf(r)["data"]
    checkpoint $d
    check wordsNamed(d, secret).len == 1
    # Refusals name the feature and the engine and carry no content (C7).
    for extra in [@["--lang", "zzz"], @["--lang", "eng+deu"]]:
      let x = runCli(@["--ocr-backend", "tesseract", "ocr", "--image", img] & extra, env)
      let e = envelopeOf(x)
      checkpoint $e
      check x.exit == 4
      check e["error"]["reason"].getStr == "unsupported-option"
      check e["error"]["details"]["feature"].getStr == "ocr"
      check e["error"]["details"]["backend"].getStr == "tesseract"
      check x.stderr == ""
      check secret notin x.stdout
    # A tesseract that fails: its diagnostics go into the message, never to
    # stderr, and they hold no recognized text.
    let failing = work / "fail-tesseract"
    writeFile(failing, "#!/bin/sh\necho 'simulated tesseract failure' >&2\nexit 3\n")
    setFilePermissions(failing, {fpUserRead, fpUserWrite, fpUserExec})
    let fenv = tessEnv(st)
    fenv["TESSERACT_BIN"] = failing
    let fr = runCli(@["--ocr-backend", "tesseract", "ocr", "--image", img], fenv)
    let fe = envelopeOf(fr)
    checkpoint $fe
    check fr.exit == 5
    check fe["error"]["reason"].getStr == "ocr-failed"
    check fr.stderr == ""
    check secret notin fr.stdout
    # A missing tesseract is exit 4 / missing-tool naming the feature.
    let menv = tessEnv(st)
    menv["TESSERACT_BIN"] = work / "no-such-tesseract"
    let mr = runCli(@["--ocr-backend", "tesseract", "ocr", "--image", img], menv)
    let me = envelopeOf(mr)
    check mr.exit == 4
    check me["error"]["reason"].getStr == "missing-tool"
    check me["error"]["details"]["feature"].getStr == "ocr"
    check me["error"]["remedy"].getStr.len > 0
    # capabilities: tesseract's ocr feature, probed; and unavailable without it.
    proc ocrFeature(caps: JsonNode): JsonNode =
      for f in caps["features"]:
        if f["feature"].getStr == "ocr": return f
      newJNull()
    let probed = ocrFeature(ok(@["--ocr-backend", "tesseract", "capabilities", "--probe"], env))
    check probed["backend"].getStr == "tesseract"
    check probed["state"].getStr == "supported"
    check probed["reason"].kind == JNull
    let missing = ocrFeature(ok(@["--ocr-backend", "tesseract", "capabilities", "--probe"], menv))
    check missing["state"].getStr == "unavailable"
    check missing["reason"].getStr == "missing-tool"

cleanupFreshDirs()
