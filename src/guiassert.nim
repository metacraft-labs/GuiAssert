## `guiassert`: the desktop-substrate program (contract `guiassert-desktop/1`).
##
## A thin `main` over the library in `gui_assert/cli`: it snapshots the
## environment, installs the SIGINT / SIGTERM handler that cancels the
## running verb (exit 8 / `signal`) or shuts the daemon down, and prints the
## one envelope line `runInvocation` returns. Everything else, including
## `serve`, is library code a Nim program can call directly.
##
## Built twice (`just build-cli`): `guiassert` with every backend for the
## target OS, and `guiassert-fixture` with `-d:guiassertMinimal` (the core and
## the fixture backends only, spec §9.2).

import std/[os, tables]

when defined(posix):
  import std/posix

import gui_assert/[cancel, state_store]
import gui_assert/cli/[args, context, run, serve]
import gui_assert/backends/session/fixture as session_fixture

var processToken: CancelToken
  ## The one global of the program: the token the signal handler cancels.
  ## A signal handler can reach nothing else, and it lives here, in the
  ## executable, not in the library.

when defined(posix):
  proc onSignal(sig: cint) {.noconv.} =
    if processToken != nil: processToken.cancel(crSignal)

proc envSnapshot(): Table[string, string] =
  for k, v in envPairs(): result[k] = v

proc readProcessStdin(maxBytes: int): string =
  ## The program's standard input, whole and exactly as given, for
  ## `type --stdin` / `element-action --value-stdin`. Refuses more than
  ## `maxBytes` (`FileTooLargeError`) instead of reading without bound.
  ## On POSIX the read waits in short `poll` slices and calls `checkpoint`
  ## between them, so a writer that never closes the pipe (or a terminal)
  ## cannot hold the verb past `--timeout-ms` or a signal (spec §7.1).
  var buf: array[65536, char]
  while true:
    when defined(posix):
      var pfd = TPollfd(fd: 0, events: POLLIN)
      processToken.checkpoint()
      let ready = posix.poll(addr pfd, 1, 50)
      if ready < 0:
        if errno == EINTR: continue
        raise newException(IOError, "poll: errno " & $errno & " `" & $strerror(errno) & "`")
      if ready == 0: continue
      let n = posix.read(0, addr buf[0], buf.len)
      if n < 0:
        if errno == EINTR: continue
        raise newException(IOError, "errno: " & $errno & " `" & $strerror(errno) & "`")
    else:
      let n = stdin.readBuffer(addr buf[0], buf.len)
    if n <= 0: break
    if result.len + n > maxBytes:
      raise newException(FileTooLargeError, "standard input is larger than the limit of " &
        $maxBytes & " bytes")
    for i in 0 ..< n: result.add buf[i]

proc main(): int =
  let argv = commandLineParams()
  if argv.len >= 1 and argv[0] == "__session-host":
    # Internal, non-contract: the detached owner of a fixture session.
    if argv.len notin 4..5 or argv[1] != "--state-dir":
      stderr.writeLine("usage: guiassert __session-host --state-dir <dir> <id> [<mode>]")
      return 2
    return runFixtureSessionHost(argv[2], argv[3], (if argv.len == 5: argv[4] else: ""))
  if argv.len == 1 and argv[0] == "--help":
    stdout.write(help())
    return 0
  processToken = newCancelToken()
  when defined(posix):
    signal(SIGINT, onSignal)
    signal(SIGTERM, onSignal)
  let ctx = RunContext(env: envSnapshot(), cwd: getCurrentDir(),
                       selfExe: getAppFilename(), token: processToken,
                       stdin: readProcessStdin)
  if findVerbToken(argv) == "serve":
    # The daemon's stdin is its protocol stream, never a verb's input.
    var serveCtx = ctx
    serveCtx.stdin = nil
    return serveMain(argv, serveCtx, processToken)
  let o = runInvocation(argv, ctx)
  stdout.writeLine(o.line)
  stdout.flushFile()
  o.exit

when isMainModule:
  quit(main())
