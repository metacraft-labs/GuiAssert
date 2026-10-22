## A small, dependency-free D-Bus client: the wire protocol over a Unix
## socket, as the `linux-atspi` tree backend needs it.
##
## GuiAssert talks to AT-SPI (the Linux accessibility bus) directly in the
## D-Bus wire format rather than through libatspi or libdbus, so the
## `guiassert` binary links no extra library, loads none at run time, and
## reads every value fresh from the application (libatspi caches names,
## roles and states and keeps them current only while a GLib main loop
## dispatches its events, which a one-shot CLI never runs). What is
## implemented is the client half of the specification that a method-call
## client uses:
##
## * **Addresses** (`unix:path=…`, `unix:abstract=…`, with `;`-separated
##   alternatives and `%`-escaped values; the other transports are refused).
## * **Authentication** with the `EXTERNAL` mechanism (the peer credentials
##   of the socket), sending the uid as the initial response.
## * **Messages**: method calls out, method returns and errors in, in either
##   byte order; signals and calls addressed to this client are read and
##   dropped (it subscribes to nothing). Calls may be pipelined: `send`
##   several, then `reply` to each.
## * **Marshalling** of every type of the type system except Unix file
##   descriptors (`h`): this client never negotiates fd passing
##   (`NEGOTIATE_UNIX_FD`), so a message that carries `h` or a non-zero
##   `UNIX_FDS` header field is malformed here.
##
## **Untrusted input.** Every byte read is treated as hostile: other
## processes (any application on the bus) can address messages to this
## client, and `AT_SPI_BUS_ADDRESS` may name any socket. A message is refused
## with `DbusError`, never a crash, a hang or unbounded memory, when it breaks
## the specification's marshalling rules: lengths beyond the data or beyond
## the message (2^27) and array (2^26) limits; non-zero padding; booleans
## other than 0 / 1; strings that are not valid UTF-8, hold a NUL or lack
## their terminating NUL; invalid object paths and signatures; nesting
## deeper than 64; header fields of the wrong type; a missing required
## header field; serial 0. Beyond the specification, one message may decode
## into at most `maxValues` values (so a 2^26-byte array of bytes cannot
## become tens of millions of heap objects), and a message that is not the
## answer to a call in flight is dropped after its header, its body never
## decoded. The first malformed message closes the connection: a byte
## stream cannot be resynchronised after one.
##
## Every read and write is bounded by a deadline, and a `checkpoint` callback
## runs at least every 50 ms while waiting, so a cancelled verb or an expired
## `--timeout-ms` interrupts a call to a hung application.
##
## D-Bus specification: https://dbus.freedesktop.org/doc/dbus-specification.html
## (§ "Type System", "Message Protocol", "Authentication Protocol",
## "Server Addresses").

import std/[monotimes, posix, sets, strutils, tables, times]

type
  DbusError* = object of CatchableError
    ## The transport or the protocol failed: no connection, a refused
    ## authentication, a malformed message, a closed socket.

  DbusTimeoutError* = object of DbusError
    ## No reply arrived before the call's deadline.

  DbusCallError* = object of DbusError
    ## The peer answered a call with an error reply. `name` is its D-Bus
    ## error name (`org.freedesktop.DBus.Error.UnknownMethod`, …).
    errorName*: string

  DKind* = enum
    dkByte = "y", dkBool = "b", dkInt16 = "n", dkUint16 = "q", dkInt32 = "i",
    dkUint32 = "u", dkInt64 = "x", dkUint64 = "t", dkDouble = "d",
    dkString = "s", dkObjectPath = "o", dkSignature = "g", dkArray = "a",
    dkStruct = "(", dkVariant = "v", dkDictEntry = "{"

  DValue* = object
    ## One D-Bus value. `sig` is its complete type signature.
    sig*: string
    case kind*: DKind
    of dkByte, dkBool, dkInt16, dkUint16, dkInt32, dkUint32, dkInt64, dkUint64:
      num*: int64
      unum*: uint64
    of dkDouble:
      dbl*: float64
    of dkString, dkObjectPath, dkSignature:
      str*: string
    of dkArray, dkStruct, dkDictEntry:
      items*: seq[DValue]   ## array elements, or struct / dict-entry fields
    of dkVariant:
      inner*: seq[DValue]   ## exactly one value

  MessageType* = enum
    mtInvalid = 0, mtMethodCall = 1, mtMethodReturn = 2, mtError = 3, mtSignal = 4

  Message* = object
    ## A received message.
    kind*: MessageType
    flags*: uint8
    serial*: uint32
    replySerial*: uint32
    path*, iface*, member*, errorName*, destination*, sender*, signature*: string
    body*: seq[DValue]

  DbusConnection* = ref object
    ## An authenticated connection to a bus. Not thread-safe.
    fd: cint
    serial: uint32
    inbuf: string
    replies: Table[uint32, Message]
    pending: HashSet[uint32]      ## serials sent whose answer has not arrived
    uniqueName*: string           ## this connection's unique name on the bus
    checkpoint*: proc () {.closure.}
      ## Called at least every 50 ms while a call waits; it raises to abort
      ## (cancellation, the verb's deadline). Nil: never called.

const
  maxMessageBytes = 134_217_728   ## 2^27, the specification's maximum
  maxArrayBytes = 67_108_864      ## 2^26
  maxDepth = 64                   ## nesting bound (the spec's 32 + 32)
  maxValues* = 1_048_576
    ## The most values one received message may decode into. Each is a heap
    ## object of about 100 bytes, so this bounds a decoded message near
    ## 100 MB; AT-SPI's largest answers (the children of a big table) hold a
    ## few values per child.
  flagNoReplyExpected* = 0x1'u8
  flagNoAutoStart* = 0x2'u8
    ## The bus must not start a service to deliver the call: a call to a name
    ## nobody owns fails with `ServiceUnknown` instead of activating one.

# ---------------------------------------------------------------------------
# Values
# ---------------------------------------------------------------------------

proc dbyte*(v: uint8): DValue = DValue(sig: "y", kind: dkByte, num: int64(v), unum: uint64(v))
proc dbool*(v: bool): DValue = DValue(sig: "b", kind: dkBool, num: ord(v), unum: uint64(ord(v)))
proc dint32*(v: int32 | int): DValue =
  DValue(sig: "i", kind: dkInt32, num: int64(v), unum: cast[uint64](int64(v)))
proc duint32*(v: uint32 | int): DValue =
  DValue(sig: "u", kind: dkUint32, num: int64(v), unum: uint64(v))
proc ddouble*(v: float64): DValue = DValue(sig: "d", kind: dkDouble, dbl: v)
proc dstr*(v: string): DValue = DValue(sig: "s", kind: dkString, str: v)
proc dpath*(v: string): DValue = DValue(sig: "o", kind: dkObjectPath, str: v)
proc dsig*(v: string): DValue = DValue(sig: "g", kind: dkSignature, str: v)
proc dvariant*(v: DValue): DValue = DValue(sig: "v", kind: dkVariant, inner: @[v])
proc dstruct*(fields: varargs[DValue]): DValue =
  var s = "("
  for f in fields: s.add f.sig
  DValue(sig: s & ")", kind: dkStruct, items: @fields)
proc darray*(elemSig: string, items: seq[DValue] = @[]): DValue =
  DValue(sig: "a" & elemSig, kind: dkArray, items: items)

proc asInt*(v: DValue): int64 =
  ## The value of an integer-typed `v`. Raises `DbusError` for another type.
  if v.kind notin {dkByte, dkBool, dkInt16, dkUint16, dkInt32, dkUint32, dkInt64, dkUint64}:
    raise newException(DbusError, "expected an integer, got type " & v.sig)
  v.num

proc asStr*(v: DValue): string =
  ## The text of a string, object path or signature `v`, looking through a
  ## variant. Raises `DbusError` for another type.
  if v.kind == dkVariant: return v.inner[0].asStr
  if v.kind notin {dkString, dkObjectPath, dkSignature}:
    raise newException(DbusError, "expected a string, got type " & v.sig)
  v.str

proc elems*(v: DValue): seq[DValue] =
  ## The elements of an array `v`, or the fields of a struct or dict entry,
  ## looking through a variant. Raises `DbusError` for another type, so a
  ## peer that answers with an unexpected type is an error, never an
  ## access to a field the value does not have.
  let u = if v.kind == dkVariant: v.inner[0] else: v
  if u.kind == dkVariant: return u.elems
  if u.kind notin {dkArray, dkStruct, dkDictEntry}:
    raise newException(DbusError, "expected an array or a struct, got type " & u.sig)
  u.items

proc unwrap*(v: DValue): DValue =
  ## `v` without any variant wrapping.
  result = v
  while result.kind == dkVariant: result = result.inner[0]

proc asFloat*(v: DValue): float64 =
  ## A numeric `v` as a float, looking through a variant.
  let u = v.unwrap
  if u.kind == dkDouble: u.dbl
  else: float64(u.asInt)

# ---------------------------------------------------------------------------
# Signatures
# ---------------------------------------------------------------------------

proc completeType(sig: string, pos: var int, depth = 0): string =
  ## The single complete type at `sig[pos]`, advancing `pos` past it.
  ## Raises `DbusError` for a malformed signature.
  if depth > maxDepth: raise newException(DbusError, "signature nests too deeply")
  if pos >= sig.len: raise newException(DbusError, "truncated signature '" & sig & "'")
  let start = pos
  let c = sig[pos]
  inc pos
  case c
  of 'y', 'b', 'n', 'q', 'i', 'u', 'x', 't', 'd', 's', 'o', 'g', 'v', 'h': discard
  of 'a': discard completeType(sig, pos, depth + 1)
  of '(':
    if pos < sig.len and sig[pos] == ')': raise newException(DbusError, "empty struct in signature")
    while pos < sig.len and sig[pos] != ')': discard completeType(sig, pos, depth + 1)
    if pos >= sig.len: raise newException(DbusError, "unterminated struct in '" & sig & "'")
    inc pos
  of '{':
    if start == 0 or sig[start - 1] != 'a':
      raise newException(DbusError, "dict entry outside an array in '" & sig & "'")
    let key = completeType(sig, pos, depth + 1)
    if key[0] notin {'y', 'b', 'n', 'q', 'i', 'u', 'x', 't', 'd', 's', 'o', 'g', 'h'}:
      raise newException(DbusError, "dict key of non-basic type in '" & sig & "'")
    discard completeType(sig, pos, depth + 1)
    if pos >= sig.len or sig[pos] != '}':
      raise newException(DbusError, "malformed dict entry in '" & sig & "'")
    inc pos
  else:
    raise newException(DbusError, "invalid type code '" & c & "' in signature '" & sig & "'")
  sig[start ..< pos]

proc splitSignature*(sig: string): seq[string] =
  ## The complete types of a signature, in order. Raises `DbusError` for a
  ## malformed one.
  var pos = 0
  while pos < sig.len: result.add completeType(sig, pos)

proc validUtf8*(s: string): bool =
  ## Whether `s` is a valid D-Bus string: well-formed UTF-8 (RFC 3629: no
  ## overlong forms, no surrogates, nothing beyond U+10FFFF) without NUL.
  var i = 0
  while i < s.len:
    let c = ord(s[i])
    if c == 0: return false
    if c < 0x80:
      inc i
      continue
    var n, cp, lowest: int
    if c in 0xC2 .. 0xDF: (n = 1; cp = c and 0x1F; lowest = 0x80)
    elif c in 0xE0 .. 0xEF: (n = 2; cp = c and 0x0F; lowest = 0x800)
    elif c in 0xF0 .. 0xF4: (n = 3; cp = c and 0x07; lowest = 0x10000)
    else: return false
    if i + n >= s.len: return false
    for k in 1 .. n:
      let cc = ord(s[i + k])
      if (cc and 0xC0) != 0x80: return false
      cp = (cp shl 6) or (cc and 0x3F)
    if cp < lowest or cp > 0x10FFFF or cp in 0xD800 .. 0xDFFF: return false
    i += n + 1
  true

proc validObjectPath*(s: string): bool =
  ## Whether `s` is a valid object path: `/`, or `/` followed by
  ## `/`-separated non-empty elements of `[A-Za-z0-9_]`, no trailing `/`.
  if s.len == 0 or s[0] != '/': return false
  if s.len == 1: return true
  if s[^1] == '/': return false
  for i in 1 ..< s.len:
    let c = s[i]
    if c == '/':
      if s[i - 1] == '/': return false
    elif c notin {'A'..'Z', 'a'..'z', '0'..'9', '_'}: return false
  true

proc validSignature(s: string): bool =
  ## Whether `s` is a valid signature: at most 255 bytes of complete types.
  if s.len > 255: return false
  try: discard splitSignature(s)
  except DbusError: return false
  true

proc alignOf(code: char): int =
  case code
  of 'y', 'g', 'v': 1
  of 'n', 'q': 2
  of 'b', 'i', 'u', 's', 'o', 'a', 'h': 4
  of 'x', 't', 'd', '(', '{': 8
  else: 1

# ---------------------------------------------------------------------------
# Marshalling (always little-endian out)
# ---------------------------------------------------------------------------

proc pad(buf: var string, alignment: int) =
  while buf.len mod alignment != 0: buf.add '\0'

proc putU32(buf: var string, v: uint32) =
  for i in 0 .. 3: buf.add char((v shr (8 * i)) and 0xff)

proc putU64(buf: var string, v: uint64) =
  for i in 0 .. 7: buf.add char((v shr (8 * i)) and 0xff)

proc marshal(buf: var string, sig: string, v: DValue, depth = 0) =
  ## Append `v`, of complete type `sig`, to `buf`. Positions are relative to
  ## the start of `buf`, which is the start of the message.
  if depth > maxDepth: raise newException(DbusError, "value nests too deeply")
  let code = sig[0]
  buf.pad(alignOf(code))
  case code
  of 'y': buf.add char(v.unum and 0xff)
  of 'b': buf.putU32(if v.unum != 0: 1'u32 else: 0'u32)
  of 'n', 'q':
    let u = cast[uint64](v.num)
    buf.add char(u and 0xff)
    buf.add char((u shr 8) and 0xff)
  of 'i', 'u': buf.putU32(uint32(cast[uint64](v.num) and 0xffff_ffff'u64))
  of 'x', 't': buf.putU64(cast[uint64](v.num))
  of 'd': buf.putU64(cast[uint64](v.dbl))
  of 's', 'o':
    # The bus disconnects a client that sends an invalid string, so one is
    # refused here instead (a value to set may come from the caller).
    if '\0' in v.str: raise newException(DbusError, "a string holds a NUL byte")
    if code == 's' and not validUtf8(v.str):
      raise newException(DbusError, "a string is not valid UTF-8")
    if code == 'o' and not validObjectPath(v.str):
      raise newException(DbusError, "invalid object path")
    if v.str.len > maxArrayBytes: raise newException(DbusError, "string too long")
    buf.putU32(uint32(v.str.len))
    buf.add v.str
    buf.add '\0'
  of 'g':
    if not validSignature(v.str): raise newException(DbusError, "invalid signature")
    buf.add char(v.str.len)
    buf.add v.str
    buf.add '\0'
  of 'v':
    let inner = v.inner[0]
    if not validSignature(inner.sig) or splitSignature(inner.sig).len != 1:
      raise newException(DbusError, "a variant's value is not of one complete type")
    buf.add char(inner.sig.len)
    buf.add inner.sig
    buf.add '\0'
    buf.marshal(inner.sig, inner, depth + 1)
  of 'a':
    var p = 1
    let elem = completeType(sig, p)
    let lenAt = buf.len
    buf.putU32(0)
    buf.pad(alignOf(elem[0]))
    let start = buf.len
    for it in v.items: buf.marshal(elem, it, depth + 1)
    let n = buf.len - start
    if n > maxArrayBytes: raise newException(DbusError, "array too large")
    for i in 0 .. 3: buf[lenAt + i] = char((uint32(n) shr (8 * i)) and 0xff)
  of '(', '{':
    var p = 1
    var i = 0
    while sig[p] notin {')', '}'}:
      let t = completeType(sig, p)
      if i >= v.items.len: raise newException(DbusError, "struct value has too few fields for " & sig)
      buf.marshal(t, v.items[i], depth + 1)
      inc i
  else:
    raise newException(DbusError, "cannot marshal type '" & code & "'")

# ---------------------------------------------------------------------------
# Unmarshalling (either byte order)
# ---------------------------------------------------------------------------

type Reader = object
  data: string
  pos: int
  big: bool
  values: int   ## values decoded so far (bounded by `maxValues`)

proc need(r: Reader, n: int) =
  if n < 0 or r.pos + n > r.data.len: raise newException(DbusError, "truncated message")

proc nulTerminated(r: var Reader, n: int): string =
  ## The `n` bytes at the read position, which a NUL must follow; advances
  ## past the NUL.
  r.need(n + 1)
  if r.data[r.pos + n] != '\0': raise newException(DbusError, "string not NUL-terminated")
  result = r.data[r.pos ..< r.pos + n]
  r.pos += n + 1

proc align(r: var Reader, a: int) =
  while r.pos mod a != 0:
    r.need(1)
    if r.data[r.pos] != '\0': raise newException(DbusError, "non-zero padding")
    inc r.pos

proc getUint(r: var Reader, n: int): uint64 =
  r.need(n)
  for i in 0 ..< n:
    let b = uint64(ord(r.data[r.pos + i]))
    if r.big: result = (result shl 8) or b
    else: result = result or (b shl (8 * i))
  r.pos += n

proc unmarshal(r: var Reader, sig: string, depth = 0): DValue =
  if depth > maxDepth: raise newException(DbusError, "value nests too deeply")
  inc r.values
  if r.values > maxValues:
    raise newException(DbusError, "message holds more than " & $maxValues & " values")
  let code = sig[0]
  r.align(alignOf(code))
  case code
  of 'y':
    let u = r.getUint(1)
    result = DValue(sig: sig, kind: dkByte, num: int64(u), unum: u)
  of 'b':
    let u = r.getUint(4)
    if u > 1: raise newException(DbusError, "boolean out of range")
    result = DValue(sig: sig, kind: dkBool, num: int64(u), unum: u)
  of 'n':
    let u = r.getUint(2)
    result = DValue(sig: sig, kind: dkInt16, num: int64(cast[int16](uint16(u))), unum: u)
  of 'q':
    let u = r.getUint(2)
    result = DValue(sig: sig, kind: dkUint16, num: int64(u), unum: u)
  of 'i':
    let u = r.getUint(4)
    result = DValue(sig: sig, kind: dkInt32, num: int64(cast[int32](uint32(u))), unum: u)
  of 'h':
    raise newException(DbusError, "a Unix fd in a message, but fd passing was not negotiated")
  of 'u':
    let u = r.getUint(4)
    result = DValue(sig: "u", kind: dkUint32, num: int64(u), unum: u)
  of 'x':
    let u = r.getUint(8)
    result = DValue(sig: sig, kind: dkInt64, num: cast[int64](u), unum: u)
  of 't':
    let u = r.getUint(8)
    result = DValue(sig: sig, kind: dkUint64, num: cast[int64](u), unum: u)
  of 'd':
    result = DValue(sig: sig, kind: dkDouble, dbl: cast[float64](r.getUint(8)))
  of 's', 'o':
    let n = int(r.getUint(4))
    if n > maxMessageBytes: raise newException(DbusError, "string too long")
    let s = r.nulTerminated(n)
    if code == 's':
      if not validUtf8(s): raise newException(DbusError, "a string is not valid UTF-8")
      result = DValue(sig: sig, kind: dkString, str: s)
    else:
      if not validObjectPath(s): raise newException(DbusError, "invalid object path")
      result = DValue(sig: sig, kind: dkObjectPath, str: s)
  of 'g':
    let s = r.nulTerminated(int(r.getUint(1)))
    if not validSignature(s): raise newException(DbusError, "invalid signature")
    result = DValue(sig: sig, kind: dkSignature, str: s)
  of 'v':
    let inner = r.nulTerminated(int(r.getUint(1)))
    if not validSignature(inner) or splitSignature(inner).len != 1:
      raise newException(DbusError, "variant signature is not one complete type")
    result = DValue(sig: "v", kind: dkVariant, inner: @[r.unmarshal(inner, depth + 1)])
  of 'a':
    var p = 1
    let elem = completeType(sig, p)
    let n = int(r.getUint(4))
    if n > maxArrayBytes: raise newException(DbusError, "array too large")
    r.align(alignOf(elem[0]))
    r.need(n)
    let stop = r.pos + n
    result = DValue(sig: sig, kind: dkArray)
    while r.pos < stop: result.items.add r.unmarshal(elem, depth + 1)
    if r.pos != stop: raise newException(DbusError, "array length mismatch")
  of '(', '{':
    result = if code == '(': DValue(sig: sig, kind: dkStruct)
             else: DValue(sig: sig, kind: dkDictEntry)
    var p = 1
    while sig[p] notin {')', '}'}:
      let t = completeType(sig, p)
      result.items.add r.unmarshal(t, depth + 1)
  else:
    raise newException(DbusError, "cannot unmarshal type '" & code & "'")

# ---------------------------------------------------------------------------
# Messages
# ---------------------------------------------------------------------------

proc encodeCall*(serial: uint32, destination, path, iface, member: string,
                 args: openArray[DValue], flags = 0'u8): string =
  ## A method-call message, little-endian. `iface` may be empty.
  var sig = ""
  for a in args: sig.add a.sig
  var fields: seq[DValue]
  fields.add dstruct(dbyte(1), dvariant(dpath(path)))
  if iface.len > 0: fields.add dstruct(dbyte(2), dvariant(dstr(iface)))
  fields.add dstruct(dbyte(3), dvariant(dstr(member)))
  if destination.len > 0: fields.add dstruct(dbyte(6), dvariant(dstr(destination)))
  if sig.len > 0: fields.add dstruct(dbyte(8), dvariant(dsig(sig)))
  var body = ""
  # The body starts 8-aligned in the message, so aligning within it alone
  # gives the same padding.
  for a in args: body.marshal(a.sig, a)
  result = "l"
  result.add char(ord(mtMethodCall))
  result.add char(flags)
  result.add char(1)
  result.putU32(uint32(body.len))
  result.putU32(serial)
  result.marshal("a(yv)", darray("(yv)", fields))
  result.pad(8)
  result.add body
  if result.len > maxMessageBytes: raise newException(DbusError, "message too large")

proc messageLength*(header: string): int =
  ## The total length of the message whose first 16 bytes are `header`.
  ## Raises `DbusError` for an invalid fixed header.
  if header.len < 16: raise newException(DbusError, "short header")
  var r = Reader(data: header, pos: 0)
  case header[0]
  of 'l': r.big = false
  of 'B': r.big = true
  else: raise newException(DbusError, "invalid byte-order mark")
  if ord(header[3]) != 1: raise newException(DbusError, "unsupported protocol version")
  r.pos = 4
  let bodyLen = int(r.getUint(4))
  r.pos = 12
  let fieldsLen = int(r.getUint(4))
  if bodyLen > maxMessageBytes or fieldsLen > maxArrayBytes:
    raise newException(DbusError, "message too large")
  var headerLen = 16 + fieldsLen
  while headerLen mod 8 != 0: inc headerLen
  result = headerLen + bodyLen
  if result > maxMessageBytes: raise newException(DbusError, "message too large")

const headerFieldTypes = [1: "o", 2: "s", 3: "s", 4: "s", 5: "u", 6: "s", 7: "s", 8: "g", 9: "u"]
  ## The type each defined header field must have (spec, "Header Fields").

proc decodeMessage*(data: string, withBody = true): Message =
  ## Parse one complete message; without `withBody`, its header only (the
  ## body stays empty and undecoded). Raises `DbusError` when it is
  ## malformed.
  let total = messageLength(data)
  if data.len != total: raise newException(DbusError, "message length mismatch")
  var r = Reader(data: data, pos: 0, big: data[0] == 'B')
  r.pos = 1
  let t = int(r.getUint(1))
  if t < 1 or t > 4: raise newException(DbusError, "unknown message type " & $t)
  result.kind = MessageType(t)
  result.flags = uint8(r.getUint(1))
  r.pos = 4
  let bodyLen = int(r.getUint(4))
  result.serial = uint32(r.getUint(4))
  if result.serial == 0: raise newException(DbusError, "message serial 0")
  let fields = r.unmarshal("a(yv)")
  var seen: set[uint8]
  for f in fields.items:
    let code = int(f.items[0].unum)
    let v = f.items[1].inner[0]
    if code notin 1 .. 9: continue   # unknown fields are ignored (spec)
    if uint8(code) in seen: raise newException(DbusError, "header field " & $code & " repeated")
    seen.incl uint8(code)
    if v.sig != headerFieldTypes[code]:
      raise newException(DbusError, "header field " & $code & " of type " & v.sig)
    case code
    of 1: result.path = v.str
    of 2: result.iface = v.str
    of 3: result.member = v.str
    of 4: result.errorName = v.str
    of 5: result.replySerial = uint32(v.unum)
    of 6: result.destination = v.str
    of 7: result.sender = v.str
    of 8: result.signature = v.str
    of 9:
      if v.unum != 0:
        raise newException(DbusError, "a message carries Unix fds, but fd passing was not negotiated")
    else: discard
  # Required header fields (spec, "Message Types").
  var required: set[uint8]
  case result.kind
  of mtMethodCall: required = {1'u8, 3}
  of mtSignal: required = {1'u8, 2, 3}
  of mtError: required = {4'u8, 5}
  of mtMethodReturn: required = {5'u8}
  of mtInvalid: discard
  if not (required <= seen):
    raise newException(DbusError, "a " & $result.kind & " message lacks a required header field")
  if bodyLen > 0 and 8'u8 notin seen:
    raise newException(DbusError, "a message has a body but no signature")
  r.align(8)
  if r.pos + bodyLen != data.len: raise newException(DbusError, "body length mismatch")
  if not withBody: return
  for t in splitSignature(result.signature):
    result.body.add r.unmarshal(t)
  if r.pos != data.len: raise newException(DbusError, "body longer than its signature")

# ---------------------------------------------------------------------------
# Addresses
# ---------------------------------------------------------------------------

type
  AddressKind* = enum akPath, akAbstract
  BusAddress* = object
    kind*: AddressKind
    name*: string   ## the socket path, or the abstract name

proc unescapeValue(v: string): string =
  var i = 0
  while i < v.len:
    if v[i] == '%':
      if i + 2 >= v.len: raise newException(DbusError, "bad escape in address value '" & v & "'")
      try: result.add char(parseHexInt(v[i + 1 .. i + 2]))
      except ValueError: raise newException(DbusError, "bad escape in address value '" & v & "'")
      i += 3
    else:
      result.add v[i]
      inc i

proc parseAddresses*(address: string): seq[BusAddress] =
  ## The Unix-socket addresses of a D-Bus address string, in order of
  ## preference. Transports other than `unix:path` / `unix:abstract` are
  ## skipped; raises `DbusError` when none is usable.
  for part in address.split(';'):
    if part.len == 0: continue
    let colon = part.find(':')
    if colon < 0: raise newException(DbusError, "malformed D-Bus address '" & part & "'")
    if part[0 ..< colon] != "unix": continue
    var keys = initTable[string, string]()
    for kv in part[colon + 1 .. ^1].split(','):
      if kv.len == 0: continue
      let eq = kv.find('=')
      if eq <= 0: raise newException(DbusError, "malformed D-Bus address '" & part & "'")
      keys[kv[0 ..< eq]] = unescapeValue(kv[eq + 1 .. ^1])
    if "path" in keys: result.add BusAddress(kind: akPath, name: keys["path"])
    elif "abstract" in keys: result.add BusAddress(kind: akAbstract, name: keys["abstract"])
  if result.len == 0:
    raise newException(DbusError, "no usable unix: address in '" & address & "'")

# ---------------------------------------------------------------------------
# The connection
# ---------------------------------------------------------------------------

proc deadlineAfter(ms: int): MonoTime = getMonoTime() + initDuration(milliseconds = ms)

proc msLeft(d: MonoTime): int = int((d - getMonoTime()).inMilliseconds)

proc close*(c: DbusConnection) =
  ## Close the connection. Safe to call twice.
  if c != nil and c.fd >= 0:
    discard posix.close(c.fd)
    c.fd = -1

proc waitFd(c: DbusConnection, events: cshort, deadline: MonoTime, what: string) =
  ## Wait until the socket is ready for `events`, in slices of at most
  ## 50 ms between which `checkpoint` runs.
  while true:
    if c.checkpoint != nil: c.checkpoint()
    let left = msLeft(deadline)
    if left <= 0:
      raise newException(DbusTimeoutError, "no answer within the deadline while " & what)
    var p = TPollfd(fd: c.fd, events: events)
    let r = poll(addr p, 1, cint(min(left, 50)))
    if r < 0:
      if errno == EINTR: continue
      raise newException(DbusError, "poll failed while " & what & ": " & $strerror(errno))
    if r > 0:
      if (p.revents and (POLLERR or POLLNVAL)) != 0 and (p.revents and POLLIN) == 0:
        raise newException(DbusError, "the bus connection failed while " & what)
      return

proc writeAll(c: DbusConnection, data: string, deadline: MonoTime) =
  var off = 0
  while off < data.len:
    c.waitFd(POLLOUT, deadline, "sending")
    let n = send(SocketHandle(c.fd), unsafeAddr data[off], data.len - off, MSG_NOSIGNAL)
    if n < 0:
      if errno in [EINTR, EAGAIN, EWOULDBLOCK]: continue
      raise newException(DbusError, "cannot write to the bus: " & $strerror(errno))
    off += n

proc fill(c: DbusConnection, deadline: MonoTime, what: string) =
  ## Read whatever the socket has into the input buffer (at least one byte).
  c.waitFd(POLLIN, deadline, what)
  var chunk = newString(65536)
  while true:
    let n = recv(SocketHandle(c.fd), addr chunk[0], chunk.len, 0)
    if n < 0:
      if errno == EINTR: continue
      if errno in [EAGAIN, EWOULDBLOCK]: return
      raise newException(DbusError, "cannot read from the bus: " & $strerror(errno))
    if n == 0: raise newException(DbusError, "the bus closed the connection")
    c.inbuf.add chunk[0 ..< n]
    return

proc readLine(c: DbusConnection, deadline: MonoTime): string =
  ## One `\r\n`-terminated line of the authentication exchange.
  while true:
    let i = c.inbuf.find("\r\n")
    if i >= 0:
      result = c.inbuf[0 ..< i]
      c.inbuf = c.inbuf[i + 2 .. ^1]
      return
    if c.inbuf.len > 16384: raise newException(DbusError, "authentication line too long")
    c.fill(deadline, "authenticating")

proc readMessage(c: DbusConnection, deadline: MonoTime): Message =
  ## The next message. Only the answer to a call in flight has its body
  ## decoded; anything else (signals, calls, stray answers) comes back with
  ## its header alone. A malformed message closes the connection.
  if c.fd < 0: raise newException(DbusError, "the connection is closed")
  try:
    while c.inbuf.len < 16: c.fill(deadline, "waiting for a reply")
    let total = messageLength(c.inbuf[0 ..< 16])
    while c.inbuf.len < total: c.fill(deadline, "waiting for a reply")
    let frame = c.inbuf[0 ..< total]
    result = decodeMessage(frame, withBody = false)
    if result.kind in {mtMethodReturn, mtError} and result.replySerial in c.pending:
      result = decodeMessage(frame)
    c.inbuf = c.inbuf[total .. ^1]
  except DbusTimeoutError:
    raise
  except DbusError:
    c.close()
    raise

proc openSocket(a: BusAddress): cint =
  when defined(linux):
    let fd = socket(AF_UNIX, SOCK_STREAM or SOCK_CLOEXEC, 0)
  else:
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  if fd.int < 0: raise newException(DbusError, "cannot create a socket: " & $strerror(errno))
  when not defined(linux):
    discard fcntl(fd.cint, F_SETFD, FD_CLOEXEC)
  var sa: Sockaddr_un
  sa.sun_family = TSa_Family(AF_UNIX)
  var off = 0
  if a.kind == akAbstract:
    sa.sun_path[0] = '\0'
    off = 1
  if a.name.len + off >= sa.sun_path.len:
    discard posix.close(fd.cint)
    raise newException(DbusError, "socket path too long: " & a.name)
  for i, ch in a.name: sa.sun_path[i + off] = ch
  let len = if a.kind == akAbstract: sizeof(sa.sun_family) + off + a.name.len
            else: sizeof(Sockaddr_un)
  if connect(fd, cast[ptr SockAddr](addr sa), Socklen(len)) != 0:
    let err = $strerror(errno)
    discard posix.close(fd.cint)
    raise newException(DbusError, "cannot connect to " &
      (if a.kind == akAbstract: "@" else: "") & a.name & ": " & err)
  discard fcntl(fd.cint, F_SETFL, fcntl(fd.cint, F_GETFL) or O_NONBLOCK)
  fd.cint

proc send*(c: DbusConnection, destination, path, iface, member: string,
           args: openArray[DValue] = [], flags = 0'u8, timeoutMs = 5000): uint32 =
  ## Send a method call and return its serial; collect the answer with
  ## `reply`. Raises `DbusError` when it cannot be written.
  if c.fd < 0: raise newException(DbusError, "the connection is closed")
  inc c.serial
  if c.serial == 0: inc c.serial
  result = c.serial
  let msg = encodeCall(result, destination, path, iface, member, args, flags)
  try:
    c.writeAll(msg, deadlineAfter(timeoutMs))
  except DbusError:
    # A partly written message leaves the stream unusable.
    c.close()
    raise
  c.pending.incl result

proc reply*(c: DbusConnection, serial: uint32, timeoutMs = 5000): seq[DValue] =
  ## The body of the answer to the call `serial`. Raises `DbusCallError` for
  ## an error reply, `DbusTimeoutError` when none arrives in `timeoutMs`.
  let deadline = deadlineAfter(timeoutMs)
  if serial notin c.pending and serial notin c.replies:
    raise newException(DbusError, "no call with serial " & $serial & " is in flight")
  while serial notin c.replies:
    let m = c.readMessage(deadline)
    if m.kind in {mtMethodReturn, mtError} and m.replySerial in c.pending:
      c.pending.excl m.replySerial
      c.replies[m.replySerial] = m
    # Everything else is dropped undecoded: this client exposes no object,
    # subscribes to nothing, and an answer to no call in flight is stray.
  let m = c.replies[serial]
  c.replies.del serial
  if m.kind == mtError:
    var e = newException(DbusCallError, m.errorName & ": " &
      (if m.body.len > 0 and m.body[0].kind == dkString: m.body[0].str else: "(no message)"))
    e.errorName = m.errorName
    raise e
  m.body

proc call*(c: DbusConnection, destination, path, iface, member: string,
           args: openArray[DValue] = [], flags = 0'u8, timeoutMs = 5000): seq[DValue] =
  ## Send a method call and wait for its answer (`send` then `reply`).
  let s = c.send(destination, path, iface, member, args, flags, timeoutMs)
  c.reply(s, timeoutMs)

proc hexAscii(s: string): string =
  ## `s` as lower-case hex digits, two per byte (the EXTERNAL mechanism's
  ## encoding of the uid's decimal digits).
  for ch in s: result.add toHex(ord(ch), 2).toLowerAscii

proc connectBus*(address: string, timeoutMs = 5000,
                 checkpoint: proc () {.closure.} = nil): DbusConnection =
  ## Connect to the bus at `address`, authenticate with EXTERNAL and say
  ## Hello. Tries each alternative of the address in turn; raises
  ## `DbusError` naming the last failure.
  let deadline = deadlineAfter(timeoutMs)
  var lastErr = ""
  for a in parseAddresses(address):
    var c = DbusConnection(fd: -1, checkpoint: checkpoint)
    try:
      c.fd = openSocket(a)
      c.writeAll("\0AUTH EXTERNAL " & hexAscii($getuid()) & "\r\n", deadline)
      let answer = c.readLine(deadline)
      if not answer.startsWith("OK "):
        raise newException(DbusError, "the bus refused authentication: " & answer)
      c.writeAll("BEGIN\r\n", deadline)
      let hello = c.call("org.freedesktop.DBus", "/org/freedesktop/DBus",
                         "org.freedesktop.DBus", "Hello", timeoutMs = max(1, msLeft(deadline)))
      if hello.len != 1: raise newException(DbusError, "malformed Hello reply")
      c.uniqueName = hello[0].asStr
      return c
    except CatchableError as e:
      c.close()
      if not (e of ref DbusError) or e of ref DbusTimeoutError: raise
      lastErr = e.msg
  raise newException(DbusError, lastErr)

