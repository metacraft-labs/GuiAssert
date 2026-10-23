## What the Linux input backends share at run time: their configuration,
## running a GuiAssert input helper with its script on standard input, and
## turning a helper's answer into the contract's errors.
##
## **The display server is the invocation's**, as for the capture backends
## (`backends/capture/linux_common`): a helper runs with the invocation's
## environment, never with this process's own.
##
## **The script goes to standard input**, through a pipe, and nowhere else:
## not the command line (other users read argv in the process table), not a
## file. The helper's own output is read into memory; an error message quotes
## only its result line, which names an event kind or a coordinate, never a
## keysym or typed text (spec §7.5, captured content).
##
## **Cancellation** (spec §8.6) stops the helper with SIGTERM: it releases
## every button and key it still holds before it exits, so a cancelled drag
## never leaves the button down. A helper that does not exit within
## `stopGraceMs` is killed.

import std/[os, posix, strutils, tables]

import ../../core/[geometry, desktop_types, interfaces]
import ../../cancel
import ../capture/linux_common as capture_common

export capture_common.feature, capture_common.lastLine, capture_common.unavailableWith,
  capture_common.unavailableReason

const
  helperBaseTimeoutMs* = 30_000
    ## Bound on a helper run beyond the waits its script plans.
  stopGraceMs = 2_000

type
  LinuxInputConfig* = object
    ## What a Linux input backend runs with.
    stateDir*: string
    token*: CancelToken
    env*: Table[string, string]
      ## The invocation's environment (the display server, the session bus,
      ## the `PATH` tools are found on).
    displays*: proc (): seq[Display] {.closure.}
      ## The session's displays, from its capture backend (linux-uinput
      ## spans its absolute pointer over them). Nil: unknown.
    windows*: proc (): seq[Window] {.closure.}
      ## The session's windows, from its capture backend: the window
      ## `window-focus` and `window-set-bounds` report after the change.

  HelperRun* = object
    code*: int               ## exit status; 128 + signal when killed
    line*: string            ## the first line of its standard output
    output*: string          ## all of its standard output

proc captureCfg*(cfg: LinuxInputConfig): LinuxCaptureConfig =
  ## The same invocation as the capture backends' configuration, for their
  ## tool and helper lookup.
  LinuxCaptureConfig(stateDir: cfg.stateDir, token: cfg.token, env: cfg.env)

proc inputFailed*(backend, msg: string): ref BackendError =
  ## Exit 5 / `input-failed`.
  newBackendError(BackendError, backend, "input-failed", msg)

proc helperPath*(cfg: LinuxInputConfig, backend, name: string): string =
  cfg.captureCfg.helperPath(backend, name)

proc envBlock(env: Table[string, string]): cstringArray =
  var pairs: seq[string]
  for k, v in env: pairs.add k & "=" & v
  allocCStringArray(pairs)

const helperOutputMax = 1 shl 20
  ## What of a helper's standard output is kept; the rest is read and
  ## dropped, so a helper never blocks on a full pipe.

proc drainFd(fd: cint, into: var string): bool =
  ## Read what `fd` (non-blocking) holds now into `into`, up to
  ## `helperOutputMax`. False once the writer closed its end.
  var buf: array[4096, char]
  while true:
    let n = posix.read(fd, addr buf[0], buf.len)
    if n > 0:
      let keep = min(int(n), helperOutputMax - into.len)
      if keep > 0:
        let old = into.len
        into.setLen(old + keep)
        copyMem(addr into[old], addr buf[0], keep)
    elif n == 0:
      return false
    else:
      return errno == EAGAIN or errno == EWOULDBLOCK or errno == EINTR

proc runHelper*(cfg: LinuxInputConfig, backend: string, argv: seq[string], input: string,
                timeoutMs: int): HelperRun =
  ## Run helper `argv` (its first element an absolute path) with `input` on
  ## its standard input and the invocation's environment, and wait for it:
  ## at most `timeoutMs`, never past the invocation's deadline. A
  ## cancellation or the deadline stops it (module doc) and raises the
  ## token's error; a timeout is exit 5 / `input-failed`. Its input is
  ## written and its output read at the same time (`poll`), so a helper
  ## that answers line by line (`wayland_input keysyms`) never deadlocks on
  ## two full pipes, however long the input.
  cfg.token.checkpoint()
  var inPipe, outPipe: array[2, cint]
  if pipe(inPipe) != 0: raise inputFailed(backend, "pipe failed: " & osErrorMsg(osLastError()))
  if pipe(outPipe) != 0:
    discard posix.close(inPipe[0])
    discard posix.close(inPipe[1])
    raise inputFailed(backend, "pipe failed: " & osErrorMsg(osLastError()))
  for fd in [inPipe[1], outPipe[0]]:
    discard fcntl(fd, F_SETFD, FD_CLOEXEC)
    discard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) or O_NONBLOCK)
  let args = allocCStringArray(argv)
  let envp = envBlock(cfg.env)
  let pid = fork()
  if pid == 0:
    discard dup2(inPipe[0], 0)
    discard dup2(outPipe[1], 1)
    let devnull = posix.open("/dev/null", O_WRONLY)
    if devnull >= 0: discard dup2(devnull, 2)
    var maxFd = sysconf(SC_OPEN_MAX)
    if maxFd < 0 or maxFd > 65536: maxFd = 65536
    for fd in 3 ..< int(maxFd): discard posix.close(cint(fd))
    discard execve(argv[0].cstring, args, envp)
    exitnow(127)
  deallocCStringArray(args)
  deallocCStringArray(envp)
  discard posix.close(inPipe[0])
  discard posix.close(outPipe[1])
  if pid < 0:
    discard posix.close(inPipe[1])
    discard posix.close(outPipe[0])
    raise inputFailed(backend, "fork failed: " & osErrorMsg(osLastError()))
  var status: cint
  var exited = false
  var outOpen = true
  try:
    # A helper that exits early (no display) closes its end: the write then
    # fails with EPIPE, which is not an error here, its status says why.
    signal(SIGPIPE, SIG_IGN)
    var off = 0
    if input.len == 0:
      discard posix.close(inPipe[1])
      inPipe[1] = -1
    let startNs = monoNowNs()
    while true:
      var fds: seq[TPollfd]
      if inPipe[1] >= 0: fds.add TPollfd(fd: inPipe[1], events: POLLOUT)
      if outOpen: fds.add TPollfd(fd: outPipe[0], events: POLLIN)
      if fds.len > 0: discard poll(addr fds[0], Tnfds(fds.len), 5)
      if inPipe[1] >= 0:
        let n = posix.write(inPipe[1], unsafeAddr input[off], input.len - off)
        if n > 0: off += n
        if off >= input.len or (n < 0 and errno notin [EAGAIN, EWOULDBLOCK, EINTR]):
          discard posix.close(inPipe[1])
          inPipe[1] = -1
      if outOpen: outOpen = drainFd(outPipe[0], result.output)
      let r = waitpid(pid, status, WNOHANG)
      if r == pid:
        exited = true
        break
      if r < 0 and errno != EINTR:
        raise inputFailed(backend, "waitpid failed: " & osErrorMsg(osLastError()))
      if elapsedMsSince(startNs) > timeoutMs:
        raise inputFailed(backend, argv[0].extractFilename & " did not finish within " &
          $timeoutMs & " ms")
      cfg.token.checkpoint()
      if fds.len == 0: cfg.token.sleepCancellable(5)
  finally:
    if inPipe[1] >= 0: discard posix.close(inPipe[1])
    if not exited:
      # Stopped between two events; it releases what it holds first.
      discard kill(pid, SIGTERM)
      let startNs = monoNowNs()
      while waitpid(pid, status, WNOHANG) != pid:
        if outOpen: outOpen = drainFd(outPipe[0], result.output)
        if elapsedMsSince(startNs) > stopGraceMs:
          discard kill(pid, SIGKILL)
          discard waitpid(pid, status, 0)
          break
        sleep(5)
    # What the helper wrote before it exited: all of it is in the pipe once
    # it is gone (a non-blocking read, so a stray writer cannot hang us).
    if outOpen: discard drainFd(outPipe[0], result.output)
    discard posix.close(outPipe[0])
  result.code = if WIFEXITED(status): int(WEXITSTATUS(status))
                else: 128 + int(WTERMSIG(status))
  result.line = result.output.splitLines()[0].strip
  if result.line.len > 300: result.line = result.line[0 ..< 300] & "…"

proc errorWords(line: string): tuple[word, rest: string] =
  ## `error <word> <rest>` of a helper's result line.
  let parts = line.split(' ', 2)
  if parts.len >= 2 and parts[0] == "error":
    (parts[1], (if parts.len > 2: parts[2] else: ""))
  else: ("", line)

proc raiseHelperFailure*(cfg: LinuxInputConfig, backend: string, r: HelperRun,
                         remedy: string) =
  ## Turn a failed helper run into the contract's error (exit status as in
  ## helpers/linux/input_script.h). Exit 8 (the helper was stopped) raises
  ## the token's error when the invocation was cancelled.
  let (word, rest) = errorWords(r.line)
  case r.code
  of 3:
    if word == "missing":
      raise newBackendError(BackendNotFoundError, backend, "window",
        "no window '" & rest & "' in this session")
    raise newBackendError(BackendNotFoundError, backend, "display",
      "no display of the session contains the point (" & rest.replace(" ", ", ") & ")")
  of 4:
    raise unavailableWith(backend, "display-server-unsupported",
      "cannot reach the display server: " & rest, remedy)
  of 5:
    raise unavailableWith(backend, "display-server-unsupported", rest, remedy)
  of 6:
    var e = newBackendError(PermissionDeniedError, backend, "uinput-access", rest)
    e.remedy = remedy
    raise e
  of 8, 128 + 15, 128 + 9:
    cfg.token.checkpoint()
    raise inputFailed(backend, "the input helper was stopped")
  of 127:
    raise unavailableWith(backend, "missing-tool", "the input helper could not be run",
      "run inside GuiAssert's `nix develop`, or set GUI_ASSERT_HELPER_DIR to the built helpers")
  else:
    raise inputFailed(backend, "the input helper failed (exit " & $r.code & "): " &
      (if rest.len > 0: rest else: r.line))

proc requireEnv*(cfg: LinuxInputConfig, backend: string, names: openArray[string],
                 what, remedy: string) =
  ## Exit 4 / `display-server-unsupported` when a variable of `names` is
  ## unset: there is no session of the kind the backend drives.
  for k in names:
    if cfg.env.getOrDefault(k, "").len == 0:
      raise unavailableWith(backend, "display-server-unsupported",
        k & " is not set: no " & what & " to send input to", remedy)

proc windowById*(cfg: LinuxInputConfig, backend, id: string): Window =
  ## The window `id` as the session's capture backend reports it now.
  if cfg.windows == nil:
    raise unavailableWith(backend, "display-server-unsupported",
      "the session's windows cannot be enumerated", "select the capture backend of the " &
      "session's compositor")
  for w in cfg.windows():
    if w.id == id: return w
  raise newBackendError(BackendNotFoundError, backend, "window",
    "no window '" & id & "' in this session")

proc inputFeatures*(backend: string, pointer, keyboard, windows: tuple[state: FeatureState,
                    reason, remedy: string]): seq[Feature] =
  @[feature(backend, "pointer-input", pointer.state, pointer.reason, pointer.remedy),
    feature(backend, "keyboard-input", keyboard.state, keyboard.reason, keyboard.remedy),
    feature(backend, "window-management", windows.state, windows.reason, windows.remedy)]

proc problemOf*(e: ref BackendError): tuple[state: FeatureState, reason, remedy: string] =
  ## A feature made unavailable by `e`.
  (fsUnavailable, unavailableReason(e), (if e.remedy.len > 0: e.remedy else: e.msg))

proc wrongPlatformInput*(backend: string): InputBackend =
  ## The backend on a platform it does not run on (spec §3.3).
  proc no(): ref BackendUnavailableError =
    unavailable(backend, "wrong-platform", "the " & backend & " input backend runs on Linux only")
  result.name = backend
  result.move = proc (s: string, p: Point): InputReport = raise no()
  result.click = proc (s: string, p: Point, b: MouseButton, c: int,
                       m: seq[string]): InputReport = raise no()
  result.drag = proc (s: string, p: seq[Point], b: MouseButton, st, d: int): InputReport =
    raise no()
  result.scroll = proc (s: string, p: Point, dx, dy: int, u: ScrollUnit): InputReport =
    raise no()
  result.typeText = proc (s, t: string, i: int): InputReport = raise no()
  result.key = proc (s, c: string): InputReport = raise no()
  result.focusWindow = proc (s, w: string): Window = raise no()
  result.setWindowBounds = proc (s, w: string, r: Rect): Window = raise no()
  result.features = proc (probe: bool): seq[Feature] =
    let p = (fsUnavailable, "wrong-platform", "")
    inputFeatures(backend, p, p, p)

proc settledWindow*(cfg: LinuxInputConfig, backend, id: string,
                    done: proc (w: Window): bool {.closure.},
                    timeoutMs = 3_000): Window =
  ## The window `id` once `done` holds for it (a compositor applies a focus
  ## or a new placement asynchronously: the client has to commit it), or as
  ## it is when `timeoutMs` passes: the report is what the window server
  ## says, which may differ from what was asked (spec §7.5).
  let startNs = monoNowNs()
  while true:
    result = cfg.windowById(backend, id)
    if done(result) or elapsedMsSince(startNs) > timeoutMs: return
    cfg.token.sleepCancellable(30)
