## GuiAssert action drivers
##
## Three independent driver backends share a `Script` representation produced
## by `parser.nim`:
##
##   * `BrowserDriver`  — emits Playwright-compatible JSON commands. The
##     existing CodeTracer browser-replay test suite already speaks this
##     dialect (selector-based locators, click/scroll/fill verbs, optional
##     timeout fields). We do not drive a live browser in M2 — instead we
##     produce the wire format so downstream tooling can replay it.
##
##   * `PtyDriver`      — owns a Unix pseudo-terminal pair, spawns a child
##     process (typically a shell or `cat`), and fires keystroke events at
##     timestamps computed from `script.start_time + keyframe.time`. We honour
##     the script's `time` field by sleeping until the wall-clock target,
##     then issuing the write. Drift relative to schedule is exposed on the
##     returned event log so tests can assert ≤ 50 ms tolerance.
##
##   * `VsCodeClient`   — opens a TCP connection to a (configurable) host /
##     port and emits a JSON command line for each keyframe. The server side
##     lives in a future VS Code extension; for M2 we only need the client.

import std/[json, options, net, os, strutils, monotimes, times, math]
import ./parser
import ./pty_unix

# ===========================================================================
# Common
# ===========================================================================

type
  ActionEvent* = object
    ## Recorded result of a single keyframe execution.
    keyframeIndex*: int
    scheduledOffset*: float  ## keyframe.time
    actualOffset*: float     ## wall-clock seconds since driver.start
    drift*: float            ## actualOffset - scheduledOffset
    action*: string

# ===========================================================================
# Browser Driver — Playwright JSON emitter
# ===========================================================================
#
# The wire format mirrors what an external Playwright runner would consume.
# Each command is a JSON object with at minimum a `type` field. Selectors
# follow Playwright's CSS / role syntax verbatim.

type
  BrowserDriver* = object
    baseUrl*: string           ## optional default origin for `navigate` etc.
    defaultTimeoutMs*: int     ## default per-action timeout in ms

proc newBrowserDriver*(baseUrl = ""; defaultTimeoutMs = 30000): BrowserDriver =
  BrowserDriver(baseUrl: baseUrl, defaultTimeoutMs: defaultTimeoutMs)

proc decorateAt(node: JsonNode, atSeconds: float): JsonNode =
  ## Attach a uniform `at` timing field (seconds, float) to the command.
  node["at"] = newJFloat(atSeconds)
  return node

proc emitClick*(driver: BrowserDriver, target: string, at: float;
                button = "left"): JsonNode =
  ## Emit a `click` command at `target` (CSS selector) scheduled for `at` s.
  let cmd = %* {
    "type": "click",
    "selector": target,
    "button": button,
    "timeout": driver.defaultTimeoutMs,
  }
  return decorateAt(cmd, at)

proc emitScroll*(driver: BrowserDriver, target: string, deltaY: float;
                 at: float): JsonNode =
  let cmd = %* {
    "type": "scroll",
    "selector": target,
    "deltaY": deltaY,
    "timeout": driver.defaultTimeoutMs,
  }
  return decorateAt(cmd, at)

proc emitType*(driver: BrowserDriver, target: string, text: string;
               at: float; wpm: int = 0): JsonNode =
  let cmd = %* {
    "type": "type",
    "selector": target,
    "text": text,
    "timeout": driver.defaultTimeoutMs,
  }
  if wpm > 0:
    cmd["wpm"] = newJInt(wpm)
  return decorateAt(cmd, at)

proc emitNavigate*(driver: BrowserDriver, url: string, at: float): JsonNode =
  let cmd = %* {
    "type": "navigate",
    "url": url,
    "timeout": driver.defaultTimeoutMs,
  }
  return decorateAt(cmd, at)

proc scriptToBrowserCommands*(driver: BrowserDriver, script: Script): seq[JsonNode] =
  ## Compile a `Script` into a sequence of Playwright commands. Only actions
  ## relevant to the browser are emitted; everything else is skipped. This
  ## is the canonical bridge used by `tests/tdriver_browser.nim`.
  result = @[]
  for kf in script.timeline:
    case kf.action
    of "click":
      let target = if kf.params.hasKey("target"): kf.params["target"].getStr else: ""
      let button = if kf.params.hasKey("button"): kf.params["button"].getStr else: "left"
      result.add driver.emitClick(target, kf.time, button = button)
    of "scroll":
      let target = if kf.params.hasKey("target"): kf.params["target"].getStr else: ""
      let dy =
        if kf.params.hasKey("deltaY"):
          case kf.params["deltaY"].kind
          of JFloat: kf.params["deltaY"].getFloat
          of JInt:   float(kf.params["deltaY"].getInt)
          else:      0.0
        else: 0.0
      result.add driver.emitScroll(target, dy, kf.time)
    of "type_text":
      let target = if kf.params.hasKey("target"): kf.params["target"].getStr else: ""
      let text = if kf.params.hasKey("text"): kf.params["text"].getStr else: ""
      let wpm =
        if kf.params.hasKey("wpm"):
          case kf.params["wpm"].kind
          of JInt: int(kf.params["wpm"].getInt)
          of JFloat: int(kf.params["wpm"].getFloat)
          else: 0
        else: 0
      result.add driver.emitType(target, text, kf.time, wpm = wpm)
    of "navigate":
      let url = if kf.params.hasKey("url"): kf.params["url"].getStr else: driver.baseUrl
      result.add driver.emitNavigate(url, kf.time)
    else:
      # Non-browser actions are silently ignored — the PTY/VS Code drivers
      # handle them.
      discard

# ===========================================================================
# PTY Driver
# ===========================================================================

type
  PtyDriver* = object
    pty*: PtyPair
    startMono*: MonoTime
    outputBuf*: string

proc newPtyDriver*(argv: openArray[string]): PtyDriver =
  result = PtyDriver(
    pty: openPtyPair(),
    outputBuf: "",
  )
  spawnInPty(result.pty, argv)

proc drainOutput*(driver: var PtyDriver) =
  ## Pull any data currently waiting on the master fd and append it to the
  ## driver's running buffer. Idempotent; safe to call frequently.
  let chunk = readPtyAvailable(driver.pty)
  if chunk.len > 0:
    driver.outputBuf.add chunk

proc output*(driver: PtyDriver): string =
  driver.outputBuf

proc waitForByteCount*(driver: var PtyDriver; minBytes: int; timeoutMs: int): bool =
  ## Pump output until at least `minBytes` total bytes have been read from
  ## the child, or `timeoutMs` elapses.
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while driver.outputBuf.len < minBytes:
    driver.drainOutput()
    if driver.outputBuf.len >= minBytes:
      return true
    if getMonoTime() >= deadline:
      return false
    sleep(1)
  return true

proc waitForSubstring*(driver: var PtyDriver; needle: string;
                       startOffset: int; timeoutMs: int): int =
  ## Block until `needle` appears in the output buffer starting at or after
  ## `startOffset`. Returns the index where it was found, or -1 on timeout.
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while true:
    driver.drainOutput()
    let i = driver.outputBuf.find(needle, start = startOffset)
    if i >= 0:
      return i
    if getMonoTime() >= deadline:
      return -1
    sleep(1)

proc closeDriver*(driver: var PtyDriver) =
  closePty(driver.pty)

proc fireKeyframe(driver: var PtyDriver, kf: Keyframe) =
  ## Translate one keyframe into bytes written to the PTY master.
  case kf.action
  of "type_text":
    if kf.params.hasKey("text"):
      driver.pty.writePty(kf.params["text"].getStr)
  of "hot_key":
    # Translate {Cmd|Ctrl}+<char> into the literal control byte where it
    # makes sense (Ctrl+C → 0x03 etc.). The exact OS-level binding is the
    # responsibility of higher layers; this is sufficient for shell driving.
    if kf.params.hasKey("keys") and kf.params["keys"].kind == JArray:
      var hasMod = false
      var key = ""
      for k in kf.params["keys"].elems:
        let s = k.getStr.toLowerAscii
        if s in ["ctrl", "cmd", "control"]:
          hasMod = true
        else:
          key = s
      if hasMod and key.len == 1 and key[0] in {'a' .. 'z'}:
        let ctrlByte = char(ord(key[0]) - ord('a') + 1)
        driver.pty.writePty($ctrlByte)
      elif key == "enter":
        driver.pty.writePty("\n")
      elif key == "tab":
        driver.pty.writePty("\t")
  of "move_cursor":
    # No-op in the PTY driver — provided so that mixed scripts can be
    # consumed without errors. Higher-level drivers (browser / VS Code)
    # interpret cursor movement.
    discard
  else:
    discard

proc playScriptOnPty*(driver: var PtyDriver, script: Script): seq[ActionEvent] =
  ## Drive the PTY-attached child process according to `script`. Returns a
  ## list of execution events with measured drift relative to schedule.
  result = @[]
  driver.startMono = getMonoTime()
  for i, kf in script.timeline:
    let targetMs = int(round(kf.time * 1000.0))
    while true:
      let elapsedMs = inMilliseconds(getMonoTime() - driver.startMono)
      let remaining = targetMs - int(elapsedMs)
      if remaining <= 0:
        break
      # Tight wait near the deadline to minimise drift.
      if remaining > 4:
        sleep(remaining - 2)
      else:
        # Spin for the last few ms.
        discard
    let actualOffset = float(inMicroseconds(getMonoTime() - driver.startMono)) / 1_000_000.0
    fireKeyframe(driver, kf)
    result.add ActionEvent(
      keyframeIndex: i,
      scheduledOffset: kf.time,
      actualOffset: actualOffset,
      drift: actualOffset - kf.time,
      action: kf.action,
    )

# ===========================================================================
# VS Code TCP Client
# ===========================================================================

type
  VsCodeClient* = object
    host*: string
    port*: Port
    socket*: Socket
    connected*: bool

proc newVsCodeClient*(host = "127.0.0.1"; port = 7117): VsCodeClient =
  VsCodeClient(host: host, port: Port(port), socket: nil, connected: false)

proc connect*(client: var VsCodeClient; timeoutMs = 2000) =
  client.socket = newSocket()
  client.socket.connect(client.host, client.port, timeout = timeoutMs)
  client.connected = true

proc sendCommand*(client: var VsCodeClient; command: string;
                  params: JsonNode = newJObject()): JsonNode =
  ## Send a single command. Each frame is one JSON object terminated by `\n`.
  if not client.connected:
    client.connect()
  let payload = %* {
    "command": command,
    "params": params,
  }
  let wire = $payload & "\n"
  client.socket.send(wire)
  return payload

proc close*(client: var VsCodeClient) =
  if client.connected and client.socket != nil:
    client.socket.close()
    client.connected = false

proc scriptToVsCodeCommands*(client: VsCodeClient; script: Script): seq[JsonNode] =
  ## Compile a `Script` into the JSON command payloads that would be sent to
  ## the VS Code server, without actually sending them. Useful for golden
  ## tests and tooling that wants to inspect the trace.
  result = @[]
  for kf in script.timeline:
    case kf.action
    of "open_file", "set_breakpoint", "step_over", "launch_app", "focus_window":
      let payload = %* {
        "command": kf.action,
        "params": kf.params,
        "at": kf.time,
      }
      result.add payload
    else:
      discard
