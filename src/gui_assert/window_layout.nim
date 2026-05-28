## GuiAssert window-launch / positioning helpers
##
## Cross-platform-ish wrappers around the OS-native primitives we need
## to spawn a GUI window at a known screen location.  The current
## implementation targets macOS only: `open -n -a <app>` to launch and
## AppleScript (`osascript -e ...`) for window positioning.  A future
## revision will fold in `wmctrl`/`xdotool` on Linux and PowerShell
## on Windows; the API is intentionally OS-neutral so callers don't
## have to branch.
##
## ### Why shell out instead of using FFIs?
##
## The recorder runs in two contexts: developer-local foreground mode
## (where shelling out is fast enough and lets us keep zero compile-
## time dependencies) and CI background mode (where we already shell
## to `ffmpeg`/`xvfb-run`/`osascript` everywhere else).  A native
## CGEvent / AppKit binding would be ~500 lines of Objective-C FFI
## glue; the shell approach is ~150 lines of pure-Nim string
## construction with high test coverage.
##
## ### Race conditions
##
## `open -n -a` returns as soon as the launcher has handed off the
## request; the window itself can take 0-3 seconds to appear in the
## window server.  We poll for the new PID with a configurable
## timeout (default 5 s) and fail loudly if the window never appears.

import std/[osproc, strutils, os, streams, times]

type
  WindowSpec* = object
    ## Description of the window the caller wants to launch.
    ##
    ## `bundleIdOrPath` is either a macOS bundle identifier (e.g.
    ## `"com.apple.Terminal"`) or an absolute filesystem path to a
    ## `.app` bundle (e.g. `"/Applications/Visual Studio Code.app"`)
    ## or to an executable.
    bundleIdOrPath*: string
    args*: seq[string]
    x*: int
    y*: int
    width*: int
    height*: int

  WindowHandle* = ref object
    ## Live handle to a launched window.  `pid` is the PID returned by
    ## `pgrep` after the launch race resolves; `bundleId` is the
    ## bundle id (may be empty if the caller passed a raw path).
    pid*: int
    bundleId*: string
    appPath*: string

  WindowLayoutError* = object of CatchableError
    ## Raised on any subprocess failure or window-positioning error.

# ---------------------------------------------------------------------------
# AppleScript command builders (pure, easy to test)
# ---------------------------------------------------------------------------

proc applescriptEscape*(s: string): string =
  ## Escape a string for embedding inside a double-quoted AppleScript
  ## literal.  Backslashes and double quotes need to be escaped.
  result = newStringOfCap(s.len + 4)
  for ch in s:
    case ch
    of '\\': result.add "\\\\"
    of '"':  result.add "\\\""
    else:    result.add ch

proc buildSetBoundsScript*(bundleIdOrName: string,
                            x, y, w, h: int): string =
  ## Build the AppleScript that sets the bounds of the front window of
  ## `bundleIdOrName`.  Exposed so tests can verify the exact wire
  ## format without invoking `osascript`.
  ##
  ## We address the process by `id` when the input looks like a bundle
  ## id (contains a dot) and by `name` otherwise.  AppleScript uses
  ## `{x1, y1, x2, y2}` so we compute the bottom-right corner from the
  ## width/height the caller provided.
  let x2 = x + w
  let y2 = y + h
  if '.' in bundleIdOrName:
    # Bundle id path: target System Events by `unix id` is fragile, so
    # use the `tell application id` form which AppleScript supports.
    result = "tell application id \"" & applescriptEscape(bundleIdOrName) &
      "\" to set bounds of front window to {" &
      $x & ", " & $y & ", " & $x2 & ", " & $y2 & "}"
  else:
    result = "tell application \"" & applescriptEscape(bundleIdOrName) &
      "\" to set bounds of front window to {" &
      $x & ", " & $y & ", " & $x2 & ", " & $y2 & "}"

proc buildOpenArgv*(spec: WindowSpec): seq[string] =
  ## Build the `open` argv for launching the requested app with
  ## `-n` (force new instance) and forwarding `args` via `--args`.
  ## Public so tests can assert the exact subprocess invocation.
  result = @["-n"]
  if spec.bundleIdOrPath.startsWith("/"):
    result.add "-a"
    result.add spec.bundleIdOrPath
  elif '.' in spec.bundleIdOrPath and "/" notin spec.bundleIdOrPath:
    result.add "-b"
    result.add spec.bundleIdOrPath
  else:
    result.add "-a"
    result.add spec.bundleIdOrPath
  if spec.args.len > 0:
    result.add "--args"
    for a in spec.args:
      result.add a

# ---------------------------------------------------------------------------
# Subprocess helpers
# ---------------------------------------------------------------------------

proc runOsascript(script: string): tuple[output: string, code: int] =
  ## Run `osascript -e '<script>'` and return the trimmed output + exit
  ## code.  Raises `WindowLayoutError` if `osascript` is missing.
  let bin = findExe("osascript")
  if bin.len == 0:
    raise newException(WindowLayoutError,
      "osascript not found on PATH (required for macOS window layout)")
  let p = startProcess(
    command = bin,
    args = @["-e", script],
    options = {poStdErrToStdOut})
  let combined = p.outputStream().readAll()
  let code = p.waitForExit()
  p.close()
  return (combined.strip(), code)

proc runOpen(argv: seq[string]): tuple[output: string, code: int] =
  let bin = findExe("open")
  if bin.len == 0:
    raise newException(WindowLayoutError,
      "open(1) not found on PATH (required for macOS launch)")
  let p = startProcess(
    command = bin,
    args = argv,
    options = {poStdErrToStdOut})
  let combined = p.outputStream().readAll()
  let code = p.waitForExit()
  p.close()
  return (combined.strip(), code)

proc pgrepByBundle(bundleId: string): int =
  ## Resolve a bundle id to a freshly running PID via `pgrep -n`.
  ## Returns -1 if no match is found.  We use `-n` so we pick the
  ## newest process (the one we just spawned with `open -n`).
  let pgrep = findExe("pgrep")
  if pgrep.len == 0:
    return -1
  # `pgrep` matches by process name, not by bundle id directly.  We
  # extract the trailing label of the bundle (`com.apple.Terminal` →
  # `Terminal`) which matches the executable name AppKit uses.
  var procName = bundleId
  let lastDot = bundleId.rfind('.')
  if lastDot >= 0:
    procName = bundleId[lastDot + 1 .. ^1]
  let p = startProcess(
    command = pgrep,
    args = @["-n", procName],
    options = {poStdErrToStdOut})
  let buf = p.outputStream().readAll().strip()
  discard p.waitForExit()
  p.close()
  if buf.len == 0:
    return -1
  try:
    return parseInt(buf.splitLines()[0].strip())
  except ValueError:
    return -1

proc waitForPid(bundleId: string, timeoutMs: int = 5000): int =
  ## Poll `pgrepByBundle` until a PID is found or the timeout expires.
  let deadline = epochTime() + float(timeoutMs) / 1000.0
  while true:
    let pid = pgrepByBundle(bundleId)
    if pid > 0:
      return pid
    if epochTime() >= deadline:
      return -1
    sleep(100)

proc deriveBundleId(bundleIdOrPath: string): string =
  ## If the input is a bundle id, return it as-is; otherwise derive a
  ## proc-name fallback from the file basename (Visual Studio Code →
  ## Code, Terminal.app → Terminal).  Used by `terminate`.
  if '.' in bundleIdOrPath and "/" notin bundleIdOrPath:
    return bundleIdOrPath
  var base = bundleIdOrPath.lastPathPart
  if base.endsWith(".app"):
    base = base[0 ..< base.len - 4]
  return base

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc launchWindow*(spec: WindowSpec): WindowHandle =
  ## Spawn the requested window and return a `WindowHandle` once it has
  ## materialised on the window server (or the 5-second poll timeout
  ## elapses, at which point a `WindowLayoutError` is raised).
  ##
  ## After the window appears we issue `setBounds` to put it where the
  ## caller asked.  Callers that do not care about positioning can
  ## leave `width`/`height` at zero and we will skip the positioning
  ## step.
  let argv = buildOpenArgv(spec)
  let (output, code) = runOpen(argv)
  if code != 0:
    raise newException(WindowLayoutError,
      "open failed (" & $code & "): " & output)
  let label = deriveBundleId(spec.bundleIdOrPath)
  let pid = waitForPid(label)
  if pid < 0:
    raise newException(WindowLayoutError,
      "window did not appear within 5s after launching " &
      spec.bundleIdOrPath)
  result = WindowHandle(
    pid: pid,
    bundleId: label,
    appPath: spec.bundleIdOrPath,
  )
  if spec.width > 0 and spec.height > 0:
    let script = buildSetBoundsScript(
      label, spec.x, spec.y, spec.width, spec.height)
    let (osOut, osCode) = runOsascript(script)
    if osCode != 0:
      raise newException(WindowLayoutError,
        "osascript setBounds failed (" & $osCode & "): " & osOut)

proc setBounds*(h: WindowHandle, x, y, w, hgt: int) =
  ## Move/resize the window via AppleScript.  Raises
  ## `WindowLayoutError` if `osascript` fails.
  let script = buildSetBoundsScript(h.bundleId, x, y, w, hgt)
  let (osOut, osCode) = runOsascript(script)
  if osCode != 0:
    raise newException(WindowLayoutError,
      "osascript setBounds failed (" & $osCode & "): " & osOut)

proc terminate*(h: WindowHandle) =
  ## Politely terminate the window's process.  We try `kill <pid>`
  ## first (SIGTERM) so apps get a chance to flush state; callers
  ## that need a hard kill can send their own SIGKILL.
  if h.pid <= 0:
    return
  let killBin = findExe("kill")
  if killBin.len == 0:
    raise newException(WindowLayoutError,
      "kill(1) not found on PATH (cannot terminate window)")
  let p = startProcess(
    command = killBin,
    args = @[$h.pid],
    options = {poStdErrToStdOut})
  discard p.waitForExit()
  p.close()
  h.pid = -1
