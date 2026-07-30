## GuiAssert human-cadence PACING (deterministic, seeded)
##
## A screencast that replays a scripted "beat" must not look like a macro: a
## robot types every key at a fixed 50 ms, teleports the pointer, and fires the
## send key the instant the last character lands.  Humans don't.  Their
## inter-key gaps are *log-normally* distributed (mostly quick, with an
## occasional long think), their pointer follows a *curved* path that slightly
## *overshoots* the target and settles back, and they *pause* before committing
## an action (the "send window").
##
## This module reimplements those three ideas — borrowed from agent-harbor's
## `ah-automation-pacing` crate (log-normal keystroke delays, Bézier mouse
## motion with overshoot, idle/send-window pacing) — in pure Nim.
##
## ### Determinism
##
## Everything here is a *pure* function of its inputs plus an explicit
## `seed: int64`.  A given (input, seed) pair always yields the exact same
## delays and the exact same path, so a replay is byte-for-byte reproducible
## and fully unit-testable *without* any GUI, subprocess, or macOS TCC
## permission.  The RNG is `std/random`'s `Rand`, seeded via `initRand`; no
## global RNG state is touched.
##
## ### What it does *not* do
##
## This module computes *timings and coordinates* only.  It never posts a
## keystroke or moves the pointer — that is `input.nim`'s job (and is
## Accessibility-TCC-gated).  The beat-replay driver in codetracer-marketing
## composes this module's output with `input.nim`/`window_layout.nim` to
## actually drive an app.

import std/[random, math, strutils]

type
  PacingPreset* = enum
    ## Named human-cadence styles.  Each maps to a mean inter-key delay and a
    ## log-space spread (see `keystrokePacingFor`).  Ordered fastest → slowest
    ## so tests can assert `ppQuick` produces shorter delays than `ppCareful`.
    ppTexting     ## fast thumb-typing bursts
    ppQuick       ## a confident touch-typist at speed
    ppThoughtful  ## typing while thinking; frequent short pauses
    ppCareful     ## deliberate, checking each character

  KeystrokePacing* = object
    ## Parameters of the log-normal inter-key delay distribution, in
    ## milliseconds.  `meanMs` is the *arithmetic* mean the generated delays
    ## converge to; `sigma` is the standard deviation of the underlying normal
    ## (log space) and controls burstiness.  `minMs`/`maxMs` clamp outliers so
    ## a single sample can never stall a replay or fire faster than a real key.
    meanMs*: float
    sigma*: float
    minMs*: float
    maxMs*: float

  Point* = object
    ## A 2-D screen coordinate as floats (pixels).  Kept float so a Bézier can
    ## be sampled smoothly; callers round to `int` when they post a CGEvent.
    x*: float
    y*: float

  PacingError* = object of CatchableError

func point*(x, y: float): Point = Point(x: x, y: y)

# ---------------------------------------------------------------------------
# Presets
# ---------------------------------------------------------------------------

func keystrokePacingFor*(preset: PacingPreset): KeystrokePacing =
  ## The log-normal parameters for a preset.  These are the single source of
  ## truth for both delay generation and the "mean near the preset" tests.
  case preset
  of ppTexting:
    KeystrokePacing(meanMs: 110.0, sigma: 0.42, minMs: 30.0, maxMs: 700.0)
  of ppQuick:
    KeystrokePacing(meanMs: 150.0, sigma: 0.34, minMs: 40.0, maxMs: 800.0)
  of ppThoughtful:
    KeystrokePacing(meanMs: 220.0, sigma: 0.48, minMs: 55.0, maxMs: 1100.0)
  of ppCareful:
    KeystrokePacing(meanMs: 300.0, sigma: 0.38, minMs: 80.0, maxMs: 1200.0)

func parsePreset*(name: string): PacingPreset =
  ## Map a friendly name ("thoughtful", "quick", "texting", "careful") to a
  ## `PacingPreset`.  Case-insensitive.  Raises `PacingError` for an unknown
  ## name so a mistyped beat script fails loudly rather than pacing wrong.
  case name.strip().toLowerAscii()
  of "texting":            ppTexting
  of "quick", "fast":      ppQuick
  of "thoughtful", "think": ppThoughtful
  of "careful", "slow":    ppCareful
  else:
    raise newException(PacingError, "unknown pacing preset: " & name)

func `$`*(preset: PacingPreset): string =
  case preset
  of ppTexting:    "texting"
  of ppQuick:      "quick"
  of ppThoughtful: "thoughtful"
  of ppCareful:    "careful"

# ---------------------------------------------------------------------------
# Log-normal delay generation
# ---------------------------------------------------------------------------

proc newPacingRng*(seed: int64): Rand =
  ## A fresh, independent RNG seeded deterministically.  Every pacing helper
  ## takes a seed and constructs its own `Rand`, so results never depend on
  ## global RNG state or call ordering elsewhere.
  initRand(seed)

proc logNormalDelayMs*(rng: var Rand, p: KeystrokePacing): float =
  ## One clamped log-normal delay sample (ms).
  ##
  ## For a log-normal whose logarithm is `N(mu, sigma)`, the arithmetic mean is
  ## `exp(mu + sigma^2/2)`.  To hit a target arithmetic mean `p.meanMs` we set
  ## `mu = ln(meanMs) - sigma^2/2`, so a large batch of samples averages to
  ## `meanMs` regardless of `sigma`.  The sample is then clamped to
  ## `[minMs, maxMs]`.
  let mu = ln(p.meanMs) - (p.sigma * p.sigma) / 2.0
  let sample = exp(gauss(rng, mu, p.sigma))
  clamp(sample, p.minMs, p.maxMs)

proc keystrokeDelaysMs*(text: string, preset: PacingPreset,
                        seed: int64): seq[float] =
  ## The inter-key delays (ms) for typing `text` under `preset`.  Returns one
  ## delay per character — the pause *before* pressing that character — so a
  ## caller can `sleep(delay); type(ch)` in a loop.  Deterministic in
  ## `(text, preset, seed)`.
  let p = keystrokePacingFor(preset)
  var rng = newPacingRng(seed)
  result = newSeqOfCap[float](text.len)
  for _ in text:
    result.add logNormalDelayMs(rng, p)

proc idlePauseMs*(preset: PacingPreset, seed: int64,
                  scale: float = 4.0): float =
  ## A single "idle / think" pause (ms) — the beat before switching focus,
  ## before starting to type, or the send-window pause after finishing.  It is
  ## a log-normal draw whose mean is `scale ×` the preset's inter-key mean
  ## (a human pauses far longer between *decisions* than between keys).
  ## Deterministic in `(preset, seed, scale)`.
  var p = keystrokePacingFor(preset)
  p.meanMs = p.meanMs * scale
  p.maxMs = p.maxMs * scale
  var rng = newPacingRng(seed)
  logNormalDelayMs(rng, p)

# ---------------------------------------------------------------------------
# Bézier mouse motion (cubic, with slight overshoot)
# ---------------------------------------------------------------------------

func cubicBezier(p0, p1, p2, p3, t: float): float =
  ## Scalar cubic Bézier evaluation at parameter `t`.
  let mt = 1.0 - t
  mt*mt*mt*p0 + 3.0*mt*mt*t*p1 + 3.0*mt*t*t*p2 + t*t*t*p3

proc bezierMousePath*(src, dst: Point, points: int, seed: int64,
                      overshoot: float = 0.14): seq[Point] =
  ## Sample `points` positions along a cubic Bézier from `src` to `dst`.
  ##
  ## The curve is constructed so it:
  ##   * **starts exactly at `src`** (`result[0] == src`) and **ends exactly at
  ##     `dst`** (`result[^1] == dst`) — the endpoints are Bézier anchors, so
  ##     this is exact, not approximate;
  ##   * **overshoots** the target: the second control point is placed a
  ##     fraction `overshoot` *beyond* `dst` along the travel axis, so the path
  ##     sails slightly past `dst` near the end and settles back — the way a
  ##     hand does;
  ##   * **curves** off the straight line via a seeded perpendicular bow, so
  ##     two different seeds trace visibly different arcs while keeping the same
  ##     start, end, and along-axis progress.
  ##
  ## Deterministic in `(src, dst, points, seed, overshoot)`.
  if points < 2:
    raise newException(PacingError,
      "bezierMousePath needs at least 2 points, got " & $points)

  let dx = dst.x - src.x
  let dy = dst.y - src.y
  let dist = sqrt(dx*dx + dy*dy)

  # Unit direction and its perpendicular.  For a zero-length move the path is
  # just the (repeated) point, so guard the division.
  var ux, uy, px, py = 0.0
  if dist > 1e-9:
    ux = dx / dist; uy = dy / dist
    px = -uy;       py = ux            # 90° rotation → perpendicular unit

  var rng = newPacingRng(seed)
  # Perpendicular bow amplitudes for the two interior control points, as a
  # fraction of travel distance.  Seeded → reproducible; signed → arcs can bow
  # either way.  Along-axis positions are fixed (0.33·d and (1+overshoot)·d) so
  # forward progress is deterministic regardless of seed.
  let bow1 = (rng.rand(2.0) - 1.0) * 0.18 * dist
  let bow2 = (rng.rand(2.0) - 1.0) * 0.10 * dist

  # Control points.  P1 a third of the way along; P2 *beyond* dst by
  # `overshoot` (this is what produces the overshoot-and-settle).
  let c1x = src.x + ux * (0.33 * dist) + px * bow1
  let c1y = src.y + uy * (0.33 * dist) + py * bow1
  let c2x = src.x + ux * ((1.0 + overshoot) * dist) + px * bow2
  let c2y = src.y + uy * ((1.0 + overshoot) * dist) + py * bow2

  result = newSeqOfCap[Point](points)
  for i in 0 ..< points:
    let t = i.float / (points - 1).float
    if i == 0:
      result.add src                    # exact anchor
    elif i == points - 1:
      result.add dst                    # exact anchor
    else:
      result.add Point(
        x: cubicBezier(src.x, c1x, c2x, dst.x, t),
        y: cubicBezier(src.y, c1y, c2y, dst.y, t))

func projectOntoAxis*(src, dst, p: Point): float =
  ## Signed distance of `p` from `src` projected onto the `src→dst` axis.
  ## Exposed for tests: the along-axis progression is deterministic (seed
  ## affects only the perpendicular bow), so tests assert monotone-ish forward
  ## progress and the overshoot peak with it.
  let dx = dst.x - src.x
  let dy = dst.y - src.y
  let dist = sqrt(dx*dx + dy*dy)
  if dist <= 1e-9: return 0.0
  ((p.x - src.x) * dx + (p.y - src.y) * dy) / dist
