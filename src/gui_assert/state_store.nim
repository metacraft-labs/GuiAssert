## The state directory's records, locks and process checks (spec §7.6).
##
## GuiAssert keeps exactly three kinds of state, all under one state
## directory: session records (`sessions/<id>.json`), recording records
## (`recordings/<id>.json`) and the fixture backend's desktop
## (`fixture/`). This module is the one place that writes them:
##
## * directories are created mode 0700, records mode 0600 (POSIX);
## * a record is written to a temporary file in the same directory and
##   renamed over the old one, so a reader sees the old or the new record,
##   never a half-written one;
## * a record carries a `"schema"` such as `guiassert/session/1`; a record of
##   another schema family or a newer version is refused (`internal`), never
##   half-read;
## * a lock is a directory created atomically next to the record it guards,
##   holding the owner's pid; a lock whose owner process is gone is broken,
##   and one that cannot be taken in time is `backend-error` / `busy`.
##
## Used by the CLI and by backends alike, so it imports neither.

import std/[algorithm, json, options, os, strutils]

when defined(posix):
  import std/posix
else:
  import std/winlean

import ./cancel
import ./core/[contract, desktop_types]

type
  StoreError* = object of CatchableError
    ## A record could not be read or written.

  FileTooLargeError* = object of IOError
    ## `readFileCapped` refused a file larger than its limit.

const
  maxRecordBytes* = 4 shl 20
    ## The largest state record or fixture scenario GuiAssert reads.
  maxTextFileBytes* = 1 shl 20
    ## The largest `type --text-file` GuiAssert reads.
  maxImageFileBytes* = 256 shl 20
    ## The largest PNG file GuiAssert reads (the decoder bounds the pixels
    ## separately, `core/png.maxPngPixels`).

proc readFileCapped*(path: string, maxBytes: int): string =
  ## The whole file at `path`, refusing one larger than `maxBytes` so that
  ## no input a caller names can make GuiAssert read without bound. Raises
  ## `FileTooLargeError` for a file over the limit (or one that grows past
  ## its size while it is read), and `IOError` (as `readFile` does) when the
  ## file cannot be opened or read.
  var f: File
  if not open(f, path, fmRead):
    raise newException(IOError, "cannot open " & path)
  try:
    let size = getFileSize(f)
    if size > maxBytes:
      raise newException(FileTooLargeError, path & " is " & $size &
        " bytes, larger than the limit of " & $maxBytes)
    result = newString(int(size))
    if size > 0 and readBuffer(f, addr result[0], int(size)) != int(size):
      raise newException(IOError, "short read from " & path)
    # A file that grew after its size was taken is refused rather than
    # silently truncated.
    var probe: char
    if readBuffer(f, addr probe, 1) != 0:
      raise newException(FileTooLargeError, path & " grew while it was read")
  finally:
    close(f)

proc ensurePrivateDir*(dir: string) =
  ## Create `dir` (and missing parents) and make it mode 0700 on POSIX.
  ## Raises `StoreError` when it cannot be created.
  try:
    createDir(dir)
    when defined(posix):
      setFilePermissions(dir, {fpUserRead, fpUserWrite, fpUserExec})
  except OSError as e:
    raise newException(StoreError, "cannot create the state directory " &
      dir & ": " & e.msg)

proc writePrivateFile*(path, content: string) =
  ## Write `content` to `path` atomically: a temporary file in the same
  ## directory, created mode 0600 (POSIX), then renamed over `path`.
  ## Raises `StoreError`.
  let dir = path.parentDir
  let tmp = dir / ("." & path.extractFilename & ".tmp-" & $getCurrentProcessId() &
                   "-" & $getThreadId())
  try:
    when defined(posix):
      let fd = posix.open(tmp.cstring, O_WRONLY or O_CREAT or O_TRUNC, Mode(0o600))
      if fd < 0:
        raise newException(OSError, osErrorMsg(osLastError()))
      var off = 0
      while off < content.len:
        let n = posix.write(fd, unsafeAddr content[off], content.len - off)
        if n < 0:
          let err = osErrorMsg(osLastError())
          discard posix.close(fd)
          raise newException(OSError, err)
        off += n
      if posix.close(fd) != 0:
        raise newException(OSError, osErrorMsg(osLastError()))
    else:
      writeFile(tmp, content)
    moveFile(tmp, path)
  except OSError, IOError:
    let msg = getCurrentExceptionMsg()
    try: removeFile(tmp) except OSError: discard
    raise newException(StoreError, "cannot write " & path & ": " & msg)

proc writeRecord*(path, schema: string, body: JsonNode) =
  ## Write a record: `body` (an object) with `"schema"` as its first key.
  var rec = %*{"schema": schema}
  for k, v in body.pairs: rec[k] = v
  ensurePrivateDir(path.parentDir)
  writePrivateFile(path, pretty(rec) & "\n")

proc readRecord*(path, schema: string): Option[JsonNode] =
  ## The record at `path` without its `"schema"` key, or none when there is
  ## no such file. `schema` is `<family>/<version>`; a record of another
  ## family, of a newer version, or that is not a JSON object raises
  ## `ContractError` (`internal` / `exception`), so it is never half-read.
  if not fileExists(path): return none(JsonNode)
  var text: string
  try:
    text = readFileCapped(path, maxRecordBytes)
  except IOError as e:
    raise newContractError(ekInternal, "exception",
      "cannot read the state record " & path & ": " & e.msg)
  var n: JsonNode
  try:
    n = parseJson(text)
  except CatchableError as e:
    raise newContractError(ekInternal, "exception",
      "the state record " & path & " is not JSON: " & e.msg)
  if n.kind != JObject or not n.hasKey("schema") or n["schema"].kind != JString:
    raise newContractError(ekInternal, "exception",
      "the state record " & path & " has no schema")
  let got = n["schema"].getStr
  if got != schema:
    let fam = schema.rsplit('/', 1)[0]
    let why = if got.startsWith(fam & "/"): "a newer or unknown version"
              else: "another kind of record"
    raise newContractError(ekInternal, "exception",
      "the state record " & path & " is " & why & " (" & got & ", expected " &
      schema & "); refusing to read it")
  n.delete("schema")
  some(n)

proc removeRecord*(path: string) =
  ## Delete a record; a missing one is not an error.
  try: removeFile(path)
  except OSError as e:
    raise newException(StoreError, "cannot remove " & path & ": " & e.msg)

# ---------------------------------------------------------------------------
# Processes
# ---------------------------------------------------------------------------

proc processAlive*(pid: int): bool =
  ## True when a process with this pid exists and has not exited. On POSIX a
  ## child of this process that has exited is reaped first, so a zombie is
  ## reported as gone.
  if pid <= 0: return false
  when defined(posix):
    var status: cint
    let r = waitpid(Pid(pid), status, WNOHANG)
    if r == Pid(pid): return false
    if kill(Pid(pid), 0) == 0: return true
    return errno == EPERM
  else:
    const synchronize = 0x00100000'i32
    const queryLimited = 0x1000'i32
    let h = openProcess(synchronize or queryLimited, 0, DWORD(pid))
    if h == 0: return false
    var code: int32
    let ok = getExitCodeProcess(h, code)
    discard closeHandle(h)
    const stillActive = 259'i32
    return ok != 0 and code == stillActive

proc signalProcess*(pid: int, force: bool) =
  ## Ask a process to exit (SIGTERM), or kill it outright (SIGKILL) with
  ## `force`. On Windows both terminate it. A process that is already gone
  ## is not an error.
  if pid <= 0: return
  when defined(posix):
    discard kill(Pid(pid), if force: SIGKILL else: SIGTERM)
  else:
    const terminate = 0x0001'i32
    let h = openProcess(terminate, 0, DWORD(pid))
    if h != 0:
      discard terminateProcess(h, 1)
      discard closeHandle(h)

proc waitProcessGone*(pid: int, timeoutMs: int): bool =
  ## Wait up to `timeoutMs` for the process to exit; true when it did.
  var waited = 0
  while processAlive(pid):
    if waited >= timeoutMs: return false
    sleep(10)
    waited += 10
  true

# ---------------------------------------------------------------------------
# Locks
# ---------------------------------------------------------------------------

proc tryBreakStale(lockDir: string): bool =
  ## Remove the lock when its owner process is gone; true when removed.
  let owner = lockDir / "owner"
  var pid = 0
  try:
    pid = parseInt(readFileCapped(owner, maxRecordBytes).strip)
  except IOError, ValueError, OSError:
    return false        # being created right now; not stale
  if pid != 0 and not processAlive(pid):
    try:
      removeFile(owner)
      removeDir(lockDir)
      return true
    except OSError:
      return false
  false

proc acquireLock*(lockDir: string, token: CancelToken, waitMs = 10_000) =
  ## Take the lock `lockDir`, waiting up to `waitMs` (and no longer than the
  ## token's deadline). Raises `backend-error` / `busy` when it stays taken,
  ## or the token's error when it is cancelled meanwhile.
  ensurePrivateDir(lockDir.parentDir)
  var waited = 0
  while true:
    var existed = true
    try:
      existed = existsOrCreateDir(lockDir)
    except OSError as e:
      raise newException(StoreError, "cannot create lock " & lockDir & ": " & e.msg)
    if not existed:
      try:
        writeFile(lockDir / "owner", $getCurrentProcessId())
      except IOError as e:
        try: removeDir(lockDir) except OSError: discard
        raise newException(StoreError, "cannot write lock owner: " & e.msg)
      return
    if waited mod 200 == 0 and tryBreakStale(lockDir): continue
    if waited >= waitMs or token.remainingMs == 0:
      raise newContractError(ekBackendError, "busy",
        "the state lock " & lockDir & " is held by another invocation",
        remedy = "retry once the other invocation has finished")
    token.sleepCancellable(10)
    waited += 10

proc releaseLock*(lockDir: string) =
  ## Release a lock taken with `acquireLock`.
  try:
    removeFile(lockDir / "owner")
    removeDir(lockDir)
  except OSError:
    discard   # gone already; nothing to release

template withLock*(lockDir: string, token: CancelToken, body: untyped) =
  ## Run `body` holding the lock `lockDir`.
  acquireLock(lockDir, token)
  try:
    body
  finally:
    releaseLock(lockDir)

# ---------------------------------------------------------------------------
# Session records
# ---------------------------------------------------------------------------

const sessionSchema* = "guiassert/session/1"

proc sessionRecordPath*(stateDir, id: string): string =
  ## `<state-dir>/sessions/<id>.json`.
  stateDir / "sessions" / (id & ".json")

proc sessionLockDir*(stateDir, id: string): string =
  ## The per-session lock that serializes verbs mutating session `id`.
  stateDir / "sessions" / (id & ".lock")

proc readSessionRecord*(stateDir, id: string): Option[tuple[session: Session,
                                                          private: JsonNode]] =
  ## The record of session `id`, or none when there is none. A malformed
  ## record is `internal`.
  let r = readRecord(sessionRecordPath(stateDir, id), sessionSchema)
  if r.isNone: return
  var n = r.get
  if not n.hasKey("private") or n["private"].kind != JObject:
    raise newContractError(ekInternal, "exception",
      "session record " & id & " has no private part")
  let priv = n["private"]
  n.delete("private")
  try:
    result = some((Session.fromJson(n), priv))
  except JsonShapeError as e:
    raise newContractError(ekInternal, "exception",
      "session record " & id & " is malformed: " & e.msg)

proc writeSessionRecord*(stateDir: string, s: Session, private: JsonNode) =
  ## Write the record of session `s`: its contract fields plus `private`.
  var n = s.toJson
  n["private"] = private
  writeRecord(sessionRecordPath(stateDir, s.id), sessionSchema, n)

proc listSessionIds*(stateDir: string): seq[string] =
  ## The ids of every session record, sorted.
  let dir = stateDir / "sessions"
  if not dirExists(dir): return
  for k, p in walkDir(dir):
    if k == pcFile and p.endsWith(".json"):
      result.add p.extractFilename[0 ..< ^5]
  result.sort()
