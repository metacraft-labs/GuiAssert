## Shared support of the live OCR suites that read text rendered by the
## pinned ffmpeg (`tests/live/tocr_tesseract.nim`, `tests/live/tocr_linux.nim`):
## invented images drawn with `drawtext` in the flake's DejaVu Sans (the dev
## shell's `FONTCONFIG_FILE`), the ink rectangles measured from their pixels,
## and reading words out of an `ocr` result.
##
## Where each word's ink lies is measured from the rendered pixels themselves
## (`inkWords`), not assumed from the font: tesseract reports tight ink boxes,
## so a suite can require its boxes to match the measured ones within
## `inkSlack` pixels on every edge (the one-pixel anti-aliasing fringe either
## side, and a pixel of rounding).

import std/[json, os, osproc, random]

import ../../src/gui_assert/core/[png, geometry]

const
  inkSlack* = 3
    ## How far (px) a tesseract word box may lie from the measured ink.
  defaultFontSize* = 44

proc ffmpegBin*(): string =
  result = getEnv("FFMPEG_BIN")
  if result.len == 0: result = findExe("ffmpeg")
  doAssert result.len > 0, "ffmpeg not found: run inside `nix develop`"

proc drawtextEscape(s: string): string =
  ## A value for drawtext's `text=` inside single quotes (letters, digits
  ## and spaces only are used here, so nothing needs escaping but the check).
  for c in s: doAssert c in {'A'..'Z', 'a'..'z', '0'..'9', ' '}, "unsupported character"
  s

proc renderLines*(path: string, size: Size, lines: openArray[(string, Point)],
                  fg = "black", bg = "white", fontSize = defaultFontSize) =
  ## `lines` drawn by ffmpeg at their top-left points in DejaVu Sans at
  ## `fontSize`, `fg` on `bg`, one frame at `path` (its format from the
  ## extension: `.png`, or `.ppm` for a binary PPM a fixture window shows).
  var vf = "color=c=" & bg & ":s=" & $size.width & "x" & $size.height
  for (text, at) in lines:
    vf.add ",drawtext=font='DejaVu Sans':fontsize=" & $fontSize & ":fontcolor=" & fg &
      ":text='" & drawtextEscape(text) & "':x=" & $at.x & ":y=" & $at.y
  let (o, code) = execCmdEx(quoteShell(ffmpegBin()) & " -y -hide_banner -loglevel error " &
    "-f lavfi -i " & quoteShell(vf) & " -frames:v 1 " & quoteShell(path))
  doAssert code == 0, "ffmpeg failed: " & o

proc inkWords*(path: string, band: tuple[top, bottom: int], dark: bool,
               fontSize = defaultFontSize): seq[Rect] =
  ## The ink rectangles of the words in rows `band` of the PNG at `path`:
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

proc planted*(): string =
  ## A word that appears nowhere but in the image this run draws.
  randomize()
  result = "PLANTED"
  for i in 0 ..< 5: result.add char(ord('2') + rand(7))

proc bboxOf*(w: JsonNode): Rect =
  let b = w["bbox"]
  rect(b[0].getInt, b[1].getInt, b[2].getInt, b[3].getInt)

proc wordsNamed*(data: JsonNode, text: string): seq[JsonNode] =
  for w in data["words"]:
    if w["text"].getStr == text: result.add w

proc pngToPpm*(png, ppm: string) =
  ## The PNG at `png` as the binary PPM at `ppm` (RGB24, lossless), for a
  ## fixture window to show the very pixels `inkWords` measured.
  let (o, code) = execCmdEx(quoteShellCommand([ffmpegBin(), "-y", "-hide_banner",
    "-loglevel", "error", "-i", png, "-frames:v", "1", "-pix_fmt", "rgb24", ppm]))
  doAssert code == 0, "ffmpeg failed: " & o
