## Appium WebDriver client tests.
##
## The default suite runs against an in-process mock HTTP server (built
## from `std/net` sockets) running on a worker thread. The mock records
## every request the client makes so we can assert on the exact
## request shape (method, URL path, body) without requiring the user
## to have a real Appium server running.
##
## A second suite, gated behind `-d:appiumLive`, talks to a real Appium
## server at `$APPIUM_URL` (or `http://127.0.0.1:4723` by default).

import std/[json, net, options, os, strutils, unittest]
import ../src/gui_assert/appium

# ---------------------------------------------------------------------------
# Capability shape — pure, no I/O
# ---------------------------------------------------------------------------

suite "appium capability rendering":

  test "Mac2 caps produce vendor-prefixed alwaysMatch":
    let caps = AppiumCapabilities(
      automationName: "Mac2",
      bundleId: some("com.apple.Terminal"),
      arguments: @["--login"])
    let body = newSessionRequestBody(caps)
    let always = body["capabilities"]["alwaysMatch"]
    check always["platformName"].getStr == "mac"
    check always["appium:automationName"].getStr == "Mac2"
    check always["appium:bundleId"].getStr == "com.apple.Terminal"
    check always["appium:arguments"].kind == JArray
    check always["appium:arguments"][0].getStr == "--login"

  test "Chromium caps include debuggerAddress under goog:chromeOptions":
    let caps = AppiumCapabilities(
      automationName: "Chromium",
      debuggerAddress: some("127.0.0.1:9223"))
    let body = newSessionRequestBody(caps)
    let always = body["capabilities"]["alwaysMatch"]
    check always["appium:automationName"].getStr == "Chromium"
    check always["goog:chromeOptions"]["debuggerAddress"].getStr ==
      "127.0.0.1:9223"

# ---------------------------------------------------------------------------
# Mock HTTP server on a background thread.
# We deliberately avoid `std/asynchttpserver`: the client uses the
# synchronous `httpclient` API, and mixing the two in the same thread
# deadlocks (the async accept loop never runs while the sync client
# blocks waiting for a response). A dedicated worker thread that
# speaks raw HTTP is simpler and sidesteps the issue.
# ---------------------------------------------------------------------------

type
  Recorded* = object
    verb*: string
    path*: string
    body*: string

  MockState = object
    sock: Socket
    port: int
    requests: seq[Recorded]
    stopping: bool

var mockState {.threadvar.}: ptr MockState

proc readLineSocket(client: Socket): string =
  ## Read a single CRLF-terminated line from the socket.
  result = ""
  while true:
    var ch: char
    let n = client.recv(addr ch, 1)
    if n <= 0:
      return
    result.add ch
    if result.endsWith("\r\n"):
      return

proc recvExact(client: Socket, n: int): string =
  result = ""
  while result.len < n:
    var buf = newString(n - result.len)
    let got = client.recv(buf.cstring, buf.len)
    if got <= 0:
      return
    result.add buf[0 ..< got]

proc handleClient(state: ptr MockState, client: Socket) =
  ## Parse one HTTP/1.1 request and respond.  Keeps things minimal —
  ## just enough to record what the Appium client puts on the wire.
  let requestLine = readLineSocket(client).strip()
  if requestLine.len == 0:
    client.close()
    return
  let parts = requestLine.splitWhitespace()
  if parts.len < 2:
    client.close()
    return
  let verb = parts[0]
  let path = parts[1]
  var contentLength = 0
  while true:
    let header = readLineSocket(client)
    let trimmed = header.strip()
    if trimmed.len == 0:
      break
    if trimmed.toLowerAscii().startsWith("content-length:"):
      let v = trimmed.split(':')[1].strip()
      try: contentLength = parseInt(v) except ValueError: discard
  let body =
    if contentLength > 0: recvExact(client, contentLength)
    else: ""
  state[].requests.add Recorded(verb: verb, path: path, body: body)

  var status = "200 OK"
  var respBody = """{"value":null}"""
  if path == "/session" and verb == "POST":
    respBody = """{"value":{"sessionId":"mock-sess-1","capabilities":{}}}"""
  elif path.endsWith("/element") and verb == "POST":
    respBody = """{"value":{"element-6066-11e4-a52e-4f735466cecf":"elem-42"}}"""
  elif (path.endsWith("/click") or path.endsWith("/value") or
        path.endsWith("/execute/sync")) and verb == "POST":
    respBody = """{"value":null}"""
  elif verb == "DELETE" and path.startsWith("/session/"):
    respBody = """{"value":null}"""

  let response = "HTTP/1.1 " & status & "\r\n" &
                 "Content-Type: application/json\r\n" &
                 "Content-Length: " & $respBody.len & "\r\n" &
                 "Connection: close\r\n\r\n" & respBody
  client.send(response)
  client.close()

proc mockServerThread(state: ptr MockState) {.thread.} =
  while not state[].stopping:
    try:
      var client: Socket
      state[].sock.accept(client)
      handleClient(state, client)
    except OSError:
      break

proc pickFreePort(): int =
  let s = newSocket()
  s.bindAddr(Port(0), "127.0.0.1")
  let p = s.getLocalAddr()[1]
  s.close()
  return int(p)

proc startMockServer(state: ptr MockState): Thread[ptr MockState] =
  let port = pickFreePort()
  state[].sock = newSocket()
  state[].sock.setSockOpt(OptReuseAddr, true)
  state[].sock.bindAddr(Port(port), "127.0.0.1")
  state[].sock.listen()
  state[].port = port
  state[].stopping = false
  state[].requests = @[]
  createThread(result, mockServerThread, state)

proc stopMockServer(state: ptr MockState, th: var Thread[ptr MockState]) =
  state[].stopping = true
  try: state[].sock.close() except CatchableError: discard
  # The accept call will fail with OSError and the thread exits.
  joinThread(th)

suite "appium HTTP wire protocol against mock server":

  test "newSession sends POST /session with W3C body and stores returned id":
    var state = MockState()
    var th = startMockServer(addr state)
    defer: stopMockServer(addr state, th)

    let caps = AppiumCapabilities(
      automationName: "Mac2",
      bundleId: some("com.apple.Terminal"))
    let session = newAppiumSession(
      serverUrl = "http://127.0.0.1:" & $state.port,
      caps = caps)
    check session.sessionId == "mock-sess-1"
    check state.requests.len >= 1
    let r = state.requests[0]
    check r.verb == "POST"
    check r.path == "/session"
    let parsed = parseJson(r.body)
    check parsed["capabilities"]["alwaysMatch"]["appium:automationName"].getStr ==
      "Mac2"
    check parsed["capabilities"]["alwaysMatch"]["appium:bundleId"].getStr ==
      "com.apple.Terminal"
    session.terminateSession()

  test "findElement / click / sendKeys hit the correct paths":
    var state = MockState()
    var th = startMockServer(addr state)
    defer: stopMockServer(addr state, th)

    let caps = AppiumCapabilities(automationName: "Mac2")
    let session = newAppiumSession("http://127.0.0.1:" & $state.port, caps)
    let elem = session.findElement("accessibility id", "Save")
    check elem == "elem-42"
    session.click(elem)
    session.sendKeys(elem, "hello")
    check state.requests.len >= 4
    check state.requests[1].path == "/session/mock-sess-1/element"
    let findBody = parseJson(state.requests[1].body)
    check findBody["using"].getStr == "accessibility id"
    check findBody["value"].getStr == "Save"
    check state.requests[2].path == "/session/mock-sess-1/element/elem-42/click"
    check state.requests[3].path == "/session/mock-sess-1/element/elem-42/value"
    let sendBody = parseJson(state.requests[3].body)
    check sendBody["text"].getStr == "hello"
    check sendBody["value"].len == "hello".len
    session.terminateSession()

  test "setWindowBounds invokes execute/sync with the mac2 mobile command":
    var state = MockState()
    var th = startMockServer(addr state)
    defer: stopMockServer(addr state, th)

    let caps = AppiumCapabilities(automationName: "Mac2")
    let session = newAppiumSession("http://127.0.0.1:" & $state.port, caps)
    session.setWindowBounds(100, 200, 800, 600)
    check state.requests.len >= 2
    check state.requests[1].path == "/session/mock-sess-1/execute/sync"
    let body = parseJson(state.requests[1].body)
    check body["script"].getStr == "mobile: setWindowBounds"
    let args = body["args"]
    check args.len == 1
    check args[0]["x"].getInt == 100
    check args[0]["y"].getInt == 200
    check args[0]["width"].getInt == 800
    check args[0]["height"].getInt == 600
    session.terminateSession()

  test "setWindowBounds raises on non-Mac2 automation":
    var state = MockState()
    var th = startMockServer(addr state)
    defer: stopMockServer(addr state, th)
    let caps = AppiumCapabilities(automationName: "Chromium")
    let session = newAppiumSession("http://127.0.0.1:" & $state.port, caps)
    expect AppiumError:
      session.setWindowBounds(0, 0, 100, 100)
    session.terminateSession()

# ---------------------------------------------------------------------------
# Live suite — gated behind -d:appiumLive
# ---------------------------------------------------------------------------

when defined(appiumLive):
  suite "appium live (requires real Appium server)":

    test "opens a Terminal session via mac2 and terminates cleanly":
      let url =
        if getEnv("APPIUM_URL").len > 0: getEnv("APPIUM_URL")
        else: DefaultAppiumServerUrl
      let caps = AppiumCapabilities(
        automationName: "Mac2",
        bundleId: some("com.apple.Terminal"))
      let session = newAppiumSession(url, caps)
      check session.sessionId.len > 0
      session.terminateSession()
      check session.sessionId.len == 0
