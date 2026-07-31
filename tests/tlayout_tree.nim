## VU10 tests for gui_assert/vision_windows — classical layout tree (pure CV).
##
## Mocking policy (per the workspace "mock as little as possible" policy):
##   * EVERY test in this suite is FULLY PURE. Each constructs `GrayImage`s /
##     `Mask`s / rectangle lists in memory and exercises the morphology, line
##     detection, projection-profile and region-tree algorithms with NO ffmpeg
##     and NO tesseract. Nothing is mocked — the inputs are the real data
##     structures the detector consumes at runtime.
##   * A VU4 regression check re-runs the pure `detectWindowRects` on the same
##     synthetic two-window frame the VU4 suite uses, confirming the VU10
##     morphology default (opt-in) leaves that result at exactly 2 windows.

import std/unittest

import ../src/gui_assert/vision_windows
import ../src/gui_assert/image_math

# ---------------------------------------------------------------------------
# In-memory helpers
# ---------------------------------------------------------------------------

proc mkImage(w, h, bg: int): GrayImage =
  result.width = w
  result.height = h
  result.pixels = newString(w * h)
  for i in 0 ..< w * h:
    result.pixels[i] = chr(bg)

proc fillRect(img: var GrayImage, x, y, w, h, val: int) =
  for yy in y ..< y + h:
    let rowBase = yy * img.width
    for xx in x ..< x + w:
      img.pixels[rowBase + xx] = chr(val)

proc hLine(img: var GrayImage, y, x0, x1, val: int) =
  let rowBase = y * img.width
  for x in x0 .. x1:
    img.pixels[rowBase + x] = chr(val)

proc vLine(img: var GrayImage, x, y0, y1, val: int) =
  for y in y0 .. y1:
    img.pixels[y * img.width + x] = chr(val)

proc mkMask(w, h: int): Mask =
  result.width = w
  result.height = h
  result.data = newSeq[bool](w * h)

proc setRect(m: var Mask, x, y, w, h: int, on: bool) =
  for yy in y ..< y + h:
    let rowBase = yy * m.width
    for xx in x ..< x + w:
      m.data[rowBase + xx] = on

proc approx(actual, expected, tol: int): bool =
  abs(actual - expected) <= tol

# ---------------------------------------------------------------------------
# Line detection (Hough-lite)
# ---------------------------------------------------------------------------

suite "layout_tree lines":
  test "test_hough_titlebar_synthetic":
    # 200x150 dark frame with a long horizontal title-bar line at row 20 and a
    # long vertical panel separator at col 100, plus a small noise block whose
    # runs are shorter than minRun and must NOT be reported.
    const w = 200
    const h = 150
    var img = mkImage(w, h, 30)
    hLine(img, 20, 5, 179, 220)      # horizontal line: run length 175
    vLine(img, 100, 40, 139, 220)    # vertical line:   run length 100
    fillRect(img, 150, 60, 10, 10, 220)  # noise: runs of only 10 px

    let minRun = 50
    let (hLines, vLines) = detectAxisLines(img, minRun)

    # A horizontal line near y=20 exists.
    var hHit = false
    for ln in hLines:
      if approx(ln.pos, 20, 3) and ln.len >= minRun:
        hHit = true
    check hHit

    # A vertical line near x=100 exists.
    var vHit = false
    for ln in vLines:
      if approx(ln.pos, 100, 3) and ln.len >= minRun:
        vHit = true
    check vHit

    # Every reported line clears the minRun bar (short noise filtered out).
    for ln in hLines: check ln.len >= minRun
    for ln in vLines: check ln.len >= minRun

    # The noise block (at x in [150,160), y in [60,70)) is never reported as a
    # line of its own: no horizontal line at rows 59..70 and no vertical line at
    # cols 149..160.
    for ln in hLines:
      check not (ln.pos >= 58 and ln.pos <= 71 and
                 ln.start >= 148 and ln.start <= 162)
    for ln in vLines:
      check not (ln.pos >= 148 and ln.pos <= 162 and
                 ln.start >= 58 and ln.start <= 71)

    # A far higher minRun keeps the two real lines but they must still be the
    # only survivors (both exceed 90 px).
    let (h2, v2) = detectAxisLines(img, 90)
    check h2.len >= 1
    check v2.len >= 1

# ---------------------------------------------------------------------------
# Projection profiles
# ---------------------------------------------------------------------------

suite "layout_tree profiles":
  test "test_projection_profiles":
    const w = 100
    const h = 80
    var img = mkImage(w, h, 10)
    # A bright band occupying rows 20..39 across the full width.
    fillRect(img, 0, 20, w, 20, 240)

    let rp = rowProfile(img)
    let cp = colProfile(img)
    check rp.len == h
    check cp.len == w
    # Rows inside the band are fully foreground; rows outside are empty.
    check rp[10] == 0
    check rp[25] == w
    check rp[60] == 0
    # The band spans the whole width, so every column has exactly 20 fg pixels.
    for x in 0 ..< w:
      check cp[x] == 20

# ---------------------------------------------------------------------------
# Morphology
# ---------------------------------------------------------------------------

suite "layout_tree morphology":
  test "test_morph_close_bridges_gap":
    # A filled 30x20 region split by a 2px vertical background gap -> two
    # components. Closing with a 5x5 element bridges the gap into one component.
    var m = mkMask(30, 20)
    m.setRect(0, 0, 14, 20, true)     # left block:  cols 0..13
    m.setRect(16, 0, 14, 20, true)    # right block: cols 16..29 (gap cols 14,15)
    check componentCount(m) == 2

    let closed = morphClose(m, 5)
    check componentCount(closed) == 1

    # Opening removes a thin 1px protrusion while keeping the main block.
    var m2 = mkMask(30, 20)
    m2.setRect(2, 2, 20, 15, true)    # solid block
    m2.setRect(0, 9, 2, 1, true)      # 2px-wide, 1px-tall whisker off the side
    let opened = morphOpen(m2, 3)
    # Still one main component, and the whisker column 0 is gone.
    check componentCount(opened) == 1
    check not opened.data[9 * 30 + 0]

# ---------------------------------------------------------------------------
# Region tree
# ---------------------------------------------------------------------------

suite "layout_tree region tree":
  test "test_region_tree_nesting":
    # One big window with two panels fully inside it.
    let big = [0, 0, 400, 300]
    let panelA = [20, 20, 100, 80]
    let panelB = [200, 150, 150, 100]
    let tree = buildRegionTree(@[big, panelA, panelB])
    check tree.len == 1
    check tree[0].bbox == big
    check tree[0].children.len == 2
    # Children are in reading order: panelA (y=20) before panelB (y=150).
    check tree[0].children[0].bbox == panelA
    check tree[0].children[1].bbox == panelB
    check tree[0].children[0].children.len == 0
    check tree[0].children[1].children.len == 0

    # Two disjoint windows -> two top-level regions, no children.
    let win1 = [0, 0, 100, 100]
    let win2 = [200, 200, 100, 100]
    let flat = buildRegionTree(@[win1, win2])
    check flat.len == 2
    check flat[0].children.len == 0
    check flat[1].children.len == 0

  test "test_region_tree_deep_nesting":
    # desktop > window > panel: panel attaches to the window, not the desktop.
    let desktop = [0, 0, 500, 500]
    let window = [50, 50, 300, 300]
    let panel = [80, 80, 100, 100]
    let tree = buildRegionTree(@[panel, window, desktop])  # unsorted input
    check tree.len == 1
    check tree[0].bbox == desktop
    check tree[0].children.len == 1
    check tree[0].children[0].bbox == window
    check tree[0].children[0].children.len == 1
    check tree[0].children[0].children[0].bbox == panel

# ---------------------------------------------------------------------------
# VU4 regression: the morphology default must not merge two separated windows.
# ---------------------------------------------------------------------------

suite "layout_tree vu4 regression":
  test "test_vu4_two_windows_unchanged":
    var img = mkImage(1000, 700, 20)
    fillRect(img, 60, 40, 300, 200, 230)
    fillRect(img, 500, 300, 360, 240, 230)

    # Default path (morphCloseK = 0): exactly two windows, as in VU4.
    check detectWindowRects(img).len == 2

    # Even with morphology explicitly enabled, two well-separated windows stay
    # separate (the 5x5 element cannot bridge a >100px gap).
    check detectWindowRects(img, morphCloseK = 5).len == 2
