## Removing a private desktop session's runtime directory so that nothing of
## the session is left behind (Linux).
##
## A private sway or GNOME Shell target runs in a directory of its own under
## /tmp (`XDG_RUNTIME_DIR`). Removing it once the compositor and the bus are
## stopped is not enough on its own, as measured on the live suites:
##
## * a process the session started may still be running and write into it
##   again after it was removed: GNOME Shell's `ibus-daemon` recreates
##   `$XDG_CONFIG_HOME/ibus/bus/…`, parents included, so a directory holding
##   only `config/ibus/bus` reappears;
## * the document portal's FUSE filesystem (`doc`) can still be mounted, and
##   `removeDir` stops at the first entry it cannot remove, leaving the whole
##   tree.
##
## `removeRuntimeTree` therefore first ends this user's processes whose
## environment names the directory as their `XDG_RUNTIME_DIR` (when asked:
## the directory is the session's own, made fresh for it, so only the
## session's processes and the clients started into it name it), detaches
## every mount below it, and removes it, retrying for a bounded time while
## something still holds it.
##
## proc(5): `/proc/<pid>/environ` is readable for a process of one's own
## only; field 22 of `/proc/<pid>/stat` is the start time, which with the pid
## names one process (a recycled pid is never signalled); `/proc/self/mounts`
## lists the mount points, with blanks written as octal escapes (fstab(5)).

import std/[algorithm, os, osproc, posix, strutils, times]

proc readProcFile*(path: string, limit = 1 shl 20): string =
  ## The start of a /proc file (at most `limit` bytes), "" when it cannot be
  ## read. Raw reads: walking every process must not raise on the common
  ## "not ours" or "already gone" case.
  let fd = posix.open(path.cstring, O_RDONLY or O_CLOEXEC)
  if fd < 0: return ""
  defer: discard posix.close(fd)
  var buf: array[16384, char]
  while result.len < limit:
    let n = posix.read(fd, addr buf[0], buf.len)
    if n <= 0: break
    let old = result.len
    result.setLen(old + n)
    copyMem(addr result[old], addr buf[0], n)

proc procStartTime*(pid: int): string =
  ## Field 22 of `/proc/<pid>/stat`, "" for no such process or a zombie.
  let text = readProcFile("/proc/" & $pid & "/stat", 4096)
  let close = text.rfind(')')
  if close < 0: return ""
  let fields = text[close + 1 .. ^1].strip.splitWhitespace
  if fields.len < 20 or fields[0] == "Z" or fields[0] == "X": return ""
  fields[19]

proc environHas*(environ, entry: string): bool =
  ## Whether the NUL-separated `environ` holds exactly `entry`.
  var i = environ.find(entry)
  while i >= 0:
    let starts = i == 0 or environ[i - 1] == '\0'
    let ends = i + entry.len == environ.len or environ[i + entry.len] == '\0'
    if starts and ends: return true
    i = environ.find(entry, i + 1)
  false

proc processesNaming*(dir: string): seq[tuple[pid: int, startTime: string]] =
  ## This user's live processes (but this one) whose environment sets
  ## `XDG_RUNTIME_DIR` to exactly `dir`.
  if dir.len == 0: return
  let entry = "XDG_RUNTIME_DIR=" & dir
  let uid = getuid()
  let me = getCurrentProcessId()
  for kind, path in walkDir("/proc"):
    let name = path.extractFilename
    if name.len == 0 or not name.allCharsInSet(Digits): continue
    var st: Stat
    if stat(path.cstring, st) != 0 or st.st_uid != uid: continue
    let pid = parseInt(name)
    if pid == me: continue
    if environHas(readProcFile(path / "environ"), entry):
      let started = procStartTime(pid)
      if started.len > 0: result.add (pid, started)

proc endProcessesNaming*(dir: string, graceMs = 2000) =
  ## SIGTERM every process `processesNaming(dir)` finds, SIGKILL whatever
  ## still runs `graceMs` later, then once more for anything one of them
  ## started meanwhile. Each is signalled only while its pid still has the
  ## start time it was found with.
  var procs = processesNaming(dir)
  for p in procs:
    if procStartTime(p.pid) == p.startTime: discard kill(Pid(p.pid), SIGTERM)
  let deadline = epochTime() + graceMs / 1000
  while procs.len > 0:
    var left: seq[tuple[pid: int, startTime: string]]
    for p in procs:
      if procStartTime(p.pid) == p.startTime: left.add p
    procs = left
    if procs.len == 0: break
    if epochTime() >= deadline:
      for p in procs: discard kill(Pid(p.pid), SIGKILL)
      break
    sleep(20)
  for p in processesNaming(dir):
    discard kill(Pid(p.pid), SIGKILL)

proc unescapeMount(s: string): string =
  ## A /proc/self/mounts field with its octal escapes (`\040`) decoded.
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 3 < s.len and s[i + 1 .. i + 3].allCharsInSet({'0' .. '7'}):
      result.add char(parseOctInt(s[i + 1 .. i + 3]))
      i += 4
    else:
      result.add s[i]
      inc i

proc mountsUnder*(dir: string): seq[string] =
  ## The mount points strictly below `dir`, deepest first.
  if dir.len == 0: return
  let prefix = dir & "/"
  for line in readProcFile("/proc/self/mounts").splitLines:
    let f = line.splitWhitespace
    if f.len >= 2:
      let point = unescapeMount(f[1])
      if point.startsWith(prefix): result.add point
  result.sort(proc (a, b: string): int = cmp(b.len, a.len))

proc detach(point: string) =
  ## Lazily unmount `point` (a FUSE mount of this user: fusermount3 /
  ## fusermount `-u -z`, fusermount3(1)); never raises.
  for tool in ["fusermount3", "fusermount"]:
    let exe = findExe(tool)
    if exe.len == 0: continue
    try:
      let p = startProcess(exe, args = ["-uz", point], options = {})
      discard p.waitForExit(2000)
      p.close()
    except OSError: discard
    return

proc removeTree(dir: string) =
  ## Remove what can be removed under `dir`, then `dir`: unlike `removeDir`,
  ## an entry that cannot be removed does not stop the others. Symbolic
  ## links are removed, never followed.
  for kind, path in walkDir(dir):
    if kind == pcDir: removeTree(path)
    else:
      try: removeFile(path)
      except OSError: discard
  try: removeDir(dir, checkDir = false)
  except OSError: discard

proc removeRuntimeTree*(dir: string, endProcesses = true, waitMs = 2000) =
  ## Remove the session runtime directory `dir` (module doc): with
  ## `endProcesses`, first end the processes that name it; then detach the
  ## mounts below it and remove it, retrying every 50 ms for up to `waitMs`
  ## while it is still there. Never raises.
  if dir.len == 0: return
  if endProcesses: endProcessesNaming(dir)
  let deadline = epochTime() + waitMs / 1000
  while true:
    for point in mountsUnder(dir): detach(point)
    removeTree(dir)
    if not dirExists(dir) or epochTime() >= deadline: return
    sleep(50)
