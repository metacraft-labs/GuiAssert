## Shared support of the macOS live suites (`tests/live/tcapture_macos.nim`,
## `tests/live/tocr_macos.nim`): the environment a live run uses, the AppKit
## fixture application (`fixtures/solid_window.swift`, compiled at test time),
## running the real `guiassert`, and the gate that tells a working live
## session from a missing grant or a locked screen.
##
## The gate never skips: `gated` FAILS a test that needs live capture where
## it does not work, with a `BLOCKED:` line naming why (spec §9.4).

import std/[json, os, osproc, sequtils, strtabs, strutils, unittest, times]

import ../contract/harness
import ../../src/gui_assert/swift_helper

const fixtureSrc = currentSourcePath().parentDir / "fixtures" / "solid_window.swift"

# ---------------------------------------------------------------------------
# Environment and the fixture application
# ---------------------------------------------------------------------------

proc liveEnv*(stateDir: string, extra: openArray[(string, string)] = []): StringTableRef =
  ## The caller's environment without GUIASSERT_* variables (harness rule),
  ## except the capture bundle's own GUIASSERT_CAPTURE_* settings, which
  ## decide which identity holds the grant; plus the state directory.
  result = baseEnv()
  for k, v in envPairs():
    if k.startsWith("GUIASSERT_CAPTURE_"): result[k] = v
  result["GUIASSERT_STATE_DIR"] = stateDir
  for (k, v) in extra: result[k] = v

type
  Fixture* = object
    ## One running fixture window, as its ready file describes it.
    process*: Process
    pid*: int
    window*: string
    bounds*: seq[int]        ## the window's frame, desktop points
    label*: seq[int]         ## the label's rect, desktop points; @[] without one
    title*: string
    ready*: string

proc readReady*(f: var Fixture) =
  for line in readFile(f.ready).splitLines:
    let kv = line.split('=', 1)
    if kv.len != 2: continue
    case kv[0]
    of "pid": f.pid = parseInt(kv[1])
    of "window": f.window = kv[1]
    of "bounds": f.bounds = kv[1].split(',').mapIt(parseInt(it))
    of "label": f.label = kv[1].split(',').mapIt(parseInt(it))

proc currentBounds*(f: var Fixture): seq[int] =
  ## The window's frame as the fixture reports it now (a window manager may
  ## have moved or resized it since it opened).
  f.readReady()
  f.bounds

proc near*(a, b: seq[int], slack: int): bool =
  a.len == b.len and (block:
    var ok = true
    for i in 0 ..< a.len:
      if abs(a[i] - b[i]) > slack: ok = false
    ok)

proc fixtureBin*(): string =
  compileSwiftHelper("gui_assert_live_fixture", "solid_window", fixtureSrc)

proc launchFixture*(title: string, rect: array[4, int], rgb: array[3, int],
                   floating = false, label = "", labelAt = [20, 20],
                   labelSize = 40): Fixture =
  ## Start one fixture window and wait until it reports itself on screen.
  ## With `label`, the window shows that text in black at `labelAt` (window
  ## points) in the system font at `labelSize` points, and `Fixture.label`
  ## is its on-screen rect.
  let dir = freshDir("fixture")
  let ready = dir / "ready"
  var args = @["--title", title, "--rect", rect.mapIt($it).join(","),
               "--rgb", rgb.mapIt($it).join(","), "--ready", ready,
               "--level", (if floating: "floating" else: "normal")]
  if label.len > 0:
    args.add ["--label", label, "--label-at", labelAt.mapIt($it).join(","),
              "--label-size", $labelSize]
  result.process = startProcess(fixtureBin(), args = args, options = {})
  result.title = title
  let deadline = epochTime() + 20.0
  while not fileExists(ready):
    if not result.process.running:
      raise newException(IOError, "the fixture app exited with " &
        $result.process.peekExitCode & " before its window was ready")
    if epochTime() > deadline:
      result.process.kill()
      raise newException(IOError, "the fixture app did not open its window within 20 s")
    sleep(50)
  result.ready = ready
  sleep(500)   # let the window server composite, and a window manager settle
  result.readReady()
  doAssert result.pid == result.process.processID

proc stop*(f: var Fixture) =
  if f.process != nil:
    if f.process.running:
      f.process.terminate()
      discard f.process.waitForExit(5000)
      if f.process.running: f.process.kill()
    f.process.close()
    f.process = nil

proc nonce*(): string = "Fx" & $getCurrentProcessId() & "q" & $(epochTime() * 1000).int64

# ---------------------------------------------------------------------------
# Running the binary
# ---------------------------------------------------------------------------

proc run*(args: seq[string], env: StringTableRef, timeoutMs = 90_000):
    tuple[exit: int, env: JsonNode, stderr: string] =
  let r = runCli(args, env, timeoutMs = timeoutMs)
  (r.exit, envelopeOf(r), r.stderr)

proc ok*(args: seq[string], env: StringTableRef): JsonNode =
  let (x, e, err) = run(args, env)
  if x != 0:
    checkpoint "guiassert " & args.join(" ") & " -> " & $e & "\nstderr: " & err
  doAssert x == 0, "guiassert " & args.join(" ") & " exited " & $x & ": " & $e
  e["data"]

# ---------------------------------------------------------------------------
# The gate: positive control, grant, unlocked screen
# ---------------------------------------------------------------------------

type Gate = object
  checked: bool
  blocked: string    ## "" when live capture works

var gate: Gate

proc grantClickPath*(): string =
  "System Settings > Privacy & Security > Screen & System Audio Recording, " &
  "click +, press Shift-Cmd-G, paste ~/Library/Application Support/GuiAssert/" &
  "GuiAssertCapture.app, click Open and switch it on"

proc liveGate*(): string =
  ## "" when live capture works here, else the BLOCKED line. Runs the
  ## unprivileged positive control first, so "no permission" and "nothing
  ## works" are told apart.
  if gate.checked: return gate.blocked
  gate.checked = true
  let st = freshDir("gate")
  let env = liveEnv(st)
  let (cx, ce, _) = run(@["--capture-backend", "macos-cgwindow", "windows",
                          "--all-layers"], env)
  if cx != 0 or ce["data"]["windows"].len == 0:
    gate.blocked = "BLOCKED: no GUI session (the unprivileged window enumeration " &
      "failed: " & $ce & ")"
    return gate.blocked
  let caps = ok(@["capabilities", "--probe"], env)
  let sr = caps["permissions"]["screenRecording"].getStr
  if sr != "granted":
    gate.blocked = "BLOCKED: TCC Screen Recording for " &
      caps["permissions"]["identity"].getStr & " (screenRecording: " & sr & "). " &
      grantClickPath()
    return gate.blocked
  let (sx, se, _) = run(@["screenshot", "--out", st / "gate.png"], env)
  if sx != 0:
    let msg = se["error"]["message"].getStr
    gate.blocked =
      if "screen is locked" in msg: "BLOCKED: the GUI session is locked (" & msg & ")"
      else: "BLOCKED: a display capture failed with exit " & $sx & ": " & msg
  gate.blocked

template gated*(body: untyped) =
  ## Run `body` only where live capture works; elsewhere FAIL with the
  ## BLOCKED line (never skip).
  let blocked = liveGate()
  if blocked.len > 0:
    checkpoint blocked
    echo "  ", blocked
    fail()
  else:
    body
