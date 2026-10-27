## The private Linux sessions (spec §6.1, §6.3, GS10): what the
## `linux-sway`, `linux-gnome` and `linux-xvfb` session backends share. Each
## of them is a `PrivateServer` (its own module says how its display server
## is started inside the session host); this module gives every one of them
## the same session lifecycle, records, readiness, environment contract,
## accessibility bus and clean-up.
##
## **The session host.** A private session outlives the `session-start` that
## made it: it is owned by a detached **session host**, `guiassert
## __linux-session-host --state-dir <dir> <id>` (internal, not part of the
## contract), started in a session of its own (`setsid`, double fork,
## standard streams on `<state-dir>/sessions/<id>.log`). The host starts the
## display server and everything the session needs, then supervises it:
##
## 1. the server (`PrivateServer.hostStart`): its own runtime directory under
##    `/tmp`, which the host makes first, named by the session's tag
##    (`sessionRuntimeDir`, so it is found and removed even when the host is
##    killed part way), its own session bus, and the display server;
## 2. the session's **AT-SPI bus** (`startAtspiBus`): at-spi-bus-launcher on
##    the session bus (the pinned one, `GUI_ASSERT_ATSPI_BUS_LAUNCHER`, unless
##    a client of the session already had the bus activate one), ready when
##    `org.a11y.Bus.GetAddress` names a bus inside the session's runtime
##    directory and its registry answers; then `org.a11y.Status.IsEnabled` is
##    set, as an assistive technology does on starting, because Qt's bridge
##    registers its applications only while it is true (GTK's always do).
##    AT-SPI: https://gitlab.gnome.org/GNOME/at-spi2-core/-/blob/main/xml/Bus.xml
##    and https://gitlab.gnome.org/GNOME/at-spi2-core/-/blob/main/xml/Status.xml;
## 3. optionally a **VNC endpoint**, started by the server (spec §6.5): with
##    `--vnc` a TCP listener on 127.0.0.1 and nowhere else
##    (`waitVncListening` checks every TCP socket the server holds), with
##    `--vnc-socket` (contract 1.1) a Unix socket `vnc.sock` in the session's
##    0700 runtime directory and no TCP listener (`waitVncSocketListening`);
## 4. the host then writes `<id>.ready` (the session's environment, its
##    runtime directory and VNC endpoint) for the starter, and supervises:
##    every 100 ms it checks that the record still names it and that the
##    display server and the AT-SPI bus still run. A display server that
##    exits puts the record in state `error` (`compositor-exited`) and the
##    host tears the session down; `session-stop` (SIGTERM) tears it down too.
##
## Every process of the session carries `GUIASSERT_LINUX_SESSION_TAG=<tag>`
## in its environment, a random 128-bit value recorded in the session's
## record: the host is started with it and everything it starts inherits it
## (a bus-activated service included, whatever reparented it). Tearing a
## session down ends exactly the processes that carry the tag
## (`sweepTagged`), so a session whose host was killed leaves nothing behind
## once it is stopped, and nothing that is not the session's is ever
## signalled. Applications started INTO the session (`app-launch`) do not
## carry it: they start from the caller's environment, not the host's.
##
## **Readiness** (spec §6.1, C10). `session-start` returns only a `running`
## session: the host has written `<id>.ready` (its display server answers
## and its AT-SPI bus answers a registry read) and the starter's own read of
## the session's displays through its capture backend succeeded. Otherwise,
## within the readiness bound (10 s, or the `--timeout-ms` deadline less
## 250 ms when that is shorter), the start fails with exit 5 /
## `session-failed`, at once when the host exits or reports that it could
## not start; everything it started is stopped and no record is left.
##
## **Names** (C10). A `--name` that a recorded session uses (running,
## starting or in error; a stopped session leaves no record) is exit 2 /
## `name-in-use` with `details.name` and `details.state`. A generated id is
## `<prefix>-<n>` with the first `n` no record uses. Both are decided under
## one state lock, so two concurrent starts never get one id.
##
## **Environment** (C6). `Session.env` is every variable a process in the
## session needs (the display, the runtime directory, the session bus, the
## AT-SPI bus, the session type and its settings), and `Session.envUnset`
## every variable it must not inherit from the caller because it would route
## the process to another display or bus, or switch its accessibility off
## (`baseEnvUnset`, plus the server's own, minus what `env` sets). A process
## spawned into the session starts from the caller's environment, removes
## `envUnset`, then sets `env` (`composeSessionEnv`); `app-launch` does
## exactly that, then applies `--env`.
##
## **Reconciliation** (C9). Every read of a session (`session-info`,
## `session-list`, and every verb that targets it) checks that its host still
## runs (pid AND start time, so a recycled pid is not mistaken for it) and
## that its display server accepts a connection; a session that fails either
## is reported `state: "error"` with `stateReason` `host-exited` or
## `compositor-not-answering`, never as running, and every verb but the
## session verbs answers exit 4 / `session-not-running` for it.
##
## **Isolation** is `{pixels, input, clipboard}` all true for the three
## kinds (spec §6.3): nothing else connects to their private display server.
## The VNC endpoint is the exception a caller asks for: it is unauthenticated
## (the contract's `Session.vnc` carries no credential) and bound to the
## loopback interface, so any local user can view and drive the session
## through it while it runs.

import std/[algorithm, json, net, options, os, osproc, posix, sequtils, strtabs, strutils, sysrand,
            tables]

import ../../core/[contract, desktop_types, geometry, interfaces]
import ../../[cancel, state_store]
import ../capture/linux_common
import ../tree/[dbus_wire, linux_atspi]
import ../../desktop_env/runtime_dir
import ./linux_host

export linux_host.displayAnswers, linux_host.sessionNotRunning

const
  readinessBoundMs* = 10_000
    ## How long `session-start` waits for a session to become ready, at most
    ## (spec §6.1); a `--timeout-ms` deadline shortens it.
  readinessMarginMs* = 250
    ## Kept back from the deadline so the readiness failure is reported as
    ## `session-failed` before the deadline itself expires.
  hostVerb* = "__linux-session-host"
    ## The internal verb of the session host.
  sessionTagVar* = "GUIASSERT_LINUX_SESSION_TAG"
    ## The variable every process of a session carries (module doc).
  linuxPrivateBackendNames* = ["linux-sway", "linux-gnome", "linux-xvfb"]
    ## The session backends that start private sessions.
  defaultWidth* = 1280
  defaultHeight* = 800
    ## The size of a session started without --width / --height.
  baseEnvUnset* = ["DISPLAY", "WAYLAND_DISPLAY", "WAYLAND_SOCKET", "SWAYSOCK", "I3SOCK",
    "XAUTHORITY", "AT_SPI_BUS_ADDRESS", "DBUS_SESSION_BUS_ADDRESS", "NO_AT_BRIDGE",
    "GTK_A11Y", "GDK_BACKEND", "QT_QPA_PLATFORM", "XDG_CURRENT_DESKTOP",
    "XDG_SESSION_DESKTOP", "DESKTOP_SESSION", "XDG_SESSION_ID", "XDG_SEAT", "XDG_VTNR",
    "XDG_ACTIVATION_TOKEN", "DESKTOP_STARTUP_ID", "GNOME_SETUP_DISPLAY", "GTK_IM_MODULE",
    "QT_IM_MODULE", "XMODIFIERS", "GSETTINGS_BACKEND", "XDG_DESKTOP_PORTAL_DIR"]
    ## What a process spawned into any private session must not inherit from
    ## the caller: the host's display, bus and AT-SPI bus; `NO_AT_BRIDGE`,
    ## `GTK_A11Y` (which switch the toolkits' accessibility off),
    ## `GDK_BACKEND` and `QT_QPA_PLATFORM` (which route a toolkit to another
    ## display server); the host session's identity and activation tokens;
    ## and the host's input method and settings backends, which would be
    ## looked for on the private session bus, where they are not. A variable
    ## the session sets itself is in `Session.env` instead.
  hostStopWaitMs = 10_000
    ## How long `session-stop` waits for the host's orderly teardown (a
    ## GNOME Shell takes a few seconds) before it kills the host.
  sweepGraceMs = 2000
    ## How long a session process gets between SIGTERM and SIGKILL.
  superviseMs = 100
    ## The host's supervision period (how soon it notices a dead server).
  unacknowledgedMs = readinessBoundMs + 5000
    ## A host whose starter never takes the session over (it was killed
    ## while waiting) tears the session down after this long.
  rfbBannerLen = 12
    ## "RFB xxx.yyy\n" (RFC 6143 §7.1.1).

type
  HostSpec* = object
    ## What a session host is asked to start (from the session's record).
    id*: string
    width*, height*: int
    scale*: float
    vnc*: bool
    vncSocket*: bool
      ## `--vnc-socket`: VNC on `vncSocketPath(runtimeDir)` (spec §6.5).
    runtimeDir*: string
      ## The session's private runtime directory, made by the host (mode
      ## 0700) before the server starts (`sessionRuntimeDir`); the server
      ## runs everything in it.

  ServerRun* = object
    ## A display server as its host started it.
    env*: OrderedTable[string, string]
      ## The session's environment (without the AT-SPI bus, which the host
      ## adds).
    runtimeDir*: string
      ## The session's private runtime directory (removed at teardown).
    vnc*: Option[VncEndpoint]
    vncSocket*: Option[string]
      ## The owner-only VNC socket's path (`--vnc-socket`).
    alive*: proc (): string {.closure.}
      ## "" while the server runs, else why it does not (a `stateReason`).
    stop*: proc () {.closure.}
      ## Stop everything the server started; never raises.

  PrivateServer* = object
    ## One kind of private session (`linux_sway`, `linux_gnome`,
    ## `linux_xvfb`).
    name*: string                    ## the session backend's name
    idPrefix*: string                ## generated ids are `<prefix>-<n>`
    backends*: SessionBackends       ## what the session's verbs select (§3.4 rule 5)
    envUnset*: seq[string]           ## added to `baseEnvUnset`
    supportsVnc*: bool
    supportsScale*: bool
    preflight*: proc (env: Table[string, string], vnc: bool) {.closure.}
      ## In the starter, before anything is started: raise exit 4 /
      ## `missing-tool` for a tool or file the session needs and cannot have.
    hostStart*: proc (spec: HostSpec): ServerRun {.closure.}
      ## In the session host: start the server. Raises with a message that
      ## names what failed (no captured content: a server's startup log
      ## holds none).

  LinuxPrivateConfig* = object
    ## What a private session backend runs with.
    env*: Table[string, string]
      ## The invocation's environment (for a verb in a private session, the
      ## session's, `composeSessionEnv`).
    token*: CancelToken
    stateDir*: string
    selfExe*: string                 ## the guiassert executable (the host)
    host*: LinuxHostConfig
      ## The linux-host configuration of the same invocation: apps, launches
      ## and quits of a private session are linux-host's code run with the
      ## session's environment.
    displays*: proc (env: Table[string, string], capture: string): seq[Display] {.closure.}
      ## The displays a session with environment `env` has, read through its
      ## capture backend `capture`; raises when they cannot be read.

  AtspiRun = object
    launcher: Process   ## nil when the bus was there already
    address: string

proc failed(backend, msg: string): ref BackendError =
  newBackendError(BackendError, backend, "session-failed", msg)

proc missingTool*(backend, msg, remedy: string): ref BackendUnavailableError =
  ## Exit 4 / `missing-tool`.
  result = unavailable(backend, "missing-tool", msg)
  result.remedy = remedy

proc unsupportedOption*(backend, msg: string, remedy = ""): ref BackendUnavailableError =
  ## Exit 4 / `unsupported-option`.
  result = unavailable(backend, "unsupported-option", msg)
  result.remedy = remedy

# ---------------------------------------------------------------------------
# Pure parts (unit-tested in tests/tlinux_session.nim)
# ---------------------------------------------------------------------------

proc composeSessionEnv*(caller: Table[string, string], env: OrderedTable[string, string],
                        envUnset: openArray[string]): Table[string, string] =
  ## The environment of a process spawned into a session (spec §6.1): the
  ## caller's, minus every `envUnset` variable, plus every `env` variable.
  result = caller
  for k in envUnset: result.del k
  for k, v in env: result[k] = v

proc composeSessionEnv*(caller: Table[string, string], s: Session): Table[string, string] =
  ## `composeSessionEnv` for session `s`.
  composeSessionEnv(caller, s.env, s.envUnset)

proc envUnsetFor*(serverUnset: openArray[string],
                  env: OrderedTable[string, string]): seq[string] =
  ## `Session.envUnset`: `baseEnvUnset` and the server's own, each once,
  ## minus every variable the session sets (an `env` key is never also in
  ## `envUnset`).
  for k in @baseEnvUnset & @serverUnset:
    if k notin env and k notin result: result.add k

proc readinessBound*(remainingMs: int): int =
  ## The readiness bound (spec §6.1): 10 s, or the deadline less 250 ms when
  ## that is shorter (never negative).
  if remainingMs == high(int): return readinessBoundMs
  max(0, min(readinessBoundMs, remainingMs - readinessMarginMs))

proc generatedId*(prefix: string, taken: proc (id: string): bool): string =
  ## `<prefix>-<n>` with the smallest `n` >= 1 that `taken` refuses.
  var n = 1
  while taken(prefix & "-" & $n): inc n
  prefix & "-" & $n

type
  TcpSocketRow* = object
    ## One row of /proc/net/tcp or /proc/net/tcp6 (proc_net_tcp(5)).
    localAddr*: string   ## the hex address as the kernel writes it
    localPort*: int
    state*: int          ## 0x0A is LISTEN
    inode*: string

proc parseProcNetTcp*(text: string): seq[TcpSocketRow] =
  ## The rows of a /proc/net/tcp{,6} table (proc_net_tcp(5): the header
  ## line, then `sl local_address rem_address st … uid timeout inode …`).
  ## Malformed rows are skipped.
  var first = true
  for line in text.splitLines:
    if first:
      first = false
      continue
    let f = line.splitWhitespace
    if f.len < 10: continue
    let local = f[1].split(':')
    if local.len != 2: continue
    try:
      result.add TcpSocketRow(localAddr: local[0], localPort: fromHex[int](local[1]),
                              state: fromHex[int](f[3]), inode: f[9])
    except ValueError:
      discard

const
  tcpListen = 0x0A
  ipv4Loopback = "0100007F"
    ## 127.0.0.1 as /proc/net/tcp writes it (host byte order, little-endian).

proc listenersOn*(rows: seq[TcpSocketRow], port: int): seq[TcpSocketRow] =
  ## The listening sockets of `rows` on `port`.
  rows.filterIt(it.state == tcpListen and it.localPort == port)

proc isLoopbackOnly*(v4, v6: seq[TcpSocketRow], port: int): bool =
  ## Whether the listeners on `port` are all on 127.0.0.1 (and at least one
  ## is): no IPv4 wildcard or other address, and no IPv6 listener at all
  ## (an IPv6 wildcard socket accepts IPv4 too unless it is v6-only).
  let l4 = listenersOn(v4, port)
  l4.len > 0 and l4.allIt(it.localAddr == ipv4Loopback) and listenersOn(v6, port).len == 0

proc tcpListenersOf*(v4, v6: seq[TcpSocketRow], inodes: seq[string]):
    seq[TcpSocketRow] =
  ## The listening TCP sockets (IPv4 and IPv6) among the socket `inodes` of
  ## one process.
  (v4 & v6).filterIt(it.state == tcpListen and it.inode in inodes)

proc vncTcpVerdict*(v4, v6: seq[TcpSocketRow], inodes: seq[string], port: int): string =
  ## Whether the VNC server holding socket `inodes` serves `--vnc` as spec
  ## §6.5 says: "" when it listens on 127.0.0.1:`port`, nothing else
  ## listens on that port, and it holds no other listening TCP socket;
  ## otherwise why not ("not-listening" while it has not bound yet). GS17:
  ## x11vnc also listened on [::1]:5900, which a check of `port` alone did
  ## not see.
  let mine = tcpListenersOf(v4, v6, inodes)
  if not mine.anyIt(it.localPort == port and it.localAddr == ipv4Loopback):
    return "not-listening"
  if not isLoopbackOnly(v4, v6, port):
    return "the VNC server listens on port " & $port & " beyond 127.0.0.1"
  for r in mine:
    if r.localPort != port or r.localAddr != ipv4Loopback:
      return "the VNC server also listens on " &
        (if r.localAddr.len > 8: "an IPv6 address" else: "another address") &
        " at port " & $r.localPort
  ""

type
  UnixSocketRow* = object
    ## One row of /proc/net/unix (proc(5): `Num RefCount Protocol Flags Type
    ## St Inode Path`).
    flags*: int          ## __SO_ACCEPTCON (0x10000): a listening socket
    inode*: string
    path*: string        ## "" for an unnamed socket; "@…" for an abstract one

const soAcceptCon = 0x10000

proc parseProcNetUnix*(text: string): seq[UnixSocketRow] =
  ## The rows of /proc/net/unix. Malformed rows are skipped.
  var first = true
  for line in text.splitLines:
    if first:
      first = false
      continue
    let f = line.splitWhitespace
    if f.len < 7: continue
    try:
      result.add UnixSocketRow(flags: fromHex[int](f[3]), inode: f[6],
                               path: (if f.len > 7: f[7 .. ^1].join(" ") else: ""))
    except ValueError:
      discard

proc vncSocketVerdict*(unixRows: seq[UnixSocketRow], v4, v6: seq[TcpSocketRow],
                       inodes: seq[string], path: string): string =
  ## Whether the VNC server holding socket `inodes` serves `--vnc-socket` as
  ## spec §6.5 says: "" when one of its sockets listens at `path` and it
  ## holds no listening TCP socket; otherwise why not ("not-listening" while
  ## it has not bound yet).
  if not unixRows.anyIt(it.path == path and it.inode in inodes and
                        (it.flags and soAcceptCon) != 0):
    return "not-listening"
  let tcp = tcpListenersOf(v4, v6, inodes)
  if tcp.len > 0:
    return "the VNC server also listens on TCP port " & $tcp[0].localPort
  ""

proc vncSocketPath*(runtimeDir: string): string =
  ## The owner-only VNC socket of a session (`--vnc-socket`): `vnc.sock` in
  ## its 0700 runtime directory.
  runtimeDir / "vnc.sock"

proc isRfbBanner*(s: string): bool =
  ## Whether `s` is an RFB ProtocolVersion message, "RFB 003.008\n"
  ## (RFC 6143 §7.1.1: "RFB xxx.yyy\n", three-digit major and minor).
  s.len == rfbBannerLen and s.startsWith("RFB ") and s[11] == '\n' and s[7] == '.' and
    s[4 .. 6].allCharsInSet(Digits) and s[8 .. 10].allCharsInSet(Digits)

proc newTag*(): string =
  ## A fresh session tag: 128 random bits, hex.
  let bytes = urandom(16)
  for b in bytes: result.add toHex(int(b), 2).toLowerAscii

proc runtimePrefixOf*(backend: string): string =
  ## The name prefix of a private session's runtime directory: `gaxv-` for
  ## linux-xvfb, `guienv-` (the desktop-environment targets') for
  ## linux-sway and linux-gnome. `removeRuntimeDir` removes only these.
  if backend == "linux-xvfb": "gaxv-" else: "guienv-"

proc sessionRuntimeDir*(backend, tag: string): string =
  ## The runtime directory of the session of `backend` tagged `tag`:
  ## `/tmp/<prefix><the tag's first 64 bits>`. It is named by the tag, so
  ## whoever holds the record (a starter undoing a start, `session-stop`
  ## after the host was killed) removes it even when the host died before
  ## it could report it and no live process of the session names it. The
  ## host makes it with mkdir(2), which fails when the name exists, so it
  ## is never a directory someone else made. "" for a malformed tag.
  if tag.len != 32 or not tag.allCharsInSet(HexDigits): return ""
  "/tmp/" & runtimePrefixOf(backend) & tag[0 ..< 16]

# ---------------------------------------------------------------------------
# Records and files
# ---------------------------------------------------------------------------

proc sessionsDir(stateDir: string): string = stateDir / "sessions"
proc readyPath(stateDir, id: string): string = sessionsDir(stateDir) / (id & ".ready")
proc failedPath(stateDir, id: string): string = sessionsDir(stateDir) / (id & ".failed")
proc logPath(stateDir, id: string): string = sessionsDir(stateDir) / (id & ".log")
proc shareDir(stateDir, id: string): string = sessionsDir(stateDir) / (id & ".share")
  ## The session's own XDG data directory (`activationOverride`).
proc startLockDir(stateDir: string): string = sessionsDir(stateDir) / ".linux-start.lock"
  ## Not a session id (ids never start with '.'), so it cannot collide.

proc removeQuiet(path: string) =
  try: removeFile(path)
  except OSError: discard

proc privStr(priv: JsonNode, key: string): string =
  if priv != nil and priv.kind == JObject and priv.hasKey(key) and
     priv[key].kind == JString: priv[key].getStr
  else: ""

proc hostAlive(s: Session, priv: JsonNode): bool =
  ## The session's host runs: its pid with its recorded start time.
  s.hostPid.isSome and processIs(s.hostPid.get, priv.privStr("hostStartTime"))

proc reconcilePrivate*(s: Session, priv: JsonNode): Session =
  ## The session as it really is (module doc, "Reconciliation").
  result = s
  if s.state notin {ssStarting, ssRunning}: return
  if s.hostPid.isSome and not hostAlive(s, priv):
    result.state = ssError
    result.stateReason = some("host-exited")
  elif s.state == ssRunning:
    var env = initTable[string, string]()
    for k, v in s.env: env[k] = v
    if not displayAnswers(env).ok:
      result.state = ssError
      result.stateReason = some("compositor-not-answering")

proc listPrivateSessions*(stateDir: string): seq[Session] =
  ## Every private Linux session recorded in `stateDir`, reconciled.
  for id in listSessionIds(stateDir):
    let r = readSessionRecord(stateDir, id)
    if r.isSome and r.get.session.backend in linuxPrivateBackendNames:
      result.add reconcilePrivate(r.get.session, r.get.private)

proc markError(stateDir, id: string, me: int, why: string) =
  ## Put the record of session `id` in state `error` with `why`, if it still
  ## names this host.
  try:
    let r = readSessionRecord(stateDir, id)
    if r.isNone or r.get.session.hostPid != some(me): return
    var s = r.get.session
    s.state = ssError
    s.stateReason = some(why)
    writeSessionRecord(stateDir, s, r.get.private)
  except CatchableError:
    discard

# ---------------------------------------------------------------------------
# Processes
# ---------------------------------------------------------------------------

proc environValue(environ, key: string): string =
  ## The value of `key` in the NUL-separated `environ`, "" when unset.
  for kv in environ.split('\0'):
    if kv.startsWith(key & "="): return kv[key.len + 1 .. ^1]
  ""

proc startTicks(startTime: string): int64 =
  ## A `processStartTime` as a number (clock ticks since boot), 0 when it is
  ## not one.
  try: parseBiggestInt(startTime) except ValueError: 0

iterator ownProcessEnvirons(notBefore = 0'i64):
    tuple[pid: int, startTime: string, environ: string] =
  ## Every process of this user (its /proc/<pid> directory is this uid's)
  ## that started at or after `notBefore` (clock ticks since boot, field 22
  ## of /proc/<pid>/stat), with its start time and its environment
  ## (proc(5): `/proc/<pid>/environ` is readable for a process of one's own
  ## only, so another user's process is never read). The start time is read
  ## first: it is a small file, while an environment can be large (a
  ## development shell's is tens of kilobytes), and on a busy host most of
  ## this user's processes predate the session being looked for (measured:
  ## 70-200 ms for a walk reading every environment of ~420 processes at a
  ## load average of 60).
  let uid = getuid()
  for kind, path in walkDir("/proc"):
    let name = path.extractFilename
    if name.len == 0 or not name.allCharsInSet(Digits): continue
    var st: Stat
    if stat(path.cstring, st) != 0 or st.st_uid != uid: continue
    let pid = parseInt(name)
    let started = processStartTime(pid)
    if started.len == 0 or startTicks(started) < notBefore: continue
    let environ = readProcFile(path / "environ")
    if environ.len > 0: yield (pid, started, environ)

type TaggedScan = object
  procs: seq[tuple[pid: int, startTime: string]]
  dirs: seq[string]

proc scanTagged(tag: string, notBefore = 0'i64): TaggedScan =
  ## One walk of this user's processes (`ownProcessEnvirons`): those whose
  ## environment carries `GUIASSERT_LINUX_SESSION_TAG=<tag>`, and the
  ## `XDG_RUNTIME_DIR` each of them names. Every process of a session is
  ## its host or a descendant of it (the tag is inherited, never set later),
  ## so none started before the host did: `notBefore`, the host's start
  ## time, skips every older process without reading its environment.
  if tag.len == 0: return
  let needle = sessionTagVar & "=" & tag
  for (pid, started, environ) in ownProcessEnvirons(notBefore):
    if environHas(environ, needle):
      result.procs.add (pid, started)
      let d = environValue(environ, "XDG_RUNTIME_DIR")
      if d.len > 0 and d notin result.dirs: result.dirs.add d

proc taggedProcesses*(tag: string, hostStartTime = ""): seq[tuple[pid: int, startTime: string]] =
  ## The live processes whose environment carries
  ## `GUIASSERT_LINUX_SESSION_TAG=<tag>` (`scanTagged`; `hostStartTime`, the
  ## session host's `processStartTime` when known, bounds the walk).
  scanTagged(tag, startTicks(hostStartTime)).procs

proc taggedRuntimeDirs*(tag: string): seq[string] =
  ## The `XDG_RUNTIME_DIR` of every process of the session tagged `tag`.
  ## (The session's own runtime directory is also found by its name,
  ## `sessionRuntimeDir`, for a host that died before any process named it.)
  scanTagged(tag).dirs

proc removeRuntimeDir*(dir: string, waitMs = 2000)

proc sweepTagged*(tag: string, exceptPid = 0, graceMs = sweepGraceMs,
                  keepDirs: openArray[string] = [], hostStartTime = "") =
  ## End every process of the session tagged `tag` (but `exceptPid`): SIGTERM,
  ## then SIGKILL for whatever still runs `graceMs` later; with `graceMs` 0,
  ## SIGKILL at once (a start being undone, whose processes never served a
  ## client). A process is signalled only while its pid still has the start
  ## time it was found with, so a recycled pid is never hit. Then the
  ## session's runtime directories, as its processes named them, are
  ## removed (`removeRuntimeDir`, which removes only a private session's),
  ## but never one of `keepDirs`: the CALLER's runtime directory, which the
  ## host inherited (a caller inside another private session has one under
  ## /tmp too). `hostStartTime`, the session host's start time when known,
  ## bounds the walks (`scanTagged`).
  let notBefore = startTicks(hostStartTime)
  let found = scanTagged(tag, notBefore)
  var dirs = found.dirs.filterIt(it notin keepDirs)
  var procs = found.procs.filterIt(it.pid != exceptPid)
  let first = if graceMs > 0: SIGTERM else: SIGKILL
  for p in procs:
    if processIs(p.pid, p.startTime): discard kill(Pid(p.pid), first)
  let startNs = monoNowNs()
  while procs.len > 0 and elapsedMsSince(startNs) < max(graceMs, 1000):
    sleep(10)
    procs = procs.filterIt(processIs(it.pid, it.startTime))
    if elapsedMsSince(startNs) >= graceMs:
      for p in procs:
        if processIs(p.pid, p.startTime): discard kill(Pid(p.pid), SIGKILL)
  # Anything started meanwhile (a service activated while the session went
  # down, a child forked after the first scan) carries the tag too; it is
  # killed outright, and the runtime directory it names is removed with the
  # others.
  let late = scanTagged(tag, notBefore)
  for p in late.procs:
    if p.pid != exceptPid and processIs(p.pid, p.startTime):
      discard kill(Pid(p.pid), SIGKILL)
  for d in late.dirs:
    if d notin keepDirs and d notin dirs: dirs.add d
  for d in dirs: removeRuntimeDir(d, waitMs = (if graceMs > 0: 2000 else: 100))

proc waitGone(pid: int, startTime: string, ms: int): bool =
  let startNs = monoNowNs()
  while processIs(pid, startTime):
    if elapsedMsSince(startNs) >= ms: return false
    sleep(20)
  true

proc removeRuntimeDir*(dir: string, waitMs = 2000) =
  ## Remove a session's runtime directory, but only one that is a private
  ## session's: an absolute directory directly under /tmp, named by a
  ## GuiAssert target (`guienv-` for sway and GNOME, `gaxv-` for Xvfb),
  ## owned by this user, and not a symbolic link. The path must be written
  ## plainly: a `.` or `..` component (which `parentDir` would resolve, so
  ## the name check could pass for a path that means another directory) is
  ## refused outright. A FUSE mount a portal left in it (the document
  ## portal, `doc`) is detached first.
  if dir.len == 0 or not dir.isAbsolute: return
  for part in dir.split('/'):
    if part == "." or part == "..": return
  if dir.parentDir != "/tmp": return
  let base = dir.extractFilename
  if not (base.startsWith("guienv-") or base.startsWith("gaxv-")): return
  var st: Stat
  if lstat(dir.cstring, st) != 0 or not S_ISDIR(st.st_mode) or st.st_uid != getuid(): return
  # The tag sweep has ended the session's processes; the mounts a portal
  # left below it are detached and the tree removed, retried briefly while
  # something still holds it (`runtime_dir.removeRuntimeTree`). Clients
  # started INTO the session are not ended here.
  removeRuntimeTree(dir, endProcesses = false, waitMs = waitMs)

# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------

proc onPath*(env: Table[string, string], name: string): string =
  ## The executable `name` on `env`'s PATH, or "".
  for dir in env.getOrDefault("PATH", "").split(':'):
    if dir.len == 0: continue
    let p = dir / name
    if fileExists(p) and access(p.cstring, X_OK) == 0: return p
  ""

proc requireOnPath*(backend: string, env: Table[string, string], name: string): string =
  ## `onPath`, or exit 4 / `missing-tool`.
  result = onPath(env, name)
  if result.len == 0:
    raise missingTool(backend, "'" & name & "' is not on the PATH",
      "install " & name & " (GuiAssert's `nix develop` and its package provide it)")

proc requireEnvFile*(backend: string, env: Table[string, string], name: string): string =
  ## The existing file or directory variable `name` of `env` names, or exit
  ## 4 / `missing-tool`.
  result = env.getOrDefault(name, "")
  if result.len == 0 or not (fileExists(result) or dirExists(result)):
    raise missingTool(backend, name & " is not set to an existing path",
      "run inside GuiAssert's `nix develop`, or use the packaged guiassert, which sets it")

proc atspiLauncher*(env: Table[string, string]): string =
  ## The at-spi-bus-launcher to run: `GUI_ASSERT_ATSPI_BUS_LAUNCHER`, else
  ## `../libexec/at-spi-bus-launcher` beside a PATH directory (where
  ## at-spi2-core installs it), else "".
  let named = env.getOrDefault("GUI_ASSERT_ATSPI_BUS_LAUNCHER", "")
  if named.len > 0:
    return (if fileExists(named): named else: "")
  for dir in env.getOrDefault("PATH", "").split(':'):
    if dir.len == 0: continue
    let p = dir.parentDir / "libexec" / "at-spi-bus-launcher"
    if fileExists(p): return p
  ""

proc requireAtspiLauncher*(backend: string, env: Table[string, string]) =
  ## Exit 4 / `missing-tool` when the session's AT-SPI bus cannot be started.
  if atspiLauncher(env).len == 0:
    raise missingTool(backend, "no at-spi-bus-launcher (GUI_ASSERT_ATSPI_BUS_LAUNCHER " &
      "is unset or names no file, and none is installed beside the PATH)",
      "set GUI_ASSERT_ATSPI_BUS_LAUNCHER to at-spi2-core's libexec/at-spi-bus-launcher")

# ---------------------------------------------------------------------------
# In the session host: shared start-up pieces
# ---------------------------------------------------------------------------

proc processEnv*(): Table[string, string] =
  ## This process's environment.
  for k, v in envPairs(): result[k] = v

proc childEnv*(session: OrderedTable[string, string],
               unset: openArray[string]): Table[string, string] =
  ## The environment of a process the host starts inside the session: the
  ## host's own (so the session tag and whatever the caller's run carried
  ## reach it), minus `unset`, plus `session`.
  composeSessionEnv(processEnv(), session, unset)

proc toStringTable*(env: Table[string, string]): StringTableRef =
  ## `env` as the string table `startProcess` takes.
  result = newStringTable(modeCaseSensitive)
  for k, v in env: result[k] = v

proc launchLogged*(env: Table[string, string], exe: string, args: seq[string],
                   log: string): Process =
  ## Start `exe args` with `env`, both output streams in `log` (created 0600
  ## by the shell's umask of the host, which is 077; see `runLinuxSessionHost`).
  startProcess("/bin/sh", args = @["-c", "exec " & quoteShellCommand(@[exe] & args) &
    " >" & quoteShell(log) & " 2>&1"], env = env.toStringTable, options = {})

proc logTail*(path: string, maxLen = 400): string =
  ## The end of a log, one line, for a start failure's message.
  try: lastLine(readFileCapped(path, maxRecordBytes).strip, maxLen)
  except CatchableError: ""

proc stopProcess*(p: Process, graceMs = 2000) =
  ## SIGTERM `p`, then SIGKILL after `graceMs`; reaped and closed. Never
  ## raises.
  if p == nil: return
  try:
    if p.running:
      p.terminate()
      let startNs = monoNowNs()
      while p.running and elapsedMsSince(startNs) < graceMs: sleep(20)
      if p.running: p.kill()
      discard p.waitForExit(1000)
    p.close()
  except CatchableError: discard

proc a11yBusAddress(sessionBus: string): string =
  ## What the session bus answers for `org.a11y.Bus.GetAddress`, asked only
  ## when something owns the name and without auto-start (so the ask never
  ## activates a launcher); "" when there is none yet.
  var c: DbusConnection
  try:
    c = connectBus(sessionBus, 2000)
    let owned = c.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                       "NameHasOwner", [dstr("org.a11y.Bus")], timeoutMs = 2000)
    if owned.len != 1 or owned[0].kind != dkBool or owned[0].num == 0: return ""
    let r = c.call("org.a11y.Bus", "/org/a11y/bus", "org.a11y.Bus", "GetAddress",
                   flags = flagNoAutoStart, timeoutMs = 2000)
    if r.len == 1 and r[0].kind == dkString: result = r[0].str
  except CatchableError:
    result = ""
  finally:
    if c != nil: c.close()

proc setA11yEnabled(sessionBus: string) =
  ## `org.a11y.Status.IsEnabled = true` on the session's `org.a11y.Bus`
  ## (org.freedesktop.DBus.Properties.Set, D-Bus specification "Standard
  ## Interfaces"), what an assistive technology does when it starts.
  var c: DbusConnection
  try:
    c = connectBus(sessionBus, 2000)
    discard c.call("org.a11y.Bus", "/org/a11y/bus", "org.freedesktop.DBus.Properties", "Set",
                   [dstr("org.a11y.Status"), dstr("IsEnabled"), dvariant(dbool(true))],
                   flags = flagNoAutoStart, timeoutMs = 2000)
  finally:
    if c != nil: c.close()

proc startAtspiBus(env: OrderedTable[string, string], unset: openArray[string],
                   runtimeDir: string, deadlineNs: int64): AtspiRun =
  ## The session's AT-SPI bus (module doc, step 2). Raises naming what failed.
  let sessionBus = env.getOrDefault("DBUS_SESSION_BUS_ADDRESS", "")
  if sessionBus.len == 0: raise newException(OSError, "the session has no session bus")
  proc left(): int = int((deadlineNs - monoNowNs()) div 1_000_000)
  result.address = a11yBusAddress(sessionBus)
  if result.address.len == 0:
    let launcher = atspiLauncher(processEnv())
    if launcher.len == 0: raise newException(OSError, "no at-spi-bus-launcher")
    let log = runtimeDir / "atspi-launcher.log"
    result.launcher = launchLogged(childEnv(env, unset), launcher, @["--launch-immediately"],
                                   log)
    while result.address.len == 0:
      if not result.launcher.running:
        raise newException(OSError, "at-spi-bus-launcher exited: " & logTail(log))
      if left() <= 0:
        raise newException(OSError, "the AT-SPI bus did not start in time: " & logTail(log))
      sleep(20)
      result.address = a11yBusAddress(sessionBus)
  if runtimeDir notin result.address:
    raise newException(OSError, "the session's AT-SPI bus is not its own: it is at " &
      result.address & ", outside " & runtimeDir)
  setA11yEnabled(sessionBus)
  # Ready when its registry answers (a tree query right after the start then
  # succeeds, C10). The registry is activated by the accessibility bus on
  # the first call, which may take a moment.
  var probeEnv = initTable[string, string]()
  for k, v in env: probeEnv[k] = v
  probeEnv["AT_SPI_BUS_ADDRESS"] = result.address
  let token = newCancelToken()
  try:
    while not atspiReachable(LinuxAtspiConfig(env: probeEnv, token: token)):
      if left() <= 0: raise newException(OSError, "the AT-SPI registry does not answer")
      sleep(20)
  finally:
    token.free()

proc activationOverride(stateDir, id: string) =
  ## Make the session bus activate the PINNED at-spi-bus-launcher when a
  ## client of the session asks for `org.a11y.Bus` before the host has
  ## started it (a GTK portal backend or GNOME Shell does, while the server
  ## starts). The bus's session service directories are
  ## `$XDG_DATA_DIRS/dbus-1/services`, searched in order with the first
  ## file for a name winning (D-Bus specification, "Message Bus Starting
  ## Services"); the host's own data directory, holding only
  ## `org.a11y.Bus.service`, is put first in the environment the server's
  ## bus inherits. Without it the activated launcher is at-spi2-core's own,
  ## which runs the dbus-daemon of the host system's path and fails outside
  ## NixOS (see the flake's `atspiLauncherFor`).
  let launcher = atspiLauncher(processEnv())
  if launcher.len == 0: return
  let services = shareDir(stateDir, id) / "dbus-1" / "services"
  createDir(services)
  writeFile(services / "org.a11y.Bus.service",
            "[D-BUS Service]\nName=org.a11y.Bus\nExec=" & launcher & "\n")
  let dirs = getEnv("XDG_DATA_DIRS", "/usr/local/share:/usr/share")
  putEnv("XDG_DATA_DIRS", shareDir(stateDir, id) & ":" & dirs)

proc freeLoopbackPort*(): int =
  ## A TCP port nothing listens on at 127.0.0.1 right now (bound with port 0
  ## and released). A server may still lose it to another process before it
  ## binds; `waitVncListening` then fails and the caller tries another.
  let s = newSocket()
  try:
    s.setSockOpt(OptReuseAddr, true)
    s.bindAddr(Port(0), "127.0.0.1")
    result = int(s.getLocalAddr()[1])
  finally:
    s.close()

proc socketInodes(pid: int): seq[string] =
  ## The socket inodes process `pid` holds open (`/proc/<pid>/fd/*` ->
  ## `socket:[<inode>]`, proc(5)).
  for kind, path in walkDir("/proc/" & $pid & "/fd"):
    try:
      let target = expandSymlink(path)
      if target.startsWith("socket:[") and target.endsWith("]"):
        result.add target[8 .. ^2]
    except OSError: discard

proc readTable(path: string): seq[TcpSocketRow] =
  try: parseProcNetTcp(readFile(path))
  except IOError, OSError: @[]

proc rfbBannerAt(port: int, timeoutMs: int): string =
  ## The first 12 bytes a server at 127.0.0.1:`port` sends, "" when it sends
  ## none in time.
  let s = newSocket()
  try:
    s.connect("127.0.0.1", Port(port), timeoutMs)
    result = s.recv(rfbBannerLen, timeoutMs)
  except CatchableError:
    result = ""
  finally:
    s.close()

proc unixBannerAt(path: string, timeoutMs: int): string =
  ## The first 12 bytes a server on the Unix socket `path` sends, "" when it
  ## sends none in time.
  let s = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP)
  try:
    s.connectUnix(path)
    result = s.recv(rfbBannerLen, timeoutMs)
  except CatchableError:
    result = ""
  finally:
    s.close()

proc waitVncListening*(pid: int, isRunning: proc (): bool, port: int,
                       deadlineNs: int64): string =
  ## Wait until the VNC server `pid` listens on 127.0.0.1:`port`, nowhere
  ## else (`vncTcpVerdict`: no other listening TCP socket of its own, on any
  ## port), and greets with an RFB banner. "" when it does, else why not
  ## (the server exited, it listens elsewhere too, or it never got there).
  ## The listener is the server's own: its inode is one of `pid`'s sockets
  ## (/proc/net/tcp, proc_net_tcp(5)), so another process that took the
  ## port is never mistaken for it.
  while true:
    if not isRunning(): return "the VNC server exited"
    let verdict = vncTcpVerdict(readTable("/proc/net/tcp"), readTable("/proc/net/tcp6"),
                                socketInodes(pid), port)
    if verdict.len == 0:
      if isRfbBanner(rfbBannerAt(port, 1000)): return ""
    elif verdict != "not-listening":
      return verdict
    if monoNowNs() >= deadlineNs: return "the VNC server did not listen on 127.0.0.1:" & $port
    sleep(20)

proc waitVncSocketListening*(pid: int, isRunning: proc (): bool, path: string,
                             deadlineNs: int64): string =
  ## Wait until the VNC server `pid` listens on the Unix socket `path`, holds
  ## no listening TCP socket (`vncSocketVerdict`), and greets with an RFB
  ## banner there. "" when it does, else why not.
  while true:
    if not isRunning(): return "the VNC server exited"
    var unixRows: seq[UnixSocketRow]
    try: unixRows = parseProcNetUnix(readFile("/proc/net/unix"))
    except IOError, OSError: discard
    let verdict = vncSocketVerdict(unixRows, readTable("/proc/net/tcp"),
                                   readTable("/proc/net/tcp6"), socketInodes(pid), path)
    if verdict.len == 0:
      if isRfbBanner(unixBannerAt(path, 1000)): return ""
    elif verdict != "not-listening":
      return verdict
    if monoNowNs() >= deadlineNs: return "the VNC server did not listen on " & path
    sleep(20)

# ---------------------------------------------------------------------------
# The session host
# ---------------------------------------------------------------------------

var hostStopRequested: bool
  ## The session host's one global: set by its SIGTERM / SIGINT handler (a
  ## signal handler can reach nothing else). Only the host process sets it.

proc onHostSignal(sig: cint) {.noconv.} =
  hostStopRequested = true

proc specOf(priv: JsonNode, id: string): HostSpec =
  let s = priv{"spec"}
  if s == nil or s.kind != JObject: raise newException(ValueError, "no spec")
  HostSpec(id: id, width: s["width"].getInt, height: s["height"].getInt,
           scale: s["scale"].getFloat, vnc: s["vnc"].getBool,
           vncSocket: s{"vncSocket"}.getBool(false))

proc sortedEnvJson(env: OrderedTable[string, string]): JsonNode =
  result = newJObject()
  var keys = toSeq(env.keys)
  keys.sort()
  for k in keys: result[k] = %env[k]

proc runLinuxSessionHost*(stateDir, id: string, servers: openArray[PrivateServer]): int =
  ## The body of `guiassert __linux-session-host --state-dir <dir> <id>`
  ## (module doc). Returns the exit code: 0 after an orderly teardown, 1
  ## when the session could not be started (reported in `<id>.failed`), 2
  ## when there is nothing for this process to host.
  discard umask(Mode(0o077))   # every file the session writes is the user's alone
  let me = getCurrentProcessId()
  let tag = getEnv(sessionTagVar)
  let callerRuntime = getEnv("XDG_RUNTIME_DIR")
    ## read before a server sets the session's own in this process
  var rec: Option[tuple[session: Session, private: JsonNode]]
  try: rec = readSessionRecord(stateDir, id)
  except CatchableError: return 2
  if rec.isNone or tag.len == 0 or rec.get.private.privStr("tag") != tag: return 2
  let backend = rec.get.private.privStr("backend")
  var server: PrivateServer
  var found = false
  for s in servers:
    if s.name == backend:
      server = s
      found = true
  if not found: return 2
  signal(SIGTERM, onHostSignal)
  signal(SIGINT, onHostSignal)
  signal(SIGHUP, SIG_IGN)
  signal(SIGPIPE, SIG_IGN)
  let deadlineNs = monoNowNs() + int64(readinessBoundMs) * 1_000_000
  var run: ServerRun
  var atspi: AtspiRun
  let runtimeDir = sessionRuntimeDir(backend, tag)
  proc teardown() =
    stopProcess(atspi.launcher)
    if run.stop != nil:
      try: run.stop()
      except CatchableError: discard
    sweepTagged(tag, exceptPid = me, keepDirs = [callerRuntime],
                hostStartTime = processStartTime(me))
    removeRuntimeDir(run.runtimeDir)
    removeRuntimeDir(runtimeDir)
    try: removeDir(shareDir(stateDir, id))
    except OSError: discard
  try:
    var spec = specOf(rec.get.private, id)
    # The runtime directory first, named by the tag (`sessionRuntimeDir`),
    # so a host killed at any later point leaves nothing the record's holder
    # cannot find. mkdir(2) with mode 0700 fails when the name exists.
    if runtimeDir.len == 0 or posix.mkdir(runtimeDir.cstring, Mode(0o700)) != 0:
      raise newException(OSError, "cannot make the session's runtime directory " &
                                  runtimeDir & ": " & osErrorMsg(osLastError()))
    spec.runtimeDir = runtimeDir
    activationOverride(stateDir, id)
    run = server.hostStart(spec)
    let unset = envUnsetFor(server.envUnset, run.env)
    atspi = startAtspiBus(run.env, unset, run.runtimeDir, deadlineNs)
    run.env["AT_SPI_BUS_ADDRESS"] = atspi.address
    writePrivateFile(readyPath(stateDir, id), $(%*{
      "hostPid": me, "env": sortedEnvJson(run.env), "runtimeDir": run.runtimeDir,
      "vnc": (if run.vnc.isSome: %*{"host": run.vnc.get.host, "port": run.vnc.get.port}
              else: newJNull()),
      "vncSocket": (if run.vncSocket.isSome: %run.vncSocket.get else: newJNull())}))
  except CatchableError as e:
    try: writePrivateFile(failedPath(stateDir, id), $(%*{"hostPid": me,
                          "message": lastLine(e.msg, 600)}))
    except CatchableError: discard
    teardown()
    return 1
  # Supervise until stopped, abandoned or broken.
  let readyNs = monoNowNs()
  var acknowledged = false
  while not hostStopRequested:
    sleep(superviseMs)
    if not acknowledged:
      acknowledged = not fileExists(readyPath(stateDir, id))
      if not acknowledged and elapsedMsSince(readyNs) > unacknowledgedMs:
        removeQuiet(readyPath(stateDir, id))
        break
    if acknowledged:
      var mine = true
      try:
        let r = readSessionRecord(stateDir, id)
        mine = r.isSome and r.get.session.hostPid == some(me)
      except CatchableError:
        mine = true   # a record being rewritten; look again next time
      if not mine: break
    var why = run.alive()
    if why.len == 0 and atspi.launcher != nil and not atspi.launcher.running:
      why = "accessibility-bus-exited"
    if why.len > 0:
      if acknowledged: markError(stateDir, id, me, why)
      break
  teardown()
  0

# ---------------------------------------------------------------------------
# In the starter and every later invocation: the session backend
# ---------------------------------------------------------------------------

proc abandon(cfg: LinuxPrivateConfig, server: PrivateServer, id: string, pid: int,
             startTime, tag: string, runtimeDir: string) =
  ## Undo a start that did not get ready: the host, everything tagged, the
  ## runtime directory, the record and its files. Everything is killed
  ## outright (SIGKILL): none of it ever served a client, and the failure
  ## must be reported within the readiness margin (250 ms) of the deadline.
  if pid > 0 and processIs(pid, startTime):
    discard kill(Pid(pid), SIGKILL)
    discard waitGone(pid, startTime, 1000)
  sweepTagged(tag, graceMs = 0, keepDirs = [cfg.env.getOrDefault("XDG_RUNTIME_DIR", "")],
              hostStartTime = (if pid > 0: startTime else: ""))
  removeRuntimeDir(runtimeDir, waitMs = 100)
  removeRuntimeDir(sessionRuntimeDir(server.name, tag), waitMs = 100)
  for p in [sessionRecordPath(cfg.stateDir, id), readyPath(cfg.stateDir, id),
            failedPath(cfg.stateDir, id), logPath(cfg.stateDir, id)]:
    removeQuiet(p)
  try: removeDir(shareDir(cfg.stateDir, id))
  except OSError: discard

proc envFromJson(n: JsonNode): OrderedTable[string, string] =
  if n == nil or n.kind != JObject: raise newException(ValueError, "no environment")
  for k, v in n:
    if v.kind != JString: raise newException(ValueError, "a non-string variable")
    result[k] = v.getStr

proc startPrivate(cfg: LinuxPrivateConfig, server: PrivateServer, spec: SessionSpec): Session =
  ## `session-start` of a private session (module doc).
  case spec.kind
  of skHost:
    raise badArgs("invalid-value", "the host session always exists; it is never started")
  of skVirtualDisplay, skIsolated:
    raise unsupportedOption(server.name, server.name & " starts headless sessions only, " &
      "not " & $spec.kind & " ones", "use --kind headless")
  of skHeadless: discard
  if spec.displays != 1:
    raise unsupportedOption(server.name, server.name & " sessions have one display; " &
      "--displays " & $spec.displays & " cannot be honoured")
  if spec.scale.isSome and spec.scale.get != 1.0 and not server.supportsScale:
    raise unsupportedOption(server.name, server.name & " sessions have scale 1; --scale " &
      $spec.scale.get & " cannot be honoured", "use --session-backend linux-sway")
  let flag = if spec.vncSocket: "--vnc-socket" else: "--vnc"
  if (spec.vnc or spec.vncSocket) and not server.supportsVnc:
    raise unsupportedOption(server.name, server.name & " offers no VNC endpoint",
      "use --session-backend linux-sway or linux-xvfb for " & flag)
  server.preflight(cfg.env, spec.vnc or spec.vncSocket)
  let size = spec.size.get(Size(width: defaultWidth, height: defaultHeight))
  let tag = newTag()
  ensurePrivateDir(sessionsDir(cfg.stateDir))
  var s: Session
  var priv = %*{"backend": server.name, "tag": tag,
                "spec": {"width": size.width, "height": size.height,
                         "scale": spec.scale.get(1.0), "vnc": spec.vnc,
                         "vncSocket": spec.vncSocket},
                "hostStartTime": "", "runtimeDir": "",
                "callerRuntimeDir": cfg.env.getOrDefault("XDG_RUNTIME_DIR", "")}
  withLock(startLockDir(cfg.stateDir), cfg.token):
    var id = ""
    if spec.name.isSome:
      id = spec.name.get
      if id == hostSessionId:
        raise badArgs("invalid-name", "'host' is the reserved id of the caller's session")
      let existing = readSessionRecord(cfg.stateDir, id)
      if existing.isSome:
        # Stopped sessions leave no record: any record is a session that is
        # running, starting or in error.
        let state = if existing.get.session.backend in linuxPrivateBackendNames:
                      $reconcilePrivate(existing.get.session, existing.get.private).state
                    else: $existing.get.session.state
        raise badArgs("name-in-use", "a session named '" & id & "' already exists (" &
          state & ")", details = %*{"name": id, "state": state})
    else:
      let dir = cfg.stateDir
      id = generatedId(server.idPrefix, proc (x: string): bool =
        readSessionRecord(dir, x).isSome)
    s = Session(id: id, name: spec.name, kind: skHeadless, backend: server.name,
                platform: spLinux, state: ssStarting, lifetime: spec.lifetime,
                isolation: Isolation(pixels: true, input: true, clipboard: true),
                backends: server.backends, createdAt: formatTimestamp(unixNowMs()),
                hostPid: none(int))
    for p in [readyPath(cfg.stateDir, id), failedPath(cfg.stateDir, id)]: removeQuiet(p)
    writeSessionRecord(cfg.stateDir, s, priv)
  # The host, detached, carrying the session's tag.
  var hostEnv = cfg.env
  hostEnv[sessionTagVar] = tag
  var started: tuple[pid: int, startTime: string]
  try:
    started = spawnDetached(LinuxCaptureConfig(env: hostEnv, stateDir: cfg.stateDir,
      token: cfg.token), server.name,
      @[cfg.selfExe, hostVerb, "--state-dir", cfg.stateDir, s.id], logPath(cfg.stateDir, s.id))
  except CatchableError as e:
    abandon(cfg, server, s.id, 0, "", tag, "")
    raise failed(server.name, "cannot start the session host: " & e.msg)
  s.hostPid = some(started.pid)
  priv["hostStartTime"] = %started.startTime
  writeSessionRecord(cfg.stateDir, s, priv)
  # Readiness: the host's report, the host's death, or the bound.
  let bound = readinessBound(cfg.token.remainingMs)
  let startNs = monoNowNs()
  var why = ""
  var ready: JsonNode = nil
  while true:
    if fileExists(readyPath(cfg.stateDir, s.id)):
      try:
        let n = parseJson(readFileCapped(readyPath(cfg.stateDir, s.id), maxRecordBytes))
        if n{"hostPid"}.getInt == started.pid: ready = n
      except CatchableError: discard
      if ready != nil: break
    if fileExists(failedPath(cfg.stateDir, s.id)):
      var msg = "it gave no reason"
      try:
        msg = parseJson(readFileCapped(failedPath(cfg.stateDir, s.id),
                                       maxRecordBytes)){"message"}.getStr(msg)
      except CatchableError: discard
      why = "the session host could not start the session: " & msg
      break
    if not processIs(started.pid, started.startTime):
      why = "the session host exited before the session was ready" &
            (let t = logTail(logPath(cfg.stateDir, s.id)); if t.len > 0: ": " & t else: "")
      break
    if elapsedMsSince(startNs) >= bound:
      why = "the session did not become ready within " & $bound & " ms"
      break
    if cfg.token.reason != crNone:
      why = "cancelled"
      break
    sleep(10)
  var runtimeDir = ""
  if why.len == 0:
    try:
      s.env = envFromJson(ready{"env"})
      runtimeDir = ready{"runtimeDir"}.getStr
      let v = ready{"vnc"}
      if v != nil and v.kind == JObject:
        s.vnc = some(VncEndpoint(host: v["host"].getStr, port: v["port"].getInt))
      let vs = ready{"vncSocket"}
      if vs != nil and vs.kind == JString: s.vncSocket = some(vs.getStr)
      s.envUnset = envUnsetFor(server.envUnset, s.env)
      # The caller's own read of the session through its capture backend:
      # its display server answers from here, too.
      s.displays = cfg.displays(composeSessionEnv(cfg.env, s), server.backends.capture)
      if s.displays.len == 0: why = "its display server reports no display"
    except CatchableError as e:
      why = "the session's displays cannot be read: " & e.msg
  if why.len == 0 and spec.vnc and s.vnc.isNone:
    why = "the session host started no VNC endpoint"
  if why.len == 0 and spec.vncSocket and s.vncSocket.isNone:
    why = "the session host started no VNC socket"
  if why.len > 0:
    abandon(cfg, server, s.id, started.pid, started.startTime, tag, runtimeDir)
    if cfg.token.reason != crNone: raise cancelledError(cfg.token.reason)
    raise failed(server.name, "session '" & s.id & "': " & why)
  s.state = ssRunning
  priv["runtimeDir"] = %runtimeDir
  writeSessionRecord(cfg.stateDir, s, priv)
  # Taking the session over: the host now supervises it under this record.
  removeQuiet(readyPath(cfg.stateDir, s.id))
  s

proc stopPrivate*(stateDir, id: string, force: bool): Session =
  ## `session-stop` of a private session: the host's orderly teardown
  ## (SIGTERM; SIGKILL with `--force`, or when it does not end in time), then
  ## everything tagged, the runtime directory and the record. Works for a
  ## session whose host already died.
  let r = readSessionRecord(stateDir, id)
  if r.isNone:
    raise newBackendError(BackendNotFoundError, "linux-private", "session",
                          "no session '" & id & "'")
  result = r.get.session
  let priv = r.get.private
  let st = priv.privStr("hostStartTime")
  if result.hostPid.isSome and processIs(result.hostPid.get, st):
    let pid = result.hostPid.get
    discard kill(Pid(pid), (if force: SIGKILL else: SIGTERM))
    if not waitGone(pid, st, (if force: 2000 else: hostStopWaitMs)):
      discard kill(Pid(pid), SIGKILL)
      if not waitGone(pid, st, 2000):
        raise failed(result.backend, "the session host " & $pid & " does not exit")
  sweepTagged(priv.privStr("tag"), keepDirs = [priv.privStr("callerRuntimeDir")],
              hostStartTime = priv.privStr("hostStartTime"))
  removeRuntimeDir(priv.privStr("runtimeDir"))
  removeRuntimeDir(sessionRuntimeDir(result.backend, priv.privStr("tag")))
  for p in [sessionRecordPath(stateDir, id), readyPath(stateDir, id),
            failedPath(stateDir, id), logPath(stateDir, id)]:
    removeQuiet(p)
  try: removeDir(shareDir(stateDir, id))
  except OSError: discard
  result.state = ssStopped
  result.stateReason = none(string)

proc privateFeatures(cfg: LinuxPrivateConfig, server: PrivateServer,
                     probe: bool): seq[Feature] =
  proc feat(name: string, state: FeatureState, reason = "", remedy = ""): Feature =
    Feature(feature: name, backend: server.name, state: state,
            reason: (if reason.len > 0: some(reason) else: none(string)),
            remedy: (if remedy.len > 0: some(remedy) else: none(string)))
  proc probed(name: string, vnc: bool): Feature =
    if not probe: return feat(name, fsAvailable)
    try:
      server.preflight(cfg.env, vnc)
      feat(name, fsSupported)
    except BackendError as e:
      feat(name, fsUnavailable, e.reason, e.remedy)
  result.add feat("session-management", fsAvailable)
  result.add feat("app-management", fsAvailable)
  for k in ["session-virtual-display", "session-isolated"]:
    result.add feat(k, fsUnavailable, "unsupported-option",
                    "Linux sessions are headless: use session-start --kind headless")
  result.add probed("session-headless", false)
  result.add (if server.supportsVnc: probed("session-vnc", true)
              else: feat("session-vnc", fsUnavailable, "unsupported-option",
                         "use --session-backend linux-sway or linux-xvfb for --vnc"))

proc newLinuxPrivateSession*(cfg: LinuxPrivateConfig, server: PrivateServer): SessionBackend =
  ## The session backend of `server` (`linux-sway`, `linux-gnome`,
  ## `linux-xvfb`).
  result.name = server.name
  var hostCfg = cfg.host
  let stateDir = cfg.stateDir
  hostCfg.privateSessions = proc (): seq[Session] = listPrivateSessions(stateDir)
  let host = newLinuxHostSession(hostCfg)

  result.start = proc (spec: SessionSpec): Session = startPrivate(cfg, server, spec)

  result.list = proc (): seq[Session] = host.list()

  result.info = proc (id: string): Session =
    if id == hostSessionId: return host.info(id)
    let r = readSessionRecord(stateDir, id)
    if r.isNone:
      raise newBackendError(BackendNotFoundError, server.name, "session",
                            "no session '" & id & "'")
    if r.get.session.backend in linuxPrivateBackendNames:
      reconcilePrivate(r.get.session, r.get.private)
    else: r.get.session

  result.stop = proc (id: string, force: bool): Session = stopPrivate(stateDir, id, force)

  result.apps = proc (session: string): seq[App] = host.apps(session)
  result.launch = proc (session: string, spec: LaunchSpec): LaunchReport =
    host.launch(session, spec)
  result.quit = proc (session: string, pid: int, force: bool): QuitReport =
    host.quit(session, pid, force)
  result.permissions = proc (request: Option[string]): Permissions = host.permissions(request)
  result.features = proc (probe: bool): seq[Feature] = privateFeatures(cfg, server, probe)
