## `guiassert serve` (spec §8): the NDJSON protocol over stdio and over an
## owner-only Unix socket, against the REAL built binary.
##
## Stand-ins: the fixture backend (spec §9.2) below the real daemon; its
## GUIASSERT_FIXTURE_DELAY_MS makes a verb slow enough to cancel, time out or
## overlap, which no real backend can be made to do on demand.

import std/[json, os, osproc, sequtils, sets, strtabs, strutils, tables, unittest,
            times, monotimes]

when defined(posix):
  import std/posix

import ./harness

proc msUntil(start: MonoTime): int64 = (getMonoTime() - start).inMilliseconds

proc resultFor(d: var Daemon, id: string, events: var seq[JsonNode],
               timeoutMs = 30_000): tuple[msg: JsonNode, line: string] =
  ## Read until the result of `id`; its events are collected in order, and
  ## a message for another id is an error (callers wait for one at a time).
  while true:
    let line = d.recvRaw(timeoutMs)
    let m = parseJson(line)
    doAssert m{"id"}.getStr == id, "unexpected message while waiting for " & id & ": " & line
    case m["type"].getStr
    of "event": events.add m
    of "result": return (m, line)
    else: doAssert false, "unexpected message: " & line

proc resultFor(d: var Daemon, id: string, timeoutMs = 30_000): tuple[msg: JsonNode, line: string] =
  var ev: seq[JsonNode]
  result = d.resultFor(id, ev, timeoutMs)

proc readUntilShutdown(d: var Daemon): seq[JsonNode] =
  while true:
    let m = d.recv(30_000)
    result.add m
    if m["type"].getStr == "shutdown": return

proc maskHostPid(line: string): string =
  ## Spec §6.1: a session's host process is a new process each time it is
  ## started, so its pid is the one value of `session-start` that cannot be
  ## equal between two starts. Everything else must be byte-identical.
  var n = parseJson(line)
  if n{"data", "session", "hostPid"} != nil: n["data"]["session"]["hostPid"] = %0
  $n

suite "serve protocol":
  test "test_contract_flag_and_hello_reject_unknown_major":
    let st = freshDir("hello")
    let env = fixtureEnv(st)
    let (x1, e1, _) = cli(@["--contract", "2", "version"], env)
    check x1 == 2 and e1.errorReason == "contract-unsupported"
    let (x2, _, _) = cli(@["--contract", "1", "version"], env)
    check x2 == 0
    let (x3, e3, _) = cli(@["--contract", "one", "displays"], env)
    check x3 == 2 and e3.errorReason == "contract-unsupported"
    var d = startServe(@["serve", "--stdio"], env)
    d.send(%*{"v": 1, "id": "h2", "op": "hello", "contract": [2]})
    let (r2, _) = d.resultFor("h2")
    check r2["exit"].getInt == 2
    check r2["envelope"]["verb"].getStr == "hello"
    check r2["envelope"]["error"]["reason"].getStr == "contract-unsupported"
    check r2["envelope"]["error"]["details"]["accepted"].getBool == false
    d.send(%*{"v": 1, "id": "h1", "op": "hello", "contract": [1]})
    let (r1, _) = d.resultFor("h1")
    check r1["exit"].getInt == 0
    check r1["envelope"]["data"]["accepted"].getBool
    check r1["envelope"]["data"]["contract"]["major"].getInt == 1
    d.send(%*{"v": 1, "id": "h3", "op": "hello", "contract": [2, 1]})
    check d.resultFor("h3").msg["exit"].getInt == 0
    # A run carrying --contract 2 is refused the same way as on the CLI.
    d.send(runReq("c2", @["--contract", "2", "version"]))
    check d.resultFor("c2").msg["envelope"]["error"]["reason"].getStr == "contract-unsupported"
    d.closeInput()
    discard d.readUntilShutdown()
    check d.finish() == 0
    # A daemon asked for an unknown major refuses to start, with an envelope.
    let r = runCli(@["serve", "--stdio", "--contract", "2"], env)
    check r.exit == 2
    check envelopeOf(r).errorReason == "contract-unsupported"

  test "test_serve_ready_line_then_results_by_id":
    let st = freshDir("ready")
    var d = startServe(@["serve"], fixtureEnv(st))
    check d.ready["v"].getInt == 1
    check d.ready["type"].getStr == "ready"
    check d.ready["data"]["transport"].getStr == "stdio"
    check d.ready["data"]["pid"].getInt == d.p.processID
    check d.ready["data"]["contract"]["name"].getStr == "guiassert-desktop"
    check d.ready["data"]["guiassert"].kind == JString
    # Several requests at once: exactly one result each, matched by id.
    let ids = @["a1", "a2", "a3", "a4", "a5", "a6"]
    d.send(runReq("a1", @["version"]))
    d.send(runReq("a2", @["displays"]))
    d.send(runReq("a3", @["windows"]))
    d.send(runReq("a4", @["no-such-verb"]))
    d.send(%*{"v": 1, "id": "a5", "op": "hello", "contract": [1]})
    d.send(runReq("a6", @["--session", "nobody", "apps"]))
    var got = initCountTable[string]()
    var exits = initTable[string, int]()
    while got.len < ids.len:
      let m = d.recv()
      check m["v"].getInt == 1
      if m["type"].getStr == "result":
        got.inc m["id"].getStr
        exits[m["id"].getStr] = m["exit"].getInt
        let ev = m["envelope"]
        check m["exit"].getInt == (if ev["ok"].getBool: 0 else: ev["error"]["code"].getInt)
    for id in ids: check got[id] == 1
    check exits["a1"] == 0 and exits["a4"] == 2 and exits["a6"] == 3
    check d.reader.noLineWithin(300)       # nothing more arrives
    d.closeInput()
    let tail = d.readUntilShutdown()
    check tail[^1]["data"]["cancelled"].getInt == 0
    check d.finish() == 0

  test "test_serve_cli_byte_parity_for_every_verb":
    let st = freshDir("parity")
    let snap = freshDir("parity-snap")
    let work = freshDir("parity-work")
    prepareWork(work)
    let env = fixtureEnv(st)
    var d = startServe(@["serve", "--stdio"], env)
    var cases = everyVerbScenario(work)
    # Failures too: the same envelope bytes whatever the transport.
    cases.insert(@["no-such-verb", "x"], 1)
    cases.insert(@["windows", "--bogus"], 1)
    cases.insert(@["session-info", "nobody"], 1)
    cases.insert(@["--capture-backend", "linux-x11", "displays"], 1)
    var n = 0
    for argv in cases:
      removeDir(snap)
      copyDir(st, snap)
      let r = runCli(argv, env)
      let cliLine = r.stdout.strip(leading = false, chars = {'\n'})
      removeDir(st)
      copyDir(snap, st)
      inc n
      let id = "p" & $n
      d.send(runReq(id, argv))
      let (msg, line) = d.resultFor(id, 60_000)
      let served = envelopeText(line)
      check msg["exit"].getInt == r.exit
      if argv[0] == "session-start":
        check maskHostPid(served) == maskHostPid(cliLine)
      else:
        check served == cliLine
        if served != cliLine:
          checkpoint argv.join(" ") & "\n  cli:   " & cliLine & "\n  serve: " & served
    d.closeInput()
    discard d.readUntilShutdown()
    check d.finish() == 0

  test "test_serve_cancel_running_request_exits_8":
    let st = freshDir("cancel")
    var d = startServe(@["serve"], fixtureEnv(st, {"GUIASSERT_FIXTURE_DELAY_MS": "displays:20000"}))
    let start = getMonoTime()
    d.send(runReq("r1", @["displays"]))
    sleep(300)
    d.send(%*{"v": 1, "id": "c1", "op": "cancel", "target": "r1"})
    var results = initTable[string, JsonNode]()
    while results.len < 2:
      let m = d.recv()
      if m["type"].getStr == "result": results[m["id"].getStr] = m
    check msUntil(start) < 5000
    check results["c1"]["exit"].getInt == 0
    check results["c1"]["envelope"]["data"]["state"].getStr == "cancelled"
    check results["r1"]["exit"].getInt == 8
    check results["r1"]["envelope"]["error"]["reason"].getStr == "request"
    check results["r1"]["envelope"]["verb"].getStr == "displays"
    # Cancelling it again: already finished. An unknown id: exit 3.
    d.send(%*{"v": 1, "id": "c2", "op": "cancel", "target": "r1"})
    check d.resultFor("c2").msg["envelope"]["data"]["state"].getStr == "already-finished"
    d.send(%*{"v": 1, "id": "c3", "op": "cancel", "target": "never-sent"})
    let (c3, _) = d.resultFor("c3")
    check c3["exit"].getInt == 3
    check c3["envelope"]["error"]["reason"].getStr == "request"
    # A queued request (behind a running one of its session) is removed at once.
    d.send(runReq("q1", @["displays"]))
    d.send(runReq("q2", @["displays"]))
    sleep(200)
    d.send(%*{"v": 1, "id": "c4", "op": "cancel", "target": "q2"})
    var r4 = initTable[string, JsonNode]()
    while r4.len < 2:
      let m = d.recv(5000)
      if m["type"].getStr == "result": r4[m["id"].getStr] = m
    check "q2" in r4 and "c4" in r4      # q1 is still running
    check r4["q2"]["exit"].getInt == 8
    d.send(%*{"v": 1, "id": "c5", "op": "cancel", "target": "q1"})
    var r5 = initTable[string, JsonNode]()
    while r5.len < 2:
      let m = d.recv(5000)
      if m["type"].getStr == "result": r5[m["id"].getStr] = m
    check r5["q1"]["exit"].getInt == 8
    d.closeInput()
    discard d.readUntilShutdown()
    check d.finish() == 0

  test "test_serve_timeout_exits_7":
    let st = freshDir("timeout")
    let env = fixtureEnv(st, {"GUIASSERT_FIXTURE_DELAY_MS": "displays:20000"})
    var d = startServe(@["serve"], env)
    let start = getMonoTime()
    d.send(%*{"v": 1, "id": "t1", "op": "run", "argv": ["displays"], "timeoutMs": 300})
    let (m, _) = d.resultFor("t1")
    check msUntil(start) < 5000
    check m["exit"].getInt == 7
    check m["envelope"]["error"]["reason"].getStr == "deadline"
    # timeoutMs and --timeout-ms in the argv are one flag given twice.
    d.send(%*{"v": 1, "id": "t2", "op": "run", "argv": ["--timeout-ms", "100", "displays"],
              "timeoutMs": 300})
    check d.resultFor("t2").msg["exit"].getInt == 2
    d.closeInput()
    discard d.readUntilShutdown()
    check d.finish() == 0
    # The same deadline on the one-shot CLI.
    let (cx, ce, _) = cli(@["--timeout-ms", "300", "displays"], env)
    check cx == 7 and ce.errorReason == "deadline"

  test "test_serve_duplicate_inflight_id_is_protocol_error":
    let st = freshDir("dup")
    var d = startServe(@["serve"], fixtureEnv(st, {"GUIASSERT_FIXTURE_DELAY_MS": "displays:20000"}))
    d.send(runReq("r1", @["displays"]))
    sleep(200)
    d.send(runReq("r1", @["type", "SHOULD-NOT-RUN"]))
    let pe = d.recv(5000)
    check pe["type"].getStr == "protocol-error"
    check pe["error"]["code"].getInt == 2
    check pe["error"]["kind"].getStr == "bad-args"
    check "r1" in pe["error"]["message"].getStr
    # Malformed lines and unknown keys: protocol-errors, the connection stays.
    for bad in ["not json", "[1, 2]", "{\"v\":1,\"op\":\"run\",\"argv\":[\"version\"]}",
                "{\"v\":1,\"id\":\"k\",\"op\":\"run\",\"argv\":[\"version\"],\"extra\":1}",
                "{\"v\":1,\"id\":\"k\",\"op\":\"teleport\"}",
                "{\"v\":2,\"id\":\"k\",\"op\":\"hello\",\"contract\":[1]}",
                "{\"v\":1,\"id\":\"bad id\",\"op\":\"hello\",\"contract\":[1]}",
                "{\"v\":1,\"id\":\"k\",\"op\":\"run\",\"argv\":[1]}",
                "x".repeat(1_100_000)]:
      d.send(bad)
      let m = d.recv(10_000)
      check m["type"].getStr == "protocol-error"
      check m["error"]["code"].getInt == 2
    d.send(%*{"v": 1, "id": "alive", "op": "hello", "contract": [1]})
    check d.resultFor("alive").msg["exit"].getInt == 0
    d.send(%*{"v": 1, "id": "c", "op": "cancel", "target": "r1"})
    var n = 0
    while n < 2:
      if d.recv()["type"].getStr == "result": inc n
    d.closeInput()
    discard d.readUntilShutdown()
    check d.finish() == 0
    # The duplicate never ran: the field holds no typed text.
    let (vx, ve, _) = cli(@["element", "/app[4242]/window[0]/text-field[0]"], fixtureEnv(st))
    check vx == 0
    check ve.data["element"]["value"].getStr == ""

  test "test_serve_same_session_requests_run_in_order":
    let st = freshDir("order")
    let env = fixtureEnv(st, {"GUIASSERT_FIXTURE_DELAY_MS": "displays:600"})
    for s in ["sa", "sb"]:
      check cli(@["session-start", "--kind", "headless", "--name", s], env).exit == 0
    var d = startServe(@["serve"], env)
    # A slow `type` then a fast BackSpace on one session: in arrival order.
    d.send(runReq("t1", @["type", "abc", "--interval-ms", "150"]))
    d.send(runReq("t2", @["key", "BackSpace"]))
    var order: seq[string]
    while order.len < 2:
      let m = d.recv()
      if m["type"].getStr == "result":
        check m["exit"].getInt == 0
        order.add m["id"].getStr
    check order == @["t1", "t2"]
    d.send(runReq("v", @["element", "/app[4242]/window[0]/text-field[0]"]))
    check d.resultFor("v").msg["envelope"]["data"]["element"]["value"].getStr == "ab"
    # Different sessions overlap ...
    var start = getMonoTime()
    d.send(runReq("d1", @["--session", "sa", "displays"]))
    d.send(runReq("d2", @["--session", "sb", "displays"]))
    var n = 0
    while n < 2:
      if d.recv()["type"].getStr == "result": inc n
    let parallel = msUntil(start)
    check parallel < 1150
    # ... and the same session does not (the control).
    start = getMonoTime()
    d.send(runReq("d3", @["--session", "sa", "displays"]))
    d.send(runReq("d4", @["--session", "sa", "displays"]))
    n = 0
    while n < 2:
      if d.recv()["type"].getStr == "result": inc n
    let serial = msUntil(start)
    check serial >= 1200
    checkpoint "parallel " & $parallel & " ms, serial " & $serial & " ms"
    d.closeInput()
    discard d.readUntilShutdown()
    check d.finish() == 0
    for s in ["sa", "sb"]:
      check cli(@["session-stop", s], env).exit == 0

  test "test_serve_events_seq_has_no_gaps":
    let st = freshDir("events")
    let work = freshDir("events-work")
    var d = startServe(@["serve"], fixtureEnv(st))
    var ev: seq[JsonNode]
    d.send(runReq("rec", @["record", "--out", work / "r", "--duration-ms", "300", "--fps", "10"]))
    let (rm, _) = d.resultFor("rec", ev)
    check rm["exit"].getInt == 0
    # Without the media backend the recording is a PNG sequence, and says so.
    let recd = rm["envelope"]["data"]["recording"]
    if isMinimalBinary():
      check recd["format"].getStr == "png-sequence"
      check toSeq(walkFiles(work / "r" / "*.png")).len == 3
    else:
      check recd["format"].getStr == "mp4"
      check fileExists(work / "r")
    check recd["frames"].getInt == 3 and recd["durationMs"].getInt == 300
    check ev.len == 3
    for i, e in ev:
      check e["seq"].getInt == i
      check e["event"].getStr == "progress"
      check e["data"]["frames"].getInt == i + 1
      check e["data"]["elapsedMs"].getInt == (i + 1) * 100
    var pv: seq[JsonNode]
    d.send(runReq("w", @["wait", "--element", "--role", "dialog", "--wait-ms", "200",
                         "--interval-ms", "50"]))
    let (wm, _) = d.resultFor("w", pv)
    check wm["exit"].getInt == 7
    check wm["envelope"]["error"]["details"]["attempts"].getInt == pv.len
    check pv.len == 5
    for i, e in pv:
      check e["seq"].getInt == i
      check e["event"].getStr == "poll"
      check e["data"]["attempt"].getInt == i + 1
      check e["data"]["elapsedMs"].getInt == i * 50
      check e["data"]["observed"].getInt == 0
    # watch streams windows-changed events, numbered the same way.
    var wv: seq[JsonNode]
    d.send(runReq("wa", @["watch", "--windows", "--duration-ms", "250"]))
    let (wam, _) = d.resultFor("wa", wv)
    check wam["exit"].getInt == 0
    check wv.len >= 1 and wv[0]["event"].getStr == "windows-changed"
    check wam["envelope"]["data"]["events"].getInt == wv.len
    for i, e in wv: check e["seq"].getInt == i
    d.closeInput()
    discard d.readUntilShutdown()
    check d.finish() == 0

  test "test_serve_shutdown_on_stdin_eof_stops_owner_sessions":
    let st = freshDir("eof")
    let env = fixtureEnv(st, {"GUIASSERT_FIXTURE_DELAY_MS": "displays:20000"})
    var d = startServe(@["serve"], env)
    d.send(runReq("o", @["session-start", "--kind", "headless", "--name", "own",
                         "--lifetime", "owner"]))
    let (om, _) = d.resultFor("o")
    check om["exit"].getInt == 0
    let ownPid = om["envelope"]["data"]["session"]["hostPid"].getInt
    d.send(runReq("k", @["session-start", "--kind", "headless", "--name", "kept"]))
    check d.resultFor("k").msg["exit"].getInt == 0
    d.send(runReq("slow", @["displays"]))
    sleep(200)
    d.closeInput()
    let msgs = d.readUntilShutdown()
    check d.finish() == 0
    var slowResult: JsonNode
    for m in msgs:
      if m["type"].getStr == "result" and m["id"].getStr == "slow": slowResult = m
    check slowResult != nil
    check slowResult["exit"].getInt == 8
    check slowResult["envelope"]["error"]["reason"].getStr == "shutdown"
    let sd = msgs[^1]
    check sd["type"].getStr == "shutdown" and sd["v"].getInt == 1
    check sd["data"]["cancelled"].getInt == 1
    check sd["data"]["sessionsStopped"].getInt == 1
    # The owner session is gone, its host too; the detached one is running.
    let (ix, ie, _) = cli(@["session-info", "own"], env)
    check ix == 3 and ie.errorReason == "session"
    when defined(posix):
      check posix.kill(Pid(ownPid), 0) != 0
    let (kx, ke, _) = cli(@["session-info", "kept"], env)
    check kx == 0 and ke.data["session"]["state"].getStr == "running"
    check cli(@["session-stop", "kept"], env).exit == 0

  test "test_serve_session_state_events_for_owner_sessions":
    # Spec §8.4: `session-state` is a connection event (id null, its own seq)
    # for the connection's owner sessions only.
    let st = freshDir("sstate")
    let env = fixtureEnv(st)
    var d = startServe(@["serve"], env)
    var hostPids = initTable[string, int]()
    for (id, name, lifetime) in [("a", "own-a", "owner"), ("b", "own-b", "owner"),
                                 ("c", "kept-c", "detached")]:
      d.send(runReq(id, @["session-start", "--kind", "headless", "--name", name,
                          "--lifetime", lifetime]))
      let (m, _) = d.resultFor(id)
      check m["exit"].getInt == 0
      hostPids[name] = m["envelope"]["data"]["session"]["hostPid"].getInt
    # Nothing is sent while nothing changes.
    check d.reader.noLineWithin(700)
    # The host of an owner session and of a detached one die.
    for name in ["own-b", "kept-c"]:
      when defined(posix):
        check posix.kill(Pid(hostPids[name]), SIGKILL) == 0
      else:
        discard execCmd("taskkill /F /PID " & $hostPids[name])
    let ev = d.recv(5000)
    check ev["type"].getStr == "event"
    check ev["id"].kind == JNull
    check ev["seq"].getInt == 0
    check ev["event"].getStr == "session-state"
    check ev["data"]["session"]["id"].getStr == "own-b"
    check ev["data"]["session"]["state"].getStr == "error"
    check ev["data"]["session"]["stateReason"].getStr == "host-exited"
    # Negative control: the detached session's death is not this
    # connection's event, and the dead owner session is reported once.
    check d.reader.noLineWithin(1200)
    # A request still gets its own events numbered from 0.
    var pv: seq[JsonNode]
    d.send(runReq("w", @["wait", "--element", "--role", "dialog", "--wait-ms", "100",
                         "--interval-ms", "50"]))
    discard d.resultFor("w", pv)
    check pv.len == 3 and pv[0]["seq"].getInt == 0
    # Shutdown stops both owner sessions: one event each, before the
    # shutdown line, continuing the connection's seq.
    d.closeInput()
    let msgs = d.readUntilShutdown()
    check d.finish() == 0
    check msgs.len == 3
    var stopped: seq[string]
    for i, m in msgs[0 ..< ^1]:
      check m["id"].kind == JNull and m["event"].getStr == "session-state"
      check m["seq"].getInt == i + 1
      check m["data"]["session"]["state"].getStr == "stopped"
      stopped.add m["data"]["session"]["id"].getStr
    check toHashSet(stopped) == toHashSet(["own-a", "own-b"])
    check msgs[^1]["data"]["sessionsStopped"].getInt == 2
    check cli(@["session-stop", "kept-c"], env).exit == 0

  when defined(posix):
    test "test_serve_socket_is_owner_only":
      let st = freshDir("sock")
      let env = fixtureEnv(st)
      var d = startServe(@["serve", "--listen", "unix:"], env)
      let path = st / "serve.sock"
      check d.ready["data"]["transport"].getStr == "unix"
      check d.ready["data"]["path"].getStr == path
      var sst: Stat
      check lstat(path.cstring, sst) == 0
      check S_ISSOCK(sst.st_mode)
      check (int(sst.st_mode) and 0o777) == 0o600
      var dst: Stat
      check stat(st.cstring, dst) == 0
      check (int(dst.st_mode) and 0o777) == 0o700
      proc connectTo(p: string): cint =
        result = cint(socket(AF_UNIX, SOCK_STREAM, 0))
        var sa: Sockaddr_un
        sa.sun_family = TSa_Family(AF_UNIX)
        for i, ch in p: sa.sun_path[i] = ch
        doAssert connect(SocketHandle(result), cast[ptr SockAddr](addr sa),
                         SockLen(sizeof(sa))) == 0, "connect failed"
      proc sendLine(fd: cint, s: string) =
        let data = s & "\n"
        doAssert posix.write(fd, unsafeAddr data[0], data.len) == data.len
      let c1 = connectTo(path)
      var r1 = initSocketReader(c1)
      let ready = parseJson(r1.readLine(10_000))
      check ready["type"].getStr == "ready"
      # The same protocol as stdio, the same bytes as the CLI.
      let (_, _, cliLine) = cli(@["displays"], env)
      sendLine(c1, $runReq("s1", @["displays"]))
      let line = r1.readLine(10_000)
      check envelopeText(line) == cliLine
      sendLine(c1, "garbage")
      check parseJson(r1.readLine(10_000))["type"].getStr == "protocol-error"
      sendLine(c1, $runReq("own", @["session-start", "--kind", "headless", "--name", "sockown",
                                    "--lifetime", "owner"]))
      let own = parseJson(r1.readLine(10_000))
      check own["exit"].getInt == 0
      # A second, independent connection.
      let c2 = connectTo(path)
      var r2 = initSocketReader(c2)
      check parseJson(r2.readLine(10_000))["type"].getStr == "ready"
      sendLine(c2, $runReq("s1", @["version"]))         # the same id: another connection
      check parseJson(r2.readLine(10_000))["exit"].getInt == 0
      # Closing connection 1 stops its owner session, not the daemon.
      discard posix.close(c1)
      var gone = false
      for i in 0 ..< 50:
        if cli(@["session-info", "sockown"], env).exit == 3:
          gone = true
          break
        sleep(100)
      check gone
      sendLine(c2, $(%*{"v": 1, "id": "bye", "op": "shutdown"}))
      check parseJson(r2.readLine(10_000))["id"].getStr == "bye"
      check parseJson(r2.readLine(10_000))["type"].getStr == "shutdown"
      discard posix.close(c2)
      check d.finish() == 0
      check not fileExists(path)
      # A socket directory others can enter is refused.
      let openDir = freshDir("sock-open")
      setFilePermissions(openDir, {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead,
                                fpGroupExec, fpOthersRead, fpOthersExec})
      let r = runCli(@["serve", "--listen", "unix:" & openDir / "s.sock"], env)
      check r.exit == 2
      check envelopeOf(r).errorReason == "invalid-value"
      check not fileExists(openDir / "s.sock")

cleanupFreshDirs()
