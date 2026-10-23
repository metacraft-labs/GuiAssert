## tlinux_session — the parts of the private Linux sessions (GS10:
## `linux_private`, `linux_sway`, `linux_gnome`, `linux_xvfb`) and of
## `linux-host`'s attach check that need no display server, so they run in
## the default suite (spec §9.1):
##
## * the environment contract (C6): `composeSessionEnv` and `envUnsetFor`;
## * the readiness bound (C10), generated ids, session tags;
## * the loopback check of a VNC endpoint (`parseProcNetTcp`,
##   `isLoopbackOnly`, with invented /proc/net/tcp tables) and the RFB
##   banner;
## * Xvfb's pieces: the Xauthority entry (byte for byte, against the Xau
##   format) and the `-displayfd` reading;
## * the attach check against REAL Unix sockets made here (a path socket and
##   an abstract one, and a path nothing listens on), and `linux-host` with
##   no display server: session-info `error` / `no-display-server`, `apps`
##   exit 4 / `session-not-running` with `details.feature` null;
## * reconciliation of a recorded session against a real live and a real
##   dead process, the guarded runtime-directory removal, and the tag sweep
##   against real `sleep` processes (only the tagged one is ended);
## * the private session backends' refusals that happen before anything is
##   started: unsupported kinds and options, a missing tool (exit 4 /
##   `missing-tool`, nothing recorded), and `name-in-use` (C10) for a name a
##   session in error holds.
##
## Stand-ins: none. The live suite (`tests/live/tsession_linux.nim`) starts
## real sessions.

import std/[json, options, os, osproc, posix, sequtils, strtabs, strutils, tables,
            tempfiles, unittest]

import ../src/gui_assert/core/[contract, desktop_types, interfaces]
import ../src/gui_assert/[cancel, state_store]
import ../src/gui_assert/backends/capture/linux_common
import ../src/gui_assert/backends/tree/linux_atspi
import ../src/gui_assert/backends/session/[linux_host, linux_private, linux_sway, linux_xvfb]
import ../src/gui_assert/backends/session/linux_gnome as session_gnome

proc ordered(pairs: openArray[(string, string)]): OrderedTable[string, string] =
  for (k, v) in pairs: result[k] = v

proc table(pairs: openArray[(string, string)]): Table[string, string] =
  for (k, v) in pairs: result[k] = v

proc listenUnix(path: string, abstract = false): SocketHandle =
  ## A listening Unix stream socket at `path` (unix(7)).
  result = socket(AF_UNIX, SOCK_STREAM, 0)
  doAssert result.int >= 0
  var sa: Sockaddr_un
  sa.sun_family = TSa_Family(AF_UNIX)
  let off = if abstract: 1 else: 0
  for i, ch in path: sa.sun_path[i + off] = ch
  let len = if abstract: sizeof(sa.sun_family) + off + path.len else: sizeof(Sockaddr_un)
  doAssert bindSocket(result, cast[ptr SockAddr](addr sa), Socklen(len)) == 0
  doAssert listen(result, 4) == 0

proc privateCfg(stateDir: string, env: Table[string, string],
                token: CancelToken): LinuxPrivateConfig =
  LinuxPrivateConfig(env: env, token: token, stateDir: stateDir, selfExe: "/nonexistent",
    host: LinuxHostConfig(env: env, token: token, stateDir: stateDir,
      atspi: LinuxAtspiConfig(env: env, token: token),
      capture: proc (): CaptureBackend = raise unavailable("x", "missing-tool", "none")),
    displays: proc (env: Table[string, string], capture: string): seq[Display] =
      raise newException(IOError, "no displays here"))

suite "the environment contract (C6)":
  test "test_compose_session_env_unsets_then_sets":
    let caller = table({"PATH": "/bin", "DISPLAY": ":0", "GDK_BACKEND": "x11",
                        "WAYLAND_DISPLAY": "wayland-0", "HOME": "/home/u"})
    let env = ordered({"WAYLAND_DISPLAY": "wayland-7", "XDG_RUNTIME_DIR": "/tmp/guienv-x"})
    let c = composeSessionEnv(caller, env, ["DISPLAY", "GDK_BACKEND", "WAYLAND_DISPLAY"])
    check c["PATH"] == "/bin" and c["HOME"] == "/home/u"
    check "DISPLAY" notin c and "GDK_BACKEND" notin c
    # The session's value wins, even for a variable also listed in envUnset.
    check c["WAYLAND_DISPLAY"] == "wayland-7"
    check c["XDG_RUNTIME_DIR"] == "/tmp/guienv-x"
    check caller["DISPLAY"] == ":0"   # the caller's own table is untouched

  test "test_env_unset_never_lists_what_env_sets":
    let env = ordered({"DISPLAY": ":5", "XAUTHORITY": "/tmp/gaxv-a/Xauthority",
                       "DBUS_SESSION_BUS_ADDRESS": "unix:path=/tmp/gaxv-a/bus"})
    let u = envUnsetFor(["EXTRA_VAR", "DISPLAY"], env)
    check "DISPLAY" notin u and "XAUTHORITY" notin u and "DBUS_SESSION_BUS_ADDRESS" notin u
    for k in ["WAYLAND_DISPLAY", "NO_AT_BRIDGE", "GTK_A11Y", "GDK_BACKEND", "QT_QPA_PLATFORM",
              "AT_SPI_BUS_ADDRESS", "EXTRA_VAR"]:
      check k in u
    check u.deduplicate == u

  test "test_server_tables_name_their_session_backends":
    let sway = linuxSwayServer()
    let gnome = linuxGnomeServer()
    let xvfb = linuxXvfbServer()
    check sway.name == "linux-sway" and sway.backends.capture == "linux-wlr" and
          sway.backends.input == "linux-wlr-virtual" and sway.supportsVnc and sway.supportsScale
    check gnome.name == "linux-gnome" and gnome.backends.capture == "linux-gnome" and
          gnome.backends.input == "linux-mutter" and not gnome.supportsVnc
    check xvfb.name == "linux-xvfb" and xvfb.backends.capture == "linux-x11" and
          xvfb.backends.input == "linux-xtest" and xvfb.supportsVnc and not xvfb.supportsScale
    for s in [sway, gnome, xvfb]:
      check s.backends.tree == "linux-atspi"
      check s.name in linuxPrivateBackendNames

suite "readiness, ids and tags (C10)":
  test "test_readiness_bound_is_10s_or_the_deadline_less_250ms":
    check readinessBound(high(int)) == 10_000
    check readinessBound(60_000) == 10_000
    check readinessBound(1500) == 1250
    check readinessBound(250) == 0
    check readinessBound(0) == 0

  test "test_generated_ids_skip_taken_names":
    let taken = @["sway-1", "sway-2", "sway-4"]
    check generatedId("sway", proc (x: string): bool = x in taken) == "sway-3"
    check generatedId("xvfb", proc (x: string): bool = false) == "xvfb-1"

  test "test_session_tags_are_128_random_bits":
    let a = newTag()
    let b = newTag()
    check a.len == 32 and b.len == 32 and a != b
    check a.allCharsInSet(HexDigits)

suite "the VNC endpoint check":
  const header = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when " &
                 "retrnsmt   uid  timeout inode\n"
  test "test_proc_net_tcp_rows_parse":
    let rows = parseProcNetTcp(header &
      "   0: 0100007F:1759 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000 " &
      "       0 158133108 1 0000000000000000 100 0 0 10 0\n" &
      "   1: 0100007F:E9F2 0100007F:1759 06 00000000:00000000 03:0000176F 00000000     0 " &
      "       0 0 3 0000000000000000\n" &
      "   2: garbage\n")
    check rows.len == 2
    check rows[0].localAddr == "0100007F" and rows[0].localPort == 0x1759 and
          rows[0].state == 0x0A and rows[0].inode == "158133108"
    check listenersOn(rows, 0x1759).len == 1     # the TIME_WAIT row is no listener

  test "test_loopback_only_refuses_wildcards_and_ipv6":
    let lo = parseProcNetTcp(header &
      "   0: 0100007F:170C 00000000:0000 0A 00000000:00000000 00:00000000 00000000 1000 0 11 1\n")
    let wild = parseProcNetTcp(header &
      "   0: 00000000:170C 00000000:0000 0A 00000000:00000000 00:00000000 00000000 1000 0 12 1\n")
    let v6 = parseProcNetTcp(header &
      "   0: 00000000000000000000000000000000:170C 00000000000000000000000000000000:0000 0A " &
      "00000000:00000000 00:00000000 00000000 1000 0 13 1\n")
    check isLoopbackOnly(lo, @[], 0x170C)
    check not isLoopbackOnly(wild, @[], 0x170C)
    check not isLoopbackOnly(lo & wild, @[], 0x170C)
    check not isLoopbackOnly(lo, v6, 0x170C)
    check not isLoopbackOnly(@[], @[], 0x170C)   # nothing listens: not "loopback only"
    check isLoopbackOnly(lo, v6, 0x170D) == false

  test "test_rfb_banner":
    check isRfbBanner("RFB 003.008\n")
    check isRfbBanner("RFB 003.003\n")
    check not isRfbBanner("RFB 003.008")
    check not isRfbBanner("SSH-2.0-x\r\n")
    check not isRfbBanner("RFB 3.8    \n")

suite "Xvfb's pieces":
  test "test_xauth_entry_is_the_xau_format":
    let cookie = "0123456789abcdef"
    let e = xauthEntry("12", cookie)
    # family FamilyWild (0xFFFF), empty address, number "12", the name, the data.
    check e == "\xFF\xFF" & "\x00\x00" & "\x00\x02" & "12" & "\x00\x12" &
               "MIT-MAGIC-COOKIE-1" & "\x00\x10" & cookie

  test "test_displayfd_reads_a_whole_line_only":
    check parseDisplayFd("") == -1
    check parseDisplayFd("7") == -1
    check parseDisplayFd("7\n") == 7
    check parseDisplayFd("142\n") == 142
    check parseDisplayFd("x\n") == -1

when defined(linux):
  # Real sockets, /proc and the dev shell's tools: Linux only. The suites above
  # are pure and run on every host.
  suite "the attach check":
    test "test_display_names_and_socket_paths":
      check x11DisplayNumber(":0") == 0
      check x11DisplayNumber(":12.1") == 12
      check x11DisplayNumber("unix:3") == 3
      check x11DisplayNumber("remote.example:0") == -1
      check x11DisplayNumber(":") == -1
      check waylandSocketPath(table({"WAYLAND_DISPLAY": "wayland-1",
                                     "XDG_RUNTIME_DIR": "/tmp/r"})) == "/tmp/r/wayland-1"
      check waylandSocketPath(table({"WAYLAND_DISPLAY": "/tmp/s/wl"})) == "/tmp/s/wl"
      check waylandSocketPath(table({"WAYLAND_DISPLAY": "wayland-1"})) == ""

    test "test_display_answers_only_where_something_listens":
      let dir = createTempDir("gs10-sock-", "", "/tmp")
      defer: removeDir(dir)
      let fd = listenUnix(dir / "wayland-9")
      defer: discard posix.close(fd)
      check displayAnswers(table({"WAYLAND_DISPLAY": "wayland-9", "XDG_RUNTIME_DIR": dir})).ok
      let missing = displayAnswers(table({"WAYLAND_DISPLAY": "wayland-8", "XDG_RUNTIME_DIR": dir}))
      check not missing.ok and "wayland-8" in missing.why
      let none = displayAnswers(initTable[string, string]())
      check not none.ok and "neither WAYLAND_DISPLAY nor DISPLAY" in none.why
      # A remote X display cannot be checked from here.
      check displayAnswers(table({"DISPLAY": "remote.example:0"})).ok
      # An abstract socket answers too (the X server's twin of its path socket).
      let name = dir / "abstract-x"
      let afd = listenUnix(name, abstract = true)
      defer: discard posix.close(afd)
      check unixSocketAnswers(name, abstract = true)
      check not unixSocketAnswers(name)

    test "test_linux_host_without_a_display_is_not_running":
      let token = newCancelToken()
      defer: token.free()
      let env = table({"PATH": "/bin"})
      let h = newLinuxHostSession(LinuxHostConfig(env: env, token: token,
        atspi: LinuxAtspiConfig(env: env, token: token),
        capture: proc (): CaptureBackend = raise unavailable("x", "missing-tool", "none")))
      let s = h.info("host")
      check s.state == ssError and s.stateReason == some("no-display-server")
      for verb in ["apps", "launch", "quit"]:
        try:
          case verb
          of "apps": discard h.apps("host")
          of "launch": discard h.launch("host", LaunchSpec(kind: lkArgv, argv: @["true"]))
          else: discard h.quit("host", 1, false)
          check false
        except ContractError as e:
          check e.kind == ekBackendUnavailable and e.reason == "session-not-running"
          check e.details["feature"].kind == JNull
      # headless sessions are another backend's
      try:
        discard h.start(SessionSpec(kind: skHeadless, displays: 1))
        check false
      except BackendUnavailableError as e:
        check e.reason == "unsupported-option" and "linux-sway" in e.remedy

  suite "records, processes and clean-up":
    test "test_reconcile_against_a_live_and_a_dead_host":
      let dir = createTempDir("gs10-rec-", "", "/tmp")
      defer: removeDir(dir)
      let fd = listenUnix(dir / "wayland-3")
      defer: discard posix.close(fd)
      let me = getCurrentProcessId()
      var s = Session(id: "r1", kind: skHeadless, backend: "linux-sway", platform: spLinux,
                      state: ssRunning, hostPid: some(me),
                      env: ordered({"WAYLAND_DISPLAY": "wayland-3", "XDG_RUNTIME_DIR": dir}))
      let live = %*{"hostStartTime": processStartTime(me)}
      check reconcilePrivate(s, live).state == ssRunning
      # The same pid with another start time is a recycled pid: not the host.
      check reconcilePrivate(s, %*{"hostStartTime": "1"}).stateReason == some("host-exited")
      let p = startProcess("/bin/sh", args = ["-c", "exec sleep 0.3"])
      let pid = p.processID
      let st = processStartTime(pid)
      discard p.waitForExit()
      p.close()
      s.hostPid = some(pid)
      check reconcilePrivate(s, %*{"hostStartTime": st}).stateReason == some("host-exited")
      s.hostPid = some(me)
      s.env["WAYLAND_DISPLAY"] = "wayland-4"
      let gone = reconcilePrivate(s, live)
      check gone.state == ssError and gone.stateReason == some("compositor-not-answering")
      s.state = ssStopped
      check reconcilePrivate(s, live).state == ssStopped

    test "test_runtime_dir_removal_is_guarded":
      let ours = createTempDir("gaxv-", "", "/tmp")
      let foreign = createTempDir("gs10-notours-", "", "/tmp")
      defer: removeDir(foreign)
      writeFile(foreign / "keep", "x")
      removeRuntimeDir(foreign)
      check fileExists(foreign / "keep")
      removeRuntimeDir("relative/gaxv-x")
      removeRuntimeDir("")
      # A path that names the foreign directory through a session-looking
      # one (`..`), and a session-named symbolic link to it: neither is
      # followed.
      let decoy = createTempDir("gaxv-", "", "/tmp")
      defer: removeDir(decoy)
      removeRuntimeDir(decoy & "/../" & foreign.extractFilename)
      removeRuntimeDir(decoy & "/../" & decoy.extractFilename)   # itself, spelt with ..
      check dirExists(decoy)
      let link = "/tmp/gaxv-link-" & $getCurrentProcessId()
      createSymlink(foreign, link)
      defer: removeFile(link)
      removeRuntimeDir(link)
      check fileExists(foreign / "keep") and symlinkExists(link)
      writeFile(ours / "f", "x")
      removeRuntimeDir(ours)
      check not dirExists(ours)

    test "test_stop_removes_the_tag_named_runtime_dir_no_process_names":
      # A host killed before it reported its runtime directory, whose
      # processes are gone too (or never named it, as Xvfb's environment
      # does not): session-stop still finds the directory by the tag.
      let tag = newTag()
      check sessionRuntimeDir("linux-xvfb", tag) == "/tmp/gaxv-" & tag[0 ..< 16]
      check sessionRuntimeDir("linux-sway", tag) == "/tmp/guienv-" & tag[0 ..< 16]
      check sessionRuntimeDir("linux-gnome", tag) == "/tmp/guienv-" & tag[0 ..< 16]
      check sessionRuntimeDir("linux-xvfb", "x") == ""
      check sessionRuntimeDir("linux-xvfb", "../../../../home/user/xxxxxxxxxxxx") == ""
      let st = createTempDir("gs10-st-", "", "/tmp")
      defer: removeDir(st)
      let rt = sessionRuntimeDir("linux-xvfb", tag)
      createDir(rt)
      defer: removeDir(rt)
      writeFile(rt / "Xauthority", "x")
      ensurePrivateDir(st / "sessions")
      let s = Session(id: "lost", name: some("lost"), kind: skHeadless, backend: "linux-xvfb",
                      platform: spLinux, state: ssStarting, hostPid: some(1),
                      createdAt: "2026-10-23T00:00:00.000Z")
      writeSessionRecord(st, s, %*{"backend": "linux-xvfb", "tag": tag, "hostStartTime": "1",
                                   "runtimeDir": ""})
      check taggedProcesses(tag).len == 0
      check stopPrivate(st, "lost", false).state == ssStopped
      check not dirExists(rt)
      check not fileExists(sessionRecordPath(st, "lost"))

    test "test_tag_sweep_ends_only_the_tagged":
      let tag = newTag()
      var tagged = newStringTable(modeCaseSensitive)
      for k, v in envPairs(): tagged[k] = v
      tagged[sessionTagVar] = tag
      let a = startProcess("/bin/sh", args = ["-c", "exec sleep 60"], env = tagged)
      let b = startProcess("/bin/sh", args = ["-c", "exec sleep 60"])
      defer:
        for p in [a, b]:
          if p.running: p.kill()
          discard p.waitForExit()
          p.close()
      # The tagged process is found once its environment is its own (after
      # exec; /proc/<pid>/environ is readable from then on).
      var found: seq[int]
      for _ in 1 .. 200:
        found = taggedProcesses(tag).mapIt(it.pid)
        if a.processID in found: break
        sleep(10)
      check found == @[a.processID]
      sweepTagged(tag, graceMs = 1000)
      discard a.waitForExit(2000)
      check not a.running
      check b.running
      check taggedProcesses(tag).len == 0

  suite "the private backends' refusals":
    test "test_unsupported_kinds_and_options_are_exit_4":
      let st = createTempDir("gs10-st-", "", "/tmp")
      defer: removeDir(st)
      let token = newCancelToken()
      defer: token.free()
      var env = initTable[string, string]()
      for k, v in envPairs(): env[k] = v
      let cfg = privateCfg(st, env, token)
      let gnome = newLinuxPrivateSession(cfg, linuxGnomeServer())
      let xvfb = newLinuxPrivateSession(cfg, linuxXvfbServer())
      for (b, spec) in [(gnome, SessionSpec(kind: skVirtualDisplay, displays: 1)),
                        (xvfb, SessionSpec(kind: skHeadless, displays: 2)),
                        (xvfb, SessionSpec(kind: skHeadless, displays: 1, scale: some(2.0))),
                        (gnome, SessionSpec(kind: skHeadless, displays: 1, vnc: true))]:
        try:
          discard b.start(spec)
          check false
        except BackendUnavailableError as e:
          check e.reason == "unsupported-option"
      check listSessionIds(st).len == 0
      expect ContractError:
        discard xvfb.start(SessionSpec(kind: skHost, displays: 1))
      var fs = initTable[string, Feature]()
      for f in gnome.features(false): fs[f.feature] = f
      check fs["session-headless"].state == fsAvailable
      check fs["session-vnc"].state == fsUnavailable and
            fs["session-vnc"].reason == some("unsupported-option")
      check fs["session-isolated"].state == fsUnavailable

    test "test_missing_tool_is_exit_4_and_records_nothing":
      let st = createTempDir("gs10-st-", "", "/tmp")
      defer: removeDir(st)
      let token = newCancelToken()
      defer: token.free()
      let env = table({"PATH": "/nonexistent-gs10", "HOME": st})
      for server in [linuxSwayServer(), linuxGnomeServer(), linuxXvfbServer()]:
        let b = newLinuxPrivateSession(privateCfg(st, env, token), server)
        try:
          discard b.start(SessionSpec(kind: skHeadless, displays: 1))
          check false
        except BackendUnavailableError as e:
          check e.reason == "missing-tool"
          check e.remedy.len > 0
        var probed = initTable[string, Feature]()
        for f in b.features(true): probed[f.feature] = f
        check probed["session-headless"].state == fsUnavailable and
              probed["session-headless"].reason == some("missing-tool")
      check listSessionIds(st).len == 0

    test "test_a_name_held_by_a_session_in_error_is_in_use":
      # Needs the dev shell's tools (sway, dbus-daemon, the portals, the AT-SPI
      # launcher), so the preflight passes and the name check is reached; it
      # refuses before anything is started.
      let st = createTempDir("gs10-st-", "", "/tmp")
      defer: removeDir(st)
      let token = newCancelToken()
      defer: token.free()
      var env = initTable[string, string]()
      for k, v in envPairs(): env[k] = v
      ensurePrivateDir(st / "sessions")
      let dead = Session(id: "busy", name: some("busy"), kind: skHeadless, backend: "linux-sway",
                         platform: spLinux, state: ssRunning, hostPid: some(1),
                         createdAt: "2026-10-23T00:00:00.000Z")
      writeSessionRecord(st, dead, %*{"backend": "linux-sway", "tag": "x",
                                      "hostStartTime": "1"})
      let before = readFile(sessionRecordPath(st, "busy"))
      let b = newLinuxPrivateSession(privateCfg(st, env, token), linuxSwayServer())
      try:
        discard b.start(SessionSpec(kind: skHeadless, displays: 1, name: some("busy")))
        check false
      except ContractError as e:
        check e.kind == ekBadArgs and e.reason == "name-in-use"
        check e.details["name"].getStr == "busy" and e.details["state"].getStr == "error"
      check readFile(sessionRecordPath(st, "busy")) == before
      check b.info("busy").state == ssError
      check b.list().anyIt(it.id == "busy" and it.stateReason == some("host-exited"))
      # Stopping it works although its host is long gone, and frees the name.
      check b.stop("busy", false).state == ssStopped
      check not fileExists(sessionRecordPath(st, "busy"))
