## A minimal RFB (VNC) client for the session live suite: it reads one whole
## framebuffer from a server, so a test can check that a session's VNC
## endpoint serves THAT session's pixels (GS10,
## test_session_vnc_endpoint_is_loopback_only).
##
## The protocol is RFC 6143 (https://www.rfc-editor.org/rfc/rfc6143): the
## ProtocolVersion handshake at 3.8 (§7.1.1), security type None (§7.1.2,
## §7.2.1, with the SecurityResult 3.8 sends for it, §7.1.3), ClientInit /
## ServerInit (§7.3), then SetPixelFormat to 32-bit true colour (§7.5.1),
## SetEncodings with Raw only (§7.5.2, §7.7.1) and one non-incremental
## FramebufferUpdateRequest (§7.5.3), whose FramebufferUpdate rectangles
## (§7.6.1) are painted into the frame until the whole screen is covered.
## Other server messages (SetColorMapEntries, Bell, ServerCutText, §7.6.2-4)
## are read and dropped.
##
## Test code only: it trusts nothing it reads (every length is bounded) but
## implements no more of the protocol than a test needs.

import std/[net, strutils, times]

type
  RfbFrame* = object
    width*, height*: int
    name*: string
    rgb*: seq[uint8]       ## width * height * 3, row-major

  RfbError* = object of CatchableError

const maxSide = 16384

proc fail(msg: string) {.noreturn.} =
  raise newException(RfbError, msg)

proc readExact(s: Socket, n: int, deadline: float): string =
  while result.len < n:
    let left = int((deadline - epochTime()) * 1000)
    if left <= 0: fail("the server sent " & $result.len & " of " & $n & " bytes in time")
    let chunk = s.recv(min(n - result.len, 1 shl 20), left)
    if chunk.len == 0: fail("the server closed the connection")
    result.add chunk

proc u8(s: string, i: int): int = ord(s[i])
proc u16(s: string, i: int): int = (ord(s[i]) shl 8) or ord(s[i + 1])
proc u32(s: string, i: int): int =
  (ord(s[i]) shl 24) or (ord(s[i + 1]) shl 16) or (ord(s[i + 2]) shl 8) or ord(s[i + 3])

proc be16(v: int): string = char((v shr 8) and 0xFF) & char(v and 0xFF)
proc be32(v: int): string =
  char((v shr 24) and 0xFF) & char((v shr 16) and 0xFF) & char((v shr 8) and 0xFF) &
    char(v and 0xFF)

proc readFrame*(host: string, port: int, timeoutMs = 15_000): RfbFrame =
  ## One whole framebuffer of the server at `host`:`port`.
  let deadline = epochTime() + timeoutMs / 1000
  let s = newSocket()
  try:
    s.connect(host, Port(port), timeoutMs)
    let version = s.readExact(12, deadline)
    if not version.startsWith("RFB 003."): fail("not an RFB server: " & version.escape)
    s.send("RFB 003.008\n")
    let n = u8(s.readExact(1, deadline), 0)
    if n == 0:
      let reason = s.readExact(4, deadline)
      fail("the server refused the connection: " &
           s.readExact(min(u32(reason, 0), 4096), deadline))
    let types = s.readExact(n, deadline)
    if '\x01' notin types: fail("the server offers no None security type")
    s.send("\x01")
    if u32(s.readExact(4, deadline), 0) != 0: fail("the server failed the None security")
    s.send("\x01")                                   # ClientInit: shared
    let init = s.readExact(24, deadline)
    result.width = u16(init, 0)
    result.height = u16(init, 2)
    if result.width <= 0 or result.height <= 0 or result.width > maxSide or
       result.height > maxSide:
      fail("implausible framebuffer size " & $result.width & "x" & $result.height)
    result.name = s.readExact(min(u32(init, 20), 4096), deadline)
    # 32 bpp, depth 24, little-endian, true colour, 8 bits per channel, red
    # at bit 16, green at 8, blue at 0: pixels arrive as B, G, R, X.
    s.send("\x00\x00\x00\x00" & "\x20\x18\x00\x01" & be16(255) & be16(255) & be16(255) &
           "\x10\x08\x00" & "\x00\x00\x00")
    s.send("\x02\x00" & be16(1) & be32(0))          # SetEncodings: Raw
    s.send("\x03\x00" & be16(0) & be16(0) & be16(result.width) & be16(result.height))
    result.rgb = newSeq[uint8](result.width * result.height * 3)
    var covered = 0
    let total = result.width * result.height
    while covered < total:
      let kind = u8(s.readExact(1, deadline), 0)
      case kind
      of 0:                                           # FramebufferUpdate
        let head = s.readExact(3, deadline)
        let rects = u16(head, 1)
        for _ in 1 .. rects:
          let r = s.readExact(12, deadline)
          let (x, y, w, h) = (u16(r, 0), u16(r, 2), u16(r, 4), u16(r, 6))
          let enc = u32(r, 8)
          if enc != 0: fail("the server sent encoding " & $enc & ", not Raw")
          if x + w > result.width or y + h > result.height:
            fail("a rectangle outside the framebuffer")
          let px = s.readExact(w * h * 4, deadline)
          for row in 0 ..< h:
            for col in 0 ..< w:
              let src = (row * w + col) * 4
              let dst = ((y + row) * result.width + x + col) * 3
              result.rgb[dst] = uint8(ord(px[src + 2]))
              result.rgb[dst + 1] = uint8(ord(px[src + 1]))
              result.rgb[dst + 2] = uint8(ord(px[src]))
          covered += w * h
      of 1:                                           # SetColorMapEntries
        let head = s.readExact(5, deadline)
        discard s.readExact(u16(head, 3) * 6, deadline)
      of 2: discard                                   # Bell
      of 3:                                           # ServerCutText
        let head = s.readExact(7, deadline)
        discard s.readExact(min(u32(head, 3), 1 shl 20), deadline)
      else: fail("unknown server message " & $kind)
  finally:
    s.close()

proc pixel*(f: RfbFrame, x, y: int): array[3, int] =
  let o = (y * f.width + x) * 3
  [int(f.rgb[o]), int(f.rgb[o + 1]), int(f.rgb[o + 2])]
