## Running an OCR engine's subprocess: bounded, cancellable, and with the
## engine's diagnostics kept away from GuiAssert's own output.
##
## Both subprocess engines (`tesseract`, and the Apple Vision helper behind
## `apple-vision`) write their **result to a file** in a private temporary
## directory, never to the pipe this module reads, so the pipe carries only
## the engine's diagnostics (stdout and stderr merged). Recognized text
## therefore never travels through a stream GuiAssert could echo, and the
## diagnostics — which name paths, codes and errors — are used only to build
## the message of a failure (spec §7.5, "Captured content", C15). Nothing here
## writes to GuiAssert's stderr.
##
## The child is polled rather than waited for, so a cancellation or the
## `--timeout-ms` deadline of the token (`gui_assert/cancel`) stops it within
## a few milliseconds; a child still running at `timeoutMs` is killed. The
## diagnostics are read once the child has exited, which assumes they fit in
## the pipe buffer (64 KiB on macOS and Linux): both engines print a few lines
## at most, and a child that blocked on a full pipe would be killed at the
## timeout rather than hang GuiAssert.

import std/[os, osproc, streams, strtabs, strutils, tempfiles]

import ../../core/[contract, interfaces]
import ../../cancel

const maxDiagnosticBytes* = 2048
  ## How much of an engine's diagnostics a failure message carries.

type
  EngineRun* = object
    ## The outcome of one engine run that started and exited.
    code*: int
    diagnostics*: string      ## stdout and stderr merged, trimmed, capped

proc firstLines*(diag: string, maxBytes = maxDiagnosticBytes): string =
  ## `diag` stripped and cut to `maxBytes`, for a message.
  result = diag.strip
  if result.len > maxBytes: result = result[0 ..< maxBytes] & "…"

proc runEngine*(backend, exe: string, args: seq[string], token: CancelToken,
                timeoutMs: int, env: StringTableRef = nil,
                diagnosticCap = maxDiagnosticBytes): EngineRun =
  ## Run `exe` with `args` until it exits and return its exit code and
  ## diagnostics. Raises the `cancelled` / `timeout` contract error when
  ## `token` (which may be nil) is cancelled or past its deadline, and
  ## `BackendError` (`ocr-failed`) when the process cannot be started or
  ## outlives `timeoutMs`; the child is killed and reaped in every case.
  ## `diagnosticCap` bounds the diagnostics kept (a listing mode that prints
  ## its answer, such as `tesseract --list-langs`, raises it).
  var p: Process
  try:
    p = startProcess(command = exe, args = args, env = env,
                     options = {poStdErrToStdOut})
  except OSError as e:
    raise newBackendError(BackendError, backend, "ocr-failed",
      "cannot start " & exe & ": " & e.msg)
  var stopped = false
  proc stop() =
    if not stopped:
      stopped = true
      try:
        p.kill()
        discard p.waitForExit()
      except OSError: discard
  try:
    let started = monoNowNs()
    while p.running:
      if token != nil:
        try: token.checkpoint()
        except ContractError:
          stop()
          raise
      if elapsedMsSince(started) > timeoutMs:
        stop()
        raise newBackendError(BackendError, backend, "ocr-failed",
          exe.extractFilename & " did not finish within " & $timeoutMs & " ms")
      sleep(5)
    result.code = p.waitForExit()
    var diag = ""
    try: diag = p.outputStream().readAll()
    except IOError, OSError: discard
    result.diagnostics = firstLines(diag, diagnosticCap)
  finally:
    if not stopped and p.running: stop()
    p.close()

proc canonicalPath*(path: string): string =
  ## `path` absolute with every symlink resolved, when it exists. The pinned
  ## tesseract's leptonica cannot open an image whose path traverses a
  ## symlink (macOS `/tmp` -> `private/tmp`), so engines are handed physical
  ## paths. A path that cannot be resolved is returned absolute, unchanged.
  result = absolutePath(path)
  when defined(posix):
    proc realpath(name: cstring, resolved: cstring): cstring {.importc,
      header: "<stdlib.h>".}
    var buf = newString(4096)
    if realpath(cstring(result), cstring(buf)) != nil:
      result = $cstring(buf)

proc privateTempDir*(backend, prefix: string): string =
  ## A fresh directory only this user can read, for an engine's result file
  ## (recognized text is captured content). The caller removes it.
  try:
    result = createTempDir(prefix, "")
    setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})
  except OSError, IOError:
    raise newBackendError(BackendError, backend, "ocr-failed",
      "cannot create a temporary directory: " & getCurrentExceptionMsg())
  result = canonicalPath(result)
