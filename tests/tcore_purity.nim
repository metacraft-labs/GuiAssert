## The purity rule for `gui_assert/core/` (spec §3.2), enforced.
##
## A module under `core/` may import only other `core/` modules and a fixed
## stdlib allowlist, may use no FFI and hold no global mutable state, and a
## program built from all of `core/` must link nothing beyond the platform C
## runtime. This file checks each of those against what the compiler and the
## linker actually produced, not against what the sources claim:
##
## * `test_core_imports_only_stdlib_allowlist` asks `nim genDepend` for the
##   import graph of every core module. Every file in the closure must be a
##   core module or part of the Nim standard library, and every stdlib module
##   a core module imports *directly* must be on the allowlist. A control
##   runs the same analysis on `gui_assert/image_math` (which reaches
##   `std/osproc` and the effectful `media` module) and requires both
##   violations to be reported, so an analysis that sees no edges cannot pass.
## * `test_core_sources_use_no_ffi_or_global_state` scans the core sources for
##   FFI and linking pragmas and environment access (its control is a scan of
##   `gui_assert/input`, which binds Core Graphics), and walks the syntax tree
##   of every core module, as the compiler's own parser builds it, for
##   module-level `var`s (also inside a top-level `when` or `block`) and
##   `{.global.}` variables (its control is a fixture holding one of each).
## * `test_core_binary_links_no_platform_libraries` compiles a program that
##   imports all of `core/` and reads the libraries the binary links with the
##   platform tool (`otool -L` on macOS; `readelf -d`, `objdump -p` or `ldd`
##   on Linux; `objdump -p` on Windows). Its control is the same probe on a
##   program that links a platform library: `gui_assert/input` on macOS (the
##   ApplicationServices and CoreFoundation frameworks), and a program that
##   calls into libstdc++ (Linux) or user32 (Windows), where GuiAssert itself
##   links nothing yet. If the control reports no extra library, the probe
##   is blind and the test fails saying so.
## * `test_core_builds_for_js_backend` compiles all of `core/` for the JS
##   target, which the purity rule promises for the pure maths.
##
## NO MOCKS: the real compiler, the real linker, the real binaries.

import std/[algorithm, os, sets, strutils, unittest]

import ./probe_compiler

const
  coreDir = currentSourcePath().parentDir.parentDir / "src" / "gui_assert" / "core"

  stdAllowlist = ["math", "strutils", "sequtils", "algorithm", "tables",
                  "sets", "hashes", "options", "json", "times", "parseutils",
                  "unicode", "bitops", "endians", "streams", "strformat"]
    ## Spec §3.2. `streams` is for in-memory streams only.

  importFreeCoreModules = ["sha256", "mp4"]
    ## Core modules with no import statement at all, so they show no import
    ## edges; `test_core_imports_only_stdlib_allowlist` checks that they
    ## really import nothing.

proc comparable(p: string): string =
  ## `p` absolute and normalised, case-folded with one separator on Windows,
  ## so paths reported by different tools compare equal.
  result = normalizedPath(absolutePath(p))
  when defined(windows):
    result = result.replace('/', '\\').toLowerAscii()

proc coreModules(): seq[string] =
  ## The base names of every module under `core/`, sorted.
  for f in walkFiles(coreDir / "*.nim"):
    result.add f.splitFile.name
  result.sort()

proc nimLibDir(probeFile: string): string =
  ## The standard library directory of the probing compiler, from `nim dump`.
  let (output, code) = run(nimExe(), @["dump", "--hints:off", "--dump.format:json",
                                       probeFile])
  if code != 0:
    raise newException(OSError, "nim dump failed:\n" & output)
  for line in output.splitLines:
    if line.startsWith("{"):
      let key = "\"libpath\":\""
      let p = line.find(key)
      if p >= 0:
        let start = p + key.len
        return line[start ..< line.find('"', start)].replace("\\\\", "\\")
  raise newException(OSError, "nim dump printed no libpath:\n" & output)

type
  ImportReport = object
    nonCoreFiles: seq[string]     ## project or package files outside core/
    forbiddenStd: seq[string]     ## "<core module> -> <stdlib module>"
    edges: int                    ## edges seen from the analysed modules

proc analyseImports(importPath: string, owned: proc (file: string): bool,
                    tag: string): ImportReport =
  ## Run `nim genDepend` on a probe that imports `importPath` and report:
  ## every file of the closure that is neither under `core/` nor in the
  ## stdlib, and every edge from a module whose file `owned` accepts to a
  ## stdlib module outside the allowlist (or to `system/…`, which only the
  ## compiler itself may import).
  ##
  ## genDepend names a stdlib module by its library path (`std/os`) and a
  ## project module by its path relative to the probe's directory, so the
  ## two are told apart without relying on module names being unique.
  let dir = freshDir("deps_" & tag)
  defer: removeDir(dir)
  let probe = dir / "probe.nim"
  writeFile(probe, "import " & importPath & "\n")
  let nimcache = dir / "nimcache"
  createDir(nimcache)  # genDepend writes its .deps file there without creating it
  let (output, code) = run(nimExe(), @["genDepend", "--hints:off",
    "--warnings:off", "--path:" & srcDir(), "--nimcache:" & nimcache, probe])
  let dot = dir / "probe.dot"
  # genDepend writes probe.dot, then runs Graphviz to render it. Graphviz is
  # not a dependency of this repository, so its absence (and only that) is
  # accepted once the graph itself was written.
  if code != 0 and not (fileExists(dot) and "Graphviz" in output):
    raise newException(OSError, "nim genDepend failed (" & $code & "):\n" & output)
  if not fileExists(dot):
    raise newException(OSError, "nim genDepend wrote no graph:\n" & output)
  let deps = nimcache / "probe.deps"
  if not fileExists(deps):
    raise newException(OSError, "nim genDepend wrote no file list:\n" & output)
  let lib = comparable(nimLibDir(probe))
  let core = comparable(coreDir)
  for raw in readFile(deps).splitLines:
    let f = raw.strip
    if f.len == 0: continue
    let n = comparable(f)
    if n == comparable(probe): continue
    if n.startsWith(lib & DirSep) or n.startsWith(core & DirSep): continue
    result.nonCoreFiles.add f
  var allowed = initHashSet[string]()
  for m in stdAllowlist: allowed.incl "std/" & m
  proc isStd(node: string): bool =
    node.startsWith("std/") or node == "system" or node.startsWith("system/")
  proc fileOf(node: string): string =
    comparable(absolutePath(node & ".nim", dir))
  for line in readFile(dot).splitLines:
    let parts = line.strip.strip(chars = {';'}).split(" -> ")
    if parts.len != 2: continue
    let src = parts[0].strip(chars = {'"'})
    let dst = parts[1].strip(chars = {'"'})
    if isStd(src) or not owned(fileOf(src)): continue
    inc result.edges
    if isStd(dst):
      if dst notin allowed:
        result.forbiddenStd.add fileOf(src).extractFilename & " -> " & dst
    # Any other target is a project module; the closure check above has
    # already placed it inside or outside core/.

proc stripCommentsAndStrings(line: string): string =
  ## `line` without its string literals and its comment, so that a word in
  ## a doc comment or an error message is not mistaken for code.
  var inStr = false
  var i = 0
  while i < line.len:
    let c = line[i]
    if inStr:
      if c == '\\': inc i
      elif c == '"': inStr = false
    elif c == '"':
      inStr = true
    elif c == '\'' and i + 2 < line.len and line[i + 2] == '\'':
      i += 2   # a character literal such as '"' or '#'
    elif c == '#':
      break
    else:
      result.add c
    inc i

proc containsWord(s, word: string): bool =
  ## True when `word` occurs in `s` not preceded by an identifier character
  ## (so `sawHeader:` does not count as the `header:` pragma).
  var start = 0
  while true:
    let p = s.find(word, start)
    if p < 0: return false
    if p == 0 or s[p - 1] notin IdentChars: return true
    start = p + 1

proc impurities(file: string): seq[string] =
  ## The FFI, linking and environment constructs in `file` (global state is
  ## found from the syntax tree by `globalState`).
  const forbidden = ["importc", "importcpp", "importobjc", "importjs",
                     "dynlib", "header:", "emit", "compile:", "passl",
                     "passc", "link:", "getenv", "putenv", "existsenv",
                     "delenv", "envpairs"]
  var lineNo = 0
  for raw in readFile(file).splitLines:
    inc lineNo
    let code = stripCommentsAndStrings(raw)
    let lower = code.toLowerAscii
    for word in forbidden:
      if containsWord(lower, word):
        result.add file.extractFilename & ":" & $lineNo & ": " & word & ": " & raw.strip

const globalStateProbe = """
import std/macros

proc walk(n: NimNode, inRoutine: bool, file: string, found: var seq[string]) =
  ## Collect every `var` section outside a routine body (a module-level
  ## variable, also when nested in a top-level `when` or `block`) and every
  ## `{.global.}` pragma (a routine-local variable with global lifetime).
  case n.kind
  of nnkProcDef, nnkFuncDef, nnkMethodDef, nnkIteratorDef, nnkConverterDef,
     nnkTemplateDef, nnkMacroDef, nnkLambda, nnkDo:
    for c in n: walk(c, true, file, found)
  of nnkVarSection:
    if not inRoutine:
      found.add file & ":" & $n.lineInfoObj.line & ": module-level var"
    for c in n: walk(c, inRoutine, file, found)
  of nnkPragma:
    for c in n:
      let key = if c.kind == nnkExprColonExpr: c[0] else: c
      if key.kind == nnkIdent and key.eqIdent("global"):
        found.add file & ":" & $n.lineInfoObj.line & ": {.global.} variable"
    for c in n: walk(c, inRoutine, file, found)
  else:
    for c in n: walk(c, inRoutine, file, found)

macro scan(files: static openArray[string]): string =
  var found: seq[string] = @[]
  for f in files:
    walk(parseStmt(staticRead(f), f), false, f.extractFilename, found)
  result = newLit(found.join("\n"))

const report = scan(FILES)
echo "BEGIN"
if report.len > 0: echo report
echo "END"
"""

proc globalState(dir: string, files: seq[string]): seq[string] =
  ## The module-level `var`s and `{.global.}` variables in `files`, found
  ## from the syntax tree the compiler's own parser builds (`parseStmt` at
  ## compile time), so a variable nested in a top-level `when` or `block`
  ## is seen as well. Raises `OSError` when the probe does not build or run.
  var quoted: seq[string] = @[]
  for f in files: quoted.add "\"" & f.replace("\\", "/") & "\""
  let src = "import std/[os, strutils]\n" &
    globalStateProbe.replace("FILES", "[" & quoted.join(", ") & "]")
  let (binary, output, code) = compileProbe(dir, "globalstate", src)
  if code != 0:
    raise newException(OSError, "the global-state probe did not build:\n" & output)
  let (runOut, runCode) = run(binary, @[])
  let b = runOut.find("BEGIN\n")
  let e = runOut.find("END")
  if runCode != 0 or b < 0 or e < b:
    raise newException(OSError, "the global-state probe failed:\n" & runOut)
  for line in runOut[b + "BEGIN\n".len ..< e].splitLines:
    if line.strip.len > 0: result.add line.strip

proc linkedLibraries(binary: string): tuple[tool: string, libs: seq[string]] =
  ## The shared libraries / frameworks / DLLs `binary` links, as the
  ## platform's own tool lists them. Raises `OSError` when no tool works.
  when defined(macosx):
    let otool = findExe("otool", followSymlinks = false)
    if otool.len == 0:
      raise newException(OSError, "no otool on PATH to read the linked libraries")
    let (output, code) = run(otool, @["-L", binary])
    if code != 0: raise newException(OSError, "otool -L failed:\n" & output)
    result.tool = "otool -L"
    for line in output.splitLines[1 .. ^1]:
      let l = line.strip
      if l.len > 0: result.libs.add l.split(" (")[0]
  elif defined(windows):
    let objdump = findExe("objdump", followSymlinks = false)
    if objdump.len == 0:
      raise newException(OSError, "no objdump on PATH to read the DLL imports")
    let (output, code) = run(objdump, @["-p", binary])
    if code != 0: raise newException(OSError, "objdump -p failed:\n" & output)
    result.tool = "objdump -p"
    for line in output.splitLines:
      let l = line.strip
      if l.startsWith("DLL Name:"):
        result.libs.add l["DLL Name:".len .. ^1].strip
  else:
    for (tool, args, marker) in [("readelf", @["-d", binary], "(NEEDED)"),
                                 ("objdump", @["-p", binary], "NEEDED")]:
      let exe = findExe(tool, followSymlinks = false)
      if exe.len == 0: continue
      let (output, code) = run(exe, args)
      if code != 0: continue
      result.tool = tool & " " & args[0]
      for line in output.splitLines:
        if marker in line:
          let l = line.strip
          if "[" in l: result.libs.add l[l.find('[') + 1 ..< l.find(']')]
          else: result.libs.add l.splitWhitespace[^1]
      return
    let ldd = findExe("ldd", followSymlinks = false)
    if ldd.len == 0:
      raise newException(OSError, "none of readelf, objdump, ldd on PATH")
    let (output, code) = run(ldd, @[binary])
    if code != 0: raise newException(OSError, "ldd failed:\n" & output)
    result.tool = "ldd"
    for line in output.splitLines:
      let l = line.strip
      if l.len > 0: result.libs.add l.splitWhitespace[0]

proc isCRuntime(lib: string): bool =
  ## True for the libraries that make up the platform C runtime.
  let name = lib.extractFilename.toLowerAscii
  when defined(macosx):
    lib == "/usr/lib/libSystem.B.dylib"
  elif defined(windows):
    # kernel32 and the CRT (msvcrt for the MSVCRT MinGW runtime, the UCRT
    # forwarders otherwise); winpthread is MinGW's threads runtime.
    name in ["kernel32.dll", "msvcrt.dll", "ucrtbase.dll",
             "libwinpthread-1.dll"] or name.startsWith("api-ms-win-crt-")
  else:
    # glibc's own libraries and the dynamic loader.
    for prefix in ["libc.so", "libm.so", "libdl.so", "libpthread.so",
                   "librt.so", "ld-linux", "linux-vdso.so", "ld64.so"]:
      if name.startsWith(prefix): return true
    false

proc allCoreProbe(): string =
  ## A program that imports every core module and uses each, so that no
  ## module is dropped before the link.
  result = "import gui_assert/core/[" & coreModules().join(", ") & "]\n"
  result.add """
let g = newImage(GrayImage, 8, 8, 128)
let encoded = encodePng(g)
doAssert decodePngGray(encoded) == g
doAssert computeSsim(g, g) == 1.0
doAssert hammingDistance(dctHash(g), dctHash(g)) == 0
doAssert segmentBoundaries(@[1.0, 0.1], 0.5) == @[0, 2]
doAssert detectWindowRects(g).len == 0
doAssert wordsToReadingOrderText(@[]) == ""
doAssert parseTreePath("/app[1]/button[0]").pid == 1
doAssert isValidName("probe")
doAssert rect(0, 0, 2, 2).area == 4
doAssert unavailable("probe", "wrong-platform", "x").reason == "wrong-platform"
echo "core probe ok"
"""

suite "core purity":
  test "test_core_imports_only_stdlib_allowlist":
    let modules = coreModules()
    check modules.len >= 11
    let core = comparable(coreDir)
    let inCore = proc (file: string): bool = file.parentDir == core
    for m in modules:
      let r = analyseImports("gui_assert/core/" & m, inCore, m)
      checkpoint "core/" & m & ": " & $r.edges & " import edges"
      # Every module must show its import edges (a sanity check that the
      # analysis saw the module at all), except the ones named here, which
      # import nothing: for those the source must carry no import, from or
      # include statement, so the exemption cannot hide a module the
      # analysis failed to read.
      if m in importFreeCoreModules:
        var statements: seq[string]
        for line in readFile(coreDir / m & ".nim").splitLines:
          let l = line.strip
          if l.startsWith("import ") or l.startsWith("from ") or
             l.startsWith("include "):
            statements.add l
        checkpoint "core/" & m & " import statements: " & $statements
        check statements.len == 0
        check r.edges == 0
      else:
        check r.edges > 0
      if r.nonCoreFiles.len > 0 or r.forbiddenStd.len > 0:
        checkpoint "core/" & m & " reaches outside the allowlist:\n" &
          indent(r.nonCoreFiles.join("\n") & "\n" & r.forbiddenStd.join("\n"))
      check r.nonCoreFiles.len == 0
      check r.forbiddenStd.len == 0
    # Control: an effectful module must be caught on both counts.
    let control = analyseImports("gui_assert/image_math",
      proc (file: string): bool =
        file.extractFilename in ["image_math.nim", "ffmpeg.nim"], "control")
    checkpoint "control (image_math) report: " & $control
    check control.edges > 0
    check "ffmpeg.nim -> std/osproc" in control.forbiddenStd
    var sawMedia = false
    for f in control.nonCoreFiles:
      if f.endsWith(DirSep & "media.nim"): sawMedia = true
    check sawMedia

  test "test_core_sources_use_no_ffi_or_global_state":
    var found: seq[string] = @[]
    var files = 0
    for f in walkFiles(coreDir / "*.nim"):
      inc files
      found.add impurities(f)
    check files >= 11
    if found.len > 0:
      checkpoint "impure constructs in core/:\n" & indent(found.join("\n"))
    check found.len == 0
    # Control: the scanner must see the Core Graphics binding in input.nim.
    let control = impurities(coreDir.parentDir / "input.nim")
    checkpoint "control (input.nim): " & $control
    check control.len > 0

    # Global mutable state, from the syntax tree of every core module.
    let dir = freshDir("globals")
    defer: removeDir(dir)
    var coreFiles: seq[string] = @[]
    for f in walkFiles(coreDir / "*.nim"): coreFiles.add f
    let globals = globalState(dir, coreFiles)
    if globals.len > 0:
      checkpoint "global mutable state in core/:\n" & indent(globals.join("\n"))
    check globals.len == 0
    # Control: a module-level var, one hidden in a top-level `when`, and a
    # `{.global.}` local must all be reported; a routine's own locals not.
    let fixture = dir / "globals_fixture.nim"
    writeFile(fixture, """
var counter = 0
when true:
  var hidden = 0
proc p(): int =
  var local = 1
  var kept {.global.} = 0
  local + kept
""")
    let seen = globalState(dir, @[fixture])
    checkpoint "control (globals fixture): " & $seen
    check seen.len == 3

  test "test_core_binary_links_no_platform_libraries":
    let dir = freshDir("link")
    defer: removeDir(dir)
    let (binary, output, code) = compileProbe(dir, "allcore", allCoreProbe())
    if code != 0: checkpoint "compile failed:\n" & indent(output)
    require code == 0
    let (runOut, runCode) = run(binary, @[])
    check runCode == 0
    check "core probe ok" in runOut
    let (tool, libs) = linkedLibraries(binary)
    checkpoint tool & " on the all-core program: " & $libs
    check libs.len > 0   # every dynamic binary links at least the C runtime
    var extra: seq[string] = @[]
    for l in libs:
      if not isCRuntime(l): extra.add l
    check extra.len == 0

    # Negative control: a program that links a platform library must show it.
    when defined(macosx):
      let controlSrc = "import gui_assert/input\nmouseMove(0, 0)\n"
      let expectAny = ["ApplicationServices", "CoreFoundation"]
      let controlArgs: seq[string] = @[]
    elif defined(windows):
      let controlSrc = """
proc MessageBeep(kind: uint32): int32 {.importc, stdcall, header: "<windows.h>".}
if paramCount() > 1000: discard MessageBeep(0)
"""
      let expectAny = ["user32"]
      let controlArgs = @["--passL:-luser32"]
    else:
      let controlSrc = """
proc cxaDemangle(name: cstring, buf: pointer, n: pointer, status: ptr cint): cstring
  {.importc: "__cxa_demangle", cdecl.}
if paramCount() > 1000:
  var st: cint
  discard cxaDemangle("_Z1fv", nil, nil, addr st)
"""
      let expectAny = ["libstdc++"]
      let controlArgs = @["--passL:-Wl,--no-as-needed", "--passL:-lstdc++"]
    let (cbin, cout, ccode) = compileProbe(dir, "linkcontrol", controlSrc, controlArgs)
    if ccode != 0: checkpoint "control compile failed:\n" & indent(cout)
    require ccode == 0
    let (_, clibs) = linkedLibraries(cbin)
    checkpoint tool & " on the control program: " & $clibs
    var seen = false
    for l in clibs:
      if not isCRuntime(l):
        for e in expectAny:
          if e.toLowerAscii in l.toLowerAscii: seen = true
    check seen

  test "test_core_builds_for_js_backend":
    let dir = freshDir("js")
    defer: removeDir(dir)
    var src = "import gui_assert/core/[" & coreModules().join(", ") & "]\n"
    src.add """
let g = newImage(GrayImage, 4, 4, 7)
doAssert decodePngGray(encodePng(g)) == g
doAssert computeSsim(g, g) == 1.0
echo "js ok"
"""
    writeFile(dir / "jsprobe.nim", src)
    let (output, code) = run(nimExe(), @["js", "--hints:off", "--warnings:off",
      "--path:" & srcDir(), "--nimcache:" & (dir / "nimcache"),
      "-o:" & (dir / "jsprobe.js"), dir / "jsprobe.nim"])
    if code != 0: checkpoint "nim js failed:\n" & indent(output)
    check code == 0
    check fileExists(dir / "jsprobe.js")
