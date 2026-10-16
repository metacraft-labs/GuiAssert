## Desktop-environment targets — the interface.
##
## A *target* starts (or attaches to) a desktop session, runs the application
## under test in it, injects input, reads back what the COMPOSITOR says about
## windows, captures frames, changes desktop settings, and answers typed
## questions — *facts* — about what the desktop supports and prefers.
##
## A scenario is written once against this interface. Whatever differs
## between desktops (can a window be minimized? which side do title-bar
## buttons go on? how is a drag injected? where did the window end up?) is
## answered by the target, so a scenario never branches on a desktop's name:
##
##   let t = newSwayTarget()            # or any other backend
##   t.start()
##   defer: t.stop()
##   t.requireFacts("window.canMaximize")
##   let app = t.spawn(@["./my-app"])
##   let w = t.waitWindow("my-app")
##   t.drag(titleBarPoint(w), titleBarPoint(w) + (100, 50))
##   check t.window("my-app").rect.x == w.rect.x + 100
##
## Every failure to prepare the environment — a target that cannot start, a
## helper that cannot inject input, a window that never appears, a fact a
## scenario requires and the target cannot establish — raises `EnvError`
## naming the target and the operation. It is never a skip and never a
## vacuous pass.
##
## Backends: `gui_assert/desktop_env/sway` (headless sway).

import std/[os, osproc, strtabs, strutils, times]

type
  Rect* = object
    ## A rectangle in the compositor's layout coordinates (logical pixels).
    x*, y*, w*, h*: int

  WindowState* = enum
    wsFloating = "floating"      ## positioned freely rather than tiled
    wsTiled = "tiled"            ## placed by a tiling layout
    wsMaximized = "maximized"
    wsMinimized = "minimized"
    wsFullscreen = "fullscreen"

  EnvWindow* = object
    ## A toplevel window as the COMPOSITOR reports it: never
    ## the application's own account of itself.
    appId*, title*: string
    pid*: int
    rect*: Rect
    states*: set[WindowState]
    focused*: bool

  PointerButton* = enum
    pbLeft = "left"
    pbRight = "right"
    pbMiddle = "middle"

  FactProvenance* = enum
    fpMeasured = "measured"      ## observed from the running compositor
    fpDeclared = "declared"      ## known about this backend, not observable
    fpConfigured = "configured"  ## a setting this run's session holds

  Fact* = object
    name*, value*: string
    provenance*: FactProvenance
    detail*: string              ## how it was established, for reports

  EnvError* = object of CatchableError
    ## A named failure: which target, which operation.
    target*, operation*: string

  RgbImage* = object
    ## A captured frame, 8-bit RGB, row-major.
    width*, height*: int
    data*: seq[uint8]

  TargetEnvironment* = ref object of RootObj
    ## One per backend. `name` identifies the backend in reports ("sway").
    name*: string
    started*: bool
    sessionEnv*: StringTableRef
      ## The environment an application started in this session needs
      ## (`WAYLAND_DISPLAY`, `XDG_RUNTIME_DIR`, the session bus …).
    spawned*: seq[Process]

proc envError*(t: TargetEnvironment; operation, msg: string): ref EnvError =
  result = newException(EnvError, "[" & t.name & "] " & operation & ": " & msg)
  result.target = t.name
  result.operation = operation

proc center*(r: Rect): (int, int) = (r.x + r.w div 2, r.y + r.h div 2)
proc contains*(r: Rect; p: (int, int)): bool =
  p[0] >= r.x and p[1] >= r.y and p[0] < r.x + r.w and p[1] < r.y + r.h
proc `+`*(p: (int, int); d: (int, int)): (int, int) = (p[0] + d[0], p[1] + d[1])
proc `$`*(r: Rect): string = $r.w & "x" & $r.h & "+" & $r.x & "+" & $r.y

# ---------------------------------------------------------------------------
# The backend contract. Each method raises `EnvError` when it cannot do what
# it says; none of them returns a "could not" value a caller might ignore.
# ---------------------------------------------------------------------------

method start*(t: TargetEnvironment) {.base.} =
  raise t.envError("start", "not implemented by this backend")

method stop*(t: TargetEnvironment) {.base.} =
  raise t.envError("stop", "not implemented by this backend")

method windows*(t: TargetEnvironment): seq[EnvWindow] {.base.} =
  raise t.envError("windows", "not implemented by this backend")

method pointerMove*(t: TargetEnvironment; x, y: int) {.base.} =
  raise t.envError("pointerMove", "not implemented by this backend")

method pointerButton*(t: TargetEnvironment; button: PointerButton;
                      pressed: bool) {.base.} =
  raise t.envError("pointerButton", "not implemented by this backend")

method wheel*(t: TargetEnvironment; notches: int) {.base.} =
  raise t.envError("wheel", "not implemented by this backend")

method keys*(t: TargetEnvironment; chord: string) {.base.} =
  ## Press and release a key chord: `"ctrl+shift+t"`, `"Escape"`, `"a"`.
  raise t.envError("keys", "not implemented by this backend")

method typeText*(t: TargetEnvironment; text: string) {.base.} =
  raise t.envError("typeText", "not implemented by this backend")

method capture*(t: TargetEnvironment; region: Rect): RgbImage {.base.} =
  raise t.envError("capture", "not implemented by this backend")

method configure*(t: TargetEnvironment; setting, value: string) {.base.} =
  ## Change a desktop setting for this session. Settings:
  ## `buttonLayout` (GNOME `button-layout` syntax), `doubleClickTitlebar`.
  raise t.envError("configure", "not implemented by this backend")

method fact*(t: TargetEnvironment; name: string): Fact {.base.} =
  ## The named fact, or `EnvError` when the target cannot establish it.
  raise t.envError("fact " & name, "not implemented by this backend")

method factNames*(t: TargetEnvironment): seq[string] {.base.} = @[]

# ---------------------------------------------------------------------------
# Operations every backend shares, built on the contract above.
# ---------------------------------------------------------------------------

proc spawn*(t: TargetEnvironment; argv: seq[string];
            extraEnv: openArray[(string, string)] = [];
            workingDir = ""): Process =
  ## Start the application under test inside the session. It inherits this
  ## process's environment with the session's variables (and `extraEnv`)
  ## laid over it. `stop` terminates whatever is still running.
  if not t.started:
    raise t.envError("spawn", "the target is not started")
  if argv.len == 0:
    raise t.envError("spawn", "empty command line")
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs(): env[k] = v
  for k, v in t.sessionEnv: env[k] = v
  for (k, v) in extraEnv: env[k] = v
  try:
    result = startProcess(argv[0], workingDir = workingDir, args = argv[1 .. ^1],
                          env = env, options = {poUsePath, poParentStreams})
  except OSError as e:
    raise t.envError("spawn", argv[0] & ": " & e.msg)
  t.spawned.add result

proc stopSpawned*(t: TargetEnvironment) =
  ## Terminate every application `spawn` started that is still running.
  for p in t.spawned:
    try:
      if p.running:
        p.terminate()
        let deadline = epochTime() + 3.0
        while p.running and epochTime() < deadline: sleep(50)
        if p.running: p.kill()
      p.close()
    except OSError: discard
  t.spawned.setLen 0

proc findWindow*(t: TargetEnvironment; appId: string): (bool, EnvWindow) =
  for w in t.windows():
    if w.appId == appId: return (true, w)
  (false, EnvWindow())

proc window*(t: TargetEnvironment; appId: string): EnvWindow =
  ## The window with this app id, as the compositor reports it now.
  let (found, w) = t.findWindow(appId)
  if not found:
    raise t.envError("window", "no window with app id " & appId.escape)
  w

proc waitWindow*(t: TargetEnvironment; appId: string;
                 timeout = initDuration(seconds = 20);
                 until: proc(w: EnvWindow): bool = nil): EnvWindow =
  ## Wait until a window with this app id exists (and, given `until`,
  ## satisfies it). Raises `EnvError` with the last state seen on timeout.
  let deadline = epochTime() + timeout.inMilliseconds.float / 1000
  var last = "never appeared"
  while true:
    let (found, w) = t.findWindow(appId)
    if found:
      if until == nil or until(w): return w
      last = "last seen " & $w.rect & " " & $w.states
    if epochTime() >= deadline:
      raise t.envError("waitWindow", "window " & appId.escape & " " & last &
                       " after " & $timeout)
    sleep(50)

proc waitUntil*(t: TargetEnvironment; what: string; cond: proc(): bool;
                timeout = initDuration(seconds = 10)) =
  ## Poll `cond` until it holds; `EnvError` naming `what` on timeout.
  let deadline = epochTime() + timeout.inMilliseconds.float / 1000
  while not cond():
    if epochTime() >= deadline:
      raise t.envError("waitUntil", what & " did not happen within " & $timeout)
    sleep(50)

proc press*(t: TargetEnvironment; button = pbLeft) = t.pointerButton(button, true)
proc release*(t: TargetEnvironment; button = pbLeft) = t.pointerButton(button, false)

proc click*(t: TargetEnvironment; p: (int, int); button = pbLeft) =
  t.pointerMove(p[0], p[1])
  t.press(button)
  t.release(button)

proc doubleClick*(t: TargetEnvironment; p: (int, int)) =
  ## Two left clicks well inside any desktop's double-click interval.
  t.click(p)
  sleep(60)
  t.click(p)

proc drag*(t: TargetEnvironment; src, dst: (int, int); steps = 12;
           stepMs = 16; button = pbLeft) =
  ## Press at `src`, move to `dst` in `steps` increments, release there.
  t.pointerMove(src[0], src[1])
  t.press(button)
  for i in 1 .. steps:
    t.pointerMove(src[0] + (dst[0] - src[0]) * i div steps,
                  src[1] + (dst[1] - src[1]) * i div steps)
    sleep(stepMs)
  t.release(button)

proc captureSettled*(t: TargetEnvironment; region: Rect; agree = 3;
                     intervalMs = 100;
                     timeout = initDuration(seconds = 10)): RgbImage =
  ## A capture taken once the region has stopped changing: `agree`
  ## consecutive grabs `intervalMs` apart are identical. A compositor lists
  ## a window as soon as it is MAPPED, a frame or more before its first
  ## frame is presented (measured on sway 1.11: black at once, painted by
  ## 300 ms), so a capture straight after `waitWindow` can be empty.
  let deadline = epochTime() + timeout.inMilliseconds.float / 1000
  var same = 1
  var last = t.capture(region)
  while same < agree:
    if epochTime() >= deadline:
      raise t.envError("captureSettled", "the region " & $region &
                       " did not settle within " & $timeout)
    sleep(intervalMs)
    let next = t.capture(region)
    if next.data == last.data: inc same
    else: same = 1
    last = next
  last

proc requireFacts*(t: TargetEnvironment; names: varargs[string]) =
  ## A scenario's declaration of what it cannot run without. Each fact is
  ## established now; one the target cannot establish fails the run by name.
  for n in names: discard t.fact(n)

proc boolFact*(t: TargetEnvironment; name: string): bool =
  let f = t.fact(name)
  case f.value
  of "true": true
  of "false": false
  else: raise t.envError("fact " & name, "not a boolean: " & f.value.escape)

proc pixel*(img: RgbImage; x, y: int): (uint8, uint8, uint8) =
  let i = (y * img.width + x) * 3
  (img.data[i], img.data[i + 1], img.data[i + 2])

proc decodePpm*(bytes: string): RgbImage =
  ## Decode a binary PPM (P6, maxval 255) — what `grim -t ppm` writes.
  ## Netpbm format: https://netpbm.sourceforge.net/doc/ppm.html
  var pos = 0
  proc token(): string =
    while pos < bytes.len:
      if bytes[pos] == '#':
        while pos < bytes.len and bytes[pos] != '\n': inc pos
      elif bytes[pos] in Whitespace: inc pos
      else: break
    let start = pos
    while pos < bytes.len and bytes[pos] notin Whitespace: inc pos
    bytes[start ..< pos]
  if token() != "P6": raise newException(ValueError, "not a binary PPM")
  let w = parseInt(token())
  let h = parseInt(token())
  if parseInt(token()) != 255: raise newException(ValueError, "PPM maxval is not 255")
  inc pos  # the single whitespace byte after maxval
  if bytes.len - pos < w * h * 3:
    raise newException(ValueError, "PPM is truncated")
  result = RgbImage(width: w, height: h, data: newSeq[uint8](w * h * 3))
  for i in 0 ..< w * h * 3: result.data[i] = uint8(bytes[pos + i])
