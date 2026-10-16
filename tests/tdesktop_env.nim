## GUIENV-M1 — the target interface's pure parts, with no compositor:
## PPM decoding (what `grim -t ppm` writes), rectangle helpers, and the
## base contract's NAMED refusal (`EnvError` carrying target and
## operation) for an operation a backend does not implement.
##
## MOCKS: one, justified. `NoBackend` is a target that implements nothing,
## so that the base methods' refusals are observable; it stands in for no
## real component — it IS the case under test ("a backend that cannot do
## X fails by name").

import std/unittest
import gui_assert/desktop_env

type NoBackend = ref object of TargetEnvironment

suite "GUIENV-M1 — target interface":

  test "a binary PPM decodes, comments and all":
    let ppm = "P6\n# made by a test\n2 1\n255\n" & "\x01\x02\x03\xfe\xfd\xfc"
    let img = decodePpm(ppm)
    check img.width == 2 and img.height == 1
    check img.pixel(0, 0) == (1'u8, 2'u8, 3'u8)
    check img.pixel(1, 0) == (254'u8, 253'u8, 252'u8)

  test "a malformed PPM is refused, not misread":
    expect ValueError: discard decodePpm("P3\n1 1\n255\n0 0 0")
    expect ValueError: discard decodePpm("P6\n2 2\n255\n\x00\x00\x00")
    expect ValueError: discard decodePpm("P6\n1 1\n65535\n\x00\x00\x00\x00\x00\x00")

  test "rectangles":
    let r = Rect(x: 10, y: 20, w: 100, h: 50)
    check r.center == (60, 45)
    check r.contains((10, 20)) and not r.contains((110, 20))
    check $r == "100x50+10+20"

  test "an unimplemented operation fails by name":
    let t = NoBackend(name: "none")
    try:
      discard t.windows()
      fail()
    except EnvError as e:
      check e.target == "none"
      check e.operation == "windows"

  test "spawn refuses a target that is not started":
    let t = NoBackend(name: "none")
    expect EnvError: discard t.spawn(@["true"])
