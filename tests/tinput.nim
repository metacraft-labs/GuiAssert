## Synthetic-input generation tests.
##
## The default suite is pure — it asserts the exact AppleScript strings, the
## `using {...}` modifier clauses, and the virtual key-code table the input
## builders produce, without invoking any subprocess and without requiring
## any macOS Accessibility/TCC permission.
##
## The `inputLive`-gated suite launches TextEdit, opens a new document, types
## a known string, reads it back through the accessibility tree, and asserts
## the read-back matches.  That path needs macOS Accessibility permission for
## the process running the test and is opt-in via `-d:inputLive`.

import std/[unittest]
import ../src/gui_assert/input

when defined(inputLive):
  import std/[strutils, os]
  import ../src/gui_assert/window_layout

suite "input: modifier clause builder":

  test "empty modifier set yields no clause":
    check buildModifierClause({}) == ""

  test "single modifier renders a one-element braced list":
    check buildModifierClause({modCommand}) == "{command down}"

  test "multiple modifiers render in enum order":
    check buildModifierClause({modCommand, modShift}) ==
      "{command down, shift down}"
    # Insertion order does not matter — enum order does.
    check buildModifierClause({modShift, modCommand}) ==
      "{command down, shift down}"

  test "all four modifiers render in enum order":
    check buildModifierClause({modCommand, modOption, modControl, modShift}) ==
      "{command down, option down, control down, shift down}"

suite "input: typeText script builder":

  test "buildTypeTextScript emits a System Events keystroke":
    check buildTypeTextScript("hello") ==
      "tell application \"System Events\" to keystroke \"hello\""

  test "buildTypeTextScript escapes double quotes":
    check buildTypeTextScript("say \"hi\"") ==
      "tell application \"System Events\" to keystroke \"say \\\"hi\\\"\""

  test "buildTypeTextScript escapes backslashes":
    check buildTypeTextScript("a\\b") ==
      "tell application \"System Events\" to keystroke \"a\\\\b\""

  test "buildTypeTextScript keeps spaces and punctuation":
    check buildTypeTextScript("CodeTracer flame demo") ==
      "tell application \"System Events\" to keystroke " &
      "\"CodeTracer flame demo\""

suite "input: keyStroke script builder":

  test "keyStroke with no modifiers omits the using clause":
    check buildKeyStrokeScript("a") ==
      "tell application \"System Events\" to keystroke \"a\""

  test "Cmd+S renders keystroke with a command-down clause":
    check buildKeyStrokeScript("s", {modCommand}) ==
      "tell application \"System Events\" to keystroke \"s\" " &
      "using {command down}"

  test "Cmd+Shift+Z renders both modifiers in order":
    check buildKeyStrokeScript("z", {modCommand, modShift}) ==
      "tell application \"System Events\" to keystroke \"z\" " &
      "using {command down, shift down}"

  test "keyStroke escapes a quote key":
    check buildKeyStrokeScript("\"") ==
      "tell application \"System Events\" to keystroke \"\\\"\""

suite "input: keyCode script builder":

  test "key code with no modifiers":
    check buildKeyCodeScript(36) ==
      "tell application \"System Events\" to key code 36"

  test "key code with a modifier":
    check buildKeyCodeScript(123, {modShift}) ==
      "tell application \"System Events\" to key code 123 using {shift down}"

suite "input: virtual key-code table":

  test "printable-less navigation and control keys map correctly":
    check keyCodeFor("return") == 36
    check keyCodeFor("enter") == 36
    check keyCodeFor("tab") == 48
    check keyCodeFor("space") == 49
    check keyCodeFor("delete") == 51
    check keyCodeFor("backspace") == 51
    check keyCodeFor("escape") == 53
    check keyCodeFor("esc") == 53
    check keyCodeFor("forwarddelete") == 117
    check keyCodeFor("home") == 115
    check keyCodeFor("end") == 119
    check keyCodeFor("pageup") == 116
    check keyCodeFor("pagedown") == 121
    check keyCodeFor("left") == 123
    check keyCodeFor("right") == 124
    check keyCodeFor("down") == 125
    check keyCodeFor("up") == 126

  test "keyCodeFor is case-insensitive":
    check keyCodeFor("Return") == 36
    check keyCodeFor("LEFT") == 123

  test "keyCodeFor raises InputError for an unknown name":
    expect InputError:
      discard keyCodeFor("nope")

# ---------------------------------------------------------------------------
# Live suite — gated behind -d:inputLive (macOS only).
#
# Launches TextEdit, opens a new document (Cmd+N), types a known string,
# reads it back via the accessibility tree, and asserts the read-back.
# Requires macOS Accessibility permission for the process running this test;
# without it, the keystroke osascript exits non-zero (error -1719) and this
# test reports a TCC gate rather than a code fault.  The document is closed
# WITHOUT saving so nothing is written to the user's Documents.
# ---------------------------------------------------------------------------

when defined(inputLive):
  when defined(macosx):
    import std/[osproc, streams]

    proc osa(script: string): tuple[output: string, code: int] =
      let p = startProcess(findExe("osascript"), args = @["-e", script],
                           options = {poStdErrToStdOut})
      let outp = p.outputStream().readAll().strip()
      let code = p.waitForExit()
      p.close()
      (outp, code)

    suite "input live (TextEdit type + read-back):":

      proc isTccDenial(msg: string): bool =
        ## macOS reports an Accessibility denial for synthetic keystrokes as
        ## error 1002 ("not allowed to send keystrokes") or -1719 ("not
        ## allowed assistive access").  Either means the CODE ran but the
        ## process lacks Accessibility permission — a TCC gate, not a bug.
        "1002" in msg or "-1719" in msg or "not allowed" in msg

      test "types a string into TextEdit and reads it back":
        const typed = "CodeTracer flame demo"
        var tccGated = false
        try:
          # Launch + focus TextEdit.
          discard osa("tell application \"TextEdit\" to activate")
          sleep(1500)
          activateApp("TextEdit")
          sleep(500)
          # New document, then type.
          keyStroke("n", {modCommand})
          sleep(800)
          typeText(typed)
          sleep(800)
          # Read the document text back through the accessibility tree.
          let readScript =
            "tell application \"System Events\" to tell process \"TextEdit\" " &
            "to get value of text area 1 of scroll area 1 of window 1"
          let (readBack, readCode) = osa(readScript)
          echo "LIVE read-back code=", readCode, " value=", readBack
          check readCode == 0
          check readBack == typed
        except InputError as e:
          # Distinguish an Accessibility TCC gate (expected, unattended) from
          # a genuine code failure.  The former is reported and tolerated; the
          # latter re-raises to fail the test.
          if isTccDenial(e.msg):
            tccGated = true
            echo "LIVE keystroke injection is Accessibility-TCC-GATED " &
              "(code works, permission missing): ", e.msg
          else:
            raise
        finally:
          # Close/quit WITHOUT saving so nothing lands in ~/Documents.
          discard osa("tell application \"TextEdit\" to close every document saving no")
          sleep(300)
          discard osa("tell application \"TextEdit\" to quit saving no")
        if tccGated:
          # Not a code failure — the generation path is proven by the pure
          # suites above; live injection needs Accessibility permission.
          skip()
