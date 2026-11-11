## Unit tests of `core/mp4`: measuring a finalized MP4 recording (spec §7.5,
## "Recordings").
##
## Stand-ins: none. The MP4 files are written by the real, pinned ffmpeg
## (`FFMPEG_BIN`, then `PATH`; the dev shell pins it) and measured
## independently by its `ffprobe`, decoding every frame; the probe must agree
## with that on frames, duration and size. The unfinalized files are real
## ffmpeg output with the `moov` index cut off, which is what a recorder that
## died before finalizing leaves. A missing ffmpeg or ffprobe fails the test.

import std/[os, osproc, strutils, unittest]

import ../src/gui_assert/core/mp4
import ../src/gui_assert/ffmpeg_tools

proc tool(name: string): string =
  ## ffmpeg, or the ffprobe beside it.
  let ff = resolveFfmpegBinary()
  if name == "ffmpeg": return ff
  result = ff.parentDir / ("ffprobe" & ExeExt)
  if not fileExists(result): result = findExe("ffprobe")
  doAssert result.len > 0, "ffprobe not found next to " & ff & " or on PATH"

proc run(exe: string, args: seq[string]): string =
  let (output, code) = execCmdEx(quoteShellCommand(@[exe] & args))
  doAssert code == 0, exe & " " & args.join(" ") & " failed: " & output
  output

proc makeMp4(path: string, frames, fps, w, h: int, extra: seq[string] = @[]) =
  discard run(tool("ffmpeg"), @["-hide_banner", "-loglevel", "error", "-y",
    "-f", "lavfi", "-i", "testsrc=size=" & $w & "x" & $h & ":rate=" & $fps,
    "-frames:v", $frames, "-c:v", "mpeg4", "-pix_fmt", "yuv420p"] & extra & @[path])

proc ffprobeCounts(path: string): tuple[frames, width, height: int, durationMs: int] =
  ## What ffprobe measures, decoding every frame.
  let o = run(tool("ffprobe"), @["-v", "error", "-select_streams", "v:0",
    "-count_frames", "-show_entries", "stream=nb_read_frames,width,height,duration",
    "-of", "default=noprint_wrappers=1", path])
  for line in o.splitLines:
    let kv = line.split('=', 1)
    if kv.len != 2: continue
    case kv[0]
    of "nb_read_frames": result.frames = parseInt(kv[1])
    of "width": result.width = parseInt(kv[1])
    of "height": result.height = parseInt(kv[1])
    of "duration": result.durationMs = int(parseFloat(kv[1]) * 1000.0 + 0.5)
    else: discard

let work = getTempDir() / ("tcore_mp4-" & $getCurrentProcessId())
createDir(work)

suite "mp4 probe":
  test "test_mp4_probe_matches_ffprobe":
    # Several frame counts, rates and sizes, moov at the end (ffmpeg's
    # default, what a recorder writes last) and at the front (faststart).
    for (frames, fps, w, h, extra) in [(1, 10, 64, 48, newSeq[string]()),
                                       (7, 10, 800, 600, newSeq[string]()),
                                       (30, 30, 320, 240, @["-movflags", "+faststart"]),
                                       (12, 24, 162, 90, newSeq[string]())]:
      let p = work / ("v" & $frames & "-" & $fps & ".mp4")
      makeMp4(p, frames, fps, w, h, extra)
      let got = probeMp4File(p)
      let want = ffprobeCounts(p)
      checkpoint p & ": probe " & got.describe & ", ffprobe " & $want
      check got.frames == frames and want.frames == frames
      check got.width == want.width and got.height == want.height
      check got.width == w and got.height == h
      check got.durationMs == want.durationMs
      check got.durationMs == (frames * 1000 + fps div 2) div fps
      check probeMp4(readFile(p)) == got

  test "test_mp4_probe_refuses_an_unfinalized_file":
    let p = work / "whole.mp4"
    makeMp4(p, 5, 10, 64, 48)
    let bytes = readFile(p)
    let moov = bytes.find("moov")
    check moov > 8
    # Without its moov index, the file is not finalized.
    let cut = work / "cut.mp4"
    writeFile(cut, bytes[0 ..< moov - 4])
    expect Mp4Error: discard probeMp4File(cut)
    expect Mp4Error: discard probeMp4(bytes[0 ..< moov - 4])
    # A box that overruns the file, an empty file and a non-MP4.
    writeFile(cut, bytes[0 ..< bytes.len - 10])
    expect Mp4Error: discard probeMp4File(cut)
    writeFile(cut, "")
    expect Mp4Error: discard probeMp4File(cut)
    writeFile(cut, "\x89PNG\r\n\x1a\n" & repeat('\0', 64))
    expect Mp4Error: discard probeMp4File(cut)
    expect IOError: discard probeMp4File(work / "missing.mp4")
    # Control: the whole file still measures.
    check probeMp4File(p).frames == 5

  test "test_mp4_probe_refuses_malformed_boxes":
    # The probe reads untrusted files: a field outside its own box, a 64-bit
    # size past the file's end and a duration that would overflow are each
    # an Mp4Error (found by fuzzing; before, IndexDefect / RangeDefect /
    # OverflowDefect crashed the caller).
    proc be(v: uint32): string =
      result = newString(4)
      for k in 0 .. 3: result[k] = char((v shr (24 - 8 * k)) and 0xff)
    proc box(kind, payload: string): string = be(uint32(8 + payload.len)) & kind & payload
    let mdat = box("mdat", "data")
    let hdlr = box("hdlr", repeat('\0', 8) & "vide")
    let tkhd = box("tkhd", repeat('\0', 76) & be(64'u32 shl 16) & be(48'u32 shl 16))
    let minf = box("minf", box("stbl", box("stsz", repeat('\0', 8) & be(5))))
    proc movie(mdia: string): string = mdat & box("moov", box("trak", box("mdia", mdia) & tkhd))
    let malformed = [
      mdat & box("moov", box("trak", box("mdia", box("hdlr", "")))),       # short hdlr
      mdat & box("moov", box("trak", box("mdia", hdlr) & box("tkhd", ""))), # empty tkhd
      movie(hdlr & box("mdhd", "") & minf),                                # empty mdhd
      movie(hdlr & box("mdhd", "\1\0\0\0" & repeat('\0', 16) & be(1) &
                       be(0xffffffff'u32) & be(0xffffffff'u32)) & minf)]  # 2^64 ticks
    for m in malformed:
      expect Mp4Error: discard probeMp4(m)
    let big = work / "big.mp4"
    for hi in [0xffffffff'u32, 0x7fffffff'u32]:
      writeFile(big, mdat & be(1) & "moov" & be(hi) & be(0xffffffff'u32) & repeat('\0', 8))
      expect Mp4Error: discard probeMp4File(big)
    # Control: the same movie with a well-formed mdhd measures.
    let good = movie(hdlr & box("mdhd", repeat('\0', 12) & be(10) & be(5)) & minf)
    check probeMp4(good) == Mp4Info(durationMs: 500, frames: 5, width: 64, height: 48)

  test "test_mp4_probe_counts_only_frames_within_the_track_duration":
    # A constant-rate recorder (wf-recorder -r) may end the track with a
    # sample of zero duration at the track's end: stts (4 x 1 tick, 1 x 0),
    # duration 4 ticks. No player presents it; it is not a frame.
    proc be(v: uint32): string =
      result = newString(4)
      for k in 0 .. 3: result[k] = char((v shr (24 - 8 * k)) and 0xff)
    proc box(kind, payload: string): string = be(uint32(8 + payload.len)) & kind & payload
    let hdlr = box("hdlr", repeat('\0', 8) & "vide")
    let tkhd = box("tkhd", repeat('\0', 76) & be(64'u32 shl 16) & be(48'u32 shl 16))
    let mdhd = box("mdhd", repeat('\0', 12) & be(10) & be(4))
    proc movie(stts: string): string =
      let stbl = box("stbl", box("stsz", repeat('\0', 8) & be(5)) & stts)
      box("mdat", "data") & box("moov", box("trak", box("mdia", hdlr & mdhd &
        box("minf", stbl)) & tkhd))
    let trailing = box("stts", repeat('\0', 4) & be(2) & be(4) & be(1) & be(1) & be(0))
    check probeMp4(movie(trailing)) == Mp4Info(durationMs: 400, frames: 4, width: 64,
                                                height: 48)
    # Control: five one-tick samples in a four-tick track also present four;
    # with the duration they need, all five count.
    let even = box("stts", repeat('\0', 4) & be(1) & be(5) & be(1))
    check probeMp4(movie(even)).frames == 4
    let mdhd5 = box("mdhd", repeat('\0', 12) & be(10) & be(5))
    let stbl5 = box("stbl", box("stsz", repeat('\0', 8) & be(5)) & even)
    check probeMp4(box("mdat", "data") & box("moov", box("trak", box("mdia", hdlr & mdhd5 &
      box("minf", stbl5)) & tkhd))).frames == 5
    # A malformed entry count runs into the end of the box: refused.
    let overrun = box("stts", repeat('\0', 4) & be(9) & be(2) & be(1))
    expect Mp4Error: discard probeMp4(movie(overrun))
    # A real file whose track duration is cut to four of its five frames
    # (mdhd patched in place): four frames, 400 ms. (ffprobe presents by the
    # edit list, which still spans five; the recorders' files that motivate
    # the rule have an edit list as long as the track, see the live suite.)
    let p = work / "cut-duration.mp4"
    makeMp4(p, 5, 10, 64, 48)
    var bytes = readFile(p)
    let at = bytes.find("mdhd")
    check at > 0 and bytes[at + 4] == '\0'          # version 0
    let field = at + 4 + 16                          # duration (after the timescale)
    var d = 0'u32
    for k in 0 .. 3: d = (d shl 8) or uint32(ord(bytes[field + k]))
    let cut = be(d * 4 div 5)
    for k in 0 .. 3: bytes[field + k] = cut[k]
    writeFile(p, bytes)
    let got = probeMp4File(p)
    check got.frames == 4 and got.durationMs == 400

removeDir(work)
