## tlinux_input — the parts of the Linux input backends (`linux-wlr-virtual`,
## `linux-mutter`, `linux-xtest`, `linux-uinput`) that need no display
## server, so they run in the default suite (spec §9.1):
##
## * the plans of every input verb (`linux_plan`): event order, modifiers
##   held around clicks and keys, drag interpolation through every waypoint,
##   scroll axes and signs, typed text as keysyms (control characters
##   refused by position), and the timing a plan adds up to;
## * the keysym of every key of the spec §7.5 key table, and the US key code
##   of every key `linux-uinput` can type;
## * the input script the helpers read, and the helpers' own parser: each
##   helper (built here with `helpers/linux/build.sh`) refuses a malformed
##   script before it connects to anything;
## * Mutter's stream coordinates at scale 1 and 2, in both layout modes, and
##   the display-configuration answer they come from;
## * sway's window commands (ids that are not numbers are refused, so they
##   cannot widen a criteria);
## * the input default follows the session; and every Linux input backend,
##   with no session to reach, answers exit 4 naming what is missing.
##
## Stand-ins: none. The live suite (`tests/live/tinput_linux.nim`) runs the
## backends against real compositors and X servers.

import std/[options, os, osproc, streams, strtabs, strutils, tables, unittest]
from std/posix import nil

import ../src/gui_assert/core/[geometry, desktop_types, interfaces, keys]
import ../src/gui_assert/cancel
import ../src/gui_assert/cli/registry
import ../src/gui_assert/backends/tree/dbus_wire
import ../src/gui_assert/backends/input/linux_plan

when defined(linux):
  import ../src/gui_assert/backends/input/[linux_common, linux_wlr_virtual, linux_mutter,
                                           linux_xtest, linux_uinput]

proc lines(ops: seq[InputOp]): seq[string] = toScript(ops).strip.splitLines

suite "plans":
  test "test_click_plan_holds_modifiers_around_the_clicks":
    check planClick(point(10, 20), mbLeft, 1, @[]).lines ==
      @["move 10 20", "button left down", "sleep 15", "button left up"]
    let p = planClick(point(5, 6), mbRight, 2, @["shift", "ctrl"]).lines
    check p == @["key 0x0000ffe3 down", "key 0x0000ffe1 down", "move 5 6",
                 "button right down", "sleep 15", "button right up", "sleep 40",
                 "button right down", "sleep 15", "button right up",
                 "key 0x0000ffe1 up", "key 0x0000ffe3 up"]
    # The transports that need it (Mutter, uinput) wait between the
    # modifiers and the pointer; nothing waits without modifiers.
    check planClick(point(5, 6), mbRight, 1, @["shift"], modifierSettleMs).lines ==
      @["key 0x0000ffe1 down", "sleep 30", "move 5 6", "button right down", "sleep 15",
        "button right up", "key 0x0000ffe1 up"]
    check planClick(point(5, 6), mbLeft, 1, @[], modifierSettleMs).lines ==
      @["move 5 6", "button left down", "sleep 15", "button left up"]

  test "test_drag_plan_passes_every_waypoint_in_order":
    let path = @[point(0, 0), point(10, 0), point(10, 10), point(13, 19)]
    let ops = planDrag(path, mbLeft, 2, 600)
    check ops.lines[0 .. 2] == @["move 0 0", "button left down", "sleep 30"]
    check ops.lines[^1] == "button left up"
    let moves = movePoints(ops)
    check moves == @[point(0, 0), point(5, 0), point(10, 0), point(10, 5), point(10, 10),
                     point(12, 15), point(13, 19)]
    # Every vertex is exactly visited, in order.
    var i = 0
    for v in path:
      while i < moves.len and moves[i] != v: inc i
      check i < moves.len
    # The duration is spread over the motion events (6 of them, 100 ms).
    check plannedMs(ops) == 30 + 6 * 100
    check planDrag(path, mbLeft, 1, 0).movePoints == path
    expect InputPlanError: discard planDrag(@[point(1, 1)], mbLeft, 1, 0)

  test "test_scroll_plan_axes_and_signs":
    check planScroll(point(1, 2), -3, 4, suLine).lines ==
      @["move 1 2", "scroll v 4 line", "scroll h -3 line"]
    check planScroll(point(1, 2), 0, -25, suPixel).lines ==
      @["move 1 2", "scroll v -25 pixel"]

  test "test_type_plan_is_keysyms_and_refuses_control_characters":
    check typedKeysyms("aZ é中") ==
      @[0x61'u32, 0x5a, 0x20, 0xe9, 0x0100_4e2d]
    check typedKeysyms("a\nb\r\nc\rd\te") ==
      @[0x61'u32, keysymReturn, 0x62, keysymReturn, 0x63, keysymReturn, 0x64, keysymTab, 0x65]
    check typedKeysyms("😀") == @[0x0101_f600'u32]
    try:
      discard typedKeysyms("ab\x01c")
      check false
    except InputPlanError as e:
      check "character 3" in e.msg
      check "ab" notin e.msg
    expect InputPlanError: discard typedKeysyms("x\x7f")
    expect InputPlanError: discard typedKeysyms("x\u0085")
    let ops = planType("ab", 25)
    check ops.lines == @["key 0x00000061 down", "key 0x00000061 up", "sleep 25",
                         "key 0x00000062 down", "key 0x00000062 up"]
    check planType("", 10).len == 0

  test "test_key_plan_presses_modifiers_in_table_order":
    check planKey(normalizeCombo("SHIFT+Control+Tab")).lines ==
      @["key 0x0000ffe3 down", "key 0x0000ffe1 down", "key 0x0000ff09 down",
        "key 0x0000ff09 up", "key 0x0000ffe1 up", "key 0x0000ffe3 up"]
    check planKey("cmd+alt+F24").lines ==
      @["key 0x0000ffe9 down", "key 0x0000ffeb down", "key 0x0000ffd5 down",
        "key 0x0000ffd5 up", "key 0x0000ffeb up", "key 0x0000ffe9 up"]

suite "the key table":
  test "test_every_key_of_the_table_has_its_keysym":
    let want = {"Return": 0xff0d, "Tab": 0xff09, "Escape": 0xff1b, "BackSpace": 0xff08,
                "Delete": 0xffff, "Insert": 0xff63, "Space": 0x20, "Home": 0xff50,
                "End": 0xff57, "PageUp": 0xff55, "PageDown": 0xff56, "Pause": 0xff13,
                "Up": 0xff52, "Down": 0xff54, "Left": 0xff51, "Right": 0xff53}.toTable
    for (canonical, aliases) in namedKeyTable:
      check keysymOfKey(canonical) == uint32(want[canonical])
      for a in aliases: check keysymOfKey(canonicalKey(a)) == uint32(want[canonical])
    for n in 1 .. maxFunctionKey:
      check keysymOfKey("F" & $n) == 0xffbe'u32 + uint32(n - 1)
    check keysymOfKey("F24") == 0xffd5'u32
    check keysymOfKey(canonicalKey("A")) == 0x61'u32
    check keysymOfKey("+") == 0x2b'u32
    check keysymOfKey("€") == 0x0100_20ac'u32
    check modifierKeysyms == [0xffe3'u32, 0xffe9, 0xffe1, 0xffeb]

  test "test_us_key_codes_for_uinput":
    check usKeyOf(0x61) == some((30, false))           # a -> KEY_A
    check usKeyOf(0x51) == some((16, true))            # Q -> shift+KEY_Q
    check usKeyOf(0x31) == some((2, false))            # 1
    check usKeyOf(0x30) == some((11, false))           # 0
    check usKeyOf(0x29) == some((11, true))            # )
    check usKeyOf(0x20) == some((57, false))
    check usKeyOf(0x2b) == some((13, true))            # +
    check usKeyOf(0x6d) == some((50, false))           # m
    check usKeyOf(0x6c) == some((38, false))           # l
    check usKeyOf(keysymReturn) == some((28, false))
    check usKeyOf(0xffbe) == some((59, false))         # F1
    check usKeyOf(0xffc9) == some((88, false))         # F12
    check usKeyOf(0xffca) == some((183, false))        # F13
    check usKeyOf(0xffd5) == some((194, false))        # F24
    check usKeyOf(0xe9).isNone
    check usKeyOf(0x0100_4e2d).isNone
    # Every printable ASCII character has a key.
    for c in 0x20 .. 0x7e: check usKeyOf(uint32(c)).isSome
    for (canonical, _) in namedKeyTable: check usKeyOf(keysymOfKey(canonical)).isSome

suite "Mutter's coordinates":
  test "test_stream_position_maps_back_exactly":
    let mons = @[MutterMonitor(connector: "Meta-0", bounds: rect(0, 0, 1200, 800), scale: 1.0),
                 MutterMonitor(connector: "Meta-1", bounds: rect(1200, 0, 960, 540), scale: 2.0)]
    check streamPosition(mons, false, point(10, 20)).get == ("Meta-0", 10.0, 20.0)
    check streamPosition(mons, true, point(1300, 40)).get == ("Meta-1", 200.0, 80.0)
    check streamPosition(mons, false, point(1300, 40)).get == ("Meta-1", 100.0, 40.0)
    check streamPosition(mons, true, point(1200, 600)).isNone
    check streamPosition(mons, true, point(-1, 0)).isNone

  when defined(linux):
    test "test_current_state_parsed_into_logical_monitors":
      proc mode(w, h: int, current: bool): DValue =
        dstruct(dstr($w & "x" & $h), dint32(w), dint32(h), ddouble(60.0), ddouble(1.0),
                darray("d", @[ddouble(1.0)]),
                dvardict(if current: @[("is-current", dbool(true))] else: @[]))
      proc monitor(conn: string, modes: seq[DValue]): DValue =
        dstruct(dstruct(dstr(conn), dstr("V"), dstr("P"), dstr("S")),
                darray("(siiddada{sv})", modes), dvardict([]))
      proc logical(x, y: int, scale: float, transform: int, conn: string): DValue =
        dstruct(dint32(x), dint32(y), ddouble(scale), duint32(transform), dbool(x == 0),
                darray("(ssss)", @[dstruct(dstr(conn), dstr("V"), dstr("P"), dstr("S"))]),
                dvardict([]))
      let body = @[duint32(3),
        darray("((ssss)a(siiddada{sv})a{sv})", @[
          monitor("Meta-0", @[mode(1920, 1080, false), mode(1200, 800, true)]),
          monitor("Meta-1", @[mode(1920, 1080, true)])]),
        darray("(iiduba(ssss)a{sv})", @[logical(0, 0, 1.0, 0, "Meta-0"),
                                       logical(1200, 0, 2.0, 1, "Meta-1")]),
        dvardict([("layout-mode", duint32(1))])]
      let (mons, logicalLayout) = parseCurrentState(body)
      check logicalLayout
      check mons.len == 2
      check mons[0].bounds == rect(0, 0, 1200, 800)
      # Rotated (transform 1) and scaled 2 in the logical layout.
      check mons[1].bounds == rect(1200, 0, 540, 960)
      check mons[1].scale == 2.0
      var physical = body
      physical[3] = dvardict([("layout-mode", duint32(2))])
      let (pm, pl) = parseCurrentState(physical)
      check not pl
      check pm[1].bounds == rect(1200, 0, 1080, 1920)
      expect DbusError: discard parseCurrentState(@[duint32(1)])

when defined(linux):
  suite "sway's window commands":
    test "test_sway_commands_take_numeric_ids_only":
      check swayFocusCommand("17") == "[con_id=17] focus"
      check swayBoundsCommand("17", rect(5, 6, 300, 200)) ==
        "[con_id=17] floating enable, resize set width 300 px height 200 px, " &
        "move absolute position 5 6"
      for bad in ["", "17] kill; [app_id=x", "abc", "1 2"]:
        expect BackendNotFoundError: discard swayFocusCommand(bad)

  suite "the helpers' script":
    let helpers = getTempDir() / "guiassert-tlinux-input-helpers"
    let (o, code) = execCmdEx(quoteShellCommand(["bash", currentSourcePath().parentDir.parentDir /
                                                 "helpers" / "linux" / "build.sh", helpers]))

    test "test_helpers_refuse_a_malformed_script_before_connecting":
      checkpoint o
      check code == 0
      # No display at all: a malformed script is still the script's error
      # (exit 2), so nothing was sent anywhere.
      for (helper, args) in [("wayland_input", @["run"]), ("xtest_input", @["run"]),
                             ("uinput_input", @["run", "0", "0", "100", "100"])]:
        for script in ["move 1\n", "button left sideways\n", "scroll d 1 line\n",
                       "scroll v 1 furlong\n", "key zz down\n", "sleep -5\n",
                       "jump 1 2\n", "move 1 2 3\n", repeat('x', 200) & "\n"]:
          let p = startProcess(helpers / helper, args = args,
                               env = newStringTable({"PATH": "/nonexistent"}, modeCaseSensitive),
                               options = {})
          p.inputStream.write(script)
          p.inputStream.close()
          let rc = p.waitForExit(10_000)
          let line = p.outputStream.readAll().strip
          p.close()
          checkpoint helper & " " & script.strip & " -> " & $rc & " " & line
          check rc == 2
          check line.startsWith("error script ")

    test "test_helpers_answer_connect_without_a_display":
      for (helper, args, want) in [("wayland_input", @["run"], 4), ("xtest_input", @["run"], 4)]:
        let p = startProcess(helpers / helper, args = args,
                             env = newStringTable({"PATH": "/nonexistent"}, modeCaseSensitive),
                             options = {})
        p.inputStream.write("move 1 2\n")
        p.inputStream.close()
        let rc = p.waitForExit(10_000)
        let line = p.outputStream.readAll().strip
        p.close()
        checkpoint helper & " -> " & line
        check rc == want
        check line.startsWith("error connect ")

    try: removeDir(helpers)
    except OSError: discard

  suite "the backends without a session":
    let cfg = LinuxInputConfig(stateDir: getTempDir() / "guiassert-tlinux-input-state",
                               token: newCancelToken(), env: {"PATH": "/nonexistent"}.toTable)

    test "test_helper_runner_streams_input_and_output_together":
      # A helper that answers line by line while it reads (`wayland_input
      # keysyms`) fills its output pipe before it has read all of a long
      # input: the runner must read while it writes. `cat` echoes 3 MiB
      # here, far beyond both pipes; the runner keeps the first MiB.
      let cat = findExe("cat", followSymlinks = false)
      check cat.len > 0
      var input = ""
      for i in 0 ..< 3 * 1024 * 1024 div 16: input.add "0x0100" & align($i, 8, '0') & "\n"
      let startNs = monoNowNs()
      let r = cfg.runHelper("linux-wlr-virtual", @[cat], input, 20_000)
      check elapsedMsSince(startNs) < 15_000
      checkpoint "exit " & $r.code & ", " & $r.output.len & " bytes"
      check r.code == 0
      check r.output.len == 1 shl 20
      check r.output == input[0 ..< 1 shl 20]
      check r.line == "0x010000000000"
      # A helper that exits without reading its input is not an error of the
      # runner: its status is the answer.
      let f = cfg.runHelper("linux-wlr-virtual", @[findExe("false", followSymlinks = false)], input, 20_000)
      check f.code == 1

    test "test_input_default_follows_the_session":
      check linuxHostInputDefault({"SWAYSOCK": "/x", "WAYLAND_DISPLAY": "w"}.toTable) ==
        "linux-wlr-virtual"
      check linuxHostInputDefault({"WAYLAND_DISPLAY": "w", "XDG_CURRENT_DESKTOP": "ubuntu:GNOME"}.toTable) ==
        "linux-mutter"
      check linuxHostInputDefault({"DISPLAY": ":5"}.toTable) == "linux-xtest"
      check linuxHostInputDefault(initTable[string, string]()) == "linux-wlr-virtual"
      for b in ["linux-wlr-virtual", "linux-mutter", "linux-xtest", "linux-uinput"]:
        check compiledIn(modInput, b)
        check unavailability(modInput, b).ok

    test "test_each_backend_names_what_is_missing":
      for (backend, variable) in [(newLinuxWlrVirtualInput(cfg), "WAYLAND_DISPLAY"),
                                  (newLinuxXtestInput(cfg), "DISPLAY"),
                                  (newLinuxMutterInput(cfg), "DBUS_SESSION_BUS_ADDRESS")]:
        try:
          discard backend.click("host", point(1, 1), mbLeft, 1, @[])
          check false
        except BackendUnavailableError as e:
          check e.reason == "display-server-unsupported"
          check variable in e.msg
          check e.remedy.len > 0
        let fs = backend.features(false)
        check fs.len == 3
        for f in fs:
          check f.backend == backend.name
          check f.state == fsUnavailable
      let u = newLinuxUinputInput(cfg)
      # Never run against a writable device here: that would create real
      # input devices on the host. The live suite proves the refusal.
      if posix.access("/dev/uinput", posix.W_OK) != 0:
        try:
          discard u.key("host", "Return")
          check false
        except PermissionDeniedError as e:
          check e.reason == "uinput-access"
          check "/dev/uinput" in e.remedy
        check u.features(false)[0].reason == some("uinput-access")
      expect BackendUnavailableError: discard u.focusWindow("host", "1")
