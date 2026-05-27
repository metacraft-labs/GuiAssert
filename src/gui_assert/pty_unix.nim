## Minimal Unix PTY primitives used by the terminal driver.
##
## We deliberately avoid an external dependency (`nim-pty` was not available
## in the current dev shell) and implement the small surface area we need
## directly on top of `posix`. The implementation works on Linux and macOS;
## on Windows, the terminal driver is unsupported and raises at runtime.

import std/[os, posix]
import posix/termios as ptermios

when defined(windows):
  {.error: "PTY driver is not supported on Windows".}

type
  PtyPair* = object
    master*: cint     # opened master fd (O_RDWR | O_NOCTTY)
    slaveName*: string  # path returned by ptsname()
    child*: Pid       # forked child pid (0 if not spawned yet)

# Declare the BSD/POSIX pty helpers that std/posix does not surface uniformly
# across platforms.
proc posix_openpt(flags: cint): cint
  {.importc, header: "<stdlib.h>".}
proc grantpt(fd: cint): cint
  {.importc, header: "<stdlib.h>".}
proc unlockpt(fd: cint): cint
  {.importc, header: "<stdlib.h>".}
proc ptsname(fd: cint): cstring
  {.importc, header: "<stdlib.h>".}

proc setRaw(fd: cint) =
  ## Put the slave-side TTY into a near-raw mode so that bytes we send
  ## through the master arrive at the child without canonical line buffering
  ## or local echo. Without this, on macOS `cat` would buffer until a full
  ## line and inject double-echoes of the bytes we wrote.
  var t: ptermios.Termios
  if ptermios.tcGetAttr(fd, addr t) != 0:
    raise newException(OSError, "tcgetattr failed: " & $strerror(errno))
  t.c_lflag = t.c_lflag and not (ptermios.ECHO or ptermios.ICANON or
                                 ptermios.ISIG or ptermios.IEXTEN)
  t.c_iflag = t.c_iflag and not (ptermios.IXON or ptermios.ICRNL or
                                 ptermios.BRKINT or ptermios.INPCK or
                                 ptermios.ISTRIP)
  t.c_oflag = t.c_oflag and not ptermios.OPOST
  if ptermios.tcSetAttr(fd, ptermios.TCSANOW, addr t) != 0:
    raise newException(OSError, "tcsetattr failed: " & $strerror(errno))

proc openPtyPair*(): PtyPair =
  ## Allocate a master/slave PTY pair, returning an opened master fd and the
  ## slave's filesystem name. The slave is unlocked and ready to be opened by
  ## a child process.
  let flags = posix.O_RDWR or posix.O_NOCTTY
  let m = posix_openpt(flags)
  if m < 0:
    raise newException(OSError, "posix_openpt failed: " & $strerror(errno))
  if grantpt(m) != 0:
    discard close(m)
    raise newException(OSError, "grantpt failed: " & $strerror(errno))
  if unlockpt(m) != 0:
    discard close(m)
    raise newException(OSError, "unlockpt failed: " & $strerror(errno))
  let name = ptsname(m)
  if name.isNil:
    discard close(m)
    raise newException(OSError, "ptsname returned NULL")
  result = PtyPair(master: m, slaveName: $name, child: 0)

proc spawnInPty*(pty: var PtyPair, argv: openArray[string]) =
  ## Fork a child process whose stdin/stdout/stderr are wired to the slave
  ## end of `pty`. Parent keeps the master fd; child execs `argv`.
  if argv.len == 0:
    raise newException(ValueError, "spawnInPty requires at least one argv entry")
  let pid = fork()
  if pid < 0:
    raise newException(OSError, "fork failed: " & $strerror(errno))
  if pid == 0:
    # Child branch.
    discard setsid()
    let slaveFd = open(cstring(pty.slaveName), posix.O_RDWR)
    if slaveFd < 0:
      quit(127)
    # Put the slave into raw mode so echo behaviour is deterministic.
    try:
      setRaw(slaveFd)
    except OSError:
      quit(126)
    # On Linux you'd ioctl TIOCSCTTY; on macOS opening the slave after setsid
    # already attaches it as controlling tty. We close the master in the
    # child so it doesn't keep the parent end alive accidentally.
    discard close(pty.master)
    discard dup2(slaveFd, 0)
    discard dup2(slaveFd, 1)
    discard dup2(slaveFd, 2)
    if slaveFd > 2:
      discard close(slaveFd)
    # Build argv for execvp.
    var cargs = newSeq[cstring](argv.len + 1)
    for i, a in argv:
      cargs[i] = cstring(a)
    cargs[argv.len] = nil
    discard execvp(cargs[0], cast[cstringArray](addr cargs[0]))
    # If execvp returns, the exec failed.
    quit(125)
  else:
    pty.child = pid

proc writePty*(pty: PtyPair, data: string) =
  ## Write `data` to the master end. Blocks until all bytes are written.
  var remaining = data.len
  var offset = 0
  while remaining > 0:
    let n = write(pty.master, unsafeAddr data[offset], remaining)
    if n < 0:
      if errno == EINTR:
        continue
      raise newException(OSError, "write failed: " & $strerror(errno))
    offset += n
    remaining -= n

proc readPtyAvailable*(pty: PtyPair, maxBytes: int = 4096): string =
  ## Non-blocking read of up to `maxBytes` from the master fd. Returns the
  ## empty string if no data is currently available. Uses select() with a
  ## zero timeout for portability.
  var rfds: TFdSet
  FD_ZERO(rfds)
  FD_SET(pty.master, rfds)
  var tv: Timeval
  tv.tv_sec = posix.Time(0)
  tv.tv_usec = Suseconds(0)
  let r = select(pty.master + 1, addr rfds, nil, nil, addr tv)
  if r <= 0:
    return ""
  var buf = newString(maxBytes)
  let n = read(pty.master, addr buf[0], maxBytes)
  if n <= 0:
    return ""
  buf.setLen(n)
  return buf

proc closePty*(pty: var PtyPair) =
  ## Close the master fd and reap the child. Best-effort: callers should not
  ## raise from finalisation.
  if pty.master >= 0:
    discard close(pty.master)
    pty.master = -1
  if pty.child > 0:
    # Give the child a moment then kill if still alive.
    var status: cint
    var waited = waitpid(pty.child, status, posix.WNOHANG)
    if waited == 0:
      discard kill(pty.child, SIGTERM)
      # Wait briefly for graceful shutdown.
      for _ in 0 .. 20:
        waited = waitpid(pty.child, status, posix.WNOHANG)
        if waited != 0:
          break
        sleep(10)
      if waited == 0:
        discard kill(pty.child, SIGKILL)
        discard waitpid(pty.child, status, 0)
    pty.child = 0
