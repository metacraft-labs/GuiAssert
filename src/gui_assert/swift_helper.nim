## GuiAssert shared Swift-helper toolchain
##
## Two GuiAssert backends shell out to a small Swift binary that is compiled on
## demand rather than vendored: the Apple Vision OCR helper
## (`helpers/vision_ocr.swift`, behind `ocr.obAppleVision`) and the
## ScreenCaptureKit still-capture helper (`helpers/screen_capture.swift`, behind
## `screen_capture.nim`). This module owns the one thing both need and neither
## should own privately: locating `swiftc` and compiling against the **system**
## SDK.
##
## Why the environment has to be sanitized: a nix profile commonly exports
## `SDKROOT` / `DEVELOPER_DIR` pointing at a nix-provided Apple SDK whose Swift
## version does not match the system `/usr/bin/swiftc`. The compile then fails
## with "no such module 'SwiftShims'". Dropping both lets the system compiler
## find its own matching bundled SDK. This sanitization predates this module —
## it was established for the Vision helper — and is factored out here rather
## than copied, because a second copy of it would be a second thing to forget.
##
## Nothing here is macOS-specific at compile time; `resolveSwiftc` simply
## returns "" on hosts without a Swift toolchain and the callers raise their own
## platform-appropriate "unavailable" exceptions.

import std/[os, osproc, streams, strtabs, strutils, times]

when defined(posix):
  import std/posix

  proc cRename(src, dst: cstring): cint {.importc: "rename", header: "<stdio.h>".}
    ## C `rename(2)`.

type
  SwiftHelperError* = object of CatchableError
    ## Raised when the Swift toolchain, the helper source, or the compile
    ## itself is unavailable. Callers map this onto their own "optional backend
    ## is unusable on this host" exception so that a missing toolchain is never
    ## confused with a genuine runtime failure of a working one.

proc replaceFile*(src, dst: string): string =
  ## Rename `src` over `dst` in one step (POSIX `rename`, atomic within one
  ## file system), so a concurrent reader sees the old file or the new one,
  ## never a partial one. Returns "" on success, else why it failed (and
  ## `src` is left for the caller to remove).
  when defined(posix):
    if cRename(cstring(src), cstring(dst)) != 0:
      return osErrorMsg(osLastError())
    ""
  else:
    try:
      moveFile(src, dst)
      ""
    except Exception as e:
      e.msg

proc resolveSwiftc*(): string =
  ## Locate `swiftc`. Honors `SWIFTC`, then `$PATH`, then the standard Xcode
  ## command-line-tools location. Returns "" when unavailable.
  let envBin = getEnv("SWIFTC")
  if envBin.len > 0:
    return (if fileExists(envBin): envBin else: "")
  result = findExe("swiftc")
  if result.len == 0 and fileExists("/usr/bin/swiftc"):
    result = "/usr/bin/swiftc"

proc sanitizedSwiftcEnv*(swiftc: string): StringTableRef =
  ## The current environment with `SDKROOT` / `DEVELOPER_DIR` removed when
  ## `swiftc` is the system compiler under `/usr/`. A no-op when they are
  ## unset, and a no-op for a non-system `swiftc` (a nix-provided Swift wants
  ## its own SDK vars kept).
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if swiftc.startsWith("/usr/") and (k == "SDKROOT" or k == "DEVELOPER_DIR"):
      continue
    result[k] = v

proc swiftHelperCacheDir*(name: string): string =
  ## Per-helper cache directory under the temp dir. `name` is a bare directory
  ## name, e.g. "gui_assert_vision_helper".
  result = getTempDir() / name

proc ensurePrivateCacheDir*(dir: string) =
  ## Create `dir` when missing and make sure it is safe to build and run a
  ## helper from: a real directory (not a symlink), owned by this user, and
  ## writable by nobody else. The cache lives under the temp dir, which is
  ## per-user on macOS (`$TMPDIR`) but falls back to the shared `/tmp` when
  ## `TMPDIR` is unset; there another user could pre-create the directory and
  ## plant a source or binary that GuiAssert would then compile or execute.
  ## Raises `SwiftHelperError` when the directory cannot be made private.
  try:
    createDir(dir)
  except OSError as e:
    raise newException(SwiftHelperError,
      "cannot create Swift helper cache dir " & dir & ": " & e.msg)
  when defined(posix):
    var st: Stat
    if lstat(cstring(dir), st) != 0:
      raise newException(SwiftHelperError,
        "cannot stat Swift helper cache dir " & dir & ": " & osErrorMsg(osLastError()))
    if not S_ISDIR(st.st_mode):
      raise newException(SwiftHelperError,
        "Swift helper cache dir " & dir & " is not a directory (or is a symlink)")
    if st.st_uid != getuid():
      raise newException(SwiftHelperError,
        "Swift helper cache dir " & dir & " is owned by another user")
    if (st.st_mode.cint and 0o077) != 0:
      if chmod(cstring(dir), Mode(0o700)) != 0:
        raise newException(SwiftHelperError,
          "cannot make Swift helper cache dir " & dir & " private: " &
          osErrorMsg(osLastError()))

proc compileSwiftHelper*(cacheName, binName, src: string,
                         extraArgs: seq[string] = @[]): string =
  ## Compile `src` to `<swiftHelperCacheDir(cacheName)>/<binName>` with the
  ## sanitized system `swiftc`, and return the binary path. Recompiles only when
  ## the binary is missing or older than the source. Raises `SwiftHelperError`
  ## when the toolchain or the source is missing, or when the compile fails (the
  ## compiler output is included in the message — a silent compile failure here
  ## would surface much later as an unexplained "helper exited non-zero").
  if not fileExists(src):
    raise newException(SwiftHelperError, "Swift helper source not found: " & src)
  let swiftc = resolveSwiftc()
  if swiftc.len == 0:
    raise newException(SwiftHelperError,
      "swiftc not found (set SWIFTC or install the Xcode command line tools).")
  let cacheDir = swiftHelperCacheDir(cacheName)
  ensurePrivateCacheDir(cacheDir)
  let bin = cacheDir / binName
  var needCompile = true
  if fileExists(bin):
    try:
      if getLastModificationTime(bin) >= getLastModificationTime(src):
        needCompile = false
    except OSError:
      discard
  if needCompile:
    # Compile beside the binary and rename it into place, so a concurrent
    # GuiAssert process never executes a half-written helper.
    let tmpBin = bin & "." & $getCurrentProcessId() & ".partial"
    var args = @["-O", src, "-o", tmpBin]
    for a in extraArgs: args.add a
    let p = startProcess(command = swiftc, args = args,
                         env = sanitizedSwiftcEnv(swiftc),
                         options = {poStdErrToStdOut})
    let output = p.outputStream().readAll()
    let code = p.waitForExit()
    p.close()
    if code != 0:
      discard tryRemoveFile(tmpBin)
      raise newException(SwiftHelperError,
        "swiftc failed to compile " & src & " (" & $code & "):\n" & output)
    let why = replaceFile(tmpBin, bin)
    if why.len > 0:
      discard tryRemoveFile(tmpBin)
      raise newException(SwiftHelperError,
        "cannot install the compiled helper at " & bin & ": " & why)
  return bin
