## VS Code driver test — assert the client emits a well-formed JSON command
## frame over a real TCP socket to a test listener.

import std/[asyncdispatch, asyncnet, json, net, strutils, unittest]
import ../src/gui_assert/driver

proc pickFreePort(): Port =
  let s = newSocket()
  s.bindAddr(Port(0), "127.0.0.1")
  let p = s.getLocalAddr()[1]
  s.close()
  return p

proc receiveOneFrame(server: AsyncSocket): Future[string] {.async.} =
  let client = await server.accept()
  var buffer = ""
  while true:
    let chunk = await client.recv(1024)
    if chunk.len == 0:
      break
    buffer.add chunk
    if '\n' in buffer:
      break
  client.close()
  return buffer

suite "VS Code TCP client":

  test "sends a single command frame to a real TCP listener":
    let port = pickFreePort()
    let server = newAsyncSocket()
    server.setSockOpt(OptReuseAddr, true)
    server.bindAddr(port, "127.0.0.1")
    server.listen()

    let acceptFut = receiveOneFrame(server)

    var client = newVsCodeClient(host = "127.0.0.1", port = int(port))
    client.connect()
    let sent = client.sendCommand(
      "open_file",
      %* { "path": "src/main.nim", "line": 42 },
    )
    client.close()

    # Pump the event loop until the server returns the assembled frame.
    let frame = waitFor acceptFut
    server.close()

    check frame.endsWith("\n")
    let trimmed = frame.strip()
    let parsed = parseJson(trimmed)
    check parsed["command"].getStr == "open_file"
    check parsed["params"]["path"].getStr == "src/main.nim"
    check parsed["params"]["line"].getInt == 42

    # The client must have returned the same payload it put on the wire.
    check sent["command"].getStr == parsed["command"].getStr
    check $sent["params"] == $parsed["params"]
