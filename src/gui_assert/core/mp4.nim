## GuiAssert core: measuring a finished MP4 recording.
##
## `record` and `record-stop` report a recording's `durationMs`, `frames`,
## `width` and `height` as **measured from the finalized file**, and a file
## whose container is not finalized is a failure, never a stopped recording
## (spec §7.5, "Recordings"). This module reads exactly what that needs from
## an ISO base media file (ISO/IEC 14496-12, the MP4 container; the box
## layout is summarized at https://developer.apple.com/documentation/quicktime-file-format):
##
## * the top-level boxes, which must include a `moov` box (a recorder that
##   died before finalizing never writes it) and an `mdat` box;
## * in `moov`, the first track whose `mdia/hdlr` handler is `vide`: its
##   `tkhd` presentation size, its `mdia/mdhd` duration and timescale, and
##   its frames: the samples of its `mdia/minf/stbl/stsz` (one sample per
##   frame) that start within the track's duration by the decoding times of
##   its `stts`. A recorder may end a constant-rate track with a sample of
##   zero duration placed at the track's end (wf-recorder does); no player
##   presents it and ffprobe does not count it, so neither does this. A
##   track without an `stts` (the box is mandatory, ISO/IEC 14496-12
##   §8.6.1.2) counts every `stsz` sample.
##
## A file is **finalized** when all of that is present, the video track's
## duration is positive and it has at least one sample. Anything else raises
## `Mp4Error` saying what is missing.
##
## Pure (spec §3.2): `probeMp4` works on bytes; `probeMp4File` is the one
## filesystem access, an explicitly named `…File` proc that reads only box
## headers and the `moov` box, so a large recording is not loaded whole.


type
  Mp4Error* = object of CatchableError
    ## The data is not a finalized MP4 with a video track.

  Mp4Info* = object
    ## What a finalized MP4's video track measures.
    durationMs*: int     ## video track duration, rounded to milliseconds
    frames*: int         ## video samples
    width*, height*: int ## presentation size (tkhd), in pixels

const
  maxMoovBytes = 64 shl 20
    ## A `moov` box larger than this is refused rather than read.
  maxDurationSeconds = 1'u64 shl 40
    ## A track duration longer than this is refused as corrupt.

proc mp4Error(msg: string): ref Mp4Error = newException(Mp4Error, msg)

proc be32(s: string, i: int): uint32 =
  if i < 0 or i + 4 > s.len: raise mp4Error("truncated box at offset " & $i)
  (uint32(ord(s[i])) shl 24) or (uint32(ord(s[i + 1])) shl 16) or
    (uint32(ord(s[i + 2])) shl 8) or uint32(ord(s[i + 3]))

proc be64(s: string, i: int): uint64 =
  (uint64(be32(s, i)) shl 32) or uint64(be32(s, i + 4))

type Box = tuple[kind: string, start, stop: int]
  ## A box's type and the byte range of its payload in the enclosing buffer.

proc field32(s: string, b: Box, offset: int): uint32 =
  ## The big-endian 32-bit field at `offset` into `b`'s payload. The input
  ## is untrusted: a field that does not lie wholly inside its own box is an
  ## `Mp4Error`, never a read of the next box or past the buffer.
  if offset < 0 or b.start + offset + 4 > b.stop:
    raise mp4Error("box '" & b.kind & "' is too short (" & $(b.stop - b.start) &
      " bytes) for a field at offset " & $offset)
  be32(s, b.start + offset)

proc field64(s: string, b: Box, offset: int): uint64 =
  (uint64(field32(s, b, offset)) shl 32) or uint64(field32(s, b, offset + 4))

proc fieldByte(s: string, b: Box, offset: int): int =
  if offset < 0 or b.start + offset >= b.stop:
    raise mp4Error("box '" & b.kind & "' is too short for a field at offset " & $offset)
  ord(s[b.start + offset])

proc fourcc(s: string, b: Box, offset: int): string =
  if offset < 0 or b.start + offset + 4 > b.stop:
    raise mp4Error("box '" & b.kind & "' is too short for a code at offset " & $offset)
  s[b.start + offset ..< b.start + offset + 4]

proc boxes(s: string, first, last: int): seq[Box] =
  ## The boxes laid out in `s[first ..< last]`.
  var i = first
  while i < last:
    if i + 8 > last: raise mp4Error("truncated box header at offset " & $i)
    var size = int64(be32(s, i))
    let kind = s[i + 4 ..< i + 8]
    var header = 8
    if size == 1:
      if i + 16 > last: raise mp4Error("truncated large box header at offset " & $i)
      let big = be64(s, i + 8)
      if big > uint64(high(int32)) * 16: raise mp4Error("box '" & kind & "' is too large")
      size = int64(big)
      header = 16
    elif size == 0:
      size = int64(last - i)
    if size < header or i + size > last:
      raise mp4Error("box '" & kind & "' at offset " & $i & " overruns its parent")
    result.add (kind, i + header, i + int(size))
    i += int(size)

proc child(s: string, parent: Box, kind: string): Box =
  for b in boxes(s, parent.start, parent.stop):
    if b.kind == kind: return b
  raise mp4Error("box '" & parent.kind & "' has no '" & kind & "' box")

proc sampleCount(s: string, mdia: Box, duration: uint64): int =
  ## The samples that start before `duration` (module doc).
  let stbl = child(s, child(s, mdia, "minf"), "stbl")
  let stsz = child(s, stbl, "stsz")
  # version/flags(4) sample_size(4) sample_count(4)
  let total = int(field32(s, stsz, 8))
  var stts: Box
  var found = false
  for b in boxes(s, stbl.start, stbl.stop):
    if b.kind == "stts":
      stts = b
      found = true
  if not found: return total
  # version/flags(4) entry_count(4), then (sample_count(4), sample_delta(4))
  # per entry; a malformed count runs into the end of the box (Mp4Error).
  let entries = uint64(field32(s, stts, 4))
  var t = 0'u64
  var presented = 0'u64
  var i = 0'u64
  while i < entries and t < duration:
    let count = uint64(field32(s, stts, 8 + 8 * int(i)))
    let delta = uint64(field32(s, stts, 12 + 8 * int(i)))
    if delta == 0:
      presented += count               # every one starts at t < duration
    else:
      let fit = (duration - t + delta - 1) div delta
      presented += min(count, fit)
      # count * delta < 2^64; stop at the duration rather than overflow t.
      t = if count * delta >= duration - t: duration else: t + count * delta
    inc i
  int(min(uint64(total), presented))

proc videoTrack(s: string, moov: Box): Mp4Info =
  ## The video track's measurements from a `moov` box.
  for trak in boxes(s, moov.start, moov.stop):
    if trak.kind != "trak": continue
    let mdia = child(s, trak, "mdia")
    let hdlr = child(s, mdia, "hdlr")
    # version/flags(4) pre_defined(4) handler_type(4)
    if fourcc(s, hdlr, 8) != "vide": continue
    let tkhd = child(s, trak, "tkhd")
    let tv = fieldByte(s, tkhd, 0)
    # version 0: flags(4) ctime(4) mtime(4) id(4) reserved(4) duration(4);
    # version 1 widens ctime, mtime and duration to 8 bytes. Then
    # reserved(8) layer(2) group(2) volume(2) reserved(2) matrix(36), and the
    # width and height as 16.16 fixed point.
    let sizeAt = (if tv == 1: 36 else: 24) + 8 + 8 + 36
    result.width = int(field32(s, tkhd, sizeAt) shr 16)
    result.height = int(field32(s, tkhd, sizeAt + 4) shr 16)
    let mdhd = child(s, mdia, "mdhd")
    let mv = fieldByte(s, mdhd, 0)
    var timescale, duration: uint64
    if mv == 1:
      timescale = field32(s, mdhd, 20)
      duration = field64(s, mdhd, 24)
    else:
      timescale = field32(s, mdhd, 12)
      duration = field32(s, mdhd, 16)
    if timescale == 0: raise mp4Error("the video track has a zero timescale")
    if duration == 0:
      raise mp4Error("the video track has zero duration (not finalized)")
    # Refuse an implausible duration (no recording lasts 2^40 s), and round
    # in two parts so no product can wrap: whole seconds * 1000 < 2^50, and
    # the remainder (< timescale < 2^32) * 1000 < 2^42.
    let seconds = duration div timescale
    if seconds > maxDurationSeconds:
      raise mp4Error("the video track's duration is implausibly long")
    result.durationMs = int(seconds * 1000 +
      ((duration mod timescale) * 1000 + timescale div 2) div timescale)
    result.frames = sampleCount(s, mdia, duration)
    if result.frames < 1:
      raise mp4Error("the video track has no samples (not finalized)")
    if result.width < 1 or result.height < 1:
      raise mp4Error("the video track has no presentation size")
    return
  raise mp4Error("the movie has no video track")

proc probeMp4*(data: string): Mp4Info =
  ## Measure the MP4 held in `data`. Raises `Mp4Error` unless it is a
  ## finalized MP4 with a video track (module doc).
  var moov: Box
  var haveMoov, haveMdat = false
  for b in boxes(data, 0, data.len):
    if b.kind == "moov":
      moov = b
      haveMoov = true
    elif b.kind == "mdat":
      haveMdat = true
  if not haveMdat: raise mp4Error("no media data ('mdat' box)")
  if not haveMoov: raise mp4Error("no movie header ('moov' box): the file was not finalized")
  videoTrack(data, moov)

when not defined(js):
  proc probeMp4File*(path: string): Mp4Info =
    ## Measure the MP4 file at `path`, reading only its top-level box headers
    ## and its `moov` box. Raises `IOError` when the file cannot be read and
    ## `Mp4Error` unless it is a finalized MP4 with a video track.
    var f: File
    if not open(f, path, fmRead):
      raise newException(IOError, "cannot open " & path)
    defer: f.close()
    let total = f.getFileSize
    var pos = 0'i64
    var moov = ""
    var haveMdat = false
    var header = newString(16)
    while pos < total:
      if total - pos < 8: raise mp4Error("truncated box header at offset " & $pos)
      f.setFilePos(pos)
      if f.readChars(toOpenArray(header, 0, 7)) != 8:
        raise newException(IOError, "cannot read " & path)
      var size = int64(be32(header, 0))
      let kind = header[4 ..< 8]
      var hdr = 8'i64
      if size == 1:
        if f.readChars(toOpenArray(header, 8, 15)) != 8:
          raise mp4Error("truncated large box header at offset " & $pos)
        let big = be64(header, 8)
        # Compare before converting: a 64-bit size past the file's end (or
        # past high(int64)) is corrupt, never arithmetic that overflows.
        if big > uint64(total - pos):
          raise mp4Error("box '" & kind & "' at offset " & $pos & " overruns the file")
        size = int64(big)
        hdr = 16
      elif size == 0:
        size = total - pos
      if size < hdr or pos + size > total:
        raise mp4Error("box '" & kind & "' at offset " & $pos & " overruns the file")
      if kind == "mdat": haveMdat = true
      elif kind == "moov":
        if size > maxMoovBytes:
          raise mp4Error("the 'moov' box is larger than " & $maxMoovBytes & " bytes")
        moov = newString(int(size))
        f.setFilePos(pos)
        if f.readChars(toOpenArray(moov, 0, moov.high)) != moov.len:
          raise newException(IOError, "cannot read " & path)
      pos += size
    if not haveMdat: raise mp4Error("no media data ('mdat' box)")
    if moov.len == 0:
      raise mp4Error("no movie header ('moov' box): the file was not finalized")
    let b = boxes(moov, 0, moov.len)
    videoTrack(moov, b[0])

proc describe*(i: Mp4Info): string =
  ## A one-line summary, for messages.
  $i.width & "x" & $i.height & ", " & $i.frames & " frames, " & $i.durationMs & " ms"

