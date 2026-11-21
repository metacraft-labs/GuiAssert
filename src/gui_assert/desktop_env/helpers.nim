## The C helpers the Linux targets drive (`helpers/linux`): `virtual_pointer`
## (a pointer device) and `wm_probe` (what the compositor grants a window).
##
## They are compiled on first use, and again whenever a source is newer than
## the binary, into `$GUI_ASSERT_HELPER_DIR` or `<GuiAssert>/build/linux-helpers`.
## Building needs the GuiAssert dev shell (wayland-scanner, the protocol XML,
## a C compiler); outside it the build fails and says so.

import std/[os, osproc, strutils, times]

const helperSrcDir = currentSourcePath().parentDir.parentDir.parentDir.parentDir /
                     "helpers" / "linux"

proc helperDir*(): string =
  let configured = getEnv("GUI_ASSERT_HELPER_DIR")
  if configured.len > 0: configured
  else: helperSrcDir.parentDir.parentDir / "build" / "linux-helpers"

proc newestSource(): Time =
  for f in walkFiles(helperSrcDir / "*"):
    result = max(result, getLastModificationTime(f))

proc helper*(name: string): string =
  ## The path of a built helper, building it if it is missing or stale.
  ## Raises `OSError` with the build's output if it cannot be built.
  result = helperDir() / name
  if fileExists(result) and getLastModificationTime(result) >= newestSource():
    return
  let (output, code) = execCmdEx(quoteShellCommand(
    ["bash", helperSrcDir / "build.sh", helperDir()]))
  if code != 0 or not fileExists(result):
    raise newException(OSError, "could not build the GuiAssert Linux helpers " &
      "(run inside GuiAssert's `nix develop`):\n" & output.strip())
