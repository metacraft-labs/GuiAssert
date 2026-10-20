## Shared helpers of the contract suite: run the REAL `guiassert` binary as a
## subprocess, talk to the REAL `guiassert serve` daemon over its pipes or
## its Unix socket, and read the specification's own text.
##
## The binary under test is `$GUIASSERT_CONTRACT_BIN`, else
## `build/bin/guiassert` (`just build-cli` builds it; `just test-contract`
## runs the suite against both `guiassert` and `guiassert-fixture`). Every
## run gets an explicit environment: the caller's, minus every `GUIASSERT_*`
## variable, plus what the test sets, so a developer's own settings cannot
## change a result.
##
## Stand-ins: none here. The fixture backend these tests select is the one
## sanctioned stand-in of the contract layer (spec §9.2); it sits below the
## CLI, the daemon and the serializers under test.

import std/[json, os, osproc, streams, strtabs, strutils, tables, times, monotimes]

when defined(posix):
  import std/posix
else:
  import std/winlean

const
  repoRootDir* = currentSourcePath().parentDir.parentDir.parentDir
  specPath* = repoRootDir / "Planned-Work" / "Desktop-Substrate.md"
  cliTimeoutMs* = 60_000

proc contractBin*(): string =
  ## The binary under test. Fails loudly when it has not been built.
  result = getEnv("GUIASSERT_CONTRACT_BIN")
  if result.len == 0:
    result = repoRootDir / "build" / "bin" / ("guiassert" & ExeExt)
  if not fileExists(result):
    raise newException(IOError, "the guiassert binary " & result &
      " does not exist; run `just build-cli` (or set GUIASSERT_CONTRACT_BIN)")

var stateCounter = 0
var createdDirs: seq[string]
  ## Every directory `freshDir` made, for `cleanupFreshDirs`.

proc cleanupFreshDirs*() =
  ## Remove every directory `freshDir` made. Each test file calls it after
  ## its suite (an exit procedure cannot: the allocator is gone by then).
  for d in createdDirs:
    try: removeDir(d)
    except CatchableError as e:
      stderr.writeLine("could not remove " & d & ": " & e.msg)
  createdDirs.setLen(0)

proc freshDir*(tag: string): string =
  ## A new empty directory for one test. Its path is short (a Unix socket
  ## path has a ~100-byte limit) and holds no symlink component, so paths
  ## the binary reports compare equal to the ones the test built.
  inc stateCounter
  let base = when defined(posix): "/tmp" else: getTempDir()
  result = expandFilename(base) / ("gac-" & $getCurrentProcessId() & "-" &
                                   tag & "-" & $stateCounter)
  removeDir(result)
  createDir(result)
  createdDirs.add result

proc baseEnv*(): StringTableRef =
  ## The caller's environment without any GUIASSERT_* variable.
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if not k.startsWith("GUIASSERT_"): result[k] = v

proc fixtureEnv*(stateDir: string, extra: openArray[(string, string)] = []): StringTableRef =
  ## An environment selecting the fixture backend and `stateDir`.
  result = baseEnv()
  result["GUIASSERT_BACKEND"] = "fixture"
  result["GUIASSERT_STATE_DIR"] = stateDir
  for (k, v) in extra: result[k] = v

type
  CliRun* = object
    exit*: int
    stdout*: string
    stderr*: string

proc runCli*(args: seq[string], env: StringTableRef, workDir = "",
             timeoutMs = cliTimeoutMs): CliRun =
  ## Run the binary once and collect its exit code and both streams.
  let p = startProcess(contractBin(), workingDir = workDir, args = args,
                       env = env, options = {})
  try:
    p.inputStream.close()
    result.exit = p.waitForExit(timeoutMs)
    if p.running:
      p.kill()
      raise newException(IOError, "guiassert " & args.join(" ") & " did not exit within " &
        $timeoutMs & " ms")
    result.stdout = p.outputStream.readAll()
    result.stderr = p.errorStream.readAll()
  finally:
    p.close()

proc envelopeOf*(r: CliRun): JsonNode =
  ## The envelope of a run, after checking that stdout is exactly one line.
  doAssert r.stdout.endsWith("\n"), "stdout does not end with a newline: " & r.stdout
  doAssert r.stdout.count('\n') == 1, "stdout is not exactly one line: " & r.stdout
  parseJson(r.stdout)

proc cli*(args: seq[string], env: StringTableRef): tuple[exit: int, env: JsonNode, line: string] =
  ## Run and parse: the exit code, the envelope and the raw line.
  let r = runCli(args, env)
  (r.exit, envelopeOf(r), r.stdout.strip(leading = false, chars = {'\n'}))

proc data*(env: JsonNode): JsonNode = env["data"]

proc errorKind*(env: JsonNode): string = env["error"]["kind"].getStr
proc errorReason*(env: JsonNode): string = env["error"]["reason"].getStr

proc isMinimalBinary*(): bool =
  ## True when the binary under test is `guiassert-fixture` (no media backend).
  let (_, env, _) = cli(@["version"], baseEnv())
  env["data"]["compiled"]["media"].len == 0

# ---------------------------------------------------------------------------
# Line reading with a deadline, from a pipe or a socket
# ---------------------------------------------------------------------------

type
  LineReader* = object
    buf: string
    when defined(posix):
      fd: cint
    else:
      handle: Handle
    eof*: bool

proc initLineReader*(p: Process): LineReader =
  when defined(posix):
    result.fd = cint(p.outputHandle)
  else:
    result.handle = Handle(p.outputHandle)

when defined(posix):
  proc initSocketReader*(fd: cint): LineReader =
    result.fd = fd

proc fill(r: var LineReader, waitMs: int): bool =
  ## Read whatever is available within `waitMs`; false on timeout.
  when defined(posix):
    var fds: TFdSet
    FD_ZERO(fds)
    FD_SET(r.fd, fds)
    var tv = Timeval(tv_sec: posix.Time(waitMs div 1000),
                     tv_usec: Suseconds((waitMs mod 1000) * 1000))
    let n = select(r.fd + 1, addr fds, nil, nil, addr tv)
    if n <= 0: return false
    var chunk: array[65536, char]
    let got = posix.read(r.fd, addr chunk[0], chunk.len)
    if got <= 0:
      r.eof = true
      return true
    for i in 0 ..< got: r.buf.add chunk[i]
    true
  else:
    let start = getMonoTime()
    while true:
      var avail: int32
      if not peekNamedPipe(r.handle, lpTotalBytesAvail = addr avail):
        r.eof = true
        return true
      if avail > 0:
        var chunk = newString(int(avail))
        var got: int32
        if readFile(r.handle, addr chunk[0], avail, addr got, nil) == 0 or got == 0:
          r.eof = true
          return true
        r.buf.add chunk[0 ..< int(got)]
        return true
      if (getMonoTime() - start).inMilliseconds >= waitMs: return false
      sleep(5)

proc readLine*(r: var LineReader, timeoutMs: int): string =
  ## The next line (without its newline). Raises `IOError` on timeout or EOF.
  let start = getMonoTime()
  while true:
    let nl = r.buf.find('\n')
    if nl >= 0:
      result = r.buf[0 ..< nl]
      r.buf = r.buf[nl + 1 .. ^1]
      return
    if r.eof:
      raise newException(EOFError, "end of stream; partial line: " & r.buf)
    let left = timeoutMs - int((getMonoTime() - start).inMilliseconds)
    if left <= 0:
      raise newException(IOError, "no line within " & $timeoutMs & " ms")
    discard r.fill(min(left, 200))

proc noLineWithin*(r: var LineReader, ms: int): bool =
  ## True when no complete line arrives within `ms`.
  try:
    discard r.readLine(ms)
    false
  except IOError:
    true

# ---------------------------------------------------------------------------
# The serve daemon over stdio
# ---------------------------------------------------------------------------

type
  Daemon* = object
    p*: Process
    reader*: LineReader
    ready*: JsonNode

proc startServe*(args: seq[string], env: StringTableRef): Daemon =
  ## Start `guiassert serve …` and read its ready line.
  result.p = startProcess(contractBin(), args = args, env = env, options = {})
  result.reader = initLineReader(result.p)
  let first = result.reader.readLine(30_000)
  result.ready = parseJson(first)

proc send*(d: var Daemon, line: string) =
  ## Write one request line.
  d.p.inputStream.write(line & "\n")
  d.p.inputStream.flush()

proc send*(d: var Daemon, msg: JsonNode) = d.send($msg)

proc recv*(d: var Daemon, timeoutMs = 30_000): JsonNode =
  ## The next message, parsed.
  parseJson(d.reader.readLine(timeoutMs))

proc recvRaw*(d: var Daemon, timeoutMs = 30_000): string =
  ## The next message line as written.
  d.reader.readLine(timeoutMs)

proc closeInput*(d: var Daemon) =
  ## EOF on the daemon's stdin.
  d.p.inputStream.close()

proc finish*(d: var Daemon, timeoutMs = 30_000): int =
  ## Wait for the daemon to exit; returns its exit code (kills it on timeout).
  result = d.p.waitForExit(timeoutMs)
  if d.p.running:
    d.p.kill()
    result = -1
  d.p.close()

proc runReq*(id: string, argv: seq[string]): JsonNode =
  %*{"v": 1, "id": id, "op": "run", "argv": argv}

proc envelopeText*(resultLine: string): string =
  ## The envelope of a `result` line exactly as written: the daemon puts it
  ## last, so it is everything between `"envelope":` and the final `}`.
  let key = "\"envelope\":"
  let i = resultLine.find(key)
  doAssert i >= 0 and resultLine.endsWith("}"), "not a result line: " & resultLine
  resultLine[i + key.len ..< resultLine.len - 1]

# ---------------------------------------------------------------------------
# The specification
# ---------------------------------------------------------------------------

proc specText*(): string = readFile(specPath)

proc splitCells(row: string): seq[string] =
  ## The cells of a Markdown table row; `\|` inside a cell is a literal bar.
  var cell = ""
  var i = 0
  let s = row.strip
  if not s.startsWith("|"): return
  i = 1
  while i < s.len:
    if s[i] == '\\' and i + 1 < s.len and s[i + 1] == '|':
      cell.add '|'
      i += 2
      continue
    if s[i] == '|':
      result.add cell.strip
      cell = ""
    else:
      cell.add s[i]
    inc i

proc specVerbRows*(): OrderedTable[string, string] =
  ## Every row of the verb tables of spec §7.5 (tables whose header is
  ## `| Verb | Arguments | `data` |`), as verb -> data cell.
  let text = specText()
  let start = text.find("### 7.5 Verbs and payloads")
  let stop = text.find("### 7.6 State directory")
  doAssert start >= 0 and stop > start, "spec §7.5 not found in " & specPath
  var inTable = false
  for line in text[start ..< stop].splitLines:
    let cells = splitCells(line)
    if cells.len == 3 and cells[0] == "Verb" and cells[1] == "Arguments":
      inTable = true
      continue
    if not inTable: continue
    if cells.len == 0:
      inTable = false
      continue
    if cells[0].startsWith("---"): continue
    doAssert cells.len == 3, "malformed verb row: " & line
    doAssert cells[0].startsWith("`") and cells[0].endsWith("`"), "verb cell: " & line
    result[cells[0][1 .. ^2]] = cells[2]

proc specCommonObjects*(): string =
  ## The `Common objects` code block of spec §7.5.
  let text = specText()
  let a = text.find("Common objects:")
  let b = text.find("```jsonc", a)
  let c = text.find("```", b + 8)
  doAssert a >= 0 and b > a and c > b, "spec common objects block not found"
  text[b + 8 ..< c]

# ---------------------------------------------------------------------------
# One successful invocation of every verb
# ---------------------------------------------------------------------------

proc everyVerbScenario*(work: string): seq[seq[string]] =
  ## One argv per contract verb, in an order where each succeeds against the
  ## built-in `fixture-form` scenario in a fresh state directory (later steps
  ## use what earlier ones created: the session `s1`, the launched app 4243,
  ## the recording `rec-2`, the screenshot and the watched frames).
  @[@["version"],
    @["capabilities"],
    @["permissions", "--request", "accessibility"],
    @["session-start", "--kind", "headless", "--name", "s1"],
    @["session-list"],
    @["session-info", "s1"],
    @["apps"],
    @["app-launch", "--bundle-id", "dev.example.Notes"],
    @["displays"],
    @["windows"],
    @["window-focus", "fixture-window-1"],
    @["window-set-bounds", "fixture-window-1", "--bounds", "100,80,600,400"],
    @["screenshot", "--out", work / "shot.png"],
    @["record", "--out", work / "rec1", "--duration-ms", "200"],
    @["record-start", "--out", work / "rec2"],
    @["record-stop", "rec-2"],
    @["recordings"],
    @["ocr", "--image", work / "shot.png"],
    @["tree", "--pid", "4242"],
    @["find", "--role", "button"],
    @["element", "/app[4242]/window[0]/text-field[0]"],
    @["element-action", "/app[4242]/window[0]/text-field[0]", "set-value", "--value", "Ada"],
    @["wait", "--element", "--role", "text-field", "--wait-ms", "1000", "--interval-ms", "50"],
    @["move", "--to", "10,10"],
    @["click", "--at", "190,278"],
    @["drag", "--from", "1,1", "--to", "5,5"],
    @["scroll", "--at", "10,10", "--dx", "0", "--dy", "3"],
    @["type", "hello"],
    @["key", "cmd+s"],
    @["watch", "--frames", "--out-dir", work / "frames", "--fps", "10",
      "--duration-ms", "200", "--events-file", work / "events.ndjson"],
    @["vision-compare", work / "shot.png", work / "shot.png", "--tiles", "2x2"],
    @["vision-segment", "--frames", work / "frames"],
    @["vision-windows", work / "shot.png", "--ocr"],
    @["app-quit", "4243"],
    @["session-stop", "s1"]]

proc prepareWork*(work: string) =
  ## The directories `everyVerbScenario` writes into.
  createDir(work / "frames")
