## Unit tests for the pure core modules other than PNG: geometry and the
## desktop <-> image mapping, image conversions, the frame-series
## segmentation, OCR reading order, the accessibility tree path grammar and
## element filter, and the desktop object helpers.
##
## Entirely in memory: no subprocess, no file, no mock.

import std/[options, strutils, unittest]

import ../src/gui_assert/core/[geometry, image, segmentation, ocr_types,
                              tree_types, desktop_types, interfaces]

proc gray(w, h: int, f: proc (x, y: int): int): GrayImage =
  result = newImage(GrayImage, w, h)
  for y in 0 ..< h:
    for x in 0 ..< w:
      result.pixels[y * w + x] = char(f(x, y))

suite "core geometry":
  test "rect helpers":
    let r = rect(10, 20, 30, 40)
    check r.right == 40 and r.bottom == 60 and r.area == 1200
    check r.contains(point(10, 20)) and not r.contains(point(40, 20))
    check rect(r.toArray) == r
    check intersection(r, rect(35, 55, 10, 10)) == rect(35, 55, 5, 5)
    check intersection(r, rect(100, 100, 1, 1)).isEmpty
    check r.contains(rect(11, 21, 5, 5)) and not r.contains(rect(11, 21, 50, 5))
    check $r == "[10, 20, 30, 40]"

  test "desktop and image coordinates map through origin and scale":
    let origin = point(100, 50)
    # A Retina capture: 2 physical pixels per point.
    check imageToDesktop(point(40, 20), origin, 2.0) == point(120, 60)
    check desktopToImage(point(120, 60), origin, 2.0) == point(40, 20)
    # A word box never shrinks when mapped back to the desktop.
    let box = imageToDesktop(rect(3, 3, 3, 3), origin, 2.0)
    check box == rect(101, 51, 2, 2)
    check desktopToImage(rect(101, 51, 2, 2), origin, 2.0) == rect(2, 2, 4, 4)
    expect GeometryError:
      discard imageToDesktop(point(0, 0), origin, 0.0)
    expect GeometryError:
      discard desktopToImage(point(0, 0), origin, NaN)

suite "core image":
  test "conversions, crop and scale":
    var rgb = newImage(RgbImage, 2, 1)
    rgb.pixels = "\xFF\x00\x00\x00\x00\xFF"
    let g = rgb.toGray
    check g.width == 2 and g.pixels.len == 2
    check ord(g.pixels[0]) == 76 and ord(g.pixels[1]) == 29  # BT.601 red, blue
    check rgbToGray(0, 0, 0) == 0 and rgbToGray(255, 255, 255) == 255
    check rgb.toRgba.toRgb == rgb
    check newImage(GrayImage, 3, 3, 9).toRgb.toGray == newImage(GrayImage, 3, 3, 9)
    let img = gray(4, 4, proc (x, y: int): int = y * 4 + x)
    check crop(img, rect(1, 2, 2, 2)).pixels == "\x09\x0A\x0D\x0E"
    expect ImageMathError:
      discard crop(img, rect(3, 3, 2, 2))   # never silently clipped
    expect ImageMathError:
      discard crop(img, rect(0, 0, 0, 1))
    let up = scaleNearest(crop(img, rect(0, 0, 2, 1)), 4, 2)
    check up.pixels == "\x00\x00\x01\x01\x00\x00\x01\x01"
    expect ImageMathError:
      validate(GrayImage(width: 2, height: 2, pixels: "abc"))

suite "core segmentation":
  test "segments from a frame series":
    let a = gray(32, 32, proc (x, y: int): int = 20)
    let b = gray(32, 32, proc (x, y: int): int = (if x < 16: 230 else: 20))
    let segs = segmentFrames(@[a, a, a, b, b], sampleFps = 2.0)
    check segs.len == 2
    check segs[0] == (0.0, 1.5, 1.0)
    check segs[1].tStart == 1.5 and segs[1].tEnd == 2.5
    check segs[1].changeScore > 0.35
    check segmentFrames(@[a], 4.0) == @[(0.0, 0.25, 1.0)]
    expect SegmentationError:
      discard segmentsFromSeries(@[1.0], 3, 2.0, 0.1)    # wrong series length
    expect SegmentationError:
      discard segmentsFromSeries(@[], 1, 0.0, 0.1)

suite "core ocr types":
  test "reading order and results":
    let words = @[
      OcrWord(text: "world", bbox: [60, 10, 40, 10], lineNum: 1, blockNum: 1),
      OcrWord(text: "second", bbox: [10, 40, 50, 10], lineNum: 2, blockNum: 1),
      OcrWord(text: "hello", bbox: [10, 11, 40, 10], lineNum: 1, blockNum: 1)]
    check wordsToReadingOrderText(words) == "hello world\nsecond"
    let r = initOcrResult(words, "fixture", @["eng"])
    check r.text == "hello world\nsecond" and r.backend == "fixture"
    check concatenatedText(words) == "world second hello"
    check initOcrOptions().psm == 6

suite "core tree types":
  test "path grammar round-trips and rejects malformed paths":
    let p = parseTreePath("/app[4242]/window[0]/button[3]")
    check p.pid == 4242
    check p.steps == @[PathStep(role: roleWindow, index: 0),
                       PathStep(role: roleButton, index: 3)]
    check $p == "/app[4242]/window[0]/button[3]"
    check parseTreePath("/app[1]").steps.len == 0
    for bad in ["", "/", "app[1]", "/app[1]/", "/app[01]", "/app[-1]",
                "/app[1]/widget[0]", "/app[1]/button", "/app[1]/button[x]",
                "/window[0]", "/app[1]//button[0]"]:
      checkpoint bad
      expect TreeError:
        discard parseTreePath(bad)

  test "element filter":
    let field = Node(path: "/app[1]/window[0]/text-field[0]",
                     role: roleTextField, name: some("Email"),
                     states: {stFocusable, stEnabled, stEditable})
    let submit = Node(path: "/app[1]/window[0]/button[0]", role: roleButton,
                      name: some("Submit"), states: {stEnabled})
    let unnamed = Node(path: "/app[1]/window[0]/button[1]", role: roleButton)
    let root = Node(path: "/app[1]/window[0]", role: roleWindow,
                    children: @[field, submit, unnamed], childCount: 3)
    check field.matches(ElementFilter(role: some(roleTextField)))
    check not submit.matches(ElementFilter(nameContains: some("mail")))
    # Names match case-sensitively unless ignoreCase (spec §7.5, "Matching
    # rules"; contract 1.0 decision C13).
    check not field.matches(ElementFilter(nameContains: some("MAIL"),
                                          states: {stEditable}))
    check field.matches(ElementFilter(nameContains: some("MAIL"), ignoreCase: true,
                                      states: {stEditable}))
    check field.matches(ElementFilter(nameContains: some("mail"), states: {stEditable}))
    check not field.matches(ElementFilter(states: {stChecked}))
    check not unnamed.matches(ElementFilter(name: some("")))
    let found = root.findAll(ElementFilter(role: some(roleButton)))
    check found.elements.len == 2 and not found.truncated
    check found.elements[0].path == submit.path
    let limited = root.findAll(ElementFilter(role: some(roleButton)), limit = 1)
    check limited.elements.len == 1 and limited.truncated
    check parseRole("menu-item") == roleMenuItem
    expect TreeError:
      discard parseRole("Button")
    check parseNodeAction("set-value") == actSetValue

suite "core desktop types":
  test "names and enum spellings":
    for good in ["a", "Session-1", "rec_2026.10.20", repeat('x', 64)]:
      check isValidName(good)
    for bad in ["", "-lead", ".hidden", "has space", "slash/no", repeat('x', 65),
                "ünicode"]:
      checkpoint bad
      check not isValidName(bad)
    expect DesktopTypeError:
      checkName("../escape")
    check parseEnumValue[SessionKind]("virtual-display") == skVirtualDisplay
    expect DesktopTypeError:
      discard parseEnumValue[SessionKind]("Virtual-Display")
    check $iskWindowCrop == "window-crop"

  test "backend errors carry backend and reason":
    let e = unavailable("macos-sck", "wrong-platform", "ScreenCaptureKit is macOS-only")
    check e.backend == "macos-sck" and e.reason == "wrong-platform"
    check e.msg == "macos-sck: wrong-platform: ScreenCaptureKit is macOS-only"
    let d = newBackendError(PermissionDeniedError, "macos-ax", "accessibility", "no grant")
    check d of BackendError
