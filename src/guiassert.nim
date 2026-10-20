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

import gui_assert/cancel
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

proc main(): int =
  let argv = commandLineParams()
  if argv.len >= 1 and argv[0] == "__session-host":
    # Internal, non-contract: the detached owner of a fixture session.
    if argv.len != 4 or argv[1] != "--state-dir":
      stderr.writeLine("usage: guiassert __session-host --state-dir <dir> <id>")
      return 2
    return runFixtureSessionHost(argv[2], argv[3])
  if argv.len == 1 and argv[0] == "--help":
    stdout.write(help())
    return 0
  processToken = newCancelToken()
  when defined(posix):
    signal(SIGINT, onSignal)
    signal(SIGTERM, onSignal)
  let ctx = RunContext(env: envSnapshot(), cwd: getCurrentDir(),
                       selfExe: getAppFilename(), token: processToken)
  if findVerbToken(argv) == "serve":
    return serveMain(argv, ctx, processToken)
  let o = runInvocation(argv, ctx)
  stdout.writeLine(o.line)
  stdout.flushFile()
  o.exit

when isMainModule:
  quit(main())
