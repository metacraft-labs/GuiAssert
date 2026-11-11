## `guiassert serve`: the long-lived NDJSON daemon (spec §8).
##
## One main thread owns every decision and every write; other threads only
## block and report through one channel:
##
## * a **reader** per connection (stdin for `--stdio`, a socket for
##   `--listen unix:<path>`) splits its input into lines (at most 1 MiB; a
##   longer line is a `protocol-error` and is discarded) and posts them;
## * an **acceptor** (socket transport) posts each new connection whose peer
##   uid equals the daemon's (`getpeereid` / `SO_PEERCRED`);
## * a **worker** per running request runs it with `runInvocation`, the same
##   code the one-shot CLI runs, so its envelope is byte-identical to the
##   CLI's (spec §8.3), and posts its events and its result.
##
## The main thread parses requests strictly (unknown op, unknown key, a
## missing or malformed id, a non-object line: `protocol-error`, connection
## kept open), schedules them (requests for one session run one at a time in
## arrival order; others concurrently up to `--max-concurrency`, spec §8.5),
## numbers each request's events from 0, writes exactly one `result` per
## accepted request, cancels on `cancel` / deadline / shutdown (spec §8.6),
## and on shutdown stops the `lifetime: owner` sessions of the closing
## connection(s) and writes the `shutdown` line (spec §8.7).
##
## A **prober** thread re-reads the `lifetime: owner` sessions of every
## connection with `session-info` (at most `probeIntervalMs` apart), so the
## main thread can send the connection event `session-state` (`"id": null`,
## a per-connection `seq`) when one changes state on its own, for example
## when its host exits; stopping an owner session at disconnect or shutdown
## sends one too (spec §8.4). The prober runs off the main thread because a
## platform backend's `session-info` may take a while.
##
## Global flags given to `serve` are the defaults of every request on it. A
## request whose argv names `serve` is refused: a daemon never starts a
## nested daemon.

import std/[json, options, os, sets, strutils, tables, typedthreads]

when defined(posix):
  import std/posix
else:
  import std/winlean

import ../core/[contract, desktop_types]
import ../cancel
import ./[args, context, registry, run, state]

const
  maxLineBytes* = 1 shl 20
    ## Requests longer than this are a protocol-error (spec §8.2).
  defaultMaxConcurrency* = 4
  idChars = {'A'..'Z', 'a'..'z', '0'..'9', '.', '_', ':', '-'}
  finishedMemory = 4096
    ## How many finished request ids per connection `cancel` can still name
    ## as `already-finished`.
  probeIntervalMs = 250
    ## The pause between two probes of the owner sessions (spec §8.4 asks
    ## for at least one check a second).

type
  MsgKind = enum
    mkLine, mkTooLong, mkEof, mkConnected, mkEvent, mkResult,
    mkProbed,         ## one owner session re-read by the prober
    mkProbeDone       ## the prober has finished one round

  Msg = object
    kind: MsgKind
    conn: int
    text: string      ## a request line, an event's data, a result envelope line
    reqId: string
    event: string
    exit: int
    fd: int           ## mkConnected: the accepted socket

  Chan = ptr Channel[Msg]

  WorkerArg = object
    argv: seq[string]
    stdin: string     ## the request's `stdin`
    hasStdin: bool
    env: seq[(string, string)]
    defaults: seq[(string, string)]
    cwd, selfExe, owner, reqId: string
    conn: int
    token: CancelToken
    chan: Chan

  ReaderArg = object
    fd: int
    useStdin: bool
    conn: int
    chan: Chan

  AcceptArg = object
    fd: int
    chan: Chan

  ProbeArg = object
    targets: seq[(int, string)]   ## (connection, owner session id)
    env: seq[(string, string)]
    defaults: seq[(string, string)]
    cwd, selfExe: string
    chan: Chan

  ReqState = enum rsQueued, rsRunning

  Request = ref object
    id: string
    conn: int
    argv: seq[string]
    stdin: string     ## the request's `stdin` key (spec §8.3)
    hasStdin: bool
    key: string       ## "" = may run alongside anything
    state: ReqState
    token: CancelToken
    thread: ptr Thread[WorkerArg]
    seq: int
    verb: string

  Conn = ref object
    id: int
    fd: int           ## -1 for stdout
    open: bool        ## still readable / writable
    closing: bool     ## EOF seen; waiting for its requests to finish
    inflight: Table[string, Request]
    finished: OrderedSet[string]
    ownerSessions: seq[string]
    ownerStates: Table[string, string]
      ## The last `state` reported for each owner session.
    eventSeq: int     ## the next `seq` of a connection event (session-state)

  ServeOptions* = object
    ## `serve`'s own flags plus the defaults its global flags set.
    transport*: string            ## "stdio" or "unix"
    socketPath*: string
    socketInStateDir*: bool       ## the default `<state-dir>/serve.sock`
    maxConcurrency*: int
    defaults*: Table[string, string]

  Daemon = object
    opts: ServeOptions
    ctx: RunContext
    processToken: CancelToken
    chan: Chan
    conns: Table[int, Conn]
    queue: seq[Request]           ## arrival order, queued and running
    nextConn: int
    shuttingDown: bool
    drain: bool
    listenFd: int
    cancelledOnShutdown: int
    prober: ptr Thread[ProbeArg]  ## nil while no probe round runs
    lastProbeNs: int64

# ---------------------------------------------------------------------------
# Threads
# ---------------------------------------------------------------------------

proc workerMain(a: WorkerArg) {.thread.} =
  var env = initTable[string, string]()
  for (k, v) in a.env: env[k] = v
  var defaults = initTable[string, string]()
  for (k, v) in a.defaults: defaults[k] = v
  let chan = a.chan
  let conn = a.conn
  let reqId = a.reqId
  let input = a.stdin
  # The request's `stdin` is what `type --stdin` / `--value-stdin` read; a
  # request without one has no standard input (the daemon's own stdin is the
  # protocol stream, never a verb's input).
  let source: StdinSource =
    if a.hasStdin:
      proc (maxBytes: int): string =
        if input.len > maxBytes:
          raise newException(FileTooLargeError, "the request's stdin is " & $input.len &
            " bytes, larger than the limit of " & $maxBytes)
        input
    else: nil
  let ctx = RunContext(env: env, cwd: a.cwd, selfExe: a.selfExe, token: a.token,
    stdin: source, stdinOffered: a.hasStdin,
    emit: proc (event: string, data: JsonNode) =
      var text: string
      try:
        checkSerializable(data)
        text = $data
      except ContractError:
        text = $(%*{"error": "event data could not be serialized"})
      chan[].send(Msg(kind: mkEvent, conn: conn, reqId: reqId, event: event,
                      text: text)),
    owner: some(a.owner), defaults: defaults, nested: true)
  # The backend interfaces are objects of closures, whose types carry no
  # gcsafe annotation, so the compiler cannot prove the call GC-safe. It is:
  # the library holds no global state, and everything this thread touches
  # (context, backends, JSON) is created here and never shared; results
  # leave the thread only as copies sent through the channel.
  var o: Outcome
  {.cast(gcsafe).}:
    o = runInvocation(a.argv, ctx)
  chan[].send(Msg(kind: mkResult, conn: conn, reqId: reqId, exit: o.exit,
                  text: o.line))

proc probeMain(a: ProbeArg) {.thread.} =
  ## Re-read each owner session with `session-info`, through the same
  ## `runInvocation` as every request, and post each outcome.
  var env = initTable[string, string]()
  for (k, v) in a.env: env[k] = v
  var defaults = initTable[string, string]()
  for (k, v) in a.defaults: defaults[k] = v
  let token = newCancelToken()
  let ctx = RunContext(env: env, cwd: a.cwd, selfExe: a.selfExe, token: token,
                       defaults: defaults, nested: true)
  for (conn, id) in a.targets:
    var o: Outcome
    # GC-safe for the reason given in `workerMain`.
    {.cast(gcsafe).}:
      o = runInvocation(@["session-info", id], ctx)
    a.chan[].send(Msg(kind: mkProbed, conn: conn, reqId: id, exit: o.exit,
                      text: o.line))
  free(token)
  a.chan[].send(Msg(kind: mkProbeDone))

proc readerMain(a: ReaderArg) {.thread.} =
  ## Post every line of the input, a too-long marker for each oversized
  ## line, and EOF.
  var line = ""
  var discarding = false
  var buf: array[65536, char]
  while true:
    # read(2) / ReadFile return what is available; a buffered fread would
    # wait for a full buffer and hold a request back until EOF.
    var n: int
    when defined(posix):
      n = posix.read(cint(if a.useStdin: 0 else: a.fd), addr buf[0], buf.len)
      if n < 0 and errno == EINTR: continue
    else:
      var got: int32
      if readFile(getStdHandle(STD_INPUT_HANDLE), addr buf[0], int32(buf.len),
                  addr got, nil) == 0:
        got = 0
      n = int(got)
    if n <= 0: break
    for i in 0 ..< n:
      let c = buf[i]
      if c == '\n':
        if not discarding:
          a.chan[].send(Msg(kind: mkLine, conn: a.conn, text: line))
        line.setLen(0)
        discarding = false
      elif not discarding:
        line.add c
        if line.len > maxLineBytes:
          a.chan[].send(Msg(kind: mkTooLong, conn: a.conn))
          line.setLen(0)
          discarding = true
  if line.len > 0 and not discarding:
    a.chan[].send(Msg(kind: mkLine, conn: a.conn, text: line))
  a.chan[].send(Msg(kind: mkEof, conn: a.conn))

when defined(posix):
  when defined(macosx) or defined(bsd):
    proc getpeereid(s: cint, uid: var Uid, gid: var Gid): cint {.
      importc, header: "<unistd.h>".}
  else:
    type Ucred {.importc: "struct ucred", header: "<sys/socket.h>".} = object
      pid: Pid
      uid: Uid
      gid: Gid
    var SO_PEERCRED {.importc, header: "<sys/socket.h>".}: cint

  proc peerUid(fd: cint): int =
    ## The uid of the process at the other end of a Unix socket, or -1.
    when defined(macosx) or defined(bsd):
      var uid: Uid
      var gid: Gid
      if getpeereid(fd, uid, gid) != 0: return -1
      int(uid)
    else:
      var cred: Ucred
      var len = SockLen(sizeof(cred))
      if getsockopt(SocketHandle(fd), SOL_SOCKET, SO_PEERCRED, addr cred,
                    addr len) != 0: return -1
      int(cred.uid)

  proc setCloexec(fd: cint) =
    let flags = fcntl(fd, F_GETFD)
    if flags >= 0: discard fcntl(fd, F_SETFD, flags or FD_CLOEXEC)

  proc acceptMain(a: AcceptArg) {.thread.} =
    let me = int(getuid())
    while true:
      var sa: Sockaddr_un
      var len = SockLen(sizeof(sa))
      let fd = accept(SocketHandle(a.fd), cast[ptr SockAddr](addr sa), addr len)
      if int(fd) < 0:
        if errno == EINTR: continue
        break
      setCloexec(cint(fd))
      if peerUid(cint(fd)) != me:
        stderr.writeLine("guiassert serve: refused a connection from another user")
        discard posix.close(cint(fd))
        continue
      a.chan[].send(Msg(kind: mkConnected, fd: int(fd)))

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

proc writeLine(d: var Daemon, c: Conn, line: string) =
  ## Write one message line to a connection; a dead peer closes it.
  if not c.open: return
  let data = line & "\n"
  if c.fd < 0:
    try:
      stdout.write(data)
      stdout.flushFile()
    except IOError:
      c.open = false
    return
  when defined(posix):
    var off = 0
    while off < data.len:
      let n = posix.write(cint(c.fd), unsafeAddr data[off], data.len - off)
      if n <= 0:
        if n < 0 and errno == EINTR: continue
        c.open = false
        return
      off += n

proc idJson(id: string): string =
  if id.len == 0: "null" else: $(%id)

proc protocolError(d: var Daemon, c: Conn, msg: string, reason = "invalid-value",
                   details: JsonNode = nil) =
  let e = newContractError(ekBadArgs, reason, msg, details = details)
  d.writeLine(c, $(%*{"v": serveProtocolVersion, "id": nil, "type": "protocol-error",
                      "error": errorJson(e)}))

proc writeResult(d: var Daemon, c: Conn, id: string, exit: int, envelopeLine: string) =
  ## The terminal `result` of a request. The envelope is spliced in as the
  ## exact line `runInvocation` rendered, so it is byte-identical to the CLI.
  d.writeLine(c, "{\"v\":" & $serveProtocolVersion & ",\"id\":" & idJson(id) &
                 ",\"type\":\"result\",\"exit\":" & $exit & ",\"envelope\":" &
                 envelopeLine & "}")

proc writeEnvelopeResult(d: var Daemon, c: Conn, id: string, env: JsonNode) =
  d.writeResult(c, id, envelopeExitCode(env), renderEnvelope(env))

proc writeSessionState(d: var Daemon, c: Conn, session: JsonNode) =
  ## The connection event `session-state` (spec §8.4): no request id, the
  ## connection's own `seq`, and the session as `session-info` reports it.
  d.writeLine(c, "{\"v\":" & $serveProtocolVersion & ",\"id\":null,\"type\":\"event\"," &
                 "\"seq\":" & $c.eventSeq & ",\"event\":\"session-state\",\"data\":" &
                 $(%*{"session": session}) & "}")
  inc c.eventSeq

# ---------------------------------------------------------------------------
# Requests
# ---------------------------------------------------------------------------

proc validId(id: string): bool =
  id.len in 1..64 and id.allCharsInSet(idChars)

proc requestKey(d: Daemon, argv: seq[string]): string =
  ## The ordering key of a run request: its session, or "" for a
  ## session-less verb (spec §8.5). An argv that does not parse is
  ## session-less: it only produces its bad-args envelope.
  var inv: Invocation
  try: inv = parseInvocation(argv)
  except CatchableError: return ""
  if inv.verb in sessionlessVerbs or inv.verb == "capabilities": return ""
  if inv.verb == "ocr" and inv.has("image"): return ""
  if inv.verb in ["session-info", "session-stop"]: return "session:" & inv.positionals[0]
  let s = if "session" in inv.globals: inv.globals["session"]
          else: d.opts.defaults.getOrDefault("session", hostSessionId)
  "session:" & s

proc cancelledEnvelope(argv: seq[string], reason: CancelReason): JsonNode =
  var verb = findVerbToken(argv)
  try: verb = parseInvocation(argv).verb
  except CatchableError: discard
  failureEnvelope(verb, cancelledError(reason))

proc finishRequest(d: var Daemon, r: Request) =
  let c = d.conns[r.conn]
  c.inflight.del r.id
  c.finished.incl r.id
  while c.finished.len > finishedMemory:
    var first = ""
    for x in c.finished:
      first = x
      break
    c.finished.excl first
  for i in 0 ..< d.queue.len:
    if d.queue[i] == r:
      d.queue.delete(i)
      break
  if r.thread != nil:
    joinThread(r.thread[])
    freeShared(r.thread)
    r.thread = nil
  free(r.token)
  r.token = nil

proc startRequest(d: var Daemon, r: Request) =
  var env: seq[(string, string)]
  for k, v in d.ctx.env: env.add (k, v)
  var defaults: seq[(string, string)]
  for k, v in d.opts.defaults: defaults.add (k, v)
  r.state = rsRunning
  r.thread = createShared(Thread[WorkerArg])
  createThread(r.thread[], workerMain, WorkerArg(
    argv: r.argv, stdin: r.stdin, hasStdin: r.hasStdin, env: env,
    defaults: defaults, cwd: d.ctx.cwd,
    selfExe: d.ctx.selfExe, owner: "serve:" & $getCurrentProcessId() & ":" & $r.conn,
    reqId: r.id, conn: r.conn, token: r.token, chan: d.chan))

proc schedule(d: var Daemon) =
  ## Start every queued request that may run now: within the concurrency
  ## limit, and behind no earlier request of its session.
  var running = 0
  var busy = initHashSet[string]()
  for r in d.queue:
    if r.state == rsRunning:
      inc running
      if r.key.len > 0: busy.incl r.key
  for r in d.queue:
    if r.state != rsQueued: continue
    if r.key.len > 0 and r.key in busy: continue
    if r.key.len > 0: busy.incl r.key   # later ones of this key wait for it
    if running >= d.opts.maxConcurrency: break
    d.startRequest(r)
    inc running

proc cancelRequest(d: var Daemon, r: Request, reason: CancelReason) =
  ## Cancel one request: a queued one answers at once, a running one at its
  ## next safe point.
  if r.state == rsQueued:
    let c = d.conns[r.conn]
    d.writeEnvelopeResult(c, r.id, cancelledEnvelope(r.argv, reason))
    d.finishRequest(r)
  else:
    r.token.cancel(reason)

proc noteOwnerSession(c: Conn, argv: seq[string], line: string) =
  ## Track sessions this connection started with `lifetime: owner`.
  var env: JsonNode
  try: env = parseJson(line)
  except CatchableError: return
  if not env{"ok"}.getBool: return
  let verb = env{"verb"}.getStr
  if verb == "session-start":
    let s = env{"data", "session"}
    if s != nil and s{"lifetime"}.getStr == "owner":
      c.ownerSessions.add s{"id"}.getStr
      c.ownerStates[s{"id"}.getStr] = s{"state"}.getStr
  elif verb == "session-stop":
    let id = env{"data", "session", "id"}.getStr
    let i = c.ownerSessions.find(id)
    if i >= 0: c.ownerSessions.delete(i)
    c.ownerStates.del id

proc stopOwnerSessions(d: var Daemon, c: Conn): int =
  ## Stop every `lifetime: owner` session of a closing connection; returns
  ## how many stopped.
  for id in c.ownerSessions:
    let token = newCancelToken()
    var ctx = d.ctx
    ctx.token = token
    ctx.defaults = d.opts.defaults
    ctx.nested = true
    ctx.emit = nil
    let o = runInvocation(@["session-stop", id], ctx)
    free(token)
    if o.exit == 0:
      inc result
      d.writeSessionState(c, o.envelope["data"]["session"])
    else: stderr.writeLine("guiassert serve: could not stop owner session " & id &
                           ": " & o.line)
  c.ownerSessions.setLen(0)
  c.ownerStates.clear()

proc startProbe(d: var Daemon) =
  ## Start one probe round over every open connection's owner sessions,
  ## unless one is running, the last ended less than `probeIntervalMs` ago,
  ## or there is nothing to probe.
  if d.prober != nil: return
  if monoNowNs() - d.lastProbeNs < int64(probeIntervalMs) * 1_000_000: return
  var targets: seq[(int, string)]
  for cid, c in d.conns:
    if c.open and not c.closing:
      for id in c.ownerSessions: targets.add (cid, id)
  if targets.len == 0: return
  var env: seq[(string, string)]
  for k, v in d.ctx.env: env.add (k, v)
  var defaults: seq[(string, string)]
  for k, v in d.opts.defaults: defaults.add (k, v)
  d.prober = createShared(Thread[ProbeArg])
  createThread(d.prober[], probeMain, ProbeArg(targets: targets, env: env,
    defaults: defaults, cwd: d.ctx.cwd, selfExe: d.ctx.selfExe, chan: d.chan))

proc handleProbed(d: var Daemon, m: Msg) =
  ## One owner session as the prober read it: a changed state is a
  ## `session-state` event; a record that is gone (stopped by another
  ## client) is no longer owned. Anything else (a failing backend) is left
  ## for the next round.
  if m.conn notin d.conns: return
  let c = d.conns[m.conn]
  if c.closing or m.reqId notin c.ownerStates: return
  if m.exit == 3:
    let i = c.ownerSessions.find(m.reqId)
    if i >= 0: c.ownerSessions.delete(i)
    c.ownerStates.del m.reqId
    return
  if m.exit != 0: return
  var s: JsonNode
  try: s = parseJson(m.text){"data", "session"}
  except CatchableError: return
  if s == nil or s.kind != JObject: return
  let state = s{"state"}.getStr
  if state != c.ownerStates[m.reqId]:
    c.ownerStates[m.reqId] = state
    d.writeSessionState(c, s)

proc handleRun(d: var Daemon, c: Conn, id: string, n: JsonNode) =
  expectObject(n, "request", ["v", "id", "op", "argv"], ["timeoutMs", "stdin"])
  var argv: seq[string]
  for i, a in readArray(n, "argv", "request"):
    if a.kind != JString:
      raise newException(JsonShapeError, "request.argv[" & $i & "]: expected a string")
    argv.add a.getStr
  if n.hasKey("timeoutMs"):
    let t = readInt(n, "timeoutMs", "request")
    if t < 1: raise newException(JsonShapeError, "request.timeoutMs: must be positive")
    argv.add @["--timeout-ms", $t]
  let hasStdin = n.hasKey("stdin")
  let input = if hasStdin: readStr(n, "stdin", "request") else: ""
  let r = Request(id: id, conn: c.id, argv: argv, key: d.requestKey(argv),
                  token: newCancelToken(), stdin: input, hasStdin: hasStdin)
  if d.shuttingDown:
    d.writeEnvelopeResult(c, id, cancelledEnvelope(argv, crShutdown))
    free(r.token)
    return
  c.inflight[id] = r
  d.queue.add r

proc handleHello(d: var Daemon, c: Conn, id: string, n: JsonNode) =
  expectObject(n, "request", ["v", "id", "op", "contract"])
  var majors: seq[int]
  for i, m in readArray(n, "contract", "request"):
    if m.kind != JInt:
      raise newException(JsonShapeError, "request.contract[" & $i & "]: expected an integer")
    majors.add m.getInt
  if contractMajor in majors:
    d.writeEnvelopeResult(c, id, successEnvelope("hello",
      %*{"contract": contractJson(), "accepted": true}))
  else:
    d.writeEnvelopeResult(c, id, failureEnvelope("hello", newContractError(ekBadArgs,
      "contract-unsupported", "none of the requested contract majors " & $majors &
        " is implemented (this daemon implements " & $contractMajor & ")",
      details = %*{"contract": contractJson(), "accepted": false})))

proc beginShutdown(d: var Daemon, drain: bool)

proc handleCancel(d: var Daemon, c: Conn, id: string, n: JsonNode) =
  expectObject(n, "request", ["v", "id", "op", "target"])
  let target = readStr(n, "target", "request")
  if target in c.inflight:
    d.cancelRequest(c.inflight[target], crRequest)
    d.writeEnvelopeResult(c, id, successEnvelope("cancel",
      %*{"target": target, "state": "cancelled"}))
  elif target in c.finished:
    d.writeEnvelopeResult(c, id, successEnvelope("cancel",
      %*{"target": target, "state": "already-finished"}))
  else:
    d.writeEnvelopeResult(c, id, failureEnvelope("cancel", newContractError(
      ekNotFound, "request", "no request '" & target & "' on this connection")))

proc handleLine(d: var Daemon, c: Conn, line: string) =
  var n: JsonNode
  try:
    n = parseJson(line)
  except CatchableError:
    d.protocolError(c, "the line is not JSON")
    return
  if n.kind != JObject:
    d.protocolError(c, "a request is a JSON object")
    return
  try:
    if not n.hasKey("v") or n["v"].kind != JInt or n["v"].getInt != serveProtocolVersion:
      d.protocolError(c, "\"v\" must be " & $serveProtocolVersion, "contract-unsupported")
      return
    if not n.hasKey("id") or n["id"].kind != JString or not validId(n["id"].getStr):
      d.protocolError(c, "\"id\" is missing or does not match [A-Za-z0-9._:-]{1,64}",
                      "missing-argument")
      return
    let id = n["id"].getStr
    if id in c.inflight:
      d.protocolError(c, "duplicate in-flight id \"" & id & "\"",
                      details = %*{"id": id})
      return
    if not n.hasKey("op") or n["op"].kind != JString:
      d.protocolError(c, "\"op\" is missing", "missing-argument", %*{"id": id})
      return
    case n["op"].getStr
    of "run": d.handleRun(c, id, n)
    of "hello": d.handleHello(c, id, n)
    of "cancel": d.handleCancel(c, id, n)
    of "shutdown":
      expectObject(n, "request", ["v", "id", "op"], ["drain"])
      let drain = if n.hasKey("drain"): readBool(n, "drain", "request") else: false
      d.writeEnvelopeResult(c, id, successEnvelope("shutdown", %*{"drain": drain}))
      d.beginShutdown(drain)
    else:
      d.protocolError(c, "unknown op \"" & n["op"].getStr & "\"", details = %*{"id": id})
  except JsonShapeError as e:
    d.protocolError(c, e.msg, details = %*{"id": n{"id"}.getStr})

# ---------------------------------------------------------------------------
# Connections and shutdown
# ---------------------------------------------------------------------------

proc readyLine(d: Daemon): string =
  var data = %*{"pid": getCurrentProcessId(), "guiassert": guiassertVersion,
                "contract": contractJson(), "transport": d.opts.transport}
  if d.opts.transport == "unix": data["path"] = %d.opts.socketPath
  $(%*{"v": serveProtocolVersion, "type": "ready", "data": data})

proc startReader(d: var Daemon, c: Conn) =
  var th = createShared(Thread[ReaderArg])
  createThread(th[], readerMain, ReaderArg(fd: c.fd, useStdin: c.fd < 0,
                                           conn: c.id, chan: d.chan))
  # Reader threads end with their input; they are never joined, and the
  # process exits without waiting for one blocked in read().

proc addConn(d: var Daemon, fd: int): Conn =
  result = Conn(id: d.nextConn, fd: fd, open: true)
  inc d.nextConn
  d.conns[result.id] = result
  d.startReader(result)

proc closeConn(d: var Daemon, c: Conn) =
  ## The peer is gone (socket transport): cancel its requests; it closes
  ## once they have answered.
  c.closing = true
  for id, r in c.inflight:
    if r.state == rsRunning: r.token.cancel(crShutdown)
  var queued: seq[Request]
  for id, r in c.inflight:
    if r.state == rsQueued: queued.add r
  for r in queued: d.cancelRequest(r, crShutdown)

proc finishClosedConns(d: var Daemon) =
  var gone: seq[int]
  for id, c in d.conns:
    if c.closing and c.inflight.len == 0 and not d.shuttingDown:
      discard d.stopOwnerSessions(c)
      when defined(posix):
        if c.fd >= 0: discard posix.close(cint(c.fd))
      gone.add id
  for id in gone: d.conns.del id

proc beginShutdown(d: var Daemon, drain: bool) =
  if d.shuttingDown: return
  d.shuttingDown = true
  d.drain = drain
  when defined(posix):
    if d.listenFd >= 0:
      discard posix.shutdown(SocketHandle(d.listenFd), SHUT_RDWR)
      discard posix.close(cint(d.listenFd))
      d.listenFd = -1
  if drain: return
  var all: seq[Request]
  for r in d.queue: all.add r
  for r in all:
    inc d.cancelledOnShutdown
    d.cancelRequest(r, crShutdown)

proc inflightCount(d: Daemon): int =
  for _, c in d.conns: result += c.inflight.len

proc finishShutdown(d: var Daemon) =
  var stopped = 0
  for _, c in d.conns: stopped += d.stopOwnerSessions(c)
  let line = $(%*{"v": serveProtocolVersion, "type": "shutdown",
                  "data": {"cancelled": d.cancelledOnShutdown,
                           "sessionsStopped": stopped}})
  var wroteStdout = false
  for _, c in d.conns:
    d.writeLine(c, line)
    if c.fd < 0: wroteStdout = true
  if not wroteStdout:
    try:
      stdout.writeLine(line)
      stdout.flushFile()
    except IOError: discard
  when defined(posix):
    if d.opts.transport == "unix":
      try: removeFile(d.opts.socketPath) except OSError: discard

proc handle(d: var Daemon, m: Msg) =
  case m.kind
  of mkConnected:
    if d.shuttingDown:
      when defined(posix): discard posix.close(cint(m.fd))
      return
    let c = d.addConn(m.fd)
    d.writeLine(c, d.readyLine())
  of mkLine:
    if m.conn notin d.conns: return
    let c = d.conns[m.conn]
    if c.closing: return
    if m.text.strip.len == 0: return
    d.handleLine(c, m.text)
  of mkTooLong:
    if m.conn in d.conns:
      d.protocolError(d.conns[m.conn], "request line longer than 1 MiB discarded")
  of mkEof:
    if m.conn notin d.conns: return
    let c = d.conns[m.conn]
    if c.fd < 0: d.beginShutdown(drain = false)   # stdin EOF (spec §8.7)
    else: d.closeConn(c)
  of mkEvent:
    if m.conn notin d.conns: return
    let c = d.conns[m.conn]
    if m.reqId notin c.inflight: return
    let r = c.inflight[m.reqId]
    d.writeLine(c, "{\"v\":" & $serveProtocolVersion & ",\"id\":" & idJson(r.id) &
                   ",\"type\":\"event\",\"seq\":" & $r.seq & ",\"event\":" &
                   $(%m.event) & ",\"data\":" & m.text & "}")
    inc r.seq
  of mkResult:
    if m.conn notin d.conns: return
    let c = d.conns[m.conn]
    if m.reqId notin c.inflight: return
    let r = c.inflight[m.reqId]
    d.writeResult(c, r.id, m.exit, m.text)
    noteOwnerSession(c, r.argv, m.text)
    d.finishRequest(r)
  of mkProbed:
    d.handleProbed(m)
  of mkProbeDone:
    if d.prober != nil:
      joinThread(d.prober[])
      freeShared(d.prober)
      d.prober = nil
    d.lastProbeNs = monoNowNs()

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

proc parseServeArgs*(argv: seq[string], ctx: RunContext): ServeOptions =
  ## Parse `serve`'s argv (without the program name). Raises `ContractError`.
  result.maxConcurrency = defaultMaxConcurrency
  var listen = ""
  var listening = false
  var stdio = false
  var sawVerb = false
  var sawMax = false
  var i = 0
  while i < argv.len:
    let tok = argv[i]
    if tok == "serve" and not sawVerb:
      sawVerb = true
      inc i
      continue
    if not tok.startsWith("--"):
      raise badArgs("invalid-value", "serve: unexpected argument '" & tok & "'")
    let name = tok[2 .. ^1]
    if name == "stdio":
      if stdio: raise badArgs("conflicting-arguments", "--stdio is given more than once")
      stdio = true
      inc i
      continue
    if name notin globalFlags and name notin ["listen", "max-concurrency"]:
      raise badArgs("unknown-flag", "serve has no flag " & tok)
    if i + 1 >= argv.len: raise badArgs("missing-argument", tok & " needs a value")
    let v = argv[i + 1]
    case name
    of "listen":
      if listening: raise badArgs("conflicting-arguments", "--listen is given more than once")
      if not v.startsWith("unix:"):
        raise badArgs("invalid-value", "--listen takes unix:<path> (contract 1 has no TCP)")
      listening = true
      listen = v[5 .. ^1]
    of "max-concurrency":
      if sawMax: raise badArgs("conflicting-arguments", "--max-concurrency is given more than once")
      sawMax = true
      result.maxConcurrency = parseIntValue("--max-concurrency", v, 1, 256)
    else:
      if name in result.defaults:
        raise badArgs("conflicting-arguments", tok & " is given more than once")
      result.defaults[name] = v
    i += 2
  if not sawVerb: raise badArgs("missing-argument", "no serve verb")
  if stdio and listening:
    raise badArgs("conflicting-arguments", "--stdio and --listen exclude each other")
  if "contract" in result.defaults and not contractSupported(result.defaults["contract"]):
    raise newContractError(ekBadArgs, "contract-unsupported", "this guiassert " &
      "implements contract major " & $contractMajor)
  if "timeout-ms" in result.defaults:
    discard parseIntValue("--timeout-ms", result.defaults["timeout-ms"], 1, 86_400_000)
  if not listening:
    result.transport = "stdio"
  else:
    result.transport = "unix"
    when not defined(posix):
      raise newContractError(ekBackendUnavailable, "wrong-platform",
        "serve --listen unix: is not available on Windows in this build; use --stdio",
        details = %*{"feature": nil})   # a transport, not a capability (spec §7.2)
    let stateDir = resolveStateDir(
      (if "state-dir" in result.defaults: some(result.defaults["state-dir"]) else: none(string)),
      ctx.env, ctx.cwd).dir
    result.socketInStateDir = listen.len == 0
    result.socketPath = if listen.len == 0: stateDir / "serve.sock"
                        else: absolutePath(listen, ctx.cwd)

when defined(posix):
  proc listenUnix(path: string, inStateDir: bool): int =
    ## Create the owner-only listening socket (mode 0600 in a 0700
    ## directory). The state directory is made 0700 like every state
    ## directory GuiAssert writes; any other existing directory must already
    ## be 0700 and owned by this user, and is refused otherwise rather than
    ## having its mode changed. Raises `ContractError`.
    let dir = path.parentDir
    if inStateDir or not dirExists(dir):
      ensurePrivateDir(dir)
    var st: Stat
    if stat(dir.cstring, st) != 0:
      raise badArgs("invalid-value", "cannot stat the socket directory " & dir)
    if (int(st.st_mode) and 0o077) != 0 or int(st.st_uid) != int(getuid()):
      raise badArgs("invalid-value", "the socket directory " & dir &
        " must be owned by this user and mode 0700")
    var sa: Sockaddr_un
    if path.len >= sizeof(sa.sun_path):
      raise badArgs("invalid-value", "the socket path is too long: " & path)
    sa.sun_family = TSa_Family(AF_UNIX)
    for i, ch in path: sa.sun_path[i] = ch
    if fileExists(path) or symlinkExists(path) or dirExists(path):
      # A live daemon answers; a stale socket file is removed.
      let probe = socket(AF_UNIX, SOCK_STREAM, 0)
      let live = connect(probe, cast[ptr SockAddr](addr sa), SockLen(sizeof(sa))) == 0
      discard posix.close(cint(probe))
      if live:
        raise newContractError(ekBackendError, "busy",
          "another guiassert serve is listening on " & path)
      if dirExists(path):
        raise badArgs("invalid-value", path & " is a directory")
      removeFile(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if int(fd) < 0:
      raise newContractError(ekInternal, "exception", "socket(): " & osErrorMsg(osLastError()))
    setCloexec(cint(fd))
    let old = umask(Mode(0o177))
    let rc = bindSocket(fd, cast[ptr SockAddr](addr sa), SockLen(sizeof(sa)))
    discard umask(old)
    if rc != 0:
      discard posix.close(cint(fd))
      raise newContractError(ekInternal, "exception", "bind(" & path & "): " &
        osErrorMsg(osLastError()))
    discard chmod(path.cstring, Mode(0o600))
    if listen(fd, 16) != 0:
      discard posix.close(cint(fd))
      raise newContractError(ekInternal, "exception", "listen(): " & osErrorMsg(osLastError()))
    int(fd)

proc serveMain*(argv: seq[string], ctx: RunContext, processToken: CancelToken): int =
  ## Run the daemon until it shuts down; returns the process exit code. A
  ## startup failure prints one failure envelope (verb `serve`) instead of
  ## the ready line. `processToken` is cancelled by the caller's signal
  ## handler (SIGTERM / SIGINT), which shuts the daemon down.
  var d = Daemon(ctx: ctx, processToken: processToken, listenFd: -1)
  try:
    d.opts = parseServeArgs(argv, ctx)
    when defined(posix):
      if d.opts.transport == "unix":
        d.listenFd = listenUnix(d.opts.socketPath, d.opts.socketInStateDir)
  except ContractError as e:
    let env = failureEnvelope("serve", e)
    stdout.writeLine(renderEnvelope(env))
    return e.kind.code
  except CatchableError as e:
    let env = failureEnvelope("serve", newContractError(ekInternal, "exception", e.msg))
    stdout.writeLine(renderEnvelope(env))
    return 1
  when defined(posix):
    # A peer that disconnects mid-write must not kill the daemon.
    signal(SIGPIPE, SIG_IGN)
  d.chan = cast[Chan](allocShared0(sizeof(Channel[Msg])))
  d.chan[].open()
  stdout.writeLine(d.readyLine())
  stdout.flushFile()
  if d.opts.transport == "stdio":
    discard d.addConn(-1)
  else:
    when defined(posix):
      var th = createShared(Thread[AcceptArg])
      createThread(th[], acceptMain, AcceptArg(fd: d.listenFd, chan: d.chan))
  while true:
    if processToken.reason != crNone and not d.shuttingDown:
      d.beginShutdown(drain = false)
    let (got, m) = d.chan[].tryRecv()
    if got:
      d.handle(m)
      continue
    d.finishClosedConns()
    if not d.shuttingDown:
      d.schedule()
      d.startProbe()
    elif d.drain: d.schedule()
    # A probe round still running finishes first: its thread is joined, and
    # the owner sessions it reads are then stopped by `finishShutdown`.
    if d.shuttingDown and d.inflightCount == 0 and d.prober == nil:
      d.finishShutdown()
      return 0
    sleep(2)
