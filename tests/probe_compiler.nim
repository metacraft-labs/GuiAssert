## Helpers for tests that drive the Nim compiler as a subprocess.
##
## The core purity and legacy-API tests compile small probe programs and ask
## the compiler about them. Every probe lives in its own fresh directory
## under the system temp dir and is compiled with an explicit `--nimcache:`
## and `-o:` there, so a probe never writes into the source tree and never
## uses the shared per-user nimcache (see `config.nims` for why that matters).

import std/[os, osproc, streams, strutils]

const compilerAtBuild = getCurrentCompilerExe()

proc nimExe*(): string =
  ## The compiler to probe with: the `nim` on `PATH` (inside `nix develop`
  ## that is the wrapper that knows the C toolchain), else the compiler this
  ## test was built with. Raises `OSError` when there is neither.
  result = findExe("nim")
  if result.len == 0 and fileExists(compilerAtBuild):
    result = compilerAtBuild
  if result.len == 0:
    raise newException(OSError,
      "no `nim` on PATH and the build compiler " & compilerAtBuild &
      " is gone: cannot probe")

proc repoRoot*(): string =
  ## The checkout root: the parent of this file's directory.
  currentSourcePath().parentDir.parentDir

proc srcDir*(): string =
  ## The package source root (`src/`), passed to probes as `--path:`.
  repoRoot() / "src"

proc freshDir*(tag: string): string =
  ## A new empty directory for one probe. Raises `OSError` if it cannot be
  ## created.
  result = getTempDir() / ("gui_assert_probe_" & tag & "_" &
                           $getCurrentProcessId())
  removeDir(result)
  createDir(result)

proc run*(exe: string, args: seq[string], workDir = ""):
    tuple[output: string, code: int] =
  ## Run `exe args` (no shell), stdout and stderr merged, and return what it
  ## printed and its exit code. Raises `OSError` if it cannot be started.
  let p = startProcess(exe, workingDir = workDir, args = args,
                       options = {poStdErrToStdOut})
  try:
    result.output = p.outputStream.readAll()
    result.code = p.waitForExit()
  finally:
    p.close()

proc compileProbe*(dir, name, source: string, extra: seq[string] = @[]):
    tuple[binary, output: string, code: int] =
  ## Write `source` as `<dir>/<name>.nim` and compile it to `<dir>/<name>`
  ## with the package source root on the path. Returns the binary path, the
  ## compiler output and its exit code.
  let file = dir / name & ".nim"
  writeFile(file, source)
  result.binary = dir / name.addFileExt(ExeExt)
  var args = @["c", "--hints:off", "--warnings:off",
               "--path:" & srcDir(), "--nimcache:" & (dir / "nimcache"),
               "-o:" & result.binary]
  args.add extra
  args.add file
  let (output, code) = run(nimExe(), args)
  result.output = output
  result.code = code

proc indent*(s: string): string =
  ## Indent every line of `s` for readable failure messages.
  for line in s.strip.splitLines:
    result.add "      " & line & "\n"
