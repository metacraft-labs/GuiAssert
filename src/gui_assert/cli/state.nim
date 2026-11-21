## The `guiassert` state directory (spec §7.6).
##
## The first configured location wins, never "the first writable one", so
## separate processes agree on it without probing:
##
## 1. `--state-dir <root>`;
## 2. `$GUIASSERT_STATE_DIR`;
## 3. the platform default: macOS `~/Library/Application Support/GuiAssert/state`;
##    Linux `$XDG_STATE_HOME/guiassert` or `~/.local/state/guiassert`;
##    Windows `%LOCALAPPDATA%\GuiAssert\state`.
##
## The records themselves are written by `gui_assert/state_store`, which this
## module re-exports.

import std/[options, os, tables]

import ../core/contract
import ../state_store
import ./registry

export state_store

type
  StateDirSource* = enum
    sdsFlag = "flag", sdsEnv = "env", sdsDefault = "default"

proc platformStateDir*(env: Table[string, string]): string =
  ## The platform default state directory, from `env` (`HOME`,
  ## `XDG_STATE_HOME`, `LOCALAPPDATA`). Raises `bad-args` /
  ## `missing-argument` when the variable it needs is unset.
  proc need(name: string): string =
    result = env.getOrDefault(name, "")
    if result.len == 0:
      raise badArgs("missing-argument", "cannot place the state directory: " &
        name & " is unset; pass --state-dir or set GUIASSERT_STATE_DIR")
  case currentPlatform
  of hpMacos: need("HOME") / "Library" / "Application Support" / "GuiAssert" / "state"
  of hpLinux:
    let xdg = env.getOrDefault("XDG_STATE_HOME", "")
    if xdg.len > 0 and isAbsolute(xdg): xdg / "guiassert"
    else: need("HOME") / ".local" / "state" / "guiassert"
  of hpWindows: need("LOCALAPPDATA") / "GuiAssert" / "state"

proc resolveStateDir*(flag: Option[string], env: Table[string, string],
                      cwd: string): tuple[dir: string, source: StateDirSource] =
  ## The state directory and which rule chose it; relative paths are taken
  ## against `cwd`. An empty value is `bad-args` / `invalid-value`.
  if flag.isSome:
    if flag.get.len == 0: raise badArgs("invalid-value", "--state-dir is empty")
    return (absolutePath(flag.get, cwd), sdsFlag)
  let e = env.getOrDefault("GUIASSERT_STATE_DIR", "")
  if e.len > 0:
    return (absolutePath(e, cwd), sdsEnv)
  (platformStateDir(env), sdsDefault)
