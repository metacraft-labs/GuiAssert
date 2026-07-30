## Window-layout helper tests.
##
## The default suite is pure — it asserts on the exact AppleScript
## strings and `open` argv the helpers build, without invoking any
## subprocess. The `appiumLive`-gated suite launches `TextEdit` via
## the helper and resizes it; that suite requires macOS Accessibility
## permission and is opt-in.

import std/[strutils, unittest, os]
import ../src/gui_assert/window_layout

suite "window_layout AppleScript builder":

  test "applescriptEscape escapes backslashes and quotes":
    check applescriptEscape("hello") == "hello"
    check applescriptEscape("with \"quote\"") == "with \\\"quote\\\""
    check applescriptEscape("back\\slash") == "back\\\\slash"

  test "buildSetBoundsScript uses bundle-id form when input has a dot":
    let s = buildSetBoundsScript("com.apple.Terminal", 100, 200, 800, 600)
    check s.contains("tell application id \"com.apple.Terminal\"")
    # bounds is {x1, y1, x2, y2} = {100, 200, 900, 800}
    check s.contains("{100, 200, 900, 800}")

  test "buildSetBoundsScript uses application-name form for plain names":
    let s = buildSetBoundsScript("TextEdit", 0, 0, 640, 480)
    check s.contains("tell application \"TextEdit\"")
    check s.contains("{0, 0, 640, 480}")

  test "buildSetBoundsScript escapes embedded quotes":
    let s = buildSetBoundsScript("Weird \"Name\"", 0, 0, 1, 1)
    check s.contains("\\\"Name\\\"")

suite "window_layout activate/focus builder":

  test "buildActivateScript uses bundle-id form when input has a dot":
    let s = buildActivateScript("com.apple.TextEdit")
    check s == "tell application id \"com.apple.TextEdit\" to activate"

  test "buildActivateScript uses application-name form for plain names":
    let s = buildActivateScript("TextEdit")
    check s == "tell application \"TextEdit\" to activate"

  test "buildActivateScript escapes embedded quotes and backslashes":
    let s = buildActivateScript("Weird \"Name\"\\x")
    check s == "tell application \"Weird \\\"Name\\\"\\\\x\" to activate"

  test "processNameOf derives label from a bundle id":
    check processNameOf("com.apple.TextEdit") == "TextEdit"
    check processNameOf("com.microsoft.VSCode") == "VSCode"

  test "processNameOf passes plain names and paths through unchanged":
    check processNameOf("TextEdit") == "TextEdit"
    check processNameOf("/Applications/Visual Studio Code.app") ==
      "/Applications/Visual Studio Code.app"

  test "buildFocusScript targets System Events by process name":
    let s = buildFocusScript("TextEdit")
    check s ==
      "tell application \"System Events\" to " &
      "set frontmost of process \"TextEdit\" to true"

  test "buildFocusScript normalises a bundle id to its process name":
    let s = buildFocusScript("com.apple.TextEdit")
    check s ==
      "tell application \"System Events\" to " &
      "set frontmost of process \"TextEdit\" to true"

  test "buildFocusScript escapes quotes in the process name":
    let s = buildFocusScript("Odd \"App\"")
    check s ==
      "tell application \"System Events\" to " &
      "set frontmost of process \"Odd \\\"App\\\"\" to true"

  test "buildOsascriptArgv wraps a script as a single -e argument":
    let script = buildActivateScript("TextEdit")
    check buildOsascriptArgv(script) == @["-e", script]

suite "window_layout open argv builder":

  test "buildOpenArgv with a .app path uses -a":
    let spec = WindowSpec(
      bundleIdOrPath: "/Applications/Visual Studio Code.app",
      args: @[],
      x: 0, y: 0, width: 0, height: 0)
    let argv = buildOpenArgv(spec)
    check argv == @["-n", "-a", "/Applications/Visual Studio Code.app"]

  test "buildOpenArgv with a bundle id uses -b":
    let spec = WindowSpec(
      bundleIdOrPath: "com.apple.Terminal",
      args: @[],
      x: 0, y: 0, width: 0, height: 0)
    let argv = buildOpenArgv(spec)
    check argv == @["-n", "-b", "com.apple.Terminal"]

  test "buildOpenArgv forwards args via --args":
    let spec = WindowSpec(
      bundleIdOrPath: "com.apple.Terminal",
      args: @["--login", "-i"],
      x: 0, y: 0, width: 0, height: 0)
    let argv = buildOpenArgv(spec)
    check argv == @["-n", "-b", "com.apple.Terminal", "--args",
                    "--login", "-i"]

  test "buildOpenArgv with a plain app name uses -a":
    let spec = WindowSpec(
      bundleIdOrPath: "TextEdit",
      args: @[],
      x: 0, y: 0, width: 0, height: 0)
    let argv = buildOpenArgv(spec)
    check argv == @["-n", "-a", "TextEdit"]

# ---------------------------------------------------------------------------
# Live suite — gated behind -d:appiumLive.
#
# Launches `TextEdit`, sets bounds, and terminates.  Requires macOS
# Accessibility permission to be granted to the binary running this
# test (Terminal.app, the IDE, or a LaunchAgent), otherwise the
# osascript setBounds call returns a -1719 error.
# ---------------------------------------------------------------------------

when defined(appiumLive):
  when defined(macosx):
    suite "window_layout live (TextEdit):":

      test "launches TextEdit, sets bounds, terminates":
        let spec = WindowSpec(
          bundleIdOrPath: "TextEdit",
          args: @[],
          x: 100, y: 100, width: 800, height: 600)
        let handle = launchWindow(spec)
        check handle.pid > 0
        # Bring it to the foreground.
        handle.activate()
        handle.focus()
        # Move it.
        handle.setBounds(200, 200, 900, 700)
        # Terminate.
        handle.terminate()
        check handle.pid == -1
