## Tests for the pure PNG codec, `gui_assert/core/png`.
##
## * `test_png_roundtrip_gray_rgb_rgba` and `test_zlib_roundtrip_edge_cases`
##   are pure: images and byte strings built in memory, encoded, decoded, and
##   compared bit for bit.
## * `test_png_decode_matches_ffmpeg_decode` mocks nothing: the PNGs are
##   written by the real, pinned ffmpeg (every pixel format its PNG encoder
##   offers that this decoder supports, and each of its row filters), and the
##   reference gray buffer is
##   ffmpeg's own gray decode through `backends/media/ffmpeg.decodeGray`, the
##   path the legacy `image_math.decodeGray` takes. One of the PNGs holds
##   every one of the 2^24 RGB colours, so the colour-to-gray conversion is
##   checked exhaustively, not on a sample. It also checks that corrupted
##   PNGs (a damaged chunk CRC, a damaged compressed stream, a truncated
##   file) are rejected, never partly decoded.
## * `test_png_encode_is_read_by_ffmpeg` checks the encoder against an
##   independent decoder: ffmpeg must read our files back to the exact bytes.
##
## ffmpeg is resolved the way the library resolves it (`FFMPEG_BIN`, then
## `PATH`; the dev shell pins it). A missing ffmpeg fails the test.

import std/[os, osproc, random, streams, strutils, unittest]

import ../src/gui_assert/core/[image, png]
import ../src/gui_assert/backends/media/ffmpeg
import ../src/gui_assert/ffmpeg_tools

proc randomImage[T: AnyImage](rng: var Rand, width, height: int): T =
  ## Mixed content: smooth gradients (which the predictive filters compress)
  ## next to noise (which they cannot), so every filter type gets chosen.
  result = T(width: width, height: height,
             pixels: newString(width * height * channels(T)))
  for y in 0 ..< height:
    for x in 0 ..< width:
      for c in 0 ..< channels(T):
        let i = (y * width + x) * channels(T) + c
        result.pixels[i] =
          if (x div 7 + y div 5) mod 3 == 0: char(rng.rand(255))
          else: char((x * 3 + y * 5 + c * 40) and 255)

proc runFfmpeg(args: seq[string]): string =
  ## Run the resolved ffmpeg and return its stdout; fail the test on error.
  let p = startProcess(resolveFfmpegBinary(), args = args,
                       options = {poStdErrToStdOut})
  result = p.outputStream.readAll()
  let code = p.waitForExit()
  p.close()
  if code != 0:
    raise newException(OSError, "ffmpeg " & args.join(" ") & " failed (" &
                       $code & "):\n" & result)

suite "core png":
  test "test_png_roundtrip_gray_rgb_rgba":
    var rng = initRand(20261020)
    for (w, h) in [(1, 1), (2, 3), (17, 9), (64, 64), (257, 131), (1, 300),
                   (300, 1)]:
      let g = randomImage[GrayImage](rng, w, h)
      let dg = decodePng(encodePng(g))
      check dg.channels == pcGray
      check dg.width == w and dg.height == h
      check dg.pixels == g.pixels

      let rgb = randomImage[RgbImage](rng, w, h)
      let drgb = decodePng(encodePng(rgb))
      check drgb.channels == pcRgb
      check drgb.pixels == rgb.pixels

      let rgba = randomImage[RgbaImage](rng, w, h)
      let drgba = decodePng(encodePng(rgba))
      check drgba.channels == pcRgba
      check drgba.pixels == rgba.pixels
    # The convenience decoders convert, and the converters agree.
    let rgb = randomImage[RgbImage](rng, 33, 21)
    check decodePngRgb(encodePng(rgb)) == rgb
    check decodePngRgba(encodePng(rgb)) == rgb.toRgba
    check decodePngGray(encodePng(rgb)) == rgb.toGray
    # A flat frame compresses: the encoder really finds matches.
    let flat = newImage(RgbaImage, 1920, 1080, 200)
    # (8.3 MB of pixels; the fixed Huffman code spends about 18 bits per
    # 258-byte match, so about 55 kB is the expected size.)
    check encodePng(flat).len < 100_000
    # Encoding refuses a buffer that does not fit its dimensions.
    expect PngError:
      discard encodePng(GrayImage(width: 4, height: 4, pixels: "short"))
    expect PngError:
      discard encodePng(GrayImage(width: 0, height: 4, pixels: ""))

  test "test_zlib_roundtrip_edge_cases":
    var rng = initRand(7)
    var cases = @["", "a", "abc", repeat('x', 100_000), repeat("ab", 40_000)]
    var noise = newString(70_000)
    for i in 0 ..< noise.len: noise[i] = char(rng.rand(255))
    cases.add noise
    # A repeat 32 KiB back: the longest distance DEFLATE allows.
    var far = newString(32768)
    for i in 0 ..< far.len: far[i] = char(rng.rand(255))
    cases.add far & far
    for c in cases:
      check zlibDecompress(zlibCompress(c)) == c
    # The stated output bound is enforced.
    expect ZlibError:
      discard zlibDecompress(zlibCompress(repeat('z', 1000)), 999)
    # A wrong Adler-32 is caught.
    var z = zlibCompress("hello, world")
    z[^1] = char(ord(z[^1]) xor 1)
    expect ZlibError:
      discard zlibDecompress(z)
    check crc32("123456789") == 0xCBF43926'u32   # the CRC-32 check value
    check adler32("Wikipedia") == 0x11E60398'u32

  test "test_png_decode_matches_ffmpeg_decode":
    let dir = getTempDir() / "gui_assert_tcore_png_" & $getCurrentProcessId()
    removeDir(dir)
    createDir(dir)
    defer: removeDir(dir)
    # A busy test pattern with noise, written by ffmpeg in every PNG pixel
    # format this decoder supports. The pixels themselves must be decoded
    # exactly in every format, which ffmpeg's own rgba decode shows.
    let pattern = "testsrc2=s=320x240:d=1,noise=alls=40:allf=t"
    for fmt in ["gray", "rgb24", "rgba", "pal8", "ya8", "monob"]:
      let path = dir / ("pattern_" & fmt & ".png")
      discard runFfmpeg(@["-hide_banner", "-loglevel", "error", "-y", "-f",
                          "lavfi", "-i", pattern, "-frames:v", "1", "-pix_fmt",
                          fmt, path])
      let reference = runFfmpeg(@["-hide_banner", "-loglevel", "error", "-i",
                                  path, "-f", "rawvideo", "-pix_fmt", "rgba",
                                  "pipe:1"])
      checkpoint fmt & ": pixels"
      check readPngFile(path).toRgba.pixels == reference
    # ffmpeg filters every row with Paeth unless told otherwise. Force each
    # filter type in turn (and ffmpeg's per-row choice, `mixed`), so the
    # unfiltering of every type is checked against an independent encoder,
    # not only against our own.
    for pred in ["none", "sub", "up", "avg", "paeth", "mixed"]:
      for fmt in ["gray", "rgb24", "rgba"]:
        let path = dir / ("pred_" & pred & "_" & fmt & ".png")
        discard runFfmpeg(@["-hide_banner", "-loglevel", "error", "-y", "-f",
                            "lavfi", "-i", pattern, "-frames:v", "1",
                            "-pix_fmt", fmt, "-pred", pred, path])
        let reference = runFfmpeg(@["-hide_banner", "-loglevel", "error",
                                    "-i", path, "-f", "rawvideo", "-pix_fmt",
                                    "rgba", "pipe:1"])
        checkpoint fmt & " with -pred " & pred & ": pixels"
        check readPngFile(path).toRgba.pixels == reference
    # The gray buffer equals ffmpeg's gray decode for every format whose gray
    # conversion goes through the per-pixel path. A palette image is the
    # exception: ffmpeg first rounds each palette entry to an 8-bit
    # studio-range luma and expands that, which can differ by one level from
    # converting the same colour directly; the palette pixels themselves are
    # checked exactly above.
    for fmt in ["gray", "rgb24", "rgba", "ya8", "monob"]:
      let path = dir / ("pattern_" & fmt & ".png")
      let pure = readPngFile(path)
      let reference = decodeGray(path)
      checkpoint fmt & ": pure " & $pure.width & "x" & $pure.height & " " &
        $pure.channels & ", ffmpeg " & $reference.width & "x" & $reference.height
      check pure.toGray == reference

    # Every 24-bit colour once (4096 x 4096), handed to ffmpeg as raw RGB
    # and written by ffmpeg as a PNG.
    var all = newImage(RgbImage, 4096, 4096)
    for i in 0 ..< 4096 * 4096:
      all.pixels[i * 3] = char((i shr 16) and 255)
      all.pixels[i * 3 + 1] = char((i shr 8) and 255)
      all.pixels[i * 3 + 2] = char(i and 255)
    writeFile(dir / "all.rgb", all.pixels)
    let allPng = dir / "all_colours.png"
    discard runFfmpeg(@["-hide_banner", "-loglevel", "error", "-y", "-f",
                        "rawvideo", "-pix_fmt", "rgb24", "-s", "4096x4096",
                        "-i", dir / "all.rgb", "-frames:v", "1", allPng])
    let pureAll = readPngFile(allPng)
    check pureAll.channels == pcRgb
    check pureAll.pixels == all.pixels
    let refAll = decodeGray(allPng)
    let pureGray = pureAll.toGray
    var mismatches = 0
    for i in 0 ..< refAll.pixels.len:
      if pureGray.pixels[i] != refAll.pixels[i]:
        if mismatches < 5:
          checkpoint "colour " & toHex(i, 6) & ": pure " &
            $ord(pureGray.pixels[i]) & ", ffmpeg " & $ord(refAll.pixels[i])
        inc mismatches
    check mismatches == 0

    # Corruption is rejected, not half-decoded.
    let good = readFile(dir / "pattern_rgb24.png")
    let idat = good.find("IDAT")
    require idat > 0
    var badData = good
    badData[idat + 20] = char(ord(badData[idat + 20]) xor 0x55)
    expect PngError:
      discard decodePng(badData)
    try:
      discard decodePng(badData)
    except PngError as e:
      check "CRC mismatch" in e.msg
    var badCrc = good
    let ihdrCrc = 8 + 8 + 13       # signature, IHDR length+type, IHDR body
    badCrc[ihdrCrc] = char(ord(badCrc[ihdrCrc]) xor 1)
    expect PngError:
      discard decodePng(badCrc)
    expect PngError:
      discard decodePng(good[0 ..< good.len div 2])
    expect PngError:
      discard decodePng("not a png at all")
    # 16-bit samples are refused, not truncated to 8 bits.
    let deep = dir / "pattern_gray16.png"
    discard runFfmpeg(@["-hide_banner", "-loglevel", "error", "-y", "-f",
                        "lavfi", "-i", pattern, "-frames:v", "1", "-pix_fmt",
                        "gray16be", deep])
    expect PngError:
      discard readPngFile(deep)

  test "test_png_encode_is_read_by_ffmpeg":
    let dir = getTempDir() / "gui_assert_tcore_png_enc_" & $getCurrentProcessId()
    removeDir(dir)
    createDir(dir)
    defer: removeDir(dir)
    var rng = initRand(99)
    let rgba = randomImage[RgbaImage](rng, 211, 97)
    writePngFile(dir / "ours_rgba.png", rgba)
    check runFfmpeg(@["-hide_banner", "-loglevel", "error", "-i",
                      dir / "ours_rgba.png", "-f", "rawvideo", "-pix_fmt",
                      "rgba", "pipe:1"]) == rgba.pixels
    let gray = randomImage[GrayImage](rng, 211, 97)
    writePngFile(dir / "ours_gray.png", gray)
    check decodeGray(dir / "ours_gray.png") == gray
