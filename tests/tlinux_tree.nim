## tlinux_tree — the parts of the Linux accessibility-tree backend
## (`linux-atspi`) and its D-Bus client that need no display server, so they
## run in the default suite (spec §9.1):
##
## * the D-Bus wire format (`dbus_wire`): every type of the type system
##   marshalled and read back, a big-endian message, malformed messages and
##   signatures refused, addresses parsed with their escapes;
## * on Linux, the client against a REAL `dbus-daemon` started here on a
##   private socket (path and abstract): authentication, Hello, pipelined
##   calls, error replies, the no-auto-start flag, a call nobody answers
##   (its deadline, and a checkpoint that aborts the wait);
## * the pure mapping of AT-SPI roles and states onto the contract's
##   vocabulary, and placing a frame's WINDOW coordinates on the desktop
##   (`frameOrigin`, `matchWindow`, `placeExtents`) in the shapes GTK 3 and
##   GTK 4 report (measured; see the module doc of `linux_atspi`);
## * the backend and the `linux-host` session backend in a session without
##   an AT-SPI bus: exit 6 / `atspi-disabled`, never an empty tree.
##
## Stand-ins: none. The live suite (`tests/live/ttree_linux.nim`) runs the
## backend against real GTK applications on real AT-SPI buses.

import std/[options, os, osproc, sequtils, streams, strutils, tables, times, unittest]

import ../src/gui_assert/core/[geometry, desktop_types, interfaces, tree_types]
import ../src/gui_assert/cancel
import ../src/gui_assert/cli/registry
import ../src/gui_assert/backends/tree/dbus_wire

when defined(linux):
  import ../src/gui_assert/backends/tree/linux_atspi
  import ../src/gui_assert/backends/session/linux_host

proc roundTrip(args: seq[DValue]): Message =
  decodeMessage(encodeCall(7, "org.example.Dest", "/org/example/obj", "org.example.Iface",
                           "Method", args))

suite "the D-Bus wire format":
  test "test_dbus_values_marshal_and_read_back":
    let dict = darray("{sv}", @[
      DValue(sig: "{sv}", kind: dkDictEntry, items: @[dstr("Name"), dvariant(dstr("Submit"))]),
      DValue(sig: "{sv}", kind: dkDictEntry, items: @[dstr("ChildCount"), dvariant(dint32(3))])])
    let args = @[dbyte(250), dbool(true), dbool(false),
                 DValue(sig: "n", kind: dkInt16, num: -12),
                 DValue(sig: "q", kind: dkUint16, num: 65000, unum: 65000),
                 dint32(-2147483648), duint32(4294967295'u32),
                 DValue(sig: "x", kind: dkInt64, num: -9_000_000_000),
                 DValue(sig: "t", kind: dkUint64, num: 9_000_000_000, unum: 9_000_000_000'u64),
                 ddouble(-1.5), dstr("héllo"), dpath("/org/a11y/atspi/accessible/root"),
                 dsig("a(so)"), dvariant(dstruct(dint32(1), dstr("x"))),
                 darray("(so)", @[dstruct(dstr(":1.4"), dpath("/a")),
                                  dstruct(dstr(":1.5"), dpath("/b"))]),
                 dict, darray("y", @[]), darray("s", @[dstr(""), dstr("z")]),
                 dstruct(dint32(1), dint32(2), dint32(3), dint32(4))]
    let m = roundTrip(args)
    check m.kind == mtMethodCall
    check m.serial == 7
    check m.path == "/org/example/obj"
    check m.iface == "org.example.Iface"
    check m.member == "Method"
    check m.destination == "org.example.Dest"
    var sig = ""
    for a in args: sig.add a.sig
    check m.signature == sig
    check m.body.len == args.len
    check m.body[0].num == 250
    check m.body[1].num == 1 and m.body[2].num == 0
    check m.body[3].num == -12 and m.body[4].num == 65000
    check m.body[5].num == -2147483648 and m.body[6].num == 4294967295
    check m.body[7].num == -9_000_000_000 and m.body[8].num == 9_000_000_000
    check m.body[9].dbl == -1.5
    check m.body[10].str == "héllo" and m.body[11].str == "/org/a11y/atspi/accessible/root"
    check m.body[12].str == "a(so)"
    check m.body[13].inner[0].items[1].str == "x"
    check m.body[14].items.len == 2 and m.body[14].items[1].items[0].str == ":1.5"
    check m.body[15].items[0].items[1].unwrap.str == "Submit"
    check m.body[15].items[1].items[1].asFloat == 3.0
    check m.body[16].items.len == 0
    check m.body[17].items[0].str == "" and m.body[17].items[1].str == "z"
    check m.body[18].items[3].num == 4

  test "test_dbus_big_endian_reply_is_read":
    # A method return in big-endian order: serial 9, reply to 5, body "u".
    var b = "B" & char(2) & char(0) & char(1)
    b.add "\x00\x00\x00\x04"                  # body length
    b.add "\x00\x00\x00\x09"                  # serial
    # header fields: a(yv) = [(5, v u 5), (8, v g "u")]
    var fields = ""
    fields.add char(5) & char(1) & "u" & char(0) & "\x00\x00\x00\x05"
    fields.add char(8) & char(1) & "g" & char(0) & char(1) & "u" & char(0)
    b.add "\x00\x00\x00" & char(fields.len)
    b.add fields
    while b.len mod 8 != 0: b.add '\0'
    b.add "\x01\x02\x03\x04"
    let m = decodeMessage(b)
    check m.kind == mtMethodReturn
    check m.serial == 9 and m.replySerial == 5
    check m.body.len == 1 and m.body[0].num == 0x01020304

  test "test_dbus_malformed_input_is_refused":
    let good = encodeCall(1, "d", "/p", "i.f", "M", [dstr("abc"), dbool(true)])
    expect DbusError: discard decodeMessage(good[0 ..< good.len - 1])
    expect DbusError: discard decodeMessage("x" & good[1 .. ^1])
    var badBool = good
    badBool[^4] = char(2)                     # a boolean of 2
    expect DbusError: discard decodeMessage(badBool)
    for s in ["(", "a", "{ss}", "a{vs}", "()", "a{sss}", "z"]:
      expect DbusError: discard splitSignature(s)
    check splitSignature("ia{sv}(so)as") == @["i", "a{sv}", "(so)", "as"]
    expect DbusError: discard encodeCall(1, "d", "/p", "", "M", [dstr("a\0b")])

  # A method return, little-endian, built byte by byte so that each field can
  # be broken on purpose: reply serial `replySerial` (none when 0),
  # signature `sig` (none when empty), extra raw header fields `extra`
  # (each already 8-aligned), body `body`.
  proc u32le(v: uint32): string =
    for i in 0 .. 3: result.add char((v shr (8 * i)) and 0xff)
  proc rawReturn(body, sig: string, serial = 9'u32, replySerial = 5'u32,
                 extra = "", kind = 2): string =
    var fields = ""
    if replySerial != 0:
      fields.add char(5) & char(1) & "u" & char(0) & u32le(replySerial)
    if sig.len > 0:
      while fields.len mod 8 != 0: fields.add '\0'
      fields.add char(8) & char(1) & "g" & char(0) & char(sig.len) & sig & char(0)
    if extra.len > 0:
      while fields.len mod 8 != 0: fields.add '\0'
      fields.add extra
    result = "l" & char(kind) & char(0) & char(1)
    result.add u32le(uint32(body.len))
    result.add u32le(serial)
    result.add u32le(uint32(fields.len))
    result.add fields
    while result.len mod 8 != 0: result.add '\0'
    result.add body
  proc str(s: string): string = u32le(uint32(s.len)) & s & char(0)

  test "test_dbus_hand_built_reply_is_read":
    # The builder itself is right: a well-formed reply decodes (the
    # positive control for the malformed table below).
    let m = decodeMessage(rawReturn(str("ok"), "s"))
    check m.kind == mtMethodReturn and m.replySerial == 5
    check m.body.len == 1 and m.body[0].str == "ok"
    check decodeMessage(rawReturn("", "")).body.len == 0

  test "test_dbus_malformed_messages_table_is_refused":
    # Every row breaks one rule of the D-Bus specification ("Marshaling
    # (Wire Format)", "Message Format", "Valid Names"); each must be refused
    # with DbusError, never accepted, crash or hang.
    var deep = ""
    for i in 0 ..< 70: deep.add char(1) & "v" & char(0)
    deep.add char(1) & "y" & char(0) & char(7)
    let rows = @[
      ("invalid UTF-8 byte", rawReturn(str("a\xffb"), "s")),
      ("overlong UTF-8 NUL", rawReturn(str("a\xc0\x80b"), "s")),
      ("UTF-8 surrogate", rawReturn(str("\xed\xa0\x80"), "s")),
      ("UTF-8 beyond U+10FFFF", rawReturn(str("\xf4\x90\x80\x80"), "s")),
      ("truncated UTF-8 sequence", rawReturn(str("ab\xe2\x82"), "s")),
      ("NUL inside a string", rawReturn(str("a\0b"), "s")),
      ("string without its NUL", rawReturn(u32le(2) & "abX", "s")),
      ("string longer than the body", rawReturn(u32le(1000) & "ab" & char(0), "s")),
      ("string length near 2^32", rawReturn(u32le(0xffff_fff0'u32) & "ab" & char(0), "s")),
      ("object path with a dot", rawReturn(str("/a.b"), "o")),
      ("object path with //", rawReturn(str("/a//b"), "o")),
      ("object path with a trailing /", rawReturn(str("/a/"), "o")),
      ("relative object path", rawReturn(str("a/b"), "o")),
      ("signature value invalid", rawReturn(char(2) & "az" & char(0), "g")),
      ("signature value without its NUL", rawReturn(char(1) & "iX", "g")),
      ("variant of two types", rawReturn(char(2) & "ii" & char(0) & u32le(1) & u32le(2), "v")),
      ("variant signature without its NUL", rawReturn(char(1) & "yX" & char(7), "v")),
      ("variants nested 71 deep", rawReturn(deep, "v")),
      ("array longer than the body", rawReturn(u32le(64) & u32le(1), "au")),
      ("array beyond 2^26 bytes", rawReturn(u32le(67_108_865) & u32le(1), "au")),
      ("array element straddles its length", rawReturn(u32le(6) & u32le(1) & u32le(2), "au")),
      ("non-zero padding", rawReturn(char(1) & "\x01\0\0" & u32le(5), "yu")),
      ("boolean of 2", rawReturn(u32le(2), "b")),
      ("Unix fd in the body", rawReturn(u32le(0), "h")),
      ("UNIX_FDS header field", rawReturn("", "", extra = char(9) & char(1) & "u" & char(0) & u32le(1))),
      ("reply serial of type s", rawReturn("", "", replySerial = 0,
         extra = char(5) & char(1) & "s" & char(0) & str("5"))),
      ("method return without a reply serial", rawReturn("", "", replySerial = 0)),
      ("message serial 0", rawReturn("", "", serial = 0)),
      ("unknown message type", rawReturn("", "", kind = 7)),
      ("body without a signature", rawReturn(u32le(1), "")),
      ("body longer than its signature", rawReturn(u32le(1) & u32le(2), "u")),
      ("body shorter than its signature", rawReturn(u32le(1), "uu")),
      ("signature nested too deeply", rawReturn(u32le(0), repeat('a', 70) & "y")),
      ("dict entry outside an array", rawReturn(str("k") & str("v"), "{ss}")),
    ]
    for (what, msg) in rows:
      var refused = false
      try: discard decodeMessage(msg)
      except DbusError: refused = true
      if not refused: checkpoint("accepted: " & what)
      check refused
    # The byte-order mark and the protocol version of the fixed header.
    var bom = rawReturn("", "")
    bom[0] = 'X'
    expect DbusError: discard decodeMessage(bom)
    var ver = rawReturn("", "")
    ver[3] = char(2)
    expect DbusError: discard decodeMessage(ver)
    var huge = rawReturn("", "")
    for i in 4 .. 7: huge[i] = '\xff'          # a body of 2^32-1 bytes
    expect DbusError: discard messageLength(huge[0 ..< 16])

  test "test_dbus_value_budget_bounds_a_decoded_message":
    # A legal 1 MiB byte array would be a million heap objects; one value
    # beyond maxValues is refused, its header still readable alone.
    let flood = rawReturn(u32le(uint32(maxValues)) & repeat('\x01', maxValues), "ay")
    expect DbusError: discard decodeMessage(flood)
    check decodeMessage(flood, withBody = false).replySerial == 5
    let fits = rawReturn(u32le(1000) & repeat('\x01', 1000), "ay")
    check decodeMessage(fits).body[0].elems.len == 1000

  test "test_dbus_mutated_messages_never_crash":
    # Fuzz: every truncation and, with a fixed seed, 20000 random byte
    # mutations of a message using every container type. Each must decode
    # or raise DbusError; any other exception or defect fails the test.
    let dict = darray("{sv}", @[
      DValue(sig: "{sv}", kind: dkDictEntry, items: @[dstr("Name"), dvariant(dstr("Submit"))])])
    let good = encodeCall(3, "org.a11y.atspi.Registry", "/org/a11y/atspi/accessible/root",
                          "org.a11y.atspi.Accessible", "GetChildren",
                          [darray("(so)", @[dstruct(dstr(":1.4"), dpath("/a"))]), dict,
                           dvariant(dstruct(dint32(1), ddouble(2.5))), dsig("a{sv}"),
                           dbool(true), DValue(sig: "x", kind: dkInt64, num: -5)])
    check decodeMessage(good).body.len == 6
    var bad = 0
    proc attempt(m: string) =
      try: discard decodeMessage(m)
      except DbusError: discard
      except CatchableError, Defect:
        inc bad
        checkpoint("unexpected " & $getCurrentException().name & ": " & getCurrentExceptionMsg())
    for n in 0 ..< good.len: attempt(good[0 ..< n])
    var seed = 0x2545F491'u32
    proc next(): uint32 =
      seed = seed xor (seed shl 13)
      seed = seed xor (seed shr 17)
      seed = seed xor (seed shl 5)
      seed
    for i in 0 ..< 20000:
      var m = good
      for k in 0 .. int(next() mod 3):
        m[int(next() mod uint32(m.len))] = char(next() and 0xff)
      attempt(m)
    check bad == 0

  test "test_dbus_invalid_strings_are_not_sent":
    expect DbusError: discard encodeCall(1, "d", "/p", "", "M", [dstr("a\xffb")])
    expect DbusError: discard encodeCall(1, "d", "/p", "", "M", [dpath("not/a/path")])
    expect DbusError: discard encodeCall(1, "d", "/p", "", "M", [dsig("z")])
    check validUtf8("héllo ✓ 𝄞") and not validUtf8("\xc3") and not validUtf8("a\0")
    check validObjectPath("/") and validObjectPath("/org/a11y/atspi/accessible/root")
    # A peer answering a number where an array is expected is an error,
    # never a field access the value does not have.
    expect DbusError: discard dint32(1).elems
    check dvariant(darray("i", @[dint32(4)])).elems.len == 1

  test "test_dbus_addresses_are_parsed":
    let a = parseAddresses("tcp:host=x,port=1;unix:path=/run/user/1/at%2dspi/bus,guid=ab;" &
                           "unix:abstract=/tmp/dbus-Q")
    check a.len == 2
    check a[0].kind == akPath and a[0].name == "/run/user/1/at-spi/bus"
    check a[1].kind == akAbstract and a[1].name == "/tmp/dbus-Q"
    expect DbusError: discard parseAddresses("tcp:host=localhost,port=4")
    expect DbusError: discard parseAddresses("unix:path=/x%zz")
    expect DbusError: discard parseAddresses("nonsense")

when defined(linux):
  type Daemon = object
    p: Process
    dir: string

  proc startDaemon(address: string, dir: string): Daemon =
    let exe = findExe("dbus-daemon")
    doAssert exe.len > 0, "GS7-LINUX BLOCKED: dbus-daemon is not on the PATH (run inside `nix develop`)"
    result.dir = dir
    result.p = startProcess(exe, args = ["--session", "--nofork", "--print-address",
                                         "--address=" & address], options = {})
    var line = ""
    doAssert result.p.outputStream.readLine(line), "dbus-daemon did not start"

  proc stop(d: var Daemon) =
    if d.p != nil:
      d.p.terminate()
      discard d.p.waitForExit(3000)
      d.p.close()
      d.p = nil

  suite "the D-Bus client against a real dbus-daemon":
    let dir = getTempDir() / ("gadbus-" & $getCurrentProcessId())
    createDir(dir)
    var d = startDaemon("unix:path=" & dir / "bus", dir)
    let address = "unix:path=" & dir / "bus"

    test "test_dbus_client_authenticates_and_calls":
      let c = connectBus(address)
      check c.uniqueName.startsWith(":")
      let id = c.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                      "GetId")
      check id.len == 1 and id[0].str.len == 32
      let names = c.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                         "ListNames")
      var found = false
      for n in names[0].items:
        if n.str == c.uniqueName: found = true
      check found
      # Pipelined: fifty calls in flight, answered in any order, each to its
      # own serial.
      var serials: seq[uint32]
      for i in 0 ..< 50:
        serials.add c.send("org.freedesktop.DBus", "/org/freedesktop/DBus",
                           "org.freedesktop.DBus", "NameHasOwner", [dstr(c.uniqueName)])
      for i in countdown(49, 0):
        check c.reply(serials[i])[0].num == 1
      c.close()

    test "test_dbus_client_reports_error_replies_and_no_auto_start":
      let c = connectBus(address)
      try:
        discard c.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                       "NoSuchMethod")
        check false
      except DbusCallError as e:
        check e.errorName == "org.freedesktop.DBus.Error.UnknownMethod"
      try:
        discard c.call("org.a11y.Bus", "/org/a11y/bus", "org.a11y.Bus", "GetAddress",
                       flags = flagNoAutoStart)
        check false
      except DbusCallError as e:
        # dbus-daemon answers a name nobody owns, asked not to start it, so.
        check e.errorName == "org.freedesktop.DBus.Error.NameHasNoOwner"
      c.close()

    test "test_dbus_client_call_nobody_answers_times_out_or_is_cancelled":
      # A second connection owns a name and never answers calls to it.
      let silent = connectBus(address)
      discard silent.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                          "RequestName", [dstr("org.example.Silent"), duint32(4)])
      let c = connectBus(address)
      let t0 = epochTime()
      expect DbusTimeoutError:
        discard c.call("org.example.Silent", "/x", "org.example.X", "Hang", timeoutMs = 300)
      check epochTime() - t0 < 2.0
      # A checkpoint that raises ends the wait within about 50 ms.
      let token = newCancelToken()
      token.setDeadline(150)
      c.checkpoint = proc () = token.checkpoint()
      let t1 = epochTime()
      expect CatchableError:
        discard c.call("org.example.Silent", "/x", "org.example.X", "Hang", timeoutMs = 5000)
      check epochTime() - t1 < 1.0
      token.free()
      c.close()
      silent.close()

    test "test_dbus_client_drops_unsolicited_messages_undecoded":
      # Another client of the bus (any application) floods this one with a
      # call whose body would exceed the value budget. It is skipped from its
      # header, so this client's own calls still succeed on the connection.
      let c = connectBus(address)
      let other = connectBus(address)
      discard other.send(c.uniqueName, "/x", "org.example.X", "Flood",
                         [darray("y", newSeq[DValue](maxValues + 10).mapIt(dbyte(1)))],
                         flags = flagNoReplyExpected)
      # Make sure the flood was delivered before this client's next call.
      discard other.call("org.freedesktop.DBus", "/org/freedesktop/DBus",
                         "org.freedesktop.DBus", "GetId")
      let id = c.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                      "GetId")
      check id.len == 1 and id[0].str.len == 32
      # A reply to a serial never sent is refused at once, not awaited.
      expect DbusError: discard c.reply(99_999, timeoutMs = 100)
      other.close()
      c.close()

    test "test_dbus_client_connects_to_abstract_sockets":
      var ab = startDaemon("unix:abstract=" & dir & "/abstract", dir)
      try:
        let c = connectBus("unix:abstract=" & dir & "/abstract")
        check c.uniqueName.startsWith(":")
        c.close()
      finally:
        # Stopped even when the connection fails, so no daemon outlives a
        # failing run.
        ab.stop()
      expect DbusError: discard connectBus("unix:path=" & dir / "no-such-socket")

    d.stop()
    removeDir(dir)

  suite "linux-atspi: roles, states and placement":
    test "test_atspi_roles_map_onto_the_contract_vocabulary":
      const multiLine = 1'u64 shl 17
      check contractRole(61, 0) == roleTextField              # text
      check contractRole(61, multiLine) == roleTextArea
      check contractRole(79, 0) == roleTextField              # entry
      check contractRole(40, multiLine) == roleTextField      # password text
      check contractRole(23, 0) == roleWindow                 # frame
      check contractRole(69, 0) == roleWindow                 # window (GTK 4)
      check contractRole(43, 0) == roleButton
      check contractRole(62, 0) == roleButton                 # toggle button
      check contractRole(7, 0) == roleCheckbox
      check contractRole(130, 0) == roleCheckbox              # switch
      check contractRole(29, 0) == roleLabel
      check contractRole(39, 0) == roleGroup                  # panel
      check contractRole(20, 0) == roleGroup                  # filler
      check contractRole(75, 0) == roleApplication
      check contractRole(91, 0) == roleTreeItem
      check contractRole(9999, 0) == roleUnknown
      check nativeRoleName(40) == "password text"
      check nativeRoleName(43) == "button"
      check nativeRoleName(9999) == "role-9999"

    test "test_atspi_states_map_onto_the_contract_vocabulary":
      proc bits(xs: varargs[int]): uint64 =
        for x in xs: result = result or (1'u64 shl x)
      # GTK 4 reports sensitive, not enabled.
      check stEnabled in contractStates(43, bits(24))
      check stEnabled in contractStates(43, bits(8))
      check stEnabled notin contractStates(43, bits(25, 30))
      check contractStates(43, bits(25, 30)) == {stVisible}
      check contractStates(43, bits(30)) == {stOffscreen}
      check stEditable in contractStates(61, bits(7))
      check stEditable notin contractStates(61, bits(7, 43))   # read-only
      check stProtected in contractStates(40, 0)
      check stProtected notin contractStates(61, 0)
      check stChecked in contractStates(62, bits(20))          # a pressed toggle
      check stChecked notin contractStates(43, bits(20))       # a pressed button
      check contractStates(7, bits(4, 11, 12)) == {stChecked, stFocusable, stFocused}
      check contractStates(61, bits(33, 36)) == {stRequired, stInvalid}

    test "test_atspi_focus_by_pointer_only_on_placed_editable_text":
      # linux_atspi "Focus by pointer": the click fallback is offered on
      # editable text that takes the focus, is enabled, showing and visible
      # and has non-empty desktop bounds, and on nothing else (a click on a
      # button, checkbox or slider would activate or change it).
      proc bits(xs: varargs[int]): uint64 =
        for x in xs: result = result or (1'u64 shl x)
      const
        editable = 7
        enabledSt = 8
        focusable = 11
        readOnly = 43
        sensitive = 24
        showing = 25
        visible = 30
      let ready = bits(editable, focusable, sensitive, showing, visible)
      let placed = some(rect(10, 20, 200, 30))
      check pointerFocusable(61, ready, placed)                 # text (GTK 4 entry)
      check pointerFocusable(40, ready, placed)                 # password text
      check pointerFocusable(79, bits(editable, focusable, enabledSt, showing, visible), placed)
      check not pointerFocusable(43, ready, placed)             # button
      check not pointerFocusable(7, ready, placed)              # check box
      check not pointerFocusable(51, ready, placed)             # slider
      check not pointerFocusable(29, ready, placed)             # label
      check not pointerFocusable(61, ready or bits(readOnly), placed)
      check not pointerFocusable(61, bits(focusable, sensitive, showing, visible), placed)
      check not pointerFocusable(61, bits(editable, sensitive, showing, visible), placed)
      check not pointerFocusable(61, bits(editable, focusable, showing, visible), placed)
      check not pointerFocusable(61, bits(editable, focusable, sensitive, visible), placed)
      check not pointerFocusable(61, bits(editable, focusable, sensitive, showing), placed)
      check not pointerFocusable(61, ready, none(Rect))         # not placed on the desktop
      check not pointerFocusable(61, ready, some(rect(10, 20, 0, 30)))
      check not pointerFocusable(61, ready, some(rect(10, 20, 200, 0)))

    test "test_atspi_frames_are_placed_through_their_windows":
      let content = Size(width: 360, height: 467)
      # GTK 4 and GTK 3 without a shadow: the frame is the content.
      check frameOrigin(rect(0, 0, 360, 467), @[], content) == some(point(0, 0))
      check frameOrigin(rect(-5, -5, 360, 467), @[], content) == some(point(-5, -5))
      # GTK 3 drawing its own frame and shadow on Wayland (measured): the
      # frame is the surface, the visible window the union of its children.
      check frameOrigin(rect(0, 0, 412, 519),
                        @[rect(26, 23, 360, 47), rect(26, 70, 360, 420), rect(0, 0, 0, 0)],
                        content) == some(point(26, 23))
      check frameOrigin(rect(0, 0, 412, 519), @[rect(26, 70, 360, 420)], content).isNone
      let p = some(newPlacement(point(130, 170), point(26, 23)))
      check placeExtents(rect(26, 320, 360, 34), p) == some(rect(130, 467, 360, 34))
      check placeExtents(rect(26, 320, 360, 34), none(Placement)).isNone
      proc win(id, title: string, w, h: int): Window =
        Window(id: id, pid: 7, app: "a", title: some(title), bounds: rect(10, 10, w, h),
               onScreen: true)
      let a = win("1", "Order Form A", 360, 420)
      let b = win("2", "Order Form B", 500, 300)
      check matchWindow("Order Form B", some(rect(0, 0, 500, 300)), none(Rect), 2,
                        @[a, b]).get.id == "2"
      check matchWindow("", some(rect(0, 0, 9, 9)), none(Rect), 1, @[a]).get.id == "1"
      check matchWindow("", some(rect(0, 0, 500, 300)), none(Rect), 2, @[a, b]).get.id == "2"
      check matchWindow("", some(rect(0, 0, 77, 77)), none(Rect), 2, @[a, b]).isNone
      check matchWindow("Order Form A", none(Rect), none(Rect), 1, @[]).isNone

  suite "linux-atspi and linux-host without an AT-SPI bus":
    test "test_atspi_without_a_session_bus_is_atspi_disabled":
      check compiledIn(modTree, "linux-atspi")
      check compiledIn(modSession, "linux-host")
      let token = newCancelToken()
      let b = newLinuxAtspiTree(LinuxAtspiConfig(env: initTable[string, string](),
                                                 token: token))
      try:
        discard b.tree("host", TreeTarget(kind: ttkPid, pid: 1), none(int), 10)
        check false
      except PermissionDeniedError as e:
        check e.reason == "atspi-disabled"
        check e.backend == "linux-atspi"
      for f in b.features(true):
        check f.state == fsUnavailable and f.reason == some("atspi-disabled")
      # A session bus nobody listens on: the same, not an empty tree.
      var env = initTable[string, string]()
      env["DBUS_SESSION_BUS_ADDRESS"] = "unix:path=/nonexistent/gs7/bus"
      let b2 = newLinuxAtspiTree(LinuxAtspiConfig(env: env, token: token))
      expect PermissionDeniedError:
        discard b2.find("host", none(TreeTarget), ElementFilter(), 10)
      check registeredApps(LinuxAtspiConfig(env: env, token: token)).isNone
      let h = newLinuxHostSession(LinuxHostConfig(env: initTable[string, string](),
        token: token, atspi: LinuxAtspiConfig(env: initTable[string, string](), token: token),
        capture: proc (): CaptureBackend = raise unavailable("x", "missing-tool", "none")))
      let p = h.permissions(none(string))
      check p.accessibility == psUnknown
      check p.screenRecording == psNotApplicable
      let hb = newLinuxHostSession(LinuxHostConfig(env: env, token: token,
        atspi: LinuxAtspiConfig(env: env, token: token),
        capture: proc (): CaptureBackend = raise unavailable("x", "missing-tool", "none")))
      check hb.permissions(none(string)).accessibility == psDenied
      check hb.list()[0].id == "host" and hb.list()[0].backend == "linux-host"
      expect BackendNotFoundError: discard hb.info("other")
      expect BackendUnavailableError:
        discard hb.start(SessionSpec(kind: skHeadless, displays: 1))
      token.free()
