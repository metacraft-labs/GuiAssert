## GuiAssert core: window detection from pixels only.
##
## Answers "how many top-level windows are visible in this frame, and where?"
## from decoded pixels alone, with no OS window API: the only option for a
## recorded video, a remote or virtual-machine screen, a single-surface
## application that draws its own widgets, or footage from a machine that
## cannot be introspected.
##
## Algorithm (pure CV): desktop windows are light regions on a darker
## background, so the detector
##
##   1. builds a foreground mask by thresholding brightness, the threshold
##      chosen from the frame histogram with **Otsu's method** (overridable
##      through the `threshold` parameter),
##   2. labels connected components with an **iterative** stack-based flood
##      fill (never one recursion per pixel: frames are large),
##   3. keeps components whose pixel area *and* bounding-box area exceed a
##      minimum fraction of the frame and whose aspect ratio is plausible for
##      a window. A component whose box spans essentially the whole frame is
##      either the background or a maximised window: it is split along its
##      interior separators and its panes are kept, and when it has no
##      separator it is the background and yields nothing (which is also what
##      makes a blank frame yield no windows although Otsu degenerates on a
##      unimodal histogram),
##   4. merges boxes that coincide or nest (keeping the outer box),
##   5. returns the surviving rectangles from top-left to bottom-right.
##
## Also here: binary morphology (`dilate`, `erode`, `morphClose`,
## `morphOpen`), axis-aligned line detection, row and column ink profiles, and
## the containment tree of detected regions (`buildRegionTree`).
##
## Reading each window's text needs a crop and OCR, which run subprocesses;
## that composition is `gui_assert/vision_windows.detectWindows`.

import std/algorithm

import ./image

type
  VisionWindowError* = object of CatchableError
    ## Raised on ffmpeg crop failures or when a frame cannot be processed.

  DetectedWindow* = object
    ## A single window region detected purely from pixels.
    bbox*: array[4, int]      ## [x, y, w, h] in frame pixels
    titleText*: string        ## OCR of the top title-bar band of the region
    text*: string             ## OCR of the whole window region
    confidence*: float        ## detector confidence in [0, 1]

# ---------------------------------------------------------------------------
# Pure CV core
# ---------------------------------------------------------------------------

proc otsuThreshold*(img: GrayImage): int =
  ## Compute a global grayscale threshold with Otsu's method: the level that
  ## maximises the between-class variance of the two brightness classes in the
  ## frame's histogram. Returns a value in `0 .. 255`; pixels with a gray value
  ## strictly greater than the threshold are treated as foreground.
  ##
  ## On a *unimodal* image (e.g. an all-dark frame) no split increases the
  ## between-class variance, so the returned threshold stays `0`. Callers must
  ## therefore not treat "> threshold" alone as proof of a real bimodal split —
  ## `detectWindowRects` additionally rejects a full-frame foreground blob.
  var hist: array[256, int]
  let n = img.width * img.height
  if n <= 0 or img.pixels.len < n:
    return 0
  for i in 0 ..< n:
    inc hist[ord(img.pixels[i])]

  let total = n
  var sumAll = 0.0
  for t in 0 ..< 256:
    sumAll += float(t) * float(hist[t])

  var sumB = 0.0
  var wB = 0
  var maxVar = 0.0
  var threshold = 0
  for t in 0 ..< 256:
    wB += hist[t]
    if wB == 0: continue
    let wF = total - wB
    if wF == 0: break
    sumB += float(t) * float(hist[t])
    let mB = sumB / float(wB)
    let mF = (sumAll - sumB) / float(wF)
    let diff = mB - mF
    let between = float(wB) * float(wF) * diff * diff
    if between > maxVar:
      maxVar = between
      threshold = t
  result = threshold

type
  Component = object
    ## Bounding box + connected-pixel area of one labelled foreground blob.
    minx, miny, maxx, maxy, area: int

proc labelComponents(img: GrayImage, threshold: int,
                     connectivity8: bool): seq[Component] =
  ## Connected-component labelling of the foreground mask
  ## (`gray value > threshold`) via an iterative stack-based flood fill. Uses an
  ## explicit `seq[int]` stack of pixel indices — never per-pixel recursion — so
  ## it is safe on large frames. Returns one `Component` per blob.
  let w = img.width
  let h = img.height
  let n = w * h
  result = @[]
  if n <= 0 or img.pixels.len < n:
    return
  var labels = newSeq[int](n)   # 0 = unvisited
  var stack: seq[int] = @[]
  var comp = 0
  for start in 0 ..< n:
    if labels[start] != 0: continue
    if ord(img.pixels[start]) <= threshold: continue   # background
    inc comp
    labels[start] = comp
    stack.setLen(0)
    stack.add(start)
    var minx = w
    var miny = h
    var maxx = -1
    var maxy = -1
    var area = 0
    while stack.len > 0:
      let idx = stack.pop()
      let px = idx mod w
      let py = idx div w
      inc area
      if px < minx: minx = px
      if px > maxx: maxx = px
      if py < miny: miny = py
      if py > maxy: maxy = py
      for dy in -1 .. 1:
        let ny = py + dy
        if ny < 0 or ny >= h: continue
        for dx in -1 .. 1:
          if dx == 0 and dy == 0: continue
          if not connectivity8 and dx != 0 and dy != 0: continue
          let nx = px + dx
          if nx < 0 or nx >= w: continue
          let nidx = ny * w + nx
          if labels[nidx] != 0: continue
          if ord(img.pixels[nidx]) <= threshold: continue
          labels[nidx] = comp
          stack.add(nidx)
    result.add(Component(minx: minx, miny: miny, maxx: maxx, maxy: maxy,
                         area: area))

proc intersectionArea(a, b: array[4, int]): int =
  ## Area of the axis-aligned overlap of two `[x, y, w, h]` rectangles.
  let ax2 = a[0] + a[2]
  let ay2 = a[1] + a[3]
  let bx2 = b[0] + b[2]
  let by2 = b[1] + b[3]
  let ix = max(0, min(ax2, bx2) - max(a[0], b[0]))
  let iy = max(0, min(ay2, by2) - max(a[1], b[1]))
  result = ix * iy

proc mergeBoxes(boxes: seq[array[4, int]]): seq[array[4, int]] =
  ## Deduplicate coincident / nested rectangles, keeping the outer (larger) box.
  ## Boxes are considered redundant when >90% of their own area is contained in
  ## an already-kept, larger box. Processing largest-first guarantees the outer
  ## box wins.
  var order = boxes
  order.sort(proc(a, b: array[4, int]): int =
    cmp(b[2] * b[3], a[2] * a[3]))   # area descending
  result = @[]
  for box in order:
    let boxArea = box[2] * box[3]
    var redundant = false
    for kept in result:
      let inter = intersectionArea(box, kept)
      if boxArea > 0 and float(inter) / float(boxArea) > 0.9:
        redundant = true
        break
    if not redundant:
      result.add(box)

# ---------------------------------------------------------------------------
# VU10: morphology on a binary mask
# ---------------------------------------------------------------------------

type
  Mask* = object
    ## A binary foreground mask. `data[y*width + x]` is `true` for foreground.
    ## Kept separate from `GrayImage` so morphology, labelling and the region
    ## tree all operate on the same explicit mask representation.
    width*, height*: int
    data*: seq[bool]

proc maskFromImage*(img: GrayImage, threshold: int): Mask =
  ## Build a foreground mask (`gray value > threshold`) from a `GrayImage`.
  result.width = img.width
  result.height = img.height
  let n = img.width * img.height
  result.data = newSeq[bool](n)
  if img.pixels.len < n: return
  for i in 0 ..< n:
    result.data[i] = ord(img.pixels[i]) > threshold

proc dilate*(mask: Mask, k: int): Mask =
  ## Morphological dilation with a `k`x`k` square structuring element: an output
  ## pixel is foreground when ANY input pixel within radius `k div 2` is
  ## foreground. Out-of-frame neighbours count as background. `k <= 1` is a no-op.
  result = mask
  if k <= 1: return
  let r = k div 2
  let w = mask.width
  let h = mask.height
  result.data = newSeq[bool](w * h)
  for y in 0 ..< h:
    for x in 0 ..< w:
      var on = false
      block search:
        for dy in -r .. r:
          let ny = y + dy
          if ny < 0 or ny >= h: continue
          let rowBase = ny * w
          for dx in -r .. r:
            let nx = x + dx
            if nx < 0 or nx >= w: continue
            if mask.data[rowBase + nx]:
              on = true
              break search
      result.data[y * w + x] = on

proc erode*(mask: Mask, k: int): Mask =
  ## Morphological erosion with a `k`x`k` square structuring element: an output
  ## pixel stays foreground only when ALL input pixels within radius `k div 2`
  ## are foreground. Out-of-frame neighbours count as background (so the border
  ## erodes). `k <= 1` is a no-op.
  result = mask
  if k <= 1: return
  let r = k div 2
  let w = mask.width
  let h = mask.height
  result.data = newSeq[bool](w * h)
  for y in 0 ..< h:
    for x in 0 ..< w:
      var allOn = true
      block search:
        for dy in -r .. r:
          let ny = y + dy
          if ny < 0 or ny >= h:
            allOn = false
            break search
          let rowBase = ny * w
          for dx in -r .. r:
            let nx = x + dx
            if nx < 0 or nx >= w or not mask.data[rowBase + nx]:
              allOn = false
              break search
      result.data[y * w + x] = allOn

proc morphClose*(mask: Mask, k: int): Mask =
  ## Morphological closing (dilate then erode) with a `k`x`k` element. Bridges
  ## thin gaps and fills small holes in the foreground while preserving the
  ## overall extent, so touching-but-separated blobs merge before connected
  ## components run. `k <= 1` is a no-op.
  erode(dilate(mask, k), k)

proc morphOpen*(mask: Mask, k: int): Mask =
  ## Morphological opening (erode then dilate) with a `k`x`k` element. Removes
  ## thin protrusions and specks (salt noise) smaller than the element while
  ## preserving the overall extent. `k <= 1` is a no-op.
  dilate(erode(mask, k), k)

proc labelComponentsMask*(mask: Mask, connectivity8: bool): seq[Component] =
  ## Connected-component labelling directly on a `Mask` (iterative stack-based
  ## flood fill, same algorithm as `labelComponents`). Returns one `Component`
  ## per blob.
  let w = mask.width
  let h = mask.height
  let n = w * h
  result = @[]
  if n <= 0 or mask.data.len < n:
    return
  var labels = newSeq[int](n)
  var stack: seq[int] = @[]
  var comp = 0
  for start in 0 ..< n:
    if labels[start] != 0: continue
    if not mask.data[start]: continue
    inc comp
    labels[start] = comp
    stack.setLen(0)
    stack.add(start)
    var minx = w
    var miny = h
    var maxx = -1
    var maxy = -1
    var area = 0
    while stack.len > 0:
      let idx = stack.pop()
      let px = idx mod w
      let py = idx div w
      inc area
      if px < minx: minx = px
      if px > maxx: maxx = px
      if py < miny: miny = py
      if py > maxy: maxy = py
      for dy in -1 .. 1:
        let ny = py + dy
        if ny < 0 or ny >= h: continue
        for dx in -1 .. 1:
          if dx == 0 and dy == 0: continue
          if not connectivity8 and dx != 0 and dy != 0: continue
          let nx = px + dx
          if nx < 0 or nx >= w: continue
          let nidx = ny * w + nx
          if labels[nidx] != 0: continue
          if not mask.data[nidx]: continue
          labels[nidx] = comp
          stack.add(nidx)
    result.add(Component(minx: minx, miny: miny, maxx: maxx, maxy: maxy,
                         area: area))

proc componentCount*(mask: Mask, connectivity8: bool = true): int =
  ## Number of connected foreground blobs in `mask` (convenience over
  ## `labelComponentsMask`).
  labelComponentsMask(mask, connectivity8).len

# ---------------------------------------------------------------------------
# A full-bleed window subdivided into panes
# ---------------------------------------------------------------------------
#
# A maximised application window covers the whole frame, so its foreground
# component is as large as the background blob of a blank frame, and the size
# rule alone cannot tell them apart. What tells them apart is STRUCTURE: an
# application that tiles panes paints separators between them — runs of rows or
# columns in a darker tone than the panes on either side. A blank frame has no
# such run; a subdivided window does. So instead of dropping every component
# over `maxAreaFrac`, `detectWindowRects` subdivides it along its separators and
# reports the panes; a component with no separator is still background.

const
  SeparatorDarkFraction* = 0.95
    ## A line inside a rectangle is a separator when at least this fraction of
    ## it is background-dark. A median (0.50) is wrong: a line that is a
    ## separator for half the rectangle and pane for the other half is not a
    ## separator of the whole rectangle, and it is one of the half where it is
    ## dark, which recursion reaches. 1.0 is brittle: one antialiased pixel on a
    ## true separator rejects it.

proc separatorTones*(img: GrayImage,
                     minShare: float = 0.002): tuple[threshold, separatorTone: int] =
  ## The threshold that splits a frame's dominant GROUND tone from the darker
  ## tone its separators are painted in, and that separator tone.
  ##
  ## Otsu answers a different question on a dark-themed application frame: its
  ## histogram is ink against ground, so Otsu separates the text from the
  ## panes and leaves the panes and their separators in one class. Here the
  ## ground is the histogram's MODE, the separator tone is the most frequent
  ## tone darker than the ground (at least `minShare` of the frame's pixels,
  ## and more than two levels away so antialiasing at the ground's own edges
  ## is not taken for it), and the threshold is their midpoint.
  ##
  ## Answers `(-1, -1)` when the frame has no darker population — a light
  ## window on a dark desktop, or a uniform frame — and callers then fall back
  ## to `otsuThreshold`.
  let n = img.width * img.height
  if n <= 0 or img.pixels.len < n:
    return (-1, -1)
  var hist: array[256, int]
  for i in 0 ..< n:
    inc hist[ord(img.pixels[i])]
  var ground = 0
  for t in 1 .. 255:
    if hist[t] > hist[ground]: ground = t
  let floorCount = max(1, int(minShare * float(n)))
  var sep = -1
  for t in 0 .. ground - 3:
    if hist[t] >= floorCount and (sep < 0 or hist[t] > hist[sep]):
      sep = t
  if sep < 0:
    return (-1, -1)
  ((ground + sep) div 2, sep)

proc darkFraction(img: GrayImage, r: array[4, int], vertical: bool,
                  index, threshold: int): float =
  ## Fraction of one line (column `index` if `vertical`, else row `index`)
  ## inside `r` that is background (`<= threshold`), sampled every 2 px.
  var dark = 0
  var total = 0
  if vertical:
    var y = r[1]
    while y < r[1] + r[3]:
      if ord(img.pixels[y * img.width + index]) <= threshold: inc dark
      inc total
      y += 2
  else:
    var x = r[0]
    while x < r[0] + r[2]:
      if ord(img.pixels[index * img.width + x]) <= threshold: inc dark
      inc total
      x += 2
  if total == 0: 0.0 else: dark / total

proc lineMedian(img: GrayImage, r: array[4, int], row: int): int =
  var vals: seq[int] = @[]
  var x = r[0]
  while x < r[0] + r[2]:
    vals.add ord(img.pixels[row * img.width + x])
    x += 2
  if vals.len == 0: return 0
  vals.sort()
  vals[vals.len div 2]

proc separatorsIn*(img: GrayImage, r: array[4, int], vertical: bool,
                   threshold: int, minSeparator: int = 3,
                   separatorFloor: int = -1): seq[tuple[first, last: int]] =
  ## Interior separators of `r` along one axis: runs of at least `minSeparator`
  ## lines that are each `SeparatorDarkFraction` dark inside `r`, not touching
  ## `r`'s own edge (that is its border, not a split).
  ##
  ## A HORIZONTAL run must also CONNECT `r`'s sides — a core of `minSeparator`
  ## consecutive rows dark at both its left and right edge pixel. An inset
  ## rule (a search box's border) can be dark along 95% of a wide pane without
  ## reaching either side, and it is furniture, not a split.
  ##
  ## `separatorFloor`, when `>= 0`, rejects a horizontal run with a row whose
  ## median is darker than it. A separator is painted in one tone and
  ## rasterising only blends it toward the lighter ground beside it; a SHADOW
  ## (black composited over the ground) is darker than any separator and
  ## spans the pane just the same.
  let n = if vertical: r[2] else: r[3]
  let origin = if vertical: r[0] else: r[1]
  var frac = newSeq[float](n)
  for i in 0 ..< n:
    frac[i] = darkFraction(img, r, vertical, origin + i, threshold)
  var i = 0
  while i < n:
    if frac[i] < SeparatorDarkFraction:
      inc i
      continue
    var j = i
    while j < n and frac[j] >= SeparatorDarkFraction: inc j
    if j - i >= minSeparator and i > 0 and j < n:
      var ok = vertical
      if not vertical:
        var sideRun = 0
        for row in origin + i ..< origin + j:
          if ord(img.pixels[row * img.width + r[0]]) <= threshold and
             ord(img.pixels[row * img.width + r[0] + r[2] - 1]) <= threshold:
            inc sideRun
            if sideRun >= minSeparator: ok = true
          else:
            sideRun = 0
        if ok and separatorFloor >= 0:
          for row in origin + i ..< origin + j:
            if lineMedian(img, r, row) < separatorFloor:
              ok = false
              break
      if ok:
        result.add((first: origin + i, last: origin + j - 1))
    i = j

proc subdivideRect*(img: GrayImage, r: array[4, int], threshold: int,
                    minSeparator: int = 3, minCell: int = 24,
                    separatorFloor: int = -1,
                    depth: int = 0, maxDepth: int = 6): seq[array[4, int]] =
  ## Split `r` recursively along its interior separators (`separatorsIn`) and
  ## return the leaf cells, in the order the recursion meets them.
  ##
  ## RECURSIVE, MEASURED ONLY INSIDE THE RECT BEING SPLIT, because a tiled
  ## layout is not a grid: a column can run the full height while its
  ## neighbour is split in two, and a global scan would cut the full-height
  ## column with the neighbour's split. Columns are tried first, then rows; a
  ## rect with no split in one axis recurses on the other. A band thinner than
  ## `minCell` is a separator's sliver, not a cell, and is dropped.
  if depth > maxDepth or r[2] < minCell or r[3] < minCell:
    return @[r]
  for vertical in [true, false]:
    let seps = separatorsIn(img, r, vertical, threshold, minSeparator,
                            if vertical: -1 else: separatorFloor)
    if seps.len == 0: continue
    let lo = if vertical: r[0] else: r[1]
    let extent = if vertical: r[2] else: r[3]
    var cursor = lo
    var bands: seq[tuple[a, b: int]] = @[]
    for s in seps:
      if s.first - cursor >= minCell: bands.add((cursor, s.first))
      cursor = s.last + 1
    if lo + extent - cursor >= minCell: bands.add((cursor, lo + extent))
    for b in bands:
      let sub = if vertical: [b.a, r[1], b.b - b.a, r[3]]
                else: [r[0], b.a, r[2], b.b - b.a]
      result.add subdivideRect(img, sub, threshold, minSeparator, minCell,
                               separatorFloor, depth + 1, maxDepth)
    return
  @[r]

proc detectWindowRects*(img: GrayImage,
                        threshold: int = -1,
                        minAreaFrac: float = 0.015,
                        maxAreaFrac: float = 0.98,
                        maxAspect: float = 12.0,
                        connectivity8: bool = true,
                        morphCloseK: int = 0,
                        subdivideFullBleed: bool = true,
                        minSeparator: int = 3,
                        separatorFloor: int = -1): seq[array[4, int]] =
  ## Detect top-level window rectangles from a decoded `GrayImage` using only
  ## pixels (no OS API). Returns `[x, y, w, h]` rectangles sorted top-left to
  ## bottom-right.
  ##
  ## Parameters (all with sane, data-driven defaults):
  ## * `threshold` — brightness cutoff for the foreground mask. `-1` (default)
  ##   computes it with Otsu's method (`otsuThreshold`); pass `0 .. 255` to
  ##   override.
  ## * `minAreaFrac` — a component's connected-pixel area *and* its bbox area
  ##   must each exceed this fraction of the frame. Default `0.015` (1.5%): far
  ##   below any real window yet well above icon/cursor/text specks.
  ## * `maxAreaFrac` — reject a component whose bbox covers more than this
  ##   fraction of the frame AS ONE WINDOW. Default `0.98`. Such a blob is
  ##   either the background (or a unimodal frame's whole-image mask) or a
  ##   maximised, full-bleed window; see `subdivideFullBleed`.
  ## * `subdivideFullBleed` — when true (default), a blob over `maxAreaFrac` is
  ##   split along its interior separators (`subdivideRect`) and its panes are
  ##   reported, each subject to the size and aspect rules below. A blob with
  ##   no separator yields nothing, so blank and uniform frames still yield
  ##   zero windows. When false, every such blob is dropped (the VU4 rule).
  ## * `minSeparator` — the thinnest run of dark lines that splits a full-bleed
  ##   blob. Default `3`: a one- or two-pixel rule inside a pane is furniture.
  ## * `separatorFloor` — when `>= 0`, a horizontal run with a row whose median
  ##   is darker than this is a shadow, not a separator (`separatorsIn`).
  ## * `maxAspect` — reject slivers whose longer side is more than this multiple
  ##   of the shorter side. Default `12.0`.
  ## * `connectivity8` — 8-connectivity when true (default), else 4.
  ## * `morphCloseK` — when `> 1`, morphologically CLOSE the foreground mask with
  ##   a `morphCloseK`x`morphCloseK` element before connected components, which
  ##   bridges thin gaps and fills small holes (a dashed border or an
  ##   anti-aliased seam) so a single window is not split into fragments.
  ##   Default `0` (OPT-IN): the VU4 path is byte-for-byte unchanged, so two
  ##   well-separated windows are never merged by the default behaviour.
  let w = img.width
  let h = img.height
  if w <= 0 or h <= 0 or img.pixels.len < w * h:
    return @[]
  let thr = if threshold >= 0: threshold else: otsuThreshold(img)
  let comps =
    if morphCloseK > 1:
      labelComponentsMask(morphClose(maskFromImage(img, thr), morphCloseK),
                          connectivity8)
    else:
      labelComponents(img, thr, connectivity8)
  let frameArea = float(w * h)

  var boxes: seq[array[4, int]] = @[]
  for c in comps:
    let bw = c.maxx - c.minx + 1
    let bh = c.maxy - c.miny + 1
    if bw <= 0 or bh <= 0: continue
    let bboxArea = float(bw * bh)
    # Minimum size: both the filled area and the bbox area must be substantial.
    if float(c.area) < minAreaFrac * frameArea: continue
    if bboxArea < minAreaFrac * frameArea: continue
    let plausible = proc (b: array[4, int]): bool =
      # Reject thin slivers (task bars, separators, scrollbars, ...).
      let longSide = float(max(b[2], b[3]))
      let shortSide = float(min(b[2], b[3]))
      shortSide > 0.0 and longSide / shortSide <= maxAspect
    # The whole-frame blob: background, or a full-bleed window to subdivide.
    if bboxArea > maxAreaFrac * frameArea:
      if not subdivideFullBleed: continue
      let cells = subdivideRect(img, [c.minx, c.miny, bw, bh], thr,
                                minSeparator = minSeparator,
                                separatorFloor = separatorFloor)
      if cells.len < 2: continue   # no structure: it is the background
      for cell in cells:
        if float(cell[2] * cell[3]) < minAreaFrac * frameArea: continue
        if plausible(cell): boxes.add(cell)
      continue
    if not plausible([c.minx, c.miny, bw, bh]): continue
    boxes.add([c.minx, c.miny, bw, bh])

  result = mergeBoxes(boxes)
  # Deterministic reading order: top-to-bottom, then left-to-right.
  result.sort(proc(a, b: array[4, int]): int =
    result = cmp(a[1], b[1])
    if result == 0: result = cmp(a[0], b[0]))

# ---------------------------------------------------------------------------
# VU10: axis-aligned line detection (Hough-lite via gradient RLE)
# ---------------------------------------------------------------------------

type
  AxisLine* = tuple[pos, start, len: int]
    ## A detected axis-aligned line. For a HORIZONTAL line `pos` is the row `y`
    ## and `[start, start+len)` is its `x` extent; for a VERTICAL line `pos` is
    ## the column `x` and `[start, start+len)` is its `y` extent.

proc mergeParallelLines(lines: seq[AxisLine], posGap: int): seq[AxisLine] =
  ## Collapse near-duplicate parallel lines produced by the two-sided gradient of
  ## one physical edge (a bright 1px line flags both the row above and the row of
  ## the line). Two lines merge when their positions differ by `<= posGap` and
  ## their extents overlap; the longer run is kept. Deterministic: input is
  ## sorted by `(pos, start)` first.
  var order = lines
  order.sort(proc(a, b: AxisLine): int =
    result = cmp(a.pos, b.pos)
    if result == 0: result = cmp(a.start, b.start))
  result = @[]
  for ln in order:
    var merged = false
    for i in 0 ..< result.len:
      let k = result[i]
      let overlap = min(k.start + k.len, ln.start + ln.len) -
                    max(k.start, ln.start)
      if abs(k.pos - ln.pos) <= posGap and overlap > 0:
        # Keep the longer run (and its position); extend nothing else.
        if ln.len > k.len:
          result[i] = ln
        merged = true
        break
    if not merged:
      result.add(ln)

proc detectAxisLines*(img: GrayImage, minRun: int,
                      gradThreshold: int = 32,
                      posGap: int = 2): tuple[hLines, vLines: seq[AxisLine]] =
  ## Detect long horizontal and vertical lines (title bars, toolbars, panel
  ## separators, window borders) purely from pixel gradients — a deterministic
  ## "Hough-lite" via run-length encoding, no accumulator voting.
  ##
  ## A HORIZONTAL line lives where a row exhibits a long run of strong VERTICAL
  ## gradient (`|img(y,x) - img(y+1,x)| > gradThreshold`): that is a brightness
  ## edge running left-to-right. A VERTICAL line is the transpose (long run of
  ## strong HORIZONTAL gradient down a column). Only runs of at least `minRun`
  ## contiguous strong pixels are reported, so short noisy segments are filtered.
  ## Near-duplicate parallel lines (the two sides of one edge) are merged within
  ## `posGap` rows/cols, keeping the longer run.
  let w = img.width
  let h = img.height
  var hRaw: seq[AxisLine] = @[]
  var vRaw: seq[AxisLine] = @[]
  if w <= 0 or h <= 0 or img.pixels.len < w * h:
    return (@[], @[])

  # Horizontal lines: scan each row, RLE of strong vertical gradient across x.
  for y in 0 ..< h - 1:
    let rowBase = y * w
    let nextBase = (y + 1) * w
    var runStart = -1
    for x in 0 ..< w:
      let strong = abs(ord(img.pixels[rowBase + x]) -
                       ord(img.pixels[nextBase + x])) > gradThreshold
      if strong:
        if runStart < 0: runStart = x
      else:
        if runStart >= 0 and x - runStart >= minRun:
          hRaw.add((pos: y, start: runStart, len: x - runStart))
        runStart = -1
    if runStart >= 0 and w - runStart >= minRun:
      hRaw.add((pos: y, start: runStart, len: w - runStart))

  # Vertical lines: scan each column, RLE of strong horizontal gradient down y.
  for x in 0 ..< w - 1:
    var runStart = -1
    for y in 0 ..< h:
      let base = y * w + x
      let strong = abs(ord(img.pixels[base]) -
                       ord(img.pixels[base + 1])) > gradThreshold
      if strong:
        if runStart < 0: runStart = y
      else:
        if runStart >= 0 and y - runStart >= minRun:
          vRaw.add((pos: x, start: runStart, len: y - runStart))
        runStart = -1
    if runStart >= 0 and h - runStart >= minRun:
      vRaw.add((pos: x, start: runStart, len: h - runStart))

  result = (mergeParallelLines(hRaw, posGap), mergeParallelLines(vRaw, posGap))

# ---------------------------------------------------------------------------
# VU10: projection profiles
# ---------------------------------------------------------------------------

proc rowProfile*(img: GrayImage, threshold: int = -1): seq[int] =
  ## Per-row count of foreground pixels (`gray value > threshold`); the returned
  ## seq has one entry per image row. `threshold = -1` uses Otsu. Peaks/valleys
  ## in this profile reveal horizontal band structure (title bars, tool rows).
  let w = img.width
  let h = img.height
  result = newSeq[int](max(0, h))
  if w <= 0 or h <= 0 or img.pixels.len < w * h: return
  let thr = if threshold >= 0: threshold else: otsuThreshold(img)
  for y in 0 ..< h:
    let rowBase = y * w
    var c = 0
    for x in 0 ..< w:
      if ord(img.pixels[rowBase + x]) > thr: inc c
    result[y] = c

proc colProfile*(img: GrayImage, threshold: int = -1): seq[int] =
  ## Per-column count of foreground pixels (`gray value > threshold`); one entry
  ## per image column. `threshold = -1` uses Otsu. Peaks/valleys reveal vertical
  ## column structure (panel separators, side rails).
  let w = img.width
  let h = img.height
  result = newSeq[int](max(0, w))
  if w <= 0 or h <= 0 or img.pixels.len < w * h: return
  let thr = if threshold >= 0: threshold else: otsuThreshold(img)
  for y in 0 ..< h:
    let rowBase = y * w
    for x in 0 ..< w:
      if ord(img.pixels[rowBase + x]) > thr: inc result[x]

# ---------------------------------------------------------------------------
# VU10: region tree (rectangle containment hierarchy)
# ---------------------------------------------------------------------------

type
  Region* = object
    ## A node in the layout region tree: a bounding box plus the regions nested
    ## inside it (panel-within-window).
    bbox*: array[4, int]        ## [x, y, w, h]
    children*: seq[Region]

proc containmentRatio(inner, outer: array[4, int]): float =
  ## Fraction of `inner`'s area that lies inside `outer`.
  let innerArea = inner[2] * inner[3]
  if innerArea <= 0: return 0.0
  result = float(intersectionArea(inner, outer)) / float(innerArea)

proc buildRegionTree*(rects: seq[array[4, int]],
                      containFrac: float = 0.9): seq[Region] =
  ## Nest rectangles into a containment tree: a rect at least `containFrac`
  ## (default 90%) inside a strictly larger rect becomes that rect's child; its
  ## parent is the SMALLEST such container (the immediate ancestor), so a panel
  ## inside a window inside the desktop attaches to the window, not the desktop.
  ## Returns the top-level regions, each with nested `children`. Ordering is
  ## deterministic top-to-bottom then left-to-right at every level.
  let n = rects.len
  var parentOf = newSeq[int](n)
  for i in 0 ..< n:
    parentOf[i] = -1
    let areaI = rects[i][2] * rects[i][3]
    var bestArea = high(int)
    for j in 0 ..< n:
      if j == i: continue
      let areaJ = rects[j][2] * rects[j][3]
      # Strictly larger container; on an exact-area tie the lower index wins so
      # two identical rects cannot become each other's parent.
      let larger = areaJ > areaI or (areaJ == areaI and j < i)
      if not larger: continue
      if containmentRatio(rects[i], rects[j]) >= containFrac:
        if areaJ < bestArea:
          bestArea = areaJ
          parentOf[i] = j

  proc readingOrder(a, b: Region): int =
    result = cmp(a.bbox[1], b.bbox[1])
    if result == 0: result = cmp(a.bbox[0], b.bbox[0])

  proc build(idx: int): Region =
    result = Region(bbox: rects[idx], children: @[])
    for c in 0 ..< n:
      if parentOf[c] == idx:
        result.children.add(build(c))
    result.children.sort(readingOrder)

  result = @[]
  for i in 0 ..< n:
    if parentOf[i] == -1:
      result.add(build(i))
  result.sort(readingOrder)

# ---------------------------------------------------------------------------
# VU10 note on MSER: a full MSER text-region detector is intentionally NOT
# implemented here. It is explicitly optional/stretch in the milestone, its
# region set is sensitive to the delta/stability parameters (a determinism and
# maintenance cost), and GuiAssert already recovers text-region structure by a
# cheaper route: OCR word bboxes (VU5 index) localise text, `rowProfile` /
# `colProfile` expose text-band structure, and `detectAxisLines` finds the
# separators around text panels. Adding MSER is left as a follow-up.
# ---------------------------------------------------------------------------
