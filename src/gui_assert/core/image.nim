## GuiAssert core: in-memory 8-bit images and their conversions.
##
## Three layouts, all row-major with no row padding, the pixels held in a
## `string` used as a byte buffer (the layout `GrayImage` has always had, so
## existing buffers need no copy):
##
## * `GrayImage`: one byte per pixel;
## * `RgbImage`: three bytes per pixel, red first;
## * `RgbaImage`: four bytes per pixel, red first, straight (not
##   premultiplied) alpha.
##
## Everything here is pure: decoding and encoding files is `png` (pure) or
## the opt-in `backends/media/ffmpeg` (subprocess).

import ./geometry

type
  ImageMathError* = object of CatchableError
    ## Raised on mismatched dimensions, buffers whose size does not match the
    ## dimensions, empty images, and other structural problems. (The name is
    ## the one `image_math` has always exported; it is defined here so the
    ## pure maths and the legacy module raise one and the same type.)

  GrayImage* = object
    ## An 8-bit single-channel image. `pixels` is row-major (width * height
    ## bytes). `width` and `height` are in pixels.
    width*: int
    height*: int
    pixels*: string

  RgbImage* = object
    ## An 8-bit RGB image: `width * height * 3` bytes, row-major.
    width*: int
    height*: int
    pixels*: string

  RgbaImage* = object
    ## An 8-bit RGBA image: `width * height * 4` bytes, row-major, straight
    ## alpha.
    width*: int
    height*: int
    pixels*: string

  AnyImage* = GrayImage | RgbImage | RgbaImage
    ## Any of the three layouts, for procs that work on all of them.

const
  maxImagePixels* = 1 shl 28
    ## The largest `width * height` of any image GuiAssert decodes into
    ## memory: a PNG (`png.maxPngPixels` is this value), a frame ffmpeg
    ## decodes for `backends/media/ffmpeg` (a sampled video frame, a legacy
    ## `decodeGray`), and a `vision-segment --frames` frame after
    ## `--scale-width`. 268 million pixels: 256 MiB as gray, 1 GiB as RGBA.
    ## A larger size is refused before anything is allocated (or a decoder
    ## is started), so a hostile header or an extreme scale factor cannot
    ## exhaust memory by its size alone.

func fitsPixelCap*(width, height: int): bool =
  ## True when a `width` x `height` image is positive in both dimensions and
  ## holds at most `maxImagePixels` pixels. The product is never formed, so
  ## the check cannot overflow whatever the operands.
  width > 0 and height > 0 and height <= maxImagePixels div width

func channels*(T: typedesc[GrayImage]): int = 1
  ## Bytes per pixel of the layout.
func channels*(T: typedesc[RgbImage]): int = 3
  ## Bytes per pixel of the layout.
func channels*(T: typedesc[RgbaImage]): int = 4
  ## Bytes per pixel of the layout.

proc newImage*[T: AnyImage](_: typedesc[T], width, height: int, fill = 0): T =
  ## A `width` x `height` image with every byte set to `fill` (0..255).
  ## Raises `ImageMathError` for negative dimensions or an out-of-range fill.
  if width < 0 or height < 0:
    raise newException(ImageMathError,
      "negative image dimensions " & $width & "x" & $height)
  if fill < 0 or fill > 255:
    raise newException(ImageMathError, "fill byte out of range: " & $fill)
  result = T(width: width, height: height,
             pixels: newString(width * height * channels(T)))
  if fill != 0:
    for i in 0 ..< result.pixels.len:
      result.pixels[i] = char(fill)

proc validate*[T: AnyImage](img: T) =
  ## Raise `ImageMathError` when the buffer size does not match the
  ## dimensions, or the dimensions are negative.
  if img.width < 0 or img.height < 0:
    raise newException(ImageMathError,
      "negative image dimensions " & $img.width & "x" & $img.height)
  let expected = img.width * img.height * channels(T)
  if img.pixels.len != expected:
    raise newException(ImageMathError,
      "pixel buffer has " & $img.pixels.len & " bytes, expected " & $expected &
      " for " & $img.width & "x" & $img.height)

func rgbToGray*(r, g, b: int): int =
  ## Reduce one 8-bit RGB pixel to an 8-bit gray value.
  ##
  ## This is BT.601 luma computed with the same fixed-point steps ffmpeg's
  ## libswscale takes when it converts `rgb24` to `gray`, so a frame decoded
  ## by the pure PNG decoder and the same frame decoded by
  ## `ffmpeg -pix_fmt gray` give byte-identical gray buffers, and SSIM and
  ## hashes do not depend on which decoder produced the pixels.
  ## `tests/tcore_png.nim` checks every one of the 2^24 colours against the
  ## pinned ffmpeg. The steps (libswscale `input.c` `rgb24ToY_c`,
  ## `swscale.c` `lumRangeToJpeg_c` / `solve_range_convert`, `output.c`
  ## `yuv2plane1_8_c`; https://github.com/FFmpeg/FFmpeg/tree/n8.0/libswscale):
  ##
  ## 1. studio-range (16..235) luma at 7 fractional bits, from the 15-bit
  ##    coefficients round(k * 219/255 * 2^15) for k = 0.299, 0.587, 0.114;
  ## 2. expansion from studio range to full range (0..255) with a 14-bit
  ##    multiplier and offset;
  ## 3. rounding the 7 fractional bits away, clamped to 0..255.
  const
    ry = 8414          # round(0.299 * 219 / 255 * 2^15)
    gy = 16519         # round(0.587 * 219 / 255 * 2^15)
    by = 3208          # round(0.114 * 219 / 255 * 2^15)
    rangeMul = 19078   # ceil(((255 shl 21) div 219) / 2^7)
    rangeOff = (255 shl 21) - (235 shl 7) * rangeMul
  let studio = ((ry * r + gy * g + by * b + (32 shl 14) + (1 shl 8)) shr 9) shl 1
  let full = min((studio * rangeMul + rangeOff) shr 14, 32767)
  result = max(0, min(255, (full + 64) shr 7))

proc toGray*(img: RgbImage): GrayImage =
  ## Convert to gray with `rgbToGray`.
  img.validate()
  result = GrayImage(width: img.width, height: img.height,
                     pixels: newString(img.width * img.height))
  for i in 0 ..< img.width * img.height:
    result.pixels[i] = char(rgbToGray(ord(img.pixels[i * 3]),
                                      ord(img.pixels[i * 3 + 1]),
                                      ord(img.pixels[i * 3 + 2])))

proc toGray*(img: RgbaImage): GrayImage =
  ## Convert to gray with `rgbToGray`, dropping alpha (not compositing it).
  img.validate()
  result = GrayImage(width: img.width, height: img.height,
                     pixels: newString(img.width * img.height))
  for i in 0 ..< img.width * img.height:
    result.pixels[i] = char(rgbToGray(ord(img.pixels[i * 4]),
                                      ord(img.pixels[i * 4 + 1]),
                                      ord(img.pixels[i * 4 + 2])))

proc toRgb*(img: GrayImage): RgbImage =
  ## Replicate the gray value into all three channels.
  img.validate()
  result = RgbImage(width: img.width, height: img.height,
                    pixels: newString(img.width * img.height * 3))
  for i in 0 ..< img.width * img.height:
    let g = img.pixels[i]
    result.pixels[i * 3] = g
    result.pixels[i * 3 + 1] = g
    result.pixels[i * 3 + 2] = g

proc toRgb*(img: RgbaImage): RgbImage =
  ## Drop the alpha channel (not compositing it).
  img.validate()
  result = RgbImage(width: img.width, height: img.height,
                    pixels: newString(img.width * img.height * 3))
  for i in 0 ..< img.width * img.height:
    result.pixels[i * 3] = img.pixels[i * 4]
    result.pixels[i * 3 + 1] = img.pixels[i * 4 + 1]
    result.pixels[i * 3 + 2] = img.pixels[i * 4 + 2]

proc toRgba*(img: GrayImage): RgbaImage =
  ## Replicate the gray value into the colour channels; alpha is opaque.
  img.validate()
  result = RgbaImage(width: img.width, height: img.height,
                     pixels: newString(img.width * img.height * 4))
  for i in 0 ..< img.width * img.height:
    let g = img.pixels[i]
    result.pixels[i * 4] = g
    result.pixels[i * 4 + 1] = g
    result.pixels[i * 4 + 2] = g
    result.pixels[i * 4 + 3] = '\xFF'

proc toRgba*(img: RgbImage): RgbaImage =
  ## Add an opaque alpha channel.
  img.validate()
  result = RgbaImage(width: img.width, height: img.height,
                     pixels: newString(img.width * img.height * 4))
  for i in 0 ..< img.width * img.height:
    result.pixels[i * 4] = img.pixels[i * 3]
    result.pixels[i * 4 + 1] = img.pixels[i * 3 + 1]
    result.pixels[i * 4 + 2] = img.pixels[i * 3 + 2]
    result.pixels[i * 4 + 3] = '\xFF'

proc crop*[T: AnyImage](img: T, r: Rect): T =
  ## The sub-image covered by `r`, which must lie inside `img` and be
  ## non-empty. Raises `ImageMathError` otherwise: a crop is never silently
  ## clipped, because a caller that asked for a region outside the frame has
  ## a coordinate bug the clip would hide.
  img.validate()
  if r.isEmpty or r.x < 0 or r.y < 0 or r.right > img.width or
     r.bottom > img.height:
    raise newException(ImageMathError,
      "crop " & $r & " is empty or outside the " & $img.width & "x" &
      $img.height & " image")
  const ch = channels(T)
  result = T(width: r.width, height: r.height,
             pixels: newString(r.width * r.height * ch))
  let rowBytes = r.width * ch
  for row in 0 ..< r.height:
    let src = ((r.y + row) * img.width + r.x) * ch
    let dst = row * rowBytes
    for k in 0 ..< rowBytes:
      result.pixels[dst + k] = img.pixels[src + k]

proc scaleNearest*[T: AnyImage](img: T, width, height: int): T =
  ## Resize to `width` x `height` by nearest-neighbour sampling (exact for
  ## integer up-scaling, which is what rendering fixture frames needs).
  ## Raises `ImageMathError` for an empty source or target.
  img.validate()
  if width <= 0 or height <= 0 or img.width == 0 or img.height == 0:
    raise newException(ImageMathError,
      "cannot scale " & $img.width & "x" & $img.height & " to " & $width &
      "x" & $height)
  const ch = channels(T)
  result = T(width: width, height: height,
             pixels: newString(width * height * ch))
  for y in 0 ..< height:
    let sy = y * img.height div height
    for x in 0 ..< width:
      let sx = x * img.width div width
      let src = (sy * img.width + sx) * ch
      let dst = (y * width + x) * ch
      for k in 0 ..< ch:
        result.pixels[dst + k] = img.pixels[src + k]
