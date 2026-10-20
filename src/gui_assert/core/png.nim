## GuiAssert core: PNG decode and encode in pure Nim.
##
## This module reads and writes PNG images without any external library or
## subprocess, so the pure core can turn a captured frame into pixels (and
## pixels back into a file) on every target, including the JS backend. It
## carries its own zlib stream codec (inflate and deflate) because the Nim
## standard library has none.
##
## Supported on decode (PNG 1.2 / ISO/IEC 15948, https://www.w3.org/TR/png/):
##
## * colour types 0 (gray), 2 (RGB), 3 (palette), 4 (gray + alpha) and
##   6 (RGBA);
## * bit depth 8 for every colour type, and 1 / 2 / 4 for gray and palette;
## * every filter type (None, Sub, Up, Average, Paeth);
## * a `tRNS` chunk on palette images (per-entry alpha).
##
## Rejected with `PngError` rather than approximated: 16-bit samples (they
## cannot be represented in the 8-bit image types without losing data),
## Adam7 interlacing, an unknown critical chunk, a bad chunk CRC, a bad zlib
## Adler-32, a truncated or over-long image stream, and dimensions beyond
## `maxPngPixels`. A file that fails any check yields no pixels at all; there
## is no partial decode.
##
## Encode always writes 8-bit, non-interlaced images (gray, RGB or RGBA),
## choosing a filter per row with the minimum-sum-of-absolute-differences
## heuristic recommended by the PNG specification (§12.8), and compresses with
## LZ77 plus the fixed Huffman code of RFC 1951 §3.2.6.
##
## References:
## * zlib stream format: RFC 1950, https://www.rfc-editor.org/rfc/rfc1950
## * DEFLATE: RFC 1951, https://www.rfc-editor.org/rfc/rfc1951
## * PNG: https://www.w3.org/TR/png/

import ./image

type
  PngError* = object of CatchableError
    ## Raised for every malformed, unsupported or corrupt PNG or zlib stream.

  ZlibError* = object of PngError
    ## Raised by `zlibDecompress` for a malformed or corrupt zlib stream.

  PngChannels* = enum
    ## The channel layout of a decoded PNG, after palette expansion.
    pcGray = 1       ## one byte per pixel
    pcGrayAlpha = 2  ## gray, alpha
    pcRgb = 3        ## red, green, blue
    pcRgba = 4       ## red, green, blue, alpha

  PngImage* = object
    ## A decoded PNG in its own channel layout. `pixels` is row-major with
    ## `ord(channels)` bytes per pixel. Palette images decode to `pcRgb`, or
    ## to `pcRgba` when they carry a `tRNS` chunk.
    width*, height*: int
    channels*: PngChannels
    pixels*: string

const
  maxPngPixels* = maxImagePixels
    ## The largest `width * height` this decoder accepts: the image-wide cap
    ## `image.maxImagePixels` (268 million pixels, about 1 GiB as RGBA). A
    ## larger header is refused before any allocation, so a hostile file
    ## cannot exhaust memory by its header alone.

  pngSignature = "\x89PNG\r\n\x1a\n"

# ---------------------------------------------------------------------------
# Checksums
# ---------------------------------------------------------------------------

proc makeCrcTable(): array[256, uint32] =
  ## The CRC-32 table of PNG Annex D (polynomial 0xEDB88320, reflected).
  for n in 0 ..< 256:
    var c = uint32(n)
    for _ in 0 ..< 8:
      if (c and 1'u32) != 0:
        c = 0xEDB88320'u32 xor (c shr 1)
      else:
        c = c shr 1
    result[n] = c

const crcTable = makeCrcTable()

proc updateCrc32(crc: uint32, data: string, first, last: int): uint32 =
  ## Fold `data[first ..< last]` into a running (pre-inverted) CRC.
  result = crc
  for i in first ..< last:
    result = crcTable[int((result xor uint32(ord(data[i]))) and 0xFF'u32)] xor
      (result shr 8)

proc crc32*(data: string): uint32 =
  ## The CRC-32 used by PNG chunks and by gzip (ISO 3309 / ITU-T V.42).
  updateCrc32(0xFFFFFFFF'u32, data, 0, data.len) xor 0xFFFFFFFF'u32

proc adler32*(data: string): uint32 =
  ## The Adler-32 checksum that ends a zlib stream (RFC 1950 §8.2).
  const modAdler = 65521'u32
  var a = 1'u32
  var b = 0'u32
  var i = 0
  while i < data.len:
    # 5552 is the largest block for which `b` cannot overflow 32 bits before
    # the modulo (the bound zlib itself uses).
    let stop = min(data.len, i + 5552)
    while i < stop:
      a += uint32(ord(data[i]))
      b += a
      inc i
    a = a mod modAdler
    b = b mod modAdler
  result = (b shl 16) or a

# ---------------------------------------------------------------------------
# Byte helpers
# ---------------------------------------------------------------------------

proc readU32BE(s: string, pos: int): uint32 =
  (uint32(ord(s[pos])) shl 24) or (uint32(ord(s[pos + 1])) shl 16) or
    (uint32(ord(s[pos + 2])) shl 8) or uint32(ord(s[pos + 3]))

proc addU32BE(s: var string, v: uint32) =
  s.add char((v shr 24) and 0xFF'u32)
  s.add char((v shr 16) and 0xFF'u32)
  s.add char((v shr 8) and 0xFF'u32)
  s.add char(v and 0xFF'u32)

# ---------------------------------------------------------------------------
# Inflate (RFC 1951 §3.2)
# ---------------------------------------------------------------------------
#
# Huffman codes are decoded canonically: a code is described by how many
# symbols have each code length (`counts`) and the symbols in canonical order
# (`symbols`). Decoding reads one bit at a time and walks the lengths, which
# is simple, needs no lookup tables and is fast enough for screen frames.

const
  maxCodeBits = 15
  lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
  lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
  distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
              257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
              8193, 12289, 16385, 24577]
  distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
               7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
  codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2,
                     14, 1, 15]

type
  Huffman = object
    counts: array[maxCodeBits + 1, int]
    symbols: seq[int]

  BitReader = object
    data: string
    pos: int        ## next byte to load
    bitBuf: uint32
    bitCount: int

proc zerr(msg: string) {.noreturn.} =
  raise newException(ZlibError, "zlib: " & msg)

proc needBits(br: var BitReader, n: int) =
  while br.bitCount < n:
    if br.pos >= br.data.len:
      zerr("unexpected end of compressed data")
    br.bitBuf = br.bitBuf or (uint32(ord(br.data[br.pos])) shl br.bitCount)
    inc br.pos
    br.bitCount += 8

proc getBits(br: var BitReader, n: int): int =
  ## Read `n` (0..16) bits, least significant first (RFC 1951 §3.1.1).
  if n == 0: return 0
  br.needBits(n)
  result = int(br.bitBuf and ((1'u32 shl n) - 1'u32))
  br.bitBuf = br.bitBuf shr n
  br.bitCount -= n

proc buildHuffman(lengths: openArray[int]): Huffman =
  ## Build a canonical decoder from per-symbol code lengths. Rejects an
  ## over-subscribed code; an incomplete code is allowed, as RFC 1951 permits
  ## it for a distance code with a single symbol.
  for l in lengths:
    inc result.counts[l]
  result.counts[0] = 0
  var left = 1
  for len in 1 .. maxCodeBits:
    left = left shl 1
    left -= result.counts[len]
    if left < 0:
      zerr("over-subscribed Huffman code")
  var offs: array[maxCodeBits + 2, int]
  for len in 1 .. maxCodeBits:
    offs[len + 1] = offs[len] + result.counts[len]
  result.symbols = newSeq[int](lengths.len)
  for sym, l in lengths:
    if l != 0:
      result.symbols[offs[l]] = sym
      inc offs[l]

proc decodeSymbol(br: var BitReader, h: Huffman): int =
  var code = 0    # bits read so far, MSB first
  var first = 0   # first code of the current length
  var index = 0   # index of the first symbol of the current length
  for len in 1 .. maxCodeBits:
    code = code or br.getBits(1)
    let count = h.counts[len]
    if code - first < count:
      return h.symbols[index + (code - first)]
    index += count
    first = (first + count) shl 1
    code = code shl 1
  zerr("invalid Huffman code")

proc fixedTables(): tuple[lit, dist: Huffman] =
  var lengths: array[288, int]
  for i in 0 .. 143: lengths[i] = 8
  for i in 144 .. 255: lengths[i] = 9
  for i in 256 .. 279: lengths[i] = 7
  for i in 280 .. 287: lengths[i] = 8
  result.lit = buildHuffman(lengths)
  var dl: array[30, int]
  for i in 0 ..< 30: dl[i] = 5
  result.dist = buildHuffman(dl)

proc inflateCodes(br: var BitReader, output: var string,
                  lit, dist: Huffman, limit: int) =
  while true:
    let sym = br.decodeSymbol(lit)
    if sym < 256:
      if output.len >= limit: zerr("decompressed data exceeds expected size")
      output.add char(sym)
    elif sym == 256:
      return
    else:
      let li = sym - 257
      if li >= lengthBase.len: zerr("invalid length symbol " & $sym)
      let length = lengthBase[li] + br.getBits(lengthExtra[li])
      let ds = br.decodeSymbol(dist)
      if ds >= distBase.len: zerr("invalid distance symbol " & $ds)
      let distance = distBase[ds] + br.getBits(distExtra[ds])
      if distance > output.len:
        zerr("distance " & $distance & " reaches before the start of the data")
      if output.len + length > limit:
        zerr("decompressed data exceeds expected size")
      let start = output.len - distance
      # Byte by byte: a match may overlap the bytes it is producing.
      for k in 0 ..< length:
        output.add output[start + k]

proc inflateDynamic(br: var BitReader, output: var string, limit: int) =
  let nlen = br.getBits(5) + 257
  let ndist = br.getBits(5) + 1
  let ncode = br.getBits(4) + 4
  if nlen > 286 or ndist > 30:
    zerr("bad dynamic block header counts")
  var clLengths: array[19, int]
  for i in 0 ..< ncode:
    clLengths[codeLengthOrder[i]] = br.getBits(3)
  let clCode = buildHuffman(clLengths)
  var lengths = newSeq[int](nlen + ndist)
  var i = 0
  while i < nlen + ndist:
    let sym = br.decodeSymbol(clCode)
    if sym < 16:
      lengths[i] = sym
      inc i
    else:
      var rep = 0
      var value = 0
      case sym
      of 16:
        if i == 0: zerr("repeat of a code length with no previous length")
        value = lengths[i - 1]
        rep = 3 + br.getBits(2)
      of 17:
        rep = 3 + br.getBits(3)
      else:
        rep = 11 + br.getBits(7)
      if i + rep > nlen + ndist: zerr("code lengths overflow the table")
      for _ in 0 ..< rep:
        lengths[i] = value
        inc i
  if lengths[256] == 0:
    zerr("dynamic block has no end-of-block code")
  let lit = buildHuffman(lengths.toOpenArray(0, nlen - 1))
  let dist = buildHuffman(lengths.toOpenArray(nlen, nlen + ndist - 1))
  inflateCodes(br, output, lit, dist, limit)

proc inflateRaw(data: string, start: int, limit: int):
    tuple[output: string, endPos: int] =
  ## Decode a raw DEFLATE stream from `data[start ..]`. `limit` bounds the
  ## output size. Returns the output and the byte position after the final
  ## block (the start of the zlib trailer).
  var br = BitReader(data: data, pos: start)
  var output = ""
  let fixed = fixedTables()
  while true:
    let final = br.getBits(1)
    let btype = br.getBits(2)
    case btype
    of 0:
      # Stored block: skip to a byte boundary, then LEN and NLEN.
      br.bitBuf = 0
      br.bitCount = 0
      if br.pos + 4 > data.len: zerr("truncated stored block header")
      let len = ord(data[br.pos]) or (ord(data[br.pos + 1]) shl 8)
      let nlen = ord(data[br.pos + 2]) or (ord(data[br.pos + 3]) shl 8)
      br.pos += 4
      if (len xor 0xFFFF) != nlen: zerr("stored block length check failed")
      if br.pos + len > data.len: zerr("truncated stored block")
      if output.len + len > limit:
        zerr("decompressed data exceeds expected size")
      output.add data[br.pos ..< br.pos + len]
      br.pos += len
    of 1:
      inflateCodes(br, output, fixed.lit, fixed.dist, limit)
    of 2:
      inflateDynamic(br, output, limit)
    else:
      zerr("reserved block type 3")
    if final == 1: break
  # Unused bits of the last byte are padding; whole unread bytes in the bit
  # buffer are pushed back.
  result = (output, br.pos - br.bitCount div 8)

proc zlibDecompress*(data: string, maxOutput = high(int)): string =
  ## Decompress a complete zlib stream (RFC 1950): header, DEFLATE data and
  ## the Adler-32 trailer, which is verified. `maxOutput` bounds the
  ## decompressed size; a stream that would exceed it is rejected. Raises
  ## `ZlibError` on any malformed or corrupt input.
  if data.len < 6: zerr("stream too short")
  let cmf = ord(data[0])
  let flg = ord(data[1])
  if (cmf and 0x0F) != 8: zerr("compression method is not deflate")
  if (cmf shr 4) > 7: zerr("window size larger than 32 KiB")
  if ((cmf shl 8) or flg) mod 31 != 0: zerr("header check failed")
  if (flg and 0x20) != 0: zerr("preset dictionaries are not supported")
  let (output, endPos) = inflateRaw(data, 2, maxOutput)
  if endPos + 4 > data.len: zerr("missing Adler-32 trailer")
  if readU32BE(data, endPos) != adler32(output):
    zerr("Adler-32 mismatch (corrupt data)")
  result = output

# ---------------------------------------------------------------------------
# Deflate: LZ77 with hash chains, emitted with the fixed Huffman code
# ---------------------------------------------------------------------------

type
  BitWriter = object
    output: string
    bitBuf: uint32
    bitCount: int

proc putBits(bw: var BitWriter, value: int, n: int) =
  ## Append `n` bits of `value`, least significant first.
  bw.bitBuf = bw.bitBuf or (uint32(value) shl bw.bitCount)
  bw.bitCount += n
  while bw.bitCount >= 8:
    bw.output.add char(bw.bitBuf and 0xFF'u32)
    bw.bitBuf = bw.bitBuf shr 8
    bw.bitCount -= 8

proc putCode(bw: var BitWriter, code, len: int) =
  ## Huffman codes are defined most-significant bit first (RFC 1951 §3.1.1),
  ## so they are bit-reversed before being packed.
  var rev = 0
  var c = code
  for _ in 0 ..< len:
    rev = (rev shl 1) or (c and 1)
    c = c shr 1
  bw.putBits(rev, len)

proc flush(bw: var BitWriter) =
  if bw.bitCount > 0:
    bw.output.add char(bw.bitBuf and 0xFF'u32)
    bw.bitBuf = 0
    bw.bitCount = 0

proc putLiteral(bw: var BitWriter, sym: int) =
  ## Emit a literal/length symbol with the fixed code (RFC 1951 §3.2.6).
  if sym <= 143: bw.putCode(0x30 + sym, 8)
  elif sym <= 255: bw.putCode(0x190 + (sym - 144), 9)
  elif sym <= 279: bw.putCode(sym - 256, 7)
  else: bw.putCode(0xC0 + (sym - 280), 8)

proc putMatch(bw: var BitWriter, length, distance: int) =
  var li = lengthBase.len - 1
  while lengthBase[li] > length: dec li
  bw.putLiteral(257 + li)
  bw.putBits(length - lengthBase[li], lengthExtra[li])
  var di = distBase.len - 1
  while distBase[di] > distance: dec di
  bw.putCode(di, 5)
  bw.putBits(distance - distBase[di], distExtra[di])

proc zlibCompress*(data: string): string =
  ## Compress `data` into a zlib stream (RFC 1950) holding one fixed-Huffman
  ## DEFLATE block. Matches are found with a hash chain over 3-byte prefixes
  ## inside the 32 KiB window; the chain walk is bounded so the cost per byte
  ## stays constant on repetitive input such as flat screen regions.
  const
    windowSize = 32768
    minMatch = 3
    maxMatch = 258
    hashBits = 15
    hashSize = 1 shl hashBits
    maxChain = 64
  var bw = BitWriter()
  bw.output.add char(0x78)   # CMF: deflate, 32 KiB window
  bw.output.add char(0x9C)   # FLG: default level, check bits for 0x789C
  bw.putBits(1, 1)           # BFINAL
  bw.putBits(1, 2)           # BTYPE = fixed Huffman
  var head = newSeq[int](hashSize)
  for i in 0 ..< hashSize: head[i] = -1
  var prev = newSeq[int](windowSize)
  template hashAt(p: int): int =
    ((ord(data[p]) shl 10) xor (ord(data[p + 1]) shl 5) xor ord(data[p + 2])) and
      (hashSize - 1)
  template insert(p: int) =
    if p + minMatch <= data.len:
      let h = hashAt(p)
      prev[p and (windowSize - 1)] = head[h]
      head[h] = p
  var i = 0
  while i < data.len:
    var bestLen = 0
    var bestDist = 0
    if i + minMatch <= data.len:
      var cand = head[hashAt(i)]
      var chain = 0
      let maxLen = min(maxMatch, data.len - i)
      while cand >= 0 and i - cand <= windowSize and chain < maxChain:
        if data[cand + bestLen] == data[i + bestLen] or bestLen == 0:
          var l = 0
          while l < maxLen and data[cand + l] == data[i + l]:
            inc l
          if l > bestLen:
            bestLen = l
            bestDist = i - cand
            if l == maxLen: break
        let nxt = prev[cand and (windowSize - 1)]
        # A chain entry can be stale once the window has wrapped; entries
        # must strictly decrease, which also guarantees termination.
        if nxt >= cand: break
        cand = nxt
        inc chain
    if bestLen >= minMatch:
      bw.putMatch(bestLen, bestDist)
      for k in 0 ..< bestLen:
        insert(i + k)
      i += bestLen
    else:
      bw.putLiteral(ord(data[i]))
      insert(i)
      inc i
  bw.putLiteral(256)          # end of block
  bw.flush()
  bw.output.addU32BE(adler32(data))
  result = bw.output

# ---------------------------------------------------------------------------
# PNG decode
# ---------------------------------------------------------------------------

proc perr(msg: string) {.noreturn.} =
  raise newException(PngError, "PNG: " & msg)

proc paeth(a, b, c: int): int =
  ## The Paeth predictor (PNG §9.4).
  let p = a + b - c
  let pa = abs(p - a)
  let pb = abs(p - b)
  let pc = abs(p - c)
  if pa <= pb and pa <= pc: a
  elif pb <= pc: b
  else: c

proc unfilter(raw: string, height, stride, bpp: int): string =
  ## Undo the per-row filters (PNG §9). `raw` holds `height` rows of
  ## `1 + stride` bytes; `bpp` is the filter unit (bytes per complete pixel,
  ## at least 1). Returns the `height * stride` unfiltered bytes.
  result = newString(height * stride)
  for y in 0 ..< height:
    let src = y * (stride + 1)
    let ftype = ord(raw[src])
    let dst = y * stride
    let up = dst - stride
    for x in 0 ..< stride:
      let v = ord(raw[src + 1 + x])
      let a = if x >= bpp: ord(result[dst + x - bpp]) else: 0
      let b = if y > 0: ord(result[up + x]) else: 0
      let c = if y > 0 and x >= bpp: ord(result[up + x - bpp]) else: 0
      let outv =
        case ftype
        of 0: v
        of 1: v + a
        of 2: v + b
        of 3: v + (a + b) div 2
        of 4: v + paeth(a, b, c)
        else: perr("invalid filter type " & $ftype & " on row " & $y)
      result[dst + x] = char(outv and 0xFF)

proc decodePng*(data: string): PngImage =
  ## Decode a PNG file held in memory. Every chunk CRC and the zlib Adler-32
  ## are verified; see the module documentation for what is supported and
  ## what is rejected. Raises `PngError` (or its `ZlibError` subtype).
  if data.len < pngSignature.len or data[0 ..< pngSignature.len] != pngSignature:
    perr("not a PNG file (bad signature)")
  var pos = pngSignature.len
  var sawHeader = false
  var sawEnd = false
  var width, height, bitDepth, colorType = 0
  var palette = ""
  var trns = ""
  var idat = ""
  var idatDone = false
  while pos < data.len:
    if pos + 8 > data.len: perr("truncated chunk header")
    let length = readU32BE(data, pos)
    if length > 0x7FFFFFFF'u32: perr("chunk length out of range")
    let len = int(length)
    let kind = data[pos + 4 ..< pos + 8]
    if pos + 12 + len > data.len: perr("truncated " & kind & " chunk")
    let bodyStart = pos + 8
    let storedCrc = readU32BE(data, bodyStart + len)
    let actualCrc = updateCrc32(0xFFFFFFFF'u32, data, pos + 4, bodyStart + len) xor
      0xFFFFFFFF'u32
    if storedCrc != actualCrc:
      perr("CRC mismatch in " & kind & " chunk (corrupt file)")
    if not sawHeader and kind != "IHDR":
      perr("first chunk is " & kind & ", not IHDR")
    if idat.len > 0 and kind != "IDAT":
      idatDone = true
    case kind
    of "IHDR":
      if sawHeader: perr("duplicate IHDR")
      if len != 13: perr("IHDR has length " & $len)
      sawHeader = true
      let w = readU32BE(data, bodyStart)
      let h = readU32BE(data, bodyStart + 4)
      if w == 0 or h == 0 or w > 0x7FFFFFFF'u32 or h > 0x7FFFFFFF'u32:
        perr("invalid dimensions " & $w & "x" & $h)
      if uint64(w) * uint64(h) > uint64(maxPngPixels):
        perr("image of " & $w & "x" & $h & " exceeds maxPngPixels")
      width = int(w)
      height = int(h)
      bitDepth = ord(data[bodyStart + 8])
      colorType = ord(data[bodyStart + 9])
      let compression = ord(data[bodyStart + 10])
      let filterMethod = ord(data[bodyStart + 11])
      let interlace = ord(data[bodyStart + 12])
      if compression != 0: perr("unknown compression method " & $compression)
      if filterMethod != 0: perr("unknown filter method " & $filterMethod)
      if interlace == 1: perr("Adam7-interlaced images are not supported")
      if interlace != 0: perr("unknown interlace method " & $interlace)
      case colorType
      of 0, 3:
        if bitDepth notin {1, 2, 4, 8}:
          if bitDepth == 16 and colorType == 0:
            perr("16-bit samples are not supported")
          perr("invalid bit depth " & $bitDepth & " for colour type " & $colorType)
      of 2, 4, 6:
        if bitDepth == 16: perr("16-bit samples are not supported")
        if bitDepth != 8:
          perr("invalid bit depth " & $bitDepth & " for colour type " & $colorType)
      else:
        perr("invalid colour type " & $colorType)
    of "PLTE":
      if len mod 3 != 0 or len == 0 or len > 768:
        perr("invalid PLTE length " & $len)
      palette = data[bodyStart ..< bodyStart + len]
    of "tRNS":
      trns = data[bodyStart ..< bodyStart + len]
    of "IDAT":
      if idatDone: perr("IDAT chunks are not consecutive")
      idat.add data[bodyStart ..< bodyStart + len]
    of "IEND":
      sawEnd = true
    else:
      # Bit 5 of the first byte set (lowercase) marks an ancillary chunk,
      # which a decoder may skip (PNG §5.4). A critical chunk we do not know
      # changes how the image is to be read, so it is refused.
      if (ord(kind[0]) and 0x20) == 0:
        perr("unknown critical chunk " & kind)
    pos = bodyStart + len + 4
    if sawEnd: break
  if not sawHeader: perr("missing IHDR")
  if not sawEnd: perr("missing IEND (truncated file)")
  if idat.len == 0: perr("missing IDAT")
  if colorType == 3 and palette.len == 0: perr("palette image without PLTE")

  let samples =
    case colorType
    of 0, 3: 1
    of 2: 3
    of 4: 2
    else: 4
  let bitsPerPixel = samples * bitDepth
  let stride = (width * bitsPerPixel + 7) div 8
  let bpp = max(1, bitsPerPixel div 8)
  let expected = height * (stride + 1)
  let raw = zlibDecompress(idat, expected)
  if raw.len != expected:
    perr("image data has " & $raw.len & " bytes, expected " & $expected)
  let rows = unfilter(raw, height, stride, bpp)

  result.width = width
  result.height = height
  case colorType
  of 4, 6:
    result.channels = PngChannels(samples)
    result.pixels = rows
  of 2:
    if trns.len == 0:
      result.channels = pcRgb
      result.pixels = rows
    else:
      # A colour key (PNG §11.3.2.1): pixels equal to it are transparent.
      if trns.len != 6: perr("tRNS of length " & $trns.len & " on an RGB image")
      let key = [ord(trns[1]), ord(trns[3]), ord(trns[5])]
      result.channels = pcRgba
      result.pixels = newString(width * height * 4)
      for i in 0 ..< width * height:
        let r = rows[i * 3]
        let g = rows[i * 3 + 1]
        let b = rows[i * 3 + 2]
        result.pixels[i * 4] = r
        result.pixels[i * 4 + 1] = g
        result.pixels[i * 4 + 2] = b
        let keyed = ord(r) == key[0] and ord(g) == key[1] and ord(b) == key[2]
        result.pixels[i * 4 + 3] = if keyed: '\x00' else: '\xFF'
  of 0:
    var gray = rows
    if bitDepth != 8:
      # Scale 1/2/4-bit samples to the full 0..255 range (PNG §13.12).
      let maxv = (1 shl bitDepth) - 1
      gray = newString(width * height)
      for y in 0 ..< height:
        for x in 0 ..< width:
          let bit = x * bitDepth
          let b = ord(rows[y * stride + bit div 8])
          let v = (b shr (8 - bitDepth - (bit mod 8))) and maxv
          gray[y * width + x] = char(v * 255 div maxv)
    if trns.len == 0:
      result.channels = pcGray
      result.pixels = gray
    else:
      # A gray colour key, compared at the image's own bit depth.
      if trns.len != 2: perr("tRNS of length " & $trns.len & " on a gray image")
      let maxv = (1 shl bitDepth) - 1
      let key = (ord(trns[1]) and maxv) * 255 div maxv
      result.channels = pcGrayAlpha
      result.pixels = newString(width * height * 2)
      for i in 0 ..< width * height:
        result.pixels[i * 2] = gray[i]
        result.pixels[i * 2 + 1] = if ord(gray[i]) == key: '\x00' else: '\xFF'
  else:
    let entries = palette.len div 3
    let withAlpha = trns.len > 0
    if trns.len > entries: perr("tRNS has more entries than PLTE")
    result.channels = if withAlpha: pcRgba else: pcRgb
    let ch = ord(result.channels)
    result.pixels = newString(width * height * ch)
    let maxv = (1 shl bitDepth) - 1
    for y in 0 ..< height:
      for x in 0 ..< width:
        let bit = x * bitDepth
        let b = ord(rows[y * stride + bit div 8])
        let idx =
          if bitDepth == 8: b
          else: (b shr (8 - bitDepth - (bit mod 8))) and maxv
        if idx >= entries:
          perr("palette index " & $idx & " out of range at (" & $x & ", " &
               $y & ")")
        let o = (y * width + x) * ch
        result.pixels[o] = palette[idx * 3]
        result.pixels[o + 1] = palette[idx * 3 + 1]
        result.pixels[o + 2] = palette[idx * 3 + 2]
        if withAlpha:
          result.pixels[o + 3] = if idx < trns.len: trns[idx] else: '\xFF'

proc toGray*(p: PngImage): GrayImage =
  ## Convert a decoded PNG to gray. Colour is reduced with `rgbToGray` (see
  ## `image`); alpha is dropped, not composited, which is also what ffmpeg's
  ## `-pix_fmt gray` decode does.
  case p.channels
  of pcGray:
    GrayImage(width: p.width, height: p.height, pixels: p.pixels)
  of pcGrayAlpha:
    var g = GrayImage(width: p.width, height: p.height,
                      pixels: newString(p.width * p.height))
    for i in 0 ..< p.width * p.height:
      g.pixels[i] = p.pixels[i * 2]
    g
  of pcRgb:
    toGray(RgbImage(width: p.width, height: p.height, pixels: p.pixels))
  of pcRgba:
    toGray(RgbaImage(width: p.width, height: p.height, pixels: p.pixels))

proc toRgb*(p: PngImage): RgbImage =
  ## Convert a decoded PNG to RGB (gray is replicated, alpha dropped).
  case p.channels
  of pcRgb:
    RgbImage(width: p.width, height: p.height, pixels: p.pixels)
  of pcRgba:
    toRgb(RgbaImage(width: p.width, height: p.height, pixels: p.pixels))
  of pcGray:
    toRgb(GrayImage(width: p.width, height: p.height, pixels: p.pixels))
  of pcGrayAlpha:
    toRgb(toGray(p))

proc toRgba*(p: PngImage): RgbaImage =
  ## Convert a decoded PNG to RGBA (opaque alpha where the PNG has none).
  case p.channels
  of pcRgba:
    RgbaImage(width: p.width, height: p.height, pixels: p.pixels)
  of pcRgb:
    toRgba(RgbImage(width: p.width, height: p.height, pixels: p.pixels))
  of pcGray:
    toRgba(GrayImage(width: p.width, height: p.height, pixels: p.pixels))
  of pcGrayAlpha:
    var r = RgbaImage(width: p.width, height: p.height,
                      pixels: newString(p.width * p.height * 4))
    for i in 0 ..< p.width * p.height:
      let g = p.pixels[i * 2]
      r.pixels[i * 4] = g
      r.pixels[i * 4 + 1] = g
      r.pixels[i * 4 + 2] = g
      r.pixels[i * 4 + 3] = p.pixels[i * 2 + 1]
    r

proc decodePngGray*(data: string): GrayImage =
  ## Decode a PNG held in memory straight to gray (see `toGray`).
  decodePng(data).toGray

proc decodePngRgb*(data: string): RgbImage =
  ## Decode a PNG held in memory to RGB (see `toRgb`).
  decodePng(data).toRgb

proc decodePngRgba*(data: string): RgbaImage =
  ## Decode a PNG held in memory to RGBA (see `toRgba`).
  decodePng(data).toRgba

# ---------------------------------------------------------------------------
# PNG encode
# ---------------------------------------------------------------------------

proc addChunk(output: var string, kind, body: string) =
  output.addU32BE(uint32(body.len))
  let start = output.len
  output.add kind
  output.add body
  output.addU32BE(updateCrc32(0xFFFFFFFF'u32, output, start, output.len) xor
    0xFFFFFFFF'u32)

proc filterRows(pixels: string, width, height, bpp: int): string =
  ## Filter every row with the filter type whose output has the smallest sum
  ## of absolute values (as signed bytes), the heuristic of PNG §12.8.
  let stride = width * bpp
  result = newStringOfCap(height * (stride + 1))
  var candidate = newString(stride)
  var best = newString(stride)
  for y in 0 ..< height:
    let row = y * stride
    let up = row - stride
    var bestType = 0
    var bestScore = high(int)
    for ftype in 0 .. 4:
      var score = 0
      for x in 0 ..< stride:
        let v = ord(pixels[row + x])
        let a = if x >= bpp: ord(pixels[row + x - bpp]) else: 0
        let b = if y > 0: ord(pixels[up + x]) else: 0
        let c = if y > 0 and x >= bpp: ord(pixels[up + x - bpp]) else: 0
        let pred =
          case ftype
          of 0: 0
          of 1: a
          of 2: b
          of 3: (a + b) div 2
          else: paeth(a, b, c)
        let f = (v - pred) and 0xFF
        candidate[x] = char(f)
        score += (if f < 128: f else: 256 - f)
      if score < bestScore:
        bestScore = score
        bestType = ftype
        swap(best, candidate)
    result.add char(bestType)
    result.add best

proc encodeRaw(width, height, channels: int, colorType: int,
               pixels: string): string =
  if width <= 0 or height <= 0:
    perr("cannot encode an empty " & $width & "x" & $height & " image")
  if pixels.len != width * height * channels:
    perr("pixel buffer has " & $pixels.len & " bytes, expected " &
         $(width * height * channels) & " for " & $width & "x" & $height)
  result = pngSignature
  var ihdr = ""
  ihdr.addU32BE(uint32(width))
  ihdr.addU32BE(uint32(height))
  ihdr.add char(8)          # bit depth
  ihdr.add char(colorType)
  ihdr.add char(0)          # compression: deflate
  ihdr.add char(0)          # filter method 0
  ihdr.add char(0)          # no interlace
  result.addChunk("IHDR", ihdr)
  result.addChunk("IDAT", zlibCompress(filterRows(pixels, width, height, channels)))
  result.addChunk("IEND", "")

proc encodePng*(img: GrayImage): string =
  ## Encode an 8-bit gray PNG (colour type 0). Raises `PngError` for an empty
  ## image or a buffer whose size does not match the dimensions.
  encodeRaw(img.width, img.height, 1, 0, img.pixels)

proc encodePng*(img: RgbImage): string =
  ## Encode an 8-bit RGB PNG (colour type 2).
  encodeRaw(img.width, img.height, 3, 2, img.pixels)

proc encodePng*(img: RgbaImage): string =
  ## Encode an 8-bit RGBA PNG (colour type 6).
  encodeRaw(img.width, img.height, 4, 6, img.pixels)

when not defined(js):
  proc readPngFile*(path: string): PngImage =
    ## Read and decode the PNG at `path`. The only filesystem access in this
    ## module, kept to an explicitly named `…File` proc (spec §3.2). Raises
    ## `IOError` when the file cannot be read and `PngError` when it is not a
    ## valid PNG.
    decodePng(readFile(path))

  proc writePngFile*(path: string, img: GrayImage | RgbImage | RgbaImage) =
    ## Encode `img` and write it to `path`, replacing any existing file.
    writeFile(path, encodePng(img))
