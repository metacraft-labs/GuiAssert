## tswift_helper_cache — the Swift helper cache directory is safe to compile
## into and execute from (`swift_helper.ensurePrivateCacheDir`).
##
## GuiAssert builds its Swift helpers (the Vision OCR helper, the
## ScreenCaptureKit helper) into a cache directory under the temp dir and runs
## the result. When `TMPDIR` is unset that is the shared `/tmp`, where another
## user could pre-create the directory and plant a source or a binary. The
## guard must therefore make a fresh directory private, tighten an existing
## one that others can reach, and refuse a symlink or a directory owned by
## someone else.
##
## Stand-ins: none. Real directories are created under this test's own temp
## directory; the "owned by another user" case uses `/usr` (owned by root on
## every POSIX host this suite runs on). The suite is POSIX-only and refuses
## to compile elsewhere rather than skip.

when not defined(posix):
  {.error: "tests/tswift_helper_cache.nim runs on POSIX hosts".}

import std/[os, strutils, tempfiles, unittest]

import ../src/gui_assert/swift_helper

const privateMode = {fpUserRead, fpUserWrite, fpUserExec}

suite "Swift helper cache directory":
  let base = createTempDir("gui_assert_tswift_", "")
  defer: removeDir(base)

  test "a missing directory is created private":
    let d = base / "fresh"
    ensurePrivateCacheDir(d)
    check dirExists(d)
    check getFilePermissions(d) == privateMode

  test "an existing directory others can write is tightened":
    let d = base / "shared"
    createDir(d)
    setFilePermissions(d, privateMode + {fpGroupWrite, fpOthersRead,
                                         fpOthersWrite, fpOthersExec})
    ensurePrivateCacheDir(d)
    check getFilePermissions(d) == privateMode

  test "a symlink is refused":
    let target = base / "target"
    createDir(target)
    let link = base / "link"
    createSymlink(target, link)
    expect SwiftHelperError:
      ensurePrivateCacheDir(link)

  test "a directory owned by another user is refused":
    # Refused for its owner, before any attempt to change its mode (which
    # would also fail for /usr, and must not be what refuses it).
    var msg = ""
    try: ensurePrivateCacheDir("/usr")
    except SwiftHelperError as e: msg = e.msg
    checkpoint msg
    check "owned by another user" in msg
