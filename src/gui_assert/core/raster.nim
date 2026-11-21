## GuiAssert core: drawing rectangles and text into an RGB image.
##
## The fixture backend renders its frames itself (spec §9.2): a background,
## the scenario's windows and widgets, and their text, drawn with the small
## built-in bitmap font below. Nothing here reads a file or a font from the
## host, so a frame is a pure function of the scenario and therefore
## identical on every machine.
##
## The font is GuiAssert's own 5x7 design on a 6x8 cell (one column and one
## row of spacing), drawn at an integer `scale`. It covers printable ASCII;
## lower-case letters are drawn with the upper-case glyphs, and any other
## character as a hollow box, so a string's drawn width is always
## `len * 6 * scale` and text layout never depends on which glyphs exist.

import ./[geometry, image]

type
  Rgb* = tuple[r, g, b: int]
    ## A colour, each channel 0..255.

const
  glyphWidth* = 5
  glyphHeight* = 7
  cellWidth* = 6     ## glyph plus one column of spacing
  cellHeight* = 8    ## glyph plus one row of spacing

  glyphRows: array[33 .. 96, string] = [
    "..#..|..#..|..#..|..#..|..#..|.....|..#..",   # !
    ".#.#.|.#.#.|.....|.....|.....|.....|.....",   # "
    ".#.#.|#####|.#.#.|.#.#.|#####|.#.#.|.....",   # #
    "..#..|.####|#.#..|.###.|..#.#|####.|..#..",   # $
    "##..#|##..#|...#.|..#..|.#...|#..##|#..##",   # %
    ".##..|#..#.|.##..|.#...|#.#.#|#..#.|.##.#",   # &
    "..#..|..#..|.....|.....|.....|.....|.....",   # '
    "...#.|..#..|.#...|.#...|.#...|..#..|...#.",   # (
    ".#...|..#..|...#.|...#.|...#.|..#..|.#...",   # )
    ".....|#.#.#|.###.|#####|.###.|#.#.#|.....",   # *
    ".....|..#..|..#..|#####|..#..|..#..|.....",   # +
    ".....|.....|.....|.....|..#..|..#..|.#...",   # ,
    ".....|.....|.....|#####|.....|.....|.....",   # -
    ".....|.....|.....|.....|.....|.##..|.##..",   # .
    "....#|...#.|...#.|..#..|.#...|.#...|#....",   # /
    ".###.|#...#|#..##|#.#.#|##..#|#...#|.###.",   # 0
    "..#..|.##..|..#..|..#..|..#..|..#..|.###.",   # 1
    ".###.|#...#|....#|...#.|..#..|.#...|#####",   # 2
    "#####|...#.|..#..|...#.|....#|#...#|.###.",   # 3
    "...#.|..##.|.#.#.|#..#.|#####|...#.|...#.",   # 4
    "#####|#....|####.|....#|....#|#...#|.###.",   # 5
    "..##.|.#...|#....|####.|#...#|#...#|.###.",   # 6
    "#####|....#|...#.|..#..|.#...|.#...|.#...",   # 7
    ".###.|#...#|#...#|.###.|#...#|#...#|.###.",   # 8
    ".###.|#...#|#...#|.####|....#|...#.|.##..",   # 9
    ".....|.##..|.##..|.....|.##..|.##..|.....",   # :
    ".....|.##..|.##..|.....|.##..|..#..|.#...",   # ;
    "...#.|..#..|.#...|#....|.#...|..#..|...#.",   # <
    ".....|.....|#####|.....|#####|.....|.....",   # =
    ".#...|..#..|...#.|....#|...#.|..#..|.#...",   # >
    ".###.|#...#|....#|...#.|..#..|.....|..#..",   # ?
    ".###.|#...#|....#|.##.#|#.#.#|#.#.#|.###.",   # @
    ".###.|#...#|#...#|#####|#...#|#...#|#...#",   # A
    "####.|#...#|#...#|####.|#...#|#...#|####.",   # B
    ".###.|#...#|#....|#....|#....|#...#|.###.",   # C
    "###..|#..#.|#...#|#...#|#...#|#..#.|###..",   # D
    "#####|#....|#....|####.|#....|#....|#####",   # E
    "#####|#....|#....|####.|#....|#....|#....",   # F
    ".###.|#...#|#....|#.###|#...#|#...#|.####",   # G
    "#...#|#...#|#...#|#####|#...#|#...#|#...#",   # H
    ".###.|..#..|..#..|..#..|..#..|..#..|.###.",   # I
    "..###|...#.|...#.|...#.|...#.|#..#.|.##..",   # J
    "#...#|#..#.|#.#..|##...|#.#..|#..#.|#...#",   # K
    "#....|#....|#....|#....|#....|#....|#####",   # L
    "#...#|##.##|#.#.#|#.#.#|#...#|#...#|#...#",   # M
    "#...#|#...#|##..#|#.#.#|#..##|#...#|#...#",   # N
    ".###.|#...#|#...#|#...#|#...#|#...#|.###.",   # O
    "####.|#...#|#...#|####.|#....|#....|#....",   # P
    ".###.|#...#|#...#|#...#|#.#.#|#..#.|.##.#",   # Q
    "####.|#...#|#...#|####.|#.#..|#..#.|#...#",   # R
    ".####|#....|#....|.###.|....#|....#|####.",   # S
    "#####|..#..|..#..|..#..|..#..|..#..|..#..",   # T
    "#...#|#...#|#...#|#...#|#...#|#...#|.###.",   # U
    "#...#|#...#|#...#|#...#|#...#|.#.#.|..#..",   # V
    "#...#|#...#|#...#|#.#.#|#.#.#|#.#.#|.#.#.",   # W
    "#...#|#...#|.#.#.|..#..|.#.#.|#...#|#...#",   # X
    "#...#|#...#|.#.#.|..#..|..#..|..#..|..#..",   # Y
    "#####|....#|...#.|..#..|.#...|#....|#####",   # Z
    ".###.|.#...|.#...|.#...|.#...|.#...|.###.",   # [
    "#....|.#...|.#...|..#..|...#.|...#.|....#",   # \
    ".###.|...#.|...#.|...#.|...#.|...#.|.###.",   # ]
    "..#..|.#.#.|#...#|.....|.....|.....|.....",   # ^
    ".....|.....|.....|.....|.....|.....|#####",   # _
    ".#...|..#..|.....|.....|.....|.....|....."]   # `
    ## Glyphs for '!' .. '`', top row first, '#' an inked pixel.

  braceRows: array[123 .. 126, string] = [
    "...#.|..#..|..#..|.#...|..#..|..#..|...#.",   # {
    "..#..|..#..|..#..|..#..|..#..|..#..|..#..",   # |
    ".#...|..#..|..#..|...#.|..#..|..#..|.#...",   # }
    ".....|.....|.#...|#.#.#|...#.|.....|....."]   # ~

  boxRows = "#####|#...#|#...#|#...#|#...#|#...#|#####"
    ## Drawn for any character the font does not cover.

proc glyphFor(c: char): string =
  ## The row string of the glyph drawn for `c` ("" for a space).
  case c
  of ' ': ""
  of 'a' .. 'z': glyphRows[ord(c) - 32]
  of '!' .. '`': glyphRows[ord(c)]
  of '{' .. '~': braceRows[ord(c)]
  else: boxRows

proc setPixel*(img: var RgbImage, x, y: int, color: Rgb) =
  ## Set one pixel; coordinates outside the image are ignored, so callers
  ## may draw shapes that are partly off the canvas.
  if x < 0 or y < 0 or x >= img.width or y >= img.height: return
  let i = (y * img.width + x) * 3
  img.pixels[i] = char(color.r)
  img.pixels[i + 1] = char(color.g)
  img.pixels[i + 2] = char(color.b)

proc fillRect*(img: var RgbImage, r: Rect, color: Rgb) =
  ## Fill `r` (clipped to the image) with `color`.
  let clip = intersection(r, rect(0, 0, img.width, img.height))
  if clip.isEmpty: return
  for y in clip.y ..< clip.bottom:
    for x in clip.x ..< clip.right:
      img.setPixel(x, y, color)

proc strokeRect*(img: var RgbImage, r: Rect, color: Rgb, thickness = 1) =
  ## Draw the outline of `r`, `thickness` pixels wide, inside its bounds.
  if r.isEmpty: return
  let t = min(thickness, min(r.width, r.height))
  img.fillRect(rect(r.x, r.y, r.width, t), color)
  img.fillRect(rect(r.x, r.bottom - t, r.width, t), color)
  img.fillRect(rect(r.x, r.y, t, r.height), color)
  img.fillRect(rect(r.right - t, r.y, t, r.height), color)

func textSize*(text: string, scale: int): Size =
  ## The extent of `text` drawn at `scale`: one cell per byte, without the
  ## trailing spacing column and row.
  if text.len == 0: return Size(width: 0, height: 0)
  Size(width: (text.len * cellWidth - 1) * scale,
       height: glyphHeight * scale)

proc drawText*(img: var RgbImage, text: string, at: Point, color: Rgb,
               scale = 1): Rect =
  ## Draw `text` with its top-left at `at` and return the rectangle it
  ## occupies (`textSize`), clipped to nothing: the rectangle is where the
  ## text is, whether or not all of it falls inside the image. `scale` must
  ## be at least 1.
  doAssert scale >= 1, "text scale must be at least 1"
  for ci, c in text:
    let rows = glyphFor(c)
    if rows.len == 0: continue
    let ox = at.x + ci * cellWidth * scale
    var row = 0
    var col = 0
    for ch in rows:
      if ch == '|':
        inc row
        col = 0
        continue
      if ch == '#':
        for dy in 0 ..< scale:
          for dx in 0 ..< scale:
            img.setPixel(ox + col * scale + dx, at.y + row * scale + dy, color)
      inc col
  let s = textSize(text, scale)
  rect(at.x, at.y, s.width, s.height)
