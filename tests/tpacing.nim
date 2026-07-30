## Human-cadence pacing tests (R6).
##
## The whole module is pure and deterministic — no subprocess, no GUI, no
## macOS Accessibility/TCC permission is involved.  These tests pin:
##
##   * log-normal keystroke delays: reproducible for a fixed seed, positive
##     and clamped within the preset bounds, with a batch mean that converges
##     to the preset's target mean, and distinct pacing across presets;
##   * the cubic Bézier mouse path: exact `src`/`dst` endpoints, correct point
##     count, monotone-ish forward progress with a single overshoot hump past
##     the target, seed-dependent (but endpoint-stable) arcs;
##   * idle / send-window pauses: reproducible and longer than a keystroke.
##
## No mocks are used: the code under test has no external dependencies.

import std/[unittest, math, sequtils, strutils]
import ../src/gui_assert/pacing

# ---------------------------------------------------------------------------
# Keystroke delays
# ---------------------------------------------------------------------------

suite "pacing: keystroke delay determinism + bounds":

  test "same (text, preset, seed) is byte-for-byte reproducible":
    let a = keystrokeDelaysMs("CodeTracer flame demo", ppThoughtful, 1234)
    let b = keystrokeDelaysMs("CodeTracer flame demo", ppThoughtful, 1234)
    check a == b
    check a.len == "CodeTracer flame demo".len

  test "a different seed yields a different delay sequence":
    let a = keystrokeDelaysMs("hello world", ppThoughtful, 1)
    let b = keystrokeDelaysMs("hello world", ppThoughtful, 2)
    check a.len == b.len
    check a != b

  test "every delay is positive and inside the preset clamp":
    for preset in PacingPreset:
      let p = keystrokePacingFor(preset)
      let delays = keystrokeDelaysMs("the quick brown fox jumps", preset, 99)
      for d in delays:
        check d > 0.0
        check d >= p.minMs
        check d <= p.maxMs

  test "batch mean converges to the preset's target mean":
    # 4000 samples: the arithmetic mean of a clamped log-normal parameterised
    # for target mean `meanMs` must land within 12% of it.
    let text = repeat('x', 4000)
    for preset in PacingPreset:
      let p = keystrokePacingFor(preset)
      let delays = keystrokeDelaysMs(text, preset, 4242)
      let mean = sum(delays) / delays.len.float
      check abs(mean - p.meanMs) / p.meanMs < 0.12

  test "presets differ: faster preset totals less than a slower one":
    let text = repeat('y', 2000)
    let texting    = sum(keystrokeDelaysMs(text, ppTexting, 7))
    let quick      = sum(keystrokeDelaysMs(text, ppQuick, 7))
    let thoughtful = sum(keystrokeDelaysMs(text, ppThoughtful, 7))
    let careful    = sum(keystrokeDelaysMs(text, ppCareful, 7))
    check texting < quick
    check quick < thoughtful
    check thoughtful < careful

  test "empty text yields no delays":
    check keystrokeDelaysMs("", ppQuick, 5).len == 0

suite "pacing: preset parsing":

  test "friendly names map to presets, case-insensitively":
    check parsePreset("thoughtful") == ppThoughtful
    check parsePreset("QUICK") == ppQuick
    check parsePreset("Texting") == ppTexting
    check parsePreset("careful") == ppCareful
    check parsePreset("fast") == ppQuick
    check parsePreset("slow") == ppCareful

  test "round-trips through the string form":
    for preset in PacingPreset:
      check parsePreset($preset) == preset

  test "unknown preset raises":
    expect PacingError:
      discard parsePreset("blazing")

# ---------------------------------------------------------------------------
# Bézier mouse path
# ---------------------------------------------------------------------------

suite "pacing: bezier mouse path":

  let src = point(100.0, 200.0)
  let dst = point(900.0, 500.0)

  test "path has the requested point count":
    check bezierMousePath(src, dst, 24, 77).len == 24

  test "path starts exactly at src and ends exactly at dst":
    let path = bezierMousePath(src, dst, 32, 77)
    check path[0] == src
    check path[^1] == dst

  test "too few points is rejected":
    expect PacingError:
      discard bezierMousePath(src, dst, 1, 77)

  test "forward progress is monotone up to a single overshoot hump past dst":
    let path = bezierMousePath(src, dst, 40, 77)
    let dist = sqrt((dst.x - src.x)^2 + (dst.y - src.y)^2)
    var projs: seq[float]
    for p in path:
      projs.add projectOntoAxis(src, dst, p)
    # The projection onto the travel axis rises to a peak, then settles back to
    # exactly `dist` at the end.  Find the peak.
    let peakIdx = projs.maxIndex()
    # Overshoot: the peak lies strictly beyond dst and is NOT the final point.
    check projs[peakIdx] > dist
    check peakIdx < path.high
    # Monotone increasing up to the peak ...
    for i in 1 .. peakIdx:
      check projs[i] >= projs[i-1] - 1e-9
    # ... then monotone decreasing back down to dst.
    for i in peakIdx+1 .. path.high:
      check projs[i] <= projs[i-1] + 1e-9
    # And it truly returns to the target (endpoint anchor).
    check abs(projs[^1] - dist) < 1e-6

  test "the curve bows off the straight line (not colinear)":
    let path = bezierMousePath(src, dst, 20, 77)
    var maxPerp = 0.0
    let dx = dst.x - src.x
    let dy = dst.y - src.y
    let dist = sqrt(dx*dx + dy*dy)
    for p in path:
      # perpendicular distance from the src→dst line
      let perp = abs((p.x - src.x) * (-dy) + (p.y - src.y) * dx) / dist
      maxPerp = max(maxPerp, perp)
    check maxPerp > 1.0   # visibly curved, in pixels

  test "different seeds trace different arcs but share exact endpoints":
    let a = bezierMousePath(src, dst, 24, 1)
    let b = bezierMousePath(src, dst, 24, 2)
    check a[0] == b[0]        # same start
    check a[^1] == b[^1]      # same end
    check a != b              # different interior

  test "same seed reproduces the path exactly":
    check bezierMousePath(src, dst, 24, 555) ==
          bezierMousePath(src, dst, 24, 555)

  test "a zero-length move degenerates to the point, endpoints intact":
    let p0 = point(400.0, 400.0)
    let path = bezierMousePath(p0, p0, 8, 3)
    check path.len == 8
    check path[0] == p0
    check path[^1] == p0
    for p in path:
      check abs(p.x - 400.0) < 1e-9
      check abs(p.y - 400.0) < 1e-9

# ---------------------------------------------------------------------------
# Idle / send-window pacing
# ---------------------------------------------------------------------------

suite "pacing: idle / send-window pauses":

  test "idle pause is reproducible for a fixed seed":
    check idlePauseMs(ppThoughtful, 88) == idlePauseMs(ppThoughtful, 88)

  test "an idle pause is longer than a single keystroke's mean":
    for preset in PacingPreset:
      let keyMean = keystrokePacingFor(preset).meanMs
      # scale defaults to 4×, so even a below-median idle draw comfortably
      # exceeds a typical keystroke; assert it beats the keystroke mean.
      check idlePauseMs(preset, 17) > keyMean

  test "a bigger scale produces a bigger pause (same seed)":
    check idlePauseMs(ppQuick, 21, 6.0) > idlePauseMs(ppQuick, 21, 2.0)
