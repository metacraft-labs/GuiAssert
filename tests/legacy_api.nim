## Extract and compare the public API of GuiAssert modules.
##
## `tests/tcore_shims.nim` uses this to check that the modules which existed
## before the core / opt-in split still offer every public symbol with the
## signature it had. The API of a module is read from the compiler itself
## (`nim jsondoc`), never from a hand-written list, so a signature cannot drift
## without the comparison seeing it.
##
## The baselines under `tests/fixtures/legacy_api/` were written by running
## this file as a program against the pre-split sources (origin/agents at
## 8e8df7ea):
##
##   nim c -r tests/legacy_api.nim write tests/fixtures/legacy_api \
##     src/gui_assert/image_math.nim src/gui_assert/ocr.nim ...
##
## They are a frozen record of the pre-split API and are not regenerated from
## the split tree; regenerating them from the code under test would make the
## comparison vacuous.

import std/[algorithm, json, os, sets, strutils]

import ./probe_compiler

type
  ApiEntry* = object
    ## One exported symbol as `nim jsondoc` reports it.
    name*: string   ## the symbol name
    kind*: string   ## the compiler's symbol kind (`skProc`, `skType`, ...)
    code*: string   ## the declaration as the compiler renders it

proc squash(s: string): string =
  ## Collapse every run of whitespace to one space, so the compiler's line
  ## wrapping (which depends on the length of the raises list) is not
  ## mistaken for a change.
  var lastSpace = false
  for c in s:
    if c in Whitespace:
      if not lastSpace and result.len > 0: result.add ' '
      lastSpace = true
    else:
      result.add c
      lastSpace = false
  result = result.strip()

proc splitEffects*(code: string): tuple[head: string, raises, tags: HashSet[string]] =
  ## Split a rendered routine declaration into its head (everything before
  ## the pragma block: name, parameters, defaults, return type) and the sets
  ## named in its inferred `raises` and `tags` lists.
  let flat = squash(code)
  let p = flat.find("{.")
  if p < 0:
    return (flat, initHashSet[string](), initHashSet[string]())
  result.head = flat[0 ..< p].strip()
  let pragmas = flat[p .. ^1]
  for (key, target) in [("raises:", 0), ("tags:", 1)]:
    let k = pragmas.find(key)
    if k < 0: continue
    let open = pragmas.find('[', k)
    let close = pragmas.find(']', open)
    if open < 0 or close < 0: continue
    for item in pragmas[open + 1 ..< close].split(','):
      let s = item.strip()
      if s.len == 0: continue
      if target == 0: result.raises.incl s
      else: result.tags.incl s

proc apiOf*(moduleFile, workDir: string): seq[ApiEntry] =
  ## Run `nim jsondoc` on `moduleFile` and return its exported entries.
  ## `workDir` receives the JSON and the doc nimcache (both explicit, so the
  ## probe neither writes into the source tree nor uses the shared cache).
  ## Raises `OSError` when the compiler fails, with its output.
  createDir(workDir)
  let nimcache = workDir / "nimcache"
  createDir(nimcache)
  let (output, code) = run(nimExe(), @[
    "jsondoc", "--hints:off", "--warnings:off",
    "--nimcache:" & nimcache, "--outdir:" & workDir, moduleFile])
  if code != 0:
    raise newException(OSError,
      "nim jsondoc failed (" & $code & ") for " & moduleFile & ":\n" & output)
  let jsonPath = workDir / moduleFile.splitFile.name & ".json"
  let doc = parseFile(jsonPath)
  for e in doc["entries"]:
    result.add ApiEntry(name: e["name"].getStr, kind: e["type"].getStr,
                        code: e{"code"}.getStr)

proc toJson(entries: seq[ApiEntry]): JsonNode =
  result = newJArray()
  for e in entries:
    result.add %*{"name": e.name, "kind": e.kind, "code": e.code}

proc readBaseline*(path: string): seq[ApiEntry] =
  ## Load a baseline written by `write` below.
  for e in parseFile(path):
    result.add ApiEntry(name: e["name"].getStr, kind: e["kind"].getStr,
                        code: e["code"].getStr)

proc isRoutine(kind: string): bool =
  kind in ["skProc", "skFunc", "skMethod", "skIterator", "skConverter",
           "skTemplate", "skMacro"]

proc compatible*(old, cur: ApiEntry): bool =
  ## True when `cur` can stand in for the baseline entry `old`: same name and
  ## kind; for routines the same head (parameters, defaults, return type) and
  ## no `raises` or `tags` beyond the baseline's (a caller that declared the
  ## old effects must still compile); for every other kind the identical
  ## rendered declaration.
  if old.name != cur.name or old.kind != cur.kind: return false
  if isRoutine(old.kind):
    let a = splitEffects(old.code)
    let b = splitEffects(cur.code)
    result = a.head == b.head and b.raises <= a.raises and b.tags <= a.tags
  else:
    result = squash(old.code) == squash(cur.code)

when isMainModule:
  # Usage: legacy_api write <outDir> <module.nim>...
  let args = commandLineParams()
  if args.len < 3 or args[0] != "write":
    quit "usage: legacy_api write <outDir> <module.nim>...", 2
  let outDir = args[1]
  createDir(outDir)
  let work = getTempDir() / "gui_assert_legacy_api_" & $getCurrentProcessId()
  try:
    for m in args[2 .. ^1]:
      var entries = apiOf(m, work / m.splitFile.name)
      entries.sort(proc (a, b: ApiEntry): int =
        result = cmp(a.name, b.name)
        if result == 0: result = cmp(a.code, b.code))
      writeFile(outDir / m.splitFile.name & ".json", entries.toJson.pretty & "\n")
      echo m, ": ", entries.len, " entries"
  finally:
    removeDir(work)
