## e2e_terminal_action_injection
##
## Drives an interactive shell-like process inside a virtual PTY using a
## timed script and asserts that keyboard simulation events arrive within a
## precision range of ±50 ms.
##
## Implementation choice: we use `cat` as the child process — it echoes
## stdin → stdout byte-for-byte (the PTY slave is opened in raw mode by the
## driver, so canonical buffering and local echo are disabled). This gives
## us a deterministic way to time-stamp the *arrival* of each keystroke at
## the child without depending on a real shell prompt or job control.

import std/[unittest, strutils]
import ../src/gui_assert/parser
import ../src/gui_assert/driver

suite "e2e_terminal_action_injection":

  test "PTY driver fires three keystrokes within ±50ms of schedule":
    const yaml = """
metadata:
  title: "PTY timing test"
timeline:
  - time: 0.0
    action: type_text
    params:
      text: "hello\n"
  - time: 0.5
    action: type_text
    params:
      text: "world\n"
  - time: 1.0
    action: type_text
    params:
      text: "ok\n"
"""
    let script = parseScriptYaml(yaml)
    check script.timeline.len == 3

    var driver = newPtyDriver(["/bin/cat"])
    defer: closeDriver(driver)

    let events = playScriptOnPty(driver, script)
    check events.len == 3

    # Wait for cat to echo back everything we wrote (3 newlines worth).
    # "hello\nworld\nok\n" is 14 bytes.
    let expectedEcho = "hello\nworld\nok\n"
    discard waitForByteCount(driver, expectedEcho.len, timeoutMs = 2000)

    # Each event must have fired within ±50ms of its scheduled offset.
    for ev in events:
      let driftMs = abs(ev.drift) * 1000.0
      checkpoint "kf=" & $ev.keyframeIndex &
                 " sched=" & $ev.scheduledOffset &
                 " actual=" & $ev.actualOffset &
                 " drift_ms=" & $driftMs
      check driftMs <= 50.0

    # Sanity: child actually saw our bytes (output buffer contains the echo).
    let outBuf = driver.output
    check expectedEcho in outBuf
