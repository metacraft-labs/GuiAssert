## GuiAssert core: points, sizes and rectangles, and the mapping between
## desktop and image coordinates.
##
## Two coordinate spaces meet in GuiAssert (spec §5):
##
## * **desktop coordinates**: the session's global logical coordinates, with
##   the origin at the top-left of the primary display and one unit per
##   logical point. Window bounds, input positions and display bounds use them.
## * **image coordinates**: physical pixels of a captured image, with the
##   origin at its top-left. OCR word boxes and vision results use them.
##
## A captured image records its `origin` (desktop coordinates of its top-left
## pixel) and its `scale` (physical pixels per logical point), so
## `desktop = origin + image / scale`. The procs below implement that mapping
## once, so a caller that clicks an OCR word never guesses the scale.

import std/math

type
  GeometryError* = object of CatchableError
    ## Raised for a mapping that cannot be computed (a non-positive or
    ## non-finite scale).

  Point* = object
    ## A position, in whichever space the caller states.
    x*, y*: int

  Size* = object
    ## A width and a height.
    width*, height*: int

  Rect* = object
    ## An axis-aligned rectangle: top-left `x, y`, extent `width, height`.
    ## The right and bottom edges are exclusive.
    x*, y*, width*, height*: int

func point*(x, y: int): Point = Point(x: x, y: y)
  ## Shorthand constructor.

func rect*(x, y, width, height: int): Rect =
  ## Shorthand constructor.
  Rect(x: x, y: y, width: width, height: height)

func rect*(a: array[4, int]): Rect =
  ## A rectangle from the `[x, y, w, h]` array the legacy APIs and the JSON
  ## contract use.
  Rect(x: a[0], y: a[1], width: a[2], height: a[3])

func toArray*(r: Rect): array[4, int] =
  ## The `[x, y, w, h]` form of `r`.
  [r.x, r.y, r.width, r.height]

func size*(r: Rect): Size = Size(width: r.width, height: r.height)
  ## The extent of `r`.

func right*(r: Rect): int = r.x + r.width
  ## The exclusive right edge.

func bottom*(r: Rect): int = r.y + r.height
  ## The exclusive bottom edge.

func isEmpty*(r: Rect): bool = r.width <= 0 or r.height <= 0
  ## True when `r` covers no pixel.

func area*(r: Rect): int =
  ## The number of unit cells `r` covers; 0 for an empty rectangle.
  if r.isEmpty: 0 else: r.width * r.height

func center*(r: Rect): Point =
  ## The centre of `r`, rounded towards the top-left.
  Point(x: r.x + r.width div 2, y: r.y + r.height div 2)

func contains*(r: Rect, p: Point): bool =
  ## True when `p` lies inside `r` (right and bottom edges excluded).
  p.x >= r.x and p.y >= r.y and p.x < r.right and p.y < r.bottom

func contains*(outer, inner: Rect): bool =
  ## True when the non-empty `inner` lies entirely inside `outer`.
  not inner.isEmpty and inner.x >= outer.x and inner.y >= outer.y and
    inner.right <= outer.right and inner.bottom <= outer.bottom

func intersection*(a, b: Rect): Rect =
  ## The overlap of `a` and `b`; an empty rectangle (width or height 0) when
  ## they do not overlap.
  let x0 = max(a.x, b.x)
  let y0 = max(a.y, b.y)
  let x1 = min(a.right, b.right)
  let y1 = min(a.bottom, b.bottom)
  if x1 <= x0 or y1 <= y0:
    Rect(x: x0, y: y0, width: 0, height: 0)
  else:
    Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)

func `$`*(p: Point): string = "[" & $p.x & ", " & $p.y & "]"
  ## The contract's `[x, y]` spelling.

func `$`*(r: Rect): string =
  ## The contract's `[x, y, w, h]` spelling.
  "[" & $r.x & ", " & $r.y & ", " & $r.width & ", " & $r.height & "]"

proc checkScale(scale: float) =
  if not (scale > 0.0) or scale == Inf:
    raise newException(GeometryError,
      "scale must be a positive finite number, got " & $scale)

proc imageToDesktop*(p: Point, origin: Point, scale: float): Point =
  ## Map an image pixel to desktop coordinates: `origin + p / scale`, rounded
  ## to the nearest unit. Raises `GeometryError` for a bad `scale`.
  checkScale(scale)
  Point(x: origin.x + int(round(float(p.x) / scale)),
        y: origin.y + int(round(float(p.y) / scale)))

proc desktopToImage*(p: Point, origin: Point, scale: float): Point =
  ## Map a desktop position to the image pixel that covers it:
  ## `(p - origin) * scale`, rounded down. Raises `GeometryError` for a bad
  ## `scale`.
  checkScale(scale)
  Point(x: int(floor(float(p.x - origin.x) * scale)),
        y: int(floor(float(p.y - origin.y) * scale)))

proc imageToDesktop*(r: Rect, origin: Point, scale: float): Rect =
  ## Map an image rectangle to the smallest desktop rectangle that covers it:
  ## the top-left is rounded down and the bottom-right up, so a word box
  ## never shrinks when it is mapped. Raises `GeometryError` for a bad `scale`.
  checkScale(scale)
  let x0 = origin.x + int(floor(float(r.x) / scale))
  let y0 = origin.y + int(floor(float(r.y) / scale))
  let x1 = origin.x + int(ceil(float(r.right) / scale))
  let y1 = origin.y + int(ceil(float(r.bottom) / scale))
  Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)

proc desktopToImage*(r: Rect, origin: Point, scale: float): Rect =
  ## Map a desktop rectangle to the image pixels it covers (top-left rounded
  ## down, bottom-right rounded up). Raises `GeometryError` for a bad `scale`.
  checkScale(scale)
  let x0 = int(floor(float(r.x - origin.x) * scale))
  let y0 = int(floor(float(r.y - origin.y) * scale))
  let x1 = int(ceil(float(r.right - origin.x) * scale))
  let y1 = int(ceil(float(r.bottom - origin.y) * scale))
  Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
